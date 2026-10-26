# 架构总览

> 本文是**根级薄入口**，只给出全局视角与导航；完整的架构说明、数据模型与
> 同步协议见 [docs/architecture.md](docs/architecture.md)。

随手记 Sui 采用「**本地优先 + 自托管服务端**」架构：客户端把笔记完整保存在本地
SQLite，离线可读可写；服务端只负责汇聚与版本仲裁；剪藏扩展通过 HTTP 把网页送进
服务端净化入库。四类组件通过 REST + WebSocket 协同。

## 一图看全貌

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

## 设计原则

- **离线优先**：客户端所有数据本地持久化，服务端只负责汇聚与版本仲裁。
- **Markdown 唯一正本**：笔记内容一律为 Markdown 字符串，编辑器是「源码 + 预览」
  双轨，杜绝富文本中间态转换风险。
- **内容寻址附件**：附件以 sha256 为键存储，天然去重、校验完整；映射全量同步、
  字节按需拉取 + LRU 上限。
- **服务端权威版本线**：`version` 由服务端递增下发，客户端只携带 `base_version`
  做冲突判定，不可自行篡改。
- **绝不丢字**：冲突合并采用启发式策略，双方内容都会保留。

## 深入阅读

| 想了解 | 去哪里 |
|--------|--------|
| 系统分层、数据模型、同步协议 | [docs/architecture.md](docs/architecture.md) |
| 为什么这样设计（决策记录） | [docs/adr/](docs/adr/) |
| HTTP 接口清单与载荷 | [docs/api-reference.md](docs/api-reference.md) |
| 环境搭建与构建测试 | [docs/getting-started.md](docs/getting-started.md) |
