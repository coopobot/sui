import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_version.dart';
import '../platform/desktop_platform.dart';
import 'app_controller.dart';
import 'import_dialog.dart';
import 'markdown_editor.dart';
import 'notebook_tree.dart';
import 'settings_dialog.dart';
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
  importFiles,
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
  insertNoteRef,
  findInNote,
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
  togglePropertiesPanel,

  // 设置（M14 / FR-63）
  openSettings,

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

  /// 打开**笔记内查找栏**（M15 / FR-73 / BR-73.1）。
  ///
  /// 与编辑器自身的 `Ctrl+F` **同源同效**：壳层只把请求下发给**当前活动窗口**的编辑器
  /// （`_NoteEditorState`），匹配 / 高亮 / 替换全在编辑器内部；预览态不提供（命令置灰）。
  void openFind();

  /// 打开**关联笔记选择器**（M15 / FR-75 / ui-spec §26.3）。
  ///
  /// 与格式工具栏「关联笔记」图标同源同效；产出恒为标准 Markdown 链接
  /// `[标题](sui://note/<笔记ID>)`（BR-75.1）。
  void insertNoteRef();

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
    this.activator,
  });

  /// 菜单文案。
  final String label;

  /// 快捷键提示文本（沿用 FR-30 定义）；无快捷键为 `null`（BR-41.6 / AC-121）。
  final String? shortcutLabel;

  /// **真实**的菜单加速键（M13 / FR-60）：交给 `MenuItemButton.shortcut` 向 `MenuBar`
  /// 注册，与 [shortcutLabel] 的展示文案**同源同效**（ADR-011 决策 5）。
  /// 为 `null` 表示不注册全局加速键（如编辑器内部键位由编辑器自己的 `Shortcuts` 表处理）。
  final MenuSerializableShortcut? activator;

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
  DesktopCommandId.importFiles: DesktopCommand(
    label: '导入文件…',
    // M13（FR-60 / ui-spec §23.1）：位置在「新建笔记本」之后、「导出笔记」之前
    // （导入与导出相邻）；加速键经 [activator] 注册到 `MenuBar`，与提示文案同源。
    shortcutLabel: 'Ctrl+Shift+I',
    activator: const SingleActivator(
      LogicalKeyboardKey.keyI,
      control: true,
      shift: true,
    ),
    // 无选中笔记本时导入到「未分组」是**允许**的，故恒可用（BR-60.1）。
    isEnabled: (_) => true,
    invoke: (context, controller) => showImportDialog(context, controller),
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
  DesktopCommandId.insertNoteRef: DesktopCommand(
    label: '插入关联笔记',
    // M15（FR-75 / ui-spec §26.3）：插入的是**标准 Markdown 链接** `[标题](sui://note/<id>)`；
    // 动作是「打开笔记选择器」——**幂等**（重复触发只是再打开一次选择器，不改正本），
    // 故可安全登记壳层加速键（同 `importFiles` / `openSettings` 范式）。
    shortcutLabel: 'Ctrl+Shift+L',
    activator: const SingleActivator(
      LogicalKeyboardKey.keyL,
      control: true,
      shift: true,
    ),
    isEnabled: (controller) =>
        controller.canEditContent &&
        controller.targetFor(controller.activeViewKey) != null,
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.insertNoteRef(),
  ),
  DesktopCommandId.findInNote: DesktopCommand(
    label: '在笔记内查找',
    // M15（FR-73 / BR-73.1）：**只给提示文案、不注册壳层 activator**——真实按键由
    // 编辑器子树的查找快捷键层承担（两态都挂）；壳层若也挂会与它**双重触发**
    // （与既有「编辑 → 插入表格」只给 `Ctrl+Shift+T` 文案的分工一致）。
    shortcutLabel: 'Ctrl+F',
    isEnabled: (controller) =>
        controller.canEditContent &&
        controller.targetFor(controller.activeViewKey) != null,
    invoke: (context, controller) =>
        controller.targetFor(controller.activeViewKey)?.openFind(),
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
  DesktopCommandId.togglePropertiesPanel: DesktopCommand(
    label: '笔记属性',
    // M15（FR-74 / ui-spec §26.2）：与编辑页右上角「属性」图标执行**同一命令**
    // （命令单一来源，承 ADR-011 决策 5）；加速键与「编辑 → 插入表格」同范式登记。
    shortcutLabel: 'Ctrl+Shift+P',
    activator: const SingleActivator(
      LogicalKeyboardKey.keyP,
      control: true,
      shift: true,
    ),
    // 勾选态 = 主窗口属性面板当前是否展开（「视图」菜单开关项口径）。
    checked: (controller) => controller.showPropertiesPanel,
    isEnabled: (controller) => controller.selectedNoteId != null,
    invoke: (context, controller) => controller.togglePropertiesPanel(),
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

  // ---- 设置（M14 / FR-63） ----
  DesktopCommandId.openSettings: DesktopCommand(
    label: '设置…',
    // 与顶栏「更多 → 设置」、`Ctrl/Cmd + ,` **同一命令**（BR-63.1 / AC-269 / AC-270）；
    // 加速键由 `_ShellAccelerator` 统一接管（与焦点无关）。
    shortcutLabel: 'Ctrl+,',
    activator: const SingleActivator(LogicalKeyboardKey.comma, control: true),
    isEnabled: (_) => true,
    invoke: (context, controller) =>
        unawaited(showSettingsDialog(context, controller)),
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
    // FR-56（ADR-020）：桌面菜单栏与移动端 / Web 的「更多」菜单**共用同一份**对话框，
    // 版本号来自构建期常量 [`kAppVersion`]，各端显示值逐字一致（BR-56.3 / AC-199）。
    invoke: (context, controller) => showSuiAboutDialog(context),
  ),
};

/// 「帮助 → 关于随手记 Sui」：**各端共用**的关于对话框（FR-56 / ADR-020 / ui-spec §21.2）。
///
/// 版本号取自构建期常量 [`kAppVersion`]（真源：`clients/flutter_app/pubspec.yaml`，
/// 由 `scripts/version.sh` 同步），故桌面 / 移动 / Web 显示值**逐字一致**且**离线可见**：
/// 不发请求、不读服务端、不降级为「未知」（AC-200 / AC-201）。
void showSuiAboutDialog(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: '随手记 Sui',
    // 「版本 x.y.z」紧邻应用名呈现；**不含** `+BN` 构建号（BR-56.2）。
    applicationVersion: '版本 $kAppVersion',
    applicationLegalese: '自托管 · 离线优先 · 多端同步的 Markdown 笔记应用',
    children: const [
      SizedBox(height: 12),
      Text('Markdown 为唯一正本；本地 SQLite 离线优先；自研 push/pull 协议多端同步，数据完全自持。'),
    ],
  );
}

/// 「帮助 → 使用文档」：产品文档随代码仓库发布，此处给出入口清单。
///
/// 不引入 `url_launcher` 等新依赖（依赖增删须先经批准，Agents.md §6 第 4 条）。
void showDocsDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('使用文档'),
      content: const SelectableText(
        '随手记 Sui 的使用文档，请访问 https://coopobot.github.io/sui/',
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
