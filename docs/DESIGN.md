- Go 服务端：`cmd/sui-server`（健康检查 `/healthz` + 心跳 `/api/v1/ping`，含测试），优雅启停。
- Flutter 客户端壳：连接服务端健康检查的界面，web 目标可构建 + widget 测试。
- monorepo 工程：顶层 `Makefile` / `README` / `.gitignore`；CI 尚未配置（唯一缺口）。

**M1 核心本地笔记 ✅**
- ✅ `clients/note_core`（纯 Dart 包）：数据模型（Note/Notebook/Tag/Attachment/Revision）、drift 数据库（6 表 SQLite schema）、`BlobStore` 抽象 + `LocalBlobStore`。
- ✅ `NoteRepository`：笔记本树 CRUD、标签（多对多）、笔记 CRUD、修订历史追加、标题/正文关键字搜索、软删除墓碑、归档/置顶。
- ✅ 12 个单元测试全部通过；`dart analyze` 无问题。
- ✅ **编辑器接入（M1 实现）**：Markdown 源码「编辑」+ 预览「所见即所得」双轨（`flutter_markdown` 渲染），正本恒为 Markdown；`EditorBridge` 语义内建于仓储，编辑器可后续升级富文本。
- ✅ **Flutter UI 接入**（`note_shell`）：响应式三栏（笔记本树 / 笔记列表 / 编辑区），窄屏抽屉 + 导航堆栈；笔记本树（嵌套）、标签、搜索、置顶/删除、Markdown 双轨编辑；provider 状态管理 + `AppController`。widget 测试（2）通过。
- 备注：Dart SQLite 依赖 `libsqlite3.so`，WSL 建 symlink（`~/.local/lib`），见 `clients/note_core/README`。
- 说明：编辑器当前为「Markdown 源码 + 预览」双轨（稳定、无实验性转换风险）；`flutter_quill`/`markdown_quill` 富文本 WYSIWYG 升级列为后续可选增强（§8.0 已记风险）。

**M2 多端同步 ✅**
- ✅ **Go 服务端**：SQLite 元数据（notes/revisions/blobs/users）+ 本地磁盘 Blob 存储（sha256 分片 + 引用计数 + GC）+ Bearer token 鉴权 + 增量同步 API（`/sync/push`、`/sync/pull`、`/blobs/{hash}`）。
- ✅ **冲突判定**：服务端以 `base_version` 撞车为唯一依据；一致则直接应用并 version+1，不一致则返回冲突（serverVersion），客户端本地合并后重发。符合设计 §6.4/§6.6。
- ✅ **Dart 同步引擎（note_core）**：`SyncClient` + Outbox（按笔记合并成一条）+ 增量 pull + 冲突本地合并（启发式标题 + 正文冲突标记 + 双版本保留，绝不丢字）+ 重发机制。
- ✅ **测试**：服务端 Go 单测（4 个用例：ping/health、push+pull、冲突、鉴权）通过；note_core 单测 16 个 + e2e 端到端 1 个（注册→双端 push/pull→冲突合并→重发成功）全部通过。
- ✅ **架构**：服务端 Store/Sync/Blob 分层，客户端 SyncClient 通过 `http.Client` 注入（测试可 mock）。
- 说明：WebSocket 实时通知、附件字节同步（仅 API 已接，客户端侧待接）归到 M5 多端打磨。

**M3 修订历史 ✅**
- ✅ **服务端**：revisions 表补全 title 字段；新增 `ListRevisions` / `GetRevision` 数据访问；新增 REST API（`GET /notes/{id}/revisions` 列表、`GET /notes/{id}/revisions/{version}` 详情）。
- ✅ **客户端 note_core**：revisions 表 schema v2 升级（新增 title 列 + 迁移）；`Revision` 模型补全 title；`NoteRepository` 新增 `getRevision` / `restoreRevision`（恢复=以旧内容创建新版本，不重写历史）；`SyncClient` 新增 `fetchRemoteRevisions` / `fetchRemoteRevision` 远程拉取。
- ✅ **Flutter UI**：`RevisionPanel` 侧栏（修订列表 + 版本详情预览 + 一键恢复确认）；`AppController` 增加面板显隐状态；编辑器工具栏新增「历史」按钮；恢复后编辑器内容自动刷新（版本号检测）。
- ✅ **测试**：服务端 Go 测试（6 个：新增 TestRevisionListAndGet）通过；note_core 17 个测试全部通过；flutter analyze 无问题。
- 说明：Diff 展示采用「选中版本 Markdown 预览」方式；行级 diff 高亮为 M5 可选增强。

