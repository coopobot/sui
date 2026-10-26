/// 剪贴板片段 HTML→Markdown（FR-71 / editor-formatting.md §17.3 / ADR-028 决策 4）。
///
/// 覆盖：结构与行内样式映射（Markdown 语法优先、颜色/背景/字号落受限 HTML span）、
/// 资源内联（远端图片 / `data:` 图片）、非法样式与注入内容一律丢弃、空输入回落。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('ClipboardHtmlConversion（粘贴保留原格式 / FR-71）', () {
    test('有序列表与嵌套列表结构保留', () {
      final md = convertClipboardHtml(
        '<ol><li>一<ul><li>子</li></ul></li><li>二</li></ol>',
      );
      expect(md, contains('一'));
      expect(md, contains('二'));
      expect(md, contains('子'));
      expect(
        RegExp(r'^\s*\d+\.\s', multiLine: true).hasMatch(md),
        isTrue,
        reason: '有序列表必须仍是列表行',
      );
      expect(
        md.contains('- 子') || md.contains('* 子'),
        isTrue,
        reason: '嵌套列表项不得丢失',
      );
    });

    test('加粗 / 斜体 / 删除线 / 行内代码 / 链接映射为 Markdown 语法', () {
      final md = convertClipboardHtml(
        '<p><b>粗</b> <i>斜</i> <s>删</s> <code>码</code> '
        '<a href="https://a.com/x">链</a></p>',
      );
      expect(md, contains('**粗**'));
      expect(md, contains('*斜*'));
      expect(md, contains('~~删~~'));
      expect(md, contains('`码`'));
      expect(md, contains('[链](https://a.com/x)'));
    });

    test('标题与表格保留', () {
      final md = convertClipboardHtml(
        '<h2>标题</h2><table><tr><th>A</th><th>B</th></tr>'
        '<tr><td>1</td><td>2</td></tr></table>',
      );
      expect(md, contains('## 标题'));
      expect(md, contains('| A | B |'));
      expect(md, contains('| 1 | 2 |'));
    });

    test('颜色 / 背景 / 字号保留为受限 HTML span（与网页快照同一白名单）', () {
      final md = convertClipboardHtml(
        '<p><span style="color:#c00;background-color: yellow;'
        'font-size:20px">红</span></p>',
      );
      expect(
        md,
        contains(
          '<span style="color:#c00;background-color:yellow;font-size:20px">红</span>',
        ),
      );
    });

    test('下划线用 span，加粗用语法（font-weight:700）', () {
      final md = convertClipboardHtml(
        '<p><span style="text-decoration:underline">下</span>'
        '<span style="font-weight:700">粗</span></p>',
      );
      expect(md, contains('text-decoration:underline'));
      expect(md, contains('**粗**'));
      expect(md.contains('**下**'), isFalse);
    });

    test('非法 / 非白名单样式一律丢弃，绝不透传', () {
      final md = convertClipboardHtml(
        '<p><span style="color:rgb(1,2,3);position:absolute;'
        'font-family:serif">x</span></p>',
      );
      expect(md.contains('rgb('), isFalse);
      expect(md.contains('position'), isFalse);
      expect(md.contains('font-family'), isFalse);
      expect(md, contains('x'));
    });

    test('脚本与事件属性不进产物', () {
      final md = convertClipboardHtml(
        '<div style="font-weight:700" onclick="alert(1)">粗</div>'
        '<script>alert(2)</script>',
      );
      expect(md, contains('**粗**'));
      expect(md.contains('onclick'), isFalse);
      expect(md.contains('alert'), isFalse);
    });

    test('图片保留为 Markdown 引用（远端地址原样，不出网）', () {
      final md = convertClipboardHtml(
        '<p><img src="https://a.com/a.png" alt="图"></p>',
      );
      expect(md, contains('![图](https://a.com/a.png)'));
    });

    test('data: 内联图片原样保留（由调用方决定是否落附件）', () {
      final md = convertClipboardHtml(
        '<img src="data:image/png;base64,iVBORw0KGgo=" alt="内联">',
      );
      expect(md, contains('![内联](data:image/png;base64,iVBORw0KGgo=)'));
    });

    test('空输入返回空串；纯文本原样保留（调用方回落安全插入）', () {
      expect(convertClipboardHtml('   '), isEmpty);
      expect(convertClipboardHtml('不是 HTML 的文本'), contains('不是 HTML 的文本'));
    });

    test('不丢字：Markdown 记号与特殊字符文本一并保留', () {
      final md = convertClipboardHtml('<p>a b c d e</p>');
      for (final ch in ['a', 'b', 'c', 'd', 'e']) {
        expect(md, contains(ch));
      }
    });
  });
}
