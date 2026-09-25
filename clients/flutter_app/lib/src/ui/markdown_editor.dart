import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// Markdown 双轨编辑器：源码模式直接编辑 Markdown，预览模式渲染所见所得。
/// Adapter 已是 note_core 的 persistence（canonical=Markdown），无需转换层。
class MarkdownEditor extends StatelessWidget {
  const MarkdownEditor({
    super.key,
    required this.controller,
    required this.preview,
    required this.onChanged,
    this.imageBuilder,
  });

  final TextEditingController controller;
  final bool preview;
  final VoidCallback onChanged;

  /// 预览模式的图片渲染钩子（用于 `sui://<sha256>` 这类附件引用）。
  final MarkdownSizedImageBuilder? imageBuilder;

  @override
  Widget build(BuildContext context) {
    if (preview) {
      return MarkdownPreview(text: controller.text, imageBuilder: imageBuilder);
    }
    return _SourceEditor(controller: controller, onChanged: onChanged);
  }
}

/// 源码编辑器：等宽字体，支持代码块高亮感知的朴素排版。
class _SourceEditor extends StatefulWidget {
  const _SourceEditor({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  State<_SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<_SourceEditor> {
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: TextField(
            controller: widget.controller,
            focusNode: _focus,
            // Auto-grow: 以内容高度承载，避免滚动条噪。
            expands: true,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.6,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText:
                  '# 标题\n\n在这里用 Markdown 书写…\n- 列表项\n- 加粗 **重要**',
              hintStyle:
                  TextStyle(color: scheme.outline.withValues(alpha: 0.6)),
            ),
            onChanged: (_) => _scheduleSave(),
          ),
        ),
      ),
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
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
      ),
    );
  }
}