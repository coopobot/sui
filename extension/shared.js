// shared.js — 剪藏扩展共享逻辑（popup 与 background service worker 复用）
//
// 集中承载：**会话（登录 / 令牌刷新）**、设置读取、模式记忆、整页采集（含懒加载触发）、剪藏请求。
// 通过 <script src>（popup.html / options.html）与 importScripts（background.js）加载。
//
// M12 修订 / FR-57（ADR-021）：**不再由用户手工粘贴 Token** ——
// 设置页用「服务端地址 + 账号 + 密码」登录换取双令牌，令牌存 `chrome.storage.local`，
// 访问令牌过期（401 `token-expired` / `invalid_token`）时**单飞刷新**并**重放一次**。
// **不保存口令**（登录请求发出后即丢弃，任何位置不回显、不落盘）。

// M16 / FR-83：默认全页快照（保留原页布局）；用户仍可切回 article。
const SUI_DEFAULT_MODE = 'snapshot';

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
  if (stored.lastMode === 'article' || stored.lastMode === 'snapshot') {
    return stored.lastMode;
  }
  return SUI_DEFAULT_MODE;
}

// setLastMode 记住本次选择的剪藏模式（非法值回落默认快照）。
async function suiSetLastMode(mode) {
  const normalized = mode === 'article' ? 'article' : SUI_DEFAULT_MODE;
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
  //
  // M16 / FR-83：快照模式下额外把可读取的样式表内联进克隆 DOM，并剔除脚本 /
  // 事件属性 / 远程样式表，产出**单文件 HTML 原件**。全过程自包含（本函数会被
  // 序列化后注入页面上下文，不能引用 shared.js 的其它函数）。
  async function buildSnapshotHtml() {
    try {
      const clone = document.documentElement.cloneNode(true);
      // 保留 <link rel=stylesheet>：跨域样式表在 page 上下文读不到 cssRules，
      // 交给服务端剪藏链路拉取并内联（见 server/internal/clip/webclip.go）。
      const drop = 'script,noscript,iframe,object,embed,form,input,button,select,textarea';
      clone.querySelectorAll(drop).forEach((n) => n.remove());
      for (const el of clone.querySelectorAll('*')) {
        for (const attr of Array.from(el.attributes || [])) {
          const name = String(attr.name || '').toLowerCase();
          if (name.startsWith('on') || name === 'srcdoc' || name === 'formaction') {
            el.removeAttribute(attr.name);
            continue;
          }
          if (name === 'href' || name === 'src' || name === 'xlink:href' || name === 'action') {
            const v = String(attr.value || '').trim().toLowerCase();
            if (v.startsWith('javascript:') || v.startsWith('vbscript:') || v.startsWith('data:text/html')) {
              el.removeAttribute(attr.name);
            }
          }
        }
      }
      // 收集样式：同源可直接读 cssRules；跨域尝试 fetch（失败跳过）。
      const css = [];
      for (const sheet of Array.from(document.styleSheets || [])) {
        try {
          for (const rule of Array.from(sheet.cssRules || [])) css.push(rule.cssText);
        } catch (e) {
          const href = sheet.href;
          if (href) {
            try {
              const r = await fetch(href, { credentials: 'omit' });
              if (r.ok) css.push(await r.text());
            } catch (ignored) {
              /* 跨域且不可 fetch：保留缺失，不阻断 */
            }
          }
        }
      }
      clone.querySelectorAll('style').forEach((n) => n.remove());
      if (css.length > 0) {
        const head = clone.querySelector('head');
        if (head) {
          const style = document.createElement('style');
          style.setAttribute('data-sui-snapshot', '');
          style.textContent = css.join('\n');
          head.appendChild(style);
        }
      }
      let out = '<!DOCTYPE html>\n' + clone.outerHTML;
      // 与服务端 MaxWebClipBytes 对齐（12 MiB）；超限回退原始 DOM，服务端再兜底。
      if (out.length > 12 * 1024 * 1024) {
        out = document.documentElement.outerHTML;
      }
      return out;
    } catch (e) {
      return document.documentElement.outerHTML;
    }
  }

  return new Promise((resolve) => {
    let settled = false;
    const finish = async () => {
      if (settled) return;
      settled = true;
      const html = await buildSnapshotHtml();
      resolve({
        title: document.title,
        url: location.href,
        html,
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
//
// v0.14.0：新增**可选**字段 `screenshot {filename, dataBase64}`（整页截图，见 suiCaptureScreenshot）。
// 缺失时请求体与旧版**逐字节一致**——截图是纯加成，任何情况下都不影响剪藏本身。
async function suiPostClip(pageData, mode, screenshot) {
  const payload = {
    url: pageData.url,
    title: pageData.title,
    html: pageData.html,
    mode: mode === 'snapshot' ? 'snapshot' : SUI_DEFAULT_MODE,
  };
  if (screenshot && screenshot.dataBase64) {
    payload.screenshot = {
      filename: screenshot.filename,
      dataBase64: screenshot.dataBase64,
    };
  }
  const resp = await suiApiFetch('/api/v1/clips', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
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
//
// v0.14.0：截图**采到并随请求发出**时追加「含整页截图」。判据是扩展侧的
// `screenshotCaptured`（服务端不回报截图是否入库，故不用 `data.screenshot`）：
// 没截到 / 中途放弃 → 文案与今天**逐字符一致**（不吓唬用户）。
function suiBuildResultMessage(data) {
  let msg = `剪藏成功 v${data.version}`;
  const notes = [];
  const skipped = Number(data.unlocalizedImages) || 0;
  if (skipped > 0) {
    notes.push(`${skipped} 张图片未本地化`);
  }
  if (data && data.screenshotCaptured) {
    notes.push('含整页截图');
  }
  if (notes.length > 0) {
    msg += `（${notes.join('，')}）`;
  }
  return msg;
}

// ---- 整页截图（v0.14.0：滚动拼接 → 随剪藏请求上行 → 服务端作为附件入库）----
//
// 采集链路：**内容脚本负责滚动**（返回视口 / 文档高度 / dpr / 当前 scrollY），
// 扩展页用 `chrome.tabs.captureVisibleTab` 逐屏取图，再在 canvas 上按 `scrollY * dpr` 纵向拼接。
//
// 为什么不走 `chrome.debugger` + `Page.captureScreenshot({captureBeyondViewport:true})`？
//   1) `debugger` 会在页面顶部常驻一条「正在调试此浏览器」的黄色横幅，并要求用户额外授权，
//      对「随手剪一下」的场景代价过高；
//   2) 它会与用户自己的 DevTools 互相抢占（同一标签页只能有一个调试器），
//      用户开着 F12 时剪藏会直接失败；
//   3) 本次已有 `activeTab` + `scripting`，滚动拼接零新增权限——权限面越小越好。
// 代价是滚动拼接的固有限制：**固定定位元素（sticky header / 固定浮层）会在每个分屏重复出现**。
// 这是滚动拼接的固有产物，不是缺陷；不为此引入 debugger 权限去换「一次性整页渲染」。

// SUI_SHOT_MIN_INTERVAL_MS：chrome.tabs.captureVisibleTab 有**每秒 2 次**的调用上限
// （超限报错），故两次取图之间至少等 600ms（留 100ms 余量）。
const SUI_SHOT_MIN_INTERVAL_MS = 600;
// SUI_SHOT_MAX_MS：截图总耗时上限；超时即放弃截图（剪藏本身不受影响）。
const SUI_SHOT_MAX_MS = 20000;
// SUI_SHOT_MAX_HEIGHT：拼接画布高度上限（**设备像素**）。16000 约等于 2.3 屏像素级 4K 屏，
// 内存约 16000 × 视口宽 × 4B；再高就要防 canvas 分配失败 / 标签页被 OOM 杀掉。
const SUI_SHOT_MAX_HEIGHT = 16000;
// SUI_SHOT_MAX_B64：base64 载荷闸门。服务端请求体上限 8 MiB（limits.go maxBodyBytes），
// body 里还要装整页 HTML，故载荷超过 5 MiB 先降质量重编码；仍超限则放弃截图。
const SUI_SHOT_MAX_B64 = 5 * 1024 * 1024;
// SUI_SHOT_QUALITIES：重编码质量阶梯（首次 / 降级各档）。
const SUI_SHOT_QUALITIES = [80, 60, 45];
// SUI_SHOT_FILENAME：附件展示名（服务端只把它当展示名，不看扩展名判类型——按魔数判定）。
const SUI_SHOT_FILENAME = '整页截图.jpg';

// suiPlanScreenshotSlices 规划整页截图的分屏滚动位置（**纯函数**，便于单测）。
//
// 入参（全部由页面侧实测）：
//   - innerHeight：视口高度（CSS px）；
//   - scrollHeight：文档高度（CSS px）；
//   - devicePixelRatio：设备像素比（截图落在设备像素上，故用 dpr 换算）；
//   - maxHeight：拼接画布高度上限（**设备像素**）。
//
// 返回 { positions, canvasHeight, truncated }：
//   - positions：每屏的 CSS px 滚动位置。除末屏对齐文档底部（保证不遗漏页尾）外，
//     相邻两屏步进 `innerHeight`，**屏与屏不重叠**；
//   - canvasHeight：画布高度（设备像素；**上限按整屏向下取整**，故末屏永远画得进画布）；
//   - truncated：是否因超过 maxHeight 而截断（丢掉文档尾部，只保留画布内的部分）。
//
// 边界：视口高度非法（<=0 / 非有限数）→ 空规划，调用方据此放弃截图；
// 文档不足一屏 → 单屏（positions=[0]）。
function suiPlanScreenshotSlices({ innerHeight, scrollHeight, devicePixelRatio, maxHeight } = {}) {
  const viewport = Math.floor(Number(innerHeight) || 0);
  if (!(viewport > 0)) {
    return { positions: [], canvasHeight: 0, truncated: false };
  }
  const docHeight = Math.max(viewport, Math.floor(Number(scrollHeight) || 0));
  const dpr = Number(devicePixelRatio) > 0 ? Number(devicePixelRatio) : 1;
  const limit = Number(maxHeight) > 0 ? Number(maxHeight) : SUI_SHOT_MAX_HEIGHT;

  // 画布高度 = 文档高度（设备像素），但**上限必须整屏对齐**：上限若不落在整屏边界上，
  // 末屏就会有一部分画到画布外（drawImage 内部被静默裁剪）——那是最难查的「截图尾部缺一条」。
  // 故上限先向下取整到整屏，再与文档高度取小；文档不足一屏时画布就是一屏。
  const framePx = Math.max(1, Math.round(viewport * dpr));
  const totalPx = Math.round(docHeight * dpr);
  const canvasCap = Math.floor(limit / framePx) * framePx;
  const truncated = totalPx > canvasCap;
  const canvasHeight = Math.min(totalPx, canvasCap);

  // 末屏需覆盖到文档末尾：`maxScroll = docHeight - viewport` 恰好让末屏下沿对齐文档底部。
  // 截断时只接受到画布底为止，余下内容**不再截取**——宁少一截，不越界画布。
  const lastPosition = truncated
    ? Math.max(0, Math.floor(canvasHeight / dpr) - viewport)
    : Math.max(0, docHeight - viewport);

  // 步进恰为视口高度：上一屏覆盖 [y, y+viewport-1]，下一屏从 y+viewport 起，**不重叠**。
  // 画布不足一屏（上限比视口还小）：拼不出完整的东西，直接给空规划让调用方放弃截图。
  if (canvasHeight <= 0) {
    return { positions: [], canvasHeight: 0, truncated };
  }

  const positions = [0];
  let y = viewport;
  while (y < lastPosition) {
    positions.push(y);
    y += viewport;
  }
  if (lastPosition > positions[positions.length - 1]) {
    positions.push(lastPosition);
  }

  return { positions, canvasHeight, truncated };
}

// suiScrollToInPage 在页面上下文中执行：滚动到指定位置，返回该屏的几何信息。
//
// 经 chrome.scripting.executeScript 注入页面执行，**必须自包含**（不得引用本文件其它变量 / 函数）。
function suiScrollToInPage(y) {
  // 先定位，再等两帧：滚动是异步的（平滑滚动 / 滚动驱动的懒加载与动画），
  // 不等就可能把过渡中的画面截进来（表现为某屏模糊或错位）。
  window.scrollTo(0, y);
  return new Promise((resolve) => {
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        resolve({
          scrollY: window.scrollY,
          innerHeight: window.innerHeight,
          innerWidth: window.innerWidth,
          scrollHeight: Math.max(
            document.documentElement ? document.documentElement.scrollHeight : 0,
            document.body ? document.body.scrollHeight : 0,
          ),
          devicePixelRatio: window.devicePixelRatio || 1,
        });
      });
    });
  });
}

// suiSleep 等待 ms 毫秒（截图节奏受 captureVisibleTab 速率上限约束）。
function suiSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// suiDecodeToDrawable 把 captureVisibleTab 返回的 data URL 解成可 drawImage 的对象。
//
// 优先 `createImageBitmap`（解码在后台线程，且**不依赖扩展页的 document**——
// MV3 service worker 里也能用）；不可用时回落 HTMLImageElement。
async function suiDecodeToDrawable(dataUrl) {
  if (typeof createImageBitmap === 'function') {
    const blob = await (await fetch(dataUrl)).blob();
    return createImageBitmap(blob);
  }
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('截图解码失败'));
    img.src = dataUrl;
  });
}

// suiBlobToBase64 把 Blob 转成**不带** data URL 前缀的 base64。
//
// 浏览器走 FileReader（快），无 FileReader 的环境（Node 单测）走自带编码器——
// 不引入任何依赖，且不依赖 btoa 是否存在。
function suiBlobToBase64(blob) {
  if (typeof FileReader === 'function') {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const url = String(reader.result || '');
        const comma = url.indexOf(',');
        resolve(comma >= 0 ? url.slice(comma + 1) : url);
      };
      reader.onerror = () => reject(new Error('截图编码失败'));
      reader.readAsDataURL(blob);
    });
  }
  return blob.arrayBuffer().then((buf) => {
    const bytes = new Uint8Array(buf);
    let raw = '';
    for (let i = 0; i < bytes.length; i += 1) {
      raw += String.fromCharCode(bytes[i]);
    }
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let b64 = '';
    for (let i = 0; i < raw.length; i += 3) {
      const c1 = raw.charCodeAt(i);
      const has2 = i + 1 < raw.length;
      const has3 = i + 2 < raw.length;
      const c2 = has2 ? raw.charCodeAt(i + 1) : 0;
      const c3 = has3 ? raw.charCodeAt(i + 2) : 0;
      b64 += alphabet[c1 >> 2];
      b64 += alphabet[((c1 & 3) << 4) | (c2 >> 4)];
      b64 += has2 ? alphabet[((c2 & 15) << 2) | (c3 >> 6)] : '=';
      b64 += has3 ? alphabet[c3 & 63] : '=';
    }
    return b64;
  });
}

