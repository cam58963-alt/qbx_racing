-- ===================================
-- CAM Racing System - Client Main
-- v4.2.0
-- ===================================
-- UI構成:
--   NUI HTML (html/) → メイン画面（レース一覧・詳細・ドライバー登録・ランキング）
--   ox_lib           → ダイアログ・コンテキストメニュー・HUD・通知
-- ===================================

-- ===================================
-- グローバル変数とステート管理
-- ===================================
local isUIOpen = false
local currentSession = nil
local isInSession = false
local sessionParticipants = {}
local isCreatingRace = false
local raceCreationData = nil
local isInCountdown = false
local sessionStatus = nil      -- 'lobby' | 'countdown' | 'racing'（サーバーの sessionUpdate で更新）
local lobbyIsHost = false
local lobbyRace = nil
local lobbyThreadSession = nil  -- ロビー自動更新スレッドの多重起動防止

-- デバッグモード
local DEBUG_MODE = GetConvar('qbx_racing_debug', 'false') == 'true'

-- ===================================
-- ユーティリティ関数
-- ===================================

-- 安全なConfig値取得
local function GetConfigValue(path, defaultValue)
    local keys = {}
    for key in string.gmatch(path, "[^%.]+") do
        table.insert(keys, key)
    end
    
    local current = Config
    for _, key in ipairs(keys) do
        -- false も設定値として扱う（nil のときだけ既定値）
        if type(current) == 'table' and current[key] ~= nil then
            current = current[key]
        else
            return defaultValue
        end
    end
    return current
end

-- デバッグログ出力
local function DebugLog(message)
    if DEBUG_MODE then
        print('^3[CAM Racing Debug]^7 ' .. tostring(message))
    end
end

-- 今乗っている車両の名前（サーバーでは取得できないのでクライアントから送る）
local function GetCurrentVehicleName()
    local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    if vehicle == 0 then return nil end
    return GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))
end

-- サーバーからの問い合わせ: 今乗っている車両のクラス（スタート時の車両チェック用）
lib.callback.register('qbx_racing:client:getVehicleInfo', function()
    local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    if vehicle == 0 then return nil end
    return {
        class = GetVehicleClass(vehicle),
        netId = NetworkGetNetworkIdFromEntity(vehicle)
    }
end)

-- レース中・スタート地点へ移動中・別セッション参加中はマルチプレイに参加できない
local function CanJoinMultiplayer()
    if isInSession and currentSession then
        lib.notify({title = 'エラー', description = '既に別のセッションに参加しています（/racelobby でロビーを開けます）', type = 'error'})
        return false
    end
    if IsRaceBusy and IsRaceBusy() then
        lib.notify({title = 'エラー', description = 'レース中（またはスタート地点へ移動中）はセッションに参加できません', type = 'error'})
        return false
    end
    return true
end

-- ===================================
-- 表示モード（全画面メニュー / タブレットアプリ）
-- ===================================
local tabletAppOpen = false

-- タブレットのアプリとして表示するか（タブレットのリソースが起動していなければ全画面メニュー）
-- （アプリの登録に失敗した場合は全画面メニューを使う。登録結果はサーバーが GlobalState で知らせる）
local function IsTabletMode()
    return GetConfigValue('UI.mode', 'standalone') == 'tablet'
        and GetResourceState(GetConfigValue('UI.tablet.resource', 'cam_tablet')) == 'started'
        and GlobalState[GetCurrentResourceName() .. ':tabletApp'] == true
end

local function GetTabletResource()
    return GetConfigValue('UI.tablet.resource', 'cam_tablet')
end

local function GetTabletAppId()
    return GetConfigValue('UI.tablet.app.id', 'racing')
end

-- タブレットのアプリが開いている/閉じたことを記録
AddEventHandler(GetTabletResource() .. ':client:appOpened', function(appId)
    if appId ~= GetTabletAppId() then return end
    tabletAppOpen = true
    
    -- 全画面メニューが残っていたら閉じる（タブレットが後から起動した場合など）
    if isUIOpen then
        isUIOpen = false
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'closeUI' })
    end
end)

AddEventHandler(GetTabletResource() .. ':client:appClosed', function(appId)
    if appId == GetTabletAppId() then tabletAppOpen = false end
end)

AddEventHandler(GetTabletResource() .. ':client:closed', function()
    tabletAppOpen = false
end)

-- 安全なNUIメッセージ送信（実際に開いているメニュー画面へ送る）
-- ※ タブレットが途中で起動・停止しても、開いた側の画面に届くようにモードではなく開閉状態で判断
local function SafeSendNUIMessage(data)
    if isUIOpen then
        SendNUIMessage(data)
        DebugLog('NUI Message sent: ' .. (data.action or 'unknown'))
    elseif tabletAppOpen and IsTabletMode() then
        exports[GetTabletResource()]:SendAppMessage(GetTabletAppId(), data)
        DebugLog('Tablet app message sent: ' .. (data.action or 'unknown'))
    end
end

-- メニュー画面を閉じる（レース開始・ダイアログ表示などゲーム画面に戻る時）
-- 全画面メニューとタブレットのうち、開いている方を閉じる
local function CloseMenuUI()
    if isUIOpen then
        isUIOpen = false
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'closeUI' })
    end
    
    -- タブレットはレーシングアプリを開いている時だけ閉じる
    -- （レース情報の取得中などに別のアプリへ切り替えていたら、そのアプリを邪魔しない）
    if tabletAppOpen and IsTabletMode() then
        local tablet = exports[GetTabletResource()]
        if tablet:IsOpen() then tablet:Close() end
    end
    tabletAppOpen = false
end

-- メニュー画面を開く
local isOpeningUI = false
local function OpenMenuUI()
    if isUIOpen or isOpeningUI then
        DebugLog('UI already open, ignoring')
        return
    end
    
    if IsTabletMode() then
        -- インストールしていないアプリはタブレットが開かないので、先に案内する
        lib.callback('qbx_racing:server:hasTabletApp', false, function(installed)
            if not installed then
                lib.notify({
                    title = GetConfigValue('UI.tablet.app.label', 'レーシング'),
                    description = ('タブレットの App Store から「%s」をインストールしてください'):format(
                        GetConfigValue('UI.tablet.app.label', 'レーシング')),
                    type = 'inform'
                })
                return
            end
            exports[GetTabletResource()]:OpenApp(GetTabletAppId())
        end)
        return
    end
    
    DebugLog('Opening racing UI...')
    
    isOpeningUI = true
    lib.callback('qbx_racing:getProfile', false, function(profileData)
        isOpeningUI = false
        if profileData then
            isUIOpen = true
            SetNuiFocus(true, true)
            
            SafeSendNUIMessage({
                action = 'openUI',
                hasProfile = profileData.hasProfile,
                driverName = profileData.driverName,
                isAdmin = profileData.isAdmin,
                isRacing = IsRaceBusy and IsRaceBusy() or false,
                racesPerPage = GetConfigValue('UI.racesPerPage', 12)
            })
            
            DebugLog('UI opened successfully')
        else
            lib.notify({
                title = 'エラー',
                description = 'プロフィールデータの取得に失敗しました',
                type = 'error'
            })
            DebugLog('Failed to get profile data')
        end
    end)
