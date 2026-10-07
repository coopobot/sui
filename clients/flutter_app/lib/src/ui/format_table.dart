import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:note_core/note_core.dart';

/// 单元格内「附件引用」**原子呈现单元**的构建器（§12.1.2 / FR-46 / BR-46.6）。
///
/// [text] 为单元格**显示文本**（`<br>` 已还原为换行），[ref] 为其内的附件引用区间
/// （偏移相对 [text]，与单元格光标同一套偏移）；[selected] 由单元格自身光标判定
/// （单击选中态）；[onSelect] 由单元格提供——把光标落到引用末尾、激活本格并夺取焦点。
/// 由 UI 层注入并与**正文同源**（同一批呈现单元 widget）；未注入时引用退化为普通文本，
/// 不影响正本与偏移。
typedef TableCellUnitBuilder = Widget Function(
  BuildContext context,
  String text,
  AttachmentRef ref, {
  required bool selected,
  required VoidCallback onSelect,
});

/// 单元格内**图片呈现单元**的缩略图边长（像素，正方形）。
///
/// **单一来源**：呈现单元（`note_editor.dart` 的 `_buildCellUnit`）用它定盒子尺寸，
/// 单元格（本文件）用它定**强制行高**与**最小高度**——改一处即三处同步。
///
/// 尺寸必须**固定**（不能随图片自然尺寸 / 解码进度变化）：`WidgetSpan` 子项的高度
/// **不参与行盒与段落测量**（框架明确「高度不受约束，会造成文字溢出 / 截断」），
/// 且图片字节解码是异步的、解码完成后行高不会重算（§12.1.4 ⑫⑮）。
const double kTableCellImageBoxSize = 80;

/// 单元格内含**图片**呈现单元时的最小高度（像素）。
///
/// = 缩略图边长（[kTableCellImageBoxSize] = 80）+ 呈现单元外边距 / 内边距 /
/// 边框（约 12）+ 单元格内边距（8）+ 余量（4）。
///
/// **为何要有这个兜底**：`WidgetSpan` 子项的**高度不参与段落测量**，而图片字节的解码是
/// **异步**的、实测解码完成后**行高不会重算**——故行高必须由**单元格自身**给足，
/// 图片才能完整落在格内（§12.1.4 ⑫）。
const double _tableCellMinHeightWithImage = kTableCellImageBoxSize + 24;

/// 单元格内含**图片**呈现单元时的**强制行高**（`StrutStyle`，§12.1.4 ⑮）。
///
/// 行盒**不会**因内联子项而增高，若不强制，[kTableCellImageBoxSize] 高的缩略图以「行内
/// 中间对齐」会压在其**相邻文本行**上：实测 `文字![图]` 单元格里偏移 `0/1` 与图片后方的
/// 光标矩形**全部落在图片矩形内**，文字既被遮盖、点也点不到。故含图片的单元格**强制每行
/// 都有缩略图那么高**，图片正好落在自己那一行内，相邻文本行的文字与光标都不被覆盖；
/// 行高来自**文本 strut**（而非内联子项），段落高度天然可测，不依赖任何异步时机。
const double _tableCellFontSize = 14;
const StrutStyle _imageUnitStrut = StrutStyle(
  fontSize: _tableCellFontSize,
  height: kTableCellImageBoxSize / _tableCellFontSize,
  forceStrutHeight: true,
);

