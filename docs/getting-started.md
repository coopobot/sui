# 快速开始

本指南帮助**开发者**从零把随手记 Sui 跑起来：搭建环境 → 构建测试 → 端到端联调。
只想使用产品请看[用户指南](guides/user-guide.md)。

## 1. 前置要求

| 工具 | 版本要求 | 用途 |
|------|----------|------|
| Go | ≥ 1.26 | 服务端编译运行 |
| Flutter SDK | ≥ 3.22（内含 Dart 3.3+） | 客户端 |
| Dart SDK | 随 Flutter（本项目实测 3.13.4） | note_core 包 |
| SQLite3 native 库 | 任意现代版本 | drift 本地库依赖（仅原生平台） |
| Git | 任意 | 版本管理 |

## 2. 环境搭建

### 2.1 Go

```bash
# Linux / macOS
curl -LO https://go.dev/dl/go1.26.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.26.0.linux-amd64.tar.gz
export PATH=/usr/local/go/bin:$PATH

# Windows
winget install GoLang.Go
```

验证：

```bash
go version   # go version go1.26.0 linux/amd64
```

> 服务端 `server/go.mod` 声明 `go 1.26.0`；若本机 Go 版本较低，Go 1.21+ 的工具链
> 机制（`GOTOOLCHAIN`）会自动拉取所需工具链，也可显式升级本机 Go。

### 2.2 Flutter / Dart

```bash
# Linux
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH=$HOME/flutter/bin:$PATH
flutter doctor        # 按提示安装 Android SDK / Linux 工具链等

# Windows
winget install --id Google.Flutter
flutter doctor
```

验证：

```bash
flutter --version
dart --version
```

> 国内网络建议配置镜像：`PUB_HOSTED_URL` 与 `FLUTTER_STORAGE_BASE_URL` 指向镜像站。

### 2.3 SQLite3 native 库（drift 依赖，仅原生平台）

`note_core` 在**原生平台**（桌面 / 移动 / Dart VM 测试）通过 `drift/native` 访问
SQLite，运行需要 `libsqlite3` 动态库。**Web 端不需要本节配置**（Web 走 `drift/wasm`，
见 §4.4）。

**Ubuntu / Debian（WSL 或 Linux）**

```bash
sudo apt install libsqlite3-dev
```

WSL 常见问题：系统只有 `libsqlite3.so.0` 而没有 `libsqlite3.so` 符号链接，需手动建立：

```bash
mkdir -p ~/.local/lib
ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ~/.local/lib/libsqlite3.so
export LD_LIBRARY_PATH=$HOME/.local/lib:$LD_LIBRARY_PATH
# 建议把 export 追加到 ~/.bashrc
```

**Windows / macOS**：drift 会自动定位系统 SQLite，一般无需额外处理。

## 3. 项目结构

```
sui/
├── README.md / LICENSE / CONTRIBUTING.md / CHANGELOG.md
├── CODE_OF_CONDUCT.md / SECURITY.md / DEVELOPMENT.md / ARCHITECTURE.md
├── Makefile                     # 顶层构建入口：build-server / run-server / test / clean
├── docs/                        # 详细文档（本目录，见 index.md）
│   ├── index.md / getting-started.md / architecture.md
│   ├── api-reference.md / deployment.md / troubleshooting.md
│   ├── adr/                     # 架构决策记录
│   ├── guides/                  # 用户指南、网页剪藏
│   └── examples/                # 代码示例
├── server/                      # Go 服务端
│   ├── cmd/sui-server/          # 入口（HTTP server + 优雅启停）
│   ├── internal/
│   │   ├── api/                 # HTTP handler + 路由
│   │   ├── auth/                # Bearer Token 鉴权中间件
│   │   ├── blob/                # 附件存储（sha256 分片 + 引用计数 + GC）
│   │   ├── clip/                # HTML 净化 → Markdown 引擎
│   │   ├── cors/                # CORS 中间件
│   │   ├── store/               # SQLite 数据访问（notes/revisions/blobs/users）
│   │   ├── sync/                # 同步协议核心（push/pull + 冲突判定）
│   │   ├── version/             # 版本号
│   │   └── ws/                  # WebSocket 变更通知 Hub
│   ├── configs/                 # 配置样例
│   └── go.mod / go.sum
├── clients/
│   ├── note_core/               # 纯 Dart 共享核心（无 Flutter 依赖）
│   │   └── lib/src/
│   │       ├── db/              # drift schema + 生成代码
│   │       ├── models/          # Note / Notebook / Tag / Attachment / Revision
│   │       ├── repository/      # NoteRepository（CRUD / 标签 / 搜索 / 修订）
│   │       ├── sync/            # SyncClient + Outbox + 冲突合并
│   │       ├── blob/            # BlobStore 抽象 + LocalBlobStore + CachedBlobStore
│   │       └── util/            # 工具
│   └── flutter_app/             # Flutter 客户端
│       └── lib/src/
│           ├── app.dart / bootstrap.dart / main.dart
│           └── ui/              # note_shell / notebook_tree / note_list /
│                                # note_editor / markdown_editor / revision_panel /
│                                # app_controller（Provider 状态）
├── extension/                   # Chrome 剪藏扩展（MV3）
├── protos/                      # 预留（当前为空目录，未入库）
└── scripts/                     # 预留（当前为空目录，未入库）
```

