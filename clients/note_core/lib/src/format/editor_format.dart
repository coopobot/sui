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
        return _inline(text, selectionStart, selectionEnd, '==');
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

  static FormatResult _inline(
    String text,
    int start,
    int end,
    String marker,
  ) {
    final s = start.clamp(0, text.length);
    final e = end.clamp(0, text.length);

    // 无选区：插入一对标记并把光标置于其中。
    if (s == e) {
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
    var n = 0;
    return _mapLines(text, start, end, (line, _) {
      if (RegExp(r'^\d+\.\s+').hasMatch(line)) {
        return line.replaceFirst(RegExp(r'^\d+\.\s+'), '');
      }
      n++;
      return '$n. $line';
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
    if (e < lineEnd) return null;

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

    return null;
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
    final newText = text.substring(0, s) + md + text.substring(e);
    final pos = s + md.length;
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
}
