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

---

## 17. 项目目录结构（目标）
