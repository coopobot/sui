/// M18 / FR-107：正文右键菜单（桌面接管 `TextField.contextMenuBuilder`）。
///
/// 覆盖：
/// * 桌面（平台钉 Windows）右键正文 → 指针处弹出应用内菜单，含编辑组（剪切 / 复制 /
///   粘贴 / 全选）与插入组（添加关联笔记… / 插入附件… / 插入链接… / 插入表格… / 插入分割线）；
/// * 打开菜单**不改正本、不改选区**（BR-107.1）；无选区时剪切 / 复制禁用（AC-611）；
/// * 「添加关联笔记…」与工具栏同源：选择器 → `[标题](sui://note/<id>)`（AC-608）；
/// * 「插入附件…」与工具栏同源：调起同一个文件选择器（AC-609）；
/// * 移动端 / Web 保持框架默认工具栏、不出现自定义项（AC-614）；预览态无自定义菜单（AC-607）。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（Agents.md §5.2：30s 周期兜底同步会静默卡到超时）；
/// 平台覆写必须在用例体结束前复位（foundation 不变量检查早于 `addTearDown`，Agents.md §5.18）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/platform/attachment_picker.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/editor_context_menu.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

Finder _contentField() => find
    .descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    )
    .first;

TextEditingController _content(WidgetTester tester) =>
    tester.widget<TextField>(_contentField()).controller!;

/// 有界推进（**不用** `pumpAndSettle`）。
Future<void> _settle(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 起一个挂真实 `NoteShell` 的编辑器（宽屏，使工具栏 / 模式行整行可见）。
Future<AppController> _pumpEditor(
  WidgetTester tester,
  AppDatabase db,
  String deviceId,
  String content,
) async {
  final repo = NoteRepository(db, deviceId: deviceId);
  final controller = AppController(repository: repo, database: db);
  await controller.bootstrap();
  await controller.createNote();
  await controller.saveNote(
    controller.selectedNoteId!,
    title: 'T',
    content: content,
    tags: const <String>[],
  );

  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: const MaterialApp(home: NoteShell()),
    ),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  return controller;
}

/// 在正文中心按鼠标右键，并等菜单路由动画**完成**（`showMenu` 的入场动画
/// 第一帧位移为 0，必须多帧推进后菜单项才可命中）。
Future<void> _rightClickBody(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(_contentField()),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pump(); // post-frame 回调里 showMenu
  await _settle(tester);
}

/// 菜单某一项（按标题文字定位 `PopupMenuItem`）。
PopupMenuItem<EditorContextAction> _menuItem(
  WidgetTester tester,
  String label,
) {
  return tester.widget<PopupMenuItem<EditorContextAction>>(
    find.ancestor(
      of: find.text(label),
      matching: find.byType(PopupMenuItem<EditorContextAction>),
    ),
  );
}

void main() {
  testWidgets('桌面右键正文：菜单含编辑组与插入组，且不改正本 / 选区', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      await _pumpEditor(tester, db, 'm18-menu-open', '正文第一行');
      final ctrl = _content(tester);
      final before = ctrl.text;
      // 先聚焦正文再放光标：未聚焦时右键会按框架口径把光标落到点击位置（既有行为）。
      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();

      await _rightClickBody(tester);

      for (final label in <String>[
        '剪切',
        '复制',
        '粘贴',
        '全选',
        '添加关联笔记…',
        '插入附件…',
        '插入链接…',
        '插入表格…',
        '插入分割线',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '菜单应包含「$label」');
      }

      // 折叠光标（无选区）→ 剪切 / 复制灰显（AC-611）。
      expect(_menuItem(tester, '剪切').enabled, isFalse);
      expect(_menuItem(tester, '复制').enabled, isFalse);
      // 关键项始终可用。
      expect(_menuItem(tester, '添加关联笔记…').enabled, isTrue);
      expect(_menuItem(tester, '插入附件…').enabled, isTrue);

      // 打开菜单本身不改正本、不改选区（BR-107.1 / AC-612）。
      expect(ctrl.text, before);
      expect(ctrl.selection, const TextSelection.collapsed(offset: 2));

      // 点击菜单外部关闭。
      await tester.tapAt(const Offset(4, 4));
      await _settle(tester);
      expect(find.text('添加关联笔记…'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('菜单「添加关联笔记…」：选择器 → 正本写入 [标题](sui://note/<id>)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repo = NoteRepository(db, deviceId: 'm18-menu-noteref');
      final controller = AppController(repository: repo, database: db);
      await controller.bootstrap();
      await controller.createNote();
      final first = controller.selectedNoteId!;
      await controller.saveNote(first,
          title: '甲笔记', content: '正文', tags: const <String>[]);
      await controller.createNote();
      final second = controller.selectedNoteId!;
      await controller.saveNote(second,
          title: '目标笔记', content: '目标正文', tags: const <String>[]);
      controller.selectNote(first);

      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const MaterialApp(home: NoteShell()),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      await _rightClickBody(tester);
      await tester.tap(find.text('添加关联笔记…'));
      await tester.pump();
      await _settle(tester, frames: 10);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('sui-note-picker-query')), findsOneWidget,
          reason: '与工具栏「关联笔记」打开同一选择器（BR-107.2）');
      await tester.tap(find.byKey(ValueKey('sui-note-picker-$second')));
      await tester.pump();
      await _settle(tester);

      expect(_content(tester).text, contains('[目标笔记](sui://note/$second)'),
          reason: '菜单项与工具栏入口同源，正本形态逐字一致（AC-608）');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('菜单「插入附件…」调起同一个文件选择器（批次入口同源）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var picked = 0;
    debugAttachmentPickerOverride = () async {
      picked++;
      return const <PickedAttachment>[];
    };
    addTearDown(() => debugAttachmentPickerOverride = null);
    try {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      await _pumpEditor(tester, db, 'm18-menu-attach', '正文');
      await _rightClickBody(tester);

      await tester.tap(find.text('插入附件…'));
      await tester.pump();
      await _settle(tester);

      expect(picked, 1, reason: '菜单项应转调 _pickAndAttach（同一文件选择器）');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('移动端平台：保持框架默认工具栏，不出现自定义菜单项', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpEditor(tester, db, 'm18-menu-mobile', '正文');
    await _rightClickBody(tester);

    expect(find.text('添加关联笔记…'), findsNothing);
    expect(find.byType(PopupMenuItem<EditorContextAction>), findsNothing,
        reason: '移动端 / Web 沿用框架默认选择菜单（BR-107.4）');
    // 关闭框架工具栏，避免残留 overlay 影响后续用例。
    await tester.tapAt(const Offset(4, 4));
    await _settle(tester);
  });

  testWidgets('预览模式：右键不弹出自定义菜单', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      await _pumpEditor(tester, db, 'm18-menu-preview', '正文');

      await tester.tap(find.text('预览'));
      await _settle(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(MarkdownEditor)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await _settle(tester);

      expect(find.text('添加关联笔记…'), findsNothing,
          reason: '预览态只读，不提供正文右键菜单（AC-607）');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
