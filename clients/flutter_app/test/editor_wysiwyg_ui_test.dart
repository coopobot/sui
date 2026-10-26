/// 格式模式「所见即预览」与格式单元原子化 —— UI / 渲染回归（M9 缺陷修复）
/// （editor-formatting.md §13 / BR-23.7\~BR-23.9 / BR-44.11 / AC-172\~AC-176）。
///
/// - `FormatPreviewParity`：同一正本下，**格式模式的可见文本**与「预览」模式的可见文本
///   一致（忽略空白差异），且可见文本内**不含任何 Markdown 记号**（AC-172）。
/// - `MarkerCaretWidget`：折叠光标**不停在记号内部**（自动跨到外侧边界）（AC-173）。
/// - `MarkerDeleteWidget`：删除键一次取消整处格式、内容逐字保留（AC-174）。
/// - `TableBoundaryWidget`：勾选框紧贴表格上方时删除勾选框 → **表格逐字不变、仍以表格呈现**
///   （用户反馈的缺陷 ①，AC-175）。
/// - `IndentGfmWidget`：缩进产出 GFM 合法结构（以 `package:markdown` 真实解析为基准，AC-176）。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（Agents.md §5.2），一律有界 `pump`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/format_table.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// 起一个挂了真实 `NoteShell` 的编辑器，并把 [content] 写入当前笔记（口径同 editor_m9_test）。
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

/// 正文输入框（格式模式下表格 / 单元格输入框嵌在其内部，故取 `.first`）。
Finder _contentField() => find
    .descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    )
    .first;

TextEditingController _contentValue(WidgetTester tester) =>
    tester.widget<TextField>(_contentField()).controller!;

/// span 树的**可见文本**：跳过零宽透明片段（`fontSize: 0` / 透明色），
/// 呈现单元取其**语义占位文本**（`Text` 子项；勾选框 / 图片 / 水平线等无文字单元为空串）。
String _visibleText(InlineSpan span) {
  final buf = StringBuffer();
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      final style = s.style;
      final invisible = style != null &&
          (style.fontSize == 0 || style.color == Colors.transparent);
      if (!invisible && s.text != null) buf.write(s.text);
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    } else if (s is WidgetSpan) {
      final child = s.child;
      if (child is Text && child.data != null) buf.write(child.data);
    }
  }

  walk(span);
  return buf.toString();
}

/// 去掉全部空白后的文本（两态比对口径：空行 / 缩进 / 编号后空格等版式差异不计）。
String _norm(String s) => s.replaceAll(RegExp(r'\s+'), '');

