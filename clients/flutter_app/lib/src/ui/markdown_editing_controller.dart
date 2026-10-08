import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

/// 格式模式下把一段图片引用渲染为可交互「呈现单元」的构建器。
///
/// 由 UI 层注入：控制器本身不依赖附件缓存，只负责在 [buildTextSpan] 里把
/// `![alt](sui://<sha256>){尺寸}` 这一段从纯文本样式片段替换为图片 widget
/// （BR-27.1）。未注入时图片引用退化为普通样式文本，不影响正本与偏移。
///
/// [block] 为 true 表示该引用**独占一块**（引用前后即行边界，由块级插入保证，
/// 见 §5.5），UI 层据此按「块级呈现单元」布局：块宽即段落宽、块高向下扩展，
/// 后续文字整体下移；为 false 表示历史**行内引用**，仍按 §5.4 行内呈现，
/// 不强行改写正本（§5.5「行内引用兼容」）。
typedef FormatImageSpanBuilder = Widget Function(
  BuildContext context,
  ParsedImage image, {
  bool? block,
});

/// 格式模式下把任务项勾选框 `[ ]` / `[x]` 渲染为可点选复选框的构建器（§10.1）。
///
/// 由 UI 层注入；点选触发 [onToggle]，UI 层据此原地切换方括号内一个字符并回写
/// 正本（BR-31.2）。未注入时勾选框退化为普通样式文本，不影响正本与偏移。
typedef FormatTaskCheckboxBuilder = Widget Function(
  BuildContext context, {
  required bool checked,
  required VoidCallback onToggle,
});

/// 格式模式下把附件**链接**引用 `[name](sui://<sha256>)` 渲染为原子呈现单元的构建器。
///
/// 图片引用由 [FormatImageSpanBuilder] 承担；本钩子只负责链接型附件（FR-46 / §12.4）。
/// 未注入时链接引用退化为普通文本，不影响正本与偏移。
typedef FormatAttachmentLinkSpanBuilder = Widget Function(
  BuildContext context,
  AttachmentRef ref,
);

/// 格式模式下把一段 **GFM 管道表**渲染为可交互「表格呈现单元」的构建器（FR-44 / §12.1）。
///
/// 由 UI 层注入：控制器本身只负责把 `| 表头 | … |` 起至最后一行的**连续表格块**从纯文本
/// 样式片段替换为表格 widget（承 §11.2 块级呈现单元），单元格增删 / 内容 / 对齐改动全部经
/// 回调交由 UI 层用 [EditorFormat] 纯函数整体回写正本。
///
/// 未注入时表格退化为普通样式文本，不影响正本与偏移。残缺 / 非法表（`wellFormed == false`）
/// 不经本钩子，按普通块级文本原样透传（BR-44.5）。
typedef FormatTableSpanBuilder = Widget Function(
  BuildContext context,
  ParsedTable table,
);

/// 任务项行（GFM task list）：行首（可含缩进）`- [ ]` / `- [x]`，其后为任务文本。
///
/// 组 1 = 列表前缀（含尾随空白），组 2 = 方括号内的勾选字符（空格 / `x` / `X`），
/// 组 3 = 任务文本。非行首 / 无方括号的 `-[`、`[x]` 片段不匹配，按普通正文透传。
final RegExp _taskLinePattern = RegExp(r'^([ \t]*[-*+][ \t]+)\[([ xX])\](.*)$');

