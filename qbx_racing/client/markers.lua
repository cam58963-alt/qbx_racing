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

    -- 次のCPとゴールの画像がないと表示が消えるため、標準チェックポイントに戻す
    if not markerConfig.styles.checkpoint or not markerConfig.styles.finish then
        print('^3[QBX Racing]^7 customMarker.styles に checkpoint / finish がないため、標準チェックポイントを使用します')
        return
    end

    local txd = CreateRuntimeTxd(markerConfig.textureDict)
    for kind, style in pairs(markerConfig.styles) do
        CreateRuntimeTextureFromImage(txd, kind, style.image)
    end

    -- ルート線の1区切り（白い画像に DrawMarker で色を付ける）
    if markerConfig.routeLine and markerConfig.routeLine.image then
        CreateRuntimeTextureFromImage(txd, 'route_dash', markerConfig.routeLine.image)
    end

    -- 乗り物ごとの画像はテクスチャ名を「乗り物_種類」にする（例: heli_checkpoint）
    -- 書いていない項目（画像を含む）は共通の styles で補う
    for vehicleType, set in pairs(markerConfig.vehicleTypes or {}) do
        -- radiusRing / routeLine などの入れ子の設定も、書いていない項目は共通の設定で補う
        for key, value in pairs(set) do
            if key ~= 'styles' and type(value) == 'table' and type(markerConfig[key]) == 'table' then
                setmetatable(value, {__index = markerConfig[key]})
            end
        end

        for kind, style in pairs(set.styles or {}) do
            local base = markerConfig.styles[kind]
            if base then setmetatable(style, {__index = base}) end

            if rawget(style, 'image') then
                CreateRuntimeTextureFromImage(txd, vehicleType .. '_' .. kind, style.image)
            end
        end

        -- 乗り物ごとのルート線の画像
        if type(set.routeLine) == 'table' and rawget(set.routeLine, 'image') then
            CreateRuntimeTextureFromImage(txd, vehicleType .. '_route_dash', set.routeLine.image)
        end
    end

    isTextureReady = true
end

-- 自作マーカーが使えるか
function RaceMarkers.IsEnabled()
    return isTextureReady
end

-- 乗り物ごとの画像セット（'car' / 'heli' / 'boat'、vehicleTypes にない乗り物は nil）
-- レースとコース作成が同時に動いても混ざらないよう、描画ごとに乗り物の種類を渡す
local function GetSet(vehicleType)
    return vehicleType and markerConfig.vehicleTypes and markerConfig.vehicleTypes[vehicleType] or nil
end

-- 乗り物ごとの設定を優先して取得
local function GetOption(set, key)
    if set and set[key] ~= nil then return set[key] end
    return markerConfig[key]
end

-- 乗り物ごとの画像を優先し、なければ共通の画像を使う
local function ResolveStyle(set, vehicleType, kind)
    local style = set and set.styles and set.styles[kind]
    if style then
        -- 自分の画像があればそれを、なければ共通の画像（テクスチャ）を使う
        if rawget(style, 'image') then
            return style, vehicleType .. '_' .. kind
        elseif markerConfig.styles[kind] then
            return style, kind
        end
    end
    return markerConfig.styles[kind], kind
end

