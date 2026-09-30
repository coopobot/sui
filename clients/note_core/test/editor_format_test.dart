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
