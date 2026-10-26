/// 编辑器格式化：工具栏指令 → 标准 Markdown 语法的纯函数映射。
///
/// 依据 [ADR-006]（轻量格式化编辑，Markdown 为唯一正本）与
/// [ADR-007]（图片尺寸以 Markdown 兼容语法持久化）。
///
/// 本文件**只做文本变换**，不持有任何文档模型、不依赖 Flutter：
/// - [apply] 把「工具栏指令 + 当前选区」映射为「新正本 + 新选区」；
/// - [insertImage] 生成 `![文件名](sui://<sha256>)[{...}]` 引用；
/// - [findImage] / [parseSizeAttribute] / [setImageSize] 读写图片尺寸属性块；
/// - [escapePlainText] / [htmlToMarkdown] 处理粘贴来源。
///
/// 所有产出均为标准 Markdown，未识别语法原样透传（BR-23.1 / BR-23.3）。
library;

import 'snapshot_html.dart';

/// 工具栏格式指令。作用域见 editor-formatting.md §3。
///
/// M5 起补充 `highlight` / `taskList` / `indent` / `outdent` / `clearFormat`：
/// 与工具栏按钮**同一套**实现（BR-30.4），快捷键只是它的另一个入口（§9）。
enum FormatCommand {
  bold,
  italic,
  strikethrough,
  highlight,
  heading1,
  heading2,
  heading3,
  bulletList,
  orderedList,
  taskList,
  blockquote,
  codeBlock,
  link,
  divider,
  indent,
  outdent,
  clearFormat,
}

/// 文本变换结果：新正本 + 新选区（供 UI 回填 `TextEditingController`）。
class FormatResult {
  final String text;
  final int selectionStart;
  final int selectionEnd;

  const FormatResult(this.text, this.selectionStart, this.selectionEnd);
}

/// 尺寸单位：像素或百分比。
enum SizeUnit { pixel, percent }

/// 单维度尺寸值（像素或百分比）。
class ImageDimension {
  final int value;
  final SizeUnit unit;

  const ImageDimension(this.value, this.unit);

  @override
  String toString() => unit == SizeUnit.percent ? '$value%' : '$value';

  @override
  bool operator ==(Object other) =>
      other is ImageDimension && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);
}

/// 图片尺寸：宽 / 高可各自缺省（缺省=按原图比例自适应）。
class ImageSize {
  final ImageDimension? width;
  final ImageDimension? height;

  const ImageSize({this.width, this.height});

  /// 自适应：无任何尺寸属性。
  static const ImageSize auto = ImageSize();

  bool get isAuto => width == null && height == null;

  @override
  bool operator ==(Object other) =>
      other is ImageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'ImageSize(${width ?? '-'}, ${height ?? '-'})';
}

/// 一个图片引用的解析结果（含紧随其后的可选尺寸属性块位置）。
class ParsedImage {
  final String alt;
  final String url;
  final ImageSize size;

  /// 图片引用 `![alt](url)` 在原串中的起止。
  final int start;
  final int end;

  /// 尺寸属性块 `{...}` 的起止；无属性块时为 -1。
  final int attributeStart;
  final int attributeEnd;

  /// 属性块是否被识别为合法的尺寸属性（false 时按普通正文透传）。
  final bool attributeValid;

  const ParsedImage({
    required this.alt,
    required this.url,
    required this.size,
    required this.start,
    required this.end,
    this.attributeStart = -1,
    this.attributeEnd = -1,
    this.attributeValid = false,
  });
}

/// 表格列对齐：编码于 GFM 分隔行（§12.1）。
///
/// [none] 为缺省（渲染为左对齐 `---`）；[left] 显式写 `:---`。
enum TableColumnAlign { none, left, center, right }

/// 一个 GFM 管道表的解析结果（M9 / FR-44 / §12.1）。
///
/// [header] / [rows] 内单元格为**原始文本**（保留 `\|` 等转义原样），
/// 以便结构编辑时未编辑单元格**逐字回写**（保 §4.1）。
class ParsedTable {
  /// 表格块在原文中的起止（按 `\n` 分隔的行区间，不含块外空白）。
  final int start;
  final int end;

  /// 表头单元格。
  final List<String> header;

  /// 各列对齐（长度与 [header] 一致）。
  final List<TableColumnAlign> aligns;

  /// 数据行；残缺表时各行列数可能与 [header] 不一致。
  final List<List<String>> rows;

  /// 是否为合规管道表（表头行 + 分隔行且列数一致）。
  final bool wellFormed;

  const ParsedTable({
    required this.start,
    required this.end,
    required this.header,
    required this.aligns,
    required this.rows,
    required this.wellFormed,
  });
}

/// 一个附件引用的解析结果（M9 / FR-46 / §12.4）。
///
/// 覆盖两种形态：图片 `![alt](sui://<sha256>)` 与附件链接 `[name](sui://<sha256>)`；
/// 图片若紧随 §5 尺寸属性块 `{...}`，则 [end] 一并覆盖该属性块（删除 / 移动时整体处理）。
///
/// [corrupt] 标记为「残缺引用」（缺 `)`、`](` 不成对等）——仍按整块识别
/// （§12.4「残缺自愈」），由视图层决定就地修复或整块处理。
class AttachmentRef {
  /// 引用起始（`!` 或 `[`）。
  final int start;

  /// 引用结束（含 `)`；图片含尺寸属性块）；残缺时为可识别的末端。
  final int end;

  /// `alt` / `name` 文本。
  final String label;

  /// 内容寻址的 sha256（`sui://` 之后）。
  final String sha256;

  /// 是否为图片引用（`![...]`）；false 为附件链接（`[...]`）。
  final bool isImage;

  /// 是否为残缺引用（缺少闭合 `)`）。
  final bool corrupt;

  const AttachmentRef({
    required this.start,
    required this.end,
    required this.label,
    required this.sha256,
    required this.isImage,
    this.corrupt = false,
  });

  /// 引用重写为规范文本时使用（去掉可选尺寸属性块，属性块由图片层单独管理）。
  String get markdown =>
      isImage ? '![$label](sui://$sha256)' : '[$label](sui://$sha256)';

  @override
  String toString() =>
      'AttachmentRef(${isImage ? 'img' : 'link'}, [$start,$end), '
      '$sha256${corrupt ? ', corrupt' : ''})';
}

/// 一处**网页原件**引用（M16 / FR-83）。
///
/// 正本形态：`[网页原件](sui://webclip/<64 位小写 hex>)`，独占一行。
/// 原件字节是内容寻址附件（mimeKind = `webclip`），本类只描述正本里的区间。
class WebClipRef {
  const WebClipRef({
    required this.start,
    required this.end,
    required this.label,
    required this.sha256,
  });

  /// `[` 在正本中的下标。
  final int start;

  /// `)` 之后一位（区间右开）。
  final int end;

  /// 链接显示文字（当前恒为「网页原件」）。
  final String label;

  /// 原件 HTML 的 sha256（小写十六进制）。
  final String sha256;

  @override
  String toString() => 'WebClipRef([$start,$end), $sha256)';
}

/// 一处 Markdown 行内链接 `[显示文字](网址)` 的解析结果（FR-70 / §16）。
///
/// 只覆盖**单行**链接（与格式模式的记号扫描同口径）；图片引用 `![alt](url)`、
/// `sui://` 附件引用（附件有自己的原子单元，见 §12.4）与未闭合的残缺引用**不算**链接。
class MarkdownLink {
  const MarkdownLink({
    required this.start,
    required this.end,
    required this.label,
    required this.url,
  });

  /// `[` 在正本中的下标。
  final int start;

  /// `)` 之后一位（区间右开）。
  final int end;

  /// 显示文字。
  final String label;

  /// 目标地址（**原样**，未做协议补全；是否可打开由 UI 层的协议白名单判定）。
  final String url;
}

/// 格式化工具栏的纯函数实现。
abstract final class EditorFormat {
  /// 预设「小 / 中 / 大」；「原始」对应 [ImageSize.auto]。
  static const ImageSize presetSmall =
      ImageSize(width: ImageDimension(25, SizeUnit.percent));
  static const ImageSize presetMedium =
      ImageSize(width: ImageDimension(50, SizeUnit.percent));
  static const ImageSize presetLarge =
      ImageSize(width: ImageDimension(100, SizeUnit.percent));

  /// 应用格式指令：[selectionStart] / [selectionEnd] 为当前选区（相同即光标）。
  static FormatResult apply(
    FormatCommand command,
    String text,
    int selectionStart,
    int selectionEnd,
  ) {
    switch (command) {
      case FormatCommand.bold:
        return _inline(text, selectionStart, selectionEnd, '**');
      case FormatCommand.italic:
        return _inline(text, selectionStart, selectionEnd, '*');
      case FormatCommand.strikethrough:
        return _inline(text, selectionStart, selectionEnd, '~~');
      case FormatCommand.heading1:
        return _heading(text, selectionStart, selectionEnd, 1);
      case FormatCommand.heading2:
        return _heading(text, selectionStart, selectionEnd, 2);
      case FormatCommand.heading3:
        return _heading(text, selectionStart, selectionEnd, 3);
      case FormatCommand.bulletList:
        return _bulletList(text, selectionStart, selectionEnd);
      case FormatCommand.orderedList:
        return _orderedList(text, selectionStart, selectionEnd);
      case FormatCommand.blockquote:
        return _blockquote(text, selectionStart, selectionEnd);
      case FormatCommand.codeBlock:
        return _codeBlock(text, selectionStart, selectionEnd);
      case FormatCommand.link:
        return _link(text, selectionStart, selectionEnd);
      case FormatCommand.divider:
        return _divider(text, selectionStart, selectionEnd);
      case FormatCommand.highlight:
        // 高亮只作用于当前**选中文本**：无选区时不插入占位标记（BR-31.7）。
        return _inline(
          text,
          selectionStart,
          selectionEnd,
          '==',
          requireSelection: true,
        );
      case FormatCommand.taskList:
        return _taskList(text, selectionStart, selectionEnd);
      case FormatCommand.indent:
        return _indent(text, selectionStart, selectionEnd);
      case FormatCommand.outdent:
        return _outdent(text, selectionStart, selectionEnd);
      case FormatCommand.clearFormat:
        return _clearFormat(text, selectionStart, selectionEnd);
    }
  }

  // ---------------------------------------------------------------------------
  // 行内指令
  // ---------------------------------------------------------------------------

  /// [requireSelection] 为 true 时，无选区（纯光标）**不插入占位标记**，原样返回
  /// （高亮等「只作用于选中文本」的指令，BR-31.7）；为 false 时在光标处插入一对标记。
  ///
  /// **记号集合语义**（FR-80 / BR-80.1\~80.3）：有选区时**不再只看选区两端**，而是取
  /// [syntaxMarkers] 中**同类**记号（`**`→strong / `*`→emphasis / `~~`→strike /
  /// `==`→highlight）的完整对，把选区**外扩**到与之相交或紧贴者；外扩区间内含完整同类对
  /// 且「移除区间内**全部同类**记号后的可见内容」非空 → **取消**（一次编辑删净同类记号、
  /// 内容逐字保留、新选区覆盖内容）；否则 → **包裹**（既有行为，幂等）。
  /// 不同类记号互不吞噬（BR-80.2），以记号分类实现，取代旧的「选区两端字符串前后缀」判据。
  static FormatResult _inline(
    String text,
    int start,
    int end,
    String marker, {
    bool requireSelection = false,
  }) {
    final s = start.clamp(0, text.length);
    final e = end.clamp(0, text.length);

    // 无选区：默认插入一对标记并把光标置于其中；要求选区时原样返回。
    if (s == e) {
      if (requireSelection) {
        return FormatResult(text, s, e);
      }
      final newText = text.substring(0, s) + marker + marker + text.substring(e);
      final pos = s + marker.length;
      return FormatResult(newText, pos, pos);
    }

    final lo0 = s <= e ? s : e;
    final hi0 = s <= e ? e : s;
    final selected = text.substring(lo0, hi0);

    final kind = _inlineKindOf(marker);
    if (kind != null) {
      final groups = _sameKindGroups(text, kind);
      // 外扩：反复吸收与当前区间**严格相交**的完整同类对，直到稳定。
      //
      // 口径（v0.15.0 主线复核修正）：判据是「对区间 `[open.start, close.end)` 与选区
      // `[lo, hi)` 相交」，即 `open.start < hi && close.end > lo`——**不含「仅紧贴」**。
      // 若写成 `open.start <= hi && close.end >= lo`，则「选区起点正好等于相邻对的
      // `close.end`」（逐字加斜体的关键路径：`*甲*乙` 里选 `乙`）也会被吸收 → 误走「取消」
      // 分支、把前一段的格式吞掉（实测：`甲乙丙丁` 逐字点斜体第二步得 `甲乙丙丁`）。
      // 严格相交仍覆盖全部既有取消路径：选区含整对 / 选区恰为内容 / 全选多段都成立。
      var lo = lo0;
      var hi = hi0;
      var grew = true;
      while (grew) {
        grew = false;
        for (final g in groups) {
          final open = g.first;
          final close = g.last;
          if (open.start < hi && close.end > lo) {
            if (open.start < lo) {
              lo = open.start;
              grew = true;
            }
            if (close.end > hi) {
              hi = close.end;
              grew = true;
            }
          }
        }
      }

      // 取消判据（BR-80.3）：外扩区间内至少一个**完整**同类对，且去记号后内容非空。
      final cuts = <(int, int)>[];
      for (final g in groups) {
        final open = g.first;
        final close = g.last;
        if (open.start < lo || close.end > hi) continue;
        cuts.add((open.start, open.end));
        cuts.add((close.start, close.end));
      }
      if (cuts.isNotEmpty) {
        cuts.sort((a, b) => a.$1.compareTo(b.$1));
        final buf = StringBuffer();
        var cursor = lo;
        for (final c in cuts) {
          if (c.$1 > cursor) buf.write(text.substring(cursor, c.$1));
          if (c.$2 > cursor) cursor = c.$2;
        }
        if (cursor < hi) buf.write(text.substring(cursor, hi));
        final visible = buf.toString();
        if (visible.isNotEmpty) {
          final newText = text.substring(0, lo) + visible + text.substring(hi);
          return FormatResult(newText, lo, lo + visible.length);
        }
      }
    }

    final before = text.substring(0, lo0);
    final after = text.substring(hi0);
    final newText = before + marker + selected + marker + after;
    return FormatResult(newText, lo0 + marker.length, hi0 + marker.length);
  }

  /// 行内指令标记 → 记号种类（FR-80「只删同类」的判据，BR-80.2）。
  static SyntaxMarkerKind? _inlineKindOf(String marker) {
    if (marker == '**') return SyntaxMarkerKind.strong;
    if (marker == '*') return SyntaxMarkerKind.emphasis;
    if (marker == '~~') return SyntaxMarkerKind.strike;
    if (marker == '==') return SyntaxMarkerKind.highlight;
    return null;
  }