class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text}) : _lastText = text ?? '';

  /// 上一次赋值的正本（用于判断本次赋值是否为「纯光标移动」——文本未变）。
  String _lastText;

  /// 上一次折叠光标的偏移；用于表格边界吸附时推断移动方向
  /// （左 / 上 → 跳到表格前，右 / 下 → 跳到表格后）。
  int? _lastCollapsedOffset;

  /// 是否以富样式呈现（true=格式模式，false=源码模式）。
  ///
  /// 刻意做成**普通字段而非通知型状态**：该值由 [MarkdownEditor] 在每次构建时
  /// 依据当前模式写入，随同 TextField 一起重建；无需（也不应在）build 期间触发
  /// notifyListeners，否则会引发「build 期间 setState」断言。
  bool styled = false;

  /// 格式模式下的图片呈现单元构建器；由 UI 层注入（见 [FormatImageSpanBuilder]）。
  FormatImageSpanBuilder? formatImageBuilder;

  /// 格式模式下的任务勾选框构建器；由 UI 层注入（见 [FormatTaskCheckboxBuilder]）。
  FormatTaskCheckboxBuilder? formatTaskCheckboxBuilder;

  /// 格式模式下附件**链接**引用 `[name](sui://<sha256>)` 的呈现单元构建器。
  ///
  /// 由 UI 层注入（见 [FormatAttachmentLinkSpanBuilder]）。图片引用由
  /// [formatImageBuilder] 承担，本钩子只负责链接型附件；未注入时链接引用退化为
  /// 普通样式文本，不影响正本与偏移（FR-46 / §12.4）。
  FormatAttachmentLinkSpanBuilder? formatAttachmentLinkBuilder;

  /// 格式模式下 **GFM 管道表**的表格呈现单元构建器；由 UI 层注入（见 [FormatTableSpanBuilder]）。
  ///
  /// 未注入时表格退化为普通样式文本；残缺 / 非法表一律按普通文本透传（BR-44.5）。
  FormatTableSpanBuilder? formatTableBuilder;

  /// 勾选框被点选时的回调，入参为**该任务项所在行的起始偏移**。
  ///
  /// 由 UI 层接管：据此调用 `EditorFormat.toggleTaskChecked` 原地反转方括号内的
  /// 一个字符并回写正本（BR-31.2）。
  void Function(int lineStart)? onToggleTask;

  @override
  set value(TextEditingValue newValue) {
    final isCollapsed =
        newValue.selection.isValid && newValue.selection.isCollapsed;
    // 仅当「纯光标移动」（文本未变）且格式模式 + 表格启用时做边界吸附；
    // 否则（输入文字 / 程序化改写）不吸附，避免把光标强行拽到表格边界。
    if (styled && isCollapsed && newValue.text == _lastText) {
      final offset = newValue.selection.extentOffset;
      var snapped = offset;
      if (formatTableBuilder != null) {
        snapped =
            _snapOffsetAroundTables(newValue.text, snapped, _lastCollapsedOffset);
      }
      // 记号（`**` / `==` / `` ` `` / `- [ ] ` / `## ` …）**不可落点**：光标吸附到记号的外侧边界，
      // 使「折叠光标不停在记号内部」（BR-23.8① / §13.2）。
      snapped =
          _snapOffsetOutOfMarkers(newValue.text, snapped, _lastCollapsedOffset);
      if (snapped != offset) {
        newValue = newValue.copyWith(
          selection: TextSelection.collapsed(offset: snapped),
        );
      }
      _lastCollapsedOffset = snapped;
    } else {
      _lastCollapsedOffset = isCollapsed ? newValue.selection.extentOffset : null;
    }
    _lastText = newValue.text;
    super.value = newValue;
  }

  /// 若 [offset] 落在某张表格的**内部**或**首行起点**，返回「跳过整张表格」后的偏移量；
  /// 否则原样返回。
  ///
  /// [prev] 提供移动方向（上一次折叠光标偏移）：
  /// - 右 / 下移动（offset >= prev）→ 跳到表格**下方默认空行的行首**（`table.end + 1`）
  /// - 左 / 上移动（offset <  prev）→ 跳到表格前一行（`table.start - 1`）
  /// - 无方向信息时 → 就近吸附
  ///
  /// 表格以「原子块」参与外层光标导航（同块级图片 §5.5）：从上方往下、从下方往上
  /// 都应**整块跳过**，而不是被吸附回原位导致光标卡在表格边界（H2 复现）。
  ///
  /// 边界收紧（Issue 2）：`table.start` 正是表格**首行（控件栏 / 表头行）起点**，光标若停在
  /// 此处，落下的字会插到表头行开头，把表格打回原形。故落在 `table.start` 的光标一律前移
  /// 到「表格前一行」——即表格前那个 `\n` 之前（`table.start - 1`）；仅在表格位于文首
  /// （`start == 0`、无前行可退）时保持原位。
  ///
  /// 边界收紧（Issue 7）：右 / 下移动的落点应是表格**下方默认空行的行首**（`table.end + 1`，
  /// 即表格块区间外的那个行尾换行**之后**），而**不是**表格末行末尾（`table.end`）——后者光标
  /// 会滞留在表格最后一行，无法在表格下方正常落点、输入或回车换行。表格位于文末且其后无
  /// 换行（`table.end == text.length`）时无行可退，保持 `table.end`。
  static int _snapOffsetAroundTables(String text, int offset, int? prev) {
    final tables = _tableRegions(text);
    for (final t in tables) {
      final beforeStart = t.start > 0 ? t.start - 1 : t.start;
      // 表格下方「默认空行」的行首：表格块区间外的行尾换行之后。表格到文末无换行时退回原位。
      final afterEnd = t.end < text.length ? t.end + 1 : t.end;
      if (offset == t.start) {
        if (prev != null) {
          return offset >= prev ? afterEnd : beforeStart;
        }
        return beforeStart;
      }
      if (offset > t.start && offset <= t.end) {
        if (prev != null) {
          return offset >= prev ? afterEnd : beforeStart;
        }
        final distToStart = offset - t.start;
        final distToEnd = t.end - offset;
        return distToStart <= distToEnd ? beforeStart : afterEnd;
      }
    }
    return offset;
  }

  /// 若 [offset] 落在某个**记号区间内部**，返回吸附到记号**外侧边界**的偏移量；否则原样返回。
  ///
  /// 记号在格式模式下**不可见**（零宽透明），故光标不得停在记号内部——否则方向键会「看不见地」
  /// 移动、删除键会逐字符破坏记号（BR-23.8①）。方向口径同表格吸附：右 / 下移 → 记号的**末尾**
  /// （落到内容侧）、左 / 上移 → 记号的**起点**；无方向信息时就近吸附。
  static int _snapOffsetOutOfMarkers(String text, int offset, int? prev) {
    for (final m in EditorFormat.syntaxMarkers(text)) {
      if (offset <= m.start || offset >= m.end) continue;
      if (prev != null) return offset >= prev ? m.end : m.start;
      final distToStart = offset - m.start;
      final distToEnd = m.end - offset;
      return distToStart <= distToEnd ? m.start : m.end;
    }
    return offset;
  }

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

  /// 生成格式模式的样式片段：图片引用 / 任务勾选框替换为 [WidgetSpan]，其余按
  /// 逐字符样式合并。
  ///
  /// 偏移契约：整棵 span 树的 `toPlainText()` 必须与 [text] 等长，否则 TextField
  /// 的光标定位 / 命中测试会错位。`WidgetSpan` 在文本模型中固定占用 1 个码元，
  /// 故其引用余下的字符用「零宽透明」文本补足，保证等长（BR-27.1 / §10.1）。
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
      value.selection,
    );
    final imageBuilder = formatImageBuilder;
    final linkBuilder = formatAttachmentLinkBuilder;
    final tableBuilder = formatTableBuilder;

    // 收集所有「呈现单元」区间（图片引用 / 任务勾选框 / 附件链接 / 有序列表显示
    // 编号），按起点排序后逐段替换。
    final regions = <_SpanRegion>[];
    if (imageBuilder != null) {
      var from = 0;
      while (true) {
        final image = EditorFormat.findImage(text, from);
        if (image == null) break;
        final spanEnd = image.attributeEnd > 0 ? image.attributeEnd : image.end;
        regions.add(
          _SpanRegion(
            image.start,
            spanEnd,
            _RegionKind.image,
            image: image,
            block: _isStandaloneBlock(text, image.start, spanEnd),
          ),
        );
        from = spanEnd;
      }
    }
    // 记号呈现（§13.2 / BR-23.7）：行级前缀（标题 / 无序 / 有序 / 任务 / 引用 / 围栏 / 分割线）
    // 与行内成对记号（`**` `__` `*` `_` `~~` `==` `` ` ``）及链接语法部分**一律不可见**；
    // 其中项目符号 / 编号 / 勾选框 / 引用竖条 / 水平线以呈现单元 widget 承载。
    // 扫描口径与「预览」同源（[EditorFormat.syntaxMarkers]）：围栏内部 / 良构表格内部不扫描、
    // 缩进越界的行不建立行级前缀记号（BR-23.9②）。
    regions.addAll(_markerRegions(text));
    if (linkBuilder != null) {
      regions.addAll(_attachmentLinkRegions(text));
    }
    // 表格呈现单元：整块 GFM 管道表替换为可交互表格 widget（FR-44 / §12.1）。
    if (tableBuilder != null) {
      regions.addAll(_tableRegions(text));
    }
    if (regions.isEmpty) {
      return _MarkdownStyler.coalesce(text, styles, 0, text.length);
    }
    // 同起点时**长区间优先**（整块单元优先于其内部的记号片段，如附件链接整块 vs 其链接语法
    // 记号），避免因排序抖动丢掉整块呈现单元。
    regions.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      return b.end.compareTo(a.end);
    });

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final region in regions) {
      if (region.start < cursor) continue; // 与上一区域重叠，跳过
      if (region.start > cursor) {
        spans.addAll(
          _MarkdownStyler.coalesce(text, styles, cursor, region.start),
        );
      }
      spans.addAll(_regionSpans(context, text, base, region));
      cursor = region.end;
    }
    if (cursor < text.length) {
      spans.addAll(_MarkdownStyler.coalesce(text, styles, cursor, text.length));
    }
    return spans;
  }

  /// 跨行区间（表格）补齐文本所用的**零宽、禁断行**填充字符（`U+2060` WORD JOINER）。
  ///
  /// 补齐文本必须与正本**等码元**（偏移契约，BR-27.1），故不能直接删掉区间内的 `\n`；
  /// 但原样保留的 `\n` 会逐行建立行盒、叠加 strut 最小行高，在表格下方撑出**光标不可达、
  /// 不可删的空行**（§12.1.1「表格后占位行」）。以 `U+2060` 顶替 `\n` / `\r` 即可两全。
  static const String _noBreakFill = '\u2060';

  /// 隐藏（零宽透明）文本的**等码元替身**（偏移契约不变，BR-27.1）：
  ///
  /// - `\n` / `\r` → [_noBreakFill]（`U+2060` WORD JOINER：零宽、禁断行，不建立额外行盒）；
  /// - 空格 / `\t` → `U+00A0`（不换行空格）：Flutter 的行尾光标锚点计算在「末尾码元是空白
  ///   分隔符、但其字形包围盒为空」时会触发 `assert(!glyphBounds.isEmpty)`——零宽隐藏文本的
  ///   包围盒恰好为空（实测：内容只有 `- ` 的笔记按退格前设光标即断言失败）；`U+00A0` 不在其
  ///   空白判定内，改用它即可规避，宽度仍为 0、颜色透明、不产生任何可见字符。
  static String hiddenFill(String raw) => raw
      .replaceAll('\r', _noBreakFill)
      .replaceAll('\n', _noBreakFill)
      .replaceAll('\t', '\u00A0')
      .replaceAll(' ', '\u00A0');

  /// 把单个呈现单元区间替换为对应 widget，并用零宽透明文本补齐剩余码元。
  List<InlineSpan> _regionSpans(
    BuildContext context,
    String text,
    TextStyle base,
    _SpanRegion region,
  ) {
    final out = <InlineSpan>[];
    Widget child;
    var alignment = PlaceholderAlignment.top;
    if (region.kind == _RegionKind.image) {
      // 行内 / 块级一律 top 对齐：块级呈现单元（block == true）因此**向下扩展**，
      // 保证后续文字整体下移、不被遮盖；行内引用保持既有 §5.4 行为不变。
      child = formatImageBuilder!(
        context,
        region.image!,
        block: region.block,
      );
    } else if (region.kind == _RegionKind.attachmentLink) {
      // 附件链接引用 `[name](sui://<sha256>)`：整块呈现为原子单元（FR-46 / §12.4）。
      // 中部对齐，与任务勾选框一致；偏移由下方零宽透明文本补齐。
      alignment = PlaceholderAlignment.middle;
      child = formatAttachmentLinkBuilder!(context, region.attachment!);
    } else if (region.kind == _RegionKind.table) {
      // 表格呈现单元：整块 GFM 管道表（FR-44 / §12.1）。表格为**独占块**，
      // 行顶对齐（top）使其自首行位置**向下扩展**，后续文字整体下移（承 §5.5 块级呈现）。
      // 区间首字符由 WidgetSpan 占位，其余（含表内换行，换行以 `U+2060` 顶替）以零宽
      // 透明文本补齐，偏移保真且不撑出空行（见下方 §12.1.1「表格后占位行」说明）。
      alignment = PlaceholderAlignment.top;
      child = formatTableBuilder!(context, region.table!);
    } else {
      // —— 记号（§13.2 / BR-23.7）：一律不可见；需要视觉承载者以呈现单元 widget 呈现 ——
      final marker = region.marker!;
      final scheme = Theme.of(context).colorScheme;
      switch (marker.kind) {
        case SyntaxMarkerKind.bullet:
          alignment = PlaceholderAlignment.middle;
          child = Text('• ', style: base.copyWith(color: scheme.primary));
        case SyntaxMarkerKind.ordered:
          alignment = PlaceholderAlignment.middle;
          child = Text(
            '${marker.displayNumber ?? 1}. ',
            style: base.copyWith(color: scheme.primary),
          );
        case SyntaxMarkerKind.task:
          alignment = PlaceholderAlignment.middle;
          final builder = formatTaskCheckboxBuilder;
          child = builder == null
              ? const SizedBox.shrink()
              : builder(
                  context,
                  checked: marker.checked,
                  onToggle: () =>
                      onToggleTask?.call(marker.lineStart ?? marker.start),
                );
        case SyntaxMarkerKind.quote:
          alignment = PlaceholderAlignment.middle;
          child = Container(
            width: 3,
            height: 18,
            margin: const EdgeInsets.only(right: 6),
            color: scheme.outline.withValues(alpha: 0.6),
          );
        case SyntaxMarkerKind.rule:
          alignment = PlaceholderAlignment.top;
          child = const FormatRuleLine();
        case SyntaxMarkerKind.heading:
        case SyntaxMarkerKind.setext:
        case SyntaxMarkerKind.fence:
        case SyntaxMarkerKind.strong:
        case SyntaxMarkerKind.emphasis:
        case SyntaxMarkerKind.strike:
        case SyntaxMarkerKind.highlight:
        case SyntaxMarkerKind.code:
        case SyntaxMarkerKind.link:
          // 纯记号：**不可见**（零宽 + 透明），整段一并用零宽文本顶替，不产生 widget。
          return <InlineSpan>[
            TextSpan(
              text: MarkdownEditingController.hiddenFill(
                text.substring(region.start, region.end),
              ),
              style: base.copyWith(color: Colors.transparent, fontSize: 0),
            ),
          ];
      }
    }
    out.add(WidgetSpan(alignment: alignment, child: child));
    // 区间首字符由 WidgetSpan 的 1 个码元占位，其余用零宽透明文本补齐。
    final restStart = region.start + 1;
    if (region.end - restStart > 0) {
      // 表格是**唯一跨行**的呈现单元：其区间内含有表内 `\n`（`rows×cols` 表共 `rows−1` 个）。
      // 补齐文本若原样保留这些 `\n`，会在 WidgetSpan 之后**逐行建立行盒**，叠加
      // `StrutStyle(forceStrutHeight: false)` 的最小行高，撑出多个**可见、光标不可达、
      // 不可删的空行**（表格行数越多空行越多，§12.1.1「表格后占位行」）。故把 `\n` / `\r`
      // 顶替为**等码元、零宽、禁断行**的 `U+2060`——既维持 `toPlainText()` 与正本等长
      // （偏移契约，BR-27.1 / §4.1），又不产生任何额外行盒。单行区间（图片 / 勾选框 /
      // 附件链接 / 有序编号）不含换行，保持逐字透传。
      // 补齐文本一律走 [hiddenFill]：换行以 `U+2060` 顶替（表格区间专用，避免撑出空行），
      // 空白以 `U+00A0` 顶替（规避 Flutter 行尾光标锚点断言），二者均等码元、零宽、不可见。
      final fill =
          MarkdownEditingController.hiddenFill(text.substring(restStart, region.end));
      out.add(TextSpan(
        text: fill,
        style: base.copyWith(color: Colors.transparent, fontSize: 0),
      ));
    }
    return out;
  }

  /// 判断一个图片引用区间是否**独占一块**：区间左侧是行首（文本开头或 `\n`），
  /// 右侧是行尾（文本结尾或 `\n`）。
  ///
  /// 只有满足该条件时才按块级呈现（§5.5）；历史行内引用（前后同一行还有文字）
  /// 仍走行内呈现，正本逐字保真（§5.5「行内引用兼容」）。
  static bool _isStandaloneBlock(String text, int start, int end) {
    final leftOk = start == 0 || text[start - 1] == '\n';
    final rightOk = end >= text.length || text[end] == '\n';
    return leftOk && rightOk;
  }

  /// 收集全部**记号区间**（§13.2 / BR-23.7）。
  ///
  /// 记号 = 被 Markdown 解析为**语法**的字符；扫描由 [EditorFormat.syntaxMarkers] 统一承担
  /// （与预览同源判定：围栏内部 / 良构表格内部不扫描，缩进越界的行不建立行级前缀记号）。
  static List<_SpanRegion> _markerRegions(String text) =>
      EditorFormat.syntaxMarkers(text)
          .map((m) => _SpanRegion(m.start, m.end, _RegionKind.marker, marker: m))
          .toList();

  /// 扫描所有附件**链接**引用 `[name](sui://<sha256>)`，返回其整块区间。
  ///
  /// 图片引用 `![alt](sui://<sha256>)` 由 [formatImageBuilder] 另行呈现，此处仅取
  /// 链接型（`isImage == false`）。残缺引用（缺 `)`）同样按整块识别，交由 UI 层
  /// 自愈（FR-46 / §12.4）。
  static List<_SpanRegion> _attachmentLinkRegions(String text) {
    final regions = <_SpanRegion>[];
    for (final ref in EditorFormat.attachmentRefs(text)) {
      if (ref.isImage) continue;
      regions.add(_SpanRegion(
        ref.start,
        ref.end,
        _RegionKind.attachmentLink,
        attachment: ref,
      ));
    }
    return regions;
  }

  /// 扫描所有**完整的 GFM 管道表**块，返回其整块区间（FR-44 / §12.1）。
  ///
  /// 仅当 [EditorFormat.parseTable] 解析成功且 `wellFormed == true` 时建立区间；
  /// 残缺 / 非法表（列数不齐、缺分隔行等）**不建区间**，按普通块级文本原样透传
  /// （BR-44.5）。表格为独占块，区间覆盖「表头行 + 分隔行 + 数据行」全部字符。
  static List<_SpanRegion> _tableRegions(String text) {
    final regions = <_SpanRegion>[];
    var from = 0;
    while (from < text.length) {
      final table = EditorFormat.parseTable(text, from);
      if (table == null) {
        // 当前位置不是表格，跳到下一行继续找（而不是直接 break），
        // 否则表格前面有文字时整段扫描都会提前终止。
        final nl = text.indexOf('\n', from);
        if (nl == -1) break;
        from = nl + 1;
        continue;
      }
      if (table.wellFormed) {
        regions.add(_SpanRegion(
          table.start,
          table.end,
          _RegionKind.table,
          table: table,
        ));
      }
      // table.end 恒为「末行行尾换行符」下标或文本末尾：跳到下一行继续扫描，
      // 避免在同一表格块上重复命中（防御：解析未推进时直接结束）。
      if (table.end >= text.length) break;
      from = table.end + 1;
    }
    return regions;
  }

}

