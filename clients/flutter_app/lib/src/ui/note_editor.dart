import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import '../platform/attachment_picker.dart';
import 'app_controller.dart';
import 'desktop_commands.dart';
import 'format_table.dart';
import 'markdown_editing_controller.dart';
import 'markdown_editor.dart';
import 'note_window_manager.dart';

/// 笔记编辑页：标题 + 格式工具栏 + Markdown 编辑器（格式 / 源码 / 预览三态） + 标签。
/// 编辑变更实时保存到仓储并追加一条修订。
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    this.viewKey = kMainViewKey,
    this.noteId,
    this.mode,
    this.onModeChanged,
    this.showRevisions = false,
    this.onToggleRevisions,
  });

  /// 本编辑器所属**视图**的键（M8 · 详细设计 §5.1）。
  ///
  /// 主窗口固定 [kMainViewKey]；独立笔记窗口取窗口句柄（M8-T10 注入）。
  /// 用于向 [AppController] 按视图注册命令桥，使菜单 / 快捷键命令派发到正确的窗口。
  final Object viewKey;

  /// 本编辑器呈现的笔记 id（M8-T10 · 详细设计 §4.2 / §5.2）。
  ///
  /// `null`（默认）= 跟随 [AppController.selectedNoteId]，即**主窗口**口径；独立笔记
  /// 窗口传入固定 `noteId`，使窗口**始终呈现**该笔记、不随主窗口选中变化（主窗口与
  /// 独立窗口两面并行，各自独立导航）。
  final String? noteId;

  /// 三态编辑模式的**显式来源**（M8-T10 · 详细设计 §5.2）。
  ///
  /// `null`（默认）= 跟随全局 [AppController.editorMode]（主窗口口径）；独立笔记窗口
  /// 传入**窗口局部**模式，避免与主窗口联动。
  final EditorMode? mode;

  /// 模式切换回调；`null` 时回落到 [AppController.setEditorMode]（主窗口口径）。
  final ValueChanged<EditorMode>? onModeChanged;

  /// 修订面板是否可见（M8-T10）。仅当 [onToggleRevisions] 非空时生效（独立窗口口径）；
  /// 主窗口保持默认，改用全局 [AppController.showRevisionPanel]。
  final bool showRevisions;

  /// 修订面板显隐切换回调；`null` 时回落到 [AppController.toggleRevisionPanel]。
  final VoidCallback? onToggleRevisions;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor>
    implements EditorCommandTarget {
  final TextEditingController _title = TextEditingController();
  final MarkdownEditingController _content = MarkdownEditingController();
  final TextEditingController _tagInput = TextEditingController();

  /// 共享撤销 / 重做控制器：正文输入与工具栏指令的写入落在同一个撤销栈上。
  final UndoHistoryController _undoHistory = UndoHistoryController();

  /// 正文焦点节点：工具栏执行指令后据此把焦点交还正文，便于连贯排版。
  final FocusNode _contentFocus = FocusNode();

  /// 是否有焦点落在嵌套的表格单元格内（含上下文操作按钮）。
  ///
  /// 单元格是 [_contentFocus] 的焦点子树：焦点在单元格时 [_contentFocus] 的
  /// `hasFocus` 仍为 true，正文会画出自己的光标，出现「两个光标」。据此在
  /// 单元格聚焦期间隐藏正文光标（见 [MarkdownEditor.showCursor]）。
  bool _tableHasFocus = false;

  List<String> _tags = [];
  List<Attachment> _attachments = [];

  /// 模式行「窄屏紧凑排布」的宽度阈值（逻辑像素，ui-spec §4.1 / B17）。
  ///
  /// 编辑区自身宽度小于该值时，三态切换只留图标、模式行与「历史 / 导出」压成一行，
  /// 把高度尽量让给正文编辑区。取 520 的依据：桌面壳层 1200x800 下编辑区约 612px
  /// （左栏 280 + 中栏 306 + 右栏 612）、1280x900 下约 665px，均高于阈值 —— 桌面与 e2e
  /// 用例仍能按文本找到「格式 / 源码 / 预览」；而手机竖屏（约 360~430px）低于阈值，
  /// 走紧凑排布，正是本次要修的窄屏场景。
  static const double _compactWidth = 520;

  /// 三态编辑模式：格式（默认）/ 源码 / 预览。正本始终是 Markdown。
  /// （M7-T06 上提为 [AppController] 的本地视图偏好，见下方 `_mode` getter。）
  bool _loaded = false;
  String? _loadedNoteId;

  /// 正在进行的「写回模型」次数。非零期间禁止用模型内容重绑输入框，
  /// 否则每次敲字触发的保存都会重置标题/正文，selection 被置回 -1，光标跳行首。
  int _pendingSaves = 0;

  /// 已注册到 [AppController] 的命令桥引用（M7-T08，详细设计 §4.2）。
  ///
  /// 注册发生在 `initState`，注销发生在 `dispose`——而 `dispose` 内不能再查 `context`
  /// （元素已失活），因此在此留存注册时的实例，供注销复用。
  AppController? _registeredController;

  /// 注册命令桥时所用的**视图键**，供 `dispose` 注销复用（M8 · 详细设计 §5.1）。
  ///
  /// 与 [_registeredController] 同生共死；同样是因为 `dispose` 内不能读 `widget`。
  Object? _registeredViewKey;

  @override
  void initState() {
    super.initState();
    // 格式模式：把 `![alt](sui://<sha256>){尺寸}` 渲染为图片呈现单元（FR-27）。
    _content.formatImageBuilder = _buildFormatImage;
    // 格式模式：把任务项 `- [ ]` / `- [x]` 的勾选框渲染为可点选复选框（§10.1）。
    _content.formatTaskCheckboxBuilder = _buildTaskCheckbox;
    _content.onToggleTask = _toggleTask;
    // 格式模式：把附件链接引用 `[name](sui://<sha256>)` 渲染为原子呈现单元（FR-46）。
    _content.formatAttachmentLinkBuilder = _buildAttachmentLink;
    // 格式模式：把整块 GFM 管道表渲染为可交互「表格呈现单元」（FR-44 / §12.1）。
    _content.formatTableBuilder = _buildFormatTable;
    // 向壳层登记命令桥（FR-41）：登记后「编辑 / 文件」菜单中作用于正文的命令才可用。
    // 此处刻意不触发 notifyListeners——注册发生在构建阶段，通知会撞上「构建期重建」断言；
    // 菜单项的可用性是在菜单展开时按 `isEnabled` 现算的，无需依赖通知。
    _registeredController = _controller;
    _registeredViewKey = widget.viewKey;
    _registeredController!.registerEditorTarget(_registeredViewKey!, this);
  }

  @override
  void dispose() {
    final controller = _registeredController;
    final viewKey = _registeredViewKey;
    if (controller != null && viewKey != null) {
      // 带身份校验注销：同视图键下新旧编辑器交替时，旧实例不得删掉新实例的登记。
      controller.unregisterEditorTarget(viewKey, this);
    }
    _registeredController = null;
    _registeredViewKey = null;
    _title.dispose();
    _content.dispose();
    _tagInput.dispose();
    _undoHistory.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  AppController get _controller => context.read<AppController>();

  /// 三态编辑模式（M7-T06 上提，详细设计 §5.1）：优先取**显式**模式（独立窗口的
  /// 窗口局部状态），否则取 [AppController] 的本地视图偏好（主窗口）。
  ///
  /// 不再随切换笔记重置（`NoteEditor(key: ValueKey(noteId))` 重建 State 与否都稳定）；
  /// 三态共享同一 Markdown 正本，切换只改呈现，不保存、不入修订（守 BR-23.1）。
  EditorMode get _mode => widget.mode ?? _controller.editorMode;

  /// 切换三态：显式回调优先（独立窗口写窗口局部状态），否则回落到控制器（主窗口）。
  void _setMode(EditorMode mode) {
    final onChanged = widget.onModeChanged;
    if (onChanged != null) {
      onChanged(mode);
    } else {
      _controller.setEditorMode(mode);
    }
  }

  /// 本编辑器绑定的笔记 id：显式 [NoteEditor.noteId] 优先，否则跟随主窗口选中项
  /// （M8-T10 · 详细设计 §5.2）。
  String? get _noteId => widget.noteId ?? _controller.selectedNoteId;

  /// 当前笔记，**不受中栏筛选影响**（M8-T10 · AC-125）。
  ///
  /// 走 `AppController.noteById`：先查中栏列表，再回落独立窗口摘要缓存——独立窗口
  /// 承载的笔记可能不在主窗口中栏的筛选结果里，直接读 `controller.notes` 会取不到。
  Note? get _note => _controller.noteById(_noteId);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 仅首次依赖解析时载入；后续切换笔记 / 外部变化统一交给 build 判断，
    // 避免保存过程中被无条件重绑导致光标跳动。
    if (!_loaded) _loadNote();
  }

  void _loadNote() {
    final note = _note;
    if (note != null) {
      _title.text = note.title;
      _content.text = note.contentMarkdown;
      final s =
          _controller.notes.where((s) => s.note.id == note.id).firstOrNull;
      _tags = s?.tags ?? _controller.tagsById(note.id);
      _loaded = true;
      _boundTitle = note.title;
      _boundContent = note.contentMarkdown;
    }
    if (note?.id != _loadedNoteId) {
      _loadedNoteId = note?.id;
      if (note != null) {
        _controller.refreshAttachments(note.id).then((list) {
          _attachments = list;
          if (mounted) setState(() {});
        });
      } else {
        _attachments = [];
      }
    }
  }

  /// 上一次绑定到输入框的标题 / 正文。
  ///
  /// 仅当底层内容真正被外部改写时才重绑输入框：`Notes.version` 在 push 成功后
  /// 会作为「服务端基线镜像」被回写（`setNoteServerVersion`），此时内容并未变化，
  /// 不能据此重绑，否则正在输入的字词会被同步刷掉。
  String? _boundTitle;
  String? _boundContent;

  bool _hasExternalChange(Note note) =>
      !_loaded ||
      note.title != _boundTitle ||
      note.contentMarkdown != _boundContent;

  Future<void> _save() async {
    final id = _noteId;
    if (id == null) return;
    _pendingSaves++;
    try {
      await _controller.saveNote(
        id,
        title: _title.text,
        content: _content.text,
        tags: _tags,
      );
    } finally {
      _pendingSaves--;
      // 全部保存落盘后对齐基线，避免后续 build 把自身保存误判为外部变化。
      if (_pendingSaves == 0) {
        final note = _note;
        if (note != null) {
          _boundTitle = note.title;
          _boundContent = note.contentMarkdown;
        }
      }
    }
  }

  /// 格式工具栏：一行可横向滚动的排版指令。每条指令都只在正本 Markdown 上做
  /// 纯文本改写（`EditorFormat`），不回写中间态，保证「格式 / 源码」所见一致。
  ///
  /// 按钮**自左向右按使用频度排布**（ui-spec §12 / BR-23.6）：
  /// 高频（加粗、勾选框、撤销 / 重做、斜体、删除线、高亮）→ 中频（无序 / 有序列表、
  /// 缩进、引用、代码块、表格、链接、图片、附件、分割线）→ 低频靠右（标题一~三级）。
  /// 顺序调整**不改变**任一按钮的语义与产出。
  Widget _buildFormatToolbar() {
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // —— 高频区 ——
            _fmtIcon(Icons.format_bold, '加粗', FormatCommand.bold),
            _fmtIcon(Icons.check_box_outlined, '勾选框', FormatCommand.taskList),
            // 撤销 / 重做：与正文输入共用同一个撤销栈，故按钮可用性随其变化重绘。
            ListenableBuilder(
              listenable: _undoHistory,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '撤销',
                    icon: const Icon(Icons.undo),
                    onPressed: _undoHistory.value.canUndo
                        ? () => _undoHistory.undo()
                        : null,
                  ),
                  IconButton(
                    tooltip: '重做',
                    icon: const Icon(Icons.redo),
                    onPressed: _undoHistory.value.canRedo
                        ? () => _undoHistory.redo()
                        : null,
                  ),
                ],
              ),
            ),
            _fmtIcon(Icons.format_italic, '斜体', FormatCommand.italic),
            _fmtIcon(
              Icons.format_strikethrough,
              '删除线',
              FormatCommand.strikethrough,
            ),
            _fmtIcon(Icons.format_color_fill, '高亮', FormatCommand.highlight),
            // —— 中频区 ——
            const _ToolbarDivider(),
            _fmtIcon(
              Icons.format_list_bulleted,
              '无序列表',
              FormatCommand.bulletList,
            ),
            _fmtIcon(
              Icons.format_list_numbered,
              '有序列表',
              FormatCommand.orderedList,
            ),
            _fmtIcon(
              Icons.format_indent_increase,
              '缩进',
              FormatCommand.indent,
            ),
            _fmtIcon(
              Icons.format_indent_decrease,
              '反缩进',
              FormatCommand.outdent,
            ),
            const _ToolbarDivider(),
            _fmtIcon(Icons.format_quote, '引用', FormatCommand.blockquote),
            _fmtIcon(Icons.data_object, '代码块', FormatCommand.codeBlock),
            // 表格入口（ui-spec §18.1 / FR-44）：弹出「插入表格」面板，自定义行列数。
            // 与「编辑」菜单的等价项同源（命令单一来源，承 §16.2）。
            IconButton(
              tooltip: '表格',
              icon: const Icon(Icons.table_chart_outlined),
              onPressed: _openTablePanel,
            ),
            const _ToolbarDivider(),
            _fmtIcon(Icons.link, '链接', FormatCommand.link),
            IconButton(
              tooltip: '插入图片',
              icon: const Icon(Icons.image_outlined),
              onPressed: _pickAndAttach,
            ),
            // 附件入口（ui-spec §4）：以弹窗「附件面板」列出 / 增删附件。
            // 原先常驻底部的附件条已移除，为窄屏编辑腾出高度（B17，AC-135）。
            IconButton(
              tooltip: '附件',
              icon: const Icon(Icons.attach_file),
              onPressed: _openAttachmentPanel,
            ),
            _fmtIcon(Icons.horizontal_rule, '分割线', FormatCommand.divider),
            const _ToolbarDivider(),
            _fmtIcon(Icons.format_clear, '简化格式', FormatCommand.clearFormat),
            // —— 低频区（靠右） ——
            const _ToolbarDivider(),
            _fmtIcon(Icons.looks_one_outlined, '标题 1', FormatCommand.heading1),
            _fmtIcon(Icons.looks_two_outlined, '标题 2', FormatCommand.heading2),
            _fmtIcon(Icons.looks_3_outlined, '标题 3', FormatCommand.heading3),
          ],
        ),
      ),
    );
  }

  Widget _fmtIcon(IconData icon, String tooltip, FormatCommand command) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: () => _applyCommand(command),
    );
  }

  /// 对当前选区执行排版指令，并把结果即时回写正本。
  void _applyCommand(FormatCommand command) {
    final value = _content.value;
    // 光标失焦时 selection 为 -1；此时以文末作为落点，避免指令无处施加。
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    _writeBack(EditorFormat.apply(command, value.text, start, end));
  }

  /// 格式模式下把任务项勾选框渲染为可点选复选框；点选即原地切换并回写正本。
  Widget _buildTaskCheckbox(
    BuildContext context, {
    required bool checked,
    required VoidCallback onToggle,
  }) {
    return _TaskCheckbox(checked: checked, onToggle: onToggle);
  }

  /// 切换某任务项所在行的勾选态，仅改方括号内一个字符（BR-31.2）。
  void _toggleTask(int lineStart) {
    final result = EditorFormat.toggleTaskChecked(_content.text, lineStart);
    if (result == null) return;
    _writeBack(result);
  }

  /// 格式模式下回车先经「空块交互」处理（§11.2 / BR-32.4）：空列表项退出列表、
  /// 任务项续行、空引用行退出引用。命中则原地改写正本并返回 true，未命中返回
  /// false，交由默认换行。仅在格式模式 + 折叠光标时生效，保证两态内容一致（AC-92）。
  bool _handleBlockNewline() {
    if (_mode != EditorMode.formatted) return false;
    final sel = _content.value.selection;
    if (!sel.isValid || !sel.isCollapsed) return false;
    final result = EditorFormat.blockNewline(_content.text, sel.extentOffset);
    if (result == null) return false;
    _writeBack(result);
    return true;
  }

  /// 格式模式下 Shift+Enter：表格单元格内插入 `<br>` 软换行。
  bool _handleSoftNewline() {
    if (_mode != EditorMode.formatted) return false;
    final sel = _content.value.selection;
    if (!sel.isValid || !sel.isCollapsed) return false;
    final result =
        EditorFormat.tableSoftNewline(_content.text, sel.extentOffset);
    if (result == null) return false;
    _writeBack(result);
    return true;
  }

  /// 格式模式下把附件链接引用 `[name](sui://<sha256>)` 渲染为原子呈现单元（FR-46）。
  Widget _buildAttachmentLink(BuildContext context, AttachmentRef ref) {
    final sel = _content.value.selection;
    final selected = sel.isValid &&
        sel.isCollapsed &&
        sel.start >= ref.start &&
        sel.start <= ref.end;
    final att = _attachments.where((a) => a.sha256 == ref.sha256).firstOrNull;
    return _FormatAttachmentLinkUnit(
      label: ref.label,
      isImage: ref.isImage,
      corrupt: ref.corrupt,
      selected: selected,
      onSelect: () => _selectAttachmentLink(ref),
      onDoubleTap: att != null ? () => _openAttachment(att) : null,
    );
  }

  /// 选中附件链接引用：把光标落到引用末尾，与图片选中口径一致（便于尺寸条 / 后续操作）。
  void _selectAttachmentLink(AttachmentRef ref) {
    final pos = ref.end.clamp(0, _content.text.length);
    _content.value = TextEditingValue(
      text: _content.text,
      selection: TextSelection.collapsed(offset: pos),
    );
    if (_mode != EditorMode.preview) _contentFocus.requestFocus();
  }

  /// 格式模式下退格 / 删除键的附件引用处理（FR-46 / §12.4）。
  ///
  /// 优先级：残缺引用**就地修复**（补 `)`，AC-147）→ 引用边界**整块删除**
  /// （AC-145 / AC-146）。命中返回 true 抑制默认逐字符删除；未命中返回 false。
  /// 仅在格式模式 + 折叠光标时生效，源码模式保持原始文本语义（AC-147）。
  bool _handleAttachmentDelete({required bool backspace}) {
    if (_mode != EditorMode.formatted) return false;
    final sel = _content.value.selection;
    if (!sel.isValid || !sel.isCollapsed) return false;
    final text = _content.text;
    final at = EditorFormat.attachmentRefAt(text, sel.extentOffset);
    if (at != null && at.corrupt) {
      _writeBack(EditorFormat.repairAttachmentRef(text, at));
      return true;
    }
    final ref = EditorFormat.attachmentRefForDeletion(
      text,
      sel.extentOffset,
      backspace: backspace,
    );
    if (ref == null) return false;
    _writeBack(EditorFormat.deleteAttachmentRef(text, ref));
    return true;
  }

  /// 快捷键映射（§9）：与工具栏指令**同源**，仅改写正本、不产生新保存语义。
  ///
  /// 只在「格式模式」下挂载，且位于正文编辑区子树内，故天然满足「正文编辑区聚焦 +
  /// 格式模式」的作用域（BR-30.2 / BR-30.5）。未列出的键（如撤销 / 重做）继续冒泡到
  /// EditableText 的默认文本编辑快捷键。对已应用格式再次触发即取消 / 降级（§9）。
  static const Map<ShortcutActivator, Intent> _formatShortcuts = {
    SingleActivator(LogicalKeyboardKey.keyB, control: true):
        _FormatIntent(FormatCommand.bold),
    SingleActivator(LogicalKeyboardKey.keyI, control: true):
        _FormatIntent(FormatCommand.italic),
    SingleActivator(LogicalKeyboardKey.keyT, control: true):
        _FormatIntent(FormatCommand.strikethrough),
    SingleActivator(LogicalKeyboardKey.keyH, control: true, shift: true):
        _FormatIntent(FormatCommand.highlight),
    SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
        _FormatIntent(FormatCommand.taskList),
    SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true):
        _FormatIntent(FormatCommand.bulletList),
    SingleActivator(LogicalKeyboardKey.keyO, control: true, shift: true):
        _FormatIntent(FormatCommand.orderedList),
    SingleActivator(LogicalKeyboardKey.keyQ, control: true, shift: true):
        _FormatIntent(FormatCommand.blockquote),
    SingleActivator(LogicalKeyboardKey.keyK, control: true, shift: true):
        _FormatIntent(FormatCommand.codeBlock),
    SingleActivator(LogicalKeyboardKey.minus, control: true, shift: true):
        _FormatIntent(FormatCommand.divider),
    SingleActivator(LogicalKeyboardKey.keyK, control: true):
        _FormatIntent(FormatCommand.link),
    SingleActivator(LogicalKeyboardKey.digit1, control: true, alt: true):
        _FormatIntent(FormatCommand.heading1),
    SingleActivator(LogicalKeyboardKey.digit2, control: true, alt: true):
        _FormatIntent(FormatCommand.heading2),
    SingleActivator(LogicalKeyboardKey.digit3, control: true, alt: true):
        _FormatIntent(FormatCommand.heading3),
    SingleActivator(LogicalKeyboardKey.keyM, control: true):
        _FormatIntent(FormatCommand.indent),
    SingleActivator(LogicalKeyboardKey.keyM, control: true, shift: true):
        _FormatIntent(FormatCommand.outdent),
    SingleActivator(LogicalKeyboardKey.space, control: true):
        _FormatIntent(FormatCommand.clearFormat),
    // `Ctrl+Shift+V`（纯文本粘贴）为编辑器自有的显式入口（FR-45 / §12.2）。
    // 注意：`Ctrl+V`（富文本粘贴）**不在此声明**——它沿用系统默认的文本编辑快捷键，
    // 以免抢占剪贴板级按键（BR-30.2 / AC-88）；格式模式通过覆写 `PasteTextIntent`
    // 对应的 Action 来接管其行为（见 [_formatActions]）。
    SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
        _PasteIntent(rich: false),
  };

  /// 快捷键动作：统一落到 [_applyCommand]，保证与工具栏「同源同效」（BR-30.4）。
  Map<Type, Action<Intent>> _formatActions() => {
        _FormatIntent: CallbackAction<_FormatIntent>(
          onInvoke: (intent) {
            _applyCommand(intent.command);
            return null;
          },
        ),
        _PasteIntent: CallbackAction<_PasteIntent>(
          onInvoke: (intent) {
            _pasteFromClipboard(rich: intent.rich);
            return null;
          },
        ),
        // 覆写系统默认粘贴：格式模式下 `Ctrl+V` 优先富文本（FR-45 / §12.2）。
        // 采用 Action 覆写而非在 `Shortcuts` 中声明 `Ctrl+V`，以满足 BR-30.2「不抢占
        // 剪贴板级按键」：键位仍归系统默认文本编辑快捷键，仅行为由本层接管。
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (intent) {
            _pasteFromClipboard(rich: true);
            return null;
          },
        ),
      };

  /// 仅在格式模式下把编辑区包进 [Shortcuts] / [Actions]；其余模式直连（BR-30.5）。
  Widget _wrapShortcuts(Widget child) {
    if (_mode != EditorMode.formatted) return child;
    return Shortcuts(
      shortcuts: _formatShortcuts,
      child: Actions(actions: _formatActions(), child: child),
    );
  }

  /// 把指令产物写回正文控制器并恢复选区，随后即时保存。
  ///
  /// 通过 `controller.value` 整体赋值（而非只改 `text`），既能让 EditableText 的
  /// 原生撤销栈记录这次程序化写入，也能把选区落到 `FormatResult` 指定的位置。
  void _writeBack(FormatResult result) {
    final text = result.text;
    final start = result.selectionStart.clamp(0, text.length);
    final end = result.selectionEnd.clamp(0, text.length);
    _content.value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end),
    );
    // 点工具栏会让正文失焦；交还焦点，排版后可立即继续输入。
    if (_mode != EditorMode.preview) _contentFocus.requestFocus();
    _save();
  }

  /// 把「表格结构 / 内容」类编辑的产物写回正文并即时保存（FR-44 / §12.1）。
  ///
  /// `EditorFormat` 的表格族 API（`setTableCell` / `insertTableRow` / …）返回**改写后的
  /// 正本字符串**而不携带选区，故此处不指定新选区：沿用编辑前的选区（就近钳制），
  /// 从而**不抢占焦点**——用户可能正在某个单元格内输入，夺焦会中断连续编辑。
  void _writeBackTable(String newText) {
    final sel = _content.value.selection;
    final base =
        (sel.isValid ? sel.start : newText.length).clamp(0, newText.length);
    final extent = (sel.isValid ? sel.end : base).clamp(0, newText.length);
    _content.value = TextEditingValue(
      text: newText,
      selection: TextSelection(baseOffset: base, extentOffset: extent),
    );
    _save();
  }

  /// 粘贴：按 [rich] 选择来源，产物**直接写入正本**并即时保存（FR-45 / §12.2）。
  ///
  /// `Ctrl+V`（[rich] 为 true）**优先读取剪贴板 HTML 表示**，复用与剪藏同源的
  /// [EditorFormat.htmlToMarkdown] 转成语义等价的 Markdown；无 HTML 表示时回退纯文本，
  /// 并用 [EditorFormat.escapePlainText] 转义 Markdown 特殊字符。`Ctrl+Shift+V`
  /// （[rich] 为 false）**仅取纯文本**。结果作为一次编辑落库，不产生中间态。
  Future<void> _pasteFromClipboard({required bool rich}) async {
    String? html;
    if (rich) {
      try {
        html = (await Clipboard.getData('text/html'))?.text;
      } catch (_) {
        html = null; // 平台不提供 text/html 表示时静默回退纯文本。
      }
    }
    final plain = (await Clipboard.getData(Clipboard.kTextPlain))?.text;

    final String? payload;
    if (rich && html != null && html.trim().isNotEmpty) {
      payload = EditorFormat.htmlToMarkdown(html);
    } else if (plain != null && plain.isNotEmpty) {
      payload = EditorFormat.escapePlainText(plain);
    } else {
      payload = null;
    }
    if (payload == null || payload.isEmpty || !mounted) return;

    final value = _content.value;
    final text = value.text;
    final sel = value.selection;
    final start = (sel.isValid ? sel.start : text.length).clamp(0, text.length);
    final end = (sel.isValid ? sel.end : start).clamp(0, text.length);
    final caret = start + payload.length;
    _writeBack(
        FormatResult(text.replaceRange(start, end, payload), caret, caret));
  }

  /// 用**当前正本**重新解析同一个表格块，得到与正本一致的最新结构。
  ///
  /// 表格族编辑（尤其单元格提交）可能在闭包捕获的 [fallback] 之后又发生了别的写入；
  /// 以 [fallback] 的起点重新解析，能在结构未变时拿回新鲜数据，解析失败则退回 [fallback]。
  ParsedTable _resolveTable(ParsedTable fallback) {
    final parsed = EditorFormat.parseTable(_content.text, fallback.start);
    if (parsed != null && parsed.start == fallback.start) return parsed;
    return fallback;
  }

  // ---------------------------------------------------------------------------
  // 图片尺寸调整（ADR-007 / M2-T07）
  // ---------------------------------------------------------------------------

  /// 光标落在某个图片引用（含属性块）范围内时返回该图片，否则 null。
  ///
  /// 只在折叠选区（纯光标）时检测；选中文本时不弹尺寸条，避免与选区操作冲突。
  ParsedImage? get _imageAtCursor {
    final sel = _content.value.selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    final pos = sel.start;
    final text = _content.text;
    var from = 0;
    while (true) {
      final img = EditorFormat.findImage(text, from);
      if (img == null) return null;
      final spanEnd = img.attributeEnd > 0 ? img.attributeEnd : img.end;
      if (pos >= img.start && pos <= spanEnd) return img;
      from = spanEnd;
    }
  }

  /// 格式模式下把图片引用渲染为图片呈现单元：点按即选中（把光标落到引用内），
  /// 尺寸条随光标出现；`sui://` 走附件缓存，字节未就绪时显示占位（BR-27.1/27.3）。
  ///
  /// [block] 为 true 表示该引用独占一块（§5.5），按**块级呈现单元**布局：
  /// 块宽即段落宽、块高向下扩展，后续文字整体下移；为 false 表示历史行内引用，
  /// 保持既有行内呈现（§5.5「行内引用兼容」）。
  Widget _buildFormatImage(
    BuildContext context,
    ParsedImage image, {
    bool? block,
  }) {
    final sel = _content.value.selection;
    final spanEnd = image.attributeEnd > 0 ? image.attributeEnd : image.end;
    final selected = sel.isValid &&
        sel.isCollapsed &&
        sel.start >= image.start &&
        sel.start <= spanEnd;
    final uri = Uri.tryParse(image.url);
    final isSui = uri != null && uri.scheme == 'sui';
    final att = isSui
        ? _attachments.where((a) => a.sha256 == uri.host).firstOrNull
        : null;
    return _FormatImageUnit(
      image: image,
      selected: selected,
      block: block ?? false,
      onSelect: () => _selectImage(image),
      onDoubleTap: att != null ? () => _openAttachment(att) : null,
    );
  }

  /// 选中某个图片：把光标置于引用（含属性块）末尾，与 [_imageAtCursor] 的判定
  /// 对齐，从而弹出尺寸条（BR-27.2）。
  void _selectImage(ParsedImage image) {
    final spanEnd = image.attributeEnd > 0 ? image.attributeEnd : image.end;
    final pos = spanEnd.clamp(0, _content.text.length);
    _content.value = TextEditingValue(
      text: _content.text,
      selection: TextSelection.collapsed(offset: pos),
    );
    if (_mode != EditorMode.preview) _contentFocus.requestFocus();
  }

  /// 对指定图片应用尺寸，只重写其属性块，其余字符不动（BR-24.1）。
  ///
  /// 写回后把光标置于图片引用末尾（`image.end`），确保仍在图片范围内，
  /// 便于连续切换预设或拖拽滑块。
  void _applyImageSize(ParsedImage image, ImageSize? size) {
    final newText = EditorFormat.setImageSize(_content.text, image, size);
    // image.end 始终在 setImageSize 产出的新文本中有效（该方法只改写属性块，
    // 图片引用部分位置不变）。
    final pos = image.end.clamp(0, newText.length);
    _content.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: pos),
    );
    _contentFocus.requestFocus();
    _save();
  }

  /// 表格单元格（含上下文操作按钮）聚焦变化的回调：据以触发重建，切换正文光标的
  /// 显隐（[MarkdownEditor.showCursor]），消除「两个光标」并配合正文点击显式取回焦点。
  void _setTableFocus(bool focused) {
    if (_tableHasFocus == focused) return;
    setState(() => _tableHasFocus = focused);
  }

  /// 格式模式下把整块 GFM 管道表渲染为可交互「表格呈现单元」（FR-44 / §12.1）。
  ///
  /// 表格为**独占块**，宽按可用段落宽计算（`LayoutBuilder`，无界时退回 720），列较多时
  /// 以横向滚动兜底，避免溢出编辑区（BR-44.1）。单元格内容 / 增删行列 / 列对齐全部经
  /// [EditorFormat] 纯函数**整体回写正本**，未编辑的单元格逐字保真（BR-44.2）；呈现为
  /// 视图层行为，源码 / 预览两态内容不受影响。
  Widget _buildFormatTable(BuildContext context, ParsedTable table) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 内联子组件受段落宽度约束；无界时退回一个稳妥的段落宽（同 [_FormatImageUnit]）。
        final available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 720.0;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Focus(
            onFocusChange: _setTableFocus,
            child: FormatTableView(
              table: table,
              availableWidth: available,
              onSetCell: (rowIndex, column, value) {
                final t = _resolveTable(table);
                _writeBackTable(
                  EditorFormat.setTableCell(
                    _content.text,
                    t,
                    rowIndex,
                    column,
                    value,
                  ),
                );
              },
              onInsertRow: (rowIndex, after) {
                final t = _resolveTable(table);
                _writeBackTable(
                  EditorFormat.insertTableRow(
                    _content.text,
                    t,
                    rowIndex,
                    after: after,
                  ),
                );
              },
              onRemoveRow: (rowIndex) {
                final t = _resolveTable(table);
                _writeBackTable(
                  EditorFormat.removeTableRow(_content.text, t, rowIndex),
                );
              },
              onInsertColumn: (column, after) {
                final t = _resolveTable(table);
                // `after < 0` 表示插到最前：某列「左侧插入」即在其**前一列之后**插入。
                _writeBackTable(
                  EditorFormat.addTableColumn(
                    _content.text,
                    t,
                    after: after ? column : column - 1,
                  ),
                );
              },
              onRemoveColumn: (column) {
                final t = _resolveTable(table);
                _writeBackTable(
                  EditorFormat.removeTableColumn(_content.text, t, column),
                );
              },
              onSetAlignment: (column, align) {
                final t = _resolveTable(table);
                _writeBackTable(
                  EditorFormat.setTableAlignment(
                      _content.text, t, column, align),
                );
              },
              onInsertAttachment: (rowIndex, column) =>
                  _attachIntoCell(table, rowIndex, column),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 订阅 [AppController]：编辑器须随其重建（首次载入依赖解析、内容被同步改写、
    // 主窗口选中项切换）。独立窗口的 noteId 固定，但同样需要内容变化后重绘，
    // 故此处保留 watch 只作依赖登记，实际取值走 [_noteId]（M8-T10 · §5.2）。
    context.watch<AppController>();
    final id = _noteId;
    // 仅在「首次载入 / 切换到另一篇笔记 / 内容被外部改写（恢复修订、同步拉取）」
    // 时重绑输入框。判定依据是标题 / 正文内容是否真的变了，而非 version：
    // `updateNoteContent` 不改 `Notes.version`，而 push 成功后 `setNoteServerVersion`
    // 会把 `Notes.version` 回写为服务端基线（内容不变），若用 version 判定，会在
    // 输入过程中误判为外部变化并重绑，把已敲入的字词刷掉。
    final note = _note;
    final switched = note != null && note.id != _loadedNoteId;
    if (note != null &&
        (switched || (_pendingSaves == 0 && _hasExternalChange(note)))) {
      _loadNote();
    }
    if (id == null) {
      return const _EmptyEditor();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _title,
                  onChanged: (_) => _save(),
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    hintText: '标题',
                    border: InputBorder.none,
                  ),
                ),
              ),
              // 标签入口（ui-spec §4 / BR-21.4）：标题行**右上角图标**、与标题同行，
              // 点击弹出标签浮层；标签**不再单独占用一行**。
              Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _buildTagEntry()),
            ],
          ),
        ),
        const Divider(height: 1),
        // 窄屏 / 宽屏两套排布（ui-spec §4.1，B17）：
        //   窄屏——三态切换只留图标，与「历史 / 导出」入口压成一行、上下留白收紧，
        //         把高度尽量让给正文编辑区（键盘弹出后空间尤其紧张）；
        //   宽屏——沿用原来的 Wrap 自适应（B14），三态保留文本标签，入口不缩水。
        // 判据是编辑区自身宽度，而非平台：桌面端把两栏折叠后编辑区可能很窄，
        // 而平板宽屏仍应有完整按钮。
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < _compactWidth;
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 8,
                vertical: compact ? 2 : 8,
              ),
              child: compact ? _buildCompactModeBar() : _buildModeBar(),
            );
          },
        ),
        // 格式工具栏只在可编辑的两态（格式 / 源码）下出现；预览态是只读渲染，
        // 不给排版入口，避免「点了没反应」的困惑。
        if (_mode != EditorMode.preview) ...[
          const Divider(height: 1),
          _buildFormatToolbar(),
          // 图片尺寸条：点选 / 光标落在图片引用内时出现。用 ListenableBuilder
          // 监听正文控制器 —— 光标移动不会触发本组件重建，靠它才能即时显隐
          // （BR-27.2：点按图片即选中并显示手柄，不以光标落入引用跨度为前提）。
          ListenableBuilder(
            listenable: _content,
            builder: (context, _) {
              final image = _imageAtCursor;
              if (image == null) return const SizedBox.shrink();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Divider(height: 1),
                  _ImageSizeBar(
                    image: image,
                    onApply: (size) => _applyImageSize(image, size),
                  ),
                ],
              );
            },
          ),
        ],
        const Divider(height: 1),
        Expanded(
          child: _wrapShortcuts(
            MarkdownEditor(
              controller: _content,
              mode: _mode,
              onChanged: () => _save(),
              imageBuilder: _buildImage,
              undoController: _undoHistory,
              focusNode: _contentFocus,
              showCursor: !_tableHasFocus,
              onBlockNewline:
                  _mode == EditorMode.formatted ? _handleBlockNewline : null,
              onSoftNewline:
                  _mode == EditorMode.formatted ? _handleSoftNewline : null,
              onAttachmentDelete: _mode == EditorMode.formatted
                  ? _handleAttachmentDelete
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  /// 窄屏紧凑模式行：三态切换（图标态）+ 历史 / 导出，压成一行（ui-spec §4.1，B17）。
  ///
  /// 三态按钮在窄屏只留图标：三个带文本标签的分段在手机上会挤出屏幕，
  /// 一旦换行就吃掉一整行编辑高度——这正是本次要修的问题。
  Widget _buildCompactModeBar() {
    return Row(
      children: [
        _buildModeSelector(compact: true),
        const Spacer(),
        ..._buildActionIcons(),
      ],
    );
  }

  /// 宽屏模式行：沿用原有 Wrap 自适应（B14），三态保留文本标签。
  Widget _buildModeBar() {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4,
      spacing: 12,
      children: [
        _buildModeSelector(compact: false),
        Row(mainAxisSize: MainAxisSize.min, children: _buildActionIcons()),
      ],
    );
  }

  /// 三态切换控件。三态只切换「怎么画 / 能不能改」，正本不变，故切换不保存
  /// （守 BR-23.1）；状态写入 [AppController] 单一状态源（M7-T06 上提），
  /// 与桌面「视图」菜单同源同效。
  Widget _buildModeSelector({required bool compact}) {
    return SegmentedButton<EditorMode>(
      segments: [
        ButtonSegment(
          value: EditorMode.formatted,
          label: compact ? null : const Text('格式'),
          icon: const Icon(Icons.text_fields),
        ),
        ButtonSegment(
          value: EditorMode.source,
          label: compact ? null : const Text('源码'),
          icon: const Icon(Icons.code),
        ),
        ButtonSegment(
          value: EditorMode.preview,
          label: compact ? null : const Text('预览'),
          icon: const Icon(Icons.visibility_outlined),
        ),
      ],
      selected: {_mode},
      onSelectionChanged: (sel) => _setMode(sel.first),
      showSelectedIcon: false,
    );
  }

  /// 模式行右侧的两个动作入口：版本历史 / 导出 Markdown。
  ///
  /// 「附件」入口不在此处——它落在格式工具栏（见 [EditorFormat] 上一个回形针按钮），
  /// 免得同一能力在编辑区出现两个入口（ui-spec §4 / §4.1）。
  List<Widget> _buildActionIcons() {
    return [
      IconButton(
        tooltip: '版本历史',
        icon: const Icon(Icons.history),
        // 独立窗口传入 onToggleRevisions → 用窗口局部可见性；主窗口沿用全局状态。
        isSelected: widget.onToggleRevisions != null
            ? widget.showRevisions
            : context.watch<AppController>().showRevisionPanel,
        onPressed: widget.onToggleRevisions ?? _controller.toggleRevisionPanel,
      ),
      IconButton(
        tooltip: '导出 Markdown',
        icon: const Icon(Icons.file_download_outlined),
        onPressed: () => _showExportDialog(),
      ),
    ];
  }

  /// 预览里的图片：`sui://<sha256>` 走附件缓存（本地命中或按需下载），
  /// 其余交给默认的 `Image.network`。
  Widget _buildImage(MarkdownImageConfig config) {
    final uri = config.uri;
    final label = config.alt ?? config.title ?? uri.toString();
    if (uri.scheme != 'sui') {
      return Image.network(
        uri.toString(),
        width: config.width,
        height: config.height,
        errorBuilder: (_, __, ___) => _AttachmentPlaceholder(label: label),
      );
    }
    return _SuiAttachmentImage(
      sha256: uri.host,
      label: config.alt ?? config.title ?? '附件',
      width: config.width,
      height: config.height,
    );
  }

  /// 选择文件并挂到当前笔记上，同时在正文里插入 `![](sui://<sha256>)` 引用。
  ///
  /// 引用写进正文是刻意的：canonical 正本只有 Markdown，附件与正文必须一起
  /// 同步，否则换台设备拉到笔记却不知道它带附件。
  ///
  /// 图片在光标处插入（`EditorFormat.insertImage`），而非总是追加到文末——
  /// 这样用户在正文中间也能就地插图。
  Future<void> _pickAndAttach() async {
    final id = _noteId;
    if (id == null) return;

    // 在打开文件选择器之前记下光标位置；选择器是异步的，回来时光标可能已移动。
    final sel = _content.value.selection;
    var insertAt = sel.isValid ? sel.start : _content.text.length;

    List<PickedAttachment> picked;
    try {
      picked = await pickAttachments();
    } catch (e) {
      _toast('打开文件选择器失败：$e');
      return;
    }
    if (picked.isEmpty) return;

    var text = _content.text;
    var count = 0;
    for (final f in picked) {
      try {
        final att = await _controller.addAttachmentFromBytes(
          noteId: id,
          filename: f.filename,
          bytes: f.bytes,
        );
        final result = EditorFormat.insertImage(
          text,
          insertAt,
          insertAt,
          filename: att.filename,
          sha256: att.sha256,
        );
        text = result.text;
        insertAt = result.selectionStart;
        count++;
      } catch (e) {
        _toast('附件「${f.filename}」添加失败：$e');
      }
    }
    if (count == 0) return;

    // 以「按本笔记刷新」的**返回值**为准，避免与其它窗口刷新的笔记互相覆盖（详细设计 §5.2）。
    final freshAttachments = await _controller.refreshAttachments(id);
    if (!mounted) return;
    setState(() {
      _attachments = freshAttachments;
      _content.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: insertAt),
      );
    });
    await _save();
    _toast('已添加 $count 个附件');
  }

  /// 在**活动单元格**内插入图片 / 附件引用（§12.1.1「单元格内附件」）。
  ///
  /// 复用 [pickAttachments] 选文件、`AppController.addAttachmentFromBytes` 入库（同 FR-14 /
  /// FR-24 / §4.2），再经 [EditorFormat.insertTableCellAttachment] 把引用文本（图片
  /// `![文件名](sui://<sha256>)`、其余 `[文件名](sui://<sha256>)`）**就地回写活动单元格**，
  /// 其余单元格逐字不动（BR-44.2）。附件字节与内容寻址存储不变。
  Future<void> _attachIntoCell(
    ParsedTable fallback,
    int rowIndex,
    int column,
  ) async {
    final id = _noteId;
    if (id == null) return;

    List<PickedAttachment> picked;
    try {
      picked = await pickAttachments();
    } catch (e) {
      _toast('打开文件选择器失败：$e');
      return;
    }
    if (picked.isEmpty) return;

    var text = _content.text;
    var count = 0;
    for (final f in picked) {
      try {
        final att = await _controller.addAttachmentFromBytes(
          noteId: id,
          filename: f.filename,
          bytes: f.bytes,
        );
        // 每次落笔都以**当前正本**重新解析同一表格，拿到最新结构再写入。
        final parsed = EditorFormat.parseTable(text, fallback.start);
        final table = (parsed != null && parsed.start == fallback.start)
            ? parsed
            : fallback;
        text = EditorFormat.insertTableCellAttachment(
          text,
          table,
          rowIndex,
          column,
          filename: att.filename,
          sha256: att.sha256,
          isImage: mimeKindFor(att.filename) == 'image',
        );
        count++;
      } catch (e) {
        _toast('附件「${f.filename}」添加失败：$e');
      }
    }
    if (count == 0 || !mounted) return;

    // 以「按本笔记刷新」的返回值更新附件缓存；引用文本整体回写正本并即时保存。
    final freshAttachments = await _controller.refreshAttachments(id);
    if (!mounted) return;
    setState(() => _attachments = freshAttachments);
    _writeBackTable(text);
    _toast('已在单元格插入 $count 个附件');
  }

  Future<void> _removeAttachment(Attachment a) async {
    final list = await _controller.removeAttachment(a);
    if (!mounted) return;
    if (list != null) setState(() => _attachments = list);
    _toast('已移除「${a.filename}」');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// 附件面板（ui-spec §4 / §5，B17 / AC-135）：把原先常驻编辑区底部的附件条
  /// 改为按需弹出的弹窗，为窄屏编辑腾出高度。
  ///
  /// 面板内容用 [StatefulBuilder] 局部重建：附件增删只影响面板自身，
  /// 无需把整棵编辑区连带刷新。图片附件在添加时仍会由 [_pickAndAttach]
  /// 把 `![](sui://<sha256>)` 引用插进正文（canonical 正本只有 Markdown）。
  Future<void> _openAttachmentPanel() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final attachments = _attachments;
          final theme = Theme.of(context);
          return AlertDialog(
            title: Row(
              children: [
                const Expanded(child: Text('附件')),
                Text(
                  '${attachments.length} 个',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: attachments.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        '暂无附件。点「添加附件」选择文件；'
                        '图片会自动插入正文。',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: attachments.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => SizedBox(
                          width: double.infinity,
                          child: _AttachmentCard(
                            key: ValueKey(attachments[i].id),
                            attachment: attachments[i],
                            onOpen: () => _openAttachment(attachments[i]),
                            onDelete: () async {
                              await _removeAttachment(attachments[i]);
                              if (dialogContext.mounted) setDialogState(() {});
                            },
                          ),
                        ),
                      ),
                    ),
            ),
            actions: [
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('添加附件'),
                onPressed: () async {
                  await _pickAndAttach();
                  if (dialogContext.mounted) setDialogState(() {});
                },
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 表格插入面板（ui-spec §18.1 / FR-44 / BR-44.1）：自定义行 / 列数后于光标处
  /// 插入一张空表；超界（行 1~20、列 1~8）时提示并钳制到边界值。
  Future<void> _openTablePanel() async {
    final picked = await showDialog<({int rows, int columns})>(
      context: context,
      builder: (_) => const _TableSizeDialog(),
    );
    if (picked == null) return;
    final rows = picked.rows;
    final columns = picked.columns;
    final clampedRows = rows.clamp(
      EditorFormat.tableMinRows,
      EditorFormat.tableMaxRows,
    );
    final clampedCols = columns.clamp(
      EditorFormat.tableMinColumns,
      EditorFormat.tableMaxColumns,
    );
    if (clampedRows != rows || clampedCols != columns) {
      _toast(
        '表格上限为 ${EditorFormat.tableMaxRows} 行 × '
        '${EditorFormat.tableMaxColumns} 列、下限为 '
        '${EditorFormat.tableMinRows} 行 × '
        '${EditorFormat.tableMinColumns} 列，已按边界值插入',
      );
    }
    _insertTableAtCursor(clampedRows, clampedCols);
  }

  /// 在光标 / 选区处插入一张 [rows] × [columns] 的空表（GFM 管道表，BR-44.2）。
  void _insertTableAtCursor(int rows, int columns) {
    final value = _content.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    _writeBack(
      EditorFormat.insertTable(
        value.text,
        start,
        end,
        rows: rows,
        columns: columns,
      ),
    );
  }

  /// 打开附件 = **预览**（ui-spec §18.3 / FR-47 / AC-148 / BR-47.1）。
  ///
  /// 字节先按需就绪（本地命中或下载），随后按 [Attachment.mimeKind] 弹内置预览：
  /// 文本（只读、截断）/ 图片（可缩放）/ PDF 与其它（元信息卡）；弹窗内统一提供
  /// 「用系统默认应用打开」入口（BR-47.2，AC-149）。字节拿不到时降级为提示。
  Future<void> _openAttachment(Attachment a) async {
    Uint8List? bytes;
    try {
      bytes = await _controller.openAttachment(a);
    } catch (e) {
      _toast('下载「${a.filename}」失败：$e');
      return;
    }
    if (bytes == null) {
      _toast('附件「${a.filename}」本机没有字节，且当前未连接服务端');
      return;
    }
    if (!mounted) return;
    // 刷新卡片状态（未下载 → 已缓存/待上传）。
    setState(() {});
    final data = bytes;
    await showDialog<void>(
      context: context,
      builder: (_) => _AttachmentPreviewDialog(
        attachment: a,
        bytes: data,
        onOpenExternally: () => _controller.openAttachmentExternally(a),
      ),
    );
  }

  /// 标签浮层入口（ui-spec §4 / BR-21.4）：标题行**右上角图标**，与标题同行。
  ///
  /// 点击弹出**标签浮层**（锚定图标下方），可就地增删标签；标签**不再单独占一行**，
  /// 把纵向空间还给正文编辑区。标签数量以角标呈现，便于一眼看出是否已有标签。
  Widget _buildTagEntry() {
    return MenuAnchor(
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: SizedBox(width: 240, child: _buildTagEditor()),
        ),
      ],
      builder: (context, controller, child) => IconButton(
        tooltip: '标签',
        icon: Badge(
          isLabelVisible: _tags.isNotEmpty,
          label: Text('${_tags.length}'),
          child: const Icon(Icons.label_outline),
        ),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  /// 标签浮层内容：已有标签（可就地删除）+ 添加输入框（回车添加）。
  Widget _buildTagEditor() {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_tags.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('暂无标签', style: theme.textTheme.bodySmall),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in _tags)
                InputChip(
                  label: Text('#$t'),
                  onDeleted: () {
                    setState(() => _tags = _tags.where((e) => e != t).toList());
                    _save();
                  },
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _tagInput,
          onSubmitted: (_) => _addTag(),
          decoration: const InputDecoration(
            hintText: '输入标签后回车',
            isDense: true,
            border: InputBorder.none,
          ),
        ),
      ],
    );
  }

  void _addTag() {
    final name = _tagInput.text.trim();
    if (name.isEmpty || _tags.contains(name)) {
      _tagInput.clear();
      return;
    }
    _tagInput.clear();
    setState(() => _tags = [..._tags, name]);
    _save();
  }

  void _showExportDialog() {
    final title = _title.text.isEmpty ? '未命名笔记' : _title.text;
    final content = '# $title\n\n${_content.text}';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出 Markdown'),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('标题：$title', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Container(
                height: 200,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    content,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制全部'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
              );
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  // ---- EditorCommandTarget：桌面壳层命令的真实实现（M7-T08，详细设计 §4.2） ----
  //
  // 壳层（菜单栏 / 快捷键 / 顶栏按钮）只发命令，真实落在编辑器内部，故由本 State 实现
  // 该接口并在 initState 注册、dispose 注销。可用性统一由 AppController 判定后置灰。

  @override
  bool get canUndo => _undoHistory.value.canUndo;

  @override
  bool get canRedo => _undoHistory.value.canRedo;

  @override
  void undo() => _undoHistory.undo();

  @override
  void redo() => _undoHistory.redo();

  @override
  void cut() => _dispatchTextIntent(
        const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
      );

  @override
  void copy() => _dispatchTextIntent(CopySelectionTextIntent.copy);

  @override
  void paste() => _dispatchTextIntent(
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );

  @override
  void selectAll() => _dispatchTextIntent(
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );

  @override
  void insertTable() => _openTablePanel();

  @override
  void exportNote() => _showExportDialog();

  @override
  Future<void> flushPendingEdits() async {
    // 本地写入本身不防抖（随编辑即时落库），但编辑器内部对「写回模型」另有一层 400ms
    // 防抖；退出前补一次 [save]，确保正文以当前字面量落库（详细设计 §7 第 1 步）。
    await _save();
  }

  /// 把正文编辑意图派发给 [EditableText] 自带的动作（菜单 / 快捷键与系统行为同源同效）。
  ///
  /// 用 `maybeInvoke` 而非 `invoke`：选区折叠 / 剪贴板为空 / 无匹配动作时静默返回，
  /// 不抛异常——菜单项在壳层已由 `AppController.canEditContent` 统一置灰。
  void _dispatchTextIntent<T extends Intent>(T intent) {
    final ctx = _contentFocus.context;
    if (ctx == null) return; // 预览模式等：正文输入框未挂载
    Actions.maybeInvoke<T>(ctx, intent);
    _contentFocus.requestFocus();
  }
}

