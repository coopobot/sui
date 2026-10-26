/// 网页快照的受限内嵌 HTML（FR-69 / editor-formatting.md §16.3）。
///
/// 覆盖：HTML 块的**定位**（单行 / 多行 / 多块 / 无块）、白名单化解析（标签 / 样式 /
/// 属性三级收口、非法内容丢弃但不丢文本）、以及**原子删除**（整块删除、不与相邻行合并）。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('HtmlBlockScan（正本中的 HTML 块定位 / BR-69.4）', () {
    test('单行 div 块被识别，区间覆盖整行且 end 指向行尾换行', () {
      const text = '前文\n\n<div style="text-align:center">居中</div>\n\n后文\n';
      final blocks = htmlBlocks(text);
      expect(blocks.length, 1);
      final b = blocks.single;
      expect(text.substring(b.start, b.end),
          '<div style="text-align:center">居中</div>');
      expect(text[b.end], '\n');
    });

    test('多块按出现顺序返回；纯 Markdown 文本没有块', () {
      const text = '<p style="color:#c00">一</p>\n\n普通段落\n\n'
          '<div style="text-align:center"><img src="sui://aa"></div>\n';
      final blocks = htmlBlocks(text);
      expect(blocks.length, 2);
      expect(blocks.first.html, contains('color:#c00'));
      expect(blocks.last.html, contains('sui://aa'));
      expect(htmlBlocks('只有 Markdown 的正本\n\n- 列表\n'), isEmpty);
    });

    test('多行 HTML 块（闭合标签在下一行）也能整块识别', () {
      const text = '<div style="text-align:center">\n正文\n</div>\n后文';
      final blocks = htmlBlocks(text);
      expect(blocks.length, 1);
      expect(blocks.single.html, contains('正文'));
      expect(blocks.single.html, contains('</div>'));
    });

    test('htmlBlockAt：块内与块下方默认行首命中，块外不命中', () {
      const text = 'x\n\n<div style="color:#c00">y</div>\n\nz';
      final b = htmlBlocks(text).single;
      expect(htmlBlockAt(text, b.start), isNotNull);
      expect(htmlBlockAt(text, b.start + 3), isNotNull);
      expect(htmlBlockAt(text, b.end + 1), isNotNull);
      expect(htmlBlockAt(text, 0), isNull);
      expect(htmlBlockAt(text, text.length), isNull);
    });
  });

  group('SnapshotHtmlParse（白名单化 / BR-69.2、BR-69.6）', () {
    test('白名单标签保留，脚本与事件属性 / class / id 一律丢弃', () {
      final root = parseSnapshotHtml(
        '<div style="color:#c00" onclick="alert(1)" class="x" id="y">'
        '<b>粗</b><script>alert(2)</script></div>',
      );
      expect(root.children.length, 1);
      final div = root.children.single as SnapshotElement;
      expect(div.tag, 'div');
      expect(div.styles['color'], '#c00');
      expect(div.attributes.containsKey('onclick'), isFalse);
      expect(div.attributes.containsKey('class'), isFalse);
      expect(div.attributes.containsKey('id'), isFalse);
      expect(div.effectiveStyles['color'], '#c00');
      // 脚本内容不进树（文本也不留：script 属非内容节点）。
      final json = _dump(root);
      expect(json.contains('alert'), isFalse);
      expect(json, contains('粗'));
    });

    test('样式白名单：非法值与非白名单属性丢弃', () {
      final root = parseSnapshotHtml(
        '<p style="background-color:yellow;position:absolute;'
        'font-size:20px;color:rgb(1,2,3)">x</p>',
      );
      final p = root.children.single as SnapshotElement;
      expect(p.styles['background-color'], 'yellow');
      expect(p.styles['font-size'], '20px');
      expect(p.styles.containsKey('position'), isFalse);
      expect(p.styles.containsKey('color'), isFalse); // rgb() 不在白名单值形态内
    });

    test('语义标签折算为呈现样式（b / i / u / s / mark）', () {
      final root = parseSnapshotHtml('<div><b>x</b><u>y</u><s>z</s></div>');
      final div = root.children.single as SnapshotElement;
      expect((div.children[0] as SnapshotElement).effectiveStyles['font-weight'],
          'bold');
      expect((div.children[1] as SnapshotElement).effectiveStyles['text-decoration'],
          'underline');
      expect((div.children[2] as SnapshotElement).effectiveStyles['text-decoration'],
          'line-through');
    });

    test('非白名单元素透明（保留文本，不保留元素）', () {
      final root = parseSnapshotHtml('<custom-tag>保留我</custom-tag>');
      final text = _dump(root);
      expect(text, contains('保留我'));
      expect(text.contains('custom-tag'), isFalse);
    });
  });

  group('HtmlBlockAtomicDelete（整块删除 / BR-69.3）', () {
    const text = '前文\n\n<div style="color:#c00">x</div>\n\n后文\n';

    test('退格命中块下方默认行首 → 整块连同块尾换行一并删除', () {
      final b = htmlBlocks(text).single;
      final hit = EditorFormat.htmlBlockForDeletion(text, b.end + 1,
          backspace: true);
      expect(hit, isNotNull);
      final r = EditorFormat.deleteHtmlBlock(text, hit!);
      expect(r.text, '前文\n\n后文\n');
    });

    test('块外的退格不命中（交由普通删除）', () {
      expect(EditorFormat.htmlBlockForDeletion(text, 1, backspace: true), isNull);
    });

    test('structuralDelete 命中块内字符时整块删除（不逐字符咬坏标签）', () {
      final b = htmlBlocks(text).single;
      final r = EditorFormat.structuralDelete(
        text,
        b.start + 6,
        b.start + 6,
        backspace: true,
      );
      expect(r, isNotNull);
      expect(r!.text.contains('<div'), isFalse);
    });
  });
}

/// 把节点树压成字符串，便于断言「内容在 / 不在」。
String _dump(SnapshotNode node) {
  if (node is SnapshotText) return node.text;
  if (node is SnapshotElement) {
    final inner = node.children.map(_dump).join();
    final attrs = node.attributes.entries.map((e) => '${e.key}=${e.value}').join(' ');
    return '<${node.tag} $attrs>$inner</${node.tag}>';
  }
  return '';
}
