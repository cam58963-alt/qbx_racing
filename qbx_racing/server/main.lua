-- ===================================
-- CAM Racing System - Server Main
-- 完全統合版 v4.2.0
-- ===================================

-- ===================================
-- グローバル変数とキャッシュ
-- ===================================
local ActiveSessions = {} -- アクティブなマルチプレイヤーセッション

-- ===================================
-- ヘルパー関数群
-- ===================================

-- 安全なConfig値取得（サーバーサイド用）
local function GetConfigValue(path, defaultValue)
    local keys = {}
    for key in string.gmatch(path, "[^%.]+") do
        table.insert(keys, key)
    end
    
    local current = Config
    for _, key in ipairs(keys) do
        if current and type(current) == 'table' and current[key] ~= nil then
            current = current[key]
        else
            return defaultValue
        end
    end
    return current
end

-- 金額フォーマット
local function FormatMoney(amount)
    if not amount or amount == 0 then return '0' end
    return tostring(amount):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

-- QBXプレイヤー取得（環境対応版）
local function GetPlayer(source)
    -- 方法1: 直接エクスポート（QBX推奨）
    local success, player = pcall(function()
        return exports.qbx_core:GetPlayer(source)
    end)
    
    if success and player then
        return player
    end
    
    -- 方法2: CoreObject方式（フォールバック）
    local success2, corePlayer = pcall(function()
        local QBX = exports['qbx_core']:GetCoreObject()
        return QBX.Functions.GetPlayer(source)
    end)
    
    return success2 and corePlayer or nil
end

-- 整数に変換（数値でない・小数・NaN は nil）
local function ToInteger(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.tointeger(n)
end

-- 文字数（バイト数ではなく）で切り詰める。日本語が途中で切れて不正な文字列にならないように
-- 文字列でない・UTF-8 として不正な場合は nil
local function TruncateText(text, maxChars)
    if type(text) ~= 'string' then return nil end
    local length = utf8.len(text)
    if not length then return nil end
    if length <= maxChars then return text end
    return text:sub(1, utf8.offset(text, maxChars + 1) - 1)
end

-- お金を渡す（返金・賞金）
-- 本人がオンラインならその人に、オフラインなら qbx_core に citizenid で渡す（qbx_core がオフライン保存に対応）
local function GiveMoney(src, citizenid, amount, reason)
    amount = ToInteger(amount)
    if not amount or amount <= 0 then return true end
    local currency = GetConfigValue('Race.currency', 'cash')
    
    local Player = src and GetPlayer(src)
    if Player and (not citizenid or Player.PlayerData.citizenid == citizenid) then
        -- 失敗（お金の種類が無いなど）は台帳に伝えて、未払いに戻してもらう
        return Player.Functions.AddMoney(currency, amount, reason) ~= false
    end
    
    if citizenid then
        local ok, result = pcall(function()
            return exports.qbx_core:AddMoney(citizenid, currency, amount, reason)
        end)
        if ok and result then return true end
    end
    
    print(('^1[CAM Racing]^7 お金を渡せませんでした: citizenid=%s 金額=$%s（%s）'):format(
        tostring(citizenid), FormatMoney(amount), tostring(reason)))
    return false
end

-- ===================================
-- 支払い台帳（qbx_race_payouts）
-- 返金・賞金は「先に DB へ支払い予定を記録 → 1件ずつ支払い済みにしてから渡す」。
-- 途中でサーバーが落ちても、未払いの予定は次回起動時に支払われ、二重には払われない。
-- ===================================

-- 支払い予定を記録する。extraQueries（状態の更新など）も同じトランザクションで実行する
-- payouts: { {citizenid = ..., amount = ..., reason = ...}, ... }
local function RecordPayouts(sessionId, payouts, extraQueries)
    local queries = {}
    for _, query in ipairs(extraQueries or {}) do
        queries[#queries + 1] = query
    end
    for _, payout in ipairs(payouts or {}) do
        local amount = ToInteger(payout.amount)
        if amount and amount > 0 and payout.citizenid then
            queries[#queries + 1] = {
                query = 'INSERT INTO qbx_race_payouts (session_id, citizenid, amount, reason) VALUES (?, ?, ?, ?)',
                values = {sessionId, payout.citizenid, amount, payout.reason or 'race-payout'}
            }
        end
    end
    if #queries == 0 then return true end
    return MySQL.transaction.await(queries) and true or false
end

-- 未払いの支払い予定を実行する（sessionId が nil なら全セッション分）
-- sources: citizenid → source（オンラインの人に直接渡すため。無ければ citizenid で渡す）
-- citizenid を指定すると、そのセッションのその人の分だけ（TA・デイリー報酬は session_id = 0 で共通のため）
local function SettlePayouts(sessionId, sources, citizenid)
    local rows
    if sessionId and citizenid then
        rows = MySQL.query.await('SELECT id, citizenid, amount, reason FROM qbx_race_payouts WHERE session_id = ? AND citizenid = ? AND paid = 0', {sessionId, citizenid})
    elseif sessionId then
        rows = MySQL.query.await('SELECT id, citizenid, amount, reason FROM qbx_race_payouts WHERE session_id = ? AND paid = 0', {sessionId})
    else
        rows = MySQL.query.await('SELECT id, citizenid, amount, reason FROM qbx_race_payouts WHERE paid = 0')
    end
    
    for _, row in ipairs(rows or {}) do
        -- 先に「支払い済み」にできた分だけ渡す（同じ予定を二重に払わない）
        local claimed = MySQL.update.await('UPDATE qbx_race_payouts SET paid = 1 WHERE id = ? AND paid = 0', {row.id})
        if claimed and claimed > 0 then
            local src = sources and sources[row.citizenid]
            if not GiveMoney(src, row.citizenid, row.amount, row.reason) then
                -- 渡せなかった分は未払いに戻して、次回起動時にもう一度試す
                MySQL.update('UPDATE qbx_race_payouts SET paid = 0 WHERE id = ?', {row.id})
            end
        end
    end
end

-- 同じプレイヤーのセッション作成・参加が同時に走らないようにする（DB 待ちの間の二重課金防止）
local busyPlayers = {}
local function RunExclusive(src, fn)
    if busyPlayers[src] then
        return {success = false, message = '処理中です。少し待ってからもう一度お試しください'}
    end
    busyPlayers[src] = true
    local ok, result = pcall(fn)
    busyPlayers[src] = nil
    if not ok then
        print('^1[CAM Racing]^7 エラー: ' .. tostring(result))
        return {success = false, message = 'エラーが発生しました'}
    end
    return result
end

-- ソロレースの開始記録（サーバー側でタイムを確認するため）
local soloRuns = {}

-- コースを最高速度で走っても必要な最短時間（これより速いゴールは不正とみなす）
local function CalculateMinRaceTimeMs(race)
    if not GetConfigValue('Security.antiCheat.enabled', true) then return 0 end
    
    local checkpoints = race.checkpoints or {}
    local laps = race.race_type == 'sprint' and 1 or math.max(1, ToInteger(race.laps) or 1)
    local function dist(a, b)
        return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
    end
    
    local lapDistance = 0
    for i = 2, #checkpoints do
        lapDistance = lapDistance + dist(checkpoints[i - 1], checkpoints[i])
    end
    -- 周回は毎周スタート地点（CP1）に戻る（最終周もスタート地点がゴール）
    local closing = (race.race_type ~= 'sprint' and #checkpoints > 1) and dist(checkpoints[#checkpoints], checkpoints[1]) or 0
    local total = lapDistance * laps + closing * laps
    
    -- チェックポイントの判定半径ぶんの近道を差し引く
    for _, cp in ipairs(checkpoints) do
        total = total - 2 * (tonumber(cp.radius) or 10.0) * laps
    end
    
    local maxSpeed = GetConfigValue('Security.antiCheat.maxSpeed', 500.0) / 3.6 -- km/h → m/s
    if total <= 0 or maxSpeed <= 0 then return 0 end
    return math.floor(total / maxSpeed * 1000)
end

-- サーバーで見たプレイヤーの位置（OneSync が無いなどで取れない場合は false）
local function GetServerPlayerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    if coords.x == 0.0 and coords.y == 0.0 and coords.z == 0.0 then return false end
    return coords
end

-- サーバーで見たプレイヤーの位置がチェックポイントの近くか（位置が取れない場合は確認しない）
-- coords: 報告が届いた時点の位置（省略すると今の位置）
local function IsPlayerNearCheckpoint(src, cp, coords)
    if not cp then return false end
    if coords == nil then coords = GetServerPlayerCoords(src) end
    if not coords then return true end
    local allowed = (tonumber(cp.radius) or 10.0) + GetConfigValue('Security.antiCheat.progressDistanceMargin', 100.0)
    return #(coords - vector3(cp.x, cp.y, cp.z)) <= allowed
end

-- コース上の位置 index のチェックポイント（周回の index n+1 はスタート地点 = CP1）
local function CourseCheckpointAt(checkpoints, index)
    return checkpoints[index] or checkpoints[1]
end

-- 曲がり角ガイド取得（手動設置分）
local function GetRaceTurnGuides(raceId)
    return MySQL.query.await([[
        SELECT checkpoint_order, x, y, z, direction, segments FROM qbx_race_turn_guides 
        WHERE race_id = ? ORDER BY id ASC
    ]], {raceId}) or {}
end

-- ドライバープロフィール取得
local function GetDriverProfile(citizenid)
    if not citizenid then return nil end
    
    return MySQL.single.await(
        'SELECT * FROM qbx_driver_profiles WHERE citizenid = ?', 
        {citizenid}
    )
end

-- レース管理権限チェック（作成・編集・削除）
local function HasRacePermission(source)
    local Player = GetPlayer(source)
    if not Player then return false end
    
    local job = Player.PlayerData.job.name
    local allowedJobs = Config.RaceManagerJobs or {'cityhall', 'raceorganizer'}
    
    for _, allowedJob in ipairs(allowedJobs) do
        if job == allowedJob then
            return true
        end
    end
    return false
end

-- 掛けレース作成権限チェック
local function HasBetRacePermission(source)
    local Player = GetPlayer(source)
    if not Player then return false end
    
    local job = Player.PlayerData.job.name
    local allowedJobs = Config.BetRaceJobs or Config.RaceManagerJobs or {'cityhall', 'raceorganizer'}
    
    for _, allowedJob in ipairs(allowedJobs) do
        if job == allowedJob then
            return true
        end
    end
    return false
end

-- 入力値検証
local function ValidateDriverName(name)
    if not name or type(name) ~= 'string' then return false end
    
    local minLen = Config.DriverName and Config.DriverName.minLength or 3
    local maxLen = Config.DriverName and Config.DriverName.maxLength or 20
    local pattern = Config.DriverName and Config.DriverName.pattern or '^[a-zA-Z0-9_]+$'
    
    if #name < minLen or #name > maxLen then return false end
    if not string.match(name, pattern) then return false end
    
    return true
end

-- ===================================
-- プロフィール管理システム
-- ===================================

-- プロフィール取得コールバック
lib.callback.register('qbx_racing:getProfile', function(source)
    local Player = GetPlayer(source)
    if not Player then 
        print('^1[CAM Racing]^7 プレイヤーデータ取得失敗: ' .. tostring(source))
        return nil 
    end
    
    local profile = GetDriverProfile(Player.PlayerData.citizenid)
    return {
        hasProfile = profile ~= nil,
        driverName = profile and profile.driver_name or nil,
        isAdmin = HasRacePermission(source),
        canCreateBetRace = HasBetRacePermission(source)
    }
end)

-- ドライバー登録
lib.callback.register('qbx_racing:server:registerDriver', function(source, data)
    local Player = GetPlayer(source)
    if not Player then 
        return {success = false, message = 'プレイヤーデータが見つかりません'} 
    end
    
    if not data or not data.driverName then
        return {success = false, message = 'ドライバーネームが指定されていません'}
    end
    
    local driverName = tostring(data.driverName):gsub('^%s+', ''):gsub('%s+$', '')
    
    -- 名前検証
    if not ValidateDriverName(driverName) then
        return {success = false, message = '無効なドライバーネームです（3-20文字、英数字とアンダースコアのみ）'}
    end
    
    -- 重複チェック
    local exists = MySQL.scalar.await(
        'SELECT 1 FROM qbx_driver_profiles WHERE driver_name = ?', 
        {driverName}
    )
    if exists then
        return {success = false, message = 'そのドライバーネームは既に使用されています'}
    end
    
    -- 登録処理
    local success = MySQL.insert.await([[
        INSERT INTO qbx_driver_profiles (citizenid, driver_name, total_races, total_wins, points) 
        VALUES (?, ?, 0, 0, ?)
    ]], {Player.PlayerData.citizenid, driverName, ToInteger(GetConfigValue('Ranking.startPoints', 1000)) or 1000})
    
    if success then
        TriggerClientEvent('ox_lib:notify', source, {
            title = '登録完了',
            description = 'ドライバーネーム「' .. driverName .. '」を登録しました',
            type = 'success'
        })
        return {success = true, driverName = driverName}
    else
        return {success = false, message = 'データベースエラーが発生しました'}
    end
end)

-- ドライバーネーム変更
lib.callback.register('qbx_racing:server:updateDriverName', function(source, data)
    local Player = GetPlayer(source)
    if not Player then 
        return {success = false, message = 'プレイヤーデータが見つかりません'} 
    end
    
    if not data or not data.driverName then
        return {success = false, message = 'ドライバーネームが指定されていません'}
    end
    
    local driverName = tostring(data.driverName):gsub('^%s+', ''):gsub('%s+$', '')
    
    -- 名前検証
    if not ValidateDriverName(driverName) then
        return {success = false, message = '無効なドライバーネームです'}
    end
    
    -- 重複チェック（自分以外）
    local exists = MySQL.scalar.await([[
        SELECT 1 FROM qbx_driver_profiles 
        WHERE driver_name = ? AND citizenid != ?
    ]], {driverName, Player.PlayerData.citizenid})
    
    if exists then
        return {success = false, message = 'そのドライバーネームは既に使用されています'}
    end
    
    -- 更新処理
    local success = MySQL.update.await([[
        UPDATE qbx_driver_profiles 
        SET driver_name = ? 
        WHERE citizenid = ?
    ]], {driverName, Player.PlayerData.citizenid})
    
    if success and success > 0 then
        TriggerClientEvent('ox_lib:notify', source, {
            title = '更新完了',
            description = 'ドライバーネームを「' .. driverName .. '」に変更しました',
            type = 'success'
        })
        return {success = true, driverName = driverName}
    else
        return {success = false, message = 'データベースエラーが発生しました'}
    end
end)

-- ===================================
-- レース管理システム
-- ===================================

-- レース一覧取得
lib.callback.register('qbx_racing:getRaces', function(source)
    local races = MySQL.query.await([[
        SELECT r.*, 
               COUNT(rt.id) as total_attempts,
               MIN(rt.time_ms) as best_time,
               (SELECT driver_name FROM qbx_race_times 
                WHERE race_id = r.id ORDER BY time_ms ASC LIMIT 1) as best_player
        FROM qbx_races r
        LEFT JOIN qbx_race_times rt ON r.id = rt.race_id
        WHERE r.is_active = 1
        GROUP BY r.id
        ORDER BY r.created_at DESC
    ]])
    
    return races or {}
end)

-- レース詳細取得（チェックポイント含む）
lib.callback.register('qbx_racing:getRaceDetails', function(source, raceId)
    if not raceId then return nil end
    
    local race = MySQL.single.await(
        'SELECT * FROM qbx_races WHERE id = ? AND is_active = 1', 
        {raceId}
    )
    
    if race then
        race.checkpoints = MySQL.query.await([[
            SELECT x, y, z, radius FROM qbx_race_checkpoints 
            WHERE race_id = ? ORDER BY checkpoint_order ASC
        ]], {raceId}) or {}
        race.turnGuides = GetRaceTurnGuides(raceId)
    end
    
    return race
end)

-- ランキング取得
lib.callback.register('qbx_racing:getLeaderboard', function(source, raceId)
    if not raceId then return {} end
    
    return MySQL.query.await([[
        SELECT driver_name, time_ms, vehicle_model, completed_at,
               ROW_NUMBER() OVER (ORDER BY time_ms ASC) as position
        FROM qbx_race_times
        WHERE race_id = ?
        ORDER BY time_ms ASC
        LIMIT 20
    ]], {raceId}) or {}
end)

-- レース作成
RegisterNetEvent('qbx_racing:server:createRace', function(data)
    local src = source
    local Player = GetPlayer(src)
    
    if not Player then
        print('^1[CAM Racing]^7 レース作成: プレイヤーデータなし')
        return
    end
    
    if not HasRacePermission(src) then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'エラー',
            description = 'レース作成権限がありません',
            type = 'error'
        })
        return
    end
    
    -- 入力チェック（クライアントから来た値はそのまま信用しない）
    data = type(data) == 'table' and data or {}
    local minCheckpoints = GetConfigValue('Checkpoint.minCheckpoints', 3)
    local maxCheckpoints = GetConfigValue('Checkpoint.maxCheckpoints', 50)
    
    local name = type(data.name) == 'string' and data.name:gsub('^%s+', ''):gsub('%s+$', '') or ''
    local nameLength = utf8.len(name) or #name
    local description = TruncateText(data.description, 500) or ''
    
    local vehicleType = data.vehicleType or 'car'
    if not (Config.VehicleTypes and Config.VehicleTypes[vehicleType]) then vehicleType = nil end
    local raceType = data.raceType or 'circuit'
    if raceType ~= 'circuit' and raceType ~= 'sprint' then raceType = nil end
    local maxLaps = GetConfigValue('RaceTypes.circuit.maxLaps', 10)
    local laps = raceType == 'sprint' and 1 or math.max(1, math.min(maxLaps, ToInteger(data.laps) or 1))
    
    local checkpoints = {}
    local checkpointsValid = type(data.checkpoints) == 'table'
    for _, cp in ipairs(checkpointsValid and data.checkpoints or {}) do
        local x = type(cp) == 'table' and tonumber(cp.x)
        local y = type(cp) == 'table' and tonumber(cp.y)
        local z = type(cp) == 'table' and tonumber(cp.z)
        if not (x and y and z) then
            checkpointsValid = false
            break
        end
        table.insert(checkpoints, {x = x, y = y, z = z})
    end
    
    if not checkpointsValid or not vehicleType or not raceType or nameLength < 1 or nameLength > 100
        or #checkpoints < minCheckpoints or #checkpoints > maxCheckpoints then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'エラー',
            description = string.format('レース名（1〜100文字）とチェックポイント（%d〜%d個）を確認してください',
                minCheckpoints, maxCheckpoints),
            type = 'error'
        })
        return
    end
    
    -- 判定半径は車両タイプごとの設定に揃える（表示のリングと判定を一致させる）
    local radius = GetConfigValue('VehicleTypes.' .. vehicleType .. '.checkpoint.radius',
        GetConfigValue('Checkpoint.radius', 10.0))
    
    local profile = GetDriverProfile(Player.PlayerData.citizenid)
    if not profile then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'エラー',
            description = 'ドライバープロフィールを先に作成してください',
            type = 'error'
        })
        return
    end
    
    -- レース作成
    local raceId = MySQL.insert.await([[
        INSERT INTO qbx_races 
        (name, description, vehicle_type, race_type, laps, creator_driver_name) 
        VALUES (?, ?, ?, ?, ?, ?)
    ]], {
        name,
        description,
        vehicleType,
        raceType,
        laps,
        profile.driver_name
    })
    
    if raceId then
        -- チェックポイントとガイドはまとめて保存（途中で失敗したら全部取り消す）
        local queries = {}
        for i, checkpoint in ipairs(checkpoints) do
            queries[#queries + 1] = {
                query = 'INSERT INTO qbx_race_checkpoints (race_id, checkpoint_order, x, y, z, radius) VALUES (?, ?, ?, ?, ?, ?)',
                values = {raceId, i, checkpoint.x, checkpoint.y, checkpoint.z, radius}
            }
        end
        
        -- 曲がり角ガイド保存（手動設置分、checkpoint は一番近いチェックポイント）
        local checkpointCount = #checkpoints
        local maxTurnGuides = Config.Checkpoint and Config.Checkpoint.maxTurnGuides or 50
        local savedGuides = 0
        for _, guide in ipairs(type(data.turnGuides) == 'table' and data.turnGuides or {}) do
            if type(guide) ~= 'table' then goto continue end
            
            local order = tonumber(guide.checkpoint)
            order = order and math.tointeger(order)
            
            local x, y, z = tonumber(guide.x), tonumber(guide.y), tonumber(guide.z)
            local isValid = order and order >= 1 and order <= checkpointCount
                and x and y and z
                and (guide.direction == 'left' or guide.direction == 'right')
            
            -- 横に並べる矢印の数（1 ～ maxSegments）
            local maxSegments = GetConfigValue('Checkpoint.customMarker.turnGuide.maxSegments', 8)
            local segments = math.tointeger(tonumber(guide.segments) or 1) or 1
            segments = math.max(1, math.min(maxSegments, segments))
            
            if isValid and savedGuides < maxTurnGuides then
                queries[#queries + 1] = {
                    query = 'INSERT INTO qbx_race_turn_guides (race_id, checkpoint_order, x, y, z, direction, segments) VALUES (?, ?, ?, ?, ?, ?, ?)',
                    values = {raceId, order, x, y, z, guide.direction, segments}
                }
                savedGuides = savedGuides + 1
            end
            
            ::continue::
        end
        
        if not MySQL.transaction.await(queries) then
            MySQL.query.await('DELETE FROM qbx_races WHERE id = ?', {raceId})
            TriggerClientEvent('ox_lib:notify', src, {
                title = 'エラー',
                description = 'チェックポイントの保存に失敗しました',
                type = 'error'
            })
            return
        end
        
        TriggerClientEvent('ox_lib:notify', src, {
            title = '成功',
            description = 'レース「' .. name .. '」を作成しました',
            type = 'success'
        })
        TriggerClientEvent('qbx_racing:client:refreshRaces', -1)
    else
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'エラー',
            description = 'レースの作成に失敗しました',
            type = 'error'
        })
    end
