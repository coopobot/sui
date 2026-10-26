/// M15 单测：笔记内查找与替换（FR-73 / BR-73.1~73.4）。
///
/// **红检**（回退源文件再跑本文件）：`FindMatch` / `findMatches` / `isStructuralOffset` /
/// `replaceAllMatches` / `replaceMatch` 尚不存在 → 编译失败。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

List<(int, int)> _spans(String text, String q, {bool cs = false}) =>
    EditorFormat.findMatches(text, q, caseSensitive: cs)
        .map((m) => (m.start, m.end))
        .toList();

void main() {
  group('FindMatches（FR-73 / BR-73.1）', () {
    test('命中计数与偏移（正本下标）', () {
      expect(_spans('abc abc\nabc', 'abc'), [(0, 3), (4, 7), (8, 11)]);
    });

    test('空 query → 空列表；空正本 → 空列表', () {
      expect(EditorFormat.findMatches('abc', ''), isEmpty);
      expect(EditorFormat.findMatches('', 'a'), isEmpty);
    });

    test('默认大小写不敏感，可选敏感', () {
      expect(_spans('AbC abc', 'abc'), [(0, 3), (4, 7)]);
      expect(_spans('AbC abc', 'abc', cs: true), [(4, 7)]);
      expect(_spans('AbC abc', 'AbC', cs: true), [(0, 3)]);
    });

    test('不跨行：跨行 query 与跨行命中都不成立', () {
      expect(EditorFormat.findMatches('ab\ncd', 'b\nc'), isEmpty);
      expect(_spans('ab\ncd', 'b'), [(1, 2)]);
      expect(_spans('ab\ncd', 'c'), [(3, 4)]);
    });

    test('非重叠推进', () {
      expect(_spans('aaaa', 'aa'), [(0, 2), (2, 4)]);
    });

    test('中文 / 多字节字符的偏移是码元下标', () {
      expect(_spans('甲乙丙甲乙', '甲乙'), [(0, 2), (3, 5)]);
    });

    test('FindMatch.length 与区间自洽', () {
      final m = EditorFormat.findMatches('abc', 'bc').single;
      expect(m.length, 2);
      expect(m.start, 1);
      expect(m.end, 3);
    });
  });

  group('StructuralOffset（BR-73.2 结构区不可替换）', () {
    const table = '| A | B |\n| --- | --- |\n| 1 | 2 |';
    const attach = '![图](sui://deadbeef)';
    const link = '[文字](https://a.com/x)';
    const fence = '```\ncode\n```';
    const escaped = r'\*a';

    test('表格块内 / 外', () {
      expect(EditorFormat.isStructuralOffset(table, 2), isTrue);
      expect(EditorFormat.isStructuralOffset('$table\n\n正文', table.length + 3),
          isFalse);
    });

    test('附件引用内 / 外', () {
      expect(EditorFormat.isStructuralOffset('前 $attach 后', 4), isTrue);
      expect(EditorFormat.isStructuralOffset('前 $attach 后', 1), isFalse);
    });

    test('链接的 `](网址)` 段为结构区，显示文字不是', () {
      expect(EditorFormat.isStructuralOffset(link, 1), isFalse, reason: '显示文字可替换');
      expect(EditorFormat.isStructuralOffset(link, 4), isTrue, reason: 'URL 段');
    });

    test('记号区间（含 escape）为结构区', () {
      expect(EditorFormat.isStructuralOffset('**粗**', 0), isTrue);
      expect(EditorFormat.isStructuralOffset('**粗**', 2), isFalse,
          reason: '可见内容可替换');
      expect(EditorFormat.isStructuralOffset(escaped, 1), isTrue);
      expect(EditorFormat.isStructuralOffset(escaped, 2), isFalse);
    });

    test('围栏行为结构区，围栏**内容**不是', () {
      expect(EditorFormat.isStructuralOffset(fence, 0), isTrue);
      expect(EditorFormat.isStructuralOffset(fence, 9), isTrue,
          reason: '闭合围栏行（` ```\\ncode\\n``` ` 中 ` ``` ` 始于下标 9）');
      expect(EditorFormat.isStructuralOffset(fence, 5), isFalse, reason: '内容行可替换');
    });
  });

  group('ReplaceAll（BR-73.3 / BR-73.4）', () {
    test('全部替换：一次到位、文本逐字相符、选区落在最后一次替换之后', () {
      final r = EditorFormat.replaceAllMatches('a b a b', 'a', 'X');
      expect(r.text, 'X b X b');
      expect(r.skipped, 0);
      expect(r.selectionStart, 5);
      expect(r.selectionEnd, 5);
    });

    test('无命中：原样返回、skipped 为 0', () {
      final r = EditorFormat.replaceAllMatches('abc', 'z', 'X');
      expect(r.text, 'abc');
      expect(r.skipped, 0);
      expect(r.selectionStart, 0);
      expect(r.selectionEnd, 0);
    });

    test('大小写不敏感替换保持一致', () {
      final r = EditorFormat.replaceAllMatches('Ab aB', 'ab', 'X');
      expect(r.text, 'X X');
    });

    test('跳过结构区并计数：表格内不替换、正文替换', () {
      const src = '| x |\n| --- |\n| 1 |\n\nx';
      final r = EditorFormat.replaceAllMatches(src, 'x', 'Y');
      expect(r.skipped, 1);
      expect(r.text, '| x |\n| --- |\n| 1 |\n\nY');
    });

    test('附件引用内命中被跳过（显示文字同样不可替换）', () {
      final r = EditorFormat.replaceAllMatches(
          '![图](sui://deadbeef) 图', '图', 'X');
      expect(r.skipped, 1);
      expect(r.text, '![图](sui://deadbeef) X');
    });

    test('链接 URL 段命中被跳过，显示文字可替换', () {
      final r = EditorFormat.replaceAllMatches(
          '[文字](https://a.com) 文字', '文字', 'X');
      expect(r.skipped, 0);
      expect(r.text, '[X](https://a.com) X');
    });

    test('围栏行命中被跳过，围栏**内容行**命中不跳过', () {
      const src = '```\ncode\n```\ncode';
      final lines = EditorFormat.replaceAllMatches(src, '```', 'X');
      expect(lines.skipped, 2);
      expect(lines.text, src);

      final body = EditorFormat.replaceAllMatches(src, 'code', 'X');
      expect(body.skipped, 0);
      expect(body.text, '```\nX\n```\nX');
    });

    test('转义记号内的命中被跳过', () {
      final r = EditorFormat.replaceAllMatches(r'\*a *a', '*', 'X');
      expect(r.skipped, 1);
      expect(r.text, r'\*a Xa');
    });

    test('不引入任何隐藏字符（BR-73.4）', () {
      final r = EditorFormat.replaceAllMatches('甲乙', '甲', 'A');
      expect(r.text.runes.any((c) => c == 0x2060 || c == 0x00A0), isFalse);
      expect(r.text, 'A乙');
    });
  });

  group('ReplaceMatch（BR-73.3）', () {
    test('只替换一处、光标落到替换内容之后', () {
      const src = 'a b a';
      final m = EditorFormat.findMatches(src, 'a').last;
      final r = EditorFormat.replaceMatch(src, m, 'XYZ');
      expect(r.text, 'a b XYZ');
      expect(r.selectionStart, 7);
      expect(r.selectionEnd, 7);
    });

    test('替换文本可为空（等价删除该命中）', () {
      final m = EditorFormat.findMatches('a b a', 'a').first;
      final r = EditorFormat.replaceMatch('a b a', m, '');
      expect(r.text, ' b a');
      expect(r.selectionStart, 0);
    });

    test('越界命中区间被钳制，不抛异常', () {
      final r = EditorFormat.replaceMatch('abc', const FindMatch(-5, 99), 'X');
      expect(r.text, 'X');
    });
  });
}
