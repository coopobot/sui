# 随手记 Sui

**印象笔记替代品 —— 自托管 · 离线优先 · 多端同步的现代 Markdown 笔记应用。**

> 项目英文名：**Sui**（音近「随手」）

随手记 Sui 是一款面向个人知识管理的极简笔记应用：笔记以 Markdown 为唯一正本，本地 SQLite 离线优先存储，通过自托管 Go 服务端在多端之间同步；支持网页一键剪藏、版本历史恢复、全文搜索、附件与分组，数据完全由你自己掌控。

## 核心特性

| 特性 | 说明 |
|------|------|
| 离线优先 | 所有笔记存于本地 SQLite，断网可读可写，联网后自动同步 |
| 多端同步 | 自研 push/pull 协议，`base_version` 冲突检测 + 启发式合并，绝不丢字 |
| Markdown 编辑 | 源码 / 预览双模式，所见即所得渲染（flutter_markdown） |
| 网页剪藏 | Chrome MV3 扩展一键剪藏，服务端类 Readability 净化转 Markdown，自动进「收件箱」 |
| 版本历史 | 每条修订记录可查看、可一键恢复，历史永不重写 |
| 全局搜索 | 标题 / 正文关键字搜索 |
| 附件管理 | 内容寻址 Blob 存储（sha256 去重），云端与本地一致 |
| 笔记分组 | 笔记本（嵌套）+ 标签（多对多） |
| 实时通知 | WebSocket 变更广播，多端即时感知 |
| 数据导出 | Markdown 一键复制到剪贴板 |

**里程碑进度速记：**

**M0 骨架 ✅**
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

- **映射同步**：笔记附件清单随笔记一起走 push/pull（`items[].attachments` /
  `notes[].attachments`，含墓碑，否则删除无法传播），字节永远不随 pull 下发。
  映射随笔记而非独立游标，是因为映射脱离笔记没有意义，且省掉一个同步游标。
- **惰性下载**：附件打开 / 预览时才请求 `GET /api/v1/blobs/{hash}`；Web 端同理（浏览器沙箱缓存）。
- **LRU 淘汰**：容量超限时淘汰最久未访问的 hash（先删物理字节，再清元数据）；被淘汰后再次打开触发重新下载。
- **占位 UX**：未缓存的附件显示「未下载」占位 + 手动下载按钮；离线时未缓存附件不可看（可接受权衡）。
- **桌面可扩**：桌面端可提供「全量镜像」开关（关闭 LRU），移动端默认按需。

**实现清单（后续）**

1. ✅ note_core：`CachedBlobStore`（实现 `BlobStore`，内部 = LocalBlobStore + 容量记账 + LRU 淘汰 + 下载回调）。
2. ✅ 附件映射表：客户端 `blob_refs`（hash / size / last_access_at / ref_count，drift v3）与服务端 `attachments`（映射本体 + refcount 驱动，见修复 3）。
3. ✅ SyncClient：`ensureBlob(hash)` 按需下载入口（`GET /blobs/{hash}` + 写入缓存）；附件映射随 push/pull 交换（修复 3）。
4. ✅ Flutter UI：编辑器工具条「添加附件」入口（`file_picker`，`withData: true` 统一拿字节）
   + 底部附件卡片区（文件名/大小/可用性状态/移除）+ 预览内 `sui://<sha256>` 图片渲染（修复 4）。
5. ✅ 服务端：`GET /blobs/{hash}` 已就绪（M5），无需改动；缩略图生成（C 方案）留后续。
6. ✅ 测试：`cached_blob_store_test.dart`（幂等 / 按需下载 / 无源返回 null / LRU 淘汰 / 孤儿优先 /
   引用归零清理 / 删除联动 / 待上传清单）+ `attachment_test.dart`（引用计数增删 / 共享 sha / 墓碑连带）
   + `sync_client_test.dart`（先补传字节再 push 映射 / 不重复上传）；note_core 全量 51 用例通过；
   flutter analyze 零问题、widget 测试通过。

