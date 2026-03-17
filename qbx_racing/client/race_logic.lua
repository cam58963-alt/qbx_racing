-- ===================================
-- QBX Racing System - Client Race Logic
-- 完全統合版 v3.0.0
-- レース進行・ゴーストモード・チェックポイント管理・視覚効果
-- ===================================

-- ===================================
-- グローバル変数とステート管理
-- ===================================

-- レース状態
local isRacing = false
local isMultiplayerRace = false
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
    
    -- 装飾・ブリップ生成
    CreateRaceDecorations(raceCheckpoints)
    CreateRaceBlips(raceCheckpoints)
    
    -- カウントダウン
    local countdownDuration = GetConfigValue('Race.countdownSeconds', 5)
    for i = countdownDuration, 1, -1 do
        lib.notify({
            title = 'レーススタート',
            description = tostring(i),
            type = 'inform'
        })
        Wait(1000)
    end
    
    lib.notify({
        title = 'スタート！',
        description = 'レース開始！',
        type = 'success'
    })
    
    isRacing = true
    raceStartTime = GetGameTimer()
    
    -- レース進行スレッド開始
    CreateThread(function()
        SoloRaceProgressThread()
    end)
    CreateThread(RaceDrawThread)
    CreateThread(SoloRaceUI)
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
                        
                        lib.notify({
                            title = 'ラップ完了',
                            description = string.format('ラップ %d/%d', currentLap, totalLaps),
                            type = 'success'
                        })
                        
                        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                    end
                else
                    -- チェックポイント通過
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
            
            lib.showTextUI(string.format([[
🏁 %s レース進行中

⏱️ タイム: %ss
🔄 CP: %d / %d
🏁 ラップ: %d / %d
            ]], raceTypeLabel, timeFormatted, 
                math.max(0, currentCheckpoint - 1), #raceCheckpoints,
                currentLap, totalLaps), {
                position = "right-center",
                icon = 'flag-checkered',
                style = {
                    borderRadius = 8,
                    backgroundColor = 'rgba(26, 26, 46, 0.95)',
                    color = '#ffffff',
                    borderLeft = '4px solid #ef4444'
                }
            })
            
            Wait(100)
        end
        
        lib.hideTextUI()
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
    
    -- 装飾・ブリップ生成
    CreateRaceDecorations(raceCheckpoints)
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
                        
                        lib.notify({
                            title = 'ラップ完了',
                            description = string.format('ラップ %d/%d', currentLap, totalLaps),
                            type = 'success'
                        })
                        
                        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                    end
                else
                    -- チェックポイント通過
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
            
            lib.showTextUI(string.format([[
🏁 %s レース進行中

⏱️ タイム: %ss
🏆 順位: %d / %d
🔄 CP: %d / %d
🏁 ラップ: %d / %d
            ]], raceTypeLabel, timeFormatted, myPosition, totalParticipants, 
                math.max(0, currentCheckpoint - 1), #raceCheckpoints,
                currentLap, totalLaps), {
                position = "right-center",
                icon = 'flag-checkered',
                style = {
                    borderRadius = 8,
                    backgroundColor = 'rgba(26, 26, 46, 0.95)',
                    color = '#ffffff',
                    borderLeft = '4px solid #ef4444'
                }
            })
            
            Wait(100)
        end
        
        lib.hideTextUI()
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
    
    -- ゴーストモードリセット
    if GetConfigValue('Multiplayer.ghostMode.optimizedMode', false) then
        ResetGhostModeOptimized()
    else
        ResetGhostMode()
    end
    
    lib.hideTextUI()
end

-- ===================================
-- レース描画システム
-- ===================================

-- レース中のマーカー描画
function RaceDrawThread()
    CreateThread(function()
        while isRacing and currentRace do
            -- 現在のチェックポイント
            if currentCheckpoint <= #raceCheckpoints then
                local cp = raceCheckpoints[currentCheckpoint]
                local vehicleType = currentRace.vehicle_type or 'car'
                local markerColor = GetConfigValue('VehicleTypes.' .. vehicleType .. '.markerColor', {r = 255, g = 0, b = 0, a = 150})
                
                DrawMarker(
                    1, -- 円柱型マーカー
                    cp.x, cp.y, cp.z - 1.0,
                    0.0, 0.0, 0.0,
                    0.0, 0.0, 0.0,
                    (cp.radius or 10.0) * 2, (cp.radius or 10.0) * 2, 5.0,
                    markerColor.r, markerColor.g, markerColor.b, markerColor.a,
                    false, false, 2, false, nil, nil, false
                )
            end
            
            -- 次のチェックポイント（半透明）
            if currentCheckpoint < #raceCheckpoints then
                local nextCp = raceCheckpoints[currentCheckpoint + 1]
                DrawMarker(
                    1,
                    nextCp.x, nextCp.y, nextCp.z - 1.0,
                    0.0, 0.0, 0.0,
                    0.0, 0.0, 0.0,
                    (nextCp.radius or 10.0) * 2, (nextCp.radius or 10.0) * 2, 5.0,
                    255, 255, 255, 50,
                    false, false, 2, false, nil, nil, false
                )
            end
            
            Wait(0)
        end
    end)
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
        ClearRaceObjects()
        ClearRaceBlips()
        
        if isMultiplayerRace then
            if GetConfigValue('Multiplayer.ghostMode.optimizedMode', false) then
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
-- 初期化
-- ===================================
CreateThread(function()
    print('^2[QBX Racing]^7 レースロジック起動完了')
    
    if DEBUG_MODE then
        print('^3[QBX Racing]^7 デバッグモードが有効です（race_logic.lua）')
    end
end)
