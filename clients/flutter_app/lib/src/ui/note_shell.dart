import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/desktop_platform.dart';
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
            showDesktopChrome: isDesktopPlatform,
          );
        }
        return _NarrowLayout(controller: controller);
      },
    );
  }
}

/// 宽屏三栏布局：笔记本树 / 笔记列表 / 编辑区并排。
///
/// 桌面端判定口径统一收敛到 [`isDesktopPlatform`](../platform/desktop_platform.dart)
/// （菜单栏与折叠切换仅在桌面三平台渲染，详细设计 §6），避免与命令入口 / 独立窗口
/// 入口各写一份。
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
        // 桌面外壳：菜单栏 → 折叠切换（BR-41.5 / AC-117）。
        // 桌面端不再重复呈现应用标题文本（标题由操作系统窗口标题承载）。
        titleSpacing: showDesktopChrome ? 8 : null,
        title: showDesktopChrome
            ? Row(
                children: [
                  AppMenuBar(controller: controller),
                  const SizedBox(width: 4),
                  PanelToggles(controller: controller),
                ],
              )
            : const Text('随手记 Sui'),
        actions: [
          SyncActions(controller: controller),
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
    // 窄屏修订历史：无右侧栏可切换，改为**整页推入**（BR-12.3 / AC-137 / ui-spec §4.1 / §6）。
    final showRevisions = editorOpen && controller.showRevisionPanel;
    // 手机：选中笔记后进入全屏编辑页；平板中等宽度时可用双栏。
    return PopScope(
      // 系统返回键（Android）：优先关修订面板回编辑页，其次退出编辑回列表。
      // 两级都不可弹时才交还系统（否则「点了历史 → 按返回」会直接退出应用）。
      canPop: !showRevisions && !editorOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (showRevisions) {
          controller.setRevisionPanelVisible(false);
        } else if (editorOpen) {
          controller.selectNote(null);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            showRevisions ? '版本历史' : (editorOpen ? '笔记' : '随手记 Sui'),
          ),
          leading: showRevisions
              // 返回先关闭修订面板，回到编辑页（不是退回列表）。
              ? BackButton(
                  onPressed: () => controller.setRevisionPanelVisible(false),
                )
              : editorOpen
                  ? BackButton(
                      onPressed: () {
                        controller.setRevisionPanelVisible(false);
                        controller.selectNote(null);
                      },
                    )
                  : null,
          actions: [
            SyncActions(controller: controller),
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
        // 修订面板整页推入：复用宽屏右侧栏的同一 `RevisionPanel`，能力（列表 / 详情 /
        // 恢复）完全一致；返回后回到编辑页。
        body: showRevisions
            ? RevisionPanel(
                key: ValueKey(controller.selectedNoteId),
                noteId: controller.selectedNoteId!,
              )
            : editorOpen
                ? NoteEditor(key: ValueKey(controller.selectedNoteId))
                : NoteList(controller: controller),
      ),
    );
  }
}

/// 顶栏同步状态与入口：未连接时点按打开设置，已连接时点按立即同步。
///
/// 主窗口顶栏与独立笔记窗口精简顶栏**共用**同一实现（M8 · 详细设计 §4.2）。
class SyncActions extends StatelessWidget {
  const SyncActions({super.key, required this.controller});

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