/// 表格尺寸输入对话框（FR-44）。
///
/// `showDialog` 返回的 Future 在路由 pop 时即完成，而对话框子树在退场动画期间仍会
/// 重建；若在其返回后立即 `dispose()` 输入控制器，会触发
/// 「A TextEditingController was used after being disposed」。故控制器由对话框自身
/// 持有，并随子树一并释放，行 / 列数经 `pop` 结果回传。
class _TableSizeDialog extends StatefulWidget {
  const _TableSizeDialog();

  @override
  State<_TableSizeDialog> createState() => _TableSizeDialogState();
}

class _TableSizeDialogState extends State<_TableSizeDialog> {
  final TextEditingController _rowCtrl = TextEditingController(text: '3');
  final TextEditingController _colCtrl = TextEditingController(text: '3');

  @override
  void dispose() {
    _rowCtrl.dispose();
    _colCtrl.dispose();
    super.dispose();
  }

  int _parse(TextEditingController ctl) => int.tryParse(ctl.text.trim()) ?? 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('插入表格'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '行 ${EditorFormat.tableMinRows}~${EditorFormat.tableMaxRows}，'
              '列 ${EditorFormat.tableMinColumns}~'
              '${EditorFormat.tableMaxColumns}。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _rowCtrl,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '行数',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _colCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '列数',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('sui-table-insert-confirm'),
          onPressed: () => Navigator.of(context).pop(
            (rows: _parse(_rowCtrl), columns: _parse(_colCtrl)),
          ),
          child: const Text('插入'),
        ),
      ],
    );
  }
}

