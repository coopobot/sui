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

    final selected = text.substring(s, e);

    // 选区自身已含标记 → 取消包裹。
    if (selected.length >= marker.length * 2 &&
        selected.startsWith(marker) &&
        selected.endsWith(marker)) {
      final inner =
          selected.substring(marker.length, selected.length - marker.length);
      return FormatResult(
        text.substring(0, s) + inner + text.substring(e),
        s,
        s + inner.length,
      );
    }

    final before = text.substring(0, s);
    final after = text.substring(e);

    // 标记紧贴选区外侧 → 取消包裹（幂等切换）。
    if (before.endsWith(marker) &&
        after.startsWith(marker) &&
        !_adjacentIsLongerMarker(before, after, marker)) {
      final newText = before.substring(0, before.length - marker.length) +
          selected +
          after.substring(marker.length);
      return FormatResult(newText, s - marker.length, e - marker.length);
    }

    final newText = before + marker + selected + marker + after;
    return FormatResult(newText, s + marker.length, e + marker.length);
  }

  /// `*` 的紧邻字符若属于 `**`（加粗），不视为斜体包裹，避免误删加粗星号。
  static bool _adjacentIsLongerMarker(
    String before,
    String after,
    String marker,
  ) {
    if (marker == '*') {
      if (before.endsWith('**') || after.startsWith('**')) return true;
    }
    return false;
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

  static FormatResult _divider(String text, int start, int end) {
    final (blockStart, blockEnd) = _blockRange(text, start, end);
    final block = text.substring(blockStart, blockEnd).trim();
    if (block == '---' || block == '***' || block == '___') {
      var end2 = blockEnd;
      if (end2 < text.length && text[end2] == '\n') end2++;
      final newText = text.substring(0, blockStart) + text.substring(end2);
      return FormatResult(newText, blockStart, blockStart);
    }
    final newText =
        '${text.substring(0, blockStart)}---\n${text.substring(blockStart)}';
    final pos = blockStart + 4;
    return FormatResult(newText, pos, pos);
  }

  static FormatResult _taskList(String text, int start, int end) {
    return _mapLines(text, start, end, (line, _) {
      final m = _taskLine.firstMatch(line);
      if (m != null) {
        final checked = m.group(2)!.toLowerCase() == 'x';
        return '${m.group(1)}[${checked ? ' ' : 'x'}]${m.group(3)}';
      }
      return line.isEmpty ? '- [ ]' : '- [ ] $line';
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

  static FormatResult _indent(String text, int start, int end) {
    return _mapLines(text, start, end, (line, _) {
      if (line.isEmpty) return line;
      return '  $line';
    });
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
    return FormatResult(newText, from, from + cleared.length);
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
    return FormatResult(newText, blockStart, blockStart + transformed.length);
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
    final s = start.clamp(0, text.length);
    final e = end.clamp(0, text.length);
    final attr = size == null ? '' : renderSizeAttribute(size);
    final md = '![$filename](sui://$sha256)$attr';

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

    final newText = '$before$leading$md$trailing$after';
    final pos = before.length + leading.length + md.length + trailing.length;
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
    for (final line in text.split('\n')) {
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
}
