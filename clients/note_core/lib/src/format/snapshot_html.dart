/// 网页快照的**受限内嵌 HTML**（FR-69 / ADR-028 决策 1）。
///
/// 快照正文 = Markdown 主干 + 少量**受限 HTML 块**（Markdown 无法表达的对齐 / 颜色 /
/// 背景 / 字号等版式）。HTML 块是正本里的**字面字符**（守「Markdown 唯一正本」，
/// 源码模式逐字可见、三态往返逐字节），故本文件只做两件事：
///
/// 1. **定位**：在正本里找出这些块（[htmlBlocks] / [htmlBlockAt]）——供格式模式把它们
///    当作**原子块**整体呈现与整块删除（承 BR-23.8 / BR-44.6）；
/// 2. **白名单化解析**：把块解析成节点树（[parseSnapshotHtml]）——供预览态与格式模式
///    渲染（两态同源，BR-69.3）。
///
/// 白名单在**服务端生成侧与客户端渲染侧双向收口**（BR-69.2 / 69.6）：标签、样式属性、
/// 元素属性三类都在这里收口，非法内容一律丢弃、只保留其文本（BR-69.3「不丢字」）。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// 允许作为 **HTML 块**（独占一行）的块级标签。
const Set<String> kSnapshotBlockTags = <String>{
  'div',
  'p',
  'center',
  'section',
  'figure',
  'figcaption',
  'blockquote',
  'table',
  'ul',
  'ol',
  'li',
  'pre',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
};

/// 允许出现在 HTML 块内部的**行内**标签。
const Set<String> kSnapshotInlineTags = <String>{
  'b',
  'strong',
  'i',
  'em',
  'u',
  's',
  'del',
  'strike',
  'code',
  'span',
  'sub',
  'sup',
  'mark',
  'font',
  'a',
  'img',
  'br',
};

/// 允许保留的内联样式属性（与网页快照服务端生成侧同一张表，BR-69.2）。
const Set<String> kSnapshotStyleProps = <String>{
  'text-align',
  'color',
  'background-color',
  'font-weight',
  'font-style',
  'text-decoration',
  'font-size',
  'text-indent',
  'width',
  'height',
};

/// **整块丢弃**的非内容标签（标签与其文本都不留，与快照服务端同一口径）。
///
/// 这些标签的文本不是「内容」（脚本源码、样式表、表单控件值…），若按「未知标签透明」
/// 处理就会把 `alert(1)` 之类当正文留下——既是注入面，也不是用户想看的笔记内容。
const Set<String> kSnapshotDroppedTags = <String>{
  'script',
  'style',
  'noscript',
  'template',
  'iframe',
  'object',
  'embed',
  'svg',
  'canvas',
  'video',
  'audio',
  'source',
  'form',
  'input',
  'button',
  'select',
  'option',
  'textarea',
  'meta',
  'link',
  'title',
  'head',
  'base',
};

/// 允许保留的元素属性（其余一律丢弃；`class` / `id` / `on*` 永不保留）。
const Set<String> kSnapshotAttributes = <String>{
  'style',
  'href',
  'src',
  'alt',
  'title',
  'width',
  'height',
  'align',
  'color',
  'colspan',
  'rowspan',
  'start',
};

/// 样式值白名单：只放行「单 token、只含安全字符」的值。
///
/// 这条正则同时挡掉了 `url(...)` / `expression(...)` / 带引号的字体名 / `!important`
/// 一类会破坏 Markdown 行内规整或带副作用的值（BR-69.6）。
final RegExp _safeStyleValue = RegExp(r'^[#a-zA-Z0-9,.%\-]{1,48}$');

/// 正本里的一个 **HTML 块**区间。
///
/// [end] 与表格区间同口径：块的**末字符之后**（即末行的行尾换行符下标，或文末）。
/// 故块下方的行首是 `end + 1`（`end < text.length` 时）。
class HtmlBlock {
  const HtmlBlock({required this.start, required this.end, required this.html});

  /// 块首字符下标（行首）。
  final int start;

  /// 块末字符之后（末行换行符下标或文末）。
  final int end;

  /// 块的完整 HTML 文本（不含行尾换行）。
  final String html;

  /// 规范化文本是否为空。
  bool get isEmpty => html.trim().isEmpty;
}

