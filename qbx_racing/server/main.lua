-- ===================================
-- QBX Racing System - Server Main
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
        print('^1[QBX Racing]^7 プレイヤーデータ取得失敗: ' .. tostring(source))
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
        INSERT INTO qbx_driver_profiles (citizenid, driver_name, total_races, total_wins) 
        VALUES (?, ?, 0, 0)
    ]], {Player.PlayerData.citizenid, driverName})
    
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
    
    if success then
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
        print('^1[QBX Racing]^7 レース作成: プレイヤーデータなし')
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
    
    if not data or not data.name or not data.checkpoints or 
       #data.checkpoints < (Config.Checkpoint and Config.Checkpoint.minCheckpoints or 3) then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'エラー',
            description = 'レース名またはチェックポイントが不足しています',
            type = 'error'
        })
        return
    end
    
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
        data.name,
        data.description or '',
        data.vehicleType or 'car',
        data.raceType or 'circuit',
        data.laps or 1,
        profile.driver_name
    })
    
    if raceId then
        -- チェックポイント保存
        for i, checkpoint in ipairs(data.checkpoints) do
            MySQL.insert.await([[
                INSERT INTO qbx_race_checkpoints (race_id, checkpoint_order, x, y, z, radius) 
                VALUES (?, ?, ?, ?, ?, ?)
            ]], {
                raceId, i, checkpoint.x, checkpoint.y, checkpoint.z, 
                checkpoint.radius or (Config.Checkpoint and Config.Checkpoint.radius or 10.0)
            })
        end
        
        TriggerClientEvent('ox_lib:notify', src, {
            title = '成功',
            description = 'レース「' .. data.name .. '」を作成しました',
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
lib.callback.register('qbx_racing:server:createMultiSession', function(source, data)
    local Player = GetPlayer(source)
    if not Player then 
        return {success = false, message = 'プレイヤーデータが見つかりません'} 
    end
    
    local profile = GetDriverProfile(Player.PlayerData.citizenid)
    if not profile then 
        return {success = false, message = 'ドライバープロフィールが必要です'} 
    end
    
    -- レース情報取得
    local race = MySQL.single.await('SELECT * FROM qbx_races WHERE id = ? AND is_active = 1', {data.raceId})
    if not race then 
        return {success = false, message = 'レースが見つかりません'} 
    end
    
    race.checkpoints = MySQL.query.await([[
        SELECT x, y, z, radius FROM qbx_race_checkpoints 
        WHERE race_id = ? ORDER BY checkpoint_order ASC
    ]], {data.raceId}) or {}
    
    -- 掛け金・スポンサー設定
    local isBetMode = data.betMode or false
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
        entryFee = tonumber(data.entryFee) or 0
        
        -- スポンサー金設定
        if GetConfigValue('Race.betting.sponsor.enabled', true) and 
           GetConfigValue('Race.betting.sponsor.host.enabled', true) then
            sponsorAmount = tonumber(data.sponsorAmount) or 0
            
            -- スポンサー金額の検証
            local minSponsor = GetConfigValue('Race.betting.sponsor.host.min', 0)
            local maxSponsor = GetConfigValue('Race.betting.sponsor.host.max', 5000000)
            
            if sponsorAmount < minSponsor or sponsorAmount > maxSponsor then
                return {success = false, message = string.format('スポンサー金は$%s～$%sの範囲で設定してください', 
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
        
        -- 主催者の資金チェック（参加費 + スポンサー金）
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
        data.raceId, 
        Player.PlayerData.citizenid, 
        profile.driver_name, 
        data.sessionName or (race.name .. ' - セッション'),
        data.countdownDuration or GetConfigValue('Multiplayer.defaultCountdown', 10),
        isBetMode and 1 or 0,
        entryFee,
        sponsorAmount,  -- 初期賞金プール = スポンサー金
        sponsorAmount,
        sponsorAmount > 0 and Player.PlayerData.citizenid or nil,
        sponsorAmount > 0 and profile.driver_name or nil
    })
    
    if sessionId then
        -- スポンサー金の徴収
        if sponsorAmount > 0 then
            local currency = GetConfigValue('Race.currency', 'cash')
            if Player.Functions.RemoveMoney(currency, sponsorAmount, 'race-sponsor') then
                -- スポンサー履歴に記録
                MySQL.insert.await([[
                    INSERT INTO qbx_race_sponsors (session_id, sponsor_citizenid, sponsor_driver_name, amount, sponsor_type) 
                    VALUES (?, ?, ?, ?, 'host')
                ]], {sessionId, Player.PlayerData.citizenid, profile.driver_name, sponsorAmount})
                
                -- 成功ログ
                print(string.format('[QBX Racing] スポンサー記録: %s が $%d をセッション %d に提供', 
                    profile.driver_name, sponsorAmount, sessionId))
            else
                -- 支払い失敗時はセッション削除
                MySQL.query.await('DELETE FROM qbx_race_sessions WHERE id = ?', {sessionId})
                return {success = false, message = 'スポンサー金の支払いに失敗しました'}
            end
        end
        
        -- アクティブセッション登録
        ActiveSessions[sessionId] = {
            id = sessionId,
            raceId = data.raceId,
            race = race,
            host = source,
            hostName = profile.driver_name,
            participants = {},
            status = 'lobby',
            countdownDuration = data.countdownDuration or 10,
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
        
        -- 主催者を自動参加
        if RegisterSessionParticipant(sessionId, source, {isHost = true}) then
            return {
                success = true, 
                sessionId = sessionId,
                race = race,
                isBetMode = isBetMode,
                entryFee = entryFee,
                sponsorAmount = sponsorAmount,
                initialPrizePool = sponsorAmount,
                totalCost = entryFee + sponsorAmount
            }
        end
    end
    
    return {success = false, message = 'セッション作成に失敗しました'}
end)

-- セッション参加
lib.callback.register('qbx_racing:server:joinSession', function(source, sessionId)
    local session = ActiveSessions[sessionId]
    if not session then 
        return {success = false, message = 'セッションが見つかりません'} 
    end
    
    if session.status ~= 'lobby' then
        return {success = false, message = 'このセッションは既に開始されています'}
    end
    
    local maxParticipants = Config.Multiplayer and Config.Multiplayer.maxParticipants or 16
    if #session.participants >= maxParticipants then
        return {success = false, message = '参加人数が上限に達しています'}
    end
    
    if RegisterSessionParticipant(sessionId, source, {}) then
        BroadcastSessionUpdate(sessionId)
        return {
            success = true,
            participants = GetSessionParticipantList(sessionId)
        }
    end
    
    return {success = false, message = '参加処理に失敗しました'}
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
    local Player = GetPlayer(source)
    if not Player then return false end
    
    local profile = GetDriverProfile(Player.PlayerData.citizenid)
    if not profile then return false end
    
    local session = ActiveSessions[sessionId]
    if not session then return false end
    
    -- 重複チェック
    for _, participant in ipairs(session.participants) do
        if participant.citizenid == Player.PlayerData.citizenid then
            return false
        end
    end
    
    -- 掛け金モードの場合は参加費を徴収（ホストはスポンサー金で別途支払い済みのため免除可）
    local entryPaid = false
    if session.isBetMode and session.entryFee > 0 and not options.isHost then
        local currency = GetConfigValue('Race.currency', 'cash')
        local balance = Player.Functions.GetMoney(currency)
        
        if balance < session.entryFee then
            TriggerClientEvent('ox_lib:notify', source, {
                title = '参加失敗',
                description = string.format('参加費$%dが不足しています（所持金: $%d）', session.entryFee, balance),
                type = 'error'
            })
            return false
        end
        
        -- 参加費徴収
        if Player.Functions.RemoveMoney(currency, session.entryFee, 'race-entry-fee') then
            session.prizePool = session.prizePool + session.entryFee
            entryPaid = true
            
            -- データベース更新
            MySQL.update.await('UPDATE qbx_race_sessions SET prize_pool = ? WHERE id = ?', {session.prizePool, sessionId})
            
            TriggerClientEvent('ox_lib:notify', source, {
                title = '参加完了',
                description = string.format('参加費$%dを支払いました（賞金プール: $%d）', session.entryFee, session.prizePool),
                type = 'success'
            })
        else
            return false
        end
    end
    
    -- 車両情報取得
    local ped = GetPlayerPed(source)
    local vehicle = GetVehiclePedIsIn(ped, false)
    local vehicleModel = vehicle ~= 0 and GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)) or 'なし'
    
    -- データベース登録
    local participantId = MySQL.insert.await([[
        INSERT INTO qbx_session_participants 
        (session_id, citizenid, driver_name, vehicle_model, status, entry_paid) 
        VALUES (?, ?, ?, ?, 'entered', ?)
    ]], {sessionId, Player.PlayerData.citizenid, profile.driver_name, vehicleModel, entryPaid and 1 or 0})
    
    if participantId then
        table.insert(session.participants, {
            id = participantId,
            source = source,
            citizenid = Player.PlayerData.citizenid,
            driverName = profile.driver_name,
            vehicleModel = vehicleModel,
            status = 'entered',
            isHost = options.isHost or false,
            entryPaid = entryPaid,
            currentCheckpoint = 1,
            currentLap = 1
        })
        return true
    end
    
    return false
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
        TriggerClientEvent('qbx_racing:client:sessionUpdate', participant.source, updateData)
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
RegisterNetEvent('qbx_racing:server:startCountdown', function(sessionId)
    local src = source
    local session = ActiveSessions[sessionId]
    
    if not session or session.host ~= src or session.status ~= 'lobby' then
        return
    end
    
    local minParticipants = Config.Multiplayer and Config.Multiplayer.minParticipants or 2
    if #session.participants < minParticipants then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'エラー',
            description = string.format('最低%d人の参加者が必要です', minParticipants),
            type = 'error'
        })
        return
    end
    
    session.status = 'countdown'
    MySQL.update.await('UPDATE qbx_race_sessions SET status = ? WHERE id = ?', {'countdown', sessionId})
    
    -- 有効な参加者をチェック
    local validParticipants = {}
    for _, participant in ipairs(session.participants) do
        local ped = GetPlayerPed(participant.source)
        local vehicle = GetVehiclePedIsIn(ped, false)
        
        if vehicle ~= 0 then
            local vehicleClass = GetVehicleClass(vehicle)
            local allowedClasses = Config.VehicleTypes and Config.VehicleTypes[session.race.vehicle_type] and 
                                   Config.VehicleTypes[session.race.vehicle_type].allowedClasses or {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
            
            for _, allowedClass in ipairs(allowedClasses) do
                if vehicleClass == allowedClass then
                    table.insert(validParticipants, participant.source)
                    break
                end
            end
        end
    end
    
    if #validParticipants < minParticipants then
        session.status = 'lobby'
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'エラー',
            description = '有効な参加者が不足しています',
            type = 'error'
        })
        return
    end
    
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
        while countdown > 0 and ActiveSessions[sessionId] and ActiveSessions[sessionId].status == 'countdown' do
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
        if ActiveSessions[sessionId] and ActiveSessions[sessionId].status == 'countdown' then
            StartMultiplayerRace(sessionId, validParticipants)
        end
    end)
