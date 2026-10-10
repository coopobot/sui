// options.js — 设置页逻辑（M12 修订 / FR-57 / ADR-021）
//
// 变更：**不再粘贴访问 Token** —— 改为「服务端地址 + 账号 + 密码」登录，
// 令牌由 shared.js 的会话层（`suiLogin` / `suiRefreshOnce` / `suiApiFetch`）持有与刷新。
// 口令**不保存**：登录请求发出后即清空输入框（BR-57.2）。
const form = document.getElementById('settingsForm');
const serverUrlInput = document.getElementById('serverUrl');
const usernameInput = document.getElementById('username');
const passwordInput = document.getElementById('password');
const statusEl = document.getElementById('status');
const accountStateEl = document.getElementById('accountState');
const logoutBtn = document.getElementById('logoutBtn');
const warnEl = document.getElementById('plaintextWarn');

// 加载已有设置与会话状态
document.addEventListener('DOMContentLoaded', async () => {
  // FR-56（BR-56.4）：版本号与弹出面板同源——运行时读清单，不硬编码。
  const extVersionEl = document.getElementById('extVersion');
  if (extVersionEl) {
    extVersionEl.textContent = '版本 ' + chrome.runtime.getManifest().version;
  }

  const session = await suiGetSession();
  if (session.serverUrl) serverUrlInput.value = session.serverUrl;
  if (session.username) usernameInput.value = session.username;
  renderAccount(session);
  renderPlaintextWarning(serverUrlInput.value);
});

serverUrlInput.addEventListener('input', () => {
  renderPlaintextWarning(serverUrlInput.value);
});

function renderAccount(session) {
  const logged = Boolean(session.refreshToken);
  accountStateEl.textContent = logged
    ? `已登录：${session.username || '(未知账号)'}`
    : '未登录';
  logoutBtn.style.display = logged ? 'inline-block' : 'none';
}

// BR-57.6 / AC-215：扩展不实现受保护通道，公网必须 https。
function renderPlaintextWarning(url) {
  const msg = suiPlaintextWarning(url);
  warnEl.textContent = msg;
  warnEl.style.display = msg ? 'block' : 'none';
}

logoutBtn.addEventListener('click', async () => {
  await suiLogout();
  renderAccount(await suiGetSession());
  showStatus('已退出登录', 'success');
});

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const serverUrl = serverUrlInput.value.trim();
  const username = usernameInput.value.trim();
  const password = passwordInput.value;

  if (!serverUrl) {
    showStatus('请输入服务端地址', 'error');
    return;
  }
  if (!username) {
    showStatus('请输入用户名', 'error');
    return;
  }
  if (!password) {
    showStatus('请输入密码', 'error');
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
    await suiLogin(serverUrl, username, password);
    // 登录后验证一次受保护接口：确认令牌与站点权限都能用（旧版「验证连接」的等价口径）。
    const resp = await suiApiFetch('/api/v1/sync/pull?since=1970-01-01T00:00:00Z');
    if (!resp.ok) {
      throw new Error(`连接失败：HTTP ${resp.status}`);
    }
  } catch (err) {
    showStatus(`登录失败：${err.message}`, 'error');
    passwordInput.value = ''; // 口令不保留（BR-57.2）
    renderAccount(await suiGetSession());
    return;
  }

  passwordInput.value = ''; // 口令不保留（BR-57.2）
  renderAccount(await suiGetSession());
  showStatus('✓ 已登录并保存设置', 'success');
});

function showStatus(msg, type) {
  statusEl.textContent = msg;
  statusEl.className = 'status ' + type;
  if (type === 'success') {
    setTimeout(() => { statusEl.className = 'status'; }, 3000);
  }
}
