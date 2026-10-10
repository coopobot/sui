/// 本地存储位置：解析、引导指针与迁移（M12 修订 / FR-58）。
///
/// 决策见 [ADR-022]，详细设计见 `local-storage.md`：
///
/// - 数据目录由**库外引导指针** `<应用支持根>/storage.json` 决定（BR-58.1，库内自指不成立）；
/// - 启动解析**不静默回落**：指针存在但目录不可用时返回
///   [StorageLocationState.pointerUnavailable]，由上层**阻断式提示**（BR-58.7）；
/// - 迁移是「落盘 → 复制 → 校验 → 切换指针」事务，**任一步失败都不切指针**（BR-58.2）；
/// - 校验口径：关键表行数 + `blobs/` 文件数与总字节（BR-58.4）；
/// - 旧目录**保留**，清理是用户的显式动作（BR-58.6）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'storage_location_constants.dart';

/// 本平台是否支持「本地存储位置」能力：桌面端（有可写文件系统）为真。
bool get supportsStorageLocation => true;

/// 存储位置解析状态。
enum StorageLocationState {
  /// 无指针 → 使用默认目录 `<应用支持根>/sui`。
  defaultDir,

  /// 指针有效且目录可用。
  pointerDir,

  /// 指针存在但目录**不可用**（外置盘未挂载 / 被删 / 无权限）。
  pointerUnavailable,
}

/// 存储位置解析结果。
class StorageResolution {
  const StorageResolution({
    required this.state,
    required this.dataDir,
    required this.defaultDir,
    required this.pointerPath,
    this.configuredDir,
  });

  /// 测试 / 显式指定目录（不读指针）。
  factory StorageResolution.forDir(String dir) => StorageResolution(
        state: StorageLocationState.defaultDir,
        dataDir: dir,
        defaultDir: dir,
        pointerPath: p.join(dir, kStoragePointerFileName),
      );

  final StorageLocationState state;

  /// 生效的数据目录（[StorageLocationState.pointerUnavailable] 时为默认目录，
  /// 但**不得**直接使用——上层须先让用户选择）。
  final String dataDir;

  /// 默认目录 `<应用支持根>/sui`。
  final String defaultDir;

  /// 指针文件全路径。
  final String pointerPath;

  /// 指针里写的目录（仅 [StorageLocationState.pointerUnavailable] 时有值）。
  final String? configuredDir;

  /// 是否可用（不可用时上层必须阻断，而不是换目录继续）。
  bool get usable => state != StorageLocationState.pointerUnavailable;

  /// 是否使用了自定义目录（指针生效）。
  bool get custom => state == StorageLocationState.pointerDir;
}

/// 应用支持根（不可迁移；指针文件与默认数据目录都在它下面）。
Future<String> resolveAppSupportRoot() async {
  final base = await getApplicationSupportDirectory();
  return base.path;
}

/// 解析存储位置；[appSupportRoot] 可注入（测试用）。
Future<StorageResolution> resolveStorageLocation({String? appSupportRoot}) async {
  final root = appSupportRoot ?? await resolveAppSupportRoot();
  final defaultDir = p.join(root, 'sui');
  final pointerPath = p.join(root, kStoragePointerFileName);
  final configured = await readStoragePointer(pointerPath);
  if (configured == null) {
    return StorageResolution(
      state: StorageLocationState.defaultDir,
      dataDir: defaultDir,
      defaultDir: defaultDir,
      pointerPath: pointerPath,
    );
  }
  final available = await Directory(configured).exists();
  return StorageResolution(
    state: available
        ? StorageLocationState.pointerDir
        : StorageLocationState.pointerUnavailable,
    dataDir: available ? configured : defaultDir,
    defaultDir: defaultDir,
    pointerPath: pointerPath,
    configuredDir: configured,
  );
}

