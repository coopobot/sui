// v0.14.0「全页快照 → 整页截图」的扩展侧自动化门禁。
//
// 运行：`node --test extension/test/screenshot_test.mjs`（Node ≥ 18，无需任何依赖）
//
// 覆盖：
//   - `suiPlanScreenshotSlices` **纯函数**：不重复、不遗漏、末屏对齐文档底部、
//     超上限时截断、文档不足一屏、视口非法（分屏位置规划）；
//   - 分屏**采集**：逐屏 `captureVisibleTab` + 按 `scrollY * dpr` 纵向拼接，
//     两次取图之间至少 600ms（captureVisibleTab 每秒 2 次的速率上限）；
//   - 载荷：base64 超 5 MiB → 按质量阶梯 80 → 60 → 45 重编码；仍超限 → 放弃截图；
//   - 降级：`captureVisibleTab` 抛错 / 总耗时超上限 → 静默放弃，剪藏照常且请求体不含截图字段；
//   - 模式闸门：`popup.js` 真实流程下 `article` 模式**一次都不截**、`snapshot` 才截；
//   - 结果文案：带了截图才追加「含整页截图」，没带则与既有文案**逐字符一致**。
//
// 说明：`shared.js` / `popup.js` 都不是 ES 模块（走 `<script src>` / `importScripts`），
// 故沿用 `session_test.mjs` 的范式——用 `node:vm` 在带 stub 的沙箱里求值，
// 再调用其顶层函数 / 触发其事件回调。截图相关的浏览器 API（chrome.tabs / canvas /
// createImageBitmap）全部以桩替代，**不触网、不依赖真实浏览器**。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const sharedSrc = fs.readFileSync(path.join(here, '..', 'shared.js'), 'utf8');
const popupSrc = fs.readFileSync(path.join(here, '..', 'popup.js'), 'utf8');

const MiB = 1024 * 1024;
// chrome.tabs.captureVisibleTab 的真实报错文案（未授权 / 速率超限都归到「取图失败」）。
const CAPTURE_DENIED = 'Either the "activeTab" permission or a matching host permission is required.';

/// jsonResponse 构造 HTTP 响应桩（含 shared.js 用到的 `ok` / `status` / `headers` / `json` / `text` / `clone`）。
function jsonResponse(status, body) {
  const resp = {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    json: async () => body,
    text: async () => JSON.stringify(body),
    clone: () => resp,
  };
  return resp;
}

/// decodeDataUrl 取 data URL 的字节（测试桩用的极简解码，与产品代码无关）。
function decodeDataUrl(url) {
  const comma = url.indexOf(',');
  return Buffer.from(url.slice(comma + 1), 'base64');
}

/// makeBlob 造一个只实现 `arrayBuffer()` 的 Blob 桩（shared.js 在无 FileReader 时走这条路）。
function makeBlob(bytes) {
  return {
    size: bytes.length,
    async arrayBuffer() {
      const copy = new Uint8Array(bytes.length);
      copy.set(bytes);
      return copy.buffer;
    },
  };
}

/// pageGlobals 造页面侧的最小全局桩（两个注入函数在真实浏览器里跑在**页面**上下文）。
///
/// 只给它们真正用到的成员：`suiScrollToInPage` 要 window / document；
/// `suiCaptureInPage` 要 document.images / document.title / location.href / documentElement.outerHTML。
function pageGlobals(initial) {
  const page = { ...initial, scrollY: 0 };
  const windowStub = {
    get innerWidth() {
      return page.innerWidth;
    },
    get innerHeight() {
      return page.innerHeight;
    },
    get devicePixelRatio() {
      return page.devicePixelRatio;
    },
    get scrollY() {
      return page.scrollY;
    },
    set scrollY(v) {
      page.scrollY = v;
    },
    // 老实滚动：页面停在目标位置（真实页面的 `window.scrollTo` 同义）。
    scrollTo: (_x, y) => {
      page.scrollY = y;
    },
  };
  const documentStub = {
    title: '测试页',
    images: [],
    get documentElement() {
      return { scrollHeight: page.scrollHeight, outerHTML: '<html><body>stub</body></html>' };
    },
    get body() {
      return { scrollHeight: page.scrollHeight };
    },
  };
  return { page, windowStub, documentStub };
}