-- 反応範囲の丸を描画
local function DrawRangeCircle(set, pos, z, color, alpha)
    local ring = GetOption(set, 'radiusRing')
    if not ring or not ring.enabled then return end

    local diameter = pos.radius * 2
    local alphaRate = alpha / 255

    -- 半透明の球（空中の反応範囲。チェックポイントからこの半径以内で通過判定）
    if ring.sphere then
        local sphereSize = pos.radius * (ring.sphereScale or 1.0)
        DrawMarker(
            28,
            pos.x, pos.y, z,
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
            sphereSize, sphereSize, sphereSize,
            color.r, color.g, color.b,
            math.floor((ring.sphereAlpha or 50) * alphaRate),
            false, false, 2, false, nil, nil, false
        )
    end

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
-- vehicleType: 乗り物の種類（乗り物ごとの画像セットを使う）
-- 無効時・未設定時は false を返すので、呼び出し側で標準マーカーを描画する
function RaceMarkers.Draw(kind, pos, alphaScale, vehicleType)
    if not isTextureReady then return false end

    local set = GetSet(vehicleType)
    local style, textureName = ResolveStyle(set, vehicleType, kind)
    if not style then return false end

    -- 大きさ: この画像に書いた size > 反応範囲に合わせる（sizeFromRadius） > 共通の画像の size > 全体の size
    local sizeFromRadius = style.sizeFromRadius or GetOption(set, 'sizeFromRadius')
    local size = rawget(style, 'size')
        or (sizeFromRadius and pos.radius and pos.radius * sizeFromRadius)
        or style.size
        or GetOption(set, 'size') or 12.0
    local anchor = style.groundAnchor or GetOption(set, 'groundAnchor') or 0.0
    local rotation = GetOption(set, 'rotation') or vector3(90.0, 0.0, 0.0)
    local alpha = math.floor((style.alpha or 255) * (alphaScale or 1.0))
    local groundZ = pos.z - 1.0

    -- 空中のマーカー（ヘリ）はチェックポイントの位置を中心に、
    -- 地上のマーカーは画像の地面リング部分が地面に来るように高さを調整
    local isCentered = GetOption(set, 'centerOnPoint')
    local markerZ = isCentered and pos.z or groundZ + size * (0.5 - anchor)

    -- showImage = false の場合は画像を出さず、反応範囲の表示だけにする
    if style.showImage ~= false then
        DrawMarker(
            9,
            pos.x, pos.y, markerZ,
            0.0, 0.0, 0.0,
            rotation.x, rotation.y, rotation.z,
            size, size, size,
            255, 255, 255, alpha,
            false, GetOption(set, 'faceCamera') ~= false, 2, false,
            markerConfig.textureDict, textureName, false
        )
    end

    -- 反応範囲の丸
    if style.ringColor and pos.radius then
        DrawRangeCircle(set, pos, isCentered and pos.z or groundZ, style.ringColor, alpha)
    end

    return true
end

-- ===================================
-- ルート線
-- from = 'player'    : 自分の位置から次のチェックポイントまで
-- from = 'checkpoint': 次のチェックポイントからその次のチェックポイントまで
-- ===================================

-- 区切りの位置は一定間隔でまとめて計算し、毎フレームは描画だけ行う
local routeCache = {time = 0, target = nil, points = {}}

-- from から target までの区切りの位置を計算（startDistance: from から何メートル先から並べるか）
local function BuildRoutePoints(from, target, route, startDistance)
    local points = {}
    local dx, dy, dz = target.x - from.x, target.y - from.y, target.z - from.z
    local total = math.sqrt(dx * dx + dy * dy + dz * dz)
    if total < 0.01 then return points end

    -- チェックポイントの反応範囲の手前まで、最大 maxDistance まで
    local length = math.min(total - (target.radius or 10.0) * 0.5, route.maxDistance or 60.0)
    local spacing = route.spacing or 4.0
    local heading = GetHeadingFromVector_2d(dx, dy)

    local distance = startDistance
    while distance <= length do
        local rate = distance / total
        local x, y, z = from.x + dx * rate, from.y + dy * rate, from.z + dz * rate

        if route.followGround ~= false then
            -- 地面に沿わせる（見つからなければ足元の高さ）
            local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 3.0, false)
            z = (found and groundZ or z - 1.0) + 0.05
        end

        table.insert(points, {
            x = x, y = y, z = z,
            heading = heading,
            fade = 1.0 - (distance / math.max(length, 0.01)) * 0.7
        })
        distance = distance + spacing
    end

    return points
end

