/// FR-58 本地存储路径与迁移的门禁（ADR-022 / local-storage.md §7 / AC-216~AC-221）。
///
/// 覆盖：解析四态（含「不静默回落」）、指针原子写、目标目录处置、迁移成功与失败回退、
/// 阶段顺序、占用统计。**待写数据不丢（AC-221）** 由集成用例（真实应用 + 编辑后立即迁移）覆盖。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;

import 'package:sui_flutter_app/src/platform/storage_location.dart';

/// 读取某数据目录的关键表行数（迁移校验的源侧口径）。
Future<Map<String, int>> _tableCounts(String dir) async {
  final db = AppDatabase.file(basePath: dir);
  try {
    final out = <String, int>{};
    for (final table in kVerifiedTables) {
      final row =
          await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
      out[table] = row.read<int>('c');
    }
    return out;
  } finally {
    await db.close();
  }
}

/// 造一个「源数据目录」：真实 drift 库 + 两个附件文件。
Future<String> _makeSourceDir(String root) async {
  final dir = p.join(root, 'sui');
  await Directory(dir).create(recursive: true);
  final db = AppDatabase.file(basePath: dir);
  // drift 的 NativeDatabase 按需建文件：先跑一次查询，确保库文件真的落盘。
  await db.customSelect('SELECT COUNT(*) AS c FROM notes').getSingle();
  await db.close();

  final blobs = <String, int>{'ab' * 32: 10, 'cd' * 32: 5};
  for (final entry in blobs.entries) {
    final file = File(p.join(dir, kBlobsDirName, entry.key.substring(0, 2), entry.key));
    await file.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(entry.value, 7));
  }
  return dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('C1 存储位置解析（不静默回落）', () {
    test('无指针 → 默认目录 <应用支持根>/sui', () async {
      final root = Directory.systemTemp.createTempSync('sui-loc-').path;
      addTearDown(() => Directory(root).deleteSync(recursive: true));

      final res = await resolveStorageLocation(appSupportRoot: root);
      expect(res.state, StorageLocationState.defaultDir);
      expect(res.dataDir, p.join(root, 'sui'));
      expect(res.usable, isTrue);
      expect(res.custom, isFalse);
    });

    test('指针有效且目录可用 → 指针目录', () async {
      final root = Directory.systemTemp.createTempSync('sui-loc-').path;
      addTearDown(() => Directory(root).deleteSync(recursive: true));
      final custom = p.join(root, 'other-disk');
      await Directory(custom).create(recursive: true);
      await writeStoragePointer(p.join(root, kStoragePointerFileName), custom);

      final res = await resolveStorageLocation(appSupportRoot: root);
      expect(res.state, StorageLocationState.pointerDir);
      expect(res.dataDir, custom);
      expect(res.custom, isTrue);
    });

    test('指针存在但目录不可用 → pointerUnavailable（绝不回落默认目录）', () async {
      final root = Directory.systemTemp.createTempSync('sui-loc-').path;
      addTearDown(() => Directory(root).deleteSync(recursive: true));
      final missing = p.join(root, 'unmounted-disk');
      await writeStoragePointer(p.join(root, kStoragePointerFileName), missing);

      final res = await resolveStorageLocation(appSupportRoot: root);
      expect(res.state, StorageLocationState.pointerUnavailable);
      expect(res.usable, isFalse);
      expect(res.configuredDir, missing);
    });

    test('指针 JSON 损坏 → 视为无指针（回落默认目录）', () async {
      final root = Directory.systemTemp.createTempSync('sui-loc-').path;
      addTearDown(() => Directory(root).deleteSync(recursive: true));
      await File(p.join(root, kStoragePointerFileName)).writeAsString('{not json');

      final res = await resolveStorageLocation(appSupportRoot: root);
      expect(res.state, StorageLocationState.defaultDir);
      expect(res.dataDir, p.join(root, 'sui'));
    });
  });

  test('C2 指针原子写：内容可解析、无 .tmp 残留', () async {
    final root = Directory.systemTemp.createTempSync('sui-loc-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final pointer = p.join(root, kStoragePointerFileName);

    await writeStoragePointer(pointer, p.join(root, 'target'));
    expect(File('$pointer.tmp').existsSync(), isFalse);
    final decoded = jsonDecode(File(pointer).readAsStringSync()) as Map;
    expect(decoded['version'], 1);
    expect(decoded['dataDir'], p.join(root, 'target'));
    expect(await readStoragePointer(pointer), p.join(root, 'target'));
  });

  test('AC-220 目标目录处置：同路径 / 已含数据 / 非空', () async {
    final root = Directory.systemTemp.createTempSync('sui-loc-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final src = await _makeSourceDir(root);

    expect(
      await checkStorageTarget(currentDir: src, targetDir: src),
      StorageTargetIssue.samePath,
    );

    final withData = p.join(root, 'with-data');
    await Directory(withData).create(recursive: true);
    await File(p.join(withData, kDatabaseFileName)).writeAsString('');
    expect(
      await checkStorageTarget(currentDir: src, targetDir: withData),
      StorageTargetIssue.containsAppData,
    );

    final unrelated = p.join(root, 'unrelated');
    await Directory(unrelated).create(recursive: true);
    await File(p.join(unrelated, 'a.txt')).writeAsString('x');
    expect(
      await checkStorageTarget(currentDir: src, targetDir: unrelated),
      StorageTargetIssue.notEmpty,
    );

    final empty = p.join(root, 'empty');
    await Directory(empty).create(recursive: true);
    expect(await checkStorageTarget(currentDir: src, targetDir: empty), isNull);
  });

  test('AC-217 迁移成功：库与附件一致、指针切换、旧目录保留', () async {
    final root = Directory.systemTemp.createTempSync('sui-loc-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final src = await _makeSourceDir(root);
    final dst = p.join(root, 'new-location');
    final pointer = p.join(root, kStoragePointerFileName);
    final stages = <StorageMigrationStage>[];

    final res = await migrateStorage(
      fromDir: src,
      toDir: dst,
      pointerPath: pointer,
      checkpoint: () async {},
      sourceTableCounts: () => _tableCounts(src),
      onStage: stages.add,
    );

    expect(res.ok, isTrue, reason: res.error);
    expect(res.targetDir, dst);
    expect(File(p.join(dst, kDatabaseFileName)).existsSync(), isTrue);
    expect(await _tableCounts(dst), await _tableCounts(src));
    final (files, bytes) = await dirStats(p.join(dst, kBlobsDirName));
    expect(files, 2);
    expect(bytes, 15);
    // 旧目录**保留**（BR-58.6）。
    expect(Directory(src).existsSync(), isTrue);
    expect((await dirStats(p.join(src, kBlobsDirName))).$1, 2);
    // 指针已原子切换。
    expect(await readStoragePointer(pointer), dst);
    // 阶段顺序（BR-58.2）。
    expect(stages, <StorageMigrationStage>[
      StorageMigrationStage.checkpoint,
      StorageMigrationStage.copyDatabase,
      StorageMigrationStage.copyBlobs,
      StorageMigrationStage.verify,
      StorageMigrationStage.switchPointer,
    ]);
  });

  test('AC-219 校验不一致 → 不写指针、旧路径继续可用', () async {
    final root = Directory.systemTemp.createTempSync('sui-loc-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final src = await _makeSourceDir(root);
    final dst = p.join(root, 'new-location');
    final pointer = p.join(root, kStoragePointerFileName);

    final res = await migrateStorage(
      fromDir: src,
      toDir: dst,
      pointerPath: pointer,
      checkpoint: () async {},
      // 故意伪造源侧行数 → 校验必须失败
      sourceTableCounts: () async => <String, int>{
        for (final t in kVerifiedTables) t: 999,
      },
    );

    expect(res.ok, isFalse);
    expect(res.error, contains('校验不一致'));
    // **指针未被改写**（仍是「无指针」状态）。
    expect(File(pointer).existsSync(), isFalse);
    // 旧路径可用（库与附件都在）。
    expect(File(p.join(src, kDatabaseFileName)).existsSync(), isTrue);
    expect((await dirStats(p.join(src, kBlobsDirName))).$1, 2);
  });

  test('目标与当前路径相同 → 迁移被拒且不写指针', () async {
    final root = Directory.systemTemp.createTempSync('sui-loc-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final src = await _makeSourceDir(root);
    final pointer = p.join(root, kStoragePointerFileName);

    final res = await migrateStorage(
      fromDir: src,
      toDir: src,
      pointerPath: pointer,
      checkpoint: () async {},
      sourceTableCounts: () => _tableCounts(src),
    );

    expect(res.ok, isFalse);
    expect(res.error, contains('相同'));
    expect(File(pointer).existsSync(), isFalse);
  });

  test('AC-216 占用统计：库 + 附件字节', () async {
    final root = Directory.systemTemp.createTempSync('sui-loc-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final src = await _makeSourceDir(root);

    final usage = await storageUsage(src);
    expect(usage.databaseBytes, greaterThan(0));
    expect(usage.blobBytes, 15);
  });
}
