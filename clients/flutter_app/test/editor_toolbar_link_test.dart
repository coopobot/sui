/// 工具栏快捷键提示与「插入超链接」弹框（M9 缺陷修复 ②）
/// （editor-formatting.md §14 / BR-23.10 / BR-23.11 / BR-44.12 / AC-177~AC-179）。
///
/// - `ToolbarShortcutTooltip`：工具栏按钮悬浮提示带**键位说明**（`加粗 (Ctrl+B)`），
///   键位取自同一份快捷键映射；无快捷键的按钮保持纯名称（AC-179）。
/// - `LinkDialogBody`：点「链接」（含选区预填 / 网址为空不落笔 / 取消不改动正本 / `Ctrl+K` 同源）（AC-177）。
/// - `LinkInCell`：单元格上下文栏「链接」与「单元格获焦时的正文工具栏链接」都写入该单元格（AC-178）。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（Agents.md §5.2），一律有界 `pump`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/format_table.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

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

  await tester.binding.setSurfaceSize(const Size(1200, 800));
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

Finder _contentField() => find
    .descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    )
    .first;

TextEditingController _contentValue(WidgetTester tester) =>
    tester.widget<TextField>(_contentField()).controller!;

/// 有界推进若干帧，等对话框路由动画走完（替代 `pumpAndSettle()`）。
Future<void> _settleRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// 点击工具栏按钮（先 `ensureVisible`：工具栏是横向滚动行，靠右按钮可能在视口之外）。
Future<void> _tapTooltip(WidgetTester tester, String tooltip) async {
  final finder = find.byTooltip(tooltip);
  expect(finder, findsOneWidget, reason: '工具栏应有 tooltip「$tooltip」');
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// 在「插入超链接」弹框内填写并确认。
Future<void> _fillLinkDialog(
  WidgetTester tester, {
  String? label,
  String? url,
}) async {
  expect(find.text('插入超链接'), findsOneWidget, reason: '应弹出「插入超链接」录入框');
  if (label != null) {
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ).first,
      label,
    );
  }
  if (url != null) {
    await tester.enterText(find.byKey(const ValueKey('sui-link-url')), url);
  }
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('sui-link-confirm')));
  await _settleRoute(tester);
}

