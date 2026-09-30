/// M5-T11 编辑器增强 widget 测试（editor-formatting.md §8 / §9 / §10 / §11）。
///
/// - `ShortcutScopeGuard`：快捷键仅在「格式模式 + 正文聚焦」时生效，且不抢占系统 /
///   输入法级按键（AC-88 / BR-30.2 / BR-30.5）。
/// - `FocusMarkerHideFidelity`：聚焦态标记隐藏 / 展开只改显示，正本逐字节不变
///   （AC-91 / §11.1 / §11.3）。
/// - `BlockUnitBehavior`：块级呈现单元的空块交互（空列表项回车退出、任务项回车续行、
///   空引用行回车退出），且产出与源码 / 预览两态一致（AC-92 / §11.2）。
/// - `PreviewHighlightRender`：预览模式同样把 `==高亮==` 渲染为高亮（BR-31.5）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// 取整棵 span 树中覆盖 [target] 偏移处的叶子样式（纯文本 span 场景）。
TextStyle _styleAt(TextSpan root, int target) {
  var remaining = target;
  TextStyle? result;
  void visit(InlineSpan span) {
    if (result != null || span is! TextSpan) return;
    final t = span.text;
    if (t != null) {
      if (remaining < t.length) {
        result = span.style;
        return;
      }
      remaining -= t.length;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child);
      if (result != null) return;
    }
  }

  visit(root);
  return result!;
}

/// 在悬挂于 MaterialApp 的 Builder 内构建富样式 span（脱离 UI 的纯呈现测试）。
Future<TextSpan> _buildSpan(
  WidgetTester tester,
  MarkdownEditingController controller,
) async {
  late TextSpan span;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(builder: (context) {
        span = controller.buildTextSpan(
          context: context,
          style: const TextStyle(),
          withComposing: false,
        );
        return const SizedBox.shrink();
      }),
    ),
  );
  return span;
}

