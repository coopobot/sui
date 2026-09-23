import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'app_controller.dart';
import 'markdown_editor.dart';

/// 笔记编辑页：标题 + Markdown 编辑器（源码/预览双轨） + 标签。
/// 编辑变更实时保存到仓储并追加一条修订。
class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key});

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _content = TextEditingController();
  final TextEditingController _tagInput = TextEditingController();
  List<String> _tags = [];
  List<Attachment> _attachments = [];
  bool _preview = false;
  bool _loaded = false;
  String? _loadedNoteId;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _tagInput.dispose();
    super.dispose();
  }

  AppController get _controller => context.read<AppController>();

  Note? get _note => _controller.notes
      .where((s) => s.note.id == _controller.selectedNoteId)
      .map((s) => s.note)
      .firstOrNull;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadNote();
  }

  void _loadNote() {
    final note = _note;
    if (note != null) {
      _title.text = note.title;
      _content.text = note.contentMarkdown;
      final s = _controller.notes
          .where((s) => s.note.id == note.id)
          .firstOrNull;
      _tags = s?.tags ?? [];
      _loaded = true;
      _lastVersion = note.version;
    }
    if (note?.id != _loadedNoteId) {
      _loadedNoteId = note?.id;
      if (note != null) {
        _controller.refreshAttachments(note.id).then((_) {
          _attachments = _controller.attachments;
          if (mounted) setState(() {});
        });
      } else {
        _attachments = [];
      }
    }
  }

  int? _lastVersion;

  Future<void> _save() async {
    final id = _controller.selectedNoteId;
    if (id == null) return;
    await _controller.saveNote(
      id,
      title: _title.text,
      content: _content.text,
      tags: _tags,
    );
  }

  @override
  Widget build(BuildContext context) {
    final id = context.watch<AppController>().selectedNoteId;
    // 检测到笔记版本变化（如恢复操作），重新加载内容
    final note = _note;
    if (_loaded && note != null && note.version != _lastVersion) {
      _loadNote();
    }
    if (id == null) {
      return const _EmptyEditor();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: TextField(
            controller: _title,
            onChanged: (_) => _save(),
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
              hintText: '标题',
              border: InputBorder.none,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 6,
            children: [
              for (final t in _tags)
                InputChip(
                  label: Text('#$t'),
                  onDeleted: () {
                    setState(() => _tags = _tags.where((e) => e != t).toList());
                    _save();
                  },
                  visualDensity: VisualDensity.compact,
                ),
              SizedBox(
                width: 130,
                child: TextField(
                  controller: _tagInput,
                  onSubmitted: (_) => _addTag(),
                  decoration: const InputDecoration(
                    hintText: '添加标签',
                    isDense: true,
                    border: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('编辑')),
                  ButtonSegment(value: true, label: Text('预览')),
                ],
                selected: {_preview},
                onSelectionChanged: (sel) {
                  setState(() => _preview = sel.first);
                  _save();
                },
                showSelectedIcon: false,
              ),
              const Spacer(),
              IconButton(
                tooltip: '版本历史',
                icon: const Icon(Icons.history),
                isSelected: context.watch<AppController>().showRevisionPanel,
                onPressed: () => _controller.toggleRevisionPanel(),
              ),
              IconButton(
                tooltip: '导出 Markdown',
                icon: const Icon(Icons.file_download_outlined),
                onPressed: () => _showExportDialog(),
              ),
              IconButton(
                tooltip: '删除笔记',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await _confirmDelete();
                  if (ok) _controller.deleteNote(id);
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: MarkdownEditor(
            controller: _content,
            preview: _preview,
            onChanged: () => _save(),
          ),
        ),
        if (_attachments.isNotEmpty) _buildAttachmentBar(context),
      ],
    );
  }

  Widget _buildAttachmentBar(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _attachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => _AttachmentCard(
          attachment: _attachments[i],
          cached: _controller.syncClient != null
              ? null // 未知 → 卡片自行查询
              : false,
          onOpen: () => _openAttachment(_attachments[i]),
        ),
      ),
    );
  }

  Future<void> _openAttachment(Attachment a) async {
    final Uint8List? bytes;
    try {
      bytes = await _controller.openAttachment(a);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载「${a.filename}」失败：$e')),
      );
      return;
    }
    if (bytes == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('附件「${a.filename}」未配置同步客户端，无法下载')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('已下载「${a.filename}」（${bytes.length} 字节，已缓存）'),
          duration: const Duration(seconds: 2)),
    );
    // 刷新卡片缓存状态
    setState(() {});
  }

  void _addTag() {
    final name = _tagInput.text.trim();
    if (name.isEmpty || _tags.contains(name)) {
      _tagInput.clear();
      return;
    }
    _tagInput.clear();
    setState(() => _tags = [..._tags, name]);
    _save();
  }

  void _showExportDialog() {
    final title = _title.text.isEmpty ? '未命名笔记' : _title.text;
    final content = '# $title\n\n${_content.text}';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出 Markdown'),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('标题：$title',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Container(
                height: 200,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    content,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制全部'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('已复制到剪贴板'),
                    duration: Duration(seconds: 1)),
              );
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除这篇笔记？'),
            content: const Text('将移到回收站（逻辑删除），可从档案恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _EmptyEditor extends StatelessWidget {
  const _EmptyEditor();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.edit_note, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          Text('选择或新建一篇笔记开始记录',
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ],
      ),
    );
  }
}