end)

-- ===================================
-- マルチプレイヤーセッション管理
-- ===================================

-- ===================================
-- セッション作成（スポンサー機能対応）
-- ===================================
-- 他のセッションに参加中（ロビー〜レース中）かどうか
function FindPlayerActiveSession(src)
    for sessionId, session in pairs(ActiveSessions) do
        if session.status == 'lobby' or session.status == 'countdown' or session.status == 'racing' then
            for _, participant in ipairs(session.participants) do
                if participant.source == src and not participant.disconnected
                    and participant.status ~= 'excluded' and participant.status ~= 'retired'
                    and participant.status ~= 'finished' then
                    return sessionId
                end
            end
        end
    end
    return nil
end

-- 切断していない参加者を source で探す
local function FindParticipant(session, src)
    for index, participant in ipairs(session.participants) do
        if participant.source == src and not participant.disconnected then
            return participant, index
        end
    end
    return nil
end

-- 通知などを送れる source（切断済みなら nil）
local function OnlineSource(participant)
    return not participant.disconnected and participant.source or nil
end

-- 主催者の source（切断済みなら nil）
local function HostSource(session)
    for _, participant in ipairs(session.participants) do
        if participant.isHost then return OnlineSource(participant) end
    end
    return session.host
end

-- citizenid → source（オンラインの参加者と主催者）
local function SessionSources(session)
    local sources = {}
    if session.hostCitizenid then
        sources[session.hostCitizenid] = HostSource(session)
    end
    for _, participant in ipairs(session.participants) do
        sources[participant.citizenid] = OnlineSource(participant)
    end
    return sources
end

