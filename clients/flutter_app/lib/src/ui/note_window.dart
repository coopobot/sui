import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_controller.dart';
import 'markdown_editor.dart';
import 'note_editor.dart';
import 'note_properties_panel.dart';
import 'revision_panel.dart';

/// 独立笔记窗口内容（M8-T10 · 详细设计 §4.2；M15 修订 FR-82）。
///
/// 桌面端「在独立窗口打开」后由 `openWindow` 创建，**只渲染该篇笔记**：
/// 单篇 [NoteEditor]（+ 按需的属性 / 修订右栏）。
///
/// **M15（FR-82 / BR-82.1）：不渲染 Flutter 侧顶栏** —— 原先「笔记标题 + 同步图标 +
/// 设置图标」那一行已整体删除，编辑区上移、有效编辑面积最大化；窗口拖拽 / 最小化 /
/// 最大化 / 关闭由 **OS 原生标题栏**承载（`multiview_desktop` 默认 `titleBarStyle: normal`），
/// 标题仍可编辑（[NoteEditor] 顶部标题框，BR-82.3）；同步与设置入口保留在**主窗口**。
///
/// **普通 widget，不是第二层 `MaterialApp`**（详细设计 §3.4）：库的 `SharedEntryApp`
/// 已为次级窗口复现主窗口外观（主题 / 方向 / 生命周期），此处只需 [Scaffold]。
///
/// 视图局部状态（详细设计 §5.2）：
/// - 编辑三态 [_mode]：窗口局部，经 [AppController.loadWindowNoteEditorMode] /
///   [AppController.saveWindowNoteEditorMode] 持久化，**不与主窗口联动**；
/// - 修订面板显隐 [_showRevisions]：窗口局部；主窗口沿用全局 `showRevisionPanel`；
/// - 属性面板显隐：窗口局部（`AppController.propertiesPanelVisibleFor(widget.viewId)`），
///   主窗口沿用全局 `showPropertiesPanel`（M15 / FR-74 / ui-spec §26.6）；
/// - 滚动 / 光标 / 撤销栈：天然随 [NoteEditor] 自身的控制器独立。
///
/// 本组件**不 import `multiview_desktop`**，保持平台无关：真实多窗口实现只在
/// 桌面专属的 `platform/multi_window_io.dart` 里引用它。
class SuiNoteWindow extends StatefulWidget {
  const SuiNoteWindow({
    super.key,
    required this.noteId,
    required this.viewId,
  });

  /// 本窗口承载的笔记 id（一笔记一窗口，BR-43.3）。
  final String noteId;

  /// 本窗口的**公开视图 id**（`openWindow` 的 `childBuilder` 第二参）。
  ///
  /// 与 `NoteWindowManager.openNoteWindow` 登记到注册表的**窗口句柄同值**，故直接
  /// 用作 [NoteEditor.viewKey]，使菜单 / 快捷键命令派发到本窗口自己的编辑器（§5.1）。
  final int viewId;

  @override
  State<SuiNoteWindow> createState() => _SuiNoteWindowState();
}

class _SuiNoteWindowState extends State<SuiNoteWindow> {
  /// 窗口局部编辑三态；首帧读取持久化偏好前先用默认「格式」（详细设计 §5.2）。
  EditorMode _mode = EditorMode.formatted;

  /// 窗口局部修订面板显隐。
  bool _showRevisions = false;

  /// 是否已发起窗口局部三态的首帧读取（避免 `didChangeDependencies` 重复触发）。
  bool _modeLoaded = false;

  AppController get _controller => context.read<AppController>();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_modeLoaded) return;
    _modeLoaded = true;
    // 读取持久化的窗口局部三态（缺省 formatted，详细设计 §5.2 / §8）；
    // 异步返回后若窗口已卸载则丢弃结果。
    _controller.loadWindowNoteEditorMode().then((mode) {
      if (mounted && mode != _mode) setState(() => _mode = mode);
    });
  }

  /// 切换窗口局部三态：只改呈现，不保存、不入修订（守 BR-23.1）。
  void _setMode(EditorMode mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    // 尽力落盘（失败只记录不抛出）；与主窗口 `ui.editorMode` 各自独立。
    _controller.saveWindowNoteEditorMode(mode);
  }

  void _toggleRevisions() => setState(() => _showRevisions = !_showRevisions);

  @override
  Widget build(BuildContext context) {
    // M15（FR-74 / ui-spec §26.6）：属性面板显隐是**窗口局部**状态——按本窗口的视图键取，
    // 与主窗口的全局开关互不影响（在一个窗口开属性栏不会连带主窗口）。
    final showProperties =
        context.watch<AppController>().propertiesPanelVisibleFor(widget.viewId);

    // M15（FR-82 / BR-82.1）：**不渲染 Flutter 侧顶栏** —— 原先「笔记标题 + 同步 + 设置」
    // 那一行已整体删除；窗口操作由 OS 原生标题栏承载，笔记标题的编辑入口是下方
    // NoteEditor 自带的标题框（与旧顶栏同源，BR-82.3），故此处不再取标题。
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: NoteEditor(
              key: ValueKey(widget.noteId),
              // 命令桥按视图键登记：本窗口句柄（= 公开视图 id），使菜单 / 快捷键
              // 命令派发到本窗口的编辑器（详细设计 §5.1）。
              viewKey: widget.viewId,
              // 显式绑定该篇笔记：独立窗口**始终呈现**该笔记，不跟随主窗口的
              // `selectedNoteId`（后者会随主窗口浏览变化；两窗口两面并行）。
              noteId: widget.noteId,
              // 窗口局部三态（不与主窗口联动）。
              mode: _mode,
              onModeChanged: _setMode,
              // 窗口局部修订面板显隐。
              showRevisions: _showRevisions,
              onToggleRevisions: _toggleRevisions,
            ),
          ),
          // M15（FR-74 / BR-74.5 同口径）：右栏同一槽位在「属性」与「版本历史」之间
          // **二选一**（属性优先），避免两栏同时展开把编辑区压到不可用。
          if (showProperties) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: 320,
              child: NotePropertiesPanel(
                key: ValueKey(widget.noteId),
                noteId: widget.noteId,
              ),
            ),
          ] else if (_showRevisions) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: 320,
              child: RevisionPanel(
                key: ValueKey(widget.noteId),
                noteId: widget.noteId,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