/// 呈现单元类型。
///
/// [marker] 为格式模式的**记号区间**：一律不可见（或由 widget 承载项目符号 / 编号 / 勾选框 /
/// 引用竖条 / 水平线），见 §13.2 / BR-23.7。
enum _RegionKind { image, marker, attachmentLink, table }

/// 一个「呈现单元」在正本中的字符区间。
class _SpanRegion {
  final int start;
  final int end;
  final _RegionKind kind;
  final ParsedImage? image;

  /// 仅附件链接区间有意义：该链接型附件的解析结果（FR-46 / §12.4）。
  final AttachmentRef? attachment;

  /// 仅表格区间有意义：该 GFM 管道表块的解析结果（FR-44 / §12.1）。
  final ParsedTable? table;

  /// 仅记号区间有意义：该记号的扫描结果（§13.2 / BR-23.7）。
  final SyntaxMarker? marker;

  /// 仅图片区间有意义：true 表示该引用独占一块（§5.5），应按块级呈现单元布局。
  final bool block;

  const _SpanRegion(
    this.start,
    this.end,
    this.kind, {
    this.image,
    this.attachment,
    this.table,
    this.marker,
    this.block = false,
  });
}

/// 把 Markdown 正文解析为「覆盖全部字符」的样式片段。
///
/// 契约：产出的样式必须**逐字符覆盖** `0..text.length`，不允许出现空洞——
/// 否则 TextField 的光标定位与命中测试会错位。实现上先为每个字符算出最终样式，
/// 再把样式相同的相邻字符合并成一个 span。
class _MarkdownStyler {
  _MarkdownStyler._();

