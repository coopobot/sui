@TestOn('vm')
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/appearance/app_palette.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';
import 'package:sui_flutter_app/src/ui/notebook_tree.dart';

/// `v0.17.2` / FR-101\~FR-105：左栏底部固定、数量内联恒定行高、右键菜单、默认开篇、顶栏不变色。
void main() {
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<AppController> pumpTree(
    WidgetTester tester,
    AppDatabase db, {
    Size size = const Size(420, 560),
  }) async {
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'v172-sidebar'),
      database: db,
    );
    await controller.bootstrap();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(body: NotebookTree(controller: controller)),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('左栏底部固定：全部标签 / 归档 / 回收站不在滚动容器内', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await pumpTree(tester, db);

    for (final label in ['全部标签', '归档', '回收站']) {
      expect(
          find.ancestor(
              of: find.text(label), matching: find.byType(ListView)),
          findsNothing,
          reason: '「$label」必须位于底部固定区，不能随树滚动');
    }
    // 底部顺序：全部标签 → 归档 → 回收站。
    final tagsY = tester.getTopLeft(find.text('全部标签')).dy;
    final archiveY = tester.getTopLeft(find.text('归档')).dy;
    final trashY = tester.getTopLeft(find.text('回收站')).dy;
    expect(tagsY < archiveY && archiveY < trashY, isTrue);
    expect(trashY, greaterThan(560 - 120),
        reason: '底部入口应贴着侧栏底部');
  });

  testWidgets('笔记本数量同行、无 subtitle，0 篇 / N 篇行高一致', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = NoteRepository(db, deviceId: 'v172-sidebar');
    final work = await repo.createNotebook(name: '工作');
    await repo.createNotebook(name: '空本');
    const longName = '一个名字特别特别长的笔记本名称用于验证省略号';
    await repo.createNotebook(name: longName);
    await repo.createNote(notebookId: work.id, title: '第一篇');
    final controller = await pumpTree(tester, db);
    await controller.refreshNotebooks();
    await tester.pump();

    final workTile =
        tester.widget<ListTile>(find.widgetWithText(ListTile, '工作'));
    final emptyTile =
        tester.widget<ListTile>(find.widgetWithText(ListTile, '空本'));
    expect(workTile.subtitle, isNull);
    expect(emptyTile.subtitle, isNull);
    expect(
        find.descendant(
            of: find.widgetWithText(ListTile, '工作'), matching: find.text('1')),
        findsOneWidget,
        reason: '数量应显示在名称尾部同一行');
    final workSize = tester.getSize(find.widgetWithText(ListTile, '工作'));
    final emptySize = tester.getSize(find.widgetWithText(ListTile, '空本'));
    expect(workSize.height, closeTo(emptySize.height, 0.5),
        reason: '0 篇与 N 篇的节点行高必须一致');

    final longText = tester.widget<Text>(find.text(longName));
    expect(longText.maxLines, 1);
    expect(longText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('笔记本行鼠标右键打开同源菜单，且不改变选中', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = NoteRepository(db, deviceId: 'v172-sidebar');
    await repo.createNotebook(name: '工作');
    final controller = await pumpTree(tester, db);
    await controller.refreshNotebooks();
    await tester.pump();
    expect(controller.selectedNotebookId, isNull);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('工作')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('重命名'), findsOneWidget,
        reason: '右键应弹出与「⋯」相同的菜单');
    expect(controller.selectedNotebookId, isNull,
        reason: '右键打开菜单不得改变当前选中笔记本');
  });

  testWidgets('点击笔记本默认选中并打开列表第一篇', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'v172-open'),
      database: db,
    );
    await controller.bootstrap();
    final repo = controller.repository;
    final a = await repo.createNotebook(name: 'A本');
    final b = await repo.createNotebook(name: 'B本');
    final c = await repo.createNotebook(name: 'C空本');
    final firstA = await repo.createNote(
        notebookId: a.id,
        title: 'A第一篇',
        contentMarkdown: 'A第一篇正文',
        now: DateTime(2026, 1, 1));
    final secondA = await repo.createNote(
        notebookId: a.id,
        title: 'A第二篇',
        contentMarkdown: 'A第二篇正文',
        now: DateTime(2026, 1, 2));
    final firstB = await repo.createNote(
        notebookId: b.id,
        title: 'B第一篇',
        contentMarkdown: 'B第一篇正文',
        now: DateTime(2026, 1, 3));
    await controller.refreshNotebooks();
    await controller.refreshNotes();

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: NoteShell()),
      ),
    );
    await flush(tester);

    await tester.tap(find.descendant(
        of: find.byType(NotebookTree), matching: find.text('A本')));
    await flush(tester);
    expect(controller.selectedNotebookId, a.id);
    expect(controller.selectedNoteId, secondA.id,
        reason: '默认打开当前排序下的第一篇（更新时间倒序）');
    expect(find.byType(NoteEditor), findsOneWidget);

    // 空笔记本：保持空态，不自动建笔记。
    await tester.tap(find.descendant(
        of: find.byType(NotebookTree), matching: find.text('C空本')));
    await flush(tester);
    expect(controller.selectedNotebookId, c.id);
    expect(controller.selectedNoteId, isNull);
    expect(controller.notes, isEmpty);

    // 非空笔记本：默认打开第一篇。
    await tester.tap(find.descendant(
        of: find.byType(NotebookTree), matching: find.text('B本')));
    await flush(tester);
    expect(controller.selectedNotebookId, b.id);
    expect(controller.selectedNoteId, firstB.id);
    expect(controller.notes.length, 1);

    // 快速切换：最后一次点击的目标生效。
    await tester.tap(find.descendant(
        of: find.byType(NotebookTree), matching: find.text('A本')));
    await tester.tap(find.descendant(
        of: find.byType(NotebookTree), matching: find.text('B本')));
    await flush(tester);
    expect(controller.selectedNotebookId, b.id);
    expect(controller.selectedNoteId, firstB.id);
    expect(firstA.id, isNotEmpty);
    expect(secondA.id, isNotEmpty);
  });

  test('顶栏主题：取消 scrolledUnderElevation 与 surface tint', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final theme = buildSuiTheme(brightness: brightness);
      expect(theme.appBarTheme.scrolledUnderElevation, 0,
          reason: '滚动时不得抬升 / 着色（FR-105）');
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
    }
  });
}
