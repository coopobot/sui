import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

import 'app_controller.dart';
import 'tag_overview.dart';

/// FR-28：左栏深色配色（RGB(34,34,38)）与高对比前景色。
const Color _sidebarBg = Color(0xFF222226);
const Color _sidebarFg = Color(0xFFEDEDF0);
const Color _sidebarFgDim = Color(0xFF9A9AA2);

/// 侧栏笔记本树（宽屏直接嵌入，窄屏经抽屉复用）。
class NotebookTree extends StatelessWidget {
  const NotebookTree({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    // 顶层：全部笔记 + 笔记本分组（平铺，UI 按 parentId 递归展现）
    final notebooks = controller.notebooks;
    final roots = notebooks.where((n) => n.parentId == null).toList();

    return Material(
      color: _sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // BUG6：左栏顶部提供「新建笔记」入口。
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: _sidebarFg),
                onPressed: () => controller.createNote(),
                icon: const Icon(Icons.note_add_outlined, size: 18),
                label: const Text('新建笔记'),
              ),
            ),
          ),
          const Divider(height: 1, color: Colors.white24),
          _SidebarTile(
            leading: const Icon(Icons.layers_outlined),
            title: const Text('全部笔记'),
            selected: controller.isAllNotesView,
            onTap: () {
              controller.selectNotebook(null);
              // 清除搜索以便"全部笔记"可见
              controller.search('');
            },
          ),
          _SidebarTile(
            leading: const Icon(Icons.inbox_outlined),
            title: const Text('收件箱'),
            subtitle: Text('${_clipCount(controller)} 篇剪藏',
                style: const TextStyle(fontSize: 11, color: _sidebarFgDim)),
            selected: controller.inboxMode,
            onTap: () {
              controller.selectInbox();
              controller.search('');
            },
          ),
          const Divider(height: 1, color: Colors.white24),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('笔记本',
                      style: Theme.of(context)
                          .textTheme
                          .labelLarge
                          ?.copyWith(color: _sidebarFgDim)),
                ),
                // BUG7：新建笔记本入口移到「笔记本」栏行尾的「+」图标。
                IconButton(
                  tooltip: '新建笔记本',
                  visualDensity: VisualDensity.compact,
                  color: _sidebarFgDim,
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: () => showCreateNotebookDialog(context, controller),
                ),
              ],
            ),
          ),
          Expanded(child: _Tree(controller: controller, roots: roots)),
          const Divider(height: 1, color: Colors.white24),
          // 标签入口区：「全部标签」打开总览（FR-22），下方汇总已选筛选标签。
          if (controller.hasTagFilter)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final name in controller.selectedTagNames)
                    InputChip(
                      label: Text('#$name'),
                      labelStyle:
                          const TextStyle(color: _sidebarFg, fontSize: 12),
                      backgroundColor: Colors.white10,
                      side: const BorderSide(color: Colors.white24),
                      onDeleted: () => controller.toggleTag(name),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: _sidebarFgDim),
                    onPressed: controller.clearTags,
                    child: const Text('清空'),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: _sidebarFg),
              onPressed: () => openTagOverview(context, controller),
              icon: const Icon(Icons.label_outline, size: 18),
              label: const Text('全部标签'),
            ),
          ),
          const Divider(height: 1, color: Colors.white24),
          // FR-25 / FR-26：左栏底部固定「归档」「回收站」入口。
          _SidebarTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('归档'),
            selected: controller.archivedView,
            onTap: () {
              controller.selectArchivedView();
              controller.search('');
            },
          ),
          _SidebarTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('回收站'),
            selected: controller.trashView,
            onTap: () {
              controller.selectTrashView();
              controller.search('');
            },
          ),
        ],
      ),
    );
  }
}

/// FR-28：左栏深色底上的列表项，统一高对比前景色与选中态。
class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final Widget leading;
  final Widget title;
  final Widget? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: leading,
      title: title,
      subtitle: subtitle,
      selected: selected,
      textColor: _sidebarFg,
      iconColor: _sidebarFgDim,
      selectedColor: Colors.white,
      selectedTileColor: Colors.white12,
      onTap: onTap,
    );
  }
}

class _Tree extends StatelessWidget {
  const _Tree({required this.controller, required this.roots});
  final AppController controller;
  final List<Notebook> roots;