**M4 网页剪藏 ✅**
- ✅ **服务端剪藏 API**：`POST /api/v1/clips` 接收 URL+HTML，自动净化为 Markdown，以 URL 为幂等键创建/更新笔记（source_device="clip:web-extension"）。
- ✅ **HTML 净化引擎**（`internal/clip`）：类 Readability 启发式（剔除 nav/footer/aside 噪声，按文本密度选主内容块），HTML → Markdown 转换（标题/段落/列表/链接/粗斜体/图片/引用/代码块）。
- ✅ **Chrome MV3 扩展**：弹窗剪藏 + 右键菜单 + 服务端/Token 设置页（含连接验证）；`chrome.scripting` 注入取页面完整 HTML；`chrome.storage.sync` 保存配置。
- ✅ **客户端收件箱**：笔记本树顶部「收件箱」入口，按 `sourceDevice` 前缀过滤剪藏笔记；列表项显示「剪藏」标签；支持与正常笔记一样的编辑/同步。
- ✅ **测试**：服务端 Go 测试（7 个：新增 TestClipEndpoint 覆盖净化、幂等、同步集成）通过；flutter analyze 零问题。

**M5 多端打磨 & 性能优化 ✅**
- ✅ **CORS 中间件**（`internal/cors`）：支持跨域调用，方便 Web 客户端和浏览器扩展直连。
- ✅ **Blob 下载接口**：`GET /api/v1/blobs/{hash}` 返回附件二进制流，补全 Blob CRUD。
- ✅ **WebSocket 实时通知**（`internal/ws`）：`GET /api/v1/ws` 端点，push/剪藏成功后广播 `{"type":"changed"}`，客户端可据此主动触发 pull。
- ✅ **登录接口**：`POST /api/v1/login` 支持用户登录并返回新 token（与 register 对称）。
- ✅ **source_device 同步**：notes 表新增 `source_device` 列，pull 响应携带，客户端同步时保留剪藏来源标记，收件箱跨端一致。
- ✅ **性能索引**：新增 `idx_revisions_note_ver`（修订快速定位）、`idx_notes_isdel`（过滤已删除+按时间排序）。
- ✅ **Markdown 导出**：编辑器工具栏新增「导出」按钮，一键复制完整 Markdown（含标题）到剪贴板。
- ✅ **测试**：服务端 Go 测试 7/7 通过；flutter analyze 零问题。

---

## 项目总结

**随手记 Sui** — 一个极简、离线优先、支持多端同步的 Markdown 笔记应用。

### 技术栈
| 层级 | 技术 |
|------|------|
| 客户端 | Flutter（跨平台：Android/iOS/Windows/macOS/Linux/Web） |
| 状态管理 | Provider |
| 本地存储 | SQLite + Moor/Drift（FTS5 全文搜索预留） |
| 服务端 | Go（标准库 net/http） |
| 服务端存储 | SQLite + 本地文件系统（Blob） |
| 同步协议 | 自研 push/pull + base_version 冲突检测 + 三向合并 |
| 剪藏净化 | 类 Readability 启发式 + 自定义 HTML→Markdown 转换器 |
| 浏览器扩展 | Chrome Extension MV3 |
| 实时通知 | WebSocket（nhooyr.io/websocket） |

### 5 个里程碑完成情况
1. **M1 骨架** — 设计文档 + Go 服务端基础 + Flutter 客户端基础 ✅
2. **M2 同步引擎** — 客户端同步引擎（Outbox/冲突/合并）+ 服务端同步协议 ✅
3. **M3 修订历史** — 修订列表/详情/恢复 + 客户端面板 + Diff 展示 ✅
4. **M4 网页剪藏** — 服务端净化 API + Chrome MV3 扩展 + 客户端收件箱 ✅
5. **M5 多端打磨** — CORS + Blob 下载 + WS 通知 + 登录 + 导出 + 性能索引 ✅

### 核心特性
- ✅ 离线优先：本地 SQLite 存储，断网可用
- ✅ 多端同步：push/pull 协议，base_version 冲突检测
- ✅ Markdown 编辑：源码/预览双模式
- ✅ 版本历史：修订记录 + 一键恢复
- ✅ 网页剪藏：Chrome 扩展 + HTML 净化 + 收件箱
- ✅ 全文搜索：SQLite FTS5 架构预留
- ✅ 附件管理：内容寻址 Blob 存储
- ✅ 笔记分组：笔记本 + 标签
- ✅ 实时通知：WebSocket 变更广播
- ✅ 数据导出：Markdown 一键复制

