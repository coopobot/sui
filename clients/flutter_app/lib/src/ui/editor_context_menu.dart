/// 正文右键菜单（M18 / FR-107 / BR-107.1\~107.5）。
///
/// 桌面端由 `NoteEditor` 接管 `TextField.contextMenuBuilder`，经本文件在**鼠标指针处**弹出
/// 一张按组排列的 `showMenu`：编辑组（剪切 / 复制 / 粘贴 / 全选）+ 插入组（添加关联笔记 /
/// 插入附件 / 插入链接）+ 格式组（插入表格 / 插入分割线，仅格式模式）。
///
/// 移动端 / Web **不进入**本文件：`NoteEditor` 直接返回框架默认的
/// `AdaptiveTextSelectionToolbar`，长按选择行为与升级前一致（BR-107.4）。
///
/// 菜单本身**只读**：打开菜单不改选区、不改正本、不写库（BR-107.1）；每个动作的落地实现
/// 仍在 `NoteEditor`，且一律转调既有工具栏 / 菜单入口（BR-107.2）。
///
/// 设计见 `technology/design/low-level-design/editor-context-menu.md` §2。
library;

import 'package:flutter/material.dart';

/// 正文右键菜单的动作（枚举只承载「选了哪一项」，实现仍在 `NoteEditor`）。
enum EditorContextAction {
  cut,
  copy,
  paste,
  selectAll,
  insertNoteRef,
  insertAttachment,
  insertLink,
  insertTable,
  insertDivider,
}

/// 在 [globalAnchor]（全局坐标）处弹出正文右键菜单；取消 / 无法定位时返回 null。
///
/// [formatted] 为真时追加「插入表格… / 插入分割线」两项（仅格式模式有对应呈现语义）。
/// 可用态由调用方按 `EditableTextState` 的 `cutEnabled/copyEnabled/pasteEnabled/selectAllEnabled`
/// 与附件批次状态给出；禁用项**保留在菜单里**灰显，不隐藏（AC-611）。
Future<EditorContextAction?> showEditorContextMenu({
  required BuildContext context,
  required Offset globalAnchor,
  required bool formatted,
  required bool canCut,
  required bool canCopy,
  required bool canPaste,
  required bool canSelectAll,
  required bool attaching,
}) async {
  final overlay = Navigator.of(context).overlay?.context.findRenderObject();
  if (overlay is! RenderBox) return null;
  final local = overlay.globalToLocal(globalAnchor);
  final dx = local.dx.clamp(0.0, overlay.size.width);
  final dy = local.dy.clamp(0.0, overlay.size.height);
  final disabled = Theme.of(context).disabledColor;

  PopupMenuItem<EditorContextAction> item(
    EditorContextAction action,
    String label,
    IconData icon, {
    bool enabled = true,
  }) {
    return PopupMenuItem<EditorContextAction>(
      value: action,
      enabled: enabled,
      height: 36,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: enabled ? null : disabled),
          const SizedBox(width: 12),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: enabled ? null : TextStyle(color: disabled),
          ),
        ],
      ),
    );
  }

  return showMenu<EditorContextAction>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(dx, dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<EditorContextAction>>[
      item(EditorContextAction.cut, '剪切', Icons.content_cut, enabled: canCut),
      item(EditorContextAction.copy, '复制', Icons.content_copy,
          enabled: canCopy),
      item(EditorContextAction.paste, '粘贴', Icons.content_paste,
          enabled: canPaste),
      item(EditorContextAction.selectAll, '全选', Icons.select_all,
          enabled: canSelectAll),
      const PopupMenuDivider(),
      item(EditorContextAction.insertNoteRef, '添加关联笔记…', Icons.add_link),
      item(EditorContextAction.insertAttachment, '插入附件…', Icons.attach_file,
          enabled: !attaching),
      item(EditorContextAction.insertLink, '插入链接…', Icons.link),
      if (formatted) ...<PopupMenuEntry<EditorContextAction>>[
        const PopupMenuDivider(),
        item(EditorContextAction.insertTable, '插入表格…',
            Icons.table_chart_outlined),
        item(EditorContextAction.insertDivider, '插入分割线',
            Icons.horizontal_rule),
      ],
    ],
  );
}
