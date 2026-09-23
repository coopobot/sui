// options.js — 设置页逻辑
const form = document.getElementById('settingsForm');
const serverUrlInput = document.getElementById('serverUrl');
const tokenInput = document.getElementById('token');
const statusEl = document.getElementById('status');

// 加载已有设置
document.addEventListener('DOMContentLoaded', async () => {
  const settings = await chrome.storage.sync.get(['serverUrl', 'token']);
  if (settings.serverUrl) serverUrlInput.value = settings.serverUrl;
  if (settings.token) tokenInput.value = settings.token;
});

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const serverUrl = serverUrlInput.value.trim();
  const token = tokenInput.value.trim();

  if (!serverUrl) {
    showStatus('请输入服务端地址', 'error');
    return;
  }
  if (!token) {
    showStatus('请输入访问 Token', 'error');
    return;
  }

  try {
    // 验证连接
    const resp = await fetch(`${serverUrl.replace(/\/$/, '')}/api/v1/sync/pull?since=1970-01-01T00:00:00Z`, {
      headers: { 'Authorization': `Bearer ${token}` },
    });
    if (!resp.ok) {
      throw new Error(`连接失败：HTTP ${resp.status}（请检查地址和 Token）`);
    }
  } catch (err) {
    showStatus(`验证失败：${err.message}`, 'error');
    return;
  }

  await chrome.storage.sync.set({ serverUrl, token });
  showStatus('✓ 设置已保存', 'success');
});

function showStatus(msg, type) {
  statusEl.textContent = msg;
  statusEl.className = 'status ' + type;
  if (type === 'success') {
    setTimeout(() => { statusEl.className = 'status'; }, 3000);
  }
}
