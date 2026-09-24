import 'package:note_core/note_core.dart';

import 'platform/data_dir.dart';

/// 应用启动时组装好的存储三件套。
///
/// 一起返回是因为上层（`AppController`）需要 [db] 做配置读写与附件缓存记账、
/// 需要 [dataDir] 定位附件缓存目录、需要 [repository] 做业务读写。
class AppStorage {
  AppStorage({
    required this.db,
    required this.repository,
    required this.dataDir,
  });

  final AppDatabase db;
  final NoteRepository repository;

  /// 原生平台的数据目录；Web 为 null（持久化由浏览器存储负责）。
  final String? dataDir;
}

/// 初始化本地数据库 + 仓储。
///
/// - 非 Web（桌面/移动）：落地 `<应用支持目录>/sui/sui.sqlite`，持久化。
/// - Web：drift wasm + 浏览器持久化（OPFS → IndexedDB 回退），无文件路径。
///
/// [basePath] 仅原生平台有效，用于测试或指定自定义数据目录。
Future<AppStorage> bootstrapStorage({String? basePath}) async {
  final dir = basePath ?? await resolveDataDir();
  final db = AppDatabase.file(basePath: dir);
  return AppStorage(
    db: db,
    repository: NoteRepository(db),
    dataDir: dir,
  );
}