import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../format/editor_format.dart';
import 'import_types.dart';
import 'source_document.dart';
import 'text_decoding.dart';

/// M13（FR-61 / BR-61.3 / BR-61.8\~61.12）—— DOM 式 HTML→Markdown 转换器。
///
/// 详细设计 §6。与 M9 粘贴链路的 [EditorFormat.htmlToMarkdown] **各自演进**：
/// 后者面向剪贴板片段（正则式、无 `<img>` / 无有序列表 / 无代码块），
/// 改动它会直接冲击 FR-45 的既有门禁（ADR-024 决策 3）。
///
/// 三条底线：
/// * **不丢字**：无法映射的元素保留其文本，或降级为链接（BR-61.3）；
/// * **不臆测附件**：只有 HTML **明确给出可用引用**的节点才登记资源（BR-61.12）；
/// * **不做 IO**：图片 / 链接在正文里只写**节点级占位符**，由导入服务本地化（§6.9）。
///
/// 实现口径：先按块级规则表（§6.3）拼出**行缓冲**，再统一执行 §6.5 的空白规整与
/// §6.11 的转义。转换器**自己生成**的结构行（`#` 标题 / 表格行 / `---`）不参与行首转义。

/// 一个 HTML 文件的转换结果。
///
/// 印象笔记「单个网页」导出会把**多篇**笔记塞进一个 `.html`（`div.html-note` 分节），
/// 故这里返回**列表**（§3.2 / BR-61.9）。
class HtmlConversionResult {
  const HtmlConversionResult({
    this.documents = const [],
    this.indexPageReason,
    this.warnings = const [],
  });

  /// 索引页时为空；普通单篇时长度 1；「单个网页」多节时 > 1。
  final List<ImportedDocument> documents;

  /// 非空 = 判为导出索引页（BR-61.10），服务侧记 `skipped(indexPage)`。
  final String? indexPageReason;

  final List<String> warnings;
}

// ---------------------------------------------------------------------------
// 标签分类
// ---------------------------------------------------------------------------

/// 预处理阶段**整块丢弃**的标签（其文本不进正文，也**不**计入「未本地化资源」）：
/// BR-61.3 / BR-61.11 / §6.1。
const Set<String> _droppedTags = {
  'script',
  'style',
  'link',
  'meta',
  'title',
  'base',
  'noscript',
  'icons', // 印象笔记的 SVG 雪碧图（约 800 KB）
  'svg',
  'note-attributes',
  'head',
};

/// 明确**无文本**的标签（不透明也不降级，直接丢弃）。
const Set<String> _voiderNoText = {
  'input',
  'source',
  'track',
  'wbr',
  'area',
  'template',
};

/// 媒体 / 框架元素：**降级为链接**并保留其 `src` / `data`（BR-61.3 / §6.3）。
const Set<String> _downgradeToLink = {
  'iframe',
  'video',
  'audio',
  'embed',
  'object',
};

/// 块级标签（用于判定「容器是否含块级子元素」→ 透明，§6.3）。
const Set<String> _blockTags = {
  'address',
  'article',
  'aside',
  'blockquote',
  'center',
  'dd',
  'details',
  'dialog',
  'dir',
  'div',
  'dl',
  'dt',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hgroup',
  'hr',
  'li',
  'main',
  'menu',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'summary',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'ul',
  'en-note',
  'html-note',
  'note-attributes',
};

/// **行内包装**标签（不产生块级结构，但可能包着块级元素——见 [_hasBlockChildren]）。
///
/// 印象笔记旧版「导出为网页」（`<meta name="exporter-version" content="YXBJ …">`）的真实形态是
/// `<a name="…"/><h1>标题</h1><div><span><div>每行</div>…</div></span></div>`：`<a name>` 按 HTML
/// 解析规则**不闭合**，把整个正文吞成它的子节点；`<span>` 里嵌 `<div>` 又是非法嵌套。
/// 故块级探测必须能穿过这些行内包装（否则整篇会被当成一个段落，段界退化成行内 `<br>`）。
const Set<String> _inlineWrappers = {
  'a',
  'abbr',
  'b',
  'bdi',
  'bdo',
  'big',
  'cite',
  'code',
  'data',
  'del',
  'dfn',
  'em',
  'font',
  'i',
  'ins',
  'kbd',
  'label',
  'mark',
  'q',
  'ruby',
  's',
  'samp',
  'small',
  'span',
  'strike',
  'strong',
  'sub',
  'sup',
  'time',
  'tt',
  'u',
  'var',
  'wbr',
};

// ---------------------------------------------------------------------------
// 渲染中间态的私有标记
// ---------------------------------------------------------------------------

/// 字面片段（代码片段等**不参与转义**的内容）的边界标记。
const String _litStart = '\u{E010}';
const String _litEnd = '\u{E011}';

/// `li` 内 `<p>` / `<div>` 子块的段落分界标记。
const String _paragraphMarker = '\u{E013}';

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

/// 把 HTML 字节转换为若干篇 Markdown（§6）。
HtmlConversionResult convertHtmlDocument(Uint8List bytes, String fileName) {
  final decoded = decodeTextBytes(bytes);
  final warnings = <String>[
    if (decoded.degraded) '编码可能不正确',
  ];

  final dom.Document document;
  try {
    document = html_parser.parse(decoded.text);
  } catch (e) {
    return HtmlConversionResult(warnings: [...warnings, 'HTML 解析失败：$e']);
  }

  // §6.2 第 1 条：**索引页判定先于一切**——文件名以 `index` 结尾，且既无
  // `<en-note>` 也无 `<div class="html-note">`。
  if (_looksLikeIndexPage(fileName, document)) {
    return HtmlConversionResult(
      documents: const [],
      indexPageReason: '索引页',
      warnings: warnings,
    );
  }

  final body = document.body ?? document.documentElement;
  if (body == null) {
    return HtmlConversionResult(warnings: [...warnings, 'HTML 无正文']);
  }

  final sections = document.querySelectorAll('div.html-note');

  // §6.2 第 2 条：≥2 节 → 逐节各产出一篇（BR-61.9，不得把多篇揉成一篇）。
  if (sections.length >= 2) {
    final documents = <ImportedDocument>[];
    final stem = titleFromFileName(fileName);
    for (var i = 0; i < sections.length; i++) {
      final section = sections[i];
      // 节内标题：`meta[itemprop=title]` → `h1.noteTitle` → 节内首个 `h1`。
      // **不回退到文档级 H1**——否则所有节都会拿到第一篇的标题（BR-61.9 的动机）。
      final scoped = _extractTitle(document, section, '', scoped: true);
      final title = scoped.isNotEmpty ? scoped : '$stem (${i + 1})';
      documents.add(_convertNote(
        root: section.querySelector('en-note') ?? section,
        title: title,
        warnings: warnings,
      ));
    }
    return HtmlConversionResult(documents: documents, warnings: warnings);
  }

  // 单篇（含恰有 1 节的情况）：正文根按 `en-note` → `div.html-note` → `body`（§6.2 第 3 条）。
  final root = document.querySelector('en-note') ??
      document.querySelector('div.html-note') ??
      body;
  final title = _extractTitle(document, root, titleFromFileName(fileName));
  return HtmlConversionResult(
    documents: [
      _convertNote(root: root, title: title, warnings: warnings),
    ],
    warnings: warnings,
  );
}

/// 剪贴板片段的 HTML→Markdown 入口（FR-71 / ADR-028 决策 4）。
///
/// 与批量导入**共用同一个 DOM 式渲染器**（BR-71.2），只去掉两处「文档级」语义——
/// 它们正是「整篇文件」与「一段选区」的固有差异：
///
/// * **不做标题推导与去重**：片段没有文档标题；若沿用标题推导 + §6.10 去重，正文首个
///   `h1` 会被当成「标题副本」删掉，等于吃掉用户刚复制的内容；
/// * **资源就地内联**：片段没有导入会话来替换占位符，故收尾后直接把
///   `![alt](ref)` / `[text](ref)` 写回正文（`data:` 引用**原样保留**，是否落附件由调用方决定）。
///
/// 解析失败 / 无内容返回空串（调用方回落纯文本安全插入，BR-71.6）。
String convertClipboardHtml(String html) {
  if (html.trim().isEmpty) return '';
  final dom.Document document;
  try {
    document = html_parser.parse(html);
  } catch (_) {
    return '';
  }
  final body = document.body ?? document.documentElement;
  if (body == null) return '';
  final root = document.querySelector('en-note') ?? body;
  final r = _Renderer()..inlineStyles = true;
  _renderChildren(root, r, const _Ctx());
  return inlineResourcePlaceholders(_finalize(r), r.resources).trim();
}

