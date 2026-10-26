import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

import 'appearance/app_palette.dart';

/// 编辑区正文的左右**内边距**（px）——FR-93 / BR-93.1 的**单一真源**。
///
/// 三处共用，禁止再各写一份魔数：
/// * `_SourceEditor`（`markdown_editor.dart`）的正文白底 `Padding`；
/// * `note_editor.dart` 的 `paragraphWidth = 布局宽 − 2 × kEditorBodyPadding`（正文列宽）；
/// * 围栏代码块底色带的定宽（`paragraphWidth + 2 × kEditorBodyPadding`）与左侧偏移。
///
/// 底色带因此**恰好铺满编辑区白底**、左右边界与白底重合，不再依赖上层裁剪（§22.8）。
const double kEditorBodyPadding = 16;

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

/// 格式模式下把一处 **Markdown 链接** `[显示文字](网址)` 渲染为**原子链接单元**的构建器
/// （FR-76 / 规范 §1.3）。
///
/// 由 UI 层注入（`note_editor.dart` 的 `_buildFormatLink`）。链接单元内的显示文字**必须**用
/// `Text.data` 承载——`FormatPreviewParity` 只从 `Text.data` 收集可见文本（BR-76.2）。
/// 未注入时链接退化为普通样式文本（记号仍不可见），不影响正本与偏移。
typedef FormatLinkSpanBuilder = Widget Function(
  BuildContext context,
  MarkdownLink link,
);

/// 任务项行（GFM task list）：行首（可含缩进）`- [ ]` / `- [x]`，其后为任务文本。
///
/// 组 1 = 列表前缀（含尾随空白），组 2 = 方括号内的勾选字符（空格 / `x` / `X`），
/// 组 3 = 任务文本。非行首 / 无方括号的 `-[`、`[x]` 片段不匹配，按普通正文透传。
final RegExp _taskLinePattern = RegExp(r'^([ \t]*[-*+][ \t]+)\[([ xX])\](.*)$');

/// 格式模式下**快照 HTML 块**（FR-69）的呈现单元构建器：整块替换为一个 widget。
typedef FormatHtmlBlockSpanBuilder = Widget Function(
  BuildContext context,
  String html,
);

