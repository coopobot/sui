# 系统架构

本文描述随手记 Sui 的整体架构、分层、数据模型、同步协议与关键设计决策。
决策的**背景与权衡**见架构决策记录（ADR）；接口细节见 [API 参考](api-reference.md)。

## 1. 总体架构

```
┌───────────────┐   push/pull (REST)   ┌──────────────────┐
│ Flutter 客户端 │ ◄────────────────────► │   Go 服务端        │
│ (多端)         │   WebSocket 变更通知  │                   │
│               │ ◄──────────────────── │  sync 协议        │
│ ┌───────────┐ │                       │  store (SQLite)   │
│ │note_core  │ │                       │  blob (磁盘分片)   │
│ │ SyncClient│ │                       │  clip (净化引擎)   │
│ │ Repository│ │                       │  ws (Hub)         │
│ │ drift/SQL │ │                       └──────────────────┘
│ └───────────┘ │   HTTPS + HTML       ┌──────────────────┐
│               │ ◄──────────────────── │ Chrome 剪藏扩展   │
└───────────────┘                       └──────────────────┘
```

### 设计原则

- **离线优先**：客户端所有数据本地持久化，服务端只负责汇聚与版本仲裁。
- **Markdown 唯一正本**：笔记内容一律为 Markdown 字符串，编辑器提供「格式 / 源码 / 预览」三态
  （格式态为正本之上的可视化视图），杜绝富文本中间态转换风险。
- **内容寻址附件**：附件以 sha256 为键存储，天然去重、可校验完整性。
- **服务端权威版本线**：`version` 由服务端递增下发，客户端只携带 `base_version` 做冲突
  判定，不可自行篡改。
- **绝不丢字**：冲突合并采用启发式策略，双方内容都会保留。

### 技术栈

| 层级 | 技术 |
|------|------|
| 客户端 | Flutter（跨平台：Android / iOS / Windows / macOS / Linux / Web） |
| 状态管理 | Provider |
| 本地存储 | SQLite + Moor/Drift（FTS5 全文搜索预留） |
| 服务端 | Go（标准库 `net/http`） |
| 服务端存储 | SQLite + 本地文件系统（Blob） |
| 同步协议 | 自研 push/pull + `base_version` 冲突检测 + 启发式合并 |
| 剪藏净化 | 类 Readability 启发式 + 自定义 HTML→Markdown 转换器 |
| 浏览器扩展 | Chrome Extension MV3 |
| 实时通知 | WebSocket（`nhooyr.io/websocket`） |

## 2. 服务端

### 2.1 分层

| 包 | 职责 |
|----|------|
| `api` | HTTP 路由 + handler（JSON 入出参） |
| `sync` | 同步协议：`Push`（冲突判定）/ `Pull`（增量拉取） |
| `store` | SQLite 数据访问层（`Store` 结构体） |
| `blob` | 附件存储：sha256 分片路径、引用计数、GC |
| `auth` | `Bearer` Token 中间件 |
| `clip` | 网页净化：类 Readability 选主内容（`article`）/ 整页保序快照（`snapshot`）+ HTML→Markdown + 图片本地化（下载→sha256→附件库，失败降级保留绝对 URL） |
| `ws` | WebSocket Hub：push/剪藏成功后广播 `{"type":"changed"}` |
| `cors` | 跨域中间件（`SUI_ALLOWED_ORIGINS` 白名单；未配置时开发模式全允许） |

### 2.2 数据模型（SQLite，服务端）

服务端库只承载**同步汇聚**所需的最小元数据，实际建表语句见
`server/internal/store/store.go` 的 `migrate()`。

| 表 | 用途 |
|----|------|
| `users` | 用户（id / username / password_hash / password_salt / created_at）。单用户模式至多一行 |
| `sessions` | 会话令牌（token / username / created_at），多设备 / 多 profile 各持一行 |
| `notes` | 笔记元数据（id / title / content_markdown / notebook_id / version / is_deleted / archived / source_device / source_url / updated_at）。`source_url` 为剪藏**来源标记**（普通笔记为 NULL；`v0.13.3` 起不再作幂等键） |
| `revisions` | 修订历史（id / note_id / version / title / content_markdown / source_device / is_conflict / created_at） |
| `blobs` | 附件字节登记（sha256 / size / refcount / created_at）。**refcount 唯一来源是 `attachments` 映射**：指向该 hash 的有效映射条数 |
| `attachments` | 附件-笔记映射（id / note_id / filename / mime_kind / byte_size / sha256 / storage_ref / thumbnail_ref / embedded_pos / is_deleted / created_at / updated_at） |
| `notebooks` | 笔记本分组（id / parent_id / name / sort_order / is_deleted / version / source_device / created_at / updated_at） |
| `tags` | 标签（id / name / is_deleted / version / source_device / created_at / updated_at） |
| `note_tags` | 笔记-标签多对多关联（note_id / tag_id） |
| `meta` | 实例元数据键值（key / value / updated_at）。当前存 `instance_id` —— **云端实例身份**（形如 `inst-<32 位小写十六进制>`），首启初始化生成、同一数据目录内恒定、**重建 / 换库必变**（M12 / FR-55） |

关键索引：`idx_notes_updated`、`idx_revisions_note`、`idx_revisions_note_ver`、`idx_notes_isdel`、
`idx_attachments_note`、`idx_notebooks_updated`、`idx_tags_updated`、`idx_note_tags_note`、`idx_note_tags_tag`、`idx_sessions_user`。

> **同步净荷（M1 起，M2 增补）**：push 请求体在 `items`（笔记）之外新增 `notebooks` / `tags` 两个数组，
> 笔记条目新增 `notebookId`（指针语义：缺省=不变、`""`=移入收件箱、有值=归属该笔记本）与
> `tagIds`（该笔记标签的全量集合）；pull 响应新增 `notebooks` / `tags` 两个数组，笔记条目回带
> `notebookId` / `tagIds`。push 响应新增 `notebookResults` / `tagResults`，与 `results` 同构
> （`accepted` / `serverVersion` / `appliedVersion`），复用同一套 `base_version` 冲突与墓碑机制。
> M2 起笔记条目增带 `archived`（归档状态，随 push/pull 往返、跨端一致）。
> 旧表清单中的 `outbox` 为设计预留描述，代码中并未建表，已从本表移除。
>
> **M12 起（FR-55）**：服务端库由 9 张表增至 **10 张**（新增 `meta`）；`GET /api/v1/sync/pull`
> 响应新增 `instanceId`（该端点恒鉴权），`GET /api/v1/ping` **仅在鉴权通过时**回带 `instanceId`
> （匿名探测不返回，避免对公网暴露稳定指纹）。push 逐项结果新增 `notFound`，且 `serverVersion`
> 去掉 `omitempty` ——「服务端没有该实体」时**显式**给出 `serverVersion: 0`。push/pull 的其余净荷
> 字段、`baseVersion` 冲突判定与启发式合并策略**均未改动**；契约细节见 [API 参考](api-reference.md)。

### 2.3 测试清单（`internal/api/handlers_test.go` + `internal/api/m4_test.go` + `internal/api/m6_test.go` + `internal/api/m10_test.go` + `internal/api/m12_test.go` + `internal/clip/snapshot_test.go` + `internal/api/clip_screenshot_test.go`）

| 测试 | 覆盖 |
|------|------|
| `TestPing` | 心跳 |
| `TestHealth` | 健康检查 |
| `TestPushPull` | 推送 + 增量拉取闭环 |
| `TestConflictDetection` | `base_version` 冲突判定 |
| `TestAuthReject` | 无 token / 坏 token 拒绝 |
| `TestRevisionListAndGet` | 修订列表 + 详情 |
| `TestAttachmentMappingSync` | 附件映射往返 + refcount 幂等/改指/墓碑归零 + 孤儿 GC |
| `TestClipEndpoint` | 剪藏净化 + 同步集成（同 URL 再次剪藏**新建**笔记） |
| `TestSyncNotebookTagPayload` | 笔记本 / 标签净荷往返 + `notebookId` / `tagIds` + 冲突回传 `serverVersion` |
| `TestSyncArchivedFlag` | 归档状态 `archived` 净荷往返 |
| `TestSyncNotebookCreateRename` | 笔记本新建 / 重命名变更上行与 pull 收敛 |
| `TestPingInitialized` | `initialized` 心跳（首启 `false` → 建号后 `true`） |
| `TestRegisterGatewayClosed` | 首启后注册网关关闭（403 `already-initialized`） |
| `TestLoginRejectsWrongPassword` | 密码哈希校验（错误密码 401，正确密码可登录） |
| `TestWsAuthRequired` | WS 端点鉴权（无 token 拒绝 / 有效 token 升级） |
| `TestClipIDUniqueness` | 剪藏 id ≥128 bit + **同 URL 各自成篇**（唯一性按 `noteId`）/ 异 URL 区分 |
| `TestClipSnapshotMode` | `snapshot` 模式：整页保序净化（标题 / 表格 / 图注）产出语义等价 Markdown |
| `TestClipMediaLocalization` | 图片本地化：下载 → sha256 → 附件入库 → 正文改 `sui://` + 附件映射随笔记入库 |
| `TestClipMediaFailureDegrade` | 单图失败降级：保留（已解析的）**绝对 URL**，不阻断整篇 |
| `TestClipOfflineReadable` | 离线可读：本地化后按 `sha256` 可从附件库取回图片字节 |
| `TestM12InstanceIDStableWithinDataDir` | 云端实例身份在同一数据目录内**恒定**（重开库不变） |
| `TestM12InstanceIDChangesAfterRebuild` | 重建 / 换库后实例身份**必变** |
| `TestM12PingExposesInstanceIDOnlyWhenAuthed` | 匿名 `ping` **不**返回 `instanceId`，鉴权通过后返回 |
| `TestM12PushNotFoundSignalAndSelfHeal` | 「服务端没有该实体」→ `notFound: true` + 显式 `serverVersion: 0`；基线归零后**立即**被接受 |
| `TestSnapshotBlockSeparation` / `TestSnapshotBlockSeparationThreeLevels` | `v0.14.1`：快照**块级分段**——`<div>行1</div><div>行2</div>` 不再被拼成「行1行2」一行；多层级容器逐层分段（FR-69 / BR-69.1 / AC-323） |
| `TestSnapshotArticleModeUnchanged` | `v0.14.1`：**`article` 模式产物逐字节不变**（9/9 夹具 `cmp` 自证，只影响 `snapshot`）（BR-69.7 / AC-328） |
| `TestSnapshotHTMLBlockNeedsLayout` / `TestSnapshotCenterBlockKeepsLayout` / `TestSnapshotAlignAttributeAndCenterTag` / `TestSnapshotHTMLBlockIsOwnLine` | `v0.14.1`：**受限内嵌 HTML 块**的产出判据——只有带版式信息（白名单内联 `style` / `align` 属性 / `<center>`）才落 HTML 块，且**独占一行**（FR-69 / BR-69.2） |
| `TestSnapshotStyleWhitelistDropsIllegalValues` / `TestSnapshotHTMLBlockInjectionGuard` / `TestSnapshotDropsNonContentNodes` / `TestSnapshotInlineHTMLBlockWhitelist` | `v0.14.1`：**白名单三级收口**——非法样式值 / `on*` 事件属性 / `class`·`id` / `script`·`iframe`·表单类一律**不进正文**（连带文本也不留）（BR-69.2 / BR-69.6 / AC-329\~AC-333、AC-336） |
| `TestSnapshotKeepsMarkdownCapabilities` | `v0.14.1`：标题 / 列表 / 表格 / 引用 / 代码块 / 图片尺寸等既有 Markdown 能力**不因新版式路径而丢失**（BR-69.1 / AC-324\~AC-327） |
| `TestSnapshotHTMLEmphasisWithMarkdownInside` / `TestSnapshotStyledInlineInsidePlainBlock` / `TestSnapshotAlignPushdownToChildBlocks` | `v0.14.1`：HTML 块内与 Markdown 记号混排、样式下推到子块、无版式的普通块仍走 Markdown 路径 |
| `TestClipScreenshotStoredAsAttachment` | `v0.14.1`：`screenshot` 载荷 → 内容寻址入库为**附件** → 正文末尾 `![整页截图](sui://<sha256>)`（FR-69 / BR-69.5 / AC-345） |
| `TestClipScreenshotIgnoredInArticleMode` | `v0.14.1`：截图**仅 `snapshot` 生效**——`article` 模式忽略该载荷（AC-347） |
| `TestClipScreenshotOversizedIgnored` / `TestClipScreenshotMalformedIgnored` / `TestClipScreenshotRejectsEmptyFilenameOnly` | `v0.14.1`：**体积闸门与非法载荷静默忽略**（不返回 4xx / 5xx，剪藏仍成功、无半截附件记录）（BR-69.5 / AC-346） |
| `TestClipScreenshotAbsentUnchanged` / `TestClipScreenshotFilenameFallback` | `v0.14.1`：不带截图时行为不变；文件名为空 / 全空白时回退缺省名 `整页截图.jpg` |

## 3. 客户端

### 3.1 note_core（共享核心）

纯 Dart 包，不依赖 Flutter，可被任何 Dart 宿主复用。

| 类 | 职责 |
|----|------|
| `NoteRepository` | 本地数据访问门面：笔记本 CRUD、标签、笔记 CRUD、修订追加、搜索 |
| `SyncClient` | 同步引擎：按库中状态**重建**上行批次（状态即队列）、增量 pull、冲突本地合并与「服务端没有该实体」自愈、核对补齐 `reconcile()` |
| `EntitySyncState` | 逐项同步状态五态（`已同步` / `待上传` / `仅本地` / `冲突` / `同步失败`）+ 承载实体类别映射（M12 / FR-53） |
| `AppDatabase` | drift 数据库（8 表 + 迁移；当前 `schemaVersion = 10`） |
| `LocalBlobStore` | 附件本地存储实现（原生分片落盘 / Web 内存缓存） |
| `CachedBlobStore` | 附件缓存层：LRU 上限 + 按需下载 + `uploaded_at` 待上传记账（`blob_refs`） |
| `FileImportService` | 批量导入本地文件（M13 / FR-60\~FR-62）：编码识别（UTF-8 / BOM / UTF-16）、`.md`·`.txt`·HTML→Markdown 转换、资源本地化（`sui://<sha256>`）、内容指纹幂等去重、进度 / 取消 / 结果报告 |
| `SnapshotHtml`（`lib/src/format/snapshot_html.dart`） | 网页快照的**受限内嵌 HTML**（FR-69 / `v0.14.1`）：`htmlBlocks` / `htmlBlockAt` **块定位**（`HtmlBlock` 区间口径与表格一致）+ `parseSnapshotHtml` **白名单化解析**（标签 / 样式属性 / 元素属性三级收口；`kSnapshotDroppedTags` 整块丢弃**连文本也不留**；`_safeStyleValue` 挡 `url(...)` / `expression(...)` / `!important`）——预览态与格式模式**同一套白名单** |
| `EditorFormat`（`lib/src/format/editor_format.dart`） | 编辑器格式化纯函数：**分割线块级插入**（`_divider` / `_dividerAnchorEnd` / `_fenceBlockEndAt` / `_isThematicBreak`，`v0.14.1` / FR-72）、**HTML 块整块删除**（`htmlBlockForDeletion` / `deleteHtmlBlock`，`structuralDelete` 的一环） |
| `mimeKindFor()` | 由扩展名推断附件大类（卡片图标用） |
| `DeviceId` | 设备标识（冲突合并 / 来源标记用） |

