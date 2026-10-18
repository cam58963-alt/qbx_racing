-- ===================================
-- CAM Racing System - Client Race Logic
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
local soloCountdownVehicle = 0  -- ソロのカウントダウン中に止めている車両（リソース停止時に解除するため）
local raceStartTime = 0
local currentCheckpoint = 1
local currentLap = 1
local raceCheckpoints = {}

-- マルチプレイヤー関連
local multiplayerSessionId = nil
local ghostPlayers = {}
local progressData = {}
local finishedCount = 0  -- 先にゴールした人数（サーバーから届く）

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
        -- false も設定値として扱う（nil のときだけ既定値）
        if type(current) == 'table' and current[key] ~= nil then
            current = current[key]
        else
            return defaultValue
        end
    end
    return current
end

-- 前回位置から今回位置までの間にチェックポイントの球を通ったか（高速でもすり抜けない）
local function PassedThrough(fromPos, toPos, center, radius)
    if #(toPos - center) <= radius then return true end
    if not fromPos then return false end
    
    local segment = toPos - fromPos
    local lengthSq = segment.x * segment.x + segment.y * segment.y + segment.z * segment.z
    -- 止まっている時・テレポートのような大きな移動は線分で判定しない
    if lengthSq < 0.0001 or lengthSq > 200.0 * 200.0 then return false end
    
    local toCenter = center - fromPos
    local t = (toCenter.x * segment.x + toCenter.y * segment.y + toCenter.z * segment.z) / lengthSq
    t = math.max(0.0, math.min(1.0, t))
    return #((fromPos + segment * t) - center) <= radius
end

-- ===================================
-- コースの進み方
-- スプリント: CP1 → … → CPn がゴール
-- 周回: CP1（スタート）→ … → CPn → CP1 に戻って1周。最終周はスタート地点（CP1）がゴール
--   currentCheckpoint は「次に通過する番号」。周回では n+1 が「スタート地点に戻る」を表す
-- ===================================
local function IsCircuitRace()
    return currentRace ~= nil and currentRace.race_type ~= 'sprint'
end

local function GetTotalLaps()
    return IsCircuitRace() and math.max(1, tonumber(currentRace.laps) or 1) or 1
end

-- 1周の最後の番号（周回は n+1 = スタート地点に戻る）
local function LapEndIndex()
    return IsCircuitRace() and #raceCheckpoints + 1 or #raceCheckpoints
end

