// html/js/script.js
// QBX Racing System - NUI Script v4.2.0

let currentRaces = [];
let filteredRaces = [];
let currentPage = 1;
let racesPerPage = 12;
let selectedRaceId = null;
let currentFilter = 'all';
let searchQuery = '';
let isAdmin = false;
let isCurrentlyRacing = false;

// ===================================
// NUIメッセージ受信
// ===================================
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
        case 'updateRaceHUD':
            updateRaceHUD(data);
            break;
    }
});

// ===================================
// FiveM NUI API ヘルパー
// ===================================
function getResourceName() {
    if (typeof GetParentResourceName === 'function') {
        return GetParentResourceName();
    }
    return 'qbx_racing';
}

function nuiPost(endpoint, data) {
    return fetch(`https://${getResourceName()}/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data || {})
    }).then(res => res.json()).catch(err => {
        console.error(`NUI POST ${endpoint} failed:`, err);
        return null;
    });
}

// ===================================
// UI開閉
// ===================================
function openRacingUI(data) {
    const ui = document.getElementById('racing-ui');
    ui.style.display = 'flex';
    ui.style.opacity = '0';
    requestAnimationFrame(() => {
        ui.style.transition = 'opacity 0.3s ease';
        ui.style.opacity = '1';
    });
    
    if (data.hasProfile) {
        document.getElementById('current-driver-name').textContent = data.driverName;
        document.getElementById('main-screen').style.display = 'flex';
        document.getElementById('driver-setup-modal').style.display = 'none';
        
        isAdmin = data.isAdmin || false;
        isCurrentlyRacing = data.isRacing || false;
        
        if (isAdmin) {
            document.getElementById('admin-controls').style.display = 'block';
        } else {
            document.getElementById('admin-controls').style.display = 'none';
        }
        
        // レース中ならキャンセルボタンを表示
        const cancelControls = document.getElementById('race-cancel-controls');
        if (cancelControls) {
            cancelControls.style.display = isCurrentlyRacing ? 'flex' : 'none';
        }
        
        loadRaces();
    } else {
        showDriverSetup();
    }
}

function closeRacingUI() {
    const ui = document.getElementById('racing-ui');
    ui.style.transition = 'opacity 0.25s ease';
    ui.style.opacity = '0';
    setTimeout(() => {
        ui.style.display = 'none';
    }, 250);
    nuiPost('closeUI');
}

function showDriverSetup() {
    document.getElementById('main-screen').style.display = 'none';
    document.getElementById('driver-setup-modal').style.display = 'flex';
}

// ===================================
// レース一覧読み込み
// ===================================
function loadRaces() {
    nuiPost('getRaces').then(races => {
        currentRaces = races || [];
        filterAndDisplayRaces();
    });
}

function filterAndDisplayRaces() {
    filteredRaces = currentRaces.filter(race => {
        const typeMatch = currentFilter === 'all' || race.vehicle_type === currentFilter;
        const query = searchQuery.toLowerCase();
        const searchMatch = !query || 
            race.name.toLowerCase().includes(query) ||
            (race.creator_driver_name && race.creator_driver_name.toLowerCase().includes(query));
        
        return typeMatch && searchMatch;
    });
    
    currentPage = 1;
    displayRaces();
    updatePagination();
}

// ===================================
// レース表示（グリッド）
// ===================================
function displayRaces() {
    const grid = document.getElementById('race-grid');
    grid.innerHTML = '';
    
    const startIndex = (currentPage - 1) * racesPerPage;
    const endIndex = Math.min(startIndex + racesPerPage, filteredRaces.length);
    const racesToShow = filteredRaces.slice(startIndex, endIndex);
    
    if (racesToShow.length === 0) {
        grid.innerHTML = `
            <div class="no-races">
                <i class="fas fa-flag-checkered"></i>
                <p>レースが見つかりません</p>
                <p class="hint">${currentRaces.length === 0 ? '管理者がレースを作成するとここに表示されます' : 'フィルター条件を変更してください'}</p>
            </div>
        `;
        return;
    }
    
    racesToShow.forEach(race => {
        const vConfig = getVehicleConfig(race.vehicle_type);
        const rConfig = getRaceTypeConfig(race.race_type);
        const bestTimeText = race.best_time ? formatTime(race.best_time) : null;
        const bestHolderText = race.best_player || '';
        
        const card = document.createElement('div');
        card.className = 'race-card';
        card.setAttribute('data-race-id', race.id);
        
        card.innerHTML = `
            <div class="race-header">
                <div class="race-name">${escapeHtml(race.name)}</div>
                <div class="badge-group">
                    <div class="vehicle-badge ${race.vehicle_type}">
                        <i class="${vConfig.icon}"></i> ${vConfig.label}
                    </div>
                    <div class="race-type-badge ${race.race_type || 'circuit'}">
                        <i class="${rConfig.icon}"></i> ${rConfig.label}
                    </div>
                </div>
            </div>
            
            <div class="race-stats">
                <div class="stat-row">
                    <span><i class="fas fa-redo"></i> 周回数</span>
                    <span class="stat-value">${race.laps || 1}</span>
                </div>
                <div class="stat-row">
                    <span><i class="fas fa-user"></i> 作成者</span>
                    <span class="stat-value">${escapeHtml(race.creator_driver_name || '不明')}</span>
                </div>
                <div class="stat-row">
                    <span><i class="fas fa-chart-line"></i> 参加回数</span>
                    <span class="stat-value">${race.total_attempts || 0}</span>
                </div>
            </div>
            
            <div class="best-time">
                ${bestTimeText 
                    ? `<div class="time">${bestTimeText}</div>
                       ${bestHolderText ? `<div class="holder">by ${escapeHtml(bestHolderText)}</div>` : ''}`
                    : '<div class="no-record">タイム未記録</div>'
                }
            </div>
        `;
        
        card.addEventListener('click', () => showRaceDetail(race.id));
        grid.appendChild(card);
    });
}

// ===================================
// ページネーション
// ===================================
function updatePagination() {
    const totalPages = Math.max(1, Math.ceil(filteredRaces.length / racesPerPage));
    const pageNumbers = document.getElementById('page-numbers');
    pageNumbers.innerHTML = '';
    
    document.getElementById('prev-page').disabled = currentPage <= 1;
    document.getElementById('next-page').disabled = currentPage >= totalPages;
    
    const maxVisible = 5;
    let startPage = Math.max(1, currentPage - Math.floor(maxVisible / 2));
    let endPage = Math.min(totalPages, startPage + maxVisible - 1);
    
    if (endPage - startPage + 1 < maxVisible) {
        startPage = Math.max(1, endPage - maxVisible + 1);
    }
    
    for (let i = startPage; i <= endPage; i++) {
        const btn = document.createElement('button');
        btn.className = `page-number${i === currentPage ? ' active' : ''}`;
        btn.textContent = i;
        btn.addEventListener('click', () => goToPage(i));
        pageNumbers.appendChild(btn);
    }
}

function goToPage(page) {
    currentPage = page;
    displayRaces();
    updatePagination();
    
    // スクロールをトップに
    const grid = document.getElementById('race-grid');
    grid.scrollTop = 0;
}

// ===================================
// レース詳細表示
// ===================================
function showRaceDetail(raceId) {
    selectedRaceId = raceId;
    const race = currentRaces.find(r => r.id === raceId);
    if (!race) return;
    
    const vConfig = getVehicleConfig(race.vehicle_type);
    const rConfig = getRaceTypeConfig(race.race_type);
    
    document.getElementById('detail-race-name').textContent = race.name;
    document.getElementById('detail-vehicle-type').innerHTML = `<i class="${vConfig.icon}"></i> ${vConfig.label}`;
    document.getElementById('detail-race-type').innerHTML = `<i class="${rConfig.icon}"></i> ${rConfig.label}`;
    document.getElementById('detail-laps').textContent = race.laps || 1;
    document.getElementById('detail-creator').textContent = race.creator_driver_name || '不明';
    document.getElementById('detail-attempts').textContent = race.total_attempts || 0;
    
    // 管理者のみ削除ボタン表示
    const deleteBtn = document.getElementById('delete-race-btn');
    deleteBtn.style.display = isAdmin ? 'block' : 'none';
    
    loadLeaderboard(raceId);
    
    const modal = document.getElementById('race-detail-modal');
    modal.style.display = 'flex';
    modal.style.opacity = '0';
    requestAnimationFrame(() => {
        modal.style.transition = 'opacity 0.2s ease';
        modal.style.opacity = '1';
    });
}

function closeDetailModal() {
    const modal = document.getElementById('race-detail-modal');
    modal.style.transition = 'opacity 0.2s ease';
    modal.style.opacity = '0';
    setTimeout(() => {
        modal.style.display = 'none';
    }, 200);
    selectedRaceId = null;
}

// ===================================
// ランキング
// ===================================
function loadLeaderboard(raceId) {
    nuiPost('getLeaderboard', { raceId: raceId }).then(leaderboard => {
        displayLeaderboard(leaderboard || []);
    });
}

function displayLeaderboard(leaderboard) {
    const list = document.getElementById('leaderboard-list');
    list.innerHTML = '';
    
    if (leaderboard.length === 0) {
        list.innerHTML = `
            <div class="no-records">
                <i class="fas fa-trophy"></i>
                <p>まだ記録がありません</p>
            </div>
        `;
        return;
    }
    
    leaderboard.forEach((record, index) => {
        let rankClass = 'normal';
        if (index === 0) rankClass = 'gold';
        else if (index === 1) rankClass = 'silver'; 
        else if (index === 2) rankClass = 'bronze';
        
        const item = document.createElement('div');
        item.className = 'leaderboard-item';
        item.innerHTML = `
            <div class="rank-badge ${rankClass}">${index + 1}</div>
            <div class="driver-info-lb">
                <div class="driver-name-lb">${escapeHtml(record.driver_name)}</div>
                <div class="vehicle-model">${escapeHtml(record.vehicle_model || '')}</div>
            </div>
            <div class="time-display">${formatTime(record.time_ms)}</div>
        `;
        
        list.appendChild(item);
    });
}

// ===================================
// レース中HUDオーバーレイ
// ===================================
function updateRaceHUD(data) {
    const hud = document.getElementById('race-hud');
    if (!hud) return;
    
    if (!data.visible) {
        hud.style.display = 'none';
        return;
    }
    
    hud.style.display = 'block';
    
    document.getElementById('hud-race-type').textContent = data.raceType || '';
    document.getElementById('hud-time').textContent = (data.time || '0.00') + 's';
    document.getElementById('hud-checkpoint').textContent = (data.checkpoint || 0) + ' / ' + (data.totalCheckpoints || 0);
    document.getElementById('hud-lap').textContent = (data.lap || 1) + ' / ' + (data.totalLaps || 1);
    
    const posRow = document.getElementById('hud-position-row');
    if (data.isMultiplayer && data.position != null) {
        posRow.style.display = 'flex';
        document.getElementById('hud-position').textContent = data.position + ' / ' + (data.totalParticipants || 1);
    } else {
        posRow.style.display = 'none';
    }
}

// ===================================
// ヘルパー関数
// ===================================
function getVehicleConfig(type) {
    const configs = {
        car:  { label: '自動車',       icon: 'fas fa-car' },
        heli: { label: 'ヘリコプター', icon: 'fas fa-helicopter' },
        boat: { label: 'ボート',       icon: 'fas fa-ship' }
    };
    return configs[type] || configs.car;
}

function getRaceTypeConfig(type) {
    const configs = {
        circuit: { label: '周回',       icon: 'fas fa-redo' },
        sprint:  { label: 'スプリント', icon: 'fas fa-bolt' }
    };
    return configs[type] || configs.circuit;
}

function formatTime(ms) {
    if (!ms || ms <= 0) return '--:--';
    
    const totalSeconds = ms / 1000;
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    
    if (minutes > 0) {
        return `${minutes}:${seconds.toFixed(2).padStart(5, '0')}`;
    }
    return `${seconds.toFixed(2)}s`;
}

function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function validateDriverName(name) {
    if (!name || name.length < 3 || name.length > 20) return false;
    return /^[a-zA-Z0-9_]+$/.test(name);
}

// ===================================
// イベントハンドラー初期化
// ===================================
document.addEventListener('DOMContentLoaded', function() {
    // 閉じるボタン（UI全体を閉じる）
    document.getElementById('close-ui-btn').addEventListener('click', closeRacingUI);
    
    // 詳細モーダルの閉じるボタン（モーダルだけ閉じる）
    document.querySelector('.close-detail-modal').addEventListener('click', function(e) {
        e.stopPropagation();
        closeDetailModal();
    });
    
    // 詳細モーダルの背景クリックで閉じる
    document.getElementById('race-detail-modal').addEventListener('click', function(e) {
        if (e.target === this) {
            closeDetailModal();
        }
    });
    
    // フィルターボタン
    document.querySelectorAll('.filter-btn').forEach(btn => {
        btn.addEventListener('click', function() {
            if (this.classList.contains('active')) return;
            
            document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
            this.classList.add('active');
            
            currentFilter = this.getAttribute('data-filter');
            filterAndDisplayRaces();
        });
    });
    
    // 検索（デバウンス付き）
    let searchTimeout;
    document.getElementById('search-input').addEventListener('input', function() {
        clearTimeout(searchTimeout);
        searchTimeout = setTimeout(() => {
            searchQuery = this.value;
            filterAndDisplayRaces();
        }, 200);
    });
    
    // ページネーション
    document.getElementById('prev-page').addEventListener('click', () => {
        if (currentPage > 1) goToPage(currentPage - 1);
    });
    
    document.getElementById('next-page').addEventListener('click', () => {
        const totalPages = Math.ceil(filteredRaces.length / racesPerPage);
        if (currentPage < totalPages) goToPage(currentPage + 1);
    });
    
    // ドライバー登録
    document.getElementById('register-driver-btn').addEventListener('click', function() {
        const input = document.getElementById('driver-name-input');
        const driverName = input.value.trim();
        
        if (!validateDriverName(driverName)) {
            input.style.borderColor = '#ef4444';
            input.style.boxShadow = '0 0 0 3px rgba(239, 68, 68, 0.2)';
            setTimeout(() => {
                input.style.borderColor = '';
                input.style.boxShadow = '';
            }, 2000);
            return;
        }
        
        const btn = this;
        btn.disabled = true;
        btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> 登録中...';
        
        nuiPost('registerDriver', { driverName: driverName }).then(result => {
            if (result && result.success) {
                document.getElementById('current-driver-name').textContent = result.driverName;
                document.getElementById('driver-setup-modal').style.display = 'none';
                document.getElementById('main-screen').style.display = 'flex';
                loadRaces();
            } else {
                input.style.borderColor = '#ef4444';
                input.style.boxShadow = '0 0 0 3px rgba(239, 68, 68, 0.2)';
            }
        }).finally(() => {
            btn.disabled = false;
            btn.innerHTML = '<i class="fas fa-check"></i> 登録';
        });
    });
    
    // Enter キーでドライバー登録
    document.getElementById('driver-name-input').addEventListener('keydown', function(e) {
        if (e.key === 'Enter') {
            document.getElementById('register-driver-btn').click();
        }
    });
    
    // ドライバー名編集
    document.getElementById('edit-driver-btn').addEventListener('click', function() {
        const currentName = document.getElementById('current-driver-name').textContent;
        const newName = prompt('新しいドライバーネームを入力してください:', currentName);
        
        if (newName && validateDriverName(newName)) {
            nuiPost('updateDriverName', { driverName: newName }).then(result => {
                if (result && result.success) {
                    document.getElementById('current-driver-name').textContent = result.driverName;
                }
            });
        }
    });
    
    // スタート地点ウェイポイント設置
    document.getElementById('set-waypoint-btn').addEventListener('click', function() {
        if (!selectedRaceId) return;
        nuiPost('setStartWaypoint', { raceId: selectedRaceId });
        
        const btn = this;
        btn.innerHTML = '<i class="fas fa-check"></i> マップにピンを設置しました！';
        btn.style.borderColor = '#10b981';
        btn.style.color = '#34d399';
        setTimeout(() => {
            btn.innerHTML = '<i class="fas fa-map-marker-alt"></i> スタート地点をマップに表示';
            btn.style.borderColor = '';
            btn.style.color = '';
        }, 2000);
    });
    
    // レース開始
    document.getElementById('start-race-btn').addEventListener('click', function() {
        if (!selectedRaceId) return;
        
        nuiPost('startRace', { raceId: selectedRaceId });
        closeDetailModal();
        closeRacingUI();
    });
    
    // 新規レース作成
    document.getElementById('create-race-btn').addEventListener('click', function() {
        nuiPost('createRace');
        closeRacingUI();
    });
    
    // レース削除
    document.getElementById('delete-race-btn').addEventListener('click', function() {
        if (!selectedRaceId) return;
        
        const race = currentRaces.find(r => r.id === selectedRaceId);
        const raceName = race ? race.name : 'Unknown';
        
        if (confirm('レース「' + raceName + '」を削除しますか？\nこの操作は取り消せません。')) {
            const btn = this;
            btn.disabled = true;
            btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> 削除中...';
            
            nuiPost('deleteRace', { raceId: selectedRaceId }).then(result => {
                if (result && result.success) {
                    closeDetailModal();
                    loadRaces();
                }
            }).finally(() => {
                btn.disabled = false;
                btn.innerHTML = '<i class="fas fa-trash-alt"></i> レース削除';
            });
        }
    });
    
    // マルチセッション作成（NUIを閉じてox_lib inputDialogへ遷移）
    document.getElementById('create-session-btn').addEventListener('click', function() {
        if (!selectedRaceId) return;
        nuiPost('createSessionDialog', { raceId: selectedRaceId });
        closeDetailModal();
        closeRacingUI();
    });
    
    // セッション参加（NUIを閉じてox_libコンテキストメニューへ遷移）
    document.getElementById('join-session-btn').addEventListener('click', function() {
        if (!selectedRaceId) return;
        nuiPost('joinSessionList', { raceId: selectedRaceId });
        closeDetailModal();
        closeRacingUI();
    });
    
    // ESCキーで閉じる
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape') {
            const detailModal = document.getElementById('race-detail-modal');
            if (detailModal.style.display !== 'none' && detailModal.style.display !== '') {
                closeDetailModal();
            } else {
                closeRacingUI();
            }
        }
    });
    
    // レースキャンセルボタン（/race UI内）
    document.getElementById('cancel-race-btn').addEventListener('click', function() {
        closeRacingUI();
        nuiPost('retireRace');
    });
});
