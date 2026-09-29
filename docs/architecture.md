# 系统架构

本文描述随手记 Sui 的整体架构、分层、数据模型、同步协议与关键设计决策。
决策的**背景与权衡**见 [ADR](adr/)；接口细节见 [API 参考](api-reference.md)。

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
| `clip` | 网页净化：Readability 启发式选主内容 + HTML→Markdown |
| `ws` | WebSocket Hub：push/剪藏成功后广播 `{"type":"changed"}` |
| `cors` | 跨域中间件（开发模式全允许） |

### 2.2 数据模型（SQLite，服务端）

服务端库只承载**同步汇聚**所需的最小元数据，实际建表语句见
[`server/internal/store/store.go`](../server/internal/store/store.go) 的 `migrate()`。

| 表 | 用途 |
|----|------|
| `users` | 用户（id / username / password_hash / token / created_at） |
| `notes` | 笔记元数据（id / title / content_markdown / notebook_id / version / is_deleted / archived / source_device / updated_at） |
| `revisions` | 修订历史（id / note_id / version / title / content_markdown / source_device / is_conflict / created_at） |
| `blobs` | 附件字节登记（sha256 / size / refcount / created_at）。**refcount 唯一来源是 `attachments` 映射**：指向该 hash 的有效映射条数 |
| `attachments` | 附件-笔记映射（id / note_id / filename / mime_kind / byte_size / sha256 / storage_ref / thumbnail_ref / embedded_pos / is_deleted / created_at / updated_at） |
| `notebooks` | 笔记本分组（id / parent_id / name / sort_order / is_deleted / version / source_device / created_at / updated_at） |
| `tags` | 标签（id / name / is_deleted / version / source_device / created_at / updated_at） |
| `note_tags` | 笔记-标签多对多关联（note_id / tag_id） |

关键索引：`idx_notes_updated`、`idx_revisions_note`、`idx_revisions_note_ver`、`idx_notes_isdel`、
`idx_attachments_note`、`idx_notebooks_updated`、`idx_tags_updated`、`idx_note_tags_note`、`idx_note_tags_tag`。

> **同步净荷（M1 起，M2 增补）**：push 请求体在 `items`（笔记）之外新增 `notebooks` / `tags` 两个数组，
> 笔记条目新增 `notebookId`（指针语义：缺省=不变、`""`=移入收件箱、有值=归属该笔记本）与
> `tagIds`（该笔记标签的全量集合）；pull 响应新增 `notebooks` / `tags` 两个数组，笔记条目回带
> `notebookId` / `tagIds`。push 响应新增 `notebookResults` / `tagResults`，与 `results` 同构
> （`accepted` / `serverVersion` / `appliedVersion`），复用同一套 `base_version` 冲突与墓碑机制。
> M2 起笔记条目增带 `archived`（归档状态，随 push/pull 往返、跨端一致）。
> 旧表清单中的 `outbox` 为设计预留描述，代码中并未建表，已从本表移除。

### 2.3 测试清单（`internal/api/handlers_test.go`）

| 测试 | 覆盖 |
|------|------|
| `TestPing` | 心跳 |
| `TestHealth` | 健康检查 |
| `TestPushPull` | 推送 + 增量拉取闭环 |
| `TestConflictDetection` | `base_version` 冲突判定 |
| `TestAuthReject` | 无 token / 坏 token 拒绝 |
| `TestRevisionListAndGet` | 修订列表 + 详情 |
| `TestAttachmentMappingSync` | 附件映射往返 + refcount 幂等/改指/墓碑归零 + 孤儿 GC |
| `TestClipEndpoint` | 剪藏净化 + URL 幂等 + 同步集成 |
| `TestSyncNotebookTagPayload` | 笔记本 / 标签净荷往返 + `notebookId` / `tagIds` + 冲突回传 `serverVersion` |
| `TestSyncArchivedFlag` | 归档状态 `archived` 净荷往返 |
| `TestSyncNotebookCreateRename` | 笔记本新建 / 重命名变更上行与 pull 收敛 |

## 3. 客户端

### 3.1 note_core（共享核心）

纯 Dart 包，不依赖 Flutter，可被任何 Dart 宿主复用。

