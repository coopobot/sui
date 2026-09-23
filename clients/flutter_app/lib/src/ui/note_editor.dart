import 'package:flutter/material.dart';
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
  bool _preview = false;
  bool _loaded = false;

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
    if (_loaded) return;
    final note = _note;
    if (note != null) {
      _title.text = note.title;
      _content.text = note.contentMarkdown;
      final s = _controller.notes
          .where((s) => s.note.id == note.id)
          .firstOrNull;
      _tags = s?.tags ?? [];
      _loaded = true;
    }
  }

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
    final id = _controller.selectedNoteId;
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
      ],
    );
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

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}