/// 含图片单元格的**光标高度**（像素，§12.1.4 ⑯）。
///
/// 上面的强制行高会**顺带撑大光标**：`RenderEditable.cursorHeight` 默认取
/// `preferredLineHeight`（有 strut 时即行高 80），于是「换行后在下一行输入」会出现
/// **跟图片一样高的巨光标**。故显式给一个**字号级**高度（≈ 14px 字号的自然行高 16.4，
/// 取 18 略宽松）：框架会把光标在行内**垂直居中**，与行内居中的文字自然对齐。
const double _tableCellCaretHeight = 18;

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
    this.cellUnitBuilder,
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

  /// 单元格内**附件引用**的原子呈现单元构建器（§12.1.2 / FR-46 / BR-46.6）。
  ///
  /// 由 UI 层注入并与**正文同源**（同一批呈现单元 widget）；未注入时引用退化为普通文本，
  /// 不影响正本与偏移。
  final TableCellUnitBuilder? cellUnitBuilder;

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
      // 末行末列：`Enter`（createRow == true）**每次追加一行**并把光标移到新行首列
      // ——可在表格末尾**连续新增**；`Tab`（createRow == false）只把光标退回本行首列、
      // **绝不新增行**。
      //
      // 旧实现在此另加「当前行非空才追加」的**幽灵行守卫**：其动机是防「无法删除的尾部
      // 空行」，而当时单元格内删除键本身就失效（§12.1.2 ⑩ 已修）——如今行删除按钮与
      // 单元格内删除键均可用、空行可删，故守卫**已无必要**，反而使「新建的空行无法再
      // 回车续行」（§12.1.1 ⑬）。此处直接每次回车都追加。
      if (createRow) {
        widget.onInsertRow(_activeRow, true);
        _activate(_activeRow + 1, 0, caret: 0);
      } else {
        _activate(_activeRow, 0, caret: 0);
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
              // `intrinsicHeight`：测量阶段以子项**自然高度**参与行高计算，定位阶段再以
              // **行高紧约束**重新布局子项 —— 单元格盒子因此**铺满整行**，行内不留任何
              // 「无组件覆盖」的垂直死区（否则同行多行单元格旁的留白点不到、无法激活该行，
              // 见 §12.1.1 ⑧）。**不可改用 `fill`**：`RenderTable` 在测量阶段跳过 `fill`，
              // 整行皆为 `fill` 时行高退化为 0。内容由单元格内部 `Center` 垂直居中，
              // 与原先 `middle` 的观感一致。
              defaultVerticalAlignment:
                  TableCellVerticalAlignment.intrinsicHeight,
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
            unitBuilder: widget.cellUnitBuilder,
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
    this.unitBuilder,
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

  /// 单元格内附件引用的原子呈现单元构建器（§12.1.2 / BR-46.6）；`null` 时引用按普通文本显示。
  final TableCellUnitBuilder? unitBuilder;

  @override
  State<_FormatTableCell> createState() => _FormatTableCellState();
}

class _FormatTableCellState extends State<_FormatTableCell> {
  late final TableCellEditingController _controller;
  final FocusNode _focus = FocusNode();
  String? _lastCommitted; // 上次提交的 Markdown 正本值（含 `<br>`），避免重复提交

  /// 单元格内容中的 `<br>` → 编辑器显示为 `\n`（视觉换行）。
  static String _brToNewline(String s) => s.replaceAll('<br>', '\n');

  /// 编辑器中的 `\n` → 提交回 Markdown 正本时转为 `<br>`（GFM 管道表兼容）。
  static String _newlineToBr(String s) => s.replaceAll('\n', '<br>');