/// loadShared 在沙箱中加载 `shared.js`，并返回 api 与各调用记录桩。
///
/// 签名沿用 `session_test.mjs` 的 `loadShared({...})`；另兼容 `loadShared(true)`
/// （等价于 `{ recordCalls: true }`，用例里读起来更短）。
///
/// opts：
///   - recordCalls：记录发往服务端的请求（默认关：纯函数用例不必记录）；
///   - captureImpl：`chrome.tabs.captureVisibleTab` 实现；**缺省即模拟「未授权」抛错**；
///   - encodePlan：按质量返回 JPEG 字节，用于模拟体积阶梯。
function loadShared(opts = {}) {
  if (opts === true) opts = { recordCalls: true };
  if (typeof opts !== 'object' || opts === null) opts = {};
  const { recordCalls = false, captureImpl, encodePlan } = opts;

  const store = new Map();
  const calls = [];
  const captureCalls = [];
  const sleepCalls = [];
  const drawCalls = [];
  const qualityCalls = [];

  const local = {
    get: async (keys) => {
      const list = Array.isArray(keys) ? keys : [keys];
      const out = {};
      for (const k of list) if (store.has(k)) out[k] = store.get(k);
      return out;
    },
    set: async (obj) => {
      for (const [k, v] of Object.entries(obj)) store.set(k, v);
    },
    remove: async (keys) => {
      const list = Array.isArray(keys) ? keys : [keys];
      for (const k of list) store.delete(k);
    },
  };

  const canvas = {
    width: 0,
    height: 0,
    getContext() {
      return {
        drawImage(source, dx, dy, w, h) {
          drawCalls.push({ source, dx, dy, w, h });
        },
      };
    },
    toBlob(cb, type, quality) {
      qualityCalls.push(quality);
      const plan = encodePlan || (() => new Uint8Array([7, 7, 7]));
      cb(makeBlob(plan(quality, canvas)));
    },
  };

  const { page, windowStub, documentStub } = pageGlobals({
    innerWidth: 600,
    innerHeight: 800,
    devicePixelRatio: 1,
    scrollHeight: 2400,
  });

  const sandbox = {
    chrome: { storage: { local } },
    console,
    URL,
    Uint8Array,
    Promise,
    // 注意：必须在**沙箱内**定义 setTimeout 包装（而不是把宿主函数直接塞进去）——
    // 产品代码里 `setTimeout === setTimeout` 的恒等性会让注入 wrapper 失效，记录不到节奏。
    setTimeout: (fn, ms) => {
      sleepCalls.push(Number(ms) || 0);
      return setTimeout(fn, ms);
    },
    clearTimeout: (id) => clearTimeout(id),
    OffscreenCanvas: function OffscreenCanvas(width, height) {
      canvas.width = width;
      canvas.height = height;
      return canvas;
    },
    createImageBitmap: async () => ({ width: 100, height: 100, close() {} }),
    requestAnimationFrame: (fn) => setTimeout(fn, 0),
    location: { href: 'https://page.example/' },
    window: windowStub,
    document: documentStub,
    fetch: async (url, init) => {
      if (recordCalls) calls.push({ url: String(url), init });
      if (String(url).startsWith('data:')) {
        return { blob: async () => makeBlob(decodeDataUrl(String(url))) };
      }
      return jsonResponse(200, { ok: true });
    },
  };
  // executeScript 注入的函数在本沙箱里执行，故 chrome.scripting 桩直接调用它。
  sandbox.chrome.scripting = {
    async executeScript({ func, args }) {
      return [{ result: await func(args && args.length ? args[0] : 0) }];
    },
  };
  sandbox.chrome.tabs = {
    async captureVisibleTab(windowId, options) {
      if (!captureImpl) throw new Error(CAPTURE_DENIED); // 缺省 = 取图失败
      captureCalls.push({ windowId, options });
      return captureImpl(captureCalls.length, options);
    },
  };

  vm.createContext(sandbox);
  vm.runInContext(sharedSrc, sandbox);

  return {
    api: sandbox,
    store,
    page,
    calls,
    captureCalls,
    sleepCalls,
    drawCalls,
    qualityCalls,
    canvas,
    /// setGeometry 设定下一次采集看到的页面几何（等价于真实页面的 window.innerXX）。
    setGeometry({ innerHeight, innerWidth, scrollHeight, devicePixelRatio }) {
      page.innerHeight = innerHeight;
      page.innerWidth = innerWidth;
      page.scrollHeight = scrollHeight;
      page.devicePixelRatio = devicePixelRatio;
      page.scrollY = 0;
    },
  };
}

