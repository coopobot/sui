/// 快照 HTML 块的**受限渲染器**（FR-69 / ADR-028 决策 1 / §16.3）。
///
/// 输入是一段 HTML 文本（正本里的字面字符），内部经 note_core 的
/// [parseSnapshotHtml] **白名单化**后渲染；**预览态与格式模式共用本组件**（BR-69.3 两态同源）。
///
/// 安全边界（BR-69.6）：
/// * **不发起任何网络请求**——图片只认 `sui://<sha256>`（走 [suiImageBuilder] 提供的附件
///   组件）；外链图片显示占位（与项目既有外链图片口径一致，见 M10-T30）；
/// * 不执行脚本、不加载样式表、不解析 `javascript:` 一类协议为可点目标；
/// * 白名单已在 note_core 收口，本组件不做「猜标签」。
library;

import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

/// 快照 HTML 块里 `sui://<sha256>` 图片的构建器：参数依次为 sha256、替代文字、
/// 宽、高（宽 / 高可能为 `null`，表示按原始尺寸）。
typedef SnapshotHtmlImageBuilder = Widget Function(
  String sha256,
  String label,
  double? width,
  double? height,
);

/// 快照 HTML 块的渲染组件。
class SnapshotHtmlView extends StatelessWidget {
  const SnapshotHtmlView({
    super.key,
    required this.html,
    this.baseStyle,
    this.suiImageBuilder,
    this.onOpenLink,
  });

  /// 块的 HTML 原文（正本里的字面字符）。
  final String html;

  /// 基础文字样式（缺省取 `DefaultTextStyle`）。
  final TextStyle? baseStyle;

  /// `sui://<sha256>` 图片的呈现组件构建器（`null` 时显示占位）。
  final SnapshotHtmlImageBuilder? suiImageBuilder;