-- 番号 → チェックポイント（n+1 は CP1）
local function CheckpointAt(index)
    return raceCheckpoints[index > #raceCheckpoints and 1 or index]
end

local function IsFinishPosition(lap, index)
    return lap >= GetTotalLaps() and index == LapEndIndex()
end

-- 次の（周, 番号）。周の最後の次は、次の周の CP2（CP1 は今通ったスタート地点）
local function NextPosition(lap, index)
    if index < LapEndIndex() then
        return lap, index + 1
    end
    return lap + 1, 2
end

-- ゴール地点のブリップ番号（周回はスタート地点）
local function GoalBlipIndex()
    return IsCircuitRace() and 1 or #raceCheckpoints
end

-- デバッグログ出力
local function DebugLog(message)
    if DEBUG_MODE then
        print('^3[CAM Racing Logic]^7 ' .. tostring(message))
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
        SetBlipColour(blip, i == GoalBlipIndex() and 38 or 5) -- ゴールはオレンジ、他は黄色（周回はスタート地点がゴール）
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

-- プレイヤーが運転している車両か（NPCの車・駐車中の車は false）
local function IsPlayerDrivenVehicle(vehicle)
    local driver = GetPedInVehicleSeat(vehicle, -1)
    return driver ~= 0 and IsPedAPlayer(driver)
end

-- レースのゴーストモード（players = プレイヤーの車だけ / full = NPCの車も）
local function GetRaceGhostMode()
    return currentRace and currentRace.ghost_mode == 'players' and 'players' or 'full'
end

-- この車両をすり抜けるか
local function ShouldGhostVehicle(vehicle, ghostMode, isRacer)
    return ghostMode == 'full' or isRacer or IsPlayerDrivenVehicle(vehicle)
end

-- 今回ゴースト化しなかった車両（運転手が降りた・範囲外に出たなど）の透明度を戻す
-- applied: これまでに透明度を変えた車両、seen: 今回ゴースト化した車両
local function ResetUnghostedAlpha(applied, seen)
    for vehicle in pairs(applied) do
        if not seen[vehicle] then
            if DoesEntityExist(vehicle) then ResetEntityAlpha(vehicle) end
            applied[vehicle] = nil
        end
    end
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
        local ghostMode = GetRaceGhostMode()
        local alphaApplied = {}
        
        while isRacing and isMultiplayerRace and isGhostModeActive do
            local playerPed = PlayerPedId()
            local playerVehicle = GetVehiclePedIsIn(playerPed, false)
            
            if playerVehicle ~= 0 then
                local playerCoords = GetEntityCoords(playerVehicle)
                local seen = {}
                
                -- 全車両を取得（NPC車両含む）
                local vehicles = GetGamePool('CVehicle')
                
                for _, otherVehicle in ipairs(vehicles) do
                    if otherVehicle ~= playerVehicle and DoesEntityExist(otherVehicle) then
                        local otherCoords = GetEntityCoords(otherVehicle)
                        local distance = #(playerCoords - otherCoords)
                        
                        -- 設定範囲内の車両に対して処理
                        local isRacerVehicle = distance <= collisionRadius and IsVehicleOwnedByRacer(otherVehicle)
                        if distance <= collisionRadius and ShouldGhostVehicle(otherVehicle, ghostMode, isRacerVehicle) then
                            -- 衝突無効化（一方向：自分が相手をすり抜ける）
                            SetEntityNoCollisionEntity(playerVehicle, otherVehicle, true)
                            
                            -- レース参加者同士なら双方向
                            if isRacerVehicle then
                                SetEntityNoCollisionEntity(otherVehicle, playerVehicle, true)
                            end
                            
                            -- 視覚効果
                            ApplyGhostVisualEffect(otherVehicle, isRacerVehicle)
                            seen[otherVehicle] = true
                            alphaApplied[otherVehicle] = true
                        end
                    end
                end
                
                ResetUnghostedAlpha(alphaApplied, seen)
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
                -- 衝突は毎フレームの無効化を止めれば戻る（false で呼ぶと逆に永久に無効になる）
                ResetEntityAlpha(entity)
                
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
        local ghostMode = GetRaceGhostMode()
        
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
                    
                    if vehicle ~= playerVehicle and DoesEntityExist(vehicle)
                        and ShouldGhostVehicle(vehicle, ghostMode, isRacer) then
                        ProcessVehicleGhosting(playerVehicle, vehicle, distance, isRacer)
                    elseif ghostedEntities[vehicle] then
                        -- 対象外になった車両（運転手が降りたなど）はすぐ透明度を戻す
                        if DoesEntityExist(vehicle) then ResetEntityAlpha(vehicle) end
                        ghostedEntities[vehicle] = nil
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
            -- 衝突は毎フレームの無効化を止めれば戻る（false で呼ぶと逆に永久に無効になる）
            ResetEntityAlpha(vehicle)
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
        local ghostMode = GetRaceGhostMode()
        local alphaApplied = {}
        
        while isRacing and not isMultiplayerRace and isGhostModeActive do
            local playerPed = PlayerPedId()
            local playerVehicle = GetVehiclePedIsIn(playerPed, false)
            
            if playerVehicle ~= 0 then
                local playerCoords = GetEntityCoords(playerVehicle)
                local seen = {}
                
                -- 周りの車両をゴースト化（players モードはプレイヤーが運転している車だけ）
                local vehicles = GetGamePool('CVehicle')
                
                for _, otherVehicle in ipairs(vehicles) do
                    if otherVehicle ~= playerVehicle and DoesEntityExist(otherVehicle) then
                        local otherCoords = GetEntityCoords(otherVehicle)
                        local distance = #(playerCoords - otherCoords)
                        
                        if distance <= collisionRadius and ShouldGhostVehicle(otherVehicle, ghostMode, false) then
                            -- 衝突無効化
                            SetEntityNoCollisionEntity(playerVehicle, otherVehicle, true)
                            SetEntityNoCollisionEntity(otherVehicle, playerVehicle, true)
                            
                            -- すり抜ける車両を半透明に
                            SetEntityAlpha(otherVehicle, 150, false)
                            seen[otherVehicle] = true
                            alphaApplied[otherVehicle] = true
                        end
                    end
                end
                
                ResetUnghostedAlpha(alphaApplied, seen)
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
    if isRacing or currentRace then
        lib.notify({
            title = 'エラー',
            description = '既にレース中（またはスタート地点へ移動中）です',
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
            '**レース準備中**: %s  \n'
            .. 'スタートまで **%.0fm**  \n'
            .. '%s・%s（%d周）・CP %d個  \n'
            .. '到着するとカウントダウン開始',
            race.name, distToStart, vehicleLabel, raceTypeLabel, totalLaps, #raceCheckpoints), {
            position = "left-center",
            icon = 'map-marked-alt',
            style = {
                borderRadius = 6,
                backgroundColor = 'rgba(26, 26, 46, 0.8)',
                color = '#ffffff',
                borderLeft = '3px solid #fbbf24',
                fontSize = '12px',
                lineHeight = '1.5',
                padding = '8px 12px'
            }
        })
    end
    
    -- カウントダウン（スレッド内でブロックしないように実装）
    -- 準備（ロックなし・マーカー表示で向きを確認）→ ロックしてカウント → スタート
    local prepSeconds = math.max(0, math.floor(tonumber(GetConfigValue('Race.prepSeconds', 10)) or 10))
    local lockSeconds = math.max(1, math.floor(tonumber(GetConfigValue('Race.lockSeconds', 3)) or 3))
    local startRadius = GetConfigValue('Checkpoint.radius', 10.0) * 2 -- スタート判定は広めに
    
    local thisRace = race
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
                    '**レース準備中**: %s  \n'
                    .. 'スタートまで **%.0fm**  \n'
                    .. '%s・%s（%d周）・CP %d個  \n'
                    .. '到着するとカウントダウン開始',
                    currentRace.name, dist, vehicleLabel, raceTypeLabel, totalLaps, #raceCheckpoints), {
                    position = "left-center",
                    icon = 'map-marked-alt',
                    style = {
                        borderRadius = 6,
                        backgroundColor = 'rgba(26, 26, 46, 0.8)',
                        color = '#ffffff',
                        borderLeft = '3px solid #fbbf24',
                        fontSize = '12px',
                        lineHeight = '1.5',
                        padding = '8px 12px'
                    }
                })
                
                Wait(1000)
                
                -- レース開始前に取り消された場合（後片付けは取り消した側で済んでいる）
                if currentRace ~= thisRace then
                    return
                end
            end
        end
        
        -- ウェイポイント削除
        SetWaypointOff()
        
        -- 準備カウント（車両はロックしない）。コースのマーカーを出して向きを確認してもらう
        local prepVehicle = GetVehiclePedIsIn(PlayerPedId(), false)
        local prepCoords = prepVehicle ~= 0 and GetEntityCoords(prepVehicle) or nil
        local previewToken = StartStartPreview(thisRace)
        
        lib.notify({
            title = 'まもなくスタート',
            description = string.format('%d秒の準備のあと、車両をロックして%d秒でスタートします。マーカーで向きを確認してください',
                prepSeconds, lockSeconds),
            type = 'inform',
            duration = 5000
        })
        
        for i = prepSeconds, 1, -1 do
            if currentRace ~= thisRace then
                StopStartPreview(previewToken)
                return
            end
            ShowStartPrepCount(i)
            if i <= 3 then
                PlaySoundFrontend(-1, 'NAV_UP_DOWN', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
            end
            Wait(1000)
        end
        lib.hideTextUI()
        if currentRace ~= thisRace then
            StopStartPreview(previewToken)
            return
        end
        
        -- ロック開始。準備中に降りた・乗り換えた場合は準備開始時の車両に戻す
        local countdownVehicle = GetVehiclePedIsIn(PlayerPedId(), false)
        if prepVehicle ~= 0 and countdownVehicle ~= prepVehicle and PutPedBackInVehicle(prepVehicle) then
            countdownVehicle = prepVehicle
            lib.notify({
                title = 'レース車両に戻しました',
                description = '準備中に降りたため、元の車両に戻しました',
                type = 'warning'
            })
        end
        
        -- 準備中にスタート地点から離れていたら準備開始時の位置に戻す（向きはそのまま）
        if countdownVehicle ~= 0 and prepCoords and startCp
            and #(GetEntityCoords(countdownVehicle) - vector3(startCp.x, startCp.y, startCp.z)) > startRadius then
            SetEntityCoords(countdownVehicle, prepCoords.x, prepCoords.y, prepCoords.z, false, false, false, false)
            SetEntityVelocity(countdownVehicle, 0.0, 0.0, 0.0)
            lib.notify({
                title = 'スタート地点に戻しました',
                description = '準備中にスタート地点から離れたため、元の位置に戻しました',
                type = 'warning'
            })
        end
        
        -- ロック中は車両を止める（走りながらのスタートで記録が縮まないように）
        soloCountdownVehicle = countdownVehicle
        if countdownVehicle ~= 0 then
            FreezeEntityPosition(countdownVehicle, true)
        end
        
        for i = lockSeconds, 1, -1 do
            if currentRace ~= thisRace then
                if countdownVehicle ~= 0 then FreezeEntityPosition(countdownVehicle, false) end
                soloCountdownVehicle = 0
                StopStartPreview(previewToken)
                return
            end
            ShowStartLockCount(i)
            PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
            Wait(1000)
            lib.hideTextUI()
        end
        StopStartPreview(previewToken)
        
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
        
        if countdownVehicle ~= 0 then
            FreezeEntityPosition(countdownVehicle, false)
        end
        soloCountdownVehicle = 0
        if currentRace ~= thisRace then
            lib.hideTextUI()
            return
        end
        
        isRacing = true
        raceStartTime = GetGameTimer()
        TriggerServerEvent('qbx_racing:server:soloRaceStarted', thisRace.id, thisRace.playMode)
        
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

-- 準備中に降りた・乗り換えた人を元の車両の運転席に戻す。戻せたら true
function PutPedBackInVehicle(vehicle)
    local ped = PlayerPedId()
    if GetVehiclePedIsIn(ped, false) == vehicle then return true end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or IsEntityDead(vehicle) then return false end
    
    local driver = GetPedInVehicleSeat(vehicle, -1)
    if driver ~= 0 and driver ~= ped then return false end
    
    TaskWarpPedIntoVehicle(ped, vehicle, -1)
    return true
end

-- 準備カウントの表示（ロックなし。向きの確認をうながす）
function ShowStartPrepCount(count)
    lib.showTextUI(string.format('準備 **%d**  \n向きを確認してください（まだ動けます）', count), {
        position = 'top-center',
        icon = 'compass',
        style = {
            borderRadius = 8,
            backgroundColor = 'rgba(26, 26, 46, 0.85)',
            color = '#ffffff',
            borderLeft = '3px solid #fbbf24',
            fontSize = '14px',
            lineHeight = '1.5',
            padding = '8px 14px'
        }
    })
end

-- ロック中のカウント表示（この後スタート）
function ShowStartLockCount(count)
    lib.showTextUI(tostring(count), {
        position = 'top-center',
        icon = 'stopwatch',
        style = {
            borderRadius = 16,
            backgroundColor = 'rgba(239, 68, 68, 0.95)',
            color = 'white',
            fontSize = '48px',
            fontWeight = 'bold',
            padding = '24px 48px'
        }
    })
end

-- レース進行（ソロ・マルチ共通）
-- onPassed(lap, index): 通過して位置が進んだ時（マルチはサーバーに報告）
-- onFinish(): ゴール / onRetire(reason): 車両の乗り換えなどでリタイア
local function RunRaceProgress(onPassed, onFinish, onRetire)
    local totalLaps = GetTotalLaps()
    local swapEnabled = GetConfigValue('Race.vehicleSwapCheck.enabled', true)
    local swapGraceMs = GetConfigValue('Race.vehicleSwapCheck.graceSeconds', 10) * 1000
    local raceVehicle = GetVehiclePedIsIn(PlayerPedId(), false)
    local swapDeadline = nil
    local nextVehicleCheck = 0
    
    DebugLog('Race progress started - Type: ' .. (IsCircuitRace() and 'circuit' or 'sprint') .. ', Laps: ' .. totalLaps)
    
    local lastCoords = nil
    while isRacing and currentRace do
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        local fromCoords = lastCoords
        lastCoords = coords
        local now = GetGameTimer()
        
        -- 車両の乗り換えチェック（スタート時の車両から降りたまま／別の車両のままなら一定時間後にリタイア）
        if swapEnabled and now >= nextVehicleCheck then
            nextVehicleCheck = now + 500
            local vehicle = GetVehiclePedIsIn(ped, false)
            if raceVehicle == 0 then raceVehicle = vehicle end
            if vehicle ~= raceVehicle then
                if not swapDeadline then
                    swapDeadline = now + swapGraceMs
                    lib.notify({
                        title = '車両チェック',
                        description = string.format('スタート時の車両に%d秒以内に戻ってください（乗り換えはリタイアになります）', math.floor(swapGraceMs / 1000)),
                        type = 'error',
                        duration = 5000
                    })
                elseif now >= swapDeadline then
                    onRetire('スタート時の車両から乗り換えた（または降りたまま）ため、リタイアになりました')
                    break
                end
            else
                swapDeadline = nil
            end
        end
        
        local lapEnd = LapEndIndex()
        if not swapDeadline and currentCheckpoint <= lapEnd then
            local cp = CheckpointAt(currentCheckpoint)
            
            if PassedThrough(fromCoords, coords, vector3(cp.x, cp.y, cp.z), cp.radius or 10.0) then
                -- ブリップ更新（通過済みは緑）
                local blipIndex = currentCheckpoint > #raceCheckpoints and 1 or currentCheckpoint
                if raceBlips[blipIndex] then
                    SetBlipColour(raceBlips[blipIndex], 2)
                end
                
                if IsFinishPosition(currentLap, currentCheckpoint) then
                    -- ゴール
                    ClearCheckpointEntities()
                    onFinish()
                    break
                elseif currentCheckpoint == lapEnd then
                    -- 1周完了 → 次の周（スタート地点は今通ったので CP2 から）
                    currentLap, currentCheckpoint = NextPosition(currentLap, currentCheckpoint)
                    onPassed(currentLap, currentCheckpoint)
                    
                    for i, blip in ipairs(raceBlips) do
                        SetBlipColour(blip, i == 1 and 2 or (i == GoalBlipIndex() and 38 or 5))
                    end
                    UpdateRaceCheckpoints()
                    
                    lib.notify({
                        title = 'ラップ完了',
                        description = string.format('ラップ %d/%d', currentLap, totalLaps),
                        type = 'success'
                    })
                    PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                else
                    -- チェックポイント通過
                    currentCheckpoint = currentCheckpoint + 1
                    onPassed(currentLap, currentCheckpoint)
                    UpdateRaceCheckpoints()
                    
                    PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
                    lib.notify({
                        title = 'チェックポイント通過',
                        description = string.format('CP %d/%d', math.min(currentCheckpoint - 1, #raceCheckpoints), #raceCheckpoints),
                        type = 'success'
                    })
                end
            end
        end
        
        Wait(0) -- 毎フレーム判定（タイムの精度と、高速時のすり抜け防止）
    end
end

-- ソロレース進行処理
function SoloRaceProgressThread()
    local raceId = currentRace and currentRace.id
    RunRaceProgress(
        function(lap, index)
            -- サーバーに進捗報告（ゴール時にサーバーが順番どおりに通過したか確認する）
            TriggerServerEvent('qbx_racing:server:soloProgress', raceId, index, lap)
        end,
        FinishSoloRace,
        function(reason) RetireSoloRace(reason) end
    )
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
                checkpoint = math.min(math.max(0, currentCheckpoint - 1), #raceCheckpoints),
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
function RetireSoloRace(reason)
    -- スタート地点へ移動中・カウントダウン中の取り消し（進行スレッドは currentRace の変化を見て止まる）
    if not isRacing and currentRace and not isMultiplayerRace then
        currentRace = nil
        currentCheckpoint = 1
        currentLap = 1
        raceCheckpoints = {}
        ClearRaceBlips()
        ClearCheckpointEntities()
        StopStartPreview()
        SetWaypointOff()
        lib.hideTextUI()
        local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
        if vehicle ~= 0 then FreezeEntityPosition(vehicle, false) end
        
        lib.notify({
            title = 'レース取り消し',
            description = 'スタート前のレースを取り消しました',
            type = 'inform'
        })
        return
    end
    
    if not isRacing then return end
    
    DebugLog('Solo race retired')
    if currentRace then
        TriggerServerEvent('qbx_racing:server:soloRaceRetired', currentRace.id)
    end
    
    lib.notify({
        title = 'リタイア',
        description = reason or 'レースを放棄しました',
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
-- timeUp = true のときはサーバーが制限時間切れでリタイア扱いにした（サーバーへの通知は不要）
function RetireMultiplayerRace(timeUp, reason)
    if not isRacing or not isMultiplayerRace then return end
    
    DebugLog('Multiplayer race retired - Session: ' .. tostring(multiplayerSessionId))
    
    if timeUp then
        lib.notify({
            title = 'タイムアップ',
            description = '制限時間を過ぎたため、レースを終了しました',
            type = 'error',
            duration = 8000
        })
    else
        -- サーバーにリタイア通知
        TriggerServerEvent('qbx_racing:server:retireRace', multiplayerSessionId)
        
        lib.notify({
            title = 'リタイア',
            description = reason or 'レースを放棄しました',
            type = 'error',
            duration = 5000
        })
    end
    
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
            description = '既にレース中のため、マルチプレイレースには参加できませんでした',
            type = 'error'
        })
        TriggerServerEvent('qbx_racing:server:retireRace', sessionId)
        return
    end
    
    -- スタート地点へ移動中のソロレースは取り消す
    if currentRace then
        RetireSoloRace()
    end
    
    isMultiplayerRace = true
    multiplayerSessionId = sessionId
    ghostPlayers = participants or {}
    progressData = {}
    finishedCount = 0
    
    currentRace = race
    raceCheckpoints = race.checkpoints or {}
    currentCheckpoint = 1
    currentLap = 1
    isRacing = true
    raceStartTime = GetGameTimer()

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
        description = GetRaceGhostMode() == 'players' and '他のプレイヤーの車をすり抜けられます（NPCの車とはぶつかります）'
            or 'NPCを含む他の車両をすり抜けられます',
        type = 'inform',
        duration = 3000
    })
    
    -- レース進行スレッド開始
    CreateThread(MultiplayerRaceProgressThread)
    CreateThread(RaceDrawThread)
    CreateThread(MultiplayerRaceUI)
end

-- マルチプレイヤーレース進行処理
function MultiplayerRaceProgressThread()
    RunRaceProgress(
        function(lap, index)
            -- サーバーに進捗報告（サーバーも順番どおりに進んでいるか確認する）
            TriggerServerEvent('qbx_racing:server:updateProgress', multiplayerSessionId, index, lap)
        end,
        FinishMultiplayerRace,
        function(reason) RetireMultiplayerRace(false, reason) end
    )
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
                checkpoint = math.min(math.max(0, currentCheckpoint - 1), #raceCheckpoints),
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
    local position = 1 + finishedCount  -- 先にゴールした人より後ろ
    
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
    if data.sessionId ~= multiplayerSessionId then return end
    progressData = data.progressData or {}
    finishedCount = data.finishedCount or 0
end)

-- 制限時間切れ
RegisterNetEvent('qbx_racing:client:raceTimeUp', function(data)
    if data.sessionId == multiplayerSessionId then
        RetireMultiplayerRace(true)
    end
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

-- 標準チェックポイント（CreateCheckpoint）の見た目の設定
function GetStandardCheckpointConfig(vehicleType)
    return GetConfigValue('VehicleTypes.' .. (vehicleType or 'car') .. '.checkpoint', {
        type = 0, typeNoArrow = 2, goalType = 4,
        radius = 10.0, height = 5.0, nearHeight = 100.0,
        color = {r = 255, g = 0, b = 0, a = 200},
        goalColor = {r = 255, g = 215, b = 0, a = 200},
        nextColor = {r = 255, g = 255, b = 255, a = 80},
        iconColor = {r = 255, g = 255, b = 255, a = 255}
    })
end

-- 現在のチェックポイント表示を更新（進行に合わせて呼び出す）
function UpdateRaceCheckpoints()
    -- 既存のチェックポイントエンティティを全削除して再生成
    ClearCheckpointEntities()
    
    -- 自作マーカー使用時は RaceDrawThread で毎フレーム描画するため生成しない
    if RaceMarkers.IsEnabled() then return end

    if not currentRace or not isRacing then return end

    local cpConfig = GetStandardCheckpointConfig(currentRace.vehicle_type)

    local lapEnd = LapEndIndex()

    -- 現在のチェックポイント
    if currentCheckpoint <= lapEnd then
        local cp = CheckpointAt(currentCheckpoint)
        local cpPos = vector3(cp.x, cp.y, cp.z)

        -- ゴール判定（スプリントの最終CP or 周回の最終ラップでスタート地点に戻る時）
        local isFinalGoal = IsFinishPosition(currentLap, currentCheckpoint)

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
            local _, nextIdx = NextPosition(currentLap, currentCheckpoint)
            local nextCp = CheckpointAt(nextIdx)
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
    local previewLap, previewIdx = NextPosition(currentLap, currentCheckpoint)
    if previewLap <= GetTotalLaps() and previewIdx <= lapEnd and not IsFinishPosition(currentLap, currentCheckpoint) then
        local nextCp = CheckpointAt(previewIdx)
        local nextPos = vector3(nextCp.x, nextCp.y, nextCp.z)

        -- 次の次のCP方向（矢印用）
        local _, pointToIdx = NextPosition(previewLap, previewIdx)
        local pointToCp = CheckpointAt(pointToIdx)
        local pointToPos = vector3(pointToCp.x, pointToCp.y, pointToCp.z)

        local isNextFinalGoal = IsFinishPosition(previewLap, previewIdx)

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

    DebugLog('Checkpoints updated: current=' .. currentCheckpoint .. '/' .. lapEnd)
end

-- 自作マーカー描画（次のCP・曲がり角ガイド・予告・ゴール）
local function DrawCustomRaceMarkers(turns, isCircuit, vehicleType)
    local total = #raceCheckpoints
    local totalLaps = GetTotalLaps()
    
    -- 次に通過するチェックポイント（周回の最終周はスタート地点がゴール）
    local cp = CheckpointAt(currentCheckpoint)
    local isFinish = IsFinishPosition(currentLap, currentCheckpoint)
    RaceMarkers.Draw(isFinish and 'finish' or 'checkpoint', cp, nil, vehicleType)
    
    -- ルート線（自分の位置から次のCPまで。周回レースは次の周の CP2 へもつなぐ）
    local nextCp = nil
    if not isFinish then
        local nextLap, nextIndex = NextPosition(currentLap, currentCheckpoint)
        if nextLap <= totalLaps then
            nextCp = CheckpointAt(nextIndex)
        end
    end
    RaceMarkers.DrawRouteLine(GetEntityCoords(PlayerPedId()), cp, nextCp,
        isFinish and 'finish' or 'checkpoint', vehicleType)
    
    -- 曲がり角ガイド（このCPに向かっている間、ゴール以外。スタート地点に戻る区間は CP1 のガイド）
    local turnIndex = currentCheckpoint > total and 1 or currentCheckpoint
    if not isFinish and turns[turnIndex] then
        for _, turn in ipairs(turns[turnIndex]) do
            RaceMarkers.DrawTurnGuide(turn, vehicleType)
        end
    end
    
    -- 先のチェックポイントの予告（周回レースは次の周までつなげて表示）
    -- 曲がり角ガイドも、予告しているチェックポイントの分を同じ薄さで表示する
    local showGuidesAhead = RaceMarkers.ShowTurnGuidesAhead()
    local lap, index = currentLap, currentCheckpoint
    for ahead = 1, RaceMarkers.GetPreviewCount() do
        if IsFinishPosition(lap, index) then break end
        lap, index = NextPosition(lap, index)
        
        -- 一周しても足りない短いコースでは今のCPまで戻らないように止める
        if lap > totalLaps or ahead >= total then break end
        
        local previewCp = CheckpointAt(index)
        local alpha = RaceMarkers.GetPreviewAlpha(ahead)
        if IsFinishPosition(lap, index) then
            RaceMarkers.Draw('finish', previewCp, alpha * 0.5, vehicleType)
        else
            RaceMarkers.Draw('preview', previewCp, alpha, vehicleType)
            
            local aheadTurns = showGuidesAhead and turns[index > total and 1 or index]
            for _, turn in ipairs(aheadTurns or {}) do
                RaceMarkers.DrawTurnGuide(turn, vehicleType, alpha)
            end
        end
    end
end

-- レース中のチェックポイント描画スレッド
function RaceDrawThread()
    -- 初回表示
    UpdateRaceCheckpoints()

    -- 標準チェックポイント（CreateCheckpoint）の場合、CP通過時に進行処理
    -- （SoloRaceProgressThread / MultiplayerRaceProgressThread）が UpdateRaceCheckpoints() を
    -- 呼び出すため、ここでは何もしない
    if not RaceMarkers.IsEnabled() then
        DebugLog('RaceDrawThread: checkpoint entities created (no per-frame draw needed)')
        return
    end

    -- 自作マーカーは毎フレーム描画
    local vehicleType = currentRace.vehicle_type or 'car'
    local isCircuit = currentRace.race_type ~= 'sprint'
    local turns = RaceMarkers.BuildTurnGuides(raceCheckpoints, isCircuit, currentRace.turnGuides, vehicleType)
    
    while isRacing and currentRace do
        if currentCheckpoint <= LapEndIndex() then
            DrawCustomRaceMarkers(turns, isCircuit, vehicleType)
        end
        
        Wait(0)
    end
end

-- ===================================
-- スタート前のコース表示（カウントダウン中に向きを確認してもらう）
-- スタート直後に向かうチェックポイント（CP2）と、その先・ルート線・曲がり角ガイドを表示する
-- ===================================
local startPreviewToken = 0
local startPreviewEntities = {}

-- token を渡すと、その表示がまだ続いている時だけ止める（新しい表示を消さないように）
function StopStartPreview(token)
    if token and token ~= startPreviewToken then return end
    startPreviewToken = startPreviewToken + 1
    for _, handle in ipairs(startPreviewEntities) do
        DeleteCheckpoint(handle)
    end
    startPreviewEntities = {}
end

-- 表示を始めて token を返す（race: checkpoints / vehicle_type / race_type / laps / turnGuides）
function StartStartPreview(race)
    StopStartPreview()
    local token = startPreviewToken
    local checkpoints = race and race.checkpoints or {}
    if #checkpoints < 2 then return token end
    
    local vehicleType = race.vehicle_type or 'car'
    local isCircuit = race.race_type ~= 'sprint'
    local isOneLap = not isCircuit or math.max(1, tonumber(race.laps) or 1) == 1
    
    -- スタート後 offset 番目に向かうチェックポイント（0 = CP2）と、それがゴールか
    -- 周回は最後にスタート地点（CP1）へ戻る。2周以上ならそこはゴールではないので、表示はそこまで
    local function PointAt(offset)
        local index = 2 + offset
        if index <= #checkpoints then
            return checkpoints[index], not isCircuit and index == #checkpoints
        elseif isCircuit and index == #checkpoints + 1 then
            return checkpoints[1], isOneLap
        end
        return nil, false
    end
    
    -- 標準チェックポイント: 最初に向かうCP（矢印は次のCPへ）と、その次を薄く表示
    if not RaceMarkers.IsEnabled() then
        local cpConfig = GetStandardCheckpointConfig(vehicleType)
        for offset = 0, 1 do
            local cp, isFinish = PointAt(offset)
            if not cp then break end
            local pos = vector3(cp.x, cp.y, cp.z)
            local nextCp = not isFinish and PointAt(offset + 1) or nil
            local color = offset == 0 and (isFinish and cpConfig.goalColor or cpConfig.color) or cpConfig.nextColor
            local handle = CreateCheckpointEntity(
                isFinish and cpConfig.goalType or cpConfig.type,
                pos, nextCp and vector3(nextCp.x, nextCp.y, nextCp.z) or nil,
                cpConfig.radius, cpConfig.height, color, cpConfig.iconColor, cpConfig.nearHeight
            )
            -- レース中のチェックポイントとは別に管理する
            if handle then
                for i = #activeCheckpointEntities, 1, -1 do
                    if activeCheckpointEntities[i] == handle then table.remove(activeCheckpointEntities, i) break end
                end
                startPreviewEntities[#startPreviewEntities + 1] = handle
            end
            if isFinish then break end
        end
        return token
    end
    
    -- 自作マーカー: 毎フレーム描画
    CreateThread(function()
        local turns = RaceMarkers.BuildTurnGuides(checkpoints, isCircuit, race.turnGuides, vehicleType)
        local previewCount = RaceMarkers.GetPreviewCount()
        
        while startPreviewToken == token do
            local target, targetIsFinish = PointAt(0)
            local kind = targetIsFinish and 'finish' or 'checkpoint'
            local nextCp = not targetIsFinish and PointAt(1) or nil
            
            RaceMarkers.Draw(kind, target, nil, vehicleType)
            RaceMarkers.DrawRouteLine(GetEntityCoords(PlayerPedId()), target, nextCp, kind, vehicleType)
            
            if not targetIsFinish then
                for _, turn in ipairs(turns[2] or {}) do
                    RaceMarkers.DrawTurnGuide(turn, vehicleType)
                end
                
                local showGuidesAhead = RaceMarkers.ShowTurnGuidesAhead()
                for ahead = 1, previewCount do
                    local cp, isFinish = PointAt(ahead)
                    if not cp then break end
                    local alpha = RaceMarkers.GetPreviewAlpha(ahead)
                    if isFinish then
                        RaceMarkers.Draw('finish', cp, alpha * 0.5, vehicleType)
                        break
                    end
                    RaceMarkers.Draw('preview', cp, alpha, vehicleType)
                    
                    -- 予告しているチェックポイントの曲がり角ガイド（周回でスタート地点に戻る区間は CP1 のガイド）
                    local index = 2 + ahead
                    local aheadTurns = showGuidesAhead and turns[index > #checkpoints and 1 or index]
                    for _, turn in ipairs(aheadTurns or {}) do
                        RaceMarkers.DrawTurnGuide(turn, vehicleType, alpha)
                    end
                end
            end
            
            Wait(0)
        end
    end)
    
    return token
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
    
    -- ソロのカウントダウン中に止めた車両を解除（カウントダウン中は isRacing が false のため個別に）
    if soloCountdownVehicle ~= 0 and DoesEntityExist(soloCountdownVehicle) then
        FreezeEntityPosition(soloCountdownVehicle, false)
    end
    soloCountdownVehicle = 0
    StopStartPreview()
    
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
    
    print('^2[CAM Racing]^7 レースロジック停止完了')
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

-- レース中、またはスタート地点へ移動中・カウントダウン中
function IsRaceBusy()
    return isRacing or currentRace ~= nil
end

-- ===================================
-- 初期化
-- ===================================
CreateThread(function()
    print('^2[CAM Racing]^7 レースロジック起動完了')
    
    if DEBUG_MODE then
        print('^3[CAM Racing]^7 デバッグモードが有効です（race_logic.lua）')
    end
end)