**本机数据表（drift，`schemaVersion = 10`，共 8 张）**：定义见
`clients/note_core/lib/src/db/app_database.dart`。

| 表 | 用途 | 随同步上行 |
|----|------|------------|
| `notebooks` | 笔记本分组（树形：id / parent_id / name / sort_order / is_deleted / version / 时间戳） | ✅ |
| `tags` | 标签（扁平、跨笔记组合） | ✅ |
| `notes` | 笔记正本（notebook_id / title / content_markdown / pinned / archived / is_deleted / revision_count / version / source_device / 时间戳） | ✅ |
| `note_tags` | 笔记-标签多对多关联（note_id / tag_id） | ✅（随笔记 `tagIds`） |
| `revisions` | 修订历史（快照 + diff 增量） | ✅ |
| `attachments` | 附件元数据（字节存 BlobStore，此处只存引用 + sha256） | ✅（映射随笔记） |
| `blob_refs` | 本机附件缓存记账（LRU 元数据 + `uploaded_at` 待上传标记） | ❌ 本机缓存状态 |
| `settings` | 应用级键值配置（服务端地址 / 会话令牌 / deviceId；M12 增 `sync.instanceId` / `sync.lastPull` / `sync.lastReconcileAt`；**M14 增外观偏好** `ui.themeMode` / `ui.fontFamily.ui` / `ui.fontFamily.body` / `ui.notebookFont.<notebookId>`） | ❌ 设备级偏好 |

> M1 起服务端补齐 `notebooks` / `tags` / `note_tags` 三表：`notebooks` / `tags` 随 sync/push、
> sync/pull 净荷上下行（与笔记一样携带 `version` / `is_deleted` / 来源设备与墓碑机制）；
> `note_tags` 关联不单独传输，而是随所属笔记的 `tagIds` 全量携带、在笔记被接受时重建关联。
>
> **M12 起（FR-53）：新增逐项同步状态列。** `notes` / `notebooks` / `tags` 三表各增
> `sync_state`（0 已同步 / 1 待上传 / 2 仅本地 / 3 冲突 / 4 同步失败）、`sync_error`、
> `sync_error_at`、`sync_checked_at`、`sync_hold`（用户选「以云端为准」后被**按住**的项）。
> 状态是**纯本地记账** —— 它描述「本端这一条相对云端的关系」，故**不写入 Markdown 正本、
> 不进 push/pull 净荷、服务端不存储**（BR-53.3）。迁移（v7 → v8）取**保守初值**、
> **绝不预置「已同步」**：有服务端基线（`version > 0`）→ 待上传；`version == 0` 且无未确认
> 修订 → 仅本地；有未确认修订 → 待上传；首次连接并完成核对后由同步层**整体重算**。
>
> 笔记本 / 标签的 `version` 自 M12 起与笔记同口径 —— 是**服务端基线镜像**，本地编辑不再递增它。
>
> **M13 起（FR-62）：`notes` 新增导入内容指纹列。** `import_fingerprint` 存
> `sha256(标题 + 正文 Markdown)`，用于「同一文件重复导入不产生重复笔记」；
> 它同样是**纯本地记账**——不写入 Markdown 正本、**不进 push / pull 净荷、服务端不存储**，
> 故仍为 **8 张表**，仅 `schemaVersion 8 → 9`（迁移为幂等补列，老数据该列为空串、
> **不参与**去重，不会被误判为重复）。跨端去重本轮不做（需协议级来源标识）。

### 3.2 flutter_app（Flutter 客户端）

**状态管理**：Provider + `AppController`（单一状态源，暴露 `notifyListeners`）。

| 文件 | 职责 |
|------|------|
| `note_shell.dart` | 响应式三栏骨架（宽屏三栏 / 窄屏抽屉 + 导航堆栈）；桌面端左栏 / 中栏按视图偏好**条件渲染**（折叠面板与其分隔线一并消失）；M12 增顶栏同步状态入口（未连接 → 打开设置，已连接 → 立即同步）与「云端数据已更换 / 重建」**三选一对话框**（默认焦点在「取消」，非破坏性）；**M14** 顶栏「更多」菜单增「设置」入口（窄屏 / Web） |
| `notebook_tree.dart` | 笔记本树 + 收件箱 + 全部笔记 + 标签入口 + 归档 / 回收站入口（底部区域） |
| `note_list.dart` | 笔记列表（置顶 / 剪藏标签 / 搜索过滤） |
| `note_editor.dart` | 编辑器（标题 / 格式工具栏 + 编辑快捷键 / 勾选框点选 / 标签 / 附件面板 / 附件预览 / 历史 / 导出 / 删除 / **表格工具** / **粘贴保留格式** / **简化格式**）；`v0.14.1`：**链接条** `_LinkBar`（光标落在链接里 → 网址 + 打开 / 编辑，含表格单元格内链接）、`_openUrl` / `_editLink`、`_pasteFromClipboard({rich})`（优先读剪贴板 **HTML 表示**，失败静默回落纯文本）、`_localizePastedImages`（`data:` 图片落附件） |
| `markdown_editing_controller.dart` | 「格式 / 源码 / 预览」三态编辑控制器（Markdown 为正本；格式态渲染行内样式、图片单元、任务勾选框与高亮、**表格呈现单元**、**附件胶囊单元**、**有序列表编号**，支持选中调尺寸）；`v0.14.1`：新增区域种类 **`_RegionKind.htmlBlock`**——快照受限 HTML 块作为**原子块**整块呈现（其余码元以零宽等码元 `U+2060` 补齐，守偏移契约） |
| `markdown_editor.dart` | 源码编辑 + 预览切换（`sizedImageBuilder` 渲染 `sui://` 附件图；预览态渲染任务列表、`==高亮==`、**表格**、**有序列表编号**） |
| `revision_panel.dart` | 版本历史面板 + 一键恢复（宽屏为右侧栏、窄屏**整页推入**，能力一致；BR-12.3） |
| `app_controller.dart` | 全局状态与业务编排（附件增删 / 上传 / 缓存状态）；桌面折叠状态 `leftPanelCollapsed` / `noteListCollapsed`、编辑模式与 **M14 外观偏好**（主题三态、界面字体、笔记正文字体、各笔记本字体覆盖，均 `ui.*` **本机偏好**，**不进同步**）；退出前落库 `flushPendingEdits`；同步调度：编辑防抖 0.7s 推送、WS 通知拉取、30s 周期兜底；**多窗口**：编辑器命令目标按**视图键**索引（`_editorTargets` / `setActiveViewKey`）、窗口注册表与「一笔记一窗口」去重聚焦、`quitApplication` 关闭全部窗口后退出 |
| `note_window_manager.dart` | 桌面多窗口**平台无关接缝**：`NoteWindowManager` 接口（开窗 / 聚焦 / 关闭 / 查询）+ `WindowEventHub` 事件枢纽（窗口打开 / 关闭 / 视图聚焦）—— 窗口注册表语义与「两面并行」流程可在**纯 Dart 单测**中驱动，无需真实窗口 |
| `note_window.dart` | **独立笔记窗口**内容（复用 `NoteEditor`，按笔记 id 装载）；窗口内以视图键 `setActiveViewKey` 认领命令、关闭经 `closeCurrentWindow` 释放 |
| `desktop_commands.dart` | 桌面命令**单一来源**（`DesktopCommandId` / `DesktopCommand` / `desktopCommands` 注册表）+ `EditorCommandTarget` 接口桥；菜单项 / 顶栏图标按钮 / 快捷键**同源**（多窗口下按当前**聚焦视图**路由命令） |
| `app_menu_bar.dart` | 桌面端自绘菜单栏「文件 / 编辑 / 视图 / **同步** / 帮助」（M12 增「同步 → 全部重新同步」）+ 顶栏折叠切换控件 `PanelToggles`（窄屏 / 非桌面**不渲染**） |
| `settings_dialog.dart` | **设置中心**（M14 / FR-63）：五分区「外观 / 同步与账号 / 本地存储（仅桌面）/ 附件缓存 / 关于」；桌面「文件 → 设置…」与 `Ctrl/Cmd + ,`、窄屏 / Web 顶栏「更多 → 设置」、顶栏同步图标直达「同步与账号」；分区按端裁剪（移动 / Web 不渲染「本地存储」） |
| `appearance/app_palette.dart` | **中性色板**（`AppPalette` 亮 / 暗）+ 主题构建 `buildSuiTheme(brightness, uiFontFamily, bodyFontFamily)` + 外观扩展 `SuiAppearance`（承载中性色板与**笔记正文字体**）——主题层把 `surface*` / `outline*` 覆盖为中性灰阶（M14 / FR-64 / FR-67） |
| `appearance/font_catalog.dart` | 分平台字体候选清单（界面字体 / 笔记正文字体；`system` ↔ `null` 互转） |
| `appearance/font_availability.dart` | 字体**运行时可用性探测**（`TextPainter` 同字号量宽比对哨兵族名 + 会话内缓存）——只列本机可用项，避免「选了没反应」（M14 / FR-65 / BR-65.3） |
| `sync_settings_dialog.dart` | 「同步与账号」分区面板 `SyncSettingsPanel`（服务端地址 + **账号密码登录** / 设备 ID）+ M12 的「全部重新同步」面板；`showSyncSettingsDialog` 为直达该分区的薄封装 |
| `sync_status_icon.dart` | 逐项同步状态的**就地呈现**（五态图标 + tooltip 缘由 + 未同步计数角标；窄屏降级为状态点）——图标与文案的单一来源在 `note_core`（M12 / FR-53） |
| `ui/snapshot_html_view.dart` | **快照受限 HTML 渲染器**（FR-69 / `v0.14.1`）：`SnapshotHtmlView`（受限渲染：`sui://` 图片走附件构建器 `suiImageBuilder`、**外链图片只占位不出网**、`a` 经 `onOpenLink` 走链接白名单）+ `PreviewHtmlBlock`（预览态按块混排单元）——**渲染期零网络请求** |
| `platform/url_opener.dart`（+ `_io` / `_web`）· `url_schemes.dart` · `platform_seams.dart` | **打开外部网址**（FR-70 / `v0.14.1`）：协议白名单 `kOpenableUrlSchemes` = `http` / `https` / `mailto` / `tel`（`isOpenableUrl` 纯函数）；平台分派 = 桌面三平台系统壳层（`cmd /c start` / `open` / `xdg-open`）、Web `window.open`、Android **自研通道** `sui/platform.openUrl`（`ACTION_VIEW`）；`debugUrlOpenerOverride` / `debugClipboardHtmlOverride` 为**测试接缝**（未注入时行为与生产一致） |
| `platform/clipboard_html.dart`（+ `_io` / `_web`）· `cf_html.dart` | **读剪贴板 HTML 表示**（FR-71 / `v0.14.1`）：Windows 读 **CF_HTML**（原生回原始**字节** → Dart `decodeCfHtml` 按 `StartFragment` / `EndFragment` **字节偏移**切片）、Android 读 **`ClipData`** HTML 项；其余平台恒 `null` → 回落纯文本；原生侧**不做解析** |
| `platform/attachment_picker.dart` | 跨端文件选择（`file_picker`，返回文件名 + 字节） |
| `platform/app_lifecycle.dart`（+ `_io` / `_web`） | 桌面退出前落库接缝（条件导入）：桌面实现「`flushPendingEdits` → 尽力推送 → 退出」，其他平台降级为空实现 |
| `platform/multi_window.dart`（+ `_io` / `_stub`） | 多窗口平台接缝（条件导入）：桌面经 `multiview_desktop` 开**真 OS 窗口**（单引擎多视图），其他平台降级为 no-op（Web / 移动端不构建该依赖） |

**服务端地址**：不写死在代码里，由用户在「同步设置」对话框录入，经
`SyncConfig.normalizeBaseUrl` 规整后存入本地 SQLite `settings` 表；未填写时输入框以
`http://127.0.0.1:8080` 作占位提示。运行时地址一律取自 `AppController` 持有的 `SyncConfig`。

### 3.3 测试

- note_core：**612 个用例**（**M15 新增 97 项**：新增 `editor_find_test.dart`（笔记内查找与替换）、
  `note_ref_test.dart`（关联笔记）、`editor_typing_escape_test.dart`（输入转义）、
  `editor_inline_nesting_test.dart`（行内记号按区间递归）、`editor_inline_toggle_test.dart`
  （格式指令的记号集合语义）、`editor_crlf_test.dart`（CRLF 容错）、`editor_fence_block_test.dart`
  （围栏代码块原子边界），并按新口径同步既有用例）；M13 新增**批量导入模块 132 项**；`v0.14.1` 新增 **36 项**——
  `snapshot_html_test.dart` **11 项**（HTML 块定位 / 白名单化解析 / 脚本与事件属性不进树 / 原子块整块删除）、
  `clipboard_paste_test.dart` **11 项**（CF_HTML 头部与片段切片 / 样式映射 / `data:` 图片 / 失败回落与限额）、
  `editor_format_test.dart` 新增 `DividerBlockInsertion` **10 项**与 `MarkdownLinks` **4 项**；
  `v0.14.3` 分割线口径修订：删除 `PreviewSource` 组 3 项、按「标准语义 + 规则区间折叠」重写分割线记号用例），
  覆盖仓储 CRUD / 标签 / 搜索 / 修订 / 同步 / 附件引用计数与上传 /
  缓存 LRU / 配置存取 / 落盘持久化 / 笔记本排序（同级 `sortOrder` 递增、子笔记本权重独立、
  重排归一化）/ 编辑器格式化（快捷键映射同源、勾选框往返、`==高亮==` 往返、块级行为）/
  **逐项同步状态与核对补齐（M12：写路径状态、`notFound` 自愈、真冲突合并且绝不丢字、
  游标回退与重放幂等、换库拒落数据、v7 → v8 迁移保守初值）**，另含
  e2e（首批注册后双端 push/pull→冲突合并→重发；附件映射同步 + 字节按需下载）。