  /// 正本中**同类**成对记号的两两分组（FR-80）。
  ///
  /// 只保留恰好两个成员、且 `open.end <= close.start` 的**完整对**；残缺 / 重叠组
  /// **不参与判定**（BR-80.3）。每组内按 `start` 升序：[0] 为开记号、[1] 为闭记号。
  static List<List<SyntaxMarker>> _sameKindGroups(
    String text,
    SyntaxMarkerKind kind,
  ) {
    final byPair = <int, List<SyntaxMarker>>{};
    for (final m in syntaxMarkers(text)) {
      if (m.kind != kind || m.pairId == null) continue;
      byPair.putIfAbsent(m.pairId!, () => <SyntaxMarker>[]).add(m);
    }
    final out = <List<SyntaxMarker>>[];
    for (final group in byPair.values) {
      if (group.length != 2) continue;
      final sorted = [...group]..sort((a, b) => a.start.compareTo(b.start));
      if (sorted.first.end > sorted.last.start) continue;
      out.add(sorted);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 块级指令（按行处理选区覆盖的所有行）
  // ---------------------------------------------------------------------------

  static FormatResult _heading(String text, int start, int end, int level) {
    final prefix = '${'#' * level} ';
    return _mapLines(text, start, end, (line, _) {
      final m = RegExp(r'^(#{1,6})(\s+)(.*)$').firstMatch(line);
      if (m != null) {
        final existing = m.group(1)!.length;
        final content = m.group(3)!;
        // 同级别 → 取消；不同级别 → 降级 / 升级到目标级别。
        return existing == level ? content : '$prefix$content';
      }
      return '$prefix$line';
    });
  }

  static FormatResult _bulletList(String text, int start, int end) {
    return _mapLines(text, start, end, (line, _) {
      if (RegExp(r'^[-*+]\s+').hasMatch(line)) {
        return line.replaceFirst(RegExp(r'^[-*+]\s+'), '');
      }
      return '- $line';
    });
  }

  static FormatResult _orderedList(String text, int start, int end) {
    // M9 惰性编号（FR-48 / editor-formatting.md §12.5）：连续有序列表在正本中
    // **统一写作 `1.`**，由渲染层按序编号（见 [orderedListNumbers]），
    // 插入 / 删除项后天然重排、零正本改写；`orderedList` 指令不再写实序号。
    return _mapLines(text, start, end, (line, _) {
      if (RegExp(r'^\d+\.\s+').hasMatch(line)) {
        return line.replaceFirst(RegExp(r'^\d+\.\s+'), '');
      }
      return '1. $line';
    });
  }

  static FormatResult _blockquote(String text, int start, int end) {
    return _mapLines(text, start, end, (line, _) {
      if (line.startsWith('> ')) return line.substring(2);
      if (line == '>') return '';
      return '> $line';
    });
  }

  static FormatResult _codeBlock(String text, int start, int end) {
    final (blockStart, blockEnd) = _blockRange(text, start, end);
    final block = text.substring(blockStart, blockEnd);
    final lines = block.split('\n');
    const fence = '```';

    final isFenced = lines.length >= 2 &&
        lines.first.trimLeft().startsWith(fence) &&
        lines.last.trim() == fence;

    if (isFenced) {
      final inner = lines.sublist(1, lines.length - 1).join('\n');
      final newText =
          text.substring(0, blockStart) + inner + text.substring(blockEnd);
      return FormatResult(newText, blockStart, blockStart + inner.length);
    }

    final fenced = '$fence\n$block\n$fence';
    final newText =
        text.substring(0, blockStart) + fenced + text.substring(blockEnd);
    final innerStart = blockStart + fence.length + 1;
    return FormatResult(newText, innerStart, innerStart + block.length);
  }

  /// 链接的**文字 / 网址规范化**结果（[renderLink] 与「选中占位符」口径共用同一套规则）。
  ///
  /// - 两端空白裁掉；「显示文字」为空时**以网址本身充当**；
  /// - 网址**未写协议**时补 `https://`（见 [_normalizeUrl]）。
  static ({String label, String url}) _linkParts({
    required String label,
    required String url,
  }) {
    final u = _normalizeUrl(url.trim());
    final l = label.trim().isEmpty ? u : label.trim();
    return (label: l, url: u);
  }

  /// 网址规范化：**未写协议时补 `https://`**（BR-23.10④）。
  ///
  /// `mailto:` / `tel:` / `data:` 等已带协议者、以及 `#锚点` / `/相对路径` 一律**原样保留**
  /// ——否则会把它们变成 `https://#锚点` 这类打不开的地址。
  static String _normalizeUrl(String raw) {
    if (raw.isEmpty) return raw;
    if (raw.startsWith('#') || raw.startsWith('/')) return raw;
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:').hasMatch(raw);
    return hasScheme ? raw : 'https://$raw';
  }

  /// 生成标准 Markdown 超链接 `[显示文字](网址)`（BR-23.2 不变）。
  ///
  /// [url] 为空时返回**空串**（调用方据此**不落笔**，正本一字不动，BR-23.10②）。
  static String renderLink({required String label, required String url}) {
    if (url.trim().isEmpty) return '';
    final p = _linkParts(label: label, url: url);
    return '[${p.label}](${p.url})';
  }

  /// 在选区处替换 / 光标处插入超链接（**链接录入弹框**的落笔口径，§14.1 / BR-23.10）。
  ///
  /// - [url] 为空 → **原样返回**（不落笔，正本一字不动）；
  /// - 否则按 [renderLink] 生成 `[显示文字](网址)` 并替换选区、**光标落到链接之后**（便于继续输入）。
  static FormatResult insertLink(
    String text,
    int start,
    int end, {
    required String label,
    required String url,
  }) {
    final s = start.clamp(0, text.length);
    final e = end.clamp(0, text.length);
    final lo = s <= e ? s : e;
    final hi = s <= e ? e : s;
    if (url.trim().isEmpty) return FormatResult(text, lo, hi);
    final md = renderLink(label: label, url: url);
    final newText = text.substring(0, lo) + md + text.substring(hi);
    final caret = (lo + md.length).clamp(0, newText.length);
    return FormatResult(newText, caret, caret);
  }

  /// 纯指令口径的链接插入（**保留 `FormatCommand.link` 的既有行为**）：`文字` + `url` 占位符，
  /// 并**选中占位符**便于直接输入地址。
  ///
  /// 与弹框口径（[insertLink] / [renderLink]）的区别：此处 `url` 是**占位符而非真实网址**，
  /// 故**不做协议补全**（否则会变成 `https://url`）。UI 侧工具栏与 `Ctrl+K` 已改为弹框录入。
  static FormatResult _link(String text, int start, int end) {
    final s = start.clamp(0, text.length);
    final e = end.clamp(0, text.length);
    final label = s == e ? '文字' : text.substring(s, e);
    const url = 'url';
    final md = '[$label]($url)';
    final newText = text.substring(0, s) + md + text.substring(e);
    // 选中 url 占位符，便于直接输入地址。
    final urlStart = s + 1 + label.length + 2;
    return FormatResult(newText, urlStart, urlStart + url.length);
  }

  /// 分割线（M2 起；`v0.14.1` 改为插到光标下方；`v0.14.3` 起**正本按标准 Markdown**、
  /// **格式/预览渲染为紧贴的分割线**）。
  ///
  /// 三条硬口径：
  ///
  /// - **正本（源码态）**：`---` **上方保证一个空行**、**下方不再补空行**（紧随原有正文）——
  ///   插入后即 `段落1\n\n---\n段落2`。这仍是标准 CommonMark（`---` 前有空行即为主题分隔线，
  ///   其后紧跟正文不影响判定），与 Gitea / GitHub / Typora 的语义一致（BR-72.1）；
  ///   `段落\n---`（`---` 紧贴上一行、无空行）仍按 CommonMark 解析为 **setext 二级标题**
  ///   （BR-72.7），要二级标题请用 `##`。
  /// - **渲染（格式/预览态）**：分割线是「把 `\n---\n` 当作一个整体」的原子块——规则记号的
  ///   区间**含「上方空行的行尾换行 + `---` 行 + 该行自身的行尾换行」**（[_scanLineMarkers]），
  ///   呈现层据此折叠为一个**紧贴**的规则 WidgetSpan（内部换行以 U+2060 顶替、不建立行盒），
  ///   视觉上不出现「段落1 / 空行 / 分割线 / 空行 / 段落2」的多余行（BR-72.2 / BR-72.3）。
  /// - **幂等切换**：光标停在**分割线行**上（`---` 且上方不是段落；`***` / `___` 恒为分割线），
  ///   或停在**紧贴其下方那一行的行首**（规则记号区间吸收了 `---` 行自身的行尾换行后，该行
  ///   不再有可停的光标位，光标会被吸附到这一处，与「停在分割线行上」等价）时，再次触发
  ///   = **移除**该行（BR-72.4）。
  ///
  /// 表格 / 围栏代码块内**不打断结构**：锚点取到整块之后（同 BR-44.11 的保护口径）。
  static FormatResult _divider(String text, int start, int end) {
    final n = text.length;
    var (lineStart, lineEnd) = _blockRange(text, start, end);
    var trimmed = text.substring(lineStart, lineEnd).trim();
    var isRule = (trimmed == '---' || trimmed == '***' || trimmed == '___') &&
        (trimmed != '---' || _isThematicBreak(text, lineStart));
    // 光标吸附落点补偿（BR-72.4）：规则记号区间已含 `---` 行自身的行尾换行，**该行整行都在
    // 记号内**，故不再有可停的光标位（光标会被送出区间），吸附落点只剩两处：上方空行的行首、
    // 下一行的行首。后者与「停在分割线行上」等价（分割线被折叠成原子块，光标"跨过"它就落在
    // 其下方），故一并按命中分割线处理——否则「插入后光标就在该处，再点一次却变成又插一条」
    // 的幂等切换会失效。
    if (!isRule && start == end && start == lineStart && lineStart > 0) {
      final prevEnd = lineStart - 1;
      final prevStart =
          prevEnd == 0 ? 0 : text.lastIndexOf('\n', prevEnd - 1) + 1;
      final prevTrimmed = text.substring(prevStart, prevEnd).trim();
      if ((prevTrimmed == '---' ||
              prevTrimmed == '***' ||
              prevTrimmed == '___') &&
          (prevTrimmed != '---' || _isThematicBreak(text, prevStart))) {
        lineStart = prevStart;
        lineEnd = prevEnd;
        trimmed = prevTrimmed;
        isRule = true;
      }
    }
    if (isRule) {
      var removeEnd = lineEnd;
      if (removeEnd < n && text[removeEnd] == '\n') removeEnd++;
      final out = text.substring(0, lineStart) + text.substring(removeEnd);
      // 移除后若与相邻空行连成 ≥3 个换行，折叠为一个空行（不制造多余空行，BR-72.3）。
      if (lineStart > 0 &&
          out.length > lineStart &&
          out[lineStart - 1] == '\n' &&
          out[lineStart] == '\n') {
        final collapsed =
            out.substring(0, lineStart) + out.substring(lineStart + 1);
        return FormatResult(collapsed, lineStart, lineStart);
      }
      return FormatResult(out, lineStart, lineStart);
    }

    // 插入点 = 锚点行**行尾换行之后**（即光标下方那一行的起点）。
    // 上方要不要补空行由 `pre` 的后缀统一决定（见下方 `lead` 三分支）；`tail` 原样接在
    // `---\n` 之后，**下方不补空行**——`v0.14.1` 的「中间多出一行」正是补出来的那一行。
    final anchorEnd = _dividerAnchorEnd(text, lineStart, lineEnd);
    final hasNewline = anchorEnd < n && text[anchorEnd] == '\n';
    final pos = hasNewline ? anchorEnd + 1 : anchorEnd;
    final pre = text.substring(0, pos);
    final tail = text.substring(pos);

    // 上方：`pre` 已以空行结尾（`\n\n`）→ 复用既有空行；以单个 `\n` 结尾 → 补一个换行凑成
    // 空行；文末无换行（`pre` 不以 `\n` 结尾）→ 补两个换行。
    final String lead;
    if (pre.isEmpty || pre.endsWith('\n\n')) {
      lead = '';
    } else if (pre.endsWith('\n')) {
      lead = '\n';
    } else {
      lead = '\n\n';
    }
    // 下方**不补**空行：`---\n` 之后直接接 `tail`；确有空行时由 `tail` 自身携带
    // （如表格 / 围栏代码块锚点外移后，`tail` 以 `\n` 开头）。
    final insert = '$lead---\n';
    final newText = '$pre$insert$tail';
    final caret = pos + insert.length;
    return FormatResult(newText, caret, caret);
  }

  /// 分割线插入的**锚点行尾**：默认取光标所在行；光标落在**良构表格**或**围栏代码块**内部时，
  /// 锚点扩展到整个块之后——避免把表格打断成两截、或把 `---` 写进代码块内容。
  static int _dividerAnchorEnd(String text, int lineStart, int lineEnd) {
    for (final (ts, te) in _wellFormedTableRanges(text)) {
      if (lineStart >= ts && lineStart <= te) return te;
    }
    return _fenceBlockEndAt(text, lineStart) ?? lineEnd;
  }

  /// 行 [lineStart] 所在**围栏代码块**的结束行尾；不在任何围栏内时返回 null。
  ///
  /// 未闭合的围栏（文档中途开了 ``` 就没了）锚到文末——此时「块之后」即文档末尾。
  static int? _fenceBlockEndAt(String text, int lineStart) {
    final n = text.length;
    int? openStart;
    var ls = 0;
    while (ls <= n) {
      final nl = text.indexOf('\n', ls);
      final le = nl == -1 ? n : nl;
      if (_fencePrefixRe.hasMatch(text.substring(ls, le))) {
        if (openStart == null) {
          openStart = ls;
        } else {
          if (lineStart >= openStart && lineStart <= le) return le;
          openStart = null;
        }
      }
      if (le >= n) break;
      ls = le + 1;
    }
    return openStart != null && lineStart >= openStart ? n : null;
  }

  static FormatResult _taskList(String text, int start, int end) {
    return _mapLines(text, start, end, (line, _) {
      final m = _taskLine.firstMatch(line);
      if (m != null) {
        final checked = m.group(2)!.toLowerCase() == 'x';
        return '${m.group(1)}[${checked ? ' ' : 'x'}]${m.group(3)}';
      }
      // 空行也保留标记后的空格：`- [ ] ` + 键入首字 = 合法任务项 `- [ ] 甲`。
      return line.isEmpty ? '- [ ] ' : '- [ ] $line';
    });
  }

  /// 切换 [offset] 所在行的任务项勾选态（`[ ]` ↔ `[x]`）。
  ///
  /// 非任务项行返回 null（按普通正文处理，不误改）。仅改动方括号内一个字符，
  /// 行内其余字符逐字不动（BR-31.2 / `TaskListToggleRoundTrip`）。
  static FormatResult? toggleTaskChecked(
    String text,
    int offset, [
    int? caretEnd,
  ]) {
    final s = offset.clamp(0, text.length);
    final e = (caretEnd ?? offset).clamp(0, text.length);
    final lineStart = s == 0 ? 0 : text.lastIndexOf('\n', s - 1) + 1;
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd == -1) lineEnd = text.length;
    final m = _taskLine.firstMatch(text.substring(lineStart, lineEnd));
    if (m == null) return null;
    final checked = m.group(2)!.toLowerCase() == 'x';
    final newLine = '${m.group(1)}[${checked ? ' ' : 'x'}]${m.group(3)}';
    final newText =
        text.substring(0, lineStart) + newLine + text.substring(lineEnd);
    return FormatResult(newText, s, e);
  }

  /// 块级呈现单元内按下回车时的正本变换（仅格式化模式，§11.2 / BR-32.4）。
  ///
  /// 返回 null 表示**交由默认行为**（在光标处插入换行）；非 null 结果用于
  /// 「空块交互」，与源码 / 预览两态内容保持一致（AC-92）：
  /// - 空列表项（`- ` / `* ` / `+ `，无文本）回车 → 移除标记、退出列表；
  /// - 任务项（`- [ ]` / `- [x]`，空或含文本）回车 → 续行，新建 `- [ ] `；
  /// - 空引用行（`> ` / `>`，无文本）回车 → 移除标记、退出引用。
  ///
  /// 仅在**行尾**触发；仅重写当前行的标记，其余字符一律不动。
  static FormatResult? blockNewline(String text, int offset, [int? caretEnd]) {
    final s = offset.clamp(0, text.length);
    final e = (caretEnd ?? offset).clamp(0, text.length);
    final lineStart = s == 0 ? 0 : text.lastIndexOf('\n', s - 1) + 1;
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd == -1) lineEnd = text.length;

    // 行中回车交由默认行为，避免打断行内编辑。
    // 例外：表格行内回车——跳到下一个单元格，防止插入真换行破坏管道表结构。
    if (e < lineEnd) {
      return _tableCellEnter(text, s);
    }

    final line = text.substring(lineStart, lineEnd);

    // 任务项：续行，保持缩进并新建未勾选任务。
    if (_taskLine.hasMatch(line)) {
      final indent = _leadingWhitespace.firstMatch(line)!.group(0)!;
      final insert = '\n$indent- [ ] ';
      final pos = lineEnd + insert.length;
      return FormatResult(
        text.substring(0, lineEnd) + insert + text.substring(lineEnd),
        pos,
        pos,
      );
    }

    // 空列表项：移除标记，退出列表（留在空行）。
    if (_emptyBulletLine.hasMatch(line)) {
      final newText = text.substring(0, lineStart) + text.substring(lineEnd);
      return FormatResult(newText, lineStart, lineStart);
    }

    // 空引用行：移除标记，退出引用。
    if (_emptyQuoteLine.hasMatch(line)) {
      final newText = text.substring(0, lineStart) + text.substring(lineEnd);
      return FormatResult(newText, lineStart, lineStart);
    }

    // 表格行（行尾）：回车跳到下一个单元格（最后一列则新增一行），
    // 避免插入真实换行破坏 GFM 管道表结构（BR-44.5）。
    if (_hasUnescapedPipe(line)) {
      final result = _tableCellEnter(text, s);
      if (result != null) return result;
    }

    return null;
  }

  /// 表格单元格内 Shift+Enter 软换行：在光标处插入 `<br>` 标签。
  ///
  /// GFM 管道表不支持多行单元格，用内嵌 HTML `<br>` 实现"视觉换行"
  /// （与 Typora / Obsidian 一致）。只有光标在有效表格行内时生效，
  /// 否则返回 `null` 交由默认行为处理。
  static FormatResult? tableSoftNewline(String text, int offset) {
    final lineStart =
        offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd == -1) lineEnd = text.length;
    final line = text.substring(lineStart, lineEnd);
    if (!_hasUnescapedPipe(line)) return null;

    // 回溯找表格头，确认当前行在有效表格内
    final table = _findTableFromLine(text, lineStart);
    if (table == null || !table.wellFormed) return null;
    if (lineStart < table.start || lineStart > table.end) return null;
    if (_isSeparatorRow(line)) return null; // 分隔行不插入软换行

    // 光标在第一个 | 之前 → 不在任何单元格内，走默认行为
    final cursorInLine = offset - lineStart;
    var pipeCount = 0;
    for (var i = 0; i < cursorInLine && i < line.length; i++) {
      if (line[i] == '|' && (i == 0 || line[i - 1] != '\\')) {
        pipeCount++;
      }
    }
    if (pipeCount == 0) return null;

