import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/notebook_tree.dart';

/// M10-T29 / FR-51 §5.1：**「设为加密笔记本」入口**门禁。
///
/// 覆盖：控制器路径（真异步，`test()`）、菜单项按加密状态显隐（普通本有 / 加密本无）、
/// 二次确认密码不一致**不落笔**、取消不改动。
///
/// **成功落笔（点「加密」真正加密）不在 widget 测试里跑**：那一步要在按钮回调里跑真实
/// Argon2id，而 `testWidgets` 的用例体处于假时钟 zone、isolate 往返不被投递（登记于
/// `Memory.md` §2 B23②）——该路径由仓储门禁（`note_core/test/encrypted_notebook_set_test.dart`）
/// 与下面的控制器用例覆盖。
void main() {
  Future<void> settle(WidgetTester tester,
      {Duration step = const Duration(milliseconds: 16), int frames = 30}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  Widget buildTree(AppController controller) =>
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(body: NotebookTree(controller: controller)),
        ),
      );

  test('控制器：设为加密成功返回 null、笔记本翻标记并保持已解锁', () async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'ctrl-set');
    final controller = AppController(repository: repo, database: db);
    final nb = await repo.createNotebook(name: '加密目标');
    final note = await repo.createNote(
        notebookId: nb.id, title: 'T', contentMarkdown: 'C');

    final err = await controller.setNotebookEncrypted(nb.id, 'lock-pw');

    expect(err, isNull, reason: '成功路径不应返回错误文案');
    expect((await repo.getNotebook(nb.id))!.encrypted, isTrue);
    expect(repo.isNotebookUnlocked(nb.id), isTrue, reason: '设为加密后应保持解锁');
    final stored = (await repo.getStoredNote(note.id))!;
    expect(stored.encrypted, isTrue);
    expect(NotebookFieldCipher.isEnvelope(stored.title), isTrue);
    await db.close();
  });

  testWidgets('菜单：普通笔记本提供「设为加密笔记本」', (tester) async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'ui-menu-plain');
    final controller = AppController(repository: repo, database: db);
    await repo.createNotebook(name: '普通本');
    await controller.refreshNotebooks();

    await tester.pumpWidget(buildTree(controller));
    await settle(tester);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await settle(tester, frames: 10);

    expect(find.text('设为加密笔记本'), findsOneWidget);
    await db.close();
  });

  testWidgets('菜单：已加密笔记本不再提供该入口（一次性动作）', (tester) async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'ui-menu-enc');
    final controller = AppController(repository: repo, database: db);
    // 夹具：手工造 crypto_meta（低参 KDF，避免每次跑真实 Argon2id）。
    final created = await tester.runAsync(() => NotebookCrypto.create(
        password: 'pw', salt: List<int>.filled(16, 7)));
    await repo.createNotebook(
        name: '加密本', encrypted: true, cryptoMeta: created!.meta.toJson());
    await controller.refreshNotebooks();

    await tester.pumpWidget(buildTree(controller));
    await settle(tester);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await settle(tester, frames: 10);

    expect(find.text('设为加密笔记本'), findsNothing);
    expect(find.text('重命名'), findsOneWidget, reason: '其它菜单项不受影响');
    await db.close();
  });

  testWidgets('对话框：两次密码不一致不落笔、取消不改动', (tester) async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'ui-dialog');
    final controller = AppController(repository: repo, database: db);
    final nb = await repo.createNotebook(name: '普通本');
    await controller.refreshNotebooks();

    await tester.pumpWidget(buildTree(controller));
    await settle(tester);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await settle(tester, frames: 30);
    await tester.tap(find.text('设为加密笔记本'));
    // 对话框路由过渡约 150ms：推进 480ms 确保标签已布局（10 帧会偶发不够）。
    await settle(tester, frames: 30);

    // 对话框：两个密码框 + 不可找回警示
    expect(find.text('锁定密码'), findsOneWidget);
    expect(find.text('再次输入锁定密码'), findsOneWidget);
    expect(find.textContaining('无法找回'), findsOneWidget);

    // 两次不一致 → 就地报错、**不落笔**
    await tester.enterText(find.byType(TextField).at(0), 'aaa');
    await tester.enterText(find.byType(TextField).at(1), 'bbb');
    await tester.tap(find.text('加密'));
    await settle(tester, frames: 10);
    expect(find.text('两次输入的锁定密码不一致'), findsOneWidget);
    expect((await repo.getNotebook(nb.id))!.encrypted, isFalse,
        reason: '不一致时绝不能落笔');
    expect(repo.isNotebookUnlocked(nb.id), isFalse);

    // 取消 → 不改动
    await tester.tap(find.text('取消'));
    await settle(tester, frames: 10);
    expect((await repo.getNotebook(nb.id))!.encrypted, isFalse);
    expect(repo.isNotebookUnlocked(nb.id), isFalse);
    await db.close();
  });
}
