# 变更日志

本文件记录随手记 Sui 的重要变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.5.0] - 2026-09-30

M4 里程碑：单用户服务化与安全加固。

### 变更

- **服务模式定为单用户（FR-33）** — 一个服务实例即一个用户的笔记库；首启创建唯一账号后关闭
  自助注册（再次注册返回 403 `already-initialized`），`/api/v1/ping` 回带 `initialized`
  供客户端判定首启状态。
- **剪藏 id 幂等与去碰撞（FR-34）** — 剪藏笔记 id 改为 ≥128 bit 摘要（`clip-<32hex>`），
  不再与手写笔记共用命名空间；服务端 `notes` 表新增 `source_url` 幂等键，同 URL 复用既有
  笔记（版本递增），异 URL 各自成篇。
- **WebSocket 广播鉴权（FR-35）** — `/api/v1/ws` 端点改为须 Token 鉴权（`?token=<token>`
  或 `Authorization: Bearer`），未通过返回 401，不再向未授权客户端广播变更。
- **密码与传输安全加固（FR-36）** — 密码以 PBKDF2-HMAC-SHA256（100000 次迭代）+ 每用户
  随机盐存储、登录常量时间比对，老库明文密码首登自动升级；CORS 支持
  `SUI_ALLOWED_ORIGINS` 白名单（未配置时开发模式全允许）；会话以 `sessions` 表为唯一真源，
  支持多设备登录。

### 测试

- 服务端 18/18、note_core 97/97、flutter_app 17/17（新增 `initialized` 心跳、注册网关关闭、
  密码校验、WS 鉴权、剪藏 id 唯一性等用例）。

## [0.3.0] - 2026-09-29

M2 里程碑：整理体验与格式化编辑。

### 新增

- **归档视图（FR-25）** — 左侧栏底部新增「归档」入口，集中展示已归档笔记并支持取消归档；
  服务端 `notes` 表新增 `archived` 列，归档状态随 push/pull 跨端一致。
- **回收站（FR-26）** — 左侧栏底部新增「回收站」入口，收纳已删除（墓碑）笔记，支持查看与还原
  （原笔记本仍在则还原到原笔记本，否则回到「全部笔记」）；删除笔记本时其笔记级联进入回收站。
- **轻量格式化编辑（FR-23 / FR-24）** — 编辑器提供「格式 / 源码 / 预览」三态，正本仍为 Markdown；
  格式工具栏与图片插入 / 尺寸调整（拖拽手柄或预设）即时回写正本。
- **笔记整理与信息呈现（FR-20 / FR-21 / FR-22）** — 笔记列表元信息（创建 / 更新时间、所属笔记本、
  标签）与排序切换；笔记归属调整（移动到…）与基本操作（置顶 / 归档 / 删除）；笔记本排序与软删除；
  全部标签总览（数量统计 + 多选筛选）。
- **界面配色与布局（FR-28）** — 左侧栏底色 `RGB(34,34,38)`，中间栏与编辑栏白底；「新建笔记本」
  按钮移至左侧栏顶部。

### 修复

- **笔记本变更同步（FR-29）** — 新建 / 重命名笔记本未进入待同步队列导致跨端不一致；补齐全部
  笔记本变更的 Outbox 入队，并修正 pull 时间游标仅在笔记变更时推进的缺陷。
- **格式模式图片渲染（FR-27）** — 「格式」模式下图片引用未渲染为图片、尺寸调整无效；改为渲染
  图片呈现单元并在选中后提供尺寸手柄 / 预设。

### 测试

- 服务端 13/13、note_core 90/90、flutter_app 10/10（新增归档净荷、笔记本新建 / 重命名同步、
  格式模式图片渲染与尺寸等用例）。

## [0.2.0] - 2026-09-27

M1 里程碑：笔记本分组与标签的云端同步。

### 新增

- **服务端数据模型** — 新增 `notebooks` / `tags` / `note_tags` 三表（含 4 个索引），
  `notes` 表新增 `notebook_id` 列承载分组归属。
