import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import 'markdown_editing_controller.dart';

/// 编辑器三态：格式（默认，所见即所得的 Markdown 渲染编辑）、源码（纯 Markdown
/// 文本）、预览（只读渲染）。
///
/// 三种模式共用**同一个正本**：`MarkdownEditingController.text` 自始至终是标准
/// Markdown。模式只决定「怎么画 / 能不能改」，不做任何格式转换，因此来回切换
/// 无损、可往返（ADR-006 / BR-23.1）。Adapter 已是 note_core 的 persistence
/// （canonical=Markdown），这里无需任何转换层。
enum EditorMode { formatted, source, preview }

/// Markdown 编辑器：把三态的差异收敛在极薄的一层，正本仍在 `note_core` 之上。
class MarkdownEditor extends StatelessWidget {
  const MarkdownEditor({
    super.key,
    required this.controller,
    required this.mode,
    required this.onChanged,
    this.imageBuilder,
    this.undoController,
    this.focusNode,
    this.onBlockNewline,
    this.onSoftNewline,
    this.onStructuralDelete,
    this.showCursor = true,
  });

  /// 正文控制器；其 `text` 是唯一的 Markdown 正本。
  final MarkdownEditingController controller;
  final EditorMode mode;
  final VoidCallback onChanged;

  /// 预览模式的图片渲染钩子（用于 `sui://<sha256>` 这类附件引用）。
  final MarkdownSizedImageBuilder? imageBuilder;

  /// 供外部（格式工具栏）触发撤销 / 重做的共享控制器。
  final UndoHistoryController? undoController;

  /// 编辑态共用的焦点节点；工具栏执行指令后据此把焦点交还正文。
  final FocusNode? focusNode;

  /// 格式模式下回车键的拦截钩子：返回 true 表示已就地处理（块级空块交互，
  /// §11.2 / BR-32.4），返回 false 表示交由默认换行；null 表示不拦截。
  final bool Function()? onBlockNewline;

  /// 格式模式下 Shift+Enter（软换行）的拦截钩子：返回 true 表示已就地处理
  /// （如表格单元格内插入 `<br>`），返回 false 表示交由默认行为；null 表示不拦截。
  final bool Function()? onSoftNewline;

  /// 格式模式下退格 / 删除键的拦截钩子（FR-46 / FR-44 / §12.4 / §12.1.1）：返回 true 表示
  /// 已就地处理——整块删除附件引用、修复残缺引用，或**整块删除表格**（表格边界删除）；
  /// 返回 false 表示交由默认逐字符删除；null 表示不拦截。
  /// [backspace] 为 true 表示退格键，false 表示 Delete 键。
  final bool Function({required bool backspace})? onStructuralDelete;

  /// 是否显示正文光标。格式模式下光标落在嵌套的表格单元格内时（单元格是正文
  /// 焦点节点的子树），正文仍会因 `hasFocus` 而画出自己的光标，造成「两个光标」；
  /// 由上层据此置 false 隐藏正文光标。
  final bool showCursor;

  @override
  Widget build(BuildContext context) {
    if (mode == EditorMode.preview) {
      return MarkdownPreview(text: controller.text, imageBuilder: imageBuilder);
    }
    // 格式模式渲染富样式，源码模式渲染纯文本。`styled` 是普通字段而非通知型
    // 状态，这里同步写入不会触发「build 期间 setState」断言；EditableText 每次
    // 重建都会重新调用 controller.buildTextSpan，故模式切换即时生效。
    controller.styled = mode == EditorMode.formatted;
    return _SourceEditor(
      controller: controller,
      monospace: mode == EditorMode.source,
      onChanged: onChanged,
      undoController: undoController,
      focusNode: focusNode,
      onBlockNewline: onBlockNewline,
      onSoftNewline: onSoftNewline,
      onStructuralDelete: onStructuralDelete,
      showCursor: showCursor,
    );
  }
}

/// 可直接编辑的正文区（格式 / 源码共用）：[monospace] 决定是否用等宽字体。
class _SourceEditor extends StatefulWidget {
  const _SourceEditor({
    required this.controller,
    required this.monospace,
    required this.onChanged,
    this.undoController,
    this.focusNode,
    this.onBlockNewline,
    this.onSoftNewline,
    this.onStructuralDelete,
    this.showCursor = true,
  });

  final MarkdownEditingController controller;
  final bool monospace;
  final VoidCallback onChanged;
  final UndoHistoryController? undoController;
  final FocusNode? focusNode;
  final bool Function()? onBlockNewline;
  final bool Function()? onSoftNewline;
  final bool Function({required bool backspace})? onStructuralDelete;
  final bool showCursor;

