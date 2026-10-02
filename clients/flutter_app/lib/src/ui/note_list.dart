import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

import 'app_controller.dart';

/// 笔记列表：展示所选笔记本/搜索下的笔记摘要 + 元信息（时间、所属笔记本）。
///
/// 列表头部提供排序切换（更新时间 / 创建时间 / 标题）；选择记忆为本机偏好，
/// 由 [AppController.setSortMode] 落 SQLite，重启保留。
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
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _headerTitle(),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              _SortButton(controller: controller),
            ],
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
              ? _EmptyHint(
                  icon: controller.trashView
                      ? Icons.delete_outline
                      : controller.archivedView
                          ? Icons.archive_outlined
                          : Icons.inbox_outlined,
                  title: controller.trashView
                      ? '回收站为空'
                      : controller.archivedView
                          ? '暂无归档笔记'
                          : '暂无笔记',
                  subtitle: controller.trashView || controller.archivedView
                      ? null
                      : '点击下方按钮新建一篇',
                )
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
    if (controller.trashView) return '回收站';
    if (controller.archivedView) return '归档';
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

/// 排序切换菜单：当前模式以对勾标出，其余纯文本。
///
/// 用 PopupMenu 而非 SegmentedButton：选项数固定为 3、占位小、不抢标题空间；
/// 切换后立刻调用 [AppController.setSortMode]，UI 即时重排。
class _SortButton extends StatelessWidget {
  const _SortButton({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<NoteSortMode>(
      icon: const Icon(Icons.sort, size: 20),
      tooltip: '排序',
      onSelected: controller.setSortMode,
      itemBuilder: (context) => [
        for (final mode in NoteSortMode.values)
          PopupMenuItem<NoteSortMode>(
            value: mode,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: controller.sortMode == mode
                      ? const Icon(Icons.check, size: 18)
                      : null,
                ),
                Text(_sortLabel(mode)),
              ],
            ),
          ),
      ],
    );
  }

  static String _sortLabel(NoteSortMode mode) => switch (mode) {
        NoteSortMode.updatedAt => '更新时间',
        NoteSortMode.createdAt => '创建时间',
        NoteSortMode.title => '标题',
      };
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({
    this.icon = Icons.inbox_outlined,
    this.title = '暂无笔记',
    this.subtitle = '点击下方按钮新建一篇',
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final hintColor = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          Text(title, style: TextStyle(color: hintColor)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: TextStyle(color: hintColor, fontSize: 12)),
          ],
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
    final showNotebook = !controller.inboxMode &&
        controller.selectedNotebookId == null &&
        note.notebookId != null;
    final notebookName = showNotebook
        ? controller.notebooks
            .where((n) => n.id == note.notebookId)
            .firstOrNull
            ?.name
        : null;

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
        mainAxisSize: MainAxisSize.min,
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
          _MetaLine(
            relativeTime: _relativeTime(note.updatedAt),
            notebookName: notebookName,
            isClip: note.sourceDevice.startsWith('clip:'),
            pinned: note.pinned,
            archived: note.archived,
          ),
        ],
      ),
      isThreeLine: true,
      trailing: controller.trashView
          ? IconButton(
              icon: const Icon(Icons.restore, size: 20),
              tooltip: '还原',
              onPressed: () => controller.restoreNote(note.id),
            )
          : _NoteTileMenu(controller: controller, note: note),
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