/// seedSession 预置一个「已登录」的会话（截图用例都要走真实剪藏请求）。
function seedSession(env) {
  env.store.set('serverUrl', 'http://h');
  env.store.set('username', 'u1');
  env.store.set('accessToken', 'A1');
  env.store.set('refreshToken', 'R1');
  env.store.set('accessExpiresAt', 1_000_000 + 10 * 60 * 1000);
}

/// planOf 调纯函数（options 用简写，避免与 shared.js 的长参数名混读）。
function planOf(env, { innerHeight, scrollHeight, dpr, maxHeight }) {
  return env.api.suiPlanScreenshotSlices({
    innerHeight,
    scrollHeight,
    devicePixelRatio: dpr,
    maxHeight,
  });
}

/// lastClipBody 取最近一次 /api/v1/clips 请求体。
function lastClipBody(env) {
  const call = env.calls.filter((c) => String(c.url).endsWith('/api/v1/clips')).pop();
  assert.ok(call, '期望发出过一次剪藏请求');
  return JSON.parse(call.init.body);
}

// ---- 分屏位置规划（纯函数）----

test('分屏规划：不重复、不遗漏、末屏对齐文档底部', () => {
  const plan = planOf(loadShared(), { innerHeight: 800, scrollHeight: 4800, dpr: 1 });

  assert.deepEqual([...plan.positions], [0, 800, 1600, 2400, 3200, 4000]);
  assert.equal(plan.canvasHeight, 4800);
  assert.equal(plan.truncated, false);

  // 不重复：
  assert.equal(new Set(plan.positions).size, plan.positions.length);
  // 不遗漏：各屏覆盖的闭区间并起来必须覆盖 [0, docHeight-1] 的每个像素。
  const covered = new Set();
  for (const y of plan.positions) {
    for (let i = 0; i < 800; i += 1) covered.add(y + i);
  }
  for (let px = 0; px < 4800; px += 1) {
    assert.ok(covered.has(px), `像素 ${px} 未被任何分屏覆盖（遗漏）`);
  }
  // 末屏对齐文档底部（不遗漏页尾，也不多截一屏空白）。
  assert.equal(plan.positions[plan.positions.length - 1] + 800, 4800);
});

test('分屏规划：末屏步进不足一屏时不得重复取同一屏', () => {
  const plan = planOf(loadShared(), { innerHeight: 1000, scrollHeight: 2500, dpr: 1 });
  assert.deepEqual([...plan.positions], [0, 1000, 1500]);
});

test('分屏规划：文档不足一屏 → 单屏；视口非法 → 空规划', () => {
  const short = planOf(loadShared(), { innerHeight: 900, scrollHeight: 400, dpr: 1 });
  assert.deepEqual([...short.positions], [0]);
  assert.equal(short.canvasHeight, 900, '文档比视口矮时应按一屏算');

  for (const bad of [0, -1, NaN, undefined]) {
    const empty = planOf(loadShared(), { innerHeight: bad, scrollHeight: 5000, dpr: 1 });
    assert.deepEqual([...empty.positions], [], `innerHeight=${bad} 应给出空规划`);
    assert.equal(empty.canvasHeight, 0);
  }
});