## 4. 构建与测试

### 4.1 服务端

```bash
cd server
go mod tidy                # 首次拉取依赖（国内可用 GOPROXY=https://goproxy.cn,direct）
go build ./...             # 编译
go build -o bin/sui-server ./cmd/sui-server   # 输出二进制
go vet ./...               # 静态检查
go test ./... -count=1     # 全部测试（当前 8 个用例，均在 internal/api）
```

### 4.2 note_core（纯 Dart 包）

```bash
cd clients/note_core
dart pub get
dart run build_runner build   # 生成 drift 代码（app_database.g.dart）
dart analyze                  # 静态检查
dart test                     # 全部用例（当前 51 个，含 2 个 e2e）
```

> 注意：drift schema 变更后必须重新执行 `build_runner build`。

### 4.3 Flutter 客户端

```bash
cd clients/flutter_app
flutter pub get
flutter analyze                # 静态检查（当前 0 问题）
flutter test                   # widget 测试（当前 5 个）

# 运行 / 构建
flutter run -d chrome          # Web（本机已验证）
flutter build web              # 产出 build/web
```

> **平台脚手架现状**：`web/` 与 `android/ ios/ linux/ macos/ windows/` 六个平台目录
> **均已入库**，应用显示名统一为「随手记 Sui」。但**可构建性取决于本机工具链**，
> 不是代码问题：

| 目标 | 脚手架 | 本机可构建 | 缺什么 |
|------|--------|-----------|--------|
| Web | ✅ | ✅ 已实测 | — |
| Linux 桌面 | ✅ | ⚠️ | `clang` / `ninja-build` / `pkg-config` / `libgtk-3-dev` |
| Windows 桌面 | ✅ | ➖ | 只能在 Windows 宿主构建 |
| macOS 桌面 | ✅ | ➖ | 只能在 macOS 宿主构建 |
| Android | ✅ | ⚠️ | Android SDK（+ 设备/模拟器） |
| iOS | ✅ | ➖ | 只能在 macOS 宿主构建 |

Linux 工具链安装（需要 sudo）：

```bash
sudo apt install -y clang ninja-build pkg-config libgtk-3-dev
```

### 4.4 Web 端资源（sqlite3.wasm 与 drift worker）

Web 端用 `drift/wasm` 访问 SQLite，需要 `clients/flutter_app/web/` 下两个**已入库**的资源：

| 资源 | 说明 |
|------|------|
| `sqlite3.wasm` | SQLite 的 WebAssembly 引擎 |
| `drift_worker.dart.js` | drift worker（承载 sqlite3 与浏览器文件系统模拟） |

`drift_worker.dart.js` 是编译产物，源码为 `web/drift_worker.dart`。**修改源码后需重新生成**：

```bash
cd clients/flutter_app
dart compile js -O4 --no-source-maps web/drift_worker.dart -o web/drift_worker.dart.js
```

`sqlite3.wasm` 的版本必须与 `note_core` 的 `sqlite3` 依赖版本一致（当前 `2.9.4`）：

```bash
cd clients/flutter_app/web
curl -L -o sqlite3.wasm \
  https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-2.9.4/sqlite3.wasm
```

> 缺失任一资源时，浏览器控制台会出现 drift worker / wasm 相关报错，数据库将回退为
> **内存实现**（数据不持久化）。验证是否落库：DevTools 中执行
> `indexedDB.databases()`，应能看到名为 `sui` 的库。

### 4.5 顶层 Makefile

```bash
make build-server   # 编译服务端到 server/bin/sui-server
make run-server     # 编译并运行（SUI_ADDR 可覆盖端口）
make test           # 服务端测试
make clean
```

## 5. 端到端联调

手动联调流程：

1. 启动服务端：`make run-server`
2. 注册账号获取 token（见[部署指南 · 注册与 Token](deployment.md#3-注册账号与-token)）
3. 启动客户端：`cd clients/flutter_app && flutter run -d chrome`
4. 新建一篇笔记 → 再开第二个客户端窗口 → 观察 WebSocket 通知触发同步
5. 双端同时编辑同一笔记制造冲突 → 验证自动合并不丢字

> 注：客户端顶栏右上角有同步状态图标与「同步设置」入口。首次使用先在设置里填服务端
> 地址，用「注册并连接」/「登录并连接」拿 Token（也可直接粘贴已有 Token）。连接后
> 编辑会自动防抖推送，服务端 WS 广播变更时会自动拉取。

## 6. 新增代码的流程

- **新增服务端 API**：`internal/api/` 加 handler → `api.NewRouter` 注册路由 →
  数据访问写 `internal/store`、同步语义写 `internal/sync` → 在 `handlers_test.go`
  补测试 → `go test ./... -count=1`。
- **新增数据表 / 字段**：改 `note_core/lib/src/db/app_database.dart` → 增加迁移版本 →
  `dart run build_runner build` → 同步域模型与 `NoteRepository`。
- **新增 UI 页面**：组件放入 `flutter_app/lib/src/ui/` → 通过 `AppController` 读写状态
  → 补 widget 测试 → `flutter analyze`。

## 7. 遇到问题？

见[故障排查](troubleshooting.md)。