  @override
  void initState() {
    super.initState();
    _controller = TableCellEditingController(text: _brToNewline(widget.initial))
      ..unitBuilder = widget.unitBuilder
      // 单击选中附件呈现单元：激活本格并夺取焦点，随后退格即可整块删除（§12.1.2）。
      ..onUnitSelected = () {
        widget.onActivate();
        _focus.requestFocus();
      };
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
    // 注入的构建器随上层重建而变化（闭包每次 build 都是新实例），须同步给控制器。
    _controller.unitBuilder = widget.unitBuilder;
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

  /// 单元格内 `Backspace` / `Delete`：**在本格内就地完成**（§12.1.2 / BR-44.8）。
  ///
  /// 三级处理，与正文口径一致：① **残缺引用**命中 → 就地补齐自愈；② **附件引用**命中
  /// （光标在引用内部 / 退格落在引用**末尾** / `Delete` 落在引用**起点**）→ **整块删除**
  /// （一次可撤销，BR-46.1 / BR-46.2 / BR-46.5）；③ 否则按**选区 / 单字符**删除
  /// （跳过代理对，不劈开 emoji）。
  ///
  /// **为何不「返回 `ignored` 交给单元格自身的文本编辑动作」**：实测该按键会一路漏到
  /// **外层编辑器**的 `EditableText`——外层 `DeleteCharacterIntent` 作用在表格 `WidgetSpan`
  /// 的占位字符上，实测把**整段表格正本清空**（`note=[]`）。故必须在本格就地消费、绝不漏泡
  /// （这正是旧实现「无条件吞掉」的原始动机，只是吞掉后忘了自己删）。
  void _handleCellDelete({required bool backspace}) {
    final sel = _controller.selection;
    if (!sel.isValid) return;
    // 显示文本（`<br>` 已还原为换行）——引用区间扫描与光标共用同一套偏移。
    final text = _controller.text;

    if (!sel.isCollapsed) {
      final s = sel.start.clamp(0, text.length);
      final e = sel.end.clamp(0, text.length);
      _writeCellValue(text.substring(0, s) + text.substring(e), s);
      return;
    }

    final pos = sel.extentOffset.clamp(0, text.length);
    final at = EditorFormat.attachmentRefAt(text, pos);
    if (at != null && at.corrupt) {
      final fixed = EditorFormat.repairAttachmentRef(text, at);
      _writeCellValue(fixed.text, fixed.selectionStart);
      return;
    }
    final ref = EditorFormat.attachmentRefForDeletion(
      text,
      pos,
      backspace: backspace,
    );
    if (ref != null) {
      final result = EditorFormat.deleteAttachmentRef(text, ref);
      _writeCellValue(result.text, result.selectionStart);
      return;
    }

    if (backspace) {
      if (pos == 0) return; // 已在格首：无操作（事件仍由调用方吞掉，绝不漏泡）
      final cut = _surrogateSafeBackward(text, pos);
      _writeCellValue(text.substring(0, cut) + text.substring(pos), cut);
    } else {
      if (pos >= text.length) return; // 已在格尾：无操作
      final cut = _surrogateSafeForward(text, pos);
      _writeCellValue(text.substring(0, pos) + text.substring(cut), pos);
    }
  }

  /// 退格删除点：落点是**低位代理**时再回退一格，避免劈开代理对（emoji / 罕用字）。
  static int _surrogateSafeBackward(String text, int off) {
    final cut = off - 1;
    if (cut > 0 &&
        _isLowSurrogate(text.codeUnitAt(cut)) &&
        _isHighSurrogate(text.codeUnitAt(cut - 1))) {
      return cut - 1;
    }
    return cut;
  }

  /// 向前删除的终点：落点是**高位代理**时再吞掉其低位代理。
  static int _surrogateSafeForward(String text, int off) {
    final cut = off + 1;
    if (cut < text.length &&
        _isHighSurrogate(text.codeUnitAt(off)) &&
        _isLowSurrogate(text.codeUnitAt(cut))) {
      return cut + 1;
    }
    return cut;
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  /// 光标 / 选择类按键（须由单元格**就地接管**，见 [_handleCaretJump]）。
  static bool _isCaretJumpKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.home ||
      key == LogicalKeyboardKey.end ||
      key == LogicalKeyboardKey.pageUp ||
      key == LogicalKeyboardKey.pageDown;

  /// `Home` / `End` / `PageUp` / `PageDown` 在**单元格内**移动 / 扩选光标
  /// （§12.1.1 ⑭ / BR-44.10）。
  ///
  /// - `Ctrl+Home` / `Ctrl+End` → **格内首 / 末**；`Home` / `End` → **格内当前显示行**
  ///   （格内软换行以 `\n` 表示）的行首 / 行尾；
  /// - `PageUp` / `PageDown` → 格内无「页」概念，落到**格内首 / 末**；
  /// - [shift] 为 true 时**扩选**（保持 `baseOffset`、移动 `extentOffset`），否则折叠光标。
  ///
  /// **为何必须就地完成**：这些键一旦漏泡到外层编辑器，外层处理时会把它自己的文本
  /// （**整段笔记 Markdown**）回灌进本格控制器，随后 `_commit` 把它当格内内容经
  /// `setTableCell` 转义写回正本——正本被塞进一坨 `| \| A \| B \|<br>…` 文本（⑭ 的成因，
  /// 机制与方向键历史成因 H1 相同）。
  void _handleCaretJump(LogicalKeyboardKey key, {required bool shift}) {
    final text = _controller.text;
    final sel = _controller.selection;
    final off = sel.isValid ? sel.extentOffset.clamp(0, text.length) : 0;
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final int target;
    switch (key) {
      case LogicalKeyboardKey.home:
        target = ctrl ? 0 : _lineStartAt(text, off);
      case LogicalKeyboardKey.end:
        target = ctrl ? text.length : _lineEndAt(text, off);
      case LogicalKeyboardKey.pageUp:
        target = 0;
      case LogicalKeyboardKey.pageDown:
        target = text.length;
      default:
        return;
    }
    final base = shift && sel.isValid ? sel.baseOffset : target;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: base, extentOffset: target),
    );
  }

