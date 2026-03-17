-- ===================================
-- QBX Racing System - Configuration
-- 完全統合版 v3.0.0
-- すべての設定項目を一元管理
-- ===================================

Config = {}

-- ===================================
-- バージョン情報
-- ===================================
Config.Version = {
    major = 3,
    minor = 0,
    patch = 0,
    build = '2024.01',
    name = 'Complete Edition'
}

-- ===================================
-- 基本権限設定
-- ===================================

-- レース管理（作成・編集・削除）が可能なジョブ
Config.RaceManagerJobs = {
    'admin',           -- 管理者
    'raceorganizer',   -- レース主催者
    'eventmanager'     -- イベントマネージャー
}

-- ドライバーネーム制約
Config.DriverName = {
    minLength = 3,                    -- 最小文字数
    maxLength = 20,                   -- 最大文字数
    pattern = '^[a-zA-Z0-9_]+$'       -- 許可文字パターン（英数字とアンダースコア）
}

-- ===================================
-- 車両タイプ設定（GTA V Vehicle Classes準拠）
-- ===================================
Config.VehicleTypes = {
    car = {
        label = '自動車',
        emoji = '🚗',
        icon = 'fa-solid fa-car',
        color = '#ef4444',
        
        -- マーカー設定
        markerType = 1,
        markerColor = {r = 255, g = 0, b = 0, a = 150},
        
        -- 許可する車両クラス
        -- 0: Compacts, 1: Sedans, 2: SUVs, 3: Coupes, 4: Muscle, 5: Sports Classics
        -- 6: Sports, 7: Super, 8: Motorcycles, 9: Off-road, 10: Industrial
        -- 11: Utility, 12: Vans, 17: Service, 18: Emergency, 19: Military, 20: Commercial
        allowedClasses = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 17, 18, 19, 20}
    },
    
    heli = {
        label = 'ヘリコプター',
        emoji = '🚁',
        icon = 'fa-solid fa-helicopter',
        color = '#10b981',
        
        markerType = 1,
        markerColor = {r = 0, g = 255, b = 0, a = 150},
        
        allowedClasses = {
            15, -- Helicopters
            16  -- Planes
        }
    },
    
    boat = {
        label = 'ボート',
        emoji = '⛵',
        icon = 'fa-solid fa-ship',
        color = '#3b82f6',
        
        markerType = 1,
        markerColor = {r = 0, g = 0, b = 255, a = 150},
        
        allowedClasses = {
            14  -- Boats
        }
    }
}

-- ===================================
-- レースタイプ設定
-- ===================================
Config.RaceTypes = {
    circuit = {
        label = '周回レース',
        description = '指定された周回数を完走するレース',
        icon = 'fa-solid fa-rotate',
        emoji = '🔄',
        allowLapSetting = true,
        minLaps = 1,
        maxLaps = 10,
        defaultLaps = 3
    },
    
    sprint = {
        label = 'スプリントレース',
        description = 'スタートからゴールまで1回のみ',
        icon = 'fa-solid fa-flag-checkered',
        emoji = '🏁',
        allowLapSetting = false,
        laps = 1
    }
}

-- ===================================
-- チェックポイント設定
-- ===================================
Config.Checkpoint = {
    -- 基本設定
    radius = 10.0,              -- チェックポイントの半径（メートル）
    height = 5.0,               -- マーカーの高さ
    minCheckpoints = 3,         -- 最低必要なチェックポイント数
    maxCheckpoints = 50,        -- 最大チェックポイント数
    
    -- 作成モード設定
    creationMode = {
        previewColor = {r = 255, g = 255, b = 0, a = 100},  -- 設置予定位置の色（黄色）
        placedColor = {r = 0, g = 150, b = 255, a = 200},   -- 設置済みの色（青）
        latestColor = {r = 0, g = 255, b = 0, a = 200},     -- 最新設置の色（緑）
        showNumbers = true,                                  -- チェックポイント番号表示
        numberScale = 0.5,                                   -- 番号のサイズ
        numberFont = 4                                       -- 番号のフォント
    },
    
    -- ブリップ設定
    blip = {
        sprite = 1,              -- ブリップのスプライトID
        scale = 0.7,             -- ブリップのサイズ
        normalColor = 5,         -- 通常のチェックポイント色（黄色）
        finishColor = 38,        -- ゴールの色（オレンジ）
        passedColor = 2,         -- 通過済みの色（緑）
        showNumbers = true       -- 番号表示
    }
}

