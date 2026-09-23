import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

import 'app_controller.dart';

/// 笔记列表：展示所选笔记本/搜索下的笔记摘要。
class NoteList extends StatelessWidget {
  const NoteList({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final notes = controller.notes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            _headerTitle(),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            onChanged: controller.search,
            decoration: const InputDecoration(
              hintText: '搜索标题或内容…',
              prefixIcon: Icon(Icons.search, size: 20),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: notes.isEmpty
              ? const _EmptyHint()
              : ListView.builder(
                  itemCount: notes.length,
                  itemBuilder: (context, i) =>
                      _NoteTile(controller: controller, s: notes[i]),
                ),
        ),
      ],
    );
  }

  String _headerTitle() {
    if (controller.inboxMode) return '收件箱 · 剪藏';
    if (controller.selectedNotebookId != null) {
      final nb = controller.notebooks
          .where((n) => n.id == controller.selectedNotebookId)
          .firstOrNull;
      return nb?.name ?? '笔记';
    }
    return '全部笔记';
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox_outlined, size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          Text('暂无笔记',
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          const SizedBox(height: 4),
          Text('点击下方按钮新建一篇',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.outline, fontSize: 12)),
        ],
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.controller, required this.s});
  final AppController controller;
  final NoteSummary s;

  @override
  Widget build(BuildContext context) {
    final note = s.note;
    return ListTile(
      selected: controller.selectedNoteId == note.id,
      title: Text(
        note.title.isEmpty ? '（无标题）' : note.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: controller.selectedNoteId == note.id
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2, top: 2),
              child: Wrap(
                spacing: 4,
                children: [
                  for (final t in s.tags.take(3))
                    Chip(
                      label: Text('#$t'),
                      labelStyle: const TextStyle(fontSize: 11),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
            )
          else
            Text(
              _excerpt(note.contentMarkdown),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.outline),
            ),
        ],
      ),
      isThreeLine: s.tags.isNotEmpty,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (note.sourceDevice.startsWith('clip:'))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '剪藏',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          if (note.pinned)
            const Icon(Icons.push_pin_outlined, size: 16),
        ],
      ),
      onTap: () => controller.selectNote(note.id),
    );
  }

  String _excerpt(String md) {
    final t = md
        .replaceAll(RegExp(r'[#*_`>\[\]()!\-|]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }
}