end

-- ===================================
-- セッション作成ダイアログ（スポンサー対応）
-- ===================================
function ShowSessionCreateDialog(race)
    if not CanJoinMultiplayer() then return end
    
    local bettingEnabled = GetConfigValue('Race.betting.enabled', true)
    local sponsorEnabled = GetConfigValue('Race.betting.sponsor.enabled', true) and 
                          GetConfigValue('Race.betting.sponsor.host.enabled', true)
    
    local inputFields = {
        {
            type = 'input',
            label = 'セッション名',
            description = 'セッションの名前（任意）',
            default = race.name .. ' - マルチプレイ',
            max = 100
        },
        {
            type = 'number',
            label = 'カウントダウン時間（秒）',
            description = 'レース開始前のカウントダウン',
            default = GetConfigValue('Multiplayer.defaultCountdown', 10),
            min = GetConfigValue('Multiplayer.minCountdown', 5),
            max = GetConfigValue('Multiplayer.maxCountdown', 30)
        }
    }
    
    if bettingEnabled then
        table.insert(inputFields, {
            type = 'checkbox',
            label = '掛け金モード',
            description = '参加費を徴収して賞金を配分（1位50% / 2位30% / 3位20%）',
            checked = false
        })
        
        table.insert(inputFields, {
            type = 'number',
            label = '参加費（$）',
            description = string.format('$%s～$%s（0で無料）', 
                FormatMoney(GetConfigValue('Race.betting.entryFee.min', 0)),
                FormatMoney(GetConfigValue('Race.betting.entryFee.max', 100000))),
            default = GetConfigValue('Race.betting.entryFee.default', 1000),
            min = GetConfigValue('Race.betting.entryFee.min', 0),
            max = GetConfigValue('Race.betting.entryFee.max', 100000),
            icon = 'dollar-sign'
        })
        
        if sponsorEnabled then
            table.insert(inputFields, {
                type = 'number',
                label = 'スポンサー金（$）',
                description = string.format([[
主催者が賞金プールに追加する金額
※参加費とは別に自腹で支払います
上限: $%s
                ]], FormatMoney(GetConfigValue('Race.betting.sponsor.host.max', 5000000))),
                default = GetConfigValue('Race.betting.sponsor.host.default', 0),
                min = GetConfigValue('Race.betting.sponsor.host.min', 0),
                max = GetConfigValue('Race.betting.sponsor.host.max', 5000000),
                icon = 'hand-holding-dollar'
            })
        end
    end
    
    local input = lib.inputDialog('新規セッション作成', inputFields)
    
    if input then
        local betMode = bettingEnabled and input[3] or false
        local entryFee = bettingEnabled and betMode and input[4] or 0
        local sponsorAmount = bettingEnabled and sponsorEnabled and betMode and input[5] or 0
        
        -- 高額スポンサーの確認ダイアログ
        if sponsorAmount >= GetConfigValue('Race.betting.sponsor.display.highlightBig', 100000) then
            local totalCost = entryFee + sponsorAmount
            local estimatedParticipants = 8  -- 予想参加者数
            local estimatedPool = (entryFee * estimatedParticipants) + sponsorAmount
            
            local alert = lib.alertDialog({
                header = '⚠️ 高額スポンサー確認',
                content = string.format([[
セッション名: %s
参加費: $%s
スポンサー金: $%s

あなたが支払う総額: $%s
予想賞金プール: $%s（%d人参加の場合）

予想配分:
🥇 1位: $%s (50%%)
🥈 2位: $%s (30%%)
🥉 3位: $%s (20%%)

※スポンサー金はキャンセル時に返金されます

本当に作成しますか？
                ]], input[1], 
                    FormatMoney(entryFee), 
                    FormatMoney(sponsorAmount), 
                    FormatMoney(totalCost),
                    FormatMoney(estimatedPool),
                    estimatedParticipants,
                    FormatMoney(math.floor(estimatedPool * 0.5)),
                    FormatMoney(math.floor(estimatedPool * 0.3)),
                    FormatMoney(math.floor(estimatedPool * 0.2))),
                centered = true,
                cancel = true,
                labels = {
                    confirm = '作成する',
                    cancel = 'キャンセル'
                }
            })
            
            if alert ~= 'confirm' then
                return
            end
        end
        
        local sessionData = {
            raceId = race.id,
            sessionName = input[1],
            countdownDuration = input[2],
            betMode = betMode,
            entryFee = entryFee,
            sponsorAmount = sponsorAmount,
            vehicleModel = GetCurrentVehicleName()
        }
        
        lib.callback('qbx_racing:server:createMultiSession', false, function(result)
            result = result or {success = false}
            if result.success then
                currentSession = result.sessionId
                isInSession = true
                sessionParticipants = result.participants or {}
                
                local message = ''
                if result.isBetMode then
                    if result.sponsorAmount > 0 then
                        message = string.format([[
💰 スポンサー付きレース作成完了！

参加費: $%s（あなたも支払い済み）
スポンサー: $%s（あなたが提供）
初期賞金プール: $%s

配分: 1位50%% / 2位30%% / 3位20%%
参加者が増えるほど賞金も増加！
                        ]], FormatMoney(result.entryFee), 
                            FormatMoney(result.sponsorAmount), 
                            FormatMoney(result.initialPrizePool))
                    else
                        message = string.format('参加費: $%s\n配分: 1位50%% / 2位30%% / 3位20%%', 
                            FormatMoney(result.entryFee))
                    end
                else
                    message = '無料レース - タイム計測のみ'
                end
                
                lib.notify({
                    title = 'セッション作成完了',
                    description = message,
                    type = 'success',
                    duration = 10000
                })
                
                ShowSessionLobby(result.sessionId, true, result.race)
            else
                lib.notify({
                    title = 'エラー',
                    description = result.message or 'セッション作成に失敗しました',
                    type = 'error'
                })
            end
        end, sessionData)
    end
end

-- ヘルプ関数: 金額フォーマット（クライアント用）
function FormatMoney(amount)
    if not amount or amount == 0 then return '0' end
    return tostring(amount):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

