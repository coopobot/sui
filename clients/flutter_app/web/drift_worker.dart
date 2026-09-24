import 'package:drift/wasm.dart';

/// drift Web Worker 入口。
///
/// 编译产物 `drift_worker.dart.js` 供 `WasmDatabase.open` 使用，负责在
/// worker 内承载 sqlite3 与文件系统模拟（OPFS / IndexedDB）。
///
/// 重新生成：
/// ```
/// dart compile js -O4 web/drift_worker.dart -o web/drift_worker.dart.js
/// ```
void main() => WasmDatabase.workerMainForOpen();