/// 读取引导指针；无指针 / 内容损坏 / 字段非法一律返回 null（视为「无指针」）。
Future<String?> readStoragePointer(String pointerPath) async {
  final file = File(pointerPath);
  if (!await file.exists()) return null;
  try {
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map) return null;
    final dir = raw['dataDir'];
    if (dir is! String || dir.trim().isEmpty) return null;
    return dir;
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

/// 原子写入引导指针（写 `.tmp` → rename）。
///
/// 原子性很重要：半截 JSON 会被 [readStoragePointer] 判为「无指针」，
/// 那会让应用回落到默认目录 —— 在用户看来就是「数据不见了」。
Future<void> writeStoragePointer(String pointerPath, String dataDir) async {
  final file = File(pointerPath);
  await file.parent.create(recursive: true);
  final tmp = File('$pointerPath.tmp');
  await tmp.writeAsString(
    jsonEncode(<String, Object?>{'version': 1, 'dataDir': dataDir}),
    flush: true,
  );
  await tmp.rename(pointerPath);
}

/// 目标目录问题（BR-58.5 / AC-220）。
enum StorageTargetIssue {
  /// 与当前路径相同。
  samePath,

  /// 目标已含本应用数据（存在 `sui.sqlite`）→ 拒绝覆盖。
  containsAppData,

  /// 目标非空且为无关文件 → 需用户**显式确认**。
  notEmpty,
}

/// 目标目录前置校验；返回 null 表示可以直接迁移（非空需确认的情形由界面处理）。
Future<StorageTargetIssue?> checkStorageTarget({
  required String currentDir,
  required String targetDir,
}) async {
  if (_samePath(currentDir, targetDir)) return StorageTargetIssue.samePath;
  if (await File(p.join(targetDir, kDatabaseFileName)).exists()) {
    return StorageTargetIssue.containsAppData;
  }
  final dir = Directory(targetDir);
  if (await dir.exists()) {
    final empty = await dir.list(followLinks: false).take(1).isEmpty;
    if (!empty) return StorageTargetIssue.notEmpty;
  }
  return null;
}

bool _samePath(String a, String b) =>
    p.equals(p.normalize(p.absolute(a)), p.normalize(p.absolute(b)));

/// 目录占用统计。
class StorageDirStats {
  const StorageDirStats({
    required this.tableCounts,
    required this.blobFiles,
    required this.blobBytes,
  });

  /// 关键表行数（打不开库时为空表 → 校验必然不通过）。
  final Map<String, int> tableCounts;

  /// `blobs/` 文件数。
  final int blobFiles;

  /// `blobs/` 总字节。
  final int blobBytes;
}

/// 统计**目标目录**（未被占用）的关键表行数与附件统计。
///
/// 源侧行数由**实时连接**提供（见 [migrateStorage] 的 `sourceTableCounts`），
/// 避免为校验再开一个源库连接而与正在写入的应用争锁。
Future<StorageDirStats> statsOfCopy(String dataDir) async {
  final counts = <String, int>{};
  final db = AppDatabase.file(basePath: dataDir);
  try {
    for (final table in kVerifiedTables) {
      final row =
          await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
      counts[table] = row.read<int>('c');
    }
  } finally {
    await db.close();
  }
  final (files, bytes) = await dirStats(p.join(dataDir, kBlobsDirName));
  return StorageDirStats(tableCounts: counts, blobFiles: files, blobBytes: bytes);
}

/// 递归统计目录的文件数与总字节（目录不存在视为 0）。
Future<(int, int)> dirStats(String dir) async {
  final d = Directory(dir);
  if (!await d.exists()) return (0, 0);
  var files = 0;
  var bytes = 0;
  await for (final entity in d.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      files++;
      bytes += await entity.length();
    }
  }
  return (files, bytes);
}

/// 数据目录当前占用（库 + 附件），供界面显示（AC-216）。
Future<({int databaseBytes, int blobBytes})> storageUsage(String dataDir) async {
  final dbFile = File(p.join(dataDir, kDatabaseFileName));
  final databaseBytes = await dbFile.exists() ? await dbFile.length() : 0;
  final (_, blobBytes) = await dirStats(p.join(dataDir, kBlobsDirName));
  return (databaseBytes: databaseBytes, blobBytes: blobBytes);
}

/// 迁移阶段（界面文案与门禁断言共用）。
enum StorageMigrationStage {
  checkpoint,
  copyDatabase,
  copyBlobs,
  verify,
  switchPointer,
}

/// 校验报告（源 ↔ 目标逐项比对，BR-58.4）。
class StorageVerifyReport {
  const StorageVerifyReport({required this.source, required this.target});

  final StorageDirStats source;
  final StorageDirStats target;

  /// 校验是否通过：关键表行数一致 + `blobs/` 文件数与总字节一致。
  bool get ok {
    if (source.blobFiles != target.blobFiles) return false;
    if (source.blobBytes != target.blobBytes) return false;
    for (final table in kVerifiedTables) {
      if (source.tableCounts[table] != target.tableCounts[table]) return false;
    }
    return true;
  }

