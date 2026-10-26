import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import '../platform/attachment_picker.dart';
import '../platform/clipboard_html.dart';
import '../platform/url_opener.dart';
import 'snapshot_html_view.dart';
import 'web_clip_unit.dart';
import 'web_clip_view.dart';
import 'app_controller.dart';
import 'appearance/app_palette.dart';
import 'desktop_commands.dart';
import 'format_table.dart';
import 'markdown_editing_controller.dart';
import 'markdown_editor.dart';
import 'note_window_manager.dart';
import 'time_format.dart';

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
    this.showProperties = false,
    this.onToggleProperties,
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

  /// **属性面板**是否可见（M15 / FR-74）。仅当 [onToggleProperties] 非空时生效
  /// （独立窗口口径）；主窗口保持默认，改用 [AppController.propertiesPanelVisibleFor]。
  final bool showProperties;

  /// 属性面板显隐切换回调（M15 / FR-74）；`null` 时回落到
  /// [AppController.togglePropertiesPanel]（与「版本历史」同源的**双口径**）。
  final VoidCallback? onToggleProperties;

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

  /// 当前**活动单元格**（由 [FormatTableView.onActiveCellChanged] 回传）：正文工具栏的
  /// 「链接」（含 `Ctrl+K`）在单元格获焦时据此写入**该单元格**（§14.1 / BR-44.12）。
  ParsedTable? _activeCellTable;
  int _activeCellRow = -1;
  int _activeCellCol = 0;

  /// **活动单元格光标处**的链接地址（由 [FormatTableView.onActiveCellLinkChanged] 回传）：
  /// 非 null 时链接条提供「打开」入口（FR-70 / editor-formatting.md §16.2）。
  String? _activeCellLink;

  /// 是否有焦点落在嵌套的表格单元格内（含上下文操作按钮）。
  ///
  /// 单元格是 [_contentFocus] 的焦点子树：焦点在单元格时 [_contentFocus] 的
  /// `hasFocus` 仍为 true，正文会画出自己的光标，出现「两个光标」。据此在
  /// 单元格聚焦期间隐藏正文光标（见 [MarkdownEditor.showCursor]）。
  bool _tableHasFocus = false;

  List<String> _tags = [];
  List<Attachment> _attachments = [];

  /// 是否有「添加附件」批次正在进行（`v0.16.3` / FR-91 / BR-91.2）。
  ///
  /// **单批次互斥**：批次入口处同步置位，结束（含异常 / 用户关闭面板）清除；
  /// 期间「添加附件」按钮与工具栏「插入图片」置灰，连点不会开第二个批次。
  bool _attaching = false;

  /// 本批次**尚未完成**的文件名，供附件面板逐项显示进度（完成一个移除一个）。
  ///
  /// 与 [_attaching] 同生共死；面板是独立路由，靠 [_notifyAttaching] 的 `onChanged`
  /// 回调把变化推给 `setDialogState`。
  final List<String> _attachPending = <String>[];

  // ---------------------------------------------------------------------------
  // 笔记内查找与替换（M15 / FR-73 / BR-73.1\~73.4）
  // ---------------------------------------------------------------------------

  /// 查找栏是否可见（**不是**预览态：FR-73 明确预览模式不提供）。
  bool _findVisible = false;

  /// 查询词 / 替换词输入框（状态归本 State，故关闭再打开不丢词）。
  final TextEditingController _findQuery = TextEditingController();
  final TextEditingController _findReplacement = TextEditingController();

  /// 查询框焦点：打开查找栏即聚焦（FR-73「打开即聚焦查询框」）。
  final FocusNode _findQueryFocus = FocusNode();

  /// 是否区分大小写（默认不区分，FR-73）。
  bool _findCaseSensitive = false;

  /// 参与导航 / 替换的命中集合（**格式模式**已滤除结构区；**源码模式**全量）。
  List<FindMatch> _findMatches = const <FindMatch>[];

  /// 当前命中下标（`-1` = 无）。
  int _findIndex = -1;

  /// 被**结构区**挡下、未参与替换的命中数（仅格式模式非零；FR-73 要求提示）。
  int _findSkipped = 0;

  /// 上次计算命中集合时的正本 / 模式：用于在 build 期**检测失效**并安排一次帧后重算
  /// （模式切换、撤销、外部改写都会让集合过期）。build 期只登记，不在 build 期 setState。
  String? _findComputedText;
  EditorMode? _findComputedMode;

  /// 是否已安排帧后重算（防止一次 build 里重复排队）。
  bool _findRefreshPending = false;

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
    _content.formatHtmlBlockBuilder = _buildHtmlBlock;
    // M16 / FR-83：网页原件整行渲染为原子卡片（单击选中、双击全屏）。
    _content.formatWebClipBuilder = _buildWebClipFormat;
    // 格式模式：把整块 GFM 管道表渲染为可交互「表格呈现单元」（FR-44 / §12.1）。
    _content.formatTableBuilder = _buildFormatTable;
    // 格式模式：把 Markdown 链接 `[文字](网址)`（含笔记引用）渲染为**可点击的原子链接单元**
    // （M15 / FR-76 / BR-76.1）——单击选中、双击打开，见 [_buildFormatLink]。
    _content.formatLinkBuilder = _buildFormatLink;
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
    _findQuery.dispose();
    _findReplacement.dispose();
    _findQueryFocus.dispose();
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
                    tooltip: _tooltipWithShortcut('撤销'),
                    icon: const Icon(Icons.undo),
                    onPressed: _undoHistory.value.canUndo
                        ? () => _undoHistory.undo()
                        : null,
                  ),
                  IconButton(
                    tooltip: _tooltipWithShortcut('重做'),
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
              tooltip: _tooltipWithShortcut('表格'),
              icon: const Icon(Icons.table_chart_outlined),
              onPressed: _openTablePanel,
            ),
            const _ToolbarDivider(),
            // 链接：弹出**录入框**填「显示文字 + 网址」后回写（§14.1 / BR-23.10）；
            // **单元格获焦时写入该活动单元格**（BR-44.12），故不再是「纯指令」入口。
            IconButton(
              tooltip: _tooltipWithShortcut('链接'),
              icon: const Icon(Icons.link),
              onPressed: _handleLinkCommand,
            ),
            // 关联笔记（M15 / FR-75 / BR-75.2）：**紧随「链接」之后**（中频区顺序
            // 链接 → 关联笔记 → 图片 → 附件）。产出恒为标准 Markdown 链接
            // `[标题](sui://note/<id>)`，与手写一致（BR-23.2）。
            IconButton(
              key: const ValueKey('sui-note-ref'),
              tooltip: '关联笔记',
              icon: const Icon(Icons.add_link),
              onPressed: insertNoteRef,
            ),
            IconButton(
              tooltip: '插入图片',
              icon: const Icon(Icons.image_outlined),
              // 添加批次进行中置灰：再点会开第二个批次（BR-91.2 / AC-518）。
              onPressed: _attaching ? null : _pickAndAttach,
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
      // 悬浮提示带**键位说明**（由快捷键映射反查，单一来源，§14.2 / BR-23.11）。
      tooltip: _tooltipWithShortcut(tooltip, command: command),
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

  // ---------------------------------------------------------------------------
  // 超链接录入（弹框 → 正本；含单元格内，§14.1 / BR-23.10 / BR-44.12）
  // ---------------------------------------------------------------------------

  /// 「链接」入口的统一处理：**单元格获焦时写入该活动单元格**，否则写入正文选区。
  ///
  /// 工具栏按钮与 `Ctrl+K`（[_LinkIntent]）同源走本方法（BR-30.4）。
  Future<void> _handleLinkCommand() async {
    final table = _activeCellTable;
    if (_tableHasFocus && table != null) {
      await _insertLinkIntoCell(table, _activeCellRow, _activeCellCol);
      return;
    }
    await _openLinkDialog();
  }

  /// 弹出「插入超链接」录入框；返回 null 表示取消（调用方不改动正本，BR-23.10⑤）。
  Future<_LinkDialogResult?> _promptLink({String initialLabel = ''}) {
    return showDialog<_LinkDialogResult>(
      context: context,
      builder: (_) => _LinkDialog(initialLabel: initialLabel),
    );
  }

  /// 正文：把链接写入**当前选区 / 光标处**（有选区时以选中文字预填「显示文字」）。
  Future<void> _openLinkDialog() async {
    final value = _content.value;
    final text = value.text;
    final sel = value.selection;
    final start = (sel.isValid ? sel.start : text.length).clamp(0, text.length);
    final end = (sel.isValid ? sel.end : start).clamp(0, text.length);
    final lo = start <= end ? start : end;
    final hi = start <= end ? end : start;
    // 「显示文字」保持单行：选区里的换行折叠为空格。
    final selected = lo < hi
        ? text.substring(lo, hi).replaceAll(RegExp(r'\s*\n\s*'), ' ')
        : '';
    final result = await _promptLink(initialLabel: selected);
    if (result == null || !mounted) return;
    final r = EditorFormat.insertLink(
      _content.text,
      lo,
      hi,
      label: result.label,
      url: result.url,
    );
    if (r.text == _content.text) {
      _toast('网址为空，未插入链接');
      return;
    }
    _writeBack(r);
  }

  /// 单元格：把链接写入**活动单元格**（`<br>` 软换行追加，其余单元格逐字不动，BR-44.12）。
  Future<void> _insertLinkIntoCell(
    ParsedTable fallback,
    int rowIndex,
    int column,
  ) async {
    final result = await _promptLink();
    if (result == null || !mounted) return;
    // 每次落笔都以**当前正本**重新解析同一表格，拿到最新结构再写入（同单元格附件口径）。
    final text = _content.text;
    final parsed = EditorFormat.parseTable(text, fallback.start);
    final table =
        (parsed != null && parsed.start == fallback.start) ? parsed : fallback;
    final newText = EditorFormat.insertTableCellLink(
      text,
      table,
      rowIndex,
      column,
      label: result.label,
      url: result.url,
    );
    if (newText == text) {
      _toast('网址为空，未插入链接');
      return;
    }
    _writeBackTable(newText);
    _toast('已在单元格插入链接');
  }

  // ---------------------------------------------------------------------------
  // 工具栏悬浮提示里的快捷键说明（§14.2 / BR-23.11）
  // ---------------------------------------------------------------------------

  /// **非格式指令**按钮的键位说明（系统默认文本编辑键 / 弹框类入口）。
  ///
  /// 格式指令的键位一律由 [_formatShortcuts] **反查**（见 [_shortcutLabelFor]），本表只收
  /// 「不在该映射里」的几个入口，避免键位在两处各写一份。
  static const Map<String, String> _panelShortcutLabels = {
    '撤销': 'Ctrl+Z',
    '重做': 'Ctrl+Shift+Z',
    '链接': 'Ctrl+K',
    '表格': 'Ctrl+Shift+T',
  };

  /// 组装 tooltip：`加粗 (Ctrl+B)`；无快捷键时原样返回按钮名称（BR-23.11）。
  static String _tooltipWithShortcut(String label, {FormatCommand? command}) {
    final key =
        command == null ? _panelShortcutLabels[label] : _shortcutLabelFor(command);
    return key == null || key.isEmpty ? label : '$label ($key)';
  }

  /// 由 [_formatShortcuts]**反查**该指令的键位说明（**单一来源**：改键位则提示自动跟随）。
  static String? _shortcutLabelFor(FormatCommand command) {
    for (final entry in _formatShortcuts.entries) {
      final intent = entry.value;
      if (intent is _FormatIntent && intent.command == command) {
        return _describeActivator(entry.key);
      }
    }
    return null;
  }

  /// 把单个 [ShortcutActivator] 描述为 `Ctrl+Shift+K` 形式（与本项目菜单 / 文档口径一致：写 `Ctrl`）。
  static String? _describeActivator(ShortcutActivator activator) {
    if (activator is! SingleActivator) return null;
    final parts = <String>[
      if (activator.control) 'Ctrl',
      if (activator.alt) 'Alt',
      if (activator.shift) 'Shift',
      if (activator.meta && !activator.control) 'Meta',
      _keyLabel(activator.trigger),
    ];
    return parts.where((p) => p.isNotEmpty).join('+');
  }

  /// 键名的人类可读写法（`keyB` → `B`、`digit1` → `1`、`space` → `Space`、`minus` → `-`）。
  static String _keyLabel(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.minus) return '-';
    if (key == LogicalKeyboardKey.equal) return '=';
    final label = key.keyLabel.trim();
    return label.isEmpty ? (key.debugName ?? '?') : label;
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

  /// 格式模式下把**快照 HTML 块**渲染为受限渲染组件（FR-69 / §16.3）。
  ///
  /// 与预览态**同源**（同一个 [SnapshotHtmlView]）；格式模式**不给点链接**——那里是编辑区，
  /// 「点击 = 放置光标」的语义与打开链接冲突，链接另由链接条提供入口（FR-70）。
  Widget _buildHtmlBlock(BuildContext context, String html) {
    return SnapshotHtmlView(
      html: html,
      baseStyle: _htmlBlockBaseStyle(context),
      suiImageBuilder: _buildHtmlImage,
    );
  }

  /// 网页原件（M16 / FR-83）：格式态原子卡片。
  Widget _buildWebClipFormat(BuildContext context, WebClipRef ref) {
    final sel = _content.value.selection;
    final selected =
        sel.isValid && sel.isCollapsed && sel.start >= ref.start && sel.start <= ref.end;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: selected
            ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2)
            : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: WebClipFormatUnit(
        ref: ref,
        htmlLoader: _loadWebClipHtml,
        title: _note?.title,
        imageResolver: _controller.loadAttachmentBytes,
        onSelect: () => _selectWebClip(ref),
      ),
    );
  }

  /// 网页原件（M16 / FR-83）：预览态内嵌网页。
  Widget _buildWebClipPreview(BuildContext context, WebClipRef ref) {
    return WebClipPreviewUnit(
      ref: ref,
      htmlLoader: _loadWebClipHtml,
      title: _note?.title,
      imageResolver: _controller.loadAttachmentBytes,
    );
  }

  /// 读取原件 HTML 字节并解码（附件尚未同步时返回 null，由单元降级）。
  Future<String?> _loadWebClipHtml(String sha256) async {
    final bytes = await _controller.loadAttachmentBytes(sha256);
    return decodeWebClipHtml(bytes);
  }

  /// 单击原件卡片：光标落到引用末尾，便于出现选中描边 / 继续操作。
  void _selectWebClip(WebClipRef ref) {
    final pos = ref.end.clamp(0, _content.text.length);
    _content.value = TextEditingValue(
      text: _content.text,
      selection: TextSelection.collapsed(offset: pos),
    );
    if (_mode != EditorMode.preview) _contentFocus.requestFocus();
  }

  /// 快照 HTML 块里的 `sui://` 图片：与预览 / 正文**同源**的附件组件（FR-69）。
  Widget _buildHtmlImage(
    String sha256,
    String label,
    double? width,
    double? height,
  ) =>
      _SuiAttachmentImage(
        sha256: sha256,
        label: label,
        width: width,
        height: height,
      );

  /// 快照 HTML 块的基础文字样式：与正文**同源**（笔记正文字体 + 1.6 倍行距）。
  TextStyle _htmlBlockBaseStyle(BuildContext context) => SuiAppearance.of(context)
      .applyBodyFont(const TextStyle(fontSize: 15, height: 1.6));

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

  /// 格式模式下退格 / 删除键的**结构化删除**处理（FR-46 / FR-44 / §12.4 / §12.1.1）。
  ///
  /// 优先级：残缺引用**就地修复**（补 `)`，AC-147）→ 附件引用边界**整块删除**
  /// （AC-145 / AC-146）→ 表格边界**整块删除**（AC-140 / BR-44.6）。命中返回 true
  /// 抑制默认逐字符删除；未命中返回 false。仅在格式模式 + 折叠光标时生效，
  /// 源码模式保持原始文本语义（AC-147）。
  bool _handleStructuralDelete({required bool backspace}) {
    if (_mode != EditorMode.formatted) return false;
    final sel = _content.value.selection;
    if (!sel.isValid) return false;
    final text = _content.text;
    // 统一结构删除（§13.2 / §13.4 / BR-23.8 / BR-44.11）：附件整块删除 / 残缺自愈 →
    // **记号原子删除**（一次取消整处格式、内容保留）→ 表格整块删除 → **表格边界保护**
    // （绝不把表格行与相邻行文字合并，故表格**永不打回原形**）。选区同样经此入口，
    // 保证记号与整块单元不被「切半」。
    final result = EditorFormat.structuralDelete(
      text,
      sel.start,
      sel.end,
      backspace: backspace,
    );
    if (result == null) return false;
    // 表格边界保护命中「无法安全合并」的情形：文本未变 = **吞掉该按键**（不写回、
    // 不产生多余撤销步），表格与文字均保持不变。
    if (result.text == text) return true;
    _writeBack(result);
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
    // `Ctrl+K` 与工具栏「链接」同源：打开**录入弹框**（§14.1 / BR-23.10），不再是纯指令。
    SingleActivator(LogicalKeyboardKey.keyK, control: true): _LinkIntent(),
    // `Ctrl+Shift+T`：打开「插入表格」面板（与工具栏「表格」/「编辑」菜单同源，FR-44）。
    SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true):
        _TableIntent(),
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
        _LinkIntent: CallbackAction<_LinkIntent>(
          onInvoke: (intent) {
            _handleLinkCommand();
            return null;
          },
        ),
        _TableIntent: CallbackAction<_TableIntent>(
          onInvoke: (intent) {
            _openTablePanel();
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

  // ---------------------------------------------------------------------------
  // 笔记内查找与替换（M15 / FR-73 / BR-73.1~73.4）
  // ---------------------------------------------------------------------------

  /// 打开**笔记内查找栏**（FR-73 / BR-73.1）。**幂等**：已打开时只重新聚焦查询框，
  /// 绝不 toggle——菜单点击与 `Ctrl+F` 可能因平台差异先后触发两次，不得把栏开了又关
  /// （这是 ADR-030 决策 1 的明确口径）。
  @override
  void openFind() {
    // FR-73：预览模式不提供笔记内查找（只读渲染，没有可编辑的正本视图）；入口也置灰。
    if (_mode == EditorMode.preview) return;
    if (_findVisible) {
      _focusFindQuery();
      return;
    }
    // 打开时若正文有**非折叠选区**，以该选区文本预填查询词（FR-73 交互细节）。
    // 跨行选区不预填：查找**不跨行**（BR-73.4 登记的范围），预填只会得到 0 命中。
    final sel = _content.value.selection;
    final text = _content.text;
    if (sel.isValid && !sel.isCollapsed) {
      final lo = (sel.start <= sel.end ? sel.start : sel.end).clamp(0, text.length);
      final hi = (sel.start <= sel.end ? sel.end : sel.start).clamp(0, text.length);
      final selected = text.substring(lo, hi);
      if (selected.isNotEmpty && !selected.contains('\n')) {
        _findQuery.text = selected;
      }
    }
    setState(() {
      _findVisible = true;
      _refreshFind();
      _applyFindToController();
    });
    _locateFind();
    _focusFindQuery();
  }

  /// 查询框聚焦（帧后执行：打开当帧该输入框尚未挂载，直接 requestFocus 无效）。
  ///
  /// 顺带**全选**已有查询词：连续按 `Ctrl+F` 是「重新输入查找词」的直觉动作。
  void _focusFindQuery() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_findVisible) return;
      _findQueryFocus.requestFocus();
      _findQuery.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findQuery.text.length,
      );
    });
  }

  /// 关闭查找栏：清空控制器命中集合并**把焦点还给正文**（FR-73：`Esc` 的口径）。
  void _closeFind() {
    if (!_findVisible) return;
    setState(() {
      _findVisible = false;
      _findMatches = const <FindMatch>[];
      _findIndex = -1;
      _findSkipped = 0;
      _findComputedText = null;
      _findComputedMode = null;
      _applyFindToController();
    });
    if (_mode != EditorMode.preview) _contentFocus.requestFocus();
  }

  /// 把命中集合写进正文控制器——**控制器只负责画**（规范 §1.5），计算全在本 State。
  ///
  /// 只在 [setState] 内调用：控制器字段是**普通字段**（刻意不是通知型状态），靠外层重建
  /// 触发 `buildTextSpan` 重画；在 build 期 `notifyListeners()` 会撞断言。
  void _applyFindToController() {
    _content.findMatches = _findVisible ? _findMatches : const <FindMatch>[];
    _content.activeFindIndex = _findVisible ? _findIndex : -1;
  }

  /// 当前命中项（越界 / 无命中时为 null）。
  FindMatch? get _currentFindMatch {
    if (_findIndex < 0 || _findIndex >= _findMatches.length) return null;
    return _findMatches[_findIndex];
  }

  /// 按当前查询词 / 大小写 / 模式**重算**命中集合（纯计算，不 setState、不写控制器）。
  ///
  /// **结构区过滤**（FR-73 / BR-73.2）：格式模式下不可见 / 非普通文本的区段（表格块、
  /// 快照 HTML 块、附件引用、链接的 `](网址)` 段、任意记号区间与围栏行）**不参与替换**，
  /// 命中它们**不计数**并累计到 [_findSkipped]（查找栏据此显示「已跳过 N 处结构区」）；
  /// **源码模式**下一切字符可见，故**全量**参与查找与替换。
  void _refreshFind() {
    final text = _content.text;
    final raw = EditorFormat.findMatches(
      text,
      _findQuery.text,
      caseSensitive: _findCaseSensitive,
    );
    final previous = _currentFindMatch;
    final usable = <FindMatch>[];
    var skipped = 0;
    if (_mode == EditorMode.formatted) {
      for (final m in raw) {
        if (EditorFormat.isStructuralOffset(text, m.start)) {
          skipped++;
          continue;
        }
        usable.add(m);
      }
    } else {
      usable.addAll(raw);
    }
    _findMatches = usable;
    _findSkipped = skipped;
    _findComputedText = text;
    _findComputedMode = _mode;
    // 保持**当前项位置**（FR-73 交互细节）：优先按原当前命中的区间找回；
    // 找不回（如刚替换掉、或换了查询词）则按下标就近钳制。
    var index = -1;
    if (previous != null) {
      index = usable.indexWhere(
        (m) => m.start == previous.start && m.end == previous.end,
      );
    }
    if (index < 0 && usable.isNotEmpty) {
      index = _findIndex < 0 ? 0 : _findIndex.clamp(0, usable.length - 1);
    }
    _findIndex = index;
  }

  /// 把正文选区设成**当前命中区间**（FR-73 定位）。
  ///
  /// 刻意用**非折叠**选区：控制器的 `set value` 只在「折叠光标 + 文本未变」时做记号 /
  /// 表格 / 围栏吸附，非折叠选区**原样保留**——这正是「查找定位不被光标吸附改写」的
  /// 隐含契约（规范 §1.7）。
  void _locateFind() {
    final m = _currentFindMatch;
    if (m == null) return;
    final text = _content.text;
    final start = m.start.clamp(0, text.length);
    final end = m.end.clamp(start, text.length);
    _content.value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end),
    );
  }

  /// 查询词变化：重算命中集合并定位到当前项（`Enter` / 按钮再逐处游走）。
  void _onFindQueryChanged(String _) {
    setState(() {
      _refreshFind();
      _applyFindToController();
    });
    _locateFind();
  }

  /// 切换**区分大小写**（FR-73）：重算命中集合并重新定位。
  void _toggleFindCase() {
    setState(() {
      _findCaseSensitive = !_findCaseSensitive;
      _refreshFind();
      _applyFindToController();
    });
    _locateFind();
  }

  /// 「下一个」/ `Enter`：移到下一处命中（到尾循环）。
  void _findNext() {
    if (_findMatches.isEmpty) return;
    setState(() {
      _findIndex = _findIndex < 0 ? 0 : (_findIndex + 1) % _findMatches.length;
      _applyFindToController();
    });
    _locateFind();
  }

  /// 「上一个」/ `Shift+Enter`：移到上一处命中（到头循环）。
  void _findPrev() {
    if (_findMatches.isEmpty) return;
    setState(() {
      _findIndex = _findIndex <= 0 ? _findMatches.length - 1 : _findIndex - 1;
      _applyFindToController();
    });
    _locateFind();
  }

  /// 「替换当前一处」（FR-73）：**一次** `value` 赋值 = **一步撤销**（BR-73.3）。
  ///
  /// 替换后命中集合实时重算并保持当前项位置；焦点**留在查找栏**（连续替换是常态，
  /// 夺焦到正文会打断这一节奏——这也是本方法不走 [_writeBack] 的原因）。
  void _replaceCurrent() {
    final m = _currentFindMatch;
    if (m == null) return;
    final text = _content.text;
    if (EditorFormat.isStructuralOffset(text, m.start)) return; // 防御：结构区不替换
    final r = EditorFormat.replaceMatch(text, m, _findReplacement.text);
    _content.value = TextEditingValue(
      text: r.text,
      selection: TextSelection(
        baseOffset: r.selectionStart,
        extentOffset: r.selectionEnd,
      ),
    );
    _save();
    setState(() {
      _refreshFind();
      _applyFindToController();
    });
  }

  /// 「全部替换」（FR-73 / BR-73.3）：**一次编辑**（一步撤销）。
  ///
  /// * **格式模式**：走 `EditorFormat.replaceAllMatches`——它按结构区**跳过**命中并回报
  ///   `skipped` 计数（BR-73.2）；
  /// * **源码模式**：一切字符可见，`replaceAllMatches` 的结构区跳过**不适用**（FR-73
  ///   「源码模式下全量参与」），故在此用 `StringBuffer` **一次性**重建全文（同样是一个
  ///   撤销步），不逐处调用 `replaceMatch` 以免产生多次写入。
  void _replaceAll() {
    final query = _findQuery.text;
    if (query.isEmpty) return;
    final replacement = _findReplacement.text;
    final total = EditorFormat.findMatches(
      _content.text,
      query,
      caseSensitive: _findCaseSensitive,
    ).length;
    if (total == 0) return;

    if (_mode == EditorMode.formatted) {
      final r = EditorFormat.replaceAllMatches(
        _content.text,
        query,
        replacement,
        caseSensitive: _findCaseSensitive,
      );
      final changed = r.text != _content.text;
      if (changed) {
        _content.value = TextEditingValue(
          text: r.text,
          selection: TextSelection.collapsed(offset: r.selectionStart),
        );
        _save();
      }
      setState(() {
        _refreshFind();
        _applyFindToController();
      });
      _toastFindReplaced(changed ? total - r.skipped : 0, r.skipped);
      return;
    }

    final text = _content.text;
    final matches = EditorFormat.findMatches(
      text,
      query,
      caseSensitive: _findCaseSensitive,
    );
    final buf = StringBuffer();
    var cursor = 0;
    var caret = 0;
    for (final m in matches) {
      buf.write(text.substring(cursor, m.start));
      buf.write(replacement);
      cursor = m.end;
      caret = buf.length;
    }
    buf.write(text.substring(cursor));
    _content.value = TextEditingValue(
      text: buf.toString(),
      selection: TextSelection.collapsed(offset: caret),
    );
    _save();
    setState(() {
      _refreshFind();
      _applyFindToController();
    });
    _toastFindReplaced(matches.length, 0);
  }

  /// 替换结果提示（FR-73 要求结构区跳过**在 UI 可见**）。
  void _toastFindReplaced(int replaced, int skipped) {
    final buf = StringBuffer('已替换 $replaced 处');
    if (skipped > 0) buf.write('，已跳过 $skipped 处结构区');
    _toast(buf.toString());
  }

  /// build 期检测命中集合是否**过期**（模式切换 / 撤销重做 / 外部改写），帧后重算一次。
  ///
  /// 刻意不在 build 期直接重算：重算要写控制器字段并 `setState`，会撞
  /// 「build 期间 setState」断言；故只登记一次帧后回调，并用 [_findRefreshPending] 去重。
  void _scheduleFindRefreshIfStale() {
    if (!_findVisible || _findRefreshPending) return;
    if (_findComputedMode == _mode && _findComputedText == _content.text) return;
    _findRefreshPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findRefreshPending = false;
      if (!mounted || !_findVisible) return;
      setState(() {
        _refreshFind();
        _applyFindToController();
      });
    });
  }

  /// 查找栏 UI（元素与 `ValueKey` 见规范 §2.1；插入位置 = 模式行 / 工具栏之下、编辑区之上）。
  Widget _buildFindBar() {
    return _FindBar(
      query: _findQuery,
      replacement: _findReplacement,
      queryFocus: _findQueryFocus,
      caseSensitive: _findCaseSensitive,
      count: _findMatches.length,
      index: _findIndex,
      skipped: _findSkipped,
      onQueryChanged: _onFindQueryChanged,
      onPrev: _findPrev,
      onNext: _findNext,
      onToggleCase: _toggleFindCase,
      onReplace: _replaceCurrent,
      onReplaceAll: _replaceAll,
      onClose: _closeFind,
    );
  }

  /// 查找层快捷键（M15 / FR-73）：`Ctrl/Cmd+F` 打开、`Esc`（**仅栏打开时**）关闭。
  ///
  /// **独立于** [_formatShortcuts]：那张表只在格式模式挂载，且不应把排版键带进源码态
  /// （BR-30.5）。键位归**编辑器子树**（ADR-030 决策 1）：壳层菜单命令只给提示文案、
  /// **不注册 activator**，避免菜单与编辑器双重触发。
  Map<ShortcutActivator, Intent> _findShortcuts() => <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            const _FindIntent(),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            const _FindIntent(),
        if (_findVisible)
          const SingleActivator(LogicalKeyboardKey.escape):
              const _CloseFindIntent(),
      };

  /// 查找层动作（与工具栏 / 菜单**同源**，BR-30.4）。
  Map<Type, Action<Intent>> _findActions() => <Type, Action<Intent>>{
        _FindIntent: CallbackAction<_FindIntent>(
          onInvoke: (_) {
            openFind();
            return null;
          },
        ),
        _CloseFindIntent: CallbackAction<_CloseFindIntent>(
          onInvoke: (_) {
            _closeFind();
            return null;
          },
        ),
      };

  /// **源码模式**的 Actions：只覆写 [PasteTextIntent]（FR-77 粘贴归一）。
  ///
  /// 源码态走框架默认文本编辑快捷键（**不**纳入格式层），故只需接管粘贴这一处：
  /// 读剪贴板纯文本 → `normalizeLineEndings` → 安全插入选区；其余键位照旧冒泡。
  Map<Type, Action<Intent>> _sourceActions() => <Type, Action<Intent>>{
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (_) {
            _pasteFromClipboard(rich: false);
            return null;
          },
        ),
      };

  /// 把编辑区包进 [Shortcuts] / [Actions]：**格式层只挂格式模式，查找层两态都挂**
  /// （M15 / FR-73 / BR-30.5）。预览模式不套（只读渲染，没有可编辑正文）。
  Widget _wrapShortcuts(Widget child) {
    if (_mode == EditorMode.preview) return child;
    final formatted = _mode == EditorMode.formatted;
    final shortcuts = <ShortcutActivator, Intent>{
      if (formatted) ..._formatShortcuts,
      ..._findShortcuts(),
    };
    final actions = <Type, Action<Intent>>{
      if (formatted) ..._formatActions() else ..._sourceActions(),
      ..._findActions(),
    };
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(actions: actions, child: child),
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

  /// 粘贴：按 [rich] 选择来源，产物**直接写入正本**并即时保存（FR-45 / FR-71 / §17）。
  ///
  /// 来源优先级：
  /// 1. `Ctrl+V`（[rich]）且剪贴板有 **HTML 表示** → 用 `note_core` 的 **DOM 式转换器**
  ///    （[convertClipboardHtml]，与批量导入同源，BR-71.2）转成语义等价的 Markdown；
  /// 2. 否则纯文本 → [EditorFormat.escapePlainText] 安全插入。
  ///
  /// HTML 表示的读取顺序：**自研原生通道**（Windows CF_HTML / Android `ClipData`，
  /// 见 [readClipboardHtml]）→ Flutter 内建的 `text/html`（部分平台可能提供）→ 纯文本。
  /// 任一环节失败都**静默回落**（BR-71.6：绝不出现「粘贴无反应」）。
  /// `Ctrl+Shift+V`（[rich] 为 false）恒取纯文本，口径不变。
  Future<void> _pasteFromClipboard({required bool rich}) async {
    String? html;
    if (rich) {
      html = await readClipboardHtml();
      if (html == null || html.trim().isEmpty) {
        try {
          html = (await Clipboard.getData('text/html'))?.text;
        } catch (_) {
          html = null; // 平台不提供 text/html 表示时静默回退纯文本。
        }
      }
    }
    // 纯文本来源同样容错：平台剪贴板不可用时（如无插件的宿主）必须静默回落，
    // 不能因为读不到纯文本而让整个粘贴抛异常（BR-71.6）。
    String? plain;
    try {
      plain = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      plain = null;
    }

    String? payload;
    if (rich && html != null && html.trim().isNotEmpty) {
      final converted = convertClipboardHtml(html);
      if (converted.trim().isNotEmpty) {
        // FR-77 / BR-77.3：**格式与源码两态的粘贴都先做换行归一**（`\r\n` / `\r` → `\n`）——
        // Windows 剪贴板是 CRLF 的真实注入路径，而 CRLF 会让格式模式的行级识别（任务项 /
        // 分割线 / setext）整行失配。**只归换行、不做空白规整**（`normalizeLineEndings`）：
        // `normalizePlainText` 是**导入**口径（逐行 rstrip + 折叠空行 + 补结尾换行），
        // 用在粘贴上会让「行内粘贴一个词」凭空多一个换行。
        // 归一位于**图片本地化之前**，避免把 `data:` 载荷当普通文本处理。
        // `data:` 内联图片落附件（BR-71.4）；远端图片保留绝对地址原样。
        payload = await _localizePastedImages(normalizeLineEndings(converted));
      }
    }
    if (payload == null || payload.trim().isEmpty) {
      // FR-77 / BR-77.3：纯文本同样先做**换行归一**（`\r\n` / `\r` → `\n`；只归换行、不做空白
      // 规整），再按 Markdown 特殊字符转义插入（格式与源码**两态同源**；
      // 源码态的接管见 [_sourceActions]）。
      payload = (plain != null && plain.isNotEmpty)
          ? EditorFormat.escapePlainText(normalizeLineEndings(plain))
          : null;
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

  /// 粘贴内容里的 **`data:` 内联图片**落成**附件**（FR-71 / BR-71.4）。
  ///
  /// 字节入库后把引用改写为 `sui://<sha256>`；**超限 / 解码失败 / 落库失败**时降级为
  /// 图片替代文字——绝不把几 MB 的 base64 塞进正本（那既撑爆同步净荷，也让笔记不可读）。
  /// 远端图片（`http(s)`）保留绝对地址原样（既有外链图片口径，FR-27 / M10-T30）。
  Future<String> _localizePastedImages(String markdown) async {
    final id = _noteId;
    if (id == null || !markdown.contains('data:image/')) return markdown;
    // base64 文本长度上限（约 4 MiB 原始字节）：超过就不落库，避免大对象卡住界面。
    const maxChars = 4 * 1024 * 1024;
    var out = markdown;
    final refs = RegExp(r'!\[([^\]]*)\]\((data:image/[^)\s]+)\)')
        .allMatches(markdown)
        .toList();
    for (var i = 0; i < refs.length; i++) {
      final m = refs[i];
      final alt = m.group(1)!;
      final raw = m.group(2)!;
      final bytes = raw.length > maxChars ? null : _decodeDataUri(raw);
      if (bytes == null || bytes.isEmpty) {
        out = out.replaceAll(m.group(0)!, alt);
        continue;
      }
      try {
        final att = await _controller.addAttachmentFromBytes(
          noteId: id,
          filename: _pastedImageName(alt, raw, i + 1),
          bytes: bytes,
        );
        final label = alt.trim().isEmpty ? att.filename : alt;
        out = out.replaceAll(m.group(0)!, '![$label](sui://${att.sha256})');
      } catch (_) {
        out = out.replaceAll(m.group(0)!, alt);
      }
    }
    return out;
  }

  /// 解码 `data:` URI 的 base64 载荷；非 base64 / 解码失败返回 null。
  Uint8List? _decodeDataUri(String raw) {
    final comma = raw.indexOf(',');
    if (comma < 0) return null;
    if (!raw.substring(0, comma).toLowerCase().contains(';base64')) return null;
    try {
      return base64Decode(raw.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  /// 粘贴图片的建议文件名：优先用替代文字，否则按 MIME 推扩展名并编号。
  String _pastedImageName(String alt, String raw, int index) {
    final mime =
        RegExp(r'^data:image/([a-z0-9.+-]+)').firstMatch(raw.toLowerCase());
    final ext = switch (mime?.group(1) ?? '') {
      'jpeg' || 'jpg' => 'jpg',
      'gif' => 'gif',
      'webp' => 'webp',
      'bmp' => 'bmp',
      'svg+xml' => 'svg',
      _ => 'png',
    };
    final base = alt.trim().isEmpty ? '粘贴图片-$index' : alt.trim();
    final safe = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return safe.toLowerCase().endsWith('.$ext') ? safe : '$safe.$ext';
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

  // ---------------------------------------------------------------------------
  // 链接条与打开外部网址（FR-70 / §16）
  // ---------------------------------------------------------------------------

  /// 正文光标处的链接（格式 / 源码模式）：光标落在 `[文字](网址)` 区间内时非 null。
  ///
  /// 预览态不返回（预览里链接本身即可点击，不需要链接条）。
  MarkdownLink? get _linkAtCursor {
    if (_mode == EditorMode.preview) return null;
    final sel = _content.value.selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    return EditorFormat.linkAt(_content.text, sel.start);
  }

  /// 打开 [url]（FR-70）。**先分流**：笔记引用 → 库内跳转；其余 → 系统默认浏览器。
  ///
  /// 协议不在白名单（`javascript:` / `data:` / `file:` …）或打开失败时只**提示**：
  /// 正本一字不动、编辑器不被打断（BR-70.2 / BR-70.4）。
  Future<void> _openUrl(String url) async {
    final target = url.trim();
    if (target.isEmpty) return;
    // FR-75 / BR-75.1：`sui://note/<笔记ID>` 是**库内跳转**，必须在白名单判定之前接走
    // （它本就不在 `http/https/mailto/tel` 白名单里）。
    final refId = EditorFormat.noteRefId(target);
    if (refId != null) {
      await _openNoteRef(refId);
      return;
    }
    if (!isOpenableUrl(target)) {
      _toast('不支持的链接协议：$target');
      return;
    }
    final ok = await openExternalUrl(target);
    if (!ok && mounted) _toast('未能打开链接：$target');
  }

  /// 跳转到一篇**关联笔记**（M15 / FR-75 / BR-75.2 / BR-75.3）。
  ///
  /// 桌面端沿用既有「在独立窗口打开」入口（[AppController.openNoteInWindow]；未注入窗口
  /// 管理器时它自己**优雅降级**为主窗口内选中该笔记，BR-42.5 / AC-128）。
  /// 目标**不存在 / 属于未解锁的加密笔记本**时只提示：**不改动正本**、不崩溃、不清空链接
  /// （BR-75.3 / BR-70.4）——链接的显示文字是写入时的标题快照，目标改名后不自动跟随
  /// （BR-75.3 已知限制）。
  Future<void> _openNoteRef(String noteId) async {
    // M16 / FR-84：跳转 = **先切目标所属笔记本 / 收件箱 / 归档视图，再选中目标**。
    // 旧实现恒调 `openNoteInWindow`：桌面开独立窗口、窄屏只 `selectNote`，都不会
    // 切换当前笔记本，用户看到的是「点了没反应 / 还在 A 笔记本」。
    final error = await _controller.navigateToNote(noteId);
    if (error != null) _toast(error);
  }

  // ---------------------------------------------------------------------------
  // 关联笔记的插入（M15 / FR-75 / BR-75.1~75.3）
  // ---------------------------------------------------------------------------

  /// 「关联笔记」入口（工具栏按钮 / 桌面「编辑」菜单同源，BR-30.4）。
  ///
  /// **幂等**：只负责打开选择器，不做任何 toggle 态（规范 §3 的明确要求）。
  @override
  void insertNoteRef() {
    unawaited(_pickNoteRef());
  }

  /// 「关联笔记」完整流程：选择器 → `[标题](sui://note/<笔记ID>)` → 回写正本。
  ///
  /// 与「链接」入口**同源**（都经 [EditorFormat.insertLink]），故产出与手写完全一致
  /// （BR-23.2 / BR-75.1）。URL 恒由 [EditorFormat.noteRefUrl] 生成，**绝不**写裸
  /// `sui://<uuid>`——那会被附件引用正则误判并静默截断正本（FR-75 正本语法）。
  Future<void> _pickNoteRef() async {
    final picked = await showDialog<NoteSummary>(
      context: context,
      builder: (_) => _NotePickerDialog(
        controller: _controller,
        excludeNoteId: _noteId,
      ),
    );
    if (picked == null || !mounted) return;
    final value = _content.value;
    final text = value.text;
    final sel = value.selection;
    final start = (sel.isValid ? sel.start : text.length).clamp(0, text.length);
    final end = (sel.isValid ? sel.end : start).clamp(0, text.length);
    final lo = start <= end ? start : end;
    final hi = start <= end ? end : start;
    final r = EditorFormat.insertLink(
      text,
      lo,
      hi,
      label: picked.note.title,
      url: EditorFormat.noteRefUrl(picked.note.id),
    );
    if (r.text == text) {
      _toast('未能插入关联笔记');
      return;
    }
    _writeBack(r);
  }

  // ---------------------------------------------------------------------------
  // 格式模式链接单元（M15 / FR-76 / BR-76.1~76.2）
  // ---------------------------------------------------------------------------

  /// 格式模式下把 Markdown 链接渲染为**原子链接单元**（FR-76）。
  ///
  /// 单击 = **选中**（光标落到链接末尾 → 上方「链接条」随之出现，提供「打开 / 跳转 / 编辑」）；
  /// 双击 = **打开**（普通链接交系统默认浏览器；笔记引用在笔记库内跳转）。
  /// 非白名单协议（`javascript:` / `data:` / `file:` …）与空地址：**可选中、不打开**
  /// （`onDoubleTap` 为 null），正本一字不改（BR-70.2）。
  Widget _buildFormatLink(BuildContext context, MarkdownLink link) {
    final sel = _content.value.selection;
    final selected = sel.isValid &&
        sel.isCollapsed &&
        sel.start >= link.start &&
        sel.start <= link.end;
    return _FormatLinkUnit(
      link: link,
      selected: selected,
      onSelect: () => _selectLink(link),
      onOpen: () => _openUrl(link.url),
    );
  }

  /// 单元格内的链接单元（FR-76「表格单元格内链接同口径」）。
  ///
  /// 与正文**同源**（同一个 [_FormatLinkUnit]）；「怎么打开」由本层注入——单元格只提供
  /// 「选中」（落光标 + 激活本格）。
  Widget _buildCellLinkUnit(
    BuildContext context,
    String text,
    MarkdownLink link, {
    required bool selected,
    required VoidCallback onSelect,
  }) {
    return _FormatLinkUnit(
      link: link,
      selected: selected,
      onSelect: onSelect,
      onOpen: () => _openUrl(link.url),
    );
  }

  /// 选中某个链接：把光标落到链接**末尾**（照 [_selectAttachmentLink] 口径），链接条据此
  /// 出现（`EditorFormat.linkAt` 的两端都算「落在链接里」）。
  void _selectLink(MarkdownLink link) {
    final pos = link.end.clamp(0, _content.text.length);
    _content.value = TextEditingValue(
      text: _content.text,
      selection: TextSelection.collapsed(offset: pos),
    );
    if (_mode != EditorMode.preview) _contentFocus.requestFocus();
  }

  /// 编辑光标处的链接（链接条「编辑」）：弹框预填原值，确认后**就地重写该链接区间**。
  ///
  /// 与「插入」共用同一套口径（[EditorFormat.renderLink] 负责协议补全与文字回退），
  /// 其余字节逐字不动（BR-23.10 / BR-70.4）。
  Future<void> _editLink(MarkdownLink link) async {
    final result = await showDialog<_LinkDialogResult>(
      context: context,
      builder: (_) => _LinkDialog(
        initialLabel: link.label,
        initialUrl: link.url,
        confirmLabel: '保存',
      ),
    );
    if (result == null || !mounted) return;
    final rendered =
        EditorFormat.renderLink(label: result.label, url: result.url);
    if (rendered.isEmpty) {
      _toast('网址为空，未修改链接');
      return;
    }
    final text = _content.text;
    final start = link.start.clamp(0, text.length);
    final end = link.end.clamp(start, text.length);
    final newText = text.replaceRange(start, end, rendered);
    final caret = start + rendered.length;
    _writeBack(FormatResult(newText, caret, caret));
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
              cellUnitBuilder: _buildCellUnit,
              // FR-76：单元格内链接与正文**同口径**（单击选中 / 双击打开）。
              linkUnitBuilder: _buildCellLinkUnit,
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
              // 活动单元格回传：正文工具栏的「链接」据此写入该单元格而非表格外的正文（BR-44.12）。
              onActiveCellChanged: (rowIndex, column) {
                _activeCellTable = table;
                _activeCellRow = rowIndex;
                _activeCellCol = column;
              },
              // 单元格光标处的链接（FR-70）：驱动链接条显示「打开」入口。
              // 用 post-frame 回调落状态：该回调可能由焦点 / 选区监听在构建期间触发，
              // 直接 setState 会撞上「build 期间 setState」断言。
              onActiveCellLinkChanged: (url) {
                if (_activeCellLink == url) return;
                _activeCellLink = url;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
              },
              onInsertLink: (rowIndex, column) =>
                  _insertLinkIntoCell(table, rowIndex, column),
            ),
          ),
        );
      },
    );
  }

  /// 单元格内**附件引用**的原子呈现单元（§12.1.2 / FR-46 / BR-46.6）。
  ///
  /// 与正文**同源**：图片走 `_SuiAttachmentImage`（附件缓存 + 加载 / 失败占位）、附件链接
  /// 显示为附件卡片（残缺引用带错误标记）；单击选中（由单元格提供回调）、双击打开附件
  /// （内置预览 / 系统默认应用，承 FR-47）。图片呈 **`kTableCellImageBoxSize` 边长的正方形
  /// 缩略图**（尺寸固定、自首帧稳定；单元格另以**强制行高**保证它不遮盖同格文本，§12.1.4 ⑮）。
  Widget _buildCellUnit(
    BuildContext context,
    String text,
    AttachmentRef ref, {
    required bool selected,
    required VoidCallback onSelect,
  }) {
    final att = _attachments.where((a) => a.sha256 == ref.sha256).firstOrNull;
    final onOpen = att == null ? null : () => _openAttachment(att);
    // 图片引用交给图片单元（含尺寸属性块解析）；解析失败（如残缺引用）退化为附件卡片。
    final image = ref.isImage ? EditorFormat.findImage(text, ref.start) : null;
    if (image == null) {
      return _FormatAttachmentLinkUnit(
        label: ref.label,
        isImage: ref.isImage,
        corrupt: ref.corrupt,
        selected: selected,
        onSelect: onSelect,
        onDoubleTap: onOpen,
      );
    }
    return _FormatImageUnit(
      image: image,
      selected: selected,
      onSelect: onSelect,
      onDoubleTap: onOpen,
      // 单元格模式：固定**正方形缩略图**（边长 `kTableCellImageBoxSize`），见 §12.1.4 / BR-44.9。
      cellBoxSize: kTableCellImageBoxSize,
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
    // 查找命中集合随正本 / 模式变化（模式切换、撤销、外部改写）会过期：此处只**登记**
    // 一次帧后重算，不在 build 期 setState（FR-73）。
    _scheduleFindRefreshIfStale();

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
                  textInputAction: TextInputAction.next,
                  // M16 / FR-87：标题回车把焦点交给正文，光标留在正文当前选区。
                  onSubmitted: (_) {
                    if (_mode != EditorMode.preview) {
                      _contentFocus.requestFocus();
                    }
                  },
                  onChanged: (_) => _save(),
                  // M14（FR-65 / AC-286）：笔记**标题**同用「笔记正文字体」。
                  style: SuiAppearance.of(context).applyBodyFont(
                        Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w600) ??
                            const TextStyle(),
                      ),
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
              final bodyLink = _linkAtCursor;
              final cellLink = _activeCellLink;
              if (image == null && bodyLink == null && cellLink == null) {
                return const SizedBox.shrink();
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (image != null) ...[
                    const Divider(height: 1),
                    _ImageSizeBar(
                      image: image,
                      onApply: (size) => _applyImageSize(image, size),
                    ),
                  ],
                  // FR-70：光标落在链接里（正文或活动单元格）时给「打开 / 编辑」入口。
                  // FR-75：**笔记引用**（`sui://note/<id>`）按钮文案为「跳转」，且**隐藏
                  // 「编辑」**——就地改网址会把引用改坏（正本里它是标准 Markdown 链接，
                  // 但 URL 是应用生成的 scheme，手改没有意义）。
                  if (cellLink != null) ...[
                    const Divider(height: 1),
                    _LinkBar(
                      url: cellLink,
                      noteRef: EditorFormat.noteRefId(cellLink) != null,
                      onOpen: () => _openUrl(cellLink),
                    ),
                  ] else if (bodyLink != null) ...[
                    const Divider(height: 1),
                    _LinkBar(
                      url: bodyLink.url,
                      noteRef: EditorFormat.noteRefId(bodyLink.url) != null,
                      onOpen: () => _openUrl(bodyLink.url),
                      onEdit: EditorFormat.noteRefId(bodyLink.url) != null
                          ? null
                          : () => _editLink(bodyLink),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
        // 查找栏（FR-73）：模式行 / 工具栏之下、编辑区之上；预览态不提供（FR-73）。
        if (_findVisible && _mode != EditorMode.preview) ...[
          const Divider(height: 1),
          _buildFindBar(),
        ],
        const Divider(height: 1),
        Expanded(
          // FR-81a / FR-93：把**正文列宽**写入控制器 `paragraphWidth`，供围栏代码块底色带定宽。
          // 正文 `TextField` 外侧有左右各 `kEditorBodyPadding` 的内边距（见 `markdown_editor.dart`
          // 的 `_SourceEditor`），故列宽 = 约束宽 − 2 × kEditorBodyPadding（**单一真源**，BR-93.1）；
          // 宽度未知时写 0，控制器**不建立**底色带区间（兜底走逐字形底色）。
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              _content.paragraphWidth = width.isFinite
                  ? (width - 2 * kEditorBodyPadding).clamp(0.0, double.infinity)
                  : 0;
              return _wrapShortcuts(
                MarkdownEditor(
                  controller: _content,
                  mode: _mode,
                  onChanged: () => _save(),
                  imageBuilder: _buildImage,
                  htmlImageBuilder: _buildHtmlImage,
                  webClipBuilder: _buildWebClipPreview,
                  undoController: _undoHistory,
                  focusNode: _contentFocus,
                  showCursor: !_tableHasFocus,
                  // FR-75：预览态点笔记引用 → **库内跳转**（与普通外链分流的接缝）。
                  noteRefOpener: _openNoteRef,
                  onBlockNewline:
                      _mode == EditorMode.formatted ? _handleBlockNewline : null,
                  onSoftNewline:
                      _mode == EditorMode.formatted ? _handleSoftNewline : null,
                  onStructuralDelete: _mode == EditorMode.formatted
                      ? _handleStructuralDelete
                      : null,
                ),
              );
            },
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
      // 查找（M15 / FR-73）：窄屏 / 移动 / Web **无硬件键盘**，故模式行给图标入口；
      // 预览态置灰（FR-73：预览模式不提供笔记内查找）。
      IconButton(
        key: const ValueKey('sui-find-open'),
        tooltip: '在笔记内查找 (Ctrl+F)',
        icon: const Icon(Icons.search),
        isSelected: _findVisible,
        onPressed: _mode == EditorMode.preview ? null : openFind,
      ),
      // 属性（M15 / FR-74）：与「版本历史」同源的**双口径**——独立窗口传入
      // `onToggleProperties`（窗口局部状态），主窗口回落到全局开关。
      IconButton(
        key: const ValueKey('sui-note-properties'),
        tooltip: '属性信息',
        icon: const Icon(Icons.info_outline),
        isSelected: widget.onToggleProperties != null
            ? widget.showProperties
            : context
                .watch<AppController>()
                .propertiesPanelVisibleFor(widget.viewKey),
        onPressed:
            widget.onToggleProperties ?? _controller.togglePropertiesPanel,
      ),
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

  /// 预览里的图片（M10-T30）：
  ///   - `sui://<sha256>` 走**附件缓存**（本地命中或按需下载）——这是唯一会取图的来源；
  ///   - 其余（外链）**一律不取图**，只显示占位与主机名。
  ///
  /// 为什么外链图不出网：剪藏正文里的图片来自被剪藏页面，预览时自动取图会把**本机 IP
  /// 与访问行为**暴露给第三方宿主（input-validation.md §9）。
  Widget _buildImage(MarkdownImageConfig config) {
    final uri = config.uri;
    final label = config.alt ?? config.title ?? uri.toString();
    if (uri.scheme != 'sui') {
      return _ExternalImagePlaceholder(
        label: label,
        uri: uri.toString(),
        width: config.width,
        height: config.height,
      );
    }
    return _SuiAttachmentImage(
      sha256: uri.host,
      label: config.alt ?? config.title ?? '附件',
      width: config.width,
      height: config.height,
    );
  }

  /// 选择文件并挂到当前笔记上，同时在正文里插入附件引用。
  ///
  /// 引用写进正文是刻意的：canonical 正本只有 Markdown，附件与正文必须一起
  /// 同步，否则换台设备拉到笔记却不知道它带附件。
  ///
  /// 引用在光标处插入（独占块，`EditorFormat.insertAttachment`），而非总是追加到文末——
  /// 这样用户在正文中间也能就地插图 / 挂附件。
  ///
  /// `v0.16.3`（FR-91）起的行为：
  /// * **单批次互斥**——批次进行中再次触发直接返回（按钮同时置灰），
  ///   杜绝「连点 → 多批并发 → 后一批覆盖前一批的引用」；
  /// * **即时反馈**——选完文件立刻把文件名放进 [_attachPending]，面板据此逐项显示进度；
  /// * **逐项落笔**——每成功一个就立即把引用写进**当前**正本并保存：附件映射、
  ///   正文引用、笔记落库三者逐项同进，中途退出也不会出现「有列表无引用」；
  /// * **形态随类型**——图片插 `![…](sui://…)`，其余插 `[…](sui://…)`（附件卡片）。
  Future<void> _pickAndAttach({VoidCallback? onChanged}) async {
    final id = _noteId;
    if (id == null || _attaching) return;
    _attaching = true;
    _notifyAttaching(onChanged);
    try {
      List<PickedAttachment> picked;
      try {
        picked = await pickAttachments();
      } catch (e) {
        _toast('打开文件选择器失败：$e');
        return;
      }
      if (picked.isEmpty) return;

      // 选完即公开「本批次有哪些文件」，面板下一帧就能列出（BR-91.1 / AC-516）。
      _attachPending
        ..clear()
        ..addAll(picked.map((f) => f.filename));
      _notifyAttaching(onChanged);

      // 在打开文件选择器之前记下光标位置；选择器是异步的，回来时光标可能已移动。
      final sel = _content.value.selection;
      var insertAt = sel.isValid ? sel.start : _content.text.length;
      var count = 0;
      for (final f in picked) {
        // 编辑器已销毁（关闭笔记 / 切走窗口）就没必要继续落笔；已完成的项两边一致。
        if (!mounted) break;
        try {
          final att = await _controller.addAttachmentFromBytes(
            noteId: id,
            filename: f.filename,
            bytes: f.bytes,
          );
          // 以**当前**正本落笔（不是批次开始时的快照），位置钳制到当前长度：
          // 即便内容在此期间被外部改写，也不会覆盖别人的字。
          final current = _content.text;
          final at = insertAt.clamp(0, current.length);
          final result = EditorFormat.insertAttachment(
            current,
            at,
            at,
            filename: att.filename,
            sha256: att.sha256,
            isImage: att.mimeKind == 'image',
          );
          insertAt = result.selectionStart;
          _content.value = TextEditingValue(
            text: result.text,
            selection: TextSelection.collapsed(offset: insertAt),
          );
          // 逐项保存：映射刚入库，引用必须同一轮落库（BR-91.3 / AC-521）。
          await _save();
          count++;
        } catch (e) {
          _toast('附件「${f.filename}」添加失败：$e');
        } finally {
          _attachPending.remove(f.filename);
          final fresh = await _controller.refreshAttachments(id);
          if (mounted) {
            setState(() => _attachments = fresh);
            _notifyAttaching(onChanged);
          }
        }
      }
      if (count > 0 && mounted) _toast('已添加 $count 个附件');
    } finally {
      _attaching = false;
      _attachPending.clear();
      _notifyAttaching(onChanged);
    }
  }

  /// 通知「添加批次」状态变化：编辑器自身重绘（工具栏置灰），并回调附件面板。
  ///
  /// 附件面板是独立路由，不随编辑器 `setState` 重建，故由调用方传入
  /// `setDialogState` 包一层（`v0.16.3` / BR-91.1 / BR-91.6）。
  void _notifyAttaching(VoidCallback? onChanged) {
    if (mounted) setState(() {});
    onChanged?.call();
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
  /// 无需把整棵编辑区连带刷新。附件在添加时仍会由 [_pickAndAttach] 把引用
  /// （图片 `![…]`、其余 `[…]`）插进正文（canonical 正本只有 Markdown）。
  ///
  /// `v0.16.3`（FR-91）：本批次**待添加**的文件排在已存在附件之前逐项显示，
  /// 完成一个换成一个正常卡片；批次进行中「添加附件」置灰为「正在添加…」，
  /// 面板关闭 / 重开都按编辑器状态重现进度（AC-516\~AC-520）。
  Future<void> _openAttachmentPanel() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final attachments = _attachments;
          // 快照：批次可能在面板打开期间继续推进，构建期只读本地副本。
          final pending = List<String>.of(_attachPending);
          final busy = _attaching;
          final theme = Theme.of(context);
          void refreshPanel() {
            if (dialogContext.mounted) setDialogState(() {});
          }

          return AlertDialog(
            title: Row(
              children: [
                const Expanded(child: Text('附件')),
                if (busy) ...[
                  Flexible(
                    child: Text(
                      '正在添加 ${pending.length} 个…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  '${attachments.length} 个',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: (attachments.isEmpty && pending.isEmpty)
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        '暂无附件。点「添加附件」选择文件；'
                        '图片与附件会自动插入正文。',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: pending.length + attachments.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          if (i < pending.length) {
                            return _PendingAttachmentTile(
                              key: ValueKey('pending-${pending[i]}'),
                              filename: pending[i],
                            );
                          }
                          final a = attachments[i - pending.length];
                          return SizedBox(
                            width: double.infinity,
                            child: _AttachmentCard(
                              key: ValueKey(a.id),
                              attachment: a,
                              onOpen: () => _openAttachment(a),
                              onDelete: () async {
                                await _removeAttachment(a);
                                refreshPanel();
                              },
                            ),
                          );
                        },
                      ),
                    ),
            ),
            actions: [
              TextButton.icon(
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(busy ? '正在添加…' : '添加附件'),
                // 批次互斥：置灰即连点无效（BR-91.2 / AC-518）。
                onPressed: busy
                    ? null
                    : () => _pickAndAttach(onChanged: refreshPanel),
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

/// 「关联笔记」选择器（M15 / FR-75 / ui-spec §26.3 / BR-75.2）：搜索框 + 笔记列表
/// （标题 + 上次修改时间）。
///
/// **数据源必须是全库查询**（[AppController.searchNotesForPicker]），不能复用中栏筛选结果
/// ——否则中栏一筛选，选择器就只剩可见的几条。仓储侧已排除**回收站**（墓碑）与**未解锁的
/// 加密笔记本**内笔记（`locked` 占位）；「**排除当前笔记**」由本组件承担——只有它知道正在
/// 编辑哪一篇（仓储接口刻意不管这件事）。
class _NotePickerDialog extends StatefulWidget {
  const _NotePickerDialog({required this.controller, this.excludeNoteId});

  final AppController controller;

  /// 当前正在编辑的笔记 id（从候选中排除；`null` 表示不排除）。
  final String? excludeNoteId;

  @override
  State<_NotePickerDialog> createState() => _NotePickerDialogState();
}

class _NotePickerDialogState extends State<_NotePickerDialog> {
  final TextEditingController _query = TextEditingController();
  late Future<List<NoteSummary>> _future = _search();

  Future<List<NoteSummary>> _search() async {
    final list = await widget.controller.searchNotesForPicker(_query.text);
    final exclude = widget.excludeNoteId;
    if (exclude == null) return list;
    return list.where((s) => s.note.id != exclude).toList();
  }

  void _refresh() => setState(() => _future = _search());

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('关联笔记'),
      content: SizedBox(
        width: 420,
        height: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('sui-note-picker-query'),
              controller: _query,
              autofocus: true,
              onChanged: (_) => _refresh(),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜索笔记标题',
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<NoteSummary>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final items = snapshot.data ?? const <NoteSummary>[];
                  if (items.isEmpty) {
                    return Center(
                      child: Text(
                        '没有可关联的笔记',
                        style: theme.textTheme.bodySmall,
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final summary = items[i];
                      final title = summary.note.title.trim().isEmpty
                          ? '未命名笔记'
                          : summary.note.title;
                      return ListTile(
                        key: ValueKey('sui-note-picker-${summary.note.id}'),
                        dense: true,
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          formatRelativeTime(summary.note.updatedAt),
                          style: theme.textTheme.labelSmall,
                        ),
                        onTap: () => Navigator.of(context).pop(summary),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
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

/// 「插入超链接」入口的快捷键意图（`Ctrl+K`）：与工具栏按钮同源，走**录入弹框**（§14.1）。
class _LinkIntent extends Intent {
  const _LinkIntent();
}

/// 「插入表格」入口的快捷键意图（`Ctrl+Shift+T`）：与工具栏「表格」/「编辑」菜单同源（FR-44）。
class _TableIntent extends Intent {
  const _TableIntent();
}

/// 「笔记内查找」入口的快捷键意图（`Ctrl/Cmd+F`，M15 / FR-73）。
///
/// 与工具栏「查找」图标、桌面「编辑 → 在笔记内查找」菜单**同源同效**（BR-30.4）：
/// 一律落到 [_NoteEditorState.openFind]，且该方法是**幂等**的「打开并聚焦」。
class _FindIntent extends Intent {
  const _FindIntent();
}

/// 「关闭笔记内查找栏」的快捷键意图（`Esc`，M15 / FR-73）：关闭并把焦点还给正文。
class _CloseFindIntent extends Intent {
  const _CloseFindIntent();
}

/// 携带「粘贴模式」的快捷键意图（FR-45 / §12.2）。
///
/// [rich] 为 true（`Ctrl+V`）时优先读取剪贴板 HTML 表示并转 Markdown；
/// 为 false（`Ctrl+Shift+V`）时仅取纯文本并转义 Markdown 特殊字符。
class _PasteIntent extends Intent {
  const _PasteIntent({required this.rich});

  final bool rich;
}

/// 「插入超链接」录入结果（[showDialog] 的返回值）。
class _LinkDialogResult {
  const _LinkDialogResult(this.label, this.url);

  /// 显示文字（可为空 → 以网址充当，BR-23.10③）。
  final String label;

  /// 网址（非空；未写协议由 [EditorFormat.renderLink] 补 `https://`）。
  final String url;
}

/// 「插入超链接」录入弹框（§14.1 / BR-23.10）。
///
/// 两个输入框「显示文字」「网址」+「取消 / 插入」：**网址为空时「插入」置灰**（不落笔）；
/// 任一输入框回车即确认；取消 / 关闭返回 null（调用方不改动正本）。
class _LinkDialog extends StatefulWidget {
  const _LinkDialog({
    this.initialLabel = '',
    this.initialUrl = '',
    this.confirmLabel = '插入',
  });

  /// 「显示文字」的预填值（有选区时为选中文字）。
  final String initialLabel;

  /// 「网址」的预填值（**编辑既有链接**时传入；插入场景留空）。
  final String initialUrl;

  /// 确认按钮文案（插入 / 保存）。
  final String confirmLabel;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _label =
      TextEditingController(text: widget.initialLabel);
  late final TextEditingController _url =
      TextEditingController(text: widget.initialUrl);

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    super.dispose();
  }

  bool get _canInsert => _url.text.trim().isNotEmpty;

  void _submit() {
    if (!_canInsert) return;
    Navigator.of(context).pop(_LinkDialogResult(_label.text, _url.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('插入超链接'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _label,
            decoration: const InputDecoration(
              labelText: '显示文字',
              hintText: '留空则以网址充当文字',
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('sui-link-url'),
            controller: _url,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '网址',
              hintText: 'https://example.com（不写协议会自动补 https://）',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('sui-link-confirm'),
          onPressed: _canInsert ? _submit : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 链接条（FR-70 / §16）：光标（或活动单元格光标）落在 Markdown 链接区间内时出现，
/// 显示目标地址并提供「打开 / 编辑」入口。
///
/// **为什么不做成原子呈现单元**（像附件那样整块替换为 widget）：链接的显示文字必须能
/// 继续逐字编辑——一旦整块变成 widget，链接文字就改不了了。故沿用**图片尺寸条**的既有范式：
/// 不动呈现层，只在光标进入链接时给一个操作入口；表格单元格同理由本条承载。
class _LinkBar extends StatelessWidget {
  const _LinkBar({
    required this.url,
    required this.onOpen,
    this.onEdit,
    this.noteRef = false,
  });

  /// 目标地址（原样显示）。
  final String url;

  /// 用系统默认浏览器打开（笔记引用时改为**库内跳转**，见 [noteRef]）。
  final VoidCallback onOpen;

  /// 编辑链接（仅**普通链接**的正文场景提供；单元格内链接与笔记引用为 null）。
  final VoidCallback? onEdit;

  /// 是否为**笔记引用**（`sui://note/<笔记ID>`，M15 / FR-75）。
  ///
  /// 为 true 时按钮文案为「跳转」（它不开系统浏览器，而是在笔记库内切换 / 开窗口），
  /// 且「编辑」入口由调用方置空——就地手改引用 URL 没有意义，只会把引用改坏。
  final bool noteRef;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Icon(Icons.link, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (onEdit != null)
              TextButton(
                onPressed: onEdit,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('编辑'),
              ),
            TextButton.icon(
              onPressed: onOpen,
              icon: Icon(noteRef ? Icons.arrow_forward : Icons.open_in_new,
                  size: 16),
              label: Text(noteRef ? '跳转' : '打开'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 笔记内**查找栏**（M15 / FR-73 / BR-73.1\~73.4）：模式行 / 工具栏之下的窄条，
/// 与 [_LinkBar] 同一范式（紧凑按钮 + 单行 + 横向可滚）。
///
/// 元素与 `ValueKey`（规范 §2.1；测试按 key 断言）：
/// `sui-find-query` / `sui-find-count` / `sui-find-prev` / `sui-find-next` / `sui-find-case` /
/// `sui-find-replace-query` / `sui-find-replace` / `sui-find-replace-all` / `sui-find-close`。
///
/// 键盘（FR-73 交互细节）：`Enter` = 下一个、`Shift+Enter` = 上一个、`Esc` = 关闭并**把焦点
/// 还给正文**。用 [Focus]（`canRequestFocus: false`）拦截——与 `markdown_editor.dart` 的
/// `_wrapKeys` 同一套路：它只作为键事件冒泡的中间节点，不额外占用 Tab 焦点。
///
/// 本组件**无状态**：查询词 / 当前项 / 命中集合全部归 `_NoteEditorState`，故关闭再打开
/// 不丢查询词，且「替换后实时重算并保持当前项」只需外层一次 `setState`。
class _FindBar extends StatelessWidget {
  const _FindBar({
    required this.query,
    required this.replacement,
    required this.queryFocus,
    required this.caseSensitive,
    required this.count,
    required this.index,
    required this.skipped,
    required this.onQueryChanged,
    required this.onPrev,
    required this.onNext,
    required this.onToggleCase,
    required this.onReplace,
    required this.onReplaceAll,
    required this.onClose,
  });

  /// 查询词输入框（控制器归上层）。
  final TextEditingController query;

  /// 替换词输入框（控制器归上层）。
  final TextEditingController replacement;

  /// 查询框焦点节点（打开 / 重开时聚焦并全选）。
  final FocusNode queryFocus;

  /// 是否区分大小写。
  final bool caseSensitive;

  /// 参与导航的命中数（格式模式已排除结构区）。
  final int count;

  /// 当前命中下标（`-1` = 无）。
  final int index;

  /// 被结构区挡下的命中数（> 0 时显示「已跳过 N 处结构区」）。
  final int skipped;

  final ValueChanged<String> onQueryChanged;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToggleCase;
  final VoidCallback onReplace;
  final VoidCallback onReplaceAll;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final position = count == 0 ? 0 : (index < 0 ? 1 : index + 1);
    final counter = count == 0 ? '0/0' : '$position/$count';
    final hint = skipped > 0 ? ' · 已跳过 $skipped 处结构区' : '';
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.escape) {
          onClose();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) {
          if (HardwareKeyboard.instance.isShiftPressed) {
            onPrev();
          } else {
            onNext();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        height: 44,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              SizedBox(
                width: 180,
                child: TextField(
                  key: const ValueKey('sui-find-query'),
                  controller: query,
                  focusNode: queryFocus,
                  autofocus: true,
                  onChanged: onQueryChanged,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '查找',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 计数 + 结构区跳过提示：`n/m` 或 `n/m · 已跳过 N 处结构区`（FR-73 要求
              // 两态差异在 UI 可见）。
              Text(
                key: const ValueKey('sui-find-count'),
                '$counter$hint',
                style: theme.textTheme.bodySmall,
              ),
              IconButton(
                key: const ValueKey('sui-find-prev'),
                tooltip: '上一个 (Shift+Enter)',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                onPressed: count == 0 ? null : onPrev,
              ),
              IconButton(
                key: const ValueKey('sui-find-next'),
                tooltip: '下一个 (Enter)',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                onPressed: count == 0 ? null : onNext,
              ),
              // 区分大小写（默认不区分）；选中态以 `isSelected` 呈现。
              IconButton(
                key: const ValueKey('sui-find-case'),
                tooltip: '区分大小写',
                visualDensity: VisualDensity.compact,
                isSelected: caseSensitive,
                icon: const Text('Aa', style: TextStyle(fontSize: 13)),
                onPressed: onToggleCase,
              ),
              const _ToolbarDivider(),
              SizedBox(
                width: 180,
                child: TextField(
                  key: const ValueKey('sui-find-replace-query'),
                  controller: replacement,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '替换为',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey('sui-find-replace'),
                onPressed: count == 0 ? null : onReplace,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('替换'),
              ),
              TextButton(
                key: const ValueKey('sui-find-replace-all'),
                onPressed: count == 0 ? null : onReplaceAll,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('全部替换'),
              ),
              IconButton(
                key: const ValueKey('sui-find-close'),
                tooltip: '关闭查找 (Esc)',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    this.cellBoxSize,
  });

  final ParsedImage image;
  final bool selected;
  final VoidCallback onSelect;

  /// 是否按**块级呈现单元**布局（§5.5）：引用独占一块时为 true——块宽即段落宽、
  /// 块高向下扩展，后续文字整体下移；历史行内引用为 false，保持行内呈现。
  final bool block;

  final VoidCallback? onDoubleTap;

  /// **单元格模式**的缩略图盒子边长（像素，正方形）；`null` = 正文模式（按段落宽度 / 图片
  /// 自然比例呈现，行为不变）。单元格内固定边长使尺寸**自首帧即稳定**（§12.1.4 / BR-44.9），
  /// 配合单元格的**强制行高**（`format_table.dart` 的 `_imageUnitStrut`）保证图片落在自己
  /// 那一行内、不遮盖同格文本（§12.1.4 ⑮）。
  final double? cellBoxSize;

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
              // M10-T30：外链图片**不取图**（与预览同一口径，见 _buildImage 注释）。
              // 两态都显示同一占位，顺带守住「格式与预览一致」的口径。
              imageWidget = _ExternalImagePlaceholder(
                label: label,
                uri: image.url,
                width: dims.$1,
                height: dims.$2,
              );
            }
            if (!block) return _sized(imageWidget);
            // 块级呈现：块占满段落宽（图片左对齐），使该行只承载图片，
            // 行高即块高、向下扩展，后续文字整体下移、与图片不重叠。
            // 用 Align 而非定宽 SizedBox：宽度受限时撑满段落，无界时自动收缩。
            return Align(
              alignment: Alignment.centerLeft,
              child: _sized(imageWidget),
            );
          },
        ),
      ),
    );
  }

  /// 单元格内图片的**固定正方形缩略图盒子**（§12.1.4 / BR-44.9）：`cellBoxSize != null` 即单元格模式。
  ///
  /// 返回 `边长 × 边长` 的盒子，图片以 `BoxFit.scaleDown` + 居中填充——尺寸**自首帧即稳定**
  /// （与异步解码无关）；**边长固定（不是列宽）**，图片前 / 后的文字才能与它**同行**排布、不被它挤走。
  /// 配合单元格的**强制行高**（`format_table.dart` 的 `_imageUnitStrut`，行高 = 边长）与最小高度
  /// （`_tableCellMinHeightWithImage`），图片**正好落在自己那一行内**、不遮盖同格文本（⑮）。
  /// 正文（`cellBoxSize == null`）原样返回，**行为不变**。
  Widget _sized(Widget child) {
    final box = cellBoxSize;
    if (box == null) return child;
    return SizedBox(width: box, height: box, child: child);
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

/// 格式模式内联的**链接呈现单元**（M15 / FR-76 / BR-76.1 / BR-76.2）：把 `[文字](网址)`
/// 呈现为可点选 / 可双击的**原子**单元。
///
/// * **单击 = 选中**（光标落到链接末尾、既有「链接条」随之出现，承载「打开 / 跳转 / 编辑」）；
/// * **双击 = 打开**（普通链接交系统默认浏览器，白名单与失败提示同 FR-70；**笔记引用**
///   `sui://note/<id>` 在笔记库内跳转）；
/// * **非白名单协议**（`javascript:` / `data:` / `file:` …）与空地址：可选中、**不打开**
///   （`onDoubleTap` 为 null），正本一字不改（BR-70.2 / BR-70.4）。
///
/// 显示文字**必须**用 `Text.data` 承载（本组件的 `Text(link.label)`）：格式模式与预览的
/// 「可见文本一致」门禁（`FormatPreviewParity`）只从 `Text.data` 收集可见文本，
/// 改用 `Text.rich` 会让门禁回归（BR-76.2 / AC-435）。
class _FormatLinkUnit extends StatelessWidget {
  const _FormatLinkUnit({
    required this.link,
    required this.selected,
    required this.onSelect,
    required this.onOpen,
  });

  /// 被承载的链接（偏移相对正本）。
  final MarkdownLink link;

  /// 单击选中态（光标落在链接区间内）：加浅底 + 细边框，与图片 / 附件单元同范式。
  final bool selected;

  final VoidCallback onSelect;
  final VoidCallback onOpen;

  /// 该链接是否**可打开**：外部协议走白名单；**笔记引用**恒可打开（由应用自身处理，
  /// 不交给系统浏览器）。
  bool get _openable =>
      isOpenableUrl(link.url) || EditorFormat.noteRefId(link.url) != null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final noteRef = EditorFormat.noteRefId(link.url) != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSelect,
      onDoubleTap: _openable ? onOpen : null,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.10) : null,
          border: selected ? Border.all(color: scheme.primary) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 笔记引用给一个图标，与普通外链**一眼可辨**（观感差异跟随，不改正本）。
            if (noteRef) ...[
              Icon(Icons.link, size: 13, color: scheme.primary),
              const SizedBox(width: 2),
            ],
            // 标签：**必须** `Text.data`（parity 契约，见类文档）。
            Text(
              link.label,
              style: TextStyle(
                color: scheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
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
          // M14（FR-67 / AC-304）：附件单元改**中性灰**（原 `secondaryContainer` 带绿调）。
          color: SuiAppearance.of(context).palette.chipSurface,
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
            // 文件名须**可压缩**：卡片所在的内联 widget 宽受段落 / 单元格可用宽度约束，
            // 而 `Text` 默认按自身固有宽度参与 `Row` 布局——文件名一长（如长标题 PDF）
            // 就把 `Row` 撑出可用宽度（实测 `RenderFlex overflowed by 315 pixels`），
            // 卡片于是横向溢出单元格 / 段落（§12.1.4 ⑫）。`Flexible` + 单行省略号即可：
            // 短名照旧自适应，长名截断且不再溢出（正文与单元格同时受益）。
            Flexible(
              child: Text(
                label.isEmpty ? '附件' : label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSecondaryContainer,
                ),
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

/// 附件面板里「本批次待添加」的占位行（`v0.16.3` / FR-91 / AC-516）。
///
/// 只读：不可点开、不可移除；带进行态，明确告诉用户「文件已收到、正在添加」，
/// 避免用户以为没生效而反复点「添加附件」。
class _PendingAttachmentTile extends StatelessWidget {
  const _PendingAttachmentTile({super.key, required this.filename});

  final String filename;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              filename,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '添加中…',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
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
      // M14（FR-67 / AC-304）：附件卡片改**中性灰**（无绿调）。
      color: SuiAppearance.of(context).palette.chipSurface,
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
/// 预览 / 格式模式里的**外链图片**占位（M10-T30）。
///
/// 刻意**不取图**：剪藏正文中的外链图片来自被剪藏页面，自动加载会把本机 IP 与访问行为
/// 暴露给第三方宿主（input-validation.md §9）。只展示文件名与主机名，正本一字不动。
class _ExternalImagePlaceholder extends StatelessWidget {
  const _ExternalImagePlaceholder({
    required this.label,
    required this.uri,
    this.width,
    this.height,
  });

  final String label;
  final String uri;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = Uri.tryParse(uri)?.host ?? '';
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_not_supported_outlined,
                  size: 18, color: theme.colorScheme.outline),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            host.isEmpty ? '外链图片未加载（避免预览出网）' : '外链图片未加载（$host）',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

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
          // 文件名须**可压缩**：单元格内呈现单元是固定边长的小盒子（`kTableCellImageBoxSize`
          // = 80，去掉内边距后仅剩约 58px），不可压缩的 `Text` 会把 `Row` 撑破
          // （实测 `RenderFlex overflowed by 38 pixels`，§12.1.4 ⑮）——加 `Flexible` +
          // 单行省略号后短名照旧、长名截断。
          Flexible(
            child: Text(
              loading ? '加载「$label」…' : label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
