/// 数据库连接的平台条件导入。
///
/// - 原生（桌面 / 移动 / Dart VM 测试）：`drift/native` + SQLite 文件。
/// - Web：`drift/wasm` + 浏览器持久化（OPFS / IndexedDB）。
///
/// 该分层是为了让 Web 构建不引入 `dart:io` / `dart:ffi`（二者在 Web 不可用）。
library;

export 'connection_unsupported.dart'
    if (dart.library.io) 'connection_io.dart'
    if (dart.library.js_interop) 'connection_web.dart';