    const br = '<br>';
    final caret = offset + br.length;
    final newText =
        text.substring(0, offset) + br + text.substring(offset);
    return FormatResult(newText, caret, caret);
  }

  /// 从任意表格行出发，向上回溯找到表头并调用 [parseTable]。
  ///
  /// [parseTable] 要求从表格第一行（表头）调用才能返回完整结构，
  /// 因此对于数据行需要先找到分隔行（`|---|`），再往上一格定位表头。
  /// 当前行不在任何表格内时返回 `null`。
  static ParsedTable? _findTableFromLine(String text, int lineStart) {
    // 先试直接解析（可能就在表头行）
    var table = parseTable(text, lineStart);
    if (table != null && table.wellFormed) return table;

    // 向上回溯找分隔行 → 表头
    var scan = lineStart;
    for (var i = 0; i < 50; i++) {
      if (scan == 0) break;
      // scan 是行首，其前一行的**结束换行**位于 scan-1。要取到「上一行」的起止，
      // 必须从 scan-2 往前找分隔换行，否则会把 scan-1 这个换行符本身当成上一行的
      // 结尾，得到 prevStart == scan、prevEnd == scan-1 的非法区间（substring 越界）。
      final prevNl = scan >= 2 ? text.lastIndexOf('\n', scan - 2) : -1;
      final prevStart = prevNl == -1 ? 0 : prevNl + 1;
      final prevEnd = scan - 1;
      final prevLine = text.substring(prevStart, prevEnd);
      if (_isSeparatorRow(prevLine)) {
        // 找到分隔行，再往上一行就是表头（同样要跳过 prevStart-1 处的换行符）
        if (prevStart == 0) break;
        final hdrNl =
            prevStart >= 2 ? text.lastIndexOf('\n', prevStart - 2) : -1;
        final headerStart = hdrNl == -1 ? 0 : hdrNl + 1;
        table = parseTable(text, headerStart);
        if (table != null && table.wellFormed) return table;
        break;
      }
      scan = prevStart;
    }

    return null;
  }

  /// 表格单元格内回车：跳到下一个单元格；最后一列则新增一空行并跳到首列。
  ///
  /// 光标在行内任意位置都生效——防止用户在单元格里按回车把管道表打断
  /// （BR-44.5 / 表格「行内回车即现形」）。
  /// 不在有效表格行内时返回 `null`，走默认换行行为。
  ///
  /// 幽灵行守卫（§12.1.1）：已在**末行末列**时，仅当当前行**非全空**才追加空行，
  /// 否则把光标退回本行首列——避免末格连续回车堆叠**无法删除的尾部空行**。
  static FormatResult? _tableCellEnter(String text, int offset) {
    final lineStart =
        offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd == -1) lineEnd = text.length;
    final line = text.substring(lineStart, lineEnd);
    if (!_hasUnescapedPipe(line)) return null;

    final table = _findTableFromLine(text, lineStart);
    if (table == null || !table.wellFormed) return null;

    // 确认当前行确实在表格范围内
    if (lineStart < table.start || lineStart > table.end) return null;

    // 分隔行回车走默认（跳到下一行，即退出表格编辑态）
    final isSeparator = _isSeparatorRow(line);
    if (isSeparator) return null;

    final cells = _splitRow(line);
    final totalCols = cells.length;
    if (totalCols == 0) return null;

    // 计算光标所在列：数光标前有几个未转义 |
    final cursorInLine = offset - lineStart;
    var pipeCount = 0;
    for (var i = 0; i < cursorInLine && i < line.length; i++) {
      if (line[i] == '|' && (i == 0 || line[i - 1] != '\\')) {
        pipeCount++;
      }
    }
    // 光标在第一个 | 之前 → 不在任何单元格内，属于"表格前面"的位置，
    // 走默认换行（在表格上方插入空行，整体下移）。
    if (pipeCount == 0) return null;
    var colIndex = pipeCount - (line.startsWith('|') ? 1 : 0);
    if (colIndex < 0) colIndex = 0;
    if (colIndex >= totalCols) colIndex = totalCols - 1;

    if (colIndex < totalCols - 1) {
      // 非最后一列：跳到下一列
      var nextPipeAt = -1;
      for (var i = cursorInLine; i < line.length; i++) {
        if (line[i] == '|' && (i == 0 || line[i - 1] != '\\')) {
          nextPipeAt = i;
          break;
        }
      }
      if (nextPipeAt == -1) {
        return FormatResult(text, lineEnd, lineEnd);
      }
      var nextColStart = nextPipeAt + 1;
      if (nextColStart < line.length && line[nextColStart] == ' ') {
        nextColStart++;
      }
      final caret = lineStart + nextColStart;
      return FormatResult(text, caret, caret);
    } else {
      // 最后一列：新增一空行，光标落到新行首列。
      //
      // 幽灵行守卫（§12.1.1）：若当前已是**表格末行**且该行**全空**，说明它是上一次
      // 回车新追加出来的空行——此时不再继续追加，否则末格连续回车会堆叠出**无法删除的
      // 尾部空行**（BR-44.3）。把光标退回本行首列即可。
      final isLastRow = lineEnd >= table.end;
      final rowIsEmpty = cells.every((c) => c.trim().isEmpty);
      if (isLastRow && rowIsEmpty) {
        final caret = lineStart + 2 > lineEnd ? lineEnd : lineStart + 2;
        return FormatResult(text, caret, caret);
      }
      final newRow = _renderRow(List<String>.filled(totalCols, ''));
      final insert = '\n$newRow';
      final newText =
          text.substring(0, lineEnd) + insert + text.substring(lineEnd);
      // 新行格式：|  |  |，首列起始 = \n + | + 空格 = 偏移 2
      final caret = lineEnd + 2;
      return FormatResult(newText, caret, caret);
    }
  }

  /// 缩进：只在**合法层级**内加 2 个空格（§13.3 / BR-23.9）。
  ///
  /// GFM 中行首缩进 ≥4 且**无父列表项**时该行会变成**缩进代码块**（列表 / 勾选框行退化为字面量
  /// `- [ ] x`），故这里按「父列表项缩进 + 标记宽度 + 3」推出上限；目标缩进超出上限时**原样不动**
  /// （即「已在最深合法层级」），绝不产出预览无法解析的结构。
  static FormatResult _indent(String text, int start, int end) {
    final (blockStart, blockEnd) = _blockRange(text, start, end);
    final block = text.substring(blockStart, blockEnd);
    final lines = block.split('\n');
    final out = <String>[];
    var offset = blockStart;
    for (final line in lines) {
      if (line.isEmpty) {
        out.add(line);
      } else {
        final indent = _leadingWhitespace.firstMatch(line)!.group(0)!.length;
        final limit = _listIndentLimit(text, offset, line);
        final target = indent + 2;
        out.add(target <= limit
            ? '${' ' * target}${line.substring(indent)}'
            : line);
      }
      offset += line.length + 1;
    }
    final transformed = out.join('\n');
    final newText =
        text.substring(0, blockStart) + transformed + text.substring(blockEnd);
    // M16 / FR-89：缩进同样落末行行尾（不再是整段选区）。
    final caret = blockStart + transformed.length;
    return FormatResult(newText, caret, caret);
  }

  /// 该行**允许的最大行首缩进**（§13.3 / BR-23.9①）。
  ///
  /// - 非列表行（段落 / 标题 / 引用 …）：上限 **3**（行首 ≥4 空格即缩进代码块）；
  /// - 列表 / 任务行：向上找最近的非空**父列表项**（缩进小于本行）→ 上限 = 父缩进 + 父标记宽度 + 3；
  ///   找不到父列表项（首行、上方是普通段落 / 表格行等）时上限同为 **3**。
  static int _listIndentLimit(String text, int lineStart, String line) {
    final indent = _leadingWhitespace.firstMatch(line)!.group(0)!.length;
    if (_listMarkerWidth(line) == 0) return 3;
    var scan = lineStart;
    while (scan > 0) {
      final prevNl = scan >= 2 ? text.lastIndexOf('\n', scan - 2) : -1;
      final prevStart = prevNl == -1 ? 0 : prevNl + 1;
      final prevLine = text.substring(prevStart, scan - 1);
      if (prevLine.trim().isNotEmpty) {
        final w = _listMarkerWidth(prevLine);
        if (w == 0) return 3; // 上一非空行不是列表项 → 只能是顶层列表项
        final pIndent = _leadingWhitespace.firstMatch(prevLine)!.group(0)!.length;
        if (pIndent < indent) return pIndent + w + 3;
      }
      if (prevStart == 0) break;
      scan = prevStart;
    }
    return 3;
  }

  /// 列表行标记宽度（`- ` = 2、`1. ` = 3、任务项 `- ` = 2）；非列表行返回 0（§13.3）。
  static int _listMarkerWidth(String line) {
    if (_taskLine.hasMatch(line)) return 2; // `[ ]` 属项内容，不计入标记宽度
    final ordered = _orderedPrefixRe.firstMatch(line);
    if (ordered != null) {
      return ordered.group(2)!.trimRight().length + 1;
    }
    final bullet = _bulletPrefixRe.firstMatch(line);
    if (bullet != null) return bullet.group(2)!.trimRight().length + 1;
    return 0;
  }

  /// 该行是否**被 GFM 解析为列表 / 任务项**（缩进层级合法，§13.3 / BR-23.9②）。
  ///
  /// 「格式」模式只对判定为真的行呈现项目符号 / 勾选框，从而与「预览」的行级结构判定一致。
  static bool isListLineAt(String text, int lineStart) {
    final line = _lineText(text, lineStart);
    if (line.trim().isEmpty) return false;
    if (_listMarkerWidth(line) == 0) return false;
    final indent = _leadingWhitespace.firstMatch(line)!.group(0)!.length;
    return indent <= _listIndentLimit(text, lineStart, line);
  }

  static FormatResult _outdent(String text, int start, int end) {
    return _mapLines(text, start, end, (line, _) {
      if (line.startsWith('\t')) return line.substring(1);
      var n = 0;
      while (n < 2 && n < line.length && line[n] == ' ') {
        n++;
      }
      return line.substring(n);
    });
  }

  static FormatResult _clearFormat(String text, int start, int end) {
    final s = start.clamp(0, text.length);
    final e = end.clamp(0, text.length);
    final (from, to) = s == e ? _blockRange(text, s, e) : (s, e);
    var cleared = text.substring(from, to);
    var previous = '';
    while (previous != cleared) {
      previous = cleared;
      for (final re in _inlineRemovable) {
        cleared = cleared.replaceAllMapped(re, (m) => m.group(1)!);
      }
    }
    final newText = text.substring(0, from) + cleared + text.substring(to);
    // M16 / FR-89：简化格式后光标落末行行尾。
    final caret = from + cleared.length;
    return FormatResult(newText, caret, caret);
  }

  /// 任务项行：行首（可含缩进）`- [ ]` / `- [x]`，其后为任务文本（§10.1）。
  static final RegExp _taskLine =
      RegExp(r'^([ \t]*[-*+][ \t]+)\[([ xX])\](.*)$');

  /// 空列表项行：仅含标记、无文本（供回车退出列表，§11.2）。
  static final RegExp _emptyBulletLine = RegExp(r'^[ \t]*[-*+][ \t]+$');

  /// 空引用行：仅含 `>`、无文本（供回车退出引用，§11.2）。
  static final RegExp _emptyQuoteLine = RegExp(r'^[ \t]*>[ \t]?$');

  /// 行首空白（用于任务续行时保持缩进）。
  static final RegExp _leadingWhitespace = RegExp(r'^[ \t]*');

  /// `简化格式` 可移除的行内标记对（长标记先行，避免误伤内部单字符）。
  static final List<RegExp> _inlineRemovable = [
    RegExp(r'\*\*(.+?)\*\*', dotAll: true),
    RegExp(r'__(.+?)__', dotAll: true),
    RegExp(r'~~(.+?)~~', dotAll: true),
    RegExp(r'==(.+?)==', dotAll: true),
    RegExp(r'`(.+?)`', dotAll: true),
    RegExp(r'\*(.+?)\*', dotAll: true),
    RegExp(r'_(.+)_', dotAll: true),
  ];

  /// 对选区覆盖的整行区间逐行应用 [transform]，返回整体重写后的结果。
  static FormatResult _mapLines(
    String text,
    int start,
    int end,
    String Function(String line, int index) transform,
  ) {
    final (blockStart, blockEnd) = _blockRange(text, start, end);
    final block = text.substring(blockStart, blockEnd);
    final lines = block.split('\n');
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      out.add(transform(lines[i], i));
    }
    final transformed = out.join('\n');
    final newText =
        text.substring(0, blockStart) + transformed + text.substring(blockEnd);
    // M16 / FR-89 / BR-89.1：块级指令统一返回**折叠光标 + 末行行尾**。
    // 旧实现返回 [blockStart, blockStart + transformed.length)（整段选中），
    // 用户键入会替换整行 / 整段，表现为「失焦 / 无法打字」。
    final caret = blockStart + transformed.length;
    return FormatResult(newText, caret, caret);
  }

  /// 计算选区覆盖的整行区间 `[blockStart, blockEnd)`（不含尾换行）。
  static (int, int) _blockRange(String text, int start, int end) {
    final from = start.clamp(0, text.length);
    final to = end.clamp(0, text.length);
    final lineStart = from == 0 ? 0 : text.lastIndexOf('\n', from - 1) + 1;
    final nlAfter = text.indexOf('\n', to);
    final blockEnd = nlAfter == -1 ? text.length : nlAfter;
    return (lineStart, blockEnd);
  }

  // ---------------------------------------------------------------------------
  // 图片引用与尺寸（ADR-007）
  // ---------------------------------------------------------------------------

  static final RegExp _imageRef = RegExp(r'!\[([^\]]*)\]\(([^)]*)\)');

  /// 插入图片引用 `![文件名](sui://<sha256>)[{尺寸}]`。
  ///
  /// 采用**独占块（block）**语义（editor-formatting.md §5.5）：
  ///
  /// - 图片引用前后各保证与相邻段落以空行（`\n\n`）分隔——光标若落在某行的
  ///   行中，则该行被一分为二，图片引用自占一段（「另起新段」）；
  /// - 若文档末尾没有可落点的下一行，则补一个换行（`\n`），使图片引用之后
  ///   仍存在一行，光标可以在图片**下方**落点（避免「光标粘滞在图片上」）；
  /// - 插入后光标置于图片引用**之后**（下一块起始处），便于继续输入而不会
  ///   把正文粘进图片引用所在行（否则会退化为行内 `![...]文字`）。
  ///
  /// 本方法只做文本变换，不触碰文档其余字节（BR-32.1）。
  static FormatResult insertImage(
    String text,
    int start,
    int end, {
    required String filename,
    required String sha256,
    ImageSize? size,
  }) {
    final attr = size == null ? '' : renderSizeAttribute(size);
    return _insertBlockReference(
      text,
      start,
      end,
      '![$filename](sui://$sha256)$attr',
    );
  }

  /// 插入一条附件引用块（`v0.16.3` / FR-91 / BR-91.4）。
  ///
  /// 形态**随附件类型**：图片走 [insertImage]（`![文件名](sui://<sha256>)`，可带尺寸属性），
  /// 其余走**附件链接** `[文件名](sui://<sha256>)`（格式 / 预览态呈现为附件卡片）。
  /// 两种形态**共用同一段独占块语义**（前后各留空行、光标落引用之后），与单元格内的
  /// [insertTableCellAttachment] 口径一致；非图片**不得**写成 `![…]`——那会渲染成坏图占位，
  /// 与附件列表里的「PDF / 其它」卡片不一致。
  static FormatResult insertAttachment(
    String text,
    int start,
    int end, {
    required String filename,
    required String sha256,
    bool isImage = true,
  }) {
    if (isImage) {
      return insertImage(text, start, end, filename: filename, sha256: sha256);
    }
    return _insertBlockReference(text, start, end, '[$filename](sui://$sha256)');
  }

  /// 把 [token] 以**独占块**语义插入 `[start, end)`（§5.5 / BR-32.1）：
  /// 左侧保证一个空行、右侧保证一个空行（文末补一个换行），光标落 [token] 之后。
  static FormatResult _insertBlockReference(
    String text,
    int start,
    int end,
    String token,
  ) {
    final s = start.clamp(0, text.length);
    final e = end.clamp(0, text.length);
    final before = text.substring(0, s);
    final after = text.substring(e);

    // 左侧：已在段首（空 / 已有一个空行）则不补；否则补到「一个空行」。
    final String leading;
    if (before.isEmpty || before.endsWith('\n\n')) {
      leading = '';
    } else {
      leading = before.endsWith('\n') ? '\n' : '\n\n';
    }

    // 右侧：已有空行则不补；文末（无可落点的下一行）补一个换行。
    final String trailing;
    if (after.isEmpty) {
      trailing = '\n';
    } else if (after.startsWith('\n\n')) {
      trailing = '';
    } else {
      trailing = after.startsWith('\n') ? '\n' : '\n\n';
    }

    final newText = '$before$leading$token$trailing$after';
    final pos = before.length + leading.length + token.length + trailing.length;
    return FormatResult(newText, pos, pos);
  }

  /// 把 [size] 渲染为属性块；自适应尺寸返回空串。
  static String renderSizeAttribute(ImageSize size) {
    final parts = <String>[];
    final w = size.width;
    final h = size.height;
    if (w != null) parts.add('width=$w');
    if (h != null) parts.add('height=$h');
    if (parts.isEmpty) return '';
    return '{${parts.join(' ')}}';
  }

  /// 查找 [fromIndex] 之后第一个图片引用及其尺寸属性。
  static ParsedImage? findImage(String source, [int fromIndex = 0]) {
    for (final m in _imageRef.allMatches(source)) {
      if (m.start < fromIndex) continue;
      final refEnd = m.end;
      var attrStart = -1;
      var attrEnd = -1;
      var size = ImageSize.auto;
      var valid = false;

      // 属性块须「同一行、紧跟」，但允许中间有空格 / 制表符。
      var cursor = refEnd;
      while (cursor < source.length &&
          (source[cursor] == ' ' || source[cursor] == '\t')) {
        cursor++;
      }
      if (cursor < source.length && source[cursor] == '{') {
        final close = source.indexOf('}', cursor + 1);
        final nl = source.indexOf('\n', cursor + 1);
        if (close != -1 && (nl == -1 || close < nl)) {
          final parsed =
              parseSizeAttribute(source.substring(cursor, close + 1));
          if (parsed != null) {
            valid = true;
            size = parsed;
            attrStart = cursor;
            attrEnd = close + 1;
          }
        }
      }

      return ParsedImage(
        alt: m.group(1) ?? '',
        url: m.group(2) ?? '',
        size: size,
        start: m.start,
        end: refEnd,
        attributeStart: attrStart,
        attributeEnd: attrEnd,
        attributeValid: valid,
      );
    }
    return null;
  }

  /// 解析 `{width=320 height=50%}` 形式的属性块。
  ///
  /// 返回 null 表示**完全无法解析**（应原样透传，绝不删除）。含未知键但结构合法
  /// 时返回已知尺寸（未知键忽略）。
  static ImageSize? parseSizeAttribute(String block) {
    final trimmed = block.trim();
    if (trimmed.length < 2 ||
        !trimmed.startsWith('{') ||
        !trimmed.endsWith('}')) {
      return null;
    }
    final body = trimmed.substring(1, trimmed.length - 1).trim();
    if (body.isEmpty) return null;

    ImageDimension? width;
    ImageDimension? height;
    var structureValid = false;

    for (final token in body.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final eq = token.indexOf('=');
      if (eq <= 0) continue;
      structureValid = true;
      final key = token.substring(0, eq).trim().toLowerCase();
      final value = token.substring(eq + 1).trim();
      if (key == 'width') {
        width = _parseDimension(value); // 非法值 → null（忽略该尺寸）
      } else if (key == 'height') {
        height = _parseDimension(value);
      }
      // 未知键：忽略，保留其余已知键。
    }

    // 结构不合法（无任何 key=value）→ 不可解析，透传。
    if (!structureValid) return null;
    return ImageSize(width: width, height: height);
  }

  /// 原地改写图片尺寸属性块；[size] 为 null 或自适应时移除属性块。
  ///
  /// **只重写该属性块**，其余字符一律不动（BR-24.1 / 往返保真）。
  static String setImageSize(String text, ParsedImage image, ImageSize? size) {
    final attr = (size == null || size.isAuto) ? '' : renderSizeAttribute(size);
    if (image.attributeValid && image.attributeStart >= 0) {
      return text.substring(0, image.attributeStart) +
          attr +
          text.substring(image.attributeEnd);
    }
    if (attr.isEmpty) return text;
    return text.substring(0, image.end) + attr + text.substring(image.end);
  }

  /// 容错读入：从 URL 查询串的 `?w=` / `?h=` 归一为尺寸（只读，不用于写回）。
  static ImageSize? parseUrlSize(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final w = _parseDimension(uri.queryParameters['w'] ?? '');
    final h = _parseDimension(uri.queryParameters['h'] ?? '');
    if (w == null && h == null) return null;
    return ImageSize(width: w, height: h);
  }

  /// 容错读入：从 HTML `<img width= height=>` 归一为尺寸（只读，不用于写回）。
  static ImageSize? parseHtmlImgSize(String html) {
    final m = RegExp(r'<img\b[^>]*>', caseSensitive: false).firstMatch(html);
    if (m == null) return null;
    final tag = m.group(0)!;
    final w = _parseDimension(_htmlAttr(tag, 'width') ?? '');
    final h = _parseDimension(_htmlAttr(tag, 'height') ?? '');
    if (w == null && h == null) return null;
    return ImageSize(width: w, height: h);
  }

  static String? _htmlAttr(String tag, String name) {
    final m = RegExp("$name\\s*=\\s*[\"']?([^\"'\\s>]+)",
            caseSensitive: false)
        .firstMatch(tag);
    return m?.group(1);
  }

  /// 解析单维度值：正整数像素或 `NN%`（1..100）。非法返回 null。
  static ImageDimension? _parseDimension(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null;
    if (v.endsWith('%')) {
      final n = int.tryParse(v.substring(0, v.length - 1));
      if (n == null || n <= 0 || n > 100) return null;
      return ImageDimension(n, SizeUnit.percent);
    }
    final n = int.tryParse(v);
    if (n == null || n <= 0 || n > 100000) return null;
    return ImageDimension(n, SizeUnit.pixel);
  }

  // ---------------------------------------------------------------------------
  // 表格：GFM 管道表（M9 / FR-44 / §12.1）
  // ---------------------------------------------------------------------------

  /// 行数钳制下界（BR-44.1）。
  static const int tableMinRows = 1;

  /// 行数钳制上界（BR-44.1）。
  static const int tableMaxRows = 20;

  /// 列数钳制下界（BR-44.1）。
  static const int tableMinColumns = 1;

  /// 列数钳制上界（BR-44.1）。
  static const int tableMaxColumns = 8;

  /// 单元格文本转义：`|` → `\|`（§12.1 / BR-44.4）；已转义的不重复转义。
  static String escapeTableCell(String raw) =>
      raw.replaceAll(RegExp(r'(?<!\\)\|'), r'\|');

  /// 单元格文本反转义：`\|` → `|`（[escapeTableCell] 的逆操作）。
  ///
  /// [ParsedTable] 的单元格保留原文转义（`_splitRow` 原样保留 `\|`），本方法用于取回
  /// **字面文本**（如把附件引用并入既有单元格内容后再交给 [setTableCell] 重新转义）。
  static String unescapeTableCell(String raw) => raw.replaceAll(r'\|', '|');

  /// 插入管道表：表头行 + 分隔行 +（行−1）空数据行，独占块（§12.1）。
  ///
  /// [rows] / [columns] 为**正整数**，超限时取边界值（行 1~20、列 1~8，BR-44.1）。
  /// 插入后光标落在**首个表头单元格**；表格前后以空行与相邻段落分隔（同 §5.5）。
  static FormatResult insertTable(
    String text,
    int start,
    int end, {
    required int rows,
    required int columns,
  }) {
    final r = rows.clamp(tableMinRows, tableMaxRows);
    final c = columns.clamp(tableMinColumns, tableMaxColumns);
    final block = _renderTableBlock(
      header: List<String>.filled(c, ''),
      aligns: List<TableColumnAlign>.filled(c, TableColumnAlign.none),
      rows: List<List<String>>.generate(r - 1, (_) => List<String>.filled(c, '')),
    );

    final s = start.clamp(0, text.length);
    final e = end.clamp(0, text.length);
    final before = text.substring(0, s);
    final after = text.substring(e);
    final String leading;
    if (before.isEmpty || before.endsWith('\n\n')) {
      leading = '';
    } else {
      leading = before.endsWith('\n') ? '\n' : '\n\n';
    }
    final String trailing;
    if (after.isEmpty) {
      trailing = '\n';
    } else if (after.startsWith('\n\n')) {
      trailing = '';
    } else {
      trailing = after.startsWith('\n') ? '\n' : '\n\n';
    }
    final newText = '$before$leading$block$trailing$after';
    // 光标落在首个表头单元格（表头行 `| ` 之后）。
    final caret = before.length + leading.length + 2;
    return FormatResult(newText, caret, caret);
  }

  /// 解析 [fromIndex] 所在行起的连续管道表块；无 `|` 时返回 null（降级为普通文本）。
  ///
  /// 残缺表（缺分隔行 / 列数不齐）仍返回结果，`wellFormed == false`，
  /// 由调用方**尽力呈现、不丢内容、不报错**（BR-44.5）。
  static ParsedTable? parseTable(String text, [int fromIndex = 0]) {
    final from = fromIndex.clamp(0, text.length);
    final lineStart = from == 0 ? 0 : text.lastIndexOf('\n', from - 1) + 1;

    // 收集连续「含未转义 |」的行（表格块）。
    final starts = <int>[];
    final rowsRaw = <String>[];
    var cursor = lineStart;
    while (cursor <= text.length) {
      final nl = text.indexOf('\n', cursor);
      final lineEnd = nl == -1 ? text.length : nl;
      final line = text.substring(cursor, lineEnd);
      if (!_hasUnescapedPipe(line)) break;
      starts.add(cursor);
      rowsRaw.add(line);
      if (nl == -1) break;
      cursor = nl + 1;
    }
    if (rowsRaw.isEmpty) return null;

    final blockStart = starts.first;
    final last = starts.last + rowsRaw.last.length;
    final header = _splitRow(rowsRaw.first);

    final hasSeparator =
        rowsRaw.length >= 2 && rowsRaw[1].trim().isNotEmpty && _isSeparatorRow(rowsRaw[1]);

    List<TableColumnAlign> aligns;
    List<List<String>> rows;
    var wellFormed = false;
    if (hasSeparator) {
      aligns = _splitRow(rowsRaw[1]).map(_parseAlign).toList();
      rows = rowsRaw.skip(2).map(_splitRow).toList();
      wellFormed = true;
      for (final row in rows) {
        if (row.length != header.length) {
          wellFormed = false;
          break;
        }
      }
      if (aligns.length != header.length) wellFormed = false;
    } else {
      aligns = List<TableColumnAlign>.filled(header.length, TableColumnAlign.none);
      rows = rowsRaw.skip(1).map(_splitRow).toList();
    }

    return ParsedTable(
      start: blockStart,
      end: last,
      header: header,
      aligns: aligns,
      rows: rows,
      wellFormed: wellFormed,
    );
  }

  /// 设置第 [column] 列对齐：**仅重写分隔行**对应单元格，其余逐字不动（§12.1）。
  static String setTableAlignment(
    String text,
    ParsedTable table,
    int column,
    TableColumnAlign align,
  ) {
    final lines = _tableLines(text, table);
    if (lines.length < 2) return text;
    final sep = lines[1];
    final cells = _splitRow(sep.text);
    if (column < 0 || column >= cells.length) return text;
    cells[column] = _alignMarker(align);
    final newSep = _renderRow(cells);
    return text.substring(0, sep.start) +
        newSep +
        text.substring(sep.start + sep.text.length);
  }

  /// 在第 [after] 列之后插入空列（[after] < 0 表示最前）。
  ///
  /// 同步补齐**表头行 / 分隔行 / 各数据行**，保持列数一致（§12.1）。
  static String addTableColumn(String text, ParsedTable table, {int? after}) {
    final insertAt =
        ((after ?? table.header.length - 1) + 1).clamp(0, table.header.length);
    final lines = _tableLines(text, table);
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final cells = _splitRow(lines[i].text);
      final at = insertAt.clamp(0, cells.length);
      cells.insert(at, i == 1 ? '---' : '');
      out.add(_renderRow(cells));
    }
    final replaced = out.join('\n');
    return text.substring(0, table.start) + replaced + text.substring(table.end);
  }

  /// 删除第 [column] 列（保留至少一列）；同步裁剪表头行 / 分隔行 / 各数据行。
  static String removeTableColumn(String text, ParsedTable table, int column) {
    if (table.header.length <= 1) return text;
    final lines = _tableLines(text, table);
    final out = <String>[];
    for (final l in lines) {
      final cells = _splitRow(l.text);
      if (column >= 0 && column < cells.length) cells.removeAt(column);
      out.add(_renderRow(cells));
    }
    final replaced = out.join('\n');
    return text.substring(0, table.start) + replaced + text.substring(table.end);
  }

  /// 在表格块末尾追加一空数据行。
  static String addTableRow(String text, ParsedTable table) {
    final cols = table.header.length;
    if (cols == 0) return text;
    final newRow = _renderRow(List<String>.filled(cols, ''));
    return '${text.substring(0, table.end)}\n$newRow${text.substring(table.end)}';
  }

  /// 删除第 [rowIndex] 个**数据行**（0-based，不含表头 / 分隔行）。
  static String removeTableRow(String text, ParsedTable table, int rowIndex) {
    final lines = _tableLines(text, table);
    final target = 2 + rowIndex;
    if (target < 2 || target >= lines.length) return text;
    final l = lines[target];
    var from = l.start;
    var to = l.start + l.text.length;
    if (to < text.length && text[to] == '\n') {
      to++;
    } else if (from > 0 && text[from - 1] == '\n') {
      from--;
    }
    return text.substring(0, from) + text.substring(to);
  }

  /// 在第 [rowIndex] 个**数据行**的**上方 / 下方**插入一空行（§12.1 结构编辑）。
  ///
  /// [rowIndex] 为 0-based 数据行序号（不含表头 / 分隔行）；[after] 为 `true` 表示
  /// 插入其**下方**，否则插入**上方**。越界时钳制到表格末尾（等价于追加）。
  /// 新行单元格数与表头列数一致，均为空内容（BR-44.4 / §12.1）。
  static String insertTableRow(
    String text,
    ParsedTable table,
    int rowIndex, {
    bool after = false,
  }) {
    final cols = table.header.length;
    if (cols == 0) return text;
    final lines = _tableLines(text, table);
    final dataCount = lines.length > 2 ? lines.length - 2 : 0;
    final at = (after ? rowIndex + 1 : rowIndex).clamp(0, dataCount);
    final newRow = _renderRow(List<String>.filled(cols, ''));
    final targetLine = at + 2; // 表头行 0 + 分隔行 1
    if (targetLine >= lines.length) {
      return '${text.substring(0, table.end)}\n$newRow${text.substring(table.end)}';
    }
    final l = lines[targetLine];
    return '${text.substring(0, l.start)}$newRow\n${text.substring(l.start)}';
  }

  /// 就地改写某个单元格文本，其余单元格逐字不动（§12.1 / BR-44.4）。
  ///
  /// [rowIndex] `< 0` 表示**表头行**；否则为 0-based 数据行序号。[column] 为列序号。
  /// 写入内容先做 `|` → `\|` 转义；行 / 列越界时原样返回。
  static String setTableCell(
    String text,
    ParsedTable table,
    int rowIndex,
    int column,
    String value,
  ) {
    final lines = _tableLines(text, table);
    final lineIndex = rowIndex < 0 ? 0 : rowIndex + 2;
    if (lineIndex < 0 || lineIndex >= lines.length) return text;
    final l = lines[lineIndex];
    final cells = _splitRow(l.text);
    if (column < 0 || column >= cells.length) return text;
    cells[column] = escapeTableCell(value);
    final newLine = _renderRow(cells);
    return text.substring(0, l.start) +
        newLine +
        text.substring(l.start + l.text.length);
  }

  /// 把附件引用插入表格指定单元格（§12.1.1「单元格内附件」）。
  ///
  /// [isImage] 为 true 生成图片引用 `![文件名](sui://<sha256>)`，否则生成附件链接
  /// `[文件名](sui://<sha256>)`。引用以单元格内**软换行**（`<br>`，与 [tableSoftNewline] 一致；
  /// GFM 管道表不支持多行单元格）追加到活动单元格既有内容之后——既有内容取回**字面文本**
  /// （[unescapeTableCell]），并入后再经 [setTableCell] 统一转义 `|` 写回，**其余单元格逐字不动**
  /// （BR-44.2 / BR-44.4）。行 / 列越界时原样返回。
  static String insertTableCellAttachment(
    String text,
    ParsedTable table,
    int rowIndex,
    int column, {
    required String filename,
    required String sha256,
    bool isImage = true,
  }) {
    final lines = _tableLines(text, table);
    final lineIndex = rowIndex < 0 ? 0 : rowIndex + 2;
    if (lineIndex < 0 || lineIndex >= lines.length) return text;
    final cells = _splitRow(lines[lineIndex].text);
    if (column < 0 || column >= cells.length) return text;

    // 单元格内软换行用 `<br>`（GFM 管道表不支持多行单元格，§12.1 / tableSoftNewline）；
    // 若用字面 `\n` 会把该行物理拆成两行，破坏表格结构。
    final ref =
        isImage ? '![$filename](sui://$sha256)' : '[$filename](sui://$sha256)';
    final existing = unescapeTableCell(cells[column]).trim();
    final value = existing.isEmpty ? ref : '$existing<br>$ref';
    return setTableCell(text, table, rowIndex, column, value);
  }

  /// 把 **Markdown 超链接**插入表格指定单元格（§12.1.1「单元格内链接」/ BR-44.12）。
  ///
  /// 与 [insertTableCellAttachment] **同范式**：取回单元格**字面文本**（[unescapeTableCell]），
  /// 既有内容为空则直接写入，否则以**软换行 `<br>` 追加**（GFM 管道表不支持多行单元格），
  /// 再经 [setTableCell] 统一转义 `|` 写回——**其余单元格与表结构逐字不动**（守 BR-44.2 / BR-44.4）。
  ///
  /// [url] 为空（[renderLink] 返回空串）或行 / 列越界时**原样返回**（不落笔）。
  static String insertTableCellLink(
    String text,
    ParsedTable table,
    int rowIndex,
    int column, {
    required String label,
    required String url,
  }) {
    final md = renderLink(label: label, url: url);
    if (md.isEmpty) return text;
    final lines = _tableLines(text, table);
    final lineIndex = rowIndex < 0 ? 0 : rowIndex + 2;
    if (lineIndex < 0 || lineIndex >= lines.length) return text;
    final cells = _splitRow(lines[lineIndex].text);
    if (column < 0 || column >= cells.length) return text;
    final existing = unescapeTableCell(cells[column]).trim();
    final value = existing.isEmpty ? md : '$existing<br>$md';
    return setTableCell(text, table, rowIndex, column, value);
  }

  /// 按 [table] 的行区间切出逐行（含每行起始偏移）。
  static List<({int start, String text})> _tableLines(
    String text,
    ParsedTable table,
  ) {
    final out = <({int start, String text})>[];
    var off = table.start;
    for (final line in text.substring(table.start, table.end).split('\n')) {
      out.add((start: off, text: line));
      off += line.length + 1;
    }
    return out;
  }

  static String _renderTableBlock({
    required List<String> header,
    required List<TableColumnAlign> aligns,
    required List<List<String>> rows,
  }) {
    final buf = StringBuffer(_renderRow(header))
      ..write('\n')
      ..write(_renderSeparator(aligns));
    for (final row in rows) {
      buf
        ..write('\n')
        ..write(_renderRow(row));
    }
    return buf.toString();
  }

  /// HTML 表格（`<table>` 内部内容）→ GFM 管道表（§12.2「表格」，尽力转换、不丢内容）。
  ///
  /// 首行作为**表头行**（含 `<th>` 与否皆然，GFM 要求表头 + 分隔行），其余为数据行；
  /// 列对齐取自表头单元格 `align` 属性，缺省为 `---`（左）。单元格保留行内语义
  /// （粗体 / 斜体 / 代码 / 链接），其余标签去除、实体反转义，文本内 `|` 转义为 `\|`。
  static String _htmlTableToMarkdown(String tableInner) {
    final trRe = RegExp(r'<\s*tr\b[^>]*>(.*?)<\s*/\s*tr>',
        caseSensitive: false, dotAll: true);
    final cellRe = RegExp(r'<\s*(td|th)\b([^>]*)>(.*?)<\s*/\s*\1>',
        caseSensitive: false, dotAll: true);

    final rows = <List<String>>[];
    final aligns = <TableColumnAlign>[];

    for (final tr in trRe.allMatches(tableInner)) {
      final cells = <String>[];
      for (final cell in cellRe.allMatches(tr.group(1)!)) {
        cells.add(escapeTableCell(_htmlInline(cell.group(3)!)));
        if (rows.isEmpty) aligns.add(_parseHtmlAlign(cell.group(2)!));
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return tableInner;

    final cols = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    for (final r in rows) {
      while (r.length < cols) {
        r.add('');
      }
    }
    while (aligns.length < cols) {
      aligns.add(TableColumnAlign.none);
    }

    final buf = StringBuffer();
    buf.writeln('| ${rows.first.join(' | ')} |');
    buf.writeln(
        '| ${List<String>.generate(cols, (i) => _alignMarker(aligns[i])).join(' | ')} |');
    for (final r in rows.skip(1)) {
      buf.writeln('| ${r.join(' | ')} |');
    }
    return '\n${buf.toString().trimRight()}\n';
  }

  /// 解析表头单元格的 `align` 属性（缺省 `none`）。
  static TableColumnAlign _parseHtmlAlign(String attrs) {
    final m = RegExp(r'''align\s*=\s*["']?\s*(left|center|right)''',
            caseSensitive: false)
        .firstMatch(attrs);
    switch (m?.group(1)?.toLowerCase()) {
      case 'center':
        return TableColumnAlign.center;
      case 'right':
        return TableColumnAlign.right;
      case 'left':
        return TableColumnAlign.left;
      default:
        return TableColumnAlign.none;
    }
  }

  /// 表格单元格 / 行内片段：保留行内语义后去除标签、反转义实体。
  static String _htmlInline(String raw) {
    var out = raw;
    out = out.replaceAllMapped(
        RegExp(r'<\s*(strong|b)\b[^>]*>(.*?)<\s*/\s*\1>',
            caseSensitive: false, dotAll: true),
        (m) => '**${m.group(2)}**');
    out = out.replaceAllMapped(
        RegExp(r'<\s*(em|i)\b[^>]*>(.*?)<\s*/\s*\1>',
            caseSensitive: false, dotAll: true),
        (m) => '*${m.group(2)}*');
    out = out.replaceAllMapped(
        RegExp(r'<\s*(s|del|strike)\b[^>]*>(.*?)<\s*/\s*\1>',
            caseSensitive: false, dotAll: true),
        (m) => '~~${m.group(2)}~~');
    out = out.replaceAllMapped(
        RegExp(r'<\s*code\b[^>]*>(.*?)<\s*/\s*code>',
            caseSensitive: false, dotAll: true),
        (m) => '`${m.group(1)}`');
    out = out.replaceAllMapped(
        RegExp(
            r'''<\s*a\b[^>]*href\s*=\s*["']([^"']*)["'][^>]*>(.*?)<\s*/\s*a>''',
            caseSensitive: false,
            dotAll: true),
        (m) => '[${m.group(2)}](${m.group(1)})');
    out = out.replaceAll(
        RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), ' ');
    out = out.replaceAll(RegExp(r'<[^>]+>'), '');
    out = out
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"');
    return out.trim();
  }

  /// 渲染一行：`| a | b |`；单元格**逐字写出**（不改写转义，保 §4.1）。
  static String _renderRow(List<String> cells) {
    final buf = StringBuffer('|');
    for (final cell in cells) {
      buf.write(' $cell |');
    }
    return buf.toString();
  }

  static String _renderSeparator(List<TableColumnAlign> aligns) =>
      _renderRow(aligns.map(_alignMarker).toList());

  static String _alignMarker(TableColumnAlign a) {
    switch (a) {
      case TableColumnAlign.none:
        return '---';
      case TableColumnAlign.left:
        return ':---';
      case TableColumnAlign.center:
        return ':---:';
      case TableColumnAlign.right:
        return '---:';
    }
  }

  static TableColumnAlign _parseAlign(String cell) {
    final c = cell.trim();
    final left = c.startsWith(':');
    final right = c.endsWith(':');
    if (left && right) return TableColumnAlign.center;
    if (left) return TableColumnAlign.left;
    if (right) return TableColumnAlign.right;
    return TableColumnAlign.none;
  }

  /// 是否为分隔行（全部分隔单元格，至少一个）。
  static bool _isSeparatorRow(String line) {
    final cells = _splitRow(line);
    if (cells.isEmpty) return false;
    for (final c in cells) {
      if (!RegExp(r'^:?-+:?$').hasMatch(c.trim())) return false;
    }
    return true;
  }

  static bool _hasUnescapedPipe(String line) {
    for (var i = 0; i < line.length; i++) {
      if (line[i] == '|' && (i == 0 || line[i - 1] != '\\')) return true;
    }
    return false;
  }

  /// 按未转义 `|` 拆分一行单元格，去除首尾竖线与两侧空白。
  static List<String> _splitRow(String line) {
    var s = line.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|') && !s.endsWith(r'\|')) {
      s = s.substring(0, s.length - 1);
    }
    final cells = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == '\\' && i + 1 < s.length && s[i + 1] == '|') {
        buf.write(r'\|');
        i++;
      } else if (ch == '|') {
        cells.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    cells.add(buf.toString().trim());
    return cells;
  }

  // ---------------------------------------------------------------------------
  // 有序列表惰性编号（M9 / FR-48 / §12.5）
  // ---------------------------------------------------------------------------

  /// 计算有序列表的**显示编号**（FR-48 惰性编号）。
  ///
  /// 返回与输入**行**一一对应的编号：有序列表行给出其显示编号，其余行为 null。
  /// - 连续有序列表从 1 递增；
  /// - 空行 / 非列表行隔断后重新从 1 开始；
  /// - 行首显式写了非 `1` 的数字（用户指定起始）时以该值为准并按其递增（BR-48.4）。
  ///
  /// 本函数**只读**，不改写正本（BR-48.1 / 保 §4.1）。
  static List<int?> orderedListNumbers(String text) {
    final result = <int?>[];
    int? current;
    for (final raw in text.split('\n')) {
      // 行尾 `\r` 在匹配前剥除（FR-77 / BR-77.2）：只影响匹配，偏移语义与正本不变。
      final line = _stripCr(raw);
      final m = RegExp(r'^([ \t]*)(\d+)\.[ \t]+(.*)$').firstMatch(line);
      if (m != null) {
        final n = int.tryParse(m.group(2)!) ?? 1;
        current = n != 1 ? n : (current ?? 1);
        result.add(current);
        current = current + 1;
      } else {
        result.add(null);
        if (_breaksList(line)) current = null;
      }
    }
    return result;
  }

  /// 该行是否隔断有序列表（空行 / 顶格非列表行；缩进续行不打断）。
  static bool _breaksList(String line) {
    if (line.trim().isEmpty) return true;
    if (line.startsWith(' ') || line.startsWith('\t')) return false;
    return true;
  }

  // ---------------------------------------------------------------------------
  // 笔记内链接（FR-70 / §16）
  // ---------------------------------------------------------------------------

  /// 行内链接匹配：1 `!`（图片标记）/ 2 显示文字 / 3 目标。
  static final RegExp _linkRefRe = RegExp(r'(!?)\[([^\]\n]*)\]\(([^)\n]*)\)');

  /// 正本中的全部 Markdown 行内链接（按出现顺序，FR-70 / §16）。
  ///
  /// 只扫**单行**链接：跨行 `[文字](\n网址)` 属于未识别语法（预览同样按普通文本呈现），
  /// 不建立链接区间，避免「格式模式可点、预览不可点」的两态分裂（BR-70.1）。
  static List<MarkdownLink> links(String text) {
    final out = <MarkdownLink>[];
    var lineStart = 0;
    while (lineStart <= text.length) {
      final nl = text.indexOf('\n', lineStart);
      final lineEnd = nl == -1 ? text.length : nl;
      final line = _stripCr(text.substring(lineStart, lineEnd));
      for (final m in _linkRefRe.allMatches(line)) {
        if (m.group(1) == '!') continue; // 图片引用不是链接。
        final url = m.group(3)!.trim();
        if (url.isEmpty) continue;
        // 附件引用（`sui://<sha256>`）另有原子单元；**笔记引用**（`sui://note/<id>`）
        // 是标准 Markdown 链接（FR-75 / BR-75.1），必须保留为链接。
        if (url.startsWith('sui://') && noteRefId(url) == null) continue;
        out.add(MarkdownLink(
          start: lineStart + m.start,
          end: lineStart + m.end,
          label: m.group(2)!,
          url: url,
        ));
      }
      if (nl == -1) break;
      lineStart = nl + 1;
    }
    return out;
  }

  /// [offset] 落在某个行内链接区间内（含两端）时返回该链接，否则 null。
  ///
  /// 「光标落在链接里」是格式模式弹出**链接条**的判据（§16 / BR-70.1）。
  static MarkdownLink? linkAt(String text, int offset) {
    for (final link in links(text)) {
      if (offset >= link.start && offset <= link.end) return link;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 关联笔记引用（FR-75 / BR-75.1~75.3）
  // ---------------------------------------------------------------------------

  /// 笔记引用的 scheme（FR-75）：正本形态恒为 `[标题](sui://note/<笔记ID>)`（BR-75.1）。
  static const String kNoteRefPrefix = 'sui://note/';

  /// 生成笔记引用的 URL 部分（FR-75）。
  static String noteRefUrl(String noteId) => '$kNoteRefPrefix$noteId';

  /// 解析 [url] 是否为笔记引用；是则返回笔记 ID（**非空、无额外路径段**），否则 null。
  ///
  /// 口径：前缀**大小写敏感**（正本由 [noteRefUrl] 生成，恒为小写）；空 ID、
  /// `sui://note/a/b` 这类多余路径段、非 `sui://note/` 前缀一律 null。
  static String? noteRefId(String url) {
    final u = url.trim();
    if (!u.startsWith(kNoteRefPrefix)) return null;
    final id = u.substring(kNoteRefPrefix.length);
    if (id.isEmpty || id.contains('/')) return null;
    return id;
  }

  /// [offset] 落在哪个**笔记引用**上（格式模式链接条 / 跳转判据，FR-75），否则 null。
  static MarkdownLink? noteRefAt(String text, int offset) {
    for (final link in links(text)) {
      if (offset < link.start || offset > link.end) continue;
      if (noteRefId(link.url) != null) return link;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 网页原件引用（M16 / FR-83）
  // ---------------------------------------------------------------------------

  /// 网页原件的 scheme：正本形态 `[网页原件](sui://webclip/<sha256>)`。
  static const String kWebClipPrefix = 'sui://webclip/';

  static final RegExp _webClipRe =
      RegExp(r'\[([^\]\n]*)\]\(\s*sui://webclip/([0-9a-fA-F]{64})\s*\)');

  /// 正本中的全部网页原件引用（按出现顺序）。
  static List<WebClipRef> webClipRefs(String text) {
    final out = <WebClipRef>[];
    var lineStart = 0;
    while (lineStart <= text.length) {
      final nl = text.indexOf('\n', lineStart);
      final lineEnd = nl == -1 ? text.length : nl;
      final line = _stripCr(text.substring(lineStart, lineEnd));
      for (final m in _webClipRe.allMatches(line)) {
        out.add(WebClipRef(
          start: lineStart + m.start,
          end: lineStart + m.end,
          label: m.group(1) ?? '',
          sha256: m.group(2)!.toLowerCase(),
        ));
      }
      if (nl == -1) break;
      lineStart = nl + 1;
    }
    return out;
  }

  /// [offset] 落在某个网页原件引用区间内（含两端）时返回该引用。
  static WebClipRef? webClipRefAt(String text, int offset) {
    for (final ref in webClipRefs(text)) {
      if (offset >= ref.start && offset <= ref.end) return ref;
    }
    return null;
  }

  /// 结构删除命中判定（M16 / FR-83）：Backspace 看前一位、Delete 看当前位。
  static WebClipRef? webClipRefForDeletion(
    String text,
    int pos, {
    required bool backspace,
  }) {
    final p = pos.clamp(0, text.length);
    final target = backspace ? p - 1 : p;
    return webClipRefAt(text, target);
  }

  /// 整块删除一个网页原件引用所在行（含行尾换行），并折叠成一个空行。
  ///
  /// 单次 `FormatResult` 写入 → 一步撤销；光标落回删除位置。
  static FormatResult deleteWebClip(String text, WebClipRef ref) {
    final lineStart =
        ref.start == 0 ? 0 : text.lastIndexOf('\n', ref.start - 1) + 1;
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd == -1) lineEnd = text.length;
    final end = lineEnd < text.length ? lineEnd + 1 : lineEnd;
    var newText = text.substring(0, lineStart) + text.substring(end);
    var caret = lineStart.clamp(0, newText.length);
    // `a\n\n[webclip]\n\nb` → 删除后 `a\n\n\nb`：再吞掉一个换行，保持一个空行。
    final before = newText.substring(0, caret);
    final after = newText.substring(caret);
    if (before.endsWith('\n\n') && after.startsWith('\n')) {
      // 吞掉**后面**那个换行：保留 `前\n\n后` 的一个空行，光标仍在 `后` 之前。
      newText = before + after.substring(1);
    }
    return FormatResult(newText, caret, caret);
  }

  // ---------------------------------------------------------------------------
  // 笔记内查找与替换（FR-73 / BR-73.1~73.4）
  // ---------------------------------------------------------------------------

  /// 笔记内查找（纯函数，格式 / 源码两态同源，BR-73.1 / FR-73）。
  ///
  /// - **不跨行**匹配：跨行替换风险高，登记为不做的范围；`query` 含 `\n` 时结果为空；
  /// - 大小写不敏感时用 `toLowerCase()` 比较（按**等长片段**比较，保证偏移契约）；
  /// - 空 `query` 返回空列表；命中项**非重叠**推进（与既有扫描口径一致）。
  static List<FindMatch> findMatches(
    String text,
    String query, {
    bool caseSensitive = false,
  }) {
    final out = <FindMatch>[];
    if (query.isEmpty || text.isEmpty) return out;
    final needle = caseSensitive ? query : query.toLowerCase();
    final n = needle.length;
    var lineStart = 0;
    while (lineStart <= text.length) {
      final nl = text.indexOf('\n', lineStart);
      final lineEnd = nl == -1 ? text.length : nl;
      for (var i = lineStart; i + n <= lineEnd; i++) {
        final seg = text.substring(i, i + n);
        if (caseSensitive ? seg == query : seg.toLowerCase() == needle) {
          out.add(FindMatch(i, i + n));
          i += n - 1; // 非重叠推进
        }
      }
      if (nl == -1) break;
      lineStart = nl + 1;
    }
    return out;
  }

  /// **结构区**区间（半开 `[start, end)`；格式模式下不可替换，BR-73.2）：良构表格块 /
  /// 快照 HTML 块 / 附件引用 / 任意记号区间（含 `escape`、链接语法段与**围栏行**）。
  ///
  /// 口径：围栏**内容**可见、**可被替换**；围栏**行**属结构区（FR-81 边界不可破）。
  /// 链接只有 `](网址)` 段落在此处——显示文字仍是可见文本，可被替换（BR-76.2）。
  static List<(int, int)> _structuralRanges(String text) {
    final out = <(int, int)>[];
    // 表格区间同 `_wellFormedTableRanges` 口径：`$2` 为**末行末字符下标**，故 +1 转半开。
    for (final r in _wellFormedTableRanges(text)) {
      out.add((r.$1, r.$2 + 1));
    }
    for (final b in htmlBlocks(text)) {
      out.add((b.start, b.end));
    }
    for (final ref in attachmentRefs(text)) {
      out.add((ref.start, ref.end));
    }
    for (final m in syntaxMarkers(text)) {
      if (m.end > m.start) out.add((m.start, m.end));
    }
    return out;
  }

  /// [offset] 是否落在**结构区**（格式模式下不可替换）内（BR-73.2），否则 false。
  static bool isStructuralOffset(String text, int offset) {
    final pos = offset.clamp(0, text.length);
    for (final r in _structuralRanges(text)) {
      if (pos >= r.$1 && pos < r.$2) return true;
    }
    return false;
  }

  /// 「全部替换」：**一次编辑**（BR-73.3）用 `StringBuffer` 重建全文，只替换**不在结构区**的
  /// 命中项。
  ///
  /// 返回新文本、新选区（落在**最后一次替换的内容之后**；无任何替换时折叠在 0）与
  /// **跳过计数**（BR-73.2 的「已跳过 N 处结构区」）。替换文本由调用方决定是否转义，本层
  /// **不做**隐式转义，也**不引入任何隐藏字符**（BR-73.4）。
  static ({
    String text,
    int selectionStart,
    int selectionEnd,
    int skipped,
  }) replaceAllMatches(
    String text,
    String query,
    String replacement, {
    bool caseSensitive = false,
  }) {
    final matches = findMatches(text, query, caseSensitive: caseSensitive);
    if (matches.isEmpty) {
      return (text: text, selectionStart: 0, selectionEnd: 0, skipped: 0);
    }
    final structural = _structuralRanges(text);
    bool hitsStructural(FindMatch m) {
      for (final r in structural) {
        if (r.$1 < m.end && r.$2 > m.start) return true;
      }
      return false;
    }

    final buf = StringBuffer();
    var cursor = 0;
    var skipped = 0;
    var caret = 0;
    var replaced = false;
    for (final m in matches) {
      if (hitsStructural(m)) {
        skipped++;
        continue;
      }
      buf.write(text.substring(cursor, m.start));
      buf.write(replacement);
      cursor = m.end;
      caret = buf.length;
      replaced = true;
    }
    buf.write(text.substring(cursor));
    return (
      text: buf.toString(),
      selectionStart: replaced ? caret : 0,
      selectionEnd: replaced ? caret : 0,
      skipped: skipped,
    );
  }

  /// 「替换当前一处」：只替换 [match] 一处，同样**一次编辑、一步撤销**（BR-73.3）。
  ///
  /// 结构区的跳过判定由调用方先行完成（[isStructuralOffset]）；本方法只做就地替换并把
  /// 光标落到替换内容之后。
  static ({String text, int selectionStart, int selectionEnd}) replaceMatch(
    String text,
    FindMatch match,
    String replacement,
  ) {
    final s = match.start.clamp(0, text.length);
    final e = match.end.clamp(s, text.length);
    final newText = text.substring(0, s) + replacement + text.substring(e);
    final caret = s + replacement.length;
    return (text: newText, selectionStart: caret, selectionEnd: caret);
  }

  // ---------------------------------------------------------------------------
  // 格式模式输入转义（FR-78 / BR-78.1~78.5）
  // ---------------------------------------------------------------------------

  /// 行内**恒敏感**的 ASCII 标点：任何位置被键入都转义（FR-78 / BR-78.1）。
  static const String _typingInlineSensitive = r'\`*_~=[]<&|';

  /// **行首敏感**的 ASCII 标点：其前只有行首空白时才转义。
  static const String _typingLineStartSensitive = '#-+>|';

  /// 「数字 + `.`」判定：光标前缀只有行首空白与数字（BR-78.2：只转义 `.`，数字不转义）。
  static final RegExp _typingOrderedPrefixRe = RegExp(r'^[ \t]*\d+$');

  /// [offset] 是否处于**围栏代码块内部**或**行内代码跨度内**（BR-78.3：代码区不转义）。
  ///
  /// - 围栏：从文首逐行扫 `_fencePrefixRe` 翻转 `inFence`；`offset` 所在行是围栏行，
  ///   或进入该行时已在围栏内 → true；
  /// - 行内代码：本行 `[行首, offset)` 内**未被转义**的反引号个数为**奇数** → true。
  static bool isInsideCodeRegion(String text, int offset) {
    final n = text.length;
    final pos = offset.clamp(0, n);
    final lineStart = pos == 0 ? 0 : text.lastIndexOf('\n', pos - 1) + 1;
    final line = _stripCr(text.substring(lineStart, _lineEndAt(text, lineStart)));

    // ① 围栏块状态。
    var inFence = false;
    var ls = 0;
    while (ls < lineStart) {
      final le = _lineEndAt(text, ls);
      if (_fencePrefixRe.hasMatch(_stripCr(text.substring(ls, le)))) {
        inFence = !inFence;
      }
      ls = le + 1;
    }
    if (inFence || _fencePrefixRe.hasMatch(line)) return true;

    // ② 行内代码跨度。
    final prefix = text.substring(lineStart, pos);
    final escaped = <int>{};
    for (final (bs, end) in _escapeSpans(prefix)) {
      for (var i = bs; i < end; i++) {
        escaped.add(i);
      }
    }
    var ticks = 0;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] == '`' && !escaped.contains(i)) ticks++;
    }
    return ticks.isOdd;
  }

  /// 「格式模式」键入一个字符时，返回**应当写入正本**的文本（可能带前置反斜杠）。
  ///
  /// 口径（FR-78 / BR-78.1\~78.5）：
  /// - 只转义**会改变语法树**的 ASCII 标点：行内恒敏感（任何位置）；行首敏感的
  ///   `#` `-` `+` `>` 只在其前只有行首空白时转义；「数字 + `.`」只转义 **`.`**；
  /// - **只转义合法转义目标**（ASCII 标点）——字母 / 数字 / 空格**绝不**前置反斜杠
  ///   （BR-78.2：`\a` / `\1` / `\ ` 不是合法转义，只会把反斜杠留在预览里）；
  /// - 围栏代码块内 / 行内代码跨度内**不转义**（BR-78.3）；
  /// - [inTableCell] 为 true 时跳过所有**行首敏感**判定（单元格是行内语境），且 `|` **不转义**
  ///   （由 `escapeTableCell` 在提交时统一处理，避免双重转义）；其余行内敏感字符照转义；
  /// - 长度不为 1 或非 ASCII 标点 → 原样返回。
  ///
  /// 本层**只返回字符串、不改任何文本**（BR-78.5：粘贴与程序化写入不经过本函数）。
  static String escapeForTyping(
    String text,
    int offset,
    String typed, {
    bool inTableCell = false,
  }) {
    if (typed.length != 1) return typed;
    if (!_isEscapableAsciiPunct(typed)) return typed;
    final pos = offset.clamp(0, text.length);
    if (isInsideCodeRegion(text, pos)) return typed;
    if (_typingInlineSensitive.contains(typed)) {
      if (inTableCell && typed == '|') return typed;
      return '\\$typed';
    }
    if (inTableCell) return typed;
    final lineStart = pos == 0 ? 0 : text.lastIndexOf('\n', pos - 1) + 1;
    final prefix = text.substring(lineStart, pos);
    if (typed == '.') {
      return _typingOrderedPrefixRe.hasMatch(prefix) ? '\\.' : typed;
    }
    if (_typingLineStartSensitive.contains(typed) && prefix.trim().isEmpty) {
      return '\\$typed';
    }
    return typed;
  }

  // ---------------------------------------------------------------------------
  // 粘贴（BR-23.4）
  // ---------------------------------------------------------------------------

  /// Markdown 需转义的特殊字符（用于纯文本粘贴的安全插入）。
  static const String _mdSpecial = r'\`*_{}[]()#+!|>~';

  /// 纯文本粘贴：转义 Markdown 特殊字符，作为安全文本插入，避免被误解析。
  static String escapePlainText(String raw) {
    final buf = StringBuffer();
    for (final ch in raw.split('')) {
      if (_mdSpecial.contains(ch)) buf.write('\\');
      buf.write(ch);
    }
    return buf.toString();
  }

  /// 富文本粘贴：**尽力**把 HTML 转为等价 Markdown。
  ///
  /// 只识别常见标记；无法转换的部分保留其文本内容（降级为纯文本，不丢内容）。
  /// 若完全不含可识别标记，返回原文本。
  static String htmlToMarkdown(String html) {
    if (!html.contains('<')) return html;
    var out = html;

    // 表格优先整体转换（否则后续「去标签」会抹平表格结构，§12.2「表格」）。
    out = out.replaceAllMapped(
        RegExp(r'<\s*table\b[^>]*>(.*?)<\s*/\s*table>',
            caseSensitive: false, dotAll: true),
        (m) => _htmlTableToMarkdown(m.group(1)!));

    // 块级元素先处理。
    out = out.replaceAllMapped(
        RegExp(r'<\s*h1[^>]*>(.*?)<\s*/\s*h1>',
            caseSensitive: false, dotAll: true),
        (m) => '\n# ${m.group(1)}\n');
    out = out.replaceAllMapped(
        RegExp(r'<\s*h2[^>]*>(.*?)<\s*/\s*h2>',
            caseSensitive: false, dotAll: true),
        (m) => '\n## ${m.group(1)}\n');
    out = out.replaceAllMapped(
        RegExp(r'<\s*h3[^>]*>(.*?)<\s*/\s*h3>',
            caseSensitive: false, dotAll: true),
        (m) => '\n### ${m.group(1)}\n');
    out = out.replaceAllMapped(
        RegExp(r'<\s*li[^>]*>(.*?)<\s*/\s*li>',
            caseSensitive: false, dotAll: true),
        (m) => '- ${m.group(1)}\n');
    out = out.replaceAllMapped(
        RegExp(r'<\s*blockquote[^>]*>(.*?)<\s*/\s*blockquote>',
            caseSensitive: false, dotAll: true),
        (m) => '\n> ${m.group(1)}\n');
    out = out.replaceAllMapped(
        RegExp(r'<\s*p[^>]*>(.*?)<\s*/\s*p>',
            caseSensitive: false, dotAll: true),
        (m) => '\n${m.group(1)}\n');
    out = out.replaceAll(
        RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n');

    // 行内元素。
    out = out.replaceAllMapped(
        RegExp(r'<\s*(strong|b)[^>]*>(.*?)<\s*/\s*\1>',
            caseSensitive: false, dotAll: true),
        (m) => '**${m.group(2)}**');
    out = out.replaceAllMapped(
        RegExp(r'<\s*(em|i)[^>]*>(.*?)<\s*/\s*\1>',
            caseSensitive: false, dotAll: true),
        (m) => '*${m.group(2)}*');
    out = out.replaceAllMapped(
        RegExp(r'<\s*(s|del|strike)[^>]*>(.*?)<\s*/\s*\1>',
            caseSensitive: false, dotAll: true),
        (m) => '~~${m.group(2)}~~');
    out = out.replaceAllMapped(
        RegExp(r'<\s*code[^>]*>(.*?)<\s*/\s*code>',
            caseSensitive: false, dotAll: true),
        (m) => '`${m.group(1)}`');
    out = out.replaceAllMapped(
        RegExp(r'''<\s*a\b[^>]*href\s*=\s*["']([^"']*)["'][^>]*>(.*?)<\s*/\s*a>''',
            caseSensitive: false,
            dotAll: true),
        (m) => '[${m.group(2)}](${m.group(1)})');

    // 其余标签一律去掉（保留其文本内容，不丢失）。
    out = out.replaceAll(RegExp(r'<[^>]+>'), '');
    out = out.replaceAll(RegExp(r'&nbsp;'), ' ');
    out = out.replaceAll(RegExp(r'&amp;'), '&');
    out = out.replaceAll(RegExp(r'&lt;'), '<');
    out = out.replaceAll(RegExp(r'&gt;'), '>');
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return out.trim();
  }

  // ---------------------------------------------------------------------------
  // 附件引用的原子编辑单元（M9 / FR-46 / §12.4）
  // ---------------------------------------------------------------------------

  /// 附件引用匹配：图片 `![alt](sui://<sha>)` 或链接 `[name](sui://<sha>)`。
  ///
  /// 闭合 `)` 设为**可选**，以便残缺引用（缺 `)`）仍被整块识别（§12.4 残缺自愈）。
  static final RegExp _attachmentRefPattern = RegExp(
    r'(!?)\[([^\]]*)\]\(\s*sui://([0-9a-fA-F]+)\s*\)?',
  );

  /// 枚举 [source] 中全部附件引用（图片 + 链接），按出现顺序返回。
  ///
  /// 图片引用若紧随 §5 尺寸属性块 `{...}`（同行），[AttachmentRef.end] 一并覆盖该属性块。
  /// 未识别为附件引用的文本原样透传（绝不删改，守往返保真）。
  static List<AttachmentRef> attachmentRefs(String source) {
    final result = <AttachmentRef>[];
    for (final m in _attachmentRefPattern.allMatches(source)) {
      final isImage = m.group(1) == '!';
      var end = m.end;
      final corrupt = !source.startsWith(')', m.end - 1) || m.end == m.start;
      // 图片：紧随其后的尺寸属性块（同行、可含空格）并入原子块。
      if (isImage) {
        var cursor = m.end;
        while (cursor < source.length &&
            (source[cursor] == ' ' || source[cursor] == '\t')) {
          cursor++;
        }
        if (cursor < source.length && source[cursor] == '{') {
          final close = source.indexOf('}', cursor + 1);
          final nl = source.indexOf('\n', cursor + 1);
          if (close != -1 && (nl == -1 || close < nl)) {
            if (parseSizeAttribute(source.substring(cursor, close + 1)) != null) {
              end = close + 1;
            }
          }
        }
      }
      result.add(AttachmentRef(
        start: m.start,
        end: end,
        label: m.group(2) ?? '',
        sha256: (m.group(3) ?? '').toLowerCase(),
        isImage: isImage,
        corrupt: corrupt,
      ));
    }
    return result;
  }

  /// 返回**光标落在其内或边界**的附件引用；无则返回 null。
  ///
  /// [offset] 处于 `[start, end]` 闭区间即视为命中，供选中 / 复制 / 移动按整块处理。
  static AttachmentRef? attachmentRefAt(String source, int offset) {
    final pos = offset.clamp(0, source.length);
    for (final ref in attachmentRefs(source)) {
      if (pos >= ref.start && pos <= ref.end) return ref;
    }
    return null;
  }

  /// 判断一次删除键是否应触发**整块删除**附件引用（BR-46.1 / BR-46.2）。
  ///
  /// - `backspace == true`（退格）：`offset` 恰在引用末端（`ref.end`）或引用内部；
  /// - `backspace == false`（Delete）：`offset` 恰在引用起点（`ref.start`）或引用内部。
  ///
  /// 命中时返回该引用，调用方应整块删除（不进入内部逐字符删除）；否则返回 null。
  static AttachmentRef? attachmentRefForDeletion(
    String source,
    int offset, {
    required bool backspace,
  }) {
    final pos = offset.clamp(0, source.length);
    for (final ref in attachmentRefs(source)) {
      if (pos > ref.start && pos < ref.end) return ref; // 光标在引用内部
      if (backspace && pos == ref.end) return ref; // 退格落在引用末尾边界
      if (!backspace && pos == ref.start) return ref; // Delete 落在引用起点边界
    }
    return null;
  }

  /// 整块删除附件引用，返回新正本与新光标位置（作为**一次**可撤销编辑，BR-46.5）。
  ///
  /// 若引用**独占整行**，连同该行换行一并移除，避免残留空行；行内引用仅删除引用本身，
  /// 其余字符逐字不动（守 §4.1）。
  static FormatResult deleteAttachmentRef(String text, AttachmentRef ref) {
    var s = ref.start.clamp(0, text.length);
    var e = ref.end.clamp(0, text.length);
    final lineStart = s == 0 ? 0 : text.lastIndexOf('\n', s - 1) + 1;
    final nl = text.indexOf('\n', e);
    final lineEnd = nl == -1 ? text.length : nl;
    if (s == lineStart && e == lineEnd) {
      if (nl != -1) {
        e = nl + 1; // 独占整行且非末行：连行尾换行一起删
      } else if (s > 0 && text[s - 1] == '\n') {
        s = s - 1; // 独占末行：删前导换行
      }
    }
    final newText = text.substring(0, s) + text.substring(e);
    final caret = s.clamp(0, newText.length);
    return FormatResult(newText, caret, caret);
  }

  /// 判断一次删除键是否应触发**整块删除**整张表格（BR-44.6 / §12.1.1 ⑥⑦）。
  ///
  /// 表格是原子单元（承 §12.1 / BR-44.2），正文光标经吸附只能停在表格前一行或表格**下方
  /// 默认空行的行首**（`table.end + 1`）；若把 `Backspace` / `Delete` 落到表格内部字符
  /// （如末尾 `|`）会改坏管道表源码，使 `parseTable(...).wellFormed` 转假，表格**非法回退为原文**
  /// （「打回原形」）。
  ///
  /// - `backspace == true`：删除点落在表格字符区间 `[start, end]` 上，或落在表格**下方默认空行
  ///   的行首**（`offset == end + 1`，即表格末尾那个行尾换行**之后**）→ 命中；
  /// - `backspace == false`：删除点（`offset`）落在 `[start, end)` 内 → 命中（含 `offset == start`）。
  ///
  /// 命中时返回该表格，调用方应整块删除（不进入逐字符删除）；否则返回 null。
  /// 仅**合规**表格（`wellFormed`）参与判定——残缺 / 非法表按普通文本透传（BR-44.5）。
  static ParsedTable? tableForDeletion(
    String source,
    int offset, {
    required bool backspace,
  }) {
    final pos = offset.clamp(0, source.length);
    var from = 0;
    while (from < source.length) {
      final table = parseTable(source, from);
      if (table == null) {
        final nl = source.indexOf('\n', from);
        if (nl == -1) break;
        from = nl + 1;
        continue;
      }
      if (table.wellFormed) {
        final s = table.start;
        final e = table.end;
        // 退格落在表格字符上（含末尾 `|`），或落在表格下方「默认空行」行首（末尾换行之后）。
        // `pos == e + 1` 成立时必有 `e < source.length` 且 `source[e] == '\n'`（parseTable 的 end
        // 恒指向行尾换行），故该落点即「表格下方默认空行」的行首。
        if (backspace && pos > s && pos <= e + 1) return table;
        if (!backspace && pos >= s && pos < e) return table; // Delete 落在表格字符上
      }
      if (table.end >= source.length) break;
      from = table.end + 1;
    }
    return null;
  }

  /// 整块删除一张表格，返回新正本与新光标位置（作为**一次**可撤销编辑，BR-44.6）。
  ///
  /// 连同表格块**行尾换行**一并移除；表格位于文末（无后续换行）时改删**前导换行**，
  /// 避免残留空行。表格之外字符**逐字不动**（守 §4.1）。
  static FormatResult deleteTable(String text, ParsedTable table) {
    var s = table.start.clamp(0, text.length);
    var e = table.end.clamp(0, text.length);
    if (e < text.length && text[e] == '\n') {
      e = e + 1; // 表格块后带换行：连行尾换行一起删
    } else if (s > 0 && text[s - 1] == '\n') {
      s = s - 1; // 表格位于文末：删前导换行，避免残留空行
    }
    final newText = text.substring(0, s) + text.substring(e);
    final caret = s.clamp(0, newText.length);
    return FormatResult(newText, caret, caret);
  }

  /// 就地修复**残缺引用**（缺 `)`）：补上闭合括号。
  ///
  /// 返回新文本与光标；[ref] 非残缺时原样返回（无操作）。供 §12.4「残缺自愈」。
  static FormatResult repairAttachmentRef(String text, AttachmentRef ref) {
    if (!ref.corrupt) {
      final caret = ref.end.clamp(0, text.length);
      return FormatResult(text, caret, caret);
    }
    final newText = '${text.substring(0, ref.end)})${text.substring(ref.end)}';
    final caret = ref.end + 1;
    return FormatResult(newText, caret, caret);
  }

  /// 内容寻址写回：把文本中所有指向 [oldSha256] 的 `sui://` 引用替换为 [newSha256]。
  ///
  /// 用于 M9-T09「附件外部编辑更新回写」（见 attachment-store.md §12）——新字节
  /// 产生新 sha256，正本内旧引用整体改指新内容；其余字符逐字不动（守 §4.1）。
  /// 返回 null 表示文本中不含旧引用（无须回写）。
  static String? replaceAttachmentSha256(
    String text,
    String oldSha256,
    String newSha256,
  ) {
    final old = oldSha256.toLowerCase();
    final refs = attachmentRefs(text);
    final hits = refs.where((r) => r.sha256 == old).toList();
    if (hits.isEmpty) return null;
    final buf = StringBuffer();
    var cursor = 0;
    for (final ref in refs) {
      if (ref.sha256 != old) continue;
      // 保留原前缀 / 属性块：只在 sha256 段内替换。
      final shaStart = text.indexOf('sui://', ref.start) + 'sui://'.length;
      final shaEnd = shaStart + old.length;
      buf.write(text.substring(cursor, shaStart));
      buf.write(newSha256);
      cursor = shaEnd;
    }
    buf.write(text.substring(cursor));
    return buf.toString();
  }
  // ---------------------------------------------------------------------------
  // 格式模式「所见即预览」：记号扫描、原子删除与表格边界保护
  // （M9 缺陷修复 / editor-formatting.md §13 / BR-23.7~BR-23.9 / BR-44.11）
  // ---------------------------------------------------------------------------

  /// 行级前缀：标题（允许 ≤3 空格前导，与 CommonMark 一致）。
  static final RegExp _headingPrefixRe = RegExp(r'^([ \t]{0,3})(#{1,6})([ \t]+)');

  /// 行级前缀：无序列表（缩进合法性另由 [isListLineAt] 判定）。
  static final RegExp _bulletPrefixRe = RegExp(r'^([ \t]*)([-*+][ \t]+)');

  /// 行级前缀：有序列表（缩进合法性另由 [isListLineAt] 判定）。
  static final RegExp _orderedPrefixRe = RegExp(r'^([ \t]*)(\d+\.[ \t]+)');

  /// 行级前缀：引用（≤3 空格前导）。
  static final RegExp _quotePrefixRe = RegExp(r'^([ \t]{0,3})(>[ \t]?)');

  /// 围栏行（``` / ~~~，可带信息串）。
  static final RegExp _fencePrefixRe = RegExp(r'^([ \t]*)(```|~~~)');

  /// 分割线行（≤3 空格前导）。
  static final RegExp _rulePrefixRe =
      RegExp(r'^([ \t]{0,3})(-{3,}|\*{3,}|_{3,})[ \t]*$');

  /// 行内记号（与样式层 `_MarkdownStyler._inline` 同口径）：
  /// 1 行内代码 / 2 图片 / 3 链接 / 4 `**` / 5 `__` / 6 `~~` / 7 `*` / 8 `_` / 9 `==`。
  static final RegExp _inlineMarkerRe = RegExp(
    r'(`[^`\n]+`)'
    r'|(!\[[^\]\n]*\]\([^)\n]*\))'
    r'|(\[[^\]\n]*\]\([^)\n]*\))'
    r'|(\*\*[^*\n]+\*\*)'
    r'|(__[^_\n]+__)'
    r'|(~~[^~\n]+~~)'
    r'|(\*[^*\n]+\*)'
    r'|(_[^_\n]+_)'
    r'|(==[^=\n]+==)',
  );

  /// 行尾 `\r`（CRLF 正本）在匹配前剥除；`\r` 是行尾最后一个码元，剥除**不改任何偏移**。
  ///
  /// FR-77 / BR-77.2：历史 CRLF 正本（Windows 剪贴板经源码模式粘贴注入）里的 `\r` 会让
  /// 「零容错的字面正则」整行降级（勾选框 / 分割线 / setext 都不再成记号）。容错只发生在
  /// **扫描视图**内——正本字节一字不改，`spans` 与正本仍逐码元等长。
  static String _stripCr(String line) =>
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line;

  /// 行首偏移 [lineStart] 所在行的文本（不含行尾换行；行尾 `\r` 已按 FR-77 剥除）。
  static String _lineText(String text, int lineStart) {
    final s = lineStart.clamp(0, text.length);
    final nl = text.indexOf('\n', s);
    return _stripCr(text.substring(s, nl == -1 ? text.length : nl));
  }

  /// 行首偏移 [lineStart] 所在行的**行尾**（不含换行；行尾即换行符下标或文本末尾）。
  static int _lineEndAt(String text, int lineStart) {
    final s = lineStart.clamp(0, text.length);
    final nl = text.indexOf('\n', s);
    return nl == -1 ? text.length : nl;
  }

  /// 所有**良构表格**块的区间（`[start, end]`，`end` 为末行末字符下标）。
  static List<(int, int)> _wellFormedTableRanges(String text) {
    final ranges = <(int, int)>[];
    var from = 0;
    while (from < text.length) {
      final table = parseTable(text, from);
      if (table == null) {
        final nl = text.indexOf('\n', from);
        if (nl == -1) break;
        from = nl + 1;
        continue;
      }
      if (table.wellFormed) ranges.add((table.start, table.end));
      if (table.end >= text.length) break;
      from = table.end + 1;
    }
    return ranges;
  }

  /// 是否为**行级前缀**类记号（删除时按「整行前缀」处理）。
  static bool _isPrefixKind(SyntaxMarkerKind kind) =>
      kind == SyntaxMarkerKind.heading ||
      kind == SyntaxMarkerKind.bullet ||
      kind == SyntaxMarkerKind.ordered ||
      kind == SyntaxMarkerKind.task ||
      kind == SyntaxMarkerKind.quote;

  /// setext 标题下划线（`===` / `---`，≥1 个字符）。
  static final RegExp _setextUnderlineRe = RegExp(r'^[ \t]{0,3}(={1,}|-{1,})[ \t]*$');

  /// `---` 是否真是**分割线**（上一行是普通段落时，GFM 视为 setext 标题下划线，不是分割线）。
  static bool _isThematicBreak(String text, int lineStart) =>
      !_hasParagraphAbove(text, lineStart);

  /// [lineStart] 行的**上一行**是否为普通段落行（非空、且不是列表 / 引用 / 标题 / 围栏等块级标记行）。
  static bool _hasParagraphAbove(String text, int lineStart) {
    if (lineStart == 0) return false;
    final prevNl = lineStart >= 2 ? text.lastIndexOf('\n', lineStart - 2) : -1;
    final prevStart = prevNl == -1 ? 0 : prevNl + 1;
    final prev = _stripCr(text.substring(prevStart, lineStart - 1));
    if (prev.trim().isEmpty) return false;
    if (_listMarkerWidth(prev) > 0) return false;
    if (_quotePrefixRe.hasMatch(prev) || _headingPrefixRe.hasMatch(prev)) {
      return false;
    }
    if (_fencePrefixRe.hasMatch(prev)) return false;
    return true;
  }

  /// [lineStart] 行是否为 **setext 标题下划线**（`标题` 的下一行写 `===` / `---`）。
  ///
  /// 「格式」模式据此把**上一行**按 h2 呈现、把本行记号隐藏，与「预览」一致（§13.2 / BR-23.7）。
  static bool isSetextUnderlineAt(String text, int lineStart) {
    final line = _lineText(text, lineStart);
    if (!_setextUnderlineRe.hasMatch(line)) return false;
    return _hasParagraphAbove(text, lineStart);
  }

  /// 扫描正本中**被 Markdown 解析为语法**的记号区间（§13.2 / BR-23.7）。
  ///
  /// 纪律：
  /// - **围栏代码块内部**不扫描（预览同样不解析其中的 Markdown）；
  /// - **良构表格块内部**不扫描（整表已是一个「表格呈现单元」，其 Markdown 由表格 UI 承担）；
  /// - **缩进越界**的行（GFM 会解析为缩进代码块 / 懒续行）**不建立**行级前缀记号——与预览的
  ///   行级结构判定保持一致（BR-23.9②）；
  /// - **未识别 / 落单**的记号不进集合（预览也只是原样文本），故两态一致。
  static List<SyntaxMarker> syntaxMarkers(String text) {
    final out = <SyntaxMarker>[];
    final n = text.length;
    if (n == 0) return out;
    final tables = _wellFormedTableRanges(text);
    final ordered = orderedListNumbers(text);
    var pairId = 0;
    int nextPair() => pairId++;
    var lineStart = 0;
    var lineIndex = 0;
    var inFence = false;
    var fencePair = -1;
    while (lineStart <= n) {
      final nl = text.indexOf('\n', lineStart);
      final lineEnd = nl == -1 ? n : nl;
      final line = _stripCr(text.substring(lineStart, lineEnd));
      final inTable =
          tables.any((r) => lineStart >= r.$1 && lineStart <= r.$2);
      if (inFence) {
        if (_fencePrefixRe.hasMatch(line)) {
          out.add(SyntaxMarker(lineStart, lineEnd, SyntaxMarkerKind.fence,
              lineStart: lineStart, pairId: fencePair));
          inFence = false;
          fencePair = -1;
        }
      } else if (!inTable && _fencePrefixRe.hasMatch(line)) {
        inFence = true;
        fencePair = nextPair();
        out.add(SyntaxMarker(lineStart, lineEnd, SyntaxMarkerKind.fence,
            lineStart: lineStart, pairId: fencePair));
      } else if (!inTable) {
        _scanLineMarkers(
            text, lineStart, lineEnd, line, ordered, lineIndex, out, nextPair);
      }
      if (lineEnd >= n) break;
      lineStart = lineEnd + 1;
      lineIndex++;
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  /// **单元格**（单行文本）内的行内记号扫描（§12.1.2 / §13.2，供单元格富文本控制器复用）。
  static List<SyntaxMarker> inlineSyntaxMarkers(String text) {
    final out = <SyntaxMarker>[];
    if (text.isEmpty) return out;
    var pairId = 0;
    _scanInlineMarkers(text, 0, out, () => pairId++);
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  /// 单行内的行级前缀 + 行内记号扫描。
  static void _scanLineMarkers(
    String text,
    int lineStart,
    int lineEnd,
    String line,
    List<int?> ordered,
    int lineIndex,
    List<SyntaxMarker> out,
    int Function() nextPair,
  ) {
    final indent = _leadingWhitespace.firstMatch(line)!.group(0)!.length;
    final task = _taskLine.firstMatch(line);
    final bullet = _bulletPrefixRe.firstMatch(line);
    final orderedLine = _orderedPrefixRe.firstMatch(line);
    final heading = _headingPrefixRe.firstMatch(line);
    final quote = _quotePrefixRe.firstMatch(line);
    if (task != null && isListLineAt(text, lineStart)) {
      var end = lineStart + task.group(1)!.length + 3;
      if (end < lineEnd && (text[end] == ' ' || text[end] == '\t')) end++;
      out.add(SyntaxMarker(
        lineStart + indent,
        end,
        SyntaxMarkerKind.task,
        lineStart: lineStart,
        checked: task.group(2)!.toLowerCase() == 'x',
      ));
    } else if (bullet != null && isListLineAt(text, lineStart)) {
      out.add(SyntaxMarker(
        lineStart + indent,
        lineStart + bullet.group(1)!.length + bullet.group(2)!.length,
        SyntaxMarkerKind.bullet,
        lineStart: lineStart,
      ));
    } else if (orderedLine != null && isListLineAt(text, lineStart)) {
      final digitsStart = lineStart + indent;
      final digits = orderedLine.group(2)!.trimRight().length;
      var end = digitsStart + digits;
      if (end < lineEnd && (text[end] == ' ' || text[end] == '\t')) end++;
      final literal = int.tryParse(orderedLine.group(2)!.trimRight().replaceAll('.', '')) ?? 1;
      final display = (lineIndex >= 0 && lineIndex < ordered.length)
          ? (ordered[lineIndex] ?? literal)
          : literal;
      out.add(SyntaxMarker(
        digitsStart,
        end,
        SyntaxMarkerKind.ordered,
        lineStart: lineStart,
        displayNumber: display,
      ));
    } else if (heading != null) {
      out.add(SyntaxMarker(
        lineStart,
        lineStart +
            heading.group(1)!.length +
            heading.group(2)!.length +
            heading.group(3)!.length,
        SyntaxMarkerKind.heading,
        lineStart: lineStart,
      ));
    } else if (quote != null) {
      out.add(SyntaxMarker(
        lineStart,
        lineStart + quote.group(1)!.length + quote.group(2)!.length,
        SyntaxMarkerKind.quote,
        lineStart: lineStart,
      ));
    } else if (_rulePrefixRe.hasMatch(line) &&
        _isThematicBreak(text, lineStart)) {
      // 分割线在「格式 / 预览」里是「把 `\n---\n` 当作一个整体」的原子块（BR-72.2/72.3）：
      // 规则记号区间 = **上方空行的行尾换行** + `---` 行 + **该行自身的行尾换行**。呈现层据此
      // 把整段折叠为一个紧贴的规则 WidgetSpan（内部换行以 U+2060 顶替、不建立行盒）。
      // 两点口径（`v0.14.3` 补正）：
      //   ① `---` 行自身的行尾换行**必须**纳入区间；否则它会作为真正的换行在呈现单元之后再建立
      //      一个行盒，视觉上正是「插入分割线后多出一行」；
      //   ② 下方空行的换行**不**纳入（它是段落之间的空行，仍作真正的换行）。
      var ruleStart = lineStart;
      var ruleEnd = lineEnd;
      if (ruleEnd < text.length && text[ruleEnd] == '\n') ruleEnd++;
      // 上方空行：其行尾换行在 lineStart-1，且再往前一格也是换行（两个连续 `\n`）。
      if (ruleStart > 0 &&
          text[ruleStart - 1] == '\n' &&
          (ruleStart == 1 || text[ruleStart - 2] == '\n')) {
        ruleStart--;
      }
      out.add(SyntaxMarker(ruleStart, ruleEnd, SyntaxMarkerKind.rule,
          lineStart: lineStart));
    } else if (isSetextUnderlineAt(text, lineStart)) {
      out.add(SyntaxMarker(lineStart, lineEnd, SyntaxMarkerKind.setext,
          lineStart: lineStart));
    }
    _scanInlineMarkers(line, lineStart, out, nextPair);
  }

  /// 合法转义的 ASCII 标点全集（CommonMark：反斜杠只对 ASCII 标点成立，FR-78 / BR-78.2）。
  ///
  /// 用 `const String` + `contains` 判定，避免正则里的转义地狱。
  static const String _escapableAsciiPunct =
      r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

  /// [ch] 是否为**合法转义目标**（单个 ASCII 标点）。
  static bool _isEscapableAsciiPunct(String ch) =>
      ch.length == 1 && _escapableAsciiPunct.contains(ch);

  /// 一行内**逐个**解析转义序列（左到右，`\\` 视为「转义反斜杠」并消费 2 个码元）。
  ///
  /// 返回每处 `(反斜杠下标, 被转义字符下标 + 1)`——即区间 `[bs, bs + 2)`（FR-78 / BR-78.4）。
  static List<(int, int)> _escapeSpans(String line) {
    final out = <(int, int)>[];
    var i = 0;
    while (i < line.length) {
      if (line[i] == r'\' &&
          i + 1 < line.length &&
          _isEscapableAsciiPunct(line[i + 1])) {
        out.add((i, i + 2));
        i += 2;
      } else {
        i++;
      }
    }
    return out;
  }

  /// 把转义序列的两个码元替换为**等长占位字符** `\uE000`（私用区，任何 `_inlineMarkerRe`
  /// 分支都不可能匹配），从而：
  /// ① 匹配不会从被转义字符开始；② 匹配不会跨越被转义字符而错配（`*a\*b*` 仍能整体成对）。
  /// 蒙版与原始行**等长**，下标可直接复用；正本字节一字不改（FR-78 / BR-78.4）。
  static String _maskEscapes(String line) {
    final spans = _escapeSpans(line);
    if (spans.isEmpty) return line;
    final buf = StringBuffer();
    var cursor = 0;
    for (final (bs, end) in spans) {
      buf.write(line.substring(cursor, bs));
      buf.write('\uE000' * (end - bs));
      cursor = end;
    }
    buf.write(line.substring(cursor));
    return buf.toString();
  }

  /// 行内记号扫描（成对记号生成**两个**同 `pairId` 的记号）。
  ///
  /// FR-78 / BR-78.4：先按**原始行**产出 `escape` 记号（转义序列是原子记号，无 `pairId`），
  /// 再在**蒙版行**上做递归扫描——被转义字符既不参与候选，也不会被误判为记号。
  static void _scanInlineMarkers(
    String line,
    int offset,
    List<SyntaxMarker> out,
    int Function() nextPair,
  ) {
    for (final (bs, end) in _escapeSpans(line)) {
      out.add(SyntaxMarker(offset + bs, offset + end, SyntaxMarkerKind.escape));
    }
    _scanInlineRange(_maskEscapes(line), 0, line.length, offset, out, nextPair);
  }

  /// 在 `[from, to)` 内扫描行内记号；成对记号命中后**递归进入其内容区间**（FR-79 / BR-79.1）。
  ///
  /// 下标一律为**行内绝对下标**（在 `masked` 上算；`masked` 与原始行等长）。
  /// - 行内代码：**不递归**（代码内不解析 Markdown）；
  /// - 图片引用：整块由图片呈现单元承担，不产出记号、**不递归**；
  /// - 链接：**不递归**（与旧 flat 扫描的非重叠推进口径一致）；
  /// - `highlight`：**不递归**——预览侧 `_HighlightSyntax` 明确「内容按纯文本承载、不做嵌套
  ///   解析」（`markdown_editor.dart`），若递归则 `==~~文字~~==` 会多出一层 `strike`、
  ///   格式模式可见文本由 `~~文字~~` 变成 `文字`，制造两态**新分裂**（BR-79.2 反向组合
  ///   保持现状）。正反组合由此各自与预览一致。
  static void _scanInlineRange(
    String masked,
    int from,
    int to,
    int offset,
    List<SyntaxMarker> out,
    int Function() nextPair,
  ) {
    if (to <= from) return;
    for (final m in _inlineMarkerRe.allMatches(masked.substring(from, to))) {
      final ls = from + m.start;
      final le = from + m.end;
      if (m.group(1) != null) {
        // 行内代码 `x`：开闭单引号各一个记号。
        final id = nextPair();
        out.add(SyntaxMarker(
            offset + ls, offset + ls + 1, SyntaxMarkerKind.code, pairId: id));
        out.add(SyntaxMarker(
            offset + le - 1, offset + le, SyntaxMarkerKind.code, pairId: id));
      } else if (m.group(2) != null) {
        // 图片引用：整块由**图片呈现单元**承担（此处不产生记号）。
        continue;
      } else if (m.group(3) != null) {
        final rb = masked.indexOf(']', ls);
        final lp = masked.indexOf('(', rb);
        if (rb < 0 || lp < 0) continue;
        final id = nextPair();
        out.add(SyntaxMarker(
            offset + ls, offset + ls + 1, SyntaxMarkerKind.link, pairId: id));
        out.add(SyntaxMarker(
            offset + rb, offset + le, SyntaxMarkerKind.link, pairId: id));
      } else if (m.group(4) != null || m.group(5) != null) {
        _pairMarkers(out, offset, ls, le, 2, SyntaxMarkerKind.strong, nextPair);
        if (le - ls > 4) {
          _scanInlineRange(masked, ls + 2, le - 2, offset, out, nextPair);
        }
      } else if (m.group(6) != null) {
        _pairMarkers(out, offset, ls, le, 2, SyntaxMarkerKind.strike, nextPair);
        if (le - ls > 4) {
          _scanInlineRange(masked, ls + 2, le - 2, offset, out, nextPair);
        }
      } else if (m.group(9) != null) {
        // 高亮**不递归**：内容按纯文本承载（与预览 `_HighlightSyntax` 同口径，BR-79.2）。
        _pairMarkers(
            out, offset, ls, le, 2, SyntaxMarkerKind.highlight, nextPair);
      } else if (m.group(7) != null || m.group(8) != null) {
        _pairMarkers(
            out, offset, ls, le, 1, SyntaxMarkerKind.emphasis, nextPair);
        if (le - ls > 2) {
          _scanInlineRange(masked, ls + 1, le - 1, offset, out, nextPair);
        }
      }
    }
  }

  /// 成对记号的**开 / 闭两侧**各生成一个记号（同 `pairId`）。
  static void _pairMarkers(
    List<SyntaxMarker> out,
    int offset,
    int ls,
    int le,
    int len,
    SyntaxMarkerKind kind,
    int Function() nextPair,
  ) {
    final id = nextPair();
    out.add(SyntaxMarker(offset + ls, offset + ls + len, kind, pairId: id));
    out.add(SyntaxMarker(offset + le - len, offset + le, kind, pairId: id));
  }

  // ---------------------------------------------------------------------------
  // 围栏代码块（FR-81 / BR-81.2~81.5）
  // ---------------------------------------------------------------------------

  /// 全部围栏代码块（按出现顺序，FR-81）。
  ///
  /// 扫描规则与 [syntaxMarkers] 的围栏状态机**同源**：`_fencePrefixRe`（``` / ~~~，可带信息串）
  /// **成对翻转**；良构表格块内的行不参与翻转（与记号扫描一致）；未闭合则吃到文末。
  static List<FenceBlock> fenceBlocks(String text) {
    final out = <FenceBlock>[];
    final n = text.length;
    if (n == 0) return out;
    final tables = _wellFormedTableRanges(text);
    var lineStart = 0;
    var inFence = false;
    var openStart = 0;
    var openLineEnd = 0;
    var contentStart = 0;
    while (lineStart <= n) {
      final nl = text.indexOf('\n', lineStart);
      final lineEnd = nl == -1 ? n : nl;
      final line = _stripCr(text.substring(lineStart, lineEnd));
      final inTable = tables.any((r) => lineStart >= r.$1 && lineStart <= r.$2);
      final isFenceLine = _fencePrefixRe.hasMatch(line);
      if (inFence) {
        if (!inTable && isFenceLine) {
          out.add(FenceBlock(
            start: openStart,
            openLineEnd: openLineEnd,
            contentStart: contentStart,
            contentEnd: lineStart,
            closeLineStart: lineStart,
            closeLineEnd: lineEnd,
            closed: true,
            end: lineEnd,
          ));
          inFence = false;
        }
      } else if (!inTable && isFenceLine) {
        inFence = true;
        openStart = lineStart;
        openLineEnd = lineEnd;
        contentStart = lineEnd < n ? lineEnd + 1 : n;
      }
      if (lineEnd >= n) break;
      lineStart = lineEnd + 1;
    }
    // 未闭合：吃到文末（`closeLineStart/End == text.length`，`end == text.length`）。
    if (inFence) {
      out.add(FenceBlock(
        start: openStart,
        openLineEnd: openLineEnd,
        contentStart: contentStart,
        contentEnd: n,
        closeLineStart: n,
        closeLineEnd: n,
        closed: false,
        end: n,
      ));
    }
    return out;
  }

  /// [offset] 落在哪个围栏块内（**含围栏行、内容与块末那一格**），否则 null。
  static FenceBlock? fenceBlockAt(String text, int offset) {
    final pos = offset.clamp(0, text.length);
    for (final b in fenceBlocks(text)) {
      if (pos >= b.start && pos <= b.end) return b;
    }
    return null;
  }

  /// 结构删除是否命中某个围栏块（FR-81 / BR-81.2 / BR-81.4）——命中即**整块删除**，
  /// 不再走「取消代码块、保留内容」的旧语义。
  ///
  /// 判据（`target = backspace ? pos - 1 : pos`）：
  /// 1. `target ∈ [start, openLineEnd]` → 命中（Backspace 落在第一内容行行首时，target 是
  ///    开围栏行的换行）；
  /// 2. `closed && target ∈ [closeLineStart - 1, closeLineEnd]` → 命中（Delete 落在**末内容行
  ///    行尾**时 target 就是「闭合围栏行前那个换行」，删掉它会吃掉闭合围栏、块永不闭合
  ///    ——实测 R9-6；`-1` 正好落在该换行上，**不会**误伤块内中间代码行）；
  /// 3. `pos ∈ [start, openLineEnd + 1]` → 命中（光标停在开围栏行上，含行尾之后那一格）；
  /// 4. `closed && pos ∈ [closeLineStart - 1, closeLineEnd + 1]` → 命中（光标停在闭合围栏行上
  ///    / 末内容行行尾 / 块下方那一行的行首）。
  ///
  /// 3 / 4 覆盖「光标停在围栏行行首 / 行尾」这类**未落在任何字符内**的位置——它们是一键打坏
  /// 块结构的两条真实路径（实测 R9-3 / R9-6）。块内**中间**代码行不受影响（BR-81.3）。
  static FenceBlock? fenceBlockForDeletion(
    String text,
    int pos, {
    required bool backspace,
  }) {
    final p = pos.clamp(0, text.length);
    final target = backspace ? p - 1 : p;
    for (final b in fenceBlocks(text)) {
      if (target >= b.start && target <= b.openLineEnd) return b;
      if (b.closed &&
          target >= b.closeLineStart - 1 &&
          target <= b.closeLineEnd) {
        return b;
      }
      if (p >= b.start && p <= b.openLineEnd + 1) return b;
      if (b.closed &&
          p >= b.closeLineStart - 1 &&
          p <= b.closeLineEnd + 1) {
        return b;
      }
    }
    return null;
  }

  /// 整块移除围栏代码块（FR-81 / BR-81.4）：删除 `[start, end)` 及**一个相邻换行**
  /// （块后有换行则连同删、块在文末则删前导换行），并避免残留 ≥3 个连续换行；
  /// 围栏行与代码内容一并移除，**单次可撤销**。
  static FormatResult deleteFenceBlock(String text, FenceBlock block) {
    var start = block.start.clamp(0, text.length);
    var end = block.end.clamp(0, text.length);
    if (end < text.length && text[end] == '\n') {
      end++;
      // 块上下本就各有一个空行（`甲\n\n```…```\n\n乙`）时，删掉块与其行尾换行会连成三个换行，
      // 再吃掉一个，避免留下多余空行。
      if (end < text.length &&
          text[end] == '\n' &&
          start > 0 &&
          text[start - 1] == '\n') {
        end++;
      }
    } else if (start > 0 && text[start - 1] == '\n') {
      start--;
    }
    return FormatResult(
      text.substring(0, start) + text.substring(end),
      start,
      start,
    );
  }

  /// 格式模式的**结构删除**统一入口（§13.2 / §13.4 / BR-23.8 / BR-44.11）。
  ///
  /// 返回 `null` 表示「无结构语义」，调用方交默认**逐字符删除**。返回非 `null` 时：
  /// - `result.text != text` → 按结果写回正本（**一次**可撤销编辑）；
  /// - `result.text == text` → **吞掉该按键**（表格边界保护：正本与光标均不变）。
  ///
  /// 优先级：残缺附件引用自愈 → 附件引用整块删除 → 围栏块整块删除 → **网页原件整块删除**
  /// → **记号原子删除** → 表格整块删除（BR-44.6）→ **表格边界保护**（BR-44.11）。
  static FormatResult? structuralDelete(
    String text,
    int selectionStart,
    int selectionEnd, {
    required bool backspace,
  }) {
    final a = selectionStart.clamp(0, text.length);
    final b = selectionEnd.clamp(0, text.length);
    final lo = a <= b ? a : b;
    final hi = a <= b ? b : a;

    // 1) 附件引用：残缺自愈 → 整块删除（§12.4 既有口径）
    if (lo == hi) {
      final at = attachmentRefAt(text, lo);
      if (at != null && at.corrupt) return repairAttachmentRef(text, at);
      final ref = attachmentRefForDeletion(text, lo, backspace: backspace);
      if (ref != null) return deleteAttachmentRef(text, ref);
    }

    // 1.5) 围栏代码块：边界不可破（FR-81 / BR-81.2 / BR-81.4）——命中即**整块删除**
    // （取代「落到围栏行 = 取消代码块、保留内容」的旧语义）。
    if (lo == hi) {
      final fence = fenceBlockForDeletion(text, lo, backspace: backspace);
      if (fence != null) return deleteFenceBlock(text, fence);
      // 网页原件是整行原子单元（FR-83）：命中引用即整行删除，绝不逐字符咬坏。
      final webClip =
          webClipRefForDeletion(text, lo, backspace: backspace);
      if (webClip != null) return deleteWebClip(text, webClip);
    }

    final markers = syntaxMarkers(text);
    final pairs = <int, List<SyntaxMarker>>{};
    for (final m in markers) {
      if (m.pairId == null) continue;
      pairs.putIfAbsent(m.pairId!, () => <SyntaxMarker>[]).add(m);
    }

    // 2) 选区删除：记号 / 单元不得被切半（BR-23.8③）
    if (lo != hi) {
      final removals = <(int, int)>[(lo, hi)];
      var touched = false;
      for (final m in markers) {
        final intersects = m.start < hi && m.end > lo;
        final empties = m.pairId != null && _selectionEmptiesPair(m, pairs, lo, hi);
        if (!intersects && !empties) continue;
        touched = true;
        removals.add((m.start, m.end));
        for (final o in pairs[m.pairId] ?? const <SyntaxMarker>[]) {
          removals.add((o.start, o.end));
        }
      }
      for (final ref in attachmentRefs(text)) {
        if (ref.start < hi && ref.end > lo) {
          touched = true;
          removals.add((ref.start, ref.end));
        }
      }
      for (final r in _wellFormedTableRanges(text)) {
        if (r.$1 < hi && r.$2 > lo) {
          touched = true;
          removals.add((r.$1, r.$2 < text.length ? r.$2 + 1 : r.$2));
        }
      }
      // 快照 HTML 块同样不得被切半（FR-69 / BR-69.3）。
      for (final b in htmlBlocks(text)) {
        if (b.start < hi && b.end > lo) {
          touched = true;
          removals.add((b.start, b.end < text.length ? b.end + 1 : b.end));
        }
      }
      // 围栏代码块：**边界区**（围栏行 + 块边界换行）不得被切半（FR-81 / BR-81.2 / BR-81.4）
      // ——选区与 `[start, contentStart) ∪ [contentEnd, end + 1)` 相交时**整块删除**；
      // 选区完全落在**内容区**时走普通删除（代码内容必须可改，BR-81.3）。
      for (final fb in fenceBlocks(text)) {
        final hitsBoundary = (fb.start < hi && fb.contentStart > lo) ||
            (fb.contentEnd < hi && fb.end + 1 > lo);
        if (!hitsBoundary) continue;
        touched = true;
        removals.add((fb.start, fb.end < text.length ? fb.end + 1 : fb.end));
      }
      if (!touched) return null;
      return _removeRanges(text, removals, lo);
    }

    // 3) 折叠光标：记号原子删除
    final pos = lo;
    final hit = _markerForDeletion(text, markers, pairs, pos,
        backspace: backspace);
    if (hit != null) {
      final removals = _markerRemovals(text, hit, pairs);
      // 成对记号**仅剩最后一个内容字符**时命中的是内容字符本身 → 连它一并移除（不留空对）
      final target = backspace ? pos - 1 : pos;
      if (target >= 0 &&
          target < text.length &&
          _isPairLastContentChar(hit, pairs, target)) {
        removals.add((target, target + 1));
      }
      return _removeRanges(text, removals, pos);
    }

    // 3.5) 快照 HTML 块整块删除（FR-69 / BR-69.3）：与表格同为**原子块**，
    // 绝不让退格逐字符咬坏标签（那会让块不再成立、在编辑器里露出原始 HTML）。
    final block = htmlBlockForDeletion(text, pos, backspace: backspace);
    if (block != null) return deleteHtmlBlock(text, block);

    // 4) 表格整块删除（BR-44.6，口径不变）
    final table = tableForDeletion(text, pos, backspace: backspace);
    if (table != null) return deleteTable(text, table);

    // 5) 表格边界保护（BR-44.11）：绝不把表格行与相邻行文字合并
    final guard = _tableBoundaryGuard(text, pos, backspace: backspace);
    if (guard != null) return guard;

    return null;
  }

  /// 光标处是否命中**快照 HTML 块**（FR-69 / BR-69.3）。
  ///
  /// 命中口径与表格一致：退格命中 `start < pos <= end(+1)`（含块下方默认空行的行首）、
  /// `Delete` 命中 `start <= pos < end`。
  static HtmlBlock? htmlBlockForDeletion(
    String text,
    int pos, {
    required bool backspace,
  }) {
    for (final b in htmlBlocks(text)) {
      final after = b.end < text.length ? b.end + 1 : b.end;
      if (backspace) {
        if (b.start < pos && pos <= after) return b;
      } else if (b.start <= pos && pos < b.end) {
        return b;
      }
    }
    return null;
  }

  /// 整块删除快照 HTML 块：连同块尾换行一并移除（不残留空行），**单次可撤销**。
  static FormatResult deleteHtmlBlock(String text, HtmlBlock block) {
    var start = block.start;
    var end = block.end;
    if (end < text.length && text[end] == '\n') {
      end++;
      // 块的前后本来就各有一个空行（独占块形态）：删掉块与其行尾换行后，上下空行会连成
      // 两个空行（`\n\n\n`）——再吃掉一个换行，避免留下多余空行。
      if (end < text.length &&
          text[end] == '\n' &&
          start > 0 &&
          text[start - 1] == '\n') {
        end++;
      }
    } else if (start > 0 && text[start - 1] == '\n') {
      start--;
    }
    return FormatResult(
      text.substring(0, start) + text.substring(end),
      start,
      start,
    );
  }

  /// [target] 是否为某成对记号**仅剩的最后一个内容字符**（此时整对连内容一并移除）。
  static bool _isPairLastContentChar(
    SyntaxMarker hit,
    Map<int, List<SyntaxMarker>> pairs,
    int target,
  ) {
    final group = pairs[hit.pairId];
    if (group == null || group.length < 2) return false;
    final sorted = [...group]..sort((a, b) => a.start.compareTo(b.start));
    final open = sorted.first;
    final close = sorted.last;
    return open.end == target && close.start == target + 1;
  }

  /// 选区是否**恰好覆盖某成对记号的全部内容**（此时若只删内容会留下 `****` 一类空对，须连记号一并去掉）。
  static bool _selectionEmptiesPair(
    SyntaxMarker m,
    Map<int, List<SyntaxMarker>> pairs,
    int lo,
    int hi,
  ) {
    final group = pairs[m.pairId];
    if (group == null || group.length < 2) return false;
    final sorted = [...group]..sort((a, b) => a.start.compareTo(b.start));
    final open = sorted.first;
    final close = sorted.last;
    if (open.end > close.start) return false;
    return lo <= open.end && hi >= close.start;
  }

  /// 折叠光标下**命中记号**的判定（§13.2 / BR-23.8）。
  static SyntaxMarker? _markerForDeletion(
    String text,
    List<SyntaxMarker> markers,
    Map<int, List<SyntaxMarker>> pairs,
    int pos, {
    required bool backspace,
  }) {
    // ① 目标字符落在记号区间内（Backspace 删光标前一字符、Delete 删光标处字符）
    final target = backspace ? pos - 1 : pos;
    if (target >= 0 && target < text.length) {
      for (final m in markers) {
        if (target >= m.start && target < m.end) return m;
      }
      // ② 目标字符是某成对记号**仅剩的最后一个内容字符** → 连整对一并移除（不留空对）
      for (final m in markers) {
        if (m.pairId == null) continue;
        final group = pairs[m.pairId];
        if (group == null || group.length < 2) continue;
        final sorted = [...group]..sort((a, b) => a.start.compareTo(b.start));
        final open = sorted.first;
        final close = sorted.last;
        if (open.end == target && close.start == target + 1) return open;
      }
    }
    // ③ 空前缀行：行首退格 / 行尾删除同样整块移除前缀（BR-23.8②，等价「退出列表」）
    for (final m in markers) {
      if (!_isPrefixKind(m.kind)) continue;
      if (m.end != _lineEndAt(text, m.lineStart ?? m.start)) continue;
      if (backspace ? pos == m.start : pos == m.end) return m;
    }
    // ④ 分割线**无需**额外边界分支：规则记号区间已含 `---` 行自身的行尾换行，故两个「贴边」
    //    位置都已被 ① 覆盖——
    //      * Backspace 落「分割线下方那一行的行首」→ target = m.end - 1 ∈ [start, end)；
    //      * Delete 落「`---` 行行尾」→ target = m.end - 1 ∈ [start, end)。
    //    （`v0.14.3` 补正：旧分支 `boundary = backspace ? m.end + 1 : m.end` 与「记号区间止于
    //    换行之前」的旧假设配套；区间语义变更后它只会误吞「下方空行的换行」，故删除。）
    return null;
  }

  /// 命中记号后应移除的区间集合（成对记号同生共死；围栏 / 分割线**连行**移除）。
  static List<(int, int)> _markerRemovals(
    String text,
    SyntaxMarker hit,
    Map<int, List<SyntaxMarker>> pairs,
  ) {
    final removals = <(int, int)>[
      if (hit.kind == SyntaxMarkerKind.rule)
        () {
          // rule 的记号区间 = **上方空行的行尾换行** + `---` 行 + **该行自身的行尾换行**。
          // 「连行移除」= 只删 `---` 这一行（含它自己的行尾换行），**保留上方空行**——它是两段
          // 之间的分隔空行，删了会把两段并成一段。旧实现按「区间止于换行之前」的假设向后再扫
          // 2 个字符，会把下一行开头的两个字一起吞掉（`v0.14.3` 补正修掉）。
          // 若记号右侧紧邻的又是一个换行（标准形 `---` 下方的空行），一并吸收，避免留下
          // ≥3 个连续换行（BR-72.3 / AC-318）。
          var end = hit.end;
          if (end < text.length && text[end] == '\n') end++;
          return (hit.lineStart ?? hit.start, end);
        }()
      else
        (hit.start, hit.end),
    ];
    final group = pairs[hit.pairId] ?? const <SyntaxMarker>[];
    for (final o in group) {
      removals.add((o.start, o.end));
    }
    if (hit.kind == SyntaxMarkerKind.fence) {
      final lineStarts = <int>{hit.lineStart ?? hit.start};
      for (final o in group) {
        lineStarts.add(o.lineStart ?? o.start);
      }
      for (final lineStart in lineStarts) {
        var s = lineStart.clamp(0, text.length);
        var e = _lineEndAt(text, s);
        if (e < text.length && text[e] == '\n') {
          e++;
        } else if (s > 0 && text[s - 1] == '\n') {
          s--;
        }
        removals.add((s, e));
      }
    }
    return removals;
  }

  /// 按给定区间集合移除字符（区间自动合并），并把 [caretHint] 映射到新文本中的等义位置。
  static FormatResult _removeRanges(
    String text,
    List<(int, int)> ranges,
    int caretHint,
  ) {
    final normalized = <(int, int)>[];
    for (final r in ranges) {
      final s = r.$1.clamp(0, text.length);
      final e = r.$2.clamp(0, text.length);
      if (e > s) normalized.add((s, e));
    }
    normalized.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final r in normalized) {
      if (merged.isNotEmpty && r.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, r.$2 > last.$2 ? r.$2 : last.$2));
      } else {
        merged.add(r);
      }
    }
    final buf = StringBuffer();
    var cursor = 0;
    var removedBefore = 0;
    for (final r in merged) {
      buf.write(text.substring(cursor, r.$1));
      if (caretHint > r.$2) {
        removedBefore += r.$2 - r.$1;
      } else if (caretHint > r.$1) {
        removedBefore += caretHint - r.$1;
      }
      cursor = r.$2;
    }
    buf.write(text.substring(cursor));
    final newText = buf.toString();
    final caret = (caretHint - removedBefore).clamp(0, newText.length);
    return FormatResult(newText, caret, caret);
  }

  /// **表格边界保护**（§13.4 / BR-44.11）：绝不把表格行与相邻行文字**合并**。
  ///
  /// 返回 `null` 表示允许默认逐字符删除（相邻行是**空行**：合并后表格行字节不变、仍合法）；
  /// 否则返回应执行的结果——命中相邻行的**块级记号** → 取消该行记号；其余 → **吞掉按键**
  /// （`text` 不变、光标不动）。表格因此**只会整体保留或整体删除**，绝不退化为原始文本。
  static FormatResult? _tableBoundaryGuard(
    String text,
    int pos, {
    required bool backspace,
  }) {
    for (final r in _wellFormedTableRanges(text)) {
      final start = r.$1;
      final end = r.$2;
      // 表格**首行前**的换行：Backspace 停在表格首字符处 / Delete 停在上一行行尾
      if (start > 0 &&
          ((backspace && pos == start) || (!backspace && pos == start - 1))) {
        final prevNl = start >= 2 ? text.lastIndexOf('\n', start - 2) : -1;
        final lineAbove = prevNl == -1 ? 0 : prevNl + 1;
        return _boundaryProtect(text, pos, lineAbove);
      }
      // 表格**末行后**的换行：Delete 停在表格末字符处
      if (end < text.length && !backspace && pos == end) {
        return _boundaryProtect(text, pos, end + 1);
      }
    }
    return null;
  }

  /// 边界保护动作（[lineStart] 为紧贴表格的那一行）。
  static FormatResult? _boundaryProtect(String text, int pos, int lineStart) {
    final line = _lineText(text, lineStart);
    if (line.trim().isEmpty) return null; // 空行：合并无损，允许默认删除
    for (final m in syntaxMarkers(text)) {
      if (m.lineStart != lineStart) continue;
      if (!_isPrefixKind(m.kind)) continue;
      if (m.end != _lineEndAt(text, lineStart)) continue; // 前缀后还有内容
      return _removeRanges(text, <(int, int)>[(m.start, m.end)], pos);
    }
    return FormatResult(text, pos, pos); // 吞掉按键：表格与文字均保持不变
  }
}

