/// M15 单测：格式模式输入转义（FR-78 / BR-78.1~78.5）。
///
/// 矩阵覆盖：行内恒敏感（任意位置）/ 行首敏感（仅行首空白区）/「数字 + `.`」/ 代码区不转义 /
/// 字母数字空格中文**绝不**转义 / 表格单元格口径 / 代码区判定。
///
/// **红检**（回退源文件再跑本文件）：`escapeForTyping` 与 `isInsideCodeRegion` 尚不存在 →
/// 整个文件编译失败；若只把「合法性判据」去掉，则 `a` / `1` / ` ` 会被加上反斜杠 →
/// 「只转义合法转义目标」用例失败。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

String _type(String text, int offset, String ch, {bool cell = false}) =>
    EditorFormat.escapeForTyping(text, offset, ch, inTableCell: cell);

void main() {
  group('EscapeForTypingInline（行内恒敏感：任意位置，FR-78 / BR-78.1）', () {
    test(r'* _ ~ = [ ] < & | 与 \ 在行首 / 词中 / 行尾都被转义', () {
      const chars = ['*', '_', '~', '=', '[', ']', '<', '&', '|', r'\'];
      for (final ch in chars) {
        expect(_type('', 0, ch), '\\$ch', reason: '行首 $ch');
        expect(_type('甲乙', 1, ch), '\\$ch', reason: '词中 $ch');
        expect(_type('甲乙', 2, ch), '\\$ch', reason: '行尾 $ch');
      }
      // 行内代码标记（反引号）同理。
      expect(_type('甲乙', 1, '`'), r'\`');
    });

    test('多字符 / 空串 / 非 ASCII 原样返回（只处理单字符键入，BR-78.5）', () {
      expect(_type('', 0, 'ab'), 'ab');
      expect(_type('', 0, ''), '');
      expect(_type('', 0, '中'), '中');
    });
  });

  group('EscapeForTypingLineStart（行首敏感）', () {
    test('# - + > 只在行首空白区转义', () {
      for (final ch in ['#', '-', '+', '>']) {
        expect(_type('', 0, ch), '\\$ch', reason: '行首 $ch');
        expect(_type('  ', 2, ch), '\\$ch', reason: '行首空白后 $ch');
        expect(_type('甲', 1, ch), ch, reason: '词中 $ch 不转义');
        expect(_type('甲 ', 2, ch), ch, reason: '行首非空白后 $ch 不转义');
        expect(_type('甲\n\t', 3, ch), '\\$ch', reason: '换行 + 制表符后 $ch');
      }
    });

    test('| 在行首同样被转义（行内敏感已覆盖）', () {
      expect(_type('', 0, '|'), r'\|');
      expect(_type('甲', 1, '|'), r'\|');
    });

    test('「数字 + .」：只转义 `.`，数字不转义（返回值只是该字符的落笔文本）', () {
      expect(_type('1', 1, '.'), r'\.');
      expect(_type('12', 2, '.'), r'\.');
      expect(_type(' 1', 2, '.'), r'\.', reason: '行首空白 + 数字仍是行首有序列表');
      expect(_type('abc', 3, '.'), '.');
      expect(_type('1.2', 3, '.'), '.', reason: '前缀含 `.` 时不成有序列表前缀');
      expect(_type('1', 1, '1'), '1', reason: '数字不是合法转义目标');
    });
  });

  group('EscapeForTypingValidTarget（只转义合法转义目标，BR-78.2）', () {
    test('字母 / 数字 / 空格 / 中文绝不前置反斜杠', () {
      for (final ch in ['a', 'Z', '1', ' ', '中', '，', '。', '！']) {
        expect(_type('甲乙', 1, ch), ch, reason: '$ch 不是合法转义目标');
        expect(_type('', 0, ch), ch, reason: '行首 $ch 同样不转义');
      }
    });
  });

  group('EscapeForTypingCodeRegion（代码区不转义，BR-78.3）', () {
    test('围栏代码块内（围栏行与内容行）不转义', () {
      const src = '```\ncode\n```';
      expect(EditorFormat.isInsideCodeRegion(src, 0), isTrue, reason: '开围栏行');
      expect(EditorFormat.isInsideCodeRegion(src, 4), isTrue, reason: '内容行行首');
      expect(EditorFormat.isInsideCodeRegion(src, 8), isTrue, reason: '闭合围栏行');
      expect(_type(src, 4, '*'), '*');
      expect(_type(src, 5, '`'), '`');
    });

    test('围栏块之后回到普通语境', () {
      const src = '```\ncode\n```\n正文';
      expect(EditorFormat.isInsideCodeRegion(src, 13), isFalse);
      expect(_type(src, 13, '*'), r'\*');
    });

    test('行内代码跨度内不转义，跨度之后恢复', () {
      const src = '`a`b';
      expect(EditorFormat.isInsideCodeRegion(src, 1), isTrue);
      expect(EditorFormat.isInsideCodeRegion(src, 2), isTrue);
      expect(EditorFormat.isInsideCodeRegion(src, 3), isFalse);
      expect(_type(src, 2, '*'), '*');
      expect(_type(src, 3, '*'), r'\*');
    });

    test('被转义的反引号不计入跨度判定', () {
      const src = r'\`a';
      expect(EditorFormat.isInsideCodeRegion(src, 3), isFalse);
      expect(_type(src, 3, '*'), r'\*');
    });

    test('CRLF 围栏块内同样不转义（FR-77 容错 + BR-78.3）', () {
      const src = '```\r\ncode\r\n```\r\n正文';
      expect(EditorFormat.isInsideCodeRegion(src, 5), isTrue);
      expect(_type(src, 5, '~'), '~');
    });
  });

  group('EscapeForTypingTableCell（表格单元格口径）', () {
    test('| 不转义、格首 # / - 不转义、* 与 ~ 仍转义', () {
      expect(_type('', 0, '|', cell: true), '|');
      expect(_type('', 0, '#', cell: true), '#');
      expect(_type('甲', 1, '-', cell: true), '-');
      expect(_type('', 0, '*', cell: true), r'\*');
      expect(_type('甲', 1, '~', cell: true), r'\~');
      expect(_type('甲', 1, '=', cell: true), r'\=');
    });
  });
}