-- ===================================
-- アクティブセッション一覧（スポンサー情報強調）
-- ===================================
function ShowActiveSessionsList(race)
    lib.callback('qbx_racing:server:getActiveSessions', false, function(sessions)
        if not sessions or #sessions == 0 then
            lib.notify({
                title = '情報',
                description = '現在参加可能なセッションがありません',
                type = 'inform'
            })
            return
        end
        
        local options = {}
        
        for _, session in ipairs(sessions) do
            local description = string.format('主催: %s | 参加者: %d/%d', 
                session.hostName, session.participantCount, session.maxParticipants)
            
            local iconColor = '#10b981'
            local icon = 'fa-solid fa-users'
            local titlePrefix = ''
            
            if session.isBetMode then
                description = description .. string.format('\n💵 参加費: $%s', FormatMoney(session.entryFee or 0))
                
                -- スポンサー情報の表示
                if session.sponsorAmount and session.sponsorAmount > 0 then
                    description = description .. string.format('\n💎 スポンサー: $%s（by %s）', 
                        FormatMoney(session.sponsorAmount), session.sponsorName or '不明')
                end
                
                description = description .. string.format('\n💰 総賞金プール: $%s', 
                    FormatMoney(session.prizePool or 0))
                
                -- 賞金額に応じてアイコンと色を変更
                local prizePool = session.prizePool or 0
                if prizePool >= 1000000 then  -- 100万ドル以上
                    titlePrefix = '🔥 '
                    iconColor = '#dc2626'  -- 赤（超高額）
                    icon = 'fa-solid fa-fire'
                elseif prizePool >= 500000 then  -- 50万ドル以上
                    titlePrefix = '💎 '
                    iconColor = '#7c3aed'  -- 紫（高額）
                    icon = 'fa-solid fa-gem'
                elseif prizePool >= 100000 then  -- 10万ドル以上
                    titlePrefix = '⭐ '
                    iconColor = '#fbbf24'  -- 金（中額）
                    icon = 'fa-solid fa-trophy'
                elseif prizePool > 0 then
                    iconColor = '#10b981'  -- 緑（通常）
                    icon = 'fa-solid fa-dollar-sign'
                end
            else
                description = description .. '\n🆓 無料レース（練習）'
            end
            
            table.insert(options, {
                title = titlePrefix .. session.raceName,
                description = description,
                icon = icon,
                iconColor = iconColor,
                onSelect = function()
                    if session.isBetMode and session.entryFee > 0 then
                        ShowSessionJoinConfirmation(session, race)
                    else
                        JoinSession(session.sessionId, race)
                    end
                end
            })
        end
        
        lib.registerContext({
            id = 'qbx_racing_active_sessions',
            title = '参加可能なセッション',
            options = options
        })
        lib.showContext('qbx_racing_active_sessions')
    end)
end

-- セッション参加確認ダイアログ
function ShowSessionJoinConfirmation(session, race)
    local prizePool = session.prizePool or 0
    local entryFee = session.entryFee or 0
    
    -- 現在の配分計算
    local first = math.floor(prizePool * 0.5)
    local second = math.floor(prizePool * 0.3)
    local third = math.floor(prizePool * 0.2)
    
    -- 参加者が1人増えた場合の予想
    local newPool = prizePool + entryFee
    local newFirst = math.floor(newPool * 0.5)
    local newSecond = math.floor(newPool * 0.3)
    local newThird = math.floor(newPool * 0.2)
    
    local sponsorInfo = ''
    if session.sponsorAmount and session.sponsorAmount > 0 then
        sponsorInfo = string.format('\nスポンサー: $%s（by %s）', 
            FormatMoney(session.sponsorAmount), session.sponsorName or '不明')
    end
    
    local alert = lib.alertDialog({
        header = '💰 レース参加確認',
        content = string.format([[
レース: %s
主催者: %s%s

💵 参加費: $%s
💰 現在の賞金プール: $%s

現在の配分:
🥇 1位: $%s → $%s
🥈 2位: $%s → $%s  
🥉 3位: $%s → $%s
（→ は参加後の予想配分）

4位以下: 賞金なし（参加費没収）

参加しますか？
        ]], session.raceName, 
            session.hostName, 
            sponsorInfo,
            FormatMoney(entryFee),
            FormatMoney(prizePool),
            FormatMoney(first), FormatMoney(newFirst),
            FormatMoney(second), FormatMoney(newSecond),
            FormatMoney(third), FormatMoney(newThird)),
        centered = true,
        cancel = true,
        labels = {
            confirm = '参加する',
            cancel = 'キャンセル'
        }
    })
    
    if alert == 'confirm' then
        JoinSession(session.sessionId, race)
    end
end

-- ===================================
-- メインコマンド登録
-- ===================================
local menuCommand = GetConfigValue('UI.command', 'race')
RegisterCommand(menuCommand, function()
    -- タブレットモードで commandOpensApp = false の場合はコマンドを使わない
    -- （GetConfigValue は false を既定値に置き換えるため直接参照）
    local tabletConfig = Config.UI and Config.UI.tablet or {}
    if IsTabletMode() and tabletConfig.commandOpensApp == false then
        return
    end
    OpenMenuUI()
end)

-- キーバインド登録（オプション）
local keybind = GetConfigValue('UI.keybind', nil)
if keybind then
    RegisterKeyMapping(menuCommand, 'レースメニューを開く', 'keyboard', keybind)
end

-- ===================================
-- NUIコールバック: 基本操作
-- ===================================

-- タブレットのアプリの表示状態（画面側から通知）
-- タブレットは閉じてもアプリを残して、開き直すとそのまま再開する（その時は appOpened が来ない）ため、
-- 画面が表示されたことをアプリ自身から受け取って記録する
RegisterNUICallback('tabletAppVisible', function(data, cb)
    if IsTabletMode() then
        tabletAppOpen = data and data.visible == true or false
    end
    cb({})
end)

-- 画面の初期状態（タブレットのアプリが開いた時に取得）
RegisterNUICallback('getUIState', function(data, cb)
    lib.callback('qbx_racing:getProfile', false, function(profileData)
        if not profileData then
            cb({error = true})
            return
        end
        cb({
            hasProfile = profileData.hasProfile or false,
            driverName = profileData.driverName,
            isAdmin = profileData.isAdmin or false,
            isRacing = IsRaceBusy and IsRaceBusy() or false,
            racesPerPage = GetConfigValue('UI.racesPerPage', 12)
        })
    end)
end)

-- UI閉じる
RegisterNUICallback('closeUI', function(data, cb)
    isUIOpen = false
    SetNuiFocus(false, false)
    DebugLog('UI closed by user')
    cb({})
end)

