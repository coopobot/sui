import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

/// 格式模式下的正文控制器：正本仍是 Markdown 字符串，但 [buildTextSpan] 会把
/// 块级 / 行内标记渲染为可读的富样式（标题放大、加粗加重、标记符号淡化）。
///
/// 这样做守住了**单一正本**（ADR-006 / BR-23.1）：`text` 自始至终是标准
/// Markdown，光标 / 选区 / 撤销栈都以正本偏移为准；[styled] 只影响「怎么画」，
/// 不影响「存什么」。切到源码模式时把 [styled] 置回 false 即恢复纯文本呈现。
/// 格式模式下，把一段图片引用渲染为可交互「呈现单元」的构建器。
///
/// 由 UI 层注入：控制器本身不依赖附件缓存，只负责在 [buildTextSpan] 里把
/// `![alt](sui://<sha256>){尺寸}` 这一段从纯文本样式片段替换为图片 widget
/// （BR-27.1）。未注入时图片引用退化为普通样式文本，不影响正本与偏移。
typedef FormatImageSpanBuilder = Widget Function(
  BuildContext context,
  ParsedImage image,
);

class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  /// 是否以富样式呈现（true=格式模式，false=源码模式）。
  ///
  /// 刻意做成**普通字段而非通知型状态**：该值由 [MarkdownEditor] 在每次构建时
  /// 依据当前模式写入，随同 TextField 一起重建；无需（也不应在）build 期间触发
  /// notifyListeners，否则会引发「build 期间 setState」断言。
  bool styled = false;

  /// 格式模式下的图片呈现单元构建器；由 UI 层注入（见 [FormatImageSpanBuilder]）。
  FormatImageSpanBuilder? formatImageBuilder;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!styled) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    final composing = withComposing ? value.composing : TextRange.empty;
    return TextSpan(
      style: base,
      children: _buildSpans(context, text, base, composing),
    );
  }

  /// 生成格式模式的样式片段：图片引用替换为 [WidgetSpan]，其余按逐字符样式合并。
  ///
  /// 偏移契约：整棵 span 树的 `toPlainText()` 必须与 [text] 等长，否则 TextField
  /// 的光标定位 / 命中测试会错位。`WidgetSpan` 在文本模型中固定占用 1 个码元，
  /// 故其引用余下的字符用「零宽透明」文本补足，保证等长（BR-27.1）。
  List<InlineSpan> _buildSpans(
    BuildContext context,
    String text,
    TextStyle base,
    TextRange composing,
  ) {
    if (text.isEmpty) return const <InlineSpan>[];
    final styles = _MarkdownStyler.characterStyles(
      context,
      text,
      base,
      composing,
    );
    final builder = formatImageBuilder;
    if (builder == null) {
      return _MarkdownStyler.coalesce(text, styles, 0, text.length);
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    while (true) {
      final image = EditorFormat.findImage(text, cursor);
      if (image == null) break;
      final spanEnd = image.attributeEnd > 0 ? image.attributeEnd : image.end;
      if (image.start > cursor) {
        spans.addAll(
          _MarkdownStyler.coalesce(text, styles, cursor, image.start),
        );
      }
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.top,
        child: builder(context, image),
      ));
      // 引用首字符由 WidgetSpan 的 1 个码元占位，其余用零宽透明文本补齐。
      if (spanEnd - image.start - 1 > 0) {
        spans.add(TextSpan(
          text: text.substring(image.start + 1, spanEnd),
          style: base.copyWith(color: Colors.transparent, fontSize: 0),
        ));
      }
      cursor = spanEnd;
    }
    if (cursor < text.length) {
      spans.addAll(_MarkdownStyler.coalesce(text, styles, cursor, text.length));
    }
    return spans;
  }
}

/// 把 Markdown 正文解析为「覆盖全部字符」的样式片段。
///
/// 契约：产出的样式必须**逐字符覆盖** `0..text.length`，不允许出现空洞——
/// 否则 TextField 的光标定位与命中测试会错位。实现上先为每个字符算出最终样式，
/// 再把样式相同的相邻字符合并成一个 span。
class _MarkdownStyler {
  _MarkdownStyler._();

