-- ===================================
-- QBX Racing System - Custom Checkpoint Markers
-- 自作画像のチェックポイントマーカー描画
-- ===================================

RaceMarkers = {}

local markerConfig = Config.Checkpoint and Config.Checkpoint.customMarker or {}
local isTextureReady = false

-- 画像をランタイムテクスチャとして登録（.ytd不要、PNGをそのまま使用）
local function LoadMarkerTextures()
    if not markerConfig.enabled or not markerConfig.styles then return end

    local txd = CreateRuntimeTxd(markerConfig.textureDict)
    for kind, style in pairs(markerConfig.styles) do
        CreateRuntimeTextureFromImage(txd, kind, style.image)
    end

    isTextureReady = true
end

-- 自作マーカーが使えるか
function RaceMarkers.IsEnabled()
    return isTextureReady
end

-- 自作マーカーを描画
-- kind: styles のキー（'checkpoint' / 'preview' / 'finish' / 'turn_left' / 'turn_right'）
-- pos: x, y, z（radius があれば判定範囲リングも描画）
-- 無効時・未設定時は false を返すので、呼び出し側で標準マーカーを描画する
function RaceMarkers.Draw(kind, pos, alphaScale)
    if not isTextureReady then return false end

    local style = markerConfig.styles[kind]
    if not style then return false end

    local size = style.size or markerConfig.size or 12.0
    local anchor = style.groundAnchor or markerConfig.groundAnchor or 0.0
    local rotation = markerConfig.rotation or vector3(90.0, 0.0, 0.0)
    local alpha = math.floor((style.alpha or 255) * (alphaScale or 1.0))
    local groundZ = pos.z - 1.0

    -- 画像の地面リング部分が地面に来るように中心の高さを調整
    DrawMarker(
        9,
        pos.x, pos.y, groundZ + size * (0.5 - anchor),
        0.0, 0.0, 0.0,
        rotation.x, rotation.y, rotation.z,
        size, size, size,
        255, 255, 255, alpha,
        false, markerConfig.faceCamera ~= false, 2, false,
        markerConfig.textureDict, kind, false
    )

    -- 判定範囲を示す薄いリング
    local ring = markerConfig.radiusRing
    if ring and ring.enabled and style.ringColor and pos.radius then
        DrawMarker(
            1,
            pos.x, pos.y, groundZ,
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
            pos.radius * 2, pos.radius * 2, ring.height or 0.6,
            style.ringColor.r, style.ringColor.g, style.ringColor.b,
            math.floor((ring.alpha or 60) * alpha / 255),
            false, false, 2, false, nil, nil, false
        )
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

-- 各チェックポイントの曲がり方向を計算
-- 戻り値: turns[i] = { kind = 'turn_left' / 'turn_right', x, y, z }（曲がらない場合は nil）
function RaceMarkers.ComputeTurns(checkpoints, isCircuit)
    local turns = {}
    local guide = markerConfig.turnGuide
    if not guide or not guide.enabled or guide.auto == false then return turns end

    local minAngle = math.rad(guide.minAngle or 35.0)
    local total = #checkpoints

    for i, cp in ipairs(checkpoints) do
        -- 周回レースは最初と最後をつなげて判定
        local prev = checkpoints[i - 1] or (isCircuit and checkpoints[total])
        local nextCp = checkpoints[i + 1] or (isCircuit and checkpoints[1])

        if prev and nextCp and prev ~= cp and nextCp ~= cp then
            local inX, inY = Normalize2D(cp.x - prev.x, cp.y - prev.y)
            local outX, outY = Normalize2D(nextCp.x - cp.x, nextCp.y - cp.y)

            if inX and outX then
                -- 符号付きの角度（正 = 左曲がり、負 = 右曲がり）
                local cross = inX * outY - inY * outX
                local dot = inX * outX + inY * outY
                local angle = math.atan(cross, dot)

                if math.abs(angle) >= minAngle then
                    local isLeft = angle > 0

                    -- コーナーの外側にガイドを置く（進入と脱出の中間方向に対して垂直）
                    local midX, midY = Normalize2D(inX + outX, inY + outY)
                    midX, midY = midX or inX, midY or inY
                    local sideX, sideY
                    if isLeft then
                        sideX, sideY = midY, -midX   -- 左曲がりの外側 = 右側
                    else
                        sideX, sideY = -midY, midX   -- 右曲がりの外側 = 左側
                    end

                    local distance = (cp.radius or 10.0) + (guide.offset or 4.0)
                    turns[i] = {
                        kind = isLeft and 'turn_left' or 'turn_right',
                        x = cp.x + sideX * distance,
                        y = cp.y + sideY * distance,
                        z = cp.z
                    }
                end
            end
        end
    end

    return turns
end

-- 手動設置の曲がり角ガイドをチェックポイントごとにまとめる
-- 戻り値: guides[i] = { { kind, x, y, z }, ... }、手動ガイドがあるか
function RaceMarkers.GroupManualGuides(turnGuides)
    local guides = {}
    local hasAny = false
    local guide = markerConfig.turnGuide
    if not guide or not guide.enabled then return guides, hasAny end

    for _, turnGuide in ipairs(turnGuides or {}) do
        local order = tonumber(turnGuide.checkpoint_order)
        if order then
            guides[order] = guides[order] or {}
            table.insert(guides[order], {
                kind = turnGuide.direction == 'left' and 'turn_left' or 'turn_right',
                x = turnGuide.x,
                y = turnGuide.y,
                z = turnGuide.z
            })
            hasAny = true
        end
    end

    return guides, hasAny
end

-- 手動ガイドがあるコースで自動ガイドを止めるか
function RaceMarkers.ManualOverridesAuto()
    local guide = markerConfig.turnGuide
    return not guide or guide.manualOverridesAuto ~= false
end

LoadMarkerTextures()