-- レース一覧取得
RegisterNUICallback('getRaces', function(data, cb)
    DebugLog('Fetching races list...')
    lib.callback('qbx_racing:getRaces', false, function(races)
        cb(races or {})
        DebugLog('Races fetched: ' .. #(races or {}))
    end)
end)

-- ランキング取得
RegisterNUICallback('getLeaderboard', function(data, cb)
    if not data or not data.raceId then
        DebugLog('Invalid leaderboard request - missing raceId')
        cb({})
        return
    end
    
    DebugLog('Fetching leaderboard for race: ' .. data.raceId)
    lib.callback('qbx_racing:getLeaderboard', false, function(leaderboard)
        cb(leaderboard or {})
        DebugLog('Leaderboard fetched: ' .. #(leaderboard or {}) .. ' entries')
    end, data.raceId)
end)

-- ===================================
-- NUIコールバック: プロフィール管理
-- ===================================

-- ドライバー登録
RegisterNUICallback('registerDriver', function(data, cb)
    if not data or not data.driverName then
        cb({success = false, message = 'ドライバーネームが指定されていません'})
        return
    end
    
    DebugLog('Registering driver: ' .. data.driverName)
    lib.callback('qbx_racing:server:registerDriver', false, function(result)
        cb(result or {success = false, message = 'サーバーエラー'})
        if result and result.success then
            DebugLog('Driver registered successfully')
        end
    end, data)
end)

-- ドライバーネーム更新
RegisterNUICallback('updateDriverName', function(data, cb)
    if not data or not data.driverName then
        cb({success = false, message = 'ドライバーネームが指定されていません'})
        return
    end
    
    DebugLog('Updating driver name to: ' .. data.driverName)
    lib.callback('qbx_racing:server:updateDriverName', false, function(result)
        cb(result or {success = false, message = 'サーバーエラー'})
        if result and result.success then
            DebugLog('Driver name updated successfully')
        end
    end, data)
end)

-- ===================================
-- NUIコールバック: スタート地点ウェイポイント
-- ===================================
RegisterNUICallback('setStartWaypoint', function(data, cb)
    if not data or not data.raceId then
        cb({})
        return
    end
    
    DebugLog('Setting waypoint for race start: ' .. data.raceId)
    
    lib.callback('qbx_racing:getRaceDetails', false, function(race)
        if race and race.checkpoints and #race.checkpoints > 0 then
            local startCp = race.checkpoints[1]
            SetNewWaypoint(startCp.x, startCp.y)
            
            lib.notify({
                title = 'ウェイポイント設置',
                description = string.format('%s のスタート地点をマップに表示しました', race.name),
                type = 'success',
                duration = 3000
            })
            DebugLog('Waypoint set for race: ' .. race.name)
        else
            DebugLog('Failed to get race details for waypoint')
        end
    end, data.raceId)
    
    cb({})
end)

-- ===================================
-- NUIコールバック: レース中リタイア
-- ===================================
RegisterNUICallback('retireRace', function(data, cb)
    DebugLog('Cancel race button pressed from NUI')
    
    -- isMultiplayerRace は race_logic.lua でグローバル変数
    if isMultiplayerRace and RetireMultiplayerRace then
        RetireMultiplayerRace()
    elseif RetireSoloRace then
        RetireSoloRace()  -- スタート地点へ移動中・カウントダウン中の取り消しも含む
    end
    
    -- UIを閉じる
    CloseMenuUI()
    
    cb({})
end)

-- ===================================
-- NUIコールバック: ソロレース
-- ===================================

-- レース開始
RegisterNUICallback('startRace', function(data, cb)
    if not data or not data.raceId then
        cb({})
        return
    end
    
    DebugLog('Starting solo race: ' .. data.raceId)
    
    lib.callback('qbx_racing:getRaceDetails', false, function(race)
        if race then
            -- UIを閉じてレース開始
            CloseMenuUI()
            
            TriggerEvent('qbx_racing:client:startSoloRace', race)
            DebugLog('Solo race started successfully')
        else
            lib.notify({
                title = 'エラー',
                description = 'レース情報の取得に失敗しました',
                type = 'error'
            })
            DebugLog('Failed to get race details')
        end
    end, data.raceId)
    
    cb({})
end)

-- ===================================
-- NUIコールバック: マルチプレイヤー
-- ===================================

-- セッション参加
function JoinSession(sessionId, race)
    if not CanJoinMultiplayer() then return end
    
    DebugLog('Joining session: ' .. tostring(sessionId))
    
    lib.callback('qbx_racing:server:joinSession', false, function(result)
        if result and result.success then
            currentSession = sessionId
            isInSession = true
            sessionParticipants = result.participants or {}
            
            -- UIを閉じてロビー画面へ
            CloseMenuUI()
            
            local description = string.format('参加者: %d名', #sessionParticipants)
            if (result.entryFee or 0) > 0 then
                description = description .. string.format('\n参加費$%sを支払いました（賞金プール: $%s）',
                    FormatMoney(result.entryFee), FormatMoney(result.prizePool or 0))
            end
            lib.notify({
                title = 'セッション参加完了',
                description = description,
                type = 'success'
            })
            
            ShowSessionLobby(sessionId, false, race)
            DebugLog('Session joined successfully')
        else
            lib.notify({
                title = 'エラー',
                description = result and result.message or 'セッション参加に失敗しました',
                type = 'error'
            })
            DebugLog('Session join failed')
        end
    end, sessionId, GetCurrentVehicleName())
end

-- ===================================
-- NUIコールバック: レース削除
-- ===================================
RegisterNUICallback('deleteRace', function(data, cb)
    if not data or not data.raceId then
        cb({success = false, message = 'レースIDが指定されていません'})
        return
    end
    
    DebugLog('Deleting race: ' .. data.raceId)
    
    -- 確認ダイアログ表示
    -- NUI側で確認済みのため、直接サーバーに送信
    lib.callback('qbx_racing:server:deleteRace', false, function(result)
        cb(result or {success = false, message = 'サーバーエラー'})
        if result and result.success then
            DebugLog('Race deleted successfully')
        end
    end, data.raceId)
end)

-- ===================================
-- NUIコールバック: マルチセッション作成
-- ※NUI HTMLを閉じてからox_lib inputDialogに遷移する
-- ===================================
RegisterNUICallback('createSessionDialog', function(data, cb)
    if not data or not data.raceId then
        cb({})
        return
    end
    
    DebugLog('Opening session create dialog for race: ' .. data.raceId)
    
    -- UIを閉じる（NUI側で既に閉じ処理済みだが念のため）
    CloseMenuUI()
    
    -- レース情報を取得してセッション作成ダイアログを表示
    lib.callback('qbx_racing:getRaceDetails', false, function(race)
        if race then
            ShowSessionCreateDialog(race)
        else
            lib.notify({
                title = 'エラー',
                description = 'レース情報の取得に失敗しました',
                type = 'error'
            })
        end
    end, data.raceId)
    
    cb({})
end)

-- ===================================
-- NUIコールバック: セッション参加一覧
-- ※NUI HTMLを閉じてからox_lib contextMenuに遷移する
-- ===================================
RegisterNUICallback('joinSessionList', function(data, cb)
    if not data or not data.raceId then
        cb({})
        return
    end
    
    DebugLog('Opening session list for race: ' .. data.raceId)
    
    -- UIを閉じる
    CloseMenuUI()
    
    -- レース情報を取得してアクティブセッション一覧を表示
    lib.callback('qbx_racing:getRaceDetails', false, function(race)
        if race then
            ShowActiveSessionsList(race)
        else
            lib.notify({
                title = 'エラー',
                description = 'レース情報の取得に失敗しました',
                type = 'error'
            })
        end
    end, data.raceId)
    
    cb({})
end)

-- ===================================
-- NUIコールバック: レース作成
-- ===================================

-- レース作成開始
-- ※NUI HTMLを閉じてからox_lib inputDialogに遷移する
RegisterNUICallback('createRace', function(data, cb)
    DebugLog('Starting race creation flow')
    
    -- UIを閉じる
    CloseMenuUI()
    
    -- レース基本情報入力ダイアログ
    local input = lib.inputDialog('新規レース作成', {
        {
            type = 'input',
            label = 'レース名',
            description = '3-50文字で入力してください',
            required = true,
            min = 3,
            max = 50,
            icon = 'flag-checkered'
        },
        {
            type = 'input',
            label = '説明（任意）',
            description = 'レースの詳細説明',
            max = 200,
            icon = 'info-circle'
        },
        {
            type = 'select',
            label = '車両タイプ',
            description = '使用する車両の種類を選択',
            options = {
                {value = 'car', label = '🚗 自動車'},
                {value = 'heli', label = '🚁 ヘリコプター'},
                {value = 'boat', label = '⛵ ボート'}
            },
            required = true,
            icon = 'car'
        },
        {
            type = 'select',
            label = 'レースタイプ',
            description = 'レースの種類を選択',
            options = {
                {value = 'circuit', label = '🔄 周回レース'},
                {value = 'sprint', label = '🏁 スプリントレース'}
            },
            required = true,
            icon = 'flag'
        },
        {
            type = 'number',
            label = '周回数',
            description = '周回レースの場合のみ有効（1-10）',
            default = 1,
            min = 1,
            max = 10,
            icon = 'rotate'
        }
    })
    
    if input then
        -- 入力データを保存してチェックポイント設置モードを開始
        raceCreationData = {
            name = input[1],
            description = input[2] or '',
            vehicleType = input[3],
            raceType = input[4],
            laps = input[4] == 'sprint' and 1 or input[5]
        }
        
        DebugLog('Race creation data prepared: ' .. raceCreationData.name)
        TriggerEvent('qbx_racing:client:startCheckpointMode')
    else
        -- キャンセルされた場合はUIを再表示
        DebugLog('Race creation cancelled')
        OpenMenuUI()
    end
    
    cb({})
end)

-- ===================================
-- セッションロビーUI
-- ===================================
function ShowSessionLobby(sessionId, isHost, race)
    lobbyIsHost = isHost and true or false
    lobbyRace = race or lobbyRace
    if sessionStatus ~= 'countdown' and sessionStatus ~= 'racing' then
        sessionStatus = 'lobby'
    end
    
    local function refreshLobby()
        local options = {}
        
        -- 参加者リスト表示
        for i, participant in ipairs(sessionParticipants) do
            local hostLabel = participant.isHost and ' 👑' or ''
            local statusText = participant.status == 'entered' and '待機中' or participant.status
            
            table.insert(options, {
                title = participant.driverName .. hostLabel,
                description = string.format('車両: %s | ステータス: %s', 
                    participant.vehicleModel or '不明', statusText),
                icon = 'fa-solid fa-user',
                iconColor = participant.isHost and '#fbbf24' or '#3b82f6',
                readOnly = true
            })
        end
        
        -- 主催者のみレース開始ボタン
        if isHost then
            local minParticipants = GetConfigValue('Multiplayer.minParticipants', 2)
            table.insert(options, {
                title = 'レース開始',
                description = string.format('カウントダウンを開始（最低%d人必要）', minParticipants),
                icon = 'fa-solid fa-play',
                iconColor = '#10b981',
                onSelect = function()
                    DebugLog('Starting countdown for session: ' .. sessionId)
                    TriggerServerEvent('qbx_racing:server:startCountdown', sessionId)
                    -- 開始できなかった場合（人数不足など）はロビーを開き直す
                    SetTimeout(1500, function()
                        if isInSession and currentSession == sessionId and sessionStatus == 'lobby'
                            and not isInCountdown and not lib.getOpenContextMenu() then
                            refreshLobby()
                        end
                    end)
                end
            })
        end
        
        table.insert(options, {
            title = 'セッション退出',
            description = 'このセッションから退出する',
            icon = 'fa-solid fa-sign-out-alt',
            iconColor = '#ef4444',
            onSelect = function()
                -- サーバーに離脱通知（返金処理もサーバー側で実行）
                TriggerServerEvent('qbx_racing:server:leaveSession', sessionId)
                ResetSessionState()
                DebugLog('Left session: ' .. sessionId)
            end
        })
        
        lib.registerContext({
            id = 'qbx_racing_lobby',
            title = '🏁 セッションロビー',
            options = options
        })
        lib.showContext('qbx_racing_lobby')
    end
    
    refreshLobby()
    
    -- 自動更新スレッド（同じセッションで多重起動しない）
    if lobbyThreadSession == sessionId then return end
    lobbyThreadSession = sessionId
    CreateThread(function()
        while isInSession and currentSession == sessionId and sessionStatus == 'lobby' do
            Wait(1000)
            if lib.getOpenContextMenu() == 'qbx_racing_lobby' then
                refreshLobby()
            end
        end
        if lobbyThreadSession == sessionId then
            lobbyThreadSession = nil
        end
    end)
end

-- セッション状態をリセット
function ResetSessionState()
    isInSession = false
    currentSession = nil
    sessionParticipants = {}
    sessionStatus = nil
    lobbyIsHost = false
    lobbyRace = nil
end

-- ロビーを閉じてしまった時に開き直す
RegisterCommand('racelobby', function()
    if not isInSession or not currentSession then
        lib.notify({title = 'ロビー', description = '参加中のセッションはありません', type = 'inform'})
        return
    end
    if sessionStatus ~= 'lobby' then
        lib.notify({title = 'ロビー', description = 'レースは既に開始しています', type = 'inform'})
        return
    end
    ShowSessionLobby(currentSession, lobbyIsHost, lobbyRace)
end, false)

-- ===================================
-- チェックポイント設置モード
-- ===================================
RegisterNetEvent('qbx_racing:client:startCheckpointMode', function()
    if not raceCreationData then 
        DebugLog('No race creation data available')
        return 
    end
    
    isCreatingRace = true
    local checkpoints = {}
    local minCheckpoints = GetConfigValue('Checkpoint.minCheckpoints', 3)
    local checkpointRadius = GetConfigValue('Checkpoint.radius', 10.0)
    
    -- キーバインドをConfigから取得
    local keyPlace = GetConfigValue('UI.creationKeybinds.placeCheckpoint', 38)     -- E
    local keyFinish = GetConfigValue('UI.creationKeybinds.finishCreation', 45)      -- R
    local keyCancel = GetConfigValue('UI.creationKeybinds.cancelCreation', 200)     -- ESC
    local keyDelete = GetConfigValue('UI.creationKeybinds.deleteLastCheckpoint', 194) -- Backspace
    
    local turnGuides = {}
    local maxTurnGuides = GetConfigValue('Checkpoint.maxTurnGuides', 50)
    local vehicleType = raceCreationData.vehicleType or 'car'
    local keyTurnLeft = GetConfigValue('UI.creationKeybinds.placeTurnLeft', 174)         -- ←
    local keyTurnRight = GetConfigValue('UI.creationKeybinds.placeTurnRight', 175)       -- →
    local keyDeleteTurn = GetConfigValue('UI.creationKeybinds.deleteLastTurnGuide', 178) -- Delete
    local keyLongerTurn = GetConfigValue('UI.creationKeybinds.longerTurnGuide', 172)     -- ↑
    local keyShorterTurn = GetConfigValue('UI.creationKeybinds.shorterTurnGuide', 173)   -- ↓
    local maxSegments = GetConfigValue('Checkpoint.customMarker.turnGuide.maxSegments', 8)
    local isCircuit = raceCreationData.raceType ~= 'sprint'
    
    DebugLog('Starting checkpoint mode for: ' .. raceCreationData.name)
    
    -- 操作ガイドを左側に表示
    local function ShowCreationGuide()
        lib.showTextUI(
            '🏁 <b>レース作成モード</b>: ' .. raceCreationData.name .. '<br><br>'
            .. '[E] チェックポイント設置<br>'
            .. '[R] 作成完了（最低 ' .. minCheckpoints .. '個）<br>'
            .. '[ESC] 作成キャンセル<br>'
            .. '[Backspace] 最後のポイント削除<br><br>'
            .. '[←] [→] 今いる場所に曲がり角ガイド設置（左・右）<br>'
            .. '[↑] [↓] 最後のガイドを横に長く・短く<br>'
            .. '[Delete] 最後のガイド削除<br><br>'
            .. '設置済み: <b>' .. #checkpoints .. '個</b> / ガイド: <b>' .. #turnGuides .. '個</b>',
        {
            position = "left-center",
            icon = 'map-marked-alt',
            style = {
                borderRadius = 8,
                backgroundColor = 'rgba(26, 26, 46, 0.95)',
                color = '#ffffff',
                borderLeft = '4px solid #ef4444'
            }
        })
    end
    
    -- 3D位置にテキスト表示
    local function DrawLabel(x, y, z, text)
        local onScreen, screenX, screenY = World3dToScreen2d(x, y, z)
        if onScreen then
            SetTextScale(0.5, 0.5)
            SetTextFont(4)
            SetTextProportional(1)
            SetTextColour(255, 255, 255, 255)
            SetTextOutline()
            SetTextCentre(true)
            SetTextEntry("STRING")
            AddTextComponentString(text)
            DrawText(screenX, screenY)
        end
    end
    
    -- 曲がり角ガイドを今いる場所に設置（保存時に一番近いチェックポイントに紐づける）
    local function PlaceTurnGuide(coords, direction)
        if #turnGuides >= maxTurnGuides then
            lib.notify({
                title = 'エラー',
                description = string.format('曲がり角ガイドは最大 %d 個までです', maxTurnGuides),
                type = 'error'
            })
            return
        end
        
        table.insert(turnGuides, {
            x = coords.x,
            y = coords.y,
            z = coords.z,
            direction = direction,
            segments = 1
        })
        
        ShowCreationGuide()
        lib.notify({
            title = '曲がり角ガイド設置',
            description = string.format('%s曲がりの矢印を設置しました', direction == 'left' and '左' or '右'),
            type = 'success'
        })
        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
    end
    
    -- 最後に置いたガイドの長さ（並べる矢印の数）を変える
    local function ResizeLastTurnGuide(delta)
        local guide = turnGuides[#turnGuides]
        if not guide then return end
        
        local segments = math.max(1, math.min(maxSegments, guide.segments + delta))
        if segments == guide.segments then return end
        
        guide.segments = segments
        PlaySoundFrontend(-1, 'NAV_UP_DOWN', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
    end
    
    ShowCreationGuide()
    
    -- 作成モードのメインループ
    CreateThread(function()
        while isCreatingRace do
            Wait(0)
            
            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            
            -- 現在位置に設置予定マーカーを表示
            DrawMarker(
                1, -- 円柱型マーカー
                coords.x, coords.y, coords.z - 1.0,
                0.0, 0.0, 0.0,
                0.0, 0.0, 0.0,
                checkpointRadius * 2, checkpointRadius * 2, 3.0,
                255, 255, 0, 100, -- 黄色半透明
                false, false, 2, false, nil, nil, false
            )
            
            -- 設置済みチェックポイントを表示
            for i, cp in ipairs(checkpoints) do
                local isLatest = i == #checkpoints
                
                -- 自作マーカー（最新以外は薄く表示）、無効な場合は標準マーカー
                if not RaceMarkers.Draw('checkpoint', cp, isLatest and 1.0 or 0.6, vehicleType) then
                    local color = isLatest and {0, 255, 0} or {0, 150, 255}
                    
                    DrawMarker(
                        1,
                        cp.x, cp.y, cp.z - 1.0,
                        0.0, 0.0, 0.0,
                        0.0, 0.0, 0.0,
                        cp.radius * 2, cp.radius * 2, 3.0,
                        color[1], color[2], color[3], 200,
                        false, false, 2, false, nil, nil, false
                    )
                end
                
                -- チェックポイント番号表示
                DrawLabel(cp.x, cp.y, cp.z + 1.5, tostring(i))
            end
            
            -- 設置済み曲がり角ガイドを表示（どのCPに向かう時に出るかをラベル表示）
            for _, guide in ipairs(turnGuides) do
                local arrow = guide.direction == 'left' and '←' or '→'
                if guide.segments > 1 then
                    arrow = arrow .. '×' .. guide.segments
                end
                
                -- 長いガイドは紐づくCPへ近づく向きに対して横に並べる
                local nearest = RaceMarkers.FindNearestCheckpoint(checkpoints, guide)
                local axisX, axisY = nil, nil
                if nearest then
                    axisX, axisY = RaceMarkers.GetGuideAxis(checkpoints, nearest, isCircuit)
                end
                
                RaceMarkers.DrawTurnGuide({
                    kind = guide.direction == 'left' and 'turn_left' or 'turn_right',
                    x = guide.x,
                    y = guide.y,
                    z = guide.z,
                    segments = guide.segments,
                    axisX = axisX,
                    axisY = axisY
                }, vehicleType)
                DrawLabel(guide.x, guide.y, guide.z + 1.5, nearest and string.format('%s CP%d', arrow, nearest) or arrow)
            end
            
            -- E: チェックポイント設置
            if IsControlJustPressed(0, keyPlace) then -- E
                table.insert(checkpoints, {
                    x = coords.x,
                    y = coords.y,
                    z = coords.z,
                    radius = checkpointRadius
                })
                
                -- ガイド更新
                ShowCreationGuide()
                
                lib.notify({
                    title = 'チェックポイント設置',
                    description = string.format('チェックポイント %d を設置しました', #checkpoints),
                    type = 'success'
                })
                
                PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                DebugLog('Checkpoint placed: ' .. #checkpoints)
            end
            
            -- Backspace: 最後のポイント削除
            if IsControlJustPressed(0, keyDelete) and #checkpoints > 0 then -- Backspace
                table.remove(checkpoints)
                
                -- ガイド更新
                ShowCreationGuide()
                
                lib.notify({
                    title = 'チェックポイント削除',
                    description = '最後のチェックポイントを削除しました',
                    type = 'inform'
                })
                DebugLog('Checkpoint removed: ' .. #checkpoints)
            end
            
            -- ← / →: 曲がり角ガイド設置
            if IsControlJustPressed(0, keyTurnLeft) then
                PlaceTurnGuide(coords, 'left')
            elseif IsControlJustPressed(0, keyTurnRight) then
                PlaceTurnGuide(coords, 'right')
            end
            
            -- ↑ / ↓: 最後のガイドを横に長く・短く
            if IsControlJustPressed(0, keyLongerTurn) then
                ResizeLastTurnGuide(1)
            elseif IsControlJustPressed(0, keyShorterTurn) then
                ResizeLastTurnGuide(-1)
            end
            
            -- Delete: 最後の曲がり角ガイド削除
            if IsControlJustPressed(0, keyDeleteTurn) and #turnGuides > 0 then
                table.remove(turnGuides)
                ShowCreationGuide()
                
                lib.notify({
                    title = '曲がり角ガイド削除',
                    description = '最後のガイドを削除しました',
                    type = 'inform'
                })
            end
            
            -- R: 作成完了
            if IsControlJustPressed(0, keyFinish) then -- R
                if #checkpoints >= minCheckpoints then
                    -- 曲がり角ガイドを一番近いチェックポイントに紐づける
                    for _, guide in ipairs(turnGuides) do
                        guide.checkpoint = RaceMarkers.FindNearestCheckpoint(checkpoints, guide)
                    end
                    
                    -- サーバーにレース作成リクエスト送信
                    TriggerServerEvent('qbx_racing:server:createRace', {
                        name = raceCreationData.name,
                        description = raceCreationData.description,
                        vehicleType = raceCreationData.vehicleType,
                        raceType = raceCreationData.raceType,
                        laps = raceCreationData.laps,
                        checkpoints = checkpoints,
                        turnGuides = turnGuides
                    })
                    
                    -- 作成モード終了
                    isCreatingRace = false
                    raceCreationData = nil
                    lib.hideTextUI()
                    
                    lib.notify({
                        title = 'レース作成完了',
                        description = 'サーバーに送信しています...',
                        type = 'success'
                    })
                    DebugLog('Race creation completed with ' .. #checkpoints .. ' checkpoints')
                else
                    lib.notify({
                        title = 'エラー',
                        description = string.format('最低 %d 個のチェックポイントが必要です（現在: %d個）', 
                            minCheckpoints, #checkpoints),
                        type = 'error'
                    })
                end
            end
            
            -- ESC: 作成キャンセル（ポーズメニューを開かないようにして、確認してから中止）
            DisableControlAction(0, keyCancel, true)
            if IsDisabledControlJustPressed(0, keyCancel) then -- ESC
                local answer = lib.alertDialog({
                    header = 'レース作成を中止しますか？',
                    content = string.format('設置したチェックポイント %d 個は保存されません', #checkpoints),
                    centered = true,
                    cancel = true,
                    labels = { confirm = '中止する', cancel = '作成を続ける' }
                })
                
                if answer == 'confirm' and isCreatingRace then
                    isCreatingRace = false
                    raceCreationData = nil
                    lib.hideTextUI()
                    
                    lib.notify({
                        title = 'レース作成キャンセル',
                        description = '作成を中止しました',
                        type = 'inform'
                    })
                    DebugLog('Race creation cancelled')
                end
            end
        end
    end)
end)

-- ===================================
-- カウントダウン中の制限処理
-- ===================================
local countdownFrozenVehicles = {}

local function UnfreezeCountdownVehicles()
    for vehicle in pairs(countdownFrozenVehicles) do
        if DoesEntityExist(vehicle) then
            FreezeEntityPosition(vehicle, false)
        end
    end
    countdownFrozenVehicles = {}
end

function StartCountdownRestrictions(sessionId, startPoint, duration)
    isInCountdown = true
    local endTime = GetGameTimer() + (duration * 1000)
    -- 全員をスタート地点1点に戻すと車両が重なるため、カウントダウン開始時の各自の位置で固定する
    -- （スタート地点付近にいるかはサーバーが startAreaRadius で確認済み）
    local initialVehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    local lockCoords = initialVehicle ~= 0 and GetEntityCoords(initialVehicle)
        or vector3(startPoint.x, startPoint.y, startPoint.z)
    local lockHeading = initialVehicle ~= 0 and GetEntityHeading(initialVehicle) or nil
    local maxDistance = GetConfigValue('Multiplayer.countdownRestrictions.maxDistanceFromStart', 3.0)
    local showWarnings = GetConfigValue('Multiplayer.countdownRestrictions.showWarnings', true)
    local disableControls = GetConfigValue('Multiplayer.countdownRestrictions.disableControls', true)
    
    DebugLog('Starting countdown restrictions for session: ' .. sessionId)
    
    CreateThread(function()
        while isInCountdown and GetGameTimer() < endTime do
            local ped = PlayerPedId()
            local vehicle = GetVehiclePedIsIn(ped, false)
            
            if vehicle ~= 0 then
                -- 車両完全ロック
                FreezeEntityPosition(vehicle, true)
                countdownFrozenVehicles[vehicle] = true
                SetVehicleEngineOn(vehicle, true, true, false)
                
                -- 操作無効化
                if disableControls then
                    DisableControlAction(0, 71, true)  -- W
                    DisableControlAction(0, 72, true)  -- S
                    DisableControlAction(0, 63, true)  -- A
                    DisableControlAction(0, 64, true)  -- D
                    DisableControlAction(0, 75, true)  -- F（車両退出）
                end
                
                -- 固定位置から離れたら戻す
                local currentCoords = GetEntityCoords(vehicle)
                local distance = #(currentCoords - lockCoords)
                
                if distance > maxDistance then
                    SetEntityCoords(vehicle, lockCoords.x, lockCoords.y, lockCoords.z, false, false, false, true)
                    if lockHeading then
                        SetEntityHeading(vehicle, lockHeading)
                    end
                    
                    if showWarnings then
                        lib.notify({
                            title = '警告',
                            description = 'スタート地点に戻されました',
                            type = 'error',
                            duration = 2000
                        })
                    end
                end
            end
            
            Wait(0)
        end
        
        -- カウントダウン終了：ロック解除
        isInCountdown = false
        UnfreezeCountdownVehicles()
        
        DebugLog('Countdown restrictions ended')
    end)
end

-- ===================================
-- サーバーイベント受信
-- ===================================

-- セッション更新通知
RegisterNetEvent('qbx_racing:client:sessionUpdate', function(data)
    if data.sessionId == currentSession then
        sessionParticipants = data.participants or {}
        if data.status then
            sessionStatus = data.status
        end
        DebugLog('Session updated - participants: ' .. #sessionParticipants)
    end
end)

-- カウントダウン開始
RegisterNetEvent('qbx_racing:client:countdownStarted', function(data)
    if data.sessionId == currentSession then
        sessionStatus = 'countdown'
    end
    lib.hideContext()
    
    lib.notify({
        title = 'カウントダウン開始',
        description = string.format('%d秒後にスタートします', data.duration),
        type = 'inform',
        duration = 3000
    })
    
    -- カウントダウン中の制限開始
    StartCountdownRestrictions(data.sessionId, data.startPoint, data.duration)
end)

-- カウントダウンティック
RegisterNetEvent('qbx_racing:client:countdownTick', function(data)
    local countdown = data.countdown
    
    lib.showTextUI(
        '⏱️ <b>' .. countdown .. '</b>',
    {
        position = "top-center",
        icon = 'stopwatch',
        style = {
            borderRadius = 16,
            backgroundColor = countdown <= 3 and 'rgba(239, 68, 68, 0.95)' or 'rgba(251, 191, 36, 0.95)',
            color = 'white',
            fontSize = '48px',
            fontWeight = 'bold',
            padding = '32px'
        }
    })
    
    PlaySoundFrontend(-1, countdown == 1 and 'GO' or 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
    
    SetTimeout(800, function()
        lib.hideTextUI()
    end)
end)

-- マルチプレイヤーレース開始
RegisterNetEvent('qbx_racing:client:multiRaceStart', function(data)
    lib.hideTextUI()
    
    lib.showTextUI(
        '🏁 <b>GO!</b>',
    {
        position = "top-center",
        icon = 'flag-checkered',
        style = {
            borderRadius = 16,
            backgroundColor = 'rgba(16, 185, 129, 0.95)',
            color = 'white',
            fontSize = '64px',
            fontWeight = 'bold',
            padding = '48px'
        }
    })
    
    PlaySoundFrontend(-1, 'GO', 'HUD_MINI_GAME_SOUNDSET', true)
    
    SetTimeout(2000, function()
        lib.hideTextUI()
    end)
    
    DebugLog('Multiplayer race started for session: ' .. data.sessionId)
    
    -- ロビー状態を終了（以降は race_logic.lua がレースを管理）
    isInCountdown = false
    ResetSessionState()
    
    -- マルチプレイヤーレース開始（race_logic.luaの関数を呼び出し）
    if StartMultiplayerRace then
        StartMultiplayerRace(data.race, data.sessionId, data.participants)
    else
        print('^1[CAM Racing]^7 エラー: StartMultiplayerRace関数が見つかりません（race_logic.luaを確認してください）')
    end
end)

-- セッションキャンセル通知（タイムアウト・主催者退出など）
RegisterNetEvent('qbx_racing:client:sessionCancelled', function(data)
    if data.sessionId == currentSession then
        -- ロビーメニューが開いていたら閉じる
        if lib.getOpenContextMenu() == 'qbx_racing_lobby' then
            lib.hideContext()
        end
        
        isInCountdown = false
        ResetSessionState()
        
        lib.notify({
            title = 'セッション終了',
            description = data.reason or 'セッションがキャンセルされました',
            type = 'error',
            duration = 8000
        })
        DebugLog('Session cancelled: ' .. tostring(data.sessionId) .. ' - ' .. (data.reason or ''))
    end
end)

-- 参加者完了通知
RegisterNetEvent('qbx_racing:client:participantFinished', function(data)
    local medals = {'🥇', '🥈', '🥉'}
    local medal = medals[data.position] or '🏁'
    
    lib.notify({
        title = string.format('%s %d位ゴール', medal, data.position),
        description = string.format('%s: %s', data.finisher, data.timeFormatted),
        type = data.position <= 3 and 'success' or 'inform',
        duration = 6000
    })
end)

-- レース一覧更新通知
RegisterNetEvent('qbx_racing:client:refreshRaces', function()
    SafeSendNUIMessage({
        action = 'updateRaces'
    })
end)

RegisterNetEvent('qbx_racing:client:updateRaces', function()
    SafeSendNUIMessage({
        action = 'updateRaces'
    })
end)

-- ソロレース開始
RegisterNetEvent('qbx_racing:client:startSoloRace', function(race)
    if not race then 
        DebugLog('No race data provided for solo race')
        return 
    end
    
    DebugLog('Starting solo race: ' .. race.name)
    
    -- race_logic.luaの関数を呼び出し
    if StartRace then
        StartRace(race)
    else
        print('^1[CAM Racing]^7 エラー: StartRace関数が見つかりません（race_logic.luaを確認してください）')
    end
end)

-- ===================================
-- リソース停止時のクリーンアップ
-- ===================================
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    
    -- UI関連クリーンアップ
    if isUIOpen then
        SetNuiFocus(false, false)
    end
    
    if isCreatingRace then
        lib.hideTextUI()
    end
    
    if isInCountdown then
        lib.hideTextUI()
    end
    UnfreezeCountdownVehicles()
    
    -- セッション関連クリーンアップ
    isInSession = false
    currentSession = nil
    sessionParticipants = {}
    isCreatingRace = false
    raceCreationData = nil
    isInCountdown = false
    
    print('^2[CAM Racing]^7 クライアントメイン停止完了')
end)

-- ===================================
-- 初期化とエラーハンドリング
-- ===================================
CreateThread(function()
    -- Config検証
    if not Config then
        print('^1[CAM Racing]^7 警告: Config.luaが読み込まれていません')
    end
    
    print('^2[CAM Racing]^7 クライアントメイン起動完了')
    
    if DEBUG_MODE then
        print('^3[CAM Racing]^7 デバッグモードが有効です')
    end
end)

-- グローバルエラーハンドラー
CreateThread(function()
    while true do
        Wait(5000) -- 5秒ごとにチェック
        
        -- UIの整合性チェック（ポーズメニュー中にUIが開いていたら閉じる）
        if isUIOpen and IsPauseMenuActive() then
            DebugLog('UI state mismatch detected (pause menu active) - correcting')
            CloseMenuUI()
        end
        
        -- セッション状態チェック
        if isInSession and not currentSession then
            DebugLog('Session state mismatch detected - resetting')
            isInSession = false
            sessionParticipants = {}
        end
    end
end)
