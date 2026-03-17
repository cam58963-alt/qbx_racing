-- ===================================
-- QBX Racing System - Database Helper Functions
-- v4.2.0
-- ※ server/main.lua でも直接クエリを実行しているため、
--   これらは共通ユーティリティとして利用可能
-- ===================================

-- レース作成
function CreateRace(data)
    local raceId = MySQL.insert.await([[
        INSERT INTO qbx_races (name, description, creator_driver_name, vehicle_type, race_type, laps) 
        VALUES (?, ?, ?, ?, ?, ?)
    ]], {
        data.name,
        data.description or '',
        data.creatorName,
        data.vehicleType or 'car',
        data.raceType or 'circuit',
        data.laps or 1
    })
    
    if raceId then
        for i, checkpoint in ipairs(data.checkpoints) do
            MySQL.insert.await([[
                INSERT INTO qbx_race_checkpoints (race_id, checkpoint_order, x, y, z, radius) 
                VALUES (?, ?, ?, ?, ?, ?)
            ]], {
                raceId,
                i,
                checkpoint.x,
                checkpoint.y,
                checkpoint.z,
                checkpoint.radius or (Config.Checkpoint and Config.Checkpoint.radius or 10.0)
            })
        end
    end
    
    return raceId
end

-- レース一覧取得
function GetRaces(vehicleType)
    local query = [[
        SELECT r.*, COUNT(rt.id) as total_attempts,
               MIN(rt.time_ms) as best_time,
               (SELECT driver_name FROM qbx_race_times WHERE race_id = r.id ORDER BY time_ms ASC LIMIT 1) as best_player
        FROM qbx_races r
        LEFT JOIN qbx_race_times rt ON r.id = rt.race_id
        WHERE r.is_active = 1
    ]]
    
    local params = {}
    if vehicleType and vehicleType ~= 'all' then
        query = query .. ' AND r.vehicle_type = ?'
        table.insert(params, vehicleType)
    end
    
    query = query .. ' GROUP BY r.id ORDER BY r.created_at DESC'
    
    return MySQL.query.await(query, params)
end

-- ランキング取得
function GetLeaderboard(raceId, limit)
    return MySQL.query.await([[
        SELECT driver_name, time_ms, vehicle_model, completed_at,
               ROW_NUMBER() OVER (ORDER BY time_ms ASC) as position
        FROM qbx_race_times
        WHERE race_id = ?
        ORDER BY time_ms ASC
        LIMIT ?
    ]], {raceId, limit or 10})
end

-- プレイヤーベストタイム取得
function GetPlayerBestTime(raceId, citizenid)
    return MySQL.single.await([[
        SELECT MIN(time_ms) as best_time,
               (SELECT COUNT(*) FROM qbx_race_times WHERE race_id = ? AND time_ms < 
                (SELECT MIN(time_ms) FROM qbx_race_times WHERE race_id = ? AND citizenid = ?)) + 1 as rank
        FROM qbx_race_times
        WHERE race_id = ? AND citizenid = ?
    ]], {raceId, raceId, citizenid, raceId, citizenid})
end

-- タイム記録
function SaveRaceTime(raceId, citizenid, driverName, timeMs, vehicleModel)
    return MySQL.insert.await([[
        INSERT INTO qbx_race_times (race_id, citizenid, driver_name, time_ms, vehicle_model) 
        VALUES (?, ?, ?, ?, ?)
    ]], {raceId, citizenid, driverName, timeMs, vehicleModel})
end

-- レース削除（論理削除）
function DeleteRace(raceId)
    return MySQL.update.await('UPDATE qbx_races SET is_active = 0 WHERE id = ?', {raceId})
end
