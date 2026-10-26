import 'package:drift/drift.dart';

/// 兜底实现：当前平台既非原生也非 Web（不应出现）。
QueryExecutor openConnection({String? basePath, bool inMemory = false}) {
  throw UnsupportedError('当前平台没有可用的 SQLite 实现');
}