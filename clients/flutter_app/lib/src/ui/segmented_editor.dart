import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:note_core/note_core.dart';

import 'appearance/app_palette.dart';
import 'markdown_editing_controller.dart';
import 'snapshot_html_view.dart';

/// 文档块类型（大笔记分块编辑的最小单位）。
///
/// 「逻辑单元」口径：标题 / 段落 / 列表组 / 引用组 / 围栏代码块 / 表格 / HTML 块 /
/// 独立图片 / 独立附件 / 分割线，各自成为一个单元（表格、图片、附件不混在段落里）。
enum BlockKind {
  text,
  heading,
  list,
  quote,
  fence,
  table,
  html,
  image,
  attachment,
  rule,
}

/// 正本里的一个顶层块 `[start, end)`。
class DocBlock {
  DocBlock({required this.start, required this.end, required this.kind});

  int start;
  int end;
  final BlockKind kind;

  String source(String text) => text.substring(start, end);
}

/// 行级判定的正则（与 `EditorFormat` 的扫描口径对齐；这里只用于**切分单元**）。
final RegExp _reHeading = RegExp(r'^[ \t]{0,3}#{1,6}[ \t]+');
final RegExp _reFence = RegExp(r'^[ \t]*(```|~~~)');
final RegExp _reList = RegExp(r'^[ \t]*([-*+]|\d+\.)[ \t]+');
final RegExp _reQuote = RegExp(r'^[ \t]{0,3}>');
final RegExp _reRule = RegExp(r'^[ \t]{0,3}(-{3,}|\*{3,}|_{3,})[ \t]*$');
final RegExp _reImageOnly =
    RegExp(r'^[ \t]*!\[[^\]\n]*\]\([^)\n]*\)(\{[^}\n]*\})?[ \t]*$');
final RegExp _reAttachOnly =
    RegExp(r'^[ \t]*\[[^\]\n]*\]\(sui://[^)\n]*\)[ \t]*$');

/// 把正本切成**逻辑单元**（块级虚拟化的最小单位）。
///
/// 单元类型见 [BlockKind]：标题 / 段落 / 列表组 / 引用组 / 围栏 / 表格 / HTML /
/// 独立图片 / 独立附件 / 分割线。任意类型都可以单独点开编辑，互不牵连。
List<DocBlock> splitDocBlocks(String text) {
  final out = <DocBlock>[];
  if (text.isEmpty) return out;

  // 原子块（围栏 / 表格 / HTML）：按起点索引，扫描时整体跳过。
  final atomic = <int, (int, BlockKind)>{};
  for (final f in EditorFormat.fenceBlocks(text)) {
    if (f.end > f.start) atomic[f.start] = (f.end, BlockKind.fence);
  }
  for (final h in htmlBlocks(text)) {
    if (!h.isEmpty && h.end > h.start) {
      atomic.putIfAbsent(h.start, () => (h.end, BlockKind.html));
    }
  }
  var from = 0;
  while (from < text.length) {
    final table = EditorFormat.parseTable(text, from);
    if (table == null) {
      final nl = text.indexOf('\n', from);
      if (nl == -1) break;
      from = nl + 1;
      continue;
    }
    if (table.wellFormed && table.end > table.start) {
      atomic.putIfAbsent(table.start, () => (table.end, BlockKind.table));
    }
    if (table.end >= text.length) break;
    from = table.end + 1;
  }

  var i = 0;
  while (i < text.length) {
    // 跳过空行（空行不属于任何单元，靠块间距体现）。
    while (i < text.length) {
      final le = _lineEnd(text, i);
      if (text.substring(i, le).trim().isNotEmpty) break;
      i = le < text.length ? le + 1 : text.length;
    }
    if (i >= text.length) break;

    final a = atomic[i];
    if (a != null) {
      out.add(DocBlock(start: i, end: a.$1, kind: a.$2));
      i = a.$1 < text.length ? a.$1 + 1 : text.length;
      continue;
    }

    final lineEnd = _lineEnd(text, i);
    final line = text.substring(i, lineEnd);
    if (_reFence.hasMatch(line)) {
      // 围栏未闭合 / 被表格区间挡掉的兜底：整行一个单元。
      out.add(DocBlock(start: i, end: lineEnd, kind: BlockKind.fence));
      i = _next(text, lineEnd);
      continue;
    }
    if (_reRule.hasMatch(line)) {
      out.add(DocBlock(start: i, end: lineEnd, kind: BlockKind.rule));
      i = _next(text, lineEnd);
    } else if (_reHeading.hasMatch(line)) {
      out.add(DocBlock(start: i, end: lineEnd, kind: BlockKind.heading));
      i = _next(text, lineEnd);
    } else if (_reImageOnly.hasMatch(line)) {
      out.add(DocBlock(start: i, end: lineEnd, kind: BlockKind.image));
      i = _next(text, lineEnd);
    } else if (_reAttachOnly.hasMatch(line)) {
      out.add(DocBlock(start: i, end: lineEnd, kind: BlockKind.attachment));
      i = _next(text, lineEnd);
    } else if (_reList.hasMatch(line)) {
      i = _consumeRun(text, i, lineEnd, out, BlockKind.list,
          (l) => _reList.hasMatch(l) || l.startsWith(' ') || l.startsWith('\t'));
    } else if (_reQuote.hasMatch(line)) {
      i = _consumeRun(text, i, lineEnd, out, BlockKind.quote,
          (l) => _reQuote.hasMatch(l));
    } else {
      i = _consumeText(text, i, lineEnd, out, atomic);
    }
  }
  return out;
}

