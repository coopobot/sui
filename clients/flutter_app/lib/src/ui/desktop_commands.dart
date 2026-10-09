import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/desktop_platform.dart';
import 'app_controller.dart';
import 'markdown_editor.dart';
import 'notebook_tree.dart';
import 'sync_settings_dialog.dart';
import 'tag_overview.dart';

/// 壳层命令标识（ADR-011 决策 5 / 详细设计 §4.2）。
///
/// 菜单项、顶栏图标按钮、快捷键**共用同一份定义**——新增入口只在
/// [desktopCommands] 登记一次，避免「菜单可点、按钮不可点」这类状态分裂。
enum DesktopCommandId {
  // 文件
  newNote,
  createNotebook,
  exportNote,
  openNoteInWindow,
  quit,

  // 编辑
  undo,
  redo,
  cut,
  copy,
  paste,
  selectAll,
  insertTable,
  findNotes,

  // 视图
  toggleLeftPanel,
  toggleNoteList,
  showAllTags,
  showArchived,
  showTrash,
  editorModeFormatted,
  editorModeSource,
  editorModePreview,
  toggleRevisionPanel,

  // 同步
  reconcileAll,

  // 帮助
  openDocs,
  about,
}

/// 编辑器命令桥（详细设计 §4.2）。
///
/// 撤销 / 重做 / 剪切 / 复制 / 粘贴 / 全选 / 导出 / 回写刷新的**真实实现**位于活动
/// 编辑器内部（`_NoteEditorState`），壳层不可直接触达，故经此接口下发。
///
/// 活动编辑器在 `initState` 向 [AppController] **按视图键注册**自身、`dispose` **注销**；
/// 命令执行体经 `controller.targetFor(controller.activeViewKey)` 取**当前活动窗口**的
/// 目标，取不到时相关命令一律置灰（BR-41.4 / AC-119）。
///
/// **M8（ADR-012）**：主窗口 + 多个独立笔记窗口共存，故由 M7 的单一可空 target
/// 收敛为**按视图键的注册表**（详细设计 §5.1），避免多窗口抢同一 target。
abstract interface class EditorCommandTarget {
  /// 当前编辑器是否可撤销（供「编辑 → 撤销」置灰）。
  bool get canUndo;

  /// 当前编辑器是否可重做（供「编辑 → 重做」置灰）。
  bool get canRedo;

  void undo();
  void redo();

  void cut();
  void copy();
  void paste();
  void selectAll();

  /// 打开「插入表格」面板（M9 / FR-44 / ui-spec §18.1）。
  ///
  /// 与格式工具栏的「表格」图标**同源同效**（命令单一来源，ADR-011 决策 5）。
  void insertTable();

  /// 导出当前笔记（复用既有导出对话框）。
  void exportNote();

  /// 立即结束编辑器 400ms 防抖并写回落库（退出前调用，详细设计 §7）。
  Future<void> flushPendingEdits();
}

/// 一条壳层命令：文案、快捷键提示、可用性谓词与执行体（详细设计 §4.2）。
class DesktopCommand {
  DesktopCommand({
    required this.label,
    required this.isEnabled,
    required this.invoke,
    this.shortcutLabel,
    this.checked,
  });

  /// 菜单文案。
  final String label;

  /// 快捷键提示文本（沿用 FR-30 定义）；无快捷键为 `null`（BR-41.6 / AC-121）。
  final String? shortcutLabel;

  /// 可用性谓词：菜单置灰状态与图标按钮同源（BR-41.4 / AC-119）。
  final bool Function(AppController controller) isEnabled;

  /// 执行体。
  final void Function(BuildContext context, AppController controller) invoke;

  /// 勾选态谓词（「视图」菜单的开关项）；不适用为 `null`。
  final bool Function(AppController controller)? checked;
}