**上传方向（修复 4 补齐）**

方案 B 只规定了「字节按需下行」，上行方向必须同时明确，否则新增的附件永远留在本机：

- **新增即上传，失败不阻断**：挂载附件时先落本地字节、再写映射（引用计数 +1），然后尽力
  `PUT /blobs/{hash}`。上传失败（断网 / 未连服务端）不算失败——字节已在本地、映射已入库，
  属于「待上传」状态。
- **同步周期补传**：`blob_refs.uploaded_at` 为 null 即「服务端尚未确认持有」，`SyncClient.backfillBlobs()`
  在每轮同步开头扫一遍待上传清单补齐。挂在同步周期而非独立重试队列，天然幂等、断网恢复后自愈。
- **顺序：先补传字节，再 push 映射**。反过来会出现对端已收到映射、却下载不到字节的空窗。
- **四态可用性**：UI 用 `AttachmentAvailability`（`cached` / `pendingUpload` / `localOnly` / `remoteOnly`）
  而非布尔「已缓存」。只显示「已缓存」会让用户误以为换台设备也一定能打开——「本地有字节」与
  「服务端有字节」是两件独立事实。

> Web 端补充：浏览器无文件系统，`LocalBlobStore` 在 Web 退化为**进程内内存缓存**
> （见 §19.5）。这与 BlobStore 的缓存语义一致，不构成数据丢失。

**存储压力结论**

- 移动端：本地占用 ≤ 512MB 上限（可配置），**与附件总量解耦**，压力可控。
- 桌面端：可选全量镜像，默认同上限策略。
- 离线：未缓存附件不可看，但有占位提示；已缓存附件完整可用。

## 17. 项目目录结构（目标）

```
sui/
├── Makefile                     # 服务端构建/测试入口
├── README.md                    # 项目总览
├── docs/
│   ├── DESIGN.md                # 本文档（设计决策）
│   ├── DEVELOPER.md             # 开发者文档（环境/接口/调试）
│   └── USER_GUIDE.md            # 用户使用说明
├── protos/                      # 同步协议定义
├── server/                      # Go 服务端
│   ├── cmd/sui-server/          # 入口
│   └── internal/
│       ├── api/                 # HTTP 路由与 handler
│       ├── auth/                # 账号与 token
│       ├── blob/                # 内容寻址 Blob 存储
│       ├── clip/                # 网页剪藏净化
│       ├── cors/                # CORS
│       ├── store/               # SQLite 持久化
│       ├── sync/                # push/pull 协议与冲突检测
│       ├── version/             # 版本信息
│       └── ws/                  # WebSocket 变更广播
├── extension/                   # Chrome MV3 剪藏扩展
└── clients/
    ├── note_core/               # 多端共享核心（纯 Dart，不依赖 Flutter）
    │   ├── lib/src/
    │   │   ├── db/
    │   │   │   ├── app_database.dart      # drift 表定义 + 迁移
    │   │   │   └── connection/            # 平台条件导入的连接层
    │   │   │       ├── connection.dart            # 壳（条件导出）
    │   │   │       ├── connection_io.dart         # 原生：drift/native + 文件
    │   │   │       ├── connection_web.dart        # Web：drift/wasm + 浏览器持久化
    │   │   │       └── connection_unsupported.dart
    │   │   ├── blob/
    │   │   │   ├── blob_store.dart        # 抽象接口
    │   │   │   ├── local_blob_store.dart  # 壳（条件导出）
    │   │   │   ├── local_blob_store_io.dart   # 原生：文件系统分片
    │   │   │   ├── local_blob_store_web.dart  # Web：内存缓存
    │   │   │   ├── cached_blob_store.dart # LRU + 容量记账
    │   │   │   └── sqlite_blob_cache_meta.dart
    │   │   ├── models/                    # Note/Notebook/Tag/Revision/Attachment
    │   │   ├── repository/note_repository.dart
    │   │   ├── sync/sync_client.dart      # push/pull + ensureBlob + uploadBlob/backfillBlobs
    │   │   └── util/                      # ids.dart（sha256Hex）/ mime_kind.dart（附件大类）
    │   └── test/                          # 51 用例
    └── flutter_app/                       # Flutter 客户端
        ├── lib/src/
        │   ├── app.dart / main.dart
        │   ├── bootstrap.dart             # 存储初始化（默认落库）
        │   ├── platform/                  # 数据目录条件导入 + attachment_picker（file_picker 封装）
        │   └── ui/                        # 三栏外壳/编辑器/修订面板/附件卡片
        ├── web/
        │   ├── index.html
        │   ├── sqlite3.wasm               # SQLite 引擎（Web）
        │   ├── drift_worker.dart          # worker 入口源码
        │   └── drift_worker.dart.js       # worker 编译产物
        └── test/widget_test.dart
```