test('分屏规划：dpr 换算画布高度', () => {
  // dpr=2：1000 CSS px 视口 = 2000 设备像素；文档 8000 CSS px → 16000 设备像素。
  const dpr2 = planOf(loadShared(), { innerHeight: 1000, scrollHeight: 8000, dpr: 2 });
  assert.equal(dpr2.canvasHeight, 16000);
  assert.equal(dpr2.truncated, false);
  assert.deepEqual([...dpr2.positions], [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000]);

  // 不足整屏的尾部交给末屏覆盖：文档 4500 → 画布 4500，末屏 3500 覆盖到 4500。
  const tail = planOf(loadShared(), { innerHeight: 1000, scrollHeight: 4500, dpr: 1 });
  assert.equal(tail.canvasHeight, 4500);
  assert.deepEqual([...tail.positions], [0, 1000, 2000, 3000, 3500]);
  assert.equal(tail.positions[tail.positions.length - 1] + 1000, 4500);
});

test('分屏规划：超过上限时截断（丢掉尾部，且末屏对齐画布下沿）', () => {
  // 视口 900、文档 4000、dpr=1，上限 2500 → 上限向下取整到 1800（两整屏）。
  const capped = planOf(loadShared(), {
    innerHeight: 900,
    scrollHeight: 4000,
    dpr: 1,
    maxHeight: 2500,
  });
  assert.equal(capped.truncated, true);
  assert.equal(capped.canvasHeight, 1800, '上限必须向下取整到整屏');
  assert.equal(capped.positions[0], 0);
  const last = capped.positions[capped.positions.length - 1];
  assert.equal(last + 900, 1800, '末屏下沿必须对齐画布下沿');
  assert.equal(new Set(capped.positions).size, capped.positions.length, '分屏位置不得重复');
  // 截断 = 只保留画布装得下的部分：分屏数必须比不截断时少。
  const full = planOf(loadShared(), { innerHeight: 900, scrollHeight: 4000, dpr: 1 });
  assert.equal(full.truncated, false);
  assert.equal(full.canvasHeight, 4000);
  assert.ok(
    capped.positions.length < full.positions.length,
    `截断后分屏数应减少：${capped.positions.length} < ${full.positions.length}`,
  );

  // 上限低于一屏（边界）：画布为 0，不返回任何分屏（调用方据此放弃截图）。
  const tiny = planOf(loadShared(), {
    innerHeight: 1000,
    scrollHeight: 20000,
    dpr: 1,
    maxHeight: 500,
  });
  assert.equal(tiny.canvasHeight, 0, '画布不足一屏时不应拼出残缺画布');
  assert.deepEqual([...tiny.positions], []);
});

// ---- 采集 / 拼接 / 载荷 ----

test('快照采集：逐屏取图 → 按 scrollY*dpr 拼接 → 载荷带 screenshot', async () => {
  const frames = [
    'data:image/jpeg;base64,QUFB',
    'data:image/jpeg;base64,QkJC',
    'data:image/jpeg;base64,Q0ND',
  ];
  const env = loadShared({
    recordCalls: true,
    captureImpl: async (n) => frames[(n - 1) % frames.length],
  });
  seedSession(env);
  // 视口 800、文档 2400 → 三屏：0 / 800 / 1600。
  env.setGeometry({ innerHeight: 800, innerWidth: 600, scrollHeight: 2400, devicePixelRatio: 1 });

  const shot = await env.api.suiCaptureScreenshot(42);
  assert.ok(shot, '正常页面应采到整页截图');
  assert.equal(shot.filename, '整页截图.jpg');

  assert.deepEqual(
    env.captureCalls.map((c) => c.options.format),
    ['jpeg', 'jpeg', 'jpeg'],
  );
  // 三屏 → 相邻两屏之间等 2 次，每次 ≥600ms（captureVisibleTab 每秒 2 次的上限）。
  const sleeps = env.sleepCalls.filter((ms) => ms >= 600);
  assert.equal(sleeps.length, 2);
  for (const ms of sleeps) {
    assert.ok(ms >= 600, `两次取图之间应至少等 600ms，实际 ${ms}`);
  }
  // 画布尺寸：宽 = 视口宽，高 = 文档高（dpr=1 时与 CSS px 等值）。
  assert.equal(env.canvas.width, 600);
  assert.equal(env.canvas.height, 2400);
  // 纵向拼接：第 n 屏画在 scrollY × dpr 处。
  assert.deepEqual(
    env.drawCalls.map((d) => d.dy),
    [0, 800, 1600],
  );
  // 取图后页面停在末屏（可读回）。
  assert.equal(env.page.scrollY, 1600);
});