/// 壳层命令注册表——**唯一定义处**（ADR-011 决策 5）。
///
/// 顺序即菜单期望的展示顺序；各菜单按 [DesktopCommandId] 显式取用，不依赖遍历顺序。
final Map<DesktopCommandId, DesktopCommand> desktopCommands = {
  // ---- 文件 ----
  DesktopCommandId.newNote: DesktopCommand(
    label: '新建笔记',
    isEnabled: (_) => true,
    invoke: (context, controller) => controller.createNote(),
  ),
  DesktopCommandId.createNotebook: DesktopCommand(
    label: '新建笔记本',
    // 左栏折叠时经此仍可新建笔记本（BR-40.5 / AC-115）。
    isEnabled: (_) => true,
    invoke: showCreateNotebookDialog,
  ),
  DesktopCommandId.exportNote: DesktopCommand(
    label: '导出笔记',
    // M8（§5.1 收敛点）：命令派发到**当前活动窗口**自己的编辑器命令桥，
    // 而非进程内唯一目标——否则独立笔记窗口会抢错 target。
    isEnabled: (controller) =>
        controller.selectedNoteId != null &&
        controller.targetFor(controller.activeViewKey) != null,
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.exportNote(),
  ),
  DesktopCommandId.openNoteInWindow: DesktopCommand(
    label: '在独立窗口打开',
    // 入口仅桌面端呈现（§6）；未选笔记置灰（§4.4）。命令只对**主窗口当前选中笔记**
    // 生效，实际打开 / 去重聚焦由 [AppController.openNoteInWindow] 负责（§4.3）。
    isEnabled: (controller) =>
        isDesktopPlatform && controller.selectedNoteId != null,
    invoke: (context, controller) {
      final noteId = controller.selectedNoteId;
      if (noteId != null) controller.openNoteInWindow(noteId);
    },
  ),
  DesktopCommandId.quit: DesktopCommand(
    label: '退出应用',
    isEnabled: (_) => true,
    invoke: (context, controller) => controller.quitApplication(),
  ),

  // ---- 编辑 ----
  DesktopCommandId.undo: DesktopCommand(
    label: '撤销',
    shortcutLabel: 'Ctrl+Z',
    isEnabled: (controller) =>
        controller.canEditContent &&
        (controller.targetFor(controller.activeViewKey)?.canUndo ?? false),
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.undo(),
  ),
  DesktopCommandId.redo: DesktopCommand(
    label: '重做',
    shortcutLabel: 'Ctrl+Shift+Z',
    isEnabled: (controller) =>
        controller.canEditContent &&
        (controller.targetFor(controller.activeViewKey)?.canRedo ?? false),
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.redo(),
  ),
  DesktopCommandId.cut: DesktopCommand(
    label: '剪切',
    shortcutLabel: 'Ctrl+X',
    isEnabled: (controller) => controller.canEditContent,
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.cut(),
  ),
  DesktopCommandId.copy: DesktopCommand(
    label: '复制',
    shortcutLabel: 'Ctrl+C',
    isEnabled: (controller) => controller.canEditContent,
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.copy(),
  ),
  DesktopCommandId.paste: DesktopCommand(
    label: '粘贴',
    shortcutLabel: 'Ctrl+V',
    isEnabled: (controller) => controller.canEditContent,
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.paste(),
  ),
  DesktopCommandId.selectAll: DesktopCommand(
    label: '全选',
    shortcutLabel: 'Ctrl+A',
    isEnabled: (controller) => controller.canEditContent,
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.selectAll(),
  ),
  DesktopCommandId.insertTable: DesktopCommand(
    label: '插入表格',
    // 与格式工具栏「表格」同源；键位与编辑器 `Shortcuts` 表一致（M9 补丁 `v0.10.14` / §14.2）。
    shortcutLabel: 'Ctrl+Shift+T',
    // 与格式工具栏的「表格」图标同源（M9 / FR-44 / ui-spec §18.1）；预览态只读，
    // 不给排版入口，故与其他排版命令一样受 canEditContent 约束。
    isEnabled: (controller) =>
        controller.canEditContent &&
        controller.targetFor(controller.activeViewKey) != null,
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.insertTable(),
  ),
  DesktopCommandId.findNotes: DesktopCommand(
    label: '查找',
    // 界定为「查找笔记」：中栏折叠时先展开，再请求聚焦其搜索框（§4.3 / AC-120）。
    isEnabled: (_) => true,
    invoke: (context, controller) async {
      await controller.setNoteListCollapsed(false);
      controller.requestFindNotes();
    },
  ),

  // ---- 视图 ----
  DesktopCommandId.toggleLeftPanel: DesktopCommand(
    label: '切换左侧栏',
    checked: (controller) => !controller.leftPanelCollapsed,
    isEnabled: (_) => true,
    invoke: (context, controller) => controller.toggleLeftPanel(),
  ),
  DesktopCommandId.toggleNoteList: DesktopCommand(
    label: '切换笔记列表',
    checked: (controller) => !controller.noteListCollapsed,
    isEnabled: (_) => true,
    invoke: (context, controller) => controller.toggleNoteList(),
  ),
  DesktopCommandId.showAllTags: DesktopCommand(
    label: '全部标签',
    // BR-40.5 / AC-115：左栏折叠后仍可经「视图」菜单打开标签总览。
    isEnabled: (_) => true,
    invoke: (context, controller) => openTagOverview(context, controller),
  ),
  DesktopCommandId.showArchived: DesktopCommand(
    label: '归档',
    // BR-40.5 / AC-115：与左栏「归档」同源同效。
    isEnabled: (_) => true,
    invoke: (context, controller) {
      controller.selectArchivedView();
      controller.search('');
    },
  ),
  DesktopCommandId.showTrash: DesktopCommand(
    label: '回收站',
    // BR-40.5 / AC-115：与左栏「回收站」同源同效。
    isEnabled: (_) => true,
    invoke: (context, controller) {
      controller.selectTrashView();
      controller.search('');
    },
  ),
  DesktopCommandId.editorModeFormatted: DesktopCommand(
    label: '格式模式',
    checked: (controller) => controller.editorMode == EditorMode.formatted,
    isEnabled: (_) => true,
    invoke: (context, controller) => controller.setEditorMode(EditorMode.formatted),
  ),
  DesktopCommandId.editorModeSource: DesktopCommand(
    label: '源码模式',
    checked: (controller) => controller.editorMode == EditorMode.source,
    isEnabled: (_) => true,
    invoke: (context, controller) => controller.setEditorMode(EditorMode.source),
  ),
  DesktopCommandId.editorModePreview: DesktopCommand(
    label: '预览模式',
    checked: (controller) => controller.editorMode == EditorMode.preview,
    isEnabled: (_) => true,
    invoke: (context, controller) => controller.setEditorMode(EditorMode.preview),
  ),
  DesktopCommandId.toggleRevisionPanel: DesktopCommand(
    label: '切换修订面板',
    checked: (controller) => controller.showRevisionPanel,
    isEnabled: (controller) => controller.selectedNoteId != null,
    invoke: (context, controller) => controller.toggleRevisionPanel(),
  ),

  // ---- 同步 ----
  DesktopCommandId.reconcileAll: DesktopCommand(
    label: '全部重新同步',
    // M12（FR-54 / ui-spec §20.5 入口二）：与同步设置对话框内的按钮**同一命令、
    // 同一实现**（[showReconcileAllDialog] 复用 [SyncReconcilePanel]），
    // 未连接服务端时置灰。
    isEnabled: (controller) => controller.canReconcile,
    invoke: (context, controller) =>
        unawaited(showReconcileAllDialog(context, controller)),
  ),

  // ---- 帮助 ----
  DesktopCommandId.openDocs: DesktopCommand(
    label: '使用文档',
    isEnabled: (_) => true,
    invoke: (context, controller) => showDocsDialog(context),
  ),
  DesktopCommandId.about: DesktopCommand(
    label: '关于随手记 Sui',
    isEnabled: (_) => true,
    invoke: (context, controller) => showAboutDialog(
      context: context,
      applicationName: '随手记 Sui',
      applicationLegalese: '自托管 · 离线优先 · 多端同步的 Markdown 笔记应用',
      children: const [
        SizedBox(height: 12),
        Text('Markdown 为唯一正本；本地 SQLite 离线优先；自研 push/pull 协议多端同步，数据完全自持。'),
      ],
    ),
  ),
};

/// 「帮助 → 使用文档」：产品文档随代码仓库发布，此处给出入口清单。
///
/// 不引入 `url_launcher` 等新依赖（依赖增删须先经批准，Agents.md §6 第 4 条）。
void showDocsDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('使用文档'),
      content: const SelectableText(
        '随手记 Sui 的使用文档随代码仓库发布，位于 docs/ 目录：\n'
        '\n'
        '· docs/index.md           文档导航与现状速览\n'
        '· docs/getting-started.md 环境搭建、构建、快速上手\n'
        '· docs/guides/user-guide.md   使用指南\n'
        '· docs/guides/web-clipper.md  网页剪藏\n'
        '· docs/architecture.md    架构、数据模型、同步协议\n'
        '· docs/api-reference.md   服务端 API 参考\n'
        '· docs/deployment.md      部署说明\n'
        '· docs/troubleshooting.md 常见问题排查\n',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
