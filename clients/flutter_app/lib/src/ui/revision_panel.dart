import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'app_controller.dart';
import 'markdown_editor.dart';

/// 修订历史侧栏：列出历史版本，点击查看详情，支持一键恢复。
class RevisionPanel extends StatefulWidget {
  final String noteId;

  const RevisionPanel({super.key, required this.noteId});

  @override
  State<RevisionPanel> createState() => _RevisionPanelState();
}

class _RevisionPanelState extends State<RevisionPanel> {
  List<Revision> _revisions = [];
  bool _loading = true;
  int? _selectedVersion;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _loadRevisions();
  }

  @override
  void didUpdateWidget(covariant RevisionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noteId != widget.noteId) {
      _selectedVersion = null;
      _loadRevisions();
    }
  }

  Future<void> _loadRevisions() async {
    setState(() => _loading = true);
    final controller = context.read<AppController>();
    try {
      final revs = await controller.listRevisions(widget.noteId);
      setState(() {
        _revisions = revs;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载历史失败：$e')),
        );
      }
    }
  }

  Future<void> _restore(int version) async {
    final controller = context.read<AppController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复此版本？'),
        content: Text('将恢复到 v$version，当前内容会作为新版本保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _restoring = true);
    try {
      await controller.restoreRevision(widget.noteId, version);
      await _loadRevisions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已恢复到 v$version')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_revisions.isEmpty) {
      return const Center(child: Text('暂无历史版本'));
    }

    final selectedRev = _selectedVersion != null
        ? _revisions.firstWhere(
            (r) => r.version == _selectedVersion,
            orElse: () => _revisions.first,
          )
        : null;

    return Column(
      children: [
        // 标题栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.history, size: 18),
              const SizedBox(width: 8),
              Text(
                '历史版本（${_revisions.length}）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
        ),
        // 内容区：上半部分列表，下半部分详情
        Expanded(
          child: _selectedVersion == null
              ? _buildRevisionList()
              : _buildRevisionDetail(selectedRev!),
        ),
      ],
    );
  }

  Widget _buildRevisionList() {
    return ListView.builder(
      itemCount: _revisions.length,
      itemBuilder: (ctx, i) {
        final rev = _revisions[i];
        final isCurrent = i == 0; // 最新的就是当前版本
        return ListTile(
          dense: true,
          title: Row(
            children: [
              Text(
                'v${rev.version}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              if (isCurrent) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '当前',
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
              if (rev.isConflict) ...[
                const SizedBox(width: 6),
                const Icon(Icons.warning_amber, size: 14, color: Colors.orange),
              ],
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                rev.title.isEmpty ? '(无标题)' : rev.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _formatTime(rev.createdAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => setState(() => _selectedVersion = rev.version),
        );
      },
    );
  }

  Widget _buildRevisionDetail(Revision rev) {
    return Column(
      children: [
        // 详情头部
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 18),
                onPressed: () => setState(() => _selectedVersion = null),
                tooltip: '返回列表',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'v${rev.version}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      _formatTime(rev.createdAt),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (rev.version != _revisions.first.version)
                TextButton.icon(
                  onPressed: _restoring ? null : () => _restore(rev.version),
                  icon: const Icon(Icons.restore, size: 16),
                  label: Text(_restoring ? '恢复中...' : '恢复'),
                ),
            ],
          ),
        ),
        // 内容预览
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (rev.title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      rev.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                MarkdownPreview(text: rev.contentMarkdown),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
