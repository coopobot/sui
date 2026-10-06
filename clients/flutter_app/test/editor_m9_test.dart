/// M9-T12 编辑器编辑能力与附件体验 widget 测试
/// （editor-formatting.md §12 / FR-44~FR-48 / AC-138~AC-155）。
///
/// - `TableToolWidget`：表格工具面板（默认 3×3 / 自定义尺寸 / 取消不插入）、格式模式
///   表格呈现为 `FormatTableView`、上下文栏按钮可用性随激活行 / 列变化（FR-44）。
/// - `AttachmentBlockDeleteWidget`：附件引用作为**原子编辑单元**的整块删除（退格落
///   引用末端 / Delete 落引用起点 / 非边界不动）与残缺引用就地自愈（FR-46）。
/// - `AttachmentPanelWidget`：附件面板空态引导与元数据列表（FR-46 / FR-47）。
/// - `OrderedListRenderWidget`：正本统一写 `1.`、渲染层按序编号，且 span 树与正本
///   逐字符等长（FR-48）。
///
/// 纪律：全组**禁用** `pumpAndSettle()`——连接成功后挂的 30s 周期兜底同步会让假时钟推
/// 出不定长转圈动画，`pumpAndSettle()` 永不返回（Agents.md §5.2）；一律改用有界
/// `pump` + `runAsync`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/format_table.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// 起一个挂了真实 `NoteShell` 的编辑器，并把 [content] 写入当前笔记。
///
/// [seed] 在 `pumpWidget` 前执行，便于在 NoteEditor 首次加载前预置附件等数据。
Future<AppController> _pumpEditor(
  WidgetTester tester,
  AppDatabase db,
  String deviceId,
  String content, {
  Future<void> Function(AppController controller, NoteRepository repo)? seed,
}) async {
  final repo = NoteRepository(db, deviceId: deviceId);
  final controller = AppController(repository: repo, database: db);
  await controller.bootstrap();
  await controller.createNote();
  await controller.saveNote(
    controller.selectedNoteId!,
    title: 'T',
    content: content,
    tags: const <String>[],
  );
  if (seed != null) await seed(controller, repo);

  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: const MaterialApp(home: NoteShell()),
    ),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  return controller;
}

/// 正文输入框。
///
/// 用 `MarkdownEditor` 作锚点并取 `.first`：格式模式下表格 / 附件呈现单元会嵌在正文
/// `TextField` **内部**，`find.descendant(...).last` 可能落到表格单元格的输入框上，
/// 只有 `.first` 恒为正文输入框。
Finder _contentField() => find
    .descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    )
    .first;

TextEditingController _contentValue(WidgetTester tester) =>
    tester.widget<TextField>(_contentField()).controller!;