/// 一个**围栏代码块**（FR-81 / BR-81.2\~81.5）。
///
/// 口径：围栏块「**内容可编辑、边界不可破**」——块内代码行仍可逐字符编辑（与表格原子块的关键
/// 差别），但两条围栏行与块边界换行**不得**被逐字符破坏（一个按键即可让块不再成立）。
class FenceBlock {
  const FenceBlock({
    required this.start,
    required this.openLineEnd,
    required this.contentStart,
    required this.contentEnd,
    required this.closeLineStart,
    required this.closeLineEnd,
    required this.closed,
    required this.end,
  });

  /// 开围栏行的行首（含）。
  final int start;

  /// 开围栏行的行尾（不含换行）。
  final int openLineEnd;

  /// 首个内容行行首（未闭合且内容为空时为 [closeLineStart] / `text.length`）。
  final int contentStart;

  /// 闭合围栏行行首（未闭合时为 `text.length`）。
  final int contentEnd;

  /// 闭合围栏行行首（未闭合时 == `text.length`）。
  final int closeLineStart;

  /// 闭合围栏行行尾（不含换行；未闭合时 == `text.length`）。
  final int closeLineEnd;

  /// 是否已闭合。
  final bool closed;

  /// 块末（**不含**闭合围栏行的行尾换行）：`closed ? closeLineEnd : text.length`。
  final int end;