  @override
  State<_SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<_SourceEditor> {
  FocusNode? _internalFocus;
  Timer? _debounce;

  /// 正文自身滚动的控制器：`TextField(expands: true)` 内部滚动，配 [Scrollbar]
  /// 让长文有可见滚动条，便于把光标移到视口下方继续编辑（B13）。
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) _internalFocus = FocusNode();
  }

  FocusNode get _focus => widget.focusNode ?? _internalFocus!;

  /// 正文基础样式：源码模式用等宽字体，格式模式用正文字体；两者都取 1.6 倍行距。
  /// 抽成 getter 是为了让 [TextField.style] 与 [TextField.strutStyle] 共用同一份
  /// 样式定义（见 [_buildField] 中关于 B18 的说明）。
  TextStyle get _textStyle => widget.monospace
      ? const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.6)
      : const TextStyle(fontSize: 15, height: 1.6);

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _internalFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _wrapKeys(_buildField(scheme)),
      ),
    );
  }

  Widget _buildField(ColorScheme scheme) {
    // 不要套 SingleChildScrollView：它给子节点的高度约束是无界的，而
    // `expands: true` 要求有界高度，两者相遇会在 layout 阶段断言失败
    // （_RenderDecoration given an infinite size）。父级是 Expanded，
    // 高度本来就有限，让 TextField 自己撑满并内部滚动即可。
    // 外层再套 Scrollbar（与 TextField 共用同一个 scrollController）：长文有
    // 可见滚动条，便于把光标移到视口下方继续编辑（B13）。
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        scrollController: _scroll,
        // 交给上层的撤销栈控制器，工具栏的撤销 / 重做按钮据此驱动。
        undoController: widget.undoController,
        // 撑满编辑区高度，滚动交给 TextField 自己处理。
        expands: true,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        // 光标落在嵌套表格单元格内时（单元格是正文焦点节点的子树），正文仍会因
        // `hasFocus` 而画自己的光标；置 false 隐藏正文光标，避免「两个光标」。
        showCursor: widget.showCursor,
        style: _textStyle,
        // [EditableText] 的默认 strutStyle 是
        // `StrutStyle.fromTextStyle(style, forceStrutHeight: true)`，会把**每一行**都强制
        // 成固定行高，从而忽略行内 [WidgetSpan] 的实际高度：块级图片会溢出自己那一行、
        // 压住下方文字，光标也落不到图片下面（B18）。显式关闭 forceStrutHeight，含图片
        // 的行即可按图片高度撑开，后续文字整体下移（§5.5 / AC-74）。
        // 普通文字行高仍由 1.6 倍行距的 strut 决定，观感不变。
        strutStyle: StrutStyle.fromTextStyle(_textStyle, forceStrutHeight: false),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: widget.monospace
              ? '# 标题\n\n在这里用 Markdown 书写…\n- 列表项\n- 加粗 **重要**'
              : '开始书写，或用上方工具栏排版…',
          hintStyle: TextStyle(color: scheme.outline.withValues(alpha: 0.6)),
        ),
        onChanged: (_) => _scheduleSave(),
        // 点击正文时强制把主焦点交还正文输入框，而不是停留在嵌套的表格单元格内：
        // 单元格是 _focus 的焦点子树，会让 EditableText 误以为「已聚焦」从而跳过
        // requestFocus，造成「光标卡在表格里出不来」。显式 requestFocus 打破该误判。
        onTap: () => _focus.requestFocus(),
      ),
    );
  }

  /// 格式模式下拦截若干「结构键」：回车先经块级空块交互；退格 / 删除落在附件引用
  /// 边界时整块删除或就地修复残缺引用（§11.2 / §12.4）。未处理则交默认文本编辑。
  ///
  /// 用 [Focus]（而非 [KeyboardListener]）才能返回 [KeyEventResult.handled] 以
  /// 抑制默认行为；`canRequestFocus: false` 使其只作为键事件冒泡的中间节点，不
  /// 额外占用 Tab 焦点。仅在提供任一钩子（仅格式模式）时启用。
  Widget _wrapKeys(Widget child) {
    final newline = widget.onBlockNewline;
    final softNewline = widget.onSoftNewline;
    final del = widget.onStructuralDelete;
    if (newline == null && softNewline == null && del == null) return child;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        final isEnter = key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter;
        final isShift = HardwareKeyboard.instance.isShiftPressed;
        if (isEnter && isShift && softNewline != null) {
          return softNewline()
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        }
        if (isEnter && !isShift && newline != null) {
          return newline() ? KeyEventResult.handled : KeyEventResult.ignored;
        }
        if (del != null && key == LogicalKeyboardKey.backspace) {
          return del(backspace: true)
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        }
        if (del != null && key == LogicalKeyboardKey.delete) {
          return del(backspace: false)
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }

  void _scheduleSave() {
    _debounce?.cancel();
    // 轻量防抖：停止输入 400ms 后持久化，避免每条 keystroke 都写库。
    _debounce = Timer(const Duration(milliseconds: 400), () {
      widget.onChanged();
    });
  }
}

