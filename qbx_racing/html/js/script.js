// html/js/script.js

let currentRaces = [];
let filteredRaces = [];
let currentPage = 1;
let racesPerPage = 12;
let selectedRaceId = null;
let currentFilter = 'all';
let searchQuery = '';

// NUIメッセージ受信
window.addEventListener('message', function(event) {
    const data = event.data;
    
    switch(data.action) {
        case 'openUI':
            openRacingUI(data);
            break;
        case 'closeUI':
            closeRacingUI();
            break;
        case 'updateRaces':
            loadRaces();
            break;
        case 'showDriverSetup':
            showDriverSetup();
            break;
    }
});

// UI開く
function openRacingUI(data) {
    $('#racing-ui').fadeIn(300);
    
    if (data.hasProfile) {
        $('#current-driver-name').text(data.driverName);
        $('#main-screen').show();
        $('#driver-setup-modal').hide();
        
        // 管理者権限チェック
        if (data.isAdmin) {
            $('#admin-controls').show();
        }
        
        loadRaces();
    } else {
        showDriverSetup();
    }
}

// UI閉じる
function closeRacingUI() {
    $('#racing-ui').fadeOut(300);
    $.post(`https://${GetParentResourceName()}/closeUI`);
}

// ドライバー登録画面表示
function showDriverSetup() {
    $('#main-screen').hide();
    $('#driver-setup-modal').show();
}

// レース一覧読み込み
function loadRaces() {
    $.post(`https://${GetParentResourceName()}/getRaces`, JSON.stringify({}))
        .done(function(races) {
            currentRaces = races || [];
            filterAndDisplayRaces();
        })
        .fail(function() {
            console.error('Failed to load races');
        });
}

// フィルタリングと表示
function filterAndDisplayRaces() {
    filteredRaces = currentRaces.filter(race => {
        const typeMatch = currentFilter === 'all' || race.vehicle_type === currentFilter;
        const searchMatch = !searchQuery || 
            race.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
            (race.creator_driver_name && race.creator_driver_name.toLowerCase().includes(searchQuery.toLowerCase()));
        
        return typeMatch && searchMatch;
    });
    
    currentPage = 1;
    displayRaces();
    updatePagination();
}

// レース表示（グリッド）
function displayRaces() {
    const grid = $('#race-grid');
    grid.empty();
    
    const startIndex = (currentPage - 1) * racesPerPage;
    const endIndex = Math.min(startIndex + racesPerPage, filteredRaces.length);
    const racesToShow = filteredRaces.slice(startIndex, endIndex);
    
    if (racesToShow.length === 0) {
        grid.append(`
            <div class="no-races">
                <i class="fas fa-search"></i>
                <p>レースが見つかりません</p>
            </div>
        `);
        return;
    }
    
    racesToShow.forEach(race => {
        const vehicleConfig = getVehicleConfig(race.vehicle_type);
        const bestTimeText = race.best_time ? 
            formatTime(race.best_time) : 'タイムなし';
        const bestHolderText = race.best_player || '';
        
        const raceCard = $(`
            <div class="race-card" data-race-id="${race.id}">
                <div class="race-header">
                    <div>
                        <div class="race-name">${race.name}</div>
                    </div>
                    <div class="vehicle-badge ${race.vehicle_type}">
                        <i class="${vehicleConfig.icon}"></i> ${vehicleConfig.label}
                    </div>
                </div>
                
                <div class="race-stats">
                    <div class="stat-row">
                        <span>周回数:</span>
                        <span class="stat-value">${race.laps}</span>
                    </div>
                    <div class="stat-row">
                        <span>作成者:</span>
                        <span class="stat-value">${race.creator_driver_name || '不明'}</span>
                    </div>
                    <div class="stat-row">
                        <span>参加回数:</span>
                        <span class="stat-value">${race.total_attempts || 0}</span>
                    </div>
                </div>
                
                <div class="best-time">
                    <div class="time">${bestTimeText}</div>
                    ${bestHolderText ? `<div class="holder">by ${bestHolderText}</div>` : ''}
                </div>
            </div>
        `);
        
        raceCard.on('click', () => showRaceDetail(race.id));
        grid.append(raceCard);
    });
}

// ページネーション更新
function updatePagination() {
    const totalPages = Math.ceil(filteredRaces.length / racesPerPage);
    const pageNumbers = $('#page-numbers');
    pageNumbers.empty();
    
    // 前へボタン
    $('#prev-page').prop('disabled', currentPage === 1);
    
    // 次へボタン  
    $('#next-page').prop('disabled', currentPage === totalPages);
    
    // ページ番号
    const maxVisiblePages = 5;
    let startPage = Math.max(1, currentPage - Math.floor(maxVisiblePages / 2));
    let endPage = Math.min(totalPages, startPage + maxVisiblePages - 1);
    
    if (endPage - startPage + 1 < maxVisiblePages) {
        startPage = Math.max(1, endPage - maxVisiblePages + 1);
    }
    
    for (let i = startPage; i <= endPage; i++) {
        const pageBtn = $(`
            <button class="page-number ${i === currentPage ? 'active' : ''}" data-page="${i}">
                ${i}
            </button>
        `);
        pageBtn.on('click', () => goToPage(i));
        pageNumbers.append(pageBtn);
    }
}

// ページ移動
function goToPage(page) {
    currentPage = page;
    displayRaces();
    updatePagination();
}