/// 把 [markdown] 里的**资源占位符**替换为内联 Markdown 引用（剪贴板片段专用，§17.3）。
///
/// 必须在收尾规整**之后**替换：占位符是不含 Markdown 记号的哨兵字符，替换成 `![…](…)`
/// 不会经过转义；若提前写入，方括号会被转义成字面量而不再是链接。
String inlineResourcePlaceholders(
  String markdown,
  List<ImportResourceRef> resources,
) {
  var out = markdown;
  for (final res in resources) {
    final label = res.alt.trim().isEmpty ? res.suggestedName : res.alt.trim();
    final safeLabel = label
        .replaceAll(r'\', r'\\')
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]');
    final target = _escapeLinkTarget(res.reference);
    final String replacement;
    if (res.kind == ImportResourceKind.image) {
      final size = res.width == null ? '' : '{width=${res.width}}';
      replacement = '![$safeLabel]($target)$size';
    } else {
      replacement = '[$safeLabel]($target)';
    }
    out = out.replaceAll(resourcePlaceholder(res.index), replacement);
  }
  return out;
}

/// 链接目标位转义：空格与括号必须转义，否则 Markdown 会把地址截断在第一个 `)`。
String _escapeLinkTarget(String raw) => raw
    .replaceAll(' ', '%20')
    .replaceAll('(', '%28')
    .replaceAll(')', '%29')
    .replaceAll('<', '%3C')
    .replaceAll('>', '%3E');

/// 行内**样式保留**（仅剪贴板片段，§17.3）：返回 null 表示「无可用样式」（走上层透明口径）。
///
/// 映射优先级：Markdown 有对应语法的先用语法（加粗 / 斜体 / 删除线），其余（颜色 / 背景 /
/// 字号 / 下划线）落 `style` 白名单的 HTML `<span>` ——与网页快照同一套白名单与渲染口径
/// （FR-69 / BR-69.2）。
/// 用**字面片段标记**保护自产的强调记号（`**` / `*` / `~~`）。
///
/// 动机：§6.11 的行内转义会把 `*` 转成 `\*`（批量导入的既有口径是「不臆造强调」，
/// 见 `import_html_test.dart` 的 `strong/b → **` 用例）。但**粘贴**的诉求恰恰是
/// 「保留原格式」，故剪贴板路径把自产记号包进字面片段——转义跳过它们，收尾时
/// [literalStrip] 再去掉标记，最终正本里就是真正的 `**粗**`。
String _emphasis(String marker, String inner) =>
    '$_litStart$marker$_litEnd$inner$_litStart$marker$_litEnd';

/// 强调包裹：剪贴板路径用 [_emphasis] 保护，批量导入保持既有「转义成字面星号」口径。
String _wrapEmphasis(_Renderer r, String marker, String inner) {
  if (inner.trim().isEmpty) return inner;
  return r.inlineStyles ? _emphasis(marker, inner) : '$marker$inner$marker';
}

/// 块级容器自身的**行内样式**（仅剪贴板路径，§17.3）。
///
/// 剪贴板片段里很常见 `<div style="font-weight:700">粗</div>` / `<p style="color:#c00">红</p>`
/// ——样式挂在**块级**容器上，而 [_styledInline] 只覆盖行内元素，故这里补一层。
/// 批量导入路径原样返回（不改变既有产物，BR-71.2）。
String _styledBlockInline(_Renderer r, dom.Element node, String inner) {
  final normalized = _normalizeInline(inner);
  if (!r.inlineStyles) return normalized;
  return _styledInline(node, normalized) ?? normalized;
}

String? _styledInline(dom.Element node, String inner) {
  if (inner.trim().isEmpty) return inner;
  final tag = node.localName?.toLowerCase() ?? '';
  final styles = _parseInlineStyle(node.attributes['style']);
  // 标签级默认样式（`<u>` / `<mark>` / `<font color=…>`）与内联 `style` 合并。
  if (tag == 'u') styles.putIfAbsent('text-decoration', () => 'underline');
  if (tag == 'mark') styles.putIfAbsent('background-color', () => '#ffff00');
  if (tag == 'font') {
    final color = _normalizeColor(node.attributes['color'] ?? '');
    if (color != null) styles.putIfAbsent('color', () => color);
  }
  if (styles.isEmpty) return null;

  var out = inner;
  final html = <String>[];
  styles.forEach((key, value) {
    switch (key) {
      case 'font-weight':
        if (_isBold(value)) out = _emphasis('**', out);
      case 'font-style':
        if (value.contains('italic') || value.contains('oblique')) {
          out = _emphasis('*', out);
        }
      case 'text-decoration':
        if (value.contains('line-through')) out = _emphasis('~~', out);
        if (value.contains('underline')) {
          html.add('text-decoration:underline');
        }
      case 'color':
        final c = _normalizeColor(value);
        if (c != null) html.add('color:$c');
      case 'background-color':
        final c = _normalizeColor(value);
        if (c != null) html.add('background-color:$c');
      case 'font-size':
        final s = _normalizeFontSize(value);
        if (s != null) html.add('font-size:$s');
    }
  });
  if (html.isNotEmpty) out = '<span style="${html.join(';')}">$out</span>';
  return out;
}

/// 解析内联 `style` 属性为 `属性 → 值` 表（键与值都小写、去首尾空白）。
Map<String, String> _parseInlineStyle(String? raw) {
  final out = <String, String>{};
  if (raw == null || raw.isEmpty) return out;
  for (final part in raw.split(';')) {
    final i = part.indexOf(':');
    if (i <= 0) continue;
    final key = part.substring(0, i).trim().toLowerCase();
    final value = part.substring(i + 1).trim().toLowerCase();
    if (key.isNotEmpty && value.isNotEmpty) out[key] = value;
  }
  return out;
}

/// `font-weight` 是否算加粗（`bold` / `bolder` / 数值 ≥ 600）。
bool _isBold(String value) {
  if (value == 'bold' || value == 'bolder') return true;
  final n = int.tryParse(value);
  return n != null && n >= 600;
}

/// 颜色归一化：只接受 `#rgb` / `#rrggbb` / 纯字母色名（**单 token、无空格**）。
///
/// `rgb(1,2,3)` / `var(--x)` / `inherit` 一类一律**丢弃**——白名单要的是「不破坏 Markdown
/// 行内规整」的简单值（§17.3）。
String? _normalizeColor(String raw) {
  final v = raw.trim().toLowerCase();
  if (RegExp(r'^#[0-9a-f]{3}$').hasMatch(v) ||
      RegExp(r'^#[0-9a-f]{6}$').hasMatch(v)) {
    return v;
  }
  if (RegExp(r'^[a-z]{3,20}$').hasMatch(v)) return v;
  return null;
}

/// 字号归一化：只接受 `NNpx` / `NN%`（8..72）；其余丢弃。
String? _normalizeFontSize(String raw) {
  final m = RegExp(r'^(\d{1,3})(px|%)$').firstMatch(raw.trim());
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  if (n < 8 || n > 72) return null;
  return '$n${m.group(2)}';
}

// ---------------------------------------------------------------------------
// 定位（索引页 / 标题）
// ---------------------------------------------------------------------------

/// BR-61.10：文件名（去扩展名、**小写**）以 `index` 结尾，且正文既无 `en-note`
/// 也无 `div.html-note` → 索引页。**只**用于这一种组合，其余 HTML 一律按普通网页导入。
bool _looksLikeIndexPage(String fileName, dom.Document document) {
  final stem = titleFromFileName(fileName).toLowerCase();
  if (!stem.endsWith('index')) return false;
  final hasEnNote = document.querySelector('en-note') != null;
  final hasHtmlNote = document.querySelectorAll('div.html-note').isNotEmpty;
  return !hasEnNote && !hasHtmlNote;
}

/// 标题：`meta[itemprop=title]` → `h1.noteTitle` → 首个 `h1` → [fallback]（§6.2 第 4 条）。
///
/// `meta[itemprop=title]` 常位于 `<en-note>` **内部**，故文档级与 [scope] 级都要找；
/// `meta` 在遍历时被整块丢弃（§6.1），所以**先读取**再丢弃——读取发生在渲染之前，
/// 顺序天然正确。
///
/// [scoped] 为 `true`（多节模式）时**只看 [scope] 内部**：
/// 既不回退文档级 `meta`，也不回退文档级 `h1`——否则所有节都会拿到第一篇的标题。
String _extractTitle(
  dom.Document document,
  dom.Element? scope,
  String fallback, {
  bool scoped = false,
}) {
  if (scoped) {
    final metaText =
        _normalizeText(scope?.querySelector('meta[itemprop="title"]')
                ?.attributes['content'] ??
            '');
    if (metaText.isNotEmpty) return metaText;
    final head = _firstHeadingText(scope);
    return head.isNotEmpty ? head : fallback;
  }

  final meta = document.querySelector('meta[itemprop="title"]') ??
      scope?.querySelector('meta[itemprop="title"]');
  final metaText = _normalizeText(meta?.attributes['content'] ?? '');
  if (metaText.isNotEmpty) return metaText;

  final scopedHead = _firstHeadingText(scope);
  if (scopedHead.isNotEmpty) return scopedHead;

  final docLevel = _firstHeadingText(document.body ?? document.documentElement);
  if (docLevel.isNotEmpty) return docLevel;
  return fallback;
}