end)

-- マルチプレイヤーレース開始
function StartMultiplayerRace(sessionId, validParticipants)
    local session = ActiveSessions[sessionId]
    if not session then return end
    
    session.status = 'racing'
    session.startTime = os.time()
    
    MySQL.update.await('UPDATE qbx_race_sessions SET status = ?, start_time = NOW() WHERE id = ?', {'racing', sessionId})
    MySQL.update.await('UPDATE qbx_session_participants SET status = ? WHERE session_id = ?', {'racing', sessionId})
    
    -- 参加者ステータス更新
    for _, participant in ipairs(session.participants) do
        participant.status = 'racing'
    end
    
    -- 全参加者にレース開始通知
    for _, participantSource in ipairs(validParticipants) do
        TriggerClientEvent('qbx_racing:client:multiRaceStart', participantSource, {
            sessionId = sessionId,
            race = session.race,
            participants = validParticipants,
            isMultiplayer = true
        })
    end
    
    -- 進捗同期スレッド開始
    StartProgressSyncThread(sessionId)
end

-- 進捗同期スレッド
function StartProgressSyncThread(sessionId)
    CreateThread(function()
        local session = ActiveSessions[sessionId]
        if not session then return end
        
        local syncInterval = Config.Multiplayer and Config.Multiplayer.progressSyncInterval or 500
        
        while session.status == 'racing' do
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
                if participant.status == 'racing' then
                    TriggerClientEvent('qbx_racing:client:progressUpdate', participant.source, {
                        sessionId = sessionId,
                        progressData = progressData
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
    
    for _, participant in ipairs(session.participants) do
        if participant.source == src then
            participant.currentCheckpoint = checkpoint or 1
            participant.currentLap = lap or 1
            break
        end
    end
end)

-- ===================================
-- レース完了（スポンサー対応賞金分配）
-- ===================================
RegisterNetEvent('qbx_racing:server:finishMultiRace', function(sessionId, timeMs, vehicleModel)
    local src = source
    local Player = GetPlayer(src)
    if not Player then return end
    
    local session = ActiveSessions[sessionId]
    if not session then return end
    
    local profile = GetDriverProfile(Player.PlayerData.citizenid)
    if not profile then return end
    
    -- 順位計算
    local finishedCount = 0
    for _, participant in ipairs(session.participants) do
        if participant.status == 'finished' then
            finishedCount = finishedCount + 1
        end
    end
    local position = finishedCount + 1
    
    -- 参加者情報更新
    for _, participant in ipairs(session.participants) do
        if participant.source == src then
            participant.status = 'finished'
            participant.finishTime = timeMs
            participant.position = position
            break
        end
    end
    
    -- データベース更新
    MySQL.update.await([[
        UPDATE qbx_session_participants 
        SET status = 'finished', finish_time_ms = ?, final_position = ? 
        WHERE session_id = ? AND citizenid = ?
    ]], {timeMs, position, sessionId, Player.PlayerData.citizenid})
    
    MySQL.insert.await([[
        INSERT INTO qbx_race_times (race_id, driver_name, citizenid, time_ms, vehicle_model) 
        VALUES (?, ?, ?, ?, ?)
    ]], {session.raceId, profile.driver_name, Player.PlayerData.citizenid, timeMs, vehicleModel})
    
    -- ===================================
    -- スポンサー対応賞金計算
    -- ===================================
    local reward = 0
    local rewardMessage = ''
    
    if session.isBetMode and session.prizePool > 0 then
        -- ハウスカット計算
        local houseCutConfig = GetConfigValue('Race.betting.houseCut', {enabled = false})
        local houseCutAmount = 0
        
        if houseCutConfig.enabled then
            houseCutAmount = math.floor(session.prizePool * (houseCutConfig.percentage or 10) / 100)
        end
        
        local distributionPool = session.prizePool - houseCutAmount
        
        -- 順位別賞金配分
        local distribution = GetConfigValue('Race.betting.distribution', {
            [1] = 50, [2] = 30, [3] = 20
        })
        
        local percentage = distribution[position]
        if percentage and percentage > 0 then
            reward = math.floor(distributionPool * percentage / 100)
            
            -- 賞金支払い
            local currency = GetConfigValue('Race.currency', 'cash')
            Player.Functions.AddMoney(currency, reward, 'race-prize')
            
            -- 詳細メッセージ作成
            local medals = {'🥇 優勝', '🥈 準優勝', '🥉 3位'}
            local positionText = medals[position] or (position .. '位')
            
            if session.sponsorAmount > 0 then
                rewardMessage = string.format('%s賞金: $%s\n（総プール $%s = 参加費 + スポンサー $%s）', 
                    positionText, FormatMoney(reward), FormatMoney(session.prizePool), FormatMoney(session.sponsorAmount))
            else
                rewardMessage = string.format('%s賞金: $%s', positionText, FormatMoney(reward))
            end
            
            -- データベースに記録
            MySQL.update.await([[
                UPDATE qbx_session_participants 
                SET prize_amount = ? 
                WHERE session_id = ? AND citizenid = ?
            ]], {reward, sessionId, Player.PlayerData.citizenid})
        else
            rewardMessage = '賞金圏外'
        end
        
        -- ハウスカット処理
        if houseCutAmount > 0 then
            local recipient = houseCutConfig.recipient or 'none'
            if recipient == 'society' and houseCutConfig.societyName then
                pcall(function()
                    exports['qb-management']:AddMoney(houseCutConfig.societyName, houseCutAmount)
                end)
            end
        end
    else
        rewardMessage = 'タイム記録のみ'
    end
    
    -- 統計更新
    if GetConfigValue('Race.updateStats', true) then
        MySQL.query.await('UPDATE qbx_driver_profiles SET total_races = total_races + 1 WHERE citizenid = ?', {Player.PlayerData.citizenid})
        if position == 1 then
            MySQL.query.await('UPDATE qbx_driver_profiles SET total_wins = total_wins + 1 WHERE citizenid = ?', {Player.PlayerData.citizenid})
        end
    end
    
    -- 完了通知
    local timeFormatted = string.format("%.2f秒", timeMs / 1000)
    local medals = {'🥇', '🥈', '🥉'}
    local medal = medals[position] or '🏁'
    
    TriggerClientEvent('ox_lib:notify', src, {
        title = string.format('%s %d位でゴール！', medal, position),
        description = string.format('%s\n%s', timeFormatted, rewardMessage),
        type = reward > 0 and 'success' or 'inform',
        duration = 10000
    })
    
    -- 全参加者に完了通知（スポンサー情報含む）
    for _, participant in ipairs(session.participants) do
        local notificationMsg = string.format('%s: %s', profile.driver_name, timeFormatted)
        if reward > 0 then
            notificationMsg = notificationMsg .. string.format(' (賞金: $%s)', FormatMoney(reward))
        end
        
        TriggerClientEvent('qbx_racing:client:participantFinished', participant.source, {
            sessionId = sessionId,
            finisher = profile.driver_name,
            position = position,
            time = timeMs,
            timeFormatted = timeFormatted,
            reward = reward,
            message = notificationMsg
        })
    end
    
    -- 全員完了チェックと最終結果
    local allFinished = true
    for _, participant in ipairs(session.participants) do
        if participant.status == 'racing' then
            allFinished = false
            break
        end
    end
    
    if allFinished then
        session.status = 'finished'
        MySQL.update.await('UPDATE qbx_race_sessions SET status = ? WHERE id = ?', {'finished', sessionId})
        
        -- 最終結果発表（スポンサー情報含む）
        BroadcastFinalResults(sessionId)
        
        SetTimeout(300000, function()
            ActiveSessions[sessionId] = nil
        end)
    end
end)

-- (FormatMoney はヘルパー関数セクションで定義済み)

-- 最終結果発表
function BroadcastFinalResults(sessionId)
    local session = ActiveSessions[sessionId]
    if not session then return end
    
    -- 順位順にソート
    local results = {}
    for _, participant in ipairs(session.participants) do
        if participant.status == 'finished' then
            table.insert(results, participant)
        end
    end
    
    table.sort(results, function(a, b)
        return (a.position or 999) < (b.position or 999)
    end)
    
    -- 結果サマリー
    local summary = '🏁 最終結果\n\n'
    for i, participant in ipairs(results) do
        local medals = {'🥇', '🥈', '🥉'}
        local medal = medals[i] or (i .. '位')
        local time = participant.finishTime and string.format("%.2f秒", participant.finishTime / 1000) or 'DNF'
        summary = summary .. string.format('%s %s - %s\n', medal, participant.driverName, time)
    end
    
    if session.isBetMode and session.prizePool > 0 then
        summary = summary .. string.format('\n💰 総賞金プール: $%d', session.prizePool)
    end
    
    -- 全参加者に送信
    for _, participant in ipairs(session.participants) do
        TriggerClientEvent('ox_lib:notify', participant.source, {
            title = 'レース終了',
            description = summary,
            type = 'inform',
            duration = 15000
        })
    end
end

-- ソロレース完了処理

RegisterNetEvent('qbx_racing:server:finishRace', function(raceId, timeMs, vehicleModel)
    local src = source
    local Player = GetPlayer(src)
    if not Player then return end
    
    local profile = GetDriverProfile(Player.PlayerData.citizenid)
    if not profile then return end
    
    -- タイム記録のみ
    MySQL.insert.await([[
        INSERT INTO qbx_race_times (race_id, driver_name, citizenid, time_ms, vehicle_model) 
        VALUES (?, ?, ?, ?, ?)
    ]], {raceId, profile.driver_name, Player.PlayerData.citizenid, timeMs, vehicleModel})
    
    -- 統計更新
    if GetConfigValue('Race.updateStats', true) then
        MySQL.query.await('UPDATE qbx_driver_profiles SET total_races = total_races + 1 WHERE citizenid = ?', {Player.PlayerData.citizenid})
    end
    
    -- 通知（報酬なし）
    local timeFormatted = string.format("%.2f秒", timeMs / 1000)
    TriggerClientEvent('ox_lib:notify', src, {
        title = 'タイム記録完了',
        description = timeFormatted .. '（練習モード - 報酬なし）',
        type = 'inform'
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
        print(string.format('[QBX Racing] レース削除: ID=%d, Name=%s, 実行者=%s', raceId, race.name, tostring(source)))
        
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
    
    for i, participant in ipairs(session.participants) do
        if participant.source == src then
            -- 参加費の返金（ロビー状態の場合のみ）
            if session.status == 'lobby' and session.isBetMode and participant.entryPaid then
                local Player = GetPlayer(src)
                if Player and session.entryFee > 0 then
                    local currency = GetConfigValue('Race.currency', 'cash')
                    Player.Functions.AddMoney(currency, session.entryFee, 'race-entry-refund')
                    session.prizePool = session.prizePool - session.entryFee
                    MySQL.update.await('UPDATE qbx_race_sessions SET prize_pool = ? WHERE id = ?', {session.prizePool, sessionId})
                    
                    TriggerClientEvent('ox_lib:notify', src, {
                        title = '返金',
                        description = string.format('参加費$%sを返金しました', FormatMoney(session.entryFee)),
                        type = 'success'
                    })
                end
            end
            
            table.remove(session.participants, i)
            
            -- DB更新
            MySQL.update.await([[
                DELETE FROM qbx_session_participants 
                WHERE session_id = ? AND citizenid = (
                    SELECT citizenid FROM qbx_driver_profiles WHERE driver_name = ?
                )
            ]], {sessionId, participant.driverName})
            
            -- 主催者が離脱した場合 → セッションキャンセル＋スポンサー返金
            if session.host == src then
                session.status = 'cancelled'
                MySQL.update.await('UPDATE qbx_race_sessions SET status = ? WHERE id = ?', {'cancelled', sessionId})
                
                -- スポンサー金返金
                if session.sponsorAmount and session.sponsorAmount > 0 then
                    local hostPlayer = GetPlayer(src)
                    if hostPlayer then
                        local currency = GetConfigValue('Race.currency', 'cash')
                        hostPlayer.Functions.AddMoney(currency, session.sponsorAmount, 'race-sponsor-refund')
                        TriggerClientEvent('ox_lib:notify', src, {
                            title = '返金',
                            description = string.format('スポンサー金$%sを返金しました', FormatMoney(session.sponsorAmount)),
                            type = 'success'
                        })
                    end
                end
                
                -- 残りの参加者に参加費返金＋通知
                for _, p in ipairs(session.participants) do
                    if session.isBetMode and p.entryPaid and session.entryFee > 0 then
                        local pPlayer = GetPlayer(p.source)
                        if pPlayer then
                            local currency = GetConfigValue('Race.currency', 'cash')
                            pPlayer.Functions.AddMoney(currency, session.entryFee, 'race-entry-refund')
                        end
                    end
                    
                    TriggerClientEvent('qbx_racing:client:sessionCancelled', p.source, {
                        sessionId = sessionId,
                        reason = '主催者が退出しました'
                    })
                    TriggerClientEvent('ox_lib:notify', p.source, {
                        title = 'セッション終了',
                        description = '主催者が退出したため、セッションが終了しました（参加費は返金済み）',
                        type = 'error'
                    })
                end
                
                ActiveSessions[sessionId] = nil
            else
                BroadcastSessionUpdate(sessionId)
                
                TriggerClientEvent('ox_lib:notify', src, {
                    title = 'セッション退出',
                    description = 'セッションから退出しました',
                    type = 'inform'
                })
            end
            break
        end
    end
end)

-- ===================================
-- セッションタイムアウト管理
-- ===================================
function StartSessionTimeoutThread()
    CreateThread(function()
        local checkInterval = 60000 -- 1分ごとにチェック
        local sessionTimeout = Config.Multiplayer and Config.Multiplayer.sessionTimeout or 600
        
        while true do
            Wait(checkInterval)
            
            local currentTime = os.time()
            local sessionsToCancel = {}
            
            for sessionId, session in pairs(ActiveSessions) do
                if session.status == 'lobby' and session.createdAt then
                    local elapsed = currentTime - session.createdAt
                    if elapsed >= sessionTimeout then
                        table.insert(sessionsToCancel, sessionId)
                    end
                end
            end
            
            for _, sessionId in ipairs(sessionsToCancel) do
                local session = ActiveSessions[sessionId]
                if session then
                    session.status = 'cancelled'
                    MySQL.update.await('UPDATE qbx_race_sessions SET status = ? WHERE id = ?', {'cancelled', sessionId})
                    
                    -- 参加者に返金＋通知
                    for _, p in ipairs(session.participants) do
                        if session.isBetMode and p.entryPaid and session.entryFee > 0 then
                            local pPlayer = GetPlayer(p.source)
                            if pPlayer then
                                local currency = GetConfigValue('Race.currency', 'cash')
                                pPlayer.Functions.AddMoney(currency, session.entryFee, 'race-timeout-refund')
                            end
                        end
                        
                        TriggerClientEvent('qbx_racing:client:sessionCancelled', p.source, {
                            sessionId = sessionId,
                            reason = 'セッションがタイムアウトしました'
                        })
                        TriggerClientEvent('ox_lib:notify', p.source, {
                            title = 'セッションタイムアウト',
                            description = '一定時間開始されなかったため、セッションが終了しました（参加費は返金済み）',
                            type = 'error'
                        })
                    end
                    
                    -- スポンサー返金
                    if session.sponsorAmount and session.sponsorAmount > 0 and session.host then
                        local hostPlayer = GetPlayer(session.host)
                        if hostPlayer then
                            local currency = GetConfigValue('Race.currency', 'cash')
                            hostPlayer.Functions.AddMoney(currency, session.sponsorAmount, 'race-sponsor-timeout-refund')
                        end
                    end
                    
                    print(string.format('[QBX Racing] セッションタイムアウト: ID=%d (%d秒経過)', sessionId, sessionTimeout))
                    ActiveSessions[sessionId] = nil
                end
            end
        end
    end)
end

-- ===================================
-- 初期化とクリーンアップ
-- ===================================

-- リソース起動時
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    print('^2[QBX Racing]^7 サーバーサイド起動完了')
    print('^2[QBX Racing]^7 マルチプレイヤーシステム: ' .. 
          (Config.Multiplayer and Config.Multiplayer.enabled and '有効' or '無効'))
    
    -- 既存のセッションクリーンアップ
    MySQL.update.await("UPDATE qbx_race_sessions SET status = 'cancelled' WHERE status IN ('lobby', 'countdown', 'racing')")
    ActiveSessions = {}
    
    -- セッションタイムアウト管理スレッド開始
    StartSessionTimeoutThread()
end)

-- リソース停止時
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    -- アクティブセッションを終了状態に更新
    for sessionId, _ in pairs(ActiveSessions) do
        MySQL.update.await('UPDATE qbx_race_sessions SET status = ? WHERE id = ?', {'cancelled', sessionId})
    end
    
    print('^1[QBX Racing]^7 サーバーサイド停止完了')
end)

-- プレイヤー切断時のクリーンアップ
AddEventHandler('playerDropped', function(reason)
    local src = source
    
    -- アクティブセッションから削除
    for sessionId, session in pairs(ActiveSessions) do
        for i, participant in ipairs(session.participants) do
            if participant.source == src then
                -- ロビー中の参加費返金は不要（切断なので送金先がない）
                table.remove(session.participants, i)
                
                -- 主催者が切断した場合はセッション終了
                if session.host == src then
                    session.status = 'cancelled'
                    MySQL.update.await('UPDATE qbx_race_sessions SET status = ? WHERE id = ?', {'cancelled', sessionId})
                    
                    -- 残りの参加者に参加費返金＋通知
                    for _, p in ipairs(session.participants) do
                        if session.isBetMode and p.entryPaid and session.entryFee > 0 then
                            local pPlayer = GetPlayer(p.source)
                            if pPlayer then
                                local currency = GetConfigValue('Race.currency', 'cash')
                                pPlayer.Functions.AddMoney(currency, session.entryFee, 'race-entry-refund-host-dropped')
                            end
                        end
                        
                        TriggerClientEvent('qbx_racing:client:sessionCancelled', p.source, {
                            sessionId = sessionId,
                            reason = '主催者が切断しました'
                        })
                        TriggerClientEvent('ox_lib:notify', p.source, {
                            title = 'セッション終了',
                            description = '主催者が切断したため、セッションが終了しました（参加費は返金済み）',
                            type = 'error'
                        })
                    end
                    
                    ActiveSessions[sessionId] = nil
                else
                    BroadcastSessionUpdate(sessionId)
                end
                break
            end
        end
    end
end)
