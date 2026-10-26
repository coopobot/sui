import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const read = (f) => readFileSync(join(root, f), 'utf8');

test('选择正文：popup 有入口并发送启动消息', () => {
  const html = read('popup.html');
  const js = read('popup.js');
  assert.match(html, /id="selectBtn"/);
  assert.match(html, /选择正文区域剪藏/);
  assert.match(js, /sui-start-selection-clip/);
  assert.match(js, /startSelectionClip/);
});

test('选择正文：background 注册菜单 / 选择器 / 结果消息', () => {
  const js = read('background.js');
  assert.match(js, /sui-clip-selection/);
  assert.match(js, /suiPickContentInPage/);
  assert.match(js, /sui-selection-result/);
  assert.match(js, /sui-selection-cancel/);
  // 只保留祖先链：按 body → 选中元素的 childIndex 路径裁剪兄弟节点
  assert.match(js, /path\.unshift/);
  assert.match(js, /clone\.querySelectorAll\('\[data-sui-picker\]'\)/);
});

test('选择正文：快照仍保留 stylesheet link 交给服务端内联', () => {
  const js = read('shared.js');
  const m = js.match(/const drop = '([^']+)'/);
  assert.ok(m, 'shared.js 应有 drop 列表');
  assert.ok(!m[1].split(',').includes('link'), 'drop 列表不能包含 link');
});