String _firstHeadingText(dom.Element? scope) {
  if (scope == null) return '';
  final noteTitle = scope.querySelector('h1.noteTitle');
  final noteTitleText = _normalizeText(noteTitle?.text ?? '');
  if (noteTitleText.isNotEmpty) return noteTitleText;
  final h1 = scope.querySelector('h1');
  return _normalizeText(h1?.text ?? '');
}

/// 规范化文本：去首尾空白 + 折叠内部空白（§6.10 的标题比较口径）。
/// `&nbsp;` 已由解析器解码为 U+00A0，故一并视作空白。
String _normalizeText(String raw) =>
    raw.replaceAll(RegExp(r'[\s\u00a0\u3000]+'), ' ').trim();

// ---------------------------------------------------------------------------
// 渲染中间态
// ---------------------------------------------------------------------------

/// 一次转换的中间态：行缓冲 + 资源登记 + 代码块豁免区间。
class _Renderer {
  /// 输出行（空串 = 空行）。
  final List<String> lines = <String>[];

  /// 已登记的资源（`index` 即占位符序号，与 [resourcePlaceholder] 一致）。
  final List<ImportResourceRef> resources = <ImportResourceRef>[];

  /// 代码块覆盖的行区间（成对出现，`[start, end)`）：收尾时**不**参与 §6.5 的 ①②③。
  final List<int> codeRanges = <int>[];

  /// **转换器自己生成的结构行**行号（`#` 标题 / `|` 表格行 / `---` / 围栏）。
  ///
  /// 这些行不参与 §6.11 的行首转义（否则 `#` 会变 `\#`、表格会散架、`---` 会变
  /// `\-\-\-`）；源文本里的同名首字符（如 `<p># 不是标题</p>`）不在集合里，仍会转义。
  /// 用**行号集合**而不是行内哨兵字符：哨兵容易被后续的转义 / 折叠 / 裁剪环节吃掉。
  final Set<int> structuralLines = <int>{};

  /// `#` 标题行的行号：既跳过行首转义（在 [structuralLines] 里），又需要参与 §6.10 去重。
  final Set<int> headingLines = <int>{};

  /// **转换器自产的列表项标记行**的行号：这些行不做行首转义。
  ///
  /// 背景（`v0.13.5` 缺陷修复）：[_escapeLineStart] 有一条「源文本里的字面 `1. ` 不当列表」的
  /// 保护——它把 `1. ` 转义成 `1\. `。但列表项是经 [addLine] 写入的**非结构行**，于是**转换器
  /// 自己生成的**有序列表也被转义成 `1\. xxx`：Markdown 上退化为字面文本，且在**格式模式**下把
  /// 反斜杠原样显示出来（用户实测报障「列表前有斜杠」）。自产结构不需要这层保护，故在此登记行号。
  final Set<int> _preserveListMarkerLines = <int>{};

  /// 文档级标题（多节模式下为**节**标题）：供 §6.10 标题去重使用。
  String documentTitle = '';

  /// **剪贴板片段模式**（FR-71 / §17.3）：把 Markdown 无法表达的行内样式保留为受限 HTML span。
  ///
  /// 只有**粘贴**链路打开它——批量导入保持既有口径（`u` / `font` / `color` 一类透明丢弃，
  /// 见 §6.4），以免改动 M13 的产物与门禁（BR-71.2「转换单一来源，口径不分裂」）。
  bool inlineStyles = false;

  int get lineCount => lines.length;

  void addLine(String line) => lines.add(line);

  /// 追加一条**转换器自产的列表项标记行**（`1. ` / `- ` / 任务标记）并记录行号。
  ///
  /// 记录行号的用途见 [_preserveListMarkerLines]：这些行**不做行首转义**。
  void addListItemLine(String line) {
    _preserveListMarkerLines.add(lines.length);
    lines.add(line);
  }

  /// 追加一条**结构行**（`#` 标题 / `|` 表格行 / `---` / 围栏）：不做行首转义。
  void addStructuralLine(String line) {
    structuralLines.add(lines.length);
    lines.add(line);
  }

  /// 追加一条 `#` 标题行（结构行 + 记录行号供 §6.10 去重）。
  void addHeadingLine(String line) {
    headingLines.add(lines.length);
    structuralLines.add(lines.length);
    lines.add(line);
  }

  void blank() => lines.add('');

  /// 删除第 [index] 行，并把**所有按行号记账的集合**同步平移（标题 / 结构 / 列表标记 / 代码区段）。
  ///
  /// 纪律：任何新增的「行号集合」都必须在这里参与平移，否则删行后会**整体错位**——实测踩过：
  /// `_preserveListMarkerLines` 漏了这一步，于是每组有序列表的**首项**仍被行首转义成 `1\.`
  /// （用户报障「列表前有斜杠」）。此处同时把 [index] 本身从集合里**移除**（它现在指向下一行）。
  void removeLineAt(int index) {
    lines.removeAt(index);

    void shiftSet(Set<int> s) {
      s.remove(index);
      final out = <int>{};
      for (final n in s) {
        out.add(n > index ? n - 1 : n);
      }
      s
        ..clear()
        ..addAll(out);
    }

    shiftSet(headingLines);
    shiftSet(structuralLines);
    shiftSet(_preserveListMarkerLines);
    for (var i = 0; i < codeRanges.length; i++) {
      if (codeRanges[i] > index) codeRanges[i] -= 1;
    }
  }

  /// 去掉**行尾**空行（保证块之间恰好一个空行）。
  void trimTrailingBlanks() {
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
  }

  /// 把 [from] 起的后续行按 [prefix] 加前缀；空行保持空行。
  void prefixLines(int from, String prefix) {
    for (var i = from; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      lines[i] = '$prefix${lines[i]}';
    }
  }
}

/// 单篇转换（§6.2\~§6.12 全流程）。
ImportedDocument _convertNote({
  required dom.Element root,
  required String title,
  required List<String> warnings,
}) {
  final r = _Renderer()..documentTitle = _normalizeText(title);
  _renderChildren(root, r, const _Ctx());
  _dedupeLeadingTitle(r);

  final markdown = _finalize(r);
  // §7 收尾断言：转换器只**登记**资源，占位符由 FileImportService 替换；
  // 这里断言的是「占位符标记本身没有被转义或吃掉」。
  assert(
    !markdown.contains(kResourcePlaceholderStart) ||
        markdown.contains(kResourcePlaceholderEnd),
    '资源占位符必须成对出现',
  );
  return ImportedDocument(
    title: title,
    markdown: markdown,
    resources: r.resources,
    warnings: warnings,
  );
}

/// §6.10 标题去重：仅当**首个块级元素**是 `h1` 且其规范化文本与最终标题**完全相同**
/// 时才移除该 H1；其余情况一律保留（不视为丢字）。
void _dedupeLeadingTitle(_Renderer r) {
  // 只看**标题行**（转换器生成的 `h1`\~`h6` 行）：首个块级元素不是标题 → 无需去重。
  final headings = r.headingLines.toList()..sort();
  if (headings.isEmpty) return;
  final first = headings.first;
  // 「首个块级元素」判定：标题行之前不得有其它可见行。
  for (var i = 0; i < first; i++) {
    if (r.lines[i].trim().isNotEmpty) return;
  }
  final line = r.lines[first];
  final m = RegExp(r'^#\s+(.*)$').firstMatch(line);
  if (m != null && _normalizeText(m.group(1)!) == r.documentTitle) {
    // 删该行 + **统一平移所有行号集合**（[ _Renderer.removeLineAt ]）。
    r.removeLineAt(first);
  }
}

// ---------------------------------------------------------------------------
// 收尾规整（§6.5）
// ---------------------------------------------------------------------------

