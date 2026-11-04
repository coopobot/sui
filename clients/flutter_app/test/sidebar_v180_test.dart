/// M18 / FR-109：左栏父笔记本与叶笔记本的**名称左边界一致**（缺陷修复）。
///
/// 根因：`_NotebookNode` 的 `ListTile.leading` 按 `hasChildren ? 56 : 40` 取宽，
/// 父节点名称比叶节点右移 16px。修法：前置区定宽（`leadingWidth = 56`）。
/// 设计见 `desktop-shell.md` §14。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/notebook_tree.dart';

Future<AppController> _pumpTree(
  WidgetTester tester,
  AppDatabase db,
  NoteRepository repo, {
  Size size = const Size(420, 560),
}) async {
  final controller = AppController(repository: repo, database: db);
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
  await controller.refreshNotebooks();
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('父笔记本与叶笔记本名称左边界一致，子本按层级缩进', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = NoteRepository(db, deviceId: 'm18-align');
    final parent = await repo.createNotebook(name: '父本');
    await repo.createNotebook(name: '子本', parentId: parent.id);
    await repo.createNotebook(name: '叶本');

    await _pumpTree(tester, db, repo);

    final parentX = tester.getTopLeft(find.text('父本')).dx;
    final leafX = tester.getTopLeft(find.text('叶本')).dx;
    final childX = tester.getTopLeft(find.text('子本')).dx;

    expect(parentX, closeTo(leafX, 0.5),
        reason: '有子节点的父笔记本与叶笔记本名称必须左对齐（AC-625）');
    expect(childX - parentX, closeTo(16, 0.5),
        reason: '子笔记本只按层级左移一个固定缩进（AC-627）');
  });

  testWidgets('展开 / 折叠只换箭头图形，名称位置不变', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = NoteRepository(db, deviceId: 'm18-align-fold');
    final parent = await repo.createNotebook(name: '父本');
    await repo.createNotebook(name: '子本', parentId: parent.id);

    final controller = await _pumpTree(tester, db, repo);
    final before = tester.getTopLeft(find.text('父本')).dx;
    expect(find.text('子本'), findsOneWidget, reason: '默认展开，子节点可见');

    // 折叠：点箭头（只切换折叠，不选中）。
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pump();
    expect(controller.isNotebookCollapsed(parent.id), isTrue);
    expect(find.text('子本'), findsNothing);
    expect(tester.getTopLeft(find.text('父本')).dx, closeTo(before, 0.5),
        reason: '折叠后名称不得左右跳（AC-626）');

    // 再展开：箭头换成 chevron_right，名称位置仍不变。
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pump();
    expect(find.text('子本'), findsOneWidget);
    expect(tester.getTopLeft(find.text('父本')).dx, closeTo(before, 0.5));
  });
}