- flutter_app：**318 个用例**（**M15 净增 70 项**：5 个新测试文件共**声明 64 个用例**——
  `editor_m15_ui_test.dart` 18（编辑器 M15 交互）、`editor_controller_m15_test.dart` 21（编辑控制器）、
  `note_properties_panel_test.dart` 12（属性面板）、`desktop_commands_m15_test.dart` 9（桌面命令与加速键）、
  `note_window_m15_test.dart` 4（独立窗口去首栏）——其余 6 项为循环参数化的运行时用例；
  并按新口径同步 `note_window_manager_test.dart`；含 M13 `file_import_ui_test.dart` 8 项：命令注册表与加速键、桌面菜单 / 窄屏「更多」入口、对话框目标只读、加密未解锁拒绝、报告计数与明细、平台层相对资源解析的候选回退与越界拒绝、文件夹递归收集跳过导出资源目录；`v0.14.1` 新增 **13 项**：
  `editor_link_paste_v141_test.dart` **10 项**（预览态链接点按与协议白名单 / 格式模式链接条 / 单元格内链接 / 粘贴 HTML 路径与失败回落）、
  `snapshot_html_view_test.dart` **3 项**（`sui://` 图片走附件构建器、外链图片只占位**不出网**、预览态混排不露标签原文）；
  `v0.14.3` 重写 `divider_preview_v142_test.dart` 为 **4 项**（用**真实的 `markdown` 包**断言：空白分隔的 `---` → `hr`、
  紧贴上一行的 `---` → setext `h2`、格式模式规则记号区间 [4,9] / [4,8] 折叠）），含 widget 测试、`sync_wiring_test.dart`（起真服务端跑注册连接→同步→
  第二设备拉取）、`editor_format_image_test.dart`（格式模式图片渲染与尺寸手柄）、
  `editor_enhancement_test.dart` / `editor_enhancement_e2e_test.dart`（编辑器增强：编辑快捷键、
  勾选框点选回写、`==高亮==` 三态渲染，以及「打开不编辑」跨三态逐字节保真）、
  `note_shell_narrow_test.dart`（窄屏历史入口 3 项：点历史整页推入修订面板、顶栏返回 / 系统返回
  先关面板回编辑页再退出编辑）、
  `desktop_shell_test.dart`（桌面外壳 12 项：折叠四态与上下文不丢、视图偏好持久化、恢复入口、
  菜单命令与图标 / 快捷键等价、不可用命令置灰、快捷键提示、编辑模式跨重启、窄屏不渲染、
  落盘失败不阻断刷新）与
  `note_window_manager_test.dart` / `attachment_window_isolation_test.dart`（桌面多窗口 12 项：
  开窗 / 去重聚焦（含最小化先还原）、两面并行（主窗口照常保留编辑面、选中不变）、
  关闭释放与「关闭全部窗口退出」、窗口局部 `ui.window.note.editorMode` 独立于主窗口、
  附件列表按笔记取值**不回读**全局字段的跨窗口隔离）。
