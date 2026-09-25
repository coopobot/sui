import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

/// Web 连接：drift wasm + 浏览器持久化。
///
/// 需要 `web/` 下存在两个资源（见 `docs/getting-started.md`）：
/// - `sqlite3.wasm`
/// - `drift_worker.dart.js`
///
/// drift 会探测浏览器能力，按可靠性优先选择 OPFS（shared worker）→
/// IndexedDB → 内存。`[basePath]` 在 Web 无意义（持久化位置由浏览器决定），
/// 保留参数只为与原生实现签名一致。
QueryExecutor openConnection({String? basePath, bool inMemory = false}) {
  return LazyDatabase(() async {
    final result = await WasmDatabase.open(
      databaseName: 'sui',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.dart.js'),
    );
    return result.resolvedExecutor;
  });
}
