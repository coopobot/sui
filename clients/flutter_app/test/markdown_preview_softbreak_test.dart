/// 预览态软换行（`<br>`）渲染回归测试
/// （editor-formatting.md §12.1.3「⑪」/ BR-44.2 / AC-139）。
///
/// 覆盖：**表头单元格** / **数据行单元格** / **正文段落**内的 `<br>` 在「预览」模式下渲染为
/// **真实换行**、**不露出字面量 `<br>`**；`<br/>` / `<br />` 变体同样处理；其它行内 HTML
/// （如 `<b>`）不受影响（回归护栏）。
///
/// 说明：`MarkdownPreview` 即编辑器「预览」态挂载的渲染组件（`note_editor` 的三态切换），
/// 故这里直接挂它做**聚焦**渲染断言，不起整个编辑器（更快、更稳）；三态切换本身由
/// `editor_m9_e2e_test.dart`「三态一致」用例覆盖。
///
/// 纪律：不使用 `pumpAndSettle()`（Agents.md §5.2），Markdown 渲染在一次 `pump` 内完成。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sui_flutter_app/src/ui/markdown_editor.dart';

Future<void> _pumpPreview(WidgetTester tester, String text) async {
  await tester.binding.setSurfaceSize(const Size(900, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: MarkdownPreview(text: text))),
  );
  await tester.pump();
}

/// 预览渲染出的全部纯文本。
///
/// 预览态默认 `selectable: true`，flutter_markdown 用 `SelectableText` 而非 `RichText`
/// 承载行内 span，两处都取（口径同 `editor_enhancement_test.dart`）。
List<String> _renderedTexts(WidgetTester tester) => <String>[
      ...tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text.toPlainText()),
      ...tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.textSpan?.toPlainText() ?? ''),
    ];

void main() {
  group('MarkdownPreviewSoftBreak（预览态 `<br>`，§12.1.3 ⑪ / BR-44.2 / AC-139）', () {
    testWidgets('表头单元格内的 `<br>` 渲染为真实换行，不露出字面量标签', (tester) async {
      await _pumpPreview(
        tester,
        '| 甲<br>乙 | B |\n| --- | --- |\n| 1 | 2 |',
      );
      final texts = _renderedTexts(tester);

      expect(
        texts.any((t) => t.contains('<br>')),
        isFalse,
        reason: '预览态不得露出字面量 <br>（markdown 的 InlineHtmlSyntax 会原文透传）',
      );
      expect(
        texts.any((t) => t.contains('甲\n乙')),
        isTrue,
        reason: '表头单元格内的软换行应渲染为真实换行（BR-44.2 两态语义一致）',
      );
    });

    testWidgets('数据行单元格内的 `<br>` 同样渲染为真实换行', (tester) async {
      await _pumpPreview(
        tester,
        '| A | B |\n| --- | --- |\n| 1<br>2 | 3 |',
      );
      final texts = _renderedTexts(tester);

      expect(texts.any((t) => t.contains('<br>')), isFalse);
      expect(
        texts.any((t) => t.contains('1\n2')),
        isTrue,
        reason: '数据行单元格内的软换行应渲染为真实换行',
      );
    });

    testWidgets('正文段落内的 `<br>` 同样渲染为真实换行', (tester) async {
      await _pumpPreview(tester, '甲<br>乙');
      final texts = _renderedTexts(tester);

      expect(texts.any((t) => t.contains('<br>')), isFalse);
      expect(texts.any((t) => t.contains('甲\n乙')), isTrue);
    });

    testWidgets('`<br/>` / `<br />` 变体同样渲染为真实换行', (tester) async {
      await _pumpPreview(tester, '甲<br/>乙 与 丙<br />丁');
      final texts = _renderedTexts(tester);

      expect(
        texts.any((t) => t.contains('<br')),
        isFalse,
        reason: '自闭合写法也不得露出字面量标签',
      );
      expect(texts.any((t) => t.contains('甲\n乙 与 丙\n丁')), isTrue);
    });

    testWidgets('回归护栏：其它行内 HTML 与普通文本不受影响', (tester) async {
      await _pumpPreview(tester, 'a <b>b</b> c 与 4<5');
      final texts = _renderedTexts(tester);

      expect(
        texts.any((t) => t.contains('a <b>b</b> c 与 4<5')),
        isTrue,
        reason: '本次只接管 <br>，其它行内 HTML / 文本仍按原口径原样呈现',
      );
    });
  });
}
