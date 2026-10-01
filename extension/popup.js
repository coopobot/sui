// popup.js — 剪藏插件弹窗逻辑
const $ = (id) => document.getElementById(id);

const MODE_HINTS = {
  article: '智能提取正文：只保留主要正文。',
  snapshot: '全页快照：保留整页结构与顺序，原页下线也可读。',
};

let currentTab = null;
let currentMode = SUI_DEFAULT_MODE;

// 初始化：获取当前标签页信息、恢复上次模式、绑定事件
document.addEventListener('DOMContentLoaded', async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  currentTab = tab;
  $('pageTitle').textContent = tab.title || '(无标题)';
  $('pageUrl').textContent = tab.url || '';

  // 恢复上次选择（默认 article）
  currentMode = await suiGetLastMode();
  renderMode();

  $('modeRow').addEventListener('click', onModeClick);
  $('clipBtn').addEventListener('click', handleClip);
  $('optionsBtn').addEventListener('click', openOptions);
  $('settingsLink').addEventListener('click', (e) => {
    e.preventDefault();
    openOptions();
  });

  // 检查是否已配置服务端
  const settings = await suiGetSettings();
  if (!settings.serverUrl || !settings.token) {
    showStatus('请先配置服务端地址和 Token', 'error');
    $('clipBtn').disabled = true;
  }
});

// 切换模式（分段控件）并记住选择
async function onModeClick(e) {
  const btn = e.target.closest('.mode-btn');
  if (!btn) return;
  currentMode = await suiSetLastMode(btn.dataset.mode);
  renderMode();
}

function renderMode() {
  $('modeArticle').classList.toggle('active', currentMode === 'article');
  $('modeSnapshot').classList.toggle('active', currentMode === 'snapshot');
  $('modeHint').textContent = MODE_HINTS[currentMode] || MODE_HINTS.article;
}

async function handleClip() {
  if (!currentTab) return;
  const btn = $('clipBtn');
  btn.disabled = true;
  showStatus('正在采集页面...', 'loading');

  try {
    // 采集完整 DOM（先触发懒加载图片，再取 outerHTML）
    const pageData = await suiCaptureTab(currentTab.id);
    if (!pageData || !pageData.html) {
      throw new Error('采集页面内容失败');
    }

    showStatus('正在剪藏...', 'loading');
    const settings = await suiGetSettings();
    const mode = await suiSetLastMode(currentMode);
    const data = await suiPostClip(settings, pageData, mode);

    // 结果反馈：附「未本地化」计数附注（§5）
    showStatus('✓ ' + suiBuildResultMessage(data), 'success');

    // 1.5 秒后关闭弹窗
    setTimeout(() => window.close(), 1500);
  } catch (err) {
    showStatus(`剪藏失败：${err.message}`, 'error');
    btn.disabled = false;
  }
}

function showStatus(msg, type) {
  const el = $('status');
  el.textContent = msg;
  el.className = 'status ' + type;
}

function openOptions() {
  chrome.runtime.openOptionsPage();
}
