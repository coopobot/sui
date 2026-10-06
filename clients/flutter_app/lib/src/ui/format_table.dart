import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:note_core/note_core.dart';

/// 格式模式下的**可视化表格**呈现单元（M9-T06 / FR-44 / ui-spec §18.1）。
///
/// 表格正本一律是 GFM 管道表（BR-44.2）；本组件只负责「格式」模式下的网格呈现与
/// 就地编辑入口，任何改动都经回调交由上层用 [EditorFormat] 纯函数**整体回写**正本，
/// 不引入中间态（守 BR-23.1）。「预览」模式仍由 flutter_markdown 标准渲染，二者语义
/// 一致（§18.1 可视化呈现）。
///
/// 上下文控件以「活动单元格」为基准：点选任一单元格即成为活动单元格，行 / 列结构
/// 操作与列对齐都作用于它（§18.1 结构编辑）。
class FormatTableView extends StatefulWidget {
  const FormatTableView({
    super.key,
    required this.table,
    required this.onSetCell,
    required this.onInsertRow,
    required this.onRemoveRow,
    required this.onInsertColumn,
    required this.onRemoveColumn,
    required this.onSetAlignment,
    this.onInsertAttachment,
    this.availableWidth,
  });

  /// 当前解析结果（来自正本；单元格文本保留 `\|` 转义原样）。
  final ParsedTable table;

  /// 单元格内容改动：`rowIndex < 0` 为表头行，`>= 0` 为数据行下标。
  final void Function(int rowIndex, int column, String value) onSetCell;

  /// 在 [rowIndex] 行的上方（after=false）/ 下方（after=true）插入空行。
  final void Function(int rowIndex, bool after) onInsertRow;

  /// 删除 [rowIndex] 数据行（表头行不可删）。
  final void Function(int rowIndex) onRemoveRow;

  /// 在 [column] 列的左侧（after=false）/ 右侧（after=true）插入空列。
  final void Function(int column, bool after) onInsertColumn;

  /// 删除 [column] 列（至少保留 1 列）。
  final void Function(int column) onRemoveColumn;

  /// 设置 [column] 列对齐。
  final void Function(int column, TableColumnAlign align) onSetAlignment;

  /// 在活动单元格内插入图片 / 附件引用（§12.1.1「单元格内附件」）。
  ///
  /// 由操作栏按钮触发：选文件 → 字节入库 → 引用文本按单元格转义规则**就地回写活动
  /// 单元格**（其余单元格逐字不动）。[rowIndex] `< 0` 为表头行，`>= 0` 为数据行下标。
  final Future<void> Function(int rowIndex, int column)? onInsertAttachment;

  /// 编辑区可用宽度（按列均分单元格宽度）；缺省 / 非有限时按每列 140 估算。
  final double? availableWidth;

  @override
  State<FormatTableView> createState() => _FormatTableViewState();
}

class _FormatTableViewState extends State<FormatTableView> {
  /// 活动单元格：`-1` 表示表头行，`>= 0` 为数据行下标。
  int _activeRow = -1;
  int _activeCol = 0;

  /// 本次程序化跳格（Enter / 方向键跨格）后，是否需要把焦点交给目标单元格。
  ///
  /// 增行会**新建**目标单元格：新单元格没有 `didUpdateWidget` 的 false→true 过渡，
  /// 无法复用「由激活触发焦点」的既有逻辑；故用本标志在 `initState` 里补一次焦点请求
  /// （见 [_FormatTableCellState.initState]）。初始为 false，避免首次渲染时表头偷走焦点。
  bool _focusOnMount = false;

  /// 本次程序化跳格后，目标单元格的光标落点：`-1` 落到文本末尾，`>= 0` 落到该偏移，
  /// `null` 表示不干预（点击激活时交给 TextField 自身的点击定位）。
  int? _pendingCaret;

  @override
  void didUpdateWidget(covariant FormatTableView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cols = widget.table.header.length;
    if (_activeCol >= cols) _activeCol = cols > 0 ? cols - 1 : 0;
    if (_activeCol < 0) _activeCol = 0;
    final dataRows = widget.table.rows.length;
    if (_activeRow >= dataRows) _activeRow = dataRows - 1;
    if (_activeRow < -1) _activeRow = -1;
  }