> 平台脚手架现状：仓库目前只有 `web/`。桌面/移动需执行
> `flutter create --platforms=windows,linux,macos,android,ios .` 生成后再构建。

## 19. 平台分层：条件导入与构建目标

### 19.1 问题（已修复）

`note_core` 原先在 `app_database.dart`、`local_blob_store.dart` 中**无条件**
`import 'dart:io'` 与 `package:drift/native.dart`（后者间接引入 `dart:ffi`）。
两者在 Web 平台都不存在，导致 `flutter build web` 直接编译失败
（`Dart library 'dart:ffi' is not available on this platform`）。
而 `flutter_app` 当时只有 `web/` 一个平台目录 —— 即**没有任何可构建目标**。

### 19.2 方案：条件导入分层

平台相关能力下沉为「壳文件 + 各平台实现」，由 Dart 条件导入在编译期选择：

| 能力 | 壳文件 | 原生实现 | Web 实现 |
|------|--------|----------|----------|
| 数据库连接 | `db/connection/connection.dart` | `connection_io.dart`：`drift/native` + SQLite 文件 | `connection_web.dart`：`drift/wasm` + 浏览器持久化 |
| Blob 存储 | `blob/local_blob_store.dart` | `local_blob_store_io.dart`：文件系统分片 | `local_blob_store_web.dart`：内存缓存 |
| 数据目录 | `flutter_app/src/platform/data_dir.dart` | `data_dir_io.dart`：`path_provider` | `data_dir_web.dart`：返回 `null` |

条件常量用 `dart.library.io`（原生）与 `dart.library.js_interop`（Web）。
**判定顺序是关键**：`dart.library.io` 必须排在前面 —— 已实测
`dart.library.js_interop` 在 Dart VM 上为 `false`，但仍以显式顺序兜底，
避免未来 SDK 行为变化导致 VM 误选 Web 实现。

### 19.3 Web 端持久化

`WasmDatabase.open` 需要 `flutter_app/web/` 下两个资源：

| 资源 | 来源 | 大小 |
|------|------|------|
| `sqlite3.wasm` | sqlite3.dart releases（版本需与 `sqlite3` 依赖一致，当前 2.9.4） | ~714KB |
| `drift_worker.dart.js` | 由 `web/drift_worker.dart` 经 `dart compile js -O4` 生成 | ~355KB |

重新生成命令见 DEVELOPER.md。drift 会探测浏览器能力并按可靠性择优：
OPFS(shared) → OPFS(locks) → IndexedDB(shared) → IndexedDB(unsafe) → 内存。

> 实测（Chrome、非跨域隔离 `crossOriginIsolated=false`、无 `SharedArrayBuffer`）：
> 落到 **IndexedDB** 持久化 —— `indexedDB.databases()` 中存在名为 `sui` 的库，
> 存储占用约 208KB，**非内存回退**。

### 19.4 数据落库位置

| 平台 | 位置 |
|------|------|
| 桌面 / 移动 | `<应用支持目录>/sui/sui.sqlite`（`path_provider`，目录不存在时自动创建） |
| Web | 浏览器 OPFS / IndexedDB（库名 `sui`） |
| 测试 | 内存库（`AppDatabase.memory()`） |

