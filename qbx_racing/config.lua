-- ===================================
-- CAM Racing System - Configuration
-- 完全統合版 v4.2.0
-- すべての設定項目を一元管理
-- ===================================

Config = {}

-- ===================================
-- バージョン情報
-- ===================================
Config.Version = {
    major = 4,
    minor = 2,
    patch = 0,
    build = '2026.03',
    name = 'Race Delete & Bet Permission'
}

-- ===================================
-- 基本権限設定
-- ===================================

-- レース管理（作成・編集・削除）が可能なジョブ
Config.RaceManagerJobs = {
    'cityhall',        -- 市役所
    'raceorganizer'    -- レース主催者
}

-- 掛けレース（ベットモード）セッションを作成できるジョブ
-- ※通常の無料セッションは誰でも作成可能
Config.BetRaceJobs = {
    'cityhall',        -- 市役所
    'raceorganizer'    -- レース主催者
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
        
        -- チェックポイント設定（CreateCheckpoint ネイティブ使用）
        -- 参考: https://docs.fivem.net/docs/game-references/checkpoints/
        checkpoint = {
            type = 0,              -- 通過CP: 矢印付き円柱（方向指示あり）
            typeNoArrow = 2,       -- 通過CP（矢印なし・最終CP前）
            goalType = 4,          -- ゴールCP: チェッカーフラッグ円柱
            radius = 10.0,         -- チェックポイント半径
            height = 5.0,          -- チェックポイント高さ
            nearHeight = 100.0,    -- 近づいた時の描画高さ
            color = {r = 255, g = 0, b = 0, a = 200},       -- メインCP色（赤）
            goalColor = {r = 255, g = 215, b = 0, a = 200},  -- ゴール色（金）
            nextColor = {r = 255, g = 255, b = 255, a = 80}, -- 次CP色（白半透明）
            iconColor = {r = 255, g = 255, b = 255, a = 255} -- アイコン色
        },
        
        -- 許可する車両クラス
        -- 0: Compacts, 1: Sedans, 2: SUVs, 3: Coupes, 4: Muscle, 5: Sports Classics
        -- 6: Sports, 7: Super, 8: Motorcycles, 9: Off-road, 10: Industrial
        -- 11: Utility, 12: Vans, 17: Service, 18: Emergency, 19: Military, 20: Commercial
        allowedClasses = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 17, 18, 19, 20},
        -- サーバーで確認する車両の種類（GetVehicleType。細かいクラスはクライアントで確認）
        serverTypes = {'automobile', 'bike'},
        -- チェックポイント通過の報告を受け付ける距離（判定半径 + この値、メートル）
        -- サーバーで見た位置は通信のぶん少し遅れるため、速い乗り物ほど大きめにする
        progressDistanceMargin = 50.0
    },
    
    heli = {
        label = 'ヘリコプター',
        emoji = '🚁',
        icon = 'fa-solid fa-helicopter',
        color = '#10b981',
        
        -- ヘリ用チェックポイント: リング型（空中通過用）
        checkpoint = {
            type = 12,             -- 通過CP: 矢印付きリング（空中飛行通過用）
            typeNoArrow = 14,      -- 通過CP（矢印なし・最終CP前）
            goalType = 16,         -- ゴールCP: チェッカーフラッグリング
            radius = 15.0,         -- チェックポイント半径（ヘリ用大きめ）
            height = 15.0,         -- チェックポイント高さ（リング）
            nearHeight = 100.0,    -- 近づいた時の描画高さ
            color = {r = 0, g = 255, b = 0, a = 200},        -- メインCP色（緑）
            goalColor = {r = 255, g = 215, b = 0, a = 200},   -- ゴール色（金）
            nextColor = {r = 255, g = 255, b = 255, a = 80},  -- 次CP色（白半透明）
            iconColor = {r = 255, g = 255, b = 255, a = 255}  -- アイコン色
        },
        
        allowedClasses = {
            15, -- Helicopters
            16  -- Planes
        },
        serverTypes = {'heli', 'plane'},
        progressDistanceMargin = 150.0  -- 速度が出る・高度もずれるため大きめ
    },
    
    boat = {
        label = 'ボート',
        emoji = '⛵',
        icon = 'fa-solid fa-ship',
        color = '#3b82f6',
        
        -- ボート用チェックポイント: 円柱型（水上用）
        checkpoint = {
            type = 0,              -- 通過CP: 矢印付き円柱
            typeNoArrow = 2,       -- 通過CP（矢印なし）
            goalType = 4,          -- ゴールCP: チェッカーフラッグ円柱
            radius = 12.0,         -- チェックポイント半径（ボート用やや大きめ）
            height = 5.0,          -- チェックポイント高さ
            nearHeight = 100.0,    -- 近づいた時の描画高さ
            color = {r = 0, g = 100, b = 255, a = 200},      -- メインCP色（青）
            goalColor = {r = 255, g = 215, b = 0, a = 200},   -- ゴール色（金）
            nextColor = {r = 255, g = 255, b = 255, a = 80},  -- 次CP色（白半透明）
            iconColor = {r = 255, g = 255, b = 255, a = 255}  -- アイコン色
        },
        
        allowedClasses = {
            14  -- Boats
        },
        serverTypes = {'boat', 'submarine'},
        progressDistanceMargin = 80.0   -- 波で揺れるため車より大きめ
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
    maxCheckpoints = 500,       -- 最大チェックポイント数
    maxTurnGuides = 50,         -- 手動設置できる曲がり角ガイドの最大数
    
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
    },
    
    -- 自作マーカー（画像）設定
    -- html/img/markers/ の画像をマーカーとして表示（enabled = false で VehicleTypes.*.checkpoint の標準チェックポイントに戻る）
    customMarker = {
        enabled = true,
        textureDict = 'qbx_racing_markers',      -- ランタイムテクスチャ辞書名
        size = 12.0,                             -- 画像の大きさ（メートル）
        groundAnchor = 0.12,                     -- 画像の下端から地面リングまでの割合（0.0 = 画像の下端を地面に合わせる）
        rotation = vector3(90.0, 0.0, 0.0),      -- 画像が横倒し・逆さまに見える場合はここを調整
        faceCamera = true,                       -- 常にカメラの方を向ける
        
        -- 反応範囲の丸（ringColor がある画像に表示）
        radiusRing = {
            enabled = true,
            outline = true,                      -- 輪郭線（地面に水平の丸）
            outlineType = 25,                    -- 輪郭線のマーカータイプ（25 = 細い円）
            outlineAlpha = 200,                  -- 輪郭線の透明度（0-255）
            fill = true,                         -- 内側の薄い塗り
            fillHeight = 0.6,                    -- 塗りの高さ
            fillAlpha = 40                       -- 塗りの透明度（0-255）
        },
        
        -- 先のチェックポイントの予告表示
        preview = {
            enabled = true,
            count = 4,                           -- 何個先まで表示するか
            fadeStep = 0.2                       -- 1個先へ行くごとに薄くする割合
        },
        
        -- ルート線（光る矢印をまっすぐ並べる）
        routeLine = {
            enabled = true,
            from = 'player',                     -- 'player' = 自分の位置から次のCPまで / 'checkpoint' = 次のCPからその次のCPまで
            image = 'html/img/markers/route_dash.png',  -- 白い画像（色は color で付ける）
            color = nil,                         -- 線の色（nil = 目標のマーカーの ringColor に合わせる）
            alpha = 200,                         -- 透明度（0-255、遠いほど薄くなる）
            size = 3.0,                          -- 1区切りの大きさ（メートル）
            spacing = 4.0,                       -- 区切りの間隔（メートル）
            startDistance = 4.0,                 -- 自分から何メートル先から表示するか（from = 'player' のとき）
            maxDistance = 60.0,                  -- 何メートル先まで表示するか
            followGround = true,                 -- 地面に沿わせる
            updateInterval = 100,                -- 位置の再計算の間隔（ミリ秒）
            rotationOffset = 0.0,                -- 矢印の向きが進行方向とずれる場合に調整（例: 180.0 / 90.0）
            linkNext = false,                    -- 次のチェックポイントからその次へ細い線を引く
            linkAlpha = 150                      -- 細い線の透明度
        },
        
        -- 曲がり角ガイド（オレンジの矢印、そのチェックポイントに向かっている間に表示）
        -- 自動: コースの向きから曲がるチェックポイントを判定し、カーブの外側に表示
        -- 手動: コース作成モードで [←] [→] を押した場所に表示（一番近いチェックポイントに紐づく）
        turnGuide = {
            enabled = true,
            auto = true,                         -- 自動ガイドを使うか
            manualOverridesAuto = true,          -- 手動ガイドがあるコースでは自動ガイドを出さない
            minAngle = 35.0,                     -- この角度（度）以上曲がる場所にだけ表示（自動）
            distance = 12.0,                     -- 自動ガイドをチェックポイントの中心からカーブの外側へ離す距離（メートル）
            
            -- 横に長いガイド（光の柱のない矢印 turn_strip_* を壁に沿う向きに並べる）
            -- 手動: コース作成モードで置いた後に [↑] [↓] で長さを変更
            autoLongAngle = 80.0,                -- 自動ガイドはこの角度（度）以上の急カーブで長くする（nil で無効）
            autoLongSegments = 3,                -- 自動で長くするときの矢印の数
            maxSegments = 8,                     -- 手動で並べられる矢印の最大数
            segmentSpacing = 2.0                 -- 並べる間隔（メートル）
        },
        
        -- 用途別の画像（image はリソース内のパス、fxmanifest の files にも登録が必要）
        styles = {
            -- 次に通過するチェックポイント（コース作成モードの設置済みポイントにも使用）
            checkpoint = {
                image = 'html/img/markers/checkpoint.png',
                alpha = 230,
                ringColor = {r = 120, g = 255, b = 0}
            },
            -- 先のチェックポイントの予告
            preview = {
                image = 'html/img/markers/preview.png',
                alpha = 150,
                size = 10.0,
                ringColor = {r = 0, g = 220, b = 255}
            },
            -- ゴール（最終周の最後のチェックポイント）
            finish = {
                image = 'html/img/markers/finish.png',
                alpha = 240,
                ringColor = {r = 255, g = 210, b = 0}
            },
            -- 曲がり角ガイド（左・右）
            turn_left = {
                image = 'html/img/markers/turn_left.png',
                alpha = 240,
                size = 8.0
            },
            turn_right = {
                image = 'html/img/markers/turn_right.png',
                alpha = 240,
                size = 8.0
            },
            -- 横に長いガイド用の矢印（光の柱なし、横に並べて使う）
            turn_strip_left = {
                image = 'html/img/markers/turn_strip_left.png',
                alpha = 240,
                size = 3.0,
                groundAnchor = -0.3              -- 地面から少し浮かせる
            },
            turn_strip_right = {
                image = 'html/img/markers/turn_strip_right.png',
                alpha = 240,
                size = 3.0,
                groundAnchor = -0.3
            }
        },
        
        -- 乗り物ごとの画像セット（ここにない設定・画像は上の共通設定を使う）
        vehicleTypes = {
            -- ヘリ: 空中でくぐるリング型
            heli = {
                centerOnPoint = true,            -- チェックポイントの位置を中心に表示（空中）
                turnGuideDistance = 16.0,        -- 自動ガイドをリングの外側に出す（反応範囲の半径 + 余白）
                turnGuideSegmentSpacing = 4.0,   -- 横に長いガイドの並べる間隔
                
                -- 反応範囲（空中なので半透明の球。チェックポイントからこの半径以内で通過）
                radiusRing = {
                    enabled = true,
                    sphere = true,
                    sphereAlpha = 110,               -- 球の透明度（0-255）
                    sphereScale = 1.0,               -- 球の大きさが反応範囲とずれる場合に調整
                    outline = false,
                    fill = false
                },
                
                -- ルート線（次のチェックポイントからその次のチェックポイントへ、空中に矢印を並べる）
                routeLine = {
                    enabled = true,
                    from = 'checkpoint',
                    color = {r = 0, g = 220, b = 255},
                    alpha = 220,
                    size = 5.0,
                    spacing = 8.0,
                    maxDistance = 500.0,
                    followGround = false,
                    linkNext = false
                },
                
                -- チェックポイントは半透明の球（反応範囲）＋マーカー（中心のひし形 / ゴールはチェッカーのリング）で表示
                -- 球だけにする場合は showImage = false
                styles = {
                    checkpoint = {
                        image = 'html/img/markers/heli_checkpoint.png',
                        size = 5.0,
                        alpha = 230,
                        ringColor = {r = 120, g = 255, b = 0}
                    },
                    preview = {
                        image = 'html/img/markers/heli_preview.png',
                        size = 3.5,
                        alpha = 150,
                        ringColor = {r = 0, g = 220, b = 255}
                    },
                    finish = {
                        image = 'html/img/markers/heli_finish.png',  -- チェッカー模様の帯付きリング
                        sizeFromRadius = 2.5,            -- 画像の大きさ = 反応範囲の半径 × 2.5（リングの直径が球と一致）
                        alpha = 240,
                        ringColor = {r = 255, g = 210, b = 0}
                    },
                    turn_left = {
                        image = 'html/img/markers/heli_turn_left.png',
                        alpha = 240,
                        size = 12.0
                    },
                    turn_right = {
                        image = 'html/img/markers/heli_turn_right.png',
                        alpha = 240,
                        size = 12.0
                    },
                    -- 横に長いガイド（画像は共通の turn_strip_* を使う）
                    turn_strip_left = {
                        size = 6.0
                    },
                    turn_strip_right = {
                        size = 6.0
                    }
                }
            }
        }
    }
}