int _lineEnd(String text, int start) {
  final nl = text.indexOf('\n', start);
  return nl == -1 ? text.length : nl;
}

int _next(String text, int lineEnd) =>
    lineEnd < text.length ? lineEnd + 1 : text.length;

/// 连续同类行（列表组 / 引用组）合成一个单元。
int _consumeRun(
  String text,
  int start,
  int firstLineEnd,
  List<DocBlock> out,
  BlockKind kind,
  bool Function(String line) continues,
) {
  var end = firstLineEnd;
  var next = _next(text, firstLineEnd);
  while (next < text.length) {
    final le = _lineEnd(text, next);
    final line = text.substring(next, le);
    if (line.trim().isEmpty || !continues(line)) break;
    end = le;
    next = _next(text, le);
  }
  out.add(DocBlock(start: start, end: end, kind: kind));
  return next;
}

/// 普通段落：连续非空、非结构行，单块上限约 4000 字符（按行断开）。
int _consumeText(
  String text,
  int start,
  int firstLineEnd,
  List<DocBlock> out,
  Map<int, (int, BlockKind)> atomic,
) {
  var end = firstLineEnd;
  var next = _next(text, firstLineEnd);
  while (next < text.length) {
    if (atomic.containsKey(next)) break;
    final le = _lineEnd(text, next);
    final line = text.substring(next, le);
    if (line.trim().isEmpty) break;
    if (_isUnitStart(line)) break;
    if (end - start >= 4000) break;
    end = le;
    next = _next(text, le);
  }
  out.add(DocBlock(start: start, end: end, kind: BlockKind.text));
  return next;
}

/// 该行是否会开启一个新单元（用于终止当前段落）。
bool _isUnitStart(String line) =>
    _reHeading.hasMatch(line) ||
    _reRule.hasMatch(line) ||
    _reFence.hasMatch(line) ||
    _reList.hasMatch(line) ||
    _reQuote.hasMatch(line) ||
    _reImageOnly.hasMatch(line) ||
    _reAttachOnly.hasMatch(line);

/// 大笔记的**分块编辑器**（块级虚拟化 + 当前块编辑）。
///
/// 达到 [LargeNotePolicy] 阈值时由 `NoteEditor` 自动启用：
/// * `ListView` 只构建视口附近的块，每块单独做格式渲染（块内偏移，代价与块长相关）；
/// * 点按某块 → 该块换成只含本块源码的 `TextField`，输入即写回全文（`onChanged` 收到完整正本）；
/// * 其余块只读，点按即可切换编辑目标。
///
/// MVP 取舍：单块内撤销；跨块选区 / 查找 / 表格与图片块的结构编辑暂不在本模式提供
/// （切回全文模式即可）。
class SegmentedMarkdownEditor extends StatefulWidget {
  const SegmentedMarkdownEditor({
    super.key,
    required this.text,
    required this.onChanged,
    this.imageBuilder,
    this.htmlImageBuilder,
    this.webClipBuilder,
    this.formatImageBuilder,
    this.formatTaskCheckboxBuilder,
    this.formatAttachmentLinkBuilder,
    this.formatTableBuilder,
    this.formatHtmlBlockBuilder,
    this.formatWebClipBuilder,
    this.formatLinkBuilder,
    this.onToggleTask,
    this.onActiveBlockChanged,
  });

  /// 完整正本（Markdown）。
  final String text;

