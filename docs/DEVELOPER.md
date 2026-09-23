# 随手记 Sui · 开发者文档

本文面向**开发者**：从零搭建开发环境、构建测试、理解架构与 API，并参与各模块开发。

---

## 目录

1. [环境搭建](#1-环境搭建)
2. [项目结构](#2-项目结构)
3. [构建与测试](#3-构建与测试)
4. [架构总览](#4-架构总览)
5. [服务端开发](#5-服务端开发)
6. [客户端开发](#6-客户端开发)
7. [同步协议与冲突解决](#7-同步协议与冲突解决)
8. [API 参考](#8-api-参考)
9. [剪藏扩展开发](#9-剪藏扩展开发)
10. [安全与生产化](#10-安全与生产化)
11. [路线图](#11-路线图)

---

## 1. 环境搭建

### 1.1 必需工具

| 工具 | 版本要求 | 用途 |
|------|----------|------|
| Go | ≥ 1.26 | 服务端编译运行 |
| Flutter SDK | ≥ 3.22（内含 Dart 3.3+） | 客户端 |
| Dart SDK | 随 Flutter（本项目实测 3.13.4） | note_core 包 |
| SQLite3 native 库 | 任意现代版本 | drift 本地库依赖 |
| Git | 任意 | 版本管理 |

### 1.2 Go 环境

```bash
# Linux / macOS（或官方安装包）
curl -LO https://go.dev/dl/go1.26.x.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.26.x.linux-amd64.tar.gz
export PATH=/usr/local/go/bin:$PATH

# Windows：下载 MSI 安装包或使用 winget
winget install GoLang.Go
```

验证：

```bash
go version   # go version go1.26.x linux/amd64
```

### 1.3 Flutter / Dart 环境

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

### 1.4 SQLite3 native 库（drift 依赖）

note_core 使用 drift 访问 SQLite，运行需要 `libsqlite3` 动态库：

**Ubuntu / Debian（WSL 或 Linux）**

```bash
sudo apt install libsqlite3-dev
```

WSL 环境常见问题是只有 `libsqlite3.so.0` 而没有 `libsqlite3.so` 符号链接，需要手动建立：

```bash
mkdir -p ~/.local/lib
ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ~/.local/lib/libsqlite3.so
export LD_LIBRARY_PATH=$HOME/.local/lib:$LD_LIBRARY_PATH
# 建议把 export 追加到 ~/.bashrc
```

**Windows / macOS**：drift 会自动定位系统 SQLite，一般无需额外处理。

---

## 2. 项目结构

```
sui/
├── docs/
│   ├── DESIGN.md            # 设计文档（需求 / 同步协议 / 冲突解决 / 里程碑）
│   ├── USER_GUIDE.md        # 产品使用说明
│   └── DEVELOPER.md         # 本文档
├── server/                  # Go 服务端
│   ├── cmd/sui-server/      # 入口（HTTP server + 优雅启停）
│   ├── internal/
│   │   ├── api/             # HTTP handler + 路由
│   │   ├── auth/            # Bearer Token 鉴权中间件
│   │   ├── blob/            # 附件存储（sha256 分片 + 引用计数 + GC）
│   │   ├── clip/            # HTML 净化 → Markdown 引擎
│   │   ├── cors/            # CORS 中间件
│   │   ├── store/           # SQLite 数据访问（notes/revisions/blobs/users）
│   │   ├── sync/            # 同步协议核心（push/pull + 冲突判定）
│   │   ├── version/         # 版本号
│   │   └── ws/              # WebSocket 变更通知 Hub
│   ├── configs/             # 配置样例
│   ├── go.mod / go.sum
│   └── Makefile             # 顶层构建工具
├── clients/
│   ├── note_core/           # 纯 Dart 共享核心（无 Flutter 依赖）
│   │   └── lib/src/
│   │       ├── db/          # drift schema + 生成代码
│   │       ├── models/      # Note / Notebook / Tag / Attachment / Revision
│   │       ├── repository/  # NoteRepository（CRUD / 标签 / 搜索 / 修订）
│   │       ├── sync/        # SyncClient + Outbox + 冲突合并
│   │       ├── blob/        # BlobStore 抽象 + LocalBlobStore
│   │       └── util/        # 工具
│   └── flutter_app/         # Flutter 客户端
│       └── lib/src/
│           ├── app.dart / bootstrap.dart / main.dart
│           └── ui/          # note_shell / notebook_tree / note_list /
│                            # note_editor / markdown_editor / revision_panel /
│                            # app_controller（Provider 状态）
├── extension/               # Chrome 剪藏扩展（MV3）
│   ├── manifest.json
│   ├── popup.html / popup.js        # 弹窗剪藏
│   ├── options.html / options.js    # 服务端配置页
│   └── background.js                # 右键菜单 + badge
├── protos/                  # 共享接口契约
├── scripts/                 # 构建 / 部署脚本
└── Makefile
```

---

## 3. 构建与测试

### 3.1 服务端

```bash
cd server
go mod tidy                # 首次拉取依赖（国内可用 GOPROXY=https://goproxy.cn,direct）
go build ./...             # 编译
go build -o bin/sui-server ./cmd/sui-server   # 输出二进制
go vet ./...               # 静态检查
go test ./... -count=1     # 全部测试（当前 7 个用例）
```

### 3.2 note_core（纯 Dart 包）

```bash
cd clients/note_core
dart pub get
dart run build_runner build   # 生成 drift 代码（app_database.g.dart）
dart analyze                  # 静态检查
dart test                     # 单元测试（17 个）+ e2e（1 个）
```

> 注意：drift schema 变更后必须重新执行 `build_runner build`。

### 3.3 Flutter 客户端

```bash
cd clients/flutter_app
flutter pub get
flutter analyze                # 静态检查（当前 0 问题）
flutter test                   # widget 测试
flutter run -d windows|chrome|linux|android
```

### 3.4 顶层 Makefile

```bash
make build-server   # 编译服务端到 server/bin/sui-server
make run-server     # 编译并运行（SUI_ADDR 可覆盖端口）
make test           # 服务端测试
make clean
```

### 3.5 端到端验证

手动联调流程：

1. 启动服务端：`make run-server`
2. 注册账号获取 token（见 USER_GUIDE §3）
3. 启动客户端：`cd clients/flutter_app && flutter run -d windows`
4. 新建一篇笔记 → 再开第二个客户端（`-d chrome`）→ 观察 WebSocket 通知触发同步
5. 双端同时编辑同一笔记制造冲突 → 验证自动合并不丢字

---

## 4. 架构总览

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

**设计原则**

- **离线优先**：客户端所有数据本地持久化，服务端只负责汇聚与版本仲裁。
- **Markdown 唯一正本**：笔记内容一律为 Markdown 字符串，编辑器是"源码+预览"双轨，杜绝富文本中间态转换风险。
- **内容寻址附件**：附件以 sha256 为键存储，天然去重、校验完整。
- **服务端权威版本线**：`version` 由服务端递增下发，客户端只携带 `base_version` 做冲突判定，客户端不可自行篡改。
- **绝不丢字**：冲突合并采用启发式策略，双方内容都会保留。

---

## 5. 服务端开发

### 5.1 数据模型（SQLite）

| 表 | 用途 |
|----|------|
| `users` | 用户（username / password_hash / token） |
| `notes` | 笔记元数据（title / content_markdown / version / is_deleted / source_device / updated_at） |
| `revisions` | 修订历史（note_id / version / title / content / source_device / created_at） |
| `blobs` | 附件引用（hash / ref_count / size） |
| `outbox` | （服务端侧预留）推送队列 |

关键索引：`idx_notes_updated`、`idx_revisions_note_ver`、`idx_notes_isdel`。

### 5.2 分层

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

### 5.3 新增一个 API 的流程

1. 在 `internal/api/` 新增 handler 方法（挂在 `Server` 上）。
2. 在 `api.NewRouter` 注册路由（受保护端点）。
3. 数据访问写在 `internal/store`，同步语义写在 `internal/sync`。
4. 在 `handlers_test.go` 追加测试用例。
5. `go test ./... -count=1` 验证。

### 5.4 测试

当前测试清单（`internal/api/handlers_test.go`）：

| 测试 | 覆盖 |
|------|------|
| TestPing | 心跳 |
| TestHealth | 健康检查 |
| TestPushPull | 推送 + 增量拉取闭环 |
| TestConflictDetection | base_version 冲突判定 |
| TestAuthReject | 无 token / 坏 token 拒绝 |
| TestRevisionListAndGet | 修订列表 + 详情 |
| TestClipEndpoint | 剪藏净化 + URL 幂等 + 同步集成 |

---

## 6. 客户端开发

### 6.1 note_core（共享核心）

纯 Dart 包，不依赖 Flutter，可被任何 Dart 宿主复用。

**关键类**

| 类 | 职责 |
|----|------|
| `NoteRepository` | 本地数据访问门面：笔记本 CRUD、标签、笔记 CRUD、修订追加、搜索 |
| `SyncClient` | 同步引擎：Outbox 合并、增量 pull、冲突本地合并、重发 |
| `AppDatabase` | drift 数据库（6 表 + 迁移） |
| `LocalBlobStore` | 附件本地存储实现 |
| `DeviceId` | 设备标识（冲突合并 / 来源标记用） |

**新增表 / 字段时**：修改 `lib/src/db/app_database.dart` → 增加迁移版本 → `dart run build_runner build` → 同步域模型与 `NoteRepository`。

### 6.2 Flutter 客户端

**状态管理**：Provider + `AppController`（单一状态源，暴露 `notifyListeners`）。

**UI 组件**

| 文件 | 职责 |
|------|------|
| `note_shell.dart` | 响应式三栏骨架（宽屏三栏 / 窄屏抽屉 + 导航堆栈） |
| `notebook_tree.dart` | 笔记本树 + 收件箱 + 全部笔记 + 标签入口 |
| `note_list.dart` | 笔记列表（置顶 / 剪藏标签 / 搜索过滤） |
| `note_editor.dart` | 编辑器（标题 / Markdown 双轨 / 标签 / 历史 / 导出 / 删除） |
| `markdown_editor.dart` | 源码编辑 + 预览切换 |
| `revision_panel.dart` | 版本历史侧栏 + 一键恢复 |
| `app_controller.dart` | 全局状态与业务编排 |

**服务端地址**：`lib/src/home_page.dart` 的 `defaultServerUrl`（默认 `http://127.0.0.1:8080`），可按目标平台注入。

**新增 UI 页面流程**：组件放入 `lib/src/ui/` → 通过 `AppController` 读写状态 → widget 测试（`test/`）→ `flutter analyze`。

### 6.3 测试

- note_core：17 个单元测试（仓储 CRUD / 标签 / 搜索 / 修订 / 同步）+ 1 个 e2e（注册→双端 push/pull→冲突合并→重发）。
- flutter_app：widget 测试。
- 运行前确保 `libsqlite3` 可用（见 §1.4）。

---

## 7. 同步协议与冲突解决

完整设计见 [docs/DESIGN.md](DESIGN.md)。核心要点：

### 7.1 版本模型

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

### 7.2 冲突判定与合并

- **判定**：服务端 `base_version` 撞车即冲突，返回当前 `serverVersion`。
- **合并（客户端启发式）**：
  1. 标题取较新修订。
  2. 正文：合并双方内容，冲突段落用标记分隔，**绝不丢字**。
  3. 合并结果作为新 base 重发。
- **与 Git 类比**：rebase（基于服务端最新）+ merge（双方内容并集）。

### 7.3 历史一致性

- 历史记录以**服务端合并记录**为准，所有端看到一致。
- 客户端未同步的本地修改在同步后并入服务端时间线。

### 7.4 WebSocket 通知

- 端点：`GET /api/v1/ws`。
- push / 剪藏成功后广播 `{"type":"changed"}`。
- 客户端收到后触发一次增量 pull。

---

## 8. API 参考

Base URL：`http://<host>:8080`。受保护接口需请求头 `Authorization: Bearer <token>`。

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| GET | `/healthz` | 否 | 健康检查 |
| GET | `/api/v1/ping` | 否 | 心跳（返回 `{"ok":true}`） |
| POST | `/api/v1/register` | 否 | 注册：`{"username","password"}` → `{"ok","token","username"}` |
| POST | `/api/v1/login` | 否 | 登录：`{"username","password"}` → `{"ok","token","username"}` |
| GET | `/api/v1/ws` | 否* | WebSocket 变更通知（业务消息由客户端自行鉴权） |
| POST | `/api/v1/sync/push` | ✅ | 推送批量变更（见下） |
| GET | `/api/v1/sync/pull?since=<RFC3339>` | ✅ | 增量拉取变更 |
| PUT | `/api/v1/blobs/{hash}` | ✅ | 上传附件字节 |
| GET | `/api/v1/blobs/{hash}` | ✅ | 下载附件字节 |
| HEAD | `/api/v1/blobs/{hash}` | ✅ | 附件存在性 |
| GET | `/api/v1/notes/{id}/revisions` | ✅ | 修订列表 |
| GET | `/api/v1/notes/{id}/revisions/{version}` | ✅ | 修订详情 |
| POST | `/api/v1/clips` | ✅ | 网页剪藏：`{"url","title","html"}` → 净化入库 |

### push 请求体示例

```json
{
  "items": [
    {
      "id": "note-1",
      "title": "示例",
      "content": "# 标题\n正文",
      "baseVersion": 3,
      "version": 4,
      "sourceDevice": "device-windows"
    }
  ]
}
```

### pull 响应示例

```json
{
  "ok": true,
  "serverTime": "2026-09-24T08:00:00Z",
  "notes": [
    {
      "id": "note-1",
      "title": "示例",
      "content": "# 标题\n正文",
      "version": 4,
      "isDeleted": false,
      "sourceDevice": "clip:web-extension",
      "updatedAt": "2026-09-24T08:00:00Z"
    }
  ]
}
```

---

## 9. 剪藏扩展开发

### 9.1 加载调试

1. Chrome → `chrome://extensions` → 开发者模式 →「加载已解压的扩展程序」→ 选择 `extension/`。
2. 右键扩展图标 →「检查」打开 DevTools 调试 popup / background。
3. 改代码后在扩展管理页点「重新加载」。

### 9.2 模块说明

| 文件 | 职责 |
|------|------|
| `manifest.json` | MV3 清单：权限（activeTab / storage / scripting / contextMenus） |
| `popup.html/js` | 弹窗：显示当前页信息 + 剪藏按钮 + 状态反馈 |
| `options.html/js` | 设置页：serverUrl + token 配置 + 连接验证（`storage.sync`） |
| `background.js` | service worker：右键菜单创建 + 菜单剪藏 + badge 状态 |

### 9.3 剪藏数据流

```
popup/background
  → chrome.scripting.executeScript 取 document.documentElement.outerHTML
  → POST {serverUrl}/api/v1/clips  {url, title, html} + Bearer token
  → 服务端 clip.Purify：Readability 选主内容 + HTML→Markdown
  → 以 url 哈希为幂等键 upsert 笔记（source_device=clip:web-extension）
  → WebSocket 广播 changed → 客户端收件箱自动刷新
```

### 9.4 添加图标（可选）

manifest 可声明 `action.default_icon` / `icons`；生成 16/32/48/128px PNG 放入 `extension/icons/` 并在 manifest 引用。

---

## 10. 安全与生产化

当前为演示级实现，公网部署前必须处理：

1. **密码存储**：`store.LoginUser` 目前以明文前缀比对，应改为 bcrypt/argon2 哈希。
2. **Token 轮换**：登录即换 token，客户端需支持重新获取；建议加 token 过期时间。
3. **HTTPS**：生产环境强制 TLS（反代或服务端直接 TLS）。
4. **限流**：register/login 接口加速率限制，防爆破。
5. **WebSocket**：`/api/v1/ws` 建议加鉴权（查询参数或子协议携带 token）。
6. **CORS**：当前开发模式全允许，生产应配置具体来源白名单（`cors.Middleware` 的 `allowedOrigins` 参数）。
7. **数据备份**：定期备份数据目录（`sui.db` + `blobs/`）。

---

## 11. 路线图

已完成（M0-M5）：见 [docs/DESIGN.md](DESIGN.md) 里程碑记录。

后续可选方向：

- [ ] 附件字节同步接入客户端（API 已就绪，客户端侧待接）
- [ ] 富文本 WYSIWYG 编辑器（flutter_quill 升级）
- [ ] 行级 Diff 高亮
- [ ] FTS5 全文搜索正式启用
- [ ] CI（GitHub Actions：go test + dart test + flutter analyze）
- [ ] 端到端自动化测试脚本化
- [ ] 移动端适配打磨（iOS / Android）
- [ ] 多用户隔离完善
