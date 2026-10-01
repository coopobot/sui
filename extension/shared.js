// shared.js — 剪藏扩展共享逻辑（popup 与 background service worker 复用）
//
// 集中承载：设置读取、模式记忆、整页采集（含懒加载触发）、剪藏请求。
// 通过 <script src>（popup.html）与 importScripts（background.js）加载。

const SUI_DEFAULT_MODE = 'article';

// getSettings 读取服务端地址与 Token（缺省回落本地默认值）。
async function suiGetSettings() {
  const defaults = { serverUrl: 'http://localhost:8080', token: '' };
  const stored = await chrome.storage.sync.get(['serverUrl', 'token']);
  return { ...defaults, ...stored };
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

// postClip 调用服务端剪藏接口，返回响应体（含 mode 与 unlocalizedImages）。
async function suiPostClip(settings, pageData, mode) {
  const resp = await fetch(`${settings.serverUrl.replace(/\/$/, '')}/api/v1/clips`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${settings.token}`,
    },
    body: JSON.stringify({
      url: pageData.url,
      title: pageData.title,
      html: pageData.html,
      mode: mode === 'snapshot' ? 'snapshot' : SUI_DEFAULT_MODE,
    }),
  });
  const body = await resp.json().catch(() => ({}));
  if (!resp.ok) {
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
