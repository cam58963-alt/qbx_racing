-- ===================================
-- QBX Racing System - Client Race Logic
-- 完全統合版 v4.2.0
-- レース進行・ゴーストモード・チェックポイント管理・視覚効果
-- ===================================

-- ===================================
-- グローバル変数とステート管理
-- ===================================

-- レース状態（グローバルスコープ：main.luaからアクセス可能）
isRacing = false
isMultiplayerRace = false
local currentRace = nil
local raceStartTime = 0
local currentCheckpoint = 1
local currentLap = 1
local raceCheckpoints = {}

-- マルチプレイヤー関連
local multiplayerSessionId = nil
local ghostPlayers = {}
local progressData = {}

-- ゴーストモード管理
local isGhostModeActive = false
local ghostedEntities = {}
local entityCache = {
    vehicles = {},
    lastUpdate = 0,
    updateInterval = 500,
    maxCacheSize = 100
}

-- オブジェクト・視覚効果管理
local raceObjects = {}
local raceBlips = {}
local activeCheckpointEntities = {}  -- CreateCheckpointで生成したエンティティ管理

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
        if current and current[key] then
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
        print('^3[QBX Racing Logic]^7 ' .. tostring(message))
    end
end

-- テーブル長取得
local function GetTableLength(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

-- 時間フォーマット
local function FormatTime(ms)
    return string.format("%.2f", ms / 1000)
end

-- ===================================
-- レース装飾オブジェクト管理
-- ===================================

-- ローカルオブジェクト生成
local function SpawnLocalObject(model, coords, rotation)
    local hash = type(model) == 'string' and joaat(model) or model
    
    -- モデル読み込み
    if not HasModelLoaded(hash) then
        RequestModel(hash)
        local timeout = 0
        while not HasModelLoaded(hash) and timeout < 5000 do
            Wait(10)
            timeout = timeout + 10
        end
        
        if not HasModelLoaded(hash) then
            DebugLog('Failed to load model: ' .. tostring(model))
            return nil
        end
    end
    
    -- ローカルオブジェクト作成（参加者のみに表示）
    local obj = CreateObject(hash, coords.x, coords.y, coords.z, false, false, false)
    
    if not DoesEntityExist(obj) then
        DebugLog('Failed to create object: ' .. tostring(model))
        return nil
    end
    
    if rotation then
        SetEntityRotation(obj, rotation.x, rotation.y, rotation.z, 2, true)
    end
    
    -- 地面に配置・固定
    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    
    table.insert(raceObjects, obj)
    return obj
end

-- レース装飾オブジェクト生成
function CreateRaceDecorations(checkpoints)
    if not GetConfigValue('RaceObjects.enabled', false) then 
        DebugLog('Race objects disabled in config')
        return 
    end
    
    -- 既存オブジェクトクリア
    ClearRaceObjects()
    
    DebugLog('Creating race decorations for ' .. #checkpoints .. ' checkpoints')
    
    for i, cp in ipairs(checkpoints) do
        local cpCoords = vector3(cp.x, cp.y, cp.z)
        
        -- 最後のチェックポイント（ゴール）
        if i == #checkpoints then
            local finishConfig = GetConfigValue('RaceObjects.finish', {
                model = 'prop_beach_flag_01',
                offset = vector3(0.0, 0.0, 0.0),
                rotation = vector3(0.0, 0.0, 0.0)
            })
            if finishConfig.model then
                local finishPos = cpCoords + finishConfig.offset
                SpawnLocalObject(finishConfig.model, finishPos, finishConfig.rotation)
            end
        else
            -- 通常のチェックポイント装飾
            local checkpointConfig = GetConfigValue('RaceObjects.checkpoint', {
                model = 'prop_offroad_tyres02',
                offset = vector3(3.0, 0.0, -0.5),
                rotation = vector3(0.0, 0.0, 0.0)
            })
            if checkpointConfig.model then
                local objPos = cpCoords + checkpointConfig.offset
                SpawnLocalObject(checkpointConfig.model, objPos, checkpointConfig.rotation)
            end
        end
        
        -- 方向指示矢印（次のチェックポイントがある場合）
        if i < #checkpoints then
            local arrowConfig = GetConfigValue('RaceObjects.arrow', {
                model = 'prop_arrow_direction_yellow',
                offset = vector3(-5.0, 0.0, 1.0),
                rotation = vector3(0.0, 0.0, 0.0)
            })
            if arrowConfig and arrowConfig.model then
                local nextCp = checkpoints[i + 1]
                local direction = GetHeadingFromVector_2d(
                    nextCp.x - cp.x, 
                    nextCp.y - cp.y
                )
                
                local arrowPos = cpCoords + arrowConfig.offset
                local arrowRot = vector3(0.0, 0.0, direction)
                
                SpawnLocalObject(arrowConfig.model, arrowPos, arrowRot)
            end
        end
    end
    
    DebugLog('Race decorations created: ' .. #raceObjects .. ' objects')
end

-- オブジェクトクリア
function ClearRaceObjects()
    for _, obj in ipairs(raceObjects) do
        if DoesEntityExist(obj) then
            DeleteEntity(obj)
        end
    end
    raceObjects = {}
    DebugLog('Race objects cleared')
end

-- ===================================
-- ブリップ管理システム
-- ===================================

-- レース用ブリップ生成
local function CreateRaceBlips(checkpoints)
    ClearRaceBlips()
    
    for i, cp in ipairs(checkpoints) do
        local blip = AddBlipForCoord(cp.x, cp.y, cp.z)
        SetBlipSprite(blip, 1)
        SetBlipDisplay(blip, 4)
        SetBlipScale(blip, 0.7)
        SetBlipColour(blip, i == #checkpoints and 38 or 5) -- ゴールはオレンジ、他は黄色
        SetBlipAsShortRange(blip, true)
        ShowNumberOnBlip(blip, i)
        
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString("CP " .. i)
        EndTextCommandSetBlipName(blip)
        
        table.insert(raceBlips, blip)
    end
    
    DebugLog('Created ' .. #raceBlips .. ' race blips')
end

-- ブリップクリア
function ClearRaceBlips()
    for _, blip in ipairs(raceBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
    raceBlips = {}
    DebugLog('Cleared race blips')
end

-- ===================================
-- ゴーストモードシステム（完全版）
-- ===================================

-- レース参加者の車両か判定
function IsVehicleOwnedByRacer(vehicle)
    for _, participantSource in ipairs(ghostPlayers) do
        if participantSource ~= GetPlayerServerId(PlayerId()) then
            local otherPlayer = GetPlayerFromServerId(participantSource)
            if otherPlayer ~= -1 then
                local otherPed = GetPlayerPed(otherPlayer)
                if otherPed ~= 0 and GetVehiclePedIsIn(otherPed, false) == vehicle then
                    return true
                end
            end
        end
    end
    return false
end

-- 視覚効果適用
function ApplyGhostVisualEffect(vehicle, isRacer)
    local config = GetConfigValue('Multiplayer.ghostMode.visual', {
        racerAlpha = 180,
        nonRacerAlpha = 255,
        applyToRacers = true,
        applyToNonRacers = false
    })
    
    if isRacer and config.applyToRacers then
        SetEntityAlpha(vehicle, config.racerAlpha, false)
    elseif not isRacer and config.applyToNonRacers then
        SetEntityAlpha(vehicle, config.nonRacerAlpha, false)
    else
        ResetEntityAlpha(vehicle)
    end
end

-- 基本版ゴーストモード
function StartGhostMode()
    if not GetConfigValue('Multiplayer.ghostMode.enabled', true) then 
        DebugLog('Ghost mode disabled in config')
        return 
    end
    
    isGhostModeActive = true
    DebugLog('Ghost mode started (basic version)')
    
    CreateThread(function()
        local updateInterval = GetConfigValue('Multiplayer.ghostMode.updateInterval', 0)
        local collisionRadius = GetConfigValue('Multiplayer.ghostMode.collisionRadius', 150.0)
        
        while isRacing and isMultiplayerRace and isGhostModeActive do
            local playerPed = PlayerPedId()
            local playerVehicle = GetVehiclePedIsIn(playerPed, false)
            
            if playerVehicle ~= 0 then
                local playerCoords = GetEntityCoords(playerVehicle)
                
                -- 全車両を取得（NPC車両含む）
                local vehicles = GetGamePool('CVehicle')
                
                for _, otherVehicle in ipairs(vehicles) do
                    if otherVehicle ~= playerVehicle and DoesEntityExist(otherVehicle) then
                        local otherCoords = GetEntityCoords(otherVehicle)
                        local distance = #(playerCoords - otherCoords)
                        
                        -- 設定範囲内の車両に対して処理
                        if distance <= collisionRadius then
                            -- レース参加者かどうか判定
                            local isRacerVehicle = IsVehicleOwnedByRacer(otherVehicle)
                            
                            -- 衝突無効化（一方向：自分が相手をすり抜ける）
                            SetEntityNoCollisionEntity(playerVehicle, otherVehicle, true)
                            
                            -- レース参加者同士なら双方向
                            if isRacerVehicle then
                                SetEntityNoCollisionEntity(otherVehicle, playerVehicle, true)
                            end
                            
                            -- 視覚効果
                            ApplyGhostVisualEffect(otherVehicle, isRacerVehicle)
                        end
                    end
                end
            end
            
            Wait(updateInterval)
        end
        
        ResetGhostMode()
    end)
end

-- キャッシュ付き近隣車両取得（最適化版用）
function GetNearbyVehiclesCached(playerCoords)
    local currentTime = GetGameTimer()
    
    -- キャッシュが有効かチェック
    if currentTime - entityCache.lastUpdate < entityCache.updateInterval then
        return entityCache.vehicles
    end
    
    -- 新しいキャッシュを構築
    local vehicles = {}
    local radius = GetConfigValue('Multiplayer.ghostMode.collisionRadius', 150.0)
    
    local handle, vehicle = FindFirstVehicle()
    local success = true
    
    while success and #vehicles < entityCache.maxCacheSize do
        if DoesEntityExist(vehicle) then
            local vehicleCoords = GetEntityCoords(vehicle)
            local distance = #(playerCoords - vehicleCoords)
            
            if distance <= radius then
                table.insert(vehicles, {
                    entity = vehicle,
                    distance = distance,
                    coords = vehicleCoords,
                    isRacer = IsVehicleOwnedByRacer(vehicle)
                })
            end
        end
        
        success, vehicle = FindNextVehicle(handle)
    end
    
    EndFindVehicle(handle)
    
    -- キャッシュ更新
    entityCache.vehicles = vehicles
    entityCache.lastUpdate = currentTime
    
    return vehicles
end

-- 車両ゴースト化処理（最適化版用）
function ProcessVehicleGhosting(playerVehicle, otherVehicle, distance, isRacerVehicle)
    -- 衝突無効化
    SetEntityNoCollisionEntity(playerVehicle, otherVehicle, true)
    
    -- レース参加者同士なら双方向
    if isRacerVehicle then
        SetEntityNoCollisionEntity(otherVehicle, playerVehicle, true)
    end
    
    -- 視覚効果
    ApplyGhostVisualEffect(otherVehicle, isRacerVehicle)
    
    -- 追跡リストに追加
    ghostedEntities[otherVehicle] = {
        type = isRacerVehicle and 'racer' or 'civilian',
        lastUpdate = GetGameTimer(),
        distance = distance
    }
end

-- 遠くのゴーストエンティティをクリーンアップ
function CleanupDistantGhosts(playerCoords)
    local currentTime = GetGameTimer()
    local maxDistance = GetConfigValue('Multiplayer.ghostMode.collisionRadius', 150.0)
    
    for entity, data in pairs(ghostedEntities) do
        if not DoesEntityExist(entity) then
            ghostedEntities[entity] = nil
        else
            local entityCoords = GetEntityCoords(entity)
            local distance = #(playerCoords - entityCoords)
            
            -- 範囲外または古いエンティティをリセット
            if distance > maxDistance or (currentTime - data.lastUpdate) > 5000 then
                ResetEntityAlpha(entity)
                
                local playerVehicle = GetVehiclePedIsIn(PlayerPedId(), false)
                if playerVehicle ~= 0 then
                    SetEntityNoCollisionEntity(playerVehicle, entity, false)
                    SetEntityNoCollisionEntity(entity, playerVehicle, false)
                end
                
                ghostedEntities[entity] = nil
            end
        end
    end
end

-- 最適化版ゴーストモード
function StartGhostModeOptimized()
    if not GetConfigValue('Multiplayer.ghostMode.enabled', true) then 
        DebugLog('Ghost mode disabled in config')
        return 
    end
    
    isGhostModeActive = true
    ghostedEntities = {}
    DebugLog('Ghost mode started (optimized version)')
    
    CreateThread(function()
        local updateInterval = GetConfigValue('Multiplayer.ghostMode.updateInterval', 0)
        
        while isRacing and isMultiplayerRace and isGhostModeActive do
            local playerPed = PlayerPedId()
            local playerVehicle = GetVehiclePedIsIn(playerPed, false)
            
            if playerVehicle ~= 0 then
                local playerCoords = GetEntityCoords(playerVehicle)
                
                -- 既存のゴーストエンティティをクリーンアップ
                CleanupDistantGhosts(playerCoords)
                
                -- キャッシュ付き車両取得
                local nearbyVehicles = GetNearbyVehiclesCached(playerCoords)
                
                -- 新しい車両をゴースト化
                for _, vehicleData in ipairs(nearbyVehicles) do
                    local vehicle = vehicleData.entity
                    local distance = vehicleData.distance
                    local isRacer = vehicleData.isRacer
                    
                    if vehicle ~= playerVehicle and DoesEntityExist(vehicle) then
                        ProcessVehicleGhosting(playerVehicle, vehicle, distance, isRacer)
                    end
                end
            end
            
            Wait(updateInterval)
        end
        
        ResetGhostModeOptimized()
    end)
    
    -- デバッグ情報表示スレッド
    if GetConfigValue('Multiplayer.ghostMode.debugMode', false) then
        CreateThread(GhostModeDebugThread)
    end
end

-- デバッグ情報表示
function GhostModeDebugThread()
    CreateThread(function()
        while isGhostModeActive do
            if GetConfigValue('Multiplayer.ghostMode.showDebugInfo', false) then
                local debugText = string.format([[
~b~Ghost Mode Debug~w~
Racers: ~g~%d~w~
Ghosted: ~y~%d~w~
Cache: ~o~%d~w~ vehicles
Radius: ~p~%.0fm~w~
                ]], #ghostPlayers, GetTableLength(ghostedEntities), 
                    #entityCache.vehicles, GetConfigValue('Multiplayer.ghostMode.collisionRadius', 150.0))
                
                SetTextFont(0)
                SetTextProportional(1)
                SetTextScale(0.35, 0.35)
                SetTextColour(255, 255, 255, 255)
                SetTextOutline()
                SetTextEntry("STRING")
                AddTextComponentString(debugText)
                DrawText(0.01, 0.5)
            end
            
            Wait(100)
        end
    end)
end

-- ゴーストモードリセット（基本版）
function ResetGhostMode()
    isGhostModeActive = false
    
    -- 全車両の透明度と衝突をリセット
    local vehicles = GetGamePool('CVehicle')
    for _, vehicle in ipairs(vehicles) do
        if DoesEntityExist(vehicle) then
            ResetEntityAlpha(vehicle)
            
            local playerVehicle = GetVehiclePedIsIn(PlayerPedId(), false)
            if playerVehicle ~= 0 and vehicle ~= playerVehicle then
                SetEntityNoCollisionEntity(playerVehicle, vehicle, false)
                SetEntityNoCollisionEntity(vehicle, playerVehicle, false)
            end
        end
    end
    
    DebugLog('Ghost mode reset (basic version)')
end

-- ===================================
-- ソロレース用ゴーストモード（NPC衝突回避）
-- ===================================

-- ソロ用ゴーストモード開始
function StartSoloGhostMode()
    if not GetConfigValue('Multiplayer.ghostMode.soloEnabled', true) then 
        DebugLog('Solo ghost mode disabled in config')
        return 
    end
    
    isGhostModeActive = true
    DebugLog('Solo ghost mode started')
    
    CreateThread(function()
        local collisionRadius = GetConfigValue('Multiplayer.ghostMode.collisionRadius', 150.0)
        
        while isRacing and not isMultiplayerRace and isGhostModeActive do
            local playerPed = PlayerPedId()
            local playerVehicle = GetVehiclePedIsIn(playerPed, false)
            
            if playerVehicle ~= 0 then
                local playerCoords = GetEntityCoords(playerVehicle)
                
                -- 全NPC車両をゴースト化
                local vehicles = GetGamePool('CVehicle')
                
                for _, otherVehicle in ipairs(vehicles) do
                    if otherVehicle ~= playerVehicle and DoesEntityExist(otherVehicle) then
                        local otherCoords = GetEntityCoords(otherVehicle)
                        local distance = #(playerCoords - otherCoords)
                        
                        if distance <= collisionRadius then
                            -- NPC車両との衝突無効化
                            SetEntityNoCollisionEntity(playerVehicle, otherVehicle, true)
                            SetEntityNoCollisionEntity(otherVehicle, playerVehicle, true)
                            
                            -- NPC車両を半透明に
                            SetEntityAlpha(otherVehicle, 150, false)
                        end
                    end
                end
            end
            
            Wait(0)  -- 毎フレーム（衝突回避は即時性が重要）
        end
        
        ResetGhostMode()
    end)
end

-- ゴーストモードリセット（最適化版）
function ResetGhostModeOptimized()
    isGhostModeActive = false
    
    -- 追跡されたエンティティをリセット
    for entity, data in pairs(ghostedEntities) do
        if DoesEntityExist(entity) then
            ResetEntityAlpha(entity)
            
            local playerVehicle = GetVehiclePedIsIn(PlayerPedId(), false)
            if playerVehicle ~= 0 then
                SetEntityNoCollisionEntity(playerVehicle, entity, false)
                SetEntityNoCollisionEntity(entity, playerVehicle, false)
            end
        end
    end
    
    ghostedEntities = {}
    entityCache.vehicles = {}
    DebugLog('Ghost mode reset (optimized version)')
end

-- ===================================
-- ソロレース進行システム
-- ===================================

-- ソロレース開始
function StartRace(race)
    if isRacing then
        lib.notify({
            title = 'エラー',
            description = '既にレース中です',
            type = 'error'
        })
        return
    end
    
    -- 車両チェック
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    
    if vehicle == 0 then
        lib.notify({
            title = 'エラー',
            description = '車両に乗車してください',
            type = 'error'
        })
        return
    end
    
    -- 車両タイプチェック
    if not IsValidVehicleForRace(vehicle, race.vehicle_type) then
        lib.notify({
            title = 'エラー',
            description = 'このレースに適した車両ではありません',
            type = 'error'
        })
        return
    end
    
    currentRace = race
    raceCheckpoints = race.checkpoints or {}
    currentCheckpoint = 1
    currentLap = 1
    isRacing = false -- カウントダウン中はfalse
    isMultiplayerRace = false
    
    DebugLog('Starting solo race: ' .. race.name)
    
    -- ブリップ生成（装飾オブジェクトは不要 - CreateCheckpointで十分）
    CreateRaceBlips(raceCheckpoints)
    
    -- スタート地点案内表示
    local startCp = raceCheckpoints[1]
    if startCp then
        local startPos = vector3(startCp.x, startCp.y, startCp.z)
        local playerPos = GetEntityCoords(ped)
        local distToStart = #(playerPos - startPos)
        
        -- スタート地点にウェイポイント設置
        SetNewWaypoint(startCp.x, startCp.y)
        
        local vehicleTypeConfig = GetConfigValue('VehicleTypes.' .. (race.vehicle_type or 'car'), {})
        local vehicleLabel = vehicleTypeConfig.label or race.vehicle_type or '車両'
        local raceTypeLabel = race.race_type == 'sprint' and 'スプリント' or '周回'
        local totalLaps = race.race_type == 'sprint' and 1 or (race.laps or 1)
        
        -- 案内UI表示
        lib.showTextUI(string.format(
            '🏁 <b>レース準備中</b>: %s<br><br>'
            .. '📍 スタート地点まで: <b>%.0fm</b><br>'
            .. '🚗 車両タイプ: <b>%s</b><br>'
            .. '🏎️ タイプ: <b>%s</b>（%d周）<br>'
            .. '📍 CP: <b>%d個</b><br><br>'
            .. '➡️ スタート地点に向かってください！<br>'
            .. '到着後すぐにカウントダウンが始まります',
            race.name, distToStart, vehicleLabel, raceTypeLabel, totalLaps, #raceCheckpoints), {
            position = "left-center",
            icon = 'map-marked-alt',
            style = {
                borderRadius = 8,
                backgroundColor = 'rgba(26, 26, 46, 0.95)',
                color = '#ffffff',
                borderLeft = '4px solid #fbbf24'
            }
        })
    end
    
    -- カウントダウン（スレッド内でブロックしないように実装）
    local countdownDuration = GetConfigValue('Race.countdownSeconds', 5)
    local startRadius = GetConfigValue('Checkpoint.radius', 10.0) * 2 -- スタート判定は広めに
    
    CreateThread(function()
        -- スタート地点への接近を待つ（案内表示更新付き）
        if startCp then
            local startPos = vector3(startCp.x, startCp.y, startCp.z)
            
            while true do
                local ped2 = PlayerPedId()
                local playerPos = GetEntityCoords(ped2)
                local dist = #(playerPos - startPos)
                
                if dist <= startRadius then
                    -- スタート地点到着
                    lib.hideTextUI()
                    break
                end
                
                -- 距離更新（1秒ごと）
                local vehicleTypeConfig = GetConfigValue('VehicleTypes.' .. (currentRace.vehicle_type or 'car'), {})
                local vehicleLabel = vehicleTypeConfig.label or currentRace.vehicle_type or '車両'
                local raceTypeLabel = currentRace.race_type == 'sprint' and 'スプリント' or '周回'
                local totalLaps = currentRace.race_type == 'sprint' and 1 or (currentRace.laps or 1)
                
                lib.showTextUI(string.format(
                    '🏁 <b>レース準備中</b>: %s<br><br>'
                    .. '📍 スタート地点まで: <b>%.0fm</b><br>'
                    .. '🚗 車両タイプ: <b>%s</b><br>'
                    .. '🏎️ タイプ: <b>%s</b>（%d周）<br>'
                    .. '📍 CP: <b>%d個</b><br><br>'
                    .. '➡️ スタート地点に向かってください！<br>'
                    .. '到着後すぐにカウントダウンが始まります',
                    currentRace.name, dist, vehicleLabel, raceTypeLabel, totalLaps, #raceCheckpoints), {
                    position = "left-center",
                    icon = 'map-marked-alt',
                    style = {
                        borderRadius = 8,
                        backgroundColor = 'rgba(26, 26, 46, 0.95)',
                        color = '#ffffff',
                        borderLeft = '4px solid #fbbf24'
                    }
                })
                
                Wait(1000)
                
                -- レース開始前にキャンセルされた場合
                if not currentRace then
                    lib.hideTextUI()
                    ClearRaceBlips()
                    return
                end
            end
        end
        
        -- ウェイポイント削除
        SetWaypointOff()
        
        -- 即座にカウントダウン開始
        lib.notify({
            title = 'カウントダウン開始！',
            description = string.format('%d秒後にスタートします', countdownDuration),
            type = 'inform',
            duration = 2000
        })
        
        for i = countdownDuration, 1, -1 do
            lib.showTextUI(string.format([[%d]], i), {
                position = "top-center",
                icon = 'stopwatch',
                style = {
                    borderRadius = 16,
                    backgroundColor = i <= 3 and 'rgba(239, 68, 68, 0.95)' or 'rgba(251, 191, 36, 0.95)',
                    color = 'white',
                    fontSize = '48px',
                    fontWeight = 'bold',
                    padding = '24px 48px'
                }
            })
            PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
            Wait(1000)
            lib.hideTextUI()
        end
        
        -- GO!
        lib.showTextUI('GO!', {
            position = "top-center",
            icon = 'flag-checkered',
            style = {
                borderRadius = 16,
                backgroundColor = 'rgba(16, 185, 129, 0.95)',
                color = 'white',
                fontSize = '64px',
                fontWeight = 'bold',
                padding = '24px 48px'
            }
        })
        PlaySoundFrontend(-1, 'GO', 'HUD_MINI_GAME_SOUNDSET', true)
        
        isRacing = true
        raceStartTime = GetGameTimer()
        
        -- ソロ用ゴーストモード開始（NPC衝突回避）
        StartSoloGhostMode()
        
        SetTimeout(1500, function()
            lib.hideTextUI()
        end)
        
        -- レース進行スレッド開始
        CreateThread(function()
            SoloRaceProgressThread()
        end)
        CreateThread(RaceDrawThread)
        CreateThread(SoloRaceUI)
    end)
end

-- ソロレース進行処理
function SoloRaceProgressThread()
    local isSprintRace = (currentRace.race_type == 'sprint')
    local totalLaps = isSprintRace and 1 or (currentRace.laps or 1)
    
    DebugLog('Solo race progress started - Type: ' .. (isSprintRace and 'sprint' or 'circuit') .. ', Laps: ' .. totalLaps)
    
    while isRacing and currentRace do
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        
        if currentCheckpoint <= #raceCheckpoints then
            local cp = raceCheckpoints[currentCheckpoint]
            local cpCoords = vector3(cp.x, cp.y, cp.z)
            local distance = #(coords - cpCoords)
            
            if distance <= (cp.radius or 10.0) then
                currentCheckpoint = currentCheckpoint + 1
                
                -- ブリップ更新
                if raceBlips[currentCheckpoint - 1] then
                    SetBlipColour(raceBlips[currentCheckpoint - 1], 2) -- 通過済みは緑
                end
                
                -- ゴール判定
                if currentCheckpoint > #raceCheckpoints then
                    if isSprintRace or currentLap >= totalLaps then
                        -- レース完了
                        ClearCheckpointEntities()
                        FinishSoloRace()
                        break
                    else
                        -- 次の周回
                        currentLap = currentLap + 1
                        currentCheckpoint = 1
                        
                        -- ブリップリセット
                        for i, blip in ipairs(raceBlips) do
                            SetBlipColour(blip, i == #raceCheckpoints and 38 or 5)
                        end
                        
                        -- チェックポイント表示更新
                        UpdateRaceCheckpoints()
                        
                        lib.notify({
                            title = 'ラップ完了',
                            description = string.format('ラップ %d/%d', currentLap, totalLaps),
                            type = 'success'
                        })
                        
                        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                    end
                else
                    -- チェックポイント通過 → 表示更新
                    UpdateRaceCheckpoints()
                    
                    PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                    
                    lib.notify({
                        title = 'チェックポイント通過',
                        description = string.format('CP %d/%d', currentCheckpoint - 1, #raceCheckpoints),
                        type = 'success'
                    })
                end
            end
        end
        
        Wait(100)
    end
end

-- ソロレースUI
function SoloRaceUI()
    CreateThread(function()
        while isRacing and not isMultiplayerRace do
            local currentTime = GetGameTimer() - raceStartTime
            local timeFormatted = string.format("%.2f", currentTime / 1000)
            
            local raceTypeLabel = currentRace.race_type == 'sprint' and 'スプリント' or '周回'
            local totalLaps = currentRace.race_type == 'sprint' and 1 or (currentRace.laps or 1)
            
            -- NUI レースHUD更新（リタイアボタン付き）
            SendNUIMessage({
                action = 'updateRaceHUD',
                visible = true,
                raceType = raceTypeLabel,
                time = timeFormatted,
                checkpoint = math.max(0, currentCheckpoint - 1),
                totalCheckpoints = #raceCheckpoints,
                lap = currentLap,
                totalLaps = totalLaps,
                isMultiplayer = false,
                position = nil,
                totalParticipants = nil
            })
            
            Wait(100)
        end
        
        -- レース終了時にHUD非表示
        SendNUIMessage({ action = 'updateRaceHUD', visible = false })
    end)
end

-- ソロレース完了
function FinishSoloRace()
    if not isRacing then return end
    
    local finishTime = GetGameTimer() - raceStartTime
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    local vehicleModel = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))
    
    DebugLog('Solo race finished - Time: ' .. finishTime .. 'ms')
    
    -- サーバーに完了報告
    TriggerServerEvent('qbx_racing:server:finishRace', currentRace.id, finishTime, vehicleModel)
    
    -- クリーンアップ
    isRacing = false
    currentRace = nil
    currentCheckpoint = 1
    currentLap = 1
    raceCheckpoints = {}
    
    ClearRaceObjects()
    ClearRaceBlips()
    ClearCheckpointEntities()
    
    -- NUI HUD非表示
    SendNUIMessage({ action = 'updateRaceHUD', visible = false })
    
    -- ゴーストモードリセット
    if isGhostModeActive then
        ResetGhostMode()
    end
    
    lib.hideTextUI()
end

-- ===================================
-- リタイア（レース放棄）システム
-- ===================================

-- ソロレースリタイア
function RetireSoloRace()
    if not isRacing then return end
    
    DebugLog('Solo race retired')
    
    lib.notify({
        title = 'リタイア',
        description = 'レースを放棄しました',
        type = 'error',
        duration = 5000
    })
    
    -- NUI HUD非表示
    SendNUIMessage({ action = 'updateRaceHUD', visible = false })
    
    -- クリーンアップ
    isRacing = false
    currentRace = nil
    currentCheckpoint = 1
    currentLap = 1
    raceCheckpoints = {}
    
    ClearRaceObjects()
    ClearRaceBlips()
    ClearCheckpointEntities()
    
    -- ゴーストモードリセット
    if isGhostModeActive then
        ResetGhostMode()
    end
    
    lib.hideTextUI()
end

-- マルチプレイヤーレースリタイア
function RetireMultiplayerRace()
    if not isRacing or not isMultiplayerRace then return end
    
    DebugLog('Multiplayer race retired - Session: ' .. tostring(multiplayerSessionId))
    
    -- サーバーにリタイア通知
    TriggerServerEvent('qbx_racing:server:retireRace', multiplayerSessionId)
    
    lib.notify({
        title = 'リタイア',
        description = 'レースを放棄しました',
        type = 'error',
        duration = 5000
    })
    
    -- NUI HUD非表示
    SendNUIMessage({ action = 'updateRaceHUD', visible = false })
    
    -- クリーンアップ
    isRacing = false
    isMultiplayerRace = false
    multiplayerSessionId = nil
    currentRace = nil
    currentCheckpoint = 1
    currentLap = 1
    raceCheckpoints = {}
    ghostPlayers = {}
    progressData = {}
    
    ClearRaceObjects()
    ClearRaceBlips()
    ClearCheckpointEntities()
    
    -- ゴーストモードリセット
    if isGhostModeActive then
        if GetConfigValue('Multiplayer.ghostMode.optimizedMode', false) then
            ResetGhostModeOptimized()
        else
            ResetGhostMode()
        end
    end
    
    lib.hideTextUI()
end

-- ===================================
-- マルチプレイヤーレース進行システム
-- ===================================

-- マルチプレイヤーレース開始
function StartMultiplayerRace(race, sessionId, participants)
    if isRacing then
        lib.notify({
            title = 'エラー',
            description = '既にレース中です',
            type = 'error'
        })
        return
    end
    
    isMultiplayerRace = true
    multiplayerSessionId = sessionId
    ghostPlayers = participants or {}
    
    currentRace = race
    raceCheckpoints = race.checkpoints or {}
    currentCheckpoint = 1
    currentLap = 1
    isRacing = true
    raceStartTime = GetGameTimer()
    
    -- レースタイプ判定
    local isSprintRace = (race.race_type == 'sprint')
    local totalLaps = isSprintRace and 1 or (race.laps or 1)
    
    DebugLog('Starting multiplayer race - Session: ' .. sessionId .. ', Participants: ' .. #ghostPlayers)
    
    -- ブリップ生成（装飾オブジェクトは不要）
    CreateRaceBlips(raceCheckpoints)
    
    -- ゴーストモード開始（設定に応じて基本版または最適化版）
    if GetConfigValue('Multiplayer.ghostMode.optimizedMode', false) then
        StartGhostModeOptimized()
    else
        StartGhostMode()
    end
    
    lib.notify({
        title = 'ゴーストモード有効',
        description = '他の車両をすり抜けられます',
        type = 'inform',
        duration = 3000
    })
    
    -- レース進行スレッド開始
    CreateThread(function()
        MultiplayerRaceProgressThread(isSprintRace, totalLaps)
    end)
    CreateThread(RaceDrawThread)
    CreateThread(MultiplayerRaceUI)
end

-- マルチプレイヤーレース進行処理
function MultiplayerRaceProgressThread(isSprintRace, totalLaps)
    DebugLog('Multiplayer race progress started - Type: ' .. (isSprintRace and 'sprint' or 'circuit') .. ', Laps: ' .. totalLaps)
    
    while isRacing and currentRace do
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        
        if currentCheckpoint <= #raceCheckpoints then
            local cp = raceCheckpoints[currentCheckpoint]
            local cpCoords = vector3(cp.x, cp.y, cp.z)
            local distance = #(coords - cpCoords)
            
            if distance <= (cp.radius or 10.0) then
                currentCheckpoint = currentCheckpoint + 1
                
                -- サーバーに進捗報告
                TriggerServerEvent('qbx_racing:server:updateProgress', 
                    multiplayerSessionId, currentCheckpoint, currentLap)
                
                -- ブリップ更新
                if raceBlips[currentCheckpoint - 1] then
                    SetBlipColour(raceBlips[currentCheckpoint - 1], 2) -- 通過済みは緑
                end
                
                -- ゴール判定
                if currentCheckpoint > #raceCheckpoints then
                    if isSprintRace or currentLap >= totalLaps then
                        -- レース完了
                        ClearCheckpointEntities()
                        FinishMultiplayerRace()
                        break
                    else
                        -- 次の周回
                        currentLap = currentLap + 1
                        currentCheckpoint = 1
                        
                        -- ブリップリセット
                        for i, blip in ipairs(raceBlips) do
                            SetBlipColour(blip, i == #raceCheckpoints and 38 or 5)
                        end
                        
                        -- チェックポイント表示更新
                        UpdateRaceCheckpoints()
                        
                        lib.notify({
                            title = 'ラップ完了',
                            description = string.format('ラップ %d/%d', currentLap, totalLaps),
                            type = 'success'
                        })
                        
                        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                    end
                else
                    -- チェックポイント通過 → 表示更新
                    UpdateRaceCheckpoints()
                    
                    PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                    
                    lib.notify({
                        title = 'チェックポイント通過',
                        description = string.format('CP %d/%d', currentCheckpoint - 1, #raceCheckpoints),
                        type = 'success'
                    })
                end
            end
        end
        
        Wait(100)
    end
end

-- マルチプレイヤーレースUI
function MultiplayerRaceUI()
    CreateThread(function()
        while isRacing and isMultiplayerRace do
            local currentTime = GetGameTimer() - raceStartTime
            local timeFormatted = string.format("%.2f", currentTime / 1000)
            
            local myPosition = CalculateMyPosition()
            local totalParticipants = #ghostPlayers
            
            local raceTypeLabel = currentRace.race_type == 'sprint' and 'スプリント' or '周回'
            local totalLaps = currentRace.race_type == 'sprint' and 1 or (currentRace.laps or 1)
            
            -- NUI レースHUD更新（リタイアボタン付き）
            SendNUIMessage({
                action = 'updateRaceHUD',
                visible = true,
                raceType = raceTypeLabel,
                time = timeFormatted,
                checkpoint = math.max(0, currentCheckpoint - 1),
                totalCheckpoints = #raceCheckpoints,
                lap = currentLap,
                totalLaps = totalLaps,
                isMultiplayer = true,
                position = myPosition,
                totalParticipants = totalParticipants
            })
            
            Wait(100)
        end
        
        -- レース終了時にHUD非表示
        SendNUIMessage({ action = 'updateRaceHUD', visible = false })
    end)
end

-- 順位計算
function CalculateMyPosition()
    local myProgress = (currentLap - 1) * #raceCheckpoints + (currentCheckpoint - 1)
    local position = 1
    
    for _, data in pairs(progressData) do
        if data.status == 'racing' then
            local otherProgress = ((data.lap or 1) - 1) * #raceCheckpoints + ((data.checkpoint or 1) - 1)
            if otherProgress > myProgress then
                position = position + 1
            end
        end
    end
    
    return position
end

-- 進捗更新受信
RegisterNetEvent('qbx_racing:client:progressUpdate', function(data)
    progressData = data.progressData or {}
end)

-- マルチプレイヤーレース完了
function FinishMultiplayerRace()
    if not isRacing then return end
    
    local finishTime = GetGameTimer() - raceStartTime
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    local vehicleModel = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))
    
    DebugLog('Multiplayer race finished - Time: ' .. finishTime .. 'ms, Session: ' .. multiplayerSessionId)
    
    -- サーバーに完了報告
    TriggerServerEvent('qbx_racing:server:finishMultiRace', 
        multiplayerSessionId, finishTime, vehicleModel)
    
    -- クリーンアップ
    isRacing = false
    isMultiplayerRace = false
    multiplayerSessionId = nil
    currentRace = nil
    currentCheckpoint = 1
    currentLap = 1
    raceCheckpoints = {}
    ghostPlayers = {}
    progressData = {}
    
    ClearRaceObjects()
    ClearRaceBlips()
    ClearCheckpointEntities()
    
    -- NUI HUD非表示
    SendNUIMessage({ action = 'updateRaceHUD', visible = false })
    
    -- ゴーストモードリセット
    if GetConfigValue('Multiplayer.ghostMode.optimizedMode', false) then
        ResetGhostModeOptimized()
    else
        ResetGhostMode()
    end
    
    lib.hideTextUI()
end

-- ===================================
-- レースチェックポイント描画システム（CreateCheckpoint使用）
-- ===================================

-- チェックポイントエンティティをすべて削除
function ClearCheckpointEntities()
    for _, cpHandle in ipairs(activeCheckpointEntities) do
        DeleteCheckpoint(cpHandle)
    end
    activeCheckpointEntities = {}
    DebugLog('Checkpoint entities cleared')
end

-- チェックポイントエンティティを1つ生成
-- cpType: チェックポイントタイプID（0-47）
-- pos: 表示座標 vector3
-- pointTo: 矢印の向き先座標 vector3 (nilなら矢印なし)
-- radius: 半径
-- color: {r,g,b,a}
-- iconColor: {r,g,b,a} アイコン（矢印/チェッカー）の色
-- nearHeight: 近接時の高さ（柱の長さ）
function CreateCheckpointEntity(cpType, pos, pointTo, radius, height, color, iconColor, nearHeight)
    local pointToX, pointToY, pointToZ = 0.0, 0.0, 0.0
    if pointTo then
        pointToX, pointToY, pointToZ = pointTo.x, pointTo.y, pointTo.z
    end

    local cp = CreateCheckpoint(
        cpType,
        pos.x, pos.y, pos.z,
        pointToX, pointToY, pointToZ,
        radius,
        color.r, color.g, color.b, math.floor(color.a),
        0  -- reserved
    )

    if cp then
        SetCheckpointCylinderHeight(cp, height, nearHeight or 100.0, radius)
        SetCheckpointIconRgba(cp, iconColor.r, iconColor.g, iconColor.b, iconColor.a)
        table.insert(activeCheckpointEntities, cp)
    end

    return cp
end

-- 現在のチェックポイント表示を更新（進行に合わせて呼び出す）
function UpdateRaceCheckpoints()
    -- 既存のチェックポイントエンティティを全削除して再生成
    ClearCheckpointEntities()

    if not currentRace or not isRacing then return end

    local vehicleType = currentRace.vehicle_type or 'car'
    local cpConfig = GetConfigValue('VehicleTypes.' .. vehicleType .. '.checkpoint', {
        type = 0, typeNoArrow = 2, goalType = 4,
        radius = 10.0, height = 5.0, nearHeight = 100.0,
        color = {r = 255, g = 0, b = 0, a = 200},
        goalColor = {r = 255, g = 215, b = 0, a = 200},
        nextColor = {r = 255, g = 255, b = 255, a = 80},
        iconColor = {r = 255, g = 255, b = 255, a = 255}
    })

    local totalCPs = #raceCheckpoints

    -- 現在のチェックポイント
    if currentCheckpoint <= totalCPs then
        local cp = raceCheckpoints[currentCheckpoint]
        local cpPos = vector3(cp.x, cp.y, cp.z)
        local isGoal = (currentCheckpoint == totalCPs)

        -- ゴール判定（スプリントの最終CP or 周回の最終ラップ最終CP）
        local isSprintRace = (currentRace.race_type == 'sprint')
        local totalLaps = isSprintRace and 1 or (currentRace.laps or 1)
        local isFinalGoal = isGoal and (isSprintRace or currentLap >= totalLaps)

        if isFinalGoal then
            -- ゴールチェックポイント（矢印なし、チェッカーフラッグ）
            CreateCheckpointEntity(
                cpConfig.goalType,
                cpPos, nil,
                cpConfig.radius, cpConfig.height,
                cpConfig.goalColor, cpConfig.iconColor,
                cpConfig.nearHeight
            )
        else
            -- 通過チェックポイント（次CPへの矢印表示）
            local nextIdx = currentCheckpoint + 1
            if nextIdx > totalCPs then nextIdx = 1 end -- 周回の場合最初に戻る
            local nextCp = raceCheckpoints[nextIdx]
            local nextPos = vector3(nextCp.x, nextCp.y, nextCp.z)

            CreateCheckpointEntity(
                cpConfig.type,
                cpPos, nextPos,
                cpConfig.radius, cpConfig.height,
                cpConfig.color, cpConfig.iconColor,
                cpConfig.nearHeight
            )
        end
    end

    -- 次のチェックポイント（半透明プレビュー）
    local previewIdx = currentCheckpoint + 1
    if previewIdx <= totalCPs then
        local nextCp = raceCheckpoints[previewIdx]
        local nextPos = vector3(nextCp.x, nextCp.y, nextCp.z)
        local isNextGoal = (previewIdx == totalCPs)

        -- 次の次のCP方向（矢印用）
        local pointToIdx = previewIdx + 1
        if pointToIdx > totalCPs then pointToIdx = 1 end
        local pointToCp = raceCheckpoints[pointToIdx]
        local pointToPos = vector3(pointToCp.x, pointToCp.y, pointToCp.z)

        local isSprintRace = (currentRace.race_type == 'sprint')
        local totalLaps = isSprintRace and 1 or (currentRace.laps or 1)
        local isNextFinalGoal = isNextGoal and (isSprintRace or currentLap >= totalLaps)

        if isNextFinalGoal then
            CreateCheckpointEntity(
                cpConfig.goalType,
                nextPos, nil,
                cpConfig.radius, cpConfig.height,
                cpConfig.nextColor, cpConfig.iconColor,
                cpConfig.nearHeight
            )
        else
            CreateCheckpointEntity(
                cpConfig.type,
                nextPos, pointToPos,
                cpConfig.radius, cpConfig.height,
                cpConfig.nextColor, cpConfig.iconColor,
                cpConfig.nearHeight
            )
        end
    end

    DebugLog('Checkpoints updated: current=' .. currentCheckpoint .. '/' .. totalCPs)
end

-- レース中のチェックポイント監視スレッド（毎フレーム描画不要）
function RaceDrawThread()
    -- 初回表示
    UpdateRaceCheckpoints()

    -- チェックポイント更新は進行処理（SoloRaceProgressThread / MultiplayerRaceProgressThread）
    -- 内でCP通過時に UpdateRaceCheckpoints() を呼び出すため、
    -- ここでは何もしない（DrawMarkerと違い毎フレーム描画不要）
    DebugLog('RaceDrawThread: checkpoint entities created (no per-frame draw needed)')
end

-- ===================================
-- ユーティリティ関数
-- ===================================

-- 車両タイプチェック
function IsValidVehicleForRace(vehicle, raceType)
    local vehicleClass = GetVehicleClass(vehicle)
    local allowedClasses = GetConfigValue('VehicleTypes.' .. raceType .. '.allowedClasses', {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12})
    
    for _, allowedClass in ipairs(allowedClasses) do
        if vehicleClass == allowedClass then
            return true
        end
    end
    
    return false
end

-- ===================================
-- リソース停止時のクリーンアップ
-- ===================================
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    
    -- レース中の場合はクリーンアップ
    if isRacing then
        isRacing = false
        lib.hideTextUI()
        SendNUIMessage({ action = 'updateRaceHUD', visible = false })
        ClearRaceObjects()
        ClearRaceBlips()
        ClearCheckpointEntities()
        
        -- ゴーストモードリセット（ソロ・マルチ共通）
        if isGhostModeActive then
            if isMultiplayerRace and GetConfigValue('Multiplayer.ghostMode.optimizedMode', false) then
                ResetGhostModeOptimized()
            else
                ResetGhostMode()
            end
        end
    end
    
    -- すべての状態をリセット
    isMultiplayerRace = false
    currentRace = nil
    currentCheckpoint = 1
    currentLap = 1
    raceCheckpoints = {}
    multiplayerSessionId = nil
    ghostPlayers = {}
    progressData = {}
    isGhostModeActive = false
    ghostedEntities = {}
    
    print('^2[QBX Racing]^7 レースロジック停止完了')
end)

-- ===================================
-- レース状態取得ヘルパー（main.luaから呼び出し用）
-- ===================================
function IsCurrentlyRacing()
    return isRacing
end

function IsCurrentlyMultiplayer()
    return isMultiplayerRace
end

-- ===================================
-- 初期化
-- ===================================
CreateThread(function()
    print('^2[QBX Racing]^7 レースロジック起動完了')
    
    if DEBUG_MODE then
        print('^3[QBX Racing]^7 デバッグモードが有効です（race_logic.lua）')
    end
end)