local function CreateMultiSession(source, data)
    local Player = GetPlayer(source)
    if not Player then 
        return {success = false, message = 'プレイヤーデータが見つかりません'} 
    end
    
    if FindPlayerActiveSession(source) then
        return {success = false, message = '既に別のセッションに参加しています'}
    end
    
    local profile = GetDriverProfile(Player.PlayerData.citizenid)
    if not profile then 
        return {success = false, message = 'ドライバープロフィールが必要です'} 
    end
    
    -- レース情報取得
    local raceId = ToInteger(data.raceId)
    local race = raceId and MySQL.single.await('SELECT * FROM qbx_races WHERE id = ? AND is_active = 1', {raceId})
    if not race then 
        return {success = false, message = 'レースが見つかりません'} 
    end
    
    race.checkpoints = MySQL.query.await([[
        SELECT x, y, z, radius FROM qbx_race_checkpoints 
        WHERE race_id = ? ORDER BY checkpoint_order ASC
    ]], {raceId}) or {}
    race.turnGuides = GetRaceTurnGuides(raceId)
    if #race.checkpoints == 0 then
        return {success = false, message = 'このレースにはチェックポイントがありません'}
    end
    
    -- カウントダウン時間は設定の範囲内に収める
    local countdownDuration = ToInteger(data.countdownDuration) or GetConfigValue('Multiplayer.defaultCountdown', 10)
    countdownDuration = math.max(GetConfigValue('Multiplayer.minCountdown', 5),
        math.min(GetConfigValue('Multiplayer.maxCountdown', 30), countdownDuration))
    
    -- 掛け金・スポンサー設定
    local isBetMode = data.betMode == true
    local entryFee = 0
    local sponsorAmount = 0
    
    if isBetMode then
        -- 掛けレース作成権限チェック
        if not HasBetRacePermission(source) then
            return {success = false, message = '掛けレースを作成する権限がありません（cityhall または raceorganizer が必要です）'}
        end
        
        if not GetConfigValue('Race.betting.enabled', true) then
            return {success = false, message = '掛けレース機能は無効になっています'}
        end
        
        -- 参加費（整数・設定の範囲内）
        local minFee = GetConfigValue('Race.betting.entryFee.min', 0)
        local maxFee = GetConfigValue('Race.betting.entryFee.max', 100000)
        entryFee = ToInteger(data.entryFee)
        if not entryFee or entryFee < minFee or entryFee > maxFee then
            return {success = false, message = string.format('参加費は$%s～$%sの整数で設定してください',
                FormatMoney(minFee), FormatMoney(maxFee))}
        end
        
        -- スポンサー金設定
        if GetConfigValue('Race.betting.sponsor.enabled', true) and 
           GetConfigValue('Race.betting.sponsor.host.enabled', true) then
            sponsorAmount = ToInteger(data.sponsorAmount or 0)
            
            -- スポンサー金額の検証
            local minSponsor = GetConfigValue('Race.betting.sponsor.host.min', 0)
            local maxSponsor = GetConfigValue('Race.betting.sponsor.host.max', 5000000)
            
            if not sponsorAmount or sponsorAmount < minSponsor or sponsorAmount > maxSponsor then
                return {success = false, message = string.format('スポンサー金は$%s～$%sの整数で設定してください', 
                    FormatMoney(minSponsor), FormatMoney(maxSponsor))}
            end
            
            -- 高額スポンサーの追加チェック
            if sponsorAmount >= GetConfigValue('Race.betting.sponsor.display.highlightBig', 100000) then
                -- 1日の制限チェック（オプション）
                local todaySponsored = MySQL.scalar.await([[
                    SELECT COALESCE(SUM(amount), 0) FROM qbx_race_sponsors 
                    WHERE sponsor_citizenid = ? AND DATE(created_at) = CURDATE()
                ]], {Player.PlayerData.citizenid}) or 0
                
                local dailyLimit = GetConfigValue('Race.betting.sponsor.security.maxPerDay', 10000000)
                if todaySponsored + sponsorAmount > dailyLimit then
                    return {success = false, message = string.format('1日のスポンサー上限を超過します（上限: $%s）', FormatMoney(dailyLimit))}
                end
            end
        end
        
        -- 主催者の資金チェック（参加費 + スポンサー金。主催者も参加費を払う）
        local totalRequired = entryFee + sponsorAmount
        if totalRequired > 0 then
            local currency = GetConfigValue('Race.currency', 'cash')
            local balance = Player.Functions.GetMoney(currency)
            if balance < totalRequired then
                return {success = false, message = string.format('資金が不足しています\n必要: $%s\n所持: $%s\n不足: $%s', 
                    FormatMoney(totalRequired), FormatMoney(balance), FormatMoney(totalRequired - balance))}
            end
        end
    end
    
    -- セッション作成
    local sessionId = MySQL.insert.await([[
        INSERT INTO qbx_race_sessions 
        (race_id, host_citizenid, host_driver_name, session_name, countdown_duration, status, 
         is_bet_mode, entry_fee, prize_pool, sponsor_amount, sponsor_citizenid, sponsor_name) 
        VALUES (?, ?, ?, ?, ?, 'lobby', ?, ?, ?, ?, ?, ?)
    ]], {
        raceId, 
        Player.PlayerData.citizenid, 
        profile.driver_name, 
        TruncateText(data.sessionName, 100) or (race.name .. ' - セッション'),
        countdownDuration,
        isBetMode and 1 or 0,
        entryFee,
        sponsorAmount,  -- 初期賞金プール = スポンサー金
        sponsorAmount,
        sponsorAmount > 0 and Player.PlayerData.citizenid or nil,
        sponsorAmount > 0 and profile.driver_name or nil
    })
    if not sessionId then
        return {success = false, message = 'セッション作成に失敗しました'}
    end
    
    -- スポンサー金の徴収
    if sponsorAmount > 0 then
        local currency = GetConfigValue('Race.currency', 'cash')
        if not Player.Functions.RemoveMoney(currency, sponsorAmount, 'race-sponsor') then
            -- 支払い失敗時はセッション削除
            MySQL.query.await('DELETE FROM qbx_race_sessions WHERE id = ?', {sessionId})
            return {success = false, message = 'スポンサー金の支払いに失敗しました'}
        end
        
        -- スポンサー履歴に記録（起動時の返金はこの記録がある分だけ返す = 実際に払った分だけ）
        local recorded = MySQL.insert.await([[
            INSERT INTO qbx_race_sponsors (session_id, sponsor_citizenid, sponsor_driver_name, amount, sponsor_type) 
            VALUES (?, ?, ?, ?, 'host')
        ]], {sessionId, Player.PlayerData.citizenid, profile.driver_name, sponsorAmount})
        if not recorded then
            GiveMoney(source, Player.PlayerData.citizenid, sponsorAmount, 'race-sponsor-refund')
            MySQL.query.await('DELETE FROM qbx_race_sessions WHERE id = ?', {sessionId})
            return {success = false, message = 'セッション作成に失敗しました（スポンサー金は返金しました）'}
        end
        
        print(string.format('[CAM Racing] スポンサー記録: %s が $%s をセッション %d に提供', 
            profile.driver_name, FormatMoney(sponsorAmount), sessionId))
    end
    
    -- アクティブセッション登録
    ActiveSessions[sessionId] = {
        id = sessionId,
        raceId = raceId,
        race = race,
        host = source,
        hostCitizenid = Player.PlayerData.citizenid,
        hostName = profile.driver_name,
        participants = {},
        status = 'lobby',
        countdownDuration = countdownDuration,
        startPoint = race.checkpoints[1],
        createdAt = os.time(),
        
        -- 掛け金・スポンサー情報
        isBetMode = isBetMode,
        entryFee = entryFee,
        prizePool = sponsorAmount,  -- 初期プール = スポンサー金のみ
        sponsorAmount = sponsorAmount,
        sponsorName = sponsorAmount > 0 and profile.driver_name or nil,
        houseCut = 0
    }
    
    -- 主催者を自動参加（主催者も参加費を払う）
    local ok, err = RegisterSessionParticipant(sessionId, source, {isHost = true, vehicleModel = data.vehicleModel})
    if not ok then
        CancelSessionWithRefund(sessionId, nil)
        return {success = false, message = err or 'セッション作成に失敗しました'}
    end
    
    return {
        success = true, 
        sessionId = sessionId,
        participants = GetSessionParticipantList(sessionId),  -- 主催者のロビーに自分を表示する
        race = race,
        isBetMode = isBetMode,
        entryFee = entryFee,
        sponsorAmount = sponsorAmount,
        initialPrizePool = ActiveSessions[sessionId] and ActiveSessions[sessionId].prizePool or sponsorAmount,
        totalCost = entryFee + sponsorAmount
    }
end

lib.callback.register('qbx_racing:server:createMultiSession', function(source, data)
    return RunExclusive(source, function()
        return CreateMultiSession(source, type(data) == 'table' and data or {})
    end)
end)

-- セッション参加
lib.callback.register('qbx_racing:server:joinSession', function(source, sessionId, vehicleModel)
    return RunExclusive(source, function()
        local session = ActiveSessions[sessionId]
        if not session then 
            return {success = false, message = 'セッションが見つかりません'} 
        end
        
        if session.status ~= 'lobby' then
            return {success = false, message = 'このセッションは既に開始されています'}
        end
        
        if FindPlayerActiveSession(source) then
            return {success = false, message = '既に別のセッションに参加しています'}
        end
        
        local maxParticipants = GetConfigValue('Multiplayer.maxParticipants', 16)
        if #session.participants >= maxParticipants then
            return {success = false, message = '参加人数が上限に達しています'}
        end
        
        local ok, err = RegisterSessionParticipant(sessionId, source, {vehicleModel = vehicleModel})
        if not ok then
            return {success = false, message = err or '参加処理に失敗しました'}
        end
        
        BroadcastSessionUpdate(sessionId)
        return {
            success = true,
            participants = GetSessionParticipantList(sessionId),
            entryFee = session.isBetMode and session.entryFee or 0,
            prizePool = session.prizePool
        }
    end)
end)

-- アクティブセッション一覧
lib.callback.register('qbx_racing:server:getActiveSessions', function(source)
    local sessions = {}
    
    for sessionId, session in pairs(ActiveSessions) do
        if session.status == 'lobby' then
            table.insert(sessions, {
                sessionId = sessionId,
                raceName = session.race.name,
                raceType = session.race.race_type,
                vehicleType = session.race.vehicle_type,
                hostName = session.hostName,
                participantCount = #session.participants,
                maxParticipants = Config.Multiplayer and Config.Multiplayer.maxParticipants or 16,
                -- 掛け金・スポンサー情報
                isBetMode = session.isBetMode or false,
                entryFee = session.entryFee or 0,
                prizePool = session.prizePool or 0,
                sponsorAmount = session.sponsorAmount or 0,
                sponsorName = session.sponsorName or nil
            })
        end
    end
    
    return sessions
end)

-- ===================================
-- 参加者登録（修正版 - 参加費徴収）
-- ===================================
function RegisterSessionParticipant(sessionId, source, options)
    options = options or {}
    local Player = GetPlayer(source)
    if not Player then return false, 'プレイヤーデータが見つかりません' end
    local citizenid = Player.PlayerData.citizenid
    
    local profile = GetDriverProfile(citizenid)
    if not profile then return false, 'ドライバープロフィールが必要です' end
    
    local session = ActiveSessions[sessionId]
    if not session or session.status ~= 'lobby' then return false, 'このセッションには参加できません' end
    
    for _, participant in ipairs(session.participants) do
        if participant.citizenid == citizenid then
            return false, '既にこのセッションに参加しています'
        end
    end
    
    -- 掛け金モードの場合は参加費が必要（主催者も同じ）
    local fee = session.isBetMode and session.entryFee or 0
    local currency = GetConfigValue('Race.currency', 'cash')
    if fee > 0 and Player.Functions.GetMoney(currency) < fee then
        return false, string.format('参加費$%sが不足しています（所持金: $%s）',
            FormatMoney(fee), FormatMoney(Player.Functions.GetMoney(currency)))
    end
    
    -- 車両名はクライアントから受け取る（車両名を返すネイティブはサーバーにないため）
    local vehicleModel = TruncateText(options.vehicleModel, 50) or ''
    if vehicleModel == '' then vehicleModel = 'なし' end
    
    -- 先に DB に登録し、成功してから参加費を徴収する（失敗時にお金だけ取られないように）
    MySQL.query.await('DELETE FROM qbx_session_participants WHERE session_id = ? AND citizenid = ?', {sessionId, citizenid})
    local participantId = MySQL.insert.await([[
        INSERT INTO qbx_session_participants 
        (session_id, citizenid, driver_name, vehicle_model, status, entry_paid) 
        VALUES (?, ?, ?, ?, 'entered', 0)
    ]], {sessionId, citizenid, profile.driver_name, vehicleModel})
    if not participantId then return false, '参加処理に失敗しました' end
    
    -- DB を待っている間に開始・満員・重複になっていないか確認
    local maxParticipants = GetConfigValue('Multiplayer.maxParticipants', 16)
    local canJoin = ActiveSessions[sessionId] == session and session.status == 'lobby'
        and #session.participants < maxParticipants
    for _, participant in ipairs(session.participants) do
        if participant.citizenid == citizenid then canJoin = false end
    end
    
    local entryPaid = false
    if canJoin and fee > 0 then
        entryPaid = Player.Functions.RemoveMoney(currency, fee, 'race-entry-fee') and true or false
        canJoin = entryPaid
    end
    
    if not canJoin then
        MySQL.query('DELETE FROM qbx_session_participants WHERE id = ?', {participantId})
        return false, '参加できませんでした（開始済み・満員・所持金不足など）'
    end
    
    table.insert(session.participants, {
        id = participantId,
        source = source,
        citizenid = citizenid,
        driverName = profile.driver_name,
        vehicleModel = vehicleModel,
        status = 'entered',
        isHost = options.isHost or false,
        entryPaid = entryPaid,
        currentCheckpoint = 1,
        currentLap = 1
    })
    
    if entryPaid then
        session.prizePool = session.prizePool + fee

        -- 「支払い済み」を DB に確実に残す（落ちた時の起動時返金はこの記録を見るため）
        -- 残せなかった場合は参加を取り消して返金する
        local saved = MySQL.update.await('UPDATE qbx_session_participants SET entry_paid = 1 WHERE id = ?', {participantId})
        if not saved or saved < 1 then
            for i = #session.participants, 1, -1 do
                if session.participants[i].id == participantId then
                    table.remove(session.participants, i)
                end
            end
            session.prizePool = math.max(0, session.prizePool - fee)
            MySQL.query('DELETE FROM qbx_session_participants WHERE id = ?', {participantId})
            GiveMoney(source, citizenid, fee, 'race-entry-refund')
            return false, '参加処理に失敗しました（参加費は返金しました）'
        end
        MySQL.update('UPDATE qbx_race_sessions SET prize_pool = ? WHERE id = ?', {session.prizePool, sessionId})
    end

    return true
end