// レース詳細表示
function showRaceDetail(raceId) {
    selectedRaceId = raceId;
    const race = currentRaces.find(r => r.id === raceId);
    
    if (!race) return;
    
    const vehicleConfig = getVehicleConfig(race.vehicle_type);
    
    $('#detail-race-name').text(race.name);
    $('#detail-vehicle-type').html(`<i class="${vehicleConfig.icon}"></i> ${vehicleConfig.label}`);
    $('#detail-laps').text(race.laps);
    $('#detail-creator').text(race.creator_driver_name || '不明');
    $('#detail-attempts').text(race.total_attempts || 0);
    
    // ランキング読み込み
    loadLeaderboard(raceId);
    
    $('#race-detail-modal').fadeIn(200);
}

// ランキング読み込み
function loadLeaderboard(raceId) {
    $.post(`https://${GetParentResourceName()}/getLeaderboard`, JSON.stringify({raceId: raceId}))
        .done(function(leaderboard) {
            displayLeaderboard(leaderboard || []);
        })
        .fail(function() {
            console.error('Failed to load leaderboard');
        });
}

// ランキング表示
function displayLeaderboard(leaderboard) {
    const list = $('#leaderboard-list');
    list.empty();
    
    if (leaderboard.length === 0) {
        list.append(`
            <div class="no-records">
                <i class="fas fa-trophy"></i>
                <p>まだ記録がありません</p>
            </div>
        `);
        return;
    }
    
    leaderboard.forEach((record, index) => {
        let rankClass = 'normal';
        if (index === 0) rankClass = 'gold';
        else if (index === 1) rankClass = 'silver'; 
        else if (index === 2) rankClass = 'bronze';
        
        const item = $(`
            <div class="leaderboard-item">
                <div class="rank-badge ${rankClass}">${index + 1}</div>
                <div class="driver-info-lb">
                    <div class="driver-name-lb">${record.driver_name}</div>
                    <div class="vehicle-model">${record.vehicle_model}</div>
                </div>
                <div class="time-display">${formatTime(record.time_ms)}</div>
            </div>
        `);
        
        list.append(item);
    });
}

// 車両設定取得
function getVehicleConfig(type) {
    const configs = {
        car: { label: '自動車', icon: 'fas fa-car' },
        heli: { label: 'ヘリコプター', icon: 'fas fa-helicopter' },
        boat: { label: 'ボート', icon: 'fas fa-ship' }
    };
    return configs[type] || configs.car;
}

//時間フォーマット
function formatTime(ms) {
    const seconds = (ms / 1000).toFixed(2);
    return `${seconds}s`;
}

// ドライバーネーム検証
function validateDriverName(name) {
    if (!name || name.length < 3 || name.length > 20) {
        return false;
    }
    return /^[a-zA-Z0-9_]+$/.test(name);
}

// イベントハンドラー
$(document).ready(function() {
    // 閉じるボタン
    $('#close-ui-btn, .close-modal').on('click', closeRacingUI);
    
    // フィルターボタン
    $('.filter-btn').on('click', function() {
        if ($(this).hasClass('active')) return;
        
        $('.filter-btn').removeClass('active');
        $(this).addClass('active');
        
        currentFilter = $(this).data('filter');
        filterAndDisplayRaces();
    });
    
    // 検索
    $('#search-input').on('input', function() {
        searchQuery = $(this).val();
        filterAndDisplayRaces();
    });
    
    // ページネーション
    $('#prev-page').on('click', () => {
        if (currentPage > 1) goToPage(currentPage - 1);
    });
    
    $('#next-page').on('click', () => {
        const totalPages = Math.ceil(filteredRaces.length / racesPerPage);
        if (currentPage < totalPages) goToPage(currentPage + 1);
    });
    
    // ドライバー登録
    $('#register-driver-btn').on('click', function() {
        const driverName = $('#driver-name-input').val().trim();
        
        if (!validateDriverName(driverName)) {
            alert('ドライバーネームは3-20文字の英数字とアンダースコアのみ使用可能です。');
            return;
        }
        
        // ボタン無効化（重複送信防止）
        $(this).prop('disabled', true).text('登録中...');
        
        $.post(`https://${GetParentResourceName()}/registerDriver`, JSON.stringify({
            driverName: driverName
        }))
        .done(function(result) {
            if (result.success) {
                $('#current-driver-name').text(result.driverName);
                $('#driver-setup-modal').fadeOut(200);
                $('#main-screen').fadeIn(200);
                loadRaces();
            } else {
                alert(result.message || 'ドライバー名の登録に失敗しました。');
            }
        })
        .fail(function() {
            alert('サーバーとの通信に失敗しました。');
        })
        .always(function() {
            // ボタン復元
            $('#register-driver-btn').prop('disabled', false).html('<i class="fas fa-check"></i> 登録');
        });
    });
    
    // ドライバー名編集
    $('#edit-driver-btn').on('click', function() {
        const newName = prompt('新しいドライバーネームを入力してください:', $('#current-driver-name').text());
        
        if (newName && validateDriverName(newName)) {
            $.post(`https://${GetParentResourceName()}/updateDriverName`, JSON.stringify({
                driverName: newName
            }))
            .done(function(result) {
                if (result.success) {
                    $('#current-driver-name').text(result.driverName);
                } else {
                    alert(result.message || 'ドライバー名の更新に失敗しました。');
                }
            })
            .fail(function() {
                alert('サーバーとの通信に失敗しました。');
            });
        }
    });
    
    // レース開始
    $('#start-race-btn').on('click', function() {
        if (!selectedRaceId) return;
        
        $.post(`https://${GetParentResourceName()}/startRace`, JSON.stringify({
            raceId: selectedRaceId
        }));
        
        closeRacingUI();
    });
    
    // 新規レース作成
    $('#create-race-btn').on('click', function() {
        $.post(`https://${GetParentResourceName()}/createRace`);
        closeRacingUI();
    });
    
    // ESCキーで閉じる
    $(document).on('keydown', function(e) {
        if (e.key === 'Escape') {
            closeRacingUI();
        }
    });
});
