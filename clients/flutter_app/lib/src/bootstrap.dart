import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;

import 'platform/storage_location.dart';

/// 应用启动时组装好的存储三件套。
///
/// 一起返回是因为上层（`AppController`）需要 [db] 做配置读写与附件缓存记账、
/// 需要 [dataDir] 定位附件缓存目录、需要 [repository] 做业务读写。
class AppStorage {
  AppStorage({
    required this.db,
    required this.repository,
    required this.dataDir,
    this.resolution,
  });

  final AppDatabase db;
  final NoteRepository repository;

  /// 原生平台的数据目录；Web 为 null（持久化由浏览器存储负责）。
  final String? dataDir;

  /// 存储位置解析结果（M12 修订 / FR-58）。
  ///
  /// [StorageResolution.state] 为 `pointerUnavailable` 时，[dataDir] 指向
  /// **占位目录**（`<应用支持根>/sui-unavailable`）：应用仍能启动以便给出
  /// **阻断式提示**（重试 / 改回默认目录 / 重新指定路径，BR-58.7），
  /// 但**绝不**静默改用默认目录继续读写用户数据。
  final StorageResolution? resolution;
}

/// 初始化本地数据库 + 仓储。
///
/// - 非 Web（桌面 / 移动）：数据目录由**引导指针** `<应用支持根>/storage.json` 决定，
///   无指针时用默认目录 `<应用支持根>/sui`（BR-58.1）；库落地 `<数据目录>/sui.sqlite`。
/// - Web：drift wasm + 浏览器持久化（OPFS → IndexedDB 回退），无文件路径。
///
/// [basePath] 仅原生平台有效，用于测试或显式指定数据目录（**不读指针**）。
Future<AppStorage> bootstrapStorage({String? basePath}) async {
  if (basePath != null) {
    return _open(StorageResolution.forDir(basePath), explicitDir: basePath);
  }
  final resolution = await resolveStorageLocation();
  return _open(resolution, explicitDir: null);
}

Future<AppStorage> _open(
  StorageResolution resolution, {
  required String? explicitDir,
}) async {
  final String? dir;
  if (explicitDir != null) {
    dir = explicitDir;
  } else if (!resolution.usable) {
    // 指针目录不可用：用**占位目录**启动（界面阻断），不碰默认目录里的用户数据。
    dir = p.join(p.dirname(resolution.pointerPath), 'sui-unavailable');
  } else {
    dir = resolution.dataDir.isEmpty ? null : resolution.dataDir;
  }
  final db = AppDatabase.file(basePath: dir);
  return AppStorage(
    db: db,
    repository: NoteRepository(db),
    dataDir: dir,
    resolution: resolution,
  );
}
