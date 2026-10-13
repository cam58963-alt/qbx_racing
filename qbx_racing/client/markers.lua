-- ===================================
-- QBX Racing System - Custom Checkpoint Markers
-- 自作画像のチェックポイントマーカー描画
-- ===================================

RaceMarkers = {}

local markerConfig = Config.Checkpoint and Config.Checkpoint.customMarker or {}
local isTextureReady = false

-- 乗り物ごとの画像セット（vehicleTypes にない乗り物は共通の styles を使う）
local activeVehicleType = nil
local activeSet = nil

-- 画像をランタイムテクスチャとして登録（.ytd不要、PNGをそのまま使用）
local function LoadMarkerTextures()
    if not markerConfig.enabled or not markerConfig.styles then return end

    -- 次のCPとゴールの画像がないと表示が消えるため、標準チェックポイントに戻す
    if not markerConfig.styles.checkpoint or not markerConfig.styles.finish then
        print('^3[QBX Racing]^7 customMarker.styles に checkpoint / finish がないため、標準チェックポイントを使用します')
        return
    end

    local txd = CreateRuntimeTxd(markerConfig.textureDict)
    for kind, style in pairs(markerConfig.styles) do
        CreateRuntimeTextureFromImage(txd, kind, style.image)
    end

    -- 乗り物ごとの画像はテクスチャ名を「乗り物_種類」にする（例: heli_checkpoint）
    for vehicleType, set in pairs(markerConfig.vehicleTypes or {}) do
        for kind, style in pairs(set.styles or {}) do
            CreateRuntimeTextureFromImage(txd, vehicleType .. '_' .. kind, style.image)
        end
    end

    isTextureReady = true
end

-- 自作マーカーが使えるか
function RaceMarkers.IsEnabled()
    return isTextureReady
end

-- 使う画像セットを乗り物の種類で切り替える（'car' / 'heli' / 'boat'）
function RaceMarkers.SetVehicleType(vehicleType)
    activeVehicleType = vehicleType
    activeSet = vehicleType and markerConfig.vehicleTypes and markerConfig.vehicleTypes[vehicleType] or nil
end

-- 乗り物ごとの設定を優先して取得
local function GetOption(key)
    if activeSet and activeSet[key] ~= nil then return activeSet[key] end
    return markerConfig[key]
end

-- 乗り物ごとの画像を優先し、なければ共通の画像を使う
local function ResolveStyle(kind)
    local styles = activeSet and activeSet.styles
    if styles and styles[kind] then
        return styles[kind], activeVehicleType .. '_' .. kind
    end
    return markerConfig.styles[kind], kind
end

-- 反応範囲の丸を描画
local function DrawRangeCircle(pos, z, color, alpha)
    local ring = GetOption('radiusRing')
    if not ring or not ring.enabled then return end

    local diameter = pos.radius * 2
    local alphaRate = alpha / 255

    -- 薄い塗り（円柱）
    if ring.fill ~= false then
        DrawMarker(
            1,
            pos.x, pos.y, z,
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
            diameter, diameter, ring.fillHeight or ring.height or 0.6,
            color.r, color.g, color.b,
            math.floor((ring.fillAlpha or ring.alpha or 40) * alphaRate),
            false, false, 2, false, nil, nil, false
        )
    end

    -- 輪郭線（水平の丸）
    if ring.outline ~= false then
        DrawMarker(
            ring.outlineType or 25,
            pos.x, pos.y, z + 0.05,
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
            diameter, diameter, 1.0,
            color.r, color.g, color.b,
            math.floor((ring.outlineAlpha or 200) * alphaRate),
            false, false, 2, false, nil, nil, false
        )
    end
end

-- 自作マーカーを描画
-- kind: styles のキー（'checkpoint' / 'preview' / 'finish' / 'turn_left' / 'turn_right'）
-- pos: x, y, z（radius があれば反応範囲の丸も描画）
-- 無効時・未設定時は false を返すので、呼び出し側で標準マーカーを描画する
function RaceMarkers.Draw(kind, pos, alphaScale)
    if not isTextureReady then return false end

    local style, textureName = ResolveStyle(kind)
    if not style then return false end

    -- 大きさ: 画像ごとの size > 反応範囲に合わせる（sizeFromRadius） > 共通の size
    local sizeFromRadius = style.sizeFromRadius or GetOption('sizeFromRadius')
    local size = style.size
        or (sizeFromRadius and pos.radius and pos.radius * sizeFromRadius)
        or GetOption('size') or 12.0
    local anchor = style.groundAnchor or GetOption('groundAnchor') or 0.0
    local rotation = GetOption('rotation') or vector3(90.0, 0.0, 0.0)
    local alpha = math.floor((style.alpha or 255) * (alphaScale or 1.0))
    local groundZ = pos.z - 1.0

    -- 空中のマーカー（ヘリ）はチェックポイントの位置を中心に、
    -- 地上のマーカーは画像の地面リング部分が地面に来るように高さを調整
    local isCentered = GetOption('centerOnPoint')
    local markerZ = isCentered and pos.z or groundZ + size * (0.5 - anchor)

    DrawMarker(
        9,
        pos.x, pos.y, markerZ,
        0.0, 0.0, 0.0,
        rotation.x, rotation.y, rotation.z,
        size, size, size,
        255, 255, 255, alpha,
        false, GetOption('faceCamera') ~= false, 2, false,
        markerConfig.textureDict, textureName, false
    )

    -- 反応範囲の丸
    if style.ringColor and pos.radius then
        DrawRangeCircle(pos, isCentered and pos.z or groundZ, style.ringColor, alpha)
    end

    return true