  /// 激活单元格 [row] / [col]；[caret] 指定目标单元格的光标落点（见 [_pendingCaret]）。
  void _activate(int row, int col, {int? caret}) {
    if (_activeRow == row && _activeCol == col) return;
    _focusOnMount = true;
    _pendingCaret = caret;
    setState(() {
      _activeRow = row;
      _activeCol = col;
    });
    // 待本帧构建完成（目标单元格已 mount）后复位标志；目标单元格在 initState 里
    // 依据此标志补一次焦点请求，实现「跳格后焦点跟随」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusOnMount = false;
        _pendingCaret = null;
      }
    });
  }

  /// 跳到下一个单元格；最后一列最后一行时按 [createRow] 决定是否新增一行。
  /// 由单元格 Enter / Tab 键触发（FR-44 / 表格交互）。
  ///
  /// 新增行后**同步**激活新行（目标下标 = 原行 + 1），不依赖下一帧读回
  /// `widget.table.rows.length`（它会落后一帧，导致后续删除行点中旧行）。
  void moveNextCell({bool createRow = true}) {
    final cols = widget.table.header.length;
    final rows = widget.table.rows.length;
    if (cols == 0) return;

    if (_activeCol < cols - 1) {
      // 非最后一列：跳到下一列（光标落到目标单元格开头）
      _activate(_activeRow, _activeCol + 1, caret: 0);
    } else if (_activeRow < rows - 1) {
      // 最后一列但不是最后一行：跳到下一行首列
      _activate(_activeRow + 1, 0, caret: 0);
    } else {
      // 最后一行最后一列：若当前行已全空，或本次不要求新增行（Tab），则不再新增，
      // 只把光标退回本行首列（避免末格连续回车 / Tab 堆叠「幽灵行」）。
      if (!createRow || _rowIsEmpty(_activeRow)) {
        _activate(_activeRow, 0, caret: 0);
      } else {
        widget.onInsertRow(_activeRow, true);
        _activate(_activeRow + 1, 0, caret: 0);
      }
    }
    // 焦点交给新激活单元格的 TextField（由单元格自身 didUpdateWidget 处理）。
  }

  /// 跳到上一个单元格（Shift+Tab）。已在首个单元格时返回 false（事件仍由调用方吞掉）。
  bool movePrevCell() {
    final cols = widget.table.header.length;
    if (cols == 0) return false;
    if (_activeCol > 0) {
      _activate(_activeRow, _activeCol - 1, caret: -1);
      return true;
    }
    if (_activeRow > -1) {
      _activate(_activeRow - 1, cols - 1, caret: -1);
      return true;
    }
    return false; // 表头第 0 列，前面没有单元格
  }

  /// 数据行 [row] 的所有单元格是否都为空（用于避免末格连续回车堆叠空行）。
  bool _rowIsEmpty(int row) {
    if (row < 0 || row >= widget.table.rows.length) return true;
    return widget.table.rows[row].every((c) => c.trim().isEmpty);
  }

  /// 向上移动一格。到达表头行再往上时返回 false（由外层决定是否退出表格）。
  bool moveCellUp({int? caret}) {
    if (_activeRow == -1) return false; // 已经在表头行，无法再上移
    _activate(_activeRow - 1, _activeCol, caret: caret);
    return true;
  }

  /// 向下移动一格。到达表格底部时返回 false。
  bool moveCellDown({int? caret}) {
    final lastRow = widget.table.rows.length - 1;
    if (_activeRow >= lastRow) return false;
    _activate(_activeRow + 1, _activeCol, caret: caret);
    return true;
  }

  /// 向左移动一格。到达表格最左侧时返回 false。
  bool moveCellLeft({int? caret}) {
    if (_activeCol > 0) {
      _activate(_activeRow, _activeCol - 1, caret: caret);
      return true;
    }
    // 已经在第 0 列：如果不是第一行，跳到上一行最后一列
    if (_activeRow > 0) {
      final lastCol = widget.table.header.length - 1;
      _activate(_activeRow - 1, lastCol, caret: caret);
      return true;
    }
    return false; // 表头第 0 列，无法再左移
  }

  /// 向右移动一格（同 Enter 跳下一格，但最后一列最后一行不新增行）。
  /// 到达表格最右侧时返回 false。
  bool moveCellRight({int? caret}) {
    final cols = widget.table.header.length;
    final lastRow = widget.table.rows.length - 1;
    if (_activeCol < cols - 1) {
      _activate(_activeRow, _activeCol + 1, caret: caret);
      return true;
    }
    // 最后一列：如果不是最后一行，跳到下一行首列
    if (_activeRow < lastRow) {
      _activate(_activeRow + 1, 0, caret: caret);
      return true;
    }
    return false; // 最后一行最后一列，无法再右移
  }

  @override
  Widget build(BuildContext context) {
    final table = widget.table;
    final cols = table.header.length;
    if (cols == 0) return const SizedBox.shrink();

    final width = widget.availableWidth;
    final double colWidth = (width != null && width.isFinite && width > 0)
        ? (width / cols).clamp(48.0, 320.0)
        : 140.0;
    final totalWidth = colWidth * cols;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildContextBar(context, table, cols),
          const SizedBox(height: 4),
          SizedBox(
            width: totalWidth,
            child: Table(
              border: TableBorder.all(
                color: Theme.of(context).dividerColor,
                width: 1,
              ),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              columnWidths: {
                for (var i = 0; i < cols; i++) i: FixedColumnWidth(colWidth),
              },
              children: [
                _buildRow(context, -1, table.header, isHeader: true),
                for (var r = 0; r < table.rows.length; r++)
                  _buildRow(context, r, table.rows[r], isHeader: false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TableRow _buildRow(
    BuildContext context,
    int rowIndex,
    List<String> cells, {
    required bool isHeader,
  }) {
    final cols = widget.table.header.length;
    final scheme = Theme.of(context).colorScheme;
    return TableRow(
      decoration: isHeader
          ? BoxDecoration(color: scheme.surfaceContainerHighest)
          : null,
      children: [
        for (var c = 0; c < cols; c++)
          _FormatTableCell(
            key: ValueKey<String>('sui-table-$rowIndex-$c'),
            initial: c < cells.length ? _unescapeCell(cells[c]) : '',
            isHeader: isHeader,
            align: c < widget.table.aligns.length
                ? widget.table.aligns[c]
                : TableColumnAlign.none,
            active: _activeRow == rowIndex && _activeCol == c,
            focusOnMount: _focusOnMount,
            caretOnActivate: _pendingCaret,
            onActivate: () => _activate(rowIndex, c),
            onCommit: (value) => widget.onSetCell(rowIndex, c, value),
          ),
      ],
    );
  }

  Widget _buildContextBar(BuildContext context, ParsedTable table, int cols) {
    final rowBtnEnabled = table.rows.isNotEmpty;
    final rowIndex = _activeRow;
    // 用 GestureDetector 吸收操作栏空白区域的点击，防止光标落到表格起始位置
    // （WidgetSpan 整体占一个字符位，点击操作栏空白会被底层 EditableText 解读
    // 为「点到了表格首字符」，光标出现在操作栏位置，视觉上不合理）。
    // 按钮本身的 onPressed 会优先响应，不受影响。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _barButton(
            Icons.vertical_align_top,
            '上方插入行',
            () => widget.onInsertRow(rowIndex, false),
          ),
          _barButton(
            Icons.vertical_align_bottom,
            '下方插入行',
            () => widget.onInsertRow(rowIndex, true),
          ),
          _barButton(
            Icons.delete_outline,
            '删除行',
            (rowBtnEnabled && rowIndex >= 0)
                ? () => widget.onRemoveRow(rowIndex)
                : null,
          ),
          const _TableBarDivider(),
          _barButton(
            Icons.first_page,
            '左侧插入列',
            () => widget.onInsertColumn(_activeCol, false),
          ),
          _barButton(
            Icons.last_page,
            '右侧插入列',
            () => widget.onInsertColumn(_activeCol, true),
          ),
          _barButton(
            Icons.playlist_remove,
            '删除列',
            cols > 1 ? () => widget.onRemoveColumn(_activeCol) : null,
          ),
          const _TableBarDivider(),
          _alignButton(TableColumnAlign.left, Icons.format_align_left, '左对齐'),
          _alignButton(TableColumnAlign.center, Icons.format_align_center, '居中'),
          _alignButton(TableColumnAlign.right, Icons.format_align_right, '右对齐'),
          const _TableBarDivider(),
          _barButton(
            Icons.attach_file,
            '在单元格内插入图片 / 附件',
            widget.onInsertAttachment == null ? null : _insertAttachment,
          ),
        ],
      ),
    );
  }

  /// 在**活动单元格**内插入图片 / 附件：先让单元格失焦（提交其在编辑内容），
  /// 再交由上层选文件并回写引用（§12.1.1「单元格内附件」）。
  void _insertAttachment() {
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onInsertAttachment?.call(_activeRow, _activeCol);
  }

  Widget _barButton(IconData icon, String tooltip, VoidCallback? onPressed) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: onPressed,
    );
  }

  Widget _alignButton(TableColumnAlign align, IconData icon, String tooltip) {
    final isActive =
        _activeCol < widget.table.aligns.length &&
            widget.table.aligns[_activeCol] == align;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      color: isActive ? Theme.of(context).colorScheme.primary : null,
      onPressed: () => widget.onSetAlignment(_activeCol, align),
    );
  }
}