test('快照载荷：JPEG 经 base64 放进 screenshot 字段（无 FileReader 环境走自带编码器）', async () => {
  const env = loadShared({
    recordCalls: true,
    captureImpl: async () => 'data:image/jpeg;base64,QUFB',
    encodePlan: () => new Uint8Array([65, 65, 65]), // 'AAA'
  });
  seedSession(env);
  env.setGeometry({ innerHeight: 800, innerWidth: 600, scrollHeight: 800, devicePixelRatio: 1 });

  const shot = await env.api.suiCaptureScreenshot(42);
  assert.ok(shot, '单屏页面也应采到整页截图');
  assert.equal(env.canvas.width, 600);
  assert.equal(env.canvas.height, 800);

  await env.api.suiPostClip(
    { url: 'https://page.example', title: 't', html: '<p>h</p>' },
    'snapshot',
    shot,
  );
  const body = lastClipBody(env);
  assert.equal(body.mode, 'snapshot');
  assert.equal(body.screenshot.filename, '整页截图.jpg');
  assert.equal(Buffer.from(body.screenshot.dataBase64, 'base64').toString('utf8'), 'AAA');
});

test('载荷闸门：base64 超 5 MiB → 按 80 → 60 重编码；三档都超限则放弃截图', async () => {
  // 第 1 档（q=0.80）给 4 MiB 原始字节（base64 ≈ 5.33 MiB，超闸门），第 2 档（q=0.60）给 1 MiB。
  const env = loadShared({
    captureImpl: async () => 'data:image/jpeg;base64,QUFB',
    encodePlan: (quality) => new Uint8Array(quality === 0.8 ? 4 * MiB : 1 * MiB),
  });
  env.setGeometry({ innerHeight: 900, innerWidth: 600, scrollHeight: 900, devicePixelRatio: 1 });

  const shot = await env.api.suiCaptureScreenshot(1);
  assert.ok(shot, '降质量后应落回闸门内');
  assert.deepEqual(env.qualityCalls, [0.8, 0.6], '应先试 80，超限再降 60');
  assert.equal(Buffer.from(shot.dataBase64, 'base64').length, 1 * MiB, '发出的应是降质量后的那一份');

  // 三档都超限 → 静默放弃。
  const heavy = loadShared({
    captureImpl: async () => 'data:image/jpeg;base64,QUFB',
    encodePlan: () => new Uint8Array(4 * MiB),
  });
  heavy.setGeometry({ innerHeight: 900, innerWidth: 600, scrollHeight: 900, devicePixelRatio: 1 });
  assert.equal(await heavy.api.suiCaptureScreenshot(1), null);
  assert.deepEqual(heavy.qualityCalls, [0.8, 0.6, 0.45], '应把三档都试一遍');
});

test('降级：captureVisibleTab 抛错 → 静默放弃，剪藏照常且文案不变', async () => {
  const env = loadShared(true); // 不提供 captureImpl → 取图抛错（未授权）
  seedSession(env);
  env.setGeometry({ innerHeight: 800, innerWidth: 600, scrollHeight: 2400, devicePixelRatio: 1 });

  const shot = await env.api.suiCaptureScreenshot(7);
  assert.equal(shot, null, '截图失败必须返回 null（绝不抛给调用方）');

  const data = await env.api.suiPostClip(
    { url: 'https://page.example', title: 't', html: '<p>h</p>' },
    'snapshot',
    shot,
  );
  const body = lastClipBody(env);
  assert.equal('screenshot' in body, false, '没截到就不许出现 screenshot 字段');
  // 无截图 → 文案与既有断言**逐字符一致**。
  assert.equal(env.api.suiBuildResultMessage(data), `剪藏成功 v${data.version}`);
});

