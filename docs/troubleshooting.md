# 故障排查

汇集使用与开发过程中最常见的问题及排查思路。若未覆盖，欢迎通过
[CONTRIBUTING](../CONTRIBUTING.md) 的渠道反馈。

## 使用类问题

### 客户端连不上服务端？

1. 确认服务端已启动：`curl http://<host>:8080/healthz` 应返回 `{"ok":true,...}`。
2. 确认「同步设置」里的地址与端口正确（跨设备用机器 IP 或域名，不要用 `127.0.0.1`）。
3. 跨设备时确认防火墙放行端口。
4. Web 端跨域问题已由服务端 CORS 解决；若仍失败，检查反代是否透传。

### 剪藏扩展提示「连接失败：HTTP 401」？

Token 错误或已过期。重新注册 / 登录获取新 Token，更新扩展设置。

### 剪藏结果没有正文？

部分网页（如纯 JS 渲染的单页应用）正文在脚本执行后生成，扩展抓取的是原始 HTML。
可先选中网页文字再右键剪藏。

### 两个设备都改了同一篇笔记，会丢内容吗？

不会。冲突自动合并，双方内容都会保留（冲突段落带标记分隔）。原理见
[系统架构 · 同步协议](architecture.md#4-同步协议与冲突解决)。

### 忘记 Token 怎么办？

调用登录接口用用户名密码重新获取 Token，然后更新各客户端 / 扩展设置。

### 离线时某些附件打不开？

未缓存到本机的附件离线打不开（卡片显示「未下载」），联网后点击即可下载；
离线时新添加的附件仍会挂到笔记上（卡片显示「待上传」），联网后自动补传。

### 本地磁盘被附件占满？

附件不会全部下载到每台设备，只有真正打开过的才缓存，且总量受「缓存上限」约束
（默认 512MB，可在同步设置里调整）。超出上限时，最久未打开且没有被任何笔记引用的
附件会被自动清理，再次打开会重新下载。详见
[系统架构 · 附件存储策略](architecture.md#5-附件存储策略客户端侧)。

## 开发类问题

### `dart test` / `flutter test` 报 `Failed to load dynamic library 'libsqlite3.so'`

drift 在原生平台需要 `libsqlite3` 动态库。WSL / Linux 常见问题是只有 `libsqlite3.so.0`
而没有 `libsqlite3.so` 符号链接：

```bash
mkdir -p ~/.local/lib
ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ~/.local/lib/libsqlite3.so
export LD_LIBRARY_PATH=$HOME/.local/lib:$LD_LIBRARY_PATH
```

运行测试时确保该 `LD_LIBRARY_PATH` 生效。

### Web 端数据不持久化（刷新即丢）

检查 `clients/flutter_app/web/` 下是否存在 `sqlite3.wasm` 与 `drift_worker.dart.js`。
缺失任一资源时，浏览器控制台会出现 drift worker / wasm 相关报错，数据库回退为内存实现。

- 验证是否落库：DevTools 中执行 `indexedDB.databases()`，应能看到名为 `sui` 的库。
- 重新生成方式见[快速开始 §4.4](getting-started.md#44-web-端资源sqlite3wasm-与-drift-worker)。

### `flutter build web` 报 `Dart library 'dart:ffi' is not available on this platform`

平台相关能力必须走条件导入（壳文件 + `*_io.dart` / `*_web.dart`），不能无条件
`import 'dart:io'` 或 `package:drift/native.dart`。检查新增代码是否破坏了这一分层，
见[系统架构 · 平台分层](architecture.md#6-平台分层条件导入与构建目标)。

### `flutter build linux` 停在 CMake / Ninja 报错

脚手架与平台配置已就位，缺的是**宿主工具链**：

```bash
sudo apt install -y clang ninja-build pkg-config libgtk-3-dev
```

典型报错：`CMake was unable to find a build program corresponding to "Ninja"` /
`CMAKE_CXX_COMPILER not set`。Windows / macOS / iOS 需在对应宿主系统上构建。

### 找不到 `go` / `flutter` 命令

WSL（或其他环境）中工具链可能不在默认 `PATH`，需显式指定绝对路径，例如
Go 在 `/home/aiuser/go-sdk/go/bin`、Flutter 在 `/home/aiuser/flutter/bin`。

### e2e 测试偶发「连接被拒」

测试起服务端后若用固定 `sleep`，机器繁忙时服务端尚未监听会假失败。当前 e2e 已改为
轮询 `GET /healthz` 探活（100ms 一次，上限 20s）。若自建测试出现类似问题，同样改用探活。

### 修改了 drift schema 但代码没生效

drift schema 变更后必须重新生成代码：

```bash
cd clients/note_core
dart run build_runner build
```