Future<void> _pressCtrl(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

void main() {
  group('ToolbarShortcutTooltip（悬浮提示显示快捷键 / BR-23.11 / AC-179）', () {
    testWidgets('有快捷键的按钮 tooltip 为「名称 (键位)」', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-tip1', '正文');

      final tips = tester
          .widgetList<IconButton>(find.byType(IconButton))
          .map((b) => b.tooltip)
          .whereType<String>()
          .toList();

      const expected = <String>[
        '加粗 (Ctrl+B)',
        '勾选框 (Ctrl+Shift+C)',
        '斜体 (Ctrl+I)',
        '删除线 (Ctrl+T)',
        '高亮 (Ctrl+Shift+H)',
        '无序列表 (Ctrl+Shift+W)',
        '有序列表 (Ctrl+Shift+O)',
        '缩进 (Ctrl+M)',
        '反缩进 (Ctrl+Shift+M)',
        '引用 (Ctrl+Shift+Q)',
        '代码块 (Ctrl+Shift+K)',
        '表格 (Ctrl+Shift+T)',
        '链接 (Ctrl+K)',
        '分割线 (Ctrl+Shift+-)',
        '简化格式 (Ctrl+Space)',
        '标题 1 (Ctrl+Alt+1)',
        '标题 2 (Ctrl+Alt+2)',
        '标题 3 (Ctrl+Alt+3)',
        '撤销 (Ctrl+Z)',
        '重做 (Ctrl+Shift+Z)',
      ];
      for (final tip in expected) {
        expect(tips, contains(tip), reason: '缺少带快捷键的提示：$tip');
      }

      // 无快捷键的按钮保持纯名称（不得写出空括号 / 假键位）。
      for (final plain in const ['插入图片', '附件', '导出 Markdown']) {
        expect(tips, contains(plain), reason: '无快捷键按钮应保持纯名称：$plain');
      }
      expect(
        tips.where((t) => t.contains('()') || t.endsWith('(')),
        isEmpty,
        reason: '不得出现空键位',
      );
      await db.close();
    });
  });

  group('LinkDialogBody（正文链接录入弹框 / BR-23.10 / AC-177）', () {
    testWidgets('网址为空时「插入」禁用；填写后回写 [文字](网址)', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-link1', '');
      final ctrl = _contentValue(tester);

      await _tapTooltip(tester, '链接 (Ctrl+K)');
      await _settleRoute(tester);
      expect(find.text('插入超链接'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('sui-link-confirm')))
            .onPressed,
        isNull,
        reason: '网址为空时不得落笔（BR-23.10②）',
      );

      // 显示文字留空 → 以网址充当；未写协议自动补 https://
      await _fillLinkDialog(tester, url: 'example.com/doc');
      expect(ctrl.text, '[https://example.com/doc](https://example.com/doc)');
      expect(ctrl.selection.extentOffset, ctrl.text.length,
          reason: '光标应落在链接之后');
      await db.close();
    });

    testWidgets('有选区：以选中文字预填「显示文字」并整段替换', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-link2', '点这里看文档');
      final ctrl = _contentValue(tester);

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = const TextSelection(baseOffset: 1, extentOffset: 3);
      await tester.pump();

      await _tapTooltip(tester, '链接 (Ctrl+K)');
      await _settleRoute(tester);
      final labelField = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first;
      expect(tester.widget<TextField>(labelField).controller!.text, '这里',
          reason: '应以选中文字预填显示文字');

      await _fillLinkDialog(tester, url: 'e.com');
      expect(ctrl.text, '点[这里](https://e.com)看文档');
      await db.close();
    });

    testWidgets('取消不改动正本', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-link3', '正文');
      final ctrl = _contentValue(tester);

      await _tapTooltip(tester, '链接 (Ctrl+K)');
      await _settleRoute(tester);
      await tester.tap(find.text('取消'));
      await _settleRoute(tester);

      expect(ctrl.text, '正文');
      await db.close();
    });

    testWidgets('`Ctrl+K` 与工具栏「链接」同源：同样弹出录入框', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-link4', '');
      final ctrl = _contentValue(tester);

      await tester.tap(_contentField());
      await tester.pump();
      await _pressCtrl(tester, LogicalKeyboardKey.keyK);
      await _settleRoute(tester);
      await _fillLinkDialog(tester, label: '随手记', url: 'https://e.com');
      expect(ctrl.text, '[随手记](https://e.com)');
      await db.close();
    });

    testWidgets('`Ctrl+Shift+T` 打开「插入表格」面板', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-link5', '');

      await tester.tap(_contentField());
      await tester.pump();
      await _pressCtrl(tester, LogicalKeyboardKey.keyT, shift: true);
      await _settleRoute(tester);
      expect(find.text('插入表格'), findsOneWidget);
      await db.close();
    });
  });

  group('LinkInCell（单元格内插入链接 / BR-44.12 / AC-178）', () {
    const table = '| A | B |\n| --- | --- |\n| 甲 | 乙 |';

    testWidgets('单元格上下文栏「链接」→ 以 `<br>` 追加，其余单元格逐字不动', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-celllink1', table);
      final ctrl = _contentValue(tester);

      final cell = find.byKey(const ValueKey<String>('sui-table-0-0'));
      expect(cell, findsOneWidget);
      await tester.tap(cell);
      await tester.pump();

      await _tapTooltip(tester, '在单元格内插入链接');
      await _settleRoute(tester);
      await _fillLinkDialog(tester, label: '示例', url: 'https://e.com');

      expect(
        ctrl.text.split('\n')[2],
        '| 甲<br>[示例](https://e.com) | 乙 |',
      );
      expect(ctrl.text.split('\n')[0], '| A | B |', reason: '表头逐字不动');
      expect(find.byType(FormatTableView), findsOneWidget,
          reason: '表格仍良构、仍以表格呈现');
      await db.close();
    });

    testWidgets('空单元格直接写入链接', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(
        tester,
        db,
        'wysiwyg-celllink2',
        '| A | B |\n| --- | --- |\n|  | 乙 |',
      );
      final ctrl = _contentValue(tester);

      await tester.tap(find.byKey(const ValueKey<String>('sui-table-0-0')));
      await tester.pump();
      await _tapTooltip(tester, '在单元格内插入链接');
      await _settleRoute(tester);
      await _fillLinkDialog(tester, url: 'e.com');

      expect(ctrl.text.split('\n')[2], '| [https://e.com](https://e.com) | 乙 |');
      await db.close();
    });

    testWidgets('单元格获焦时正文工具栏「链接」写入该单元格（不落到表格外）', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-celllink3', table);
      final ctrl = _contentValue(tester);
      final before = ctrl.text;

      await tester.tap(find.byKey(const ValueKey<String>('sui-table-0-1')));
      await tester.pump();
      await _tapTooltip(tester, '链接 (Ctrl+K)');
      await _settleRoute(tester);
      await _fillLinkDialog(tester, label: 'B', url: 'https://e.com');

      expect(
        ctrl.text.split('\n')[2],
        '| 甲 | 乙<br>[B](https://e.com) |',
        reason: '应写入活动单元格（第 2 列）',
      );
      expect(ctrl.text.startsWith(before.split('\n').take(2).join('\n')), isTrue,
          reason: '表头与分隔行不动');
      await db.close();
    });
  });
}