/// ① 去行尾空白；② 连续 ≥3 个换行折叠为 2；③ 去首尾空行并保证结尾恰好一个 `\n`；
/// ④ `\u00a0` → 空格；⑤ 行内连续空白折叠为一个空格。代码块**内部**豁免 ①②③。
String _finalize(_Renderer r) {
  final inCode = List<bool>.filled(r.lines.length, false);
  for (var i = 0; i + 1 < r.codeRanges.length; i += 2) {
    for (var j = r.codeRanges[i];
        j < r.codeRanges[i + 1] && j < inCode.length;
        j++) {
      inCode[j] = true;
    }
  }

  final out = <String>[];
  for (var i = 0; i < r.lines.length; i++) {
    final raw = r.lines[i];
    if (inCode[i]) {
      // 代码块内部：只统一换行符（§6.8），不折叠空白、不去行尾空白（保真优先）。
      out.add(raw);
      continue;
    }
    // 转换器**自己生成**的结构行（见 [structuralLines]）：不参与行首转义。
    if (r.structuralLines.contains(i)) {
      final line = _collapseInlineBlanks(
          raw.replaceAll('\u00a0', ' ').replaceAll(RegExp(r'\s+$'), ''));
      out.add(_stripLiterals(line));
      continue;
    }
    // 内容块可能含换行（多段落 `li` / 多行段落）：逐**行**做行首转义。
    // 行内的 `<br>` 是**软换行**，不是行首，故不参与行首转义（沿 §6.11 口径）。
    for (final piece in raw.split('\n')) {
      var line = piece.replaceAll('\u00a0', ' ').replaceAll('\u3000', ' ');
      line = line.replaceAll(RegExp(r'\s+$'), '');
      // 顺序固定：**先**折叠行内空白（保留行首缩进），**后**做行首转义。
      line = _escapeLineStart(
        _collapseInlineBlanks(line),
        preserveListMarker: r._preserveListMarkerLines.contains(i),
      );
      out.add(_stripLiterals(line));
    }
  }

  final merged = <String>[];
  var blankRun = 0;
  for (var i = 0; i < out.length; i++) {
    if (!inCode[i] && out[i].trim().isEmpty) {
      blankRun++;
      if (blankRun > 2) continue; // 连续空行 → 一个空行（即 2 个换行）
      merged.add('');
    } else {
      blankRun = 0;
      merged.add(out[i]);
    }
  }

  var start = 0;
  var end = merged.length;
  while (start < end && merged[start].trim().isEmpty) {
    start++;
  }
  while (end > start && merged[end - 1].trim().isEmpty) {
    end--;
  }
  if (start >= end) return '';
  return '${merged.sublist(start, end).join('\n')}\n';
}

/// ⑤ 行内连续空白（空格 / 制表）折叠为一个空格。
///
/// **只折叠内容**：保留行首缩进（嵌套列表 / 松列表续行的 `2 × 层级` 个空格）。
/// 若一律整行折叠，`- a\n  - b` 会退化成 `- a\n - b`（缩进层级丢失）。
String _collapseInlineBlanks(String line) {
  final m = RegExp(r'^[ \t]*').firstMatch(line)!;
  final lead = m.group(0)!;
  return lead + line.substring(lead.length).replaceAll(RegExp(r'[ \t]{2,}'), ' ');
}

// ---------------------------------------------------------------------------
// 转义（§6.11）
// ---------------------------------------------------------------------------

/// 行内转义集合：`\` `` ` `` `*` `_` `[` `]`。
const String _inlineEscapes = r'\`*_[]';

/// 行首额外转义集合（§6.11）：`#` `>` `-` `+` `=` `|`。
///
/// 只对**首个可见字符**生效（见 [_escapeLineStart]）——否则正文中间的 `-` / `>`
/// 会被无谓转义，产物可读性变差。
const String _lineStartExtra = r'#>-+=|';

/// 行内转义（§6.11）：已转义的不重复转义；字面片段（[`_litStart`]…[`_litEnd`]）跳过。
String _escapeInlineRegion(String raw) {
  final buf = StringBuffer();
  var inLiteral = false;
  var backslashRun = 0;
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == _litStart) {
      inLiteral = true;
      continue;
    }
    if (ch == _litEnd) {
      inLiteral = false;
      continue;
    }
    if (inLiteral) {
      buf.write(ch);
      continue;
    }
    if (_inlineEscapes.contains(ch)) {
      // 已被转义的不重复转义（`\*` 保持 `\*`，`\\*` 则要转）。
      if (ch != '\\' && backslashRun.isOdd) {
        buf.write(ch);
        backslashRun = 0;
        continue;
      }
      buf.write('\\');
      backslashRun = 0;
      buf.write(ch);
      if (ch == '\\') backslashRun = 1;
      continue;
    }
    backslashRun = 0;
    buf.write(ch);
  }
  return buf.toString();
}

/// 行首转义（§6.11）。
///
/// 先做**行内转义**（`\` `` ` `` `*` `_` `[` `]`），再对**首个可见字符**追加行首额外
/// 集合（`#` `>` `-` `+` `=` `|`）与「有序列表前缀」的 `.` / `)` 的转义。
///
/// 识别并**保留**这些前缀：缩进、引用 `> `、任务列表 `- [ ] `、有序 `1. `、无序 `- `。
String _escapeLineStart(String line, {bool preserveListMarker = false}) {
  if (line.isEmpty) return line;

  // 任务列表前缀来自**转换器**（`input[type=checkbox]` / `li[data-checked]`），
  // 必须在行内转义**之前**识别：行内转义会把 `[x]` 变成 `\[x\]`，任务标记就认不出了。
  // 源文本里恰好写成 `- [x] …` 的段落会被当成任务项（可接受的歧义，仍不丢字）。
  final task = RegExp(r'^([ \t]*(?:>[ \t]+)*[ \t]*)(-[ \t]+\[[ xX]\][ \t]+)')
      .firstMatch(line);
  if (task != null) {
    final head = task.group(0)!;
    return head + _escapeInlineRegion(line.substring(head.length));
  }
  final escaped = _escapeInlineRegion(line);
  if (escaped.isEmpty) return escaped;
  // **转换器自产的列表项**：跳过下面的行首转义（否则 `1. ` 会被写成 `1\. `，格式模式露出反斜杠）。
  // 行内转义已在上一行完成，故内容里的 `*` / `[` 等仍受保护。
  if (preserveListMarker) return escaped;

  var i = 0;
  while (i < escaped.length) {
    final ch = escaped[i];
    if (ch == ' ' || ch == '\t') {
      i++;
      continue;
    }
    // 引用前缀 `> `（嵌套累加由 `_renderBlockquote` 逐行加前缀）。
    if (ch == '>' && i + 1 < escaped.length && escaped[i + 1] == ' ') {
      i += 2;
      continue;
    }
    // **有序列表前缀 `1. ` / `1) ` 一律不转义**（`v0.13.5` 口径修订）：源文里手写的编号行
    // （导出里很常见，如「2. 每月需覆盖的收入」）按**有序列表项**呈现——过去写成 `2\. ` 会在
    // 格式模式露出反斜杠（用户报障「列表前有斜杠」）；而 Markdown 本身就把 `2. ` 渲染成编号项，
    // 且编号取自字面值（`2.` 仍显示 2），视觉与源文一致、也不丢字。
    // 无序列表前缀 `- ` / `* ` / `+ `（`*` 未转义，故此处只会命中 `-` / `+`）。
    if ((ch == '-' || ch == '+') &&
        i + 1 < escaped.length &&
        (escaped[i + 1] == ' ' || escaped[i + 1] == '\t')) {
      var j = i + 1;
      while (j < escaped.length &&
          (escaped[j] == ' ' || escaped[j] == '\t')) {
        j++;
      }
      return escaped.substring(0, j) +
          _escapeDangerChar(escaped[j]) +
          escaped.substring(j + 1);
    }
    break;
  }

  if (i >= escaped.length) return escaped;
  return escaped.substring(0, i) +
      _escapeDangerChar(escaped[i]) +
      escaped.substring(i + 1);
}

/// 首个可见字符的**行首额外**转义（`#` `>` `-` `+` `=` `|`）。
///
/// 与 [_escapeInlineRegion] 分开：`*` / `_` 是行内强调语法，句首必须保留原样
/// （否则 `**加粗**` 的段落会被毁掉）；`[` / 反引号 / `\` 已在行内转义里处理。
String _escapeDangerChar(String ch) {
  if (ch.isEmpty) return ch;
  if (_lineStartExtra.contains(ch)) return '\\$ch';
  return ch;
}

/// 去掉字面片段标记（收尾最后一步）。
String _stripLiterals(String raw) =>
    raw.replaceAll(_litStart, '').replaceAll(_litEnd, '');

// ---------------------------------------------------------------------------
// 遍历上下文
// ---------------------------------------------------------------------------

/// 遍历上下文：随位置变化（列表层级 / 引用深度）。
class _Ctx {
  const _Ctx({this.listDepth = 0, this.blockquoteDepth = 0});

  final int listDepth;
  final int blockquoteDepth;

  _Ctx copyWith({int? listDepth, int? blockquoteDepth}) => _Ctx(
        listDepth: listDepth ?? this.listDepth,
        blockquoteDepth: blockquoteDepth ?? this.blockquoteDepth,
      );

  String get indent => '  ' * listDepth;
}

// ---------------------------------------------------------------------------
// 块级规则表（§6.3）
// ---------------------------------------------------------------------------

void _renderChildren(dom.Element parent, _Renderer r, _Ctx ctx) {
  for (final node in parent.nodes) {
    _renderBlockNode(node, r, ctx);
  }
}

