/// M17 / FR-96：中栏笔记列表宽度拖动的最小宽度、上限与持久化。
///
/// **纪律**：不使用 `pumpAndSettle()`（Agents.md §5.2），统一有界 `pump`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/note_list.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

const _handleKey = ValueKey('note-list-resize-handle');

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<AppController> _pumpShell(
  WidgetTester tester, {
  Size size = const Size(1200, 800),
  AppDatabase? database,
}) async {
  final db = database ?? AppDatabase.memory();
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'm17-resize-test'),
    database: db,
  );
  addTearDown(controller.dispose);
  if (database == null) {
    addTearDown(db.close);
  }
  await controller.bootstrap();

  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: const MaterialApp(home: NoteShell()),
    ),
  );
  await _settle(tester);
  return controller;
}

void main() {
  testWidgets('拖动分隔线实时改变中栏宽度，松手后写入本机偏好', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final controller = await _pumpShell(tester, database: db);
    expect(
      tester.getSize(find.byType(NoteList)).width,
      closeTo(kNoteListDefaultWidth, 1),
    );

    await tester.drag(
      find.byKey(_handleKey),
      const Offset(90, 0),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await _settle(tester);

    expect(tester.getSize(find.byType(NoteList)).width, closeTo(430, 1));
    expect(controller.noteListWidth, closeTo(430, 1));
    expect(await SettingsStore(db).get('ui.noteListWidth'), '430');

    // 同一数据库上重建 controller：启动时从 settings 恢复宽度。
    final restored = AppController(
      repository: NoteRepository(db, deviceId: 'm17-resize-test-restored'),
      database: db,
    );
    addTearDown(restored.dispose);
    await restored.bootstrap();
    expect(restored.noteListWidth, closeTo(430, 1));
  });

  testWidgets('中栏向左拖到底稳定在 270px', (tester) async {
    final controller = await _pumpShell(tester);

    await tester.drag(
      find.byKey(_handleKey),
      const Offset(-1000, 0),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await _settle(tester);

    expect(
      tester.getSize(find.byType(NoteList)).width,
      closeTo(kNoteListMinWidth, 1),
    );
    expect(controller.noteListWidth, closeTo(kNoteListMinWidth, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('1000px 窗口 + 中栏最小宽度：编辑区不出现 RenderFlex 溢出', (tester) async {
    await _pumpShell(tester, size: const Size(1000, 800));

    await tester.drag(
      find.byKey(_handleKey),
      const Offset(-1000, 0),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await _settle(tester);

    expect(
      tester.getSize(find.byType(NoteList)).width,
      closeTo(kNoteListMinWidth, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('中栏折叠时无热区，展开后恢复已保存宽度', (tester) async {
    final controller = await _pumpShell(tester);
    await controller.setNoteListWidth(410);
    await tester.pump();

    await controller.setNoteListCollapsed(true);
    await _settle(tester);
    expect(find.byKey(_handleKey), findsNothing);
    expect(find.byType(NoteList), findsNothing);

    await controller.setNoteListCollapsed(false);
    await _settle(tester);
    expect(find.byKey(_handleKey), findsOneWidget);
    expect(
      tester.getSize(find.byType(NoteList)).width,
      closeTo(410, 1),
    );
  });

  testWidgets('窄屏不渲染拖动热区', (tester) async {
    await _pumpShell(tester, size: const Size(700, 800));
    expect(find.byKey(_handleKey), findsNothing);
    expect(find.byType(NoteList), findsOneWidget);
  });
}
