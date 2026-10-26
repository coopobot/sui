/// M15 呈现层核心（`markdown_editing_controller.dart`）——控制器级回归
/// （requirements §26：FR-73 查找高亮 / FR-76 链接单元 / FR-77 `\r` 容错 / FR-78 转义呈现 /
/// FR-79 记号嵌套 / FR-81a 代码块底色带；规范 `.tmp/specs/m15-flutter-app-spec.md` §1.1\~§1.7）。
///
/// 纪律：**禁用** `pumpAndSettle()`（Agents.md §5.2），一律有界 `pump`；
/// 夹具尽量直接驱动 `MarkdownEditingController`（`buildTextSpan` 的 span 树 +
/// 真实 `TextField` 的几何），不依赖 `note_editor.dart`（并行开发中）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';

import 'package:sui_flutter_app/src/ui/appearance/app_palette.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';

// ---------------------------------------------------------------------------
// 工具（`_visibleText` / `_norm` 与 test/editor_wysiwyg_ui_test.dart 同口径）
// ---------------------------------------------------------------------------

/// span 树的**可见文本**：跳过零宽透明片段（`fontSize: 0` / 透明色），
/// 呈现单元取其**语义占位文本**（`Text` 子项；勾选框 / 图片 / 水平线等无文字单元为空串）。
String _visibleText(InlineSpan span) {
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

/// 去掉全部空白后的文本（两态比对口径）。
String _norm(String s) => s.replaceAll(RegExp(r'\s+'), '');

/// **承载第 [index] 个码元**的叶 [TextSpan] 的样式（`WidgetSpan` 按偏移契约占 1 个码元）。
TextStyle? _styleAt(InlineSpan span, int index) {
  TextStyle? found;
  var cursor = 0;
  void walk(InlineSpan s) {
    if (found != null) return;
    if (s is TextSpan) {
      final t = s.text;
      if (t != null) {
        if (index >= cursor && index < cursor + t.length) {
          found = s.style;
          return;
        }
        cursor += t.length;
      }
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
        if (found != null) return;
      }
    } else if (s is WidgetSpan) {
      cursor += 1;
    }
  }

  walk(span);
  return found;
}

/// span 树中带指定 key 的 `WidgetSpan` 数量（勾选框 / 链接单元 / 底色带…）。
int _countWidgets(InlineSpan span, Key key) {
  var count = 0;
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    } else if (s is WidgetSpan) {
      if (s.child.key == key) count++;
    }
  }

  walk(span);
  return count;
}