void _renderBlockNode(dom.Node node, _Renderer r, _Ctx ctx) {
  if (node is dom.Text) {
    // 块级容器里游离的文本：只要有可见字符就当一段（绝不丢字）。
    final text = node.text.replaceAll(RegExp(r'[\s\u00a0\u3000]+'), ' ').trim();
    if (text.isNotEmpty) _emitParagraph(r, text, ctx);
    return;
  }
  if (node is! dom.Element) return;
  final tag = node.localName?.toLowerCase() ?? '';
  if (_droppedTags.contains(tag) || _voiderNoText.contains(tag)) return;

  final heading = _headingLevel(tag);
  if (heading != null) {
    final text = _normalizeInline(_renderInlineChildren(node, r, ctx));
    if (text.isNotEmpty) {
      r.trimTrailingBlanks();
      if (r.lines.isNotEmpty) r.blank();
      r.addHeadingLine('${'#' * heading} $text');
      r.blank();
    }
    return;
  }

  switch (tag) {
    case 'p':
      // `p` 与 `div` 同口径：含块级**后代**时透明（旧版印象笔记导出会把整篇塞进
      // `<a name>` → `<span>` → `<div>` 的非法嵌套里，见 [_hasBlockChildren]）。
      if (_hasBlockChildren(node)) {
        _renderChildren(node, r, ctx);
        return;
      }
      _emitParagraph(
          r, _styledBlockInline(r, node, _renderInlineChildren(node, r, ctx)),
          ctx);
      return;
    case 'div':
      _renderDivLike(node, r, ctx);
      return;
    case 'ul':
    case 'ol':
      _renderList(node, r, ctx, ordered: tag == 'ol');
      return;
    case 'li':
      // 游离 `li`（不在列表内）：按无序项处理，绝不吞内容。
      _renderListItems([node], r, ctx, ordered: false);
      return;
    case 'blockquote':
      _renderBlockquote(node, r, ctx);
      return;
    case 'pre':
      _renderPre(node, r, ctx);
      return;
    case 'table':
      _renderTable(node, r, ctx);
      return;
    case 'hr':
      r.trimTrailingBlanks();
      if (r.lines.isNotEmpty) r.blank();
      r.addStructuralLine('---');
      r.blank();
      return;
    case 'br':
      // 顶层裸 `<br>`：视作空行（段内 `<br>` 由行内渲染处理）。
      r.blank();
      return;
    case 'img':
      _emitParagraph(r, _normalizeInline(_renderImage(node, r)), ctx);
      return;
    case 'a':
      // `<a>` 在**块级位置**且含块级后代时**透明**（只递归子节点）：
      // 印象笔记旧版导出的 `<a name="…"/>` 按 HTML 解析规则不闭合，会把整个正文吞成它的
      // 子节点（见 [_hasBlockChildren]）；若在此按「一个链接 / 一段文本」处理，整篇又会被拍平成
      // 「一行 + 行内 `<br>`」。块级链接（非法结构）因此退化为其内容，文本不丢。
      if (_hasBlockChildren(node)) {
        _renderChildren(node, r, ctx);
        return;
      }
      _emitParagraph(r, _normalizeInline(_renderAnchor(node, r, ctx)), ctx);
      return;
    case 'dl':
      _renderDefinitionList(node, r, ctx);
      return;
    case 'caption':
    case 'colgroup':
    case 'col':
    case 'td':
    case 'th':
    case 'tr':
    case 'thead':
    case 'tbody':
    case 'tfoot':
      // 游离表格片段：透明保留文本。
      _renderChildren(node, r, ctx);
      return;
  }

  if (_downgradeToLink.contains(tag)) {
    _emitParagraph(
        r, _normalizeInline(_renderEmbeddedMedia(node, r, ctx)), ctx);
    return;
  }

  // 含块级子元素的容器（含未知自定义标签 / 表单类容器）：**透明**（只递归子节点），
  // 避免把通用网页的嵌套容器变成一堆空段（§6.3 / BR-61.3）。
  if (_hasBlockChildren(node)) {
    _renderChildren(node, r, ctx);
    return;
  }
  _renderDivLike(node, r, ctx);
}

/// `div` / `span` / 未知标签：只含行内内容且充当段落时按**段落**处理
/// （印象笔记 `div.para` 即一段；仅含 `<br>` 者为一个**空行**，§6.3）。
void _renderDivLike(dom.Element node, _Renderer r, _Ctx ctx) {
  if (_hasBlockChildren(node)) {
    _renderChildren(node, r, ctx);
    return;
  }
  if (_isBlankContainer(node)) {
    r.blank();
    return;
  }
  _emitParagraph(
      r, _styledBlockInline(r, node, _renderInlineChildren(node, r, ctx)), ctx);
}

/// 是否含**块级后代**（§6.3：「含块级子元素的 div → 透明」）。
///
/// **必须穿透行内包装**（`<a>` / `<span>` / `<font>` …，见 [_inlineWrappers]）：只查直接子元素
/// 会漏掉 `<div><span><div>…</div></span></div>` 与 `<a name="…"><h1>…</h1><div>…` 这两类
/// **印象笔记旧版导出**的真实形态，导致外层容器被判成「只含行内内容」→ 整篇被当成**一个段落**、
/// 段界退化成行内 `<br>`（实测：28 KB 的导出转出「一行 + 10 个 `<br>`」）。
bool _hasBlockChildren(dom.Element node) => _containsBlock(node, 0);

bool _containsBlock(dom.Element node, int depth) {
  if (depth > 12) return false; // 防御性深度上限（畸形文档）
  for (final child in node.children) {
    final tag = child.localName?.toLowerCase() ?? '';
    if (_blockTags.contains(tag)) return true;
    if (_inlineWrappers.contains(tag) && _containsBlock(child, depth + 1)) {
      return true;
    }
  }
  return false;
}

/// 仅含 `<br>` / 空白（即「空段」，对应印象笔记 `<div class="para"><br></div>`）。
bool _isBlankContainer(dom.Element node) {
  var hasBr = false;
  for (final child in node.nodes) {
    if (child is dom.Text) {
      if (child.text.replaceAll(RegExp(r'[\s\u00a0\u3000]'), '').isNotEmpty) {
        return false;
      }
    } else if (child is dom.Element) {
      if (child.localName?.toLowerCase() == 'br') {
        hasBr = true;
      } else {
        return false;
      }
    } else {
      return false; // 非文本 / 非元素节点：保守判「非空」
    }
  }
  return hasBr;
}

int? _headingLevel(String tag) {
  if (tag.length != 2 || !tag.startsWith('h')) return null;
  final n = int.tryParse(tag[1]);
  if (n == null || n < 1 || n > 6) return null;
  return n;
}

/// 写一个段落（前后各一个空行）。
void _emitParagraph(_Renderer r, String content, _Ctx ctx) {
  if (content.trim().isEmpty) return;
  r.trimTrailingBlanks();
  if (r.lines.isNotEmpty) r.blank();
  for (final line in content.split('\n')) {
    r.addLine('${ctx.indent}$line'.trimRight());
  }
  r.blank();
}

// ---------------------------------------------------------------------------
// 行内规则表（§6.4）
// ---------------------------------------------------------------------------

String _renderInlineChildren(dom.Element node, _Renderer r, _Ctx ctx) {
  final buf = StringBuffer();
  for (final child in node.nodes) {
    buf.write(_renderInlineNode(child, r, ctx));
  }
  return buf.toString();
}

String _renderInlineNode(dom.Node node, _Renderer r, _Ctx ctx) {
  if (node is dom.Text) {
    // HTML 空白折叠语义（§6.5 第 ⑤ 条）：行内连续空白折叠为一个空格。
    return node.text.replaceAll(RegExp(r'[\s\u00a0\u3000]+'), ' ');
  }
  if (node is! dom.Element) return '';
  final tag = node.localName?.toLowerCase() ?? '';
  if (_droppedTags.contains(tag) || _voiderNoText.contains(tag)) return '';

  switch (tag) {
    case 'br':
      // **段落内的软换行 = 真换行**（`\n`）：与项目既有约定一致——编辑器里段落内 Shift+Enter
      // 走 `TextField` 默认行为插入 `\n`；粘贴链路 `EditorFormat.htmlToMarkdown` 也把 `<br>` 转 `\n`。
      // 反过来写 `<br>` 会让**格式模式**露出字面量标签（只有预览态与表格单元格会把它还原为换行，
      // 见 markdown_editor.dart 的 `_LineBreakSyntax` 与 format_table.dart 的 `_brToNewline`）——
      // 这正是用户报的「导入后笔记里出现 `<br>` 符号」。
      // **表格单元格**是唯一例外（GFM 管道表不支持多行单元格），由 `_renderTable` 的 `cellText`
      // 把这里的换行再转回 `<br>`（守 BR-44.2）。
      return '\n';
    case 'strong':
    case 'b':
      return _wrapEmphasis(r, '**', _renderInlineChildren(node, r, ctx));
    case 'em':
    case 'i':
      return _wrapEmphasis(r, '*', _renderInlineChildren(node, r, ctx));
    case 's':
    case 'del':
    case 'strike':
      return _wrapEmphasis(r, '~~', _renderInlineChildren(node, r, ctx));
    case 'code':
      return _renderCodeSpan(node);
    case 'img':
      return _renderImage(node, r);
    case 'a':
      return _renderAnchor(node, r, ctx);
  }

  if (_downgradeToLink.contains(tag)) {
    return _renderEmbeddedMedia(node, r, ctx);
  }

  // `p` / `div` 出现在行内位置（印象笔记偶有嵌套）：内容 + 软换行。
  if (tag == 'p' || tag == 'div') {
    final inner = _renderInlineChildren(node, r, ctx);
    return inner.trim().isEmpty ? '' : '$inner<br>';
  }

  // `u` / `sup` / `sub` / `font` / `mark` / `small` / 表单 / 自定义 / 未知标签：
  // **透明**（保留文本）——字体 / 颜色 / 高亮色 / 上下标无法映射，明确不做（§6.4）。
  //
  // **剪贴板路径例外**（FR-71 / §17.3）：粘贴时「颜色 / 背景 / 字号 / 下划线」这类
  // Markdown 没有对应语法的样式**保留为受限 HTML span**（与网页快照同一白名单），
  // 否则从浏览器复制来的内容会掉色；批量导入路径保持原口径不变（BR-71.2）。
  // 子节点只渲染**一次**（nil 时直接复用），否则嵌套的图片会被登记两次。
  if (r.inlineStyles) {
    final inner = _renderInlineChildren(node, r, ctx);
    return _styledInline(node, inner) ?? inner;
  }
  return _renderInlineChildren(node, r, ctx);
}

/// 反引号代码片段（不在 `pre` 内）：内容含反引号时加长围栏（§6.4）。
///
/// 以字面片段标记包裹：代码里的 `*` / `[` / 行首 `` ` `` 均为**字面字符**，
/// 不得参与 §6.11 转义（否则会改变代码内容）。
String _renderCodeSpan(dom.Element node) {
  final raw = node.text.replaceAll(RegExp(r'[\s\u00a0\u3000]+'), ' ').trim();
  if (raw.isEmpty) return '';
  var fence = '`';
  while (raw.contains(fence)) {
    fence = '$fence`';
  }
  final pad = raw.startsWith('`') || raw.endsWith('`') ? ' ' : '';
  return '$_litStart$fence$pad$raw$pad$fence$_litEnd';
}

/// 行内外整体规整：折叠空白、去掉 `<br>` 两侧多余空格与行尾 `<br>`。
String _normalizeInline(String raw) {
  var s = raw
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim())
      .join('\n');
  s = s.replaceAll(RegExp(r'(<br>\s*)+$'), '');
  s = s.replaceAll(RegExp(r'\s*<br>'), '<br>');
  return s.trim();
}

