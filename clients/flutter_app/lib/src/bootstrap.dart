import 'package:note_core/note_core.dart';

/// 初始化本地数据库 + 仓储。
///
/// - 非 Web（桌面/移动）：落地文件库 `sui.sqlite`，持久化。
/// - Web：当前用内存库（drift wasm 落库在 M5 多端打磨时接入）。
Future<(AppDatabase, NoteRepository)> bootstrapStorage({
  String? basePath,
}) async {
  final db = AppDatabase.memory();
  // 注：此处预留 file 落库入口。当前默认内存库，聚焦 M1 UI 层验证；
  // 持久化数据目录与 web wasm 见 M5。
  if (basePath != null) {
    final fileDb = AppDatabase.file(basePath: basePath);
    return (fileDb, NoteRepository(fileDb));
  }
  return (db, NoteRepository(db));
}