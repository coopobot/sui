/// M16 UI / controller 回归（v0.16.0）：
/// 关联笔记跨本跳转、笔记本折叠与搜索、收件箱标签兜底、标题回车、勾选框焦点、
/// 列表光标落行尾、网页原件两态渲染。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';
import 'package:sui_flutter_app/src/ui/notebook_tree.dart';

AppController _controller(AppDatabase db) => AppController(
      repository: NoteRepository(db, deviceId: 'm16-ui'),
      database: db,
    );

Future<AppController> _pumpShell(
  WidgetTester tester,
  AppDatabase db, {
  String content = '正文',
  String title = '标题',
}) async {
  final controller = _controller(db);
  await controller.bootstrap();
  await controller.createNote();
  await controller.saveNote(
    controller.selectedNoteId!,
    title: title,
    content: content,
    tags: const <String>[],
  );
  await tester.binding.setSurfaceSize(const Size(1400, 900));
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder _bodyField() => find
    .descendant(of: find.byType(MarkdownEditor), matching: find.byType(TextField))
    .last;

Finder _titleField() => find
    .descendant(of: find.byType(NoteEditor), matching: find.byType(TextField))
    .first;

void main() {
  testWidgets('FR-84：关联笔记跨笔记本跳转（切本 + 选中 + 清搜索）', (tester) async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'm16-nav');
    final controller = AppController(repository: repo, database: db);
    await controller.bootstrap();
    final a = await repo.createNotebook(name: 'A本');
    final b = await repo.createNotebook(name: 'B本');
    final noteA = await repo.createNote(notebookId: a.id, title: 'A笔记');
    final noteB = await repo.createNote(notebookId: b.id, title: 'B笔记');
    await controller.refreshNotebooks();
    controller.selectNotebook(a.id);
    await controller.refreshNotes();
    controller.search('A');

    expect(controller.selectedNotebookId, a.id);
    final error = await controller.navigateToNote(noteB.id);
    expect(error, isNull);
    expect(controller.selectedNotebookId, b.id,
        reason: '跳转必须先切到目标所属笔记本');
    expect(controller.selectedNoteId, noteB.id);
    expect(controller.query, isEmpty, reason: '搜索词不得遮住目标');

    // 目标为未归类（收件箱视图）。
    await repo.moveNoteToNotebook(noteB.id, null);
    await controller.refreshNotes();
    await controller.navigateToNote(noteB.id);
    expect(controller.inboxMode, isTrue);

    // 目标缺失只返回原因，不改当前视图。
    final missing = await controller.navigateToNote('missing-note');
    expect(missing, '笔记不存在或尚未同步');
    expect(noteA.id, isNotEmpty);
    await db.close();
  });

  testWidgets('FR-85：笔记本折叠 + 搜索（祖先可见 / 清空恢复）', (tester) async {
    final db = AppDatabase.memory();
    final controller = _controller(db);
    await controller.bootstrap();
    await controller.createNotebook('项目');
    final root =
        controller.notebooks.firstWhere((n) => n.name == '项目');
    await controller.createNotebook('项目A', parentId: root.id);
    await controller.createNotebook('项目B', parentId: root.id);
    await controller.createNotebook('杂项');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 600,
              child: NotebookTree(controller: controller),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('项目A'), findsOneWidget);

    // 折叠父节点 → 两个子节点隐藏。
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await _settle(tester);
    expect(find.text('项目A'), findsNothing);
    expect(find.text('项目B'), findsNothing);

    // 展开恢复。
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await _settle(tester);
    expect(find.text('项目A'), findsOneWidget);

    // 搜索「a」→ 命中项目A + 祖先项目；杂项 / 项目B 隐藏。
    await tester.enterText(
        find.byKey(const ValueKey('sui-notebook-search')), 'a');
    await _settle(tester);
    expect(find.text('项目A'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('杂项'), findsNothing);
    expect(find.text('项目B'), findsNothing);

    // 清空 → 完整树恢复。
    await tester.enterText(
        find.byKey(const ValueKey('sui-notebook-search')), '');
    await _settle(tester);
    expect(find.text('杂项'), findsOneWidget);
    await db.close();
  });

  testWidgets('FR-86：标签兜底收件箱 + 移回未归类', (tester) async {
    final db = AppDatabase.memory();
    final controller = _controller(db);
    await controller.bootstrap();
    await controller.createNotebook('归档目标');
    final nb = controller.notebooks.firstWhere((n) => n.name == '归档目标');
    await controller.createNote();
    final id = controller.selectedNoteId!;
    // 模拟「sourceUrl 丢失 / source_device 被本机改写」的老剪藏：只有标签。
    await controller.saveNote(
      id,
      title: '剪藏',
      content: '正文',
      tags: const <String>[kWebClipTagName],
    );
    await controller.moveNoteToNotebook(id, nb.id);
    controller.selectInbox();
    await controller.refreshNotes();
    expect(controller.notes.any((n) => n.note.id == id), isTrue,
        reason: '标签是收件箱兜底判据');

    await controller.moveNoteToNotebook(id, null);
    controller.selectInbox();
    await controller.refreshNotes();
    expect(controller.notes.any((n) => n.note.id == id), isTrue,
        reason: '移回未归类后必须重新出现在收件箱');
    await db.close();
  });

  testWidgets('FR-87：标题回车把焦点交给正文', (tester) async {
    final db = AppDatabase.memory();
    await _pumpShell(tester, db, title: '新笔记');
    final title = _titleField();
    await tester.tap(title);
    await tester.pump();
    await tester.enterText(title, '标题');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await _settle(tester);
    final titleWidget = tester.widget<TextField>(title);
    final bodyWidget = tester.widget<TextField>(_bodyField());
    expect(bodyWidget.focusNode?.hasFocus, isTrue,
        reason: '标题 Enter 后正文必须获得焦点');
    expect(titleWidget.controller?.text, '标题');
    await db.close();
  });

  testWidgets('FR-88/89：勾选框焦点 + 列表光标落行尾', (tester) async {
    final db = AppDatabase.memory();
    await _pumpShell(tester, db, content: '');
    final body = _bodyField();
    await tester.tap(body);
    await tester.pump();
    final ctrl = tester.widget<TextField>(body).controller!;

    // 勾选框快捷键。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);
    expect(ctrl.text, '- [ ] ');
    expect(ctrl.selection.isCollapsed, isTrue);
    expect(ctrl.selection.start, 6);
    expect(tester.widget<TextField>(body).focusNode?.hasFocus, isTrue);

    // 通过输入连接追加一个字（模拟继续键入，不做整段替换）。
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: '${ctrl.text}甲',
      selection: TextSelection.collapsed(offset: ctrl.text.length + 1),
    ));
    await _settle(tester);
    expect(ctrl.text, '- [ ] 甲', reason: '勾选框后必须能直接继续键入');

    // 清空后测无序列表：光标落行尾，键入追加。
    ctrl.text = 'a';
    ctrl.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);
    expect(ctrl.text, '- a');
    expect(ctrl.selection.isCollapsed, isTrue);
    expect(ctrl.selection.start, 3);
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: '${ctrl.text}b',
      selection: TextSelection.collapsed(offset: ctrl.text.length + 1),
    ));
    await _settle(tester);
    expect(ctrl.text, '- ab');
    await db.close();
  });

  testWidgets('FR-83：网页原件预览 / 格式两态走注入的构建器', (tester) async {
    final sha = 'a' * 64;
    final text = '[网页原件](sui://webclip/$sha)\n\n正文';
    final ctrl = MarkdownEditingController(text: text);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownEditor(
            controller: ctrl,
            mode: EditorMode.preview,
            onChanged: () {},
            webClipBuilder: (context, ref) => const Text('WEBVIEW'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('WEBVIEW'), findsOneWidget);
    expect(find.textContaining('sui://webclip/'), findsNothing,
        reason: '预览态不得露出原始引用');

    // 格式态：注入原子卡片构建器后，整行由 widget 承载。
    ctrl.formatWebClipBuilder = (context, ref) => const Text('CARD');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownEditor(
            controller: ctrl,
            mode: EditorMode.formatted,
            onChanged: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('CARD'), findsOneWidget);
  });
}
