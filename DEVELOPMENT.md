# 开发指南

> 本文是**根级薄入口**，只给出开发所需的导航与常用命令；逐项操作步骤见
> [docs/](docs/index.md) 下的详细文档。

## 从这里开始

1. **搭好环境** → [docs/getting-started.md](docs/getting-started.md)
   （Go / Flutter / SQLite native 库、构建与测试命令）
2. **理解架构** → [docs/architecture.md](docs/architecture.md)
   （服务端分层、客户端分层、数据模型、同步协议）
3. **查接口** → [docs/api-reference.md](docs/api-reference.md)
4. **遇到问题** → [docs/troubleshooting.md](docs/troubleshooting.md)

## 仓库构成（monorepo）

| 目录 | 说明 | 技术栈 |
|------|------|--------|
| `server/` | 同步服务端 | Go（标准库 `net/http`） |
| `clients/note_core/` | 多端共享核心（纯 Dart，无 Flutter 依赖） | Dart + drift |
| `clients/flutter_app/` | Flutter 多端客户端 | Flutter + Provider |
| `extension/` | 网页剪藏扩展 | Chrome MV3 |
| `docs/` | 文档中心 | Markdown |

## 常用命令

```bash
# 服务端：构建 / 测试
cd server && go build ./... && go vet ./... && go test ./... -count=1

# 共享核心：生成代码 / 静态检查 / 测试
cd clients/note_core && dart run build_runner build && dart analyze && dart test

# Flutter 客户端：静态检查 / 测试 / 运行
cd clients/flutter_app && flutter analyze && flutter test && flutter run -d chrome

# 顶层 Makefile
make build-server   # 编译服务端到 server/bin/sui-server
make run-server     # 编译并运行（SUI_ADDR 可覆盖端口）
make test           # 服务端测试
```

> drift schema 变更后必须重新执行 `build_runner build`。

## 参与贡献

- 贡献流程与代码规范 → [CONTRIBUTING.md](CONTRIBUTING.md)
- 社区行为准则 → [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- 安全策略与漏洞上报 → [SECURITY.md](SECURITY.md)
- 变更历史 → [CHANGELOG.md](CHANGELOG.md)