/// 携带 [FormatCommand] 的快捷键意图（§9）。
///
/// 与工具栏按钮落到同一套 [EditorFormat] 指令实现，确保「同源同效」（BR-30.4）。
class _FormatIntent extends Intent {
  const _FormatIntent(this.command);

  final FormatCommand command;
}

/// 携带「粘贴模式」的快捷键意图（FR-45 / §12.2）。
///
/// [rich] 为 true（`Ctrl+V`）时优先读取剪贴板 HTML 表示并转 Markdown；
/// 为 false（`Ctrl+Shift+V`）时仅取纯文本并转义 Markdown 特殊字符。
class _PasteIntent extends Intent {
  const _PasteIntent({required this.rich});

  final bool rich;
}

/// 格式模式内联的任务勾选框：点按即切换 `[ ]` ↔ `[x]`（§10.1 / BR-31.2）。
class _TaskCheckbox extends StatelessWidget {
  const _TaskCheckbox({required this.checked, required this.onToggle});

  final bool checked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Icon(
          checked ? Icons.check_box : Icons.check_box_outline_blank,
          size: 18,
          color: checked ? scheme.primary : scheme.outline,
        ),
      ),
    );
  }
}

/// 格式工具栏里的分隔竖线。
class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 1,
        height: 20,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: Theme.of(context).dividerColor,
      ),
    );
  }
}