-- ルート線を描画
-- playerPos: 自分の位置、target: 次のチェックポイント、nextCp: その次（nil 可）
-- targetKind: 目標の画像の種類（線の色を合わせる）
function RaceMarkers.DrawRouteLine(playerPos, target, nextCp, targetKind, vehicleType)
    if not isTextureReady then return end

    local set = GetSet(vehicleType)
    local route = GetOption(set, 'routeLine')
    if not route or not route.enabled then return end

    local style = ResolveStyle(set, vehicleType, targetKind)
    local color = route.color or (style and style.ringColor) or {r = 255, g = 255, b = 255}
    local fromCheckpoint = route.from == 'checkpoint'

    -- 自分から引く線は動くたびに再計算、チェックポイント同士の線は目標が変わった時だけ計算
    local now = GetGameTimer()
    local isStale = routeCache.target ~= target
        or (not fromCheckpoint and now - routeCache.time >= (route.updateInterval or 100))
    if isStale then
        if fromCheckpoint then
            -- チェックポイントの反応範囲の外から並べる（その次がない＝ゴール前は線なし）
            routeCache.points = nextCp
                and BuildRoutePoints(target, nextCp, route, target.radius or 10.0)
                or {}
        else
            routeCache.points = BuildRoutePoints(playerPos, target, route, route.startDistance or 4.0)
        end
        routeCache.target = target
        routeCache.time = now
    end

    -- 乗り物ごとの画像があればそれを、なければ共通の画像を使う
    local textureName = 'route_dash'
    if set and type(set.routeLine) == 'table' and rawget(set.routeLine, 'image') then
        textureName = vehicleType .. '_route_dash'
    end

    local size = route.size or 3.0
    local alpha = route.alpha or 200
    for _, point in ipairs(routeCache.points) do
        DrawMarker(
            9,
            point.x, point.y, point.z,
            0.0, 0.0, 0.0,
            0.0, 0.0, point.heading + (route.rotationOffset or 0.0),
            size, size, size,
            color.r, color.g, color.b, math.floor(alpha * point.fade),
            false, false, 2, false,
            markerConfig.textureDict, textureName, false
        )
    end

    -- 次のチェックポイントからその次へ細い線
    if route.linkNext and nextCp then
        local linkColor = route.linkColor or color
        DrawLine(
            target.x, target.y, target.z,
            nextCp.x, nextCp.y, nextCp.z,
            linkColor.r, linkColor.g, linkColor.b, route.linkAlpha or 150
        )
    end
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

-- 長いガイドを並べる向き（CP index へ近づいてくる方向に対して横＝壁に沿う向き）
-- 戻り値: axisX, axisY（求められない場合は nil）
function RaceMarkers.GetGuideAxis(checkpoints, index, isCircuit)
    local cp = checkpoints[index]
    if not cp then return nil end

    local prev, nextCp = GetNeighbors(checkpoints, index, isCircuit)
    local dirX, dirY
    if prev then dirX, dirY = Normalize2D(cp.x - prev.x, cp.y - prev.y) end
    if not dirX and nextCp then dirX, dirY = Normalize2D(nextCp.x - cp.x, nextCp.y - cp.y) end
    if not dirX then return nil end

    return -dirY, dirX
end

-- 自動の曲がり角ガイド（コースの向きから判定し、カーブの外側に置く）
-- 戻り値: { kind = 'turn_left' / 'turn_right', x, y, z, segments }（曲がらない場合は nil）
local function GetAutoTurnGuide(checkpoints, index, isCircuit, vehicleType)
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

    local isLeft = angle > 0

    -- カーブの外側（進入と脱出の中間方向に対して垂直、曲がる方向の反対側）
    local midX, midY = Normalize2D(inX + outX, inY + outY)
    midX, midY = midX or inX, midY or inY
    local sideX, sideY
    if isLeft then
        sideX, sideY = midY, -midX   -- 左曲がりの外側 = 右側
    else
        sideX, sideY = -midY, midX   -- 右曲がりの外側 = 左側
    end

    local distance = GetOption(GetSet(vehicleType), 'turnGuideDistance') or guide.distance or 12.0

    -- 急なカーブは横に長いガイドにする
    local segments = 1
    if guide.autoLongAngle and math.abs(angle) >= math.rad(guide.autoLongAngle) then
        segments = guide.autoLongSegments or 3
    end

    return {
        kind = isLeft and 'turn_left' or 'turn_right',
        x = cp.x + sideX * distance,
        y = cp.y + sideY * distance,
        z = cp.z,
        segments = segments
    }