| 类 | 职责 |
|----|------|
| `NoteRepository` | 本地数据访问门面：笔记本 CRUD、标签、笔记 CRUD、修订追加、搜索 |
| `SyncClient` | 同步引擎：Outbox 合并、增量 pull、冲突本地合并、重发 |
| `AppDatabase` | drift 数据库（8 表 + 迁移） |
| `LocalBlobStore` | 附件本地存储实现（原生分片落盘 / Web 内存缓存） |
| `CachedBlobStore` | 附件缓存层：LRU 上限 + 按需下载 + `uploaded_at` 待上传记账（`blob_refs`） |
| `mimeKindFor()` | 由扩展名推断附件大类（卡片图标用） |
| `DeviceId` | 设备标识（冲突合并 / 来源标记用） |

**本机数据表（drift，`schemaVersion = 5`）**：定义见
[`clients/note_core/lib/src/db/app_database.dart`](../clients/note_core/lib/src/db/app_database.dart)。

| 表 | 用途 | 随同步上行 |
|----|------|------------|
| `notebooks` | 笔记本分组（树形：id / parent_id / name / sort_order / is_deleted / version / 时间戳） | ✅ |
| `tags` | 标签（扁平、跨笔记组合） | ✅ |
| `notes` | 笔记正本（notebook_id / title / content_markdown / pinned / archived / is_deleted / revision_count / version / source_device / 时间戳） | ✅ |
| `note_tags` | 笔记-标签多对多关联（note_id / tag_id） | ✅（随笔记 `tagIds`） |
| `revisions` | 修订历史（快照 + diff 增量） | ✅ |
| `attachments` | 附件元数据（字节存 BlobStore，此处只存引用 + sha256） | ✅（映射随笔记） |
| `blob_refs` | 本机附件缓存记账（LRU 元数据 + `uploaded_at` 待上传标记） | ❌ 本机缓存状态 |
| `settings` | 应用级键值配置（服务端地址 / Token / deviceId） | ❌ 设备级偏好 |

> M1 起服务端补齐 `notebooks` / `tags` / `note_tags` 三表：`notebooks` / `tags` 随 sync/push、
> sync/pull 净荷上下行（与笔记一样携带 `version` / `is_deleted` / 来源设备与墓碑机制）；
> `note_tags` 关联不单独传输，而是随所属笔记的 `tagIds` 全量携带、在笔记被接受时重建关联。

### 3.2 flutter_app（Flutter 客户端）

**状态管理**：Provider + `AppController`（单一状态源，暴露 `notifyListeners`）。

| 文件 | 职责 |
|------|------|
| `note_shell.dart` | 响应式三栏骨架（宽屏三栏 / 窄屏抽屉 + 导航堆栈） |
| `notebook_tree.dart` | 笔记本树 + 收件箱 + 全部笔记 + 标签入口 + 归档 / 回收站入口（底部区域） |
| `note_list.dart` | 笔记列表（置顶 / 剪藏标签 / 搜索过滤） |
| `note_editor.dart` | 编辑器（标题 / 格式工具栏 / 标签 / 附件卡片 / 历史 / 导出 / 删除） |
| `markdown_editing_controller.dart` | 「格式 / 源码 / 预览」三态编辑控制器（Markdown 为正本；格式态渲染行内样式与图片单元、支持选中调尺寸） |
| `markdown_editor.dart` | 源码编辑 + 预览切换（`sizedImageBuilder` 渲染 `sui://` 附件图） |
| `revision_panel.dart` | 版本历史侧栏 + 一键恢复 |
| `app_controller.dart` | 全局状态与业务编排（附件增删 / 上传 / 缓存状态）；同步调度：编辑防抖 0.7s 推送、WS 通知拉取、30s 周期兜底 |
| `sync_settings_dialog.dart` | 同步设置对话框（服务端地址 / Token / 设备 ID 的录入与校验） |
| `platform/attachment_picker.dart` | 跨端文件选择（`file_picker`，返回文件名 + 字节） |

**服务端地址**：不写死在代码里，由用户在「同步设置」对话框录入，经
`SyncConfig.normalizeBaseUrl` 规整后存入本地 SQLite `settings` 表；未填写时输入框以
`http://127.0.0.1:8080` 作占位提示。运行时地址一律取自 `AppController` 持有的 `SyncConfig`。

### 3.3 测试

