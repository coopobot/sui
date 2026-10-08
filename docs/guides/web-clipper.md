# 网页剪藏

随手记 Sui 提供 Chrome / Edge 扩展，一键把网页保存为 Markdown 笔记，自动进入「收件箱」。
支持两种模式：**智能提取正文**（默认）与**全页快照**——后者会把整页内容（尤其图片）
本地化入库，即便原网页下线，笔记内容也不受影响。本页同时面向**使用者**与**扩展开发者**。

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

> **M10 起**：服务端地址与令牌保存在 `chrome.storage.local`——**不再随浏览器账号同步离开本机**。
>
> 站点访问权限也改为**按需申请**：首次对某个站点剪藏时会弹出授权提示，授予后该站点长期可用；
> 未授予时扩展不会也无法读取页面内容（不再申请「所有站点」的静态权限）。

## 3. 使用剪藏

两种方式：

| 方式 | 操作 | 效果 |
|------|------|------|
| 一键剪藏 | 点击工具栏扩展图标 → 选择模式 →「剪藏此页面」 | 按所选模式保存当前网页 |
| 右键剪藏 | 在页面 / 选中文字 / 链接上右键 →「剪藏到随手记 Sui」 | 按**上次使用的模式**保存 |

### 3.1 两种剪藏模式

剪藏前可在弹窗中切换模式（分段控件），选择会被记住，下次默认沿用：

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| **智能提取正文**（`article`，默认） | 类 Readability 净化：剔除导航、广告、页脚等噪声，只留正文 | 文章、博客、资讯等以正文为主的内容 |
| **全页快照**（`snapshot`） | 保留整页结构与文档顺序（标题 / 表格 / 图注等按序呈现），产出**语义等价**的 Markdown | 需要完整留档、正文提取不理想、或页面结构本身就是重点 |

> 「全页快照」追求**语义等价**（结构、顺序、图文关系保留），不追求逐像素还原版式。

### 3.2 图片本地化（离线可读）

无论哪种模式，剪藏时都会**尽量把图片本地化**到服务端附件库：

1. 扩展采集页面（对 `article` 与 `snapshot` 一致）：等待完整 DOM、触发懒加载图片。
2. 服务端按优先级取图地址（`src` → `data-src` / `data-original` / `data-lazy-src` → `srcset` 最大图），
   相对地址按页面 URL 解析为绝对地址。
3. 逐张下载图片 → 以 `sha256` 内容寻址存入附件库 → 正文图片引用改写为 `sui://<sha256>`。
4. 本地化失败的图片**降级保留其绝对外链**，不阻断整篇剪藏，并在完成提示中回带
   **「N 张图片未本地化」**。

这样即使原网页下线，已本地化的图片仍可从附件库读取（离线可读）。

> 阈值（可通过 `clip.Options` 覆盖）：单图字节上限 **10 MiB**、单篇最多本地化 **200** 张、
> 总时长上限 **30s**、单图下载超时 **10s**。超出的图片按「降级保留绝对 URL」处理。

### 3.3 剪藏流程

1. 扩展抓取页面完整 HTML（含懒加载图片）发送到服务端。
2. 服务端按所选模式净化：`article` 提取正文 / `snapshot` 保留整页结构，转 Markdown。
3. 正文内的图片尽量本地化，失败者保留绝对 URL；正文开头附来源链接。
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
| `manifest.json` | MV3 清单：权限（activeTab / storage / scripting / contextMenus）+ **`optional_host_permissions`（`http/https`，按需申请）** |
| `shared.js` | 共享逻辑：设置读取、模式记忆、整页采集（懒加载触发）、剪藏请求与结果文案（popup 与 service worker 共用） |
| `popup.html/js` | 弹窗：模式分段控件 + 当前页信息 + 剪藏按钮 + 状态反馈 |
| `options.html/js` | 设置页：serverUrl + token 配置 + 连接验证（`chrome.storage.local`） |
| `background.js` | service worker：右键菜单创建 + 菜单剪藏（沿用上次模式）+ badge 状态 |

### 4.3 剪藏数据流

```
popup/background
  → chrome.scripting.executeScript（shared.js 的采集函数）
      · img.loading = eager；用 data-src/data-original/data-lazy-src 回填 src
      · 滚动整页触发 IntersectionObserver 懒加载；有界等待待加载图片
  → POST {serverUrl}/api/v1/clips  {url, title, html, mode} + Bearer token
  → 服务端 clip：按 mode 净化（article 提正文 / snapshot 保整页结构）
  → 图片本地化：下载 → sha256 → blob.Put → 正文改 sui://；失败降级保留绝对 URL
  → 以 url 哈希为幂等键 upsert 笔记（source_device=clip:web-extension）
  → 响应回带未本地化图片数 → 扩展提示「剪藏成功 vN（M 张图片未本地化）」
  → WebSocket 广播 changed → 客户端收件箱自动刷新
```

### 4.4 添加图标（可选）

manifest 可声明 `action.default_icon` / `icons`；生成 16/32/48/128px PNG 放入
`extension/icons/` 并在 manifest 引用。

## 5. 相关

- 接口定义见 [API 参考 · 剪藏](../api-reference.md#端点清单)。
- 净化引擎实现在 `server/internal/clip`，设计见 [系统架构](../architecture.md)。