  /// 光标 [off] 所在**显示行**的行首偏移（格内软换行以 `\n` 表示）。
  static int _lineStartAt(String text, int off) {
    if (off <= 0) return 0;
    final nl = text.lastIndexOf('\n', off - 1);
    return nl == -1 ? 0 : nl + 1;
  }

  /// 光标 [off] 所在**显示行**的行尾偏移（不含换行符）。
  static int _lineEndAt(String text, int off) {
    final nl = text.indexOf('\n', off);
    return nl == -1 ? text.length : nl;
  }

  /// 把单元格编辑器内容改成 [text] 并把光标落到 [caret]，随后提交回正本。
  void _writeCellValue(String text, int caret) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: caret.clamp(0, text.length),
      ),
    );
    _commit();
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

    // 光标 / 选择类按键：`Home` / `End` / `PageUp` / `PageDown`（含 `Ctrl` / `Shift` 组合）
    // —— **必须在单元格内自行处理并吞掉**（§12.1.1 ⑭ / BR-44.10）。漏泡的后果见
    // [_handleCaretJump]：外层会把整段笔记 Markdown 回灌进本格，再被 `_commit` 写进正本。
    if (_isCaretJumpKey(key)) {
      _handleCaretJump(key, shift: HardwareKeyboard.instance.isShiftPressed);
      return KeyEventResult.handled;
    }

    // `Ctrl+A`：全选**格内**文本（而非整篇笔记）。同样必须就地吞掉（同 ⑭）。
    if (key == LogicalKeyboardKey.keyA &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      final text = _controller.text;
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: 0, extentOffset: text.length),
      );
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

    // 退格 / Delete：**必须在本格内生效**（§12.1.2 / BR-44.8）——旧实现为防「漏泡到外层
    // 编辑器」而无条件吞掉这两个键，实测结果是单元格内**无法删除任何字符**。现在改为**就地
    // 删除**（残缺引用自愈 / 附件整块删除 / 否则按选区或单字符删除），事件**一律吞掉**。
    // 绝不返回 `ignored`：实测该按键会漏到外层编辑器，把整段表格正本清空（见 _handleCellDelete）。
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      if (isDown || isRepeat) {
        _handleCellDelete(backspace: key == LogicalKeyboardKey.backspace);
      }
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
    // 单元格内含**图片**呈现单元时，行高不能指望「呈现单元高度参与段落测量」
    // ——`WidgetSpan` 子项**高度不受框架支持**（其源码注释即言明「高度不受约束，会造成
    // 文字溢出 / 截断」），且图片字节的读取与解码是**异步**的（首帧只有占位高度），
    // 实测解码完成后**行高不会重算**，图片便居中绘到行外、压住相邻行（§12.1.4 ⑫）。
    // 故改由**单元格自身的最小高度**兜底：呈现单元为固定尺寸盒子（列宽 × 固定高度），
    // 只要格高 ≥ 盒高 + 单元与单元格的边距，图片即完整落在格内（图片在格内居中摆放）。
    final hasImageUnit =
        _controller.unitBuilder != null && _controller.hasImageUnit;
    // 整格点选激活（§12.1.1 ⑧）：命中区必须覆盖**整个单元格盒子**——含内边距，以及
    // 「行高大于本格内容高度」时的上下留白（同行有 `<br>` 多行单元格时尤为明显）。
    // 旧实现把 `onTap` 只挂在**内层 `TextField`** 上，上述位置点击后**不激活**该行，
    // `_activeRow` 保持旧值（或仍为表头 `-1`），以活动单元格为基准的「删除行」便
    // **禁用**或**删错行**。`HitTestBehavior.opaque` 让容器空白处同样命中；
    // 内层 `TextField` 区域的手势仍由 `TextField` **自身优先接管**（手势竞技场取
    // 最内层），故点击文本处的**光标落点 / 选区行为不变**。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        widget.onActivate();
        _focus.requestFocus();
      },
      child: Container(
        constraints: hasImageUnit
            ? const BoxConstraints(minHeight: _tableCellMinHeightWithImage)
            : null,
        decoration: widget.active
            ? BoxDecoration(
                border: Border.all(color: scheme.primary, width: 1.5))
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        // 单元格盒子现由 `Table` 的 `intrinsicHeight` 对齐**铺满整行**，故内容需显式
        // 垂直居中，保持与原先 `middle` 对齐一致的观感（内容取自然高度）。
        child: Center(
          child: Focus(
            onKeyEvent: _onKey,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              maxLines: null,
              textAlign: _textAlign,
              // 含图片单元时**强制行高 = 缩略图边长**（§12.1.4 ⑮）：行盒不因内联子项增高，
              // 否则 80 高的缩略图会以「行内中间对齐」压在相邻文本行上，文字被遮盖且点不到。
              strutStyle: hasImageUnit ? _imageUnitStrut : null,
              // 光标 / 选中高亮仍按**字号**（§12.1.4 ⑯）：强制行高会把 `cursorHeight` 的默认值
              // （`preferredLineHeight` = 80）一并抬高，换行后在下一行输入就会出现「跟图片一样高的
              // 巨光标」。显式给字号级高度 + `BoxHeightStyle.tight`，二者不随行高拉伸。
              cursorHeight: hasImageUnit ? _tableCellCaretHeight : null,
              selectionHeightStyle:
                  hasImageUnit ? BoxHeightStyle.tight : null,
              style: TextStyle(
                fontSize: _tableCellFontSize,
                fontWeight:
                    widget.isHeader ? FontWeight.w600 : FontWeight.normal,
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

/// 单元格专用编辑控制器：把单元格文本中的**附件引用**渲染为**原子呈现单元**
/// （§12.1.2 / FR-46 / BR-46.6）。
///
/// 与正文 `MarkdownEditingController`（`markdown_editing_controller.dart`）**同一范式**：
/// 引用区间替换为 [WidgetSpan]（区间**首码元**由 widget 占位、**其余码元**以零宽禁断行的
/// `U+2060` 补齐），使整棵 span 树的 `toPlainText()` 与控制器文本**等长**——光标定位、
/// 命中测试与选区偏移全部照旧（守 §4.1 / BR-27.1 偏移契约），**正本一字不改**。
///
/// 与正文的差异：单元格只做**附件引用**一种呈现单元（表格 / 勾选框 / 有序编号等由外层
/// 控制器负责），且不做 Markdown 逐字符样式——单元格文本仍是可编辑的原始 Markdown。
class TableCellEditingController extends TextEditingController {
  TableCellEditingController({super.text});

  /// 附件引用 → 原子呈现单元的构建器（UI 层注入；未注入时引用按普通文本显示）。
  TableCellUnitBuilder? unitBuilder;

  /// 单击选中某个引用后的回调（单元格据此激活本格并夺取焦点）。
  VoidCallback? onUnitSelected;

  /// 显示文本中的附件引用（含图片紧随的尺寸属性块），按出现顺序。
  List<AttachmentRef> get attachmentRefs => EditorFormat.attachmentRefs(text);

  /// 显示文本中是否含**图片**引用。
  ///
  /// 单元格据此决定是否施加**行高兜底**（见 `_tableCellMinHeightWithImage` / §12.1.4 ⑫）：
  /// 图片呈现单元高度不参与段落测量，必须由单元格自身高度兜住。
  bool get hasImageUnit => attachmentRefs.any((r) => r.isImage);

  /// 把光标落到 [ref] **末尾**（与正文「单击选中」口径一致，便于随后整块删除）。
  void selectRef(AttachmentRef ref) {
    final pos = ref.end.clamp(0, text.length);
    if (selection.baseOffset != pos || !selection.isCollapsed) {
      selection = TextSelection.collapsed(offset: pos);
    }
    onUnitSelected?.call();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final builder = unitBuilder;
    if (builder == null) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final refs = attachmentRefs;
    if (refs.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    final composing = withComposing ? value.composing : TextRange.empty;
    final sel = value.selection;
    final out = <InlineSpan>[];
    var cursor = 0;
    for (final ref in refs) {
      if (ref.start < cursor || ref.end > text.length || ref.end <= ref.start) {
        continue; // 与上一区间重叠 / 越界：跳过（防御，不破坏偏移）
      }
      if (ref.start > cursor) {
        _addRun(out, text.substring(cursor, ref.start), cursor, base, composing);
      }
      final selected = sel.isValid &&
          sel.isCollapsed &&
          sel.start >= ref.start &&
          sel.start <= ref.end;
      out.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: builder(
          context,
          text,
          ref,
          selected: selected,
          onSelect: () => selectRef(ref),
        ),
      ));
      // 区间首码元由 WidgetSpan 占位，其余码元以**零宽、禁断行**字符等码元补齐（BR-27.1）。
      final fill = ref.end - ref.start - 1;
      if (fill > 0) {
        out.add(TextSpan(
          text: _zeroWidthFill * fill,
          style: base.copyWith(color: Colors.transparent, fontSize: 0),
        ));
      }
      cursor = ref.end;
    }
    if (cursor < text.length) {
      _addRun(out, text.substring(cursor), cursor, base, composing);
    }
    return TextSpan(style: base, children: out);
  }

  /// 零宽、禁断行的填充字符（`U+2060` WORD JOINER）：等码元补齐引用区间余下字符，
  /// 既维持偏移契约又不产生任何行盒 / 断行点（同 §12.1.1「表格后占位行」口径）。
  static const String _zeroWidthFill = '\u2060';

  /// 追加一段普通文本；**组字中**（IME）区间按 [TextEditingController] 默认行为加下划线。
  static void _addRun(
    List<InlineSpan> out,
    String run,
    int runStart,
    TextStyle base,
    TextRange composing,
  ) {
    if (run.isEmpty) return;
    if (!composing.isValid || composing.isCollapsed) {
      out.add(TextSpan(text: run, style: base));
      return;
    }
    final s = (composing.start - runStart).clamp(0, run.length);
    final e = (composing.end - runStart).clamp(0, run.length);
    if (s >= e) {
      out.add(TextSpan(text: run, style: base));
      return;
    }
    final composingStyle =
        base.merge(const TextStyle(decoration: TextDecoration.underline));
    if (s > 0) out.add(TextSpan(text: run.substring(0, s), style: base));
    out.add(TextSpan(text: run.substring(s, e), style: composingStyle));
    if (e < run.length) {
      out.add(TextSpan(text: run.substring(e), style: base));
    }
  }
}