/// 模拟 Ctrl(+[shift]) 组合键（按下 → 抬起）。
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
  group('FocusMarkerHideFidelity（聚焦态标记隐藏只改显示，AC-91 / §11.1）', () {
    testWidgets('聚焦 / 失焦两态下正本逐字节不变，仅标记可见度不同', (tester) async {
      const source = '**粗体**\n\n尾';
      final controller = MarkdownEditingController(text: source);
      controller.styled = true;

      // 失焦态：光标落在末行，第 1 行的 `**` 标记高度淡化（§11.1）。
      controller.selection = const TextSelection.collapsed(offset: 8);
      final unfocusedSpan = await _buildSpan(tester, controller);
      final unfocusedMarker = _styleAt(unfocusedSpan, 0).color!;

      // 聚焦态：光标进入第 1 行，标记完整展开（BR-32.2）。
      controller.selection = const TextSelection.collapsed(offset: 1);
      final focusedSpan = await _buildSpan(tester, controller);
      final focusedMarker = _styleAt(focusedSpan, 0).color!;

      // 显示差异：聚焦态标记不透明度更高。
      expect(
        unfocusedMarker,
        isNot(equals(focusedMarker)),
        reason: '聚焦 / 失焦两态标记可见度必须有别',
      );
      expect(
        unfocusedMarker.a,
        lessThan(focusedMarker.a),
        reason: '失焦态标记应比聚焦态更淡（§11.1）',
      );

      // 保真：呈现（含隐藏 / 展开）不得改动正本，且 span 树与正本等长。
      expect(controller.text, source, reason: '聚焦态标记隐藏不得改动正本');
      expect(
        focusedSpan.toPlainText().length,
        controller.text.length,
        reason: 'span 树纯文本必须与正本等长，否则光标定位会错位',
      );
    });
  });

  group('ShortcutScopeGuard（快捷键作用域守卫，AC-88 / BR-30.2 / BR-30.5）', () {
    late AppDatabase db;
    late AppController controller;

    Future<void> pumpEditor(WidgetTester tester, String content) async {
      db = AppDatabase.memory();
      controller = AppController(
        repository: NoteRepository(db, deviceId: 'm5t11-test'),
        database: db,
      );
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
    }

    Finder contentField() => find
        .descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(TextField),
        )
        .last;

    TextEditingController contentController(WidgetTester tester) =>
        tester.widget<TextField>(contentField()).controller!;

    /// 找到承载格式快捷键（含 Ctrl+B）的 Shortcuts 层。
    Shortcuts formatShortcuts(WidgetTester tester) =>
        tester.widgetList<Shortcuts>(find.byType(Shortcuts)).firstWhere(
              (s) => s.shortcuts.containsKey(
                const SingleActivator(LogicalKeyboardKey.keyB, control: true),
              ),
            );

    testWidgets('格式模式下正文聚焦时 Ctrl+B 加粗生效，且不抢占系统级按键',
        (tester) async {
      await pumpEditor(tester, '重点');

      // 结构断言：格式模式挂载了格式快捷键层（BR-30.5）。
      final shortcuts = formatShortcuts(tester);
      expect(
        shortcuts.shortcuts.containsKey(
          const SingleActivator(LogicalKeyboardKey.keyA, control: true),
        ),
        isFalse,
        reason: '不得抢占系统级按键（Ctrl+A 全选，BR-30.2）',
      );
      expect(
        shortcuts.shortcuts.containsKey(
          const SingleActivator(LogicalKeyboardKey.keyV, control: true),
        ),
        isFalse,
        reason: '不得抢占剪贴板级按键（Ctrl+V，BR-30.2）',
      );

      // 功能断言：聚焦正文 → 选中 → Ctrl+B 加粗（与工具栏同源，BR-30.4）。
      await tester.tap(contentField());
      await tester.pump();
      final ctrl = contentController(tester);
      ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyB);
      await tester.pump();

      expect(ctrl.text, '**重点**');

      await db.close();
    });

    testWidgets('源码模式下不挂载格式快捷键，Ctrl+B 不改动正本', (tester) async {
      await pumpEditor(tester, '重点');

      // 切到源码模式（正本不变，仅「怎么画」不同）。
      await tester.tap(find.text('源码'));
      await tester.pump();

      expect(
        tester.widgetList<Shortcuts>(find.byType(Shortcuts)).any(
              (s) => s.shortcuts.containsKey(
                const SingleActivator(LogicalKeyboardKey.keyB, control: true),
              ),
            ),
        isFalse,
        reason: '非格式模式不得挂载格式快捷键（BR-30.5）',
      );

      await tester.tap(contentField());
      await tester.pump();
      final ctrl = contentController(tester);
      ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyB);
      await tester.pump();

      expect(ctrl.text, '重点', reason: '源码模式 Ctrl+B 不应改动正本');

      await db.close();
    });
  });

  group('BlockUnitBehavior（块级呈现单元空块交互，AC-92 / §11.2）', () {
    late AppDatabase db;
    late AppController controller;

    Future<void> pumpEditor(WidgetTester tester, String content) async {
      db = AppDatabase.memory();
      controller = AppController(
        repository: NoteRepository(db, deviceId: 'm5t11-block'),
        database: db,
      );
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
    }

    Finder contentField() => find
        .descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(TextField),
        )
        .last;

    /// 聚焦正文并把光标放到 [offset]，随后按下回车。
    Future<TextEditingController> enterAt(
      WidgetTester tester,
      int offset,
    ) async {
      await tester.tap(contentField());
      await tester.pump();
      final ctrl =
          tester.widget<TextField>(contentField()).controller!;
      ctrl.selection = TextSelection.collapsed(offset: offset);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      return ctrl;
    }

    testWidgets('空列表项回车退出列表（移除标记，留在空行）', (tester) async {
      await pumpEditor(tester, '- ');
      final ctrl = await enterAt(tester, 2);
      expect(ctrl.text, '', reason: '空列表项回车应移除标记、退出列表（BR-32.4）');
      expect(ctrl.selection.baseOffset, 0);
      await db.close();
    });

    testWidgets('任务项回车续行（新建未勾选任务）', (tester) async {
      await pumpEditor(tester, '- [ ] 买牛奶');
      final ctrl = await enterAt(tester, 9);
      expect(ctrl.text, '- [ ] 买牛奶\n- [ ] ', reason: '任务项回车应续行新建未勾选任务');
      await db.close();
    });

    testWidgets('空引用行回车退出引用（移除标记）', (tester) async {
      await pumpEditor(tester, '> ');
      final ctrl = await enterAt(tester, 2);
      expect(ctrl.text, '', reason: '空引用行回车应移除标记、退出引用');
      await db.close();
    });

    testWidgets('非空列表项行中回车交由默认行为（不误退出列表）', (tester) async {
      await pumpEditor(tester, '- 有内容');
      final ctrl = await enterAt(tester, 2);
      expect(
        ctrl.text.startsWith('- '),
        isTrue,
        reason: '行中回车不得触发空块交互，列表标记须保留（BR-32.4）',
      );
      await db.close();
    });
  });

  group('PreviewHighlightRender（预览态高亮渲染，BR-31.5 / AC-90）', () {
    late AppDatabase db;
    late AppController controller;

    Future<void> pumpEditor(WidgetTester tester, String content) async {
      db = AppDatabase.memory();
      controller = AppController(
        repository: NoteRepository(db, deviceId: 'm5t11-preview'),
        database: db,
      );
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
    }

    /// span（含子 span）中是否含指定底色。
    bool spanHasBackground(InlineSpan span, Color want) {
      if (span is! TextSpan) return false;
      if (span.style?.backgroundColor == want) return true;
      return (span.children ?? const <InlineSpan>[])
          .any((c) => spanHasBackground(c, want));
    }

    testWidgets('预览态将 ==高亮== 渲染为高亮底色', (tester) async {
      await pumpEditor(tester, '==重点内容== 普通');

      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();

      expect(find.byType(Markdown), findsOneWidget);
      final want = Theme.of(tester.element(find.byType(Markdown)))
          .colorScheme
          .tertiaryContainer;
      // 预览态默认 `selectable: true`，flutter_markdown 用 SelectableText 而非
      // RichText 承载行内 span，两处都要取。
      final spans = <InlineSpan>[
        ...tester.widgetList<RichText>(find.byType(RichText)).map((rt) => rt.text),
        ...tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((st) => st.textSpan ?? const TextSpan()),
      ];
      final rendered = spans.any((s) => spanHasBackground(s, want));

      expect(rendered, isTrue, reason: '预览态 `==高亮==` 应渲染为高亮（BR-31.5）');
      expect(find.textContaining('重点内容'), findsWidgets);

      await db.close();
    });
  });
}
