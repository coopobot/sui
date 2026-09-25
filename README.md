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
| 附件管理 | 内容寻址 Blob（sha256 去重）；映射全量同步、字节按需拉取 + LRU 缓存上限，本地占用与附件总量解耦 |
| 笔记分组 | 笔记本（嵌套）+ 标签（多对多） |
| 实时通知 | WebSocket 变更广播，多端即时感知 |
| 数据导出 | Markdown 一键复制到剪贴板 |

## 技术栈

| 层级 | 技术 |
|------|------|
| 客户端 | Flutter（Android / iOS / Windows / macOS / Linux / Web） |
| 状态管理 | Provider |
| 本地存储 | SQLite（drift），FTS5 全文搜索预留 |
| 服务端 | Go（标准库 net/http），单二进制自托管 |
| 服务端存储 | SQLite 元数据 + 本地磁盘 Blob（sha256 分片） |
| 同步协议 | 自研 push/pull + base_version 冲突检测 + 三向合并 |
| 剪藏净化 | 类 Readability 启发式 + HTML→Markdown 转换器 |
| 浏览器扩展 | Chrome Extension Manifest V3 |
| 实时通知 | WebSocket（nhooyr.io/websocket） |

## 项目结构（monorepo）

```
sui/
├── docs/                    # 文档中心
│   ├── DESIGN.md            # 设计与规划文档（同步协议、冲突解决等）
│   ├── USER_GUIDE.md        # 产品使用说明（部署 / 客户端 / 剪藏扩展）
│   └── DEVELOPER.md         # 开发者文档（环境搭建 / 构建 / 测试 / 架构 / API）
├── server/                  # Go 同步服务端（自托管友好）
│   ├── cmd/sui-server/      # 服务端入口
│   └── internal/            # api / auth / blob / clip / cors / store / sync / ws 等
├── clients/
│   ├── note_core/           # 多端共享核心逻辑（纯 Dart：模型 / 本地库 / 同步引擎）
│   └── flutter_app/         # Flutter 多端客户端
├── extension/               # Chrome 剪藏扩展（Manifest V3）
├── protos/                  # 共享接口契约定义
├── scripts/                 # 构建 / 部署脚本
└── Makefile                 # 顶层构建工具
```

## 快速开始

### 1. 启动服务端

```bash
cd server
go build -o bin/sui-server ./cmd/sui-server
./bin/sui-server            # 默认监听 :8080，数据目录 ./data
```

可通过环境变量覆盖：`SUI_ADDR`（监听地址，默认 `:8080`）、`SUI_DATA`（数据目录，默认 `./data`）。

验证：

```bash
curl http://localhost:8080/healthz
curl http://localhost:8080/api/v1/ping
```

### 2. 注册账号获取 Token

```bash
curl -X POST http://localhost:8080/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{"username":"me","password":"secret"}'
# → {"ok":true,"token":"...","username":"me"}
```

### 3. 运行客户端

```bash
cd clients/flutter_app
flutter run -d windows   # 或 -d chrome / -d linux / -d android
```

客户端默认连接 `http://127.0.0.1:8080`。

### 4. 安装剪藏扩展

1. 打开 Chrome → `chrome://extensions` → 开启「开发者模式」
2. 「加载已解压的扩展程序」→ 选择 `extension/` 目录
3. 点击扩展图标 → 右键「选项」→ 填入服务端地址与 Token

详细步骤见 [docs/USER_GUIDE.md](docs/USER_GUIDE.md)。

## 文档索引

- [📖 产品使用说明](docs/USER_GUIDE.md) —— 服务端部署、客户端使用、剪藏扩展、账号与同步
- [🛠 开发者文档](docs/DEVELOPER.md) —— 环境搭建、构建测试、架构说明、API 参考
- [📐 设计与规划](docs/DESIGN.md) —— 需求设计、同步协议、冲突解决、里程碑记录

## 里程碑

- [x] **M0 骨架** — monorepo + Go 服务端基础 + Flutter 客户端壳
- [x] **M1 核心本地笔记** — note_core 数据层 + Markdown 双轨编辑器 + 响应式三栏 UI
- [x] **M2 多端同步** — 服务端同步协议 + 客户端同步引擎（Outbox / 冲突合并 / e2e 测试）
- [x] **M3 修订历史** — 服务端修订 API + 客户端恢复逻辑 + Flutter 历史面板
- [x] **M4 网页剪藏** — 服务端净化 API + Chrome MV3 扩展 + 客户端收件箱
- [x] **M5 多端打磨** — CORS + Blob 下载 + WebSocket 通知 + 登录 + 导出 + 性能索引

## 许可证

（待定 —— 自托管个人项目）
