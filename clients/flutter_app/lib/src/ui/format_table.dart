import 'package:flutter/material.dart';
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

  /// 编辑区可用宽度（按列均分单元格宽度）；缺省 / 非有限时按每列 140 估算。
  final double? availableWidth;

  @override
  State<FormatTableView> createState() => _FormatTableViewState();
}

class _FormatTableViewState extends State<FormatTableView> {
  /// 活动单元格：`-1` 表示表头行，`>= 0` 为数据行下标。
  int _activeRow = -1;
  int _activeCol = 0;

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

  void _activate(int row, int col) {
    if (_activeRow == row && _activeCol == col) return;
    setState(() {
      _activeRow = row;
      _activeCol = col;
    });
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
            onActivate: () => _activate(rowIndex, c),
            onCommit: (value) => widget.onSetCell(rowIndex, c, value),
          ),
      ],
    );
  }

  Widget _buildContextBar(BuildContext context, ParsedTable table, int cols) {
    final rowBtnEnabled = table.rows.isNotEmpty;
    final rowIndex = _activeRow;
    return Wrap(
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
          Icons.keyboard_tab,
          '左侧插入列',
          () => widget.onInsertColumn(_activeCol, false),
        ),
        _barButton(
          Icons.keyboard_tab_rounded,
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
      ],
    );
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
  });

  final String initial;
  final bool isHeader;
  final TableColumnAlign align;
  final bool active;
  final VoidCallback onActivate;
  final ValueChanged<String> onCommit;

  @override
  State<_FormatTableCell> createState() => _FormatTableCellState();
}

class _FormatTableCellState extends State<_FormatTableCell> {
  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.onCommit(_controller.text);
    });
  }

  @override
  void didUpdateWidget(covariant _FormatTableCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅在「外部内容确实变了且本单元格未聚焦」时同步，避免输入过程中被刷掉。
    if (widget.initial != oldWidget.initial &&
        _controller.text != widget.initial &&
        !_focus.hasFocus) {
      _controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  TextAlign get _textAlign => switch (widget.align) {
        TableColumnAlign.center => TextAlign.center,
        TableColumnAlign.right => TextAlign.right,
        _ => TextAlign.left,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: widget.active
          ? BoxDecoration(border: Border.all(color: scheme.primary, width: 1.5))
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
        onChanged: widget.onCommit,
        onSubmitted: widget.onCommit,
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
