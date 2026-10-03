# 随手记 Sui

**印象笔记替代品 —— 自托管 · 离线优先 · 多端同步的现代 Markdown 笔记应用。**

> 项目英文名：**Sui**（音近「随手」）

随手记 Sui 是一款面向个人知识管理的极简笔记应用：笔记以 Markdown 为唯一正本，
本地 SQLite 离线优先存储，通过自托管 Go 服务端在多端之间同步；支持网页一键剪藏、
版本历史恢复、标题/正文关键字搜索、附件与分组，数据完全由你自己掌控。

## 核心特性

| 特性 | 说明 |
|------|------|
| 离线优先 | 所有笔记存于本地 SQLite，断网可读可写，联网后自动同步（编辑防抖推送 + WS 通知拉取 + 30s 周期兜底） |
| 多端同步 | 自研 push/pull 协议，`base_version` 冲突检测 + 启发式合并，绝不丢字 |
| Markdown 编辑 | 「格式 / 源码 / 预览」三态编辑（Markdown 为唯一正本，格式模式即时回写；预览由 flutter_markdown 渲染；富文本 WYSIWYG 为后续可选增强） |
| 网页剪藏 | Chrome MV3 扩展一键剪藏，支持「智能提取正文 / 全页快照」两种模式；服务端净化转 Markdown 并**本地化页面图片**（下载入库、正文改 `sui://`），**原网页下线后内容与图片仍可读** |
| 版本历史 | 每条修订记录可查看、可一键恢复，历史永不重写 |
| 全局搜索 | 标题 / 正文关键字搜索（`LIKE` 子串匹配，非 FTS5） |
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
├── README.md  LICENSE  CONTRIBUTING.md  CHANGELOG.md    # 根级：社区/协作文件（全大写）
├── CODE_OF_CONDUCT.md  SECURITY.md  DEVELOPMENT.md  ARCHITECTURE.md
├── docs/                    # 文档中心（入口：docs/index.md）
│   ├── index.md             # 文档索引
│   ├── getting-started.md   # 环境搭建 / 构建测试 / 快速开始
│   ├── architecture.md      # 系统架构 / 数据模型 / 同步协议
│   ├── api-reference.md     # HTTP API 参考
│   ├── deployment.md        # 部署与生产化
│   ├── troubleshooting.md   # 故障排查
│   ├── adr/                 # 架构决策记录
│   ├── guides/              # 用户指南
│   └── examples/            # 代码示例
├── server/                  # Go 同步服务端（自托管友好）
│   ├── cmd/sui-server/      # 服务端入口
│   └── internal/            # api / auth / blob / clip / cors / store / sync / ws 等
├── clients/
│   ├── note_core/           # 多端共享核心逻辑（纯 Dart：模型 / 本地库 / 同步引擎）
│   └── flutter_app/         # Flutter 多端客户端
├── extension/               # Chrome 剪藏扩展（Manifest V3）
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
flutter run -d chrome    # Web（本机已验证可运行）
```

客户端**不预设服务端地址**：首次使用点顶栏「同步设置」，填入地址（如
`http://127.0.0.1:8080`）并用上一步拿到的账号「注册并连接」或「登录并连接」，
配置会存入本地库，之后自动防抖同步。

### 4. 安装剪藏扩展

1. 打开 Chrome → `chrome://extensions` → 开启「开发者模式」
2. 「加载已解压的扩展程序」→ 选择 `extension/` 目录
3. 点击扩展图标 → 右键「选项」→ 填入服务端地址与 Token

> 详细步骤与各平台构建说明见 [docs/getting-started.md](docs/getting-started.md)。

## 文档导航

| 文档 | 内容 |
|------|------|
| [📚 文档中心](docs/index.md) | 全部文档的索引入口 |
| [🚀 快速开始](docs/getting-started.md) | 环境搭建、构建测试、端到端验证 |
| [🏛 系统架构](docs/architecture.md) | 分层设计、数据模型、同步协议 |
| [🔌 API 参考](docs/api-reference.md) | HTTP 接口与载荷示例 |
| [📦 部署指南](docs/deployment.md) | 生产部署、反代、备份、安全加固 |
| [🧭 故障排查](docs/troubleshooting.md) | 常见问题与已知坑 |
| [📖 用户指南](docs/guides/user-guide.md) | 客户端日常使用 |
| [🧩 网页剪藏](docs/guides/web-clipper.md) | 浏览器扩展使用 |
| [📐 决策记录](docs/adr/) | 架构决策记录（ADR） |
| [🛠 开发指南](DEVELOPMENT.md) | 开发者根级入口 |
| [🏗 架构总览](ARCHITECTURE.md) | 架构根级入口 |

## 里程碑

- [x] **v0.1.0（M0）框架与基本功能** — 工程骨架；笔记 / 笔记本 / 标签本地 CRUD、多端同步、修订历史、网页剪藏、附件策略等基本功能跑通
- [x] **v0.2.0（M1）笔记本分组与标签的云端同步** — 服务端 `notebooks` / `tags` / `note_tags` 三表 + 同步净荷扩展
- [x] **v0.3.0（M2）整理体验与格式化编辑** — 归类 / 排序 / 归档 / 回收站 / 标签总览 + 格式三态编辑与图片尺寸
- [x] **v0.5.0（M4）单用户服务化与安全加固** — 首启建号 + 注册网关 + 密码哈希 + WS 鉴权 + CORS 白名单
- [x] **v0.6.0（M5）编辑器交互与呈现增强** — 编辑快捷键 + 任务列表勾选框与高亮 + 聚焦式呈现
- [x] **v0.7.0（M6）全页快照与离线自持剪藏** — 剪藏新增「全页快照」模式 + 图片等内容本地化，来源失效仍可读
- [x] **v0.8.0（M7）桌面端界面布局优化** — 左栏 / 中栏可分别折叠隐藏（纯编辑区沉浸写作）+ 顶栏「文件 / 编辑 / 视图 / 帮助」自绘菜单栏（与图标按钮、快捷键同源）

> 里程碑与版本一一对应；M3 编号留空（原 M3 顺延为 M5，见 `CHANGELOG.md`）。
> 变更历史详见 [CHANGELOG.md](CHANGELOG.md)。

## 贡献

欢迎参与贡献！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 与
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。安全问题请按 [SECURITY.md](SECURITY.md) 上报。

## 许可证

本项目基于 [MIT License](LICENSE) 开源。
