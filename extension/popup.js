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

  // FR-56（BR-56.4）：版本号运行时读**清单实际版本**，不硬编码。
  $('extVersion').textContent = 'v' + chrome.runtime.getManifest().version;

  // 恢复上次选择（默认 article）
  currentMode = await suiGetLastMode();
  renderMode();

  $('modeRow').addEventListener('click', onModeClick);
  $('clipBtn').addEventListener('click', handleClip);
  $('selectBtn').addEventListener('click', startSelectionClip);
  $('optionsBtn').addEventListener('click', openOptions);
  $('settingsLink').addEventListener('click', (e) => {
    e.preventDefault();
    openOptions();
  });

  // M12 修订 / FR-57：凭据判据由「地址 + 手填 Token」改为「地址 + 已登录会话」（AC-210）。
  const session = await suiGetSession();
  if (!session.serverUrl) {
    showStatus('请先在设置中填写服务端地址', 'error');
    $('clipBtn').disabled = true;
  } else if (!session.refreshToken) {
    showStatus('请先在设置中登录', 'error');
    $('clipBtn').disabled = true;
    $('selectBtn').disabled = true;
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

    // v0.14.0 / 整页截图：**只在快照模式**采集（article 模式一次都不截——
    // 用户要的是「只要正文」，多传一张整页图既费流量又不符合预期）。
    let screenshot = null;
    if (currentMode === 'snapshot') {
      showStatus('正在采集整页截图...', 'loading');
      // 失败静默降级为 null：截图丢了也要把内容存下来（suiCaptureScreenshot 内部已兜底）。
      screenshot = await suiCaptureScreenshot(currentTab.id);
    }

    showStatus('正在剪藏...', 'loading');
    const mode = await suiSetLastMode(currentMode);
    // 会话由 shared.js 的 suiApiFetch 自动携带，并在 401 时单飞刷新后重放一次（AC-212）。
    const data = await suiPostClip(pageData, mode, screenshot);

    // 结果反馈：附「未本地化」计数附注（§5）；带截图时额外一句，没截到则文案不变。
    if (data && screenshot) data.screenshotCaptured = true;
    showStatus('✓ ' + suiBuildResultMessage(data), 'success');

    // 1.5 秒后关闭弹窗
    setTimeout(() => window.close(), 1500);
  } catch (err) {
    showStatus(`剪藏失败：${err.message}`, 'error');
    btn.disabled = false;
  }
}

/// 选择正文区域：弹窗立即关闭，由 background 注入页面选择器。
/// 用户点选后，页面选择器把结果消息发回 background，由 background 完成剪藏。
async function startSelectionClip() {
  if (!currentTab) return;
  const btn = $('selectBtn');
  btn.disabled = true;
  showStatus('请在网页上点选正文区域…', 'loading');
  try {
    await chrome.runtime.sendMessage({
      type: 'sui-start-selection-clip',
      tabId: currentTab.id,
    });
    // 给页面选择器一点时间挂载，再关闭弹窗（弹窗关闭不会中断 background）。
    setTimeout(() => window.close(), 300);
  } catch (err) {
    showStatus(`无法启动选择器：${err.message}`, 'error');
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