-- ロビーから参加者を外す（参加費を返し、DB の行も消す）
-- 戻り値: 外せたら true / 既に退出処理中なら 'busy' / DB に保存できなかったら false（メモリ上もそのまま残す）
function RemoveLobbyParticipant(sessionId, index)
    local session = ActiveSessions[sessionId]
    local participant = session and session.participants[index]
    if not participant then return false end
    -- 退出処理中に同じ人の退出（連打・切断）が来ても二重に返金しない
    if participant.removing then return 'busy' end
    participant.removing = true

    -- DB を待っている間に中止処理などが同じ参加費を返金しないよう、先にメモリ上で「返金対象」を確保する
    -- （保存に失敗したら元に戻す）
    local refund = participant.entryPaid and session.entryFee > 0
    if refund then
        participant.entryPaid = false
        session.prizePool = math.max(0, session.prizePool - session.entryFee)
    end

    -- 行の削除と返金予定の記録を一緒に保存する
    local recorded = RecordPayouts(sessionId,
        refund and {{citizenid = participant.citizenid, amount = session.entryFee, reason = 'race-entry-refund'}} or {},
        {
            {query = 'DELETE FROM qbx_session_participants WHERE session_id = ? AND citizenid = ?', values = {sessionId, participant.citizenid}},
            {query = 'UPDATE qbx_race_sessions SET prize_pool = prize_pool - ? WHERE id = ?', values = {refund and session.entryFee or 0, sessionId}}
        })
    if not recorded then
        print(('^1[CAM Racing]^7 セッション %d: %s の退出を保存できませんでした'):format(sessionId, participant.driverName))
        participant.removing = nil

        -- 待っている間にセッションが中止・終了していた場合、中止処理はこの人を返金対象から外しているので、
        -- この人の返金だけをもう一度記録する（記録できればそのまま精算）
        if refund and ActiveSessions[sessionId] ~= session then
            if RecordPayouts(sessionId,
                {{citizenid = participant.citizenid, amount = session.entryFee, reason = 'race-entry-refund'}},
                {{query = 'UPDATE qbx_session_participants SET entry_paid = 0 WHERE session_id = ? AND citizenid = ?',
                  values = {sessionId, participant.citizenid}}}) then
                SettlePayouts(sessionId, {[participant.citizenid] = OnlineSource(participant)})
            else
                print(('^1[CAM Racing]^7 セッション %d: %s の参加費の返金を記録できませんでした（要手動対応）'):format(
                    sessionId, participant.driverName))
            end
            return true
        end

        if refund then
            participant.entryPaid = true
            session.prizePool = session.prizePool + session.entryFee
        end
        return false
    end

    -- DB を待っている間に並びが変わっていることがあるので、本人を探して外す
    for i = #session.participants, 1, -1 do
        if session.participants[i] == participant then
            table.remove(session.participants, i)
        end
    end

    if refund then
        local src = OnlineSource(participant)
        SettlePayouts(sessionId, {[participant.citizenid] = src})
        if src then
            TriggerClientEvent('ox_lib:notify', src, {
                title = '返金',
                description = string.format('参加費$%sを返金しました', FormatMoney(session.entryFee)),
                type = 'success'
            })
        end
    end

    return true
end

-- セッション更新ブロードキャスト
function BroadcastSessionUpdate(sessionId)
    local session = ActiveSessions[sessionId]
    if not session then return end
    
    local updateData = {
        sessionId = sessionId,
        participants = GetSessionParticipantList(sessionId),
        participantCount = #session.participants,
        status = session.status
    }
    
    for _, participant in ipairs(session.participants) do
        if not participant.disconnected then
            TriggerClientEvent('qbx_racing:client:sessionUpdate', participant.source, updateData)
        end
    end
end

-- 参加者リスト取得
function GetSessionParticipantList(sessionId)
    local session = ActiveSessions[sessionId]
    if not session then return {} end
    
    local list = {}
    for _, participant in ipairs(session.participants) do
        table.insert(list, {
            driverName = participant.driverName,
            vehicleModel = participant.vehicleModel,
            status = participant.status,
            isHost = participant.isHost
        })
    end
    return list
end

-- カウントダウン開始
-- 参加者の車両クラスを各クライアントに問い合わせる（車両クラスはサーバーでは取得できないため）
-- 返事は最大 timeoutMs 待つ。戻り値: source → {class = ..., netId = ...}
local function RequestVehicleInfo(sources, timeoutMs)
    local results, pending = {}, #sources
    for _, src in ipairs(sources) do
        lib.callback('qbx_racing:client:getVehicleInfo', src, function(info)
            results[src] = type(info) == 'table' and info or false
            pending = pending - 1
        end)
    end
    local deadline = GetGameTimer() + timeoutMs
    while pending > 0 and GetGameTimer() < deadline do
        Wait(100)
    end
    return results
end

RegisterNetEvent('qbx_racing:server:startCountdown', function(sessionId)
    local src = source
    local session = ActiveSessions[sessionId]
    
    if not session or session.host ~= src or session.status ~= 'lobby' then
        return
    end
    
    local minParticipants = GetConfigValue('Multiplayer.minParticipants', 2)
    if #session.participants < minParticipants then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'エラー',
            description = string.format('最低%d人の参加者が必要です', minParticipants),
            type = 'error'
        })
        return
    end
    
    -- 確認中に開始ボタンを連打されても二重に始めない
    if session.checkingStart then return end
    session.checkingStart = true
    
    -- 有効な参加者をチェック（対象クラスの車両に乗ってスタート地点付近にいる人）
    local startRadius = GetConfigValue('Multiplayer.countdownRestrictions.startAreaRadius', 30.0)
    local startCoords = session.startPoint and vector3(session.startPoint.x, session.startPoint.y, session.startPoint.z)
    local vehicleConfig = Config.VehicleTypes and Config.VehicleTypes[session.race.vehicle_type]
    local allowedClasses = {}
    for _, class in ipairs(vehicleConfig and vehicleConfig.allowedClasses or {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}) do
        allowedClasses[class] = true
    end
    
    local onlineSources = {}
    for _, participant in ipairs(session.participants) do
        if not participant.disconnected then
            table.insert(onlineSources, participant.source)
        end
    end
    local vehicleInfo = RequestVehicleInfo(onlineSources, 3000)
    session.checkingStart = nil
    
    -- 問い合わせ中にセッションが変わっていたらやめる
    if ActiveSessions[sessionId] ~= session or session.status ~= 'lobby' then return end
    
    local validParticipants = {}
    for _, participant in ipairs(session.participants) do
        local info = vehicleInfo[participant.source]
        if not participant.disconnected and info then
            -- クライアントが答えた車両が、サーバーから見て実際に乗っている車両か確認する
            local vehicle = GetVehiclePedIsIn(GetPlayerPed(participant.source), false)
            local reported = ToInteger(info.netId) and NetworkGetEntityFromNetworkId(ToInteger(info.netId)) or 0
            if vehicle ~= 0 and reported == vehicle and allowedClasses[ToInteger(info.class)]
                and (not startCoords or #(GetEntityCoords(vehicle) - startCoords) <= startRadius) then
                table.insert(validParticipants, participant.source)
            end
        end
    end
    
    if #validParticipants < minParticipants then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'エラー',
            description = string.format('レースに出られる参加者が%d人です（最低%d人）。全員が対象の車両に乗ってスタート地点（半径%dm以内）に集まっているか確認してください',
                #validParticipants, minParticipants, math.floor(startRadius)),
            type = 'error'
        })
        return
    end
    
    session.status = 'countdown'
    MySQL.update('UPDATE qbx_race_sessions SET status = ? WHERE id = ?', {'countdown', sessionId})
    
    -- カウントダウンスレッド
    CreateThread(function()
        local countdown = session.countdownDuration
        
        -- 全参加者にカウントダウン開始通知
        for _, participantSource in ipairs(validParticipants) do
            TriggerClientEvent('qbx_racing:client:countdownStarted', participantSource, {
                sessionId = sessionId,
                duration = countdown,
                startPoint = session.startPoint
            })
        end
        
        -- カウントダウンループ
        while countdown > 0 and ActiveSessions[sessionId] == session and session.status == 'countdown' do
            for _, participantSource in ipairs(validParticipants) do
                TriggerClientEvent('qbx_racing:client:countdownTick', participantSource, {
                    sessionId = sessionId,
                    countdown = countdown
                })
            end
            
            Wait(1000)
            countdown = countdown - 1
        end
        
        -- レース開始
        if ActiveSessions[sessionId] == session and session.status == 'countdown' then
            StartMultiplayerRace(sessionId, validParticipants)
        end
    end)
end)

-- 参加者のステータスを変更（メモリと DB の両方）
function SetParticipantStatus(sessionId, participant, status)
    participant.status = status
    MySQL.update('UPDATE qbx_session_participants SET status = ? WHERE session_id = ? AND citizenid = ?',
        {status, sessionId, participant.citizenid})
end