- note_core：90 个用例，覆盖仓储 CRUD / 标签 / 搜索 / 修订 / 同步 / 附件引用计数与上传 /
  缓存 LRU / 配置存取 / 落盘持久化，另含 2 个 e2e（注册→双端 push/pull→冲突合并→重发；
  附件映射同步 + 字节按需下载）。
- flutter_app：10 个用例，含 widget 测试、`sync_wiring_test.dart`（起真服务端跑注册连接→同步→
  第二设备拉取）与 `editor_format_image_test.dart`（格式模式图片渲染与尺寸手柄）。
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
- **合并（客户端启发式）**：
  1. 标题取较新修订。
  2. 正文：合并双方内容，冲突段落用标记分隔，**绝不丢字**。
  3. 合并结果作为新 base 重发。
- **与 Git 类比**：rebase（基于服务端最新）+ merge（双方内容并集）。

### 4.3 历史一致性

- 历史记录以**服务端合并记录**为准，所有端看到一致。
- 客户端未同步的本地修改在同步后并入服务端时间线。

### 4.4 WebSocket 通知

- 端点：`GET /api/v1/ws`。
- push / 剪藏成功后广播 `{"type":"changed"}`。
- 客户端收到后触发一次增量 pull；WS 不可用仅静默降级，手动同步与防抖推送仍可用。

## 5. 附件存储策略（客户端侧）

> 决策来源：M5 后讨论「客户端附件存储压力」。结论：采用 **B 方案（元数据全量同步 +
> 附件按需拉取 + LRU 容量上限）**，放弃全量镜像。详见 [ADR-002](adr/)。

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
│   ├── adr/                     # 架构决策记录
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
    │   └── test/                # 51 用例
    └── flutter_app/             # Flutter 客户端
        ├── lib/src/
        │   ├── app.dart / main.dart / bootstrap.dart
        │   ├── platform/        # 数据目录条件导入 + attachment_picker
        │   └── ui/              # 三栏外壳/编辑器/修订面板/附件卡片
        ├── web/                 # index.html / sqlite3.wasm / drift_worker.dart(.js)
        ├── android/ ios/ linux/ windows/ macos/
        └── test/
```

## 8. 当前状态与已知缺口

> 本节用于区分「设计目标」与「已落地」。变更历史见根目录 [CHANGELOG.md](../CHANGELOG.md)。

### 8.1 已落地并验证

- **服务端**：Go 构建通过、13/13 测试通过；`ping` / `register` / `login` / `push` / `pull` /
  `blobs`(HEAD/PUT/GET) / `revisions` / `clips` 全部实测正常，鉴权 401、重复注册 409、
  坏 body 400、不存在资源 404、`base_version` 冲突 `accepted=false` 均正确。
- **note_core**：90/90 测试通过（落盘持久化 2 + 配置存取 9 + 附件映射 3 + 引用计数 4 +
  附件上传 3 + 笔记本/标签同步 6 + 格式化编辑与图片尺寸 + e2e 同步 3 等）。
- **flutter_app**：10/10 测试通过（含**真服务端**端到端：注册连接 → 本地新建 → 同步 →
  第二台设备拉取到；以及格式模式图片渲染与尺寸手柄用例）。
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
- **附件 UI**：编辑器工具条「添加附件」入口（`file_picker` 跨端取字节）+ 底部卡片四态
  （已同步 / 待上传 / 仅本机 / 未下载）+ 预览内 `sui://<sha256>` 图片渲染。
- **Web 构建**：`flutter build web --release` 成功；真实浏览器验证启动、IndexedDB 落库。
- **平台脚手架**：`web/` + 桌面/移动五端目录均已就位，应用显示名统一为「随手记 Sui」；
  Linux 桌面实测只差宿主编译工具链。
- **代码质量**：`flutter analyze` 两个包 0 问题。
- **测试稳定性**：两个 e2e 起服务端由固定 `sleep 1.5s` 改为轮询 `/healthz` 探活，
  消除机器繁忙时的「连接被拒」假失败。

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

### 8.3 未实现的设计项

- 缩略图生成（附件方案 C）。
- 桌面端「全量镜像」开关。
- Web 端 BlobStore 的 IndexedDB 实现（当前为内存）。
- FTS5 全文搜索（当前为 `LIKE` 子串匹配；表结构已预留）。
- 富文本 WYSIWYG 编辑器（`flutter_quill` 升级，当前为「格式 / 源码 / 预览」三态）。