/// 图片尺寸调整条：原始 / 小 / 中 / 大 四档预设 + 像素宽度滑块。
///
/// 预设对应百分比写回（`{width=25%}` 等）；滑块产出像素宽度（`{width=400}`），
/// 即规格 §5.1 中「拖拽手柄产出像素宽度」的等价交互。尺寸只重写图片属性块，
/// 不触碰正文其它字符（BR-24.1）。
class _ImageSizeBar extends StatefulWidget {
  const _ImageSizeBar({required this.image, required this.onApply});

  final ParsedImage image;
  final void Function(ImageSize? size) onApply;

  @override
  State<_ImageSizeBar> createState() => _ImageSizeBarState();
}

class _ImageSizeBarState extends State<_ImageSizeBar> {
  late double _sliderPx;

  @override
  void initState() {
    super.initState();
    _sliderPx = _currentPx();
  }

  @override
  void didUpdateWidget(covariant _ImageSizeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 图片切换、或预设改了尺寸后，滑块要同步到当前值。
    if (oldWidget.image.size != widget.image.size) {
      _sliderPx = _currentPx();
    }
  }

  double _currentPx() {
    final w = widget.image.size.width;
    if (w != null && w.unit == SizeUnit.pixel) return w.value.toDouble();
    return 400;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.image.size;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Text('图片尺寸', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(width: 4),
            _preset('原始', ImageSize.auto, current, scheme),
            _preset('小', EditorFormat.presetSmall, current, scheme),
            _preset('中', EditorFormat.presetMedium, current, scheme),
            _preset('大', EditorFormat.presetLarge, current, scheme),
            const _ToolbarDivider(),
            Expanded(
              child: Slider(
                min: 100,
                max: 800,
                value: _sliderPx.clamp(100, 800),
                divisions: 35,
                label: '${_sliderPx.round()}px',
                onChanged: (v) => setState(() => _sliderPx = v),
                onChangeEnd: (v) => widget.onApply(
                  ImageSize(
                    width: ImageDimension(v.round(), SizeUnit.pixel),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preset(
    String label,
    ImageSize size,
    ImageSize current,
    ColorScheme scheme,
  ) {
    final selected = current == size;
    return TextButton(
      onPressed: () => widget.onApply(size),
      style: TextButton.styleFrom(
        foregroundColor: selected ? scheme.primary : null,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label),
    );
  }
}

/// 格式模式内联的图片呈现单元：包一层点选 / 高亮，尺寸与预览共用同一套
/// `sui://<sha256>` 附件加载；字节未就绪或失败时显示占位，不阻断编辑
/// （BR-27.1 / BR-27.3）。
class _FormatImageUnit extends StatelessWidget {
  const _FormatImageUnit({
    required this.image,
    required this.selected,
    required this.onSelect,
    this.block = false,
    this.onDoubleTap,
  });

  final ParsedImage image;
  final bool selected;
  final VoidCallback onSelect;

  /// 是否按**块级呈现单元**布局（§5.5）：引用独占一块时为 true——块宽即段落宽、
  /// 块高向下扩展，后续文字整体下移；历史行内引用为 false，保持行内呈现。
  final bool block;

  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final uri = Uri.tryParse(image.url);
    final label = image.alt.isNotEmpty ? image.alt : '附件';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSelect,
      onDoubleTap: onDoubleTap,
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: 2,
          vertical: block ? 6 : 2,
        ),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 内联子组件受段落宽度约束，百分比宽度即相对该可用宽度换算。
            final available =
                constraints.maxWidth.isFinite ? constraints.maxWidth : 720.0;
            final dims = _resolveSize(available);
            final Widget imageWidget;
            if (uri != null && uri.scheme == 'sui') {
              imageWidget = _SuiAttachmentImage(
                sha256: uri.host,
                label: label,
                width: dims.$1,
                height: dims.$2,
              );
            } else {
              imageWidget = Image.network(
                image.url,
                width: dims.$1,
                height: dims.$2,
                errorBuilder: (_, __, ___) =>
                    _AttachmentPlaceholder(label: label),
              );
            }
            if (!block) return imageWidget;
            // 块级呈现：块占满段落宽（图片左对齐），使该行只承载图片，
            // 行高即块高、向下扩展，后续文字整体下移、与图片不重叠。
            // 用 Align 而非定宽 SizedBox：宽度受限时撑满段落，无界时自动收缩。
            return Align(
              alignment: Alignment.centerLeft,
              child: imageWidget,
            );
          },
        ),
      ),
    );
  }

