-- ===================================
-- CAM Racing System - タイムアタック・デイリーレース・ランキング
-- server/main.lua の後に読み込む（RacingServer の関数を使う）
-- ===================================

local GetConfigValue = RacingServer.GetConfigValue
local FormatMoney = RacingServer.FormatMoney
local GetPlayer = RacingServer.GetPlayer
local ToInteger = RacingServer.ToInteger
local GetDriverProfile = RacingServer.GetDriverProfile
local HasRacePermission = RacingServer.HasRacePermission
local RecordPayouts = RacingServer.RecordPayouts
local SettlePayouts = RacingServer.SettlePayouts

-- TA・デイリーの報酬は特定のセッションに属さないので、台帳の session_id は 0 で記録する
local PROGRESSION_SESSION_ID = 0

Progression = {}

-- ===================================
-- ヘルパー
-- ===================================

local function TimeAttackEnabled() return GetConfigValue('TimeAttack.enabled', true) == true end
local function DailyEnabled() return GetConfigValue('Daily.enabled', true) == true end
local function RankingEnabled() return GetConfigValue('Ranking.enabled', true) == true end

-- 1:23.456 形式
local function FormatTimeMs(ms)
    ms = ToInteger(ms)
    if not ms then return '--:--.---' end
    return string.format('%d:%02d.%03d', ms // 60000, (ms // 1000) % 60, ms % 1000)
end

-- 今日の日付（デイリーの区切り。サーバーの OS の時刻で 0 時に切り替わる）
local function Today()
    return os.date('%Y-%m-%d')
end

local function GetCalibrationRuns()
    return math.max(1, ToInteger(GetConfigValue('TimeAttack.calibrationRuns', 10)) or 10)
end

-- コースの長さ（m）と通過するチェックポイントの数
-- 周回は毎周スタート地点（CP1）に戻る
local function CourseLength(race, checkpoints)
    local laps = race.race_type == 'sprint' and 1 or math.max(1, ToInteger(race.laps) or 1)
    local function dist(a, b)
        return #(vector3(a.x, a.y, a.z) - vector3(b.x, b.y, b.z))
    end
    local lap = 0
    for i = 2, #checkpoints do
        lap = lap + dist(checkpoints[i - 1], checkpoints[i])
    end
    if race.race_type ~= 'sprint' and #checkpoints > 1 then
        lap = lap + dist(checkpoints[#checkpoints], checkpoints[1])
    end
    return lap * laps, #checkpoints * laps
end

-- TA の報酬（レート × 単位額）。コースの長さ・チェックポイント数・目標タイムから計算
local function CalculateTimeAttackReward(lengthM, gates, targetMs)
    local cfg = GetConfigValue('TimeAttack.reward', {})
    cfg = type(cfg) == 'table' and cfg or {}
    local score = (lengthM / 1000) * (tonumber(cfg.distanceWeight) or 0.5)
        + gates * (tonumber(cfg.checkpointWeight) or 0.05)
        + (targetMs / 60000) * (tonumber(cfg.timeWeight) or 0.5)
    local minRate = ToInteger(cfg.minRate) or 1
    local maxRate = math.max(minRate, ToInteger(cfg.maxRate) or 15)
    local rate = math.max(minRate, math.min(maxRate, math.floor(score + 0.5)))
    return rate * (ToInteger(cfg.unit) or 1000000), rate
end

-- ランキングのポイントを増減する（0 未満にはならない）
local function AddRankingPoints(citizenid, delta, reason, raceId)
    delta = ToInteger(delta)
    if not citizenid or not delta or delta == 0 then return false end
    return MySQL.transaction.await({
        {
            query = 'UPDATE qbx_driver_profiles SET points = GREATEST(0, COALESCE(points, ?) + ?) WHERE citizenid = ?',
            values = {ToInteger(GetConfigValue('Ranking.startPoints', 1000)) or 1000, delta, citizenid}
        },
        {
            query = 'INSERT INTO qbx_ranking_log (citizenid, delta, reason, race_id) VALUES (?, ?, ?, ?)',
            values = {citizenid, delta, reason, raceId}
        }
    }) and true or false
end

-- 今日すでに同じ理由で同じレースのポイントをもらったか（ソロの稼ぎすぎ防止）
local function RankingGivenToday(citizenid, reason, raceId)
    return MySQL.scalar.await([[
        SELECT 1 FROM qbx_ranking_log
        WHERE citizenid = ? AND reason = ? AND race_id = ? AND created_at >= CURDATE() LIMIT 1
    ]], {citizenid, reason, raceId}) ~= nil
end

local function GetRank(points)
    local higher = MySQL.scalar.await('SELECT COUNT(*) FROM qbx_driver_profiles WHERE points > ?', {points or 0})
    return (tonumber(higher) or 0) + 1
end

-- ===================================
-- タイムアタック: 目標タイム
-- ===================================

-- 目標タイムがまだ無いレースで、計測に使う記録がそろったら目標タイムと報酬を決める
-- 戻り値: 新しく決まった目標タイム, 報酬（決まらなかったら nil）
function Progression.UpdateTargetTime(raceId)
    if not TimeAttackEnabled() then return nil end
    raceId = ToInteger(raceId)
    if not raceId then return nil end

    local race = MySQL.single.await([[
        SELECT id, race_type, laps, target_time_ms, ta_calib_after_id FROM qbx_races WHERE id = ? AND is_active = 1
    ]], {raceId})
    if not race or race.target_time_ms then return nil end

    local runs = GetCalibrationRuns()
    local rows = MySQL.query.await([[
        SELECT time_ms FROM qbx_race_times WHERE race_id = ? AND id > ? ORDER BY id ASC LIMIT ?
    ]], {raceId, ToInteger(race.ta_calib_after_id) or 0, runs}) or {}
    if #rows < runs then return nil end

    local sum = 0
    for _, row in ipairs(rows) do sum = sum + (tonumber(row.time_ms) or 0) end
    local target = math.floor(sum / #rows)
    if target <= 0 then return nil end

    local checkpoints = MySQL.query.await([[
        SELECT x, y, z FROM qbx_race_checkpoints WHERE race_id = ? ORDER BY checkpoint_order ASC
    ]], {raceId}) or {}
    local length, gates = CourseLength(race, checkpoints)
    local reward, rate = CalculateTimeAttackReward(length, gates, target)

    local updated = MySQL.update.await([[
        UPDATE qbx_races SET target_time_ms = ?, ta_reward = ?, ta_rate = ?, course_length_m = ?
        WHERE id = ? AND target_time_ms IS NULL
    ]], {target, reward, rate, length, raceId})
    if not updated or updated == 0 then return nil end

    print(('^2[CAM Racing]^7 レース %d の目標タイムを %s に設定しました（レート %d / 報酬 $%s）'):format(
        raceId, FormatTimeMs(target), rate, FormatMoney(reward)))
    return target, reward
end

-- 計測中のレースの記録数
local function CalibrationCount(raceId)
    return tonumber(MySQL.scalar.await([[
        SELECT COUNT(*) FROM qbx_race_times t JOIN qbx_races r ON r.id = t.race_id
        WHERE t.race_id = ? AND t.id > r.ta_calib_after_id
    ]], {raceId})) or 0
end

-- ===================================
-- デイリーレース（その日はサーバー共通）
-- ===================================

local function LoadDailyRows(day)
    return MySQL.query.await([[
        SELECT d.slot, d.race_id, d.target_time_ms, d.reward,
               r.name, r.vehicle_type, r.race_type, r.laps, r.course_length_m
        FROM qbx_daily_races d JOIN qbx_races r ON r.id = d.race_id
        WHERE d.day = ? AND r.is_active = 1
        ORDER BY d.slot ASC
    ]], {day}) or {}
end

-- 目標タイムが決まっているレースからランダムに選ぶ（目標タイムと報酬は選んだ時点の値で固定）
local function PickDailyRaces(day)
    local candidates = MySQL.query.await([[
        SELECT id, target_time_ms, ta_reward FROM qbx_races
        WHERE is_active = 1 AND target_time_ms IS NOT NULL AND ta_reward IS NOT NULL
    ]]) or {}
    if #candidates == 0 then return end

    local minCount = math.max(1, ToInteger(GetConfigValue('Daily.raceCount.min', 1)) or 1)
    local maxCount = math.max(minCount, ToInteger(GetConfigValue('Daily.raceCount.max', 2)) or 2)
    local count = math.min(#candidates, math.random(minCount, maxCount))
    local multiplier = tonumber(GetConfigValue('Daily.rewardMultiplier', 1.0)) or 1.0

    for slot = 1, count do
        local index = math.random(slot, #candidates)
        candidates[slot], candidates[index] = candidates[index], candidates[slot]
        local race = candidates[slot]
        MySQL.insert.await([[
            INSERT IGNORE INTO qbx_daily_races (day, slot, race_id, target_time_ms, reward) VALUES (?, ?, ?, ?, ?)
        ]], {day, slot, race.id, race.target_time_ms, math.floor(race.ta_reward * multiplier)})
    end
end

-- 今日のデイリーレース（まだ選ばれていなければここで選ぶ）
local dailyPicking = false
function Progression.GetDailyRaces()
    local day = Today()
    if not DailyEnabled() then return {}, day end

    local rows = LoadDailyRows(day)
    if #rows > 0 then return rows, day end

    -- 同時に選ばないように1つずつ（別のリクエストが選んでいる間は待つ）
    while dailyPicking do Wait(50) end
    rows = LoadDailyRows(day)
    if #rows > 0 then return rows, day end

    dailyPicking = true
    local ok, err = pcall(PickDailyRaces, day)
    dailyPicking = false
    if not ok then
        print('^1[CAM Racing]^7 デイリーレースを選べませんでした: ' .. tostring(err))
    end
    return LoadDailyRows(day), day
end

local function FindDailyRace(raceId)
    local rows, day = Progression.GetDailyRaces()
    for _, row in ipairs(rows) do
        if row.race_id == raceId then return row, day end
    end
    return nil, day
end

-- 完走分・目標タイム分の金額
local function DailyShares(reward)
    local share = math.max(0, math.min(1, tonumber(GetConfigValue('Daily.finishShare', 1 / 3)) or (1 / 3)))
    local finish = math.floor((ToInteger(reward) or 0) * share)
    return finish, (ToInteger(reward) or 0) - finish
end

-- 受け取り済みの種類（finish / target）
local function DailyClaims(day, citizenid, raceId)
    local claimed = {}
    for _, row in ipairs(MySQL.query.await([[
        SELECT kind FROM qbx_daily_claims WHERE day = ? AND citizenid = ? AND race_id = ?
    ]], {day, citizenid, raceId}) or {}) do
        claimed[row.kind] = true
    end
    return claimed
end

-- まだ受け取っていない報酬が残っているか
local function DailyHasRemaining(daily, claimed)
    local finishAmount, targetAmount = DailyShares(daily.reward)
    return (finishAmount > 0 and not claimed.finish) or (targetAmount > 0 and not claimed.target)
end

-- デイリーとして出走できるか（今日のデイリーで、受け取っていない報酬が残っている）
function Progression.IsDailyPlayable(citizenid, raceId)
    raceId = ToInteger(raceId)
    if not citizenid or not raceId or not DailyEnabled() then return false end
    local daily, day = FindDailyRace(raceId)
    if not daily then return false end
    return DailyHasRemaining(daily, DailyClaims(day, citizenid, raceId))
end

-- ===================================
-- 報酬の受け取り（受け取りの記録と支払い予定を同じトランザクションで記録する）
-- ===================================

local function ClaimTimeAttack(citizenid, raceId, timeMs, reward)
    return RecordPayouts(PROGRESSION_SESSION_ID,
        {{citizenid = citizenid, amount = reward, reason = 'race-time-attack'}},
        {{
            query = 'INSERT INTO qbx_ta_claims (citizenid, race_id, time_ms, reward) VALUES (?, ?, ?, ?)',
            values = {citizenid, raceId, timeMs, reward}
        }})
end

local function ClaimDaily(day, citizenid, raceId, kind, amount)
    return RecordPayouts(PROGRESSION_SESSION_ID,
        {{citizenid = citizenid, amount = amount, reason = 'race-daily-' .. kind}},
        {{
            query = 'INSERT INTO qbx_daily_claims (day, citizenid, race_id, kind, amount) VALUES (?, ?, ?, ?, ?)',
            values = {day, citizenid, raceId, kind, amount}
        }})
end

-- ===================================
-- ソロレースのゴール・リタイア（server/main.lua から呼ぶ）
-- ===================================

-- race: id, name, target_time_ms, ta_reward（今回の記録を保存する前の値）
-- 戻り値: ゴール通知に追加する行
function Progression.OnSoloRaceFinished(src, citizenid, race, timeMs, isDaily)
    local lines = {}
    local paid = false
    local target = ToInteger(race.target_time_ms)
    local reward = ToInteger(race.ta_reward)

    -- タイムアタック（1人1レース1回）
    if TimeAttackEnabled() and target and reward then
        if timeMs <= target then
            if MySQL.scalar.await('SELECT 1 FROM qbx_ta_claims WHERE citizenid = ? AND race_id = ?', {citizenid, race.id}) then
                lines[#lines + 1] = '🎯 目標タイム突破！（TA報酬は受け取り済み）'
            elseif ClaimTimeAttack(citizenid, race.id, timeMs, reward) then
                lines[#lines + 1] = ('🎯 目標タイム突破！ TA報酬 $%s'):format(FormatMoney(reward))
                paid = true
            else
                lines[#lines + 1] = '⚠️ TA報酬を記録できませんでした'
            end
        else
            lines[#lines + 1] = ('🎯 目標タイム %s まで あと %.2f秒'):format(FormatTimeMs(target), (timeMs - target) / 1000)
        end
    end

    -- デイリーレース（完走分・目標タイム分をそれぞれ1日1回）
    local daily, day
    if isDaily and DailyEnabled() then
        daily, day = FindDailyRace(race.id)
        if not daily then
            lines[#lines + 1] = '📅 今日のデイリーレースではなくなったため、デイリー報酬はありません'
        else
            local claimed = DailyClaims(day, citizenid, race.id)
            local finishAmount, targetAmount = DailyShares(daily.reward)
            if finishAmount > 0 and not claimed.finish then
                if ClaimDaily(day, citizenid, race.id, 'finish', finishAmount) then
                    lines[#lines + 1] = ('📅 デイリー完走報酬 $%s'):format(FormatMoney(finishAmount))
                    paid = true
                else
                    lines[#lines + 1] = '⚠️ デイリー完走報酬を記録できませんでした'
                end
            end
            if targetAmount > 0 and not claimed.target then
                if timeMs <= daily.target_time_ms then
                    if ClaimDaily(day, citizenid, race.id, 'target', targetAmount) then
                        lines[#lines + 1] = ('📅 デイリー目標タイム報酬 $%s'):format(FormatMoney(targetAmount))
                        paid = true
                    else
                        lines[#lines + 1] = '⚠️ デイリー目標タイム報酬を記録できませんでした'
                    end
                else
                    lines[#lines + 1] = ('📅 デイリー目標 %s で残り $%s'):format(
                        FormatTimeMs(daily.target_time_ms), FormatMoney(targetAmount))
                end
            end
        end
    end

    if paid then
        SettlePayouts(PROGRESSION_SESSION_ID, {[citizenid] = src}, citizenid)
    end

    -- 目標タイムの計測（今回の記録を含めてそろったら決まる）
    if TimeAttackEnabled() and not target then
        local newTarget, newReward = Progression.UpdateTargetTime(race.id)
        if newTarget then
            lines[#lines + 1] = ('📊 目標タイムが決まりました: %s（TA報酬 $%s）'):format(FormatTimeMs(newTarget), FormatMoney(newReward))
        else
            lines[#lines + 1] = ('📊 目標タイム計測中（%d/%d）'):format(
                math.min(CalibrationCount(race.id), GetCalibrationRuns()), GetCalibrationRuns())
        end
    end

    -- ランキング（同じレースは1日1回まで）
    if RankingEnabled() then
        local delta = 0
        local finishPoints = ToInteger(GetConfigValue('Ranking.solo.finish', 5)) or 0
        if finishPoints ~= 0 and not RankingGivenToday(citizenid, 'solo-finish', race.id)
            and AddRankingPoints(citizenid, finishPoints, 'solo-finish', race.id) then
            delta = delta + finishPoints
        end
        local beatTarget = target or (daily and daily.target_time_ms)
        local targetPoints = ToInteger(GetConfigValue('Ranking.solo.beatTarget', 10)) or 0
        if beatTarget and timeMs <= beatTarget and targetPoints ~= 0
            and not RankingGivenToday(citizenid, 'solo-target', race.id)
            and AddRankingPoints(citizenid, targetPoints, 'solo-target', race.id) then
            delta = delta + targetPoints
        end
        if delta ~= 0 then
            lines[#lines + 1] = ('🏆 ランキング %+dpt'):format(delta)
        end
    end

    return lines
end

function Progression.OnSoloRaceRetired(src, citizenid, raceId)
    if not RankingEnabled() or not GetDriverProfile(citizenid) then return end
    local penalty = ToInteger(GetConfigValue('Ranking.solo.retire', -5)) or 0
    if penalty == 0 then return end
    if AddRankingPoints(citizenid, penalty, 'solo-retire', raceId) then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'ランキング',
            description = ('リタイアのため %+dpt'):format(penalty),
            type = 'error'
        })
    end
end

-- ===================================
-- マルチプレイ: 参加者同士のポイントのやり取り
-- 自分より下の順位の参加者1人につき pointsPerOpponent をもらい、上の順位の参加者には同じだけ渡す
-- （リタイアはゴールした人より下、リタイア同士は同順位でやり取りなし）
-- 渡す側の持ち点が足りない分は受け取れない（ポイントの合計は増えも減りもしない）
-- ===================================
function Progression.ApplyMultiplayerRanking(session)
    if not RankingEnabled() then return end
    local perOpponent = ToInteger(GetConfigValue('Ranking.multiplayer.pointsPerOpponent', 5)) or 0
    if perOpponent <= 0 then return end
    
    local entrants = {}
    for _, participant in ipairs(session.participants) do
        local order
        if participant.status == 'finished' then
            order = participant.position or 999
        elseif participant.status == 'retired' then
            order = math.huge
        end
        if order then
            local points = MySQL.scalar.await('SELECT points FROM qbx_driver_profiles WHERE citizenid = ?', {participant.citizenid})
            if points then
                entrants[#entrants + 1] = {participant = participant, order = order, balance = ToInteger(points) or 0, delta = 0}
            end
        end
    end
    if #entrants < 2 then return end
    
    -- 上の順位から順に、下の順位の人から持ち点の範囲で受け取る
    table.sort(entrants, function(a, b) return a.order < b.order end)
    for i, winner in ipairs(entrants) do
        for j = i + 1, #entrants do
            local loser = entrants[j]
            if winner.order < loser.order then
                local amount = math.min(perOpponent, loser.balance)
                if amount > 0 then
                    loser.balance = loser.balance - amount
                    loser.delta = loser.delta - amount
                    winner.balance = winner.balance + amount
                    winner.delta = winner.delta + amount
                end
            end
        end
    end
    
    -- 全員分をまとめて保存（途中で失敗して片方だけ動くことがないように）
    local queries = {}
    for _, entrant in ipairs(entrants) do
        if entrant.delta ~= 0 then
            queries[#queries + 1] = {
                query = 'UPDATE qbx_driver_profiles SET points = GREATEST(0, points + ?) WHERE citizenid = ?',
                values = {entrant.delta, entrant.participant.citizenid}
            }
            queries[#queries + 1] = {
                query = 'INSERT INTO qbx_ranking_log (citizenid, delta, reason, race_id) VALUES (?, ?, ?, ?)',
                values = {entrant.participant.citizenid, entrant.delta, 'multi', session.raceId}
            }
        end
    end
    if #queries == 0 or not MySQL.transaction.await(queries) then return end
    for _, entrant in ipairs(entrants) do
        if entrant.delta ~= 0 then
            entrant.participant.pointsDelta = entrant.delta
        end
    end
end

-- ===================================
-- 画面用のデータ
-- ===================================

local function DailyView(daily, day, citizenid)
    local claimed = citizenid and DailyClaims(day, citizenid, daily.race_id) or {}
    local finishAmount, targetAmount = DailyShares(daily.reward)
    return {
        raceId = daily.race_id,
        name = daily.name,
        vehicleType = daily.vehicle_type,
        raceType = daily.race_type,
        laps = daily.laps,
        lengthM = daily.course_length_m,
        targetTimeMs = daily.target_time_ms,
        reward = daily.reward,
        finishReward = finishAmount,
        targetReward = targetAmount,
        finishClaimed = claimed.finish == true,
        targetClaimed = claimed.target == true,
        completed = not DailyHasRemaining(daily, claimed)
    }
end

local function TopRanking(limit)
    local rows = MySQL.query.await([[
        SELECT driver_name, points, total_races, total_wins FROM qbx_driver_profiles
        ORDER BY points DESC, total_wins DESC, driver_name ASC LIMIT ?
    ]], {limit}) or {}
    -- 同じポイントは同じ順位
    local rank, previous = 0, nil
    for i, row in ipairs(rows) do
        if row.points ~= previous then rank = i end
        row.rank = rank
        previous = row.points
    end
    return rows
end

-- ホーム: プロフィール・今日のデイリー・最近のポイント変動・ランキング上位
lib.callback.register('qbx_racing:getHomeData', function(source)
    local Player = GetPlayer(source)
    if not Player then return nil end
    local citizenid = Player.PlayerData.citizenid

    local data = {
        features = {timeAttack = TimeAttackEnabled(), daily = DailyEnabled(), ranking = RankingEnabled()},
        daily = {races = {}},
        recent = {},
        top = {}
    }

    local profile = GetDriverProfile(citizenid)
    if profile then
        local ta = MySQL.single.await([[
            SELECT COUNT(*) AS cleared, COALESCE(SUM(reward), 0) AS earned FROM qbx_ta_claims WHERE citizenid = ?
        ]], {citizenid}) or {}
        local points = ToInteger(profile.points) or 0
        data.profile = {
            driverName = profile.driver_name,
            points = points,
            rank = GetRank(points),
            totalRaces = profile.total_races or 0,
            totalWins = profile.total_wins or 0,
            taCleared = tonumber(ta.cleared) or 0,
            taEarned = tonumber(ta.earned) or 0
        }
        data.recent = MySQL.query.await([[
            SELECT l.delta, l.reason, l.created_at, r.name AS race_name
            FROM qbx_ranking_log l LEFT JOIN qbx_races r ON r.id = l.race_id
            WHERE l.citizenid = ? ORDER BY l.id DESC LIMIT 6
        ]], {citizenid}) or {}
    end

    local rows, day = Progression.GetDailyRaces()
    data.daily.day = day
    for _, daily in ipairs(rows) do
        data.daily.races[#data.daily.races + 1] = DailyView(daily, day, profile and citizenid)
    end

    if RankingEnabled() then
        data.top = TopRanking(5)
    end
    return data
end)

-- タイムアタック: レースごとの目標タイム・報酬・自分の状況
lib.callback.register('qbx_racing:getTimeAttack', function(source)
    local Player = GetPlayer(source)
    if not Player then return nil end
    local citizenid = Player.PlayerData.citizenid
    local runs = GetCalibrationRuns()

    local function load()
        return MySQL.query.await([[
            SELECT r.id, r.name, r.vehicle_type, r.race_type, r.laps,
                   r.target_time_ms, r.ta_reward, r.ta_rate, r.course_length_m,
                   (SELECT COUNT(*) FROM qbx_race_times t WHERE t.race_id = r.id AND t.id > r.ta_calib_after_id) AS calib_count,
                   (SELECT MIN(time_ms) FROM qbx_race_times t WHERE t.race_id = r.id AND t.citizenid = ?) AS my_best,
                   (SELECT time_ms FROM qbx_ta_claims c WHERE c.race_id = r.id AND c.citizenid = ?) AS claimed_time
            FROM qbx_races r
            WHERE r.is_active = 1
            ORDER BY (r.target_time_ms IS NULL) ASC, r.ta_rate DESC, r.created_at DESC
        ]], {citizenid, citizenid}) or {}
    end

    local races = load()
    if TimeAttackEnabled() then
        -- 記録がそろっているのに目標タイムが無いレース（設定変更・前回の失敗など）はここで決める
        local updated = false
        for _, race in ipairs(races) do
            if not race.target_time_ms and (tonumber(race.calib_count) or 0) >= runs then
                updated = Progression.UpdateTargetTime(race.id) ~= nil or updated
            end
        end
        if updated then races = load() end
    end

    return {
        enabled = TimeAttackEnabled(),
        calibrationRuns = runs,
        races = races
    }
end)

-- ランキング: 上位と自分
lib.callback.register('qbx_racing:getRanking', function(source)
    local Player = GetPlayer(source)
    if not Player then return nil end
    local profile = GetDriverProfile(Player.PlayerData.citizenid)

    local me
    if profile then
        local points = ToInteger(profile.points) or 0
        me = {driverName = profile.driver_name, points = points, rank = GetRank(points)}
    end
    local total = MySQL.scalar.await('SELECT COUNT(*) FROM qbx_driver_profiles')

    return {
        enabled = RankingEnabled(),
        top = TopRanking(math.max(1, ToInteger(GetConfigValue('Ranking.topCount', 50)) or 50)),
        me = me,
        totalDrivers = tonumber(total) or 0,
        rules = {
            soloFinish = GetConfigValue('Ranking.solo.finish', 5),
            soloTarget = GetConfigValue('Ranking.solo.beatTarget', 10),
            soloRetire = GetConfigValue('Ranking.solo.retire', -5),
            perOpponent = GetConfigValue('Ranking.multiplayer.pointsPerOpponent', 5)
        }
    }
end)

-- デイリーとして出走できるか（画面から出走する前の確認）
lib.callback.register('qbx_racing:server:canStartDaily', function(source, raceId)
    local Player = GetPlayer(source)
    if not Player then return {success = false, message = 'プレイヤーデータが見つかりません'} end
    if Progression.IsDailyPlayable(Player.PlayerData.citizenid, raceId) then
        return {success = true}
    end
    return {success = false, message = '今日のデイリー報酬はすべて受け取り済みです（また明日！）'}
end)

-- ===================================
-- 管理
-- ===================================

-- 目標タイムのリセット（これ以降のゴールで計測し直す。受け取り済みの TA 報酬はそのまま）
lib.callback.register('qbx_racing:server:adminResetTarget', function(source, raceId)
    if not HasRacePermission(source) then
        return {success = false, message = '権限がありません'}
    end
    raceId = ToInteger(raceId)
    if not raceId then return {success = false, message = 'レースIDが指定されていません'} end

    local lastTimeId = ToInteger(MySQL.scalar.await('SELECT COALESCE(MAX(id), 0) FROM qbx_race_times')) or 0
    local updated = MySQL.update.await([[
        UPDATE qbx_races SET target_time_ms = NULL, ta_reward = NULL, ta_rate = NULL, course_length_m = NULL,
               ta_calib_after_id = ?
        WHERE id = ? AND is_active = 1
    ]], {lastTimeId, raceId})
    if not updated or updated == 0 then
        return {success = false, message = 'レースが見つかりません'}
    end
    print(('[CAM Racing] 目標タイムをリセット: race=%d 実行者=%s'):format(raceId, tostring(source)))
    TriggerClientEvent('qbx_racing:client:refreshRaces', -1)
    return {success = true}
end)

-- 今日のデイリーレースを選び直す（受け取り済みの報酬はそのまま。同じレースが選ばれたら受け取り済みのまま）
lib.callback.register('qbx_racing:server:adminRerollDaily', function(source)
    if not HasRacePermission(source) then
        return {success = false, message = '権限がありません'}
    end
    if not DailyEnabled() then
        return {success = false, message = 'デイリーレースは無効になっています'}
    end

    while dailyPicking do Wait(50) end
    dailyPicking = true
    local day = Today()
    local ok, err = pcall(function()
        MySQL.query.await('DELETE FROM qbx_daily_races WHERE day = ?', {day})
        PickDailyRaces(day)
    end)
    dailyPicking = false
    if not ok then
        print('^1[CAM Racing]^7 デイリーレースを選び直せませんでした: ' .. tostring(err))
        return {success = false, message = 'データベースエラーが発生しました'}
    end

    local count = #LoadDailyRows(day)
    TriggerClientEvent('qbx_racing:client:refreshRaces', -1)
    if count == 0 then
        return {success = true, message = '目標タイムが決まっているレースが無いため、今日のデイリーはありません'}
    end
    return {success = true, message = ('今日のデイリーレースを %d 件選び直しました'):format(count)}
end)