// ---------------------------------------------------------------------------
// 列表与任务列表（§6.6）
// ---------------------------------------------------------------------------

void _renderList(
  dom.Element node,
  _Renderer r,
  _Ctx ctx, {
  required bool ordered,
}) {
  // ① 归一化**非法嵌套**：`<ol><li>a</li><ul>…</ul><li>b</li></ol>`——网页剪藏 / 印象笔记导出里
  // 常见（浏览器把本想挂在 `<li>` 下的子列表序列化成了 `<li>` 的**兄弟**，且 `<ul>` 直接落在
  // `<ol>` 下）。这里把这类兄弟列表**移回前一个 `<li>` 内部**，随后由 `_renderLiSegments` 按
  // 「子列表」渲染。
  //    若不归一化，`node.children.where(li)` 会**整段丢弃**这些兄弟列表——实测
  // `AIGC生图和视频市场` 因此只剩 **29%** 内容（「定位 / 在线生图 / 社区互动」等全丢）。
  dom.Element? lastLi;
  for (final child in node.nodes.toList()) {
    if (child is! dom.Element) continue;
    final tag = child.localName?.toLowerCase() ?? '';
    if (tag == 'li') {
      lastLi = child;
      continue;
    }
    if ((tag == 'ul' || tag == 'ol') && lastLi != null) {
      child.parent?.nodes.remove(child);
      lastLi.append(child);
    }
  }

  final items = node.children
      .where((c) => (c.localName?.toLowerCase() ?? '') == 'li')
      .toList();
  if (items.isEmpty) {
    // 无 `li` 的列表：保留文本（容错脏结构），绝不丢字。
    _renderChildren(node, r, ctx);
    return;
  }
  _renderListItems(items, r, ctx,
      ordered: ordered, startAt: _listStart(node));
}

int _listStart(dom.Element node) {
  final n = int.tryParse((node.attributes['start'] ?? '').trim());
  return (n == null || n < 1) ? 1 : n;
}

void _renderListItems(
  List<dom.Element> items,
  _Renderer r,
  _Ctx ctx, {
  required bool ordered,
  int startAt = 1,
}) {
  r.trimTrailingBlanks();
  if (r.lines.isNotEmpty) r.blank();
  final indent = ctx.indent;
  var number = startAt;

  for (final li in items) {
    final task = _taskState(li);
    final marker = task != null
        ? '- [${task ? 'x' : ' '}] '
        : ordered
            ? '${number++}. '
            : '- ';
    final continuation = '$indent${' ' * marker.length}';

    final segments = _renderLiSegments(li, r, ctx);
    var markerWritten = false;

    for (final seg in segments) {
      if (seg.element != null) {
        // 子列表在**父项内容之后换行**并以 `2 × 层级` 缩进（§6.6）。
        _renderList(
          seg.element!,
          r,
          ctx.copyWith(listDepth: ctx.listDepth + 1),
          ordered: seg.element!.localName?.toLowerCase() == 'ol',
        );
        continue;
      }
      final text = _stripMarkers(_normalizeInline(seg.text));
      if (text.isEmpty) continue;
      final lines = text.split('\n');
      if (!markerWritten) {
        r.addListItemLine('$indent$marker${lines.first}'.trimRight());
        markerWritten = true;
        // 首段之后的其他段落：缩进对齐（Markdown 松列表的续行）。
        for (var k = 1; k < lines.length; k++) {
          r.addLine('$continuation${lines[k]}'.trimRight());
        }
      } else {
        for (var k = 0; k < lines.length; k++) {
          r.addLine('$continuation${lines[k]}'.trimRight());
        }
      }
    }
    if (!markerWritten) r.addListItemLine('$indent$marker'.trimRight());
  }
  r.blank();
}

/// `li` 内容的一段：要么是文本，要么是一个内嵌子列表元素。
class _LiSegment {
  const _LiSegment.text(this.text) : element = null;
  const _LiSegment.list(this.element) : text = '';
  final String text;
  final dom.Element? element;
}

/// 把 `li` 渲染成「文本段 / 子列表段」序列。
///
/// 子列表**不在这里渲染**（否则输出顺序会与父项内容交叉），而是打标记后交给
/// [_renderListItems] 顺序处理——这样「子列表在父项内容之后换行」天然成立（§6.6）。
List<_LiSegment> _renderLiSegments(dom.Element li, _Renderer r, _Ctx ctx) {
  final segments = <_LiSegment>[];
  final buf = StringBuffer();

  void flush() {
    if (buf.isEmpty) return;
    segments.add(_LiSegment.text(buf.toString()));
    buf.clear();
  }

  for (final child in li.nodes) {
    if (child is dom.Element) {
      final tag = child.localName?.toLowerCase() ?? '';
      if (tag == 'ul' || tag == 'ol') {
        flush();
        segments.add(_LiSegment.list(child));
        continue;
      }
      if (tag == 'p' || tag == 'div') {
        final inner = _normalizeInline(_renderInlineChildren(child, r, ctx));
        if (inner.isEmpty) continue;
        if (buf.isNotEmpty) buf.write(_paragraphMarker);
        buf.write(inner);
        continue;
      }
    }
    buf.write(_renderInlineNode(child, r, ctx));
  }
  flush();
  return segments;
}

String _stripMarkers(String text) =>
    text.replaceAll(_paragraphMarker, '\n');

/// 任务列表判定（§6.6）：`input[type=checkbox]`（含印象笔记 `list-bullet-todo`）
/// 或 `li[data-checked]`。
///
/// 勾选态取 `checked` 属性**或** `aria-checked="true"`（印象笔记两种都出现过）；
/// `input` 元素本身不进正文。
bool? _taskState(dom.Element li) {
  final input = li.querySelector('input');
  if (input != null) {
    final type = (input.attributes['type'] ?? '').toLowerCase();
    if (type == 'checkbox' || input.classes.contains('list-bullet-todo')) {
      return _isChecked(input);
    }
  }
  if (li.attributes.containsKey('data-checked')) return _isChecked(li);
  return null;
}

bool _isChecked(dom.Element el) {
  final attr = el.attributes['checked'];
  if (attr != null) return attr.toLowerCase() != 'false';
  if ((el.attributes['aria-checked'] ?? '').toLowerCase() == 'true') return true;
  final data = (el.attributes['data-checked'] ?? '').toLowerCase();
  return data == 'true' || data == 'checked' || data == '1';
}

// ---------------------------------------------------------------------------
// 引用（§6.3）
// ---------------------------------------------------------------------------