  /// 把 `{width=...}` 换算为具体像素；未指定宽度时按原图自适应（受可用宽度限制）。
  (double?, double?) _resolveSize(double available) {
    final w = image.size.width;
    final h = image.size.height;
    double? width;
    double? height;
    if (w != null) {
      width = w.unit == SizeUnit.percent
          ? available * (w.value / 100)
          : w.value.toDouble();
      width = width.clamp(24.0, available);
    }
    if (h != null && h.unit == SizeUnit.pixel) {
      height = h.value.toDouble();
    }
    return (width, height);
  }
}

/// 格式模式内联的附件**链接**呈现单元：把 `[name](sui://<sha256>)` 呈现为可点选的
/// 整块「附件胶囊」（FR-46 / §12.4）。仅格式模式启用；点按即选中（光标落入引用）；
/// **双击直接打开预览**（FR-47 / AC-148）。
/// 残缺引用（缺 `)`）显式标红，提示可退格自愈（AC-147）。
class _FormatAttachmentLinkUnit extends StatelessWidget {
  const _FormatAttachmentLinkUnit({
    required this.label,
    required this.isImage,
    required this.corrupt,
    required this.selected,
    required this.onSelect,
    this.onDoubleTap,
  });

  final String label;
  final bool isImage;
  final bool corrupt;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final borderColor = corrupt
        ? scheme.error
        : (selected ? scheme.primary : scheme.outlineVariant);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSelect,
      onDoubleTap: onDoubleTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          border: Border.all(color: borderColor, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isImage ? Icons.image_outlined : Icons.attach_file,
              size: 14,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 4),
            Text(
              label.isEmpty ? '附件' : label,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSecondaryContainer,
              ),
            ),
            if (corrupt) ...[
              const SizedBox(width: 4),
              Icon(Icons.error_outline, size: 14, color: scheme.error),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyEditor extends StatelessWidget {
  const _EmptyEditor();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.edit_note, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          Text('选择或新建一篇笔记开始记录',
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ],
      ),
    );
  }
}

