/// 本地存储位置（Web 端桩实现）。
///
/// Web 端持久化由浏览器存储（OPFS / IndexedDB）负责，**没有文件系统路径**，
/// 因此本能力不支持（BR-58.8）：界面不渲染入口，相关调用一律安全降级。
library;

/// Web 端不支持本地存储位置能力。
bool get supportsStorageLocation => false;

/// 存储位置解析状态（与 io 侧同名同义，供共用代码编译）。
enum StorageLocationState { defaultDir, pointerDir, pointerUnavailable }

/// 存储位置解析结果（Web 端 `dataDir` 恒为空串，表示「无路径」）。
class StorageResolution {
  const StorageResolution({
    required this.state,
    required this.dataDir,
    required this.defaultDir,
    required this.pointerPath,
    this.configuredDir,
  });

  factory StorageResolution.forDir(String dir) => StorageResolution(
        state: StorageLocationState.defaultDir,
        dataDir: dir,
        defaultDir: dir,
        pointerPath: '',
      );

  final StorageLocationState state;
  final String dataDir;
  final String defaultDir;
  final String pointerPath;
  final String? configuredDir;

  bool get usable => true;
  bool get custom => false;
}

/// 无文件系统路径。
Future<String> resolveAppSupportRoot() async => '';

/// Web 端恒为「无路径」。
Future<StorageResolution> resolveStorageLocation({String? appSupportRoot}) async =>
    const StorageResolution(
      state: StorageLocationState.defaultDir,
      dataDir: '',
      defaultDir: '',
      pointerPath: '',
    );

/// Web 端无指针文件。
Future<String?> readStoragePointer(String pointerPath) async => null;

/// Web 端不支持写指针。
Future<void> writeStoragePointer(String pointerPath, String dataDir) async {
  throw UnsupportedError('本地存储位置仅桌面端支持');
}

/// 目标目录问题（与 io 侧同名）。
enum StorageTargetIssue { samePath, containsAppData, notEmpty }

/// Web 端不适用。
Future<StorageTargetIssue?> checkStorageTarget({
  required String currentDir,
  required String targetDir,
}) async =>
    null;

/// 目录统计（Web 端恒为空）。
class StorageDirStats {
  const StorageDirStats({
    required this.tableCounts,
    required this.blobFiles,
    required this.blobBytes,
  });

  final Map<String, int> tableCounts;
  final int blobFiles;
  final int blobBytes;
}

/// 校验报告（与 io 侧同名）。
class StorageVerifyReport {
  const StorageVerifyReport({required this.source, required this.target});

  final StorageDirStats source;
  final StorageDirStats target;

  bool get ok => false;
  String describe() => 'Web 端不支持本地存储迁移';
}

/// 迁移阶段（与 io 侧同名）。
enum StorageMigrationStage {
  checkpoint,
  copyDatabase,
  copyBlobs,
  verify,
  switchPointer,
}

/// 迁移结果（与 io 侧同名）。
class StorageMigrationResult {
  const StorageMigrationResult({
    required this.ok,
    this.error,
    this.report,
    this.targetDir,
  });

  final bool ok;
  final String? error;
  final StorageVerifyReport? report;
  final String? targetDir;
}

/// Web 端不支持。
Future<StorageDirStats> statsOfCopy(String dataDir) async =>
    const StorageDirStats(tableCounts: <String, int>{}, blobFiles: 0, blobBytes: 0);

/// Web 端不支持。
Future<(int, int)> dirStats(String dir) async => (0, 0);

/// Web 端不支持。
Future<({int databaseBytes, int blobBytes})> storageUsage(String dataDir) async =>
    (databaseBytes: 0, blobBytes: 0);

/// Web 端不支持。
Future<StorageMigrationResult> migrateStorage({
  required String fromDir,
  required String toDir,
  required String pointerPath,
  required Future<void> Function() checkpoint,
  required Future<Map<String, int>> Function() sourceTableCounts,
  void Function(StorageMigrationStage stage)? onStage,
}) async =>
    const StorageMigrationResult(
      ok: false,
      error: '本地存储位置仅桌面端支持',
    );

/// Web 端无系统文件管理器可打开。
Future<void> openInFileManager(String dir) async {}

/// Web 端不退出进程。
Future<void> quitApp() async {}