- 运行前确保 `libsqlite3` 可用（见[快速开始 §2.3](getting-started.md#23-sqlite3-native-库drift-依赖仅原生平台)）。

## 4. 同步协议与冲突解决

### 4.1 版本模型

```
客户端                       服务端
┌────────────────────┐      ┌──────────────────────┐
│ base_version = 服务 │      │ version（权威，单调递增）│
│ 端最近一次下发的值  │      │                      │
│ 本地修订 = 动态递增 │      │ 每次接受 push：      │
│ （未同步的修改）     │      │  base==server → 应用  │
└────────────────────┘      │        version+1      │
                            │  base!=server → 冲突   │
                            └──────────────────────┘
```

- `version` 只由服务端下发，客户端不可修改。
- 客户端本地每次修改 = 本地版本 +1（未提交前一直 +1）。
- 客户端 pull 后 base 刷新、本地修订重置。

### 4.2 冲突判定与合并

- **判定**：服务端 `base_version` 撞车即冲突，返回当前 `serverVersion`。
- **服务端没有该实体**（客户端基线非 0、服务端无记录）：**不算冲突** —— M12 起服务端回
  `accepted: false` + `notFound: true` + **显式** `serverVersion: 0`；客户端据此把该实体**基线归零
  并在同一轮内重发**（自愈）。旧实现只回 `accepted: false`，客户端无从判断 → 会**永久冲突**（B24-①）。
- **合并（客户端启发式）**：
  1. 标题取较新修订。
  2. 正文：合并双方内容，冲突段落用标记分隔，**绝不丢字**。
  3. 合并结果作为新 base 重发。
- **与 Git 类比**：rebase（基于服务端最新）+ merge（双方内容并集）。

### 4.3 历史一致性

- 历史记录以**服务端合并记录**为准，所有端看到一致。
- 客户端未同步的本地修改在同步后并入服务端时间线。

### 4.4 WebSocket 通知

- 端点：`GET /api/v1/ws?token=<token>`（亦接受 `Authorization: Bearer`）；鉴权未通过 → 401。
- push / 剪藏成功后向已鉴权连接广播 `{"type":"changed"}`。
- 客户端收到后触发一次增量 pull；WS 不可用仅静默降级，手动同步与防抖推送仍可用。

### 4.5 逐项同步状态（M12 / FR-53）

五态为**纯本地记账**（不写入 Markdown 正本、不进 push/pull 净荷、服务端不存储），落在
`notes` / `notebooks` / `tags` 三表：

| 状态 | 判定口径 |
|------|----------|
| `已同步` | 本端无未确认改动，且已知服务端版本与本端基线一致 |
| `待上传` | 本端有未上行改动，且**云端已知持有**该实体 |
| `仅本地` | 云端**从未持有**该实体（核对确认不存在） |
| `冲突` | 云端持有、版本 ≠ 本端基线，**且**本端仍有未上行改动（含加密笔记本未解锁、无法就地合并） |
| `同步失败` | 最近一次针对该项的上行 / 下行失败（保留原因与时间） |

未知落库值一律按**保守态**（`待上传`）处理，**不误报「已同步」**（BR-53.6）；未配置同步时界面
一律呈现「仅本地」的弱化文案，同样不伪造「已同步」。

### 4.6 状态即队列与自愈（M12）

- **上行队列 = 库中状态**：`push()` 按 `sync_state` **重建**批次（内存 Outbox 退役），本地写路径
  （新建 / 编辑 / 改名 / 移动 / 排序 / 删除 / 归档 / 恢复 / 附件 / 标签 / 加密开关 / 还原修订）
  即时置位 —— 待上传意图**跨重启、跨换服务端保持**（B24-②）。
- **自愈**：收到 `notFound`（或旧服务端的 `serverVersion == 0`）→ 该实体**基线归零并在同一轮内
  重发**；真冲突 → 同一轮内完成「明文层启发式合并 → 以服务端版本为 base 重发」，**重发轮不再
  重复合并**（避免冲突标记膨胀）；加密笔记本未解锁 → 保持「冲突」并提示先解锁。
- **单项重试**：`retryOne()` 只影响该项，并顺带解除「以云端为准」留下的按住标记。

### 4.7 拉取游标与下行幂等（M12）

游标持久化于 `settings`（`sync.lastPull`），取值 `max(updated_at) − 1s`（服务端 `updated_at`
仍是秒精度，**未改**）；下行幂等，故重放最后一秒安全，而同一秒内新增的多条不再被永久漏拉（B24-③）。

### 4.8 核对补齐与换库决策（M12 / FR-54 / FR-55）

- **`reconcile()`（「全部重新同步」）**：`ping`（取实例身份）→ `pull?since=epoch`（云端全量权威态，
  含墓碑）→ 逐项判定与下行 → 云端缺失的本地实体标「仅本地」→ 分批 push（用户选「用本地补齐」时
  含被按住项；选「以云端为准」则**按住不上行**）→ 逐项回写状态 + 失败原因。可取消、幂等，
  给出进度与逐项结果。
- **云端实例身份**：服务端首启初始化生成 `instance_id`（`meta` 表，形如 `inst-<32 位小写十六进制>`）；
  `pull` 恒下发，`ping` **仅鉴权时**下发。
- **换库 / 重建**：客户端记录的身份与云端不一致，或**首次连接即发现云端为空而本机有数据** →
  抛 `CloudInstanceChangedException`，**在用户决断前不落任何数据、不上传、不更新身份**；
  界面弹三选一（用本地补齐 / 以云端为准 / 取消）。「以云端为准」**不删除本地数据**，只把它们
  降级为「仅本地」并按住（`sync_hold`）。

## 5. 附件存储策略（客户端侧）

> 决策来源：M5 后讨论「客户端附件存储压力」。结论：采用 **B 方案（元数据全量同步 +
> 附件按需拉取 + LRU 容量上限）**，放弃全量镜像。

### 5.1 问题

客户端存储压力 = 本地持久化的附件字节总量。全量镜像（A 方案）下每台设备存储 ≈ 附件总量：
剪藏图片 50KB~2MB/张、PDF 1~50MB、视频更大，移动端极易被不知不觉占满。

内容寻址（sha256 去重）只能解决「同图多篇引用只存一份」，**解决不了总量大** —— 两个不同问题。

### 5.2 方案 B 设计

```
┌─────────────────────────────────────────────────────────┐
│ 同步层（SyncClient）                                      │
│  - 笔记-附件映射关系：全量同步（映射数据极小）               │
│  - 附件字节：不同步，打开时按需下载（GET /blobs/{hash}）    │
├─────────────────────────────────────────────────────────┤
│ 缓存层（CachedBlobStore，实现 BlobStore 接口）             │
│  - 容量记账：维护本地已缓存字节总量                         │
│  - LRU 淘汰：超上限（默认 512MB，可配置）按最近最少使用淘汰   │
│  - 元数据（hash/大小/最后访问）落 SQLite 或 sidecar 文件     │
│  - 命中缓存直接读本地；未命中 → 服务端下载 → 写入缓存        │
├─────────────────────────────────────────────────────────┤
│ 物理层（LocalBlobStore）                                   │
│  - <root>/<hash前2位>/<hash> 分片存储                      │
└─────────────────────────────────────────────────────────┘
```

**关键点**

- **映射同步**：笔记附件清单随笔记一起走 push/pull（`items[].attachments` /
  `notes[].attachments`，含墓碑，否则删除无法传播），字节永远不随 pull 下发。
  映射随笔记而非独立游标，是因为映射脱离笔记没有意义，且省掉一个同步游标。
- **惰性下载**：附件打开 / 预览时才请求 `GET /api/v1/blobs/{hash}`。
- **LRU 淘汰**：容量超限时淘汰最久未访问的 hash（先删物理字节，再清元数据）；
  被淘汰后再次打开触发重新下载。
- **占位 UX**：未缓存的附件显示「未下载」占位 + 手动下载按钮；离线时未缓存附件不可看
  （可接受权衡）。
- **桌面可扩**：桌面端可提供「全量镜像」开关（关闭 LRU），移动端默认按需。

**上传方向**

方案 B 只规定了「字节按需下行」，上行方向必须同时明确，否则新增的附件永远留在本机：

- **新增即上传，失败不阻断**：挂载附件时先落本地字节、再写映射（引用计数 +1），然后尽力
  `PUT /blobs/{hash}`。上传失败（断网 / 未连服务端）不算失败 —— 字节已在本地、映射已入库，
  属于「待上传」状态。
- **同步周期补传**：`blob_refs.uploaded_at` 为 null 即「服务端尚未确认持有」，
  `SyncClient.backfillBlobs()` 在每轮同步开头扫一遍待上传清单补齐。
- **顺序：先补传字节，再 push 映射**。反过来会出现对端已收到映射、却下载不到字节的空窗。
- **四态可用性**：UI 用 `AttachmentAvailability`（`cached` / `pendingUpload` / `localOnly` /
  `remoteOnly`）而非布尔「已缓存」，因为「本地有字节」与「服务端有字节」是两件独立事实。

**存储压力结论**

- 移动端：本地占用 ≤ 512MB 上限（可配置），**与附件总量解耦**，压力可控。
- 桌面端：可选全量镜像，默认同上限策略。
- 离线：未缓存附件不可看，但有占位提示；已缓存附件完整可用。

## 6. 平台分层：条件导入与构建目标

### 6.1 方案：条件导入分层

平台相关能力下沉为「壳文件 + 各平台实现」，由 Dart 条件导入在编译期选择：

| 能力 | 壳文件 | 原生实现 | Web 实现 |
|------|--------|----------|----------|
| 数据库连接 | `db/connection/connection.dart` | `connection_io.dart`：`drift/native` + SQLite 文件 | `connection_web.dart`：`drift/wasm` + 浏览器持久化 |
| Blob 存储 | `blob/local_blob_store.dart` | `local_blob_store_io.dart`：文件系统分片 | `local_blob_store_web.dart`：内存缓存 |
| 数据目录 | `flutter_app/src/platform/data_dir.dart` | `data_dir_io.dart`：`path_provider` | `data_dir_web.dart`：返回 `null` |

条件常量用 `dart.library.io`（原生）与 `dart.library.js_interop`（Web）。
**判定顺序是关键**：`dart.library.io` 必须排在前面 —— 已实测 `dart.library.js_interop`
在 Dart VM 上为 `false`，但仍以显式顺序兜底，避免未来 SDK 行为变化导致 VM 误选 Web 实现。

### 6.2 Web 端持久化

`WasmDatabase.open` 需要 `flutter_app/web/` 下两个资源：

| 资源 | 来源 | 大小 |
|------|------|------|
| `sqlite3.wasm` | sqlite3.dart releases（版本需与 `sqlite3` 依赖一致，当前 2.9.4） | ~714KB |
| `drift_worker.dart.js` | 由 `web/drift_worker.dart` 经 `dart compile js -O4` 生成 | ~355KB |

生成命令见[快速开始 §4.4](getting-started.md#44-web-端资源sqlite3wasm-与-drift-worker)。
drift 会探测浏览器能力并按可靠性择优：
OPFS(shared) → OPFS(locks) → IndexedDB(shared) → IndexedDB(unsafe) → 内存。

> 实测（Chrome、非跨域隔离、无 `SharedArrayBuffer`）：落到 **IndexedDB** 持久化 ——
> `indexedDB.databases()` 中存在名为 `sui` 的库，非内存回退。

### 6.3 数据落库位置

| 平台 | 位置 |
|------|------|
| 桌面 / 移动 | `<应用支持目录>/sui/sui.sqlite`（`path_provider`，目录不存在时自动创建） |
| Web | 浏览器 OPFS / IndexedDB（库名 `sui`） |
| 测试 | 内存库（`AppDatabase.memory()`） |

选「应用支持目录」而非「文档目录」：数据库属应用内部状态，不应出现在用户可见的文件列表中，
也避免被系统云盘同步误处理。

### 6.4 Web 端 Blob 的取舍

Web 无文件系统，`LocalBlobStore` 在 Web 退化为**进程内内存缓存**。方案 B 中 BlobStore 本就是
缓存语义（正本在服务端、按需拉取），刷新页面后重新下载即可，不构成数据丢失。若后续需要
Web 端跨会话缓存附件字节，可再补一个 IndexedDB 实现（壳文件的第三个分支）。

### 6.5 构建目标现状

各目标的**可构建性**取决于本机工具链（脚手架均已入库）。详见
[快速开始 §4.3 的平台脚手架现状表](getting-started.md#43-flutter-客户端)。

**平台相关配置**

| 项 | 位置 | 说明 |
|----|------|------|
| 应用显示名 | `linux/runner/my_application.cc`、`windows/runner/main.cpp`、`android/app/src/main/AndroidManifest.xml`、`ios/Runner/Info.plist`、`macos/Runner/Configs/AppInfo.xcconfig` | 统一为「随手记 Sui」（Windows 资源元数据用 ASCII `Sui`） |
| MSVC 源码编码 | `windows/runner/CMakeLists.txt` | 加 `/utf-8`：窗口标题含中文，MSVC 默认按系统 ANSI 代码页解析无 BOM 源文件会乱码 |
| Android 网络权限 | `android/app/src/main/AndroidManifest.xml` | 模板只在 debug/profile 清单声明 `INTERNET`，release 包必须补在 main 清单 |

> Windows 的 `Runner.rc` 里 `FileDescription` / `ProductName` 用 ASCII `Sui`：`.rc` 由
> `rc.exe` 编译，无 BOM 的 UTF-8 中文会被按代码页误读，不值得为此引入 BOM。
> `InternalName` / `OriginalFilename` 必须保持 `sui_flutter_app`（与可执行文件名绑定）。

> 明文 HTTP 说明：iOS 的 ATS 与 Android 的 Network Security Config 都只约束**平台原生**
> 网络栈（`NSURLSession` / OkHttp 等）。本客户端走 `package:http` → `dart:io` 的 Dart 自有
> socket，Flutter 不在 socket 层施加策略，因此自托管的 `http://` 服务端无需任何明文豁免配置。
> 生产环境仍建议 HTTPS。

## 7. 项目目录结构（目标）

```
sui/
├── Makefile                     # 服务端构建/测试入口
├── README.md                    # 项目总览（薄入口）
├── ARCHITECTURE.md              # 架构入口（薄入口，指向本文件）
├── DEVELOPMENT.md               # 开发入口（薄入口）
├── LICENSE / CONTRIBUTING.md / CHANGELOG.md
├── CODE_OF_CONDUCT.md / SECURITY.md
├── docs/                        # 详细文档
│   ├── index.md / getting-started.md / architecture.md
│   ├── api-reference.md / deployment.md / troubleshooting.md
│   ├── guides/                  # 用户指南、网页剪藏
│   └── examples/                # 代码示例
├── protos/                      # 同步协议定义（预留）
├── server/                      # Go 服务端
│   ├── cmd/sui-server/          # 入口
│   └── internal/
│       ├── api/ auth/ blob/ clip/ cors/ store/ sync/ version/ ws/
├── extension/                   # Chrome MV3 剪藏扩展
└── clients/
    ├── note_core/               # 多端共享核心（纯 Dart，不依赖 Flutter）
    │   ├── lib/src/
    │   │   ├── db/              # app_database.dart + connection/（平台条件导入）
    │   │   ├── blob/            # blob_store / local_blob_store* / cached_blob_store
    │   │   ├── models/          # Note / Notebook / Tag / Revision / Attachment
    │   │   ├── repository/      # note_repository.dart
    │   │   ├── sync/            # sync_client.dart
    │   │   └── util/            # ids.dart / mime_kind.dart
    │   └── test/                # 466 用例
    └── flutter_app/             # Flutter 客户端
        ├── lib/src/
        │   ├── app.dart / main.dart / bootstrap.dart
        │   ├── platform/        # 数据目录 / 附件选择 / 生命周期 / 多窗口接缝（均条件导入）
        │   └── ui/              # 三栏外壳 / 编辑器 / 修订面板 / 附件卡片 / 独立笔记窗口
        ├── web/                 # index.html / sqlite3.wasm / drift_worker.dart(.js)
        ├── android/ ios/ linux/ windows/ macos/
        └── test/
```

## 8. 当前状态与已知缺口

> 本节用于区分「设计目标」与「已落地」。变更历史见根目录 `CHANGELOG.md`。

### 8.1 已落地并验证

- **服务端**：Go 构建通过、`go test ./...` 全绿；`ping` / `register` / `login` / `push` / `pull` /
  `blobs`(HEAD/PUT/GET) / `revisions` / `clips` / `ws` 全部实测正常，鉴权 401、密码错误 401、
  已建号后重复注册 403、坏 body 400、不存在资源 404、`base_version` 冲突 `accepted=false` 均正确。
- **note_core**：466/466 测试通过（仓储 CRUD / 标签 / 搜索 / 修订 / 同步 / 附件引用计数与上传 /
  缓存 LRU / 配置存取 / 落盘持久化 / 笔记本排序 / 编辑器格式化（含图片块级插入）/
  逐项同步状态与核对补齐 + e2e 同步等）。
- **flutter_app**：199/199 测试通过（含**真服务端**端到端：注册连接 → 本地新建 → 同步 →
  第二台设备拉取到；格式模式图片渲染与尺寸手柄、块级图片下方留出行高；编辑器增强的快捷键 /
  勾选框 / 高亮与「打开不编辑」保真用例；窄屏紧凑模式行与附件弹窗；窄屏历史入口（整页推入
  修订面板、返回两级）；桌面外壳 12 项：折叠 /
  展开与持久化、菜单命令等价与置灰、编辑模式跨重启、窄屏不渲染、落盘失败不阻断刷新；
  桌面多窗口 12 项：开窗 / 去重聚焦 / 两面并行 / 关闭全部窗口退出与附件列表跨窗口隔离）。
- **同步链路**：`SyncClient` 已实例化并注入 `CachedBlobStore`，push/pull + WS 通知已接线。
  同步触发点有三：编辑防抖 0.7s 推送、WS 通知拉取、**30s 周期兜底**（让「断网改动在恢复
  网络后自动补上」成立，而不必等用户再编辑一次）。
- **笔记本 / 标签同步**：服务端新增 `notebooks` / `tags` / `note_tags` 三表，push/pull 净荷
  扩展为 `items` + `notebooks` + `tags`；笔记条目携带 `notebookId`（指针语义）与 `tagIds`
  全量集合；复用 `base_version` 冲突与墓碑机制，新设备首拉即可重建完整分组树与标签。
- **整理与归档（M2）**：笔记归属调整、排序、置顶 / 归档 / 删除；笔记本排序与软删除（删除
  笔记本级联把其笔记置入回收站）；左侧栏底部「归档」「回收站」入口（回收站支持查看 + 还原到
  原笔记本或「全部笔记」）；全部标签总览统计 + 多选筛选。
- **格式化编辑（M2）**：编辑器「格式 / 源码 / 预览」三态，Markdown 唯一正本；格式工具栏与
  图片插入 / 尺寸调整（手柄 / 预设）即时回写 `content`；服务端 `notes` 表新增 `archived` 列。
- **界面配色（M2）**：左侧栏 `RGB(34,34,38)`、中间栏与编辑栏白底；「新建笔记本」按钮置于左栏顶部。
- **附件映射**：随笔记 push/pull 全量交换（含墓碑），服务端 blob `refcount` 由映射驱动；
  字节仍按需下载，映射同步不触发字节传输。
- **附件上传**：新增附件先落本地 → 写映射 → 尽力上传，失败留待 `backfillBlobs()` 在同步
  周期补传；push 前先补字节，避免对端拿到映射却下不到字节。
- **附件 UI**：编辑器格式工具栏「附件」入口（`file_picker` 跨端取字节）→ 弹出**附件面板**
  （`AlertDialog`，列出全部附件，四态：已同步 / 待上传 / 仅本机 / 未下载）+ 预览 / 格式态内
  `sui://<sha256>` 图片渲染。图片以**独占块**插入正文（块高向下撑开，后续文字下移、光标可越过）。
- **Web 构建**：`flutter build web --release` 成功；真实浏览器验证启动、IndexedDB 落库。
- **平台脚手架**：`web/` + 桌面/移动五端目录均已就位，应用显示名统一为「随手记 Sui」；
  Linux 桌面实测只差宿主编译工具链。
- **代码质量**：`flutter analyze` 两个包 0 问题。
- **测试稳定性**：两个 e2e 起服务端由固定 `sleep 1.5s` 改为轮询 `/healthz` 探活，
  消除机器繁忙时的「连接被拒」假失败。
- **单用户服务化（M4）**：服务实例即单用户笔记库；首启建号后关闭自助注册（403
  `already-initialized`），`/api/v1/ping` 回带 `initialized` 供客户端判定首启状态。
- **安全加固（M4）**：密码以 PBKDF2-HMAC-SHA256（100000 次迭代）+ 每用户随机盐存储，
  登录常量时间比对，老库明文密码首登自动升级为哈希；WS 端点须 Token 鉴权；CORS 支持
  `SUI_ALLOWED_ORIGINS` 白名单（未配置时开发模式全允许）；会话以 `sessions` 表为唯一
  真源，支持多设备登录。
- **剪藏 id 与唯一性（M4；`v0.13.3` 修订）**：剪藏 id 为 `clip-<32hex>`（≥128 bit）；
  **`v0.13.3` 起唯一性一律按 `noteId`** —— 每次剪藏都新建一条笔记（同 URL 也各自成篇），
  `notes.source_url` 由「幂等键」降级为**来源标记**（溯源 + 收件箱判据）。
- **编辑器交互增强（M5）**：格式态新增与工具栏**同源**的编辑快捷键（加粗 / 斜体 / 删除线 /
  高亮 / 任务项 / 列表 / 引用 / 代码块 / 分隔线 / 链接 / 标题 / 缩进 / 清除格式，撤销重做沿用
  原生栈）；GFM 任务列表 `- [ ]` / `- [x]` 可点选勾选框（仅改写方括号内字符，逐字符回写）；
  `==高亮==` 在格式态与预览态**均**渲染（`tertiaryContainer` 底色）；块级呈现单元（标题 / 列表 /
  引用 / 代码 / 分隔线）与空块回车退出的聚焦式呈现。以上均为**呈现层**能力，正本 Markdown
  字节不变（「打开 →（不编辑）→ 关闭」逐字节保真，BR-32.1 / AC-91 / AC-93）。
- **剪藏全页快照与图片本地化（M6）**：`POST /api/v1/clips` 新增 `mode`（`article` 默认 /
  `snapshot`）；`snapshot` 保留整页结构与文档顺序（标题 / 表格 / 图注保序），产出**语义等价**
  Markdown（非逐像素还原）。两种模式均**尽量本地化正文图片**（下载 → `sha256` → 附件库 →
  正文改 `sui://<sha256>`，映射随笔记入库），**原网页下线后图片仍可从附件库读取**；单图
  失败 / 超限降级为**保留绝对外链**（不阻断整篇），数量经响应 `unlocalizedImages` 回带。
  Chrome 扩展新增「智能提取正文 / 全页快照」分段控件（默认 `article`、记住上次），采集时
  等待完整 DOM 并触发懒加载图片。幂等键为 `notes.source_url`，与 `mode` 无关。
- **桌面端界面布局优化（M7）**：桌面端左栏（笔记本树）与中栏（笔记列表）可**分别**折叠 / 展开，
  折叠后面板与其分隔线一并消失，得到纯编辑区沉浸写作；顶栏左上角新增**自绘菜单栏**
  「文件 / 编辑 / 视图 / 帮助」，菜单项与顶栏图标按钮、编辑快捷键**同源**（`desktopCommands`
  单一来源），不可用命令**置灰**、有状态命令显示勾选、快捷键以右侧提示呈现。折叠状态与
  「格式 / 源码 / 预览」编辑模式为**本机视图偏好**（`ui.leftPanelCollapsed` /
  `ui.noteListCollapsed` / `ui.editorMode`），**重启后保持**且**不进同步**；经菜单「退出」时
  先 `flushPendingEdits` 落库、再尽力推送后退出。**窄屏 / 移动端 / Web 不渲染**菜单栏与折叠
  开关，既有响应式导航**不回归**（FR-40 / FR-41）。
- **移动端编辑布局与图片块级插入（M7 补丁 / v0.8.2，B17 / B18）**：窄屏（编辑列宽 < 520px）
  模式行改**紧凑单行**——「格式 / 源码 / 预览」只留图标，与「历史 / 导出」压成一行并收紧上下
  留白，**保留格式工具栏**；常驻底部的附件条**移除**，改由格式工具栏「附件」按钮弹出附件面板，
  为正文腾出编辑高度。图片引用以**独占块**（前后 `\n\n`）插入，编辑器正文显式
  `strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: false)`——解除 `EditableText`
  默认按 strut 高度强制排行的约束（该默认会**忽略较高的行内 `WidgetSpan`**，导致图片溢出本行
  遮挡后续文字、光标无法越过），使块高向下撑开、后续文字整体下移（AC-135 / AC-136）。
- **桌面端独立笔记窗口（M8）**：桌面端可将笔记在**独立 OS 窗口**中打开 —— 所有窗口共享
  同一 Flutter 引擎 / isolate（**单引擎多视图**），因而共用同一 `AppController`、drift SQLite
  连接、`SettingsStore` 与附件缓存，窗口间通信为**纯 Dart**、无 IPC / 序列化。同一笔记
  **一笔记一窗口**：重复打开即**聚焦**（已最小化则先还原）；主窗口**照常保留**该笔记的编辑面
  （两面并行、可同时编辑、实时互相同步），两窗口指向**同一条**笔记记录。窗口局部与全局状态**分治**：`selectedNotebookId` /
  `selectedNoteId` / 搜索 / 标签筛选 / 排序为**全局**（独立窗口**不得**改写 —— BR-42.2 / AC-125），
  而 `ui.window.note.editorMode`（编辑模式）与**当前编辑笔记的附件列表**为**窗口 / 编辑器局部**
  （附件刷新以 `refreshAttachments` 返回值取自该笔记，**不回读**全局字段）。编辑器命令目标按
  **视图键**索引（主窗口固定 `kMainViewKey = 'main'`、独立窗口取窗口句柄），由焦点事件驱动
  `setActiveViewKey` 路由命令。生命周期：窗口注册表预置主窗口，关闭**全部**窗口即退出应用；菜单
  「退出」= `flushPendingEdits` → 尽力推送 → 关闭全部窗口 → 退出（FR-42 / FR-43 / BR-42 / BR-43）。接缝
  `NoteWindowManager` / `WindowEventHub` 平台无关，窗口语义可在纯 Dart 单测中驱动（12 项）。
- **编辑器编辑能力与附件体验增强（M9 / v0.10.0）**：在「Markdown 唯一正本」原则不变的前提下
  （架构零改动，与 M5 同一范式），补齐编辑器五大编辑能力：
  - **表格工具（FR-44）**：格式工具栏「表格」按钮 → 自定义行列数对话框 → 光标处插入 GFM
    管道表；表格呈现单元内置行/列增删按钮，改动即时回写 Markdown 正本。
  - **粘贴保留格式 + 简化格式（FR-45）**：Ctrl+V 富粘贴——剪贴板 HTML → Markdown 转换
    （表格 / 列表 / 引用 / 粗斜体 / 链接 / 代码等），无法转换时降级纯文本并转义 Markdown 特殊字符；
    Ctrl+Shift+V 纯粘贴——纯文本转义后插入。工具栏「简化格式」一键剥离行内格式（粗/斜/删/
    高亮/行内代码），保留块级结构（列表/引用/代码块/表格）。
  - **附件整体编辑单元（FR-46）**：`[name](sui://<sha256>)` 附件引用在格式态渲染为整块「附件
    胶囊」，退格/删除键整块移除（而非逐个字符删除），残缺引用自动自愈；源码模式不受约束。
  - **附件预览与外部编辑回写（FR-47）**：点附件卡片弹出预览弹窗——文本（只读截断）/ 图片
    （缩放）/ PDF 与其他（元信息卡）；「用系统默认应用打开」启动外部编辑器，文件变更后自动
    回写（新 sha256 → 更新正文 `sui://` 引用 → 上传同步），一处变更多端可见。
  - **有序列表自动编号（FR-48）**：Markdown 正本统一 `1.`（写回时不递增），格式态与预览态
    按 DOM 顺序渲染为 1. / 2. / 3.；手动输入非 1 数字或空行隔断后编号重启。
  所有能力均为**呈现层 / 编辑器层**增强，Markdown 正本字节在「未编辑」时逐字节不变
  （`FormatNoTouchFidelity` 门禁 8 条全绿）。
- **格式模式「所见即预览」与表格边界保护（M9 补丁 / v0.10.13）**：在正本仍为 Markdown 的前提下
  （架构零改动），把「格式」模式收敛为与「预览」同源的所见即所得呈现：
  - **记号彻底不可见（BR-23.7 / AC-172）**：凡被解析为语法的字符（`**` / `__` / `*` / `_` / `~~` /
    `==` / `` ` `` / `#` 前缀 / `- ` / `1. ` / `> ` / 围栏行 / `---` / 链接语法）一律以**零宽 +
    透明**的等码元替身呈现，改由真实格式承载（粗体 / 底色 / 标题字号 / 项目符号 / 连续编号 /
    勾选框 / 引用竖条 / 水平线 / 仅链接标签）；**未识别**的记号仍按普通文本显示——两态可见文本
    逐例比对（`FormatPreviewParity`）。扫描口径与预览同源：围栏内部、良构表格内部不扫描，
    缩进越界的行不建立行级前缀记号。
  - **格式单元原子化（BR-23.8 / AC-173 / AC-174）**：折叠光标**不停在记号内部**（自动跨到外侧
    边界，内容仍可编辑）；删除键命中记号时**一次取消整处格式**且内容逐字保留（成对记号去整对、
    行级前缀去整行、围栏 / 分割线连行移除），选区删除不留残缺记号。
  - **缩进只产出 GFM 合法结构（BR-23.9 / AC-176）**：无合法父列表项时最多缩进到 3 个空格
    （再缩进原样不动），有父列表项时落在合法层级内；缩进越界的行在两态都按普通文本呈现，
    杜绝「格式态是勾选框、预览态是 `[ ]` 字面量 / 缩进代码块」。
  - **表格永不「打回原形」（BR-44.11 / AC-175）**：表格首 / 末行两侧的换行受保护，任何编辑不得
    把表格行与相邻行文字**合并**——命中边界时按「先取消相邻行的块级记号 → 空行允许默认合并 →
    其余吞掉按键」处理；`Backspace` 落在表格下方默认空行行首仍整块删表（BR-44.6 不回归）。
  - 表格**单元格内**亦复用同一套行内记号隐藏与原子删除（§12.1.2 延伸）。
- **超链接弹框录入与工具栏快捷键提示（M9 补丁 / v0.10.14）**：同为编辑器层增强，正本仍为 Markdown（守 BR-23.1）：
  「链接」由「插入 `[文字](url)` 占位文本」改为**弹框录入**（显示文字 + 网址；网址为空**不落笔**；显示文字留空
  以网址充当；未写协议自动补 `https://`，`mailto:` / `#锚点` / `/相对路径` 原样保留），`Ctrl+K` 与工具栏按钮
  **同源**走同一路径；表格**单元格内**亦可插入链接（上下文栏「链接」按钮 + **单元格获焦时**正文工具栏的「链接」
  路由到该单元格，以 `<br>` 软换行追加、其余单元格逐字不动）；工具栏按钮的悬浮提示带**键位说明**
  （`加粗 (Ctrl+B)`），键位由编辑器 `Shortcuts` 表**反查**生成（单一来源，改键位提示自动跟随），
  顺带补齐「插入表格」的 `Ctrl+Shift+T`（桌面「编辑」菜单同步显示）。

- **认证与会话（M10 / FR-49）**：服务端签发**短时访问令牌（30 分钟）+ 可撤销刷新令牌（30 天）**，
  刷新为**单次使用 + 轮换**；轮换时把旧哈希挪到 `prev_refresh_token_hash`，故**重放旧刷新令牌**可被识别
  并**吊销整个会话**（`refresh-revoked`）。401 错误码**可区分**（`token-expired` / `invalid_token`），
  客户端据此**单飞刷新 + 重放一次**（并发去重；`invalid_token` 亦允许一次性刷新，见
  `auth.md` §8.5 —— 该详细设计文档随项目技术文档单独维护，不随本仓库发布）。
  会话与 WS 连接**绑定**：会话被吊销即断开连接。
- **受保护通道（M10 / FR-50）**：`http://` 地址下应用层加密，`https://` 走 TLS 不叠加。
  服务端持有**长期 X25519 密钥**（`<数据目录>/securechan.key`，0600），客户端经
  `GET /api/v1/crypto/handshake` 取公钥 + 指纹并 **TOFU** 记录，**指纹变化即阻断**。
  逐请求：临时 X25519 → ECDH → HKDF-SHA256 → `K_chan`，正文以 **AES-256-GCM** 封装为
  `base64(ver|alg|nonce|ct|tag)`，`AAD = method\npath\nreqId`，请求头
  `X-Sui-Enc` / `X-Sui-Eph` / `X-Sui-Req-Id`；服务端维护**有界重放缓存**（TTL 5 分钟 / 4096 条）。
  客户端接缝在 **`http.BaseClient` 包装层**，push/pull 与合并逻辑**零改动**。
- **加密笔记本（M10 / FR-51）**：笔记本级**端到端加密**，服务端**只搬密文、无解密分支**。
  `K_nb = HKDF-SHA256(Argon2id(锁定密码, salt, m=64 MiB, t=3, p=1), info="sui-notebook-v1")`，
  `verifier` 用于快速校验密码；密钥**只驻内存、不落库、不上行**（回锁即删）。
  字段密文为同一 `ver|alg|nonce|ct|tag` 封装，`AAD` 绑定「笔记本 + 笔记 + 字段」（防密文搬运）。
  落库/传输层加密，**编辑器与合并逻辑仍以 Markdown 明文为正本**；**未解锁端**列表显示占位、
  不进编辑、不纳入搜索；空闲 **15 分钟自动回锁**（可配置，活动续期）。
- **测试现状（M10 收口）**：服务端 Go 测试全部通过（M10 新增 `m10_test.go` / `m10_auth_test.go` /
  `m10_clip_test.go` / `m10_encnotebook_test.go` / `m10_securechan_test.go` / `m10_transport_test.go`
  与 `internal/securechan/channel_test.go`）；`note_core` **294 项**（含 5 个 e2e：同步、受保护通道、
  加密笔记本跨端、令牌刷新、既有同步链）；`flutter_app` **171 项**。加密封装另有 **Spike 向量**
  （`sui-crypto-v1`）在 Go 与 Dart 两侧**逐字节**门禁。

- **逐项同步状态与云端核对补齐（M12 / v0.12.0，FR-53 ~ FR-55）**：`notes` / `notebooks` / `tags`
  三表新增本地状态列（五态 `已同步` / `待上传` / `仅本地` / `冲突` / `同步失败`），界面就地呈现
  状态图标与缘由（悬停可见，窄屏降级为状态点）；支持单项「立即上传 / 重试」与全局
  「全部重新同步」（核对 → 补齐，可取消、幂等、给出逐项结果与失败原因）。上行队列改由库中状态
  **重建**（内存 Outbox 退役）；服务端 push 逐项裁决显式化（`notFound` + 显式 `serverVersion: 0`），
  使「换服务端 / 服务端重建后推不上去」可自愈；拉取游标持久化并回退 1 秒；服务端新增 `meta` 表
  与**云端实例身份** `instanceId`（`pull` 恒下发 / `ping` 仅鉴权时下发），换库 / 重建由用户在
  三选一提示中决断（**选择前不动任何一端数据**）。状态为**纯本地记账**，Markdown 正本与
  同步净荷均不变（架构零改动）。
- **测试现状（M12 收口）**：`note_core` **329 项**全量通过（M12 新增 `sync_status_m12_test.dart` 15 项
  + `schema_migration_v8_test.dart` 1 项）；服务端 `go test ./...` 全绿（M12 新增
  `internal/api/m12_test.go` 4 项）；`flutter_app` **171 项**全绿（含**新增**同步状态图标与单项 / 全局入口的
  widget 用例 12 项）；**Windows 桌面目标** `flutter build windows --debug` 通过。

### 8.2 历史缺口（均已修复）

| # | 缺口 | 状态 | 影响 |
|---|------|------|------|
| 1 | 同步链路未接线：`SyncClient` 从未实例化，`blobStore` 从未注入 | ✅ 已修复 | 客户端原为纯本地编辑器；附件按需下载/LRU 机制曾是死代码 |
| 2 | 无登录 / 服务端地址配置 UI | ✅ 已修复 | 客户端原无法连接服务端 |
| 3 | 服务端 `attachments` 表为半成品（建表但无读写方法与协议字段） | ✅ 已修复 | 附件-笔记映射无法跨端重建 |
| 4 | 无附件上传 / 选择器 | ✅ 已修复 | 用户无法添加附件 |
| 5 | 缺桌面/移动平台脚手架目录 | ✅ 已修复 | 这些端暂不可构建（代码路径已就绪） |
| 6 | `lib/src/home_page.dart` 为 M0 死代码 | ✅ 已修复 | 冗余，易误导 |
| 7 | README / 开发者文档的运行命令与实际不符 | ✅ 已修复 | 按文档操作会失败 |
| 8 | 文档「核心特性」全 ✅ 但部分未在客户端生效 | ✅ 已修复 | 认知偏差 |
| 9 | 笔记本分组 / 标签 / 笔记-标签关联无云端存储与同步 | ✅ 已修复 | 换设备后分组树与标签不跟随；M1 补齐服务端三表 + 协议净荷 |
| 10 | WebSocket 端点无需鉴权，任意客户端均可订阅变更广播 | ✅ 已修复 | 未授权方可感知笔记变更；M4 起 WS 须 Token 鉴权 |
| 11 | 剪藏笔记 id 与手写笔记共用 64 bit 摘要命名空间、可能碰撞 | ✅ 已修复 | 剪藏可能覆盖同名笔记；M4 起改为 ≥128 bit 摘要；**`v0.13.3` 起按 `noteId` 每次新建**（不再按 URL 判重） |
| 12 | 换服务端 / 服务端重建（回滚）后本地实体基线非 0 而云端无记录 → 永久冲突、再也推不上去（B24-①） | ✅ 已修复 | 改动永久卡在本机；M12 起服务端回 `notFound` + 显式 `serverVersion: 0`，客户端基线归零并同轮重发 |
| 13 | 上传意图只存在于内存 Outbox（B24-②） | ✅ 已修复 | 重启 / 换服务端后未上传改动静默滞留本机；M12 起上行队列 = 库中 `sync_state`（状态即队列） |
| 14 | 拉取游标为进程内且无回退（B24-③） | ✅ 已修复 | 同一秒内的多条变更被永久漏拉；M12 起游标持久化于 `settings` 并取 `max(updated_at) − 1s`（下行幂等，重放安全） |

### 8.3 未实现的设计项

- 缩略图生成（附件方案 C）。
- 桌面端「全量镜像」开关。
- Web 端 BlobStore 的 IndexedDB 实现（当前为内存）。
- FTS5 全文搜索（当前为 `LIKE` 子串匹配；表结构已预留）。
- 富文本 WYSIWYG 编辑器（`flutter_quill` 升级，当前为「格式 / 源码 / 预览」三态）。
- **WS 升级头不在受保护通道内**（M10 已知边界）：浏览器无法自定义 WebSocket 升级请求头，故
  `Sec-WebSocket-Protocol: bearer.<token>` 在 `http://` 下对被动观察者可见。加固方向：经加密通道
  换取**一次性短时 WS ticket**。
- **加密笔记本的服务端检索**：服务端只见密文，故**服务端无法对加密笔记本做全文检索**；
  客户端在**解锁后**于本端对明文搜索（未解锁不纳入搜索范围）。
- **加密笔记本内附件字节的静态加密**：映射随笔记同步（明文元数据），字节仍内容寻址、
  仅**传输时**加密；静态加密列为将来可选项（未解锁时访问入口隐藏）。
- **Argon2id 解锁耗时的真机数据**：现仅测得 WSL2 VM 上 m=64 MiB / t=3 / p=1 ≈ **937 ms**；
  Android / iOS / Web 未实测（Web 端为纯 Dart 或 WASM 兑算，风险最高）。
- **通道正文整包缓冲**：请求与响应均先整体缓冲再加解密，单请求峰值内存约 2× 报文大小；
  流式加密为后续优化项。
- **核对补齐首版做「带正文」的全量 pull**（M12 已知取舍）：`reconcile()` 以 `pull?since=epoch`
  取云端全量权威态，因此首次核对会把所有笔记正文拉一遍；数据量大时首轮较慢，但**幂等且只此一次**。
- **`pull?meta=1` 精简清单**（演进项，当前未实现）：另提供「只回 id / version / isDeleted 的轻量
  清单」用于核对，可把首轮全量 pull 降为清单比对 + 按需拉正文。
- **标签的同步状态目前仅落在数据层**：`tags` 已有五态记账，但界面尚未为标签单列状态入口
  （笔记列表与笔记本树上的状态可就地辨认）。

### 8.4 M10 安全加固的实现要点（FR-49 / FR-50 / FR-51）

| 关注点 | 结论 |
|--------|------|
| 分层 | 受保护通道保护**线路**（服务端可解密）；加密笔记本保护**数据本身**（服务端不可解密） |
| 密钥来源 | 通道密钥**逐请求**由临时 X25519 协商（天然前向保密）；笔记本密钥由锁定密码派生，**不落库、不上行** |
| 服务端口径 | **只搬运密文**：`notebooks.encrypted` / `crypto_meta`、`notes.encrypted` 三个线上字段 **透传不解析** |
| 明文兼容 | 通道是**加成**而非强制：未声明 `X-Sui-Enc` 的请求照常处理（同一二进制要服务未升级客户端） |
| 未解锁语义 | 列表占位、不进编辑、不搜索；**未解锁拒绝写入**（否则会把占位当内容覆盖密文） |
| 形态转换 | 移入/移出加密笔记本**就地加解密**（含既有修订）；同本移动幂等；解锁态不可得时**拒绝移动** |
| 冲突合并 | 加密笔记的合并**在明文层**完成；未解锁端**不就地合并**（保持排队），保证「绝不丢字」 |
| 重放防护 | 刷新令牌**单次使用 + 轮换 + 旧哈希留存**；通道请求 id**有界缓存**去重 |

### 8.9 M12 修订（`v0.12.2`）：会话入口统一、本地存储位置与登录防护

三项用户诉求归口，均**不改变** Markdown 唯一正本与同步协议净荷（FR-57 / FR-58 / FR-59）：

- **会话入口统一（FR-57）**：客户端「同步设置」删除手工令牌输入（`connectWithToken` 保留为
  内部 / 测试装配 API）；剪藏扩展新增账号密码登录，令牌（访问 + 刷新）存 `chrome.storage.local`，
  请求 401 时**单飞刷新 + 重放一次**，刷新失败即清令牌并要求重新登录，**不保存口令**。
  扩展**不实现**应用层受保护通道（内容本身公开、简化设计）→ 公网必须使用 `https://`，
  设置页对 `http://` 非本机地址给出警示。
- **桌面端本地存储位置（FR-58）**：数据目录由**库外引导指针** `<应用支持根>/storage.json`
  （原子写）决定；「同步设置 → 本地存储」可把 `sui.sqlite` 与 `blobs/` 迁移到任意可写目录，
  过程为「落盘（`wal_checkpoint`）→ 复制 → 校验（关键表行数 + 附件数与总字节）→ 原子切换指针
  → 重启生效」事务，**失败不切换指针**、旧目录保留。指针目录不可用时启动**整屏阻断**并三选一
  （重试 / 改回默认目录 / 重新指定），**绝不静默回落**默认目录。迁移期间控制器进入维护态，
  暂停同步调度；与本机目录无关的服务端数据 / 会话 / 设备 ID 均保持不变。
- **登录失败防护（FR-59）**：`server/internal/api/login_guard.go` 在 `POST /api/v1/login` 前置判定，
  键 = `lower(username) + 来源`；≥5 次起指数退避（上限 30s），≥10 次锁定 15 分钟，
  锁定返回 `429` + `Retry-After` 且**正确口令同样被拒**，成功即清零；**同键串行化**防止并发
  请求把延迟放大为 DoS；键表 LRU 有界。状态只驻内存（**重启即解锁**，单用户自托管逃生口），
  失败 / 锁定 / 解锁写审计日志且**不含口令**；阈值环境变量化、时钟可注入（门禁不因真实等待变慢）。
  部署侧配套 nginx `limit_req` / `limit_conn` 作为第二层（详见部署文档 §11）。

**测试现状（本版新增）**：服务端新增 `m12_login_guard_test.go` **10 项**（退避 / 锁定 /
锁定拒绝正确口令 / 成功清零 / 重启解锁 / 审计不含口令 / 账号存在性响应一致 / 默认不信任
`X-Forwarded-For` / 开启信任后按最右跳 / 关闭防护），`go vet` 与 `go test ./...` 全绿；
`flutter_app` 新增 `storage_location_test.dart` **10 项**与 `storage_settings_test.dart` **6 项**，
`flutter analyze` 无问题；扩展侧新增 Node 自动化门禁 `extension/test/session_test.mjs` **9 项**
（登录 / 主动刷新 / 401 单飞刷新重放 / 并发单飞 / 刷新被拒清令牌 / 明文警示 / 剪藏带会话，
`node --test` 运行），**popup 界面与站点权限弹窗仍为真机手测**。

**补丁 `v0.13.1`（真实用户数据验收）**：用户导入 29 篇**印象笔记 Windows「导出为网页」**后报障
「正文出现 `<br>` + 布局问题」。根因是**旧版导出结构**（`<a name="…"/>` 按 HTML 规则不闭合，把整个
正文吞成子节点；`<span>` 内嵌 `<div>` 属非法嵌套）被块级探测漏掉（当时只看**直接子元素**），
整篇被当成一个段落 → 段界退化成行内 `<br>`。修法：① 块级探测**穿透行内包装**（`a` / `span` /
`font`…）找块级后代，并给 `<a>` / `<p>` 加同样守卫；② 段落内软换行改写**真换行**（与段落内
`Shift+Enter` / 粘贴链路同口径），**仅表格单元格内保留 `<br>`**（复验：29 篇残留 `<br>` 全部位于
表格行内）；③ 递归导入跳过**导出资源目录**（`<stem> files` / `_files` / `.resources`，仅当同级存在
同名笔记文件）；④ 导入指纹只认**存活**笔记（删除后可重新导入）；⑤ **嵌套资源残留占位符**
（`<a href="…"><img src="…"></a>`：外层链接的链接文字就是内层图片的占位符，单趟替换会把它「注入」
回正文；debug 下整篇失败、release 下链接里的图片静默丢失）→ 资源本地化改为**替换到不动点**。
另附**真实数据端到端复验**：`FileImportService` 全链路跑 29 篇真实导出 → 成功 29 / 跳过 0 / 失败 0 /
未本地化 0，`<br>` 表外 = 0，97 个 `sui://` 引用对应 97 条附件映射，重导全跳过，删 1 篇后重导可重建。
详细设计 §15.1 记录根因与复验口径。

**补丁 `v0.13.4`（第二轮真实数据验收）**：用户报障「附件显示错乱」（正文露出 `](sui://…)` 残余、
附件单元标签前多一个 `!`）。根因是 `v0.13.1` 的「替换到不动点」把「链接包图片」
（`<a href="文件"><img src="缩略图"></a>`，实测 7 处）组合成 `[![名](sui://缩略图)](sui://文件)`
**嵌套引用**，而客户端识别 `sui://` 引用用的是**扁平正则**（只认单层 `![…]` / `[…]` + `sui://`），
于是把 `![名` 吃成标签、sha 取内层图片，剩余 `](sui://文件)` 当字面量渲染。修法：**导入侧保证引用永不
嵌套**（外层附件胜出、内层只贡献标签）+ 形态按目标扩展名（图片 → `![]`、其余 → `[]`，无扩展名仍按图片）
+ **未被引用的资源不落盘、不建映射**。复验：29 篇端到端成功 29 / 失败 0 / 未本地化 0、**嵌套 = 0**、
`<br>` 表外 = 0、`sui://` 引用 90 ↔ 附件 90。

**补丁 `v0.13.5`（第三轮真实数据验收）**：用户报障「列表前有斜杠 `1\.`」。① 转换器**自产**的有序
列表标记被 `_escapeLineStart` 的「源文本字面 `1. ` 不当列表」保护一并转义，且标题副本去重**删行后
行号集合漏平移**（新增的列表标记行集合未登记）→ 每组列表只剩**首项**残留；② 顺带发现更严重的
**内容丢失**——`<ol>` 里作为**兄弟**出现的 `<ul>`（非法嵌套，剪藏常见）被 `_renderList` 整段丢弃，
实测 `AIGC生图和视频市场` 只剩 **29%**。修法：自产列表标记行不做行首转义（`addListItemLine` +
`_preserveListMarkerLines`）+ 删行统一平移所有行号集合（`_Renderer.removeLineAt`）+ 取消有序列表
前缀的 `\.` 转义（手写编号按列表项呈现）+ `_renderList` **归一化非法嵌套**（兄弟列表归入前一个
`<li>`）。复验：29 篇**行首转义项 = 0**、产出/源 = 97.3%、该篇 427 → **1598** 字符。

### 8.10 M13（`v0.13.0`）：批量导入本地文件到笔记本

把本机既有的 `.md` / `.markdown` / `.txt` / `.html` / `.htm` 文件（含**印象笔记「导出为 HTML」**
的产物）一次导入到**当前选中的笔记本**（FR-60 / FR-61 / FR-62）。设计要点：

- **全程在客户端**：转换与落库都在 `note_core` 的 `lib/src/import/`（纯 Dart），
  **不新增服务端接口、不改变 push / pull 净荷**，因此**离线可用**、Web 端同样可用；
  平台层只负责「取字节」与「解析 HTML 里的相对资源路径」（条件导入，
  Web 端相对资源一律降级）。
- **HTML→Markdown 为新增的 DOM 式转换器**（`package:html` 负责容错解析 + 转换规则自研），
  与 M9 剪贴板粘贴用的正则实现 `EditorFormat.htmlToMarkdown` **各自演进**、互不影响。
  图片 / 链接在转换产物中以**节点级占位符**（Unicode 私有使用区 `\uE000<n>\uE001`）表示，
  由导入服务在**取到字节后**替换为 `sui://<sha256>` 或降级文本——转换器本身**不做 IO**，
  因而可纯函数化测试。
- **印象笔记结构适配**：正文容器 `<en-note>`（自定义元素）→ `div.html-note` 分节 → `body`；
  标题 `meta[itemprop=title]` → `h1.noteTitle` → 首个 `h1` → 文件名（**只输出一次**）；
  逐行 `<div class="para">` 成段（仅含 `<br>` 者为空行）；`li` 内
  `input.list-bullet-todo` / `aria-checked` → **GFM 任务列表**；`<style>` / `<icons>` / `<svg>` /
  `meta` / `note-attributes` 与注释一律丢弃；「单个网页」导出含 **≥2 个 `div.html-note`**
  → **拆成多篇**；文件名以 `index` 结尾且无 `en-note` / `div.html-note` 者判为**导出索引页**并跳过。
- **附件本地化复用既有能力**：本地相对资源（印象笔记的资源目录实测为 `<笔记标题> files/`，
  解析时按 basename 回退 `<stem> files` / `<stem>_files` / `<stem>.resources` /
  `resources` / 同目录，并**拒绝越出 HTML 所在目录**的路径）与 `data:` 内嵌图片解码后走
  `BlobStore.put`（内容寻址天然去重）→ 正文改 `sui://<sha256>`；远端 `http(s)` 图片
  **保持原 URL、导入不出网**（**不**复用剪藏的出网媒体本地化，避免新增 SSRF 面）。
  取不到字节的资源**保留 alt 文本 / 链接文字**并计入「未本地化资源」，单点失败不影响整篇；
  印象笔记官方 HTML 导出对**非图片附件没有可用链接**（只有 `data-resource-hash` 标记与
  「Untitled Attachment」文案）→ 保留显示文本、**不臆测归属**。
- **幂等与事务**：`sha256(标题 + 正文)` 指纹一次载入 / 命中跳过（同批内相同内容也只导入一篇）；
  每篇导入是**单一库事务**（笔记 + 首条修订 + 附件映射 + 引用计数 + 指纹），
  取消与异常不留「有修订 / 有附件却无正文」的中间态；进度按**文件**计、可取消且已导入的保留。
- **入口与命令同源**：桌面「文件 → 导入文件…」（`Ctrl+Shift+I`，经 `MenuItemButton.shortcut`
  注册到菜单栏）与窄屏 / Web 顶栏「更多 → 导入文件…」共用 `DesktopCommandId.importFiles`
  与同一份对话框实现；导入**不改动**当前选中笔记与编辑器草稿。

**测试现状（本版新增）**：`note_core` 新增 `import_source_test.dart` / `import_html_test.dart` /
`import_service_test.dart` 三个文件覆盖编码四态与降级、`.md` 保真、`.txt` 规整、HTML 全规则与
脏结构、印象笔记结构、单页多笔记拆分、索引页跳过、资源本地化与降级、`data:` 图片、远端不动网、
标题去重、尺寸映射、指纹去重、报告口径、单篇事务性、加密笔记本拒绝与限额；
`flutter_app` 新增 `file_import_ui_test.dart` 覆盖命令注册表与加速键、桌面菜单 / 窄屏「更多」入口、
对话框目标只读、文件夹入口平台门控、加密未解锁拒绝、报告计数与明细、导入不改变当前编辑状态。

### 8.11 剪藏缺陷修复与扩展分发（`v0.13.2`）

**① 「剪藏成功但收件箱里看不到」**。复现（真 Chrome 145 + 真扩展 + 真服务端，对
`https://www.news.cn/` 做全页快照）：浮层回「✓ 剪藏成功 v1」、服务端落库
`source_device='clip:web-extension'` / `source_url='https://www.news.cn/'`，但桌面端「收件箱」为空。
根因是**判据选错了字段**：「收件箱」原先按 `sourceDevice.startsWith('clip:')` 过滤，而
`source_device` 在服务端与客户端两侧的语义都是**「最近一次修改的来源设备」**（`store.go` 注释即如此），
客户端 `SyncClient._buildBody` **恒发** `'sourceDevice': deviceId` → 该笔记一旦被本机 push 过
（编辑 / 单项重试 / 「全部重新同步」核对补齐），标记即被改写，笔记**永久退出收件箱**。
修法：改用**不可变的剪藏来源标记**——`notes.source_url` 只由剪藏路径写入
（`SetNoteSourceURL` 且仅当原值为空），`push` 净荷不含、`UpsertNote` 不触碰；
`pull` 的笔记项新增 `sourceUrl`（`omitempty`）随增量下行，客户端落 `notes.source_url`
（drift `9 → 10`），判据 = `sourceUrl.isNotEmpty || sourceDevice.startsWith('clip:')`
（后者为**空 URL 剪藏 / 老服务端**的兜底）。字段与兼容性见
[同步协议 §15](https://gitee.com/evangubo/sui)（工作空间技术文档 `sync-protocol.md §15`）。

**② 剪藏响应被全局写期限切断**。`handleClip` 原先只 `extendReadDeadline`，而媒体本地化预算
（`clip.DefaultTotalTimeout`）是 **30s**、`http.Server.WriteTimeout` 是 **10s**：图多 / 图慢时
处理超过 10s，响应写不出去 → **笔记已落库、客户端拿到空响应**（`Failed to fetch`）。
修法：剪藏路由**读 + 写期限一并延长**（与 `PUT /blobs/{hash}` 同口径）。

**③ 剪藏扩展打包脚本**：`scripts/package_extension.sh`（+ `scripts/pack_crx.py`）产出
zip / **CRX3** / `update.xml` / `.sha256` / `INSTALL.md` 到 `extension/dist/`（不入库），
签名私钥默认 `$HOME/.sui/extension-signing-key.pem`（600、不入库，**扩展 ID 由公钥唯一决定**）。
桌面版 Chrome 不允许 off-store 直接装 `.crx`，故个人自用走「解压 zip + 开发者模式加载」，
受管机队走企业策略 + 自托管更新，对外发布走 Web Store（上传 zip）。

**测试门禁（本版新增）**：服务端 `clip_marker_test.go`（剪藏 → 本机 push → `sourceUrl` 不丢、
`source_device` 被改写、普通笔记不带 `sourceUrl`）与 `clip_deadline_test.go`（**真实 `http.Server`**
+ 小 `WriteTimeout` + 慢图床桩：修复前响应被切断）；`note_core` `clip_source_marker_test.dart`
（pull 下行 / 只下行不上行 / 兜底判据）与 `schema_migration_v10_test.dart`（v9→v10 迁移）；
`flutter_app` `inbox_clip_test.dart`（收件箱判据）。**红检**：分别回退三处修复，三个用例各自失败
（`EOF` / `sourceUrl` 缺失 / 收件箱里没有剪藏笔记）。

### 8.12 M14（`v0.14.0`）：客户端设置与外观（FR-63\~FR-68）

**统一设置中心**：桌面「文件 → 设置…」+ `Ctrl/Cmd + ,`、窄屏 / Web 顶栏「更多 → 设置」、
顶栏同步状态图标直达「同步与账号」；五分区 = **外观 / 同步与账号 / 本地存储（仅桌面）/ 附件缓存 / 关于**。
原「同步设置」对话框升级为其中一分区（`SyncSettingsPanel`），登录 / 断开、注册入口判定、设备 ID、
桌面端存储路径与迁移、缓存上限、「关于」**一项不丢**；入口走 `desktop_commands.dart` 单一来源
（新增 `openSettings`，加速键机制由 M13 的「仅导入」泛化为 `_ShellAccelerator`：遍历注册表中声明了
`activator` 的命令，与焦点无关）。「本地存储」分区**仅桌面渲染**，请求不可见分区时回落到第一个可见分区。

**主题三态（FR-64）**：`ui.themeMode` = `light` / `dark` / `system`（默认 `system`，非法值回落 `system`）。
`MaterialApp` 挂 `theme` + `darkTheme` + `themeMode`，**跟随系统交给框架**（`ThemeMode.system` 已监听平台亮度），
不自建亮度监听；桌面多窗口共享同一 `AppController`，故外观改动**跨窗口一致**。

**字体（FR-65 / FR-66）**：`ui.fontFamily.ui`（界面字体）与 `ui.fontFamily.body`（笔记正文字体）
两项独立；**源码模式与代码块恒为等宽**（不由设置决定）。候选按平台预置，并经
`FontAvailability`（`TextPainter` 同字号量宽比对**哨兵族名**，结果会话内缓存）**只列可用项**；
**不打包字体**；Web 端仅「跟随系统」（浏览器渲染器不提供宿主系统字体）并给出说明；
偏好中的字体不可用时**回退为跟随系统**并在「外观」分区标注。**笔记本默认字体**：
键 `ui.notebookFont.<notebookId>`（缺省 = 继承全局），左栏笔记本菜单「默认字体…」可覆盖 / 清除
（「跟随全局默认」= 删键），**删除笔记本时清理该键**。

**配色修正（FR-67 / FR-68）**：绿调来自绿种子派生的**中性角色**被大面积当底色用
（编辑区 `#F2F4F1`、工具栏 / 表头 `#DFE4DD`、代码块 `#ECEFEB`、附件卡片 / 选中态 `#D2E8D4`；
种子暗色的 `surface` 亦带绿调 `#0F1511`）。修法**两条腿**：①主题层把 `surface*` / `outline*`
覆盖为**中性灰阶**（一次覆盖全局去绿）；②使用点显式取值——编辑区 `#FFFFFF`、结构块 `#F2F2F2` / `#EAEAEA`、
代码块 `#F6F6F6` + `#E0E0E0` 边框、附件卡片与列表选中态 `#EFEFEF`；暗色用**显式中性深灰**
（`#141414` / `#1F1F1F` / `#1B1B1B` / `#242424`）。**品牌主色保留**在强调语义（按钮 / 选中指示 /
勾选框 / 链接 / 焦点），列表语义徽标（剪藏 / 独立窗口 / 归档）与标签选中仍取强调色。
`==高亮==` 由 `tertiaryContainer`（`#BEEAF7` 浅青）改**黄色系**（亮 `#FFF3A3` / 暗 `#4E4400`），
格式模式与预览模式**同源取色**。

**零改动声明**：**服务端零接口、push / pull 净荷零新增字段、drift 无迁移**（仍 8 表，
`schemaVersion = 10`）；外观偏好全部落既有 `settings` 键值表。

**测试门禁（本版新增）**：`note_core` `settings_store_prefix_test.dart`（按前缀读取 / 空表 / 覆盖写）
→ 全量 **469/469**；`flutter_app` `appearance_settings_test.dart`（**21 项**：入口与五分区、
移动端分区裁剪、主题三态即时生效、**取色断言**（编辑区纯白 / 结构块中性 / 代码块灰边框 / 高亮黄色 /
暗色可读 / 品牌色仍在）、字体两项独立、探测负例、Web 降级、不可用回退、笔记本覆盖与删除清理、
偏好落盘与重载）与 `font_availability_test.dart`（**11 项**：量宽判据、缓存、清单与 `system` 互转）
→ 全量 **231/231**；服务端 `go test ./...` 全绿（零改动验证）；两个 Dart 包 `analyze` 无问题。

### 8.13 优化补丁 `v0.14.1`：编辑与渲染四项优化（FR-69\~FR-72）

**① 分割线按块插入于光标下方（FR-72）**。旧 `EditorFormat._divider` 把 `---\n` 插到**当前块起点**
（光标**上方**），上一行是非空段落时 `段落\n---` 被 CommonMark / GFM 解析为 **setext 二级标题下划线**
→ **上一行字号变大**。修法：`---` 作为**独立块**插到**光标所在行之下**（`_divider`），并**自动保证
上方是空行或文档开头**（`_isThematicBreak` 判定 setext 负例）；下方保证一个空行、光标落在分割线下方；
正本中不出现连续 ≥3 个换行；**表格 / 围栏代码块内锚点外移**（`_dividerAnchorEnd` → `_fenceBlockEndAt` /
`_wellFormedTableRanges`）不打断结构；光标停在分割线行上再次点击 = **移除**（幂等切换），
而紧贴文字的 `---`（setext 下划线）不算分割线、改为在其下方另插一条。正本字节恒为 `---`。
> **`v0.14.2` 修订**：上述「**上方自动补一个空行**」的规避做法**已被撤销**（它会在分割线与上一行之间
> **多出一行**，与用户要的「三行相邻」冲突）；改为**紧贴插入**，并把 `---` **定案为恒是分割线**
> （不再按 setext 处理）。详见 **§8.14**。

**② 笔记内网址链接可点击（FR-70）**。根因是 `MarkdownPreview` 调 `Markdown(...)` 时**未传
`onTapLink`**；更要紧的是 `selectable: true` 时 flutter_markdown 走 `SelectableText.rich`，
**`RenderEditable` 从不驱动** `TextSpan.recognizer`——手势永远到不了 `TapGestureRecognizer`。
修法：把 `a` 渲染为**真 widget**（`_PreviewLinkBuilder` → `WidgetSpan` + `GestureDetector`，裸网址同样适用）；
格式模式新增**链接条** `_LinkBar`（网址 + 打开 / 编辑）与单元格链接上报 `onActiveCellLinkChanged`；
**协议白名单** `url_schemes.dart`（`http` / `https` / `mailto` / `tel`；`javascript:` / `data:` / `file:`
不打开且**绝不写回正本**）；**零新增依赖**——桌面三平台走既有系统壳层、Web `window.open`、
Android 走**自研原生通道** `sui/platform.openUrl`（`ACTION_VIEW`）。

**③ 剪贴板富文本粘贴（FR-71）**。根因是 Flutter **Windows / Android 嵌入层只实现 `text/plain`**
（`Clipboard.getData('text/html')` 报错后被 `catch` 静默回落纯文本）。修法：新增**自研原生通道**
`clipboardHtml` 取**原始字节**——Windows 读 **CF_HTML**（Dart 侧 `cf_html.dart` 的 `decodeCfHtml`
按 `StartFragment` / `EndFragment` **字节偏移**切片）、Android 读 **`ClipData`** HTML 项；
**原生侧只取字节、解析与转换全在 Dart 侧**；转换**收口到 M13 的 DOM 式转换器**
（`convertClipboardHtml` / `inlineResourcePlaceholders`），正则版 `EditorFormat.htmlToMarkdown`
**保留但冻结**；颜色 / 背景色 / 字号保留为**受限 `<span>`**（与 FR-69 同一白名单、两态同色）；
`data:` 图片落附件、远端图片保留地址且**粘贴不出网**；任一环节失败**静默回落纯文本安全插入**，
任何路径下都是**一次可撤销**编辑。

**④ 网页快照布局保真（FR-69）**。生成侧新增 `server/internal/clip/snapshot.go`（**只服务 `snapshot`**）：
**块级分段**（`blockTagSet` 相邻块级元素之间一律空行分隔，`<div>行1</div><div>行2</div>` 不再拼成
「行1行2」）+ **版式信息落受限内嵌 HTML 块**（`emitTagSet` 段落级且后代全为 `inlineTagSet` 行内、
**且带版式信息**时才产出；`style` 只放行白名单属性且值归一化为小写单 token）；`article` 产物
**逐字节不变**（9/9 夹具 `cmp` 自证）。渲染侧新增 `note_core` `format/snapshot_html.dart`
（`htmlBlocks` / `htmlBlockAt` 块定位 + `parseSnapshotHtml` 白名单化解析，`kSnapshotDroppedTags`
整块丢弃**连文本也不留**）与 `flutter_app` `ui/snapshot_html_view.dart`（受限渲染：`sui://` 走附件、
外链图片只占位、**零网络请求**）；**预览态按块混排**（正本**无 HTML 块时沿用原单 Markdown 路径**，
零回归面）、**格式模式**把 HTML 块作为 `_RegionKind.htmlBlock` **原子块**（整块呈现 / 整块删除 /
光标吸附 / 零宽等码元守偏移契约，`htmlBlockForDeletion` / `deleteHtmlBlock`）。
另加**整页截图**：扩展用 `chrome.tabs.captureVisibleTab` **滚动拼接**（**不引入** `debugger` 权限）、
JPEG 质量阶梯压缩后随**既有**剪藏请求内联上传（可选字段 `screenshot {filename, dataBase64}`，
服务端 `maxScreenshotBytes` 8 MiB / `maxScreenshotBase64Chars` 6 MiB − 256 KiB，**仅 `snapshot` 生效**），
服务端按内容寻址入库为附件并在正文末尾引用 `![整页截图](sui://<sha256>)`；失败**静默降级**。

**零改动声明**：**服务端零新增接口**（截图内联在既有剪藏请求里）、push / pull 净荷**零新增字段**、
drift **无迁移**（仍 8 表 / `schemaVersion = 10`）、`pubspec.yaml` 依赖**零增删**。

**测试门禁（本版新增）**：`note_core` 新增 **36 项** → 全量 **505/505**；`flutter_app` 新增 **13 项**
→ 全量 **244/244**（`--concurrency=1`）；服务端 `clip/snapshot_test.go` **15 项** +
`api/clip_screenshot_test.go` **7 项**（`go test ./...` 全绿）；扩展 `extension/test/screenshot_test.mjs`
**12 项**（`node --test extension/test/*.mjs` **21/21**）；两个 Dart 包 `analyze` 无问题；
`bash scripts/version.sh check` **exit 0**。
**已知限制**：macOS / Linux / Web 读不到剪贴板 HTML（回落纯文本）；
整页截图在 `position: fixed` 元素处**接缝重复**（可稳定复现，本次不修）。

### 8.14 优化补丁 `v0.14.3`：分割线口径修订（FR-72 / BR-72.1\~72.3 · BR-72.7）

**问题**：`v0.14.2` 的「`---` 紧贴插入 + `---` 恒为分割线」虽让观感紧贴，但**偏离 CommonMark**——其它 Markdown
工具看**同一份正本**会把「`标题` 换行后紧跟 `---`」当二级标题，正本不再是标准 Markdown。本轮**撤回 v0.14.2 口径**，
改为**正本与渲染二分**：**正本恢复标准 Markdown** + **格式/预览渲染紧贴**。

**修法（三处，全在编辑器 / 渲染层；服务端与同步协议零改动）**：

1. **正本恢复标准 Markdown**（`EditorFormat._divider`）：插入 `段落1\n\n---\n段落2`——`---` **上方保证一个空行**、
   **下方不补空行**（`v0.14.3` 补正；仍是标准 CommonMark，与 Gitea / GitHub / Typora 一致——`---` 前有空行即为
   主题分隔线，其后紧跟正文不影响判定）；`_isThematicBreak` 还原为 `!_hasParagraphAbove`、`_setextUnderlineRe`
   还原为 `^[ \t]{0,3}(={1,}\|-{1,})[ \t]*$`。故 `段落\n---`（紧贴上一行）**仍是 setext 二级标题**（要二级标题请用 `##`）。
2. **格式模式渲染紧贴**（`_scanLineMarkers` 规则记号扩展）：规则记号区间 `[4,9)` = **上方空行的行尾换行 +
   `---` 行 + 该行自身的行尾换行**（下方空行的换行仍作真正换行；`---` 行自身那个换行**必须**纳入区间，否则它会
   作为真正的换行在呈现单元之后再建立一个行盒——正是「插入后多出一行」的成因），呈现层据此渲染成
   「段落 / 分割线 / 段落」紧贴、无多余空行，**两种正本形态都只占 3 个视觉行**；`FormatRuleLine` 是
   **1px `colorScheme.outlineVariant`** 细线、**居中**、无外边距、按段宽铺满——与预览 `<hr>`
   （`horizontalRuleDecoration` 的 1px `outlineVariant` 上边框）**线色线宽同源**。
   **两态段落间距现状（待决设计项，不是回归）**：真机格式态「段落1 → 段落2」顶距 **54.75px**、预览态 **37.02px**
   （`p` 14 × 1.43 + `blockSpacing` 8 + `<hr>` 1px + 8），格式态比预览松 **17.73px**、**尚未一致**；
   A/B 实测**压小 / 放大呈现单元无效**（呈现单元高度取 17 与 20 顶距同值 54.75px——该行行盒由正文 `StrutStyle`
   的 **24px 下限**（B18 为图片行而设）与占位对齐决定；占位 `middle` 54.75px / 3 行、`top` 79.75px / 4 行）；
   已撤回的「规则行以显式换行结束」在真机更差（78.75px / 4 行）。候选解法（改正文 strut / 调大预览间距）各有
   代价，**需产品决策**，详见 SuiDevAgent 侧 `technology/design/low-level-design/editor-formatting.md`
   §15.5（A/B 实测表）/ §15.8（已撤回的改法）。
3. **预览零处理**：标准 `---` 前后空行本就渲染成**紧贴的 `<hr>`**（flutter_markdown 无块间外边距）——故
   **删除** `v0.14.2` 的 `EditorFormat.previewSource`，`markdown_editor.dart` 的 `_markdown` / `_markdownBody`
   回退为 `data: data`。

**口径反转说明**：`v0.14.2` 的「恒为分割线」让源码偏离标准 Markdown（其它工具看同一份正本会当标题）；
`v0.14.3` 让正本**天然标准**，把「紧贴」落到渲染层（折叠紧邻空行），既互操作一致、又观感紧贴。
渲染紧贴**只发生在空白分隔的分割线上**（BR-72.7）；`段落\n---` 仍按 setext 二级标题呈现（两态一致，正本字节不变）。
完整设计（判定表、折叠算法与边界表、被否决方案）见 SuiDevAgent 侧
`technology/design/low-level-design/editor-formatting.md` §15。

**测试门禁（本版收尾）**：`note_core` 全量 **515/515**；`flutter_app` 的
`test/divider_preview_v142_test.dart` **3/3**（「标准语义 + 规则区间折叠」）+ `test/editor_enhancement_test.dart`
的 `DividerFormatRender` 组**全绿**（按**实测真值**断言真机 **54.75px** / 预览 **37.02px**，差 17.73px、
**登记为待决项**）；服务端 `go test ./... -count=1` **全绿**、扩展 `node --test extension/test/*.mjs` **21/21**
（本版两者均未改动）；两个 Dart 包 `analyze` **无问题**；`bash scripts/version.sh check` **exit 0**。

### 8.15 M15（`v0.15.0`）：笔记编辑体验增强（FR-73\~FR-82）

**一句话**：把**格式模式的记号解析与预览收口到同一套规则**（**按区间递归 + 转义感知 + CRLF 容错**），
并新增**笔记内查找与替换**、**笔记属性信息**、**插入关联笔记**，把**围栏代码块**做成带**块级底色带**的
**原子块**，独立笔记窗口**去掉首栏**。**零服务端改动 / 零协议字段 / 零新增依赖 / drift 无迁移**
（仍 `schemaVersion = 10`、**8 表**）。

**1. 格式模式解析与预览同源**

- **行内记号按区间递归**（`EditorFormat`，此前是一次性 flat 正则）：外层记号命中后**在其区间内继续解析**
  内层记号，「删除线 + 高亮」同用**不再明文露出 `==`**（FR-79）。**正本一字不改**。
- **转义感知**：解析与渲染**都**识别反斜杠转义——`\*` 呈现为**字面量 `*`**、**不**参与记号匹配；
  「用户看到的字符」与「正本里的转义序列」因此不再打架。
- **CRLF 容错**：扫描视图对**行尾 `\r`** 容错（**不改正本字节、不影响偏移**）——历史 CRLF 正本
  **立即恢复渲染**且**不产生新修订**（原报障：CRLF 正本勾选框 2 → 1、`---` 退化为字面量）；
  两态粘贴**只做换行归一**（`normalizeLineEndings`：`\r\n` / `\r` → `\n`），**不套用**导入用的
  `normalizePlainText`（避免行内粘贴多出换行）（FR-77）。

**2. 输入转义与渲染转义感知（FR-78）**

格式模式下键入**会改变语法树**的 ASCII 标点 → **自动转义落正本**（`*` 落为 `\*`），
屏幕显示的是**字符本身**（反斜杠**不可见**）；**源码模式一律原样输入**。敏感集：
**行内恒敏感** `` ` `` `*` `_` `~` `=` `[` `]` `<` `&` `|`，**行首敏感** `#` `-` `+` `>` 与
「数字 + `.`」中的 `.`；**围栏代码块内与行内代码内不转义**；**只转义合法目标**
（**字母 / 数字 / 空格绝不加反斜杠**）；**IME 组合期不拦**；`\x` **作为整体删除**。

**3. 格式指令的记号集合语义（FR-80）**

「斜体 / 加粗 / 删除线 / 高亮」的**取消**判定由「光标附近**单个**记号」改为「**区间内同类记号集合**」——
对多个片段**分别**加斜体后**全选再点斜体**可**一次取消**（原报障：多出大量 `**`），且**只删同类**
（区间里加粗的 `**` **不被斜体吞掉**）。

**4. 围栏代码块：块级底色带 + 边界原子化（FR-81）**

- **块级底色带**：**满行宽**、含**块内空行与两条围栏行**，与预览 **`codeSurface` / `codeBorder` 同色源**
  （圆角 + 内边距）；**正文可用宽度未知（`paragraphWidth == 0`）时不建立**，回退**逐字形底色**。
- **边界原子化**：代码**首行行首 Backspace** / **末行行尾 Delete** **不再**能吞代码或吃掉闭合围栏，
  改为**整块删除**（连同**两条围栏行**，**单次可撤销**、**不留多余空行**）；**块内代码行仍可正常编辑**；
  光标**不停在**围栏行与块边界换行上；**正本字节不变**。

**5. 笔记内查找与替换（FR-73）**

格式 / 源码两态 `Ctrl/Cmd+F` 打开**查找栏**（`sui-find-*` 一组控件）：查找 / 上一个 / 下一个 /
`n/m` 计数 / 区分大小写 / **单个替换** / **全部替换**；**不做正则、不跨行**。**格式模式跳过结构区**
（表格块 / 快照 HTML 块 / 附件引用 / 链接 URL 段 / 围栏行）并提示「**已跳过 N 处结构区**」，
**源码模式全量参与**；替换**一步可撤销**；`Esc` 关闭并把焦点还给正文；**预览态不提供**
（回落中栏「查找笔记」）；桌面「编辑 → 在笔记内查找」**只给 `Ctrl+F` 文案**（**按键由编辑器承担**）
——延续 M7 / ADR-011 的**命令单一来源**口径。

**6. 笔记属性信息（FR-74）**

编辑页右上角「属性」图标 → 桌面**宽屏右侧 320px 面板**（**与「版本历史」互斥**）/ 窄屏、移动、Web
**整页推入** / 独立窗口**右栏**。字段全部取自**既有数据**：标题 / 所属笔记本（**名称 + 祖先路径**）/
创建时间 / 上次修改时间 / 剪藏**来源链接**（**为空整行不渲染**，非空可点击打开与复制）/ 标签 /
修订次数 / 版本号 / 来源设备 / 同步状态 / 字数·字符数；时间**同时给本地时间与相对时间**。
**只读、零 DB 列改动**；**加密笔记本未解锁不显示字数**。

**7. 关联笔记（FR-75）**

工具栏「关联笔记」（**紧随「链接」**）+ 桌面「编辑 → 插入关联笔记」（`Ctrl+Shift+L`）→ **选择器**
（搜索、排除当前笔记 / 回收站 / 未解锁的加密笔记本）→ 插入**标准 Markdown 链接**
`[标题](sui://note/<id>)`；**三态都能点击跳转**（桌面**开 / 聚焦独立窗口**，移动与 Web **当前窗口切换**）；
目标不存在 / 未解锁**给提示、不改正本**。**链接文字是写入时的标题快照**，目标重命名后**不自动跟随**
（**已知限制**；`sui://note/<id>` 在其它 Markdown 工具里是**文字可读、链接不可用**的普通链接，
正本**依然合法**）。

**8. 格式模式链接单元与独立窗口去顶栏（FR-76 / FR-82）**

- **格式模式**把 `[文字](网址)` 呈现为**链接单元**：**单击选中**（出现**链接条**）、**双击**打开系统浏览器；
  **表格单元格内同口径**；**非白名单协议**（`javascript:` / `data:` / `file:`）**可选中但不打开**；
  既有「链接条」保留（延续 `v0.14.1` / FR-70 的**协议白名单**口径）。
- **独立笔记窗口**不再渲染「**标题 + 同步 + 设置**」那一行，**编辑区上移**；窗口拖拽 / 最小化 /
  最大化 / 关闭由 **OS 原生标题栏**承载；笔记标题仍可编辑（编辑器**顶部标题框**）；
  **同步与设置入口保留在主窗口**；**主窗口（宽屏 / 窄屏 / Web）布局不变**；**不新增设置项**。

**9. 守线与边界（如实登记）**

- **零服务端改动 / 零协议字段 / 零新增依赖 / drift 无迁移**（仍 `schemaVersion = 10`、**8 表**）；
  格式 / 源码 / 预览**三态往返逐字节不变**（守 **BR-23.1** Markdown 唯一正本）。
- **已知限制**：格式模式下**手打** `**x**` / `~~x~~` / `==x==` 落成**转义字面量**（要结构请用
  **工具栏**或**源码模式**——这是 FR-78 口径的**必然结果**）；笔记内查找**不做正则、不跨行**
  （格式模式命中结构区时**跳过**并提示）；关联笔记**显示文字是标题快照**；
  **`==~~文字~~==`（高亮包删除线）反向嵌套保持现状**（两态一致，登记为**待决项**）；
  **真·单独的 `\r` 作行内分隔**（`- [ ] 甲\r- [x] 乙\r`）**不被扫描器断行**，
  仅由**粘贴归一**消除；代码块底色带在 `paragraphWidth == 0` 时**不建立**；
  独立窗口内**没有**同步 / 设置入口（入口在主窗口），**同步状态并入模式行**的增强**本轮未做**。
- **性能实测**：135 KB 长文档下 `EditorFormat.syntaxMarkers` 约 **60ms/次**（呈现层已在一次 build 内做了
  text→markers 缓存）；典型笔记（<10 KB）约 **4ms** 量级。

**测试门禁（本版收尾）**：`note_core` **analyze 干净 + 612/612 全绿**（基线 **515**）；
`flutter_app` **analyze `No issues found` + 318/318 全绿**（`--concurrency=1`，基线 **248**）；
**服务端与同步协议本版零改动**。

### 8.16 M16（`v0.16.0`）：网页剪藏保真、笔记本组织与编辑体验（FR-83\~FR-89）

**一句话**：`snapshot` 剪藏新增**单文件 HTML 原件**（`webclip` 内容寻址附件）+ 笔记内 **WebView 预览**，
原页布局不再被 Markdown 转换压扁；同时修掉关联笔记**跨本跳转**、笔记本**折叠 / 搜索**、
收件箱**移回**与默认「网页剪藏」标签、标题回车、勾选框焦点与列表 / 缩进**整行选中**。

- **双产物、单一正本**：Markdown 正文 + `[网页原件](sui://webclip/<sha256>)` 一行；原件是附件，
  不写进 `notes.content`。`article` 模式**零变化**；扩展默认模式改为 `snapshot`。
- **服务端**：`BuildWebClipHTML(doc, pageURL, client)` **先内联外部样式表**（扩展保留
  `<link rel=stylesheet>`；服务端拉取跨域 CSS，单表 2 MiB / 总计 4 MiB / 最多 24 个），再做安全收口
  （删脚本 / 事件 / iframe / 表单 / 剩余 link，注入 `img-src data: sui:` CSP），`MaxWebClipBytes = 12 MiB`；
  原件写 blob 并登记 `mimeKind = webclip`；默认标签 `EnsureTag("网页剪藏") + SyncNoteTags`（同名复用）。
- **选择正文（`v0.16.2` / FR-90）**：扩展新增「选择正文区域剪藏…」与右键菜单；页面元素选择器
  只保留 `body → 选中元素` 祖先链，删除各级兄弟节点（页头 / 页脚 / 侧栏），保留 `<head>` 样式；
  固定 `snapshot` 提交、不采集整页截图；成功 / 失败用徽标 + 页面轻提示。
- **多附件添加（`v0.16.3` / FR-91）**：`NoteEditor` 以 `_attaching` + 待添加文件名列表实现
  **单批次互斥**，附件面板逐项显示「添加中…」，批次内按钮与工具栏「插入图片」置灰；每个附件
  成功后立即 `EditorFormat.insertAttachment`（图片 `![…]`、其余 `[…](sui://…)`）并 `saveNote`，
  做到「映射 + 引用 + 落库」逐项同进；`AppController.addAttachmentFromBytes` **不再等网络上传**，
  字节由 `SyncClient.backfillBlobs()`（`sync()` 开头，先补传再 push 映射）负责。
  零 drift 迁移 / 零协议字段。
- **附件读写的线程模型（`v0.16.4` / FR-92）**：受保护通道的**封装 / 解封**（AES-256-GCM + base64）
  在载荷 ≥ 64 KiB 时交给**工作 isolate**（`channel_payload_io.dart`，`TransferableTypedData`
  转移入参 / 出参）；`http://` 下 22 MB 附件的主线程停顿由 **2968 / 2858 ms** 降到 **65 / 19 ms**。
  附件字节散列（≥1 MiB）走 `compute` 工作 isolate（22 MB：325 → 约 15 ms）。线路字节与
  `v0.16.3` 逐字节一致，协议 / 表结构 / 依赖零改动；Web 无 isolate 时同线程执行（条件导入）。
  顶栏同步状态改用静态图标，长任务不再持续排帧。剩余项（包体写入 ≈185 ms、整文件读入、
  drift 查询在主 isolate）登记为后续优化。
- **代码块底色带（`v0.16.5` / FR-93 / FR-94）**：带改由正文 `TextField` **背后**的
  `CodeBlockBandPainter` 绘制——按 `RenderEditable.getLocalRectForCaret` 取「开围栏行行顶 ~
  块末行行底」，横向与**段落左右边界对齐**（两侧各留 16px 编辑区内边距）；文字天然在带之上。
  此前带是 0×0 inline 占位 widget 的溢出装饰：既靠「40px 溢出 + 编辑器裁剪」（实际未裁 →
  宽屏左压笔记列表 **23.7px**、右出窗 **24.3px**），又因 `RenderParagraph` **先画文字、
  再画 inline 子 widget** 而**盖住代码文字**。编辑区白底另加 `ClipRect` 硬兜底；
  内边距抽为共享常量 `kEditorBodyPadding`（16）。
- **客户端**：唯一新增依赖 **`flutter_inappwebview ^6.1.5`**（Windows / Android / iOS / macOS / Web）；
  预览态内嵌 WebView、格式态原子卡片、全屏查看器；桌面 / 移动由 WebView 自定义 scheme 按需读取
  `sui://` 图片（Web 端才在 8 MiB 预算内替换为 data URI）；JS 关闭、CSP `default-src 'none'` 禁网、
  外部导航拦截。
  WebView 不可用 / 原件缺失 / 超限时降级为
  「整页截图 + 打开原件」。
- **跳转与组织**：`AppController.navigateToNote` 同时切换笔记本 / 收件箱 / 归档视图并清搜索 / 标签筛选；
  笔记本树改为**单一滚动列表** + `ListenableBuilder`，逐级 chevron 与笔记本名过滤；
  收件箱判据增加「网页剪藏」标签兜底，移动对话框新增独立「收件箱」目标。
- **编辑器**：`_mapLines` / `_indent` 等块级指令统一返回**折叠光标 + 末行行尾**；空行勾选框返回
  `- [ ] `（带尾空格），插入后可直接键入；标题框 `Enter` 把焦点交给正文。
- **守线**：push / pull **零新增字段**、drift **无迁移**（`schemaVersion = 10`、8 表）；原件只走既有
  附件链路；唯一新增依赖已获用户批准。
- **测试门禁（本版收尾）**：`note_core` 全量 **627/627** + `dart analyze` 干净；`flutter_app` 全量
  （`--concurrency=1`）+ `flutter analyze` 干净；服务端 `go test ./...` 全绿；扩展 `node --test` 全绿；
  Windows `flutter build windows` 通过（含 WebView 插件 / WebView2 依赖）。