  static final RegExp _fenceLine = RegExp(r'^[ \t]*(```|~~~)');
  static final RegExp _headingLine = RegExp(r'^(#{1,6})([ \t]+)(.*)$');
  static final RegExp _quoteLine = RegExp(r'^([ \t]*>[ \t]?)(.*)$');
  static final RegExp _bulletLine = RegExp(r'^([ \t]*[-*+][ \t]+)(.*)$');
  static final RegExp _orderedLine = RegExp(r'^([ \t]*\d+\.[ \t]+)(.*)$');
  static final RegExp _ruleLine = RegExp(r'^[ \t]*(-{3,}|\*{3,}|_{3,})[ \t]*$');

  static final RegExp _inline = RegExp(
    r'(`[^`\n]+`)' // 1 行内代码
    r'|(!\[[^\]\n]*\]\([^)\n]*\))' // 2 图片
    r'|(\[[^\]\n]*\]\([^)\n]*\))' // 3 链接
    r'|(\*\*[^*\n]+\*\*)' // 4 加粗 **
    r'|(__[^_\n]+__)' // 5 加粗 __
    r'|(~~[^~\n]+~~)' // 6 删除线
    r'|(\*[^*\n]+\*)' // 7 斜体 *
    r'|(_[^_\n]+_)', // 8 斜体 _
  );

  static const List<double> _headingScale = [1.75, 1.5, 1.28, 1.14, 1.06, 1.0];

  static List<TextStyle> characterStyles(
    BuildContext context,
    String text,
    TextStyle base,
    TextRange composing,
  ) {
    if (text.isEmpty) return const <TextStyle>[];
    final scheme = Theme.of(context).colorScheme;

    final marker = base.copyWith(color: scheme.outline.withValues(alpha: 0.5));
    final accent = base.copyWith(color: scheme.primary);
    final code = base.copyWith(
      fontFamily: 'monospace',
      color: scheme.primary,
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
    );
    final quote = base.copyWith(
      color: scheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );

    final n = text.length;
    final styles = List<TextStyle>.filled(n, base);

    // 逐行扫描；围栏代码块内不做块级 / 行内解析。
    var lineStart = 0;
    var inFence = false;
    while (lineStart <= n) {
      var lineEnd = text.indexOf('\n', lineStart);
      if (lineEnd == -1) lineEnd = n;
      final line = text.substring(lineStart, lineEnd);

      if (_fenceLine.hasMatch(line)) {
        _fill(styles, lineStart, lineEnd, marker);
        inFence = !inFence;
      } else if (inFence) {
        _fill(styles, lineStart, lineEnd, code);
      } else {
        _block(styles, lineStart, lineEnd, line, base, marker, accent, quote);
        _inlineSpans(styles, lineStart, line, marker, accent, code, base);
      }

      if (lineEnd >= n) break;
      lineStart = lineEnd + 1;
    }

    // IME 组合区（拼音等）下划线。
    if (composing.isValid && !composing.isCollapsed) {
      final s = composing.start.clamp(0, n);
      final e = composing.end.clamp(0, n);
      final underline = base.copyWith(decoration: TextDecoration.underline);
      for (var i = s; i < e; i++) {
        styles[i] = styles[i].merge(underline);
      }
    }

    return styles;
  }

  // ---------------------------------------------------------------------------
  // 块级
  // ---------------------------------------------------------------------------

  static void _block(
    List<TextStyle> styles,
    int start,
    int end,
    String line,
    TextStyle base,
    TextStyle marker,
    TextStyle accent,
    TextStyle quote,
  ) {
    final heading = _headingLine.firstMatch(line);
    if (heading != null) {
      final level = heading.group(1)!.length;
      final scale = _headingScale[(level - 1).clamp(0, _headingScale.length - 1)];
      final style = base.copyWith(
        fontSize: (base.fontSize ?? 15) * scale,
        fontWeight: FontWeight.w700,
        height: 1.3,
      );
      _fill(styles, start, end, style);
      final prefixEnd =
          start + heading.group(1)!.length + heading.group(2)!.length;
      _fill(styles, start, prefixEnd, style.copyWith(color: marker.color));
      return;
    }

    if (_ruleLine.hasMatch(line)) {
      _fill(styles, start, end, marker);
      return;
    }

    final q = _quoteLine.firstMatch(line);
    if (q != null) {
      _fill(styles, start, end, quote);
      _fill(styles, start, start + q.group(1)!.length, marker);
      return;
    }

    final b = _bulletLine.firstMatch(line);
    if (b != null) {
      _fill(styles, start, start + b.group(1)!.length, accent);
      return;
    }

    final o = _orderedLine.firstMatch(line);
    if (o != null) {
      _fill(styles, start, start + o.group(1)!.length, accent);
    }
  }