选「应用支持目录」而非「文档目录」：数据库属应用内部状态，不应出现在用户可见
的文件列表中，也避免被系统云盘同步误处理。

### 19.5 Web 端 Blob 的取舍

Web 无文件系统，`LocalBlobStore` 在 Web 退化为**进程内内存缓存**。这是可接受的：
方案 B 中 BlobStore 本就是缓存语义（正本在服务端、按需拉取），刷新页面后重新
下载即可，不构成数据丢失。若后续需要 Web 端跨会话缓存附件字节，可再补一个
IndexedDB 实现（壳文件的第三个分支）。

### 19.6 构建目标现状

| 目标 | 状态 |
|------|------|
| Web | ✅ 可构建、已在真实浏览器验证启动（无控制台错误） |
| 桌面（Windows/macOS/Linux） | ⚠️ 代码路径已就绪，缺平台脚手架目录 |
| 移动（Android/iOS） | ⚠️ 代码路径已就绪，缺平台脚手架目录 |

## 20. 当前状态与已知缺口（滚动更新）

> 本节随修复进度滚动更新，用于区分「设计目标」与「已落地」。

### 20.1 已落地并验证

- 服务端：Go 构建通过、8/8 测试通过；`ping`/`register`/`login`/`push`/`pull`/
  `blobs`(HEAD/PUT/GET)/`revisions`/`clips` 全部实测正常，鉴权 401、重复注册 409、
  坏 body 400、不存在资源 404、`base_version` 冲突 `accepted=false` 均正确。
- note_core：51/51 测试通过（落盘持久化 2 + 配置存取 9 + 附件映射 3 + 引用计数 4 + 附件上传 3
  + e2e 同步 2 等）。
- flutter_app：5/5 测试通过（含**真服务端**端到端：注册连接 → 本地新建 → 同步 →
  第二台设备拉取到）。
- 同步链路：`SyncClient` 已实例化并注入 `CachedBlobStore`，push/pull + WS 通知已接线。
- 附件映射：随笔记 push/pull 全量交换（含墓碑），服务端 blob `refcount` 由映射驱动；
  字节仍按需下载，映射同步不触发字节传输。
- 附件上传：新增附件先落本地 → 写映射 → 尽力上传，失败留待 `backfillBlobs()` 在同步周期补传；
  push 前先补字节，避免对端拿到映射却下不到字节。
- 附件 UI：编辑器工具条「添加附件」入口（`file_picker` 跨端取字节）+ 底部卡片四态
  （已同步 / 待上传 / 仅本机 / 未下载）+ 预览内 `sui://<sha256>` 图片渲染。
- Web 构建：`flutter build web --release` 成功；真实浏览器验证启动、IndexedDB 落库。
- 代码质量：`flutter analyze` 两个包 0 问题。

### 20.2 待修复缺口

| # | 缺口 | 状态 | 影响 |
|---|------|------|------|
| 1 | **同步链路未接线**：`SyncClient` 从未实例化，`blobStore` 从未注入 | ✅ 修复 2 | 客户端原为纯本地编辑器；附件按需下载/LRU 机制曾是死代码 |
| 2 | 无登录 / 服务端地址配置 UI | ✅ 修复 2 | 客户端原无法连接服务端 |
| 3 | 服务端 `attachments` 表为半成品（建表但无读写方法与协议字段） | ✅ 修复 3 | 附件-笔记映射无法跨端重建 |
| 4 | 无附件上传 / 选择器 | ✅ 修复 4 | 用户无法添加附件 |
| 5 | 缺桌面/移动平台脚手架目录 | ⏳ 待修复 | 这些端暂不可构建（代码路径已就绪） |
| 6 | `lib/src/home_page.dart` 为 M0 死代码 | ⏳ 待修复 | 冗余，易误导 |
| 7 | README/DEVELOPER 的运行命令与实际不符 | ⏳ 待修复 | 按文档操作会失败 |
| 8 | 文档「核心特性」全 ✅ 但部分未在客户端生效 | ⏳ 待修复 | 认知偏差 |

