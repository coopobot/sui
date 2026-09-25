# 网页剪藏

随手记 Sui 提供 Chrome / Edge 扩展，一键把网页正文净化后保存为 Markdown 笔记，
自动进入「收件箱」。本页同时面向**使用者**与**扩展开发者**。

## 1. 安装（Chrome / Edge）

1. 打开浏览器扩展管理页：
   - Chrome：地址栏输入 `chrome://extensions`
   - Edge：地址栏输入 `edge://extensions`
2. 打开右上角「开发者模式」开关。
3. 点击「加载已解压的扩展程序」，选择项目中的 `extension/` 目录。
4. 工具栏出现「随手记 Sui」图标即安装成功。

## 2. 配置服务端

1. 右键扩展图标 →「选项」。
2. 填写：
   - **服务端地址**：如 `http://192.168.1.10:8080`
   - **访问 Token**：注册账号时获得的 token
3. 点击保存，自动验证连接；显示「✓ 设置已保存」即可使用。

> 配置保存在浏览器 `storage.sync`，同一浏览器账号多台设备间自动同步。

## 3. 使用剪藏

两种方式：

| 方式 | 操作 | 效果 |
|------|------|------|
| 一键剪藏 | 点击工具栏扩展图标 →「剪藏此页面」 | 保存当前整个网页 |
| 右键剪藏 | 在页面 / 选中文字 / 链接上右键 →「剪藏到随手记 Sui」 | 保存页面或所选内容 |

剪藏流程：

1. 扩展抓取页面完整 HTML 发送到服务端。
2. 服务端类 Readability 净化：剔除导航、广告、页脚等噪声，提取正文。
3. HTML 自动转换为 Markdown，正文开头附来源链接。
4. 以**网页 URL 为幂等键**：同一网页重复剪藏会更新同一篇笔记，不会产生重复。
5. 笔记自动进入客户端的「收件箱」，来源标记为剪藏（`source_device=clip:web-extension`）。

> 提示：重复剪藏同一网页 = 更新原文，可在客户端收件箱查看历史版本找回旧内容。

## 4. 开发与调试

### 4.1 加载调试

1. Chrome → `chrome://extensions` → 开发者模式 →「加载已解压的扩展程序」→ 选择 `extension/`。
2. 右键扩展图标 →「检查」打开 DevTools 调试 popup / background。
3. 改代码后在扩展管理页点「重新加载」。

### 4.2 模块说明

| 文件 | 职责 |
|------|------|
| `manifest.json` | MV3 清单：权限（activeTab / storage / scripting / contextMenus） |
| `popup.html/js` | 弹窗：显示当前页信息 + 剪藏按钮 + 状态反馈 |
| `options.html/js` | 设置页：serverUrl + token 配置 + 连接验证（`storage.sync`） |
| `background.js` | service worker：右键菜单创建 + 菜单剪藏 + badge 状态 |

### 4.3 剪藏数据流

```
popup/background
  → chrome.scripting.executeScript 取 document.documentElement.outerHTML
  → POST {serverUrl}/api/v1/clips  {url, title, html} + Bearer token
  → 服务端 clip.Purify：Readability 选主内容 + HTML→Markdown
  → 以 url 哈希为幂等键 upsert 笔记（source_device=clip:web-extension）
  → WebSocket 广播 changed → 客户端收件箱自动刷新
```

### 4.4 添加图标（可选）

manifest 可声明 `action.default_icon` / `icons`；生成 16/32/48/128px PNG 放入
`extension/icons/` 并在 manifest 引用。

## 5. 相关

- 接口定义见 [API 参考 · 剪藏](../api-reference.md#端点清单)。
- 净化引擎实现在 `server/internal/clip`，设计见 [系统架构](../architecture.md)。
