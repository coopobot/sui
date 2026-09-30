import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import '../platform/attachment_picker.dart';
import 'app_controller.dart';
import 'markdown_editing_controller.dart';
import 'markdown_editor.dart';

/// 笔记编辑页：标题 + 格式工具栏 + Markdown 编辑器（格式 / 源码 / 预览三态） + 标签。
/// 编辑变更实时保存到仓储并追加一条修订。
class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key});

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  final TextEditingController _title = TextEditingController();
  final MarkdownEditingController _content = MarkdownEditingController();
  final TextEditingController _tagInput = TextEditingController();

  /// 共享撤销 / 重做控制器：正文输入与工具栏指令的写入落在同一个撤销栈上。
  final UndoHistoryController _undoHistory = UndoHistoryController();

  /// 正文焦点节点：工具栏执行指令后据此把焦点交还正文，便于连贯排版。
  final FocusNode _contentFocus = FocusNode();

  List<String> _tags = [];
  List<Attachment> _attachments = [];

  /// 三态编辑模式：格式（默认）/ 源码 / 预览。正本始终是 Markdown。
  EditorMode _mode = EditorMode.formatted;
  bool _loaded = false;
  String? _loadedNoteId;

  /// 正在进行的「写回模型」次数。非零期间禁止用模型内容重绑输入框，
  /// 否则每次敲字触发的保存都会重置标题/正文，selection 被置回 -1，光标跳行首。
  int _pendingSaves = 0;

  @override
  void initState() {
    super.initState();
    // 格式模式：把 `![alt](sui://<sha256>){尺寸}` 渲染为图片呈现单元（FR-27）。
    _content.formatImageBuilder = _buildFormatImage;
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _tagInput.dispose();
    _undoHistory.dispose();
    _contentFocus.dispose();
    super.dispose();
  }

  AppController get _controller => context.read<AppController>();

  Note? get _note => _controller.notes
      .where((s) => s.note.id == _controller.selectedNoteId)
      .map((s) => s.note)
      .firstOrNull;

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
      final s = _controller.notes
          .where((s) => s.note.id == note.id)
          .firstOrNull;
      _tags = s?.tags ?? [];
      _loaded = true;
      _boundTitle = note.title;
      _boundContent = note.contentMarkdown;
    }
    if (note?.id != _loadedNoteId) {
      _loadedNoteId = note?.id;
      if (note != null) {
        _controller.refreshAttachments(note.id).then((_) {
          _attachments = _controller.attachments;
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
    final id = _controller.selectedNoteId;
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
  Widget _buildFormatToolbar() {
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            _fmtIcon(Icons.format_bold, '加粗', FormatCommand.bold),
            _fmtIcon(Icons.format_italic, '斜体', FormatCommand.italic),
            _fmtIcon(
              Icons.format_strikethrough,
              '删除线',
              FormatCommand.strikethrough,
            ),
            const _ToolbarDivider(),
            _fmtIcon(Icons.looks_one_outlined, '标题 1', FormatCommand.heading1),
            _fmtIcon(Icons.looks_two_outlined, '标题 2', FormatCommand.heading2),
            _fmtIcon(Icons.looks_3_outlined, '标题 3', FormatCommand.heading3),
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
            _fmtIcon(Icons.format_quote, '引用', FormatCommand.blockquote),
            _fmtIcon(Icons.data_object, '代码块', FormatCommand.codeBlock),
            const _ToolbarDivider(),
            _fmtIcon(Icons.link, '链接', FormatCommand.link),
            IconButton(
              tooltip: '插入图片',
              icon: const Icon(Icons.image_outlined),
              onPressed: _pickAndAttach,
            ),
            _fmtIcon(Icons.horizontal_rule, '分割线', FormatCommand.divider),
            const _ToolbarDivider(),
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
  Widget _buildFormatImage(BuildContext context, ParsedImage image) {
    final sel = _content.value.selection;
    final spanEnd = image.attributeEnd > 0 ? image.attributeEnd : image.end;
    final selected = sel.isValid &&
        sel.isCollapsed &&
        sel.start >= image.start &&
        sel.start <= spanEnd;
    return _FormatImageUnit(
      image: image,
      selected: selected,
      onSelect: () => _selectImage(image),
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

  @override
  Widget build(BuildContext context) {
    final id = context.watch<AppController>().selectedNoteId;
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
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
              SizedBox(
                width: 130,
                child: TextField(
                  controller: _tagInput,
                  onSubmitted: (_) => _addTag(),
                  decoration: const InputDecoration(
                    hintText: '添加标签',
                    isDense: true,
                    border: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              SegmentedButton<EditorMode>(
                segments: const [
                  ButtonSegment(
                    value: EditorMode.formatted,
                    label: Text('格式'),
                    icon: Icon(Icons.text_fields),
                  ),
                  ButtonSegment(
                    value: EditorMode.source,
                    label: Text('源码'),
                    icon: Icon(Icons.code),
                  ),
                  ButtonSegment(
                    value: EditorMode.preview,
                    label: Text('预览'),
                    icon: Icon(Icons.visibility_outlined),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (sel) {
                  // 三态只切换「怎么画 / 能不能改」，正本不变，故无需保存。
                  setState(() => _mode = sel.first);
                },
                showSelectedIcon: false,
              ),
              const Spacer(),
              IconButton(
                tooltip: '添加附件',
                icon: const Icon(Icons.attach_file),
                onPressed: _pickAndAttach,
              ),
              IconButton(
                tooltip: '版本历史',
                icon: const Icon(Icons.history),
                isSelected: context.watch<AppController>().showRevisionPanel,
                onPressed: () => _controller.toggleRevisionPanel(),
              ),
              IconButton(
                tooltip: '导出 Markdown',
                icon: const Icon(Icons.file_download_outlined),
                onPressed: () => _showExportDialog(),
              ),
              IconButton(
                tooltip: '删除笔记',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await _confirmDelete();
                  if (ok) _controller.deleteNote(id);
                },
              ),
            ],
          ),
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
          child: MarkdownEditor(
            controller: _content,
            mode: _mode,
            onChanged: () => _save(),
            imageBuilder: _buildImage,
            undoController: _undoHistory,
            focusNode: _contentFocus,
          ),
        ),
        if (_attachments.isNotEmpty) _buildAttachmentBar(context),
      ],
    );
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
    final id = _controller.selectedNoteId;
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

    setState(() {
      _attachments = _controller.attachments;
      _content.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: insertAt),
      );
    });
    await _save();
    _toast('已添加 $count 个附件');
  }

  Future<void> _removeAttachment(Attachment a) async {
    await _controller.removeAttachment(a);
    if (!mounted) return;
    setState(() => _attachments = _controller.attachments);
    _toast('已移除「${a.filename}」');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Widget _buildAttachmentBar(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _attachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => _AttachmentCard(
          key: ValueKey(_attachments[i].id),
          attachment: _attachments[i],
          onOpen: () => _openAttachment(_attachments[i]),
          onDelete: () => _removeAttachment(_attachments[i]),
        ),
      ),
    );
  }

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
    _toast('已下载「${a.filename}」（${bytes.length} 字节，已缓存）');
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
              Text('标题：$title',
                  style: Theme.of(context).textTheme.bodySmall),
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
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
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
                    content: Text('已复制到剪贴板'),
                    duration: Duration(seconds: 1)),
              );
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除这篇笔记？'),
            content: const Text('将移到回收站，可在左侧「回收站」中查看或还原。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
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
            Text('图片尺寸',
                style: Theme.of(context).textTheme.labelSmall),
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
  });

  final ParsedImage image;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final uri = Uri.tryParse(image.url);
    final label = image.alt.isNotEmpty ? image.alt : '附件';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onSelect,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
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
            if (uri != null && uri.scheme == 'sui') {
              return _SuiAttachmentImage(
                sha256: uri.host,
                label: label,
                width: dims.$1,
                height: dims.$2,
              );
            }
            return Image.network(
              image.url,
              width: dims.$1,
              height: dims.$2,
              errorBuilder: (_, __, ___) =>
                  _AttachmentPlaceholder(label: label),
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
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Theme.of(context).colorScheme.outline),
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

  IconData _iconFor(String mimeKind) {
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

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
        errorBuilder: (_, __, ___) => _AttachmentPlaceholder(label: widget.label),
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