  // ---------------------------------------------------------------------------
  // 行内
  // ---------------------------------------------------------------------------

  static void _inlineSpans(
    List<TextStyle> styles,
    int offset,
    String line,
    TextStyle marker,
    TextStyle accent,
    TextStyle code,
    TextStyle base,
  ) {
    for (final m in _inline.allMatches(line)) {
      final ls = m.start;
      final le = m.end;
      if (m.group(1) != null) {
        // 行内代码：标记淡化，内容等宽高亮。
        _merge(styles, offset + ls, offset + ls + 1, marker);
        _merge(styles, offset + ls + 1, offset + le - 1, code);
        _merge(styles, offset + le - 1, offset + le, marker);
      } else if (m.group(2) != null) {
        _styleReference(styles, offset, line, ls, le, 2, marker, accent);
      } else if (m.group(3) != null) {
        _styleReference(styles, offset, line, ls, le, 1, marker, accent);
      } else if (m.group(4) != null || m.group(5) != null) {
        final bold = base.copyWith(fontWeight: FontWeight.w700);
        _merge(styles, offset + ls, offset + ls + 2, marker);
        _merge(styles, offset + ls + 2, offset + le - 2, bold);
        _merge(styles, offset + le - 2, offset + le, marker);
      } else if (m.group(6) != null) {
        final strike = base.copyWith(decoration: TextDecoration.lineThrough);
        _merge(styles, offset + ls, offset + ls + 2, marker);
        _merge(styles, offset + ls + 2, offset + le - 2, strike);
        _merge(styles, offset + le - 2, offset + le, marker);
      } else if (m.group(7) != null || m.group(8) != null) {
        final italic = base.copyWith(fontStyle: FontStyle.italic);
        _merge(styles, offset + ls, offset + ls + 1, marker);
        _merge(styles, offset + ls + 1, offset + le - 1, italic);
        _merge(styles, offset + le - 1, offset + le, marker);
      }
    }
  }

  /// 渲染 `[label](url)` / `![alt](url)`；[lead] 为 `[` 前的字符数（链接 1、图片 2）。
  static void _styleReference(
    List<TextStyle> styles,
    int offset,
    String line,
    int ls,
    int le,
    int lead,
    TextStyle marker,
    TextStyle accent,
  ) {
    final rb = line.indexOf(']', ls);
    final lp = line.indexOf('(', rb);
    if (rb < 0 || lp < 0) return;
    final label = accent.copyWith(
      fontWeight: lead == 2 ? FontWeight.w600 : null,
      decoration: lead == 1 ? TextDecoration.underline : null,
    );
    _merge(styles, offset + ls, offset + ls + lead, marker); // '[' / '!['
    _merge(styles, offset + ls + lead, offset + rb, label); // label / alt
    _merge(styles, offset + rb, offset + lp + 1, marker); // ']('
    _merge(styles, offset + lp + 1, offset + le - 1, marker); // url
    _merge(styles, offset + le - 1, offset + le, marker); // ')'
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  static void _fill(List<TextStyle> styles, int start, int end, TextStyle style) {
    final s = start.clamp(0, styles.length);
    final e = end.clamp(0, styles.length);
    for (var i = s; i < e; i++) {
      styles[i] = style;
    }
  }

  static void _merge(
    List<TextStyle> styles,
    int start,
    int end,
    TextStyle style,
  ) {
    final s = start.clamp(0, styles.length);
    final e = end.clamp(0, styles.length);
    for (var i = s; i < e; i++) {
      styles[i] = styles[i].merge(style);
    }
  }

  /// 把 `[start, end)` 区间内样式相同的相邻字符合并为一个 [TextSpan]。
  static List<InlineSpan> coalesce(
    String text,
    List<TextStyle> styles,
    int start,
    int end,
  ) {
    final spans = <InlineSpan>[];
    final s = start.clamp(0, text.length);
    final e = end.clamp(0, text.length);
    var i = s;
    while (i < e) {
      final style = styles[i];
      var j = i + 1;
      while (j < e && styles[j] == style) {
        j++;
      }
      spans.add(TextSpan(text: text.substring(i, j), style: style));
      i = j;
    }
    return spans;
  }
}
