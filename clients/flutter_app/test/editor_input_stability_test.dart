@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';

/// `v0.17.2` / FR-99：编辑输入稳定性回归（保存串行、题目防抖、选区不跳文末、切换不丢字、
/// 扫描缓存与「无语法跳过」）。
void main() {
  Finder contentField() => find.byWidgetPredicate(
        (w) => w is TextField && w.controller is MarkdownEditingController,
      );
  Finder titleField() => find
      .descendant(of: find.byType(NoteEditor), matching: find.byType(TextField))
      .first;

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump();
  }

  Future<(AppController, String)> pumpEditor(
    WidgetTester tester, {
    String content = 'abcdef',
  }) async {
    final db = AppDatabase.memory();
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'v172-input'),
      database: db,
    );
    addTearDown(db.close);
    await controller.bootstrap();
    await controller.createNote(title: '标题');
    final id = controller.selectedNoteId!;
    await controller.saveNote(id, title: '标题', content: content);
    await controller.refreshNotes();
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: Scaffold(body: NoteEditor(key: ValueKey(id))),
        ),
      ),
    );
    await tester.pump();
    return (controller, id);
  }

  testWidgets('标题与正文交错的保存串行化：最终落库为最后一次字面量', (tester) async {
    final (controller, id) = await pumpEditor(tester);
    await tester.enterText(contentField(), 'v1');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(titleField(), '新标题');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(contentField(), 'v2');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(contentField(), 'v3');
    // 越过 400ms 防抖，并让真实异步落库完成。
    await tester.pump(const Duration(milliseconds: 600));
    await flush(tester);

    final note = await controller.repository.getNote(id);
    expect(note!.contentMarkdown, 'v3', reason: '旧保存不得在新内容之后回盖');
    expect(note.title, '新标题');
  });

  testWidgets('标题连续输入只写库一次（400ms 防抖）', (tester) async {
    final (controller, id) = await pumpEditor(tester);
    final before = (await controller.repository.listRevisions(id)).length;
    for (var i = 1; i <= 10; i++) {
      await tester.enterText(titleField(), '标' * i);
      await tester.pump(const Duration(milliseconds: 60));
    }
    final during = (await controller.repository.listRevisions(id)).length;
    expect(during - before, lessThanOrEqualTo(1),
        reason: '连续输入期间不应逐字写库');
    await tester.pump(const Duration(milliseconds: 600));
    await flush(tester);
    final note = await controller.repository.getNote(id);
    expect(note!.title, '标' * 10);
    final after = (await controller.repository.listRevisions(id)).length;
    expect(after - before, lessThanOrEqualTo(2));
  });

  testWidgets('选中文字后等待保存 / 列表刷新，选区不跳到文末', (tester) async {
    final (controller, _) = await pumpEditor(tester);
    final content = tester.widget<TextField>(contentField()).controller!;
    await tester.enterText(contentField(), 'abcdef ghi');
    await tester.pump();
    content.selection = const TextSelection(baseOffset: 2, extentOffset: 6);
    await tester.pump();
    // 触发 400ms 防抖保存 + 内存摘要刷新。
    await tester.pump(const Duration(milliseconds: 700));
    await flush(tester);
    expect(content.selection,
        const TextSelection(baseOffset: 2, extentOffset: 6));
    // 纯列表刷新（内容未变）也不得重绑。
    await controller.refreshNotes();
    await tester.pump();
    expect(content.selection,
        const TextSelection(baseOffset: 2, extentOffset: 6));
  });

  testWidgets('外部内容回填保留选区并按新长度钳制（不置 -1 / 不跳文末）', (tester) async {
    final (controller, id) = await pumpEditor(tester);
    final content = tester.widget<TextField>(contentField()).controller!;
    content.selection = const TextSelection(baseOffset: 2, extentOffset: 5);
    await tester.pump();
    await controller.repository.applyRemoteNoteContent(
      id,
      title: '标题',
      contentMarkdown: 'abcdefXYZ',
      version: 42,
      updatedAt: DateTime.now(),
      sourceDevice: 'other',
    );
    await controller.refreshNotes();
    await tester.pump();
    expect(content.text, 'abcdefXYZ');
    expect(content.selection,
        const TextSelection(baseOffset: 2, extentOffset: 5),
        reason: '外部回填必须保留（钳制后的）选区，而不是置为 -1');
  });

  testWidgets('切换笔记时最后 ≤400ms 的输入仍落库', (tester) async {
    final db = AppDatabase.memory();
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'v172-switch'),
      database: db,
    );
    addTearDown(db.close);
    await controller.bootstrap();
    final repo = controller.repository;
    final nb = await repo.createNotebook(name: '本');
    final first = await repo.createNote(notebookId: nb.id, title: '一');
    final second = await repo.createNote(notebookId: nb.id, title: '二');
    await controller.refreshNotebooks();
    await controller.refreshNotes();
    controller.selectNote(first.id);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: Scaffold(
            body: NoteEditor(key: ValueKey(controller.selectedNoteId)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(contentField(), '最后一段未等防抖');
    await tester.pump(const Duration(milliseconds: 100));

    // 切换 → 旧编辑器 State 销毁，dispose 必须直写。
    controller.selectNote(second.id);
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: Scaffold(
            body: NoteEditor(key: ValueKey(controller.selectedNoteId)),
          ),
        ),
      ),
    );
    await tester.pump();
    await flush(tester);
    final saved = await repo.getNote(first.id);
    expect(saved!.contentMarkdown, '最后一段未等防抖');
  });

  testWidgets('扫描缓存：同一文本只扫一次，无语法文本跳过对应扫描', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const Scaffold(body: SizedBox());
      }),
    ));
    final controller = MarkdownEditingController(text: '普通正文，没有任何语法。');
    addTearDown(controller.dispose);
    controller.styled = true;
    controller.paragraphWidth = 500;
    // 注入与真实编辑器同构的呈现单元构建器（否则对应扫描不会发生）。
    controller.formatImageBuilder =
        (context, image, {bool? block}) => const SizedBox();
    controller.formatTaskCheckboxBuilder =
        (context, {required checked, required onToggle}) => const SizedBox();
    controller.formatAttachmentLinkBuilder =
        (context, ref) => const SizedBox();
    controller.formatTableBuilder = (context, table) => const SizedBox();
    controller.formatHtmlBlockBuilder = (context, html) => const SizedBox();
    controller.formatWebClipBuilder = (context, ref) => const SizedBox();
    controller.formatLinkBuilder = (context, link) => const SizedBox();

    MarkdownEditingController.debugResetScanCounters();
    const style = TextStyle(fontSize: 15, color: Colors.black, height: 1.6);
    controller.buildTextSpan(
        context: ctx, style: style, withComposing: false);
    controller.buildTextSpan(
        context: ctx, style: style, withComposing: false);
    var stats = MarkdownEditingController.debugScanStats;
    expect(stats['markers'], 1);
    for (final key in ['fences', 'images', 'links', 'attachments', 'html',
      'webClips', 'tables']) {
      expect(stats[key], 0, reason: '无对应语法时应跳过 $key 扫描');
    }

    controller.text = '[链接](https://example.com)\n\n```\ncode\n```\n';
    MarkdownEditingController.debugResetScanCounters();
    controller.buildTextSpan(
        context: ctx, style: style, withComposing: false);
    controller.buildTextSpan(
        context: ctx, style: style, withComposing: false);
    stats = MarkdownEditingController.debugScanStats;
    expect(stats['markers'], 1);
    expect(stats['links'], 1);
    expect(stats['fences'], 1);
    expect(stats['attachments'], 0);
    expect(stats['images'], 0);
    expect(stats['tables'], 0);
  });

  testWidgets('格式模式勾选任务项不改变文字颜色', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const Scaffold(body: SizedBox());
      }),
    ));
    final controller = MarkdownEditingController(
      text: '- [x] 已完成\n- [ ] 未完成',
    );
    addTearDown(controller.dispose);
    controller.styled = true;
    const base = TextStyle(fontSize: 15, color: Colors.black, height: 1.6);
    final span = controller.buildTextSpan(
      context: ctx,
      style: base,
      withComposing: false,
    );

    Color? colorOf(String needle) {
      Color? found;
      void visit(InlineSpan span) {
        if (span is TextSpan) {
          if (span.text != null && span.text!.contains(needle)) {
            found = span.style?.color;
          }
          for (final child in span.children ?? const <InlineSpan>[]) {
            visit(child);
          }
        }
      }

      visit(span);
      return found;
    }

    expect(colorOf('已完成'), base.color,
        reason: '勾选态任务文字必须保持正文前景色，不得淡化 / 加灰');
    expect(colorOf('未完成'), base.color);
  });
}