// suiCanvasToBlob 把画布导出为 JPEG Blob（优先 toBlob；不支持时回落 toDataURL 再解码）。
async function suiCanvasToBlob(canvas, quality) {
  if (typeof canvas.toBlob === 'function') {
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', quality));
    if (blob) return blob;
  }
  const dataUrl = canvas.toDataURL('image/jpeg', quality);
  return (await fetch(dataUrl)).blob();
}

// suiEncodeScreenshotWithinBudget 把画布编码为 JPEG，并按质量阶梯满足载荷闸门。
//
// 返回 base64 字符串；即使最低质量仍超限也返回**最低质量的那一份**，由调用方决定放弃——
// 本函数只负责「尽量小」，不负责「要不要」（策略与编码分离，便于单测）。
async function suiEncodeScreenshotWithinBudget(canvas) {
  let last = null;
  for (const quality of SUI_SHOT_QUALITIES) {
    last = await suiBlobToBase64(await suiCanvasToBlob(canvas, quality / 100));
    if (last.length <= SUI_SHOT_MAX_B64) {
      return last;
    }
  }
  return last;
}

// suiCaptureScreenshot 采集**整页截图**：逐屏取图 → canvas 纵向拼接 → JPEG base64。
//
// 返回 Promise<{filename, dataBase64} | null>：null = 未采到（调用方照常剪藏）。
//
// **有界与降级**（任一失败都**静默放弃**，绝不抛给调用方）：
//   - captureVisibleTab 抛错（缺 activeTab 授权 / 页面是受保护页 / 窗口失焦）→ 整体放弃；
//   - 两次取图之间至少 SUI_SHOT_MIN_INTERVAL_MS（每秒 2 次的上限）；
//   - 总耗时超过 SUI_SHOT_MAX_MS → 放弃；
//   - 拼接高度超过 SUI_SHOT_MAX_HEIGHT（设备像素）→ 截到上限；
//   - 单屏解码 / drawImage 失败 → 放弃（拼不齐的整页截图比没有更糟）；
//   - 编码后仍超过 SUI_SHOT_MAX_B64 → 放弃。
async function suiCaptureScreenshot(tabId) {
  try {
    if (typeof tabId !== 'number' || typeof chrome === 'undefined' || !chrome.tabs) {
      return null;
    }
    const started = Date.now();

    // 1) 先到页首取几何信息（同时也把页面复位，避免接着上一轮剪藏的滚动位置截起）。
    let geo = await chrome.scripting.executeScript({
      target: { tabId },
      func: suiScrollToInPage,
      args: [0],
    });
    geo = geo && geo[0] ? geo[0].result : null;
    if (!geo || !geo.innerHeight) {
      return null;
    }

    // 2) 规划分屏（纯函数，见 suiPlanScreenshotSlices）。
    const plan = suiPlanScreenshotSlices({
      innerHeight: geo.innerHeight,
      scrollHeight: geo.scrollHeight,
      devicePixelRatio: geo.devicePixelRatio,
      maxHeight: SUI_SHOT_MAX_HEIGHT,
    });
    if (!plan.positions.length || plan.canvasHeight <= 0) {
      return null;
    }

    const dpr = Number(geo.devicePixelRatio) > 0 ? Number(geo.devicePixelRatio) : 1;

    // 3) 建画布（优先 OffscreenCanvas：不在 DOM 里挂载任何东西；回落普通 canvas）。
    const stepPx = Math.max(1, Math.round(geo.innerHeight * dpr));
    const canvasWidth = Math.max(Math.round(Number(geo.innerWidth) || 0), 1);
    let canvas;
    if (typeof OffscreenCanvas === 'function') {
      canvas = new OffscreenCanvas(canvasWidth, plan.canvasHeight);
    } else {
      canvas = document.createElement('canvas');
      canvas.width = canvasWidth;
      canvas.height = plan.canvasHeight;
    }
    const ctx = canvas.getContext('2d');
    if (!ctx || typeof ctx.drawImage !== 'function') {
      return null;
    }

    // 4) 逐屏取图 + 拼接。
    for (let i = 0; i < plan.positions.length; i += 1) {
      if (i > 0) {
        await suiSleep(SUI_SHOT_MIN_INTERVAL_MS); // 速率闸门：每秒最多 2 次
      }
      if (Date.now() - started > SUI_SHOT_MAX_MS) {
        return null; // 总耗时上限：放弃截图，剪藏照常
      }
      const scroll = await chrome.scripting.executeScript({
        target: { tabId },
        func: suiScrollToInPage,
        args: [plan.positions[i]],
      });
      const frame = scroll && scroll[0] ? scroll[0].result : null;
      if (!frame) {
        return null;
      }
      const dataUrl = await chrome.tabs.captureVisibleTab(null, {
        format: 'jpeg',
        quality: SUI_SHOT_QUALITIES[0],
      });
      if (!dataUrl) {
        return null;
      }
      const source = await suiDecodeToDrawable(dataUrl);
      // 用**接收时刻的 scrollY**（而非计划值）定位：页面被拦截滚动 / 自动回顶时不会错位。
      const topPx = Math.max(0, Math.round((Number(frame.scrollY) || 0) * dpr));
      if (topPx >= plan.canvasHeight) {
        break; // 已到画布下沿（截断场景）
      }
      try {
        ctx.drawImage(source, 0, topPx, canvasWidth, stepPx);
      } finally {
        if (source && typeof source.close === 'function') source.close();
      }
    }

    // 5) 编码 + 载荷闸门。
    const dataBase64 = await suiEncodeScreenshotWithinBudget(canvas);
    if (!dataBase64 || dataBase64.length > SUI_SHOT_MAX_B64) {
      return null;
    }
    return { filename: SUI_SHOT_FILENAME, dataBase64 };
  } catch (err) {
    // **静默放弃**：截图是加成的加成——权限被收回、受保护页、canvas 分配失败、
    // 取图被速率限制拒绝……任何一种都不该让「把内容存下来」这件事失败。
    return null;
  }
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