  /// 点开链接（`null` 表示当前场景不给点击，如格式模式下的整块呈现）。
  final void Function(String url)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final root = parseSnapshotHtml(html);
    final style = baseStyle ?? DefaultTextStyle.of(context).style;
    return _children(context, root.children, style, const <String, String>{});
  }

  // -------------------------------------------------------------------------
  // 块级
  // -------------------------------------------------------------------------

  /// 渲染一串子节点：**连续的行内节点合并为一个富文本**，块级元素各自成行。
  Widget _children(
    BuildContext context,
    List<SnapshotNode> nodes,
    TextStyle style,
    Map<String, String> inherited,
  ) {
    final widgets = <Widget>[];
    var run = <SnapshotNode>[];
    void flush() {
      if (run.isEmpty) return;
      widgets.add(_richText(context, run, style, inherited));
      run = <SnapshotNode>[];
    }

    for (final node in nodes) {
      final isBlock = node is SnapshotElement &&
          node.block &&
          node.tag != 'br' &&
          node.tag != 'img';
      if (isBlock) {
        flush();
        widgets.add(_block(context, node, style, inherited));
      } else {
        run.add(node);
      }
    }
    flush();

    if (widgets.isEmpty) return const SizedBox.shrink();
    if (widgets.length == 1) return widgets.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  Widget _block(
    BuildContext context,
    SnapshotElement element,
    TextStyle style,
    Map<String, String> inherited,
  ) {
    final styles = <String, String>{...inherited, ...element.effectiveStyles};
    // `align` 属性与 `<center>` 标签折算为 text-align（与服务端生成侧同一口径）。
    final align = (element.attributes['align'] ?? '').toLowerCase();
    if (align.isNotEmpty) styles.putIfAbsent('text-align', () => align);
    if (element.tag == 'center') {
      styles.putIfAbsent('text-align', () => 'center');
    }

    Widget child = _children(context, element.children, style, styles);
    final background = _colorOf(context, styles['background-color']);
    if (background != null) {
      child = Container(
        decoration: BoxDecoration(color: background),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: child,
      );
    }
    final textAlign = _textAlignOf(styles);
    if (textAlign != null) {
      child = Align(
        alignment: switch (textAlign) {
          TextAlign.center => Alignment.center,
          TextAlign.right => Alignment.centerRight,
          _ => Alignment.centerLeft,
        },
        child: child,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: child,
    );
  }

  // -------------------------------------------------------------------------
  // 行内
  // -------------------------------------------------------------------------

  Widget _richText(
    BuildContext context,
    List<SnapshotNode> nodes,
    TextStyle style,
    Map<String, String> styles,
  ) {
    return Text.rich(
      TextSpan(children: _spans(context, nodes, style, styles)),
      textAlign: _textAlignOf(styles),
    );
  }

  List<InlineSpan> _spans(
    BuildContext context,
    List<SnapshotNode> nodes,
    TextStyle style,
    Map<String, String> inherited,
  ) {
    final out = <InlineSpan>[];
    for (final node in nodes) {
      if (node is SnapshotText) {
        out.add(TextSpan(text: node.text, style: _textStyle(context, inherited, style)));
        continue;
      }
      final element = node as SnapshotElement;
      final styles = <String, String>{...inherited, ...element.effectiveStyles};
      final childStyle = _textStyle(context, styles, style);
      switch (element.tag) {
        case 'br':
          out.add(const TextSpan(text: '\n'));
        case 'img':
          out.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _image(context, element, styles),
          ));
        case 'a':
          out.add(_anchor(context, element, styles, childStyle));
        default:
          out.add(TextSpan(
            style: childStyle,
            children: _spans(context, element.children, style, styles),
          ));
      }
    }
    return out;
  }

  InlineSpan _anchor(
    BuildContext context,
    SnapshotElement element,
    Map<String, String> styles,
    TextStyle style,
  ) {
    final href = (element.attributes['href'] ?? '').trim();
    final linkStyle = style.copyWith(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: Theme.of(context).colorScheme.primary,
    );
    final open = onOpenLink;
    final label = _plainText(element);
    // 可点链接渲染为 **WidgetSpan**（真 widget 手势），不可点时只保留链接样式文本。
    if (open == null || href.isEmpty) {
      return TextSpan(
        style: linkStyle,
        children: _spans(context, element.children, style, styles),
      );
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => open(href),
          child: Text(label, style: linkStyle),
        ),
      ),
    );
  }

  /// 图片：只认 `sui://<sha256>`（本地附件）；其余一律占位，**不出网**（BR-69.6）。
  Widget _image(
    BuildContext context,
    SnapshotElement element,
    Map<String, String> styles,
  ) {
    final src = (element.attributes['src'] ?? '').trim();
    final label = (element.attributes['alt'] ?? '').trim();
    final width = _sizeOf(element, styles, 'width');
    final height = _sizeOf(element, styles, 'height');
    final uri = Uri.tryParse(src);
    final builder = suiImageBuilder;
    if (uri != null && uri.scheme == 'sui' && uri.host.isNotEmpty && builder != null) {
      return builder(uri.host, label.isEmpty ? '附件' : label, width, height);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label.isEmpty ? '（图片）' : '（图片：$label）',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 样式
  // -------------------------------------------------------------------------

  TextStyle _textStyle(
    BuildContext context,
    Map<String, String> styles,
    TextStyle base,
  ) {
    var out = base;
    final color = _colorOf(context, styles['color']);
    if (color != null) out = out.copyWith(color: color);
    final background = _colorOf(context, styles['background-color']);
    if (background != null) out = out.copyWith(backgroundColor: background);
    final weight = styles['font-weight'] ?? '';
    if (weight == 'bold' || weight == 'bolder' ||
        (int.tryParse(weight) ?? 0) >= 600) {
      out = out.copyWith(fontWeight: FontWeight.w700);
    }
    final fontStyle = styles['font-style'] ?? '';
    if (fontStyle == 'italic' || fontStyle == 'oblique') {
      out = out.copyWith(fontStyle: FontStyle.italic);
    }
    switch (styles['text-decoration']) {
      case 'underline':
        out = out.copyWith(decoration: TextDecoration.underline);
      case 'line-through':
        out = out.copyWith(decoration: TextDecoration.lineThrough);
    }
    final size = _pxOf(styles['font-size']);
    if (size != null && size >= 8 && size <= 72) {
      out = out.copyWith(fontSize: size);
    }
    return out;
  }

  TextAlign? _textAlignOf(Map<String, String> styles) => switch (
          (styles['text-align'] ?? '').toLowerCase()) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'left' => TextAlign.left,
        'justify' => TextAlign.justify,
        _ => null,
      };

  double? _sizeOf(
    SnapshotElement element,
    Map<String, String> styles,
    String key,
  ) {
    final attr = double.tryParse(element.attributes[key] ?? '');
    if (attr != null && attr > 0 && attr <= 4000) return attr;
    final style = _pxOf(styles[key]);
    if (style != null && style > 0 && style <= 4000) return style;
    return null;
  }

  double? _pxOf(String? raw) {
    if (raw == null || !raw.endsWith('px')) return null;
    return double.tryParse(raw.substring(0, raw.length - 2));
  }

  Color? _colorOf(BuildContext context, String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final value = raw.trim().toLowerCase();
    if (value == 'transparent' || value == 'inherit' || value == 'none') {
      return null;
    }
    if (value.startsWith('#')) {
      final hex = value.substring(1);
      if (hex.length == 3) {
        final r = int.tryParse('${hex[0]}${hex[0]}', radix: 16);
        final g = int.tryParse('${hex[1]}${hex[1]}', radix: 16);
        final b = int.tryParse('${hex[2]}${hex[2]}', radix: 16);
        if (r == null || g == null || b == null) return null;
        return Color.fromARGB(255, r, g, b);
      }
      if (hex.length == 6) {
        final v = int.tryParse(hex, radix: 16);
        if (v == null) return null;
        return Color(0xFF000000 | v);
      }
      return null;
    }
    if (value.startsWith('rgb(')) {
      final parts = value
          .substring(4, value.length - 1)
          .split(',')
          .map((p) => int.tryParse(p.trim()))
          .toList();
      if (parts.length != 3 || parts.any((p) => p == null)) return null;
      return Color.fromARGB(255, parts[0]!, parts[1]!, parts[2]!);
    }
    final named = _namedColors[value];
    return named;
  }

  static String _plainText(SnapshotElement element) {
    final buf = StringBuffer();
    void walk(List<SnapshotNode> nodes) {
      for (final node in nodes) {
        if (node is SnapshotText) {
          buf.write(node.text);
        } else if (node is SnapshotElement) {
          walk(node.children);
        }
      }
    }

    walk(element.children);
    return buf.toString().trim();
  }

  /// 常用命名色（够用即可；未知名称一律当作无色，不猜）。
  static const Map<String, Color> _namedColors = <String, Color>{
    'black': Color(0xFF000000),
    'white': Color(0xFFFFFFFF),
    'red': Color(0xFFFF0000),
    'green': Color(0xFF008000),
    'blue': Color(0xFF0000FF),
    'yellow': Color(0xFFFFFF00),
    'orange': Color(0xFFFFA500),
    'purple': Color(0xFF800080),
    'gray': Color(0xFF808080),
    'grey': Color(0xFF808080),
    'silver': Color(0xFFC0C0C0),
    'maroon': Color(0xFF800000),
    'navy': Color(0xFF000080),
    'teal': Color(0xFF008080),
    'olive': Color(0xFF808000),
    'lime': Color(0xFF00FF00),
    'aqua': Color(0xFF00FFFF),
    'cyan': Color(0xFF00FFFF),
    'fuchsia': Color(0xFFFF00FF),
    'magenta': Color(0xFFFF00FF),
    'pink': Color(0xFFFFC0CB),
    'brown': Color(0xFFA52A2A),
  };
}
