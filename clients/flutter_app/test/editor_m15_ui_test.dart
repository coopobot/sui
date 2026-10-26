/// M15 编辑器 UI 接线（v0.15.0）——**查找栏 / 关联笔记 / 链接单元 / 输入转义 / 粘贴归一 /
/// 代码块底色带 / 属性入口**。
///
/// 覆盖的冻结口径：
/// * `FindBar`（FR-73 / BR-73.1\~73.4）：打开 / 关闭 / `Esc` 归还焦点 / 上一下一个 / 计数 /
///   大小写 / 单处替换 / 全部替换 / **结构区跳过**（格式模式计数跳过、源码模式全量）/
///   一步撤销 / `openFind()` **幂等**；
/// * `NoteRef`（FR-75 / BR-75.1\~75.3）：选择器（排除当前笔记）/ 插入正本形态
///   `[标题](sui://note/<id>)` / 跳转分流走 `openNoteInWindow`（未注入窗口管理器时降级为
///   主窗口内切换）/ 目标缺失只提示、**不改正本**；
/// * `LinkUnit`（FR-76 / BR-76.1 / BR-76.2）：单击选中不打开、双击打开（`debugUrlOpenerOverride`
///   打桩）、非白名单不打开、**正本逐字节不变**；
/// * `EscapeInput`（FR-78 / BR-78.1\~78.5）：正文 `*` → `\*`、单元格 `|` 不双重转义、
///   IME 组合期不拦、源码模式不加工；
/// * `PasteNormalize`（FR-77 / BR-77.2）：CRLF → LF，且**格式模式勾选框仍在**；
/// * `CodeBlockBand`（FR-81a / BR-81.1）：`paragraphWidth > 0` 时树中存在底色带 widget；
/// * `PropertiesEntry`（FR-74）：属性图标存在且回调被调用。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（Agents.md §5.2：30s 周期同步 + 不定长进度条会静默
/// 卡到 10 分钟超时），一律有界 `pump`；真实异步 IO 用 `tester.runAsync`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/platform/url_opener.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/code_block_band_painter.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/markdown_input_formatter.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

/// 起一个挂了真实 `NoteShell` 的编辑器，并把 [content] 写入当前笔记
/// （口径同 `editor_link_paste_v141_test.dart`；窗口取宽屏，使查找栏 / 工具栏整行可见）。
Future<AppController> _pumpEditor(
  WidgetTester tester,
  AppDatabase db,
  String deviceId,
  String content,
) async {
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

  await tester.binding.setSurfaceSize(const Size(1600, 900));
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

/// 建两篇笔记（`甲笔记` 当前编辑、`目标笔记` 作为关联候选），并返回三者的 id。
Future<(AppController, String, String)> _pumpTwoNotes(
  WidgetTester tester,
  AppDatabase db,
  String deviceId, {
  String content = '正文',
}) async {
  final repo = NoteRepository(db, deviceId: deviceId);
  final controller = AppController(repository: repo, database: db);
  await controller.bootstrap();
  await controller.createNote();
  final first = controller.selectedNoteId!;
  await controller.saveNote(first,
      title: '甲笔记', content: content, tags: const <String>[]);
  await controller.createNote();
  final second = controller.selectedNoteId!;
  await controller.saveNote(second,
      title: '目标笔记', content: '目标正文', tags: const <String>[]);
  controller.selectNote(first);

  await tester.binding.setSurfaceSize(const Size(1600, 900));
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
  return (controller, first, second);
}

/// 当前编辑器里的底色带绘制器（未挂时为 null）。
CodeBlockBandPainter? _bandPainter(WidgetTester tester) {
  final finder = find.byKey(kCodeBlockBandPainterKey);
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<CustomPaint>(finder).painter as CodeBlockBandPainter?;
}

Finder _contentField() => find
    .descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    )
    .first;

TextEditingController _contentValue(WidgetTester tester) =>
    tester.widget<TextField>(_contentField()).controller!;

Finder _findQueryField() => find.byKey(const ValueKey('sui-find-query'));

String _findCountText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('sui-find-count')))
    .data!;

