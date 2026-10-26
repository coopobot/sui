// M12 修订（v0.12.2 / FR-57）剪藏扩展「会话层」自动化门禁。
//
// 运行：`node --test extension/test/session_test.mjs`（Node ≥ 18，无需任何依赖）
//
// 覆盖：
//   - 登录成功后把双令牌写入 `chrome.storage.local`，**不保留口令**（AC-210 / AC-214）；
//   - 登录失败统一「用户名或密码错误」、锁定读 `Retry-After`（AC-210 / FR-59 文案）；
//   - 访问令牌即将过期 → **主动刷新**（AC-212）；
//   - 401（`token-expired` / `invalid_token`）→ **单飞刷新 + 重放一次**（AC-212）；
//   - 并发请求只触发**一次**刷新（单飞，协议要求：刷新令牌单次使用）（AC-212）；
//   - 刷新被拒 → 清令牌、抛「登录已失效，请重新登录」、**保留 serverUrl**（AC-213 / AC-214）；
//   - 未登录 → 明确提示先登录（AC-210）；
//   - `http://` 公网地址给出明文警示，本机 / 私网与 `https://` 不警示（AC-215 / BR-57.6）；
//   - 剪藏请求携带会话令牌与所选模式。
//
// 说明：`shared.js` 不是 ES 模块（走 `<script src>` / `importScripts`），
// 故用 `node:vm` 在带 stub 的沙箱里求值，再调用其顶层函数声明。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const sharedSrc = fs.readFileSync(path.join(here, '..', 'shared.js'), 'utf8');

/// 构造 HTTP 响应桩（含 shared.js 用到的 `ok` / `status` / `headers.get` / `json` / `text` / `clone`）。
function jsonResponse(status, body, headers = {}) {
  const resp = {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (k) => (k.toLowerCase() in headers ? headers[k.toLowerCase()] : null) },
    json: async () => body,
    text: async () => JSON.stringify(body),
    clone: () => resp,
  };
  return resp;
}