end

-- 一番近いチェックポイントの番号（手動ガイドの紐づけ先）
function RaceMarkers.FindNearestCheckpoint(checkpoints, pos)
    local nearestIndex, nearestDistance = nil, math.huge
    for i, cp in ipairs(checkpoints) do
        local dx, dy, dz = cp.x - pos.x, cp.y - pos.y, cp.z - pos.z
        local distance = dx * dx + dy * dy + dz * dz
        if distance < nearestDistance then
            nearestIndex, nearestDistance = i, distance
        end
    end
    return nearestIndex
end

-- 各チェックポイントの曲がり角ガイドを作る
-- manualGuides: 手動で置いたガイド（{ checkpoint_order, x, y, z, direction, segments } のリスト）
-- 戻り値: turns[i] = { { kind, x, y, z, segments, axisX, axisY }, ... }（CP i に向かっている間に表示）
function RaceMarkers.BuildTurnGuides(checkpoints, isCircuit, manualGuides, vehicleType)
    local turns = {}
    local guide = markerConfig.turnGuide
    if not guide or not guide.enabled then return turns end

    local function Add(index, turnGuide)
        turnGuide.axisX, turnGuide.axisY = RaceMarkers.GetGuideAxis(checkpoints, index, isCircuit)
        turns[index] = turns[index] or {}
        table.insert(turns[index], turnGuide)
    end

    -- 手動で置いたガイド（置いた場所に表示）
    local hasManual = false
    for _, manual in ipairs(manualGuides or {}) do
        local order = tonumber(manual.checkpoint_order)
        if order and checkpoints[order] then
            Add(order, {
                kind = manual.direction == 'left' and 'turn_left' or 'turn_right',
                x = manual.x,
                y = manual.y,
                z = manual.z,
                segments = tonumber(manual.segments) or 1
            })
            hasManual = true
        end
    end

    -- 自動ガイド（手動ガイドがあるコースでは manualOverridesAuto = false のときだけ併用）
    if guide.auto ~= false and not (hasManual and guide.manualOverridesAuto ~= false) then
        for i = 1, #checkpoints do
            local autoGuide = GetAutoTurnGuide(checkpoints, i, isCircuit, vehicleType)
            if autoGuide then Add(i, autoGuide) end
        end
    end

    return turns
end

-- 曲がり角ガイドを描画（segments が 2 以上なら、光の柱のない矢印を横に並べて長くする）
-- guide: { kind, x, y, z, segments, axisX, axisY }
function RaceMarkers.DrawTurnGuide(guide, vehicleType, alphaScale)
    local segments = guide.segments or 1
    if segments <= 1 or not guide.axisX then
        return RaceMarkers.Draw(guide.kind, guide, alphaScale, vehicleType)
    end

    local stripKind = guide.kind == 'turn_left' and 'turn_strip_left' or 'turn_strip_right'
    local spacing = GetOption(GetSet(vehicleType), 'turnGuideSegmentSpacing')
        or (markerConfig.turnGuide and markerConfig.turnGuide.segmentSpacing) or 2.0

    -- 置いた場所を中心に、壁に沿う向きへ並べる
    local drawn = false
    for i = 1, segments do
        local offset = (i - (segments + 1) / 2) * spacing
        local segment = {
            x = guide.x + guide.axisX * offset,
            y = guide.y + guide.axisY * offset,
            z = guide.z
        }
        drawn = RaceMarkers.Draw(stripKind, segment, alphaScale, vehicleType) or drawn
    end

    -- 長いガイド用の画像（turn_strip_*）がない設定なら、通常の矢印1つで表示する
    if not drawn then
        return RaceMarkers.Draw(guide.kind, guide, alphaScale, vehicleType)
    end
    return drawn
end

LoadMarkerTextures()
