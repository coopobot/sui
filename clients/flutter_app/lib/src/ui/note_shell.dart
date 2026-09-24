import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_controller.dart';
import 'note_editor.dart';
import 'note_list.dart';
import 'notebook_tree.dart';
import 'revision_panel.dart';
import 'sync_settings_dialog.dart';

/// 应用主界面外壳：响应式三栏（笔记本树 / 笔记列表 / 编辑区）。
/// 宽屏（桌面/平板）三栏并排；窄屏（手机）用抽屉 + 导航堆栈。
class NoteShell extends StatelessWidget {
  const NoteShell({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final controller = context.watch<AppController>();

        if (wide) {
          return _WideLayout(controller: controller);
        }
        return _NarrowLayout(controller: controller);
      },
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('随手记 Sui'),
        actions: [
          _SyncActions(controller: controller),
          _newNoteAction(context),
        ],
      ),
      body: Row(
        children: [
          SizedBox(width: 280, child: NotebookTree(controller: controller)),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 2,
            child: NoteList(controller: controller),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 4,
            child: Row(
              children: [
                Expanded(
                  child: NoteEditor(key: ValueKey(controller.selectedNoteId)),
                ),
                if (controller.showRevisionPanel &&
                    controller.selectedNoteId != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 320,
                    child: RevisionPanel(noteId: controller.selectedNoteId!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _newNoteAction(BuildContext context) {
    return IconButton(
      tooltip: '新建笔记',
      icon: const Icon(Icons.note_add_outlined),
      onPressed: () => controller.createNote(),
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final editorOpen = controller.selectedNoteId != null;
    // 手机：选中笔记后进入全屏编辑页；平板中等宽度时可用双栏。
    return Scaffold(
      appBar: AppBar(
        title: Text(editorOpen ? '笔记' : '随手记 Sui'),
        leading: editorOpen
            ? BackButton(
                onPressed: () => controller.selectNote(null),
              )
            : null,
        actions: [
          _SyncActions(controller: controller),
          if (editorOpen)
            IconButton(
              tooltip: '删除笔记',
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  controller.deleteNote(controller.selectedNoteId!),
            )
          else
            IconButton(
              tooltip: '新建笔记',
              icon: const Icon(Icons.note_add_outlined),
              onPressed: () => controller.createNote(),
            ),
        ],
      ),
      drawer: editorOpen ? null : NoteTreeDrawer(controller: controller),
      body: editorOpen
          ? NoteEditor(key: ValueKey(controller.selectedNoteId))
          : NoteList(controller: controller),
    );
  }
}

/// 顶栏同步状态与入口：未连接时点按打开设置，已连接时点按立即同步。
class _SyncActions extends StatelessWidget {
  const _SyncActions({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = controller.syncState;

    final (IconData icon, String tooltip) = switch (state) {
      SyncState.unconfigured => (Icons.cloud_off_outlined, '未连接服务端 · 点击配置'),
      SyncState.idle => (Icons.cloud_done_outlined, '已同步 · 点击立即同步'),
      SyncState.syncing => (Icons.cloud_sync_outlined, '同步中…'),
      SyncState.error => (
          Icons.cloud_off_outlined,
          '同步失败：${controller.syncError ?? '未知原因'} · 点击重试',
        ),
    };
    final color = switch (state) {
      SyncState.error => scheme.error,
      SyncState.unconfigured => scheme.outline,
      _ => scheme.primary,
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: tooltip,
          icon: state == SyncState.syncing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, color: color),
          onPressed: () {
            if (state == SyncState.unconfigured) {
              showSyncSettingsDialog(context, controller);
            } else {
              controller.syncNow();
            }
          },
        ),
        IconButton(
          tooltip: '同步设置',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => showSyncSettingsDialog(context, controller),
        ),
      ],
    );
  }
}