test('降级：总耗时超过 20s 上限 → 放弃截图（不再继续取图）', async () => {
  // 用**真实时钟**验证总耗时上限：页面很高（8000/800 = 10 屏可用），取图恒慢 1.8s。
  // 采集节奏 = 600ms（速率闸门）+ 1800ms（取图）= 2.4s/屏 → 第 9 屏前累计 21.6s > 20s，放弃。
  // 注入 `Date.now` 的假时钟在 vm 上下文里行为不可靠，故这里不依赖它。
  const env = loadShared({
    captureImpl: async () => {
      await new Promise((resolve) => setTimeout(resolve, 1800));
      return 'data:image/jpeg;base64,QUFB';
    },
  });
  const before = env.captureCalls.length;
  env.setGeometry({ innerHeight: 800, innerWidth: 600, scrollHeight: 640000, devicePixelRatio: 1 });

  assert.equal(await env.api.suiCaptureScreenshot(1), null, '超时应放弃截图');
  const taken = env.captureCalls.length - before;
  // 上界：21.6s 时放弃 → 最多 9 屏；下界：15s 前不可能放弃 → 至少 7 屏。
  assert.ok(taken >= 7 && taken <= 9, `实际取图 ${taken} 屏，应落在 7~9 之间`);
  assert.equal(env.qualityCalls.length, 0, '放弃时不应再编码');
});

// ---- popup.js 真实流程的模式闸门 ----

test('popup 流程闸门：article 模式一次都不截；snapshot 模式才截', async () => {
  // article：不得出现任何 captureVisibleTab 调用，且请求体无 screenshot。
  const article = await runPopupClip('article');
  assert.equal(article.captureCalls.length, 0, 'article 模式不得调用 captureVisibleTab');
  assert.equal('screenshot' in article.body, false);
  assert.equal(article.status, '✓ 剪藏成功 v1');

  // snapshot：每屏取图一次（视口 800 / 文档 2400 → 3 屏），请求体带 screenshot，文案带附注。
  const snapshot = await runPopupClip('snapshot');
  assert.equal(snapshot.captureCalls.length, 3, 'snapshot 模式应逐屏取图');
  assert.equal(snapshot.body.screenshot.filename, '整页截图.jpg');
  assert.equal(snapshot.status, '✓ 剪藏成功 v1（含整页截图）');
});

// ---- 结果文案 ----

test('结果文案：带截图才追加「含整页截图」，不破坏既有「未本地化」附注', () => {
  const env = loadShared();
  const msg = env.api.suiBuildResultMessage;

  assert.equal(msg({ version: 3 }), '剪藏成功 v3');
  assert.equal(msg({ version: 3, unlocalizedImages: 2 }), '剪藏成功 v3（2 张图片未本地化）');
  assert.equal(msg({ version: 3, screenshotCaptured: true }), '剪藏成功 v3（含整页截图）');
  assert.equal(
    msg({ version: 3, unlocalizedImages: 2, screenshotCaptured: true }),
    '剪藏成功 v3（2 张图片未本地化，含整页截图）',
  );
  // 没截到（未设置该标志）→ 与旧文案一致，不误报。
  assert.equal(msg({ version: 3, unlocalizedImages: 0 }), '剪藏成功 v3');
});