-- ===================================
-- レース基本設定
-- ===================================
Config.Race = {
    -- カウントダウン
    countdownSeconds = 5,        -- ソロレースのカウントダウン時間
    
    -- 基本報酬（練習・タイムアタック用）
    baseRewards = {
        enabled = false,          -- 基本報酬を有効にするか
        minReward = 0,            -- 最低報酬
        maxReward = 0,            -- 最高報酬
        currency = 'cash'         -- 通貨タイプ
    },
    
    -- 掛け金モード（推奨システム）
    betting = {
        enabled = true,
        
        -- 既存設定...
        entryFee = {
            min = 0,
            max = 100000,
            default = 1000
        },
        
        distribution = {
            [1] = 50,  -- 1位: 50%
            [2] = 30,  -- 2位: 30%
            [3] = 20   -- 3位: 20%
        },
        
        -- ===================================
        -- スポンサーシステム（新規追加）
        -- ===================================
        sponsor = {
            enabled = true,                -- スポンサー機能の有効化
            
            -- 主催者スポンサー（基本機能）
            host = {
                enabled = true,            -- 主催者スポンサーを許可
                min = 0,                   -- 最低スポンサー額（0 = 任意）
                max = 5000000,             -- 最高スポンサー額（500万ドル）
                default = 0,               -- デフォルト額
                description = '主催者が賞金プールに自腹で追加する金額'
            },
            
            -- 安全制限
            security = {
                maxPerDay = 10000000,      -- 1日あたりの最大スポンサー額
                maxPerPlayer = 20000000,   -- プレイヤーあたりの累計制限
                cooldown = 300,            -- スポンサー後のクールダウン（秒）
                requireConfirmation = true  -- 高額時の確認ダイアログ
            },
            
            -- 表示設定
            display = {
                showInLobby = true,        -- ロビーでスポンサー情報表示
                showInList = true,         -- セッション一覧で表示
                highlightBig = 100000,     -- この金額以上をハイライト
                showBreakdown = true       -- 内訳表示（参加費+スポンサー）
            },
            
            -- 返金設定
            refund = {
                onCancel = true,           -- セッションキャンセル時
                onHostLeave = true,        -- 主催者退出時
                onSystemError = true       -- システムエラー時
            }
        }
    },
    
    currency = 'cash',            -- 使用通貨
    updateStats = true            -- 統計更新
}

-- ===================================
-- マルチプレイヤー設定
-- ===================================
Config.Multiplayer = {
    enabled = true,              -- マルチプレイヤー機能の有効化
    
    -- セッション設定
    minParticipants = 2,         -- 最低参加人数
    maxParticipants = 16,        -- 最大参加人数
    defaultCountdown = 10,       -- デフォルトカウントダウン時間（秒）
    minCountdown = 5,            -- 最短カウントダウン時間
    maxCountdown = 30,           -- 最長カウントダウン時間
    
    -- セッション管理
    sessionTimeout = 600,        -- セッションタイムアウト（秒）
    autoCleanup = true,          -- 自動クリーンアップ
    cleanupDelay = 300000,       -- クリーンアップ遅延（ミリ秒）
    
    -- 進捗同期
    progressSyncInterval = 500,  -- 進捗同期間隔（ミリ秒）
    
    -- ===================================
    -- ゴーストモード設定（最重要）
    -- ===================================
    ghostMode = {
        enabled = true,                -- ゴーストモード有効化
        
        -- 動作モード
        mode = 'complete',             -- 'participants_only' または 'complete'
        participantsOnly = true,       -- レース参加者のみゴースト化（推奨: true）
        optimizedMode = false,         -- 最適化版を使用するか（高負荷環境: true）
        
        -- 衝突設定
        collisionRadius = 150.0,       -- ゴースト化範囲（メートル）
        maxGhostDistance = 200.0,      -- 最大ゴースト距離
        
        -- 視覚効果
        visual = {
            racerAlpha = 180,          -- レース参加者の透明度（0-255、255=不透明）
            nonRacerAlpha = 255,       -- 一般車両の透明度
            applyToRacers = true,      -- ライバルを半透明にする
            applyToNonRacers = false,  -- 一般車も半透明にする（推奨: false）
            showGhostEffect = true     -- 視覚効果を表示
        },
        
        -- パフォーマンス設定
        updateInterval = 0,            -- 更新間隔（0 = 毎フレーム、50-100 = 軽量化）
        
        -- デバッグ
        debugMode = false,             -- デバッグモード
        showDebugInfo = false          -- デバッグ情報表示
    },
    
    -- ===================================
    -- カウントダウン中の制限
    -- ===================================
    countdownRestrictions = {
        freezeVehicle = true,          -- 車両を完全ロック
        disableControls = true,        -- 操作を無効化
        maxDistanceFromStart = 3.0,    -- スタート地点からの最大距離（メートル）
        teleportBackToStart = true,    -- 範囲外に出たら戻す
        showWarnings = true            -- 警告表示
    }
}