/// 预览模式渲染出的**可见文本**，按**布局顺序**遍历组件树收集（`RichText` / `SelectableText`）。
///
/// 过滤 **Unicode 私有区码元**（`U+E000`\~`U+F8FF`）：flutter_markdown 用 Material 图标字形
/// 绘制项目符号 / 勾选框，它们不是用户可见文本。
List<String> _previewTexts(WidgetTester tester) {
  final out = <String>[];
  void collect(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\uE000-\uF8FF]'), '');
    if (cleaned.isNotEmpty) out.add(cleaned);
  }

  final root = tester.element(find.byType(MarkdownPreview));
  void walk(Element e) {
    final w = e.widget;
    if (w is RichText) {
      collect(w.text.toPlainText());
    } else if (w is SelectableText) {
      collect(w.textSpan?.toPlainText() ?? '');
    }
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

void main() {
  group('FormatPreviewParity（格式模式可见文本 == 预览可见文本 / AC-172）', () {
    /// 覆盖各类记号：标题 / 列表 / 勾选框 / 有序编号 / 行内成对记号 / 引用 / 围栏 /
    /// 分割线 / 链接 / 缩进任务项 / 缩进越界（预览为代码块）。
    const cases = <String>[
      '# 标题\n\n正文',
      '- 甲\n- 乙',
      '- [ ] 甲\n- [x] 乙',
      '1. 甲\n1. 乙',
      '普通 **粗** ==高== `码` *斜* ~~删~~',
      '> 引用',
      '```\ncode\n```',
      '甲\n\n---\n\n乙',
      '[标签](https://example.com)',
      '  - [ ] 缩进任务',
      '    - [ ] 越界行（两态都应显示字面量）',
      '**未闭合的粗体',
    ];

    for (final src in cases) {
      testWidgets('src=${src.replaceAll('\n', r'\n')}', (tester) async {
        final controller = MarkdownEditingController(text: src);
        controller.styled = true;
        controller.formatImageBuilder =
            (context, image, {bool? block}) => const SizedBox.shrink();
        controller.formatAttachmentLinkBuilder =
            (context, ref) => const SizedBox.shrink();
        controller.formatTaskCheckboxBuilder =
            (context, {required checked, required onToggle}) =>
                const SizedBox.shrink();
        addTearDown(controller.dispose);

        late TextSpan span;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(builder: (context) {
              span = controller.buildTextSpan(
                context: context,
                style: const TextStyle(fontSize: 15),
                withComposing: false,
              );
              return const SizedBox.shrink();
            }),
          ),
        );

        // 偏移契约：span 树与正本逐码元等长（BR-27.1）。
        expect(span.toPlainText().length, src.length);

        final formatVisible = _norm(_visibleText(span));

        await tester.binding.setSurfaceSize(const Size(900, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: MarkdownPreview(text: src))),
        );
        await tester.pump();
        final previewVisible = _norm(_previewTexts(tester).join());

        expect(
          formatVisible,
          previewVisible,
          reason: '「格式」模式的可见文本须与「预览」一致（BR-23.7 / AC-172）',
        );
      });
    }

    testWidgets('规范文档：格式模式可见文本不含任何记号', (tester) async {
      const src = '# 标题\n\n**粗** 与 ==高== 与 `码`\n\n- 甲\n\n1. 乙\n\n> 引用\n\n---\n\n```\ncode\n```\n\n[标签](https://e.com)';
      final controller = MarkdownEditingController(text: src);
      controller.styled = true;
      controller.formatImageBuilder =
          (context, image, {bool? block}) => const SizedBox.shrink();
      controller.formatAttachmentLinkBuilder =
          (context, ref) => const SizedBox.shrink();
      controller.formatTaskCheckboxBuilder =
          (context, {required checked, required onToggle}) =>
              const SizedBox.shrink();
      addTearDown(controller.dispose);

      late TextSpan span;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 15),
              withComposing: false,
            );
            return const SizedBox.shrink();
          }),
        ),
      );
      final visible = _visibleText(span);
      for (final marker in const ['**', '__', '==', '~~', '```', '##', '](', '`']) {
        expect(visible.contains(marker), isFalse,
            reason: '格式模式不得露出记号 `$marker`：$visible');
      }
      expect(visible.contains('标题'), isTrue);
      expect(visible.contains('粗'), isTrue);
      expect(visible.contains('code'), isTrue, reason: '围栏内部的代码文本仍应显示');
    });
  });

  group('MarkerCaretWidget（光标不停在记号内部 / AC-173）', () {
    testWidgets('`**粗**` 的记号线内落点 → 自动跨到外侧边界', (tester) async {
      final controller = MarkdownEditingController(text: '**粗**')
        ..styled = true;
      addTearDown(controller.dispose);

      controller.selection = const TextSelection.collapsed(offset: 0);
      controller.selection = const TextSelection.collapsed(offset: 1);
      expect(controller.selection.extentOffset, 2,
          reason: '右向落入开记号内部 → 吸附到内容起点');

      controller.selection = const TextSelection.collapsed(offset: 5);
      controller.selection = const TextSelection.collapsed(offset: 4);
      expect(controller.selection.extentOffset, 3,
          reason: '左向落入闭记号内部 → 吸附到内容末端');

      controller.selection = const TextSelection.collapsed(offset: 2);
      expect(controller.selection.extentOffset, 2, reason: '内容侧落点不受影响');
    });

    testWidgets('`- [ ] x` 的前缀记号不可落点', (tester) async {
      final controller = MarkdownEditingController(text: '- [ ] x')
        ..styled = true;
      addTearDown(controller.dispose);

      controller.selection = const TextSelection.collapsed(offset: 0);
      controller.selection = const TextSelection.collapsed(offset: 3);
      expect(controller.selection.extentOffset, 6,
          reason: '前缀记号内部 → 吸附到内容起点（`x` 之前）');
    });
  });

  group('MarkerDeleteWidget（删除键一次取消整处格式 / AC-174）', () {
    testWidgets('真实编辑器：退格命中 `**` → 去掉整对、内容保留', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-del1', '**粗**');

      await tester.tap(_contentField());
      await tester.pump();
      final ctrl = _contentValue(tester);
      ctrl.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(ctrl.text, '粗', reason: '不得留下 `**粗` 一类残缺记号');
      await db.close();
    });

    testWidgets('真实编辑器：空前勾选框行退格 → 整块移除前缀（退出列表）', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-del2', '- [ ] ');

      await tester.tap(_contentField());
      await tester.pump();
      final ctrl = _contentValue(tester);
      ctrl.selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(ctrl.text, '');
      await db.close();
    });
  });

  group('TableBoundaryWidget（勾选框紧贴表格：表格永不打回原形 / AC-175）', () {
    const table = '| A | B |\n| --- | --- |\n| 1 | 2 |';
    const withTaskAbove = '- [ ] \n$table';

    Future<TextEditingController> pumpAndCaret(
      WidgetTester tester,
      String id,
      String src,
      int caret,
    ) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, id, src);
      addTearDown(() => db.close());
      expect(find.byType(FormatTableView), findsOneWidget);
      await tester.tap(_contentField());
      await tester.pump();
      final ctrl = _contentValue(tester);
      ctrl.selection = TextSelection.collapsed(offset: caret);
      await tester.pump();
      return ctrl;
    }

    testWidgets('退格删除紧贴表格上方的勾选框 → 只取消前缀，表格仍以表格呈现', (tester) async {
      final ctrl =
          await pumpAndCaret(tester, 'wysiwyg-tbl1', withTaskAbove, 6);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(ctrl.text, '\n$table', reason: '勾选框前缀整体移除，表格逐字不变');
      expect(find.byType(FormatTableView), findsOneWidget,
          reason: '表格仍以表格呈现（未「打回原形」）');
    });

    testWidgets('Delete 停在紧贴表格的勾选框行行尾 → 同样只取消前缀', (tester) async {
      final ctrl =
          await pumpAndCaret(tester, 'wysiwyg-tbl2', withTaskAbove, 6);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(ctrl.text, '\n$table');
      expect(find.byType(FormatTableView), findsOneWidget);
    });

    testWidgets('Delete 停在紧贴表格的**非空**勾选框行行尾 → 吞掉按键、表格不退化', (tester) async {
      const src = '- [ ] x\n$table';
      final ctrl = await pumpAndCaret(tester, 'wysiwyg-tbl3', src, 7);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(ctrl.text, src, reason: '绝不把 `- [ ] x` 并进表头行');
      expect(find.byType(FormatTableView), findsOneWidget);
    });

    testWidgets('相邻行是普通文字 → 吞掉按键，表格不退化', (tester) async {
      const src = '前文\n$table';
      final ctrl = await pumpAndCaret(tester, 'wysiwyg-tbl4', src, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(ctrl.text, src);
      expect(find.byType(FormatTableView), findsOneWidget);
    });
  });

  group('IndentGfmWidget（缩进只产出 GFM 合法结构 / AC-176）', () {
    /// 以 `package:markdown` **真实解析**为准：缩进后仍须是任务项 / 列表项，且不出现 `<pre>`。
    String indentTimes(String src, int times) {
      var text = src;
      for (var i = 0; i < times; i++) {
        text = EditorFormat.apply(FormatCommand.indent, text, 0, 0).text;
      }
      return text;
    }

    test('孤立勾选框行缩进多次：正本仍解析为任务项，绝不变缩进代码块', () {
      for (final times in [1, 2, 3]) {
        final text = indentTimes('- [ ] a', times);
        final html = md.markdownToHtml(
          text,
          extensionSet: md.ExtensionSet.gitHubFlavored,
        );
        expect(html.contains('type="checkbox"'), isTrue,
            reason: 'times=$times text=${text.replaceAll('\n', r'\n')}');
        expect(html.contains('<pre>'), isFalse, reason: 'times=$times');
      }
    });

    test('（红检对照）4 空格缩进的勾选框行在 GFM 下退化为代码块', () {
      final html = md.markdownToHtml(
        '    - [ ] a',
        extensionSet: md.ExtensionSet.gitHubFlavored,
      );
      expect(html.contains('<pre>'), isTrue);
      expect(html.contains('type="checkbox"'), isFalse,
          reason: '这正是「右缩进后预览显示字面量 [ ]」的成因');
    });

    test('有父列表项时可缩进为嵌套，且仍解析为任务项', () {
      const src = '- x\n- [ ] a';
      final text = EditorFormat.apply(FormatCommand.indent, src, 4, 4).text;
      final html = md.markdownToHtml(
        text,
        extensionSet: md.ExtensionSet.gitHubFlavored,
      );
      expect(text, '- x\n  - [ ] a');
      expect(html.contains('type="checkbox"'), isTrue);
    });

    test('缩进越界的行在格式模式下不再呈现为勾选框（两态结构判定一致）', () {
      final markers = EditorFormat.syntaxMarkers('    - [ ] a');
      expect(markers, isEmpty);
      expect(EditorFormat.isListLineAt('    - [ ] a', 0), isFalse);
    });
  });

  group('TableCellMarker（单元格内记号同样不可见 / AC-172 / §13.2 / §12.1.2）', () {
    testWidgets('纯控制器：单元格内记号等码元隐藏、内容按样式呈现', (tester) async {
      final cell = TableCellEditingController(
        text: '**粗** 与 ==高== 与 [标签](https://e.com) 与 `码`',
      );
      cell.unitBuilder = (context, text, ref,
              {required selected, required onSelect}) =>
          const SizedBox.shrink();
      addTearDown(cell.dispose);

      late TextSpan span;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            span = cell.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 14),
              withComposing: false,
            );
            return const SizedBox.shrink();
          }),
        ),
      );

      expect(span.toPlainText().length, cell.text.length,
          reason: '偏移契约：记号以等码元替身补齐（BR-27.1）');
      final visible = _visibleText(span);
      for (final marker in const ['**', '==', '](http', '`']) {
        expect(visible.contains(marker), isFalse,
            reason: '单元格内不得露出记号 `$marker`：$visible');
      }
      expect(visible.contains('粗'), isTrue);
      expect(visible.contains('标签'), isTrue);

      final styles = <TextStyle>[];
      void walk(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text != null && s.text!.isNotEmpty && s.style != null) {
            styles.add(s.style!);
          }
          for (final child in s.children ?? const <InlineSpan>[]) {
            walk(child);
          }
        }
      }

      walk(span);
      expect(styles.any((s) => s.fontWeight == FontWeight.w700), isTrue,
          reason: '加粗内容须呈现为粗体');
      expect(styles.any((s) => s.backgroundColor != null), isTrue,
          reason: '高亮内容须呈现为底色');
      expect(styles.any((s) => s.decoration == TextDecoration.underline), isTrue,
          reason: '链接只显示标签且带下划线');
    });

    testWidgets('真实编辑器：单元格内记号不可见', (tester) async {
      const src = '| **粗** ==高== | B |\n| --- | --- |\n| 1 | 2 |';
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-cell2', src);

      final cellFinder = find.byKey(const ValueKey<String>('sui-table--1-0'));
      expect(cellFinder, findsOneWidget);
      await tester.tap(cellFinder);
      await tester.pump();

      final cell = tester
          .widget<TextField>(find.descendant(
              of: cellFinder, matching: find.byType(TextField)))
          .controller! as TableCellEditingController;
      final span = cell.buildTextSpan(
        context: tester.element(cellFinder),
        style: const TextStyle(fontSize: 14),
        withComposing: false,
      );
      final visible = _visibleText(span);
      expect(visible.contains('**'), isFalse, reason: '实际编辑器同样隐藏记号：$visible');
      expect(visible.contains('=='), isFalse);
      await db.close();
    });

    testWidgets('真实编辑器：单元格内退格命中 `**` → 去掉整对、内容保留', (tester) async {
      const src = '| **粗** | B |\n| --- | --- |\n| 1 | 2 |';
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'wysiwyg-cell3', src);

      final cellFinder = find.byKey(const ValueKey<String>('sui-table--1-0'));
      await tester.tap(cellFinder);
      await tester.pump();
      final cell = tester
          .widget<TextField>(find.descendant(
              of: cellFinder, matching: find.byType(TextField)))
          .controller!;
      expect(cell.text, '**粗**');
      cell.selection = TextSelection.collapsed(offset: cell.text.length);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(cell.text, '粗',
          reason: '单元格内记号同样原子：一次去掉整对、内容逐字保留（BR-23.8）');
      await db.close();
    });
  });
}