/// 正本中的全部 HTML 块（按出现顺序，FR-69 / §16.3）。
///
/// 识别口径与 CommonMark 的 HTML block 对齐到「我们生成的形态」：**行首**（≤3 空格）
/// 以 `<` + 白名单块级标签开头即为块首；块尾为同一行内出现的匹配闭合标签，否则向下找
/// 到闭合标签行 / 空行 / 文末（多行 HTML 块仍可识别，不把整篇吞成一块）。
List<HtmlBlock> htmlBlocks(String text) {
  final out = <HtmlBlock>[];
  if (text.isEmpty) return out;
  var lineStart = 0;
  while (lineStart <= text.length) {
    final nl = text.indexOf('\n', lineStart);
    final lineEnd = nl == -1 ? text.length : nl;
    final line = text.substring(lineStart, lineEnd);
    final tag = _openingBlockTag(line);
    if (tag == null) {
      if (nl == -1) break;
      lineStart = nl + 1;
      continue;
    }
    // 单行形态（我们生成的形态）：本行内已有匹配闭合标签。
    var blockEnd = lineEnd;
    if (!_containsCloseTag(line, tag)) {
      // 多行形态：向下找闭合标签所在行（空行也结束该块，避免吞掉后续全部内容）。
      var probeStart = nl == -1 ? text.length : nl + 1;
      while (probeStart <= text.length) {
        final pnl = text.indexOf('\n', probeStart);
        final pEnd = pnl == -1 ? text.length : pnl;
        final pLine = text.substring(probeStart, pEnd);
        blockEnd = pEnd;
        if (_containsCloseTag(pLine, tag) || pLine.trim().isEmpty) break;
        if (pnl == -1) break;
        probeStart = pnl + 1;
      }
    }
    out.add(HtmlBlock(
      start: lineStart,
      end: blockEnd,
      html: text.substring(lineStart, blockEnd).trim(),
    ));
    if (nl == -1) break;
    lineStart = nl + 1;
  }
  return out;
}

/// [offset] 落在某个 HTML 块区间内（含块下方默认行的行首，与表格同口径）时返回该块。
HtmlBlock? htmlBlockAt(String text, int offset) {
  for (final block in htmlBlocks(text)) {
    final upper = block.end < text.length ? block.end + 1 : block.end;
    if (offset >= block.start && offset <= upper) return block;
  }
  return null;
}

/// 行首是否为白名单块级标签的开标签；是则返回标签名。
String? _openingBlockTag(String line) {
  final m = RegExp(r'^[ \t]{0,3}<\s*([a-zA-Z][a-zA-Z0-9]*)').firstMatch(line);
  if (m == null) return null;
  final tag = m.group(1)!.toLowerCase();
  return kSnapshotBlockTags.contains(tag) ? tag : null;
}

/// [line] 内是否含 `</tag>`（大小写不敏感、允许空白）。
bool _containsCloseTag(String line, String tag) =>
    RegExp('</\\s*$tag\\s*>', caseSensitive: false).hasMatch(line);

// ---------------------------------------------------------------------------
// 白名单化解析（渲染侧的输入）
// ---------------------------------------------------------------------------

/// 白名单化后的快照 HTML 节点。
sealed class SnapshotNode {
  const SnapshotNode();
}

/// 文本节点（[text] 已做实体解码与空白规整）。
class SnapshotText extends SnapshotNode {
  const SnapshotText(this.text);

  final String text;
}

/// 元素节点：只保留白名单标签 / 样式 / 属性。
class SnapshotElement extends SnapshotNode {
  const SnapshotElement({
    required this.tag,
    required this.children,
    required this.styles,
    required this.attributes,
    required this.block,
  });

  final String tag;
  final List<SnapshotNode> children;

  /// 白名单化后的内联样式（键小写）。
  final Map<String, String> styles;

  /// 白名单化后的元素属性。
  final Map<String, String> attributes;

  /// 是否块级元素（渲染层据此决定换行与对齐方式）。
  final bool block;