end

-- 予告表示する個数
function RaceMarkers.GetPreviewCount()
    local preview = markerConfig.preview
    if not preview or not preview.enabled then return 0 end
    return preview.count or 4
end

-- 予告表示の透明度（ahead: 何個先か、1 = 次の次）
function RaceMarkers.GetPreviewAlpha(ahead)
    local fadeStep = markerConfig.preview and markerConfig.preview.fadeStep or 0.2
    return math.max(0.1, 1.0 - (ahead - 1) * fadeStep)
end

-- 2Dベクトルを正規化
local function Normalize2D(x, y)
    local length = math.sqrt(x * x + y * y)
    if length < 0.001 then return nil end
    return x / length, y / length
end

-- 前後のチェックポイント（周回レースは最初と最後をつなげる）
local function GetNeighbors(checkpoints, index, isCircuit)
    local total = #checkpoints
    local prev = checkpoints[index - 1] or (isCircuit and checkpoints[total]) or nil
    local nextCp = checkpoints[index + 1] or (isCircuit and checkpoints[1]) or nil
    local cp = checkpoints[index]
    if prev == cp then prev = nil end
    if nextCp == cp then nextCp = nil end
    return prev, nextCp
end

-- コースの向きから曲がる方向を判定（'left' / 'right' / nil）
local function DetectTurnDirection(checkpoints, index, isCircuit)
    local guide = markerConfig.turnGuide
    local cp = checkpoints[index]
    local prev, nextCp = GetNeighbors(checkpoints, index, isCircuit)
    if not prev or not nextCp then return nil end

    local inX, inY = Normalize2D(cp.x - prev.x, cp.y - prev.y)
    local outX, outY = Normalize2D(nextCp.x - cp.x, nextCp.y - cp.y)
    if not inX or not outX then return nil end

    -- 符号付きの角度（正 = 左曲がり、負 = 右曲がり）
    local cross = inX * outY - inY * outX
    local dot = inX * outX + inY * outY
    local angle = math.atan(cross, dot)

    if math.abs(angle) < math.rad(guide.minAngle or 35.0) then return nil end
    return angle > 0 and 'left' or 'right'
end

-- 曲がり角ガイドの表示情報（緑のチェックポイントの横、曲がる側に置く）
-- 戻り値: { kind = 'turn_left' / 'turn_right', x, y, z }
function RaceMarkers.GetTurnGuide(checkpoints, index, isCircuit, direction)
    local cp = checkpoints[index]
    local prev, nextCp = GetNeighbors(checkpoints, index, isCircuit)

    -- 進入方向（最初のCPなどで前がなければ次のCPへの方向）
    local dirX, dirY
    if prev then dirX, dirY = Normalize2D(cp.x - prev.x, cp.y - prev.y) end
    if not dirX and nextCp then dirX, dirY = Normalize2D(nextCp.x - cp.x, nextCp.y - cp.y) end

    local isLeft = direction == 'left'
    local guide = {kind = isLeft and 'turn_left' or 'turn_right', x = cp.x, y = cp.y, z = cp.z}
    if not dirX then return guide end

    -- 進行方向の左 = (-dirY, dirX)、右 = (dirY, -dirX)
    local sideX, sideY = -dirY, dirX
    if not isLeft then sideX, sideY = dirY, -dirX end

    local offset = GetOption('turnGuideSideOffset')
        or (markerConfig.turnGuide and markerConfig.turnGuide.sideOffset) or 6.0
    guide.x = cp.x + sideX * offset
    guide.y = cp.y + sideY * offset
    return guide
end

-- 各チェックポイントの曲がり角ガイドを作る
-- manualGuides: 手動で付けた方向（{ checkpoint_order, direction } のリスト）
-- 戻り値: turns[i] = { kind, x, y, z }（曲がらない場合は nil）
function RaceMarkers.BuildTurnGuides(checkpoints, isCircuit, manualGuides)
    local turns = {}
    local guide = markerConfig.turnGuide
    if not guide or not guide.enabled then return turns end

    -- 手動で付けた方向
    local manual = {}
    local hasManual = false
    for _, turnGuide in ipairs(manualGuides or {}) do
        local order = tonumber(turnGuide.checkpoint_order)
        if order and checkpoints[order] then
            manual[order] = turnGuide.direction
            hasManual = true
        end
    end

    -- 手動がある場合は手動だけ（manualOverridesAuto = false なら自動も併用し、同じCPは手動を優先）
    local useAuto = guide.auto ~= false and not (hasManual and guide.manualOverridesAuto ~= false)

    for i = 1, #checkpoints do
        local direction = manual[i] or (useAuto and DetectTurnDirection(checkpoints, i, isCircuit))
        if direction then
            turns[i] = RaceMarkers.GetTurnGuide(checkpoints, i, isCircuit, direction)
        end
    end

    return turns
end

LoadMarkerTextures()
