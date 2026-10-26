/// M15 桌面命令注册表测试（FR-73 / FR-74 / FR-75，ADR-011 决策 5「命令单一来源」）。
///
/// 覆盖三条新命令：注册与文案、快捷键提示与**真实加速键**登记口径（`findInNote` 刻意
/// **不注册** activator——真实按键由编辑器子树承担，避免双重触发）、勾选态、
/// 菜单项存在（编辑 / 视图），以及执行体经**活动视图**的命令桥派发。
///
/// **纪律**：全程**禁用 `pumpAndSettle()`**（Agents.md §5.2），改用有界 `pump`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/app_menu_bar.dart';
import 'package:sui_flutter_app/src/ui/desktop_commands.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_window_manager.dart';

/// 有界推进：30 × 16ms = 480ms，远小于 30s 周期同步器（Agents.md §5.2）。
Future<void> _settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<AppController> _buildController(String deviceId) async {
  final db = AppDatabase.memory();
  final controller = AppController(
    repository: NoteRepository(db, deviceId: deviceId),
    database: db,
  );
  addTearDown(() async {
    controller.dispose();
    await db.close();
  });
  await controller.bootstrap();
  return controller;
}

/// 最小编辑器命令桥假实现：只记录壳层下发了哪些命令。
class _StubTarget implements EditorCommandTarget {
  final List<String> calls = <String>[];

  @override
  bool get canUndo => false;
  @override
  bool get canRedo => false;
  @override
  void undo() => calls.add('undo');
  @override
  void redo() => calls.add('redo');
  @override
  void cut() => calls.add('cut');
  @override
  void copy() => calls.add('copy');
  @override
  void paste() => calls.add('paste');
  @override
  void selectAll() => calls.add('selectAll');
  @override
  void insertTable() => calls.add('insertTable');
  // M15：新增的两个抽象方法（由 `_NoteEditorState` 实现）。
  @override
  void openFind() => calls.add('openFind');
  @override
  void insertNoteRef() => calls.add('insertNoteRef');
  @override
  void exportNote() => calls.add('exportNote');
  @override
  Future<void> flushPendingEdits() async {}
}