  @override
  String toString() => 'FenceBlock($start..$end, closed=$closed)';
}

/// 一处**笔记内查找**命中（FR-73 / BR-73.1）：`[start, end)` 为**正本**下标。
class FindMatch {
  const FindMatch(this.start, this.end);

  /// 命中起点（含）。
  final int start;

  /// 命中终点（不含）。
  final int end;

  /// 命中长度（码元数）。
  int get length => end - start;

  @override
  String toString() => 'FindMatch($start..$end)';
}

/// 记号种类：格式模式下**不可见**（或被替换为呈现单元）的语法字符（§13.2 / BR-23.7）。
enum SyntaxMarkerKind {
  /// 标题前缀 `#` … `######`（含其后空白）。
  heading,

  /// 无序列表前缀 `- `（呈现为项目符号）。
  bullet,

  /// 有序列表前缀 `1. `（呈现为连续编号）。
  ordered,

  /// 任务项前缀 `- [ ] ` / `- [x] `（呈现为勾选框）。
  task,

  /// 引用前缀 `> `（呈现为引用竖条）。
  quote,

  /// 围栏代码块行（不可见；删除时**连行**移除）。
  fence,

  /// 分割线行（呈现为水平线；删除时**连行**移除）。
  rule,

  /// setext 标题下划线行（`标题` 的下一行 `===` / `---`）：不可见，且上一行按 h2 呈现。
  setext,

