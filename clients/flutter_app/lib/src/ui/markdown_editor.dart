import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:note_core/note_core.dart';

import '../platform/url_opener.dart';
import 'appearance/app_palette.dart';
import 'code_block_band_painter.dart';
import 'markdown_editing_controller.dart';
import 'markdown_input_formatter.dart';
import 'snapshot_html_view.dart';

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
    this.linkOpener,
    this.noteRefOpener,
    this.htmlImageBuilder,
    this.webClipBuilder,
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

  /// 预览态打开外部链接的接缝（FR-70）：缺省走 [openExternalUrl]（系统默认浏览器 /
  /// 浏览器新标签页）；注入后 widget 测试可断言「点链接确实发起了打开」而不真的
  /// 拉起浏览器（AC-349）。
  final Future<bool> Function(String url)? linkOpener;

  /// 预览态**笔记引用**（`sui://note/<笔记ID>`）的跳转接缝（M15 / FR-75）。
  ///
  /// 与普通链接**分开**的理由：笔记引用不是外部协议（不在 [isOpenableUrl] 白名单里），
  /// 它要在**笔记库内**跳转（桌面端开 / 聚焦独立窗口，移动与 Web 在当前窗口内切换）。
  /// 未注入时只提示、**不触碰正本**（BR-75.3 / BR-70.4）。
  final Future<void> Function(String noteId)? noteRefOpener;

  /// **快照 HTML 块**里 `sui://<sha256>` 图片的构建器（FR-69）：与正文 / 预览同源的附件组件。
  final SnapshotHtmlImageBuilder? htmlImageBuilder;

  /// 预览态**网页原件**（M16 / FR-83）的构建器；未注入时引用按普通 Markdown 链接呈现。
  final FormatWebClipSpanBuilder? webClipBuilder;

  @override
  Widget build(BuildContext context) {
    if (mode == EditorMode.preview) {
      return MarkdownPreview(
        text: controller.text,
        imageBuilder: imageBuilder,
        linkOpener: linkOpener,
        noteRefOpener: noteRefOpener,
        htmlImageBuilder: htmlImageBuilder,
        webClipBuilder: webClipBuilder,
      );
    }
    // 格式模式渲染富样式，源码模式渲染纯文本。`styled` 是普通字段而非通知型
    // 状态，这里同步写入不会触发「build 期间 setState」断言；EditableText 每次
    // 重建都会重新调用 controller.buildTextSpan，故模式切换即时生效。
    controller.styled = mode == EditorMode.formatted;
    return _SourceEditor(
      controller: controller,
      monospace: mode == EditorMode.source,
      // FR-78 / BR-78.1：**只**在格式模式挂「语法字符自动转义」格式化器。源码模式所见即正本
      // （FR-77），**不挂任何 formatter**——否则用户按最原始字符输入会被悄悄改写。
      inputFormatters: mode == EditorMode.formatted
          ? const <TextInputFormatter>[MarkdownSyntaxEscapeFormatter()]
          : const <TextInputFormatter>[],
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
    this.inputFormatters = const <TextInputFormatter>[],
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

  /// **写入接缝**上的输入格式化器（FR-78 / BR-78.1）：格式模式 = 语法字符自动转义
  /// （[MarkdownSyntaxEscapeFormatter]）；源码模式 = 空列表（所见即正本）。
  final List<TextInputFormatter> inputFormatters;

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

  /// 正文 `TextField` 的键：`CodeBlockBandPainter` 据此在元素树里找到 `RenderEditable`，
  /// 取围栏块的行几何（FR-81a / FR-94）。
  final GlobalKey _fieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) _internalFocus = FocusNode();
  }

  FocusNode get _focus => widget.focusNode ?? _internalFocus!;

  /// 正文基础样式：源码模式恒为**等宽**，格式模式用**笔记正文字体**（M14 / FR-65 / BR-65.2）；
  /// 两者都取 1.6 倍行距。
  ///
  /// 抽成方法（而非 getter）是为了让 [TextField.style] 与 [TextField.strutStyle] 共用同一份
  /// 样式定义（见 [_buildField] 中关于 B18 的说明），同时把 [SuiAppearance] 里的正文字体带进来。
  TextStyle _textStyleFor(SuiAppearance appearance) => widget.monospace
      ? const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.6)
      : appearance.applyBodyFont(const TextStyle(fontSize: 15, height: 1.6));

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
    final appearance = SuiAppearance.of(context);
    return Container(
      // M14（FR-67 / AC-301）：编辑区底色 = **纯白**（暗色为中性深灰）。
      // 旧实现取 `surfaceContainerHighest` 的 40% 叠色（实测 #F2F4F1）带绿调，
      // 与 FR-28「中栏 / 右栏白底」冲突——这是**一致性修复**，不是新规格。
      color: appearance.palette.surface,
      // FR-93 / FR-94：编辑区**裁剪**（带不得越界）+ 底色带绘制在 `TextField` **背后**。
      // `RenderParagraph` 先画整段文字、再画 inline 子 widget，所以带绝不能靠 inline
      // 占位 widget 画——那样会盖住代码文字（§22.9）。
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CustomPaint(
              key: kCodeBlockBandPainterKey,
              painter: CodeBlockBandPainter(
                controller: widget.controller,
                fieldKey: _fieldKey,
                inset: kEditorBodyPadding,
                enabled: !widget.monospace,
                surface: appearance.palette.codeSurface,
                border: appearance.palette.codeBorder,
                textStyle: _textStyleFor(appearance),
                textScaler: MediaQuery.textScalerOf(context),
                repaint: Listenable.merge(<Listenable>[
                  widget.controller,
                  _scroll,
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(kEditorBodyPadding),
              child: _wrapKeys(_buildField(scheme, appearance)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(ColorScheme scheme, SuiAppearance appearance) {
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
        key: _fieldKey,
        controller: widget.controller,
        focusNode: _focus,
        scrollController: _scroll,
        // FR-78 / BR-78.1：格式模式下**键入**语法字符即转义落正本；IME 组合期、粘贴、
        // 删除与程序化写入一律原样放行（判定全在 formatter 内）。
        inputFormatters: widget.inputFormatters,
        // 交给上层的撤销栈控制器，工具栏的撤销 / 重做按钮据此驱动。
        undoController: widget.undoController,
        // 撑满编辑区高度，滚动交给 TextField 自己处理。
        expands: true,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        // 光标落在嵌套表格单元格内时（单元格是正文焦点节点的子树），正文仍会因
        // `hasFocus` 而画自己的光标；置 false 隐藏正文光标，避免「两个光标」。
        showCursor: widget.showCursor,
        style: _textStyleFor(appearance),
        // [EditableText] 的默认 strutStyle 是
        // `StrutStyle.fromTextStyle(style, forceStrutHeight: true)`，会把**每一行**都强制
        // 成固定行高，从而忽略行内 [WidgetSpan] 的实际高度：块级图片会溢出自己那一行、
        // 压住下方文字，光标也落不到图片下面（B18）。显式关闭 forceStrutHeight，含图片
        // 的行即可按图片高度撑开，后续文字整体下移（§5.5 / AC-74）。
        // 普通文字行高仍由 1.6 倍行距的 strut 决定，观感不变。
        strutStyle: StrutStyle.fromTextStyle(_textStyleFor(appearance),
            forceStrutHeight: false),
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
  const MarkdownPreview({
    super.key,
    required this.text,
    this.imageBuilder,
    this.linkOpener,
    this.noteRefOpener,
    this.htmlImageBuilder,
    this.webClipBuilder,
  });
  final String text;
  final MarkdownSizedImageBuilder? imageBuilder;

  /// 打开外部链接的接缝（默认 [openExternalUrl]）；见 [MarkdownEditor.linkOpener]。
  final Future<bool> Function(String url)? linkOpener;

  /// 笔记引用（`sui://note/<id>`）的跳转接缝（FR-75）；见 [MarkdownEditor.noteRefOpener]。
  final Future<void> Function(String noteId)? noteRefOpener;

  /// 快照 HTML 块里 `sui://` 图片的构建器；见 [MarkdownEditor.htmlImageBuilder]。
  final SnapshotHtmlImageBuilder? htmlImageBuilder;

  /// 网页原件构建器；见 [MarkdownEditor.webClipBuilder]。
  final FormatWebClipSpanBuilder? webClipBuilder;

  /// 点按 Markdown 链接 / 裸网址：交**系统默认浏览器**打开（FR-70）。
  ///
  /// - 协议不在白名单（`javascript:` / `data:` / `file:` …）→ 只提示、**绝不打开**（BR-70.2）；
  /// - 打开失败 → 提示「未能打开链接」，正本与编辑器状态一字不动（BR-70.4）。
  Future<void> _openLink(BuildContext context, String? href) async {
    final url = (href ?? '').trim();
    if (url.isEmpty) return;
    // FR-75 / BR-75.1：**笔记引用先分流**。它是标准 Markdown 链接，但不是外部协议
    // （`isOpenableUrl('sui://…')` 恒为 false），必须在白名单判定**之前**接走，否则会被
    // 当成「不支持的协议」拒掉——而那正是用户要点的跳转。
    final refId = EditorFormat.noteRefId(url);
    if (refId != null) {
      final opener = noteRefOpener;
      if (opener == null) {
        _notify(context, '笔记不存在或尚未同步');
        return;
      }
      await opener(refId);
      return;
    }
    if (!isOpenableUrl(url)) {
      _notify(context, '不支持的链接协议：$url');
      return;
    }
    final ok = await (linkOpener ?? openExternalUrl)(url);
    if (!ok && context.mounted) _notify(context, '未能打开链接：$url');
  }

  void _notify(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 720),
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.all(16),
      child: (htmlBlocks(text).isEmpty &&
              EditorFormat.webClipRefs(text).isEmpty)
          // 没有 HTML 块 / 网页原件（绝大多数笔记，含历史快照）：沿用既有的**单个滚动
          // Markdown**，观感与行为一字不变（零回归面）。
          ? _markdown(context, text)
          // 有特殊块：切成「Markdown 段 + 受限 HTML 块 + 网页原件」按正本顺序混排。
          // 外层用一个滚动容器、段内改用**非滚动**的 `MarkdownBody`——`Markdown` 自带
          // ListView，直接嵌进 Column 会拿到无界高度而报错。
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: _segments(context),
              ),
            ),
    );
  }

  /// 把正文切成「Markdown 段」与「快照 HTML 块」交替的组件序列（FR-69 / §16.3）。
  ///
  /// 为什么必须切：`markdown` 包把**块级 HTML 当普通文本透传**
  /// （`HtmlBlockSyntax.parse` 直接返回 `Text`），不切就会在预览里露出 `<div style=…>`
  /// 原文；切开后 Markdown 段落仍由 flutter_markdown 渲染，HTML 块交给受限渲染器
  /// [SnapshotHtmlView]，两者按正本顺序混排（BR-69.1 / BR-69.3）。
  List<Widget> _segments(BuildContext context) {
    // 事件 = 快照 HTML 块 / 网页原件；按起点排序后与 Markdown 段交替混排。
    final events = <({int start, int end, HtmlBlock? html, WebClipRef? ref})>[
      for (final b in htmlBlocks(text))
        (start: b.start, end: b.end, html: b, ref: null),
      for (final r in EditorFormat.webClipRefs(text))
        (start: r.start, end: r.end, html: null, ref: r),
    ]..sort((a, b) => a.start.compareTo(b.start));

    final out = <Widget>[];
    var cursor = 0;
    for (final event in events) {
      if (event.start < cursor) continue;
      if (event.start > cursor) {
        out.add(_markdownBody(context, text.substring(cursor, event.start)));
      }
      final block = event.html;
      if (block != null) {
        out.add(SnapshotHtmlView(
          html: block.html,
          suiImageBuilder: htmlImageBuilder,
          onOpenLink: (href) => _openLink(context, href),
        ));
        cursor = block.end < text.length ? block.end + 1 : block.end;
      } else {
        final ref = event.ref!;
        final builder = webClipBuilder;
        if (builder != null) {
          out.add(builder(context, ref));
        } else {
          out.add(_markdownBody(context, text.substring(ref.start, ref.end)));
        }
        // 整行单元：吞掉该行行尾换行，避免多出一个空段。
        final nl = text.indexOf('\n', ref.end);
        cursor = nl == -1 ? text.length : nl + 1;
      }
    }
    if (cursor < text.length) {
      out.add(_markdownBody(context, text.substring(cursor)));
    }
    if (out.isEmpty) out.add(_markdownBody(context, text));
    return out;
  }

  /// 单个**滚动** Markdown（正文里没有 HTML 块时的常规预览路径：沿用既有渲染，
  /// 观感与行为零变化）。
  Widget _markdown(BuildContext context, String data) {
    return Markdown(
      data: data,
      selectable: true,
      sizedImageBuilder: imageBuilder,
      onTapLink: (label, href, title) => _openLink(context, href),
      inlineSyntaxes: <md.InlineSyntax>[_HighlightSyntax(), _LineBreakSyntax()],
      builders: <String, MarkdownElementBuilder>{
        'mark': _HighlightBuilder(),
        'a': _PreviewLinkBuilder(onOpen: (href) => _openLink(context, href)),
      },
      styleSheet: _previewStyleSheet(context),
    );
  }

  /// 混排容器里的**非滚动** Markdown 段（`MarkdownBody` 与 `Markdown` 同一套参数，
  /// 只是不自带滚动视图，可安全嵌进外层滚动容器）。
  Widget _markdownBody(BuildContext context, String data) {
    return MarkdownBody(
      data: data,
      selectable: true,
      sizedImageBuilder: imageBuilder,
        // FR-70：链接与裸网址点按即打开。此前未传 `onTapLink`，而 flutter_markdown
        // 0.7.7 的 `createLink` 回调里判 `onTapLink != null` —— 于是链接看着像链接
        // （蓝色 + 下划线），点开却毫无反应。
        onTapLink: (label, href, title) => _openLink(context, href),
        // 与默认 GFM 扩展集叠加（markdown 的 `Document` 会把二者并入同一个**插入序**集合，
        // 且**先加入本参数**——故这里的语法总是**先于**扩展集里的 `InlineHtmlSyntax` 命中）。
        inlineSyntaxes: <md.InlineSyntax>[_HighlightSyntax(), _LineBreakSyntax()],
        builders: <String, MarkdownElementBuilder>{
          'mark': _HighlightBuilder(),
          // FR-70：链接渲染为**真 widget**（WidgetSpan）——理由见 [_PreviewLinkBuilder]。
          'a': _PreviewLinkBuilder(onOpen: (href) => _openLink(context, href)),
        },
      // M14（FR-65 / FR-67 / FR-68）：预览与格式模式**同源**——笔记正文字体一致、
      // 代码块与引用块用中性灰、高亮同色系（不出现「格式黄 / 预览青」这类分裂）。
      styleSheet: _previewStyleSheet(context),
    );
  }
}

/// 预览态样式表：在主题默认值之上套用**笔记正文字体**、**中性灰块底**与**黄色高亮**
/// （M14 / FR-65 / FR-67 / FR-68）。
///
/// 只做 family / 颜色覆写，**不改**构建器与行内语法（`mark` / `<br>` 等 M5 / M9 能力不回归）。
MarkdownStyleSheet _previewStyleSheet(BuildContext context) {
  final appearance = SuiAppearance.of(context);
  final palette = appearance.palette;
  final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
  final body = appearance.bodyFontFamily;
  TextStyle? withBody(TextStyle? style) => (style == null || body == null)
      ? style
      : style.copyWith(fontFamily: body);
  return base.copyWith(
    p: withBody(base.p),
    h1: withBody(base.h1),
    h2: withBody(base.h2),
    h3: withBody(base.h3),
    h4: withBody(base.h4),
    h5: withBody(base.h5),
    h6: withBody(base.h6),
    listBullet: withBody(base.listBullet),
    blockquote: withBody(base.blockquote),
    // 代码块 / 行内代码：中性灰底 + 灰边框（无绿调，FR-67 / AC-303 / AC-305）。
    code: (base.code ?? const TextStyle()).copyWith(
      backgroundColor: palette.codeSurface,
      fontFamily: 'monospace',
    ),
    codeblockDecoration: BoxDecoration(
      color: palette.codeSurface,
      border: Border.all(color: palette.codeBorder),
      borderRadius: BorderRadius.circular(6),
    ),
    blockquoteDecoration: BoxDecoration(
      color: palette.container,
      border: Border(
        left: BorderSide(color: palette.outlineVariant, width: 4),
      ),
    ),
    // 分割线（`<hr>`）：**1px `outlineVariant` 上边框**——与格式模式的 `FormatRuleLine`
    // （同为 `outlineVariant` 的 **1px** 细线）**线色 / 线宽同源**（BR-23.7 / AC-321）。
    // ⚠️ 两态**段落间距目前不一致**（真机格式态 54.75px vs 预览 37.02px，差 17.73px）：格式态该行
    // 行盒由正文 `StrutStyle` 的 24px 下限决定，压小呈现单元无效；已登记为**待决设计项**，
    // 详见 editor-formatting.md §15.5（A/B 实测表）与 §15.8（已撤回的改法）。
    horizontalRuleDecoration: BoxDecoration(
      border: Border(
        top: BorderSide(
          width: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    )
  );
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

/// 预览态的**链接呈现单元**（FR-70 / editor-formatting.md §16.1）。
///
/// ## 为什么不能只传 `onTapLink`
///
/// 预览是 `selectable: true`，flutter_markdown 于是走 `SelectableText.rich` →
/// `EditableText`；而 `RenderEditable.handleEvent` **只给自身的选择手势 `addPointer`**
/// （`flutter/lib/src/rendering/editable.dart`），**从不驱动 `TextSpan.recognizer`**
/// —— 实测：传了 `onTapLink`，链接照样点不开（这正是用户报的「按链接渲染了、点不开」）。
///
/// ## 做法
///
/// 把 `a` 渲染为 **WidgetSpan（真 widget）**：点击走 widget 自己的 `GestureDetector`，
/// 完全不依赖文本手势；文字样式沿用 flutter_markdown 给的链接样式（链接色 / 下划线）。
/// 与既有 `mark`（高亮）走同一条 builder 路径，改动最薄、不波及可选中复制与别处渲染。
///
/// **图片链接**（`[![](img)](url)`）返回 null 交回默认实现，否则图片本体会被吃掉。
class _PreviewLinkBuilder extends MarkdownElementBuilder {
  _PreviewLinkBuilder({required this.onOpen});

  /// 点击链接：把地址交给上层（协议白名单与失败提示都在上层）。
  final void Function(String href) onOpen;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final hasImage =
        element.children?.any((c) => c is md.Element && c.tag == 'img') ?? false;
    if (hasImage) return null;
    final href = (element.attributes['href'] ?? '').trim();
    final style = preferredStyle ?? parentStyle ?? const TextStyle();
    return GestureDetector(
      onTap: href.isEmpty ? null : () => onOpen(href),
      child: MouseRegion(
        // FR-76：笔记引用同样是**可点**的链接（手型光标），只是打开方式不同（库内跳转）。
        cursor:
            isOpenableUrl(href) || EditorFormat.noteRefId(href) != null
                ? SystemMouseCursors.click
                : MouseCursor.defer,
        child: Text(element.textContent, style: style),
      ),
    );
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
    // M14（FR-68 / AC-308）：与格式模式**同源**取色——黄色系（亮 #FFF3A3 / 暗 #4E4400）；
    // 文字沿用正文前景色，不再取 `onTertiaryContainer` 的深青。
    final base = parentStyle ?? const TextStyle();
    return Text.rich(
      TextSpan(
        text: element.textContent,
        style: base.copyWith(
          backgroundColor: SuiAppearance.of(context).palette.highlight,
        ),
      ),
    );
  }
}
