import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

import 'app_controller.dart';
// 单项「立即上传 / 重试」菜单项与笔记行尾菜单**同源**（命令单一来源，ADR-011 决策 5）。
import 'note_list.dart';
import 'sync_status_icon.dart';
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
          // M10-T29（FR-51）：加密笔记本用锁图标区分（未解锁时上锁，已解锁时开锁）。
          leading: Icon(
            nb.encrypted
                ? (controller.isNotebookUnlocked(nb.id)
                    ? Icons.lock_open_outlined
                    : Icons.lock_outline)
                : Icons.folder_outlined,
            size: 20,
          ),
          title: Text(nb.name),
          subtitle: noteCount > 0 ? Text('$noteCount篇') : null,
          selected: controller.selectedNotebookId == nb.id,
          textColor: _sidebarFg,
          iconColor: _sidebarFgDim,
          selectedColor: Colors.white,
          selectedTileColor: Colors.white12,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // M12（FR-53 / ui-spec §20.2）：状态图标在**节点右侧**，折叠态也显示；
              // 与 §19.1 的锁形图标并存（锁在 leading、状态在 trailing，互不替代）。
              _syncStatusIcon(context),
              _nodeMenu(context),
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

  /// 节点右侧同步状态（M12 / FR-53 / ui-spec §20.2 / §20.3）。
  ///
  /// * **空笔记本同样显示**：不因「里面没有笔记」而省略（AC-180）；
  /// * 左栏深色底上取**高对比前景色**（色相仍取自 `ColorScheme`，仅提亮）；
  /// * 窄屏（抽屉）按 §20.3 收敛为**单一状态点**；
  /// * 未配置同步时按「仅本地」弱化呈现（BR-53.6，**不伪造已同步**）；
  /// * 加密笔记本未解锁照常显示状态（判定不依赖明文，BR-53.5 / AC-184）。
  Widget _syncStatusIcon(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 900;
    return SyncStatusIcon(
      state: displaySyncState(nb.syncState,
          configured: controller.syncConfigured),
      error: nb.syncError,
      errorAt: nb.syncErrorAt,
      checkedAt: controller.lastReconcileAt,
      kind: SyncEntityKind.notebook,
      encryptedLocked: nb.encrypted && !controller.isNotebookUnlocked(nb.id),
      size: narrow ? 12 : 16,
      dotOnly: narrow,
      onDark: true,
    );
  }

  /// 节点菜单：既有整理 / 加密 / 删除项 + M12 单项「立即上传 / 重试」
  /// （可用性由 [syncMenuItem] 按 `offersManualUpload` 统一裁决，ui-spec §20.4）。
  Widget _nodeMenu(BuildContext context) {
    return PopupMenuButton<String>(
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
          case 'encrypt':
            await _setEncrypted(context);
            break;
          case 'delete':
            await _confirmDelete(context);
            break;
          case 'sync':
            await _retrySync(context);
            break;
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: Text('重命名')),
        const PopupMenuItem(value: 'newchild', child: Text('新建子笔记本')),
        const PopupMenuItem(value: 'up', child: Text('上移')),
        const PopupMenuItem(value: 'down', child: Text('下移')),
        // M10-T29（FR-51 §5.1）：「设为加密笔记本」为**一次性**动作，已加密则不再出现。
        if (!nb.encrypted)
          const PopupMenuItem(
              value: 'encrypt', child: Text('设为加密笔记本')),
        const PopupMenuItem(value: 'delete', child: Text('删除')),
        const PopupMenuDivider(),
        // M12（FR-54 / ui-spec §20.4）：与笔记行尾菜单**同一项、同一命令**。
        syncMenuItem(nb.syncState),
      ],
    );
  }

  /// 单项「立即上传 / 重试」（笔记本）：只影响该节点（BR-54.1），结果以 SnackBar 呈现。
  Future<void> _retrySync(BuildContext context) async {
    if (!nb.syncState.offersManualUpload) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(syncMenuHint(nb.syncState))),
      );
      return;
    }
    final error =
        await controller.retrySyncFor(SyncEntityKind.notebook, nb.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? '已上传笔记本「${nb.name}」')),
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

  /// 设为加密笔记本（M10-T29 / FR-51 §5.1）：先二次确认锁定密码，再交给控制器。
  Future<void> _setEncrypted(BuildContext context) async {
    final password = await showDialog<String>(
      context: context,
      builder: (context) => _SetLockPasswordDialog(notebookName: nb.name),
    );
    if (password == null) return;
    final err = await controller.setNotebookEncrypted(nb.id, password);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err ??
            '已加密笔记本「${nb.name}」——请牢记锁定密码，忘记后内容无法找回'),
      ),
    );
  }
}

/// 「设为加密笔记本」的锁定密码录入框：**两次输入一致**才允许落笔（§5.1 二次确认）。
class _SetLockPasswordDialog extends StatefulWidget {
  const _SetLockPasswordDialog({required this.notebookName});

  final String notebookName;

  @override
  State<_SetLockPasswordDialog> createState() => _SetLockPasswordDialogState();
}

class _SetLockPasswordDialogState extends State<_SetLockPasswordDialog> {
  final _pw = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pw.text.isEmpty) {
      setState(() => _error = '锁定密码不能为空');
      return;
    }
    if (_pw.text != _confirm.text) {
      setState(() => _error = '两次输入的锁定密码不一致');
      return;
    }
    Navigator.pop(context, _pw.text);
  }

  @override
  Widget build(BuildContext context) {
    final err = Theme.of(context).colorScheme.error;
    return AlertDialog(
      title: const Text('设为加密笔记本'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('笔记本「${widget.notebookName}」内的标题与正文将在本机加密后才落库、才上传；'
              '服务端无法解密，也不需要锁定密码。'),
          const SizedBox(height: 12),
          TextField(
            controller: _pw,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: '锁定密码'),
          ),
          TextField(
            controller: _confirm,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '再次输入锁定密码',
              errorText: _error,
            ),
          ),
          const SizedBox(height: 10),
          Text('⚠️ 锁定密码无法找回：忘记后该笔记本内容将永久不可读。',
              style: TextStyle(color: err, fontSize: 12)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('加密')),
      ],
    );
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