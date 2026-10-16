// html/js/script.js
// CAM Racing System - NUI Script v4.2.0

let currentRaces = [];
let filteredRaces = [];
let currentPage = 1;
let racesPerPage = 12;
let selectedRaceId = null;
let currentFilter = 'all';
let searchQuery = '';
let isAdmin = false;
let isCurrentlyRacing = false;
let currentTab = 'home';
let taData = null;
let taFilter = 'all';
let adminRaces = [];

// タブレット (cam_tablet) のアプリとして開かれている場合はリソース名が入る
// 例: nui://qbx_racing/html/index.html?tablet=cam_tablet
const PAGE_PARAMS = new URLSearchParams(location.search);
const TABLET_RESOURCE = PAGE_PARAMS.get('tablet');
const IS_TABLET = !!TABLET_RESOURCE;

// ===================================
// NUIメッセージ受信
// ===================================
window.addEventListener('message', function(event) {
    // タブレットからのメッセージは SDK (CamTablet.on('message')) で受け取る
    if (IS_TABLET) return;
    handleMessage(event.data);
});

function handleMessage(data) {
    if (!data) return;
    
    switch(data.action) {
        case 'openUI':
            openRacingUI(data);
            break;
        case 'closeUI':
            closeRacingUI();
            break;
        case 'updateRaces':
            refreshCurrentTab();
            break;
        case 'showDriverSetup':
            showDriverSetup();
            break;
        case 'updateRaceHUD':
            updateRaceHUD(data);
            break;
    }
}

// ===================================
// FiveM NUI API ヘルパー
// ===================================
function getResourceName() {
    // タブレットのアプリとして開いた時はサーバーが URL に付けたリソース名を使う
    if (PAGE_PARAMS.get('resource')) {
        return PAGE_PARAMS.get('resource');
    }
    if (typeof GetParentResourceName === 'function') {
        return GetParentResourceName();
    }
    // iframe 内など GetParentResourceName が無い場合は URL (cfx-nui-<リソース名>) から取得
    const host = location.hostname || '';
    if (host.indexOf('cfx-nui-') === 0) {
        return host.slice(8);
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
let uiHideTimer = null;
let detailHideTimer = null;

function openRacingUI(data) {
    // 閉じるアニメーション中に開き直した場合、後から非表示にされないようにする
    clearTimeout(uiHideTimer);
    document.body.classList.add('menu-open');
    
    const ui = document.getElementById('racing-ui');
    ui.style.display = 'flex';
    ui.style.opacity = '0';
    requestAnimationFrame(() => {
        ui.style.transition = 'opacity 0.3s ease';
        ui.style.opacity = '1';
    });
    
    if (data.racesPerPage > 0) {
        racesPerPage = data.racesPerPage;
    }
    
    // プロフィールを取得できなかった（ログイン直後など）は「未登録」と区別して案内する
    if (data.error) {
        document.getElementById('main-screen').style.display = 'none';
        document.getElementById('driver-setup-modal').style.display = 'none';
        showToast('プロフィールを取得できませんでした。少し待ってから開き直してください');
        return;
    }
    
    if (data.hasProfile) {
        document.getElementById('current-driver-name').textContent = data.driverName;
        document.getElementById('main-screen').style.display = 'flex';
        document.getElementById('driver-setup-modal').style.display = 'none';
        
        isAdmin = data.isAdmin || false;
        isCurrentlyRacing = data.isRacing || false;
        
        // 管理タブは管理者だけ
        document.getElementById('admin-tab-btn').style.display = isAdmin ? '' : 'none';
        if (!isAdmin && currentTab === 'admin') currentTab = 'home';
        
        // レース中ならキャンセルボタンを表示
        const cancelControls = document.getElementById('race-cancel-controls');
        if (cancelControls) {
            cancelControls.style.display = isCurrentlyRacing ? 'flex' : 'none';
        }
        
        switchTab(currentTab);
    } else {
        showDriverSetup();
    }
}

function closeRacingUI() {
    // タブレットではアプリを閉じてホームに戻る
    if (IS_TABLET) {
        if (typeof CamTablet !== 'undefined') CamTablet.home();
        return;
    }
    
    closeAskModal(null);
    document.body.classList.remove('menu-open');
    const ui = document.getElementById('racing-ui');
    ui.style.transition = 'opacity 0.25s ease';
    ui.style.opacity = '0';
    clearTimeout(uiHideTimer);
    uiHideTimer = setTimeout(() => {
        ui.style.display = 'none';
    }, 250);
    nuiPost('closeUI');
}

// レース開始・ダイアログ表示などでゲーム画面に戻る時
// タブレットは Lua 側で閉じるので画面はそのまま。閉じるまでの間に
// 同じ操作が二重に送られないよう、しばらく受け付けない
let isLeaving = false;
let leavingTimer = null;

function leaveRacingUI() {
    if (IS_TABLET) {
        isLeaving = true;
        clearTimeout(leavingTimer);
        // タブレットが閉じなかった場合（エラー時など）に備えて自動で戻す
        leavingTimer = setTimeout(() => { isLeaving = false; }, 3000);
        return;
    }
    closeRacingUI();
}

// 入力・確認ダイアログ（タブレットでは SDK のダイアログ、全画面メニューでは自前のダイアログ）
// ※ ゲーム内の画面（NUI）では prompt / confirm が動かないため
let askResolve = null;
let askMode = 'confirm';

function openAskModal(mode, title, message, value, okLabel) {
    return new Promise(resolve => {
        closeAskModal(null); // 前のダイアログはキャンセル扱い
        askResolve = resolve;
        askMode = mode;
        
        document.getElementById('ask-title').textContent = title;
        const messageEl = document.getElementById('ask-message');
        messageEl.textContent = message || '';
        messageEl.style.display = message ? '' : 'none';
        
        const input = document.getElementById('ask-input');
        document.getElementById('ask-input-group').style.display = mode === 'text' ? '' : 'none';
        input.value = value || '';
        document.getElementById('ask-ok-btn').textContent = okLabel || 'OK';
        
        document.getElementById('ask-modal').style.display = 'flex';
        if (mode === 'text') setTimeout(() => input.focus(), 0);
    });
}

function closeAskModal(result) {
    const modal = document.getElementById('ask-modal');
    if (modal) modal.style.display = 'none';
    const resolve = askResolve;
    askResolve = null;
    if (resolve) resolve(result);
}

function isAskModalOpen() {
    const modal = document.getElementById('ask-modal');
    return !!modal && modal.style.display !== 'none';
}

function askText(title, value) {
    if (IS_TABLET && typeof CamTablet !== 'undefined') {
        return CamTablet.prompt({ title: title, value: value });
    }
    return openAskModal('text', title, '', value, 'OK');
}

function askConfirm(title, message, okLabel, danger) {
    okLabel = okLabel || '削除';
    if (IS_TABLET && typeof CamTablet !== 'undefined') {
        return CamTablet.confirm({ title: title, message: message, okLabel: okLabel, danger: danger !== false });
    }
    return openAskModal('confirm', title, message, '', okLabel).then(result => result === true);
}

// エラーなどのお知らせ（画面下に数秒表示）
let toastTimer = null;
function showToast(message, type) {
    const toast = document.getElementById('ui-toast');
    if (!toast || !message) return;
    toast.textContent = message;
    toast.className = 'ui-toast' + (type === 'success' ? ' success' : '');
    toast.style.display = 'block';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toast.style.display = 'none'; }, 4000);
}