  /// 行内成对记号：加粗 `**` / `__`。
  strong,

  /// 行内成对记号：斜体 `*` / `_`。
  emphasis,

  /// 行内成对记号：删除线 `~~`。
  strike,

  /// 行内成对记号：高亮 `==`。
  highlight,

  /// 行内成对记号：行内代码 `` ` ``。
  code,

  /// 链接语法部分（`[` 与 `](url)`）。
  link,

  /// 转义序列 `\x`（FR-78 / BR-78.4）：反斜杠不可见、被转义字符按**普通文本**显示；
  /// 区间覆盖 `\` 与 `x` **两个码元**（保证结构删除整体生效）。
  escape,
}

/// 一个「记号」在正本中的字符区间（§13.2）。
class SyntaxMarker {
  const SyntaxMarker(
    this.start,
    this.end,
    this.kind, {
    this.lineStart,
    this.pairId,
    this.checked = false,
    this.displayNumber,
  });

  /// 区间起点（含）。
  final int start;

  /// 区间终点（不含）。
  final int end;

  final SyntaxMarkerKind kind;

  /// 所在行行首偏移（行级前缀 / 围栏 / 分割线有值）。
  final int? lineStart;

  /// 成对记号 / 配对围栏的配对标识：同 id 者**同生共死**（一次删除即取消整处格式）。
  final int? pairId;

  /// 仅任务项记号有意义：是否已勾选。
  final bool checked;

  /// 仅有序列表记号有意义：该行应呈现的**显示编号**（FR-48 惰性编号）。
  final int? displayNumber;

  @override
  String toString() => 'SyntaxMarker($kind, $start..$end, pair=$pairId)';
}