/// 单个可编辑单元格：就地编辑，失焦 / 提交时把内容回写正本。
///
/// 单元格保留 [ParsedTable] 的原始（含 `\|` 转义）文本，展示时还原为字面文本，
/// 由上层 [EditorFormat.setTableCell] 再次转义写出，保证往返一致（BR-44.4）。
class _FormatTableCell extends StatefulWidget {
  const _FormatTableCell({
    super.key,
    required this.initial,
    required this.isHeader,
    required this.align,
    required this.active,
    required this.onActivate,
    required this.onCommit,
    this.focusOnMount = false,
    this.caretOnActivate,
  });

  final String initial;
  final bool isHeader;
  final TableColumnAlign align;
  final bool active;
  final VoidCallback onActivate;
  final ValueChanged<String> onCommit;

  /// 为 true 表示本单元格是本次程序化跳格**新建**的目标，应在其挂载时请求焦点
  /// （配合 [_FormatTableViewState._focusOnMount]，弥补新单元格无 `didUpdateWidget`
  /// 过渡、无法复用「激活即聚焦」逻辑的缺口）。
  final bool focusOnMount;

  /// 程序化跳格激活本单元格时的光标落点：`-1` 落到文本末尾，`>= 0` 落到该偏移，
  /// `null` 表示不干预（点击激活时保持 TextField 自身的点击定位）。
  final int? caretOnActivate;