  static final RegExp _fenceLine = RegExp(r'^[ \t]*(```|~~~)');

  /// 标题前缀（≤3 空格前导，与 CommonMark 同口径）：组 1 缩进 / 组 2 `#` / 组 3 空白。
  static final RegExp _headingLine = RegExp(r'^([ \t]{0,3})(#{1,6})([ \t]+)(.*)$');

  /// 引用前缀（≤3 空格前导）：组 1 缩进 / 组 2 `>`（含可选空白）。
  static final RegExp _quoteLine = RegExp(r'^([ \t]{0,3})(>[ \t]?)(.*)$');
  static final RegExp _bulletLine = RegExp(r'^([ \t]*[-*+][ \t]+)(.*)$');
  static final RegExp _orderedLine = RegExp(r'^([ \t]*\d+\.[ \t]+)(.*)$');

  /// 分割线（≤3 空格前导）。
  static final RegExp _ruleLine = RegExp(r'^([ \t]{0,3})(-{3,}|\*{3,}|_{3,})[ \t]*$');

  static final RegExp _inline = RegExp(
    r'(`[^`\n]+`)' // 1 行内代码
    r'|(!\[[^\]\n]*\]\([^)\n]*\))' // 2 图片
    r'|(\[[^\]\n]*\]\([^)\n]*\))' // 3 链接
    r'|(\*\*[^*\n]+\*\*)' // 4 加粗 **
    r'|(__[^_\n]+__)' // 5 加粗 __
    r'|(~~[^~\n]+~~)' // 6 删除线
    r'|(\*[^*\n]+\*)' // 7 斜体 *
    r'|(_[^_\n]+_)' // 8 斜体 _
    r'|(==[^=\n]+==)', // 9 高亮 ==
  );

