import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

import 'app_controller.dart';
import 'tag_overview.dart';

/// 侧栏笔记本树（宽屏直接嵌入，窄屏经抽屉复用）。
class NotebookTree extends StatelessWidget {
  const NotebookTree({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    // 顶层：全部笔记 + 笔记本分组（平铺，UI 按 parentId 递归展现）
    final notebooks = controller.notebooks;
    final roots = notebooks.where((n) => n.parentId == null).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('笔记本',
              style: Theme.of(context).textTheme.labelLarge),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.layers_outlined),
          title: const Text('全部笔记'),
          selected: controller.selectedNotebookId == null &&
              controller.hasSelection == false,
          onTap: () {
            controller.selectNotebook(null);
            // 清除搜索以便"全部笔记"可见
            controller.search('');
          },
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.inbox_outlined),
          title: const Text('收件箱'),
          subtitle: Text('${_clipCount(controller)} 篇剪藏',
              style: const TextStyle(fontSize: 11)),
          selected: controller.inboxMode,
          onTap: () {
            controller.selectInbox();
            controller.search('');
          },
        ),
        const Divider(height: 1),
        Expanded(child: _Tree(controller: controller, roots: roots)),
        const Divider(height: 1),
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
                    onDeleted: () => controller.toggleTag(name),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                TextButton(
                  onPressed: controller.clearTags,
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextButton.icon(
            onPressed: () => _openTagOverview(context),
            icon: const Icon(Icons.label_outline, size: 18),
            label: const Text('全部标签'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextButton.icon(
            onPressed: () => _promptCreateNotebook(context),
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('新建笔记本'),
          ),
        ),
      ],
    );
  }

  Future<void> _promptCreateNotebook(BuildContext context) async {
    final name = await _askName(context, '新建笔记本');
    if (name == null || name.trim().isEmpty) return;
    await controller.createNotebook(name.trim());
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已创建笔记本「$name」')),
      );
    }
  }

  /// 打开标签总览（FR-22）。窄屏用全屏页面，宽屏用对话框。
  void _openTagOverview(BuildContext context) {
    controller.refreshTagSummaries();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TagOverview(controller: controller),
        fullscreenDialog: true,
      ),
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
            style: TextStyle(color: Colors.grey, fontSize: 13)),
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
          trailing: PopupMenuButton<String>(
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
    await controller.repository.renameNotebook(nb.id, name.trim());
    await controller.refreshNotebooks();
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
            '删除后其中笔记将移出到「全部笔记」，不会一并删除。'
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
    return Drawer(child: NotebookTree(controller: controller));
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