/// 快照 HTML 块的渲染（FR-69 / AC-329、AC-337）。
///
/// 覆盖：受限渲染器（`sui://` 图片走附件构建器、外链图片只占位**不出网**、样式生效）、
/// 以及**预览态混排**（Markdown 段落与 HTML 块按正本顺序同页渲染、不露出标签原文）。
///
/// 纪律：禁用 `pumpAndSettle()`（Agents.md §5.2），一律有界 `pump`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/snapshot_html_view.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  group('SnapshotHtmlView（受限渲染 / BR-69.6）', () {
    testWidgets('sui:// 图片走附件构建器并带尺寸；外链图片只占位不出网', (tester) async {
      final seen = <String>[];
      await _pump(
        tester,
        SnapshotHtmlView(
          html: '<div style="text-align:center"><img src="sui://abc" alt="图" '
              'width="600"></div><div><img src="https://example.com/a.png" alt="外链"></div>',
          suiImageBuilder: (sha256, label, width, height) {
            seen.add('$sha256|$label|$width|$height');
            return const SizedBox(width: 10, height: 10);
          },
        ),
      );

      expect(seen, ['abc|图|600.0|null']);
      expect(find.textContaining('外链'), findsOneWidget,
          reason: '外链图片只占位（不取图、不出网）');
    });

    testWidgets('颜色 / 加粗 / 下划线等样式落到文字上，文本不丢', (tester) async {
      await _pump(
        tester,
        const SnapshotHtmlView(
          html: '<p><span style="color:#c00">红</span><b>粗</b>'
              '<u>下</u>普通</p>',
        ),
      );
      final rich = tester.widget<Text>(find.byType(Text).first);
      final text = rich.textSpan?.toPlainText() ?? '';
      expect(text, contains('红'));
      expect(text, contains('粗'));
      expect(text, contains('下'));
      expect(text, contains('普通'));
    });
  });

  group('PreviewHtmlBlock（预览态混排 / AC-337）', () {
    testWidgets('Markdown 段落与 HTML 块同页渲染，且不露出标签原文', (tester) async {
      await _pump(
        tester,
        const MarkdownPreview(
          text: '# 标题\n\n普通段落\n\n'
              '<div style="text-align:center">居中内容</div>\n\n尾段\n',
        ),
      );

      expect(find.textContaining('标题'), findsWidgets);
      expect(find.textContaining('普通段落'), findsWidgets);
      expect(find.textContaining('居中内容'), findsOneWidget,
          reason: 'HTML 块必须渲染为内容而非标签原文');
      expect(find.textContaining('尾段'), findsWidgets);
      // 标签本身不得出现在可见文本里。
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final plain = t.data ?? t.textSpan?.toPlainText() ?? '';
        expect(plain.contains('<div'), isFalse);
      }
    });
  });
}
