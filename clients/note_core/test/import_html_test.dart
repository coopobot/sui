import 'dart:convert';
import 'dart:typed_data';

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M13 HTML→Markdown 转换器单测（详细设计 §13 测试矩阵 / §6 规则表）。
///
/// 覆盖：AC-243（HTML 结构与印象笔记结构）、AC-244（脏结构）、AC-245/246/248/249（资源）、
/// AC-247（远端保持 URL）、AC-250（尺寸）、AC-258（单页多笔记）、AC-259（索引页）。
void main() {
  HtmlConversionResult convert(String html, {String file = 'a.html'}) =>
      convertHtmlDocument(Uint8List.fromList(utf8.encode(html)), file);

  String mdOf(String html, {String file = 'a.html'}) {
    final r = convert(html, file: file);
    expect(r.documents, isNotEmpty, reason: '应至少有 1 篇');
    return r.documents.first.markdown;
  }

  // -------------------------------------------------------------------------
  group('块级结构（§6.3 / AC-243）', () {
    test('h1~h6 → #~###### + 前后空行', () {
      // 首个 h1 与标题同文 → 按 §6.10 去重（防双标题），其余标题层级保留。
      expect(
        mdOf('<h1>一</h1><h2>二</h2><h3>三</h3><h4>四</h4><h5>五</h5><h6>六</h6>'),
        '## 二\n\n### 三\n\n#### 四\n\n##### 五\n\n###### 六\n',
      );
      // 首个 h1 与标题**不同文**时保留（此处标题由 meta 给出）。
      expect(
        mdOf('<meta itemprop="title" content="元数据标题">'
            '<h1>页面大标题</h1><h2>副标题</h2>'),
        '# 页面大标题\n\n## 副标题\n',
      );
    });

    test('p 段间恰好一个空行；连续段落不产生多余空行', () {
      expect(mdOf('<p>a</p><p>b</p><p>c</p>'), 'a\n\nb\n\nc\n');
    });

    test('仅含 <br> 的 div.para → 一个空行（印象笔记空行形态）', () {
      expect(
        mdOf('<div class="para">一</div><div class="para"><br></div>'
            '<div class="para">二</div>'),
        '一\n\n二\n',
      );
    });

    test('含块级子元素的 div → 透明（不产生空段包装）', () {
      expect(
        mdOf('<div><p>a</p><div><p>b</p></div></div>'),
        'a\n\nb\n',
      );
    });

    test('未知自定义标签 → 透明（保留文本，不丢字）', () {
      expect(mdOf('<my-widget>自定义<strong>内容</strong></my-widget>'),
          '自定义\\*\\*内容\\*\\*\n');
    });

    test('hr → ---', () {
      expect(mdOf('<p>a</p><hr><p>b</p>'), 'a\n\n---\n\nb\n');
    });

    test('段落内 br → 真换行（不用行尾双空格、不写 <br>）', () {
      // 正本约定：段落内软换行就是换行本身（与 Shift+Enter / 粘贴链路一致）；
      // 写 `<br>` 会让格式模式露出字面量标签（`v0.13.1` 缺陷修复）。
      expect(mdOf('<p>a<br>b</p>'), 'a\nb\n');
      expect(mdOf('<p>a<br>b</p>'), isNot(contains('  \n')));
      expect(mdOf('<p>a<br>b</p>'), isNot(contains('<br>')));
    });

    test('blockquote → > 前缀；嵌套累加 > >', () {
      expect(mdOf('<blockquote><p>q1</p><p>q2</p></blockquote>'),
          '> q1\n\n> q2\n');
      expect(mdOf('<blockquote><blockquote><p>q</p></blockquote></blockquote>'),
          '> > q\n');
    });

    test('pre / pre>code → 围栏代码块；language-xxx 取语言', () {
      expect(
        mdOf('<pre><code class="language-dart">void main() {\n  x();\n}'
            '</code></pre>'),
        '```dart\nvoid main() {\n  x();\n}\n```\n',
      );
      expect(mdOf('<pre>裸代码</pre>'), '```\n裸代码\n```\n');
    });

    test('代码块内容含 ``` 行 → 改用 ~~~', () {
      final md = mdOf('<pre><code>```\ninner\n```</code></pre>');
      expect(md, startsWith('~~~\n'));
      expect(md, contains('```\ninner\n```'));
      expect(md, endsWith('~~~\n'));
    });

    test('代码块内容不折叠空白、不转义', () {
      expect(
        mdOf('<pre><code>a  *b*  [c]</code></pre>'),
        '```\na  *b*  [c]\n```\n',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('行内结构（§6.4 / AC-243）', () {
    test('strong/b → **；em/i → *；s/del/strike → ~~；u 透明保文本', () {
      expect(
        mdOf('<p>行 <strong>a</strong><b>b</b><em>c</em><i>d</i><s>e</s>'
            '<del>f</del><strike>g</strike><u>h</u></p>'),
        '行 \\*\\*a\\*\\*\\*\\*b\\*\\*\\*c\\*\\*d\\*~~e~~~~f~~~~g~~h\n',
      );
      // 行首是 `**` 时按 §6.11 转义首个可见字符（避免被预览当成强调 / 列表起始）。
      expect(mdOf('<p><strong>b</strong> x</p>'), '\\*\\*b\\*\\* x\n');
    });

    test('code（不在 pre 内）→ 反引号；内容含反引号时加长围栏', () {
      expect(mdOf('<p>x <code>c</code> y</p>'), 'x `c` y\n');
      expect(mdOf('<p>x <code>a`b</code> y</p>'), 'x ``a`b`` y\n');
      expect(mdOf('<p>x <code>a*b</code> y</p>'), 'x `a*b` y\n',
          reason: '代码片段内的 `*` 是字面字符，不得转义');
    });

    test('sup/sub/font/mark/small/abbr 等 → 透明（无法映射，不做）', () {
      expect(
        mdOf('<p>a<sup>1</sup><sub>2</sub><font color="red">3</font>'
            '<mark>4</mark><small>5</small><abbr title="t">6</abbr></p>'),
        'a123456\n',
      );
    });

    test('实体由解析器解码（&nbsp; → 空格、&#39; → 撇号）', () {
      expect(mdOf('<p>a&nbsp;b&#39;c&amp;d&lt;e&gt;f</p>'), "a b'c&d<e>f\n");
    });
  });

  // -------------------------------------------------------------------------
  group('列表与任务列表（§6.6 / AC-243）', () {
    test('ul → - ；ol → 1. 2. 且 start 生效', () {
      expect(mdOf('<ul><li>a</li><li>b</li></ul>'), '- a\n- b\n');
      // 自产列表标记**不做行首转义**：`<ol>` 就是有序列表，写成 `1. `（渲染为编号项）；
      // 写成 `1\. ` 会退化成字面文本，且格式模式会露出反斜杠（`v0.13.5` 缺陷修复）。
      expect(mdOf('<ol><li>a</li><li>b</li></ol>'), '1. a\n2. b\n');
      expect(mdOf('<ol start="3"><li>a</li><li>b</li></ol>'), '3. a\n4. b\n');
    });

    test('标题副本去重后，有序列表项仍不被转义（行号集合随之平移，`v0.13.5`）', () {
      // `<h1>` 与 `<title>` 同文会被 §6.10 去重（**删除该行**）→ 所有按行号记账的集合必须同步
      // 前移，否则每组列表的**首项**会错位，仍被写成 `1\. …`（用户报障的残留形态）。
      expect(
        mdOf('<html><head><title>标题</title></head><body>'
            '<h1>标题</h1><ol><li>甲</li><li>乙</li></ol></body></html>'),
        '1. 甲\n2. 乙\n',
      );
    });

    test('非法嵌套：`<ol>` 里的兄弟 `<ul>` 归入前一个 `<li>`（不得整段丢弃）', () {
      // 网页剪藏常见：`<ol><li>a</li><ul><li>细节</li></ul><li>b</li></ol>`（`<ul>` 是 `<li>` 的
      // **兄弟**）。不归一化时 `_renderList` 只取 `li` 子元素 → 兄弟列表被整段丢弃（实测丢过 71%）。
      final md = mdOf('<ol><li>甲</li><ul><li>细节1</li><li>细节2</li></ul>'
          '<li>乙</li></ol>');
      expect(md, contains('1. 甲'));
      expect(md, contains('2. 乙'));
      expect(md, contains('细节1'));
      expect(md, contains('细节2'));
      expect(md.contains('1\\.'), isFalse);
    });

    test('印象笔记导出形态：`<ol><li><div><span>` 不得被转义成 `1\\.`', () {
      // 用户实测报障（`v0.13.5`）：导出里 `<li>` 内容是 `<div><span>…</span></div>`，
      // 有序列表项被写成 `1\. LiblibAI…`，格式模式下反斜杠原样可见。
      expect(
        mdOf('<ol><li><div><span>甲</span></div></li>'
            '<li><div><span>乙</span></div></li></ol>'),
        '1. 甲\n2. 乙\n',
      );
      expect(
        mdOf('<ol><li><span>一</span></li><li><span>二</span></li></ol>'),
        '1. 一\n2. 二\n',
      );
    });

    test('源文本里手写的编号行按**有序列表项**呈现（不再转义成 `1\\.`，`v0.13.5`）', () {
      // 导出里常见「2. 每月需覆盖的收入」这类手写编号段落：过去转义成 `2\. `，格式模式露出反斜杠。
      expect(mdOf('<p>1. 这是普通一段文字</p>'), '1. 这是普通一段文字\n');
      expect(mdOf('<p>2. 每月需覆盖的收入</p>'), '2. 每月需覆盖的收入\n');
    });

    test('嵌套列表：子项换行并缩进 2 空格', () {
      expect(
        mdOf('<ul><li>a</li><li>b<ul><li>b1<ul><li>b2</li></ul></li></ul></li>'
            '</ul>'),
        '- a\n- b\n\n  - b1\n\n    - b2\n',
      );
    });

    test('多段落 li：后续段落缩进对齐', () {
      expect(
        mdOf('<ul><li><p>p1</p><p>p2</p></li></ul>'),
        '- p1\n  p2\n',
      );
    });

    test('任务列表：input[type=checkbox] + checked / aria-checked', () {
      expect(
        mdOf('<ul><li><input type="checkbox" checked>done</li>'
            '<li><input class="list-bullet-todo" aria-checked="true">aria</li>'
            '<li><input type="checkbox">todo</li></ul>'),
        '- [x] done\n- [x] aria\n- [ ] todo\n',
      );
    });

    test('任务列表：li[data-checked] 形态同样处理', () {
      expect(
        mdOf('<ul><li data-checked="true">one</li>'
            '<li data-checked="false">two</li></ul>'),
        '- [x] one\n- [ ] two\n',
      );
    });

    test('input 元素本身不进正文', () {
      final md = mdOf('<ul><li><input type="checkbox" checked>done</li></ul>');
      expect(md, '- [x] done\n');
      expect(md.contains('input'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('表格（§6.7 / AC-243）', () {
    test('thead 作表头；无 thead 时取第一行；分隔行按 align', () {
      expect(
        mdOf('<table><thead><tr><th align="left">A</th><th>B</th></tr></thead>'
            '<tbody><tr><td>x</td><td>y</td></tr></tbody></table>'),
        '| A | B |\n| :--- | --- |\n| x | y |\n',
      );
      expect(
        mdOf('<table><tr><th>A</th></tr><tr><td>x</td></tr></table>'),
        '| A |\n| --- |\n| x |\n',
      );
    });

    test('style="text-align:…" 也参与对齐映射；列数取最大并补空', () {
      expect(
        mdOf('<table><tr><th style="text-align:right">A</th>'
            '<th align="center">B</th><th>C</th></tr>'
            '<tr><td>1</td><td>2</td><td>3</td><td>4</td></tr></table>'),
        '| A | B | C | |\n| ---: | :---: | --- | --- |\n| 1 | 2 | 3 | 4 |\n',
      );
    });

    test('单元格内 | 转义、换行转 <br>', () {
      expect(
        mdOf('<table><tr><th>A</th></tr>'
            '<tr><td>x|y</td></tr><tr><td>z<br>w</td></tr></table>'),
        '| A |\n| --- |\n| x\\|y |\n| z<br>w |\n',
      );
    });

    test('无 tr 的表格 → 透明保留文本', () {
      expect(mdOf('<table>裸文本</table>'), '裸文本\n');
    });
  });

  // -------------------------------------------------------------------------
  group('脏结构整块丢弃（§6.1 / AC-244）', () {
    test('style / icons / svg / meta / title / link / 注释不进正文', () {
      final md = mdOf('<html><head><title>T</title><meta charset="utf-8">'
          '<style>.x{color:red}</style><link rel="x"></head><body>'
          '<p>正文</p><icons><svg><path d="M0"/></svg></icons>'
          '<!--[if gte mso 9]><p>mso</p><![endif]-->'
          '<note-attributes>x</note-attributes></body></html>');
      expect(md, '正文\n');
      for (final banned in ['color:red', 'mso', 'M0', 'charset']) {
        expect(md.contains(banned), isFalse, reason: '不得含 $banned');
      }
    });

    test('iframe → 降级为链接并保留 src；canvas / foreign-content / 表单保留文本', () {
      final r = convert('<body><p>正文</p>'
          '<iframe src="https://v.example/e"></iframe>'
          '<canvas>画布文字</canvas><foreign-content>外来文字</foreign-content>'
          '<form><button>按钮</button><textarea>输入</textarea></form>'
          '<input type="text" value="v"></body>');
      final md = r.documents.first.markdown;
      expect(md, contains('正文'));
      expect(md, contains('画布文字'));
      expect(md, contains('外来文字'));
      expect(md, contains('按钮'));
      expect(md, contains('输入'));
      final iframe = r.documents.first.resources
          .firstWhere((x) => x.reference == 'https://v.example/e');
      expect(iframe.kind, ImportResourceKind.link);
      expect(iframe.remote, isTrue);
    });

    test('iframe 无 src → 透明（保留其文本），不登记资源', () {
      final r = convert('<body><iframe>框架文字</iframe></body>');
      expect(r.documents.first.resources, isEmpty);
      expect(r.documents.first.markdown, contains('框架文字'));
    });
  });

  // -------------------------------------------------------------------------
  group('资源占位符与分发（§6.9 / AC-245 / AC-246 / AC-248 / AC-249）', () {
    test('图片登记 image 资源并写节点占位符', () {
      final r = convert('<p><img src="img/a.png" alt="图"></p>');
      final doc = r.documents.first;
      expect(doc.resources, hasLength(1));
      final ref = doc.resources.single;
      expect(ref.kind, ImportResourceKind.image);
      expect(ref.reference, 'img/a.png');
      expect(ref.alt, '图');
      expect(ref.remote, isFalse);
      expect(ref.inlineBytes, isNull);
      expect(doc.markdown, '${resourcePlaceholder(0)}\n');
    });

    test('相对路径 basename 支持反斜杠（印象笔记实测形态）', () {
      final r = convert('<p><img src="..\\笔记 files\\image (1).png"></p>');
      expect(r.documents.first.resources.single.suggestedName, 'image (1).png');
    });

    test('data:（base64）现场解码，remote=false', () {
      final r = convert('<p><img src="data:image/png;base64,MTIz" alt="d"></p>');
      final ref = r.documents.first.resources.single;
      expect(ref.inlineBytes, [0x31, 0x32, 0x33]); // "123"
      expect(ref.remote, isFalse);
      expect(ref.suggestedName, 'd.png');
    });

    test('data: 解码失败 → inlineBytes 为 null（服务侧降级，AC-249）', () {
      final r = convert('<p><img src="data:image/png;base64,!!!!" alt="d"></p>');
      expect(r.documents.first.resources.single.inlineBytes, isNull);
    });

    test('远端 http(s) 图片 → remote=true（服务侧保持 URL，不下载）', () {
      final r = convert('<p><img src="https://x.example/y.png" alt="r"></p>');
      expect(r.documents.first.resources.single.remote, isTrue);
    });

    test('mailto / tel / evernote:// / 其它 scheme → remote=true', () {
      for (final url in [
        'mailto:a@b.c',
        'tel:+8613800000000',
        'evernote:///view/1/s1/abc/abc/',
        'ftp://x/y',
      ]) {
        final r = convert('<p><a href="$url">文字</a></p>');
        expect(r.documents.first.resources.single.remote, isTrue, reason: url);
      }
    });

    test('链接登记 link 资源；空 / #锚点 / javascript: → 透明不登记', () {
      final r = convert('<p><a href="sub/doc.pdf">附件</a><a href="#a">锚</a>'
          '<a href="javascript:void(0)">js</a><a>无 href</a></p>');
      final doc = r.documents.first;
      expect(doc.resources, hasLength(1));
      expect(doc.resources.single.reference, 'sub/doc.pdf');
      expect(doc.resources.single.alt, '附件');
      expect(doc.resources.single.kind, ImportResourceKind.link);
      // 未登记的三个链接只保留文字。
      expect(doc.markdown, contains('锚'));
      expect(doc.markdown, contains('js'));
      expect(doc.markdown, contains('无 href'));
    });

    test('无 src 的 img 不登记资源（无文本可留，丢弃）', () {
      final r = convert('<p>a<img>b</p>');
      expect(r.documents.first.resources, isEmpty);
      expect(r.documents.first.markdown, 'ab\n');
    });

    test('非图片附件展示标记（无可用 href）→ 不臆测归属、不计资源（BR-61.12）', () {
      final r = convert('<en-note><div class="para">'
          '<en-media data-resource-hash="abc" data-type="application/pdf">'
          'Untitled Attachment</en-media></div></en-note>');
      expect(r.documents.first.resources, isEmpty);
      expect(r.documents.first.markdown, contains('Untitled Attachment'));
    });

    test('占位符序号与 resources 下标一致', () {
      final r = convert('<p><img src="a.png"><img src="b.png">'
          '<a href="c.pdf">c</a></p>');
      final doc = r.documents.first;
      expect(doc.resources.map((e) => e.index), [0, 1, 2]);
      for (final ref in doc.resources) {
        expect(doc.markdown, contains(resourcePlaceholder(ref.index)));
      }
    });
  });

  // -------------------------------------------------------------------------
  group('图片尺寸（BR-61.5 / AC-250）', () {
    test('width 属性 / style width:Npx → {width=N}', () {
      expect(convert('<p><img src="a.png" width="320"></p>')
          .documents
          .first
          .resources
          .single
          .width, 320);
      expect(convert('<p><img src="a.png" style="width:320px"></p>')
          .documents
          .first
          .resources
          .single
          .width, 320);
    });

    test('百分比 / em / 无宽度 → 不写尺寸（width 为 null）', () {
      for (final style in ['width:100%', 'width:2em', 'max-width:100%']) {
        expect(
          convert('<p><img src="a.png" style="$style"></p>')
              .documents
              .first
              .resources
              .single
              .width,
          isNull,
          reason: style,
        );
      }
      expect(convert('<p><img src="a.png"></p>')
          .documents
          .first
          .resources
          .single
          .width, isNull);
    });

    test('尺寸只影响展示：resources 里没有字节改写（inlineBytes 保持原样）', () {
      final r = convert('<p><img src="data:image/png;base64,MTIz" width="10">'
          '</p>');
      expect(r.documents.first.resources.single.inlineBytes!.length, 3);
      expect(r.documents.first.resources.single.width, 10);
    });
  });

  // -------------------------------------------------------------------------
  group('标题定位与去重（§6.2 / §6.10 / BR-61.6）', () {
    test('meta[itemprop=title]（en-note 内部）优先', () {
      final r = convert('<en-note><meta itemprop="title" content="元数据标题">'
          '<h1 class="noteTitle">另一标题</h1><p>x</p></en-note>');
      expect(r.documents.first.title, '元数据标题');
    });

    test('h1.noteTitle → 首个 h1 → 文件名', () {
      expect(
        convert('<body><h1 class="noteTitle">A</h1></body>').documents.first.title,
        'A',
      );
      expect(convert('<body><h1>B</h1></body>').documents.first.title, 'B');
      expect(convert('<body><p>x</p></body>', file: '回退名.html')
          .documents.first.title, '回退名');
    });

    test('首个块级元素是同文 h1 → 移除；不同文 → 保留', () {
      expect(mdOf('<h1>同名</h1><p>x</p>', file: '同名.html'), 'x\n');
      // 标题由 meta 给出（与 h1 不同文）→ h1 保留。
      expect(
        mdOf('<meta itemprop="title" content="别的"><h1>同名</h1><p>x</p>',
            file: '同名.html'),
        '# 同名\n\nx\n',
      );
    });

    test('h1 不是首个块级元素 → 一律保留', () {
      expect(mdOf('<p>p</p><h1>同名</h1>', file: '同名.html'),
          'p\n\n# 同名\n');
    });

    test('规范化比较：空白差异也算同文', () {
      expect(mdOf('<h1>  同名   标题 </h1><p>x</p>', file: '同名 标题.html'),
          'x\n');
    });
  });

  // -------------------------------------------------------------------------
  group('索引页与多节（§6.2 / AC-258 / AC-259）', () {
    test('Evernote_index.html 且无 en-note / html-note → 判为索引页跳过', () {
      final r = convert('<html><body><p>链接列表</p></body></html>',
          file: 'Evernote_index.html');
      expect(r.indexPageReason, isNotNull);
      expect(r.documents, isEmpty);
    });

    test('index.html 有 en-note → 照常导入（不得扩大跳过范围）', () {
      final r = convert('<en-note><h1>标题</h1><p>x</p></en-note>',
          file: 'index.html');
      expect(r.indexPageReason, isNull);
      expect(r.documents, hasLength(1));
      expect(r.documents.first.markdown, contains('x'));
    });

    test('index.html 有 div.html-note → 照常导入', () {
      final r = convert('<div class="html-note"><p>x</p></div>',
          file: 'index.html');
      expect(r.indexPageReason, isNull);
      expect(r.documents, hasLength(1));
    });

    test('3 个 div.html-note → 3 篇；缺标题回退「文件名 (n)」（n 从 1 起）', () {
      final r = convert('<html><body>'
          '<div class="html-note"><en-note><h1>第一篇</h1><p>1</p></en-note></div>'
          '<div class="html-note"><en-note><p>2</p></en-note></div>'
          '<div class="html-note"><en-note><p>3</p></en-note></div>'
          '</body></html>', file: '导出.html');
      expect(r.documents, hasLength(3));
      expect(r.documents[0].title, '第一篇');
      expect(r.documents[1].title, '导出 (2)');
      expect(r.documents[2].title, '导出 (3)');
      // 各篇正文独立（不得揉成一篇）；首节 h1 与节标题同文 → 去重。
      expect(r.documents[0].markdown, '1\n');
      expect(r.documents[1].markdown, '2\n');
      expect(r.documents[2].markdown, '3\n');
    });

    test('恰有 1 节 → 按单篇处理', () {
      final r = convert('<div class="html-note"><en-note><p>x</p></en-note></div>');
      expect(r.documents, hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  group('印象笔记导出结构（ADR-024 实测表 / AC-243）', () {
    const evernote = '<html><head><meta charset="utf-8">'
        '<style>en-note.peso { font-family: x }</style>'
        '<icons><svg><path/></svg></icons></head><body>'
        '<en-note class="peso">'
        '<meta itemprop="title" content="印象标题">'
        '<h1 class="noteTitle">印象标题</h1>'
        '<div class="para">第一行</div>'
        '<div class="para"><br></div>'
        '<div class="para">第二行</div>'
        '<div><ul class="list-bullet">'
        '<li><input class="list-bullet-todo" checked>已完成</li>'
        '<li><input class="list-bullet-todo" aria-checked="true">也完成</li>'
        '<li><input class="list-bullet-todo">未完成</li></ul></div>'
        '<div class="para">图片 <img src="a files\\image (1).png" '
        'data-resource-hash="h"> 结尾</div>'
        '<note-attributes/></en-note></body></html>';

    test('en-note + div.para 逐行成段 + 空行 + 复选框', () {
      final r = convert(evernote);
      final doc = r.documents.first;
      expect(doc.title, '印象标题');
      // H1 与标题同文 → 被去重；其余按段输出（第一行与第二行之间是印象笔记的空行）。
      expect(doc.markdown, startsWith('第一行\n\n第二行\n\n'));
      expect(doc.markdown, contains('- [x] 已完成'));
      expect(doc.markdown, contains('- [x] 也完成'));
      expect(doc.markdown, contains('- [ ] 未完成'));
      expect(doc.markdown, contains('图片 ${resourcePlaceholder(0)} 结尾'));
      expect(doc.markdown.contains('font-family'), isFalse);
      expect(doc.resources, hasLength(1));
      expect(doc.resources.single.reference, 'a files\\image (1).png');
      expect(doc.resources.single.suggestedName, 'image (1).png');
      // 收尾：正文不得残留任何占位符控制字符以外的噪声。
      expect(doc.markdown.contains('data-resource-hash'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 旧版印象笔记「导出为网页」结构（缺陷修复 `v0.13.1` / AC-243 / BR-61.3）
  // ---------------------------------------------------------------------------
  group('旧版印象笔记「导出为网页」（YXBJ）结构', () {
    // 真实形态（实测 2026-10-12，用户导入的 29 篇导出文件即此形态）：
    //   <a name="18179"/>   ← HTML 解析规则下**不闭合**，把后面全部吞成它的子节点
    //   <h1>标题</h1>        ← 标题副本
    //   <div><span><div>每行</div><div>每行</div></span></div>   ← 非法嵌套（块级在 span 里）
    // 修复前：外层容器只看直接子元素 → 判成「只含行内内容」→ 整篇是**一个段落**、
    // 段界退化成行内 <br>（实测 28 KB 导出 → 一行 + 10 个 <br>，源文件里一个 <br> 都没有）。
    const legacy = '<html><head><title>标题</title></head><body>'
        '<a name="18179"/>'
        '<h1>标题</h1>'
        '<div><span>'
        '<div><span style="color: rgb(15, 17, 21);">第一段</span></div>'
        '<div><span>第二段</span></div>'
        '<h3><span>小标题</span></h3>'
        '<ul><li><div>甲</div></li><li><div>乙</div></li></ul>'
        '</span></div>'
        '</body></html>';

    test('段界是段落（空行）而不是行内 <br>；标题副本被去重', () {
      final doc = convert(legacy).documents.first;
      expect(doc.title, '标题');
      expect(doc.markdown.contains('<br>'), isFalse,
          reason: '段界不得降级成行内 <br>（用户可见为多余符号）');
      expect(doc.markdown, startsWith('第一段\n\n第二段\n'));
      expect(doc.markdown, contains('### 小标题'));
      expect(doc.markdown, contains('- 甲'));
      expect(doc.markdown, contains('- 乙'));
    });

    test('段落内 <br> → 真换行；表格单元格内仍写 <br>（GFM 限制）', () {
      final doc = convert('<div><span>甲<br>乙</span></div>').documents.first;
      expect(doc.markdown.trim(), '甲\n乙');
      expect(doc.markdown.contains('<br>'), isFalse);
      // 格内换行是 `<br>` 的唯一去处（GFM 管道表不支持多行单元格，BR-44.2）
      expect(
        mdOf('<table><tr><th>H</th></tr><tr><td>甲<br>乙</td></tr></table>'),
        '| H |\n| --- |\n| 甲<br>乙 |\n',
      );
    });
  });
}
