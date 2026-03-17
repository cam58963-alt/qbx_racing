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

-- マルチプレイヤーセッション管理
CREATE TABLE IF NOT EXISTS `qbx_race_sessions` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `race_id` INT NOT NULL,
    `host_citizenid` VARCHAR(50) NOT NULL,
    `host_driver_name` VARCHAR(50) NOT NULL,
    `session_name` VARCHAR(100) NOT NULL,
    `status` ENUM('lobby', 'countdown', 'racing', 'finished', 'cancelled') DEFAULT 'lobby',
    `countdown_duration` INT DEFAULT 10,
    `start_time` TIMESTAMP NULL,
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (`race_id`) REFERENCES `qbx_races`(`id`) ON DELETE CASCADE,
    INDEX `idx_status` (`status`),
    INDEX `idx_host` (`host_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- セッション参加者
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

-- sql/install.sql または既存DBへの追加

-- セッションテーブルに掛け金情報を追加
ALTER TABLE `qbx_race_sessions` 
ADD COLUMN `is_bet_mode` TINYINT(1) DEFAULT 0,
ADD COLUMN `entry_fee` INT DEFAULT 0,
ADD COLUMN `prize_pool` INT DEFAULT 0,
ADD COLUMN `house_cut` INT DEFAULT 0;

-- 参加者テーブルに支払い状況を追加
ALTER TABLE `qbx_session_participants`
ADD COLUMN `entry_paid` TINYINT(1) DEFAULT 0,
ADD COLUMN `prize_amount` INT DEFAULT 0;

-- セッションテーブルにスポンサー情報を追加
ALTER TABLE `qbx_race_sessions`
ADD COLUMN `sponsor_amount` INT DEFAULT 0 AFTER `prize_pool`,
ADD COLUMN `sponsor_citizenid` VARCHAR(50) DEFAULT NULL AFTER `sponsor_amount`,
ADD COLUMN `sponsor_name` VARCHAR(100) DEFAULT NULL AFTER `sponsor_citizenid`;

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