  @override
  State<_FormatTableCell> createState() => _FormatTableCellState();
}

class _FormatTableCellState extends State<_FormatTableCell> {
  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode();
  String? _lastCommitted; // 上次提交的 Markdown 正本值（含 `<br>`），避免重复提交

  /// 单元格内容中的 `<br>` → 编辑器显示为 `\n`（视觉换行）。
  static String _brToNewline(String s) => s.replaceAll('<br>', '\n');

  /// 编辑器中的 `\n` → 提交回 Markdown 正本时转为 `<br>`（GFM 管道表兼容）。
  static String _newlineToBr(String s) => s.replaceAll('\n', '<br>');

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _brToNewline(widget.initial));
    _lastCommitted = widget.initial;
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
    // 增行等程序化跳格新建的「活动」单元格：挂载时补一次焦点请求（见 _focusOnMount）。
    if (widget.active && widget.focusOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focus.requestFocus();
        _applyCaretOnActivate();
      });
    }
  }

  @override
  void didUpdateWidget(covariant _FormatTableCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅在「外部内容确实变了且本单元格未聚焦」时同步，避免输入过程中被刷掉。
    if (widget.initial != oldWidget.initial &&
        widget.initial != _lastCommitted &&
        !_focus.hasFocus) {
      final display = _brToNewline(widget.initial);
      if (_controller.text != display) {
        _controller.text = display;
      }
      _lastCommitted = widget.initial;
    }
    // 从非激活变为激活：自动请求焦点（Enter / 方向键 / Tab 跳格等场景），
    // 并按跳格方向把光标落到目标单元格的开头或末尾。
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focus.requestFocus();
        _applyCaretOnActivate();
      });
    }
  }

  /// 依据 [widget.caretOnActivate] 放置光标：`-1` 落到末尾，`>= 0` 落到该偏移（越界收敛）。
  void _applyCaretOnActivate() {
    final target = widget.caretOnActivate;
    if (target == null) return;
    final len = _controller.text.length;
    final off = target < 0 ? len : target.clamp(0, len);
    _controller.value = _controller.value.copyWith(
      selection: TextSelection.collapsed(offset: off),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 把当前编辑器内容（含 `\n`）转为 `<br>` 后提交给上层。
  /// 仅当内容真正变化时才提交，避免无意义的外层重建。
  void _commit() {
    final value = _newlineToBr(_controller.text);
    if (value == _lastCommitted) return;
    _lastCommitted = value;
    widget.onCommit(value);
  }

  TextAlign get _textAlign => switch (widget.align) {
        TableColumnAlign.center => TextAlign.center,
        TableColumnAlign.right => TextAlign.right,
        _ => TextAlign.left,
      };

  /// 按键拦截：
  /// - 方向键 → 就地移动单元格光标并**吞掉事件**（handled），绝不冒泡到外层编辑器
  /// - Enter → 跳到下一格 / 末列新增行
  /// - Shift+Enter → 插入软换行（显示 `\n`，提交 `<br>`）
  ///
  /// 方向键必须在此吞掉：单元格与外层包裹它的 Editor 都是 TextField，且本组件是
  /// 外层 WidgetSpan 里的嵌套 TextField。方向键一旦漏泡到外层 EditableText，会把
  /// 单元格控制器文本改写为整段 Markdown，再在失焦时回灌进正本造成污染。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final isDown = event is KeyDownEvent;
    final isRepeat = event is KeyRepeatEvent;
    if (!isDown && !isRepeat) return KeyEventResult.ignored;

    final key = event.logicalKey;
    // 方向键：先尝试「跨单元格」移动（光标已在单元格文本边界时），否则在格内移动光标。
    // 无论是否发生移动都吞掉事件，绝不冒泡到外层编辑器——否则 KeyRepeatEvent 会漏泡，
    // 被外层 EditableText 解读为移动外层光标，进而把整段表格 Markdown 回灌进正本造成
    // 污染（H1 复现）。
    if (_isCaretKey(key)) {
      _handleCaretKey(key);
      return KeyEventResult.handled;
    }

    // Tab / Shift+Tab：切换单元格（末格 Tab 不新增行，避免与 Enter 叠加出幽灵行）。
    // 同样必须吞掉，防止 Tab 触发外层焦点遍历、把焦点移出表格。
    if (key == LogicalKeyboardKey.tab) {
      if (!isDown) return KeyEventResult.ignored;
      widget.onActivate();
      _commit();
      final state = context.findAncestorStateOfType<_FormatTableViewState>();
      if (state != null) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          state.movePrevCell();
        } else {
          state.moveNextCell(createRow: false);
        }
      }
      return KeyEventResult.handled;
    }

    // 退格 / Delete：当单元格自身消费不了（光标在边界 / 空单元格）时，事件会漏泡到
    // 外层编辑器，被外层 EditableText 解读为「删除表格（WidgetSpan）字符」，进而把整段
    // 表格 Markdown 回灌进正本造成污染。这里一旦收到漏泡的退格 / Delete，就地吞掉。
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      return KeyEventResult.handled;
    }

    // Enter / Shift+Enter 仅在首次按下触发，长按重复不重复触发。
    if (!isDown) return KeyEventResult.ignored;

    final isEnter = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    final isShift = HardwareKeyboard.instance.isShiftPressed;
    if (isShift) {
      // Shift+Enter：在光标处插入真换行（显示层），提交时自动转 `<br>`
      final sel = _controller.selection;
      if (!sel.isValid) return KeyEventResult.ignored;
      final text = _controller.text;
      final newText = text.replaceRange(sel.start, sel.end, '\n');
      final newOffset = sel.start + 1;
      _controller.value = _controller.value.copyWith(
        text: newText,
        selection: TextSelection.collapsed(offset: newOffset),
      );
      _commit();
      return KeyEventResult.handled;
    } else {
      // Enter：跳到下一格 / 新增行。
      // 同步执行（不再 addPostFrameCallback）：moveNextCell 内部已用
      // `_activeRow + 1` 显式定位新行，不依赖下一帧读回 widget.table.rows，
      // 同步调用可避免快速连按 Enter 时焦点未迁移导致漏插行（H3 复现）。
      widget.onActivate();
      _commit();
      _moveNextCell();
      return KeyEventResult.handled;
    }
  }

  static bool _isCaretKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown;

  /// 方向键处理：光标已到本单元格文本边界时**跨格**移动（左 / 右 / 上 / 下均可），
  /// 否则回落到格内移动光标。跨格失败（已在表格边界）时不做任何移动。
  void _handleCaretKey(LogicalKeyboardKey key) {
    final sel = _controller.selection;
    if (sel.isValid && sel.isCollapsed) {
      final text = _controller.text;
      final off = sel.extentOffset;
      final state = context.findAncestorStateOfType<_FormatTableViewState>();
      if (state != null) {
        if (key == LogicalKeyboardKey.arrowLeft) {
          // 行首再左移：跳到上一格（光标落到其文本末尾）
          if (off <= 0 && state.moveCellLeft(caret: -1)) return;
        } else if (key == LogicalKeyboardKey.arrowRight) {
          // 行尾再右移：跳到下一格（光标落到其文本开头）
          if (off >= text.length && state.moveCellRight(caret: 0)) return;
        } else if (key == LogicalKeyboardKey.arrowUp) {
          // 首行再上移：跳到上一格（尽量保留列位）
          if (_lineIndexAt(text, off) == 0 && state.moveCellUp(caret: off)) return;
        } else if (key == LogicalKeyboardKey.arrowDown) {
          // 末行再下移：跳到下一格（尽量保留列位）
          final lastLine = '\n'.allMatches(text).length;
          if (_lineIndexAt(text, off) == lastLine &&
              state.moveCellDown(caret: off)) {
            return;
          }
        }
      }
    }
    _moveCaret(key);
  }

  /// 光标 [off] 所在的（以 `\n` 分隔的）行下标。
  static int _lineIndexAt(String text, int off) =>
      '\n'.allMatches(text.substring(0, off.clamp(0, text.length))).length;

  /// 在单元格字符模型内移动光标：左右逐字符、上下逐行（保留列位）。
  /// 单元格文本以 `\n` 表示软换行（提交时才转 `<br>`），故按行拆分即可。
  void _moveCaret(LogicalKeyboardKey key) {
    final sel = _controller.selection;
    if (!sel.isValid) return;
    final text = _controller.text;
    final n = text.length;
    var off = sel.isCollapsed
        ? sel.extentOffset
        : (key == LogicalKeyboardKey.arrowLeft ||
                key == LogicalKeyboardKey.arrowUp
            ? sel.start
            : sel.end);

    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        off = (off - 1).clamp(0, n);
      case LogicalKeyboardKey.arrowRight:
        off = (off + 1).clamp(0, n);
      case LogicalKeyboardKey.arrowUp:
        off = _verticalOffset(text, off, -1);
      case LogicalKeyboardKey.arrowDown:
        off = _verticalOffset(text, off, 1);
      default:
        return;
    }
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: off),
    );
  }

  /// 返回光标从 [off] 按 [dir]（-1 上 / 1 下）移动一行后的偏移，列位尽量保留。
  static int _verticalOffset(String text, int off, int dir) {
    final lines = text.split('\n');
    var col = off;
    var line = 0;
    while (line < lines.length && col > lines[line].length) {
      col -= lines[line].length + 1;
      line++;
    }
    final target = line + dir;
    if (target < 0 || target >= lines.length) return off;
    var targetStart = 0;
    for (var i = 0; i < target; i++) {
      targetStart += lines[i].length + 1;
    }
    return targetStart + col.clamp(0, lines[target].length);
  }

  void _moveNextCell() {
    final state = context.findAncestorStateOfType<_FormatTableViewState>();
    if (state == null) return;
    state.moveNextCell();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: widget.active
          ? BoxDecoration(border: Border.all(color: scheme.primary, width: 1.5))
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Focus(
        onKeyEvent: _onKey,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          maxLines: null,
          textAlign: _textAlign,
          style: TextStyle(
            fontSize: 14,
            fontWeight: widget.isHeader ? FontWeight.w600 : FontWeight.normal,
          ),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          onTap: widget.onActivate,
          onChanged: (_) => _commit(),
          onSubmitted: (_) => _moveNextCell(),
          textInputAction: TextInputAction.next,
        ),
      ),
    );
  }
}

/// 上下文控件里的分隔竖线。
class _TableBarDivider extends StatelessWidget {
  const _TableBarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: Theme.of(context).dividerColor,
    );
  }
}

/// 还原单元格字面文本：把 `\|` 还原为 `|`（展示用；写出时再转义，BR-44.4）。
String _unescapeCell(String raw) => raw.replaceAll(r'\|', '|');
