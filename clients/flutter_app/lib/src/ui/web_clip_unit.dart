// M16 / FR-83：笔记里的网页原件呈现单元（预览 / 格式两态）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

import 'web_clip_view.dart';

/// 预览态：顶部工具条 + 内嵌网页（固定高度、可滚动、可全屏）。
class WebClipPreviewUnit extends StatefulWidget {
  const WebClipPreviewUnit({
    super.key,
    required this.ref,
    required this.htmlLoader,
    this.title,
    this.imageResolver,
  });

  final WebClipRef ref;
  final WebClipHtmlLoader htmlLoader;
  final String? title;
  final WebClipImageResolver? imageResolver;

  @override
  State<WebClipPreviewUnit> createState() => _WebClipPreviewUnitState();
}

class _WebClipPreviewUnitState extends State<WebClipPreviewUnit> {
  String? _html;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final html = await widget.htmlLoader(widget.ref.sha256);
    if (!mounted) return;
    setState(() {
      _html = html;
      _loading = false;
    });
  }

  Future<void> _openFullScreen() async {
    final html = _html ?? await widget.htmlLoader(widget.ref.sha256);
    if (html == null || !mounted) return;
    await showWebClipViewer(
      context,
      title: widget.title ?? '网页原件',
      html: html,
      imageResolver: widget.imageResolver,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = (MediaQuery.sizeOf(context).height * 0.6).clamp(240.0, 520.0);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Row(
              children: [
                Icon(Icons.public, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.title?.isNotEmpty == true
                        ? widget.title!
                        : '网页原件',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                TextButton.icon(
                  onPressed: _openFullScreen,
                  icon: const Icon(Icons.fullscreen, size: 16),
                  label: const Text('全屏'),
                ),
              ],
            ),
          ),
          if (_loading)
            SizedBox(
              height: height,
              child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_html == null)
            SizedBox(
              height: height,
              child: const WebClipFallback(),
            )
          else
            WebClipView(
              html: _html!,
              height: height,
              title: widget.title,
              imageResolver: widget.imageResolver,
              onOpenExternal: _openFullScreen,
            ),
        ],
      ),
    );
  }
}

/// 格式态：96px 原子卡片；单击选中、双击全屏。
class WebClipFormatUnit extends StatelessWidget {
  const WebClipFormatUnit({
    super.key,
    required this.ref,
    required this.htmlLoader,
    this.title,
    this.imageResolver,
    this.onSelect,
  });

  final WebClipRef ref;
  final WebClipHtmlLoader htmlLoader;
  final String? title;
  final WebClipImageResolver? imageResolver;
  final VoidCallback? onSelect;

  Future<void> _openFullScreen(BuildContext context) async {
    final html = await htmlLoader(ref.sha256);
    if (html == null || !context.mounted) return;
    await showWebClipViewer(
      context,
      title: title ?? '网页原件',
      html: html,
      imageResolver: imageResolver,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSelect,
      onDoubleTap: () => _openFullScreen(context),
      child: Container(
        height: 96,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        ),
        child: Row(
          children: [
            Icon(Icons.public, color: scheme.primary, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title?.isNotEmpty == true ? title! : '网页原件',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '双击查看网页',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
            ),
            Icon(Icons.fullscreen, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

/// 便捷：由原始字节加载 HTML。
Future<String?> loadHtmlFromBytes(Future<Uint8List?> Function() load) async {
  return decodeWebClipHtml(await load());
}