-- セッション中止（参加費・スポンサー金を返金）
-- reason が nil のときは通知しない（作成失敗時など）
function CancelSessionWithRefund(sessionId, reason)
    local session = ActiveSessions[sessionId]
    if not session then return end
    
    ActiveSessions[sessionId] = nil
    session.status = 'cancelled'
    
    -- 返金予定と「中止」を一緒に記録してから返金する
    -- （記録できなかった場合は DB 上はまだ進行中なので、次回起動時の返金処理に任せる）
    local payouts = {}
    for _, participant in ipairs(session.participants) do
        if participant.entryPaid and session.entryFee > 0 then
            participant.entryPaid = false
            payouts[#payouts + 1] = {citizenid = participant.citizenid, amount = session.entryFee, reason = 'race-entry-refund'}
        end
    end
    if session.sponsorAmount and session.sponsorAmount > 0 then
        payouts[#payouts + 1] = {citizenid = session.hostCitizenid, amount = session.sponsorAmount, reason = 'race-sponsor-refund'}
    end
    
    local recorded = RecordPayouts(sessionId, payouts, {
        {query = 'UPDATE qbx_race_sessions SET status = ? WHERE id = ?', values = {'cancelled', sessionId}}
    })
    if recorded then
        SettlePayouts(sessionId, SessionSources(session))
    else
        print(('^1[CAM Racing]^7 セッション %d の中止を保存できなかったため、返金は次回起動時に行います'):format(sessionId))
    end
    
    local hasRefund = recorded and session.isBetMode and session.entryFee > 0
    for _, participant in ipairs(session.participants) do
        local src = OnlineSource(participant)
        if src and reason then
            TriggerClientEvent('qbx_racing:client:sessionCancelled', src, {
                sessionId = sessionId,
                reason = reason .. (hasRefund and '（参加費は返金済み）' or '')
            })
        end
    end
    
    if recorded and session.sponsorAmount and session.sponsorAmount > 0 then
        local hostSrc = HostSource(session)
        if hostSrc and reason then
            TriggerClientEvent('ox_lib:notify', hostSrc, {
                title = '返金',
                description = string.format('スポンサー金$%sを返金しました', FormatMoney(session.sponsorAmount)),
                type = 'success'
            })
        end
    end
end

-- マルチプレイヤーレース開始
function StartMultiplayerRace(sessionId, validParticipants)
    local session = ActiveSessions[sessionId]
    if not session then return end
    
    -- 参加者ステータス更新（車両に乗っていなかった人などはレースに出られない）
    local isValid = {}
    for _, participantSource in ipairs(validParticipants) do
        isValid[participantSource] = true
    end
    local function canRace(participant)
        return not participant.disconnected and participant.status ~= 'retired' and isValid[participant.source]
    end
    
    -- カウントダウン中の退出・切断で最低人数を下回った場合は中止
    local racerCount = 0
    for _, participant in ipairs(session.participants) do
        if canRace(participant) then
            racerCount = racerCount + 1
        end
    end
    local minParticipants = GetConfigValue('Multiplayer.minParticipants', 2)
    if racerCount < minParticipants then
        CancelSessionWithRefund(sessionId, string.format('カウントダウン中に参加者が抜けて%d人未満になったため、レースを中止しました', minParticipants))
        return
    end
    
    session.status = 'racing'
    session.startTime = os.time()
    session.startTimer = GetGameTimer()
    session.finishCount = 0
    session.checkpointCount = #(session.race.checkpoints or {})
    session.totalLaps = session.race.race_type == 'sprint' and 1 or math.max(1, ToInteger(session.race.laps) or 1)
    -- 1周の最後の番号（周回は n+1 = スタート地点に戻る。最終周はそこがゴール）
    session.lapEndIndex = session.race.race_type == 'sprint' and session.checkpointCount or session.checkpointCount + 1
    session.minFinishMs = CalculateMinRaceTimeMs(session.race)
    
    MySQL.update('UPDATE qbx_race_sessions SET status = ?, start_time = NOW() WHERE id = ?', {'racing', sessionId})
    
    local racers = {}
    local poolChanged = false
    for _, participant in ipairs(session.participants) do
        if canRace(participant) then
            participant.currentCheckpoint = 1
            participant.currentLap = 1
            table.insert(racers, participant.source)
            SetParticipantStatus(sessionId, participant, 'racing')
        elseif participant.status ~= 'retired' then
            -- 走らない人が 'racing' のまま残るとレースが終わらないため、対象外にする（参加費は返す）
            SetParticipantStatus(sessionId, participant, 'excluded')
            local refunded = false
            if participant.entryPaid and session.entryFee > 0 then
                -- DB を待つ間に他の処理が同じ参加費を返金しないよう、先にメモリ上で確保してから
                -- 「支払い済み」の取り消しと返金予定を一緒に保存する
                -- （保存できなかった場合は元に戻し、レース終了時の精算で返金する）
                participant.entryPaid = false
                session.prizePool = math.max(0, session.prizePool - session.entryFee)
                refunded = RecordPayouts(sessionId,
                    {{citizenid = participant.citizenid, amount = session.entryFee, reason = 'race-entry-refund'}},
                    {{query = 'UPDATE qbx_session_participants SET entry_paid = 0 WHERE session_id = ? AND citizenid = ?',
                      values = {sessionId, participant.citizenid}}})
                if refunded then
                    poolChanged = true
                    SettlePayouts(sessionId, {[participant.citizenid] = OnlineSource(participant)})
                else
                    participant.entryPaid = true
                    session.prizePool = session.prizePool + session.entryFee
                end
            end
            
            local src = OnlineSource(participant)
            if src then
                TriggerClientEvent('qbx_racing:client:sessionCancelled', src, {
                    sessionId = sessionId,
                    reason = 'スタート時に対象の車両でスタート地点付近にいなかったため、レースに参加できませんでした'
                        .. (refunded and '（参加費は返金済み）' or '')
                })
            end
        end
    end
    if poolChanged then
        MySQL.update('UPDATE qbx_race_sessions SET prize_pool = ? WHERE id = ?', {session.prizePool, sessionId})
    end
    
    -- 全参加者にレース開始通知
    for _, participantSource in ipairs(racers) do
        TriggerClientEvent('qbx_racing:client:multiRaceStart', participantSource, {
            sessionId = sessionId,
            race = session.race,
            participants = racers,
            isMultiplayer = true
        })
    end
    
    -- 進捗同期スレッド開始
    StartProgressSyncThread(sessionId)
    
    -- カウントダウン中に全員抜けていた場合など
    CheckSessionComplete(sessionId)
end

-- 進捗同期スレッド
function StartProgressSyncThread(sessionId)
    CreateThread(function()
        local session = ActiveSessions[sessionId]
        if not session then return end
        
        local syncInterval = GetConfigValue('Multiplayer.progressSyncInterval', 500)
        local maxDuration = GetConfigValue('Multiplayer.maxRaceDuration', 1800) * 1000
        local finishTimeout = GetConfigValue('Multiplayer.finishTimeout', 180) * 1000
        
        while session.status == 'racing' and ActiveSessions[sessionId] == session do
            -- 制限時間（レース全体・1位ゴール後）を過ぎたら、まだ走っている人はリタイア扱い
            local now = GetGameTimer()
            if now - session.startTimer > maxDuration
                or (session.firstFinishAt and now - session.firstFinishAt > finishTimeout) then
                for _, participant in ipairs(session.participants) do
                    if participant.status == 'racing' then
                        SetParticipantStatus(sessionId, participant, 'retired')
                        local src = OnlineSource(participant)
                        if src then
                            TriggerClientEvent('qbx_racing:client:raceTimeUp', src, {sessionId = sessionId})
                        end
                    end
                end
                CheckSessionComplete(sessionId)
                break
            end
            
            local progressData = {}
            for _, participant in ipairs(session.participants) do
                if participant.status == 'racing' then
                    progressData[participant.source] = {
                        driverName = participant.driverName,
                        checkpoint = participant.currentCheckpoint,
                        lap = participant.currentLap,
                        status = participant.status
                    }
                end
            end
            
            for _, participant in ipairs(session.participants) do
                local src = OnlineSource(participant)
                if src and participant.status == 'racing' then
                    TriggerClientEvent('qbx_racing:client:progressUpdate', src, {
                        sessionId = sessionId,
                        progressData = progressData,
                        finishedCount = session.finishCount or 0
                    })
                end
            end
            
            Wait(syncInterval)
        end
    end)
end

-- 進捗更新受信
RegisterNetEvent('qbx_racing:server:updateProgress', function(sessionId, checkpoint, lap)
    local src = source
    local session = ActiveSessions[sessionId]
    if not session or session.status ~= 'racing' then return end
    
    local participant = FindParticipant(session, src)
    checkpoint, lap = ToInteger(checkpoint), ToInteger(lap)
    if not participant or participant.status ~= 'racing' or not checkpoint or not lap then return end
    
    -- チェックポイントは1つずつ順番にしか進めない（飛ばした報告は受け付けない）
    -- 周回は CPn の次に n+1（スタート地点に戻る）、そこを通ると次の周の CP2
    local passedIndex, nextCheckpoint, nextLap
    if participant.currentCheckpoint < session.lapEndIndex then
        passedIndex, nextCheckpoint, nextLap = participant.currentCheckpoint, participant.currentCheckpoint + 1, participant.currentLap
    else
        passedIndex, nextCheckpoint, nextLap = session.lapEndIndex, 2, participant.currentLap + 1
    end
    if checkpoint ~= nextCheckpoint or lap ~= nextLap or lap > session.totalLaps then return end
    
    -- 通過したチェックポイントの近くにいること（サーバーで見た位置で確認）
    if not IsPlayerNearCheckpoint(src, CourseCheckpointAt(session.race.checkpoints or {}, passedIndex)) then
        print(('^3[CAM Racing]^7 チェックポイント通過を受け付けませんでした（位置が離れています）: %s session=%d CP=%d'):format(
            participant.driverName, sessionId, passedIndex))
        return
    end
    participant.currentCheckpoint = checkpoint
    participant.currentLap = lap
end)

-- ===================================
-- レース完了（スポンサー対応賞金分配）
-- ===================================
RegisterNetEvent('qbx_racing:server:finishMultiRace', function(sessionId, timeMs, vehicleModel)
    local src = source
    local session = ActiveSessions[sessionId]
    if not session or session.status ~= 'racing' then return end
    
    -- 走行中の参加者からのゴールだけ受け付ける（二重のゴールや不参加者による賞金の受け取りを防ぐ）
    local finisher = FindParticipant(session, src)
    if not finisher or finisher.status ~= 'racing' then return end
    
    -- 最終周のゴール直前まで順番に通過したか（サーバーが受け取った進捗で確認。ゴールの通過はこの報告自体）
    if finisher.currentLap ~= session.totalLaps or finisher.currentCheckpoint ~= session.lapEndIndex
        or not IsPlayerNearCheckpoint(src, CourseCheckpointAt(session.race.checkpoints or {}, session.lapEndIndex)) then
        print(('^3[CAM Racing]^7 ゴールを受け付けませんでした（チェックポイント未通過）: %s session=%d'):format(
            finisher.driverName, sessionId))
        return
    end
    
    -- タイムはサーバーの経過時間と大きくずれていればサーバー側の値を使う
    local serverElapsed = GetGameTimer() - session.startTimer
    if serverElapsed < session.minFinishMs then
        print(('^1[CAM Racing]^7 不正なゴールの可能性: %s session=%d 経過=%dms 最短=%dms'):format(
            finisher.driverName, sessionId, serverElapsed, session.minFinishMs))
        SetParticipantStatus(sessionId, finisher, 'retired')
        CheckSessionComplete(sessionId)
        return
    end
    timeMs = ToInteger(timeMs)
    if not timeMs or math.abs(timeMs - serverElapsed) > 5000 then
        timeMs = serverElapsed
    end
    vehicleModel = TruncateText(vehicleModel, 50)
    if not vehicleModel or vehicleModel == '' then
        vehicleModel = finisher.vehicleModel or '不明'
    end
    
    -- 順位はここで待ちなしに確定させる（切断者がいても順位がずれないようにカウンターで管理）
    session.finishCount = (session.finishCount or 0) + 1
    local position = session.finishCount
    finisher.status = 'finished'
    finisher.finishTime = timeMs
    finisher.position = position
    if position == 1 then
        session.firstFinishAt = GetGameTimer()
    end
    
    -- 結果・記録・統計はまとめて保存し、保存が終わってからレース終了の判定（賞金の確定）に進む
    local finishQueries = {
        {
            query = "UPDATE qbx_session_participants SET status = 'finished', finish_time_ms = ?, final_position = ? WHERE session_id = ? AND citizenid = ?",
            values = {timeMs, position, sessionId, finisher.citizenid}
        },
        {
            query = 'INSERT INTO qbx_race_times (race_id, driver_name, citizenid, time_ms, server_time_ms, vehicle_model) VALUES (?, ?, ?, ?, ?, ?)',
            values = {session.raceId, finisher.driverName, finisher.citizenid, timeMs, serverElapsed, vehicleModel}
        }
    }
    if GetConfigValue('Race.updateStats', true) then
        finishQueries[#finishQueries + 1] = {
            query = 'UPDATE qbx_driver_profiles SET total_races = total_races + 1, total_wins = total_wins + ? WHERE citizenid = ?',
            values = {position == 1 and 1 or 0, finisher.citizenid}
        }
    end
    local finishSaved = MySQL.transaction.await(finishQueries)
    if finishSaved and Progression then
        -- タイムアタックの目標タイム（最初の数回のゴールの平均）の計算
        local ok, err = pcall(Progression.UpdateTargetTime, session.raceId)
        if not ok then print('^1[CAM Racing]^7 目標タイムの計算に失敗しました: ' .. tostring(err)) end
    end
    if not finishSaved then
        -- 保存できなかった記録は、レース終了時の精算（賞金の記録と同じトランザクション）でもう一度保存する
        -- （そこでも保存できなければ賞金も確定しない）
        print(('^1[CAM Racing]^7 %s のゴール記録を保存できませんでした（session=%d、終了時に再保存します）'):format(
            finisher.driverName, sessionId))
        session.pendingFinishQueries = session.pendingFinishQueries or {}
        for _, query in ipairs(finishQueries) do
            table.insert(session.pendingFinishQueries, query)
        end
    end
    
    -- 完了通知（賞金はレース終了時にまとめて支払う）
    local timeFormatted = string.format("%.2f秒", timeMs / 1000)
    local medals = {'🥇', '🥈', '🥉'}
    local medal = medals[position] or '🏁'
    local rewardMessage = session.isBetMode and session.prizePool > 0
        and '賞金はレース終了時に支払われます' or 'タイム記録のみ'
    
    TriggerClientEvent('ox_lib:notify', src, {
        title = string.format('%s %d位でゴール！', medal, position),
        description = string.format('%s\n%s', timeFormatted, rewardMessage),
        type = position <= 3 and 'success' or 'inform',
        duration = 10000
    })
    
    -- 他の参加者に完了通知
    for _, participant in ipairs(session.participants) do
        local otherSrc = OnlineSource(participant)
        if otherSrc and participant ~= finisher
            and (participant.status == 'racing' or participant.status == 'finished') then
            TriggerClientEvent('qbx_racing:client:participantFinished', otherSrc, {
                sessionId = sessionId,
                finisher = finisher.driverName,
                position = position,
                time = timeMs,
                timeFormatted = timeFormatted
            })
        end
    end
    
    -- 全員完了チェックと最終結果
    CheckSessionComplete(sessionId)
end)

-- 走行中の参加者がいなくなったらレースを終了して最終結果を発表する
-- （ゴール・リタイア・退出・切断のたびに呼ぶ）
function CheckSessionComplete(sessionId)
    local session = ActiveSessions[sessionId]
    if not session or session.status ~= 'racing' then return end
    
    for _, participant in ipairs(session.participants) do
        if participant.status == 'racing' then
            return
        end
    end
    
    session.status = 'finished'
    
    -- 賞金（または全員リタイア時の返金）の予定と「終了」を一緒に記録してから支払う
    -- （記録できなかった場合は DB 上はまだ進行中なので、次回起動時に参加費を返金する）
    local payouts, extraQueries = CalculatePrizes(session)
    table.insert(extraQueries, 1, {query = 'UPDATE qbx_race_sessions SET status = ? WHERE id = ?', values = {'finished', sessionId}})
    -- ゴール時に保存できなかった記録も一緒に保存する（記録なしで賞金だけ確定しないように）
    for _, query in ipairs(session.pendingFinishQueries or {}) do
        table.insert(extraQueries, query)
    end
    -- ランキング: 参加者同士のポイントのやり取りも同じトランザクションで保存する
    -- （結果が保存できなかったレースはポイントも動かない）
    local rankingDeltas = {}
    if Progression then
        local ok, queries, deltas = pcall(Progression.BuildMultiplayerRanking, session)
        if ok then
            for _, query in ipairs(queries or {}) do table.insert(extraQueries, query) end
            rankingDeltas = deltas or {}
        else
            print('^1[CAM Racing]^7 ランキングの計算に失敗しました: ' .. tostring(queries))
        end
    end
    if RecordPayouts(sessionId, payouts, extraQueries) then
        for participant, delta in pairs(rankingDeltas) do
            participant.pointsDelta = delta
        end
        SettlePayouts(sessionId, SessionSources(session))
        PayHouseCut(session)
    else
        session.prizesFailed = true
        print(('^1[CAM Racing]^7 セッション %d の結果を保存できなかったため、賞金を支払いませんでした（次回起動時に参加費を返金します）'):format(sessionId))
    end
    BroadcastFinalResults(sessionId)
    
    SetTimeout(GetConfigValue('Multiplayer.cleanupDelay', 300000), function()
        if ActiveSessions[sessionId] == session then
            ActiveSessions[sessionId] = nil
        end
    end)
end

-- 賞金の支払い（レース終了時にまとめて）
-- 入賞者が配分表より少ない場合（2人レースなど）は、実際の入賞者の割合でプール全額を分ける
-- 賞金の計算（支払いは CheckSessionComplete が台帳経由で行う）
-- 入賞者が配分表より少ない場合（2人レースなど）は、実際の入賞者の割合でプール全額を分ける
-- 戻り値: 支払い予定の一覧, 一緒に実行する DB 更新
function CalculatePrizes(session)
    local payouts, extraQueries = {}, {}
    if not session.isBetMode then return payouts, extraQueries end

    -- スタート時に返金を保存できなかった対象外の人は、ここで返金する（賞金プールからは除く）
    for _, participant in ipairs(session.participants) do
        if participant.status == 'excluded' and participant.entryPaid and session.entryFee > 0 then
            participant.entryPaid = false
            session.prizePool = math.max(0, session.prizePool - session.entryFee)
            payouts[#payouts + 1] = {citizenid = participant.citizenid, amount = session.entryFee, reason = 'race-entry-refund'}
            extraQueries[#extraQueries + 1] = {
                query = 'UPDATE qbx_session_participants SET entry_paid = 0 WHERE session_id = ? AND citizenid = ?',
                values = {session.id, participant.citizenid}
            }
        end
    end
    if session.prizePool <= 0 then return payouts, extraQueries end
    
    local finishers = {}
    for _, participant in ipairs(session.participants) do
        if participant.status == 'finished' then
            table.insert(finishers, participant)
        end
    end
    table.sort(finishers, function(a, b) return (a.position or 999) < (b.position or 999) end)
    
    -- 誰もゴールしなかった場合は参加費とスポンサー金を返す
    if #finishers == 0 then
        for _, participant in ipairs(session.participants) do
            if participant.entryPaid and session.entryFee > 0 then
                participant.entryPaid = false
                payouts[#payouts + 1] = {citizenid = participant.citizenid, amount = session.entryFee, reason = 'race-entry-refund'}
            end
        end
        if session.sponsorAmount > 0 then
            payouts[#payouts + 1] = {citizenid = session.hostCitizenid, amount = session.sponsorAmount, reason = 'race-sponsor-refund'}
        end
        session.refundedAll = true
        return payouts, extraQueries
    end
    
    -- ハウスカット（1レースにつき1回。支払いは PayHouseCut）
    local houseCutConfig = GetConfigValue('Race.betting.houseCut', {enabled = false})
    session.houseCutAmount = 0
    if type(houseCutConfig) == 'table' and houseCutConfig.enabled then
        session.houseCutAmount = math.floor(session.prizePool * (houseCutConfig.percentage or 10) / 100)
    end
    local distributionPool = session.prizePool - session.houseCutAmount
    
    local distribution = GetConfigValue('Race.betting.distribution', {[1] = 50, [2] = 30, [3] = 20})
    local totalShare = 0
    for _, participant in ipairs(finishers) do
        totalShare = totalShare + (distribution[participant.position] or 0)
    end
    if totalShare <= 0 then return payouts, extraQueries end
    
    for _, participant in ipairs(finishers) do
        local share = distribution[participant.position] or 0
        local prize = math.floor(distributionPool * share / totalShare)
        if prize > 0 then
            participant.prize = prize
            payouts[#payouts + 1] = {citizenid = participant.citizenid, amount = prize, reason = 'race-prize'}
            extraQueries[#extraQueries + 1] = {
                query = 'UPDATE qbx_session_participants SET prize_amount = ? WHERE session_id = ? AND citizenid = ?',
                values = {prize, session.id, participant.citizenid}
            }
        end
    end
    
    return payouts, extraQueries
end

-- ハウスカットの支払い（設定で有効な場合のみ）
function PayHouseCut(session)
    local houseCutConfig = GetConfigValue('Race.betting.houseCut', {enabled = false})
    if (session.houseCutAmount or 0) > 0 and type(houseCutConfig) == 'table'
        and houseCutConfig.recipient == 'society' and houseCutConfig.societyName then
        pcall(function()
            exports['qb-management']:AddMoney(houseCutConfig.societyName, session.houseCutAmount)
        end)
    end
end

-- レース中のリタイア
RegisterNetEvent('qbx_racing:server:retireRace', function(sessionId)
    local src = source
    local session = ActiveSessions[sessionId]
    if not session or session.status ~= 'racing' then return end
    
    local participant = FindParticipant(session, src)
    if participant and participant.status == 'racing' then
        SetParticipantStatus(sessionId, participant, 'retired')
    end
    
    CheckSessionComplete(sessionId)
end)

-- (FormatMoney はヘルパー関数セクションで定義済み)

-- ランキングのポイント変動の表示（「 +10pt」など。変動なしは空）
function FormatPointsDelta(delta)
    delta = ToInteger(delta)
    if not delta or delta == 0 then return '' end
    return string.format(' [%s%dpt]', delta > 0 and '+' or '', delta)
end

-- 最終結果発表
function BroadcastFinalResults(sessionId)
    local session = ActiveSessions[sessionId]
    if not session then return end
    
    -- 順位順にソート
    local results = {}
    local retired = {}
    for _, participant in ipairs(session.participants) do
        if participant.status == 'finished' then
            table.insert(results, participant)
        elseif participant.status == 'retired' then
            table.insert(retired, participant)
        end
    end
    
    table.sort(results, function(a, b)
        return (a.position or 999) < (b.position or 999)
    end)
    
    -- 結果サマリー
    local medals = {'🥇', '🥈', '🥉'}
    local summary = '🏁 最終結果\n\n'
    for i, participant in ipairs(results) do
        local medal = medals[i] or (i .. '位')
        local time = participant.finishTime and string.format("%.2f秒", participant.finishTime / 1000) or 'DNF'
        local prize = participant.prize and string.format('（賞金 $%s）', FormatMoney(participant.prize)) or ''
        summary = summary .. string.format('%s %s - %s%s%s\n', medal, participant.driverName, time, prize,
            FormatPointsDelta(participant.pointsDelta))
    end
    for _, participant in ipairs(retired) do
        summary = summary .. string.format('DNF %s%s\n', participant.driverName, FormatPointsDelta(participant.pointsDelta))
    end
    
    if session.isBetMode and session.prizePool > 0 then
        if session.prizesFailed then
            summary = summary .. '\n⚠️ 結果を保存できなかったため、賞金の代わりに参加費を後で返金します'
        elseif session.refundedAll then
            summary = summary .. '\n💰 ゴールした人がいなかったため、参加費とスポンサー金を返金しました'
        else
            summary = summary .. string.format('\n💰 総賞金プール: $%s', FormatMoney(session.prizePool))
        end
    end
    
    -- 全参加者に送信（レースに出られなかった人を除く）
    for _, participant in ipairs(session.participants) do
        local src = OnlineSource(participant)
        if src and participant.status ~= 'excluded' then
            TriggerClientEvent('ox_lib:notify', src, {
                title = 'レース終了',
                description = summary,
                type = 'inform',
                duration = 15000
            })
        end
    end
end

-- ソロレース完了処理

-- ソロのコース上の位置 index のチェックポイント（周回の index n+1 はスタート地点 = CP1）
local function SoloCheckpointAt(run, index)
    return CourseCheckpointAt(run.checkpoints, index)
end

-- ソロレース開始（GO の瞬間にクライアントから届く）
-- mode: 'daily' ならデイリーレースとして走る（その日のデイリーで、報酬が残っている場合のみ）
RegisterNetEvent('qbx_racing:server:soloRaceStarted', function(raceId, mode)
    local src = source
    local startedAt = GetGameTimer()
    raceId = ToInteger(raceId)
    soloRuns[src] = nil
    if not raceId then return end
    
    -- コースを読み込む間に届いた通過報告は pending に貯めて、読み込み後に順番に確認する
    -- （スタート直後にスタート地点を通過した報告がすぐ届くため）
    local run = {raceId = raceId, startedAt = startedAt, daily = false, pending = {}, checkpoint = 1, lap = 1}
    soloRuns[src] = run
    
    -- 通過の確認に使うコース（チェックポイントは順番にしか進めない。ゴールはサーバーが確認した進捗が最終地点の時だけ）
    local race = MySQL.single.await('SELECT race_type, laps FROM qbx_races WHERE id = ? AND is_active = 1', {raceId})
    local checkpoints = race and MySQL.query.await([[
        SELECT x, y, z, radius FROM qbx_race_checkpoints WHERE race_id = ? ORDER BY checkpoint_order ASC
    ]], {raceId}) or {}
    if soloRuns[src] ~= run then return end
    if #checkpoints == 0 then
        soloRuns[src] = nil
        return
    end
    local isSprint = race.race_type == 'sprint'
    run.checkpoints = checkpoints
    run.totalLaps = isSprint and 1 or math.max(1, ToInteger(race.laps) or 1)
    run.lapEndIndex = isSprint and #checkpoints or #checkpoints + 1
    local pending = run.pending
    run.pending = nil
    for _, report in ipairs(pending) do
        ApplySoloProgress(src, run, report[1], report[2], report[3])
    end
    
    if mode == 'daily' and Progression then
        local Player = GetPlayer(src)
        local ok, playable = pcall(Progression.IsDailyPlayable, Player and Player.PlayerData.citizenid, raceId)
        if ok and playable then
            run.daily = true
        else
            TriggerClientEvent('ox_lib:notify', src, {
                title = 'デイリーレース',
                description = '今日のデイリー報酬が残っていないため、通常の走行として記録します',
                type = 'inform'
            })
        end
    end
end)

-- ソロのチェックポイント通過報告（checkpoint は次に向かう位置）
RegisterNetEvent('qbx_racing:server:soloProgress', function(raceId, checkpoint, lap)
    local src = source
    local run = soloRuns[src]
    checkpoint, lap = ToInteger(checkpoint), ToInteger(lap)
    if not run or run.raceId ~= ToInteger(raceId) or not checkpoint or not lap then return end
    if run.pending then
        -- まだコースを読み込み中
        -- 位置は報告が届いた時点のものを使う（読み込み後の位置で確認すると先に進んだぶん離れてしまう）
        if #run.pending < 8 then run.pending[#run.pending + 1] = {checkpoint, lap, GetServerPlayerCoords(src)} end
        return
    end
    ApplySoloProgress(src, run, checkpoint, lap)
end)

function ApplySoloProgress(src, run, checkpoint, lap, coords)
    -- 1つずつ順番にしか進めない（周回は index n+1 = スタート地点を通ると次の周の CP2）
    local passedIndex, nextCheckpoint, nextLap
    if run.checkpoint < run.lapEndIndex then
        passedIndex, nextCheckpoint, nextLap = run.checkpoint, run.checkpoint + 1, run.lap
    else
        passedIndex, nextCheckpoint, nextLap = run.lapEndIndex, 2, run.lap + 1
    end
    if checkpoint ~= nextCheckpoint or lap ~= nextLap or lap > run.totalLaps then return end
    
    if not IsPlayerNearCheckpoint(src, SoloCheckpointAt(run, passedIndex), coords) then
        print(('^3[CAM Racing]^7 チェックポイント通過を受け付けませんでした（位置が離れています）: src=%d race=%d CP=%d'):format(
            src, run.raceId, passedIndex))
        return
    end
    run.checkpoint, run.lap = checkpoint, lap
end

-- ソロレースのリタイア（走行中のみ。ランキングのポイントが下がる）
RegisterNetEvent('qbx_racing:server:soloRaceRetired', function(raceId)
    local src = source
    local run = soloRuns[src]
    if not run or run.raceId ~= ToInteger(raceId) then return end
    soloRuns[src] = nil
    
    local Player = GetPlayer(src)
    if Player and Progression then
        local ok, err = pcall(Progression.OnSoloRaceRetired, src, Player.PlayerData.citizenid, run.raceId)
        if not ok then print('^1[CAM Racing]^7 リタイアの処理に失敗しました: ' .. tostring(err)) end
    end
end)

RegisterNetEvent('qbx_racing:server:finishRace', function(raceId, timeMs, vehicleModel)
    local src = source
    local run = soloRuns[src]
    soloRuns[src] = nil
    raceId = ToInteger(raceId)
    if not run or run.raceId ~= raceId then return end
    local serverElapsed = GetGameTimer() - run.startedAt
    
    -- 最終周のゴール直前まで順番に通過していて、ゴール地点にいること（サーバーが確認した進捗で判断）
    if run.pending or run.lap ~= run.totalLaps or run.checkpoint ~= run.lapEndIndex
        or not IsPlayerNearCheckpoint(src, SoloCheckpointAt(run, run.lapEndIndex)) then
        print(('^3[CAM Racing]^7 ソロのゴールを受け付けませんでした（チェックポイント未通過）: src=%d race=%d'):format(src, raceId))
        TriggerClientEvent('ox_lib:notify', src, {
            title = '記録なし',
            description = 'チェックポイントの通過を確認できなかったため、タイムは記録されませんでした',
            type = 'error'
        })
        return
    end
    
    local Player = GetPlayer(src)
    if not Player then return end
    
    local profile = GetDriverProfile(Player.PlayerData.citizenid)
    if not profile then return end
    
    -- 削除済みのレースには記録しない
    local race = MySQL.single.await('SELECT id, name, race_type, laps, target_time_ms, ta_reward FROM qbx_races WHERE id = ? AND is_active = 1', {raceId})
    if not race then return end
    race.checkpoints = MySQL.query.await([[
        SELECT x, y, z, radius FROM qbx_race_checkpoints WHERE race_id = ? ORDER BY checkpoint_order ASC
    ]], {raceId}) or {}
    
    -- 速すぎるゴールは記録しない
    local minTime = CalculateMinRaceTimeMs(race)
    if serverElapsed < minTime then
        print(('^1[CAM Racing]^7 不正なソロ記録の可能性: %s race=%d 経過=%dms 最短=%dms'):format(
            profile.driver_name, raceId, serverElapsed, minTime))
        return
    end
    
    -- タイムはサーバーの経過時間と大きくずれていればサーバー側の値を使う
    timeMs = ToInteger(timeMs)
    if not timeMs or math.abs(timeMs - serverElapsed) > 5000 then
        timeMs = serverElapsed
    end
    vehicleModel = TruncateText(vehicleModel, 50)
    if not vehicleModel or vehicleModel == '' then
        vehicleModel = '不明'
    end
    
    -- タイム記録
    local timeSaved = MySQL.insert.await([[
        INSERT INTO qbx_race_times (race_id, driver_name, citizenid, time_ms, server_time_ms, vehicle_model) 
        VALUES (?, ?, ?, ?, ?, ?)
    ]], {raceId, profile.driver_name, Player.PlayerData.citizenid, timeMs, serverElapsed, vehicleModel})
    
    -- 統計更新
    if timeSaved and GetConfigValue('Race.updateStats', true) then
        MySQL.query.await('UPDATE qbx_driver_profiles SET total_races = total_races + 1 WHERE citizenid = ?', {Player.PlayerData.citizenid})
    end
    
    -- タイムアタック・デイリーの報酬とランキング（記録を保存できたときだけ）
    local lines = {string.format('タイム: %.2f秒', timeMs / 1000)}
    if not timeSaved then
        lines[#lines + 1] = '⚠️ 記録を保存できませんでした'
    elseif Progression then
        -- 報酬・ランキングの判定はサーバーで測った経過時間より速くならない値で行う
        -- （記録するタイムはクライアントの値でも、報酬の判定で数秒縮められないように）
        local judgedTimeMs = math.max(timeMs, serverElapsed)
        local ok, result = pcall(Progression.OnSoloRaceFinished, src, Player.PlayerData.citizenid, race, judgedTimeMs, run.daily)
        if ok then
            for _, line in ipairs(result or {}) do lines[#lines + 1] = line end
        else
            print('^1[CAM Racing]^7 報酬・ランキングの処理に失敗しました: ' .. tostring(result))
        end
    end
    
    TriggerClientEvent('ox_lib:notify', src, {
        title = '🏁 ゴール！ ' .. tostring(race.name or ''),
        description = table.concat(lines, '\n'),
        type = 'success',
        duration = 12000
    })
    
    TriggerClientEvent('qbx_racing:client:updateRaces', -1)
end)


-- ===================================
-- レース削除機能
-- ===================================
lib.callback.register('qbx_racing:server:deleteRace', function(source, raceId)
    if not raceId then
        return {success = false, message = 'レースIDが指定されていません'}
    end
    
    -- 権限チェック
    if not HasRacePermission(source) then
        return {success = false, message = 'レース削除権限がありません'}
    end
    
    -- レース存在確認
    local race = MySQL.single.await('SELECT * FROM qbx_races WHERE id = ? AND is_active = 1', {raceId})
    if not race then
        return {success = false, message = 'レースが見つかりません'}
    end
    
    -- このレースを使用中のアクティブセッションがないか確認
    for _, session in pairs(ActiveSessions) do
        if session.raceId == raceId and session.status ~= 'finished' and session.status ~= 'cancelled' then
            return {success = false, message = 'このレースは現在使用中のセッションがあるため削除できません'}
        end
    end
    
    -- 論理削除（is_active = 0）
    local success = MySQL.update.await('UPDATE qbx_races SET is_active = 0 WHERE id = ?', {raceId})
    
    if success then
        print(string.format('[CAM Racing] レース削除: ID=%d, Name=%s, 実行者=%s', raceId, race.name, tostring(source)))
        
        TriggerClientEvent('ox_lib:notify', source, {
            title = '削除完了',
            description = 'レース「' .. race.name .. '」を削除しました',
            type = 'success'
        })
        
        -- 全クライアントにレース一覧更新通知
        TriggerClientEvent('qbx_racing:client:refreshRaces', -1)
        
        return {success = true}
    else
        return {success = false, message = 'データベースエラーが発生しました'}
    end
end)

-- ===================================
-- セッション離脱イベント
-- ===================================
RegisterNetEvent('qbx_racing:server:leaveSession', function(sessionId)
    local src = source
    local session = ActiveSessions[sessionId]
    if not session then return end
    
    local participant, index = FindParticipant(session, src)
    if not participant then return end
    
    -- ロビー以外（カウントダウン・レース中）の退出はリタイア扱い（途中でセッションを解散・返金しない）
    if session.status ~= 'lobby' then
        if participant.status ~= 'finished' and participant.status ~= 'excluded' and participant.status ~= 'retired' then
            SetParticipantStatus(sessionId, participant, 'retired')
        end
        CheckSessionComplete(sessionId)
        return
    end
    
    -- 主催者が離脱した場合 → セッション中止（全員に返金）
    if participant.isHost then
        CancelSessionWithRefund(sessionId, '主催者が退出したため、セッションが終了しました')
        return
    end
    
    local removed = RemoveLobbyParticipant(sessionId, index)
    if removed == 'busy' then return end -- 退出処理中（連打）
    if not removed then
        -- クライアントは退出したつもりなので、セッションに戻してロビーを開き直してもらう
        TriggerClientEvent('qbx_racing:client:leaveFailed', src, {
            sessionId = sessionId,
            participants = GetSessionParticipantList(sessionId)
        })
        return
    end
    BroadcastSessionUpdate(sessionId)

    TriggerClientEvent('ox_lib:notify', src, {
        title = 'セッション退出',
        description = 'セッションから退出しました',
        type = 'inform'
    })
end)

-- ===================================
-- セッションタイムアウト管理
-- ===================================
function StartSessionTimeoutThread()
    CreateThread(function()
        local checkInterval = 60000 -- 1分ごとにチェック
        local sessionTimeout = GetConfigValue('Multiplayer.sessionTimeout', 600)
        
        while true do
            Wait(checkInterval)
            
            local currentTime = os.time()
            local sessionsToCancel = {}
            
            for sessionId, session in pairs(ActiveSessions) do
                if session.status == 'lobby' and session.createdAt and currentTime - session.createdAt >= sessionTimeout then
                    table.insert(sessionsToCancel, sessionId)
                end
            end
            
            for _, sessionId in ipairs(sessionsToCancel) do
                print(string.format('[CAM Racing] セッションタイムアウト: ID=%d (%d秒経過)', sessionId, sessionTimeout))
                CancelSessionWithRefund(sessionId, '一定時間スタートされなかったため、セッションが終了しました')
            end
        end
    end)
end

-- ===================================
-- 初期化とクリーンアップ
-- ===================================

-- リソース起動時
-- ===================================
-- タブレット連携（Config.UI.mode = 'tablet' のときアプリとして登録）
-- ===================================
-- アプリ登録に成功したかをクライアントに伝える（失敗時はクライアントが通常の画面を使う）
local TABLET_STATE_KEY = GetCurrentResourceName() .. ':tabletApp'
GlobalState[TABLET_STATE_KEY] = false

local function RegisterTabletApp()
    local ui = Config.UI or {}
    local tablet = ui.tablet or {}
    if ui.mode ~= 'tablet' then return end
    
    local tabletResource = tablet.resource or 'cam_tablet'
    if GetResourceState(tabletResource) ~= 'started' then return end
    
    -- 設定をコピーして、表示するページ（タブレット向け表示）を付ける
    local app = {}
    for key, value in pairs(tablet.app or {}) do
        app[key] = value
    end
    app.id = app.id or 'racing'
    app.label = app.label or 'レーシング'
    -- 画面側が自分のリソース名（NUI コールバックの宛先）を確実に知れるよう resource も渡す
    local resource = GetCurrentResourceName()
    app.url = ('nui://%s/html/index.html?tablet=%s&resource=%s'):format(resource, tabletResource, resource)
    
    -- 同じアプリ ID を別のリソースが使っている場合などは登録を拒否される
    if exports[tabletResource]:RegisterApp(app) == false then
        print(('^1[CAM Racing]^7 タブレット (%s) へのアプリ「%s」(id: %s) の登録に失敗しました。'
            .. 'ID が別のリソースで使われている場合は Config.UI.tablet.app.id を変えるか、'
            .. 'サーバーコンソールで cam_tablet_releaseid %s を実行してください'):format(tabletResource, app.label, app.id, app.id))
        GlobalState[TABLET_STATE_KEY] = false
        return
    end
    GlobalState[TABLET_STATE_KEY] = true
    print(('^2[CAM Racing]^7 タブレット (%s) にアプリ「%s」を登録しました'):format(tabletResource, app.label))
end

-- タブレットが止まったらアプリも使えない
AddEventHandler('onResourceStop', function(resourceName)
    local tablet = Config.UI and Config.UI.tablet or {}
    if resourceName == (tablet.resource or 'cam_tablet') then
        GlobalState[TABLET_STATE_KEY] = false
    end
end)

-- タブレットにレーシングアプリがインストールされているか（/race で開く前の確認）
lib.callback.register('qbx_racing:server:hasTabletApp', function(source)
    local ui = Config.UI or {}
    local tablet = ui.tablet or {}
    local tabletResource = tablet.resource or 'cam_tablet'
    local appId = tablet.app and tablet.app.id or 'racing'
    if GetResourceState(tabletResource) ~= 'started' then return true end
    
    local ok, installed = pcall(function()
        return exports[tabletResource]:HasApp(source, appId)
    end)
    -- 確認できなかった場合はタブレット側の判断に任せる
    return not ok or installed == true
end)

-- タブレットが後から起動・再起動した場合も登録する
AddEventHandler(((Config.UI and Config.UI.tablet and Config.UI.tablet.resource) or 'cam_tablet') .. ':ready', RegisterTabletApp)

CreateThread(RegisterTabletApp)

-- ===================================
-- データベースの準備（install.sql を流していないサーバーでも動くように、起動時に作る）
-- ※ 外部キーは付けない（既存テーブルの id の型が違うと作成に失敗するため。
--   レースは論理削除なので連鎖削除がなくても困らない）
-- ===================================
local SCHEMA_TABLES = {
    [[
        CREATE TABLE IF NOT EXISTS `qbx_driver_profiles` (
            `citizenid` VARCHAR(50) PRIMARY KEY,
            `driver_name` VARCHAR(50) UNIQUE NOT NULL,
            `total_races` INT DEFAULT 0,
            `total_wins` INT DEFAULT 0,
            `points` INT DEFAULT 1000,
            `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_driver_name` (`driver_name`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_races` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `name` VARCHAR(100) NOT NULL,
            `description` TEXT,
            `vehicle_type` ENUM('car', 'heli', 'boat') NOT NULL,
            `race_type` ENUM('circuit', 'sprint') DEFAULT 'circuit',
            `laps` INT DEFAULT 1,
            `min_participants` INT DEFAULT 2,
            `max_participants` INT DEFAULT 16,
            `creator_driver_name` VARCHAR(50),
            `is_active` TINYINT(1) DEFAULT 1,
            `target_time_ms` INT NULL,
            `ta_reward` INT NULL,
            `ta_rate` INT NULL,
            `ta_calib_after_id` INT DEFAULT 0,
            `course_length_m` FLOAT NULL,
            `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_vehicle_type` (`vehicle_type`),
            INDEX `idx_race_type` (`race_type`),
            INDEX `idx_active` (`is_active`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_race_checkpoints` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `race_id` INT NOT NULL,
            `checkpoint_order` INT NOT NULL,
            `x` DOUBLE NOT NULL,
            `y` DOUBLE NOT NULL,
            `z` DOUBLE NOT NULL,
            `radius` FLOAT DEFAULT 10.0,
            INDEX `idx_race_order` (`race_id`, `checkpoint_order`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_race_turn_guides` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `race_id` INT NOT NULL,
            `checkpoint_order` INT NOT NULL,
            `x` DOUBLE NOT NULL,
            `y` DOUBLE NOT NULL,
            `z` DOUBLE NOT NULL,
            `direction` ENUM('left', 'right') NOT NULL,
            `segments` INT DEFAULT 1,
            INDEX `idx_race_guide` (`race_id`, `checkpoint_order`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_race_times` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `race_id` INT NOT NULL,
            `driver_name` VARCHAR(50) NOT NULL,
            `citizenid` VARCHAR(50) NOT NULL,
            `time_ms` INT NOT NULL,
            `server_time_ms` INT NULL,
            `vehicle_model` VARCHAR(50) NOT NULL,
            `completed_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_race_time` (`race_id`, `time_ms`),
            INDEX `idx_driver` (`driver_name`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_race_sessions` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `race_id` INT NOT NULL,
            `host_citizenid` VARCHAR(50) NOT NULL,
            `host_driver_name` VARCHAR(50) NOT NULL,
            `session_name` VARCHAR(100) NOT NULL,
            `status` ENUM('lobby', 'countdown', 'racing', 'finished', 'cancelled') DEFAULT 'lobby',
            `countdown_duration` INT DEFAULT 10,
            `start_time` TIMESTAMP NULL,
            `is_bet_mode` TINYINT(1) DEFAULT 0,
            `entry_fee` INT DEFAULT 0,
            `prize_pool` INT DEFAULT 0,
            `sponsor_amount` INT DEFAULT 0,
            `sponsor_citizenid` VARCHAR(50) DEFAULT NULL,
            `sponsor_name` VARCHAR(100) DEFAULT NULL,
            `house_cut` INT DEFAULT 0,
            `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_status` (`status`),
            INDEX `idx_host` (`host_citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_session_participants` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `session_id` INT NOT NULL,
            `citizenid` VARCHAR(50) NOT NULL,
            `driver_name` VARCHAR(50) NOT NULL,
            `vehicle_model` VARCHAR(50),
            `status` ENUM('entered', 'ready', 'racing', 'finished', 'retired', 'excluded') DEFAULT 'entered',
            `current_checkpoint` INT DEFAULT 1,
            `current_lap` INT DEFAULT 1,
            `finish_time_ms` INT NULL,
            `final_position` INT NULL,
            `entry_paid` TINYINT(1) DEFAULT 0,
            `prize_amount` INT DEFAULT 0,
            UNIQUE KEY `unique_participant` (`session_id`, `citizenid`),
            INDEX `idx_session` (`session_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_session_progress` (
            `session_id` INT NOT NULL,
            `citizenid` VARCHAR(50) NOT NULL,
            `checkpoint` INT NOT NULL,
            `lap` INT NOT NULL,
            `timestamp` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`session_id`, `citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_race_sponsors` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `session_id` INT NOT NULL,
            `sponsor_citizenid` VARCHAR(50) NOT NULL,
            `sponsor_driver_name` VARCHAR(50) NOT NULL,
            `amount` INT NOT NULL,
            `sponsor_type` ENUM('host', 'participant') DEFAULT 'host',
            `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_sponsor` (`sponsor_citizenid`),
            INDEX `idx_amount` (`amount`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_race_payouts` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `session_id` INT NOT NULL,
            `citizenid` VARCHAR(50) NOT NULL,
            `amount` INT NOT NULL,
            `reason` VARCHAR(50) NOT NULL,
            `paid` TINYINT(1) DEFAULT 0,
            `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_unpaid` (`paid`),
            INDEX `idx_session` (`session_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_ta_claims` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `citizenid` VARCHAR(50) NOT NULL,
            `race_id` INT NOT NULL,
            `time_ms` INT NOT NULL,
            `reward` INT NOT NULL,
            `claimed_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY `unique_claim` (`citizenid`, `race_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_daily_races` (
            `day` DATE NOT NULL,
            `slot` INT NOT NULL,
            `race_id` INT NOT NULL,
            `target_time_ms` INT NOT NULL,
            `reward` INT NOT NULL,
            PRIMARY KEY (`day`, `slot`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_daily_claims` (
            `day` DATE NOT NULL,
            `citizenid` VARCHAR(50) NOT NULL,
            `race_id` INT NOT NULL,
            `kind` VARCHAR(10) NOT NULL,
            `amount` INT NOT NULL,
            `claimed_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`day`, `citizenid`, `race_id`, `kind`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]],
    [[
        CREATE TABLE IF NOT EXISTS `qbx_ranking_log` (
            `id` INT AUTO_INCREMENT PRIMARY KEY,
            `citizenid` VARCHAR(50) NOT NULL,
            `delta` INT NOT NULL,
            `reason` VARCHAR(50) NOT NULL,
            `race_id` INT NULL,
            `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_citizen_time` (`citizenid`, `created_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]]
}

-- 古いバージョンのテーブルに足りない列（テーブル, 列, 定義）
local SCHEMA_COLUMNS = {
    {'qbx_races', 'description', "TEXT AFTER `name`"},
    {'qbx_races', 'race_type', "ENUM('circuit', 'sprint') DEFAULT 'circuit' AFTER `vehicle_type`"},
    {'qbx_race_sessions', 'is_bet_mode', "TINYINT(1) DEFAULT 0 AFTER `start_time`"},
    {'qbx_race_sessions', 'entry_fee', "INT DEFAULT 0 AFTER `is_bet_mode`"},
    {'qbx_race_sessions', 'prize_pool', "INT DEFAULT 0 AFTER `entry_fee`"},
    {'qbx_race_sessions', 'sponsor_amount', "INT DEFAULT 0 AFTER `prize_pool`"},
    {'qbx_race_sessions', 'sponsor_citizenid', "VARCHAR(50) DEFAULT NULL AFTER `sponsor_amount`"},
    {'qbx_race_sessions', 'sponsor_name', "VARCHAR(100) DEFAULT NULL AFTER `sponsor_citizenid`"},
    {'qbx_race_sessions', 'house_cut', "INT DEFAULT 0 AFTER `sponsor_name`"},
    {'qbx_session_participants', 'entry_paid', "TINYINT(1) DEFAULT 0 AFTER `final_position`"},
    {'qbx_session_participants', 'prize_amount', "INT DEFAULT 0 AFTER `entry_paid`"},
    {'qbx_race_turn_guides', 'segments', "INT DEFAULT 1 AFTER `direction`"},
    -- タイムアタック（目標タイム・報酬）。目標タイムはサーバーで測った経過時間から計算する
    {'qbx_race_times', 'server_time_ms', "INT NULL AFTER `time_ms`"},
    {'qbx_races', 'target_time_ms', "INT NULL"},
    {'qbx_races', 'ta_reward', "INT NULL"},
    {'qbx_races', 'ta_rate', "INT NULL"},
    {'qbx_races', 'ta_calib_after_id', "INT DEFAULT 0"},
    {'qbx_races', 'course_length_m', "FLOAT NULL"},
    -- ランキングのポイント（既存のプロフィールは設定の初期ポイントで埋める）
    {'qbx_driver_profiles', 'points', "INT DEFAULT 1000 AFTER `total_wins`", function()
        MySQL.update.await('UPDATE qbx_driver_profiles SET points = ?',
            {ToInteger(GetConfigValue('Ranking.startPoints', 1000)) or 1000})
    end}
}

-- 1つずつ実行して、失敗したものはログに出して続ける。戻り値: すべて成功したら true
local function EnsureDatabaseSchema()
    local allOk = true
    local function try(label, fn)
        local ok, err = pcall(fn)
        if not ok then
            allOk = false
            print(('^1[CAM Racing]^7 データベースの準備（%s）に失敗しました: %s'):format(label, tostring(err)))
        end
    end
    
    for _, statement in ipairs(SCHEMA_TABLES) do
        try(statement:match('`([%w_]+)`') or 'テーブル作成', function()
            MySQL.query.await(statement)
        end)
    end
    
    for _, column in ipairs(SCHEMA_COLUMNS) do
        try(column[1] .. '.' .. column[2], function()
            local exists = MySQL.scalar.await([[
                SELECT COUNT(*) FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
            ]], {column[1], column[2]})
            if tonumber(exists) == 0 then
                MySQL.query.await(('ALTER TABLE `%s` ADD COLUMN `%s` %s'):format(column[1], column[2], column[3]))
                if column[4] then column[4]() end
            end
        end)
    end
    
    -- 参加者ステータスにリタイア・対象外を追加（既存サーバー向け）
    try('qbx_session_participants.status', function()
        local statusType = MySQL.scalar.await([[
            SELECT COLUMN_TYPE FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'qbx_session_participants' AND COLUMN_NAME = 'status'
        ]])
        if statusType and not tostring(statusType):find('retired', 1, true) then
            MySQL.query.await([[ALTER TABLE `qbx_session_participants` MODIFY COLUMN `status`
                ENUM('entered', 'ready', 'racing', 'finished', 'retired', 'excluded') DEFAULT 'entered']])
        end
    end)
    
    return allOk
end

-- 指定したテーブルがすべてあるか（他の準備が失敗していても、必要なテーブルがあれば復旧はできる）
local function TablesExist(names)
    local placeholders = string.rep('?', #names, ', ')
    local count = MySQL.scalar.await(([[
        SELECT COUNT(*) FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (%s)
    ]]):format(placeholders), names)
    return tonumber(count) == #names
end

-- 起動時の処理を1つずつ実行する（1つが失敗しても残りは続ける）
local function RunStartupStep(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        print(('^1[CAM Racing]^7 起動処理「%s」に失敗しました: %s'):format(name, tostring(err)))
    end
    return ok
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    print('^2[CAM Racing]^7 サーバーサイド起動完了')
    
    -- テーブルの作成・不足している列の追加（install.sql を流していなくても動くように）
    local schemaOk = false
    RunStartupStep('データベースの準備', function()
        schemaOk = EnsureDatabaseSchema()
    end)
    if not schemaOk then
        print('^1[CAM Racing]^7 データベースの準備の一部に失敗しました。上のログを確認するか、sql/install.sql を手動で実行してください')
    end
    print('^2[CAM Racing]^7 マルチプレイヤーシステム: ' .. 
          (Config.Multiplayer and Config.Multiplayer.enabled and '有効' or '無効'))
    
    -- 返金・賞金の復旧は、必要なテーブルがあれば他の準備の失敗に関係なく行う
    -- （未払いの支払いは台帳だけ、終わっていなかったセッションの返金はセッション関連のテーブルも必要）
    local ledgerReady, recoveryReady = false, false
    RunStartupStep('支払い台帳の確認', function()
        ledgerReady = TablesExist({'qbx_race_payouts'})
        recoveryReady = ledgerReady
            and TablesExist({'qbx_race_sessions', 'qbx_session_participants', 'qbx_race_sponsors'})
    end)
    
    -- 前回サーバーが落ちたときに終わっていなかったセッション →
    -- 参加費（支払い済みの記録がある分）とスポンサー金（スポンサー履歴がある分）の返金予定を記録して中止にする
    -- （台帳が無いと返金予定を残せないので、その場合はセッションも中止にせず次回起動時に任せる）
    if recoveryReady then
        RunStartupStep('前回終わっていなかったセッションの返金', function()
            local staleSessions = MySQL.query.await([[
                SELECT id, entry_fee FROM qbx_race_sessions WHERE status IN ('lobby', 'countdown', 'racing')
            ]]) or {}
            for _, stale in ipairs(staleSessions) do
                local payouts = {}
                local entryFee = ToInteger(stale.entry_fee) or 0
                if entryFee > 0 then
                    local paid = MySQL.query.await([[
                        SELECT citizenid FROM qbx_session_participants WHERE session_id = ? AND entry_paid = 1
                    ]], {stale.id}) or {}
                    for _, row in ipairs(paid) do
                        payouts[#payouts + 1] = {citizenid = row.citizenid, amount = entryFee, reason = 'race-entry-refund'}
                    end
                end
                local sponsors = MySQL.query.await([[
                    SELECT sponsor_citizenid, SUM(amount) AS amount FROM qbx_race_sponsors
                    WHERE session_id = ? AND sponsor_type = 'host' GROUP BY sponsor_citizenid
                ]], {stale.id}) or {}
                for _, row in ipairs(sponsors) do
                    payouts[#payouts + 1] = {citizenid = row.sponsor_citizenid, amount = row.amount, reason = 'race-sponsor-refund'}
                end
                
                if not RecordPayouts(stale.id, payouts, {
                    {query = "UPDATE qbx_race_sessions SET status = 'cancelled' WHERE id = ? AND status IN ('lobby', 'countdown', 'racing')", values = {stale.id}}
                }) then
                    print(('^1[CAM Racing]^7 セッション %d の返金予定を記録できませんでした（次回起動時に再試行します）'):format(stale.id))
                end
            end
        end)
    end
    
    -- 未払いの返金・賞金をすべて支払う（前回の途中で止まった分も含む。台帳だけあればできる）
    if ledgerReady then
        RunStartupStep('未払いの返金・賞金の支払い', function()
            SettlePayouts(nil)
        end)
    end
    ActiveSessions = {}
    
    -- セッションタイムアウト管理スレッド開始
    StartSessionTimeoutThread()
end)

-- リソース停止時
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    -- 終わっていないセッションは中止して返金（レース中の賞金は終了時払いなので、まだ誰にも払われていない）
    local unfinished = {}
    for sessionId, session in pairs(ActiveSessions) do
        if session.status == 'lobby' or session.status == 'countdown' or session.status == 'racing' then
            table.insert(unfinished, sessionId)
        end
    end
    for _, sessionId in ipairs(unfinished) do
        CancelSessionWithRefund(sessionId, 'レースシステムが再起動されたため、セッションが終了しました')
    end
    
    print('^1[CAM Racing]^7 サーバーサイド停止完了')
end)

-- プレイヤー切断時のクリーンアップ
AddEventHandler('playerDropped', function(reason)
    local src = source
    busyPlayers[src] = nil
    soloRuns[src] = nil
    
    local sessionIds = {}
    for sessionId in pairs(ActiveSessions) do
        table.insert(sessionIds, sessionId)
    end
    
    for _, sessionId in ipairs(sessionIds) do
        local session = ActiveSessions[sessionId]
        local participant, index = session and FindParticipant(session, src)
        if participant then
            participant.disconnected = true
            
            if session.status == 'lobby' then
                if participant.isHost then
                    -- 主催者が切断 → セッション中止（全員に返金、本人分は citizenid で返金）
                    CancelSessionWithRefund(sessionId, '主催者が切断したため、セッションが終了しました')
                else
                    RemoveLobbyParticipant(sessionId, index)
                    BroadcastSessionUpdate(sessionId)
                end
            else
                -- カウントダウン・レース中はリタイア扱い（順位と結果のため一覧からは消さない）
                if participant.status ~= 'finished' and participant.status ~= 'excluded' and participant.status ~= 'retired' then
                    SetParticipantStatus(sessionId, participant, 'retired')
                end
                CheckSessionComplete(sessionId)
            end
        end
    end
end)

-- ===================================
-- server/progression.lua（タイムアタック・デイリー・ランキング）と共有する関数
-- ===================================
RacingServer = {
    GetConfigValue = GetConfigValue,
    FormatMoney = FormatMoney,
    GetPlayer = GetPlayer,
    ToInteger = ToInteger,
    GetDriverProfile = GetDriverProfile,
    HasRacePermission = HasRacePermission,
    RecordPayouts = RecordPayouts,
    SettlePayouts = SettlePayouts
}
