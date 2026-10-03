import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'desktop_commands.dart';

/// 桌面端应用菜单栏：**文件 / 编辑 / 视图 / 帮助**（FR-41，详细设计 §4）。
///
/// **本组件不含任何命令实现**：每个菜单项都按 [DesktopCommandId] 从
/// [desktopCommands] 注册表取用 `label` / `isEnabled` / `invoke` / `checked`
/// （ADR-011 决策 5）。由此菜单项与顶栏图标按钮（[PanelToggles]）、快捷键共享
/// 同一份定义——既保证「同源同效」（BR-41.3 / AC-118 / AC-120），也不可能出现
/// 「菜单可点、按钮不可点」这类可用性分裂（BR-41.4 / AC-119）。
///
/// 用 Material 组件自绘（`MenuBar` / `SubmenuButton`），**不走平台原生窗口菜单**
/// （ADR-011 决策 4）：三平台呈现一致，且可被 widget 测试覆盖。
///
/// 仅在 `_WideLayout` 的桌面分支渲染（BR-41.1 / AC-122）。
class AppMenuBar extends StatelessWidget {
  const AppMenuBar({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MenuBar(
      // 透明叠加：清除 `MenuBar` 默认的 surfaceContainer 底色、投影、圆角与高度，
      // 使菜单栏与 AppBar 底色（colorScheme.surface）一致，顶栏不出现分层色块（AC-117）。
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color?>(Colors.transparent),
        shadowColor: WidgetStatePropertyAll<Color?>(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll<Color?>(Colors.transparent),
        elevation: WidgetStatePropertyAll<double?>(0),
        shape: WidgetStatePropertyAll<OutlinedBorder>(RoundedRectangleBorder()),
      ),
      children: <Widget>[
        _submenu(
          context,
          '文件',
          const <DesktopCommandId?>[
            DesktopCommandId.newNote,
            DesktopCommandId.createNotebook,
            DesktopCommandId.exportNote,
            null, // 分组分隔符
            DesktopCommandId.quit,
          ],
        ),
        _submenu(
          context,
          '编辑',
          const <DesktopCommandId?>[
            DesktopCommandId.undo,
            DesktopCommandId.redo,
            null,
            DesktopCommandId.cut,
            DesktopCommandId.copy,
            DesktopCommandId.paste,
            DesktopCommandId.selectAll,
            null,
            DesktopCommandId.findNotes,
          ],
        ),
        _submenu(
          context,
          '视图',
          const <DesktopCommandId?>[
            DesktopCommandId.toggleLeftPanel,
            DesktopCommandId.toggleNoteList,
            null,
            DesktopCommandId.showAllTags,
            DesktopCommandId.showArchived,
            DesktopCommandId.showTrash,
            null,
            DesktopCommandId.editorModeFormatted,
            DesktopCommandId.editorModeSource,
            DesktopCommandId.editorModePreview,
            null,
            DesktopCommandId.toggleRevisionPanel,
          ],
        ),
        _submenu(
          context,
          '帮助',
          const <DesktopCommandId?>[
            DesktopCommandId.openDocs,
            DesktopCommandId.about,
          ],
        ),
      ],
    );
  }

  /// 顶层菜单。列表中的 `null` 元素即分组分隔符（§4.3 的「┄」），只作视觉分组、
  /// **不承载命令**。
  Widget _submenu(
    BuildContext context,
    String label,
    List<DesktopCommandId?> items,
  ) {
    return SubmenuButton(
      menuChildren: <Widget>[
        for (final id in items)
          if (id == null) const _MenuSeparator() else _commandItem(context, id),
      ],
      child: Text(label),
    );
  }

  /// 普通菜单项：`onPressed == null` 即**置灰且点击无效果**（BR-41.4 / AC-119）。
  Widget _commandItem(BuildContext context, DesktopCommandId id) {
    final command = desktopCommands[id]!;
    final shortcut = command.shortcutLabel;
    return MenuItemButton(
      onPressed: command.isEnabled(controller)
          ? () => command.invoke(context, controller)
          : null,
      // 勾选态（「视图」菜单的开关项 / 模式项）：统一预留列宽，保证同菜单内文案对齐。
      leadingIcon: _CheckGutter(checked: command.checked?.call(controller) ?? false),
      // 快捷键提示取自注册表（BR-41.6 / AC-121），与 FR-30 定义同源。
      trailingIcon: shortcut == null ? null : Text(shortcut),
      child: Text(command.label),
    );
  }
}

/// 顶栏折叠切换控件：左侧栏 / 笔记列表各一枚（FR-40，ui-spec §16.1）。
///
/// 与「视图」菜单中的同名项**共用同一命令**（[DesktopCommandId.toggleLeftPanel] /
/// [DesktopCommandId.toggleNoteList]），故执行体与可用性天然一致（AC-120）。
/// 当前态由三处共同表达：图标字形（实心 = 展开 / 描边 = 折叠）、按钮的选中高亮、
/// 以及提示文案（「折叠左侧栏」/「展开左侧栏」）。
class PanelToggles extends StatelessWidget {
  const PanelToggles({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _toggle(
          context,
          DesktopCommandId.toggleLeftPanel,
          expandedIcon: Icons.view_sidebar,
          collapsedIcon: Icons.view_sidebar_outlined,
          expandedTooltip: '折叠左侧栏',
          collapsedTooltip: '展开左侧栏',
        ),
        _toggle(
          context,
          DesktopCommandId.toggleNoteList,
          expandedIcon: Icons.view_list,
          collapsedIcon: Icons.view_list_outlined,
          expandedTooltip: '折叠笔记列表',
          collapsedTooltip: '展开笔记列表',
        ),
      ],
    );
  }

  Widget _toggle(
    BuildContext context,
    DesktopCommandId id, {
    required IconData expandedIcon,
    required IconData collapsedIcon,
    required String expandedTooltip,
    required String collapsedTooltip,
  }) {
    final command = desktopCommands[id]!;
    // `checked` 语义为「该栏当前展开」，与「视图」菜单里的勾号口径一致。
    final expanded = command.checked?.call(controller) ?? true;
    return IconButton(
      tooltip: expanded ? expandedTooltip : collapsedTooltip,
      isSelected: expanded,
      icon: Icon(collapsedIcon),
      selectedIcon: Icon(expandedIcon),
      onPressed: command.isEnabled(controller)
          ? () => command.invoke(context, controller)
          : null,
    );
  }
}

/// 勾选态列：固定宽度占位 + 勾号。
///
/// 勾号用 [Text] 而非 `Icon(Icons.check)`：`Text` 继承菜单项的 `DefaultTextStyle`
/// （含前景色），菜单项置灰时勾号同步变灰；`Icon` 走 `IconTheme`，在 AppBar 下会
/// 取到顶栏图标色，与菜单项的可用性状态脱节。
class _CheckGutter extends StatelessWidget {
  const _CheckGutter({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      child: checked ? const Text('✓', textAlign: TextAlign.center) : null,
    );
  }
}

/// 分组分隔符（§4.3 的「┄」）：只作视觉分组，不承载命令。
class _MenuSeparator extends StatelessWidget {
  const _MenuSeparator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Divider(height: 1, thickness: 1),
    );
  }
}
