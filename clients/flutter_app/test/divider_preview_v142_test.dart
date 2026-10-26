/// 分割线「标准正本 + 紧贴渲染」口径（`v0.14.3` / BR-72.1~72.3、BR-72.7）。
///
/// 正本按标准 Markdown：`---` **上方**有空行（与 Gitea / GitHub / Typora 一致）、**下方不补**
/// 空行、紧随原有正文（`段落1\n\n---\n段落2`）；格式 / 预览把「`\n---\n` 当作一个整体」渲染为
/// 紧贴的分割线（无多余行、上一行不被当标题）。
///
/// 用真实的 `markdown` 包断言解析语义：空白分隔的 `---` → `<hr>`（不是 h2）；
/// 紧贴上一行的 `---` → setext 二级标题（标准语义，与格式模式一致）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:note_core/note_core.dart';

List<String> _tagsOf(String source) {
  final doc = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
  final out = <String>[];
  void walk(List<md.Node> nodes) {
    for (final node in nodes) {
      if (node is md.Element) {
        out.add(node.tag);
        walk(node.children ?? const <md.Node>[]);
      }
    }
  }

  walk(doc.parse(source));
  return out;
}

void main() {
  group('DividerStandardSemantics（标准 Markdown 语义 / BR-72.1）', () {
    test('空白分隔的 --- 解析为 hr（不是 h2）', () {
      final tags = _tagsOf('段落\n\n---\n\n段落2');
      expect(tags, contains('hr'));
      expect(tags, isNot(contains('h2')));
    });

    test('紧贴上一行的 --- 解析为 setext 二级标题（标准语义）', () {
      final tags = _tagsOf('标题\n---');
      expect(tags, contains('h2'));
      expect(tags, isNot(contains('hr')));
    });
  });

  group('DividerRuleRegion（规则记号区间 / BR-72.2、BR-72.3）', () {
    test('区间 = 上方空行的行尾换行 + `---` 行 + 该行自身的行尾换行（两种正本形态一致）', () {
      // 索引：段0 落1 1=2 \n3 \n4 -5 -6 -7 \n8 …
      const tight = '段落1\n\n---\n段落2';
      final markers = EditorFormat.syntaxMarkers(tight);
      final rule = markers.firstWhere((m) => m.kind == SyntaxMarkerKind.rule);
      expect(rule.start, 4, reason: '含上方空行的行尾换行（index 4）');
      expect(rule.end, 9,
          reason: '含 `---` 行的行尾换行（index 8）——呈现层据此让规则行以**显式换行**结束，'
              '否则满宽水平线会被软换行结束、该行按正文行高计高（间距多 7px）');
      expect(rule.lineStart, 5, reason: '行首指向 `---` 行本身（移除 / 吸附落点判定用）');
      expect(markers.any((m) => m.kind == SyntaxMarkerKind.setext), isFalse);

      // 标准形（`---` 下方还有一个空行）：区间**相同**；下方空行的换行（index 9）
      // 不纳入区间，仍作真正的换行。
      const standard = '段落1\n\n---\n\n段落2';
      final s = EditorFormat.syntaxMarkers(standard)
          .firstWhere((m) => m.kind == SyntaxMarkerKind.rule);
      expect(s.start, 4);
      expect(s.end, 9);
    });
  });
}