-- ===================================
-- レース参加者専用オブジェクト設定
-- ===================================
Config.RaceObjects = {
    enabled = true,                -- オブジェクト生成の有効化
    
    -- チェックポイント装飾
    checkpoint = {
        model = 'prop_offroad_tyres02',  -- タイヤスタック
        offset = vector3(3.0, 0.0, -0.5),
        rotation = vector3(0.0, 0.0, 0.0)
    },
    
    -- ゴールライン装飾
    finish = {
        model = 'prop_beach_flag_01',    -- チェッカーフラッグ
        offset = vector3(0.0, 0.0, 0.0),
        rotation = vector3(0.0, 0.0, 0.0)
    },
    
    -- 方向指示矢印（オプション）
    arrow = {
        model = 'prop_arrow_direction_yellow',
        offset = vector3(-5.0, 0.0, 1.0),
        rotation = vector3(0.0, 0.0, 0.0),
        enabled = true                   -- 矢印表示の有効化
    }
}

-- ===================================
-- レース中UI設定
-- ===================================
Config.RaceUI = {
    -- 表示設定
    showLivePosition = true,       -- リアルタイム順位表示
    showLapTimes = true,           -- ラップタイム表示
    showParticipantList = true,    -- 参加者リスト表示
    showProgressBar = true,        -- 進捗バー表示
    updateInterval = 100,          -- UI更新間隔（ミリ秒）
    
    -- HUD位置設定
    positionDisplay = {
        position = "right-center",
        style = {
            borderRadius = 8,
            backgroundColor = 'rgba(26, 26, 46, 0.95)',
            color = '#ffffff',
            borderLeft = '4px solid #ef4444'
        }
    }
}

-- ===================================
-- UI設定（NUI関連）
-- ===================================
Config.UI = {
    command = 'race',              -- UIを開くコマンド
    keybind = nil,                 -- キーバインド（nil = 無効、例: 'F6'）
    
    -- ページネーション
    racesPerPage = 12,             -- 1ページあたりのレース数
    gridColumns = 4,               -- グリッド列数
    
    -- レース作成モード
    creationKeybinds = {
        placeCheckpoint = 166,     -- F5
        finishCreation = 167,      -- F6
        cancelCreation = 168,      -- F7
        deleteLastCheckpoint = 177 -- Backspace
    }
}

-- ===================================
-- サウンド設定
-- ===================================
Config.Sounds = {
    enabled = true,                -- サウンド再生の有効化
    
    -- 効果音設定
    checkpointPass = {
        soundName = 'CHECKPOINT_PERFECT',
        soundSet = 'HUD_MINI_GAME_SOUNDSET',
        volume = 1.0
    },
    
    countdown = {
        soundName = 'CHECKPOINT_PERFECT',
        soundSet = 'HUD_MINI_GAME_SOUNDSET',
        volume = 1.0
    },
    
    raceStart = {
        soundName = 'GO',
        soundSet = 'HUD_MINI_GAME_SOUNDSET',
        volume = 1.0
    }
}

-- ===================================
-- 通知設定
-- ===================================
Config.Notifications = {
    -- 通知タイプ別設定
    success = {
        duration = 5000,           -- 表示時間（ミリ秒）
        position = 'top-right'
    },
    
    error = {
        duration = 5000,
        position = 'top-right'
    },
    
    inform = {
        duration = 3000,
        position = 'top-right'
    },
    
    -- レース関連通知
    raceNotifications = {
        checkpointPass = true,     -- チェックポイント通過通知
        lapComplete = true,        -- ラップ完了通知
        positionChange = true,     -- 順位変動通知
        participantFinish = true   -- 他参加者完了通知
    }
}