/// 有界推进（**不用** `pumpAndSettle`：见文件头纪律）。
Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 打开查找栏并输入查询词（走真实按钮 / 输入框，不直调私有状态）。
Future<void> _openFind(WidgetTester tester, String query) async {
  await tester.tap(find.byKey(const ValueKey('sui-find-open')));
  await tester.pump();
  await tester.enterText(_findQueryField(), query);
  await tester.pump();
  await _settle(tester);
}

Future<void> _pressCtrl(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// 切换到指定模式（宽屏模式行保留文本标签）。
Future<void> _switchMode(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await _settle(tester);
}

/// 装上平台剪贴板 mock（测试环境下不装时 `Clipboard.getData` 不会返回）。
void _mockClipboard(WidgetTester tester, {String? html, String? plain}) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.getData') {
        final format = call.arguments as String?;
        if (format == 'text/html') return <String, dynamic>{'text': html};
        return <String, dynamic>{'text': plain};
      }
      return null;
    },
  );
}

/// 在**当前已聚焦**的输入框上模拟一次「原样键入」（走真实 `TextInputClient` 通道，
/// 因而**经过** `inputFormatters`）——`tester.enterText` 是整串替换，测不到单字符插入路径。
Future<void> _typeRaw(
  WidgetTester tester,
  String text,
  int caret, {
  TextRange composing = TextRange.empty,
}) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
      composing: composing,
    ),
  );
  await tester.pump();
}

