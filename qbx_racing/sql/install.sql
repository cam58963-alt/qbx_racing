-- ===================================
-- QBX Racing System - Database Schema
-- v4.2.0
-- 新規インストール: CREATE TABLE で全カラム作成
-- 既存v4.0以前からの更新: 末尾の ALTER TABLE で不足カラムを安全に追加
-- ===================================

-- ===================================
-- 新規インストール用（全カラム統合済み）
-- ===================================

-- ドライバープロフィール管理
CREATE TABLE IF NOT EXISTS `qbx_driver_profiles` (
    `citizenid` VARCHAR(50) PRIMARY KEY,
    `driver_name` VARCHAR(50) UNIQUE NOT NULL,
    `total_races` INT DEFAULT 0,
    `total_wins` INT DEFAULT 0,
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_driver_name` (`driver_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- レース管理テーブル
CREATE TABLE IF NOT EXISTS `qbx_races` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `name` VARCHAR(100) NOT NULL,
    `description` TEXT,
    `vehicle_type` ENUM('car', 'heli', 'boat') NOT NULL,
    `race_type` ENUM('circuit', 'sprint') DEFAULT 'circuit',
    `laps` INT DEFAULT 1,
    `min_participants` INT DEFAULT 2,
    `max_participants` INT DEFAULT 16,
    `creator_driver_name` VARCHAR(50),
    `is_active` TINYINT(1) DEFAULT 1,
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_vehicle_type` (`vehicle_type`),
    INDEX `idx_race_type` (`race_type`),
    INDEX `idx_active` (`is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- チェックポイント
CREATE TABLE IF NOT EXISTS `qbx_race_checkpoints` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `race_id` INT NOT NULL,
    `checkpoint_order` INT NOT NULL,
    `x` DOUBLE NOT NULL,
    `y` DOUBLE NOT NULL,
    `z` DOUBLE NOT NULL,
    `radius` FLOAT DEFAULT 10.0,
    FOREIGN KEY (`race_id`) REFERENCES `qbx_races`(`id`) ON DELETE CASCADE,
    INDEX `idx_race_order` (`race_id`, `checkpoint_order`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- タイム記録
CREATE TABLE IF NOT EXISTS `qbx_race_times` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `race_id` INT NOT NULL,
    `driver_name` VARCHAR(50) NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `time_ms` INT NOT NULL,
    `vehicle_model` VARCHAR(50) NOT NULL,
    `completed_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (`race_id`) REFERENCES `qbx_races`(`id`) ON DELETE CASCADE,
    INDEX `idx_race_time` (`race_id`, `time_ms`),
    INDEX `idx_driver` (`driver_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- マルチプレイヤーセッション管理（掛け金・スポンサー統合済み）
CREATE TABLE IF NOT EXISTS `qbx_race_sessions` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `race_id` INT NOT NULL,
    `host_citizenid` VARCHAR(50) NOT NULL,
    `host_driver_name` VARCHAR(50) NOT NULL,
    `session_name` VARCHAR(100) NOT NULL,
    `status` ENUM('lobby', 'countdown', 'racing', 'finished', 'cancelled') DEFAULT 'lobby',
    `countdown_duration` INT DEFAULT 10,
    `start_time` TIMESTAMP NULL,
    `is_bet_mode` TINYINT(1) DEFAULT 0,
    `entry_fee` INT DEFAULT 0,
    `prize_pool` INT DEFAULT 0,
    `sponsor_amount` INT DEFAULT 0,
    `sponsor_citizenid` VARCHAR(50) DEFAULT NULL,
    `sponsor_name` VARCHAR(100) DEFAULT NULL,
    `house_cut` INT DEFAULT 0,
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (`race_id`) REFERENCES `qbx_races`(`id`) ON DELETE CASCADE,
    INDEX `idx_status` (`status`),
    INDEX `idx_host` (`host_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- セッション参加者（支払い状況・賞金統合済み）
CREATE TABLE IF NOT EXISTS `qbx_session_participants` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `session_id` INT NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `driver_name` VARCHAR(50) NOT NULL,
    `vehicle_model` VARCHAR(50),
    `status` ENUM('entered', 'ready', 'racing', 'finished') DEFAULT 'entered',
    `current_checkpoint` INT DEFAULT 1,
    `current_lap` INT DEFAULT 1,
    `finish_time_ms` INT NULL,
    `final_position` INT NULL,
    `entry_paid` TINYINT(1) DEFAULT 0,
    `prize_amount` INT DEFAULT 0,
    FOREIGN KEY (`session_id`) REFERENCES `qbx_race_sessions`(`id`) ON DELETE CASCADE,
    UNIQUE KEY `unique_participant` (`session_id`, `citizenid`),
    INDEX `idx_session` (`session_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- セッション進捗同期
CREATE TABLE IF NOT EXISTS `qbx_session_progress` (
    `session_id` INT NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL,
    `checkpoint` INT NOT NULL,
    `lap` INT NOT NULL,
    `timestamp` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`session_id`, `citizenid`),
    FOREIGN KEY (`session_id`) REFERENCES `qbx_race_sessions`(`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- スポンサー履歴テーブル（統計・監査用）
CREATE TABLE IF NOT EXISTS `qbx_race_sponsors` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `session_id` INT NOT NULL,
    `sponsor_citizenid` VARCHAR(50) NOT NULL,
    `sponsor_driver_name` VARCHAR(50) NOT NULL,
    `amount` INT NOT NULL,
    `sponsor_type` ENUM('host', 'participant') DEFAULT 'host',
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (`session_id`) REFERENCES `qbx_race_sessions`(`id`) ON DELETE CASCADE,
    INDEX `idx_sponsor` (`sponsor_citizenid`),
    INDEX `idx_amount` (`amount`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ===================================
-- v4.0以前 → v4.2.0 マイグレーション
-- 既存テーブルに不足カラムを安全に追加
-- カラムが既に存在する場合はエラーを無視（PROCEDURE使用）
-- ===================================

-- 安全なカラム追加プロシージャ
DELIMITER //
CREATE PROCEDURE IF NOT EXISTS `qbx_racing_safe_add_column`(
    IN tbl VARCHAR(64),
    IN col VARCHAR(64),
    IN col_def VARCHAR(255)
)
BEGIN
    SET @exists = 0;
    SELECT COUNT(*) INTO @exists
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = tbl
      AND COLUMN_NAME = col;

    IF @exists = 0 THEN
        SET @sql = CONCAT('ALTER TABLE `', tbl, '` ADD COLUMN `', col, '` ', col_def);
        PREPARE stmt FROM @sql;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
    END IF;
END //
DELIMITER ;

-- qbx_races: description カラム（v4.0以前になかった場合）
CALL qbx_racing_safe_add_column('qbx_races', 'description', 'TEXT AFTER `name`');
CALL qbx_racing_safe_add_column('qbx_races', 'race_type', "ENUM('circuit', 'sprint') DEFAULT 'circuit' AFTER `vehicle_type`");

-- qbx_race_sessions: 掛け金・スポンサー関連カラム
CALL qbx_racing_safe_add_column('qbx_race_sessions', 'is_bet_mode', 'TINYINT(1) DEFAULT 0 AFTER `start_time`');
CALL qbx_racing_safe_add_column('qbx_race_sessions', 'entry_fee', 'INT DEFAULT 0 AFTER `is_bet_mode`');
CALL qbx_racing_safe_add_column('qbx_race_sessions', 'prize_pool', 'INT DEFAULT 0 AFTER `entry_fee`');
CALL qbx_racing_safe_add_column('qbx_race_sessions', 'sponsor_amount', 'INT DEFAULT 0 AFTER `prize_pool`');
CALL qbx_racing_safe_add_column('qbx_race_sessions', 'sponsor_citizenid', 'VARCHAR(50) DEFAULT NULL AFTER `sponsor_amount`');
CALL qbx_racing_safe_add_column('qbx_race_sessions', 'sponsor_name', 'VARCHAR(100) DEFAULT NULL AFTER `sponsor_citizenid`');
CALL qbx_racing_safe_add_column('qbx_race_sessions', 'house_cut', 'INT DEFAULT 0 AFTER `sponsor_name`');

-- qbx_session_participants: 支払い・賞金関連カラム
CALL qbx_racing_safe_add_column('qbx_session_participants', 'entry_paid', 'TINYINT(1) DEFAULT 0 AFTER `final_position`');
CALL qbx_racing_safe_add_column('qbx_session_participants', 'prize_amount', 'INT DEFAULT 0 AFTER `entry_paid`');

-- プロシージャ削除（後片付け）
DROP PROCEDURE IF EXISTS `qbx_racing_safe_add_column`;
