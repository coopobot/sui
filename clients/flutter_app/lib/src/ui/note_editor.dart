import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import '../platform/attachment_picker.dart';
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
                tooltip: '添加附件',
                icon: const Icon(Icons.attach_file),
                onPressed: _pickAndAttach,
              ),
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
            imageBuilder: _buildImage,
          ),
        ),
        if (_attachments.isNotEmpty) _buildAttachmentBar(context),
      ],
    );
  }

  /// 预览里的图片：`sui://<sha256>` 走附件缓存（本地命中或按需下载），
  /// 其余交给默认的 `Image.network`。
  Widget _buildImage(MarkdownImageConfig config) {
    final uri = config.uri;
    final label = config.alt ?? config.title ?? uri.toString();
    if (uri.scheme != 'sui') {
      return Image.network(
        uri.toString(),
        width: config.width,
        height: config.height,
        errorBuilder: (_, __, ___) => _AttachmentPlaceholder(label: label),
      );
    }
    return _SuiAttachmentImage(
      sha256: uri.host,
      label: config.alt ?? config.title ?? '附件',
      width: config.width,
      height: config.height,
    );
  }

  /// 选择文件并挂到当前笔记上，同时在正文里插入 `![](sui://<sha256>)` 引用。
  ///
  /// 引用写进正文是刻意的：canonical 正本只有 Markdown，附件与正文必须一起
  /// 同步，否则换台设备拉到笔记却不知道它带附件。
  Future<void> _pickAndAttach() async {
    final id = _controller.selectedNoteId;
    if (id == null) return;

    List<PickedAttachment> picked;
    try {
      picked = await pickAttachments();
    } catch (e) {
      _toast('打开文件选择器失败：$e');
      return;
    }
    if (picked.isEmpty) return;

    final refs = <String>[];
    for (final f in picked) {
      try {
        final att = await _controller.addAttachmentFromBytes(
          noteId: id,
          filename: f.filename,
          bytes: f.bytes,
        );
        refs.add('![${att.filename}](sui://${att.sha256})');
      } catch (e) {
        _toast('附件「${f.filename}」添加失败：$e');
      }
    }
    if (refs.isEmpty) return;

    setState(() {
      _attachments = _controller.attachments;
      final buf = StringBuffer(_content.text);
      if (buf.isNotEmpty && !buf.toString().endsWith('\n')) buf.write('\n');
      for (final r in refs) {
        buf.write('\n$r\n');
      }
      _content.text = buf.toString();
    });
    await _save();
    _toast('已添加 ${refs.length} 个附件');
  }

  Future<void> _removeAttachment(Attachment a) async {
    await _controller.removeAttachment(a);
    if (!mounted) return;
    setState(() => _attachments = _controller.attachments);
    _toast('已移除「${a.filename}」');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
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
          key: ValueKey(_attachments[i].id),
          attachment: _attachments[i],
          onOpen: () => _openAttachment(_attachments[i]),
          onDelete: () => _removeAttachment(_attachments[i]),
        ),
      ),
    );
  }

  Future<void> _openAttachment(Attachment a) async {
    Uint8List? bytes;
    try {
      bytes = await _controller.openAttachment(a);
    } catch (e) {
      _toast('下载「${a.filename}」失败：$e');
      return;
    }
    if (bytes == null) {
      _toast('附件「${a.filename}」本机没有字节，且当前未连接服务端');
      return;
    }
    if (!mounted) return;
    // 刷新卡片状态（未下载 → 已缓存/待上传）。
    setState(() {});
    _toast('已下载「${a.filename}」（${bytes.length} 字节，已缓存）');
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

/// 单个附件卡片：文件名 + 大小 + 可用性状态 + 打开/移除。
///
/// 状态用 [AttachmentAvailability] 而非布尔「已缓存」：方案 B 下「本地有字节」
/// 与「服务端已持有」是两件事，只显示「已缓存」会让用户误以为换台设备也能打开。
class _AttachmentCard extends StatefulWidget {
  const _AttachmentCard({
    super.key,
    required this.attachment,
    required this.onOpen,
    required this.onDelete,
  });

  final Attachment attachment;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  State<_AttachmentCard> createState() => _AttachmentCardState();
}

class _AttachmentCardState extends State<_AttachmentCard> {
  AttachmentAvailability? _availability;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _downloading =
        context.read<AppController>().isDownloading(widget.attachment.sha256);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _AttachmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sha = widget.attachment.sha256;
    if (oldWidget.attachment.sha256 != sha) {
      _availability = null;
      _refresh();
      return;
    }
    // 「下载中 → 结束」的过渡需要重新确认状态：远端未下载 → 本地已缓存。
    final nowDownloading = context.read<AppController>().isDownloading(sha);
    if (_downloading && !nowDownloading) _refresh();
    _downloading = nowDownloading;
  }

  Future<void> _refresh() async {
    final v = await context
        .read<AppController>()
        .attachmentAvailability(widget.attachment);
    if (!mounted) return;
    setState(() => _availability = v);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final downloading = context.watch<AppController>().isDownloading(a.sha256);
    final availability = _availability;
    final busy = availability == null || downloading;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: busy ? null : widget.onOpen,
        child: Container(
          padding: const EdgeInsets.only(left: 10, right: 2),
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
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(
                      a.filename,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Text(
                    '${_formatSize(a.byteSize)} · ${_statusText(downloading, availability)}',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Theme.of(context).colorScheme.outline),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(_statusIcon(availability), size: 16),
              IconButton(
                tooltip: '移除附件',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 16),
                onPressed: widget.onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusText(
    bool downloading,
    AttachmentAvailability? availability,
  ) {
    if (downloading) return '下载中…';
    if (availability == null) return '检查中';
    return switch (availability) {
      AttachmentAvailability.cached => '已同步',
      AttachmentAvailability.pendingUpload => '待上传',
      AttachmentAvailability.localOnly => '仅本机',
      AttachmentAvailability.remoteOnly => '未下载',
    };
  }

  IconData _statusIcon(AttachmentAvailability availability) {
    switch (availability) {
      case AttachmentAvailability.cached:
        return Icons.cloud_done_outlined;
      case AttachmentAvailability.pendingUpload:
        return Icons.cloud_upload_outlined;
      case AttachmentAvailability.localOnly:
        return Icons.smartphone_outlined;
      case AttachmentAvailability.remoteOnly:
        return Icons.download_for_offline_outlined;
    }
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

/// 预览内联的 `sui://<sha256>` 图片：走附件缓存（本地命中或按需下载）。
///
/// 与卡片同理，加载不出来时必须给出可读回退而不是留白 —— 换台设备首次打开
/// 需要一次下载，断网就会落到失败态。
class _SuiAttachmentImage extends StatefulWidget {
  const _SuiAttachmentImage({
    required this.sha256,
    required this.label,
    this.width,
    this.height,
  });

  final String sha256;
  final String label;
  final double? width;
  final double? height;

  @override
  State<_SuiAttachmentImage> createState() => _SuiAttachmentImageState();
}

class _SuiAttachmentImageState extends State<_SuiAttachmentImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _SuiAttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sha256 != widget.sha256) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    if (widget.sha256.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    try {
      final bytes = await context
          .read<AppController>()
          .loadAttachmentBytes(widget.sha256);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _failed = bytes == null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: widget.width,
        height: widget.height,
        errorBuilder: (_, __, ___) => _AttachmentPlaceholder(label: widget.label),
      );
    }
    if (_failed) return _AttachmentPlaceholder(label: widget.label);
    return _AttachmentPlaceholder(label: widget.label, loading: true);
  }
}

/// 附件在预览里加载中 / 加载失败时的统一占位。
class _AttachmentPlaceholder extends StatelessWidget {
  const _AttachmentPlaceholder({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.broken_image_outlined, size: 18),
          const SizedBox(width: 6),
          Text(
            loading ? '加载「$label」…' : label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}