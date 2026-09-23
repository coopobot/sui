// popup.js — 剪藏插件弹窗逻辑
const $ = (id) => document.getElementById(id);

let currentTab = null;

// 初始化：获取当前标签页信息
document.addEventListener('DOMContentLoaded', async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  currentTab = tab;
  $('pageTitle').textContent = tab.title || '(无标题)';
  $('pageUrl').textContent = tab.url || '';

  $('clipBtn').addEventListener('click', handleClip);
  $('optionsBtn').addEventListener('click', openOptions);
  $('settingsLink').addEventListener('click', (e) => {
    e.preventDefault();
    openOptions();
  });

  // 检查是否已配置服务端
  const settings = await getSettings();
  if (!settings.serverUrl || !settings.token) {
    showStatus('请先配置服务端地址和 Token', 'error');
    $('clipBtn').disabled = true;
  }
});

async function handleClip() {
  if (!currentTab) return;
  const btn = $('clipBtn');
  btn.disabled = true;
  showStatus('正在剪藏...', 'loading');

  try {
    // 注入脚本获取页面完整 HTML
    const [result] = await chrome.scripting.executeScript({
      target: { tabId: currentTab.id },
      func: () => {
        return {
          title: document.title,
          url: location.href,
          html: document.documentElement.outerHTML,
        };
      },
    });

    const pageData = result.result;
    const settings = await getSettings();

    // 调用服务端剪藏 API
    const response = await fetch(`${settings.serverUrl.replace(/\/$/, '')}/api/v1/clips`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${settings.token}`,
      },
      body: JSON.stringify({
        url: pageData.url,
        title: pageData.title,
        html: pageData.html,
      }),
    });

    if (!response.ok) {
      const err = await response.json().catch(() => ({}));
      throw new Error(err.error || `HTTP ${response.status}`);
    }

    const data = await response.json();
    showStatus(`✓ 剪藏成功！v${data.version}`, 'success');

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

async function getSettings() {
  const defaults = {
    serverUrl: 'http://localhost:8080',
    token: '',
  };
  const stored = await chrome.storage.sync.get(['serverUrl', 'token']);
  return { ...defaults, ...stored };
}