void _renderBlockquote(dom.Element node, _Renderer r, _Ctx ctx) {
  r.trimTrailingBlanks();
  if (r.lines.isNotEmpty) r.blank();
  final from = r.lineCount;
  _renderChildren(node, r, ctx);
  r.trimTrailingBlanks();
  // 嵌套累加：`> > `（§6.3）。空行保持空行，段间仍是一个空行。
  r.prefixLines(from, '> ' * (ctx.blockquoteDepth + 1));
  r.blank();
}

// ---------------------------------------------------------------------------
// 代码块（§6.8）
// ---------------------------------------------------------------------------

void _renderPre(dom.Element node, _Renderer r, _Ctx ctx) {
  final code = node.querySelector('code');
  final source = code ?? node;
  final language = _codeLanguage(code);
  var body = source.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // HTML 解析器常把 `<pre>` 起始标签后的首个换行并入内容：去掉它（不影响空行语义）。
  if (body.startsWith('\n')) body = body.substring(1);

  // 围栏：内容含以 ` ``` ` 开头的行时改用 `~~~`（§6.8）。
  var fence = '```';
  if (RegExp(r'^[ \t]*```', multiLine: true).hasMatch(body)) {
    var len = 3;
    for (final m
        in RegExp(r'^[ \t]*(~{3,})', multiLine: true).allMatches(body)) {
      if (m.group(1)!.length >= len) len = m.group(1)!.length + 1;
    }
    fence = '~' * len;
  }

  r.trimTrailingBlanks();
  if (r.lines.isNotEmpty) r.blank();
  final start = r.lineCount;
  r.addStructuralLine('$fence$language');
  for (final line in body.split('\n')) {
    r.addLine(line);
  }
  r.addStructuralLine(fence);
  r.codeRanges.addAll([start, r.lineCount]);
  r.blank();
}

String _codeLanguage(dom.Element? code) {
  if (code == null) return '';
  for (final cls in code.classes) {
    if (cls.startsWith('language-')) return cls.substring('language-'.length);
    if (cls.startsWith('lang-')) return cls.substring('lang-'.length);
  }
  return '';
}

// ---------------------------------------------------------------------------
// 表格（§6.7）
// ---------------------------------------------------------------------------

void _renderTable(dom.Element node, _Renderer r, _Ctx ctx) {
  final rows = node.querySelectorAll('tr');
  if (rows.isEmpty) {
    // 无任何行 → 透明（保留文本），绝不丢内容。
    _renderChildren(node, r, ctx);
    return;
  }

  // 表头行：优先 `thead > tr`，无 `thead` 时取**第一行**（GFM 必须有表头行）。
  final headerRow =
      node.querySelector('thead')?.querySelector('tr') ?? rows.first;

  final headerCells = _cellsOf(headerRow);
  final dataRows = <List<dom.Element>>[];
  for (final tr in rows) {
    if (identical(tr, headerRow)) continue;
    dataRows.add(_cellsOf(tr));
  }

  // 列数取各行最大值，缺格补空（`rowspan` / `colspan` 按普通格降级，§6.7）。
  var columns = headerCells.length;
  for (final row in dataRows) {
    if (row.length > columns) columns = row.length;
  }
  if (columns == 0) {
    _renderChildren(node, r, ctx);
    return;
  }

  String cellText(dom.Element cell) {
    // 行内规则（§6.4）→ 单元格内换行转 `<br>` → `escapeTableCell`（转义 `|`）。
    //
    // 段落内软换行在正文里是**真换行 `\n`**（见 `_renderInlineNode` 的 `case 'br'`），
    // 但 GFM 管道表不支持多行单元格 → 这里必须把 `\n`（以及 `<br>` 变体）再转回 `<br>`，
    // 否则换行会被紧随其后的空白折叠吃掉（BR-44.2）。
    final inline = _renderInlineChildren(cell, r, ctx)
        .replaceAll(RegExp(r'\s*<br>\s*'), '<br>')
        .replaceAll('\n', '<br>')
        .replaceAll(RegExp(r'[\s\u00a0\u3000]+'), ' ')
        .trim();
    return EditorFormat.escapeTableCell(inline);
  }

  final header = <String>[];
  final align = <String>[];
  for (var c = 0; c < columns; c++) {
    header.add(c < headerCells.length ? cellText(headerCells[c]) : '');
    align.add(c < headerCells.length ? _alignOf(headerCells[c]) : '---');
  }

  r.trimTrailingBlanks();
  if (r.lines.isNotEmpty) r.blank();
  r.addStructuralLine('| ${header.join(' | ')} |');
  r.addStructuralLine('| ${align.join(' | ')} |');
  for (final row in dataRows) {
    final cells = <String>[];
    for (var c = 0; c < columns; c++) {
      cells.add(c < row.length ? cellText(row[c]) : '');
    }
    r.addStructuralLine('| ${cells.join(' | ')} |');
  }
  r.blank();
}

/// 展平 `thead` / `tbody` / `tfoot`，`td` / `th` 一律当单元格（顺序保持）。
List<dom.Element> _cellsOf(dom.Element row) => row.children
    .where((c) => const {'td', 'th'}.contains(c.localName?.toLowerCase() ?? ''))
    .toList();

/// 对齐：`align` 属性优先，其次 `style="text-align:…"`；缺省 `---`（§6.7）。
String _alignOf(dom.Element cell) {
  var value = (cell.attributes['align'] ?? '').toLowerCase().trim();
  if (value.isEmpty) {
    final style = cell.attributes['style'] ?? '';
    value = (RegExp(r'text-align\s*:\s*([a-z]+)', caseSensitive: false)
            .firstMatch(style)
            ?.group(1) ??
        '')
        .toLowerCase();
  }
  return switch (value) {
    'left' => ':---',
    'center' => ':---:',
    'right' => '---:',
    _ => '---',
  };
}

// ---------------------------------------------------------------------------
// 定义列表（`dl` / `dt` / `dd`）
// ---------------------------------------------------------------------------

void _renderDefinitionList(dom.Element node, _Renderer r, _Ctx ctx) {
  r.trimTrailingBlanks();
  if (r.lines.isNotEmpty) r.blank();
  for (final child in node.children) {
    final tag = child.localName?.toLowerCase() ?? '';
    if (tag == 'dt') {
      final text = _normalizeInline(_renderInlineChildren(child, r, ctx));
      if (text.isNotEmpty) r.addLine('**$text**');
    } else if (tag == 'dd') {
      final text = _normalizeInline(_renderInlineChildren(child, r, ctx));
      if (text.isNotEmpty) r.addLine(': $text');
    } else {
      _renderBlockNode(child, r, ctx);
    }
  }
  r.blank();
}

// ---------------------------------------------------------------------------
// 资源与占位符（§6.9）
// ---------------------------------------------------------------------------

/// 图片类扩展名（小写、无点）。用于「`<img>` / `<a>` 的目标到底该按图片单元还是附件单元登记」。
const Set<String> _imageExtensions = {
  'png', 'jpg', 'jpeg', 'jpe', 'jfif', 'gif', 'bmp', 'webp', 'avif', 'svg',
  'svgz', 'heic', 'heif', 'ico', 'tif', 'tiff',
};

/// 引用的扩展名（小写、不含点）；无法判定时返回 `null`。
///
/// `data:` 走 MIME（`data:image/png;…` → `png`，`data:application/pdf;…` → `pdf`，其余 `null`）；
/// 其余取路径最后一段的扩展名（先做百分号解码，故 `interlace%2C1` 解出 `interlace,1` → **无扩展名**）。
String? _referenceExtension(String ref) {
  final v = ref.trim();
  final data = RegExp(r'^data:([^;,]+)', caseSensitive: false).firstMatch(v);
  if (data != null) {
    final mime = data.group(1)!.toLowerCase();
    final sub = mime.split('/').length == 2 ? mime.split('/')[1] : '';
    return sub.isEmpty ? null : sub;
  }
  var path = v;
  final q = path.indexOf(RegExp(r'[?#]'));
  if (q >= 0) path = path.substring(0, q);
  path = path.replaceAll('\\', '/');
  final base = path.split('/').last;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return null;
  try {
    return Uri.decodeComponent(base.substring(dot + 1)).toLowerCase();
  } catch (_) {
    return base.substring(dot + 1).toLowerCase();
  }
}

/// 引用是否是**明确的非图片文件**（只对**本地**引用判定）。
///
/// 判据：本地引用 + 有扩展名 + 扩展名不在 [_imageExtensions]。**无扩展名的资源一律不算**
/// ——印象笔记导出里图片经常没有扩展名（实测 29 篇里 47 处，如 `…_files/interlace%2C1`），
/// 若把它们降级成附件链接，正文里的图片会变成一排附件芯片。
/// 远端 URL **不判**（不带扩展名的图片接口很常见），保持既有口径。
bool _isClearlyNonImage(String ref) {
  if (_isRemoteReference(ref)) return false;
  final ext = _referenceExtension(ref);
  return ext != null && !_imageExtensions.contains(ext);
}