  /// 任一块提交后的完整正本。
  final ValueChanged<String> onChanged;

  final MarkdownSizedImageBuilder? imageBuilder;
  final SnapshotHtmlImageBuilder? htmlImageBuilder;
  final FormatWebClipSpanBuilder? webClipBuilder;
  final FormatImageSpanBuilder? formatImageBuilder;
  final FormatTaskCheckboxBuilder? formatTaskCheckboxBuilder;
  final FormatAttachmentLinkSpanBuilder? formatAttachmentLinkBuilder;
  final FormatTableSpanBuilder? formatTableBuilder;
  final FormatHtmlBlockSpanBuilder? formatHtmlBlockBuilder;
  final FormatWebClipSpanBuilder? formatWebClipBuilder;
  final FormatLinkSpanBuilder? formatLinkBuilder;
  final void Function(int lineStart)? onToggleTask;

  /// 当前编辑块变化（进入 / 退出编辑）时通知父级重绘工具栏（撤销/重做目标随之切换）。
  final VoidCallback? onActiveBlockChanged;

  @override
  State<SegmentedMarkdownEditor> createState() =>
      SegmentedMarkdownEditorState();
}

/// 分块编辑器的公开状态：供 `NoteEditor` 的格式工具栏读取「当前块控制器」，
/// 并在指令执行后把焦点交还当前块。
class SegmentedMarkdownEditorState extends State<SegmentedMarkdownEditor> {
  late String _text;
  late List<DocBlock> _blocks;
  int? _active;
  MarkdownEditingController? _controller;
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// 正在把焦点交给新激活的块（此期间忽略焦点丢失）。
  bool _activating = false;

  @override
  void initState() {
    super.initState();
    _text = widget.text;
    _blocks = splitDocBlocks(_text);
    _focus.addListener(_onFocusChanged);
  }

