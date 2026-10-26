/// M5-T11 编辑器增强 widget 测试（editor-formatting.md §8 / §9 / §10 / §11）。
///
/// - `ShortcutScopeGuard`：快捷键仅在「格式模式 + 正文聚焦」时生效，且不抢占系统 /
///   输入法级按键（AC-88 / BR-30.2 / BR-30.5）。
/// - `MarkerAlwaysHidden`：记号在格式模式下**任何时刻都不可见**（不再有「聚焦展开 / 失焦淡化」），
///   只改显示、正本逐字节不变（AC-91 / AC-172 / §11.1 / §13.2）。
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
import 'package:flutter/rendering.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/appearance/app_palette.dart';
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

/// 取 span 树的**可见文本**：跳过零宽透明片段（`fontSize: 0` / 透明色），
/// 呈现单元取其语义占位文本（`Text` 子项）。
String _visibleTextOf(InlineSpan span) {
  final buf = StringBuffer();
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      final style = s.style;
      final invisible = style != null &&
          (style.fontSize == 0 || style.color == Colors.transparent);
      if (!invisible && s.text != null) buf.write(s.text);
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    } else if (s is WidgetSpan) {
      final child = s.child;
      if (child is Text && child.data != null) buf.write(child.data);
    }
  }

  walk(span);
  return buf.toString();
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
  group('MarkerAlwaysHidden（记号任何时刻都不可见，AC-172 / §13.2）', () {
    testWidgets('聚焦 / 失焦两态下正本逐字节不变，记号一律零宽透明', (tester) async {
      const source = '**粗体**\n\n尾';
      final controller = MarkdownEditingController(text: source);
      controller.styled = true;

      // 失焦态：光标落在末行。
      controller.selection = const TextSelection.collapsed(offset: 8);
      final unfocusedSpan = await _buildSpan(tester, controller);

      // 聚焦态：光标进入第 1 行（内容侧——记号为**不可落点**，落在内部会被吸附到外侧边界）。
      controller.selection = const TextSelection.collapsed(offset: 2);
      final focusedSpan = await _buildSpan(tester, controller);

      // 两态都**看不到**记号：可见文本均等于「粗体\n\n尾」。
      expect(_visibleTextOf(unfocusedSpan), '粗体\n\n尾');
      expect(_visibleTextOf(focusedSpan), '粗体\n\n尾');

      // 记号的呈现：零宽（`fontSize: 0`）+ 透明色。
      expect(_styleAt(unfocusedSpan, 0).fontSize, 0, reason: '记号零宽不可见');
      expect(_styleAt(focusedSpan, 0).fontSize, 0, reason: '聚焦态同样零宽');
      expect(_styleAt(focusedSpan, 0).color, Colors.transparent);

      // 保真：呈现（记号隐藏）不得改动正本，且 span 树与正本等长。
      expect(controller.text, source, reason: '记号隐藏不得改动正本');
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
      // M14（FR-68 / AC-308）：高亮底色改**黄色系**（不再取 `tertiaryContainer` 浅青）。
      final want =
          SuiAppearance.of(tester.element(find.byType(Markdown))).palette.highlight;
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

  group('DividerFormatRender（分割线两态渲染与几何，BR-72.1~72.7 / BR-23.7）', () {
    // 口径来源：technology/design/low-level-design/editor-formatting.md §15（v0.14.3 补正）、
    // product/requirements.md §25（FR-72 / BR-72.1~BR-72.7）、
    // product/acceptance-criteria.md §26.1 / §26.9。逐条判据：
    //   ① 呈现单元：`---` → `FormatRuleLine`（1px `outlineVariant` 细线），记号零宽透明，
    //      span 树与正本**等长**（偏移契约 BR-27.1），正本不被渲染改动（BR-23.1）；
    //   ② 几何：两种正本形态（紧贴形 / 标准形）在**呈现层**都只占 **3 个视觉行**，不得露出多余行；
    //      **间距**按**实测真值**断言——真机格式态「段落1 → 段落2」顶距 **54.75px**、预览态 **37.02px**
    //      （**目前不一致、差 17.73px，登记为待决项**；该行行盒由正文 strut 的 24px 下限决定，
    //      压小呈现单元无效；曾试「显式换行」在真机更差，**已撤回**）（BR-72.2 / BR-72.5 / AC-321）；
    //   ③ 上一行字号保持正文；`---` 紧贴上一行时仍按 setext 二级标题呈现（BR-72.1 / BR-72.7）；
    //   ④ 线色 / 线宽与预览 `<hr>` **同源**、无外边距（BR-23.7 / AC-321）；
    //   ⑤ 编辑器路径：插入后光标落在分割线**下方那一行的行首**、可直接续写；再触发
    //      = **连行移除**（BR-72.3 / BR-72.4 幂等切换；吸附落点补偿）。
    const bodyBase = TextStyle(fontSize: 15, height: 1.6);

    late AppDatabase db;
    late AppController controller;

    Future<void> pumpEditor(WidgetTester tester, String content) async {
      db = AppDatabase.memory();
      controller = AppController(
        repository: NoteRepository(db, deviceId: 'divider-render'),
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

    /// 聚焦正文并把折叠光标放到 [offset]。
    Future<void> placeCaret(WidgetTester tester, int offset) async {
      await tester.tap(contentField());
      await tester.pump();
      contentController(tester).selection =
          TextSelection.collapsed(offset: offset);
      await tester.pump();
    }

    /// 有界推进假时钟（不用 `pumpAndSettle`：兜底同步的周期定时器会让其永不返回）。
    Future<void> settle(
      WidgetTester tester, {
      Duration step = const Duration(milliseconds: 16),
      int frames = 30,
    }) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(step);
      }
    }

    testWidgets('呈现单元：一个 FormatRuleLine、记号零宽透明、span 与正本等长（①）',
        (tester) async {
      const src = '段落1\n\n---\n段落2';
      final ctrl = MarkdownEditingController(text: src)..styled = true;
      final span = await _pumpStyledSpan(tester, ctrl, bodyBase);

      expect(_widgetSpanCount<FormatRuleLine>(span), 1,
          reason: '`---` 须替换为水平线呈现单元 FormatRuleLine');
      expect(_visibleTextOf(span), '段落1\n段落2',
          reason: '`---` 与它的断行都零宽透明：视觉上只剩「段落 / 分割线 / 段落」');
      expect(span.toPlainText().length, src.length,
          reason: '折叠呈现后 span 树仍须与正本等长，否则光标定位错位（BR-27.1）');
      expect(ctrl.text, src, reason: '渲染不得改动正本（BR-23.1）');
    });

    testWidgets('几何（隔离呈现层）：两种正本形态都是 3 个视觉行，规则行按正文行高计高（②）',
        (tester) async {
      for (final src in const ['段落1\n\n---\n段落2', '段落1\n\n---\n\n段落2']) {
        final ctrl = MarkdownEditingController(text: src)..styled = true;
        await _pumpStyledSpan(tester, ctrl, bodyBase);

        expect(_visualLineCount(tester), 3,
            reason: '`$src`：段落1 / 分割线 / 段落2 = 3 个视觉行，不得露出多余行（BR-72.2）');
        expect(tester.getSize(find.byType(FormatRuleLine)).height,
            FormatRuleLine.lineBoxHeight,
            reason: '呈现单元自身高度（注意：它**不**决定该行的行盒高度，见下一条）');
        // 说明：本用例**只**断言呈现层的结构性事实（3 个视觉行 + 呈现单元高度 + 偏移契约）。
        // **间距**不做断言——隔离层（裸 `RichText`，无 strut）的行盒会随「终止该行的是零宽换行
        // 还是正本真换行」在 20 / 24 之间摆动，而**真机由正文 strut 的 24px 下限决定**（≈33）。
        // 有意义的间距口径见下一条用例（真机 54.75 vs 预览 37.02，§15.5 实测表）。
      }
    });

    testWidgets('两态间距实测：真实编辑器 54.75px vs 预览 37.02px（② / AC-321 待决项）',
        (tester) async {
      // —— 格式态：**真实编辑器**（正文 `TextField` 带 `StrutStyle(forceStrutHeight: false)`）——
      // 该行行盒由 strut 的 24px 下限与占位对齐共同决定（≈33px），**与呈现单元高度无关**
      // （A/B 实测：呈现单元 17 / 20、对齐 middle / top，段落顶距分别只有 54.75 / 78.75 两档）。
      await pumpEditor(tester, '段落1\n\n---\n段落2');
      final editables = tester.allRenderObjects.whereType<RenderEditable>();
      final re = editables.firstWhere((r) => r.size.height > 40,
          orElse: () => editables.last);
      final f1 = re
          .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 3))
          .first;
      final f2 = re
          .getBoxesForSelection(const TextSelection(baseOffset: 9, extentOffset: 12))
          .first;
      final formatGap = f2.top - f1.top;
      expect(formatGap, closeTo(54.75, 0.5),
          reason: '真机格式态「段落1 → 段落2」顶距（§15.5 实测表；若此值变化请同步文档）');

      // —— 预览态：直接读**真实 app 样式表**（`_previewStyleSheet`）推算 ——
      // 预览 `<hr>` 是块级元素：块间距 8 + `<hr>` 1px + 块间距 8；正文行盒 = p 的行高。
      await tester.tap(find.text('预览'));
      await settle(tester);
      final ss = tester.widget<Markdown>(find.byType(Markdown)).styleSheet!;
      final pStyle = ss.p!;
      final previewGap = (pStyle.fontSize ?? 14) * (pStyle.height ?? 1.0) +
          ss.blockSpacing! * 2 +
          1;
      expect(previewGap, closeTo(37.02, 0.5),
          reason: '预览态「段落1 → 段落2」顶距 = 行高 14 × 1.43 + 块间距 8 + `<hr>` 1px + 8');

      // 两态**目前不一致**（差 ~17.7px）：登记为**待决项**（不是回归）——规则行行盒被正文 strut 的
      // 24px 下限钉住，压小呈现单元无效；要两态一致须改正文 strut（代价：空行行高随之变小）或改
      // 预览间距（与「紧贴」诉求相反）。决策与代价见 editor-formatting.md §15.5。
      expect(formatGap - previewGap, closeTo(17.73, 1.0),
          reason: '两态间距差（已知待决项）：格式 54.75 − 预览 37.02');

      await db.close();
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('两态同源：线色 = `outlineVariant`、1px、无外边距、按段宽铺满（④）',
        (tester) async {
      const src = '段落1\n\n---\n段落2';
      final ctrl = MarkdownEditingController(text: src)..styled = true;
      await _pumpStyledSpan(tester, ctrl, bodyBase, width: 580);

      final line = find.byType(FormatRuleLine);
      expect(line, findsOneWidget, reason: '格式模式须渲染水平线呈现单元');
      final containers =
          find.descendant(of: line, matching: find.byType(Container));
      final outer = tester.widget<Container>(containers.first);
      final inner = tester.widget<Container>(containers.last);
      final scheme = Theme.of(tester.element(line)).colorScheme;

      expect(outer.margin ?? EdgeInsets.zero, EdgeInsets.zero,
          reason: '呈现单元不得带外边距（外边距就是「多余行」的另一种形态）');
      expect(inner.color, scheme.outlineVariant,
          reason: '线色与预览 `horizontalRuleDecoration` 同源（BR-23.7）');
      expect(tester.getSize(containers.last).height, 1, reason: '1px 细线');
      expect(tester.getSize(line).width, 580, reason: '按可用段落宽铺满');
    });

    testWidgets('上一行字号保持正文；紧贴上一行的 `---` 仍是 setext 二级标题（③）',
        (tester) async {
      final rule = MarkdownEditingController(text: '段落1\n\n---\n段落2')
        ..styled = true;
      final ruleSpan = await _pumpStyledSpan(tester, rule, bodyBase);
      expect(_styleAt(ruleSpan, 0).fontSize, 15,
          reason: '空白分隔的 `---` 是分割线，上一行必须保持正文字号（字号变大即回归）');
      expect(
        EditorFormat.syntaxMarkers(rule.text)
            .any((m) => m.kind == SyntaxMarkerKind.setext),
        isFalse,
        reason: '上方有空行 → `---` 不是 setext 下划线',
      );

      // 对照：紧贴上一行的 `---` 仍是 setext 二级标题（标准语义，两态一致）。
      final setext = MarkdownEditingController(text: '标题\n---\n正文')
        ..styled = true;
      final setextSpan = await _pumpStyledSpan(tester, setext, bodyBase);
      expect(_styleAt(setextSpan, 0).fontSize, 15 * 1.5,
          reason: '对照判据：紧贴上一行的 `---` 按标准解析为 h2（上一条不是空转）');
    });

    testWidgets('编辑器路径：插入后光标落下方行首，再触发 = 连行移除（⑤）',
        (tester) async {
      await pumpEditor(tester, '段落1\n段落2');
      await placeCaret(tester, 1);

      await _pressCtrl(tester, LogicalKeyboardKey.minus, shift: true);
      await settle(tester);

      final ctrl = contentController(tester);
      expect(ctrl.text, '段落1\n\n---\n段落2',
          reason: '正本：上方空行、下方紧接正文（BR-72.1）');
      expect(ctrl.selection.extentOffset, ctrl.text.indexOf('段落2'),
          reason: '光标落在分割线下方那一行的行首，可直接续写（BR-72.3）');
      expect(ctrl.text.contains('\n\n\n'), isFalse, reason: '不留多余空行（BR-72.2）');

      await _pressCtrl(tester, LogicalKeyboardKey.minus, shift: true);
      await settle(tester);

      expect(ctrl.text, '段落1\n\n段落2',
          reason: '再触发 = 移除该行（BR-72.4 幂等切换；规则行无可停光标位 → 吸附落点补偿）');
      expect(ctrl.text.contains('---'), isFalse);

      await db.close();
    }, timeout: const Timeout(Duration(minutes: 3)));

    testWidgets('光标被吸附出被折叠的 `---` 区间，且落点可正常编辑（BR-23.8① / BR-72.5）',
        (tester) async {
      await pumpEditor(tester, '段落1\n\n---\n段落2');
      final ctrl = contentController(tester);
      final text = ctrl.text;
      final rule = EditorFormat.syntaxMarkers(text)
          .firstWhere((m) => m.kind == SyntaxMarkerKind.rule);

      // 先把光标放到分割线**上方**，使下一次赋值属于「右 / 下」方向（吸附规则的判向依据）。
      ctrl.value = ctrl.value.copyWith(
        selection: const TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      );
      await settle(tester);

      // 再把光标推进记号区间内部（等价于方向键 / 点按命中被折叠隐藏的 `---` 行）。
      ctrl.value = ctrl.value.copyWith(
        selection: TextSelection.collapsed(offset: rule.start + 1),
        composing: TextRange.empty,
      );
      await settle(tester);

      final caret = contentController(tester).selection.extentOffset;
      expect(caret > rule.start && caret < rule.end, isFalse,
          reason: '记号内部不可落点：吸附必须把光标送出区间 '
              '[${rule.start}, ${rule.end})（BR-23.8①）');
      expect(text.replaceRange(caret, caret, 'X'), isNot(contains('---X')),
          reason: '吸附落点必须可正常编辑：在该位输入字符不得把 `---` 写坏'
              '（记号当场消散 = 分割线消失 / 上一行变标题，BR-72.5）');

      await db.close();
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

/// 以指定正文基准样式把格式模式 span 树**真正渲染**出来并返回该 span 树。
///
/// 需要量几何（视觉行数 / 行盒 / 呈现单元尺寸）时必须用本函数：`buildTextSpan` 只产出 span，
/// 不布局就量不到任何行盒（这也是 [_buildSpan] 不能用于几何判据的原因）。
Future<TextSpan> _pumpStyledSpan(
  WidgetTester tester,
  MarkdownEditingController controller,
  TextStyle base, {
  double width = 580,
}) async {
  late TextSpan span;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Builder(builder: (context) {
              span = controller.buildTextSpan(
                context: context,
                style: base,
                withComposing: false,
              );
              return RichText(text: span);
            }),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return span;
}

/// 渲染后的**视觉行数**：取全部字形盒并按纵向重叠合并。
///
/// 不能数可见文本里的换行——分割线经满宽呈现单元**软换行**后，其断行在可见文本里数不出来，
/// 但它在布局上确实建立了行盒；反之零宽补白片段会给出 1px 的伪盒子，按重叠合并即可滤掉
/// （伪盒子总与所在行盒重叠）。
int _visualLineCount(WidgetTester tester) {
  final rp = tester.renderObject<RenderParagraph>(find.byType(RichText).last);
  final boxes = rp.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: rp.text.toPlainText().length),
  );
  final merged = <List<double>>[];
  for (final b in boxes) {
    var hit = false;
    for (final iv in merged) {
      if (b.top < iv[1] - 0.5 && b.bottom > iv[0] + 0.5) {
        if (b.top < iv[0]) iv[0] = b.top;
        if (b.bottom > iv[1]) iv[1] = b.bottom;
        hit = true;
        break;
      }
    }
    if (!hit) merged.add(<double>[b.top, b.bottom]);
  }
  return merged.length;
}




int _widgetSpanCount<T>(InlineSpan root) {
  var count = 0;
  void visit(InlineSpan span) {
    if (span is WidgetSpan) {
      if (span.child is T) count++;
      return;
    }
    if (span is TextSpan) {
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }
  }

  visit(root);
  return count;
}
