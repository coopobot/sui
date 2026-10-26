/// M15 单测：行内记号的嵌套与转义感知（FR-78 / BR-78.4 / FR-79 / BR-79.1~79.2）。
///
/// 「可见文本」= 移除全部记号区间后的文本；`escape` 记号按 BR-78.4 只隐藏**反斜杠**，
/// 被转义字符按普通文本显示。
///
/// **红检**（回退源文件再跑本文件）：
/// - 改动前 `~~文字==高亮==~~` 的 highlight 记号数为 **0**（内层 `==` 明文露出）→ 失败；
/// - 改动前 `\*a\*` 的 emphasis 记号数为 **2**（反斜杠可见、`*` 被当记号隐藏）→ 失败。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

List<SyntaxMarker> _markers(String text) => EditorFormat.syntaxMarkers(text);

int _count(String text, SyntaxMarkerKind kind) =>
    _markers(text).where((m) => m.kind == kind).length;

/// 格式模式下的**可见文本**：抹掉记号区间；`escape` 只抹掉反斜杠。
String _visible(String text) {
  final ms = [..._markers(text)]..sort((a, b) => a.start.compareTo(b.start));
  final buf = StringBuffer();
  var cursor = 0;
  for (final m in ms) {
    if (m.start < cursor) continue;
    buf.write(text.substring(cursor, m.start));
    if (m.kind == SyntaxMarkerKind.escape) {
      buf.write(text.substring(m.start + 1, m.end));
    }
    cursor = m.end;
  }
  buf.write(text.substring(cursor));
  return buf.toString();
}

void main() {
  group('EditorInlineNesting（FR-79 / BR-79.1）', () {
    test('~~文字==高亮==~~ → strike 对 + 内层 highlight 对，可见「文字高亮」', () {
      const src = '~~文字==高亮==~~';
      expect(_count(src, SyntaxMarkerKind.strike), 2);
      expect(_count(src, SyntaxMarkerKind.highlight), 2,
          reason: '内层 == 必须成记号（否则零宽隐藏失效、明文露出）');
      expect(_visible(src), '文字高亮');
    });

    test('~~==a==~~ → strike 对 + highlight 对，可见「a」', () {
      const src = '~~==a==~~';
      expect(_count(src, SyntaxMarkerKind.strike), 2);
      expect(_count(src, SyntaxMarkerKind.highlight), 2);
      expect(_visible(src), 'a');
    });

    test('*斜* ~~删==高==~~ → emphasis / strike / highlight 各自成对', () {
      const src = '*斜* ~~删==高==~~';
      expect(_count(src, SyntaxMarkerKind.emphasis), 2);
      expect(_count(src, SyntaxMarkerKind.strike), 2);
      expect(_count(src, SyntaxMarkerKind.highlight), 2);
      expect(_visible(src), '斜 删高');
    });

    test('加粗内嵌高亮：**加==亮==** → strong 对 + highlight 对', () {
      const src = '**加==亮==**';
      expect(_count(src, SyntaxMarkerKind.strong), 2);
      expect(_count(src, SyntaxMarkerKind.highlight), 2);
      expect(_visible(src), '加亮');
    });

    test('反向组合 ==~~文字~~== 保持现状：highlight 对、**不**递归出 strike', () {
      // BR-79.2：预览侧 `_HighlightSyntax` 明确「内容按纯文本承载、不做嵌套解析」
      // （`flutter_app/lib/src/ui/markdown_editor.dart`），故格式模式也不得递归——
      // 两态可见文本都停在 `~~文字~~`，不制造新分裂。
      const src = '==~~文字~~==';
      expect(_count(src, SyntaxMarkerKind.highlight), 2);
      expect(_count(src, SyntaxMarkerKind.strike), 0,
          reason: '外层为 highlight 时不递归内层 strike（BR-79.2 反向组合保持现状）');
      expect(_visible(src), '~~文字~~');
    });

    test('高亮内其它记号同样不递归（==*a*== 与预览逐字一致）', () {
      const src = '==*a*==';
      expect(_count(src, SyntaxMarkerKind.highlight), 2);
      expect(_count(src, SyntaxMarkerKind.emphasis), 0);
      expect(_visible(src), '*a*');
    });
  });

  group('EditorEscapeAware（FR-78 / BR-78.4）', () {
    test(r'\*a\* → 两处 escape、无 emphasis，可见 *a*', () {
      const src = r'\*a\*';
      expect(_count(src, SyntaxMarkerKind.escape), 2);
      expect(_count(src, SyntaxMarkerKind.emphasis), 0);
      expect(_count(src, SyntaxMarkerKind.strong), 0);
      expect(_visible(src), '*a*');
    });

    test(r'\=\=高亮\=\= → 四处 escape、无 highlight，可见 ==高亮==', () {
      const src = r'\=\=高亮\=\=';
      expect(_count(src, SyntaxMarkerKind.escape), 4);
      expect(_count(src, SyntaxMarkerKind.highlight), 0);
      expect(_visible(src), '==高亮==');
    });

    test(r'*a\*b* → emphasis 成对 + 一处 escape，可见 a*b', () {
      const src = r'*a\*b*';
      expect(_count(src, SyntaxMarkerKind.emphasis), 2,
          reason: '转义感知：被转义的 * 不作定界符，但花括号仍可整体成对');
      expect(_count(src, SyntaxMarkerKind.escape), 1);
      expect(_visible(src), 'a*b');
    });

    test(r'\*** → 一处 escape，其余 ** 落单不成记号，可见 ***', () {
      const src = r'\***';
      final ms = _markers(src);
      expect(ms, hasLength(1));
      expect(ms.single.kind, SyntaxMarkerKind.escape);
      expect(ms.single.start, 0);
      expect(ms.single.end, 2, reason: 'escape 区间覆盖 \\ 与被转义字符两个码元');
      expect(ms.single.pairId, isNull, reason: 'escape 不是成对记号');
      expect(_visible(src), '***');
    });

    test(r'\\ → 一处 escape（反斜杠转义反斜杠）', () {
      const src = r'\\';
      final ms = _markers(src);
      expect(ms, hasLength(1));
      expect(ms.single.kind, SyntaxMarkerKind.escape);
      expect(ms.single.start, 0);
      expect(ms.single.end, 2);
    });

    test(r'转义序列是原子记号：结构删除一次删掉 \ 与被转义字符', () {
      const src = r'\*a';
      final r = EditorFormat.structuralDelete(src, 2, 2, backspace: true)!;
      expect(r.text, 'a', reason: '不得留下孤立的 \\');
    });
  });
}
