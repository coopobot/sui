import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sui_flutter_app/src/ui/large_note_policy.dart';
import 'package:sui_flutter_app/src/ui/segmented_editor.dart';

void main() {
  group('LargeNotePolicy（大笔记分块阈值）', () {
    test('小笔记不触发', () {
      expect(
          LargeNotePolicy.shouldSegment(chars: 3000, spans: 400), isFalse);
    });

    test('同为 1 万字：稀疏不触发、密集触发', () {
      expect(LargeNotePolicy.shouldSegment(chars: 10000, spans: 120), isFalse);
      expect(LargeNotePolicy.shouldSegment(chars: 10000, spans: 900), isTrue);
    });

    test('2.5 万字普通密度触发（更早切换）', () {
      expect(LargeNotePolicy.shouldSegment(chars: 25000, spans: 900), isTrue);
    });

    test('估计值随字符与 span 单调上升', () {
      final a = LargeNotePolicy.estimateMs(chars: 10000, spans: 200);
      final b = LargeNotePolicy.estimateMs(chars: 20000, spans: 200);
      final c = LargeNotePolicy.estimateMs(chars: 10000, spans: 800);
      expect(b, greaterThan(a));
      expect(c, greaterThan(a));
    });
  });

  group('splitDocBlocks（顶层分块）', () {
    test('空行分段、列表留在同一块', () {
      const text = '第一段\n\n- 一\n- 二\n\n第三段';
      final blocks = splitDocBlocks(text);
      expect(blocks.length, 3);
      expect(blocks[0].source(text), '第一段');
      expect(blocks[1].source(text), '- 一\n- 二');
      expect(blocks[2].source(text), '第三段');
    });

    test('围栏代码块整体成块，不按空行切', () {
      const text = '前言\n\n```dart\nvar a = 1;\n\nvar b = 2;\n```\n\n结尾';
      final blocks = splitDocBlocks(text);
      final fence = blocks.where((b) => b.kind == BlockKind.fence).toList();
      expect(fence.length, 1);
      expect(fence.single.source(text).contains('var b = 2;'), isTrue);
      expect(blocks.last.source(text), '结尾');
    });

    test('表格整体成块', () {
      const text = '前言\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n结尾';
      final blocks = splitDocBlocks(text);
      final table = blocks.where((b) => b.kind == BlockKind.table).toList();
      expect(table.length, 1);
      expect(table.single.source(text).contains('| 1 | 2 |'), isTrue);
    });

    test('无空行的超长段落按 ~4000 字符上限切块', () {
      const line = '这是一行没有空行分隔的正文，用来测试块上限。';
      final text = List<String>.filled(200, line).join('\n');
      final blocks = splitDocBlocks(text);
      expect(blocks.length, greaterThan(1));
      for (final b in blocks) {
        expect(b.end - b.start, lessThan(4200));
      }
      expect(blocks.map((b) => b.source(text)).join('\n'), text);
    });

    test('逻辑单元：标题/段落/列表/引用/表格/图片/附件/分割线各自成块', () {
      const text = '# 标题\n\n正文一\n\n- 一\n- 二\n\n> 引用\n\n'
          '| a | b |\n|---|---|\n| 1 | 2 |\n\n'
          '![图](sui://abc)\n\n[附件](sui://def)\n\n---\n\n结尾';
      final blocks = splitDocBlocks(text);
      expect(blocks.map((b) => b.kind).toList(), [
        BlockKind.heading,
        BlockKind.text,
        BlockKind.list,
        BlockKind.quote,
        BlockKind.table,
        BlockKind.image,
        BlockKind.attachment,
        BlockKind.rule,
        BlockKind.text,
      ]);
      expect(blocks.map((b) => b.source(text)).toList(), [
        '# 标题',
        '正文一',
        '- 一\n- 二',
        '> 引用',
        '| a | b |\n|---|---|\n| 1 | 2 |',
        '![图](sui://abc)',
        '[附件](sui://def)',
        '---',
        '结尾',
      ]);
    });

    test('块区间连续覆盖全部非空行', () {
      const text = '# 标题\n\n正文一\n\n- 列表\n\n> 引用\n\n结束';
      final blocks = splitDocBlocks(text);
      expect(blocks.first.source(text), '# 标题');
      expect(blocks.last.source(text), '结束');
      for (final b in blocks) {
        expect(b.end, greaterThan(b.start));
        expect(b.end, lessThanOrEqualTo(text.length));
      }
    });
  });

  group('SegmentedMarkdownEditor', () {
    testWidgets('点按块进入编辑，输入写回完整正本', (tester) async {
      const text = '第一段\n\n第二段内容';
      String? latest;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SegmentedMarkdownEditor(
            text: text,
            onChanged: (t) => latest = t,
          ),
        ),
      ));

      // 点第一块 → 出现编辑框，且**不再**有「完成」按钮占一行
      await tester.tap(find.byKey(const ValueKey<String>('seg-block-0')));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('完成'), findsNothing);

      // 在块内追加文字，写回完整正本
      await tester.enterText(find.byType(TextField), '第一段改');
      await tester.pump();
      expect(latest, '第一段改\n\n第二段内容');

      // Esc 结束编辑
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('只读块可见：RichText 带前景色、有高度且含正文', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SegmentedMarkdownEditor(
            text: '第一段\n\n第二段内容',
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump();
      final texts = tester.widgetList<RichText>(find.byType(RichText)).toList();
      expect(texts, isNotEmpty);
      for (final t in texts) {
        expect(t.text.style?.color, isNotNull, reason: '只读块必须带前景色，否则透明不可见');
        expect(t.text.toPlainText().trim(), isNotEmpty);
      }
      final size =
          tester.getSize(find.byKey(const ValueKey<String>('seg-block-0')));
      expect(size.height, greaterThan(8));
    });

    testWidgets('格式工具栏写回：程序化修改当前块控制器同样提交到正本', (tester) async {
      String current = '甲\n\n乙';
      final key = GlobalKey<SegmentedMarkdownEditorState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SegmentedMarkdownEditor(
            key: key,
            text: current,
            onChanged: (t) => current = t,
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('seg-block-0')));
      await tester.pump();
      final controller = key.currentState!.activeController!;
      // 模拟工具栏指令：程序化改写块控制器（不经过 TextField.onChanged）。
      controller.value = const TextEditingValue(
        text: '**甲**',
        selection: TextSelection.collapsed(offset: 5),
      );
      await tester.pump();
      expect(current, '**甲**\n\n乙');
    });

    testWidgets('Home / End 在块内移动光标（行首 / 行尾）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SegmentedMarkdownEditor(
            text: '第一行\n第二行',
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('seg-block-0')));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      field.controller!.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(field.controller!.selection.baseOffset, 4);

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(field.controller!.selection.baseOffset, 7);
    });

    testWidgets('Ctrl+Home / Ctrl+End 跳到全文首尾单元', (tester) async {
      final key = GlobalKey<SegmentedMarkdownEditorState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SegmentedMarkdownEditor(
            key: key,
            text: '甲\n\n乙\n\n丙',
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('seg-block-1')));
      await tester.pump();
      expect(key.currentState!.activeController!.text, '乙');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(key.currentState!.activeController!.text, '甲');
      expect(key.currentState!.activeController!.selection.baseOffset, 0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(key.currentState!.activeController!.text, '丙');
      expect(key.currentState!.activeController!.selection.baseOffset, 1);
    });

    testWidgets('Ctrl+↓ / Ctrl+↑ 按单元边界跳转', (tester) async {
      final key = GlobalKey<SegmentedMarkdownEditorState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SegmentedMarkdownEditor(
            key: key,
            text: '甲\n\n乙\n\n丙',
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('seg-block-1')));
      await tester.pump();
      // 让块内 TextField 的焦点请求在帧后生效，再发按键。
      await tester.pump(const Duration(milliseconds: 100));
      key.currentState!.activeController!.selection =
          const TextSelection.collapsed(offset: 0);

      // 第一次 Ctrl+↓：到本块末尾
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(key.currentState!.activeController!.selection.baseOffset, 1);

      // 第二次 Ctrl+↓：进入下一单元（丙）行首
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(key.currentState!.activeController!.text, '丙');
      expect(key.currentState!.activeController!.selection.baseOffset, 0);

      // 已在块首 → Ctrl+↑ 进入上一单元（乙）末尾；再按一次回到乙的块首
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(key.currentState!.activeController!.text, '乙');
      expect(key.currentState!.activeController!.selection.baseOffset, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(key.currentState!.activeController!.selection.baseOffset, 0);
    });

    testWidgets('PageDown / PageUp 跨单元翻页', (tester) async {
      final key = GlobalKey<SegmentedMarkdownEditorState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SegmentedMarkdownEditor(
            key: key,
            text: '甲\n\n乙\n\n丙',
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('seg-block-0')));
      await tester.pump();
      expect(key.currentState!.activeController!.text, '甲');

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(key.currentState!.activeController!.text, '乙');

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pump();
      expect(key.currentState!.activeController!.text, '甲');
    });

    testWidgets('块级单元插入：在光标处独立成块，前后文字各自成块', (tester) async {
      String current = '前缀\n\n正文甲乙\n\n后缀';
      final key = GlobalKey<SegmentedMarkdownEditorState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SegmentedMarkdownEditor(
            key: key,
            text: current,
            onChanged: (t) => current = t,
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('seg-block-1')));
      await tester.pump();
      final controller = key.currentState!.activeController!;
      controller.value = controller.value.copyWith(
        selection: const TextSelection.collapsed(offset: 2),
      );
      await tester.pump();
      key.currentState!.insertBlockUnit('| a | b |\n|---|---|\n| 1 | 2 |');
      await tester.pump();
      expect(
        current,
        '前缀\n\n正文\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n甲乙\n\n后缀',
      );
      // 新单元成为独立的表格块
      final blocks = splitDocBlocks(current);
      expect(blocks.where((b) => b.kind == BlockKind.table).length, 1);
    });

    testWidgets('文档级撤销：退出块编辑后可跨块撤销 / 重做上一次编辑', (tester) async {
      String current = '甲\n\n乙';
      final key = GlobalKey<SegmentedMarkdownEditorState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SegmentedMarkdownEditor(
            key: key,
            text: current,
            onChanged: (t) => current = t,
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('seg-block-0')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '甲改');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(current, '甲改\n\n乙');
      expect(key.currentState!.canUndoDocument, isTrue);

      key.currentState!.undoDocument();
      await tester.pump();
      expect(current, '甲\n\n乙');
      expect(key.currentState!.canRedoDocument, isTrue);

      key.currentState!.redoDocument();
      await tester.pump();
      expect(current, '甲改\n\n乙');
    });

    testWidgets('编辑中不因父级回传文本而丢内容', (tester) async {
      const text = '甲\n\n乙';
      String current = text;
      late StateSetter setOuter;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(builder: (context, setState) {
            setOuter = setState;
            return SegmentedMarkdownEditor(
              text: current,
              onChanged: (t) {
                current = t;
                setOuter(() {});
              },
            );
          }),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('seg-block-0')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '甲丙');
      await tester.pump();
      expect(current, '甲丙\n\n乙');
      // 编辑框仍在，文本仍是刚输入的
      expect(find.byType(TextField), findsOneWidget);
    });
  });
}