-- ===================================
-- パフォーマンス設定
-- ===================================
Config.Performance = {
    -- 描画最適化
    drawDistance = 200.0,          -- 描画距離（メートル）
    markerDrawDistance = 150.0,    -- マーカー描画距離
    objectDrawDistance = 100.0,    -- オブジェクト描画距離
    
    -- スレッド最適化
    mainThreadInterval = 0,        -- メインスレッド更新間隔（0 = 毎フレーム）
    drawThreadInterval = 0,        -- 描画スレッド更新間隔
    
    -- エンティティキャッシュ（最適化版ゴーストモード用）
    entityCache = {
        enabled = true,
        updateInterval = 500,      -- キャッシュ更新間隔（ミリ秒）
        maxCacheSize = 100         -- 最大キャッシュサイズ
    },
    
    -- メモリ管理
    autoCleanup = true,            -- 自動クリーンアップ
    cleanupInterval = 300000       -- クリーンアップ間隔（ミリ秒）
}

-- ===================================
-- デバッグ設定
-- ===================================
Config.Debug = {
    enabled = false,               -- デバッグモード（ConVar: qbx_racing_debug）
    
    -- ログレベル
    logLevel = {
        info = true,               -- 情報ログ
        warning = true,            -- 警告ログ
        error = true,              -- エラーログ
        verbose = false            -- 詳細ログ
    },
    
    -- デバッグ表示
    showCheckpointInfo = false,    -- チェックポイント情報表示
    showGhostInfo = false,         -- ゴーストモード情報表示
    showPerformanceInfo = false,   -- パフォーマンス情報表示
    
    -- テストモード
    testMode = false,              -- テストモード（開発用）
    skipCountdown = false,         -- カウントダウンスキップ
    infiniteTime = false           -- 制限時間無効化
}

-- ===================================
-- セキュリティ設定
-- ===================================
Config.Security = {
    -- チート対策
    antiCheat = {
        enabled = true,
        maxSpeed = 500.0,          -- 最大速度（km/h）
        teleportDetection = true,  -- テレポート検出
        teleportThreshold = 100.0, -- テレポート判定距離（メートル）
        checkInterval = 1000       -- チェック間隔（ミリ秒）
    },
    
    -- レート制限
    rateLimit = {
        enabled = true,
        maxRequestsPerMinute = 60, -- 1分あたりの最大リクエスト数
        cooldownPeriod = 5000      -- クールダウン期間（ミリ秒）
    },
    
    -- 入力検証
    validation = {
        strictMode = true,         -- 厳格な検証モード
        sanitizeInput = true,      -- 入力サニタイズ
        maxInputLength = 200       -- 最大入力長
    }
}

-- ===================================
-- 初期化とバリデーション
-- ===================================

-- 設定検証関数
function ValidateConfig()
    local errors = {}
    
    -- 必須項目チェック
    if not Config.VehicleTypes then
        table.insert(errors, 'VehicleTypes is missing')
    end
    
    if not Config.Multiplayer then
        table.insert(errors, 'Multiplayer config is missing')
    end
    
    if not Config.Race then
        table.insert(errors, 'Race config is missing')
    end
    
    -- 値の妥当性チェック
    if Config.Multiplayer and Config.Multiplayer.minParticipants > Config.Multiplayer.maxParticipants then
        table.insert(errors, 'minParticipants cannot be greater than maxParticipants')
    end
    
    if Config.Checkpoint and Config.Checkpoint.minCheckpoints < 2 then
        table.insert(errors, 'minCheckpoints must be at least 2')
    end
    
    -- エラー表示
    if #errors > 0 then
        print('^1[QBX Racing]^7 Config validation errors:')
        for _, error in ipairs(errors) do
            print('^1  - ^7' .. error)
        end
        return false
    end
    
    print('^2[QBX Racing]^7 Config validation passed')
    return true
end

-- 初期化メッセージ
if IsDuplicityVersion() then
    -- サーバーサイド
    print('^2[QBX Racing]^7 Config loaded successfully')
    print('^2[QBX Racing]^7 Version: ' .. Config.Version.major .. '.' .. Config.Version.minor .. '.' .. Config.Version.patch)
    print('^2[QBX Racing]^7 Multiplayer: ' .. (Config.Multiplayer.enabled and 'Enabled' or 'Disabled'))
    print('^2[QBX Racing]^7 Ghost Mode: ' .. (Config.Multiplayer.ghostMode.enabled and 'Enabled' or 'Disabled'))
else
    -- クライアントサイド
    print('^2[QBX Racing]^7 Client config loaded')
end

-- 開発モードの場合は検証実行
if Config.Debug and Config.Debug.enabled then
    CreateThread(function()
        Wait(1000)
        ValidateConfig()
    end)
end
