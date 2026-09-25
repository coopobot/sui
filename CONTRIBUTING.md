# 贡献指南

感谢你愿意为**随手记 Sui** 做出贡献！本文说明如何搭建环境、遵循哪些约定，
以及如何提交被顺利合并的改动。

> 参与本项目即表示你同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 目录

1. [开发环境](#1-开发环境)
2. [项目结构](#2-项目结构)
3. [构建与测试](#3-构建与测试)
4. [代码规范](#4-代码规范)
5. [提交与分支约定](#5-提交与分支约定)
6. [Pull Request 流程](#6-pull-request-流程)
7. [文档规范](#7-文档规范)

---

## 1. 开发环境

完整步骤见 [docs/getting-started.md](docs/getting-started.md)。最少需要：

| 工具 | 版本要求 | 用途 |
|------|----------|------|
| Go | ≥ 1.22（实测 1.22.12） | 服务端 |
| Flutter SDK | ≥ 3.22（内含 Dart 3.3+） | 客户端 |
| SQLite3 native 库 | 任意现代版本 | drift 本地库依赖 |

> 各包的具体环境变量、镜像与 WSL 常见坑，见
> [docs/getting-started.md](docs/getting-started.md) 与
> [docs/troubleshooting.md](docs/troubleshooting.md)。

## 2. 项目结构

```
sui/
├── server/          # Go 同步服务端（标准库 net/http）
├── clients/
│   ├── note_core/   # 多端共享核心（纯 Dart，无 Flutter 依赖）
│   └── flutter_app/ # Flutter 多端客户端
├── extension/       # Chrome MV3 剪藏扩展
├── docs/            # 文档中心（见 docs/index.md）
└── Makefile         # 顶层构建入口
```

架构与设计决策见 [docs/architecture.md](docs/architecture.md) 与
[docs/adr/](docs/adr/)。

## 3. 构建与测试

改动前后请确保相关包全部通过：

```bash
# 服务端
cd server && go vet ./... && go test ./... -count=1

# 共享核心
cd clients/note_core && dart analyze && dart test

# Flutter 客户端
cd clients/flutter_app && flutter analyze && flutter test
```

> WSL 下跑 Dart 测试若报 `Failed to load dynamic library 'libsqlite3.so'`，
> 见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 4. 代码规范

- **Go**：提交前执行 `gofmt -w`，`go vet ./...` 无告警。
- **Dart**：`dart analyze` / `flutter analyze` 必须 **0 问题**；遵循仓库内
  `analysis_options.yaml`。
- **drift schema 变更**：修改 `app_database.dart` 后必须
  `dart run build_runner build` 重新生成代码，并补充迁移与测试。
- **不引入无必要依赖**：新增依赖前请在 PR 中说明理由。

## 5. 提交与分支约定

- **分支名**：`feat/xxx`、`fix/xxx`、`docs/xxx`、`refactor/xxx`。
- **提交信息**：使用简短的中文祈使句，首行 ≤ 50 字，说明「做了什么」而非
  「改了哪个文件」。必要时在正文补充动机与影响。
- **一个提交一件事**：避免把无关改动混在同一次提交里。

## 6. Pull Request 流程

1. Fork 仓库并从 `main` 切出功能分支。
2. 完成改动，确保第 3 节的构建与测试全部通过。
3. 若涉及文档所述行为，请同步更新对应文档（见第 7 节）。
4. 提交 PR，描述中写清：
   - 解决的问题 / 新增的能力
   - 验证方式（跑了哪些命令、结果如何）
   - 是否包含破坏性变更或数据库迁移
5. 等待 review。审核通过后由维护者合并。

## 7. 文档规范

- 根目录只保留 GitHub 约定识别的文件（全大写），详细文档放在 `docs/`。
- `docs/` 下文件名使用 **lowercase-kebab-case**，ADR 使用中文编号命名。
- 改动功能/接口/命令时，同步更新对应文档，避免文档与实现脱节。
- 文档索引见 [docs/index.md](docs/index.md)。

---

有问题欢迎先开 Issue 讨论，避免做无用功。祝你贡献愉快！
