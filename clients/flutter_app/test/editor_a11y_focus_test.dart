/// BUG 回归：**辅助功能焦点丢失不得让正文失焦**。
///
/// 真实链路（Windows，v0.17.2）：格式模式按 `Ctrl+Shift+C` 后正文变化 → 语义树
/// 重建 → 平台派发 `SemanticsAction.didLoseAccessibilityFocus` → Flutter 的
/// `TextField`（桌面分支）把它接到 `focusNode.unfocus()` → 光标消失、按键全部丢弃。
///
/// 修法是**否决**：正文焦点节点在 `didLoseAccessibilityFocus` 派发期间忽略这次
/// `unfocus()`（见 `EditorFocusNode` / `A11yFocusGate`）。本用例：
///  ① 经真实入口（`PlatformDispatcher.onSemanticsActionEvent`）派发该动作，断言
///     焦点未失、且紧接着能连续键入；
///  ② 反向断言：非辅助功能派发期间的普通 `unfocus()` 照常生效（否决没有误伤）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

AppController _controller(AppDatabase db) => AppController(
      repository: NoteRepository(db, deviceId: 'a11y-focus'),
      database: db,
    );

Future<AppController> _pumpShell(
  WidgetTester tester,
  AppDatabase db, {
  String content = '',
  String title = '标题',
}) async {
  final controller = _controller(db);
  await controller.bootstrap();
  await controller.createNote();
  await controller.saveNote(
    controller.selectedNoteId!,
    title: title,
    content: content,
    tags: const <String>[],
  );
  await tester.binding.setSurfaceSize(const Size(1400, 900));
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _bodyField() => find
    .descendant(of: find.byType(MarkdownEditor), matching: find.byType(TextField))
    .last;

Future<void> _pressCtrlShiftC(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _settle(tester);
}

void main() {
  testWidgets('勾选框快捷键后，辅助功能焦点丢失不得取消正文聚焦', (tester) async {
    // 只在桌面分支挂 onDidLoseAccessibilityFocus（material/text_field.dart），
    // 故本用例必须把平台钉到 Windows；用例结束前复位（框架不变量检查在 addTearDown 之前）。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final semanticsHandle = tester.ensureSemantics();
    final db = AppDatabase.memory();
    try {
      await _pumpShell(tester, db, content: '');

      final body = _bodyField();
      await tester.tap(body);
      await tester.pump();
      final field = tester.widget<TextField>(body);
      final node = field.focusNode!;
      final ctrl = field.controller!;

      await _pressCtrlShiftC(tester);
      expect(ctrl.text, '- [ ] ', reason: '快捷键应写入勾选框前缀');
      expect(node.hasFocus, isTrue, reason: '写回本身不应让正文失焦');

      // 经真实入口派发「辅助功能焦点丢失」（引擎就是这么进来的）。
      final semanticsNode = tester.getSemantics(find.byType(TextField).last);
      expect(
        semanticsNode
            .getSemanticsData()
            .hasAction(SemanticsAction.didLoseAccessibilityFocus),
        isTrue,
        reason: '桌面分支必须给正文挂上辅助功能焦点丢失回调（否则用例失去意义）',
      );
      final dispatcher = tester.binding.platformDispatcher;
      dispatcher.onSemanticsActionEvent!(
        SemanticsActionEvent(
          type: SemanticsAction.didLoseAccessibilityFocus,
          viewId: tester.view.viewId,
          nodeId: semanticsNode.id,
        ),
      );
      await tester.pump();
      await _settle(tester);
      expect(
        node.hasFocus,
        isTrue,
        reason: '辅助功能焦点丢失不得取消正文聚焦（否则光标消失、按键全部丢弃）',
      );

      // 仍能连续键入（输入连接未被断开）。
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: '${ctrl.text}甲',
        selection: TextSelection.collapsed(offset: ctrl.text.length + 1),
      ));
      await _settle(tester);
      expect(ctrl.text, '- [ ] 甲', reason: '否决后必须能连续输入');

      // 反向：非辅助功能派发期间的普通 unfocus 照常生效（否决没有误伤）。
      node.unfocus();
      await tester.pump();
      expect(node.hasFocus, isFalse, reason: '普通取消聚焦不得被否决');
    } finally {
      semanticsHandle.dispose();
      debugDefaultTargetPlatformOverride = null;
      await db.close();
    }
  });
}
