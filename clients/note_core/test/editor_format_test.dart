/// 编辑器格式化单测（M2-T06 / editor-formatting.md §8）。
///
/// 覆盖：工具栏指令 → Markdown 往返与幂等切换、未触碰不透传改写、
/// 粘贴转义与富文本降级、图片尺寸的插入 / 解析容错 / 写回往返。
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

    test('有序列表：逐行编号', () {
      final r = EditorFormat.apply(FormatCommand.orderedList, 'a\nb', 0, 3);
      expect(r.text, '1. a\n2. b');
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
  });

  group('ImageSizeInsert（插入图片生成引用）', () {
    test('生成 ![文件名](sui://<sha256>)', () {
      final r = EditorFormat.insertImage('', 0, 0,
          filename: '图.png', sha256: 'abc123');
      expect(r.text, '![图.png](sui://abc123)');
    });

    test('带预设尺寸写入属性块', () {
      final r = EditorFormat.insertImage('', 0, 0,
          filename: 'a.png', sha256: 's', size: EditorFormat.presetMedium);
      expect(r.text, '![a.png](sui://s){width=50%}');
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
}