### 20.3 未实现的设计项

- 缩略图生成（§18 方案 C）。
- 桌面端「全量镜像」开关。
- Web 端 BlobStore 的 IndexedDB 实现（当前为内存）。

### 20.4 修复日志（按顺序滚动更新）

#### 修复 1 ✅ 客户端可构建性 + 数据持久化

对应 §19（条件导入分层）与 §19.4（数据落库位置）。原状：`note_core` 无条件
`import 'dart:io'` / `package:drift/native.dart`（间接引入 `dart:ffi`），Web 构建
直接失败；且 `flutter_app` 只有 `web/` 一个平台目录，客户端实际无可构建目标。
持久化侧原用内存库、未接 `path_provider`，重启即丢数据。

落地内容：

| 项 | 文件 | 说明 |
|----|------|------|
| 连接层条件导入 | `note_core/lib/src/db/connection/` | 壳 + io / web / unsupported 三实现 |
| Blob 层条件导入 | `note_core/lib/src/blob/local_blob_store*.dart` | 原生文件系统分片 / Web 内存缓存 |
| 数据目录 | `flutter_app/lib/src/platform/data_dir*.dart` | 原生 `path_provider` 应用支持目录 / Web `null` |
| 存储初始化 | `flutter_app/lib/src/bootstrap.dart` + `main.dart` | 启动即落库，`AppDatabase.file()` 默认持久化 |
| Web 引擎资源 | `flutter_app/web/sqlite3.wasm`、`drift_worker.dart(.js)` | `drift/wasm` 运行必需，已入库 |
| 回归测试 | `note_core/test/persistence_test.dart` | 落盘 → 关闭 → 重开，数据保留；目录自动创建 |

验收（本次实测）：

| 检查 | 命令 | 结果 |
|------|------|------|
| 服务端 | `go build ./... && go test -count=1 -v ./internal/api/` | 构建通过，7/7 PASS |
| note_core 测试 | `dart test` | 26/26 通过 |
| note_core 静态检查 | `dart analyze` | No issues found |
| 客户端测试 | `flutter test` | 2/2 通过 |
| 客户端静态检查 | `flutter analyze` | No issues found |
| Web 构建 | `flutter build web --release` | ✓ Built build/web |

> 环境备注：WSL 内 Go 工具链位于 `/home/aiuser/go-sdk/go/bin`、Flutter 位于
> `/home/aiuser/flutter/bin`，二者均不在默认 `PATH`，需显式指定绝对路径调用。

#### 修复 2 ✅ 同步链路接线 + 服务端连接配置 UI

对应 §20.2 #1 / #2。原状：`SyncClient` 从未被实例化，`CachedBlobStore` 从未注入
（附件按需下载/LRU 全是死代码）；客户端也没有任何地方能填写服务端地址与 Token，
因此「多端同步」「实时通知」在客户端实际不可达。

设计要点：

- **配置落本地库**：新增 `settings` 键值表（drift schema v4），存
  `sync.baseUrl` / `sync.token` / `device.id` / `blob.cacheLimitBytes`。
  选本地 SQLite 而非新增 `shared_preferences` 依赖 —— 与既有存储同源，
  一份代码三端通用（Web 同样落在 IndexedDB）。
- **deviceId 首次生成后恒定**：用于来源标记（`sourceDevice`）与冲突归因；
  断开连接只清地址与 Token，**保留** deviceId 与本地数据。
- **连接即装配**：`AppController.connect()` 负责构造
  `CachedBlobStore(LocalBlobStore(dataDir/blobs), SqliteBlobCacheMeta(db))`
  并注入 `SyncClient`。注意此处**不设** `CachedBlobStore.fetcher` —— 下载由
  `SyncClient.ensureBlob()` 统一负责，设了会形成自我递归。