/// 打开顶层菜单：点标签文本 + 有界 pump（沿用 Flutter SDK 自身 menu 测试惯用法）。
Future<void> _openMenu(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('三条新命令的注册与文案（FR-73 / FR-74 / FR-75）', () {
    test('findInNote：编辑组、`Ctrl+F` 文案但**不注册** activator（真实按键在编辑器子树）', () {
      final command = desktopCommands[DesktopCommandId.findInNote]!;
      expect(command.label, '在笔记内查找');
      expect(command.shortcutLabel, 'Ctrl+F');
      // 关键分工：壳层不挂 activator，否则会与编辑器自身的 `Ctrl+F` **双重触发**。
      expect(command.activator, isNull);
      expect(command.checked, isNull);
    });

    test('insertNoteRef：编辑组、`Ctrl+Shift+L`，加速键与文案同源', () {
      final command = desktopCommands[DesktopCommandId.insertNoteRef]!;
      expect(command.label, '插入关联笔记');
      expect(command.shortcutLabel, 'Ctrl+Shift+L');
      expect(
        command.activator,
        const SingleActivator(LogicalKeyboardKey.keyL,
            control: true, shift: true),
      );
    });

    test('togglePropertiesPanel：视图组、`Ctrl+Shift+P`、带勾选态谓词', () {
      final command = desktopCommands[DesktopCommandId.togglePropertiesPanel]!;
      expect(command.label, '笔记属性');
      expect(command.shortcutLabel, 'Ctrl+Shift+P');
      expect(
        command.activator,
        const SingleActivator(LogicalKeyboardKey.keyP,
            control: true, shift: true),
      );
      expect(command.checked, isNotNull);
    });

    test('枚举与注册表一一登记（菜单 / 顶栏 / 快捷键共用同一份定义）', () {
      expect(DesktopCommandId.values, contains(DesktopCommandId.findInNote));
      expect(DesktopCommandId.values, contains(DesktopCommandId.insertNoteRef));
      expect(
        DesktopCommandId.values,
        contains(DesktopCommandId.togglePropertiesPanel),
      );
      for (final id in const [
        DesktopCommandId.findInNote,
        DesktopCommandId.insertNoteRef,
        DesktopCommandId.togglePropertiesPanel,
      ]) {
        expect(desktopCommands.containsKey(id), isTrue, reason: '$id 未登记');
      }
    });
  });

  group('勾选态与可用性谓词', () {
    test('togglePropertiesPanel.checked 跟随主窗口属性面板开关', () async {
      final controller = await _buildController('m15-cmd-checked');
      final command = desktopCommands[DesktopCommandId.togglePropertiesPanel]!;

      expect(command.checked!(controller), isFalse);
      controller.setPropertiesPanelVisible(true);
      expect(command.checked!(controller), isTrue);
      controller.setPropertiesPanelVisible(false);
      expect(command.checked!(controller), isFalse);
    });

    test('togglePropertiesPanel 未选笔记时置灰；选中后可用', () async {
      final controller = await _buildController('m15-cmd-enabled');
      final command = desktopCommands[DesktopCommandId.togglePropertiesPanel]!;

      expect(controller.selectedNoteId, isNull);
      expect(command.isEnabled(controller), isFalse);

      await controller.createNote();
      expect(controller.selectedNoteId, isNotNull);
      expect(command.isEnabled(controller), isTrue);
    });

    test('编辑器类命令（查找 / 关联笔记）无活动编辑器时置灰（BR-41.4）', () async {
      final controller = await _buildController('m15-cmd-grey');
      await controller.createNote();
      // 未注册任何编辑器命令桥 → 两个命令都置灰。
      expect(desktopCommands[DesktopCommandId.findInNote]!.isEnabled(controller),
          isFalse);
      expect(
          desktopCommands[DesktopCommandId.insertNoteRef]!.isEnabled(controller),
          isFalse);

      // 注册后可用（预览态除外——由 canEditContent 统一约束）。
      controller.registerEditorTarget(kMainViewKey, _StubTarget());
      controller.setActiveViewKey(kMainViewKey);
      expect(desktopCommands[DesktopCommandId.findInNote]!.isEnabled(controller),
          isTrue);
      expect(
          desktopCommands[DesktopCommandId.insertNoteRef]!.isEnabled(controller),
          isTrue);

      await controller.setEditorMode(EditorMode.preview);
      expect(desktopCommands[DesktopCommandId.findInNote]!.isEnabled(controller),
          isFalse);
    });
  });

  testWidgets('执行体经活动视图的命令桥派发（FR-73 / FR-75）', (tester) async {
    final controller = await _buildController('m15-cmd-invoke');
    await controller.createNote();
    final target = _StubTarget();
    controller.registerEditorTarget(kMainViewKey, target);
    controller.setActiveViewKey(kMainViewKey);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      ),
    );
    final context = tester.element(find.byType(Scaffold));

    desktopCommands[DesktopCommandId.findInNote]!.invoke(context, controller);
    desktopCommands[DesktopCommandId.insertNoteRef]!.invoke(context, controller);
    expect(target.calls, ['openFind', 'insertNoteRef']);

    // 「笔记属性」是壳层命令：作用于主窗口（活动视图）的属性面板开关。
    desktopCommands[DesktopCommandId.togglePropertiesPanel]!
        .invoke(context, controller);
    expect(controller.showPropertiesPanel, isTrue);
    desktopCommands[DesktopCommandId.togglePropertiesPanel]!
        .invoke(context, controller);
    expect(controller.showPropertiesPanel, isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('菜单栏登记：编辑 → 在笔记内查找 / 插入关联笔记；视图 → 笔记属性',
      (tester) async {
    final controller = await _buildController('m15-cmd-menu');
    await controller.createNote();

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: AppMenuBar(controller: controller)),
          ),
        ),
      ),
    );
    await _settle(tester, frames: 4);

    // 编辑组：两条新命令与既有「插入表格」「查找」同菜单。
    await _openMenu(tester, '编辑');
    expect(find.widgetWithText(MenuItemButton, '插入关联笔记'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, '在笔记内查找'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'Ctrl+Shift+L'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'Ctrl+F'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 视图组：「笔记属性」与「切换修订面板」相邻（互斥共用同一槽位）。
    await _openMenu(tester, '视图');
    expect(find.widgetWithText(MenuItemButton, '笔记属性'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'Ctrl+Shift+P'), findsOneWidget);

    // 点菜单项 = 执行同一命令（命令单一来源）。
    await tester.tap(find.widgetWithText(MenuItemButton, '笔记属性'));
    await _settle(tester, frames: 4);
    expect(controller.showPropertiesPanel, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