/// 单个附件卡片：文件名 + 大小 + 可用性状态 + 打开/移除。
///
/// 状态用 [AttachmentAvailability] 而非布尔「已缓存」：方案 B 下「本地有字节」
/// 与「服务端已持有」是两件事，只显示「已缓存」会让用户误以为换台设备也能打开。
class _AttachmentCard extends StatefulWidget {
  const _AttachmentCard({
    super.key,
    required this.attachment,
    required this.onOpen,
    required this.onDelete,
  });

  final Attachment attachment;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  State<_AttachmentCard> createState() => _AttachmentCardState();
}

class _AttachmentCardState extends State<_AttachmentCard> {
  AttachmentAvailability? _availability;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _downloading =
        context.read<AppController>().isDownloading(widget.attachment.sha256);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _AttachmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sha = widget.attachment.sha256;
    if (oldWidget.attachment.sha256 != sha) {
      _availability = null;
      _refresh();
      return;
    }
    // 「下载中 → 结束」的过渡需要重新确认状态：远端未下载 → 本地已缓存。
    final nowDownloading = context.read<AppController>().isDownloading(sha);
    if (_downloading && !nowDownloading) _refresh();
    _downloading = nowDownloading;
  }

  Future<void> _refresh() async {
    final v = await context
        .read<AppController>()
        .attachmentAvailability(widget.attachment);
    if (!mounted) return;
    setState(() => _availability = v);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.attachment;
    final downloading = context.watch<AppController>().isDownloading(a.sha256);
    final availability = _availability;
    final busy = availability == null || downloading;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: busy ? null : widget.onOpen,
        child: Container(
          padding: const EdgeInsets.only(left: 10, right: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconFor(a.mimeKind), size: 20),
              const SizedBox(width: 8),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(
                      a.filename,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Text(
                    '${_formatSize(a.byteSize)} · ${_statusText(downloading, availability)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(_statusIcon(availability), size: 16),
              IconButton(
                tooltip: '移除附件',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 16),
                onPressed: widget.onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusText(
    bool downloading,
    AttachmentAvailability? availability,
  ) {
    if (downloading) return '下载中…';
    if (availability == null) return '检查中';
    return switch (availability) {
      AttachmentAvailability.cached => '已同步',
      AttachmentAvailability.pendingUpload => '待上传',
      AttachmentAvailability.localOnly => '仅本机',
      AttachmentAvailability.remoteOnly => '未下载',
    };
  }

  IconData _statusIcon(AttachmentAvailability availability) {
    switch (availability) {
      case AttachmentAvailability.cached:
        return Icons.cloud_done_outlined;
      case AttachmentAvailability.pendingUpload:
        return Icons.cloud_upload_outlined;
      case AttachmentAvailability.localOnly:
        return Icons.smartphone_outlined;
      case AttachmentAvailability.remoteOnly:
        return Icons.download_for_offline_outlined;
    }
  }

  IconData _iconFor(String mimeKind) => _attachmentIcon(mimeKind);

  String _formatSize(int bytes) => _formatBytes(bytes);
}

/// 附件内的图标（按 [Attachment.mimeKind] 取），卡片与预览弹窗共用。
IconData _attachmentIcon(String mimeKind) {
  switch (mimeKind) {
    case 'image':
      return Icons.image_outlined;
    case 'pdf':
      return Icons.picture_as_pdf_outlined;
    case 'video':
      return Icons.videocam_outlined;
    case 'audio':
      return Icons.music_note_outlined;
    default:
      return Icons.attach_file_outlined;
  }
}

/// 人类可读的字节大小，卡片与预览弹窗共用。
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 附件内置预览弹窗（ui-spec §18.3 / FR-47 / AC-148 / BR-47.1）。
///
/// 按 [Attachment.mimeKind] 分支：
/// * `text` —— 只读文本视图（UTF-8 容错解码，超长截断并提示）；
/// * `image` —— 可缩放的图片视图（[InteractiveViewer]）；
/// * `pdf` / 其它 —— 元信息卡（零新增依赖，PDF 不做内置渲染）。
/// 三类都提供「用系统默认应用打开」入口（BR-47.2 / AC-149）；Web / 移动端该入口
/// 不可用时提示降级（BR-47.5 / AC-151）。
class _AttachmentPreviewDialog extends StatelessWidget {
  const _AttachmentPreviewDialog({
    required this.attachment,
    required this.bytes,
    required this.onOpenExternally,
  });

  final Attachment attachment;
  final Uint8List bytes;
  final Future<bool> Function() onOpenExternally;

  /// 文本预览字符上限：超过则截断，避免超长文件卡住渲染。
  static const int _maxTextChars = 20000;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(_attachmentIcon(attachment.mimeKind), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(attachment.filename, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      content: SizedBox(width: 560, child: _buildBody(context, theme)),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('用系统默认应用打开'),
          onPressed: () async {
            final ok = await onOpenExternally();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  ok ? '已用系统默认应用打开；编辑保存后将自动回写' : '当前平台不支持调用系统应用，可先用内置预览查看',
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, ThemeData theme) {
    switch (attachment.mimeKind) {
      case 'image':
        return _buildImage();
      case 'text':
        return _buildText(theme);
      default:
        return _buildMeta(theme);
    }
  }

  Widget _buildImage() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 5,
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              _AttachmentPlaceholder(label: attachment.filename),
        ),
      ),
    );
  }

  Widget _buildText(ThemeData theme) {
    var text = utf8.decode(bytes, allowMalformed: true);
    final truncated = text.length > _maxTextChars;
    if (truncated) text = text.substring(0, _maxTextChars);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 420),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style:
                  theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ),
        if (truncated)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '内容较长，仅预览前 $_maxTextChars 个字符。',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
      ],
    );
  }

  Widget _buildMeta(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_attachmentIcon(attachment.mimeKind), size: 40),
              const SizedBox(height: 12),
              Text(
                '类型：${_kindLabel(attachment.mimeKind)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                '大小：${_formatBytes(attachment.byteSize)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '此类型暂不支持内置预览，可点击下方「用系统默认应用打开」。',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }

  String _kindLabel(String mimeKind) {
    switch (mimeKind) {
      case 'image':
        return '图片';
      case 'pdf':
        return 'PDF';
      case 'video':
        return '视频';
      case 'audio':
        return '音频';
      case 'text':
        return '文本';
      case 'archive':
        return '压缩包';
      default:
        return '文件';
    }
  }
}