- **离线优先不变**：编辑先落本地并入 Outbox，700ms 防抖后推送；同步失败只把
  状态置为 error 并保留原因，不影响本地读写。
- **WS 降级**：`GET /api/v1/ws` 收到 `changed` 即触发 pull；WS 不可用仅静默降级，
  手动同步与防抖推送仍可用。

落地内容：

| 项 | 文件 | 说明 |
|----|------|------|
| 配置表 | `note_core/lib/src/db/app_database.dart` | 新增 `Settings` 表，schema v4 + 迁移 |
| 配置模型 | `note_core/lib/src/models/sync_config.dart` | `SyncConfig` + 地址规范化 |
| 配置读写 | `note_core/lib/src/repository/settings_store.dart` | get/set、deviceId、缓存上限 |
| 账号操作 | `note_core/lib/src/sync/auth_client.dart` | `register` / `login` / `ping`（取 Token 的入口，不能走已鉴权的 SyncClient） |
| 状态中枢 | `flutter_app/lib/src/ui/app_controller.dart` | 可变的 `syncClient`、`SyncState`、`connect`/`disconnect`/`syncNow`、WS 订阅、编辑自动入队 |
| 设置 UI | `flutter_app/lib/src/ui/sync_settings_dialog.dart` | 地址 / 用户名密码注册登录 / Token / 测试连接 / 缓存上限 |
| 顶栏状态 | `flutter_app/lib/src/ui/note_shell.dart` | 同步状态图标（未连接/已同步/同步中/失败）+ 立即同步 + 设置入口 |
| 启动装配 | `flutter_app/lib/src/bootstrap.dart`、`app.dart`、`main.dart` | `AppStorage` 一并返回 db / repository / dataDir |
| 依赖 | `flutter_app/pubspec.yaml` | 新增 `web_socket_channel`（WS 跨端可用） |

验收（本次实测）：

| 检查 | 命令 | 结果 |
|------|------|------|
| 服务端 | `go build ./... && go test -count=1 -v ./internal/api/` | 构建通过，7/7 PASS |
| note_core 测试 | `dart test` | 35/35 通过（新增配置存取 9 用例） |
| note_core 静态检查 | `dart analyze` | No issues found |
| 客户端测试 | `flutter test` | 5/5 通过（含 `sync_wiring_test.dart`：起真服务端，注册连接 → 新建 → 同步 → 第二台设备拉到） |
| 客户端静态检查 | `flutter analyze` | No issues found |
| Web 构建 | `flutter build web --release` | ✓ Built build/web |

> 环境备注：WSL 内 Go 工具链位于 `/home/aiuser/go-sdk/go/bin`、Flutter 位于
> `/home/aiuser/flutter/bin`，二者均不在默认 `PATH`，需显式指定绝对路径调用。

#### 修复 3 ✅ 附件-笔记映射跨端同步（服务端 `attachments` 表补全）

对应 §20.2 #3 与 §18.2「映射同步」。原状：服务端 `attachments` 表建了但没有任何
读写方法与协议字段，push/pull 载荷里也没有附件——客户端即便本地有映射，跨端也无法
重建；`blobs.refcount` 只在上传字节时 +1，与「有多少笔记引用它」脱钩，GC 语义不成立。

设计要点：

- **映射随笔记走**：push 载荷 `items[].attachments[]`、pull 载荷 `notes[].attachments[]`。
  不引入独立同步游标——映射脱离笔记没有意义，随笔记走还能复用 `base_version` 的冲突语义。
- **含墓碑**：客户端推送该笔记**全部**附件映射（`includeDeleted: true`），
  否则对端的删除永远收敛不了。
- **只在笔记被接受时落库**：冲突（`accepted=false`）时服务端不落映射——被拒的是本地
  草稿，其引用尚未成为权威内容的一部分；客户端合并重发时会一并带来。