## 18. 附件存储策略（客户端侧）—— 按需拉取 + LRU 上限

> 决策来源：M5 后讨论「客户端附件存储压力」。结论：采用 **B 方案（元数据全量同步 + 附件按需拉取 + LRU 容量上限）**，放弃全量镜像。

### 18.1 问题

客户端存储压力 = 本地持久化的附件字节总量。全量镜像（A 方案）下每台设备存储 ≈ 附件总量：
剪藏图片 50KB~2MB/张、PDF 1~50MB、视频更大，移动端极易被不知不觉占满。

内容寻址（sha256 去重）只能解决「同图多篇引用只存一份」，**解决不了总量大**——两个不同问题。

### 18.2 方案 B 设计

```
┌─────────────────────────────────────────────────────────┐
│ 同步层（SyncClient）                                      │
│  - 笔记-附件映射关系：全量同步（映射数据极小）               │
│  - 附件字节：不同步，打开时按需下载（GET /blobs/{hash}）    │
├─────────────────────────────────────────────────────────┤
│ 缓存层（CachedBlobStore，新包装，实现 BlobStore 接口）      │
│  - 容量记账：维护本地已缓存字节总量                         │
│  - LRU 淘汰：超上限（默认 512MB，可配置）按最近最少使用淘汰   │
│  - 元数据（hash/大小/最后访问）落 SQLite 或 sidecar 文件     │
│  - 命中缓存直接读本地；未命中 → 服务端下载 → 写入缓存        │
├─────────────────────────────────────────────────────────┤
│ 物理层（LocalBlobStore，已有）                             │
│  - <root>/<hash前2位>/<hash> 分片存储                      │
└─────────────────────────────────────────────────────────┘
```

**关键点**

- **映射同步**：笔记附件清单（attachment 表）随同步协议走，字节永远不随 pull 下发。
- **惰性下载**：附件打开 / 预览时才请求 `GET /api/v1/blobs/{hash}`；Web 端同理（浏览器沙箱缓存）。
- **LRU 淘汰**：容量超限时淘汰最久未访问的 hash（先删物理字节，再清元数据）；被淘汰后再次打开触发重新下载。
- **占位 UX**：未缓存的附件显示「未下载」占位 + 手动下载按钮；离线时未缓存附件不可看（可接受权衡）。
- **桌面可扩**：桌面端可提供「全量镜像」开关（关闭 LRU），移动端默认按需。

**实现清单（后续）**

1. ✅ note_core：`CachedBlobStore`（实现 `BlobStore`，内部 = LocalBlobStore + 容量记账 + LRU 淘汰 + 下载回调）。
2. ✅ 附件元数据表：`blob_refs`（hash / size / last_access_at / ref_count），随同步协议交换（表已建 + drift 迁移 v3）。
3. ✅ SyncClient：`ensureBlob(hash)` 按需下载入口（`GET /blobs/{hash}` + 写入缓存）；pull 附件映射同步待扩展。
4. ✅ Flutter UI：编辑器底部附件卡片区（文件名/大小/「未下载 ⇄ 已缓存」状态 + 下载进度提示）；`AppController` 暴露 `attachments` / `isAttachmentCached` / `openAttachment`。
5. ✅ 服务端：`GET /blobs/{hash}` 已就绪（M5），无需改动；缩略图生成（C 方案）留后续。
6. ✅ 测试：`cached_blob_store_test.dart` 7 用例（幂等 / 按需下载 / 无源返回 null / LRU 淘汰 / 孤儿优先 / 引用归零清理 / 删除联动）通过；note_core 全量 24 用例通过；flutter analyze 零问题、widget 测试通过。

> 注：附件-笔记映射（attachments 表）的服务端同步、附件选择器/上传 UI 为后续增量项，当前交付聚焦"缓存压力受控"机制本身。

**存储压力结论**

- 移动端：本地占用 ≤ 512MB 上限（可配置），**与附件总量解耦**，压力可控。
- 桌面端：可选全量镜像，默认同上限策略。
- 离线：未缓存附件不可看，但有占位提示；已缓存附件完整可用。

## 17. 项目目录结构（目标）