/// 格式模式下**网页原件**（M16 / FR-83）的呈现单元构建器：整行替换为一个 widget。
typedef FormatWebClipSpanBuilder = Widget Function(
  BuildContext context,
  WebClipRef ref,
);

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

  /// 格式模式下**快照 HTML 块**（FR-69 / §16.3）的呈现单元构建器；由 UI 层注入。
  ///
  /// 未注入时 HTML 块退化为普通样式文本（可逐字符编辑、也容易被改坏），故正文编辑器
  /// **一律注入**——它是**原子块**：整块呈现、整块删除（BR-69.3）。
  FormatHtmlBlockSpanBuilder? formatHtmlBlockBuilder;

  /// 格式模式下**网页原件**（`[网页原件](sui://webclip/<sha>)`）的呈现单元构建器。
  /// 由 UI 层注入；未注入时按普通链接样式文本透传。
  FormatWebClipSpanBuilder? formatWebClipBuilder;

  /// 格式模式下**链接单元** `[文字](网址)` 的呈现单元构建器；由 UI 层注入（见 [FormatLinkSpanBuilder]）。
  ///
  /// 未注入时链接退化为普通样式文本（`[` / `](...)` 记号仍不可见）；注入后整段链接成为
  /// **原子单元**——光标吸附把链接区间视为不可落点的原子区间（FR-76 / BR-76.1）。
  FormatLinkSpanBuilder? formatLinkBuilder;

  /// 编辑区正文的**可用段落宽度**（px）：由 `note_editor.dart` 用 `LayoutBuilder` 注入。
  ///
  /// 用途只有 **格式模式的围栏块样式切换**：`> 0` 时建立开围栏行区间（隐藏 info string）
  /// 并让内容行改用**无逐字形底色**的等宽样式（底色由 `CodeBlockBandPainter` 在文字
  /// **之下**绘制，FR-94）；`0` = 宽度未知（测试 / 首帧），回退逐字形底色。
  double paragraphWidth = 0;

  /// 笔记内查找的**命中集合**（FR-73）；由 `note_editor.dart` 计算后写入（控制器只负责画）。
  ///
  /// 刻意做成**普通字段而非通知型状态**：由 UI 层在 `setState` 里赋值并随同 TextField 重建，
  /// **不得**在 build 期触发 `notifyListeners()`（否则「build 期间 setState」断言）。
  List<FindMatch> findMatches = const <FindMatch>[];

  /// 当前命中项下标（`-1` = 无当前命中）；当前项用**更强**的底色口径，与普通命中区分。
  int activeFindIndex = -1;

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
      // 围栏代码块**边界不可落点**（FR-81 / BR-81.2 / AC-441）：围栏行内部与块边界换行一律吸附到
      // **块外**——否则一个方向键就能「看不见地」把光标移进围栏行、一个删除键就能打坏块结构。
      snapped =
          _snapOffsetOutOfFences(newValue.text, snapped, _lastCollapsedOffset);
      // 链接单元是**原子区间**（FR-76 / BR-76.1）：整段链接由 widget 承载，光标落在其内部不可见。
      if (formatLinkBuilder != null) {
        snapped =
            _snapOffsetOutOfLinks(newValue.text, snapped, _lastCollapsedOffset);
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
    // 跨行**原子块**：表格 + 快照 HTML 块（FR-69 / §16.3 同口径——光标不得停在块内部，
    // 否则方向键会「看不见地」移动、删除键会逐字符咬坏块结构）。
    final tables = <_SpanRegion>[
      ..._tableRegions(text),
      ..._htmlBlockRegions(text),
      ..._webClipRegions(text),
    ]..sort((a, b) => a.start.compareTo(b.start));
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
    for (final m in _markers(text)) {
      if (offset <= m.start || offset >= m.end) continue;
      if (prev != null) return offset >= prev ? m.end : m.start;
      final distToStart = offset - m.start;
      final distToEnd = m.end - offset;
      return distToStart <= distToEnd ? m.start : m.end;
    }
    return offset;
  }

  /// 若 [offset] 落在某个**围栏代码块的边界区**，返回吸附到**块外**的偏移量；否则原样返回。
  ///
  /// 口径（FR-81 / BR-81.2 / AC-441，规范 §1.7）：
  /// * **开围栏区** `[b.start, b.openLineEnd + 1]`（含行尾换行）：右 / 下移 → `b.contentStart`
  ///   （进入块内首行）；左 / 上移（或方向未知）→ `b.start - 1`（块前一行行尾）；
  ///   `b.start == 0`（块在文首、无前行可退）时保持原位。
  /// * **闭合围栏区**（仅 `b.closed`）`[b.closeLineStart, b.closeLineEnd + 1]`：右 / 下移 →
  ///   `b.closeLineEnd + 1`（块后一行行首）；左 / 上移 → `b.closeLineStart - 1`（末内容行行尾）；
  ///   `b.closeLineStart == 0` 时保持原位。
  ///
  /// 只在 `set value` 的「折叠光标 + 格式模式 + 文本未变」守卫内调用，不影响输入 / 程序化写入。
  static int _snapOffsetOutOfFences(String text, int offset, int? prev) {
    for (final b in _fences(text)) {
      if (offset >= b.start && offset <= b.openLineEnd + 1) {
        if (prev != null && offset >= prev) return b.contentStart;
        return b.start > 0 ? b.start - 1 : offset;
      }
      if (b.closed &&
          offset >= b.closeLineStart &&
          offset <= b.closeLineEnd + 1) {
        if (prev != null && offset >= prev) return b.closeLineEnd + 1;
        return b.closeLineStart > 0 ? b.closeLineStart - 1 : offset;
      }
    }
    return offset;
  }

  /// 若 [offset] 落在某个**链接单元区间内部**，返回吸附到区间**外侧边界**的偏移量；否则原样返回。
  ///
  /// 链接单元是**原子呈现单元**（FR-76 / BR-76.1）：整段 `[文字](网址)` 由 widget 承载，
  /// 光标落在其内部「看不见」（标签文字由 widget 绘制，而非文本模型），故一律吸附到区间边界。
  /// 方向口径同记号吸附：右 / 下移 → 区间**末尾**；左 / 上移 → 区间**起点**；无方向时就近吸附。
  static int _snapOffsetOutOfLinks(String text, int offset, int? prev) {
    for (final l in EditorFormat.links(text)) {
      if (offset <= l.start || offset >= l.end) continue;
      if (prev != null) return offset >= prev ? l.end : l.start;
      return (offset - l.start) <= (l.end - offset) ? l.start : l.end;
    }
    return offset;
  }

  /// 记号扫描的**单条缓存**（`text` → markers）。
  ///
  /// [EditorFormat.syntaxMarkers] 较重（逐行扫描 + 行内递归），而一次 build 里样式层 / 记号区间 /
  /// 光标吸附会反复取用**同一份**结果；按文本做一条缓存即可（文本一变小缓存自然失效）。
  static String? _markerCacheText;
  static List<SyntaxMarker>? _markerCacheMarkers;

  static List<SyntaxMarker> _markers(String text) {
    if (_markerCacheText == text && _markerCacheMarkers != null) {
      return _markerCacheMarkers!;
    }
    final markers = EditorFormat.syntaxMarkers(text);
    _markerCacheText = text;
    _markerCacheMarkers = markers;
    return markers;
  }

  /// 围栏块扫描的**单条缓存**（`text` → blocks），同 [_markers]。
  static String? _fenceCacheText;
  static List<FenceBlock>? _fenceCacheBlocks;

  static List<FenceBlock> _fences(String text) {
    if (_fenceCacheText == text && _fenceCacheBlocks != null) {
      return _fenceCacheBlocks!;
    }
    final blocks = EditorFormat.fenceBlocks(text);
    _fenceCacheText = text;
    _fenceCacheBlocks = blocks;
    return blocks;
  }

  /// 底色带生效时，围栏块**内容行**的行首集合（供样式层改用无 `backgroundColor` 的 `codeNoBg`）。
  ///
  /// 区间取 `[contentStart, contentEnd)`：**开 / 闭围栏行不在内**（它们整行不可见，由记号区间承担）。
  static Set<int> _bandedCodeLineStarts(String text) {
    final out = <int>{};
    for (final b in _fences(text)) {
      var ls = b.contentStart;
      while (ls < b.contentEnd) {
        out.add(ls);
        final nl = text.indexOf('\n', ls);
        if (nl == -1 || nl >= b.contentEnd) break;
        ls = nl + 1;
      }
    }
    return out;
  }


  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!styled) {
      // 源码模式是**零加工视图**（BR-77.1）：无命中时原样交回框架（含 IME 组合区下划线）。
      // 有命中时（FR-73）自建 span 切分叠加命中底色——**不得**改成正本或加隐藏字符。
      if (findMatches.isEmpty) {
        return super.buildTextSpan(
          context: context,
          style: style,
          withComposing: withComposing,
        );
      }
      return TextSpan(
        style: style,
        children: _sourceSpans(context, style, withComposing),
      );
    }
    final base = style ?? const TextStyle();
    final composing = withComposing ? value.composing : TextRange.empty;
    return TextSpan(
      style: base,
      children: _buildSpans(context, text, base, composing),
    );
  }

  /// 源码模式下存在**查找命中**（FR-73）时的 span 切分。
  ///
  /// 源码模式仍是**零加工视图**（BR-77.1）：不隐藏记号、不做转义加工，这里只叠加命中底色；
  /// **IME 组合区的下划线必须保留**（与格式态同口径，规范 §1.5）。命中底色与 FR-68 的黄色高亮
  /// （`palette.highlight`）**明确区分**：普通命中用 `secondaryContainer`，当前命中用 `primary`
  /// 实底 + `onPrimary` 前景（更强口径，且与黄底不同色系）。
  List<InlineSpan> _sourceSpans(
    BuildContext context,
    TextStyle? style,
    bool withComposing,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final n = text.length;
    final marks = List<int>.filled(n, 0);
    for (var k = 0; k < findMatches.length; k++) {
      final m = findMatches[k];
      final s = m.start.clamp(0, n);
      final e = m.end.clamp(0, n);
      for (var i = s; i < e; i++) {
        marks[i] = k == activeFindIndex ? 2 : 1;
      }
    }
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final composingActive = composing.isValid && !composing.isCollapsed;
    final matchStyle = TextStyle(backgroundColor: scheme.secondaryContainer);
    final activeStyle = TextStyle(
      backgroundColor: scheme.primary,
      color: scheme.onPrimary,
    );
    const underline = TextStyle(decoration: TextDecoration.underline);

    bool inComposing(int i) =>
        composingActive && i >= composing.start && i < composing.end;

    final spans = <InlineSpan>[];
    var i = 0;
    while (i < n) {
      final mark = marks[i];
      final comp = inComposing(i);
      var j = i + 1;
      while (j < n && marks[j] == mark && inComposing(j) == comp) {
        j++;
      }
      var s = style ?? const TextStyle();
      if (mark == 1) s = s.merge(matchStyle);
      if (mark == 2) s = s.merge(activeStyle);
      if (comp) s = s.merge(underline);
      spans.add(TextSpan(text: text.substring(i, j), style: s));
      i = j;
    }
    return spans;
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
      markers: _markers(text),
      codeBandActive: paragraphWidth > 0,
      findMatches: findMatches,
      activeFindIndex: activeFindIndex,
    );
    final imageBuilder = formatImageBuilder;
    final linkBuilder = formatAttachmentLinkBuilder;
    final tableBuilder = formatTableBuilder;
    final htmlBuilder = formatHtmlBlockBuilder;
    final webClipBuilder = formatWebClipBuilder;

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
    // 链接单元（FR-76 / §1.3）：仅当 UI 层注入构建器时建立区间（未注入时链接退化为普通文本）。
    final markdownLinkBuilder = formatLinkBuilder;
    if (markdownLinkBuilder != null) {
      regions.addAll(_linkRegions(text));
    }
    // 围栏代码块**开围栏行**（FR-81a）：隐藏整行（含 info string）；底色带由
    // `CodeBlockBandPainter` 在 `TextField` 背后绘制（FR-94），宽度未知（0）时不建立。
    if (paragraphWidth > 0) {
      regions.addAll(_codeBlockBandRegions(text));
    }
    // 表格呈现单元：整块 GFM 管道表替换为可交互表格 widget（FR-44 / §12.1）。
    if (tableBuilder != null) {
      regions.addAll(_tableRegions(text));
    }
    // 快照 HTML 块：整块替换为受限渲染 widget（FR-69 / §16.3）。
    if (htmlBuilder != null) {
      regions.addAll(_htmlBlockRegions(text));
    }
    // 网页原件（M16 / FR-83）：整行原子单元。
    if (webClipBuilder != null) {
      regions.addAll(_webClipRegions(text));
    }
    if (regions.isEmpty) {
      return _MarkdownStyler.coalesce(text, styles, 0, text.length);
    }
    // 同起点时**整块 / 原子呈现单元优先**，其次**长区间优先**（整块单元优先于其内部的记号片段，
    // 如代码块底色带 vs 开围栏行的围栏记号、附件链接整块 vs 其链接语法记号），
    // 避免因排序抖动丢掉整块呈现单元。
    regions.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      final byPriority =
          _regionPriority(a.kind).compareTo(_regionPriority(b.kind));
      if (byPriority != 0) return byPriority;
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
      spans.addAll(_regionSpans(context, text, base, styles, region));
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
    List<TextStyle> styles,
    _SpanRegion region,
  ) {
    // 转义序列 `\x`（FR-78 / BR-78.4 / 规范 §1.2）：反斜杠**零宽透明** + 被转义字符按**普通文本**
    // 呈现（不套用任何**记号**样式，但保留所在块 / 外层记号的样式）。
    // **不能**走下方「整段 hiddenFill」的通用记号分支，否则被转义字符会一起消失。
    if (region.kind == _RegionKind.marker &&
        region.marker!.kind == SyntaxMarkerKind.escape) {
      final escaped = text.substring(region.start + 1, region.end);
      final escapedStyle =
          region.start + 1 < styles.length ? styles[region.start + 1] : base;
      return <InlineSpan>[
        TextSpan(
          text: MarkdownEditingController.hiddenFill(
            text.substring(region.start, region.start + 1),
          ),
          style: base.copyWith(color: Colors.transparent, fontSize: 0),
        ),
        TextSpan(text: escaped, style: escapedStyle),
      ];
    }
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
    } else if (region.kind == _RegionKind.htmlBlock) {
      // 快照 HTML 块（FR-69）：整块**原子**呈现（独占块、行顶对齐向下扩展）；
      // 区间内换行同样以 `U+2060` 顶替（见下方补齐逻辑，避免撑出多余空行）。
      alignment = PlaceholderAlignment.top;
      child = formatHtmlBlockBuilder!(context, region.html!);
    } else if (region.kind == _RegionKind.webClip) {
      // 网页原件（M16 / FR-83）：独占一行的原子卡片 / 预览单元。
      alignment = PlaceholderAlignment.top;
      child = formatWebClipBuilder!(context, region.webClip!);
    } else if (region.kind == _RegionKind.link) {
      // 链接单元（FR-76 / BR-76.1 / 规范 §1.3）：整段 `[文字](网址)` 是一个**原子** widget；
      // 中部对齐（与附件链接单元一致），其余码元由下方 `hiddenFill` 补齐（偏移契约不变）。
      alignment = PlaceholderAlignment.middle;
      child = formatLinkBuilder!(context, region.markdownLink!);
    } else if (region.kind == _RegionKind.codeBlockBand) {
      // 围栏代码块**开围栏行**（FR-81a / FR-94）：底色带由 `TextField` **背后**的
      // `CodeBlockBandPainter` 绘制——inline 子 widget 会被画在整段文字**之上**
      // （`RenderParagraph` 先画文字、再画子 widget），会盖住代码文字（§22.9）。
      // 这里只把该行（含 info string）整行隐藏：0×0 透明占位不占可见字符、不改布局，
      // 其余码元仍由下方 `hiddenFill` 补齐（偏移契约不变，BR-27.1）。
      alignment = PlaceholderAlignment.top;
      child = const SizedBox.shrink();
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
          alignment = PlaceholderAlignment.middle;
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
        case SyntaxMarkerKind.escape:
          // 纯记号：**不可见**（零宽 + 透明），整段一并用零宽文本顶替，不产生 widget。
          // `escape` 不会走到这里（上方已有显式分支：反斜杠透明 + 被转义字符按普通文本呈现）。
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
    // ⚠️ 曾试过「让规则行以**显式换行**结束」以求两态间距一致，实测**在真实编辑器里更差**，
    // 已撤回（A/B 实测：不显式断行 → 段落顶距 54.75px；显式断行 → 78.75px 且多出一行）。
    // 原因：正文 `TextField` 带 `StrutStyle(forceStrutHeight: false)`（24px 下限），满宽呈现单元
    // 之后那个真换行会把零宽补白挤成**独立的一行**（strut 下限 24px，可见空行）。
    // 详见 editor-formatting.md §15.5。
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
      // 样式带 `fontSize: 0` + `height: 0`：补白不贡献自身的行高（避免撑出多余行盒）。
      final fill =
          MarkdownEditingController.hiddenFill(text.substring(restStart, region.end));
      out.add(TextSpan(
        text: fill,
        style: base.copyWith(color: Colors.transparent, fontSize: 0, height: 0),
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
  /// 同起点区间的**占位优先级**（数值小者先占位）：整块 / 原子呈现单元优先于**记号片段**。
  ///
  /// 必需：围栏记号与底色带区间**同起点**（都是开围栏行整行），若记号先占位，底色带会被挤掉。
  static int _regionPriority(_RegionKind kind) =>
      kind == _RegionKind.marker ? 1 : 0;

  /// 收集全部**记号区间**（§13.2 / BR-23.7）。
  ///
  /// 记号 = 被 Markdown 解析为**语法**的字符；扫描由 [EditorFormat.syntaxMarkers] 统一承担
  /// （与预览同源判定：围栏内部 / 良构表格内部不扫描，缩进越界的行不建立行级前缀记号）。
  /// 结果走单条缓存（见 [_markers]），避免一次 build 里重复扫描。
  static List<_SpanRegion> _markerRegions(String text) => _markers(text)
      .map((m) => _SpanRegion(m.start, m.end, _RegionKind.marker, marker: m))
      .toList();

  /// 扫描所有 **Markdown 链接**（`[文字](网址)`，含笔记引用 `sui://note/<id>`），返回整块区间。
  ///
  /// 与附件链接（`sui://<sha256>`）同构：链接单元是**原子呈现单元**（FR-76 / BR-76.1），
  /// 故区间覆盖「`[` + 文字 + `](` + 网址 + `)`」全部字符。`sui://<sha256>` 附件引用由
  /// [EditorFormat.links] 自身排除（它另有附件单元）。仅在注入了 [formatLinkBuilder] 时建立区间。
  static List<_SpanRegion> _linkRegions(String text) => EditorFormat.links(text)
      .map((l) => _SpanRegion(l.start, l.end, _RegionKind.link, markdownLink: l))
      .toList();

  /// 围栏代码块的**块级底色带**区间：**只对开围栏行**（`[start, openLineEnd)`）建立
  /// （FR-81a / BR-81.1 / 规范 §1.4）。
  ///
  /// 为什么不是「每行一个垫底 widget」：`WidgetSpan` 在文本模型里**固定占用 1 个码元**，被它占位的
  /// 字符必须改用零宽替身补回（否则偏移契约破坏，BR-27.1）；而内容行的行首是**可见代码字符**，
  /// 一旦被占位就只能零宽呈现 → **代码字符消失**。故垫底 widget **只能锚在本来就不显示的字符上**：
  /// 开围栏行的首个 `` ` ``。宽度未知（[paragraphWidth] == 0）时**不建立**该区间。
  static List<_SpanRegion> _codeBlockBandRegions(String text) => _fences(text)
      .map((b) => _SpanRegion(b.start, b.openLineEnd, _RegionKind.codeBlockBand,
          fence: b))
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

  /// 扫描所有**快照 HTML 块**，返回其整块区间（FR-69 / §16.3）。
  ///
  /// 与表格同为**跨行原子单元**：整块折叠为一个 widget，「其余码元以零宽文本补齐」
  /// 的偏移契约由 [_regionSpans] 统一维护（BR-27.1 / BR-69.3）。
  static List<_SpanRegion> _htmlBlockRegions(String text) {
    return htmlBlocks(text)
        .where((b) => !b.isEmpty)
        .map((b) => _SpanRegion(
              b.start,
              b.end,
              _RegionKind.htmlBlock,
              html: b.html,
            ))
        .toList();
  }

  /// 扫描全部**网页原件**引用（M16 / FR-83），整行作为一个原子区间。
  static List<_SpanRegion> _webClipRegions(String text) {
    return EditorFormat.webClipRefs(text)
        .map((r) => _SpanRegion(
              r.start,
              r.end,
              _RegionKind.webClip,
              webClip: r,
            ))
        .toList();
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
enum _RegionKind {
  image,
  marker,
  attachmentLink,
  table,
  htmlBlock,
  webClip,
  link,
  codeBlockBand,
}

/// 一个「呈现单元」在正本中的字符区间。
class _SpanRegion {
  final int start;
  final int end;
  final _RegionKind kind;
  final ParsedImage? image;

  /// 仅快照 HTML 块区间有意义：该块的 HTML 原文（FR-69 / §16.3）。
  final String? html;

  /// 仅网页原件区间有意义：该引用的解析结果（M16 / FR-83）。
  final WebClipRef? webClip;

  /// 仅附件链接区间有意义：该链接型附件的解析结果（FR-46 / §12.4）。
  final AttachmentRef? attachment;

  /// 仅表格区间有意义：该 GFM 管道表块的解析结果（FR-44 / §12.1）。
  final ParsedTable? table;

  /// 仅记号区间有意义：该记号的扫描结果（§13.2 / BR-23.7）。
  final SyntaxMarker? marker;

  /// 仅链接单元区间有意义：该 Markdown 链接的解析结果（FR-76 / 规范 §1.3）。
  final MarkdownLink? markdownLink;

  /// 仅围栏代码块底色带区间有意义：该块的扫描结果（FR-81a / BR-81.1）。
  final FenceBlock? fence;

  /// 仅图片区间有意义：true 表示该引用独占一块（§5.5），应按块级呈现单元布局。
  final bool block;

  const _SpanRegion(
    this.start,
    this.end,
    this.kind, {
    this.image,
    this.attachment,
    this.table,
    this.html,
    this.webClip,
    this.marker,
    this.markdownLink,
    this.fence,
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

  static const List<double> _headingScale = [1.75, 1.5, 1.28, 1.14, 1.06, 1.0];

  /// 逐字符样式（**记号样式由 [EditorFormat.syntaxMarkers] 单一真源决定**，FR-78 渲染侧 / FR-79）。
  ///
  /// * [markers]：整篇正本的记号扫描结果（由控制器缓存后传入，避免一次 build 重复扫描）；
  /// * [codeBandActive]：true 表示围栏**内容行**改用无 `backgroundColor` 的等宽样式
  ///   （底色只由块级底色带承担，BR-81.1 / AC-436）；false 为逐字形底色的兜底路径；
  /// * [findMatches] / [activeFindIndex]：笔记内查找命中（FR-73），收尾处覆盖命中字符底色。
  static List<TextStyle> characterStyles(
    BuildContext context,
    String text,
    TextStyle base,
    TextRange composing,
    TextSelection selection, {
    List<SyntaxMarker> markers = const <SyntaxMarker>[],
    bool codeBandActive = false,
    List<FindMatch> findMatches = const <FindMatch>[],
    int activeFindIndex = -1,
  }) {
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
      // M14（FR-67 / AC-303）：代码底改**中性灰**（不再取 `surfaceContainerHighest` 的 α 叠色）。
      backgroundColor: SuiAppearance.of(context).palette.codeSurface,
    );
    // 底色带生效时的围栏**内容行**样式变体（FR-81a / AC-436）：等宽 + 前景色、**无** backgroundColor
    // ——底色只由块级底色带承担，不再逐字形染色。宽度未知（`paragraphWidth == 0`）的兜底路径
    // 仍用上面的 `code`（逐字形底色），围栏内容行仍保持等宽字体。
    final codeNoBg = base.copyWith(
      fontFamily: 'monospace',
      color: scheme.primary,
    );
    final quote = base.copyWith(
      color: scheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );
    final faint = base.copyWith(
      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
    );
    // 高亮：等价 `<mark>`（§10.2），与删除线 `~~` 是不同字符，互不混淆。
    // M14（FR-68 / AC-307）：底色改**黄色系**（亮 #FFF3A3 / 暗 #4E4400），与预览态同源；
    // 文字仍取正文前景色（不再是 `onTertiaryContainer` 的深青）。
    final highlight = base.copyWith(
      backgroundColor: SuiAppearance.of(context).palette.highlight,
      color: base.color,
    );

    final n = text.length;
    final styles = List<TextStyle>.filled(n, base);

    // setext 标题（`标题` + 下一行 `===` / `---`）行集合：该行按 h2 呈现，下划线行由记号隐藏
    // （与预览一致，§13.2 / BR-23.7）。
    final setextHeadings = _setextHeadingLines(text);

    // 底色带生效时，围栏块**内容行**的行首集合（这些行不再逐字形染色）。
    final bandedCodeLines = codeBandActive
        ? MarkdownEditingController._bandedCodeLineStarts(text)
        : const <int>{};

    // 逐行扫描；围栏代码块内不做块级 / 行内解析。
    // 行尾 `\r`（CRLF 正本）在**匹配前**剥除（FR-77 / BR-77.2）：`\r` 是行尾最后一个码元，
    // 剥除**只影响匹配、不改任何偏移**——下方区间一律由 [lineStart] / [lineEnd] 推出，
    // 故样式仍逐字符覆盖 `0..text.length`（偏移契约，BR-27.1）。
    var lineStart = 0;
    var inFence = false;
    while (lineStart <= n) {
      var lineEnd = text.indexOf('\n', lineStart);
      if (lineEnd == -1) lineEnd = n;
      final line = _stripCr(text.substring(lineStart, lineEnd));
      // 光标落在本行内 → 标记完整展开；否则高度淡化（§11.1）。
      final lineMarker =
          _lineFocused(selection, lineStart, lineEnd) ? markerActive : marker;

      if (_fenceLine.hasMatch(line)) {
        _fill(styles, lineStart, lineEnd, lineMarker);
        inFence = !inFence;
      } else if (inFence) {
        _fill(
          styles,
          lineStart,
          lineEnd,
          bandedCodeLines.contains(lineStart) ? codeNoBg : code,
        );
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
      }

      if (lineEnd >= n) break;
      lineStart = lineEnd + 1;
    }

    // 行内记号样式（FR-78 渲染侧 / FR-79）：**单一真源** = [EditorFormat.syntaxMarkers] 的成对记号。
    _inlineMarkerStyles(styles, markers, base, code, highlight, accent);

    // IME 组合区（拼音等）下划线。
    if (composing.isValid && !composing.isCollapsed) {
      final s = composing.start.clamp(0, n);
      final e = composing.end.clamp(0, n);
      final underline = base.copyWith(decoration: TextDecoration.underline);
      for (var i = s; i < e; i++) {
        styles[i] = styles[i].merge(underline);
      }
    }

    // 笔记内查找命中高亮（FR-73）——收尾处**覆盖**命中字符的底色：用 `copyWith` 只改背景 / 前景，
    // 保留正文装饰（不影响 IME 组合区下划线）。当前命中项用**更强**口径（`primary` 实底 +
    // `onPrimary` 前景），与 FR-68 的黄色高亮（`palette.highlight`）明确区分。
    if (findMatches.isNotEmpty) {
      final matchBg = scheme.secondaryContainer;
      for (var k = 0; k < findMatches.length; k++) {
        final m = findMatches[k];
        final active = k == activeFindIndex;
        final s = m.start.clamp(0, n);
        final e = m.end.clamp(0, n);
        for (var i = s; i < e; i++) {
          styles[i] = active
              ? styles[i].copyWith(
                  backgroundColor: scheme.primary,
                  color: scheme.onPrimary,
                )
              : styles[i].copyWith(backgroundColor: matchBg);
        }
      }
    }

    return styles;
  }

  /// 行尾 `\r`（CRLF 正本）在匹配前剥除（FR-77 / BR-77.2 / 规范 §1.6）。
  ///
  /// `\r` 是行尾**最后一个**码元，剥除**只影响匹配、不改任何偏移**（与 note_core 的 `_stripCr`
  /// 同口径）——所有行级匹配（标题 / 列表 / 引用 / 围栏 / 规则 / 任务项）都在剥除后的行文本上做。
  static String _stripCr(String line) =>
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line;

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

  /// 行内记号样式（FR-78 渲染侧 / FR-79 / 规范 §1.1）——**单一真源**。
  ///
  /// 消费 [EditorFormat.syntaxMarkers] 的**成对记号**（`pairId` 非空、同组恰好开 / 闭两侧、
  /// `open.end <= close.start`）→ 对**内容区间** `[open.end, close.start)` 施加对应样式；
  /// 可**叠加**（外层删除线 + 内层高亮底色等由 `TextStyle.merge` 自然复合）。
  ///
  /// 昔日此处是 note_core `_inlineMarkerRe` 的**逐字复制**（非嵌套、非转义感知），是「格式态与
  /// 预览态分裂」的根因；现改为同源消费，两态由 note_core 一处决定。记号字符本身**不上样式**
  /// ——它们由记号区间统一隐藏 / 由呈现单元接管（§13.2 / BR-23.7）。
  static void _inlineMarkerStyles(
    List<TextStyle> styles,
    List<SyntaxMarker> markers,
    TextStyle base,
    TextStyle code,
    TextStyle highlight,
    TextStyle accent,
  ) {
    final groups = <int, List<SyntaxMarker>>{};
    for (final m in markers) {
      final id = m.pairId;
      if (id == null || !_isPairedKind(m.kind)) continue;
      (groups[id] ??= <SyntaxMarker>[]).add(m);
    }
    for (final group in groups.values) {
      group.sort((a, b) => a.start.compareTo(b.start));
      if (group.length < 2) continue;
      final open = group.first;
      final close = group.last;
      if (open.end > close.start) continue;
      final style = _inlineStyleFor(open.kind, base, code, highlight, accent);
      if (style == null) continue;
      _merge(styles, open.end, close.start, style);
    }
  }

  /// 是否参与行内**成对样式**的记号种类（行级前缀 / 转义 / 围栏等不在此列）。
  static bool _isPairedKind(SyntaxMarkerKind kind) =>
      kind == SyntaxMarkerKind.strong ||
      kind == SyntaxMarkerKind.emphasis ||
      kind == SyntaxMarkerKind.strike ||
      kind == SyntaxMarkerKind.highlight ||
      kind == SyntaxMarkerKind.code ||
      kind == SyntaxMarkerKind.link;

  /// 成对记号**内容区间**的样式（`link` 取标签样式：强调色 + 下划线，与既有观感一致）。
  static TextStyle? _inlineStyleFor(
    SyntaxMarkerKind kind,
    TextStyle base,
    TextStyle code,
    TextStyle highlight,
    TextStyle accent,
  ) {
    switch (kind) {
      case SyntaxMarkerKind.strong:
        return base.copyWith(fontWeight: FontWeight.w700);
      case SyntaxMarkerKind.emphasis:
        return base.copyWith(fontStyle: FontStyle.italic);
      case SyntaxMarkerKind.strike:
        return base.copyWith(decoration: TextDecoration.lineThrough);
      case SyntaxMarkerKind.highlight:
        return highlight;
      case SyntaxMarkerKind.code:
        return code;
      case SyntaxMarkerKind.link:
        return accent.copyWith(decoration: TextDecoration.underline);
      default:
        return null;
    }
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
/// 按可用段落宽铺满（`LayoutBuilder`，无界时退回 720），故独占一行、后续文字整体下移；
/// 线为 `colorScheme.outlineVariant` 的 **1px** 细线（与预览 `<hr>` 的
/// `horizontalRuleDecoration` **同源**：同色、同 1px）。
///
/// ⚠️ **本 Widget 的高度不决定真机该行的行盒高度**（`v0.14.3` 补正实测）：正文 `TextField` 带
/// `StrutStyle.fromTextStyle(正文样式, forceStrutHeight: false)`（24px 下限，B18 为图片行而设），
/// 规则行的行盒由该下限与占位对齐共同决定（≈33px）——A/B 实测 `lineBoxHeight` 取 **17 与 20
/// 的段落顶距完全同值（54.75px）**，`middle`（当前）与 `top` 分别是 54.75 / 79.75px。
/// 因此本 Widget 只承担「线在盒内居中」的视觉职责。
///
/// **两态间距现状（待决项）**：真机格式态「段落1 → 段落2」顶距 = **54.75px**，预览态 = **37.02px**
/// （`p` 14×1.43 + `blockSpacing` 8 + `<hr>` 1px + 8），**相差 17.73px、尚未一致**；要一致需改正文
/// strut（代价：空行行高随之变小）或改预览间距（与「紧贴」诉求相反）——需产品决策，
/// 详见 editor-formatting.md **§15.5**（A/B 实测表）与 **§15.8**（已撤回的「显式换行」改法）。
class FormatRuleLine extends StatelessWidget {
  const FormatRuleLine({super.key});

  /// 呈现单元高度（px）：只决定**线在盒内居中**的视觉，不决定真机行盒（见类文档 §15.5）。
  static const double lineBoxHeight = 20;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 720.0;
        return Container(
          width: width,
          height: lineBoxHeight,
          alignment: Alignment.center,
          child: Container(
            width: double.infinity,
            height: 1,
            color: scheme.outlineVariant,
          ),
        );
      },
    );
  }
}
