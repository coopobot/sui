import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_controller.dart';
import 'app_menu_bar.dart';
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
          return _WideLayout(
            controller: controller,
            showDesktopChrome: _isDesktopPlatform,
          );
        }
        return _NarrowLayout(controller: controller);
      },
    );
  }
}

/// 是否桌面平台（详细设计 §6）：菜单栏与折叠切换仅在桌面三平台渲染。
///
/// 用 [defaultTargetPlatform] 而非 `dart:io` 的 `Platform`：Web 上后者不可用，
/// 且能避免条件导入；[kIsWeb] 先行兜底，避免 Web 被误判为桌面。
bool get _isDesktopPlatform {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.controller, required this.showDesktopChrome});
  final AppController controller;

  /// 是否渲染桌面外壳（应用菜单栏 + 折叠切换，详细设计 §6）。
  /// 宽屏但非桌面平台（如 Web）为 false：仍出宽屏三栏，但不含菜单栏与切换控件。
  final bool showDesktopChrome;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 标题区顺序固定：菜单栏 → 折叠切换 → 标题（BR-41.5 / AC-117）。
        titleSpacing: showDesktopChrome ? 8 : null,
        title: showDesktopChrome
            ? Row(
                children: [
                  AppMenuBar(controller: controller),
                  const SizedBox(width: 4),
                  PanelToggles(controller: controller),
                  const SizedBox(width: 8),
                  const Text('随手记 Sui'),
                ],
              )
            : const Text('随手记 Sui'),
        actions: [
          _SyncActions(controller: controller),
          _newNoteAction(context),
        ],
      ),
      body: Row(
        children: [
          // 左栏（笔记本树）可折叠（FR-40）：分隔线与其相邻面板同生共死，
          // 折叠后不留悬空 VerticalDivider。
          if (!controller.leftPanelCollapsed) ...[
            SizedBox(width: 280, child: NotebookTree(controller: controller)),
            const VerticalDivider(width: 1),
          ],
          // 中栏（笔记列表）可折叠（FR-40）。
          if (!controller.noteListCollapsed) ...[
            Expanded(
              flex: 2,
              child: NoteList(controller: controller),
            ),
            const VerticalDivider(width: 1),
          ],
          // 编辑区常驻：折叠只影响前两栏，flex:4 自动吃掉释放出的宽度。
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
          // 编辑态不再提供「删除笔记」图标：它与同步/设置同处顶栏、极易误碰（B15）。
          // 删除入口保留在笔记列表的行尾菜单里（需二次确认）。
          if (!editorOpen)
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