  /// 焦点移到别处（点标题 / 侧栏 / 空白区）时结束当前块编辑——不再需要「完成」按钮。
  void _onFocusChanged() {
    if (_focus.hasFocus || _activating || _keepActive || _active == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _active == null || _focus.hasFocus || _keepActive) return;
      _deactivate();
    });
  }

  @override
  void didUpdateWidget(covariant SegmentedMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 编辑中不跟随外部文本（本编辑器的每次提交都会回传给父级，避免把光标冲掉）。
    if (_active == null && widget.text != _text) {
      _text = widget.text;
      _blocks = splitDocBlocks(_text);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _undo?.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  TextStyle _style(BuildContext context) {
    // `RichText` **不继承** `DefaultTextStyle`；若样式里没有前景色，`ui.TextStyle.color`
    // 为 null，引擎会按**透明**绘制（表现：只读块内容看不见，点开 TextField 才看得到）。
    // 故这里显式合并继承样式（自带 color / 字号），再套笔记正文字体。
    final inherited = DefaultTextStyle.of(context).style;
    return SuiAppearance.of(context).applyBodyFont(
      inherited.merge(const TextStyle(fontSize: 15, height: 1.6)),
    );
  }

  /// 当前正在编辑的块控制器（没有块在编辑时为 null）。
  MarkdownEditingController? get activeController =>
      _active == null ? null : _controller;

  /// 当前块的撤销/重做栈（没有块在编辑时为 null）。
  ///
  /// 这是 `TextField` 自带的**细粒度**撤销（逐字符/词组）；跨块的勾连由下面的
  /// 文档级撤销栈承担。
  UndoHistoryController? _undo;
  UndoHistoryController? get activeUndo => _undo;

  /// 文档级撤销/重做：以**一次块编辑会话**为一步，存整篇快照（上限 20 步）。
  final List<String> _docUndo = <String>[];
  final List<String> _docRedo = <String>[];
  static const int _docUndoLimit = 20;
  String? _sessionBefore;

  /// 工具栏点击会抢走焦点：先挂起「焦点丢失即结束编辑」，指令执行后再交还焦点。
  bool _keepActive = false;

  void prepareToolbarAction() {
    _keepActive = true;
  }

  void focusActiveBlock() {
    _keepActive = false;
    if (_active != null && _controller != null) _focus.requestFocus();
  }

  /// 结束一次块编辑会话：整篇文本有变化就压入文档级撤销栈。
  void _finalizeSession() {
    final before = _sessionBefore;
    _sessionBefore = null;
    if (before == null || before == _text) return;
    _docUndo.add(before);
    if (_docUndo.length > _docUndoLimit) _docUndo.removeAt(0);
    _docRedo.clear();
  }

  /// 文档级撤销是否可用（没有块在编辑时由工具栏使用）。
  bool get canUndoDocument => _docUndo.isNotEmpty;

  /// 文档级重做是否可用。
  bool get canRedoDocument => _docRedo.isNotEmpty;

  /// 把一段**块级 Markdown**（表格 / 图片 / 附件引用）作为**新单元**插入当前块光标处：
  /// 光标前的文字、新单元、光标后的文字各自成块；链接等**行内**语法仍走块内插入。
  void insertBlockUnit(String markdown) {
    final unit = markdown.trim();
    if (unit.isEmpty) return;
    _keepActive = false;
    final index = _active;
    var caret = _text.length;
    if (index != null && _controller != null) {
      final block = _blocks[index];
      final sel = _controller!.selection;
      final local = sel.isValid ? sel.start : block.end - block.start;
      caret = (block.start + local).clamp(0, _text.length);
    }
    final before = _text.substring(0, caret).replaceFirst(RegExp(r'\n+$'), '');
    final after = _text.substring(caret).replaceFirst(RegExp(r'^\n+'), '');
    final parts = <String>[
      if (before.trim().isNotEmpty) before,
      unit,
      if (after.trim().isNotEmpty) after,
    ];
    _finalizeSession();
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _controller = null;
    _undo?.dispose();
    _undo = null;
    _active = null;
    _text = parts.join('\n\n');
    _blocks = splitDocBlocks(_text);
    widget.onChanged(_text);
    widget.onActiveBlockChanged?.call();
    setState(() {});
  }

  /// 撤销**上一次块编辑会话**（跨块；编辑中的逐字符撤销仍由块内 `TextField` 负责）。
  void undoDocument() {
    if (_active != null) _deactivate();
    if (_docUndo.isEmpty) return;
    _docRedo.add(_text);
    _text = _docUndo.removeLast();
    _blocks = splitDocBlocks(_text);
    widget.onChanged(_text);
    widget.onActiveBlockChanged?.call();
    setState(() {});
  }

  /// 重做上一次被撤销的块编辑会话。
  void redoDocument() {
    if (_active != null) _deactivate();
    if (_docRedo.isEmpty) return;
    _docUndo.add(_text);
    _text = _docRedo.removeLast();
    _blocks = splitDocBlocks(_text);
    widget.onChanged(_text);
    widget.onActiveBlockChanged?.call();
    setState(() {});
  }

  void _onControllerChanged() {
    final c = _controller;
    if (c == null) return;
    _onBlockChanged(c.text);
  }

  void _attachBuilders(MarkdownEditingController c) {
    c.formatImageBuilder = widget.formatImageBuilder;
    c.formatTaskCheckboxBuilder = widget.formatTaskCheckboxBuilder;
    c.formatAttachmentLinkBuilder = widget.formatAttachmentLinkBuilder;
    c.formatTableBuilder = widget.formatTableBuilder;
    c.formatHtmlBlockBuilder = widget.formatHtmlBlockBuilder;
    c.formatWebClipBuilder = widget.formatWebClipBuilder;
    c.formatLinkBuilder = widget.formatLinkBuilder;
    c.onToggleTask = widget.onToggleTask;
  }

  void _activate(int index) {
    if (_active == index) return;
    _finalizeSession();
    _controller?.dispose();
    final block = _blocks[index];
    // 文档级撤销存**整篇快照**（以一次块编辑会话为一步）。
    _sessionBefore = _text;
    final c = MarkdownEditingController(text: block.source(_text));
    c.styled = true;
    _attachBuilders(c);
    // 监听控制器：用户输入与**工具栏的程序化写入**都经此写回完整正本。
    c.addListener(_onControllerChanged);
    _undo = UndoHistoryController();
    setState(() {
      _active = index;
      _controller = c;
    });
    widget.onActiveBlockChanged?.call();
    _activating = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_active == index) _focus.requestFocus();
      _activating = false;
    });
  }

  void _deactivate() {
    if (_active == null) return;
    _finalizeSession();
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    _undo?.dispose();
    _undo = null;
    setState(() {
      _controller = null;
      _active = null;
      _blocks = splitDocBlocks(_text);
    });
    widget.onActiveBlockChanged?.call();
  }

  void _onBlockChanged(String value) {
    final index = _active;
    if (index == null) return;
    final block = _blocks[index];
    final oldLength = block.end - block.start;
    if (value.length == oldLength && value == block.source(_text)) return;
    final delta = value.length - oldLength;
    _text = _text.replaceRange(block.start, block.end, value);
    block.end = block.start + value.length;
    for (var i = index + 1; i < _blocks.length; i++) {
      _blocks[i].start += delta;
      _blocks[i].end += delta;
    }
    widget.onChanged(_text);
  }

  Widget _buildReadOnly(BuildContext context, int index) {
    final block = _blocks[index];
    final style = _style(context);
    final c = MarkdownEditingController(text: block.source(_text));
    c.styled = true;
    _attachBuilders(c);
    final span = c.buildTextSpan(
      context: context,
      style: style,
      withComposing: false,
    );
    c.dispose();
    return GestureDetector(
      key: ValueKey<String>('seg-block-$index'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _activate(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: RichText(
          text: span,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: false),
        ),
      ),
    );
  }

  Widget _buildEditor(BuildContext context) {
    final style = _style(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      // 不渲染「完成」按钮（会单独占一行）；结束编辑的方式：
      // 点别的段落 / 点空白区 / 焦点移出（标题、侧栏）/ `Esc`。
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _deactivate();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: _withCaretKeys(TextField(
          controller: _controller,
          focusNode: _focus,
          undoController: _undo,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: style,
          strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: false),
          decoration: const InputDecoration(
            border: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.zero,
          ),
        )),
      ),
    );
  }

  /// 块内 `Home` / `End`（以及 `Ctrl+Home` / `Ctrl+End`）显式映射到行首 / 行尾 / 块首 / 块尾。
  ///
  /// `ListView` 自带滚动快捷键，且各平台对 Home/End 的默认映射不一致；这里显式接管，
  /// 保证块内行为与普通 `TextField` 一致（Windows）。
  Widget _withCaretKeys(Widget child) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.home): _caretToLineStart,
        const SingleActivator(LogicalKeyboardKey.end): _caretToLineEnd,
        const SingleActivator(LogicalKeyboardKey.home, control: true):
            _caretToDocumentStart,
        const SingleActivator(LogicalKeyboardKey.end, control: true):
            _caretToDocumentEnd,
        const SingleActivator(LogicalKeyboardKey.pageUp): _pageUp,
        const SingleActivator(LogicalKeyboardKey.pageDown): _pageDown,
        const SingleActivator(LogicalKeyboardKey.arrowUp, control: true):
            _toPrevBlock,
        const SingleActivator(LogicalKeyboardKey.arrowDown, control: true):
            _toNextBlock,
      },
      child: child,
    );
  }

  void _setCaret(int offset) {
    final c = _controller;
    if (c == null) return;
    c.selection =
        TextSelection.collapsed(offset: offset.clamp(0, c.text.length));
  }

  void _caretToLineStart() {
    final c = _controller;
    if (c == null || !c.selection.isValid) return;
    final pos = c.selection.extentOffset;
    _setCaret(pos == 0 ? 0 : c.text.lastIndexOf('\n', pos - 1) + 1);
  }

  void _caretToLineEnd() {
    final c = _controller;
    if (c == null || !c.selection.isValid) return;
    final nl = c.text.indexOf('\n', c.selection.extentOffset);
    _setCaret(nl == -1 ? c.text.length : nl);
  }

  /// `Ctrl+Home`：跳到**全文第一个单元**的行首（并进入编辑）。
  void _caretToDocumentStart() {
    if (_blocks.isEmpty) return;
    _activate(0);
    _setCaret(0);
    _scrollToBoundary(toEnd: false);
  }

  /// `Ctrl+End`：跳到**全文最后一个单元**的行尾（并进入编辑）。
  void _caretToDocumentEnd() {
    if (_blocks.isEmpty) return;
    _activate(_blocks.length - 1);
    final c = _controller;
    if (c != null) _setCaret(c.text.length);
    _scrollToBoundary(toEnd: true);
  }

  void _scrollToBoundary({required bool toEnd}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = toEnd ? _scroll.position.maxScrollExtent : 0.0;
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  /// 当前块在列表中的定位键（`Scrollable.ensureVisible` 用）。
  final GlobalKey _activeKey = GlobalKey();

  void _ensureActiveVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _activeKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.4,
        duration: const Duration(milliseconds: 120),
      );
    });
  }

  /// 一屏大致能放下多少行（用于 PageUp / PageDown）。
  int get _linesPerPage {
    final viewport =
        _scroll.hasClients ? _scroll.position.viewportDimension : 600.0;
    final lineHeight = MediaQuery.textScalerOf(context).scale(24).toDouble();
    return (viewport / (lineHeight == 0 ? 24 : lineHeight))
        .floor()
        .clamp(1, 200);
  }

  (int result, int column) _lineColumn(String text, int offset) {
    final pos = offset.clamp(0, text.length);
    var line = 0;
    var start = 0;
    for (var i = 0; i < pos; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        line++;
        start = i + 1;
      }
    }
    return (line, pos - start);
  }

  (int start, int end) _lineBounds(String text, int line) {
    var start = 0;
    var current = 0;
    while (current < line && start < text.length) {
      final nl = text.indexOf('\n', start);
      if (nl == -1) return (start, text.length);
      current++;
      start = nl + 1;
    }
    final nl = text.indexOf('\n', start);
    return (start, nl == -1 ? text.length : nl);
  }

  void _pageDown() => _moveByPage(down: true);

  void _pageUp() => _moveByPage(down: false);

  void _moveByPage({required bool down}) {
    final c = _controller;
    if (c == null || !c.selection.isValid) return;
    final text = c.text;
    final (line, column) = _lineColumn(text, c.selection.extentOffset);
    final total = '\n'.allMatches(text).length + 1;
    final target = line + (down ? _linesPerPage : -_linesPerPage);
    if (target >= 0 && target < total) {
      final (start, end) = _lineBounds(text, target);
      _setCaret((start + column).clamp(start, end));
      _ensureActiveVisible();
      return;
    }
    final overflow = target < 0 ? 0 : target - total + 1;
    _activateNeighbor(down: down, overflow: overflow, column: column);
  }

  /// 翻页 / 跨块跳转：把焦点交给上 / 下一个单元，并按溢出量放置光标。
  void _activateNeighbor({
    required bool down,
    required int overflow,
    required int column,
  }) {
    final index = _active;
    if (index == null) return;
    final next = index + (down ? 1 : -1);
    if (next < 0 || next >= _blocks.length) {
      final c = _controller;
      if (c != null) _setCaret(down ? c.text.length : 0);
      return;
    }
    _activate(next);
    final c = _controller;
    if (c == null) return;
    final total = '\n'.allMatches(c.text).length + 1;
    final line = down
        ? overflow.clamp(0, total - 1)
        : (total - 1 - overflow).clamp(0, total - 1);
    final (start, end) = _lineBounds(c.text, line);
    _setCaret((start + column).clamp(start, end));
    _ensureActiveVisible();
  }

  /// `Ctrl+↑`：光标已在块首时跳到**上一单元**末尾；否则回到本块行首。
  void _toPrevBlock() {
    final c = _controller;
    if (c == null || !c.selection.isValid) return;
    if (c.selection.extentOffset > 0) {
      _setCaret(0);
      return;
    }
    final index = _active;
    if (index == null || index == 0) {
      _setCaret(0);
      return;
    }
    _activate(index - 1);
    final prev = _controller;
    if (prev != null) _setCaret(prev.text.length);
    _ensureActiveVisible();
  }

  /// `Ctrl+↓`：光标已在块尾时跳到**下一单元**开头；否则到本块行尾。
  void _toNextBlock() {
    final c = _controller;
    if (c == null || !c.selection.isValid) return;
    if (c.selection.extentOffset < c.text.length) {
      _setCaret(c.text.length);
      return;
    }
    final index = _active;
    if (index == null || index >= _blocks.length - 1) {
      _setCaret(c.text.length);
      return;
    }
    _activate(index + 1);
    _setCaret(0);
    _ensureActiveVisible();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = SuiAppearance.of(context);
    return Container(
      color: appearance.palette.surface,
      child: GestureDetector(
        // 点空白区结束当前块编辑（块自身的点按会赢得手势竞技场）。
        behavior: HitTestBehavior.opaque,
        onTap: _deactivate,
        child: ListView.builder(
          controller: _scroll,
          // 逻辑单元虚拟化：只构建视口附近的单元，滚出的单元不保活。
          padding: const EdgeInsets.only(top: 8, bottom: 160),
          addAutomaticKeepAlives: false,
          itemCount: _blocks.length,
          itemBuilder: (context, i) {
            if (i == _active) {
              return KeyedSubtree(
                key: _activeKey,
                child: _buildEditor(context),
              );
            }
            return _buildReadOnly(context, i);
          },
        ),
      ),
    );
  }
}
