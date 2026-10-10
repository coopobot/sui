// shared.js — 剪藏扩展共享逻辑（popup 与 background service worker 复用）
//
// 集中承载：**会话（登录 / 令牌刷新）**、设置读取、模式记忆、整页采集（含懒加载触发）、剪藏请求。
// 通过 <script src>（popup.html / options.html）与 importScripts（background.js）加载。
//
// M12 修订 / FR-57（ADR-021）：**不再由用户手工粘贴 Token** ——
// 设置页用「服务端地址 + 账号 + 密码」登录换取双令牌，令牌存 `chrome.storage.local`，
// 访问令牌过期（401 `token-expired` / `invalid_token`）时**单飞刷新**并**重放一次**。
// **不保存口令**（登录请求发出后即丢弃，任何位置不回显、不落盘）。

const SUI_DEFAULT_MODE = 'article';

// 访问令牌到期前的主动刷新窗口（避免必然的 401 往返）。
const SUI_ACCESS_SKEW_MS = 60 * 1000;

function suiBaseUrl(serverUrl) {
  return String(serverUrl || '').replace(/\/$/, '');
}

// ---- 会话（storage.local；禁止 storage.sync：长期凭据不随浏览器账号离开本机）----

async function suiGetSession() {
  const stored = await chrome.storage.local.get([
    'serverUrl',
    'username',
    'accessToken',
    'refreshToken',
    'accessExpiresAt',
  ]);
  return {
    serverUrl: 'http://localhost:8080',
    username: '',
    accessToken: '',
    refreshToken: '',
    accessExpiresAt: 0,
    ...stored,
  };
}

async function suiSaveSession({ serverUrl, username, accessToken, refreshToken, expiresIn }) {
  await chrome.storage.local.set({
    serverUrl: suiBaseUrl(serverUrl),
    username: username || '',
    accessToken: accessToken || '',
    refreshToken: refreshToken || '',
    accessExpiresAt: Date.now() + (Number(expiresIn) || 0) * 1000,
  });
}

// suiClearSession 清除令牌与账号（**保留** serverUrl，便于重新登录）。
async function suiClearSession() {
  await chrome.storage.local.remove([
    'username',
    'accessToken',
    'refreshToken',
    'accessExpiresAt',
  ]);
}

// suiIsLoggedIn 报告本地是否持有会话（有刷新令牌即视为已登录）。
async function suiIsLoggedIn() {
  const s = await suiGetSession();
  return Boolean(s.serverUrl && s.refreshToken);
}