- **refcount 唯一来源是映射**：语义定为「指向该 sha256 的有效映射条数」。新增 +1、
  墓碑化 -1、改指别的 sha 则旧 -1 新 +1，因此重复推送天然幂等。据此把上传接口
  `PUT /blobs/{hash}` 的 `AddBlobRef(+1)` 换成 `EnsureBlob`（只登记、不动计数），
  避免「上传字节」与「挂载附件」对同一 blob 重复计数。
- **客户端记账对称**：`upsertRemoteAttachment()` 除写 `attachments` 表外，还同步维护
  本地 `blob_refs.refCount`，否则 LRU 会把仍被笔记引用的附件当孤儿淘汰掉——
  这正是 §18 方案 B 一直缺的那一环。
- **字节依旧不随映射走**：pull 只写元数据，`CachedBlobStore.exists()` 仍为 false；
  打开附件才走 `ensureBlob()` 按需下载。

落地内容：

| 项 | 文件 | 说明 |
|----|------|------|
| 服务端表 | `server/internal/store/store.go` | `attachments` 补 `updated_at`；新增 `AttachmentRow` + `ListAttachments` / `ListAttachmentsForNotes` / `SyncAttachments`（含 refcount 调整） |
| 服务端协议 | `server/internal/sync/sync.go` | `PushItem.Attachments`、`AttachmentItem`；`Push` 落映射；`Pull` 返回 `PullNote{Note, Attachments}` |
| 服务端接口 | `server/internal/api/sync_handlers.go` | pull 响应带 `attachments`；blob 上传改用 `EnsureBlob`（不再 +refcount） |
| 客户端模型 | `note_core/lib/src/models/attachment.dart` | `toJson` / `fromJson`（协议载荷，不含 noteId） |
| 客户端仓储 | `note_core/lib/src/repository/note_repository.dart` | `listAttachments(includeDeleted:)`；`upsertRemoteAttachment()` + `_adjustBlobRef()` |
| 客户端同步 | `note_core/lib/src/sync/sync_client.dart` | push 携带附件；pull 落附件（`_applyRemoteAttachments`） |

验收（本次实测）：

| 检查 | 命令 | 结果 |
|------|------|------|
| 服务端 | `go build ./... && go test -count=1 ./internal/api/` | 构建通过，8/8 PASS（新增 `TestAttachmentMappingSync`：映射往返 / refcount 幂等 / 改指 / 墓碑归零 / 孤儿 GC） |
| note_core 测试 | `dart test` | 38/38 通过（新增 push 携带附件、pull 落映射 + 记账、e2e 映射同步 + 字节按需下载） |
| note_core 静态检查 | `dart analyze` | No issues found |
| 客户端测试 | `flutter test` | 5/5 通过 |
| 客户端静态检查 | `flutter analyze` | No issues found |
| Web 构建 | `flutter build web --release` | ✓ Built build/web |

> 顺带把本次改动的 Go 文件跑了 `gofmt -w`；仓库其余文件存在既有格式漂移，
> 未一并处理以免产生无关 diff。

#### 修复 4 ✅ 附件上传与选择器（方案 B 上行补齐）

对应 §20.2 #4 与 §18.2「上传方向」。原状：附件只有下行通道（按需下载），没有任何上行入口
——用户无法从本机添加附件；卡片只区分「未下载 / 已缓存」两态，而 `AppController` 缺
`addAttachmentFromBytes` / `removeAttachment` 等入口，编辑器里也没有附件按钮。

设计要点：

- **上行三件事**（新增即传 / 同步周期补传 / 先补传再 push）见 §18.2「上传方向」。
- **引用计数归仓储**：`addAttachment` +1、`removeAttachment` -1、`markNoteDeleted` 连带墓碑化
  该笔记全部附件并逐个 -1。计数是方案 B 的关键一环——没有它，新挂载的附件会被 LRU 当孤儿淘汰。