/// 在沙箱中加载 `shared.js`，并返回 stub（storage / fetch 调用记录 / 可控时钟）。
function loadShared({ fetchImpl }) {
  const store = new Map();
  const calls = [];
  let now = 1_000_000;

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

  class FakeDate extends Date {
    static now() {
      return now;
    }
  }

  const sandbox = {
    chrome: { storage: { local } },
    console,
    Date: FakeDate,
    URL,
    Promise,
    setTimeout,
    clearTimeout,
    fetch: async (url, init) => {
      calls.push({ url, init });
      return fetchImpl(url, init);
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(sharedSrc, sandbox);

  return {
    api: sandbox,
    store,
    calls,
    advance: (ms) => {
      now += ms;
    },
  };
}

/// 预置一个「已登录」的会话。
function seedSession(env, { accessToken = 'A1', refreshToken = 'R1', expiresInMs = 10 * 60 * 1000 } = {}) {
  env.store.set('serverUrl', 'http://h');
  env.store.set('username', 'u1');
  env.store.set('accessToken', accessToken);
  env.store.set('refreshToken', refreshToken);
  env.store.set('accessExpiresAt', 1_000_000 + expiresInMs);
}

test('登录：双令牌写入 storage.local，口令不落盘（AC-210 / AC-214）', async () => {
  const env = loadShared({
    fetchImpl: async (url, init) => {
      assert.equal(url, 'http://localhost:8080/api/v1/login');
      assert.deepEqual(JSON.parse(init.body), { username: 'u1', password: 'pw-secret' });
      return jsonResponse(200, {
        ok: true,
        access_token: 'A1',
        refresh_token: 'R1',
        expires_in: 1800,
      });
    },
  });

  await env.api.suiLogin('http://localhost:8080/', 'u1', 'pw-secret');

  assert.equal(env.store.get('accessToken'), 'A1');
  assert.equal(env.store.get('refreshToken'), 'R1');
  assert.equal(env.store.get('username'), 'u1');
  assert.equal(env.store.get('serverUrl'), 'http://localhost:8080'); // 去尾斜杠
  assert.equal(env.store.get('accessExpiresAt'), 1_000_000 + 1800 * 1000);
  // 口令**绝不**落盘（BR-57.2）
  for (const value of env.store.values()) {
    assert.ok(!String(value).includes('pw-secret'), `storage 中出现口令：${value}`);
  }
  assert.equal(await env.api.suiIsLoggedIn(), true);
});

test('登录失败：统一文案；429 读出 Retry-After（AC-210）', async () => {
  const bad = loadShared({
    fetchImpl: async () => jsonResponse(401, { ok: false, error: 'invalid credentials' }),
  });
  await assert.rejects(
    () => bad.api.suiLogin('http://h', 'u1', 'x'),
    /用户名或密码错误/,
  );

  const locked = loadShared({
    fetchImpl: async () =>
      jsonResponse(429, { ok: false, error: 'too-many-attempts' }, { 'retry-after': '42' }),
  });
  await assert.rejects(() => locked.api.suiLogin('http://h', 'u1', 'x'), /42 秒后重试/);
});

test('访问令牌即将过期 → 主动刷新后再请求（AC-212）', async () => {
  const env = loadShared({
    fetchImpl: async (url) => {
      if (url.endsWith('/api/v1/refresh')) {
        return jsonResponse(200, {
          ok: true,
          access_token: 'A2',
          refresh_token: 'R2',
          expires_in: 1800,
        });
      }
      return jsonResponse(200, { ok: true });
    },
  });
  seedSession(env, { expiresInMs: 10 * 1000 }); // 余量不足 60s

  const resp = await env.api.suiApiFetch('/api/v1/sync/pull?since=x');
  assert.equal(resp.status, 200);
  assert.deepEqual(
    env.calls.map((c) => c.url),
    ['http://h/api/v1/refresh', 'http://h/api/v1/sync/pull?since=x'],
  );
  assert.equal(env.calls[1].init.headers.Authorization, 'Bearer A2');
  assert.equal(env.store.get('refreshToken'), 'R2'); // 轮换后的刷新令牌已落盘
});

test('401 token-expired → 单飞刷新并重放一次（AC-212）', async () => {
  const env = loadShared({
    fetchImpl: async (url, init) => {
      if (url.endsWith('/api/v1/refresh')) {
        return jsonResponse(200, {
          ok: true,
          access_token: 'A2',
          refresh_token: 'R2',
          expires_in: 1800,
        });
      }
      if (init.headers.Authorization === 'Bearer A1') {
        return jsonResponse(401, { ok: false, error: 'token-expired' });
      }
      return jsonResponse(200, { ok: true, version: 7 });
    },
  });
  seedSession(env);

  const resp = await env.api.suiApiFetch('/api/v1/clips', { method: 'POST' });
  assert.equal(resp.status, 200);
  assert.equal(env.calls.filter((c) => c.url.endsWith('/api/v1/refresh')).length, 1);

  const clips = env.calls.filter((c) => c.url.endsWith('/api/v1/clips'));
  assert.equal(clips.length, 2, '原请求应被重放一次');
  assert.equal(clips[1].init.headers.Authorization, 'Bearer A2');
  assert.equal(clips[0].init.headers.Authorization, 'Bearer A1');
});

test('并发请求只触发一次刷新（单飞；刷新令牌单次使用）（AC-212）', async () => {
  let refreshCount = 0;
  const env = loadShared({
    fetchImpl: async (url) => {
      if (url.endsWith('/api/v1/refresh')) {
        refreshCount += 1;
        await new Promise((resolve) => setTimeout(resolve, 10)); // 制造并发窗口
        return jsonResponse(200, {
          ok: true,
          access_token: 'A2',
          refresh_token: 'R2',
          expires_in: 1800,
        });
      }
      return jsonResponse(200, { ok: true });
    },
  });
  seedSession(env, { expiresInMs: 5 * 1000 }); // 三个请求都会想刷新

  await Promise.all([1, 2, 3].map(() => env.api.suiApiFetch('/api/v1/sync/pull?since=x')));
  assert.equal(refreshCount, 1, `刷新次数应为 1，实际 ${refreshCount}`);
});

test('刷新被拒 → 清令牌、提示重新登录、保留 serverUrl（AC-213 / AC-214）', async () => {
  const env = loadShared({
    fetchImpl: async (url) => {
      if (url.endsWith('/api/v1/refresh')) {
        return jsonResponse(401, { ok: false, error: 'refresh-revoked' });
      }
      return jsonResponse(401, { ok: false, error: 'token-expired' });
    },
  });
  seedSession(env);

  await assert.rejects(
    () => env.api.suiApiFetch('/api/v1/clips', { method: 'POST' }),
    /登录已失效，请重新登录/,
  );
  assert.equal(env.store.has('accessToken'), false);
  assert.equal(env.store.has('refreshToken'), false);
  assert.equal(env.store.get('serverUrl'), 'http://h', 'serverUrl 必须保留以便重新登录');
  assert.equal(await env.api.suiIsLoggedIn(), false);
});

test('未登录 → 明确提示先登录（AC-210）', async () => {
  const env = loadShared({ fetchImpl: async () => jsonResponse(200, {}) });
  env.store.set('serverUrl', 'http://h');
  await assert.rejects(() => env.api.suiApiFetch('/api/v1/clips'), /请先在设置中登录/);

  const noUrl = loadShared({ fetchImpl: async () => jsonResponse(200, {}) });
  noUrl.store.set('serverUrl', ''); // 显式清空（suiGetSession 缺省回落 localhost）
  await assert.rejects(() => noUrl.api.suiApiFetch('/api/v1/clips'), /请先在设置中填写服务端地址/);
});

test('明文地址警示：公网 http 警示；本机 / 私网 / https 不警示（AC-215 / BR-57.6）', () => {
  const env = loadShared({ fetchImpl: async () => jsonResponse(200, {}) });
  const warn = env.api.suiPlaintextWarning;

  assert.equal(warn('https://note.example.com'), '');
  assert.equal(warn('http://localhost:8080'), '');
  assert.equal(warn('http://127.0.0.1:8080'), '');
  assert.equal(warn('http://192.168.1.10:8080'), '');
  assert.equal(warn('http://10.0.0.5:8080'), '');
  assert.equal(warn('http://172.16.0.9:8080'), '');
  assert.match(warn('http://note.example.com'), /https/);
});

test('剪藏请求携带会话令牌与所选模式（FR-57）', async () => {
  const env = loadShared({
    fetchImpl: async () => jsonResponse(200, { ok: true, version: 3, unlocalizedImages: 1 }),
  });
  seedSession(env);

  const data = await env.api.suiPostClip(
    { url: 'https://page.example', title: 't', html: '<p>h</p>' },
    'snapshot',
  );
  assert.equal(data.version, 3);
  assert.match(env.api.suiBuildResultMessage(data), /1 张图片未本地化/);

  const call = env.calls.find((c) => c.url.endsWith('/api/v1/clips'));
  assert.equal(call.init.headers.Authorization, 'Bearer A1');
  const body = JSON.parse(call.init.body);
  assert.equal(body.mode, 'snapshot');
  assert.equal(body.url, 'https://page.example');
});