  @override
  Widget build(BuildContext context) {
    if (roots.isEmpty) {
      return const Center(
        child: Text('暂无笔记本',
            style: TextStyle(color: _sidebarFgDim, fontSize: 13)),
      );
    }
    return ListView(
      children: [
        for (final nb in roots) _NotebookNode(controller: controller, nb: nb),
      ],
    );
  }
}

class _NotebookNode extends StatelessWidget {
  const _NotebookNode({required this.controller, required this.nb});
  final AppController controller;
  final Notebook nb;

  @override
  Widget build(BuildContext context) {
    final children = controller.notebooks
        .where((n) => n.parentId == nb.id)
        .toList();
    final noteCount = controller.notes
        .where((n) => n.note.notebookId == nb.id)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.folder_outlined, size: 20),
          title: Text(nb.name),
          subtitle: noteCount > 0 ? Text('$noteCount篇') : null,
          selected: controller.selectedNotebookId == nb.id,
          textColor: _sidebarFg,
          iconColor: _sidebarFgDim,
          selectedColor: Colors.white,
          selectedTileColor: Colors.white12,
          trailing: PopupMenuButton<String>(
            iconColor: _sidebarFgDim,
            onSelected: (v) async {
              switch (v) {
                case 'rename':
                  await _rename(context);
                  break;
                case 'newchild':
                  await _addChild(context);
                  break;
                case 'up':
                  await controller.moveNotebookUp(nb.id);
                  break;
                case 'down':
                  await controller.moveNotebookDown(nb.id);
                  break;
                case 'delete':
                  await _confirmDelete(context);
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'newchild', child: Text('新建子笔记本')),
              PopupMenuItem(value: 'up', child: Text('上移')),
              PopupMenuItem(value: 'down', child: Text('下移')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
          onTap: () => controller.selectNotebook(nb.id),
        ),
        if (children.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Column(
              children: [
                for (final c in children)
                  _NotebookNode(controller: controller, nb: c),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _rename(BuildContext context) async {
    final name = await _askName(context, '重命名笔记本', initial: nb.name);
    if (name == null || name.trim().isEmpty) return;
    await controller.renameNotebook(nb.id, name.trim());
  }

  Future<void> _addChild(BuildContext context) async {
    final name = await _askName(context, '新建子笔记本');
    if (name == null || name.trim().isEmpty) return;
    await controller.createNotebook(name.trim(), parentId: nb.id);
  }

  /// 删除笔记本：二次确认，非空时按 BR-20.4 文案说明笔记移出而非删除。
  Future<void> _confirmDelete(BuildContext context) async {
    final noteCount = controller.notes
        .where((n) => n.note.notebookId == nb.id)
        .length;
    final message = noteCount > 0
        ? '笔记本「${nb.name}」下有 $noteCount 篇笔记，'
            '删除后其中笔记将进入「回收站」，可在回收站中还原，不会一并删除。'
            '子笔记本会上提到当前父级。'
        : '确定删除笔记本「${nb.name}」？子笔记本会上提到当前父级。';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除笔记本'),
        content: Text(message),
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
    if (ok == true) await controller.deleteNotebook(nb.id);
  }
}

/// 窄屏抽屉复用同一棵树。
class NoteTreeDrawer extends StatelessWidget {
  const NoteTreeDrawer({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: _sidebarBg,
      child: NotebookTree(controller: controller),
    );
  }
}

/// 「新建笔记本」对话框（FR-41 / 详细设计 §4.3）。
///
/// 由左栏「笔记本」栏的「+」入口与「文件 → 新建笔记本」菜单**共用**同一实现，
/// 使左栏折叠时仍可经菜单新建笔记本（BR-40.5 / AC-115），避免两处行为漂移。
Future<void> showCreateNotebookDialog(
    BuildContext context, AppController controller) async {
  final name = await _askName(context, '新建笔记本');
  if (name == null || name.trim().isEmpty) return;
  await controller.createNotebook(name.trim());
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已创建笔记本「$name」')),
    );
  }
}

Future<String?> _askName(BuildContext context, String title,
    {String? initial}) {
  final ctl = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: const InputDecoration(hintText: '名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ctl.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

int _clipCount(AppController controller) {
  return controller.notes.where((n) => n.note.sourceDevice.startsWith('clip:')).length;
}