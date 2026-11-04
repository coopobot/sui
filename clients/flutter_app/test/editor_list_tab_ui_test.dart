/// M18 / FR-108：列表 `Tab` / `Shift+Tab` 缩进与 `-` + `Tab` 自动成列表（真实 `TextField`）。
///
/// 语义真源在 `note_core` 的 `EditorFormat.tabListIndent`（见 `editor_list_tab_test.dart`）；
/// 本组验证**接线**：格式模式按键被消费并改写正本、光标随行平移；非列表行与源码模式
/// 原样放行（`Tab` 仍只移动焦点，正本逐字不变）。
///
/// 纪律：**禁用** `pumpAndSettle()`（Agents.md §5.2）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
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

Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

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
  await _settle(tester);
  return controller;
}

/// 聚焦正文并把折叠光标放到 [offset]。
Future<void> _focusBody(WidgetTester tester, int offset) async {
  await tester.tap(_contentField());
  await tester.pump();
  _content(tester).selection = TextSelection.collapsed(offset: offset);
  await tester.pump();
}

Future<void> _pressTab(WidgetTester tester, {bool shift = false}) async {
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
}

Future<void> _switchMode(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await _settle(tester);
}

void main() {
  testWidgets('格式模式：列表行 Tab 右缩进、Shift+Tab 左反缩进', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpEditor(tester, db, 'm18-tab-bullet', '- 项');
    await _focusBody(tester, 3);

    await _pressTab(tester);
    expect(_content(tester).text, '  - 项', reason: 'Tab 向右缩进 2 空格（AC-616）');
    expect(_content(tester).selection, const TextSelection.collapsed(offset: 5),
        reason: '光标随行平移，不跳文末（AC-620）');

    await _pressTab(tester, shift: true);
    expect(_content(tester).text, '- 项', reason: 'Shift+Tab 向左反缩进');
    expect(_content(tester).selection, const TextSelection.collapsed(offset: 3));
  });

  testWidgets('格式模式：`-` + Tab 自动变成无序列表', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpEditor(tester, db, 'm18-tab-autolist', '');
    await tester.tap(_contentField());
    await tester.pump();
    // 模拟「键入 `-`」后的正本状态（格式模式的转义格式化器不在本用例路径上）。
    _content(tester).value = const TextEditingValue(
      text: '-',
      selection: TextSelection.collapsed(offset: 1),
    );
    await tester.pump();

    await _pressTab(tester);
    expect(_content(tester).text, '- ', reason: '`-` + Tab 就地变成无序列表项（AC-621）');
    expect(_content(tester).selection, const TextSelection.collapsed(offset: 2),
        reason: '光标落在标记之后，可直接输入内容');
  });

  testWidgets('格式模式：多行选区整体缩进，行内容逐字不动', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpEditor(tester, db, 'm18-tab-multiline', '- 甲\n- 乙');
    await tester.tap(_contentField());
    await tester.pump();
    _content(tester).selection = const TextSelection(baseOffset: 0, extentOffset: 7);
    await tester.pump();

    await _pressTab(tester);
    expect(_content(tester).text, '  - 甲\n  - 乙', reason: '多行选区整体缩进（AC-619）');
  });

  testWidgets('非列表行 Tab 不改正本（交还默认焦点移动）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpEditor(tester, db, 'm18-tab-paragraph', '段落文字');
    await _focusBody(tester, 4);

    await _pressTab(tester);
    expect(_content(tester).text, '段落文字',
        reason: '普通段落不得插入缩进（会变成缩进代码块，BR-108.2）');
  });

  testWidgets('源码模式：Tab 不拦截、不自动成列表', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpEditor(tester, db, 'm18-tab-source', '- 项');
    await _switchMode(tester, '源码');
    await _focusBody(tester, 3);

    await _pressTab(tester);
    expect(_content(tester).text, '- 项', reason: '源码模式所见即正本，Tab 不改正本（AC-623）');
  });
}