  /// 供失败提示的可读描述（只列不一致项）。
  String describe() {
    final diffs = <String>[];
    for (final table in kVerifiedTables) {
      final a = source.tableCounts[table];
      final b = target.tableCounts[table];
      if (a != b) diffs.add('$table: $a → $b');
    }
    if (source.blobFiles != target.blobFiles) {
      diffs.add('附件文件数: ${source.blobFiles} → ${target.blobFiles}');
    }
    if (source.blobBytes != target.blobBytes) {
      diffs.add('附件字节: ${source.blobBytes} → ${target.blobBytes}');
    }
    return diffs.join('；');
  }
}

/// 迁移结果。
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

  /// 迁移成功时的目标目录。
  final String? targetDir;
}

/// 执行迁移：「落盘 → 复制 → 校验 → 原子切换指针」（BR-58.2）。
///
/// - [checkpoint]：由调用方执行 `PRAGMA wal_checkpoint(TRUNCATE)` 并确保此刻**无并发写**
///   （界面进入维护态，见 local-storage.md §4）；
/// - [sourceTableCounts]：由**实时连接**提供的源侧行数（避免再开源库连接争锁）；
/// - 校验不通过或任一步抛错：**不写指针**，旧路径继续可用。
Future<StorageMigrationResult> migrateStorage({
  required String fromDir,
  required String toDir,
  required String pointerPath,
  required Future<void> Function() checkpoint,
  required Future<Map<String, int>> Function() sourceTableCounts,
  void Function(StorageMigrationStage stage)? onStage,
}) async {
  try {
    final issue = await checkStorageTarget(
      currentDir: fromDir,
      targetDir: toDir,
    );
    if (issue != null) {
      return StorageMigrationResult(
        ok: false,
        error: switch (issue) {
          StorageTargetIssue.samePath => '目标目录与当前存储位置相同',
          StorageTargetIssue.containsAppData => '目标目录已包含随手记 Sui 的数据，已拒绝覆盖',
          StorageTargetIssue.notEmpty => '目标目录非空（需先确认）',
        },
      );
    }

    onStage?.call(StorageMigrationStage.checkpoint);
    await checkpoint();

    onStage?.call(StorageMigrationStage.copyDatabase);
    final target = Directory(toDir);
    await target.create(recursive: true);
    await File(p.join(fromDir, kDatabaseFileName))
        .copy(p.join(toDir, kDatabaseFileName));

    onStage?.call(StorageMigrationStage.copyBlobs);
    await _copyDir(p.join(fromDir, kBlobsDirName), p.join(toDir, kBlobsDirName));

    onStage?.call(StorageMigrationStage.verify);
    final (sourceBlobFiles, sourceBlobBytes) =
        await dirStats(p.join(fromDir, kBlobsDirName));
    final sourceStats = StorageDirStats(
      tableCounts: await sourceTableCounts(),
      blobFiles: sourceBlobFiles,
      blobBytes: sourceBlobBytes,
    );
    final targetStats = await statsOfCopy(toDir);
    final report = StorageVerifyReport(source: sourceStats, target: targetStats);
    if (!report.ok) {
      return StorageMigrationResult(
        ok: false,
        error: '校验不一致：${report.describe()}',
        report: report,
      );
    }

    onStage?.call(StorageMigrationStage.switchPointer);
    await writeStoragePointer(pointerPath, toDir);

    return StorageMigrationResult(ok: true, report: report, targetDir: toDir);
  } on FileSystemException catch (e) {
    return StorageMigrationResult(ok: false, error: '文件操作失败：${e.message}');
  } catch (e) {
    return StorageMigrationResult(ok: false, error: '$e');
  }
}

/// 递归复制目录（保持 `blobs/<sha[:2]>/<sha>` 结构）。
Future<void> _copyDir(String from, String to) async {
  final src = Directory(from);
  if (!await src.exists()) return;
  await for (final entity in src.list(recursive: true, followLinks: false)) {
    final rel = p.relative(entity.path, from: from);
    final dest = p.join(to, rel);
    if (entity is Directory) {
      await Directory(dest).create(recursive: true);
    } else if (entity is File) {
      await Directory(p.dirname(dest)).create(recursive: true);
      await entity.copy(dest);
    }
  }
}

/// 在系统文件管理器中打开目录（「打开所在文件夹」）。
Future<void> openInFileManager(String dir) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', <String>[dir]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[dir]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', <String>[dir]);
    }
  } on ProcessException {
    // 打不开就算了：这是便利功能，失败不影响数据。
  }
}

/// 退出应用（迁移后「立即重启」用）。
///
/// 只退出当前进程：下次启动会读新指针（迁移后**重启生效**，ADR-022 决策 7）。
Future<void> quitApp() async => exit(0);