void main() {
  // -------------------------------------------------------------------------
  // FR-73：笔记内查找与替换
  // -------------------------------------------------------------------------
  group('FindBar（FR-73 / BR-73.1~73.4）', () {
    testWidgets('打开 → 计数 → 上一下一个 → Esc 关闭并归还焦点', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm15-find-basic', '甲 乙 甲\n第二行 甲');

      expect(find.byKey(const ValueKey('sui-find-query')), findsNothing,
          reason: '初始不显示查找栏');

      await _openFind(tester, '甲');
      expect(find.byKey(const ValueKey('sui-find-query')), findsOneWidget);
      expect(_findCountText(tester), '1/3', reason: '不跨行逐处计数');

      await tester.tap(find.byKey(const ValueKey('sui-find-next')));
      await tester.pump();
      expect(_findCountText(tester), '2/3');

      await tester.tap(find.byKey(const ValueKey('sui-find-next')));
      await tester.pump();
      expect(_findCountText(tester), '3/3', reason: '到尾循环');

      await tester.tap(find.byKey(const ValueKey('sui-find-prev')));
      await tester.pump();
      expect(_findCountText(tester), '2/3');
      await tester.tap(find.byKey(const ValueKey('sui-find-prev')));
      await tester.pump();
      expect(_findCountText(tester), '1/3', reason: '到头循环');

      // 定位 = **非折叠**选区（控制器的光标吸附不得改写它，规范 §1.7）。
      final ctrl = _contentValue(tester);
      expect(ctrl.selection.isCollapsed, isFalse);
      expect(ctrl.text.substring(ctrl.selection.start, ctrl.selection.end), '甲');

      // `Esc` → 关闭并把焦点还给正文。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await _settle(tester);
      expect(find.byKey(const ValueKey('sui-find-query')), findsNothing);
      expect(tester.widget<TextField>(_contentField()).focusNode!.hasFocus,
          isTrue, reason: 'Esc 关闭后焦点归还正文（FR-73）');
      expect((ctrl as MarkdownEditingController).findMatches, isEmpty,
          reason: '关闭时清空控制器命中集合并重绘');
      await db.close();
    });

    testWidgets('openFind 幂等：连续两次打开不关闭', (tester) async {
      final db = AppDatabase.memory();
      final controller =
          await _pumpEditor(tester, db, 'm15-find-idem', '甲');

      // 走桌面命令桥（等同菜单 / `Ctrl+F`），连点两次不得把栏开了又关。
      controller.targetFor(controller.activeViewKey)!.openFind();
      await tester.pump();
      await _settle(tester);
      expect(find.byKey(const ValueKey('sui-find-query')), findsOneWidget);
      controller.targetFor(controller.activeViewKey)!.openFind();
      await tester.pump();
      await _settle(tester);
      expect(find.byKey(const ValueKey('sui-find-query')), findsOneWidget,
          reason: 'openFind() 必须是幂等的「打开并聚焦」，不是 toggle');
      await db.close();
    });

    testWidgets('Ctrl+F 打开（两态都挂查找层）', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm15-find-ctrl', '甲');

      await tester.tap(_contentField());
      await tester.pump();
      await _pressCtrl(tester, LogicalKeyboardKey.keyF);
      await _settle(tester);
      expect(find.byKey(const ValueKey('sui-find-query')), findsOneWidget,
          reason: '格式模式 Ctrl+F 打开查找栏');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byKey(const ValueKey('sui-find-query')), findsNothing);

      // 源码模式：查找层仍在（`_findShortcuts` 两态挂载）。
      await _switchMode(tester, '源码');
      await tester.tap(_contentField());
      await tester.pump();
      await _pressCtrl(tester, LogicalKeyboardKey.keyF);
      await _settle(tester);
      expect(find.byKey(const ValueKey('sui-find-query')), findsOneWidget,
          reason: '源码模式也要能 Ctrl+F（FR-73 两态均可）');
      await db.close();
    });

    testWidgets('区分大小写开关', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm15-find-case', 'Ab ab AB');

      await _openFind(tester, 'ab');
      expect(_findCountText(tester), '1/3', reason: '默认不区分大小写');

      await tester.tap(find.byKey(const ValueKey('sui-find-case')));
      await tester.pump();
      expect(_findCountText(tester), '1/1', reason: '区分大小写后只剩小写 ab');

      await tester.tap(find.byKey(const ValueKey('sui-find-case')));
      await tester.pump();
      expect(_findCountText(tester), '2/3',
          reason: '再次点击切回不区分：命中 3 处，且**保持当前项位置**（当前项是原 `ab`，新集合里排第 2）');
      await db.close();
    });

    testWidgets('单处替换 / 全部替换（一次写入 = 一步撤销）', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm15-find-replace', '甲 甲 甲');
      final ctrl = _contentValue(tester);

      await _openFind(tester, '甲');
      expect(_findCountText(tester), '1/3');
      await tester.enterText(
          find.byKey(const ValueKey('sui-find-replace-query')), '乙');
      await tester.pump();
      // `UndoHistory` 是 **500ms 节流**落栈（Flutter `undo_history.dart`）：先让首帧的写入
      // 落定，后续断言才有确定的栈顶。
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tap(find.byKey(const ValueKey('sui-find-replace')));
      await tester.pump();
      expect(ctrl.text, '乙 甲 甲', reason: '「替换」只改当前一处');
      expect(_findCountText(tester), '1/2', reason: '替换后命中集合实时重算');

      // 「全部替换」：**一次** `value` 赋值（一次写入 = 一步撤销，BR-73.3）。
      final snapshots = <String>[];
      void onWrite() => snapshots.add(ctrl.text);
      ctrl.addListener(onWrite);
      await tester.tap(find.byKey(const ValueKey('sui-find-replace-all')));
      await tester.pump();
      ctrl.removeListener(onWrite);
      expect(ctrl.text, '乙 乙 乙');
      expect(snapshots.toSet(), {'乙 乙 乙'},
          reason: '「全部替换」必须一次编辑：写入过程中不得出现中间态（BR-73.3）');

      // 一步撤销：整次替换回到起点。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(_contentField());
      await tester.pump();
      await _pressCtrl(tester, LogicalKeyboardKey.keyZ);
      await tester.pump();
      await _settle(tester);
      expect(ctrl.text, '甲 甲 甲',
          reason: '「全部替换」是一次编辑 = 一步撤销（BR-73.3）');
      await db.close();
    });

    testWidgets('结构区跳过：格式模式计数跳过，源码模式全量', (tester) async {
      final db = AppDatabase.memory();
      // 命中一处落在链接的 `](网址)` 段（结构区），一处是普通正文。
      await _pumpEditor(
          tester, db, 'm15-find-structural', '[文字](https://目标.com) 目标');

      await _openFind(tester, '目标');
      expect(_findCountText(tester), '1/1 · 已跳过 1 处结构区',
          reason: '格式模式：链接 URL 段属结构区，不计数并给出跳过提示（BR-73.2）');

      await tester.tap(find.byKey(const ValueKey('sui-find-close')));
      await tester.pump();
      await _switchMode(tester, '源码');
      await _openFind(tester, '目标');
      expect(_findCountText(tester), '1/2',
          reason: '源码模式一切字符可见 → 全量参与查找（FR-73）');
      await db.close();
    });

    testWidgets('打开时用非折叠选区预填查询词', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm15-find-prefill', '苹果 香蕉 苹果');
      final ctrl = _contentValue(tester);
      ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('sui-find-open')));
      await tester.pump();
      await _settle(tester);
      expect(tester.widget<TextField>(_findQueryField()).controller!.text, '苹果');
      expect(_findCountText(tester), '1/2');
      await db.close();
    });
  });

  // -------------------------------------------------------------------------
  // FR-75：关联笔记
  // -------------------------------------------------------------------------
  group('NoteRef（FR-75 / BR-75.1~75.3）', () {
    testWidgets('选择器：排除当前笔记，插入正本形态 [标题](sui://note/<id>)', (tester) async {
      final db = AppDatabase.memory();
      final (_, _, second) = await _pumpTwoNotes(tester, db, 'm15-noteref-insert');
      final ctrl = _contentValue(tester);

      await tester.tap(find.byKey(const ValueKey('sui-note-ref')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('sui-note-picker-query')), findsOneWidget,
          reason: '工具栏「关联笔记」打开选择器（FR-75 插入入口）');
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('甲笔记'),
        ),
        findsNothing,
        reason: '选择器必须排除**当前笔记**',
      );

      await tester.tap(find.byKey(ValueKey('sui-note-picker-$second')));
      await tester.pump();
      await _settle(tester);
      expect(ctrl.text, contains('[目标笔记](sui://note/$second)'),
          reason: '正本形态恒为 `[标题](sui://note/<笔记ID>)`（BR-75.1）');
      expect(ctrl.text, startsWith('正文'),
          reason: '插入落在当前光标处（无有效光标时落文末），既有正文逐字不动');
      await db.close();
    });

    testWidgets('链接条「跳转」→ openNoteInWindow（未注入窗口管理器时降级为主窗口切换）',
        (tester) async {
      final db = AppDatabase.memory();
      final (controller, _, second) = await _pumpTwoNotes(
        tester,
        db,
        'm15-noteref-jump',
        content: '[目标](sui://note/xxx)',
      );
      final ctrl = _contentValue(tester);
      // 用真实 id 改写正本链接，再定位光标到链接内。
      ctrl.text = '[目标](sui://note/$second)';
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      expect(find.text('跳转'), findsOneWidget,
          reason: '笔记引用的链接条按钮是「跳转」（不是「打开」）');
      expect(find.text('编辑'), findsNothing,
          reason: '笔记引用**隐藏「编辑」**（就地改引用 URL 只会把引用改坏）');

      await tester.tap(find.text('跳转'));
      await tester.pump();
      await _settle(tester);
      expect(controller.selectedNoteId, second,
          reason: '跳转必须走 AppController.openNoteInWindow（FR-75 跳转口径）');
      await db.close();
    });

    testWidgets('目标缺失：只提示、不改动正本', (tester) async {
      final db = AppDatabase.memory();
      const src = '[缺](sui://note/does-not-exist)';
      await _pumpEditor(tester, db, 'm15-noteref-missing', src);
      final ctrl = _contentValue(tester);
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await tester.tap(find.text('跳转'));
      await tester.pump();
      await _settle(tester);
      expect(find.text('笔记不存在或尚未同步'), findsOneWidget,
          reason: '缺失 / 未解锁 → 明确提示（BR-75.3）');
      expect(ctrl.text, src, reason: '跳转失败绝不改正本一字（BR-70.4）');
      await db.close();
    });
  });

  // -------------------------------------------------------------------------
  // FR-76：格式模式链接单元
  // -------------------------------------------------------------------------
  group('LinkUnit（FR-76 / BR-76.1 / BR-76.2）', () {
    testWidgets('单击选中不打开、双击打开、非白名单不打开、正本不变', (tester) async {
      final opened = <String>[];
      debugUrlOpenerOverride = (url) async {
        opened.add(url);
        return true;
      };
      addTearDown(() => debugUrlOpenerOverride = null);

      final db = AppDatabase.memory();
      const src = '[站](https://a.com) 与 [坏](javascript:alert(1)) 尾';
      await _pumpEditor(tester, db, 'm15-link-unit', src);
      final ctrl = _contentValue(tester);

      // 单击：选中（链接条出现）但**不打开**。
      await tester.tap(find.text('站'));
      await tester.pump(const Duration(milliseconds: 350));
      await _settle(tester);
      expect(opened, isEmpty, reason: '单击只选中，不打开（FR-76）');
      expect(find.text('https://a.com'), findsOneWidget,
          reason: '单击后链接条随之出现（光标落到链接末尾）');
      expect(ctrl.text, src, reason: '单击不改动正本一字');

      // 双击：打开（走白名单 → 系统默认浏览器接缝）。
      await tester.tap(find.text('站'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('站'));
      await tester.pump(const Duration(milliseconds: 350));
      await _settle(tester);
      expect(opened, ['https://a.com'], reason: '双击打开（FR-76 / BR-70.2）');

      // 非白名单：可选中、**不打开**。
      await tester.tap(find.text('坏'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('坏'));
      await tester.pump(const Duration(milliseconds: 350));
      await _settle(tester);
      expect(opened, ['https://a.com'], reason: 'javascript: 一律不打开');
      expect(ctrl.text, src, reason: '任何路径都不得改正本');
      await db.close();
    });
  });

  // -------------------------------------------------------------------------
  // FR-78：格式模式输入转义
  // -------------------------------------------------------------------------
  group('EscapeInput（FR-78 / BR-78.1~78.5）', () {
    test('formatter：单字符插入转义 / 光标右移 / IME 与粘贴放行 / 字母不转义', () {
      const f = MarkdownSyntaxEscapeFormatter();
      const old = TextEditingValue(
        text: '前后',
        selection: TextSelection.collapsed(offset: 1),
      );

      // 行内恒敏感字符：任何位置都转义，且光标停在字符右侧。
      final star = f.formatEditUpdate(
        old,
        const TextEditingValue(
          text: '前*后',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      expect(star.text, r'前\*后');
      expect(star.selection.baseOffset, 3);

      // IME 组合期：原样返回（否则中文拼音上屏被打断）。
      final composing = f.formatEditUpdate(
        old,
        const TextEditingValue(
          text: '前*后',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 1, end: 2),
        ),
      );
      expect(composing.text, '前*后');

      // 粘贴（长度 +2）：原样返回，绝不二次转义（BR-78.5）。
      final pasted = f.formatEditUpdate(
        old,
        const TextEditingValue(
          text: '前*~*后',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      expect(pasted.text, '前*~*后');

      // 字母 / 中文绝不前置反斜杠（BR-78.2：`\a` 不是合法转义）。
      final letter = f.formatEditUpdate(
        old,
        const TextEditingValue(
          text: '前a后',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      expect(letter.text, '前a后');

      // 单元格（行内语境）：`|` 交给 `escapeTableCell`，此处**不**转义（避免双重转义）。
      const cell = MarkdownSyntaxEscapeFormatter(inTableCell: true);
      expect(
        cell
            .formatEditUpdate(
              old,
              const TextEditingValue(
                text: '前|后',
                selection: TextSelection.collapsed(offset: 2),
              ),
            )
            .text,
        '前|后',
      );
      expect(
        cell
            .formatEditUpdate(
              old,
              const TextEditingValue(
                text: '前*后',
                selection: TextSelection.collapsed(offset: 2),
              ),
            )
            .text,
        r'前\*后',
        reason: '单元格内其余行内敏感字符照转义',
      );
    });

    testWidgets('真实编辑器：格式模式键入 `*` 落 `\\*`，源码模式不加工', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm15-escape-body', '前后');
      final ctrl = _contentValue(tester);

      await tester.tap(_contentField());
      await tester.pump();
      await tester.showKeyboard(_contentField());
      ctrl.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      await _typeRaw(tester, '前*后', 2);
      expect(ctrl.text, r'前\*后', reason: '格式模式键入 `*` 必须落成转义形式（FR-78）');

      // IME 组合期不拦（不前置反斜杠）。
      ctrl.text = '前后';
      ctrl.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      await _typeRaw(tester, '前*后', 2,
          composing: const TextRange(start: 1, end: 2));
      expect(ctrl.text, '前*后',
          reason: 'IME 组合期原样放行（否则中文拼音上屏被打断，BR-78.1）');

      // 源码模式：所见即正本，**不挂** formatter。
      await _switchMode(tester, '源码');
      final src = _contentValue(tester);
      await tester.showKeyboard(_contentField());
      src.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      await _typeRaw(
        tester,
        '${src.text.substring(0, 1)}*${src.text.substring(1)}',
        2,
      );
      expect(src.text.contains(r'\*'), isFalse,
          reason: '源码模式不加工（FR-77 所见即正本）');
      await db.close();
    });

    testWidgets('表格单元格：`*` 转义、`|` 不双重转义', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(
        tester,
        db,
        'm15-escape-cell',
        '| A | B |\n| --- | --- |\n| 1 | 2 |\n',
      );
      const cellKey = ValueKey<String>('sui-table-0-0');
      final cellField = find.descendant(
        of: find.byKey(cellKey),
        matching: find.byType(TextField),
      );
      final cellCtrl = tester.widget<TextField>(cellField).controller!;

      await tester.showKeyboard(cellField);
      await tester.pump();
      // 单元格 `*` → `\*`（行内敏感字符照转义）。
      cellCtrl.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      await _typeRaw(tester, '*1', 1);
      expect(cellCtrl.text, r'\*1');

      // 单元格 `|` **不**在此转义（由 `escapeTableCell` 提交时统一处理）。
      final before = cellCtrl.text;
      cellCtrl.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      await _typeRaw(tester, '|$before', 1);
      expect(cellCtrl.text, '|$before',
          reason: '单元格 `|` 不得双重转义（BR-44.4 / FR-78）');
      await db.close();
    });
  });

  // -------------------------------------------------------------------------
  // FR-77：粘贴归一
  // -------------------------------------------------------------------------
  group('PasteNormalize（FR-77 / BR-77.2）', () {
    testWidgets('源码模式粘贴 CRLF → 归一为 LF', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'm15-paste-crlf', '- [ ] 甲\n');
      final ctrl = _contentValue(tester);

      _mockClipboard(tester, plain: '- [ ] 甲\r\n- [x] 乙\r\n');
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await _switchMode(tester, '源码');
      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      await tester.pump();
      await _settle(tester);

      expect(ctrl.text.contains('\r'), isFalse,
          reason: '源码模式粘贴必须经 normalizePlainText（CRLF → LF，FR-77 / BR-77.2）');
      expect(ctrl.text.contains(r'- \[x\] 乙'), isTrue,
          reason: '粘贴内容完整落盘（纯文本按 Markdown 特殊字符**安全转义**插入，'
              'FR-45 口径不变）');
      await db.close();
    });

    testWidgets('CRLF 正本：格式模式两处勾选框都在（BR-77.3 门禁扩展）', (tester) async {
      final db = AppDatabase.memory();
      // 历史正本里的 CRLF（粘贴归一之前写进去的）：扫描器必须容错，**不改写正本**。
      await _pumpEditor(tester, db, 'm15-crlf-render', '- [ ] 甲\r\n- [x] 乙');
      await _settle(tester);

      expect(_contentValue(tester).text.contains('\r'), isTrue,
          reason: '历史 CRLF 正本**不**被改写（BR-77.2③）');
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      expect(find.byIcon(Icons.check_box), findsOneWidget,
          reason: 'CRLF 下任务项不得静默降级：格式模式两处勾选框都在（BR-77.3）');
      await db.close();
    });
  });

  // -------------------------------------------------------------------------
  // FR-81a：代码块底色带
  // -------------------------------------------------------------------------
  group('CodeBlockBand（FR-81a / BR-81.1 / FR-93 / FR-94）', () {
    testWidgets('绘制器存在、带矩形铺满编辑区白底，且绘制在 TextField 之前', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(
        tester,
        db,
        'm15-code-band',
        '前文\n\n```dart\nvar a = 1;\n\nvar b = 2;\n```\n\n后文',
      );
      await _settle(tester);

      final ctrl = _contentValue(tester) as MarkdownEditingController;
      expect(ctrl.paragraphWidth, greaterThan(0),
          reason: '`LayoutBuilder` 必须把正文列宽写进 `paragraphWidth`（规范 §2.7）');
      expect(ctrl.buildTextSpan(
        context: tester.element(_contentField()),
        style: const TextStyle(),
        withComposing: false,
      ).toPlainText().length, ctrl.text.length,
          reason: '底色带不得破坏偏移契约（BR-27.1）');

      final painter = _bandPainter(tester);
      expect(painter, isNotNull, reason: '宽度已知时必须挂底色带绘制器（FR-81a）');
      expect(painter!.debugBandRects, hasLength(1),
          reason: '一个围栏块对应一条底色带');
      final paintBox =
          tester.renderObject<RenderBox>(find.byKey(kCodeBlockBandPainterKey));
      final band = painter.debugBandRects.single;
      expect(band.left, closeTo(kEditorBodyPadding, 0.5),
          reason: '带左边界与段落对齐（FR-93 / AC-540）');
      expect(band.right, closeTo(paintBox.size.width - kEditorBodyPadding, 0.5),
          reason: '带右边界与段落对齐（FR-93 / AC-540）');
      expect(band.top, greaterThanOrEqualTo(-0.5));
      expect(band.bottom, lessThanOrEqualTo(paintBox.size.height + 0.5));
      expect(band.height, greaterThan(100),
          reason: '覆盖 5 行围栏块（含块内空行与两条围栏行）');

      // FR-94：带必须画在文字**之下**——绘制器是 Stack 的第一个子节点，
      // TextField 在随后被画的 Padding 里（`RenderParagraph` 会先画全部文字）。
      final stack = tester.widget<Stack>(
        find
            .ancestor(
              of: find.byKey(kCodeBlockBandPainterKey),
              matching: find.byType(Stack),
            )
            .first,
      );
      expect(stack.children.first.key, kCodeBlockBandPainterKey);
      expect(stack.children.skip(1).any((w) => w is Padding), isTrue,
          reason: 'TextField 所在的 Padding 必须在绘制器之后（绘制顺序即带在文字下）');
      await db.close();
    });
  });

  // -------------------------------------------------------------------------
  // FR-74：属性面板入口
  // -------------------------------------------------------------------------
  group('PropertiesEntry（FR-74）', () {
    testWidgets('属性图标存在且回调被调用', (tester) async {
      final db = AppDatabase.memory();
      final repo = NoteRepository(db, deviceId: 'm15-props-entry');
      final controller = AppController(repository: repo, database: db);
      await controller.bootstrap();
      await controller.createNote();
      await controller.saveNote(
        controller.selectedNoteId!,
        title: 'T',
        content: '正文',
        tags: const <String>[],
      );

      var calls = 0;
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: MaterialApp(
            home: Scaffold(
              body: NoteEditor(
                showProperties: false,
                onToggleProperties: () => calls++,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await _settle(tester);

      final icon = find.byKey(const ValueKey('sui-note-properties'));
      expect(icon, findsOneWidget, reason: '编辑页右上角「属性」入口（FR-74）');
      expect(find.byTooltip('属性信息'), findsOneWidget);

      await tester.tap(icon);
      await tester.pump();
      expect(calls, 1, reason: '独立窗口口径：回落到注入的窗口局部回调');
      await db.close();
    });
  });
}
