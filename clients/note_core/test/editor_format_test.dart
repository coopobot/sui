/// 编辑器格式化单测（M2-T06 / editor-formatting.md §8）。
///
/// 覆盖：工具栏指令 → Markdown 往返与幂等切换、未触碰不透传改写、
/// 粘贴转义与富文本降级、图片尺寸的插入 / 解析容错 / 写回往返。
/// M5 补充：快捷键 ↔ 工具栏指令同源（`ShortcutMappingEquivalence`）、
/// 任务清单勾选往返（`TaskListToggleRoundTrip`）、高亮与删除线互不混淆
/// （`HighlightParseRoundTrip`）、块级呈现单元空块交互（`BlockUnitBehavior`）。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('FormatCommandRoundTrip（指令 → Markdown → 呈现一致 / 幂等切换）', () {
    test('加粗：选区包裹，选中整段再点取消', () {
      const src = 'hello world';
      final r1 = EditorFormat.apply(FormatCommand.bold, src, 0, 5);
      expect(r1.text, '**hello** world');
      expect(r1.selectionStart, 2);
      expect(r1.selectionEnd, 7, reason: '选区应仍覆盖 hello');

      final r2 = EditorFormat.apply(FormatCommand.bold, r1.text, 0, 9);
      expect(r2.text, src, reason: '再次点击应取消包裹');
    });

    test('加粗：无选区插入标记对并把光标置于中间', () {
      final r = EditorFormat.apply(FormatCommand.bold, '', 0, 0);
      expect(r.text, '****');
      expect(r.selectionStart, 2);
      expect(r.selectionEnd, 2);
    });

    test('斜体不会误删相邻的加粗星号', () {
      final r = EditorFormat.apply(FormatCommand.italic, '**bold**', 2, 6);
      expect(r.text, '***bold***', reason: '应包裹为斜体，而非吞掉加粗星号');
    });

    test('删除线包裹与取消', () {
      final r1 = EditorFormat.apply(FormatCommand.strikethrough, 'abc', 0, 3);
      expect(r1.text, '~~abc~~');
      final r2 = EditorFormat.apply(
          FormatCommand.strikethrough, r1.text, 2, 5);
      expect(r2.text, 'abc');
    });

    test('标题：行首加 #，同级别再点取消', () {
      final r1 = EditorFormat.apply(FormatCommand.heading1, 'Title', 0, 0);
      expect(r1.text, '# Title');
      final r2 = EditorFormat.apply(FormatCommand.heading1, r1.text, 0, 0);
      expect(r2.text, 'Title');
    });

    test('标题降级：H1 → H3', () {
      final r = EditorFormat.apply(FormatCommand.heading3, '# Title', 0, 0);
      expect(r.text, '### Title');
    });

    test('无序列表：逐行加前缀，再点取消', () {
      final r1 = EditorFormat.apply(FormatCommand.bulletList, 'a\nb', 0, 3);
      expect(r1.text, '- a\n- b');
      final r2 = EditorFormat.apply(FormatCommand.bulletList, r1.text, 0, 7);
      expect(r2.text, 'a\nb');
    });

    test('有序列表：惰性编号（正本统一写 1.，渲染层按序编号，FR-48）', () {
      final r = EditorFormat.apply(FormatCommand.orderedList, 'a\nb', 0, 3);
      expect(r.text, '1. a\n1. b', reason: '正本不写实序号，由渲染层编号');
    });

    test('引用：加 > 前缀', () {
      final r = EditorFormat.apply(FormatCommand.blockquote, 'quote', 0, 0);
      expect(r.text, '> quote');
    });

    test('代码块：加围栏，选中整块再点取消', () {
      final r1 = EditorFormat.apply(FormatCommand.codeBlock, 'code', 0, 4);
      expect(r1.text, '```\ncode\n```');
      final r2 = EditorFormat.apply(
          FormatCommand.codeBlock, r1.text, 0, r1.text.length);
      expect(r2.text, 'code');
    });

    test('链接：生成 [文字](url) 并选中 url 占位', () {
      final r = EditorFormat.apply(FormatCommand.link, 'site', 0, 4);
      expect(r.text, '[site](url)');
      expect(r.text.substring(r.selectionStart, r.selectionEnd), 'url');
    });

    test('分割线：独占一行 ---', () {
      final r = EditorFormat.apply(FormatCommand.divider, 'para', 0, 0);
      expect(r.text, '---\npara');
    });
  });

  group('FormatNoTouchFidelity（未触碰内容逐字节不变）', () {
    const src = '| a | b |\n| - | - |\n![p](sui://x){width=320}  <b>bold</b>  脚注[^1]\n';

    test('未识别语法（表格 / 内联 HTML / 脚注）原样保留', () {
      expect(src.contains('<b>bold</b>'), isTrue);
      expect(src.contains('| a | b |'), isTrue);
      expect(src.contains('脚注[^1]'), isTrue);
    });

    test('以相同尺寸写回应逐字节等同', () {
      final img = EditorFormat.findImage(src)!;
      expect(img.size, const ImageSize(width: ImageDimension(320, SizeUnit.pixel)));
      expect(EditorFormat.setImageSize(src, img, img.size), src);
    });

    test('M9：表格结构编辑仅改目标行，无关的附件引用逐字节不动', () {
      const doc = '| a | b |\n| --- | --- |\n| 1 | 2 |\n\n'
          '![p](sui://abc){width=320}\n';
      final t = EditorFormat.parseTable(doc)!;
      final out =
          EditorFormat.setTableAlignment(doc, t, 0, TableColumnAlign.right);
      expect(out, '| a | b |\n| ---: | --- |\n| 1 | 2 |\n\n'
          '![p](sui://abc){width=320}\n');
    });

    test('M9：表格增行不改变附件引用与有序列表', () {
      const doc = '| a | b |\n| --- | --- |\n| 1 | 2 |\n\n'
          '1. 甲\n1. 乙\n\n![p](sui://abc)\n';
      final t = EditorFormat.parseTable(doc)!;
      // 在第 0 行之后插入一空数据行
      final out = EditorFormat.insertTableRow(doc, t, 0, after: true);
      expect(out.contains('1. 甲\n1. 乙'), isTrue,
          reason: '有序列表正本不应被表格增行改动');
      expect(out.contains('![p](sui://abc)'), isTrue,
          reason: '附件引用不应被表格增行改动');
      expect(out.contains('| a | b |'), isTrue, reason: '表头行应保留');
      expect(out.contains('| --- | --- |'), isTrue, reason: '分隔行应保留');
    });

    test('M9：表格增列不改变附件引用与有序列表', () {
      const doc = '| a | b |\n| --- | --- |\n| 1 | 2 |\n\n'
          '1. 甲\n1. 乙\n\n![p](sui://abc)\n';
      final t = EditorFormat.parseTable(doc)!;
      // 在第 0 列之后插入一空列
      final out = EditorFormat.addTableColumn(doc, t, after: 0);
      expect(out.contains('1. 甲\n1. 乙'), isTrue,
          reason: '有序列表正本不应被表格增列改动');
      expect(out.contains('![p](sui://abc)'), isTrue,
          reason: '附件引用不应被表格增列改动');
    });

    test('M9：附件引用 hash 替换仅改 sui:// 部分，周边字节逐字不动', () {
      const oldSha = 'aabbccdd11223344aabbccdd11223344aabbccdd11223344aabbccdd11223344';
      const newSha = '001122334455667788990011223344556677889900112233445566778899aabb';
      final doc = '前缀 ![图.png](sui://$oldSha) 后缀\n\n'
          '1. 第一项\n1. 第二项\n';
      final out = EditorFormat.replaceAttachmentSha256(doc, oldSha, newSha);
      expect(out, isNotNull, reason: '存在旧引用应返回替换结果');
      expect(out, '前缀 ![图.png](sui://$newSha) 后缀\n\n'
          '1. 第一项\n1. 第二项\n');
      // 找不到的旧 hash 应返回 null（无变更）
      final noChange = EditorFormat.replaceAttachmentSha256(
        doc,
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        newSha,
      );
      expect(noChange, isNull, reason: '不含旧引用时返回 null 表示无须改动');
    });

    test('M9：有序列表 orderedListNumbers 纯渲染层，正本全 1. 不变', () {
      const src = '1. 甲\n1. 乙\n1. 丙\n';
      // orderedListNumbers 返回 List<int?>：每行一个元素，非列表行为 null
      final numbers = EditorFormat.orderedListNumbers(src);
      // 4 行 = 3 个列表项 + 末尾空行（null）
      expect(numbers.length, 4, reason: '4 行文本应对应 4 个元素');
      expect(numbers[0], 1, reason: '第一项编号为 1');
      expect(numbers[1], 2, reason: '第二项编号为 2');
      expect(numbers[2], 3, reason: '第三项编号为 3');
      expect(numbers[3], isNull, reason: '末尾空行不是列表项');
      // 正本不应被改动（orderedListNumbers 只读不写）
      expect(src, '1. 甲\n1. 乙\n1. 丙\n');
    });

    test('M9：简化格式保留表格 / 列表 / 引用块结构，仅剥离行内格式', () {
      const src = '| **粗** | ==高亮== |\n| --- | --- |\n| `码` | ~~删~~ |\n\n'
          '1. **第一项**\n1. ==第二项==\n\n> **引用** 文字\n';
      final result = EditorFormat.apply(
        FormatCommand.clearFormat,
        src,
        0,
        src.length,
      );
      // 表格结构（管道 | 分隔行）应保留
      expect(result.text.contains('| --- | --- |'), isTrue,
          reason: '简化格式不应破坏表格分隔行');
      expect('| 粗 | 高亮 |'.allMatches(result.text).length, 1,
          reason: '表头行内容格式应被剥离但结构保留');
      // 有序列表标记应保留
      expect(result.text.contains('1. 第一项'), isTrue,
          reason: '有序列表数字标记应保留');
      // 引用标记应保留
      expect(result.text.contains('> '), isTrue, reason: '引用标记应保留');
      // 行内格式标记应被剥离
      expect(result.text.contains('**'), isFalse, reason: '加粗标记应被剥离');
      expect(result.text.contains('=='), isFalse, reason: '高亮标记应被剥离');
      expect(result.text.contains('`'), isFalse, reason: '行内码标记应被剥离');
      expect(result.text.contains('~~'), isFalse, reason: '删除线标记应被剥离');
    });
  });

  group('PastePlainTextEscape（纯文本粘贴转义）', () {
    test('转义 Markdown 特殊字符', () {
      expect(EditorFormat.escapePlainText('a*b_c'), r'a\*b\_c');
      expect(EditorFormat.escapePlainText('# h'), r'\# h');
      expect(EditorFormat.escapePlainText('[x](y)'), r'\[x\]\(y\)');
    });

    test('普通文本不变', () {
      expect(EditorFormat.escapePlainText('hello 世界'), 'hello 世界');
    });
  });

  group('PasteRichTextToMarkdown（富文本尽力转换，降级不丢内容）', () {
    test('标题 / 粗斜 / 删除线 / 行内码', () {
      expect(EditorFormat.htmlToMarkdown('<h1>T</h1>').trim(), '# T');
      expect(EditorFormat.htmlToMarkdown('<strong>b</strong>'), '**b**');
      expect(EditorFormat.htmlToMarkdown('<em>i</em>'), '*i*');
      expect(EditorFormat.htmlToMarkdown('<del>d</del>'), '~~d~~');
      expect(EditorFormat.htmlToMarkdown('<code>c</code>'), '`c`');
    });

    test('链接与列表', () {
      expect(EditorFormat.htmlToMarkdown('<a href="http://x">X</a>'),
          '[X](http://x)');
      expect(EditorFormat.htmlToMarkdown('<ul><li>a</li><li>b</li></ul>').trim(),
          '- a\n- b');
    });

    test('无法转换的标签降级为文本且不丢内容', () {
      expect(EditorFormat.htmlToMarkdown('<span>keep</span>'), 'keep');
      expect(EditorFormat.htmlToMarkdown('x &amp; y<br>z'), 'x & y\nz');
    });

    test('HTML 表格 → GFM 管道表（首行表头 + 分隔行，§12.2）', () {
      const html = '<table><tr><th>H1</th><th>H2</th></tr>'
          '<tr><td>a</td><td>b</td></tr></table>';
      expect(EditorFormat.htmlToMarkdown(html),
          '| H1 | H2 |\n| --- | --- |\n| a | b |');
      expect(
        EditorFormat.htmlToMarkdown(
            '<table><tr><th align="center">H</th></tr>'
            '<tr><td>x</td></tr></table>'),
        '| H |\n| :---: |\n| x |',
        reason: '列对齐取自表头 align 属性',
      );
    });
  });

  group('ImageSizeInsert（插入图片生成引用）', () {
    test('生成 ![文件名](sui://<sha256>)', () {
      final r = EditorFormat.insertImage('', 0, 0,
          filename: '图.png', sha256: 'abc123');
      expect(r.text, '![图.png](sui://abc123)\n',
          reason: '文末插入时补一个换行，使图片下方仍存在可落点的行（§5.5）');
      expect(r.selectionStart, r.text.length, reason: '光标落在图片下方的新行行首');
      expect(r.selectionEnd, r.selectionStart);
    });

    test('带预设尺寸写入属性块', () {
      final r = EditorFormat.insertImage('', 0, 0,
          filename: 'a.png', sha256: 's', size: EditorFormat.presetMedium);
      expect(r.text, '![a.png](sui://s){width=50%}\n');
    });

    test('renderSizeAttribute：宽高 / 自适应', () {
      expect(EditorFormat.renderSizeAttribute(ImageSize.auto), '');
      expect(
          EditorFormat.renderSizeAttribute(const ImageSize(
            width: ImageDimension(320, SizeUnit.pixel),
            height: ImageDimension(200, SizeUnit.pixel),
          )),
          '{width=320 height=200}');
    });
  });

  group('ImageBlockInsertion（图片独占块插入，§5.5 / AC-74 / AC-80）', () {
    const md = '![p.png](sui://abc)';

    test('行中插入：所在行一分为二，图片自占一段（前后空行）', () {
      final r = EditorFormat.insertImage('前文后文', 2, 2,
          filename: 'p.png', sha256: 'abc');
      expect(r.text, '前文\n\n$md\n\n后文');
      expect(r.selectionStart, '前文\n\n$md\n\n'.length,
          reason: '光标置于图片引用之后（下一块起始处）');
    });

    test('行首插入且已有后续段落：前不补、后补空行', () {
      final r = EditorFormat.insertImage('正文\n\n下一段', 0, 0,
          filename: 'p.png', sha256: 'abc');
      expect(r.text, '$md\n\n正文\n\n下一段');
      expect(r.selectionStart, '$md\n\n'.length);
    });

    test('文末插入：补一个换行，使图片下方仍可落点', () {
      final r = EditorFormat.insertImage('正文', 2, 2,
          filename: 'p.png', sha256: 'abc');
      expect(r.text, '正文\n\n$md\n');
      expect(r.selectionStart, r.text.length);
    });

    test('替换选区为图片引用，且不吞掉相邻内容', () {
      final r = EditorFormat.insertImage('前[选中]后', 1, 5,
          filename: 'p.png', sha256: 'abc');
      expect(r.text, '前\n\n$md\n\n后');
    });

    test('已在空行插入：复用现有空行，不产生多余空行', () {
      final r = EditorFormat.insertImage('上段\n\n下段', 3, 3,
          filename: 'p.png', sha256: 'abc');
      expect(r.text, '上段\n\n$md\n\n下段');
    });

    test('带尺寸属性同样独占块', () {
      final r = EditorFormat.insertImage('前文', 2, 2,
          filename: 'p.png', sha256: 'abc', size: EditorFormat.presetMedium);
      expect(r.text, '前文\n\n$md{width=50%}\n');
    });

    test('保真：除插入点外其余字节逐字不变', () {
      final r = EditorFormat.insertImage('AAA\nBBB', 3, 3,
          filename: 'p.png', sha256: 'abc');
      expect(r.text, 'AAA\n\n$md\n\nBBB');
    });
  });

  group('ImageSizeParseTolerance（解析容错）', () {
    test('合法像素 / 百分比', () {
      expect(EditorFormat.parseSizeAttribute('{width=320}'),
          const ImageSize(width: ImageDimension(320, SizeUnit.pixel)));
      expect(EditorFormat.parseSizeAttribute('{width=50%}'),
          const ImageSize(width: ImageDimension(50, SizeUnit.percent)));
      expect(EditorFormat.parseSizeAttribute('{height=200}'),
          const ImageSize(height: ImageDimension(200, SizeUnit.pixel)));
    });

    test('未知键忽略，保留已知键', () {
      expect(EditorFormat.parseSizeAttribute('{class=foo width=320}'),
          const ImageSize(width: ImageDimension(320, SizeUnit.pixel)));
    });

    test('非法值忽略该尺寸（按自适应）', () {
      expect(EditorFormat.parseSizeAttribute('{width=0}'), ImageSize.auto);
      expect(EditorFormat.parseSizeAttribute('{width=-3}'), ImageSize.auto);
      expect(EditorFormat.parseSizeAttribute('{width=abc}'), ImageSize.auto);
      expect(EditorFormat.parseSizeAttribute('{width=150%}'), ImageSize.auto);
    });

    test('完全无法解析 → null（原样透传）', () {
      expect(EditorFormat.parseSizeAttribute('text'), isNull);
      expect(EditorFormat.parseSizeAttribute('{}'), isNull);
      expect(EditorFormat.parseSizeAttribute('{noseparator}'), isNull);
    });

    test('findImage：属性块须同一行、相邻（允许空格）', () {
      final ok = EditorFormat.findImage('![a](sui://x){width=320}')!;
      expect(ok.attributeValid, isTrue);
      expect(ok.size,
          const ImageSize(width: ImageDimension(320, SizeUnit.pixel)));

      final spaced = EditorFormat.findImage('![a](sui://x)  {width=320}')!;
      expect(spaced.attributeValid, isTrue, reason: '允许属性块前有空格');

      final newline = EditorFormat.findImage('![a](sui://x)\n{width=320}')!;
      expect(newline.attributeValid, isFalse, reason: '跨行不视为尺寸属性');
      expect(newline.size, ImageSize.auto);
    });

    test('URL / HTML 容错读入（只读）', () {
      expect(EditorFormat.parseUrlSize('http://x/p.png?w=320&h=200'),
          const ImageSize(
            width: ImageDimension(320, SizeUnit.pixel),
            height: ImageDimension(200, SizeUnit.pixel),
          ));
      expect(EditorFormat.parseHtmlImgSize('<img src="a" width="320" height=200>'),
          const ImageSize(
            width: ImageDimension(320, SizeUnit.pixel),
            height: ImageDimension(200, SizeUnit.pixel),
          ));
    });
  });

  group('ImageSizeRoundTrip（写回 → 再解析，且不触碰其它字符）', () {
    test('写入预设后解析得到同尺寸', () {
      const src = '前文 ![a](sui://x) 后文';
      final img = EditorFormat.findImage(src)!;
      final out = EditorFormat.setImageSize(src, img, EditorFormat.presetMedium);
      expect(out, '前文 ![a](sui://x){width=50%} 后文');
      expect(EditorFormat.findImage(out)!.size, EditorFormat.presetMedium);
    });

    test('改尺寸只重写属性块，其它字符不动', () {
      const src = '![a](sui://x){width=320} tail';
      final img = EditorFormat.findImage(src)!;
      final out = EditorFormat.setImageSize(src, img, EditorFormat.presetLarge);
      expect(out, '![a](sui://x){width=100%} tail');
    });

    test('原始（自适应）移除属性块', () {
      const src = '![a](sui://x){width=320}';
      final img = EditorFormat.findImage(src)!;
      expect(EditorFormat.setImageSize(src, img, ImageSize.auto),
          '![a](sui://x)');
    });

    test('无属性块时按需追加', () {
      const src = '![a](sui://x)';
      final img = EditorFormat.findImage(src)!;
      final out = EditorFormat.setImageSize(src, img,
          const ImageSize(width: ImageDimension(320, SizeUnit.pixel)));
      expect(out, '![a](sui://x){width=320}');
    });
  });

  group('ShortcutMappingEquivalence（快捷键 ↔ 工具栏指令同源，产出完全一致）', () {
    // §9 的每个快捷键都等价于 §3 的一个 FormatCommand：同一实现、同一产出。
    // 绑定在 UI 层；此处校验「指令 → 确定 Markdown」及行内指令的幂等切换。
    final cases = <FormatCommand, (String, int, int, String)>{
      FormatCommand.bold: ('x', 0, 1, '**x**'),
      FormatCommand.italic: ('x', 0, 1, '*x*'),
      FormatCommand.strikethrough: ('x', 0, 1, '~~x~~'),
      FormatCommand.highlight: ('x', 0, 1, '==x=='),
      FormatCommand.taskList: ('x', 0, 1, '- [ ] x'),
      FormatCommand.bulletList: ('x', 0, 1, '- x'),
      FormatCommand.orderedList: ('x', 0, 1, '1. x'),
      FormatCommand.blockquote: ('x', 0, 1, '> x'),
      FormatCommand.codeBlock: ('x', 0, 1, '```\nx\n```'),
      FormatCommand.heading1: ('x', 0, 0, '# x'),
      FormatCommand.heading2: ('x', 0, 0, '## x'),
      FormatCommand.heading3: ('x', 0, 0, '### x'),
      FormatCommand.link: ('x', 0, 1, '[x](url)'),
      FormatCommand.divider: ('p', 0, 0, '---\np'),
      FormatCommand.indent: ('x', 0, 1, '  x'),
      FormatCommand.outdent: ('  x', 0, 3, 'x'),
    };

    test('每个指令产出确定的 Markdown（同源保证等价）', () {
      cases.forEach((command, c) {
        final (text, s, e, expected) = c;
        expect(EditorFormat.apply(command, text, s, e).text, expected,
            reason: '$command');
      });
    });

    test('行内指令二次触发取消（幂等切换）', () {
      for (final command in [
        FormatCommand.bold,
        FormatCommand.italic,
        FormatCommand.strikethrough,
        FormatCommand.highlight,
      ]) {
        final r1 = EditorFormat.apply(command, 'x', 0, 1);
        final r2 = EditorFormat.apply(
            command, r1.text, r1.selectionStart, r1.selectionEnd);
        expect(r2.text, 'x', reason: '$command 应可取消');
      }
    });
  });

  group('TaskListToggleRoundTrip（勾选框切换回写、再解析一致）', () {
    test('- [ ] ↔ - [x] 往返且只改方括号内一个字符', () {
      const src = '前文\n- [ ] 买牛奶 后文\n尾行';
      final r1 = EditorFormat.toggleTaskChecked(src, src.indexOf('['))!;
      expect(r1.text, '前文\n- [x] 买牛奶 后文\n尾行');
      expect(_diffCount(src, r1.text), 1, reason: '仅方括号内一个字符变化');

      final r2 = EditorFormat.toggleTaskChecked(r1.text, r1.text.indexOf('['))!;
      expect(r2.text, src, reason: '再点应还原');
    });

    test('缩进 / 其它符号（* +）的任务项同样支持', () {
      final r1 = EditorFormat.toggleTaskChecked('  * [x] done', 3)!;
      expect(r1.text, '  * [ ] done');
      final r2 = EditorFormat.toggleTaskChecked('+ [ ] t', 2)!;
      expect(r2.text, '+ [x] t');
    });

    test('非任务项行返回 null（按普通正文处理，不误改）', () {
      expect(EditorFormat.toggleTaskChecked('普通段落', 0), isNull);
      expect(EditorFormat.toggleTaskChecked('- 普通列表项', 2), isNull);
    });

    test('taskList 指令：普通行变任务项，再触发取消勾选', () {
      final r1 = EditorFormat.apply(FormatCommand.taskList, '任务', 0, 2);
      expect(r1.text, '- [ ] 任务');
      final r2 = EditorFormat.apply(
          FormatCommand.taskList, r1.text, 0, r1.text.length);
      expect(r2.text, '- [x] 任务');
    });
  });

  group('HighlightParseRoundTrip（高亮 ==…== 与删除线互不混淆）', () {
    test('高亮包裹与取消', () {
      final r1 = EditorFormat.apply(FormatCommand.highlight, '重点', 0, 2);
      expect(r1.text, '==重点==');
      final r2 = EditorFormat.apply(
          FormatCommand.highlight, r1.text, r1.selectionStart, r1.selectionEnd);
      expect(r2.text, '重点');
    });

    test('高亮与删除线标记不同、互不混淆', () {
      expect(EditorFormat.apply(FormatCommand.highlight, 'a', 0, 1).text,
          '==a==');
      expect(EditorFormat.apply(FormatCommand.strikethrough, 'a', 0, 1).text,
          '~~a~~');
      final r = EditorFormat.apply(FormatCommand.highlight, '~~a~~', 2, 3);
      expect(r.text, '~~==a==~~', reason: '高亮不吞掉既有删除线标记');
    });

    test('BR-31.7：无选区时不插入占位标记，正本原样不变', () {
      const src = '重点内容';
      final r = EditorFormat.apply(FormatCommand.highlight, src, 2, 2);
      expect(r.text, src, reason: '纯光标点高亮不应插入 ==== 占位');
      expect(r.selectionStart, 2);
      expect(r.selectionEnd, 2);
    });

    test('clearFormat 移除高亮，但不识别语法原样透传', () {
      expect(
          EditorFormat.apply(FormatCommand.clearFormat, 'a ==b== c', 0, 9).text,
          'a b c');
      expect(
          EditorFormat.apply(FormatCommand.clearFormat, 'a =b= c', 0, 7).text,
          'a =b= c',
          reason: '单个 = 非高亮语法，应逐字透传');
    });

    test('未识别语法在施加其它指令时原样保留', () {
      const src = '| a | b |\n脚注[^1] ==重点==';
      final r = EditorFormat.apply(FormatCommand.bold, src, 0, 0);
      expect(r.text, '****$src', reason: '仅在光标处插入标记对，其余逐字不变');
    });
  });

  group('BlockUnitBehavior（块级呈现单元空块交互，§11.2 / AC-92）', () {
    test('空列表项回车退出列表（移除标记，留在空行）', () {
      final r = EditorFormat.blockNewline('- ', 2)!;
      expect(r.text, '');
      expect(r.selectionStart, 0);

      final mid = EditorFormat.blockNewline('前文\n- \n后文', 5)!;
      expect(mid.text, '前文\n\n后文');
      expect(mid.selectionStart, 3, reason: '光标回到空行行首');

      expect(EditorFormat.blockNewline('* ', 2)!.text, '');
      expect(EditorFormat.blockNewline('+ ', 2)!.text, '');
    });

    test('任务项回车续行（新建未勾选任务，空 / 含文本均可）', () {
      final r = EditorFormat.blockNewline('- [ ] 买牛奶', 9)!;
      expect(r.text, '- [ ] 买牛奶\n- [ ] ');
      expect(r.selectionStart, r.text.length);

      final empty = EditorFormat.blockNewline('- [x]', 5)!;
      expect(empty.text, '- [x]\n- [ ] ');
    });

    test('缩进任务项续行保持缩进', () {
      final r = EditorFormat.blockNewline('  - [ ] t', 9)!;
      expect(r.text, '  - [ ] t\n  - [ ] ');
    });

    test('空引用行回车退出引用（移除标记）', () {
      expect(EditorFormat.blockNewline('> ', 2)!.text, '');
      expect(EditorFormat.blockNewline('>', 1)!.text, '');
    });

    test('行中 / 普通段落 / 非空列表项回车交由默认行为（返回 null）', () {
      expect(EditorFormat.blockNewline('- abc', 2), isNull, reason: '行中不上抛');
      expect(EditorFormat.blockNewline('普通段落', 4), isNull);
      expect(EditorFormat.blockNewline('- 有内容的列表项', 9), isNull);
    });

    test('空块交互不产生多余保存语义（仅改标记，其余逐字不动）', () {
      const src = '- \n后文';
      final r = EditorFormat.blockNewline(src, 2)!;
      expect(r.text, '\n后文', reason: '仅移除当前行标记');
    });
  });

  // -------------------------------------------------------------------------
  // M9 / FR-44~FR-48（editor-formatting.md §12 / AC-138~AC-155）
  // -------------------------------------------------------------------------

  group('TableInsertCustomSize（FR-44 / §12.1 / AC-138）', () {
    test('插入 3×2 空表：表头行 + 分隔行 +（行−1）空数据行，光标落首个表头单元格', () {
      final r = EditorFormat.insertTable('', 0, 0, rows: 3, columns: 2);
      expect(r.text, '|  |  |\n| --- | --- |\n|  |  |\n|  |  |\n');
      expect(r.selectionStart, 2, reason: '光标落在首个表头单元格 `| ` 之后');
      expect(r.selectionEnd, 2);
    });

    test('行列数超限时钳制到边界（行 1~20、列 1~8，BR-44.1）', () {
      final big = EditorFormat.insertTable('', 0, 0, rows: 100, columns: 100);
      final parsed = EditorFormat.parseTable(big.text)!;
      expect(parsed.header.length, EditorFormat.tableMaxColumns);
      expect(parsed.rows.length, EditorFormat.tableMaxRows - 1);
      expect(parsed.wellFormed, isTrue);

      final small = EditorFormat.insertTable('', 0, 0, rows: 0, columns: 0);
      final parsedSmall = EditorFormat.parseTable(small.text)!;
      expect(parsedSmall.header.length, EditorFormat.tableMinColumns);
      expect(parsedSmall.rows, isEmpty, reason: '1 行 = 仅表头，无数据行');
      expect(parsedSmall.wellFormed, isTrue);
    });

    test('插入为独占块：与相邻段落以空行分隔', () {
      final r = EditorFormat.insertTable('前文', 2, 2, rows: 2, columns: 2);
      expect(r.text, '前文\n\n|  |  |\n| --- | --- |\n|  |  |\n');
      expect(r.selectionStart, 6);
    });
  });

  group('TableStructureEdit（FR-44 / §12.1 / AC-139）', () {
    const src = '| a | b |\n| --- | --- |\n| 1 | 2 |';

    test('解析：表头 / 对齐 / 数据行与合规标记', () {
      final t = EditorFormat.parseTable(src)!;
      expect(t.start, 0);
      expect(t.end, src.length);
      expect(t.header, ['a', 'b']);
      expect(t.aligns, [TableColumnAlign.none, TableColumnAlign.none]);
      expect(t.rows, [
        ['1', '2']
      ]);
      expect(t.wellFormed, isTrue);
    });

    test('设置列对齐仅重写分隔行，其余单元格逐字不动', () {
      final t = EditorFormat.parseTable(src)!;
      final out =
          EditorFormat.setTableAlignment(src, t, 1, TableColumnAlign.center);
      expect(out, '| a | b |\n| --- | :---: |\n| 1 | 2 |');
    });

    test('列对齐四种标记：none / left / center / right', () {
      final t = EditorFormat.parseTable(src)!;
      expect(EditorFormat.setTableAlignment(src, t, 0, TableColumnAlign.left),
          '| a | b |\n| :--- | --- |\n| 1 | 2 |');
      expect(EditorFormat.setTableAlignment(src, t, 0, TableColumnAlign.right),
          '| a | b |\n| ---: | --- |\n| 1 | 2 |');
      expect(EditorFormat.setTableAlignment(src, t, 0, TableColumnAlign.none),
          src, reason: '未改变时逐字等同');
    });

    test('增列：表头 / 分隔 / 数据行同步补齐，列数一致', () {
      final t = EditorFormat.parseTable(src)!;
      final out = EditorFormat.addTableColumn(src, t, after: 0);
      expect(out, '| a |  | b |\n| --- | --- | --- |\n| 1 |  | 2 |');
      final reparsed = EditorFormat.parseTable(out)!;
      expect(reparsed.wellFormed, isTrue);
      expect(reparsed.header.length, 3);
    });

    test('删列：同步裁剪，保留至少一列', () {
      final t = EditorFormat.parseTable(src)!;
      final out = EditorFormat.removeTableColumn(src, t, 0);
      expect(out, '| b |\n| --- |\n| 2 |');
      final single = EditorFormat.parseTable(out)!;
      expect(EditorFormat.removeTableColumn(out, single, 0), out,
          reason: '仅剩一列时再删为无操作');
    });

    test('增行：末尾追加空数据行', () {
      final t = EditorFormat.parseTable(src)!;
      final out = EditorFormat.addTableRow(src, t);
      expect(out, '$src\n|  |  |');
      expect(EditorFormat.parseTable(out)!.wellFormed, isTrue);
    });

    test('删行：移除指定数据行且不残留空行', () {
      final t = EditorFormat.parseTable(src)!;
      final out = EditorFormat.removeTableRow(src, t, 0);
      expect(out, '| a | b |\n| --- | --- |');
    });

    test('指定行上/下插入空行：结构合法且其余行逐字不动', () {
      const two = '| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |';

      final above = EditorFormat.insertTableRow(two, EditorFormat.parseTable(two)!,
          1); // 在第 2 个数据行（3|4）上方
      expect(above, '| a | b |\n| --- | --- |\n| 1 | 2 |\n|  |  |\n| 3 | 4 |');

      final below = EditorFormat.insertTableRow(
          two, EditorFormat.parseTable(two)!, 0,
          after: true); // 在第 1 个数据行（1|2）下方
      expect(below, '| a | b |\n| --- | --- |\n| 1 | 2 |\n|  |  |\n| 3 | 4 |');

      expect(EditorFormat.parseTable(above)!.wellFormed, isTrue);
      expect(EditorFormat.parseTable(below)!.wellFormed, isTrue);
    });

    test('末尾之后插入空行等价于追加', () {
      final t = EditorFormat.parseTable(src)!;
      final out = EditorFormat.insertTableRow(src, t, 5, after: true);
      expect(out, '$src\n|  |  |');
    });

    test('就地改写单元格：其余单元格逐字不动（写入先转义）', () {
      final t = EditorFormat.parseTable(src)!;
      expect(EditorFormat.setTableCell(src, t, 0, 0, 'x'),
          '| a | b |\n| --- | --- |\n| x | 2 |');
      expect(EditorFormat.setTableCell(src, t, -1, 1, 'h'),
          '| a | h |\n| --- | --- |\n| 1 | 2 |',
          reason: 'rowIndex < 0 表示表头行');
      final esc = EditorFormat.setTableCell(src, t, 0, 0, 'a|b');
      expect(esc, '| a | b |\n| --- | --- |\n| a\\|b | 2 |');
      final reparsed = EditorFormat.parseTable(esc)!;
      expect(reparsed.rows.first, [r'a\|b', '2'],
          reason: '转义后的竖线不被拆列，回读仍为同一单元格');
      expect(reparsed.wellFormed, isTrue);
    });

    test('单元格行 / 列越界时原样返回', () {
      final t = EditorFormat.parseTable(src)!;
      expect(EditorFormat.setTableCell(src, t, 9, 0, 'x'), src);
      expect(EditorFormat.setTableCell(src, t, 0, 9, 'x'), src);
    });

    test('单元格转义：`|` → `\\|`，已转义不重复（BR-44.4）', () {
      expect(EditorFormat.escapeTableCell('a|b'), r'a\|b');
      expect(EditorFormat.escapeTableCell(r'a\|b'), r'a\|b');
      const escaped = '| a\\|b | c |\n| --- | --- |\n| 1 | 2 |';
      final t = EditorFormat.parseTable(escaped)!;
      expect(t.header, [r'a\|b', 'c'], reason: '转义竖线不被拆列为单元格');
      expect(t.wellFormed, isTrue);
    });
  });

  group('TableRenderDegrade（FR-44 / §12.1 / AC-140）', () {
    test('无分隔行：尽力解析为表头 + 数据行，wellFormed=false', () {
      final t = EditorFormat.parseTable('| a | b |\n| 1 | 2 |')!;
      expect(t.header, ['a', 'b']);
      expect(t.rows, [
        ['1', '2']
      ]);
      expect(t.wellFormed, isFalse, reason: '缺分隔行，降级呈现但不丢内容');
    });

    test('列数不齐：保留全部单元格、不丢内容、wellFormed=false', () {
      final t = EditorFormat.parseTable('| a | b |\n| --- | --- |\n| 1 |')!;
      expect(t.wellFormed, isFalse);
      expect(t.rows.first, ['1'], reason: '残缺行内容仍完整保留');
    });

    test('不含竖线的普通段落返回 null（降级为正文）', () {
      expect(EditorFormat.parseTable('普通段落'), isNull);
      expect(EditorFormat.parseTable(''), isNull);
    });
  });

  group('LineRangeSimplifyFormat（FR-45 / §12.3 / AC-143 / AC-144）', () {
    const src = '第一行\n第二行\n第三行';

    test('划行套用无序列表：整块加前缀，再点整块去除（逐字不丢）', () {
      final r1 =
          EditorFormat.apply(FormatCommand.bulletList, src, 0, src.length);
      expect(r1.text, '- 第一行\n- 第二行\n- 第三行');
      final r2 = EditorFormat.apply(
          FormatCommand.bulletList, r1.text, 0, r1.text.length);
      expect(r2.text, src, reason: '再次点击整块还原');
    });

    test('划行套用有序列表（惰性 1.）与去除', () {
      final r1 =
          EditorFormat.apply(FormatCommand.orderedList, src, 0, src.length);
      expect(r1.text, '1. 第一行\n1. 第二行\n1. 第三行');
      final r2 = EditorFormat.apply(
          FormatCommand.orderedList, r1.text, 0, r1.text.length);
      expect(r2.text, src);
    });

    test('划行套用引用与去除', () {
      final r1 =
          EditorFormat.apply(FormatCommand.blockquote, src, 0, src.length);
      expect(r1.text, '> 第一行\n> 第二行\n> 第三行');
      final r2 = EditorFormat.apply(
          FormatCommand.blockquote, r1.text, 0, r1.text.length);
      expect(r2.text, src);
    });

    test('划行套用代码块围栏与去除，内容逐字保留', () {
      final r1 =
          EditorFormat.apply(FormatCommand.codeBlock, src, 0, src.length);
      expect(r1.text, '```\n$src\n```');
      final r2 = EditorFormat.apply(
          FormatCommand.codeBlock, r1.text, 0, r1.text.length);
      expect(r2.text, src);
    });

    test('简化格式：去除行内加粗 / 斜体 / 删除线 / 高亮 / 代码标记', () {
      const rich = '**a** *b* ~~c~~ ==d== `e`';
      expect(
        EditorFormat.apply(FormatCommand.clearFormat, rich, 0, rich.length).text,
        'a b c d e',
      );
    });
  });

  group('OrderedListLazyNumbering（FR-48 / §12.5 / AC-152~AC-154）', () {
    test('连续有序列表按序编号（正本统一写 1.）', () {
      expect(EditorFormat.orderedListNumbers('1. a\n1. b\n1. c'), [1, 2, 3]);
    });

    test('插入 / 删除项后天然重排（只读正本，零改写）', () {
      const src = '1. a\n1. b\n1. c';
      expect(EditorFormat.orderedListNumbers(src), [1, 2, 3]);
      expect(EditorFormat.orderedListNumbers('1. a\n1. c'), [1, 2],
          reason: '删除第二项后重新计算编号');
      expect(src, '1. a\n1. b\n1. c', reason: '正本内容保持不变');
    });

    test('空行 / 非列表行隔断后重新从 1 开始', () {
      expect(
        EditorFormat.orderedListNumbers('1. a\n1. b\n\n1. c'),
        [1, 2, null, 1],
      );
      expect(
        EditorFormat.orderedListNumbers('1. a\n普通段落\n1. b'),
        [1, null, 1],
      );
    });

    test('缩进续行不打断编号', () {
      expect(
        EditorFormat.orderedListNumbers('1. a\n  续行\n1. b'),
        [1, null, 2],
      );
    });

    test('显式起始值优先，并按其递增（BR-48.4）', () {
      expect(EditorFormat.orderedListNumbers('3. a\n1. b\n1. c'), [3, 4, 5]);
    });

    test('非有序列表行给出 null', () {
      expect(EditorFormat.orderedListNumbers('- a\n> b'), [null, null]);
    });
  });

  group('AttachmentAtomicDelete（FR-46 / §12.4 / AC-145 / AC-146）', () {
    const img = '![p](sui://abc123)';
    const link = '[doc](sui://def456)';

    test('识别图片与链接两种形态及 sha256', () {
      final refs = EditorFormat.attachmentRefs('$img\n$link');
      expect(refs.length, 2);
      expect(refs[0].isImage, isTrue);
      expect(refs[0].sha256, 'abc123');
      expect(refs[0].label, 'p');
      expect(refs[1].isImage, isFalse);
      expect(refs[1].sha256, 'def456');
      expect(refs[1].label, 'doc');
    });

    test('图片引用连同紧随的尺寸属性块并入原子块', () {
      final refs = EditorFormat.attachmentRefs('$img{width=320}');
      expect(refs.single.end, '$img{width=320}'.length);
    });

    test('退格落在引用末尾 / Delete 落在起点 / 引用内部 → 整块命中', () {
      const text = '前$img后';
      final start = 1;
      final end = 1 + img.length;
      expect(
        EditorFormat.attachmentRefForDeletion(text, end, backspace: true)!
            .sha256,
        'abc123',
      );
      expect(
        EditorFormat.attachmentRefForDeletion(text, start, backspace: false)!
            .sha256,
        'abc123',
      );
      expect(
        EditorFormat.attachmentRefForDeletion(text, start + 3, backspace: true),
        isNotNull,
        reason: '引用内部删除也按整块处理（BR-46.1）',
      );
    });

    test('整块删除：行内引用仅删引用本身，其余逐字不动', () {
      const text = '前$img后';
      final ref = EditorFormat.attachmentRefs(text).single;
      final r = EditorFormat.deleteAttachmentRef(text, ref);
      expect(r.text, '前后');
      expect(r.selectionStart, 1);
    });

    test('整块删除：独占整行的引用连同换行一并移除，无残留空行', () {
      const text = '正文\n$img\n后续';
      final ref = EditorFormat.attachmentRefs(text).single;
      final r = EditorFormat.deleteAttachmentRef(text, ref);
      expect(r.text, '正文\n后续');
    });

    test('一次编辑即整块删除（单次可撤销，AC-146）', () {
      const text = '前$img后';
      final ref = EditorFormat.attachmentRefs(text).single;
      final r = EditorFormat.deleteAttachmentRef(text, ref);
      expect(text.length - r.text.length, img.length,
          reason: '删除长度等于整个引用，即一次原子操作');
    });
  });

  group('AttachmentCorruptSelfHeal（FR-46 / §12.4 / AC-147）', () {
    test('残缺引用（缺 `)`）仍被整块识别', () {
      final refs = EditorFormat.attachmentRefs('![p](sui://abc123');
      expect(refs.single.corrupt, isTrue);
      expect(refs.single.sha256, 'abc123');
    });

    test('残缺自愈：补上闭合括号，其余逐字不动', () {
      const corruptText = '前![p](sui://abc123后';
      final ref = EditorFormat.attachmentRefs(corruptText).single;
      expect(ref.corrupt, isTrue);
      final r = EditorFormat.repairAttachmentRef(corruptText, ref);
      expect(r.text, '前![p](sui://abc123)后');
    });

    test('非残缺引用调用自愈为无操作', () {
      const good = '![p](sui://abc123)';
      final ref = EditorFormat.attachmentRefs(good).single;
      expect(ref.corrupt, isFalse);
      expect(EditorFormat.repairAttachmentRef(good, ref).text, good);
    });
  });
}

/// 统计两个等长字符串在同一位置的差异字符数（不等长返回 -1）。
int _diffCount(String a, String b) {
  if (a.length != b.length) return -1;
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) n++;
  }
  return n;
}
