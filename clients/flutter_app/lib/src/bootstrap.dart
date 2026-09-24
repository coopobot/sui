import 'package:note_core/note_core.dart';

import 'platform/data_dir.dart';

/// 初始化本地数据库 + 仓储。
///
/// - 非 Web（桌面/移动）：落地 `<应用支持目录>/sui/sui.sqlite`，持久化。
/// - Web：drift wasm + 浏览器持久化（OPFS → IndexedDB 回退），无文件路径。
///
/// [basePath] 仅原生平台有效，用于测试或指定自定义数据目录。
Future<(AppDatabase, NoteRepository)> bootstrapStorage({String? basePath}) async {
  final dir = basePath ?? await resolveDataDir();
  final db = AppDatabase.file(basePath: dir);
  return (db, NoteRepository(db));
}