/// Markdown 预览：flutter_markdown 渲染。
///
/// 任务列表勾选框由 GFM 语法原生渲染；`==高亮==` 是本次新增的扩展语法，需
/// 自带行内解析与元素构建器，方能在预览态同样呈现为高亮（BR-31.5 / §10.2）。
/// 行内软换行 `<br>`（表格单元格的格内换行写法，见 [EditorFormat.tableSoftNewline]）
/// 亦由本类自注册行内语法解析为 **`br` 元素**，交回 flutter_markdown 原生换行分支
/// ——否则 `markdown` 的 `InlineHtmlSyntax` 会把它当**普通文本透传**，预览里露出字面量
/// `<br>`（§12.1.3「⑪」）。
class MarkdownPreview extends StatelessWidget {
  const MarkdownPreview({super.key, required this.text, this.imageBuilder});
  final String text;
  final MarkdownSizedImageBuilder? imageBuilder;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 720),
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.all(16),
      child: Markdown(
        data: text,
        selectable: true,
        sizedImageBuilder: imageBuilder,
        // 与默认 GFM 扩展集叠加（markdown 的 `Document` 会把二者并入同一个**插入序**集合，
        // 且**先加入本参数**——故这里的语法总是**先于**扩展集里的 `InlineHtmlSyntax` 命中）。
        inlineSyntaxes: <md.InlineSyntax>[_HighlightSyntax(), _LineBreakSyntax()],
        builders: <String, MarkdownElementBuilder>{
          'mark': _HighlightBuilder(),
        },
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
      ),
    );
  }
}

/// 预览态行内软换行 `<br>`（含 `<br/>` / `<br />`）的行内语法（§12.1.3「⑪」）。
///
/// 背景：`markdown` 7.3.1 的 `InlineHtmlSyntax` **继承 `TextSyntax` 且替换文本为空**，
/// 命中后走「无替换即 `advanceBy`」分支——把标签**原文并回文本缓冲当普通文本**，
/// 既不产出 HTML 元素也不丢弃。于是 flutter_markdown 里
/// `tag == 'br'` → `RichText('\n')` 的**原生换行分支永远不可达**，预览只能露出字面量 `<br>`。
///
/// 本语法把 `<br>` 还原为 **`br` 元素**（`Element.empty`），换行交回 flutter_markdown
/// 原生分支处理（表格单元格内经 `_mergeInlineChildren` 并入该格 RichText，即格内真实换行）；
/// **正本一字不改**（`<br>` 仍是格内换行的唯一写法，守 BR-44.2 / BR-23.1）。
class _LineBreakSyntax extends md.InlineSyntax {
  _LineBreakSyntax()
      : super(r'<br\s*/?>', startCharacter: 0x3C, caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}

/// 预览态 `==高亮==` 的行内语法：与格式模式同源（§10.2）——成对 `==` 且内容非空
/// 才识别；`==` 与删除线 `~~` 是不同字符互不混淆；落单 / 单个 `=` 原样透传。
class _HighlightSyntax extends md.InlineSyntax {
  _HighlightSyntax() : super(r'==([^=\n]+)==', startCharacter: 0x3D);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    // 内容按纯文本承载、不做嵌套解析：与格式模式一致，嵌套 / 跨行视为未识别。
    parser.addNode(md.Element.text('mark', match.group(1)!));
    return true;
  }
}

/// 把 `mark` 元素渲染为高亮底色（等价 `<mark>`，§10.2）。
class _HighlightBuilder extends MarkdownElementBuilder {
  _HighlightBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        text: element.textContent,
        style: (parentStyle ?? const TextStyle()).copyWith(
          backgroundColor: scheme.tertiaryContainer,
          color: scheme.onTertiaryContainer,
        ),
      ),
    );
  }
}