  /// 合并了 [styles] 与语义标签（`<b>` / `<i>` / `<u>` / `<s>` / `<code>` …）后的
  /// **呈现样式**，供渲染层直接取用（不在渲染层重复判定标签语义）。
  Map<String, String> get effectiveStyles {
    final out = Map<String, String>.from(styles);
    switch (tag) {
      case 'b' || 'strong':
        out.putIfAbsent('font-weight', () => 'bold');
      case 'i' || 'em':
        out.putIfAbsent('font-style', () => 'italic');
      case 'u':
        out.putIfAbsent('text-decoration', () => 'underline');
      case 's' || 'del' || 'strike':
        out.putIfAbsent('text-decoration', () => 'line-through');
      case 'mark':
        out.putIfAbsent('background-color', () => '#ffff00');
      case 'sub' || 'sup':
        out.putIfAbsent('vertical-align', () => tag);
    }
    return out;
  }
}

/// 把一段快照 HTML 解析为**白名单化**的节点树（根为合成的 `div`）。
///
/// 非法标签 / 样式 / 属性一律丢弃，但**文本一律保留**（BR-69.3 不丢字）；
/// 解析失败时返回只含原始文本的根（调用方据此降级为纯文本呈现，绝不空白）。
SnapshotElement parseSnapshotHtml(String html) {
  final dom.DocumentFragment fragment;
  try {
    fragment = html_parser.parseFragment(html);
  } catch (_) {
    return SnapshotElement(
      tag: 'div',
      children: <SnapshotNode>[SnapshotText(html)],
      styles: const <String, String>{},
      attributes: const <String, String>{},
      block: true,
    );
  }
  final children = <SnapshotNode>[];
  for (final node in fragment.nodes) {
    final converted = _convert(node);
    if (converted != null) children.add(converted);
  }
  return SnapshotElement(
    tag: 'div',
    children: children,
    styles: const <String, String>{},
    attributes: const <String, String>{},
    block: true,
  );
}

SnapshotNode? _convert(dom.Node node) {
  if (node is dom.Text) {
    final text = node.text.replaceAll(RegExp(r'[\s\u00a0]+'), ' ');
    return text.isEmpty ? null : SnapshotText(text);
  }
  if (node is! dom.Element) return null;
  final tag = node.localName?.toLowerCase() ?? '';
  // 非内容标签：整块丢弃（文本也不留，见 [kSnapshotDroppedTags]）。
  if (kSnapshotDroppedTags.contains(tag)) return null;
  final isBlock = kSnapshotBlockTags.contains(tag);
  if (!isBlock && !kSnapshotInlineTags.contains(tag)) {
    // 非白名单元素：**透明**（保留其子内容，不保留元素本身）。
    final kids = <SnapshotNode>[];
    for (final child in node.nodes) {
      final converted = _convert(child);
      if (converted != null) kids.add(converted);
    }
    if (kids.length == 1) return kids.first;
    return SnapshotElement(
      tag: 'span',
      children: kids,
      styles: const <String, String>{},
      attributes: const <String, String>{},
      block: false,
    );
  }
  final attributes = <String, String>{};
  for (final entry in node.attributes.entries) {
    // `package:html` 的 `attributes` 是 `Map<Object, String>`，键必须先转字符串。
    final key = entry.key.toString().toLowerCase();
    if (!kSnapshotAttributes.contains(key)) continue;
    final value = entry.value.trim();
    if (value.isEmpty) continue;
    if (key == 'style') continue; // style 走样式白名单，单独收口。
    attributes[key] = value;
  }
  final children = <SnapshotNode>[];
  for (final child in node.nodes) {
    final converted = _convert(child);
    if (converted != null) children.add(converted);
  }
  return SnapshotElement(
    tag: tag,
    children: children,
    styles: parseSnapshotStyle(node.attributes['style']),
    attributes: attributes,
    block: isBlock,
  );
}

/// 解析并**白名单化**内联 `style`（键与值都收口；非法值丢弃）。
Map<String, String> parseSnapshotStyle(String? raw) {
  final out = <String, String>{};
  if (raw == null || raw.isEmpty) return out;
  for (final part in raw.split(';')) {
    final i = part.indexOf(':');
    if (i <= 0) continue;
    final key = part.substring(0, i).trim().toLowerCase();
    final value = part.substring(i + 1).trim();
    if (!kSnapshotStyleProps.contains(key)) continue;
    if (!_safeStyleValue.hasMatch(value)) continue;
    out[key] = value.toLowerCase();
  }
  return out;
}