function showDriverSetup() {
    document.getElementById('main-screen').style.display = 'none';
    document.getElementById('driver-setup-modal').style.display = 'flex';
}

// ===================================
// レース一覧読み込み
// ===================================
function loadRaces() {
    return nuiPost('getRaces').then(races => {
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
    document.getElementById('detail-target').textContent = race.target_time_ms ? formatTime(race.target_time_ms) : '計測中';
    document.getElementById('detail-reward').textContent = race.ta_reward
        ? `${formatMoney(race.ta_reward)}（レート${race.ta_rate || '-'}）` : '-';
    
    // 管理者のみ削除ボタン表示
    const deleteBtn = document.getElementById('delete-race-btn');
    deleteBtn.style.display = isAdmin ? 'block' : 'none';
    
    // 前に開いたレースのランキングが残らないように消してから読み込む
    document.getElementById('leaderboard-list').innerHTML = '';
    loadLeaderboard(raceId);
    
    clearTimeout(detailHideTimer);
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
    clearTimeout(detailHideTimer);
    detailHideTimer = setTimeout(() => {
        modal.style.display = 'none';
    }, 200);
    selectedRaceId = null;
}

// ===================================
// ランキング
// ===================================
function loadLeaderboard(raceId) {
    nuiPost('getLeaderboard', { raceId: raceId }).then(leaderboard => {
        // 返事が来る前に別のレースを開いていたら表示しない
        if (selectedRaceId !== raceId) return;
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
    document.getElementById('hud-time').textContent = (data.time || '0.00') + '秒';
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
    return `${seconds.toFixed(2)}秒`;
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
    document.querySelectorAll('.filter-btn[data-filter]').forEach(btn => {
        btn.addEventListener('click', function() {
            if (this.classList.contains('active')) return;
            
            document.querySelectorAll('.filter-btn[data-filter]').forEach(b => b.classList.remove('active'));
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
                switchTab('home');
            } else {
                input.style.borderColor = '#ef4444';
                input.style.boxShadow = '0 0 0 3px rgba(239, 68, 68, 0.2)';
                showToast((result && result.message) || '登録に失敗しました');
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
    document.getElementById('edit-driver-btn').addEventListener('click', async function() {
        const currentName = document.getElementById('current-driver-name').textContent;
        const newName = await askText('新しいドライバーネームを入力してください', currentName);
        
        if (!newName || newName === currentName) return;
        if (!validateDriverName(newName)) {
            showToast('ドライバーネームは3〜20文字の英数字とアンダースコアで入力してください');
            return;
        }
        nuiPost('updateDriverName', { driverName: newName }).then(result => {
            if (result && result.success) {
                document.getElementById('current-driver-name').textContent = result.driverName;
            } else {
                showToast((result && result.message) || 'ドライバーネームを変更できませんでした');
            }
        });
    });
    
    // スタート地点ウェイポイント設置
    document.getElementById('set-waypoint-btn').addEventListener('click', function() {
        if (!selectedRaceId) return;
        nuiPost('setStartWaypoint', { raceId: selectedRaceId });
        showToast('スタート地点をマップに表示しました', 'success');
        
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
        startSoloRace(selectedRaceId, 'normal');
    });
    
    // 新規レース作成
    document.getElementById('create-race-btn').addEventListener('click', function() {
        if (isLeaving) return;
        nuiPost('createRace');
        leaveRacingUI();
    });
    
    // レース削除
    document.getElementById('delete-race-btn').addEventListener('click', async function() {
        if (!selectedRaceId) return;
        
        const race = currentRaces.find(r => r.id === selectedRaceId);
        const raceName = race ? race.name : '不明';
        
        if (await askConfirm('レース「' + raceName + '」を削除しますか？', 'この操作は取り消せません。')) {
            const btn = this;
            btn.disabled = true;
            btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> 削除中...';
            
            nuiPost('deleteRace', { raceId: selectedRaceId }).then(result => {
                if (result && result.success) {
                    closeDetailModal();
                    refreshCurrentTab();
                } else {
                    showToast((result && result.message) || 'レースを削除できませんでした');
                }
            }).finally(() => {
                btn.disabled = false;
                btn.innerHTML = '<i class="fas fa-trash-alt"></i> レース削除';
            });
        }
    });
    
    // マルチセッション作成（NUIを閉じてox_lib inputDialogへ遷移）
    document.getElementById('create-session-btn').addEventListener('click', function() {
        if (!selectedRaceId || isLeaving) return;
        nuiPost('createSessionDialog', { raceId: selectedRaceId });
        closeDetailModal();
        leaveRacingUI();
    });
    
    // セッション参加（NUIを閉じてox_libコンテキストメニューへ遷移）
    document.getElementById('join-session-btn').addEventListener('click', function() {
        if (!selectedRaceId || isLeaving) return;
        nuiPost('joinSessionList', { raceId: selectedRaceId });
        closeDetailModal();
        leaveRacingUI();
    });
    
    // ESCキーで閉じる（タブレットでは SDK がタブレットごと閉じる）
    document.addEventListener('keydown', function(e) {
        if (IS_TABLET) return;
        if (e.key === 'Escape') {
            if (isAskModalOpen()) {
                closeAskModal(askMode === 'text' ? null : false);
                return;
            }
            const detailModal = document.getElementById('race-detail-modal');
            if (detailModal.style.display !== 'none' && detailModal.style.display !== '') {
                closeDetailModal();
            } else {
                closeRacingUI();
            }
        }
    });
    
    // 入力・確認ダイアログのボタン
    document.getElementById('ask-ok-btn').addEventListener('click', function() {
        closeAskModal(askMode === 'text' ? document.getElementById('ask-input').value.trim() : true);
    });
    document.getElementById('ask-cancel-btn').addEventListener('click', function() {
        closeAskModal(askMode === 'text' ? null : false);
    });
    document.getElementById('ask-input').addEventListener('keydown', function(e) {
        if (e.key === 'Enter') document.getElementById('ask-ok-btn').click();
    });
    
    // レースキャンセルボタン（/race UI内）
    document.getElementById('cancel-race-btn').addEventListener('click', function() {
        if (isLeaving) return;
        leaveRacingUI();
        nuiPost('retireRace');
    });
    
    // タブ
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.addEventListener('click', function() {
            switchTab(this.getAttribute('data-tab'));
        });
    });
    
    // タイムアタックの絞り込み
    document.querySelectorAll('[data-ta-filter]').forEach(btn => {
        btn.addEventListener('click', function() {
            document.querySelectorAll('[data-ta-filter]').forEach(b => b.classList.remove('active'));
            this.classList.add('active');
            taFilter = this.getAttribute('data-ta-filter');
            renderTimeAttack();
        });
    });
    
    // カード内のボタン（出走・スタート地点・管理操作）はまとめて受け取る
    document.getElementById('main-screen').addEventListener('click', onActionClick);
    
    // デイリーの選び直し
    document.getElementById('reroll-daily-btn').addEventListener('click', async function() {
        if (!await askConfirm('今日のデイリーレースを選び直しますか？', '全員の今日のデイリーが変わります（受け取り済みの報酬はそのまま）。', '選び直す', false)) return;
        const btn = this;
        btn.disabled = true;
        nuiPost('adminRerollDaily').then(result => {
            showToast((result && result.message) || (result && result.success ? '選び直しました' : '選び直せませんでした'),
                result && result.success ? 'success' : undefined);
            refreshCurrentTab();
        }).finally(() => { btn.disabled = false; });
    });
    
    if (IS_TABLET) {
        initTablet();
    }
});

// ===================================
// タブレット (cam_tablet) のアプリとして動かす
// ===================================

// プロフィール・レース中かどうかなどを取得して画面を表示し直す
function loadTabletState() {
    nuiPost('getUIState').then(function(state) {
        openRacingUI(state || {});
    });
}

function initTablet() {
    document.body.classList.add('in-tablet');
    
    // タブレットの SDK を読み込んでから画面を開く
    const sdk = document.createElement('script');
    sdk.src = `nui://${TABLET_RESOURCE}/html/sdk/cam-tablet.js`;
    sdk.onload = function() {
        CamTablet.on('message', handleMessage);
        
        // タブレットは閉じてもこのアプリを残し、開き直すとそのまま再開する。
        // 表示された時は Lua に知らせて（タブレットを閉じる処理などに使う）、状態を読み直す
        CamTablet.on('visibility', function(visible) {
            nuiPost('tabletAppVisible', { visible: visible });
            if (visible) {
                isLeaving = false;
                loadTabletState();
            }
        });
        
        CamTablet.ready(function() {
            nuiPost('tabletAppVisible', { visible: true });
            loadTabletState();
        });
    };
    sdk.onerror = function() {
        console.error(`[CAM Racing] タブレットの SDK を読み込めません: ${sdk.src}`);
        // SDK なしでも一覧は見られるようにする（タブレットのダイアログ等は使えない）
        loadTabletState();
        showToast('タブレットとの連携に失敗しました。タブレットを開き直してください');
    };
    document.head.appendChild(sdk);
}

// ===================================
// タブ
// ===================================
function switchTab(tab) {
    if (tab === 'admin' && !isAdmin) tab = 'home';
    currentTab = tab;
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.classList.toggle('active', btn.getAttribute('data-tab') === tab);
    });
    document.querySelectorAll('.tab-panel').forEach(panel => {
        panel.classList.toggle('active', panel.id === 'tab-' + tab);
    });
    refreshCurrentTab();
}

function refreshCurrentTab() {
    switch (currentTab) {
        case 'home': loadHome(); break;
        case 'races': loadRaces(); break;
        case 'ta': loadTimeAttack(); break;
        case 'ranking': loadRanking(); break;
        case 'admin': loadAdmin(); break;
    }
}

// ===================================
// 共通の表示部品
// ===================================
function formatMoney(amount) {
    return '$' + Number(amount || 0).toLocaleString('en-US');
}

// 100万 → 「100万」
function formatMan(amount) {
    const n = Number(amount || 0);
    if (n >= 10000) {
        return (Math.round(n / 1000) / 10).toLocaleString('ja-JP') + '万';
    }
    return n.toLocaleString('ja-JP');
}

function formatDistance(meters) {
    const m = Number(meters);
    if (!m || m <= 0) return '-';
    return m >= 1000 ? (m / 1000).toFixed(1) + 'km' : Math.round(m) + 'm';
}

function formatDate(value) {
    if (!value) return '';
    const date = new Date(typeof value === 'number' ? value : String(value).replace(' ', 'T'));
    if (isNaN(date.getTime())) return '';
    const pad = n => String(n).padStart(2, '0');
    return `${pad(date.getMonth() + 1)}/${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function formatPoints(delta) {
    const n = Number(delta || 0);
    return (n > 0 ? '+' : '') + n + 'pt';
}

function reasonLabel(reason) {
    const labels = {
        'solo-finish': 'ソロ完走',
        'solo-target': '目標タイム突破',
        'solo-retire': 'リタイア',
        'multi': 'マルチプレイ'
    };
    return labels[reason] || reason || '';
}

function badgesHtml(vehicleType, raceType) {
    const v = getVehicleConfig(vehicleType);
    const r = getRaceTypeConfig(raceType);
    return `
        <div class="badge-group">
            <div class="vehicle-badge ${escapeHtml(vehicleType || 'car')}"><i class="${v.icon}"></i> ${v.label}</div>
            <div class="race-type-badge ${escapeHtml(raceType || 'circuit')}"><i class="${r.icon}"></i> ${r.label}</div>
        </div>`;
}

function emptyHtml(icon, text, hint) {
    return `
        <div class="no-races">
            <i class="fas ${icon}"></i>
            <p>${escapeHtml(text)}</p>
            ${hint ? `<p class="hint">${escapeHtml(hint)}</p>` : ''}
        </div>`;
}

function rankBadgeClass(rank) {
    return rank === 1 ? 'gold' : rank === 2 ? 'silver' : rank === 3 ? 'bronze' : 'normal';
}

function updateHeaderPoints(profile) {
    const el = document.getElementById('header-points');
    if (!profile) {
        el.style.display = 'none';
        return;
    }
    el.innerHTML = `<i class="fas fa-trophy"></i> ${Number(profile.points || 0).toLocaleString('ja-JP')}pt・${profile.rank}位`;
    el.style.display = '';
}

// ===================================
// ホーム
// ===================================
function loadHome() {
    nuiPost('getHomeData').then(data => {
        if (!data || data.error) {
            document.getElementById('daily-list').innerHTML = emptyHtml('fa-triangle-exclamation', 'データを取得できませんでした');
            return;
        }
        renderHome(data);
    });
}

function profileCardHtml(profile, extra) {
    return `
        <div class="profile-main">
            <div class="profile-avatar"><i class="fas fa-helmet-safety"></i></div>
            <div class="profile-text">
                <div class="profile-name">${escapeHtml(profile.driverName)}</div>
                <div class="profile-rank">${profile.rank ? `ランキング <b>${profile.rank}位</b>` : ''}${extra || ''}</div>
            </div>
            <div class="profile-points">
                <span class="value">${Number(profile.points || 0).toLocaleString('ja-JP')}</span>
                <span class="label">pt</span>
            </div>
        </div>`;
}

function renderHome(data) {
    const features = data.features || {};
    const profile = data.profile;
    updateHeaderPoints(profile);
    
    // プロフィール
    const profileEl = document.getElementById('home-profile');
    if (profile) {
        profileEl.innerHTML = profileCardHtml(profile) + `
            <div class="profile-stats">
                <div class="profile-stat"><span class="value">${profile.totalRaces}</span><span class="label">完走</span></div>
                <div class="profile-stat"><span class="value">${profile.totalWins}</span><span class="label">マルチ優勝</span></div>
                <div class="profile-stat"><span class="value">${profile.taCleared}</span><span class="label">TA達成</span></div>
                <div class="profile-stat"><span class="value">${formatMan(profile.taEarned)}</span><span class="label">TA獲得額</span></div>
            </div>`;
    } else {
        profileEl.innerHTML = '';
    }
    
    // 今日のデイリー
    const daily = data.daily || {};
    document.getElementById('daily-day').textContent = daily.day ? daily.day.replace(/-/g, '/') : '';
    const list = document.getElementById('daily-list');
    const races = daily.races || [];
    if (features.daily === false) {
        list.innerHTML = emptyHtml('fa-calendar-xmark', 'デイリーレースは無効になっています');
    } else if (races.length === 0) {
        list.innerHTML = emptyHtml('fa-calendar-day', '今日のデイリーレースはまだありません',
            '目標タイムが決まっているレースから選ばれます（タイムアタックのタブを参照）');
    } else {
        list.innerHTML = races.map(dailyCardHtml).join('');
    }
    
    // ランキング上位
    const top = data.top || [];
    document.getElementById('home-top').innerHTML = features.ranking === false
        ? '<p class="muted">ランキングは無効になっています</p>'
        : top.length === 0 ? '<p class="muted">まだ誰もいません</p>'
        : top.map(row => `
            <div class="mini-row">
                <div class="rank-badge ${rankBadgeClass(row.rank)}">${row.rank}</div>
                <div class="mini-name">${escapeHtml(row.driver_name)}</div>
                <div class="mini-value">${Number(row.points || 0).toLocaleString('ja-JP')}pt</div>
            </div>`).join('');
    
    // 最近のポイント変動
    const recent = data.recent || [];
    document.getElementById('home-recent').innerHTML = recent.length === 0
        ? '<p class="muted">まだありません。レースを走るとポイントが変動します</p>'
        : recent.map(row => `
            <div class="mini-row">
                <div class="mini-name">
                    ${escapeHtml(reasonLabel(row.reason))}
                    <span class="mini-sub">${escapeHtml(row.race_name || '')}・${formatDate(row.created_at)}</span>
                </div>
                <div class="mini-value ${row.delta >= 0 ? 'plus' : 'minus'}">${formatPoints(row.delta)}</div>
            </div>`).join('');
}

function dailyCardHtml(d) {
    const step = (claimed, icon, label, amount) => `
        <div class="reward-step ${claimed ? 'claimed' : ''}">
            <i class="fas ${claimed ? 'fa-circle-check' : icon}"></i>
            <span>${label}</span>
            <b>${formatMoney(amount)}</b>
        </div>`;
    return `
        <div class="daily-card ${d.completed ? 'done' : ''}">
            <div class="race-header">
                <div class="race-name">${escapeHtml(d.name)}</div>
                ${badgesHtml(d.vehicleType, d.raceType)}
            </div>
            <div class="daily-info">
                <span><i class="fas fa-bullseye"></i> 目標 <b>${formatTime(d.targetTimeMs)}</b></span>
                <span><i class="fas fa-route"></i> ${formatDistance(d.lengthM)}</span>
                ${d.raceType === 'circuit' ? `<span><i class="fas fa-redo"></i> ${d.laps || 1}周</span>` : ''}
                <span><i class="fas fa-sack-dollar"></i> 合計 <b>${formatMoney(d.reward)}</b></span>
            </div>
            <div class="reward-steps">
                ${step(d.finishClaimed, 'fa-flag-checkered', '完走', d.finishReward)}
                ${step(d.targetClaimed, 'fa-bullseye', '目標タイム', d.targetReward)}
            </div>
            <div class="card-actions">
                <button class="btn-small" data-action="waypoint" data-race-id="${d.raceId}">
                    <i class="fas fa-map-marker-alt"></i> スタート地点
                </button>
                <button class="btn-small primary" data-action="daily" data-race-id="${d.raceId}" ${d.completed ? 'disabled' : ''}>
                    ${d.completed ? '<i class="fas fa-check"></i> 今日の分は受け取り済み' : '<i class="fas fa-play"></i> デイリー出走'}
                </button>
            </div>
        </div>`;
}

// ===================================
// タイムアタック
// ===================================
function loadTimeAttack() {
    nuiPost('getTimeAttack').then(data => {
        taData = data && !data.error ? data : null;
        renderTimeAttack();
    });
}

function taStatus(race) {
    if (!race.target_time_ms) return 'pending';
    return race.claimed_time ? 'cleared' : 'open';
}

function renderTimeAttack() {
    const list = document.getElementById('ta-list');
    if (!taData) {
        list.innerHTML = emptyHtml('fa-triangle-exclamation', 'データを取得できませんでした');
        return;
    }
    if (!taData.enabled) {
        list.innerHTML = emptyHtml('fa-stopwatch', 'タイムアタックは無効になっています');
        return;
    }
    const runs = taData.calibrationRuns || 10;
    document.getElementById('ta-desc').textContent =
        `レース作成後、${runs}回のゴール（${taData.calibrationDrivers || 1}人以上）がそろうと、各ドライバーのベストの平均が目標タイムになります。` +
        '目標タイム以内でゴールすると、1レースにつき1回だけ報酬がもらえます。';
    
    const races = (taData.races || []).filter(race => taFilter === 'all' || taStatus(race) === taFilter);
    if (races.length === 0) {
        list.innerHTML = emptyHtml('fa-stopwatch', '該当するレースがありません');
        return;
    }
    list.innerHTML = races.map(race => taCardHtml(race, runs)).join('');
}

function taCardHtml(race, runs) {
    const status = taStatus(race);
    const chips = {
        pending: '<span class="status-chip pending"><i class="fas fa-hourglass-half"></i> 計測中</span>',
        open: '<span class="status-chip open"><i class="fas fa-bullseye"></i> 未達成</span>',
        cleared: '<span class="status-chip cleared"><i class="fas fa-circle-check"></i> 達成済み</span>'
    };
    let body;
    if (status === 'pending') {
        const count = Math.min(Number(race.calib_count || 0), runs);
        const needDrivers = taData.calibrationDrivers || 1;
        const drivers = Math.min(Number(race.calib_drivers || 0), needDrivers);
        const progress = (count / runs + drivers / needDrivers) / 2;
        body = `
            <div class="ta-pending">
                <div class="ta-pending-text">目標タイム計測中 ゴール <b>${count} / ${runs}</b>・ドライバー <b>${drivers} / ${needDrivers}人</b></div>
                <div class="progress"><div class="progress-bar" style="width: ${Math.round(progress * 100)}%"></div></div>
                <div class="muted">${runs}回のゴールと${needDrivers}人以上のドライバーがそろうと、各ドライバーのベストの平均で目標タイムと報酬が決まります</div>
            </div>`;
    } else {
        const myBest = Number(race.my_best || 0);
        const diff = myBest ? myBest - race.target_time_ms : null;
        body = `
            <div class="ta-target">
                <div>
                    <div class="ta-label">目標タイム</div>
                    <div class="ta-time">${formatTime(race.target_time_ms)}</div>
                </div>
                <div class="ta-reward">
                    <div class="ta-label">報酬（レート${race.ta_rate || '-'}）</div>
                    <div class="ta-money">${formatMoney(race.ta_reward)}</div>
                </div>
            </div>
            <div class="stat-row">
                <span><i class="fas fa-user-clock"></i> 自己ベスト</span>
                <span class="stat-value">${myBest ? formatTime(myBest) : '記録なし'}
                    ${diff !== null ? `<span class="${diff <= 0 ? 'plus' : 'minus'}">（${diff <= 0 ? '' : '+'}${(diff / 1000).toFixed(2)}秒）</span>` : ''}
                </span>
            </div>
            <div class="stat-row">
                <span><i class="fas fa-route"></i> コース</span>
                <span class="stat-value">${formatDistance(race.course_length_m)}${race.race_type === 'circuit' ? `・${race.laps || 1}周` : ''}</span>
            </div>`;
    }
    return `
        <div class="race-card ta-card ${status}">
            <div class="race-header">
                <div class="race-name">${escapeHtml(race.name)}</div>
                <div class="badge-row">${chips[status]}</div>
                ${badgesHtml(race.vehicle_type, race.race_type)}
            </div>
            ${body}
            <div class="card-actions">
                <button class="btn-small" data-action="waypoint" data-race-id="${race.id}">
                    <i class="fas fa-map-marker-alt"></i> スタート地点
                </button>
                <button class="btn-small primary" data-action="start" data-race-id="${race.id}">
                    <i class="fas fa-play"></i> ${status === 'pending' ? '走って計測' : '挑戦する'}
                </button>
            </div>
        </div>`;
}

// ===================================
// ランキング
// ===================================
function loadRanking() {
    nuiPost('getRanking').then(data => renderRanking(data && !data.error ? data : null));
}

function renderRanking(data) {
    const listEl = document.getElementById('ranking-list');
    const meEl = document.getElementById('ranking-me');
    if (!data) {
        listEl.innerHTML = emptyHtml('fa-triangle-exclamation', 'データを取得できませんでした');
        return;
    }
    if (!data.enabled) {
        meEl.innerHTML = '';
        listEl.innerHTML = emptyHtml('fa-trophy', 'ランキングは無効になっています');
        return;
    }
    
    meEl.innerHTML = data.me
        ? profileCardHtml(data.me, ` <span class="muted">/ ${data.totalDrivers}人</span>`)
        : '';
    updateHeaderPoints(data.me);
    
    const rules = data.rules || {};
    document.getElementById('ranking-rules').innerHTML = `
        <li><span>ソロで完走</span><b class="plus">${formatPoints(rules.soloFinish)}</b></li>
        <li><span>ソロで目標タイム以内</span><b class="plus">${formatPoints(rules.soloTarget)}</b></li>
        <li><span>ソロでリタイア</span><b class="minus">${formatPoints(rules.soloRetire)}</b></li>
        <li><span>マルチ: 自分より下の順位1人ごとに</span><b class="plus">${formatPoints(rules.perOpponent)}</b></li>
        <li><span>マルチ: 自分より上の順位1人ごとに</span><b class="minus">${formatPoints(-(rules.perOpponent || 0))}</b></li>
        <li class="muted">ソロの加点は同じレースで1日1回まで。マルチのリタイアはゴールした人より下の順位になります。</li>`;
    
    const top = data.top || [];
    if (top.length === 0) {
        listEl.innerHTML = emptyHtml('fa-trophy', 'まだ誰もいません');
        return;
    }
    const myName = data.me && data.me.driverName;
    listEl.innerHTML = `
        <div class="table-row table-head">
            <span>順位</span><span>ドライバー</span><span>ポイント</span><span>完走</span><span>優勝</span>
        </div>` + top.map(row => `
        <div class="table-row ${row.driver_name === myName ? 'me' : ''}">
            <span><div class="rank-badge ${rankBadgeClass(row.rank)}">${row.rank}</div></span>
            <span class="table-name">${escapeHtml(row.driver_name)}</span>
            <span class="table-points">${Number(row.points || 0).toLocaleString('ja-JP')}pt</span>
            <span>${row.total_races || 0}</span>
            <span>${row.total_wins || 0}</span>
        </div>`).join('');
}

// ===================================
// 管理
// ===================================
function loadAdmin() {
    nuiPost('getTimeAttack').then(data => renderAdmin(data && !data.error ? data : null));
}

function renderAdmin(data) {
    const listEl = document.getElementById('admin-list');
    if (!data) {
        listEl.innerHTML = emptyHtml('fa-triangle-exclamation', 'データを取得できませんでした');
        return;
    }
    const races = data.races || [];
    adminRaces = races;
    if (races.length === 0) {
        listEl.innerHTML = emptyHtml('fa-flag-checkered', 'レースがありません', '「新規レース作成」から作成できます');
        return;
    }
    const runs = data.calibrationRuns || 10;
    listEl.innerHTML = `
        <div class="table-row table-head admin-row">
            <span>レース</span><span>目標タイム</span><span>TA報酬</span><span>操作</span>
        </div>` + races.map(race => `
        <div class="table-row admin-row">
            <span class="table-name">
                ${escapeHtml(race.name)}
                ${badgesHtml(race.vehicle_type, race.race_type)}
            </span>
            <span>${race.target_time_ms ? formatTime(race.target_time_ms)
                : `<span class="muted">計測中 ${Math.min(Number(race.calib_count || 0), runs)}/${runs}回・${Number(race.calib_drivers || 0)}人</span>`}</span>
            <span>${race.ta_reward ? `${formatMoney(race.ta_reward)}<span class="muted">（レート${race.ta_rate}）</span>` : '-'}</span>
            <span class="table-actions">
                <button class="btn-small" data-action="detail" data-race-id="${race.id}" title="詳細"><i class="fas fa-eye"></i> 詳細</button>
                <button class="btn-small" data-action="reset-target" data-race-id="${race.id}" title="目標タイムを計測し直す"
                    ${race.target_time_ms ? '' : 'disabled'}><i class="fas fa-rotate-left"></i> 目標リセット</button>
                <button class="btn-small danger" data-action="delete" data-race-id="${race.id}" title="削除">
                    <i class="fas fa-trash-alt"></i> 削除</button>
            </span>
        </div>`).join('');
}

// ===================================
// カード内のボタン
// ===================================
let startPending = false;
function startSoloRace(raceId, mode) {
    if (!raceId || isLeaving || startPending) return;
    startPending = true;
    nuiPost('startRace', { raceId: raceId, mode: mode }).then(result => {
        if (result && result.success) {
            closeDetailModal();
            leaveRacingUI();
        } else {
            showToast((result && result.message) || 'レースを開始できませんでした');
        }
    }).finally(() => { startPending = false; });
}

function openRaceDetail(raceId) {
    if (currentRaces.some(r => r.id === raceId)) {
        showRaceDetail(raceId);
        return;
    }
    loadRaces().then(() => showRaceDetail(raceId));
}

async function onActionClick(e) {
    const btn = e.target.closest('[data-action]');
    if (!btn || btn.disabled) return;
    e.stopPropagation();
    const raceId = Number(btn.getAttribute('data-race-id'));
    
    switch (btn.getAttribute('data-action')) {
        case 'daily':
            startSoloRace(raceId, 'daily');
            break;
        case 'start':
            startSoloRace(raceId, 'normal');
            break;
        case 'waypoint':
            nuiPost('setStartWaypoint', { raceId: raceId });
            showToast('スタート地点をマップに表示しました', 'success');
            break;
        case 'detail':
            openRaceDetail(raceId);
            break;
        case 'reset-target':
            if (!await askConfirm('目標タイムをリセットしますか？',
                'これ以降のゴールで目標タイムと報酬を計測し直します（受け取り済みの報酬はそのまま）。', 'リセット')) return;
            nuiPost('adminResetTarget', { raceId: raceId }).then(result => {
                if (result && result.success) {
                    showToast('目標タイムをリセットしました', 'success');
                    refreshCurrentTab();
                } else {
                    showToast((result && result.message) || 'リセットできませんでした');
                }
            });
            break;
        case 'delete': {
            const race = adminRaces.find(r => r.id === raceId);
            const name = race ? race.name : '';
            if (!await askConfirm('レース「' + name + '」を削除しますか？', 'この操作は取り消せません。')) return;
            nuiPost('deleteRace', { raceId: raceId }).then(result => {
                if (result && result.success) {
                    refreshCurrentTab();
                } else {
                    showToast((result && result.message) || 'レースを削除できませんでした');
                }
            });
            break;
        }
    }
}