- **`uploaded_at` 标记而非每轮探测**：`blob_refs` 新增该列（drift schema v5），null = 服务端
  尚未确认持有；上传成功或从服务端下载回来即置位。用本地记账判断待上传清单，不必每轮对全部
  hash 发 `HEAD`，省网络且离线可用。
- **字节读取放平台层**：note_core 是纯 Dart 包、不能碰 `dart:io`，故用 `file_picker` 的
  `withData: true` 在平台层一次拿字节，Web / 桌面 / 移动三端接口一致。
- **正文引用即事实**：挂载后在 Markdown 正文插入 `![name](sui://<sha256>)`。canonical 正本只有
  Markdown，附件与正文必须一起同步，否则换台设备拉到笔记却不知道它带附件。
- **预览图片走缓存**：`sui://` scheme 交给 `_SuiAttachmentImage`（本地命中或按需下载），
  加载中 / 加载失败都有占位，不留白。
- **修掉废弃 API**：`flutter_markdown` 的 `imageBuilder` 已废弃，预览改用 `sizedImageBuilder`
  （额外拿到 `width` / `height`，图片尺寸约束更准）。

落地内容：

| 项 | 文件 | 说明 |
|----|------|------|
| schema v5 | `note_core/lib/src/db/app_database.dart` | `blob_refs.uploaded_at` + 迁移 |
| 记账层 | `note_core/lib/src/blob/sqlite_blob_cache_meta.dart`、`cached_blob_store.dart` | `markUploaded` / `pendingUploads`（只查记账 + 一次本地存在性检查，不发网络） |
| 引用计数 | `note_core/lib/src/repository/note_repository.dart` | `addAttachment` / `removeAttachment` / `markNoteDeleted` 维护 `blob_refs.refCount` |
| 上传 | `note_core/lib/src/sync/sync_client.dart` | `uploadBlob`（幂等 `PUT /blobs/{hash}`）/ `backfillBlobs`；`sync()` 先补传再 push |
| MIME 推断 | `note_core/lib/src/util/mime_kind.dart` | 由扩展名推大类（卡片图标用），不做内容嗅探 |
| 平台选择器 | `flutter_app/lib/src/platform/attachment_picker.dart` | `file_picker` 封装，返回文件名 + 字节 |
| 状态中枢 | `flutter_app/lib/src/ui/app_controller.dart` | `addAttachmentFromBytes` / `removeAttachment` / `attachmentAvailability` / `openAttachment` |
| 编辑器 UI | `flutter_app/lib/src/ui/note_editor.dart` | 工具条「添加附件」+ 卡片四态（已同步/待上传/仅本机/未下载）+ 移除 + `sui://` 预览渲染 |
| 预览钩子 | `flutter_app/lib/src/ui/markdown_editor.dart` | `imageBuilder` → `sizedImageBuilder` |
| 依赖 | `flutter_app/pubspec.yaml` | 新增 `file_picker` |
| 测试 | `note_core/test/attachment_test.dart`、`cached_blob_store_test.dart`、`sync_client_test.dart` | 引用计数增删 / 共享 sha / 墓碑连带 / 待上传清单 / 上传顺序 / 补传幂等 |

验收（本次实测）：

| 检查 | 命令 | 结果 |
|------|------|------|
| 服务端 | `go build ./... && go test -count=1 ./internal/api/` | 构建通过，8/8 PASS（本次未改服务端） |
| note_core 测试 | `dart test` | 51/51 通过（新增引用计数 / 上传 / 补传等 13 用例） |
| note_core 静态检查 | `dart analyze` | No issues found |
| 客户端测试 | `flutter test` | 5/5 通过 |
| 客户端静态检查 | `flutter analyze` | No issues found |
| Web 构建 | `flutter build web --release` | ✓ Built build/web（含 `file_picker` Web 实现） |

> 环境备注：`flutter test` / `dart test` 在 WSL 下需 `LD_LIBRARY_PATH=/home/aiuser/.local/lib`
> （`libsqlite3.so` 软链所在目录），否则 drift 报 `Failed to load dynamic library 'libsqlite3.so'`。