/// 笔记项行尾菜单（FR-21 / BR-21.3）：置顶 / 归档 / 移动到… / 删除。
///
/// 所有操作沿用既有软删除 / 置顶 / 归档语义（不改 BR-01.2 / BR-05.2 / FR-05）。
/// 删除需二次确认（FR-21）；移动到…打开 [_MoveToNotebookDialog]。
class _NoteTileMenu extends StatelessWidget {
  const _NoteTileMenu({required this.controller, required this.note});
  final AppController controller;
  final Note note;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: '笔记操作',
      onSelected: (v) => _onSelected(context, v),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'pin',
          child: Row(children: [
            Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                size: 18),
            const SizedBox(width: 8),
            Text(note.pinned ? '取消置顶' : '置顶'),
          ]),
        ),
        PopupMenuItem(
          value: 'archive',
          child: Row(children: [
            Icon(note.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
                size: 18),
            const SizedBox(width: 8),
            Text(note.archived ? '取消归档' : '归档'),
          ]),
        ),
        const PopupMenuItem(
          value: 'move',
          child: Row(children: [
            Icon(Icons.drive_file_move_outline, size: 18),
            SizedBox(width: 8),
            Text('移动到…'),
          ]),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(children: [
            Icon(Icons.delete_outline, size: 18),
            SizedBox(width: 8),
            Text('删除'),
          ]),
        ),
      ],
    );
  }

  Future<void> _onSelected(BuildContext context, String v) async {
    switch (v) {
      case 'pin':
        await controller.togglePinNote(note.id);
        break;
      case 'archive':
        await controller.toggleArchiveNote(note.id);
        break;
      case 'move':
        if (!context.mounted) return;
        final target = await _showMoveToNotebookDialog(
          context,
          controller,
          currentNotebookId: note.notebookId,
        );
        if (target == _MoveSentinel.canceled) return;
        await controller.moveNoteToNotebook(note.id, target);
        break;
      case 'delete':
        if (!context.mounted) return;
        final ok = await _confirmDeleteNote(context, note);
        if (ok) await controller.deleteNote(note.id);
        break;
    }
  }

  Future<bool> _confirmDeleteNote(BuildContext context, Note note) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('「${note.title.isEmpty ? '无标题' : note.title}」'
            '将被移到回收站，可在「回收站」中还原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

/// 「移动到…」对话框：列出所有笔记本（含父子层级缩进）+ 「全部笔记」入口。
///
/// 返回值约定：
/// - 用户选中某个笔记本 → 返回该 notebookId；
/// - 选中「全部笔记 / 收件箱」（notebookId = null）→ 返回 null；
/// - 取消 → 返回 [_MoveSentinel.canceled]（一个 sentinel 对象，避免与
///   合法的 null 混淆，因为 null 也表示「移出到全部笔记」）。
Future<String?> _showMoveToNotebookDialog(
  BuildContext context,
  AppController controller, {
  required String? currentNotebookId,
}) {
  return showDialog<String?>(
    context: context,
    builder: (context) {
      // controller.notebooks 已按 (sortOrder, createdAt, id) 有序，无需再排。
      final roots =
          controller.notebooks.where((n) => n.parentId == null).toList();
      return AlertDialog(
        title: const Text('移动到…'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.layers_outlined, size: 20),
                  title: const Text('全部笔记 / 收件箱'),
                  selected: currentNotebookId == null,
                  onTap: () => Navigator.pop(context, null),
                ),
                const Divider(height: 1),
                for (final nb in roots)
                  _NotebookPickerNode(
                    controller: controller,
                    nb: nb,
                    currentNotebookId: currentNotebookId,
                    depth: 0,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _MoveSentinel.canceled),
            child: const Text('取消'),
          ),
        ],
      );
    },
  );
}

class _NotebookPickerNode extends StatelessWidget {
  const _NotebookPickerNode({
    required this.controller,
    required this.nb,
    required this.currentNotebookId,
    required this.depth,
  });

  final AppController controller;
  final Notebook nb;
  final String? currentNotebookId;
  final int depth;

  @override
  Widget build(BuildContext context) {
    // controller.notebooks 已按 (sortOrder, createdAt, id) 有序，无需再排。
    final children = controller.notebooks
        .where((n) => n.parentId == nb.id)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.fromLTRB(
              16 + depth * 16.0, 0, 16, 0),
          leading: const Icon(Icons.folder_outlined, size: 20),
          title: Text(nb.name),
          selected: currentNotebookId == nb.id,
          onTap: () => Navigator.pop(context, nb.id),
        ),
        for (final c in children)
          _NotebookPickerNode(
            controller: controller,
            nb: c,
            currentNotebookId: currentNotebookId,
            depth: depth + 1,
          ),
      ],
    );
  }
}

/// 区分「用户取消」与「用户选择 null（移出到全部笔记）」的哨兵。
class _MoveSentinel {
  const _MoveSentinel._();
  static const String canceled = '\u0000__move_canceled__';
}

/// 笔记项底部元信息行：相对时间 · 笔记本名 · 角标（剪藏/置顶）。
///
/// 把时间与笔记本名放主区而非 trailing，避免在窄屏挤压时被图标顶出可见范围；
/// 角标用图标表示，与列表项的视觉重量匹配。
class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.relativeTime,
    required this.notebookName,
    required this.isClip,
    required this.pinned,
    required this.archived,
  });

  final String relativeTime;
  final String? notebookName;
  final bool isClip;
  final bool pinned;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 11, color: scheme.outline);
    final parts = <Widget>[Text(relativeTime, style: style)];
    if (notebookName != null) {
      parts
        ..add(Text(' · ', style: style))
        ..add(Text(notebookName!, style: style));
    }
    if (archived) {
      parts
        ..add(const SizedBox(width: 6))
        ..add(_MiniBadge(
          text: '归档',
          color: scheme.tertiaryContainer,
          onColor: scheme.onTertiaryContainer,
        ));
    }
    if (isClip) {
      parts
        ..add(const SizedBox(width: 6))
        ..add(_MiniBadge(
          text: '剪藏',
          color: scheme.secondaryContainer,
          onColor: scheme.onSecondaryContainer,
        ));
    }
    if (pinned) {
      parts
        ..add(const SizedBox(width: 4))
        ..add(Icon(Icons.push_pin_outlined, size: 12, color: scheme.outline));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: parts,
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({
    required this.text,
    required this.color,
    required this.onColor,
  });

  final String text;
  final Color color;
  final Color onColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, color: onColor),
      ),
    );
  }
}

/// 把 [DateTime] 渲染为相对时间（如「3 天前」）；超过 7 天回退到年月日。
///
/// 与 revision_panel 的 [_formatTime] 同语义：本机时间常用相对形式，避免长串
/// 数字占位；长按 / 悬浮查看绝对时间的入口由调用方决定（暂未实现）。
String _relativeTime(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.isNegative) return '刚刚';
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}