/// runPopupClip 在带 DOM 桩的沙箱里跑 `popup.js` 的**真实** handleClip 流程。
///
/// 与真机路径一致：DOMContentLoaded 里取当前标签页 → 点「剪藏」→ 采集 DOM →
/// （仅 snapshot）采集整页截图 → `suiPostClip` 上行 → 回填状态文案。
async function runPopupClip(mode) {
  const elements = new Map();
  const clipHandlers = [];
  const capturedTab = { id: 11, title: '测试页', url: 'https://page.example' };

  const store = new Map();
  const calls = [];
  const captureCalls = [];
  const sleepCalls = [];
  const page = { innerWidth: 600, innerHeight: 800, devicePixelRatio: 1, scrollHeight: 2400, scrollY: 0 };

  const el = (id) => {
    if (!elements.has(id)) {
      elements.set(id, {
        id,
        textContent: '',
        className: '',
        disabled: false,
        classList: { toggle: () => {}, add: () => {}, remove: () => {} },
        addEventListener: (type, cb) => {
          if (id === 'clipBtn' && type === 'click') clipHandlers.push(cb);
        },
      });
    }
    return elements.get(id);
  };

  const local = {
    get: async (keys) => {
      const list = Array.isArray(keys) ? keys : [keys];
      const out = {};
      for (const k of list) if (store.has(k)) out[k] = store.get(k);
      return out;
    },
    set: async (obj) => {
      for (const [k, v] of Object.entries(obj)) store.set(k, v);
    },
    remove: async () => {},
  };

  const canvasStub = {
    width: 0,
    height: 0,
    getContext: () => ({ drawImage: () => {} }),
    toBlob: (cb) => cb(makeBlob(new Uint8Array([9, 9, 9]))),
  };

  const { windowStub, documentStub } = pageGlobals(page);
  windowStub.close = () => {};

  const sandbox = {
    console,
    URL,
    Uint8Array,
    Promise,
    // 沙箱内自有包装：可观测节奏，同时用真实定时器保证 600ms 间距真的被等到。
    setTimeout: (fn, ms) => {
      sleepCalls.push(Number(ms) || 0);
      return setTimeout(fn, ms);
    },
    clearTimeout: (id) => clearTimeout(id),
    requestAnimationFrame: (fn) => setTimeout(fn, 0),
    OffscreenCanvas: function OffscreenCanvas(w, h) {
      canvasStub.width = w;
      canvasStub.height = h;
      return canvasStub;
    },
    createImageBitmap: async () => ({ close() {} }),
    location: { href: capturedTab.url },
    document: Object.assign(documentStub, {
      getElementById: el,
      addEventListener: (type, cb) => {
        if (type === 'DOMContentLoaded') sandbox.__ready = cb;
      },
    }),
    fetch: async (url, init) => {
      calls.push({ url: String(url), init });
      if (String(url).startsWith('data:')) {
        return { blob: async () => makeBlob(decodeDataUrl(String(url))) };
      }
      if (String(url).endsWith('/api/v1/clips')) {
        return jsonResponse(200, { ok: true, version: 1, unlocalizedImages: 0, mode });
      }
      return jsonResponse(200, { ok: true });
    },
    window: windowStub,
    chrome: {
      storage: { local },
      runtime: {
        getManifest: () => ({ version: '0.14.0' }),
        openOptionsPage: () => {},
      },
      tabs: {
        async query() {
          return [capturedTab];
        },
        async captureVisibleTab(windowId, options) {
          captureCalls.push({ windowId, options });
          return 'data:image/jpeg;base64,QUFB';
        },
      },
      scripting: {
        async executeScript({ func, args }) {
          // 同一个注入函数被两处使用：suiCaptureInPage（无参）与 suiScrollToInPage（滚动位置）。
          return [{ result: await func(args && args.length ? args[0] : undefined) }];
        },
      },
    },
  };

  vm.createContext(sandbox);
  vm.runInContext(sharedSrc, sandbox);
  vm.runInContext(popupSrc, sandbox);

  // 预置会话与「上次模式」，然后走真实的初始化钩子。
  store.set('serverUrl', 'http://h');
  store.set('accessToken', 'A1');
  store.set('refreshToken', 'R1');
  store.set('accessExpiresAt', Date.now() + 3600 * 1000);
  store.set('lastMode', mode);
  await sandbox.__ready();
  await drain();

  assert.equal(clipHandlers.length, 1, 'popup.js 应注册 clipBtn 点击回调');
  await clipHandlers[0]();
  await drain();

  const clipCall = calls.filter((c) => String(c.url).endsWith('/api/v1/clips')).pop();
  assert.ok(clipCall, '期望发出过一次剪藏请求');
  return {
    body: JSON.parse(clipCall.init.body),
    captureCalls,
    sleepCalls,
    status: el('status').textContent,
  };
}

/// drain 让挂起的微任务跑完（链式 await 需要多轮）。
async function drain() {
  for (let i = 0; i < 10; i += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
}
