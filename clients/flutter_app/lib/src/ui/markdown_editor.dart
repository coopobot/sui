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
  });

  final MarkdownEditingController controller;
  final bool monospace;
  final VoidCallback onChanged;
  final UndoHistoryController? undoController;
  final FocusNode? focusNode;
  final bool Function()? onBlockNewline;

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
        child: _withBlockNewline(_buildField(scheme)),
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
        style: widget.monospace
            ? const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                height: 1.6,
              )
            : const TextStyle(fontSize: 15, height: 1.6),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: widget.monospace
              ? '# 标题\n\n在这里用 Markdown 书写…\n- 列表项\n- 加粗 **重要**'
              : '开始书写，或用上方工具栏排版…',
          hintStyle: TextStyle(color: scheme.outline.withValues(alpha: 0.6)),
        ),
        onChanged: (_) => _scheduleSave(),
      ),
    );
  }

  /// 格式模式：回车（含小键盘回车）先经块级空块交互处理，未处理则交默认换行。
  ///
  /// 用 [Focus]（而非 [KeyboardListener]）才能返回 [KeyEventResult.handled] 以
  /// 抑制默认换行；`canRequestFocus: false` 使其只作为键事件冒泡的中间节点，不
  /// 额外占用 Tab 焦点。仅在提供 [widget.onBlockNewline] 时启用（仅格式模式）。
  Widget _withBlockNewline(Widget child) {
    final handler = widget.onBlockNewline;
    if (handler == null) return child;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter;
        if (event is KeyDownEvent && isEnter) {
          return handler() ? KeyEventResult.handled : KeyEventResult.ignored;
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
        // 与默认 GFM 扩展集叠加（markdown 的 Document 会将二者合并）。
        inlineSyntaxes: <md.InlineSyntax>[_HighlightSyntax()],
        builders: <String, MarkdownElementBuilder>{
          'mark': _HighlightBuilder(),
        },
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
      ),
    );
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