-- ===================================
-- レース基本設定
-- ===================================
Config.Race = {
    -- カウントダウン
    countdownSeconds = 3,        -- ソロレースのカウントダウン時間（スタート地点到着後）
    
    -- レース中の車両乗り換えチェック（スタート時の車両以外で走るとリタイア）
    vehicleSwapCheck = {
        enabled = true,
        graceSeconds = 10        -- 降りたり乗り換えたりしてから、元の車両に戻るまでの猶予（秒）
    },
    
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
-- タイムアタック（TA）
-- レース作成後、calibrationRuns 回のゴール（calibrationDrivers 人以上）がそろうと、
-- 各ドライバーのベストタイムの平均が「目標タイム」になる（極端に遅いベストは除く）。
-- 目標タイム以内でゴールすると、1人1レースにつき1回だけ報酬がもらえる。
-- ===================================
Config.TimeAttack = {
    enabled = true,
    calibrationRuns = 10,          -- 目標タイムを決めるのに必要なゴール数
    calibrationDrivers = 3,        -- そのうち必要なドライバーの人数（1人だけで目標タイムを決められないように）
    calibrationOutlierFactor = 1.5, -- ベストタイムの中央値のこの倍より遅いベストは平均から除く

    -- 報酬 = レート × unit（レートはコースの長さ・チェックポイントの密度・目標タイムから自動計算）
    -- スコア = 距離(km) × distanceWeight
    --        + 1kmあたりのチェックポイント数（最大 checkpointDensityCap）× checkpointDensityWeight
    --        + 目標タイム(分) × timeWeight
    --        + 低速ボーナス（細道・カーブが多く平均速度が低いコースほど加算）
    -- ※ チェックポイントは数ではなく密度で見る（長いコースは数が多くなるが、長さは距離で数えているため）
    -- レート = スコアを四捨五入して minRate ～ maxRate に収めたもの
    reward = {
        unit = 1000000,            -- レート1あたりの金額（100万）
        minRate = 1,               -- 最低レート（100万）
        maxRate = 15,              -- 最高レート（1500万）
        distanceWeight = 0.5,      -- 1km ごとに +0.5
        checkpointDensityWeight = 0.1, -- 1kmあたりのチェックポイント 1個 ごとに +0.1（例: 2kmに30個 = 15個/km → +1.5）
        checkpointDensityCap = 30,     -- 密度はこの値までで数える（最大 +3.0）
        timeWeight = 0.5,          -- 1分 ごとに +0.5
        
        -- 低速ボーナス = weight × (1 - 平均速度 / 基準速度)（平均速度が基準以上なら 0）
        -- 平均速度 = コースの長さ ÷ 目標タイム。基準速度は車両タイプごと（ボートやヘリが元々遅い・速いぶんを補正）
        -- 例: 自動車で 2km を 2分（時速60km）→ +1.0 / 5分（時速24km）→ +1.6
        slowBonus = {
            enabled = true,
            weight = 2.0,
            referenceSpeed = {     -- km/h
                car = 120.0,
                heli = 200.0,
                boat = 80.0
            }
        }
    }
}

-- ===================================
-- デイリーレース
-- 毎日サーバー共通で raceCount 個のレースをランダムに選ぶ（目標タイムが決まっているレースから）。
-- 完走で報酬の finishShare、目標タイム以内で残り（1 - finishShare）。それぞれ1日1回。
-- 両方受け取ったレースはその日はデイリーとして出走できない。
-- ===================================
Config.Daily = {
    enabled = true,
    raceCount = {min = 1, max = 2},  -- 1日に選ぶレース数（この範囲でランダム）
    rewardMultiplier = 1.0,        -- デイリーの報酬総額 = そのレースの TA 報酬 × この倍率
    finishShare = 1 / 3            -- 完走でもらえる割合（残りは目標タイムクリアで）
}

-- ===================================
-- ランキング（ポイント）
-- ===================================
Config.Ranking = {
    enabled = true,
    startPoints = 1000,            -- 初期ポイント
    solo = {
        finish = 5,                -- ソロで完走（同じレースは1日1回まで）
        beatTarget = 10,           -- ソロで目標タイム以内（同じレースは1日1回まで）
        retire = -5                -- ソロでリタイア
    },
    multiplayer = {
        -- 参加者同士でポイントをやり取りする。
        -- 自分より下の順位（リタイアはゴールした人より下）の参加者1人につき、その人から pointsPerOpponent をもらう
        pointsPerOpponent = 5
    },
    topCount = 50                  -- ランキングに表示する人数
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
    
    -- 制限時間（走り続けている人がいてもレースを終わらせる）
    maxRaceDuration = 1800,      -- レース全体の制限時間（秒）
    finishTimeout = 180,         -- 1位がゴールしてから、残りの人がゴールできる時間（秒）
    
    -- ===================================
    -- ゴーストモード設定（最重要）
    -- ===================================
    ghostMode = {
        enabled = true,                -- ゴーストモード有効化
        soloEnabled = true,            -- ソロレースでもゴーストモード有効化（NPC衝突回避）
        
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
        maxDistanceFromStart = 3.0,    -- カウントダウン開始位置から動ける最大距離（メートル）
        startAreaRadius = 30.0,        -- スタート地点からこの半径内にいる人だけがレースに出られる（メートル）
        teleportBackToStart = true,    -- 範囲外に出たら戻す
        showWarnings = true            -- 警告表示
    }
}

-- ===================================
-- レース参加者専用オブジェクト設定
-- ===================================
Config.RaceObjects = {
    enabled = false,               -- オブジェクト生成の無効化（CreateCheckpointで十分なため）
    
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
    
    -- 表示モード
    -- 'standalone' : 今までどおり /race で全画面のメニューを開く
    -- 'tablet'     : cam_tablet のアプリとして開く（/race はアプリを開くショートカット）
    -- ※ レース中の HUD はどちらのモードでも画面に表示
    -- ※ tablet でもタブレットのリソースが起動していなければ standalone で動作
    mode = 'standalone',
    
    -- タブレット連携（mode = 'tablet' のとき）
    tablet = {
        resource = 'cam_tablet',   -- タブレットのリソース名
        commandOpensApp = true,    -- /race（とキーバインド）でタブレットのアプリを開く
        
        -- タブレットに登録するアプリ（cam_tablet の RegisterApp にそのまま渡す）
        app = {
            id = 'racing',
            label = 'レーシング',
            description = 'レースの一覧・ランキング・セッション参加・コース作成',
            icon = 'fa-solid fa-flag-checkered',  -- Font Awesome 6 のクラス、または画像URL
            color = '#ef4444',
            category = 'ゲーム',
            developer = 'CAM Racing',
            size = 24,                 -- MB（ダウンロード演出用）
            featured = true,           -- ストアのおすすめに表示
            system = false,            -- true で全員インストール済み & 削除不可
            -- deviceItem = 'racing_tablet',  -- このアプリ専用の端末アイテム（ox_inventory に定義が必要）
            -- jobs = { racer = 0 },          -- 職業制限
            -- item = 'usb_racing',           -- インストールに必要なアイテム
        }
    },
    
    -- ページネーション
    racesPerPage = 12,             -- 1ページあたりのレース数
    gridColumns = 4,               -- グリッド列数
    
    -- レース作成モード
    creationKeybinds = {
        placeCheckpoint = 38,      -- E
        finishCreation = 45,       -- R
        cancelCreation = 200,      -- ESC
        deleteLastCheckpoint = 194, -- Backspace（177 は右クリックでも反応するため使わない）
        placeTurnLeft = 174,       -- ← 左曲がりガイド設置
        placeTurnRight = 175,      -- → 右曲がりガイド設置
        deleteLastTurnGuide = 178, -- Delete 最後のガイド削除
        longerTurnGuide = 172,     -- ↑ 最後のガイドを横に長く
        shorterTurnGuide = 173     -- ↓ 最後のガイドを短く
    },
    
    -- レース中キーバインド
    raceKeybinds = {
        retire = 73               -- X キー（INPUT_VEH_DUCK = 73）でリタイア
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
        teleportDetection = true,  -- テレポート検出（走行中の位置を checkInterval ごとに確認し、あり得ない移動をした走行は記録しない）
        teleportThreshold = 100.0, -- テレポート判定の余裕（メートル）。許容距離 = この値 + maxSpeed × 経過時間
        progressDistanceMargin = 100.0, -- チェックポイント通過の許容距離の既定値（車両タイプごとの progressDistanceMargin が無い場合に使う）
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
    
    if Config.Checkpoint and Config.Checkpoint.minCheckpoints < 3 then
        table.insert(errors, 'minCheckpoints must be at least 3')
    end
    
    -- エラー表示
    if #errors > 0 then
        print('^1[CAM Racing]^7 Config validation errors:')
        for _, error in ipairs(errors) do
            print('^1  - ^7' .. error)
        end
        return false
    end
    
    print('^2[CAM Racing]^7 Config validation passed')
    return true
end

-- 初期化メッセージ
if IsDuplicityVersion() then
    -- サーバーサイド
    print('^2[CAM Racing]^7 Config loaded successfully')
    print('^2[CAM Racing]^7 Version: ' .. Config.Version.major .. '.' .. Config.Version.minor .. '.' .. Config.Version.patch)
    print('^2[CAM Racing]^7 Multiplayer: ' .. (Config.Multiplayer.enabled and 'Enabled' or 'Disabled'))
    print('^2[CAM Racing]^7 Ghost Mode: ' .. (Config.Multiplayer.ghostMode.enabled and 'Enabled' or 'Disabled'))
else
    -- クライアントサイド
    print('^2[CAM Racing]^7 Client config loaded')
end

-- 開発モードの場合は検証実行
if Config.Debug and Config.Debug.enabled then
    CreateThread(function()
        Wait(1000)
        ValidateConfig()
    end)
end