- **同步协议扩展** — push 请求体新增 `notebooks` / `tags` 数组，笔记条目新增
  `notebookId`（指针语义）与 `tagIds`；pull 响应回带同名数组与字段；push 响应新增
  `notebookResults` / `tagResults`，复用 `base_version` 冲突与墓碑机制。
- **客户端** — `SyncClient` 支持笔记本 / 标签入队与推进（`enqueueNotebook` /
  `enqueueTag`，冲突后刷新 base 重发），`NoteRepository` 新增远端落库与关联重建
  （`upsertRemoteNotebook` / `upsertRemoteTag` / `syncNoteTags` / `updateNoteNotebook`）。

### 测试

- 服务端 9/9、note_core 58/58（新增笔记本 / 标签净荷与冲突 6 项 + 新设备首拉 e2e 1 项）。

## [0.1.0] - 2026-09-25

首个可用版本：完成 M0–M5 五个里程碑，服务端、客户端与剪藏扩展端到端可用。

### 新增

- **M0 骨架** — monorepo 工程（顶层 `Makefile` / `README` / `.gitignore`）；Go 服务端
  健康检查与心跳（`/healthz`、`/api/v1/ping`）；Flutter 客户端壳。
- **M1 核心本地笔记** — `clients/note_core`：数据模型、drift SQLite、`BlobStore`
  抽象与 `NoteRepository`；响应式三栏 UI 与 Markdown 源码/预览双轨编辑器。
- **M2 多端同步** — 服务端同步协议（`/sync/push`、`/sync/pull`、`/blobs/{hash}`）
  与 `base_version` 冲突判定；客户端 `SyncClient`（Outbox 合并、增量拉取、冲突本地
  合并、重发）。
- **M3 修订历史** — 服务端修订列表/详情 API；客户端 `RevisionPanel` 与一键恢复
  （恢复以新修订追加，不重写历史）。
- **M4 网页剪藏** — 服务端 `POST /api/v1/clips` 类 Readability 净化 + HTML→Markdown，
  以 URL 为幂等键；Chrome MV3 扩展；客户端「收件箱」。
- **M5 多端打磨** — CORS 中间件、Blob 下载接口、WebSocket 变更广播、登录接口、
  `source_device` 同步、性能索引、Markdown 导出。

### 修复

按时间顺序记录的 8 项修复（完整背景见 [docs/architecture.md](docs/architecture.md)）：

1. 客户端可构建性 + 数据持久化（平台条件导入分层、`path_provider` 落库）。
2. 同步链路接线 + 服务端连接配置 UI（`SyncClient` 实例化并注入 `CachedBlobStore`）。
3. 附件-笔记映射跨端同步（服务端 `attachments` 表补全，映射随笔记 push/pull）。
4. 附件上传与选择器（方案 B 上行补齐：新增即传 + 同步周期补传 + 先补传再 push）。
5. 桌面/移动平台脚手架（`android` `ios` `linux` `macos` `windows`）。
6. 删除 M0 死代码 `home_page.dart`。
7. 运行命令与文档对齐（结构树、测试用例数、各端可构建性实况）。
8. 核心特性清单与实际能力对齐；补充 30s 周期兜底同步。

### 已知限制

- 关键字搜索为 `LIKE` 子串匹配，FTS5 仅架构预留（未启用）。
- 编辑为源码 / 预览双轨，富文本 WYSIWYG 未实现。
- 鉴权为演示级实现，公网部署前需加固（见 [SECURITY.md](SECURITY.md)）。

[Unreleased]: https://gitee.com/evangubo/sui/compare/v0.5.0...HEAD
[0.5.0]: https://gitee.com/evangubo/sui/releases/tag/v0.5.0
[0.3.0]: https://gitee.com/evangubo/sui/releases/tag/v0.3.0
[0.2.0]: https://gitee.com/evangubo/sui/releases/tag/v0.2.0
[0.1.0]: https://gitee.com/evangubo/sui/releases/tag/v0.1.0