/// 预览模式渲染出的**可见文本**（口径同 `editor_wysiwyg_ui_test.dart`）。
List<String> _previewTexts(WidgetTester tester) {
  final out = <String>[];
  void collect(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\uE000-\uF8FF]'), '');
    if (cleaned.isNotEmpty) out.add(cleaned);
  }

  final root = tester.element(find.byType(MarkdownPreview));
  void walk(Element e) {
    final w = e.widget;
    if (w is RichText) {
      collect(w.text.toPlainText());
    } else if (w is SelectableText) {
      collect(w.textSpan?.toPlainText() ?? '');
    }
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

/// 在真实 [MaterialApp] 上下文里取格式模式的 span 树（口径同既有 widget 用例）。
Future<TextSpan> _pumpSpan(
  WidgetTester tester,
  MarkdownEditingController controller, {
  bool withComposing = false,
}) async {
  late TextSpan span;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          span = controller.buildTextSpan(
            context: context,
            style: const TextStyle(fontSize: 15, height: 1.6),
            withComposing: withComposing,
          );
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return span;
}

/// 把控制器挂进**真实 `TextField`**（几何类断言用；样式 / strut 与 `markdown_editor.dart` 同源）。
Future<void> _pumpRealField(
  WidgetTester tester,
  MarkdownEditingController controller, {
  double width = 400,
}) async {
  const body = TextStyle(fontSize: 15, height: 1.6);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          // 夹具与 `_SourceEditor` 同口径：`width` = **编辑区白底宽**，
          // 正文 `TextField` 内缩左右各 `kEditorBodyPadding`（FR-93 / BR-93.1）。
          child: SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.all(kEditorBodyPadding),
              child: TextField(
                controller: controller,
                maxLines: null,
                style: body,
                strutStyle:
                    StrutStyle.fromTextStyle(body, forceStrutHeight: false),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  // -------------------------------------------------------------------------
  // ① FR-79 记号解析同源化：嵌套记号（消费 EditorFormat.syntaxMarkers）
  // -------------------------------------------------------------------------
  group('InlineNesting（FR-79 / 规范 §1.1）', () {
    testWidgets('`~~文字==高亮==~~` 可见文本不含 `==`', (tester) async {
      const src = '~~文字==高亮==~~';
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);
      final span = await _pumpSpan(tester, controller);

      expect(span.toPlainText().length, src.length, reason: '偏移契约（BR-27.1）');
      final visible = _visibleText(span);
      expect(visible, '文字高亮', reason: '内层 `==高亮==` 也必须成记号（FR-79 / BR-79.1）');
      expect(visible.contains('=='), isFalse);
      // 嵌套样式叠加：删除线 + 高亮底色同时落在内层文字上。
      final style = _styleAt(span, src.indexOf('高'));
      expect(style?.decoration, TextDecoration.lineThrough);
      expect(style?.backgroundColor, isNotNull);
    });

    testWidgets('`~~文字==高亮==~~` 两态可见文本一致（FormatPreviewParity 不回归）',
        (tester) async {
      const src = '~~文字==高亮==~~';
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);
      final span = await _pumpSpan(tester, controller);
      final formatVisible = _norm(_visibleText(span));

      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MarkdownPreview(text: src))),
      );
      await tester.pump();
      expect(formatVisible, _norm(_previewTexts(tester).join()));
    });
  });

  // -------------------------------------------------------------------------
  // ② FR-78 转义记号呈现
  // -------------------------------------------------------------------------
  group('EscapeMarker（FR-78 / BR-78.4 / 规范 §1.2）', () {
    testWidgets('`\\*a\\*` 可见文本为 `*a*`（反斜杠不可见、`a` 正常）', (tester) async {
      const src = r'\*a\*';
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);
      final span = await _pumpSpan(tester, controller);

      expect(span.toPlainText().length, src.length);
      expect(_visibleText(span), '*a*');
      // 被转义字符**不是**记号：没有斜体（BR-78.4）。
      expect(_styleAt(span, 2)?.fontStyle, isNot(FontStyle.italic));
    });

    testWidgets('`\\=\\=高亮\\=\\=` 与 `\\[x\\]\\(y\\)` 可见文本为字面量', (tester) async {
      for (final src in const [r'\=\=高亮\=\=', r'\[x\]\(y\)']) {
        final controller = MarkdownEditingController(text: src)..styled = true;
        addTearDown(controller.dispose);
        final span = await _pumpSpan(tester, controller);
        expect(span.toPlainText().length, src.length);
        expect(_visibleText(span), src.replaceAll(r'\', ''),
            reason: '反斜杠不可见、被转义字符按普通文本呈现：$src');
        // 转义后**不**成形（无高亮底 / 无链接单元）。
        expect(_countWidgets(span, const ValueKey('probe-link')), 0);
      }
    });

    testWidgets('转义区间内部偏移**不可停**（FR-78 光标原子性）', (tester) async {
      const src = r'\*a\*';
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);

      controller.selection = const TextSelection.collapsed(offset: 0);
      controller.selection = const TextSelection.collapsed(offset: 1);
      expect(controller.selection.extentOffset, 2,
          reason: '右向落入 `\\*` 内部 → 吸附到区间末尾');
      controller.selection = const TextSelection.collapsed(offset: 4);
      controller.selection = const TextSelection.collapsed(offset: 3);
      expect(controller.selection.extentOffset, 3,
          reason: '左向落入 `\\*` 内部 → 吸附到区间起点');
    });
  });

  // -------------------------------------------------------------------------
  // ③ FR-76 链接单元
  // -------------------------------------------------------------------------
  group('LinkUnit（FR-76 / 规范 §1.3）', () {
    testWidgets('树中出现链接单元、可见文本仍含标签、区间纳入光标原子吸附',
        (tester) async {
      const src = '前 [标签](https://example.com) 后';
      const linkKey = ValueKey('probe-link');
      final controller = MarkdownEditingController(text: src)..styled = true;
      controller.formatLinkBuilder = (context, link) =>
          Text(link.label, key: linkKey);
      addTearDown(controller.dispose);
      final span = await _pumpSpan(tester, controller);

      expect(span.toPlainText().length, src.length, reason: '偏移契约（BR-27.1）');
      expect(_countWidgets(span, linkKey), 1,
          reason: '链接区间应替换为一个链接单元 widget');
      final visible = _visibleText(span);
      expect(visible.contains('标签'), isTrue,
          reason: '链接单元内的显示文字必须是可见文本（BR-76.2）');
      expect(visible.contains('](https'), isFalse, reason: '网址与语法记号不可见');

      // 光标原子吸附：区间内部不可落点（否则「看不见的光标」停在链接内部）。
      final start = src.indexOf('[');
      final end = src.indexOf(')') + 1;
      controller.selection = TextSelection.collapsed(offset: start);
      controller.selection = TextSelection.collapsed(offset: start + 1);
      expect(controller.selection.extentOffset, end,
          reason: '右向落入链接内部 → 吸附到区间末尾');
      controller.selection = TextSelection.collapsed(offset: start + 3);
      expect(controller.selection.extentOffset, start,
          reason: '左向落入链接内部 → 吸附到区间起点');
    });

    testWidgets('未注入构建器时链接退化为普通样式文本（正本与偏移不变）',
        (tester) async {
      const src = '[标签](https://example.com)';
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);
      final span = await _pumpSpan(tester, controller);
      expect(span.toPlainText().length, src.length);
      expect(_visibleText(span), '标签');
    });
  });

  // -------------------------------------------------------------------------
  // ④ FR-81a 代码块块级底色带
  // -------------------------------------------------------------------------
  group('CodeBlockBand（FR-81a / BR-81.1 / 规范 §1.4 / FR-94）', () {
    const src = '前文\n\n```dart\nvar a = 1;\n\nvar b = 2;\n```\n\n后文';

    testWidgets('paragraphWidth > 0：开围栏行整行隐藏、内容行等宽且无逐字形底色',
        (tester) async {
      final controller = MarkdownEditingController(text: src)
        ..styled = true
        ..paragraphWidth = 368;
      addTearDown(controller.dispose);
      await _pumpRealField(tester, controller, width: 400);

      // FR-94：底色带由 `CodeBlockBandPainter` 在 `TextField` **背后**绘制，
      // 正文 span 里**不再**有带占位 widget（inline 子 widget 会被画在文字之上）。
      final span = controller.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        style: const TextStyle(fontSize: 15, height: 1.6),
        withComposing: false,
      );
      expect(_styleAt(span, src.indexOf('var a = 1;'))?.backgroundColor, isNull,
          reason: '底色带生效时不得再逐字形染色（AC-436）');
      expect(_styleAt(span, src.indexOf('var a = 1;'))?.fontFamily, 'monospace',
          reason: '围栏内容行仍为等宽（BR-81.1）');
      expect(span.toPlainText().length, src.length, reason: '偏移契约（BR-27.1）');
      expect(_visibleText(span).contains('var a = 1;'), isTrue,
          reason: '代码文字仍可见 / 可编辑（BR-81.3 / AC-443）');
      expect(_visibleText(span).contains('dart'), isFalse,
          reason: '开围栏行的 info string 必须隐藏（否则格式态露出 ```dart）');
    });

    testWidgets('paragraphWidth == 0：不建立开围栏行区间（兜底逐字形底色）',
        (tester) async {
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);
      await _pumpRealField(tester, controller, width: 400);

      final span = controller.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        style: const TextStyle(fontSize: 15, height: 1.6),
        withComposing: false,
      );
      expect(_styleAt(span, src.indexOf('var a = 1;'))?.backgroundColor, isNotNull,
          reason: '宽度未知时退回逐字形底色（BR-81.1 兜底路径）');
    });

    testWidgets('两态（开围栏行区间建 / 不建）段落尺寸不变（零布局影响）',
        (tester) async {
      final withBand = MarkdownEditingController(text: src)
        ..styled = true
        ..paragraphWidth = 368;
      addTearDown(withBand.dispose);
      await _pumpRealField(tester, withBand);
      final sizeWith =
          tester.allRenderObjects.whereType<RenderEditable>().first.size;

      final without = MarkdownEditingController(text: src)..styled = true;
      addTearDown(without.dispose);
      await _pumpRealField(tester, without);
      final sizeWithout =
          tester.allRenderObjects.whereType<RenderEditable>().first.size;

      expect(sizeWith.height, closeTo(sizeWithout.height, 0.51));
      expect(sizeWith.width, closeTo(sizeWithout.width, 0.51));
    });
  });

  // -------------------------------------------------------------------------
  // ⑤ FR-73 查找命中高亮
  // -------------------------------------------------------------------------
  group('FindHighlight（FR-73 / 规范 §1.5）', () {
    testWidgets('格式态：命中字符底色被覆盖，当前命中项口径更强且与黄色高亮区分',
        (tester) async {
      const src = '甲虫甲乙虫';
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);

      // 普通字段：写入命中集合**不得**触发通知（build 期不得 notify）。
      controller.findMatches = const [FindMatch(1, 2), FindMatch(4, 5)];
      controller.activeFindIndex = 1;
      expect(notifications, 0, reason: 'findMatches / activeFindIndex 是普通字段，不得 notify');

      late ColorScheme cs;
      late Color highlight;
      late TextSpan span;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              cs = Theme.of(context).colorScheme;
              highlight = SuiAppearance.of(context).palette.highlight;
              span = controller.buildTextSpan(
                context: context,
                style: const TextStyle(fontSize: 15, height: 1.6),
                withComposing: false,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(span.toPlainText().length, src.length);
      expect(_styleAt(span, 1)?.backgroundColor, cs.secondaryContainer,
          reason: '普通命中底色');
      expect(_styleAt(span, 4)?.backgroundColor, cs.primary,
          reason: '当前命中项用更强口径');
      expect(_styleAt(span, 4)?.color, cs.onPrimary);
      expect(cs.secondaryContainer, isNot(highlight), reason: '与 FR-68 黄色高亮区分');
      expect(cs.primary, isNot(highlight));
      expect(_styleAt(span, 0)?.backgroundColor, isNot(cs.secondaryContainer),
          reason: '未命中字符不受影响');
    });

    testWidgets('源码态：按命中区间切分 span，且保留 IME 组合区下划线', (tester) async {
      const src = 'abcabc';
      final controller = MarkdownEditingController(text: src)..styled = false;
      addTearDown(controller.dispose);
      controller.findMatches = const [FindMatch(0, 3)];
      controller.activeFindIndex = 0;
      controller.value = const TextEditingValue(
        text: src,
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 1, end: 2),
      );

      late ColorScheme cs;
      late TextSpan span;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              cs = Theme.of(context).colorScheme;
              span = controller.buildTextSpan(
                context: context,
                style: const TextStyle(fontSize: 15),
                withComposing: true,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(span.toPlainText(), src, reason: '源码态为零加工视图（BR-77.1）');
      expect(_styleAt(span, 0)?.backgroundColor, cs.primary,
          reason: '命中区间（当前项）被染色');
      expect(_styleAt(span, 3)?.backgroundColor, isNull,
          reason: '未命中区间不染色');
      expect(_styleAt(span, 1)?.decoration, TextDecoration.underline,
          reason: 'IME 组合区下划线必须保留');
      expect(_styleAt(span, 4)?.decoration, isNot(TextDecoration.underline));
    });

    testWidgets('源码态无命中时走框架默认路径（含组合区下划线）', (tester) async {
      const src = 'abc';
      final controller = MarkdownEditingController(text: src)..styled = false;
      addTearDown(controller.dispose);
      final span = await _pumpSpan(tester, controller, withComposing: false);
      expect(span.toPlainText(), src);
    });
  });

  // -------------------------------------------------------------------------
  // ⑥ FR-81 / AC-441 围栏行光标吸附
  // -------------------------------------------------------------------------
  group('FenceCaretSnap（AC-441 / 规范 §1.7）', () {
    const src = '前文\n\n```\ncode\n\nmore\n```\n\n后文';
    // 开围栏行 `[4, 7)` + 行尾换行 7；闭合围栏行 `[19, 22)` + 行尾换行 22。
    const openFence = [4, 7];
    const closeFence = [19, 22];

    bool onFenceLine(int offset) =>
        (offset >= openFence[0] && offset <= openFence[1]) ||
        (offset >= closeFence[0] && offset <= closeFence[1]);

    testWidgets('由上方 / 下方逐偏移进入：吸附结果均不落在围栏行与边界换行上',
        (tester) async {
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);

      // 下行扫描（prev 随结果推进）。
      var previous = 0;
      controller.selection = const TextSelection.collapsed(offset: 0);
      for (var i = 1; i <= src.length; i++) {
        controller.selection = TextSelection.collapsed(offset: i);
        final at = controller.selection.extentOffset;
        expect(onFenceLine(at), isFalse,
            reason: '下移：偏移 $i 吸附到 $at（落在围栏行 / 边界换行上）');
        expect(at, greaterThanOrEqualTo(0));
        expect(at, lessThanOrEqualTo(src.length));
        previous = at;
      }
      expect(previous, lessThanOrEqualTo(src.length));

      // 上行扫描（从文末起）。
      const tail = src.length;
      controller.selection = const TextSelection.collapsed(offset: tail);
      for (var i = tail - 1; i >= 0; i--) {
        controller.selection = TextSelection.collapsed(offset: i);
        final at = controller.selection.extentOffset;
        expect(onFenceLine(at), isFalse,
            reason: '上移：偏移 $i 吸附到 $at（落在围栏行 / 边界换行上）');
      }
    });

    testWidgets('开围栏区下移进入块内首行 / 上移退到块前一行行尾', (tester) async {
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);

      // 块前一行行尾（空行 3）→ 下移进入开围栏区 → 吸附到 contentStart（8）。
      controller.selection = const TextSelection.collapsed(offset: 3);
      controller.selection = const TextSelection.collapsed(offset: 5);
      expect(controller.selection.extentOffset, 8, reason: '右 / 下移 → 块内首行行首');

      // 由块内首行上移回到开围栏区 → 吸附到块前一行行尾（3）。
      controller.selection = const TextSelection.collapsed(offset: 11);
      controller.selection = const TextSelection.collapsed(offset: 6);
      expect(controller.selection.extentOffset, 3, reason: '左 / 上移 → 块前一行行尾');
    });

    testWidgets('闭合围栏区下移 → 块后一行行首；上移 → 末内容行行尾', (tester) async {
      final controller = MarkdownEditingController(text: src)..styled = true;
      addTearDown(controller.dispose);

      controller.selection = const TextSelection.collapsed(offset: 14);
      controller.selection = const TextSelection.collapsed(offset: 20);
      expect(controller.selection.extentOffset, 23,
          reason: '右 / 下移 → 块后一行行首（closeLineEnd + 1）');

      const tail = src.length;
      controller.selection = const TextSelection.collapsed(offset: tail);
      controller.selection = const TextSelection.collapsed(offset: 20);
      expect(controller.selection.extentOffset, 18,
          reason: '左 / 上移 → 末内容行行尾（closeLineStart - 1）');
    });

    testWidgets('吸附只在**格式模式的折叠光标**下生效', (tester) async {
      final srcMode = MarkdownEditingController(text: src)..styled = false;
      addTearDown(srcMode.dispose);
      srcMode.selection = const TextSelection.collapsed(offset: 0);
      srcMode.selection = const TextSelection.collapsed(offset: 5);
      expect(srcMode.selection.extentOffset, 5, reason: '源码模式不吸附（零加工视图）');
    });
  });

  // -------------------------------------------------------------------------
  // ⑦ FR-77 CRLF 正本：勾选框数量与 LF 版一致
  // -------------------------------------------------------------------------
  group('CrlfTolerance（FR-77 / BR-77.4 / 规范 §1.6）', () {
    testWidgets('CRLF 正本下任务项仍渲染勾选框（数量 == LF 版本）', (tester) async {
      const lf = '- [ ] 甲\n- [x] 乙';
      final crlf = lf.replaceAll('\n', '\r\n');
      const boxKey = ValueKey('probe-task');

      Future<TextSpan> spanOf(String srcText) async {
        final controller = MarkdownEditingController(text: srcText)
          ..styled = true;
        addTearDown(controller.dispose);
        controller.formatTaskCheckboxBuilder =
            (context, {required checked, required onToggle}) =>
                const Text('', key: boxKey);
        return _pumpSpan(tester, controller);
      }

      final lfSpan = await spanOf(lf);
      final lfCount = _countWidgets(lfSpan, boxKey);
      final crlfSpan = await spanOf(crlf);
      final crlfCount = _countWidgets(crlfSpan, boxKey);

      expect(lfCount, 2, reason: 'LF 版两个任务项');
      expect(crlfCount, lfCount, reason: 'CRLF 正本的勾选框数量必须与 LF 版一致（BR-77.4）');
      expect(crlfSpan.toPlainText().length, crlf.length, reason: '偏移契约（BR-27.1）');
    });

    testWidgets('CRLF 正本下分割线 / 标题行仍按块级样式呈现（行级匹配剥除 `\\r`）',
        (tester) async {
      const lf = '# 标题\n\n---\n\n正文';
      final crlf = lf.replaceAll('\n', '\r\n');
      final controller = MarkdownEditingController(text: crlf)..styled = true;
      addTearDown(controller.dispose);
      final span = await _pumpSpan(tester, controller);

      expect(span.toPlainText().length, crlf.length);
      final heading = _styleAt(span, 2); // `# 标题` 的标题文字
      expect(heading?.fontWeight, FontWeight.w700, reason: '标题字号 / 字重仍生效');
      expect(heading!.fontSize, greaterThan(15));
      expect(_visibleText(span).contains('---'), isFalse, reason: '分割线记号不可见');
    });
  });

  // -------------------------------------------------------------------------
  // ⑧ 偏移契约：非折叠选区不被吸附改写（查找定位依赖）
  // -------------------------------------------------------------------------
  group('SelectionContract（查找定位依赖 / 规范 §1.7）', () {
    testWidgets('非折叠选区跨围栏 / 记号 / 链接时**原样保留**', (tester) async {
      const src = '前文\n\n```\ncode\n```\n\n[标签](https://e.com) 与 **粗**';
      final controller = MarkdownEditingController(text: src)..styled = true;
      controller.formatLinkBuilder =
          (context, link) => Text(link.label, key: const ValueKey('probe-link'));
      addTearDown(controller.dispose);

      const selection = TextSelection(baseOffset: 2, extentOffset: 30);
      controller.value =
          const TextEditingValue(text: src, selection: selection);
      expect(controller.selection.baseOffset, 2,
          reason: '非折叠选区不得被吸附改写（BR-77.1 / 查找定位依赖）');
      expect(controller.selection.extentOffset, 30);
      expect(controller.text, src, reason: '吸附不得改正本一个字节');
    });

    testWidgets('程序化写入（文本变化）不吸附', (tester) async {
      final controller = MarkdownEditingController(text: '')..styled = true;
      addTearDown(controller.dispose);
      // 文本一变即走「非纯光标移动」分支：即便偏移落在记号内部也原样保留。
      controller.value = const TextEditingValue(
        text: '**粗**',
        selection: TextSelection.collapsed(offset: 1),
      );
      expect(controller.selection.extentOffset, 1);
    });
  });
}