/// 单个附件卡片：文件名 + 大小 + 缓存状态（未下载 ⇄ 已缓存）+ 打开/下载。
class _AttachmentCard extends StatefulWidget {
  const _AttachmentCard({
    required this.attachment,
    required this.cached,
    required this.onOpen,
  });

  final Attachment attachment;

  /// 已知缓存状态；null 表示需自行异步查询。
  final bool? cached;
  final VoidCallback onOpen;

  @override
  State<_AttachmentCard> createState() => _AttachmentCardState();
}

class _AttachmentCardState extends State<_AttachmentCard> {
  late bool _cached;
  bool _checking = true;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    final known = widget.cached;
    if (known != null) {
      _cached = known;
      _checking = false;
    } else {
      _cached = false;
      _downloading = context.read<AppController>().isDownloading(widget.attachment.sha256);
      _check();
    }
  }

  @override
  void didUpdateWidget(covariant _AttachmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final known = widget.cached;
    if (known != null) {
      _cached = known;
      _checking = false;
      return;
    }
    final sha = widget.attachment.sha256;
    if (oldWidget.attachment.sha256 != sha) {
      _check();
      return;
    }
    // 下载完成过渡（下载中 → 结束）后重新确认缓存状态
    final nowDownloading = context.read<AppController>().isDownloading(sha);
    if (_downloading && !nowDownloading) {
      _check();
    }
    _downloading = nowDownloading;
  }

  Future<void> _check() async {
    final cached = await context.read<AppController>().isAttachmentCached(widget.attachment);
    if (!mounted) return;
    setState(() {
      _cached = cached;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final downloading = context.watch<AppController>().isDownloading(a.sha256);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: widget.onOpen,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconFor(a.mimeKind), size: 20),
              const SizedBox(width: 8),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      a.filename,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Text(
                    '${_formatSize(a.byteSize)} · ${_statusText(downloading)}',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Theme.of(context).colorScheme.outline),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              if (_checking || downloading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (_cached)
                const Icon(Icons.cloud_done_outlined, size: 16)
              else
                const Icon(Icons.download_for_offline_outlined, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  String _statusText(bool downloading) {
    if (_checking) return '检查中';
    if (downloading) return '下载中…';
    return _cached ? '已缓存' : '未下载';
  }

  IconData _iconFor(String mimeKind) {
    switch (mimeKind) {
      case 'image':
        return Icons.image_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'video':
        return Icons.videocam_outlined;
      case 'audio':
        return Icons.music_note_outlined;
      default:
        return Icons.attach_file_outlined;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}