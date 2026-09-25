# 变更日志

本文件记录随手记 Sui 的重要变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

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

[Unreleased]: https://gitee.com/evangubo/sui/compare/v0.1.0...HEAD
[0.1.0]: https://gitee.com/evangubo/sui/releases/tag/v0.1.0