  static const List<double> _headingScale = [1.75, 1.5, 1.28, 1.14, 1.06, 1.0];

  static List<TextStyle> characterStyles(
    BuildContext context,
    String text,
    TextStyle base,
    TextRange composing,
    TextSelection selection,
  ) {
    if (text.isEmpty) return const <TextStyle>[];
    final scheme = Theme.of(context).colorScheme;

    // 标记符号的两种可见度：失焦态高度淡化（§11.1），聚焦态完整展开。
    final marker = base.copyWith(color: scheme.outline.withValues(alpha: 0.35));
    final markerActive =
        base.copyWith(color: scheme.outline.withValues(alpha: 0.9));
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
    final faint = base.copyWith(
      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
    );
    // 高亮：等价 `<mark>`（§10.2），与删除线 `~~` 是不同字符，互不混淆。
    final highlight = base.copyWith(
      backgroundColor: scheme.tertiaryContainer,
      color: scheme.onTertiaryContainer,
    );

    final n = text.length;
    final styles = List<TextStyle>.filled(n, base);

    // setext 标题（`标题` + 下一行 `===` / `---`）行集合：该行按 h2 呈现，下划线行由记号隐藏
    // （与预览一致，§13.2 / BR-23.7）。
    final setextHeadings = _setextHeadingLines(text);

    // 逐行扫描；围栏代码块内不做块级 / 行内解析。
    var lineStart = 0;
    var inFence = false;
    while (lineStart <= n) {
      var lineEnd = text.indexOf('\n', lineStart);
      if (lineEnd == -1) lineEnd = n;
      final line = text.substring(lineStart, lineEnd);
      // 光标落在本行内 → 标记完整展开；否则高度淡化（§11.1）。
      final lineMarker =
          _lineFocused(selection, lineStart, lineEnd) ? markerActive : marker;

      if (_fenceLine.hasMatch(line)) {
        _fill(styles, lineStart, lineEnd, lineMarker);
        inFence = !inFence;
      } else if (inFence) {
        _fill(styles, lineStart, lineEnd, code);
      } else {
        _block(
          styles,
          lineStart,
          lineEnd,
          line,
          base,
          lineMarker,
          accent,
          quote,
          faint,
          setext: setextHeadings.contains(lineStart),
          listOk: EditorFormat.isListLineAt(text, lineStart),
        );
        _inlineSpans(
          styles,
          lineStart,
          line,
          lineMarker,
          accent,
          code,
          base,
          highlight,
        );
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

  /// 光标（选区活动端）是否落在 `[lineStart, lineEnd]` 行内。
  static bool _lineFocused(
      TextSelection selection, int lineStart, int lineEnd) {
    if (!selection.isValid) return false;
    final p = selection.extentOffset;
    return p >= lineStart && p <= lineEnd;
  }

  // ---------------------------------------------------------------------------
  // 块级
  // ---------------------------------------------------------------------------

  /// 收集 **setext 标题行**（其后一行是 `===` / `---` 下划线）的行首偏移集合。
  static Set<int> _setextHeadingLines(String text) {
    final out = <int>{};
    final n = text.length;
    var lineStart = 0;
    while (lineStart <= n) {
      final nl = text.indexOf('\n', lineStart);
      final lineEnd = nl == -1 ? n : nl;
      if (lineStart > 0 && EditorFormat.isSetextUnderlineAt(text, lineStart)) {
        final prevNl =
            lineStart >= 2 ? text.lastIndexOf('\n', lineStart - 2) : -1;
        out.add(prevNl == -1 ? 0 : prevNl + 1);
      }
      if (lineEnd >= n) break;
      lineStart = lineEnd + 1;
    }
    return out;
  }

  /// 块级样式（内容样式，**记号本身不在此呈现**——记号由记号区间隐藏，§13.2 / BR-23.7）。
  ///
  /// [setext] 为 true 表示本行是 setext 标题的**文本行**（按 h2 呈现）；
  /// [listOk] 为 false 表示本行缩进越界、GFM 不会解析为列表 / 任务项 → 不加列表样式，
  /// 与「预览」的行级结构判定一致（BR-23.9②）。
  static void _block(
    List<TextStyle> styles,
    int start,
    int end,
    String line,
    TextStyle base,
    TextStyle marker,
    TextStyle accent,
    TextStyle quote,
    TextStyle faint, {
    bool setext = false,
    bool listOk = true,
  }) {
    if (setext) {
      final style = base.copyWith(
        fontSize: (base.fontSize ?? 15) * _headingScale[1],
        fontWeight: FontWeight.w700,
        height: 1.3,
      );
      _fill(styles, start, end, style);
      return;
    }

    final heading = _headingLine.firstMatch(line);
    if (heading != null) {
      final level = heading.group(2)!.length;
      final scale =
          _headingScale[(level - 1).clamp(0, _headingScale.length - 1)];
      final style = base.copyWith(
        fontSize: (base.fontSize ?? 15) * scale,
        fontWeight: FontWeight.w700,
        height: 1.3,
      );
      _fill(styles, start, end, style);
      return;
    }

    if (_ruleLine.hasMatch(line)) {
      _fill(styles, start, end, marker);
      return;
    }

    if (_quoteLine.hasMatch(line)) {
      _fill(styles, start, end, quote);
      return;
    }

    if (!listOk) return;

    // 任务项需先于普通列表判定（`- [ ]` 也符合无序列表前缀）。
    final t = _taskLinePattern.firstMatch(line);
    if (t != null) {
      final prefixLen = t.group(1)!.length;
      final checked = t.group(2)!.toLowerCase() == 'x';
      final boxEnd = (start + prefixLen + 3).clamp(0, end);
      if (checked) {
        // 勾选态：任务文本**仅视觉淡化 / 加灰**，不加删除线（BR-31.6）。
        _fill(styles, boxEnd, end, faint);
      }
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
    TextStyle highlight,
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
      } else if (m.group(9) != null) {
        // 高亮 `==…==`：标记淡化，内容加高亮底色（§10.2）。
        _merge(styles, offset + ls, offset + ls + 2, marker);
        _merge(styles, offset + ls + 2, offset + le - 2, highlight);
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

  static void _fill(
      List<TextStyle> styles, int start, int end, TextStyle style) {
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

/// 格式模式下的**分割线呈现单元**（`---` 记号 → 水平线，§13.2 / BR-23.7）。
///
/// 按可用段落宽铺满（`LayoutBuilder`，无界时退回 720），故独占一行、后续文字整体下移
/// ——与「预览」的 `<hr>` 观感一致。
class FormatRuleLine extends StatelessWidget {
  const FormatRuleLine({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 720.0;
        return Container(
          width: width,
          height: 1,
          margin: const EdgeInsets.symmetric(vertical: 6),
          color: scheme.outlineVariant,
        );
      },
    );
  }
}