/// 预览内联的 `sui://<sha256>` 图片：走附件缓存（本地命中或按需下载）。
///
/// 与卡片同理，加载不出来时必须给出可读回退而不是留白 —— 换台设备首次打开
/// 需要一次下载，断网就会落到失败态。
class _SuiAttachmentImage extends StatefulWidget {
  const _SuiAttachmentImage({
    required this.sha256,
    required this.label,
    this.width,
    this.height,
  });

  final String sha256;
  final String label;
  final double? width;
  final double? height;

  @override
  State<_SuiAttachmentImage> createState() => _SuiAttachmentImageState();
}

class _SuiAttachmentImageState extends State<_SuiAttachmentImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _SuiAttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sha256 != widget.sha256) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    if (widget.sha256.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    try {
      final bytes = await context
          .read<AppController>()
          .loadAttachmentBytes(widget.sha256);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _failed = bytes == null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: widget.width,
        height: widget.height,
        errorBuilder: (_, __, ___) =>
            _AttachmentPlaceholder(label: widget.label),
      );
    }
    if (_failed) return _AttachmentPlaceholder(label: widget.label);
    return _AttachmentPlaceholder(label: widget.label, loading: true);
  }
}

/// 附件在预览里加载中 / 加载失败时的统一占位。
class _AttachmentPlaceholder extends StatelessWidget {
  const _AttachmentPlaceholder({required this.label, this.loading = false});

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.broken_image_outlined, size: 18),
          const SizedBox(width: 6),
          Text(
            loading ? '加载「$label」…' : label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