// suiLogin 账号密码登录（FR-57 / AC-210）：成功后双令牌落 storage.local，**不保留口令**。
async function suiLogin(serverUrl, username, password) {
  const base = suiBaseUrl(serverUrl);
  const resp = await fetch(`${base}/api/v1/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }),
  });
  if (resp.status === 429) {
    const retry = resp.headers.get('Retry-After') || '';
    throw new Error(`尝试过于频繁，请 ${retry || '稍后'} 秒后重试`);
  }
  const body = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    // 与客户端同口径：不区分「账号不存在」与「口令错误」（BR-59.3）。
    throw new Error('用户名或密码错误');
  }
  await suiSaveSession({
    serverUrl: base,
    username,
    accessToken: body.access_token,
    refreshToken: body.refresh_token,
    expiresIn: body.expires_in,
  });
  return body;
}

async function suiLogout() {
  await suiClearSession();
}

// suiRefreshing 保存「进行中的刷新」（**单飞**）：服务端刷新令牌**单次使用 + 重放即吊销会话**，
// 故并发请求必须共享同一次刷新，见 auth.md §11.2（AC-212）。
let suiRefreshing = null;

async function suiRefreshOnce(serverUrl) {
  if (suiRefreshing) return suiRefreshing;
  suiRefreshing = (async () => {
    const session = await suiGetSession();
    if (!session.refreshToken) {
      throw new Error('登录已失效，请重新登录');
    }
    const base = suiBaseUrl(serverUrl || session.serverUrl);
    let resp;
    try {
      resp = await fetch(`${base}/api/v1/refresh`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: session.refreshToken }),
      });
    } catch (err) {
      throw new Error(`刷新登录失败：${err.message}`);
    }
    const body = await resp.json().catch(() => ({}));
    if (!resp.ok) {
      // refresh-revoked / refresh-expired：清令牌并要求重新登录（AC-213）。
      await suiClearSession();
      throw new Error('登录已失效，请重新登录');
    }
    await suiSaveSession({
      serverUrl: base,
      username: session.username,
      accessToken: body.access_token,
      refreshToken: body.refresh_token,
      expiresIn: body.expires_in,
    });
    return body;
  })().finally(() => {
    suiRefreshing = null;
  });
  return suiRefreshing;
}

// suiApiFetch 带会话的请求：到期前主动刷新；401 时**单飞刷新后重放一次**。
async function suiApiFetch(path, init = {}, { retry = true } = {}) {
  const session = await suiGetSession();
  if (!session.serverUrl) {
    throw new Error('请先在设置中填写服务端地址');
  }
  const base = suiBaseUrl(session.serverUrl);

  if (!session.accessToken && session.refreshToken) {
    await suiRefreshOnce(base);
  }
  const current = await suiGetSession();
  if (!current.accessToken) {
    throw new Error('请先在设置中登录');
  }
  // 主动刷新：留 60s 余量，避免「取完就过期」的必然 401。
  if (
    current.refreshToken &&
    current.accessExpiresAt &&
    current.accessExpiresAt - Date.now() < SUI_ACCESS_SKEW_MS
  ) {
    try {
      await suiRefreshOnce(base);
    } catch (err) {
      // 主动刷新失败不在此处抛出：仍按 401 分支给出统一提示。
    }
  }

  const ready = await suiGetSession();
  const resp = await fetch(`${base}${path}`, {
    ...init,
    headers: {
      ...(init.headers || {}),
      Authorization: `Bearer ${ready.accessToken}`,
    },
  });

  if (resp.status === 401 && retry) {
    const text = await resp
      .clone()
      .text()
      .catch(() => '');
    if (text.includes('token-expired') || text.includes('invalid_token')) {
      await suiRefreshOnce(base); // 失败会抛「登录已失效，请重新登录」
      return suiApiFetch(path, init, { retry: false });
    }
  }
  return resp;
}

// getLastMode 读取上次选择的剪藏模式（缺省 article，BR-37.4）。
async function suiGetLastMode() {
  const stored = await chrome.storage.local.get(['lastMode']);
  return stored.lastMode === 'snapshot' ? 'snapshot' : SUI_DEFAULT_MODE;
}

// setLastMode 记住本次选择的剪藏模式（非法值回落 article）。
async function suiSetLastMode(mode) {
  const normalized = mode === 'snapshot' ? 'snapshot' : SUI_DEFAULT_MODE;
  await chrome.storage.local.set({ lastMode: normalized });
  return normalized;
}

// capturePageInTab 在页面上下文中执行：触发懒加载 → 等待就位 → 采集完整 DOM。
//
// 该函数经 chrome.scripting.executeScript 序列化后注入页面执行，
// 因此**必须自包含**（不得引用本文件其它变量 / 函数）。
function suiCaptureInPage() {
  // 1) 尽力触发懒加载：提升 loading 优先级，并把 data-* 懒加载地址回填到 src。
  const images = Array.from(document.images || []);
  for (const img of images) {
    try {
      img.loading = 'eager';
    } catch (e) {
      /* 只读属性，忽略 */
    }
    const lazy =
      img.getAttribute('data-src') ||
      img.getAttribute('data-original') ||
      img.getAttribute('data-lazy-src');
    if (lazy && (!img.getAttribute('src') || img.getAttribute('src') === location.href)) {
      try {
        img.setAttribute('src', lazy);
      } catch (e) {
        /* 忽略 */
      }
    }
  }
  // 2) 触发由 IntersectionObserver 驱动的懒加载：滚到底再回原位。
  try {
    const top = window.scrollY;
    window.scrollTo(0, document.body ? document.body.scrollHeight : 0);
    window.scrollTo(0, top);
  } catch (e) {
    /* 忽略 */
  }

  // 3) 等待未完成的图片加载（有界等待），随后返回完整 DOM。
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      resolve({
        title: document.title,
        url: location.href,
        html: document.documentElement.outerHTML,
      });
    };

    const pending = Array.from(document.images || []).filter((img) => !img.complete);
    if (pending.length === 0) {
      // 留一帧让懒加载属性回填生效。
      setTimeout(finish, 300);
      return;
    }

    let remaining = pending.length;
    const done = () => {
      remaining -= 1;
      if (remaining <= 0) finish();
    };
    for (const img of pending) {
      img.addEventListener('load', done, { once: true });
      img.addEventListener('error', done, { once: true });
    }
    // 兜底：单页最多等待 3 秒，避免浮层长时间无响应。
    setTimeout(finish, 3000);
  });
}

// captureTab 采集指定标签页的完整网页数据。
async function suiCaptureTab(tabId) {
  const [result] = await chrome.scripting.executeScript({
    target: { tabId },
    func: suiCaptureInPage,
  });
  return result.result;
}

// postClip 调用服务端剪藏接口（**带会话**，401 自动刷新），返回响应体（含 mode 与 unlocalizedImages）。
async function suiPostClip(pageData, mode) {
  const resp = await suiApiFetch('/api/v1/clips', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      url: pageData.url,
      title: pageData.title,
      html: pageData.html,
      mode: mode === 'snapshot' ? 'snapshot' : SUI_DEFAULT_MODE,
    }),
  });
  const body = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    if (resp.status === 401) {
      throw new Error('登录已失效，请重新登录');
    }
    throw new Error(body.error || `HTTP ${resp.status}`);
  }
  return body;
}

// buildResultMessage 生成结果反馈文案（含「未本地化」附注，§5）。
function suiBuildResultMessage(data) {
  let msg = `剪藏成功 v${data.version}`;
  const skipped = Number(data.unlocalizedImages) || 0;
  if (skipped > 0) {
    msg += `（${skipped} 张图片未本地化）`;
  }
  return msg;
}

// suiPlaintextWarning 返回明文地址的警示文案（BR-57.6 / AC-215）：扩展不实现受保护通道，
// 故公网场景必须使用 https；本机 / 私网地址可放宽。
function suiPlaintextWarning(serverUrl) {
  let parsed;
  try {
    parsed = new URL(serverUrl);
  } catch (e) {
    return '';
  }
  if (parsed.protocol !== 'http:') return '';
  const host = parsed.hostname;
  const isLocal =
    host === 'localhost' ||
    host === '127.0.0.1' ||
    host === '[::1]' ||
    host === '::1' ||
    host.startsWith('192.168.') ||
    host.startsWith('10.') ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host);
  return isLocal ? '' : '公网请使用 https:// 地址（扩展不加密传输）';
}