/// 引用是否按**图片**处理（用于链接目标的形态选择）。本地按扩展名白名单，`data:` 按 MIME，
/// 无扩展名 / 远端一律按**图片**（保守：宁可当图片，也不把图片降级成附件链接）。
bool _isImageReference(String ref) {
  final ext = _referenceExtension(ref);
  if (ext == null) return true;
  return _imageExtensions.contains(ext);
}

/// 图片：登记 image 资源 + 写节点占位符（尺寸随资源传递，BR-61.5）。
String _renderImage(dom.Element node, _Renderer r) {
  final src = (node.attributes['src'] ?? '').trim();
  if (!_isUsableReference(src)) return ''; // 无可用 `src` → 丢弃（无文本可留）
  final alt = _normalizeText(node.attributes['alt'] ?? '');
  // 源里 `<img>` 明确指向非图片文件（如 `….pdf` / `….json`）时按**附件链接**登记：
  // 呈现层对图片单元（`![…](sui://…)`）与附件单元（`[…](sui://…)`）的渲染不同（FR-46 / FR-27），
  // 把 PDF 标成图片会让它既不像图片也不像附件。
  final nonImage = _isClearlyNonImage(src);
  return _register(
    r,
    kind: nonImage ? ImportResourceKind.link : ImportResourceKind.image,
    reference: src,
    alt: alt,
    suggestedName: _suggestedName(src, alt),
    width: nonImage ? null : _imageWidth(node),
  );
}

/// 链接（含降级为链接的 `iframe` 等）。
String _renderAnchor(dom.Element node, _Renderer r, _Ctx ctx) {
  final href = (node.attributes['href'] ?? '').trim();
  if (!_isUsableReference(href)) {
    // 空 / 纯锚点 / `javascript:` → 透明（保留文本），**不**登记为资源（§6.9）。
    return _renderInlineChildren(node, r, ctx);
  }
  // `a` 内的 `<img>` 是**独立**节点：先渲染成自己的占位符，再把占位符换回**可读标签**当链接文字。
  final rendered = _normalizeInline(_renderInlineChildren(node, r, ctx));
  final wrapsResource = rendered.contains(kResourcePlaceholderStart);
  final text = _labelWithoutPlaceholders(rendered, r);
  return _register(
    r,
    // 形态只在「链接**包着资源**」且目标是图片时取图片引用 `![label](…)`（图链：图片本体即内容）；
    // 其余一律附件 / 普通链接 `[label](…)`——**文字链接永不因扩展名变成图片**。
    kind: (wrapsResource && _isImageReference(href))
        ? ImportResourceKind.image
        : ImportResourceKind.link,
    reference: href,
    alt: text,
    suggestedName: _suggestedName(href, text),
  );
}

/// 把行内渲染结果里的**资源占位符**换回该资源的人类可读标签（`alt` → 建议名）。
///
/// **必须做**：`<a href="文件"><img src="缩略图"></a>`（链接包图片）在印象笔记导出里很常见
/// （实测 29 篇里 7 处，**全部**是「链接到 PDF / JSON / TXT」）。若把内层占位符原样当链接文字，
/// 本地化会组合出**嵌套引用** `[![名字](sui://图)](sui://文件)`；而客户端的附件引用识别是
/// **扁平正则**（`(!?)\[([^\]]*)\]\(\s*sui://([0-9a-fA-F]+)\s*\)?`，见 `editor_format.dart`）：
/// 它会从 `[` 起把 `![名字` 整段吃成标签、sha 取**内层图片**，剩下的 `](sui://文件)` 当**字面量**
/// 渲染出来——用户可见的「附件显示错误」。故导入侧保证 **资源引用永不嵌套**：外层（附件）胜出，
/// 内层只贡献标签文本，其字节不再落盘（`import_service` 会跳过未被引用的资源）。
String _labelWithoutPlaceholders(String rendered, _Renderer r) {
  if (!rendered.contains(kResourcePlaceholderStart)) return rendered;
  return rendered.replaceAllMapped(
    RegExp('$kResourcePlaceholderStart(\\d+)$kResourcePlaceholderEnd'),
    (m) {
      final i = int.tryParse(m.group(1) ?? '');
      if (i == null || i < 0 || i >= r.resources.length) return '';
      final res = r.resources[i];
      return res.alt.isNotEmpty ? res.alt : res.suggestedName;
    },
  );
}

/// `iframe` / `video` / `audio` / `embed` / `object`：**降级为链接**并保留 `src` / `data`。
///
/// 无 `src` / `data` → **透明**（保留其文本），不登记资源（§6.3 / BR-61.3）。
String _renderEmbeddedMedia(dom.Element node, _Renderer r, _Ctx ctx) {
  final src = (node.attributes['src'] ?? node.attributes['data'] ?? '').trim();
  if (!_isUsableReference(src)) return _renderInlineChildren(node, r, ctx);
  final text = _normalizeText(node.text);
  return _register(
    r,
    kind: ImportResourceKind.link,
    reference: src,
    alt: text,
    suggestedName: _suggestedName(src, text),
  );
}

/// 登记一个资源并返回其节点占位符（§6.9）。
String _register(
  _Renderer r, {
  required ImportResourceKind kind,
  required String reference,
  required String alt,
  required String suggestedName,
  int? width,
}) {
  final index = r.resources.length;
  r.resources.add(ImportResourceRef(
    index: index,
    kind: kind,
    reference: reference,
    alt: alt,
    suggestedName: suggestedName.isEmpty ? 'resource' : suggestedName,
    inlineBytes: _decodeDataUri(reference),
    width: width,
    remote: _isRemoteReference(reference),
  ));
  return resourcePlaceholder(index);
}

/// 可用引用：非空、非纯锚点、非 `javascript:`（§6.9）。
bool _isUsableReference(String ref) {
  final v = ref.trim();
  if (v.isEmpty) return false;
  if (v.startsWith('#')) return false;
  if (v.toLowerCase().startsWith('javascript:')) return false;
  return true;
}

/// 远端 / 带 scheme：`http(s)` / `mailto:` / `tel:` / `evernote://` / 其它带 scheme。
///
/// `data:` 虽带 scheme 但**不是**远端（要现场解码入库）。
bool _isRemoteReference(String ref) {
  final v = ref.trim().toLowerCase();
  if (v.startsWith('data:')) return false;
  return RegExp(r'^[a-z][a-z0-9+.-]*:').hasMatch(v);
}

/// 建议文件名：相对路径 basename（反斜杠也认）/ `data-` 按 MIME 推导 / 链接文字回退。
String _suggestedName(String reference, String alt) {
  final v = reference.trim();
  if (v.toLowerCase().startsWith('data:')) {
    final mime = RegExp(r'^data:([^;,]+)').firstMatch(v)?.group(1) ?? '';
    return '${alt.trim().isEmpty ? 'inline' : _sanitize(alt)}${_extForMime(mime)}';
  }
  final normalized = v.split('?').first.split('#').first.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  final base = slash < 0 ? normalized : normalized.substring(slash + 1);
  final decoded = _tryDecodeComponent(base).trim();
  if (decoded.isNotEmpty) return decoded;
  return alt.trim().isEmpty ? 'resource' : _sanitize(alt);
}

String _tryDecodeComponent(String raw) {
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

String _sanitize(String raw) =>
    raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');

String _extForMime(String mime) => switch (mime.toLowerCase()) {
      'image/png' => '.png',
      'image/jpeg' || 'image/jpg' => '.jpg',
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      'image/bmp' => '.bmp',
      'image/svg+xml' => '.svg',
      _ => '',
    };

/// 尺寸：`width` 属性或内联 `style="width:<N>px"`（正整数）→ `{width=N}`（BR-61.5）。
///
/// 百分比 / `em` / 无宽度 → `null`（不写属性块，按原始尺寸显示）。
int? _imageWidth(dom.Element node) {
  final parsed = int.tryParse((node.attributes['width'] ?? '').trim());
  if (parsed != null && parsed > 0) return parsed;
  final style = node.attributes['style'] ?? '';
  final m = RegExp(r'width\s*:\s*(\d+)\s*px', caseSensitive: false)
      .firstMatch(style);
  if (m == null) return null;
  final n = int.tryParse(m.group(1)!);
  return (n != null && n > 0) ? n : null;
}

/// `data:` URI 解码（`;base64,`）；失败 / 非法返回 `null`（走降级，AC-249）。
Uint8List? _decodeDataUri(String reference) {
  final v = reference.trim();
  if (!v.toLowerCase().startsWith('data:')) return null;
  final comma = v.indexOf(',');
  if (comma < 0) return null;
  final meta = v.substring(5, comma).toLowerCase();
  final payload = v.substring(comma + 1);
  if (!meta.contains('base64')) {
    // 非 base64 的 `data:`（百分号编码）：percent-decode 后按 UTF-8 取字节。
    try {
      return Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
    } catch (_) {
      return null;
    }
  }
  try {
    return base64Decode(payload.replaceAll(RegExp(r'\s'), ''));
  } catch (_) {
    return null;
  }
}