/// 有界推进若干帧，等待对话框路由动画完成（替代 `pumpAndSettle()`）。
Future<void> _settleRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  group('TableToolWidget（FR-44 / AC-138~AC-140）', () {
    late AppDatabase db;

    Future<void> openPanel(WidgetTester tester) async {
      final btn = find.byTooltip('表格');
      await tester.ensureVisible(btn);
      await tester.pump();
      await tester.tap(btn);
      await _settleRoute(tester);
    }

    testWidgets('默认插入 3×3 空表：写回 GFM 管道表正本', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-table1', '');

      await openPanel(tester);
      expect(find.text('插入表格'), findsOneWidget, reason: '点表格工具应弹出插入面板');

      await tester.tap(find.byKey(const ValueKey('sui-table-insert-confirm')));
      await _settleRoute(tester);

      final lines = _contentValue(tester).text.split('\n');
      expect(lines[0], '|  |  |  |', reason: '表头 3 列应为 3 个空单元格');
      expect(lines[1], '| --- | --- | --- |', reason: '分隔行应为 3 个 --- 标记');
      expect(lines[2], '|  |  |  |', reason: '正文行 1');
      expect(lines[3], '|  |  |  |', reason: '正文行 2（共 3 行 → 2 个正文行）');

      await db.close();
    });

    testWidgets('自定义「2 行 2 列」写回 GFM 正本', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-table2', '');

      await openPanel(tester);
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(2), reason: '面板应提供「行数」「列数」两个输入框');
      await tester.enterText(fields.at(0), '2');
      await tester.enterText(fields.at(1), '2');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('sui-table-insert-confirm')));
      await _settleRoute(tester);

      final lines = _contentValue(tester).text.split('\n');
      expect(lines[0], '|  |  |', reason: '2 列 → 2 个空单元格');
      expect(lines[1], '| --- | --- |');
      expect(lines[2], '|  |  |', reason: '2 行 → 1 个正文行');
      expect(lines[3], '', reason: '表后应以换行收尾');

      await db.close();
    });

    testWidgets('点「取消」不插入任何内容', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-table3', '');

      await openPanel(tester);
      await tester.tap(find.text('取消'));
      await _settleRoute(tester);

      expect(_contentValue(tester).text, '', reason: '取消不应改动正本');

      await db.close();
    });

    testWidgets('表格渲染为 FormatTableView，上下文栏按钮随激活行 / 列变化', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(
        tester,
        db,
        'm9t12-table4',
        '| A | B |\n| --- | --- |\n| 1 | 2 |',
      );

      expect(find.byType(FormatTableView), findsOneWidget, reason: '良构表应渲染为表格呈现单元');
      expect(
        find.byKey(const ValueKey<String>('sui-table--1-0')),
        findsOneWidget,
        reason: '表头单元格行号为 -1',
      );
      expect(
        find.byKey(const ValueKey<String>('sui-table-0-1')),
        findsOneWidget,
        reason: '首个正文行第 2 列单元格',
      );

      IconButton bar(IconData icon) => tester.widget<IconButton>(
            find.descendant(
              of: find.byType(FormatTableView),
              matching: find.widgetWithIcon(IconButton, icon),
            ),
          );

      // 初始激活为表头（rowIndex == -1）→ 删除行禁用；2 列 → 删除列可用。
      expect(bar(Icons.delete_outline).onPressed, isNull, reason: '表头不可删除');
      expect(bar(Icons.playlist_remove).onPressed, isNotNull, reason: '2 列时可删除列');

      // 激活正文单元格 → 删除行启用。
      await tester.tap(find.byKey(const ValueKey<String>('sui-table-0-0')));
      await tester.pump();
      expect(
        bar(Icons.delete_outline).onPressed,
        isNotNull,
        reason: '激活正文行后应可删除行',
      );

      await db.close();
    });

    testWidgets('仅剩一列时「删除列」禁用', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-table5', '| A |\n| --- |\n| 1 |');

      expect(find.byType(FormatTableView), findsOneWidget);
      final del = tester.widget<IconButton>(
        find.descendant(
          of: find.byType(FormatTableView),
          matching: find.widgetWithIcon(IconButton, Icons.playlist_remove),
        ),
      );
      expect(del.onPressed, isNull, reason: '单列表格不可再删列');

      await db.close();
    });
  });

  group('表格交互导航（回归：方向键不改写正本 / 幽灵行可删 / 无表格后占位行）', () {
    late AppDatabase db;

    testWidgets('单元格内方向键不改写正本', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(
        tester,
        db,
        'm9t12-nav1',
        '| A | B |\n| --- | --- |\n| 1 | 2 |',
      );
      final ctrl = _contentValue(tester);
      final original = ctrl.text;

      // 点选正文区第一个数据单元格 (0,0)，让它获得焦点。
      await tester.tap(find.byKey(const ValueKey<String>('sui-table-0-0')));
      await tester.pump();

      for (final k in const <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
      ]) {
        await tester.sendKeyEvent(k);
        await tester.pump();
      }

      expect(ctrl.text, original, reason: '方向键只应在单元格内移动光标，不得回灌正本');
      await db.close();
    });

    testWidgets('末单元格 Enter 增行后可用「删除行」删除，无残留幽灵行', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(
        tester,
        db,
        'm9t12-nav2',
        '| A | B |\n| --- | --- |\n| 1 | 2 |',
      );
      final ctrl = _contentValue(tester);
      const base = '| A | B |\n| --- | --- |\n| 1 | 2 |';

      await tester.tap(find.byKey(const ValueKey<String>('sui-table-0-1')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(ctrl.text, '$base\n|  |  |', reason: '末单元格回车应新增一个空数据行');

      final delBtn = find.descendant(
        of: find.byType(FormatTableView),
        matching: find.widgetWithIcon(IconButton, Icons.delete_outline),
      );
      await tester.tap(delBtn);
      await tester.pump();
      expect(ctrl.text, base, reason: '删除行应精确移除刚新增的空行，回到原表');

      await db.close();
    });

    testWidgets('表格区间补齐文本禁换行：格式模式下方不产生随行数增长的占位行', (tester) async {
      db = AppDatabase.memory();
      // 3×3 表（表头 + 分隔行 + 2 数据行 = 4 行）：区间内含 **3 个表内换行**，旧实现正是
      // 逐个换行建立行盒、在表格下方撑出可见却光标不可达、不可删的「占位行」；
      // 每新增一行就多一个表内换行 → 多一个占位行。
      const source = '|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |\n';
      await _pumpEditor(tester, db, 'm9t12-nav3', source);

      expect(find.byType(FormatTableView), findsOneWidget, reason: '格式模式应呈现表格单元');
      final ctrl = _contentValue(tester) as MarkdownEditingController;
      expect(ctrl.text, source, reason: '呈现不得改动正本');

      final span = ctrl.buildTextSpan(
        context: tester.element(_contentField()),
        style: const TextStyle(),
        withComposing: false,
      );

      // 偏移契约：span 树纯文本仍与正本逐码元等长（BR-27.1 / AC-154）。
      expect(
        span.toPlainText().length,
        ctrl.text.length,
        reason: '换行替身必须等码元，否则光标定位会错位',
      );

      final children = span.children!;
      expect(
        children.whereType<WidgetSpan>().length,
        1,
        reason: '整块表格折叠为一个 WidgetSpan 占位单元',
      );
      final tableIdx = children.indexWhere((s) => s is WidgetSpan);
      final fill = children[tableIdx + 1] as TextSpan;
      expect(
        fill.text!.contains('\n'),
        isFalse,
        reason: '表格区间补齐文本含 `\\n` 会逐行建立行盒，在 strut 最小行高下撑出占位行（§12.1.1）',
      );
      // 表内换行数 = 正本换行数 − 表尾那 1 个块外换行（`rows:3` 生成表头 + 分隔 + 2 数据行 = 4 行）。
      final internalNewlines = '\n'.allMatches(source).length - 1;
      expect(internalNewlines, 3, reason: '3×3 表格正本应为 4 行（3 个表内换行）');
      expect(
        '\u2060'.allMatches(fill.text!).length,
        internalNewlines,
        reason: '每个表内换行都应以零宽禁断行字符 `U+2060` 顶替，维持等长且不换行',
      );
      expect(
        '\n'.allMatches(span.toPlainText()).length,
        1,
        reason: '整棵呈现文本只应保留表格块**外**那 1 个段间换行，不得残留表内换行',
      );

      await db.close();
    });
  });

  group('表格行整格点选激活（回归：含 <br> 单元格的行可精确删除）', () {
    late AppDatabase db;

    Finder rowDeleteBtn() => find.descendant(
          of: find.byType(FormatTableView),
          matching: find.widgetWithIcon(IconButton, Icons.delete_outline),
        );

    bool rowDeleteEnabled(WidgetTester tester) =>
        tester.widget<IconButton>(rowDeleteBtn()).onPressed != null;

    testWidgets('行高由多行（`<br>`）单元格决定时，同行单行单元格也铺满整行、留白不再是死区',
        (tester) async {
      db = AppDatabase.memory();
      // 首个数据行首格含 2 个 `<br>`（3 行文本），该行行高远高于同行的单行单元格。
      // 旧实现：同行单行单元格只包裹自身内容、由 `TableCellVerticalAlignment.middle`
      // 居中摆放，其上下留白**无任何组件覆盖**，点击不激活该行 → 以活动单元格为基准的
      // 「删除行」按钮保持**禁用**（用户报「无法删除该行」）；若此前激活过别的行，
      // 则会**误删那行**（「删除会有问题」）。
      const src = '| A | B |\n| --- | --- |\n| 1<br>1b<br>1c | 2 |\n| 3 | 4 |';
      await _pumpEditor(tester, db, 'm9t12-act1', src);
      final ctrl = _contentValue(tester);

      final tall =
          tester.getRect(find.byKey(const ValueKey<String>('sui-table-0-0')));
      final short =
          tester.getRect(find.byKey(const ValueKey<String>('sui-table-0-1')));
      expect(
        short.height,
        tall.height,
        reason: '`intrinsicHeight` 下同行各格铺满整行，行内不留可被 hitTest 穿透的垂直死区',
      );
      expect(short.top, tall.top, reason: '同行各格上边界应一致（= 行顶）');
      expect(short.bottom, tall.bottom, reason: '同行各格下边界应一致（= 行底）');

      expect(rowDeleteEnabled(tester), isFalse, reason: '初始活动单元格为表头，删除行禁用');

      // 点同行单行单元格的**顶部留白**（旧实现下此处没有任何组件，点击彻底无效）。
      await tester.tapAt(Offset(short.center.dx, short.top + 2));
      await tester.pump();
      expect(rowDeleteEnabled(tester), isTrue, reason: '整格可点选激活：留白处点击也应激活该行');

      await tester.tap(rowDeleteBtn());
      await tester.pump();
      expect(
        ctrl.text,
        '| A | B |\n| --- | --- |\n| 3 | 4 |',
        reason: '含 `<br>` 单元格的行应被精确整行删除（不误删其它行、不留残行）',
      );

      await db.close();
    });

    testWidgets('单元格内边距同样可点选激活（命中区覆盖整个单元格盒子）', (tester) async {
      db = AppDatabase.memory();
      const src = '| A | B |\n| --- | --- |\n| 1<br>1b | 2 |\n| 3 | 4 |';
      await _pumpEditor(tester, db, 'm9t12-act2', src);
      final ctrl = _contentValue(tester);

      final cell =
          tester.getRect(find.byKey(const ValueKey<String>('sui-table-0-0')));
      expect(rowDeleteEnabled(tester), isFalse, reason: '尚未激活任何数据行');

      // 落在 6px 水平内边距内：旧实现**只有**内层 `TextField` 带 `onTap`，此处点击无效。
      await tester.tapAt(Offset(cell.left + 2, cell.center.dy));
      await tester.pump();
      expect(rowDeleteEnabled(tester), isTrue, reason: '内边距也应命中并激活该行');

      await tester.tap(rowDeleteBtn());
      await tester.pump();
      expect(ctrl.text, '| A | B |\n| --- | --- |\n| 3 | 4 |');

      await db.close();
    });

    testWidgets('点击文本区仍由 TextField 接管（光标落点不被整格命中区改动）', (tester) async {
      db = AppDatabase.memory();
      const src = '| A | B |\n| --- | --- |\n| abcdef | 2 |\n| 3 | 4 |';
      await _pumpEditor(tester, db, 'm9t12-act3', src);

      const cellKey = ValueKey<String>('sui-table-0-0');
      final field = find.descendant(
        of: find.byKey(cellKey),
        matching: find.byType(TextField),
      );
      final controller = tester.widget<TextField>(field).controller!;
      final rect = tester.getRect(find.byKey(cellKey));

      // 点在文本**末尾之后**、但仍在 `TextField` 盒内：手势竞技场取最内层，故该点击
      // 仍由 `TextField` 接管、光标落到文本末尾，外层整格命中区不得吞掉它。
      await tester.tapAt(Offset(rect.right - 8, rect.center.dy));
      await tester.pump();
      expect(
        controller.selection.baseOffset,
        6,
        reason: '点击文本区仍应把光标落到文本末尾（外层只负责空白处激活）',
      );
      expect(rowDeleteEnabled(tester), isTrue, reason: '激活由 `TextField` 自身 onTap 完成');

      await db.close();
    });
  });

  group('TableCellAttachmentWidget（FR-44 / §12.1.1 / AC-139）', () {
    ParsedTable table2x2() =>
        EditorFormat.parseTable('| A | B |\n| --- | --- |\n| 1 | 2 |', 0)!;

    Future<void> pumpTableView(
      WidgetTester tester, {
      required Future<void> Function(int rowIndex, int column)? onInsertAttachment,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FormatTableView(
                table: table2x2(),
                onSetCell: (int r, int c, String v) {},
                onInsertRow: (int r, bool a) {},
                onRemoveRow: (int r) {},
                onInsertColumn: (int c, bool a) {},
                onRemoveColumn: (int c) {},
                onSetAlignment: (int c, TableColumnAlign a) {},
                onInsertAttachment: onInsertAttachment,
                availableWidth: 800,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder attachButton() => find.descendant(
          of: find.byType(FormatTableView),
          matching: find.widgetWithIcon(IconButton, Icons.attach_file),
        );

    testWidgets('上下文栏「插入图片 / 附件」按钮按活动单元格回调（行，列）', (tester) async {
      final calls = <(int, int)>[];
      await pumpTableView(
        tester,
        onInsertAttachment: (int r, int c) async => calls.add((r, c)),
      );

      expect(attachButton(), findsOneWidget, reason: '上下文栏应提供插入图片 / 附件按钮');
      expect(
        tester.widget<IconButton>(attachButton()).onPressed,
        isNotNull,
        reason: '已接线时按钮可点',
      );

      // 激活第二个数据单元格 (0,1)，按钮应汇报该活动单元格。
      await tester.tap(find.byKey(const ValueKey<String>('sui-table-0-1')));
      await tester.pump();
      await tester.tap(attachButton());
      await tester.pump();

      expect(calls, [(0, 1)], reason: '回调须带上活动单元格的行、列下标');
    });

    testWidgets('未提供 onInsertAttachment 时按钮禁用', (tester) async {
      await pumpTableView(tester, onInsertAttachment: null);
      expect(
        tester.widget<IconButton>(attachButton()).onPressed,
        isNull,
        reason: '未接线时按钮应禁用（onPressed == null）',
      );
    });

    testWidgets('真实编辑器已接线：表格上下文栏按钮可用', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(
        tester,
        db,
        'm9t12-cellatt1',
        '| A | B |\n| --- | --- |\n| 1 | 2 |',
      );

      expect(find.byType(FormatTableView), findsOneWidget);
      expect(attachButton(), findsOneWidget);
      expect(
        tester.widget<IconButton>(attachButton()).onPressed,
        isNotNull,
        reason: 'NoteEditor 应为 FormatTableView 接上 onInsertAttachment',
      );

      await db.close();
    });
  });

  group('AttachmentBlockDeleteWidget（FR-46 / AC-145~AC-147）', () {
    late AppDatabase db;

    Future<void> cursorAt(WidgetTester tester, int offset) async {
      await tester.tap(_contentField());
      await tester.pump();
      _contentValue(tester).selection = TextSelection.collapsed(offset: offset);
      await tester.pump();
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }

    testWidgets('退格落在引用末端边界 → 整块删除引用', (tester) async {
      db = AppDatabase.memory();
      // `前 [文档](sui://deadbeef) 后`：ref.start=2，ref.end=22。
      await _pumpEditor(tester, db, 'm9t12-att1', '前 [文档](sui://deadbeef) 后');

      await cursorAt(tester, 22);
      await press(tester, LogicalKeyboardKey.backspace);

      final text = _contentValue(tester).text;
      expect(
        text,
        '前  后',
        reason: '退格落在 ref.end 应整块删除引用，不进入内部逐字符删除（BR-46.1）',
      );
      expect(text.contains('sui://'), isFalse);

      await db.close();
    });

    testWidgets('Delete 落在引用起点边界 → 整块删除引用', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-att2', '前 [文档](sui://deadbeef) 后');

      await cursorAt(tester, 2);
      await press(tester, LogicalKeyboardKey.delete);

      expect(
        _contentValue(tester).text,
        '前  后',
        reason: 'Delete 落在 ref.start 应整块删除引用（BR-46.2）',
      );

      await db.close();
    });

    testWidgets('删除键未落在边界 → 引用逐字不动', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-att3', '前 [文档](sui://deadbeef) 后');

      await cursorAt(tester, 23);
      await press(tester, LogicalKeyboardKey.backspace);

      expect(
        _contentValue(tester).text.contains('[文档](sui://deadbeef)'),
        isTrue,
        reason: '非边界的删除键不得整块删除引用，引用须逐字保留',
      );

      await db.close();
    });

    testWidgets('残缺引用（缺 `)`）就地补齐自愈', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-att4', '[文档](sui://deadbeef');

      await cursorAt(tester, 19);
      await press(tester, LogicalKeyboardKey.backspace);

      expect(
        _contentValue(tester).text,
        '[文档](sui://deadbeef)',
        reason: '缺闭合括号的残缺引用应就地补齐（AC-147）',
      );

      await db.close();
    });
  });

  group('TableAtomicDeleteWidget（FR-44 / §12.1.1 ⑥⑦ / AC-140 / BR-44.6）', () {
    late AppDatabase db;

    // 正文：`前文\n| A | B |\n| --- | --- |\n| 1 | 2 |\n后文`
    // 表格块区间 [3, 36)：table.start=3、table.end=36（end 不含行尾换行；
    // source[36]='\n'）。表格下方「默认空行」的行首即 table.end + 1 = 37。
    const withAround = '前文\n| A | B |\n| --- | --- |\n| 1 | 2 |\n后文';

    Future<void> cursorAt(WidgetTester tester, int offset) async {
      await tester.tap(_contentField());
      await tester.pump();
      _contentValue(tester).selection = TextSelection.collapsed(offset: offset);
      await tester.pump();
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }

    testWidgets('右/下移入表格末尾 → 吸附到表格下方默认空行行首（table.end + 1）', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-tabsnap', withAround);

      await tester.tap(_contentField());
      await tester.pump();
      final ctrl = _contentValue(tester);
      // 直接驱动折叠光标，模拟「自表格上方向下 / 向右移动」：
      // 先落在表格前一行（offset 0，方向基准），再移入表格块末（table.end = 36）。
      ctrl.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      ctrl.selection = const TextSelection.collapsed(offset: 36);
      await tester.pump();

      expect(
        ctrl.selection.extentOffset,
        37,
        reason: '右/下移的光标须停在表格下方默认空行行首（table.end + 1），而非表格末行末尾（§12.1.1 ⑦）',
      );

      await db.close();
    });

    testWidgets('退格落在表格下方默认空行行首 → 整块删除整张表格，不再打回原形', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-tabdel1', withAround);

      await cursorAt(tester, 37); // 表格下方默认空行行首 table.end + 1
      await press(tester, LogicalKeyboardKey.backspace);

      expect(
        _contentValue(tester).text,
        '前文\n后文',
        reason: '退格落在表格下方默认空行行首须整块删除整张表格，绝不逐字符删掉末尾 `|` 致表格回退为原文（§12.1.1 ⑥⑦ / BR-44.6）',
      );

      await db.close();
    });

    testWidgets('删除键未落在表格边界 → 表格逐字保留', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-tabdel3', withAround);

      await cursorAt(tester, 1); // 「前文」中间，远离表格
      await press(tester, LogicalKeyboardKey.backspace);

      final text = _contentValue(tester).text;
      expect(text.contains('| --- | --- |'), isTrue,
          reason: '非表格边界的删除键不得波及表格');
      expect(text.contains('| 1 | 2 |'), isTrue);
      expect(text.length, withAround.length - 1, reason: '仅逐字符删掉光标前一字符');

      await db.close();
    });
  });

  group('AttachmentPanelWidget（FR-46 / FR-47）', () {
    late AppDatabase db;

    Future<void> openPanel(WidgetTester tester) async {
      final btn = find.byTooltip('附件');
      await tester.ensureVisible(btn);
      await tester.pump();
      await tester.tap(btn);
      await _settleRoute(tester);
    }

    testWidgets('无附件时面板显示空态并给出引导', (tester) async {
      db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm9t12-panel1', '正文');

      await openPanel(tester);
      expect(
        find.textContaining('暂无附件'),
        findsOneWidget,
        reason: '空态应给出「添加附件」引导',
      );

      await db.close();
    });

    testWidgets('已有附件时面板按元数据列出文件名与数量', (tester) async {
      db = AppDatabase.memory();
      final controller = await _pumpEditor(
        tester,
        db,
        'm9t12-panel2',
        '正文',
        seed: (c, repo) async {
          await repo.addAttachment(
            noteId: c.selectedNoteId!,
            filename: '报告.pdf',
            mimeKind: 'document',
            sha256: 'a' * 64,
            byteSize: 2048,
          );
          await c.refreshAttachments(c.selectedNoteId!);
        },
      );
      expect(controller.attachments, hasLength(1));

      await openPanel(tester);
      expect(find.text('报告.pdf'), findsOneWidget, reason: '面板应列出附件文件名');
      expect(find.text('1 个'), findsOneWidget, reason: '面板标题应显示附件数量');

      await db.close();
    });
  });

  group('OrderedListRenderWidget（FR-48 / AC-152~AC-154）', () {
    testWidgets('正本统一 `1.`，渲染层按序编号且 span 树与正本逐字符等长', (tester) async {
      final controller = MarkdownEditingController(text: '1. 甲\n1. 乙\n1. 丙');
      controller.styled = true;

      late TextSpan span;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(),
              withComposing: false,
            );
            return const SizedBox.shrink();
          }),
        ),
      );

      // 偏移契约：编号呈现单元占位后须用零宽透明文本补齐，整棵 span 树与正本等长。
      expect(
        span.toPlainText().length,
        controller.text.length,
        reason: 'span 树纯文本必须与正本等长，否则光标定位会错位（BR-27.1 / AC-154）',
      );

      final numbers = span.children!
          .whereType<WidgetSpan>()
          .map((w) => w.child)
          .whereType<Text>()
          .map((t) => t.data)
          .toList();
      expect(
        numbers,
        ['2', '3'],
        reason: '正本字面量均为 `1`，第 2、3 项显示编号与之不同，故各生成一个编号呈现单元',
      );

      controller.dispose();
    });
  });
}
