/// 超链接录入与单元格内链接（M9 缺陷修复 ②）
/// （editor-formatting.md §14.1 / BR-23.10 / BR-44.12 / AC-177 / AC-178）。
///
/// - `LinkRender`：`[显示文字](网址)` 生成口径——空网址不生成、显示文字留空以网址充当、
///   未写协议自动补 `https://`、`mailto:` / `#锚点` / `/相对路径` 原样保留。
/// - `LinkInsert`：选区替换 / 光标处插入、`selectUrl` 占位选中口径、网址为空不落笔。
/// - `TableCellLink`：单元格内链接以 `<br>` 软换行追加、`|` 转义、其余单元格逐字不动、越界不落笔。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('LinkRender（链接文本生成口径 / BR-23.10）', () {
    test('常规：显示文字 + 网址 → 标准 Markdown 链接', () {
      expect(
        EditorFormat.renderLink(label: '随手记', url: 'https://example.com/doc'),
        '[随手记](https://example.com/doc)',
      );
    });

    test('两端空白裁掉', () {
      expect(
        EditorFormat.renderLink(label: '  随手记  ', url: '  https://e.com  '),
        '[随手记](https://e.com)',
      );
    });

    test('网址为空 → 空串（调用方据此不落笔）', () {
      expect(EditorFormat.renderLink(label: '文字', url: ''), '');
      expect(EditorFormat.renderLink(label: '文字', url: '   '), '');
    });

    test('显示文字留空 → 以网址充当文字', () {
      expect(
        EditorFormat.renderLink(label: '', url: 'https://e.com'),
        '[https://e.com](https://e.com)',
      );
    });

    test('未写协议自动补 https://', () {
      expect(
        EditorFormat.renderLink(label: 'E', url: 'example.com/a?b=1'),
        '[E](https://example.com/a?b=1)',
      );
      expect(
        EditorFormat.renderLink(label: 'IP', url: '127.0.0.1:8080'),
        '[IP](https://127.0.0.1:8080)',
      );
    });

    test('已具形态的网址原样保留（不误补 https://）', () {
      for (final u in const [
        'http://e.com',
        'https://e.com',
        'mailto:me@e.com',
        'tel:+8613800000000',
        'data:text/plain,hi',
        '#锚点',
        '/relative/path',
      ]) {
        final md = EditorFormat.renderLink(label: 'L', url: u);
        expect(md, '[L]($u)', reason: '不应改写 $u');
      }
    });
  });

  group('LinkInsert（选区 / 光标落笔口径 / AC-177）', () {
    test('无选区：在光标处插入，光标落到链接之后', () {
      final r = EditorFormat.insertLink(
        '前后',
        1,
        1,
        label: '示例',
        url: 'https://e.com',
      );
      expect(r.text, '前[示例](https://e.com)后');
      expect(r.selectionStart, '前[示例](https://e.com)'.length);
      expect(r.selectionStart, r.selectionEnd);
    });

    test('有选区：整段替换为链接', () {
      final r = EditorFormat.insertLink(
        '点这里看文档',
        1,
        3,
        label: '这里',
        url: 'https://e.com',
      );
      expect(r.text, '点[这里](https://e.com)看文档');
    });

    test('网址为空 → 原样返回（正本一字不动）', () {
      const text = '正文';
      final r =
          EditorFormat.insertLink(text, 1, 2, label: '文字', url: '  ');
      expect(r.text, text);
    });

    test('`FormatCommand.link` 纯指令仍产出 `[文字](url)` 占位', () {
      final r = EditorFormat.apply(FormatCommand.link, 'x', 0, 1);
      expect(r.text, '[x](url)');
      expect(r.text.substring(r.selectionStart, r.selectionEnd), 'url');
      final empty = EditorFormat.apply(FormatCommand.link, '', 0, 0);
      expect(empty.text, '[文字](url)');
    });
  });

  group('TableCellLink（单元格内链接 / BR-44.12 / AC-178）', () {
    const table = '| A | B |\n| --- | --- |\n| 甲 | 乙 |';

    test('空单元格：直接写入链接', () {
      const src = '| A | B |\n| --- | --- |\n|  | 乙 |';
      final parsed = EditorFormat.parseTable(src)!;
      final out = EditorFormat.insertTableCellLink(
        src,
        parsed,
        0,
        0,
        label: '示例',
        url: 'https://e.com',
      );
      expect(out.split('\n')[2], '| [示例](https://e.com) | 乙 |');
    });

    test('非空单元格：以 `<br>` 软换行追加，其余单元格逐字不动', () {
      final parsed = EditorFormat.parseTable(table)!;
      final out = EditorFormat.insertTableCellLink(
        table,
        parsed,
        0,
        0,
        label: '示例',
        url: 'e.com',
      );
      expect(out.split('\n')[0], '| A | B |', reason: '表头逐字不动');
      expect(out.split('\n')[1], '| --- | --- |', reason: '分隔行逐字不动');
      expect(out.split('\n')[2], '| 甲<br>[示例](https://e.com) | 乙 |');
    });

    test('表头行（rowIndex < 0）同样可写入', () {
      final parsed = EditorFormat.parseTable(table)!;
      final out = EditorFormat.insertTableCellLink(
        table,
        parsed,
        -1,
        1,
        label: 'B',
        url: 'https://e.com',
      );
      expect(out.split('\n')[0], '| A | B<br>[B](https://e.com) |');
    });

    test('单元格内的 `|` 按 BR-44.4 转义', () {
      final parsed = EditorFormat.parseTable(table)!;
      final out = EditorFormat.insertTableCellLink(
        table,
        parsed,
        0,
        0,
        label: 'a|b',
        url: 'https://e.com',
      );
      expect(out.split('\n')[2].contains(r'a\|b'), isTrue);
      expect(
        EditorFormat.parseTable(out)!.wellFormed,
        isTrue,
        reason: '转义后表格仍良构',
      );
    });

    test('网址为空 / 行越界 → 原样返回（不落笔）', () {
      final parsed = EditorFormat.parseTable(table)!;
      expect(
        EditorFormat.insertTableCellLink(table, parsed, 0, 0,
            label: 'x', url: ''),
        table,
      );
      expect(
        EditorFormat.insertTableCellLink(table, parsed, 5, 0,
            label: 'x', url: 'https://e.com'),
        table,
      );
      expect(
        EditorFormat.insertTableCellLink(table, parsed, 0, 9,
            label: 'x', url: 'https://e.com'),
        table,
      );
    });
  });
}
