// options.js — 设置页逻辑
const form = document.getElementById('settingsForm');
const serverUrlInput = document.getElementById('serverUrl');
const tokenInput = document.getElementById('token');
const statusEl = document.getElementById('status');

// 加载已有设置
document.addEventListener('DOMContentLoaded', async () => {
  const settings = await chrome.storage.local.get(['serverUrl', 'token']);
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

  // M10-T30：manifest 不再声明 `<all_urls>`（收窄为 activeTab + 运行时可选项）。
  // 出网目标取决于用户配置的服务端地址，故必须在**用户手势**中按来源申请权限。
  let origin;
  try {
    const parsed = new URL(serverUrl);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      throw new Error('仅支持 http:// 或 https:// 地址');
    }
    origin = `${parsed.origin}/*`;
  } catch (err) {
    showStatus(`服务端地址无效：${err.message}`, 'error');
    return;
  }
  if (!(await chrome.permissions.request({ origins: [origin] }))) {
    showStatus('未授予该服务端地址的访问权限，无法剪藏', 'error');
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

  await chrome.storage.local.set({ serverUrl, token });
  showStatus('✓ 设置已保存', 'success');
});

function showStatus(msg, type) {
  statusEl.textContent = msg;
  statusEl.className = 'status ' + type;
  if (type === 'success') {
    setTimeout(() => { statusEl.className = 'status'; }, 3000);
  }
}
