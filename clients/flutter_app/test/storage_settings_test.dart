/// FR-58 存储设置与「数据目录不可用」阻断屏的门禁（ui-spec §22.2 / local-storage.md §7）。
///
/// 覆盖：AC-216（桌面端呈现路径与占用）、AC-222（阻断 + 三选一 + 改回默认目录写指针）、
/// AC-223（非桌面平台不渲染）、AC-219（迁移失败在控制层返回可读错误且退出维护态）。
///
/// **纪律**：
/// - 全程**禁用 `pumpAndSettle()`**，改用有界 `pump`（Agents.md §5.2）；
/// - `debugDefaultTargetPlatformOverride` 必须在**测试体结束前**复位（否则 foundation 断言报错）；
/// - 真实文件 IO 需在 `tester.runAsync` 中推进（widget 测试的假时钟不管 IO 完成）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/platform/storage_location.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';
import 'package:sui_flutter_app/src/ui/settings_dialog.dart';
import 'package:sui_flutter_app/src/ui/storage_settings.dart';

/// 有界推进：30 × 16ms = 480ms，远小于 30s 周期同步器（Agents.md §5.2）。
Future<void> _settle(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 「数据目录已就绪」的控制器（指针解析 = 自定义目录）。
Future<AppController> _readyController(String dir) async {
  final db = AppDatabase.memory();
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'fr58-test'),
    database: db,
    dataDir: dir,
    storageResolution: StorageResolution(
      state: StorageLocationState.pointerDir,
      dataDir: dir,
      defaultDir: dir,
      pointerPath: p.join(dir, 'storage.json'),
    ),
  );
  await controller.bootstrap();
  return controller;
}

/// 「指针目录不可用」的控制器（应用跑在占位目录上，界面应整屏阻断）。
Future<AppController> _blockedController(String root) async {
  final db = AppDatabase.memory();
  final missing = p.join(root, 'unmounted-disk');
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'fr58-blocked'),
    database: db,
    dataDir: p.join(root, 'sui-unavailable'),
    storageResolution: StorageResolution(
      state: StorageLocationState.pointerUnavailable,
      dataDir: p.join(root, 'sui'),
      defaultDir: p.join(root, 'sui'),
      pointerPath: p.join(root, 'storage.json'),
      configuredDir: missing,
    ),
  );
  await controller.bootstrap();
  return controller;
}

Widget _dialogHost(AppController controller) {
  return ChangeNotifierProvider<AppController>.value(
    value: controller,
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              // M14（FR-63）：本地存储已成为设置中心的独立分区（BR-63.2），
              // 故测试直接停在该分区（原「同步设置」对话框内嵌形态已升级）。
              onPressed: () => showSettingsDialog(context, controller,
                  section: SettingsSection.storage),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('桌面端同步设置渲染「本地存储」区：路径 + 占用 + 两个入口（AC-216）',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final root = Directory.systemTemp.createTempSync('sui-store-ui-').path;
      addTearDown(() => Directory(root).deleteSync(recursive: true));
      final controller = await _readyController(root);
      addTearDown(controller.dispose);

      await tester.pumpWidget(_dialogHost(controller));
      await tester.tap(find.text('打开设置'));
      await _settle(tester);

      // 分区导航与分区内容都可能出现「本地存储」，故用 findsWidgets。
      expect(find.text('本地存储'), findsWidgets);
      expect(find.text('更改位置…'), findsOneWidget);
      expect(find.text('打开所在文件夹'), findsOneWidget);
      // 当前路径可见（SelectableText 也按文本查找）。
      expect(find.textContaining(root), findsWidgets);
      expect(find.textContaining('占用：库'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('非桌面平台（移动端）不渲染存储设置区（AC-223）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final root = Directory.systemTemp.createTempSync('sui-store-ui-m-').path;
      addTearDown(() => Directory(root).deleteSync(recursive: true));
      final controller = await _readyController(root);
      addTearDown(controller.dispose);

      await tester.pumpWidget(_dialogHost(controller));
      await tester.tap(find.text('打开设置'));
      await _settle(tester);

      expect(find.text('本地存储'), findsNothing);
      expect(find.text('更改位置…'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('数据目录不可用 → 整屏阻断并给三选一（AC-222）', (tester) async {
    final root = Directory.systemTemp.createTempSync('sui-store-blocked-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final controller = await _blockedController(root);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: NoteShell()),
      ),
    );
    await _settle(tester);

    expect(find.byType(StorageUnavailableScreen), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('改回默认目录'), findsOneWidget);
    expect(find.text('重新指定其他路径'), findsOneWidget);
    // 阻断态下不渲染正常外壳内容（编辑区 / 列表不可达）。
    expect(find.text('新建笔记'), findsNothing);
  });

  // 阻断屏「改回默认目录」的**平台层契约**在普通测试里验证（真实文件 IO 在 widget 测试的
  // 假时钟 zone 内不可靠；`tester.runAsync` 又不能调用 tester 方法，会与守卫冲突挂起）。
  test('阻断屏动作等价路径：写入指针 → 解析回落默认目录（AC-222）', () async {
    final root = Directory.systemTemp.createTempSync('sui-store-default-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    const missing = '/nonexistent/unmounted-disk';
    final pointerPath = p.join(root, 'storage.json');
    await writeStoragePointer(pointerPath, missing);

    // 先造出「指针目录不可用」的初始状态。
    var resolved = await resolveStorageLocation(appSupportRoot: root);
    expect(resolved.state, StorageLocationState.pointerUnavailable);

    // 阻断屏「改回默认目录」的动作 = 把指针改写到默认目录；
    // 重启后应用在该目录新建空库（目录因此存在），指针随即生效。
    await writeStoragePointer(pointerPath, resolved.defaultDir);
    await Directory(resolved.defaultDir).create(recursive: true);
    resolved = await resolveStorageLocation(appSupportRoot: root);
    expect(resolved.state, StorageLocationState.pointerDir);
    expect(resolved.dataDir, p.join(root, 'sui'));
  });

  test('控制器：目标为当前目录 → 迁移被拒、错误可读、维护态退出（AC-219）', () async {
    final root = Directory.systemTemp.createTempSync('sui-store-fail-').path;
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    final controller = await _readyController(root);
    addTearDown(controller.dispose);

    final res = await controller.migrateStorageTo(root);
    expect(res.ok, isFalse);
    expect(res.error, isNotNull);
    expect(res.error, isNotEmpty);
    expect(controller.storageMaintenance, isFalse);
  });

  test('控制器：未注入解析结果时迁移返回「仅桌面端支持」（Web / 单测口径）', () async {
    final db = AppDatabase.memory();
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'fr58-nores'),
      database: db,
    );
    addTearDown(controller.dispose);

    final res = await controller.migrateStorageTo('/tmp/whatever');
    expect(res.ok, isFalse);
    expect(res.error, contains('桌面端'));
  });
}
