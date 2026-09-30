@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';

/// 回归：编辑笔记时，push 成功后 `setNoteServerVersion` 会把 `Notes.version`
/// 回写为「服务端基线镜像」（内容不变）。此前编辑器用 `note.version !=
/// _lastVersion` 判定「外部改写」，把这种「仅版本变化」误判为内容变化并重绑
/// 输入框，导致同步窗口内刚敲入的字词被刷掉。修复后按标题 / 正文内容判定。
void main() {
  Finder contentField() => find.byWidgetPredicate(
        (w) => w is TextField && w.controller is MarkdownEditingController,
      );

  Future<AppController> pumpEditor(WidgetTester tester) async {
    final db = AppDatabase.memory();
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'dev-test'),
      database: db,
    );
    addTearDown(db.close);
    await controller.bootstrap();
    await controller.createNote(title: '标题');
    final id = controller.selectedNoteId!;
    await controller.saveNote(id, title: '标题', content: 'abc');
    await controller.refreshNotes();

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const Scaffold(body: NoteEditor()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('同步回写版本号不得冲刷在输入中的正文', (tester) async {
    final controller = await pumpEditor(tester);
    final id = controller.selectedNoteId!;

    // 用户在已保存的 "abc" 后继续输入；400ms 防抖尚未触发，库中仍是 "abc"。
    await tester.enterText(contentField(), 'abcdef');
    await tester.pump();
    expect(
      controller.notes.firstWhere((s) => s.note.id == id).note.contentMarkdown,
      'abc',
      reason: '此时库中内容仍是上一次保存的 "abc"',
    );

    // 模拟 push 回写：只改 Notes.version，不改内容。
    await controller.repository.setNoteServerVersion(id, 999);
    await controller.refreshNotes();
    await tester.pump();

    expect(
      tester.widget<TextField>(contentField()).controller!.text,
      'abcdef',
      reason: '仅版本回写不得冲刷正在输入的正文',
    );
  });

  testWidgets('真正的内容改写（远端编辑 / 恢复修订）仍会刷新正文', (tester) async {
    final controller = await pumpEditor(tester);
    final id = controller.selectedNoteId!;

    await tester.enterText(contentField(), 'abcdef');
    await tester.pump();

    await controller.repository.applyRemoteNoteContent(
      id,
      title: '标题',
      contentMarkdown: '远端内容',
      version: 42,
      updatedAt: DateTime.now(),
      sourceDevice: 'other',
    );
    await controller.refreshNotes();
    await tester.pump();

    expect(
      tester.widget<TextField>(contentField()).controller!.text,
      '远端内容',
      reason: '底层内容确实变化时应刷新输入框',
    );
  });
}
