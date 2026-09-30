import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// 用 ChangeNotifierProvider 包裹 NoteShell，让测试 controller 真正被使用。
Widget buildShell(AppController controller) {
  return ChangeNotifierProvider<AppController>.value(
    value: controller,
    child: const MaterialApp(home: NoteShell()),
  );
}

AppController newController(AppDatabase db) => AppController(
      repository: NoteRepository(db, deviceId: 'widget-test'),
      database: db,
    );

void main() {
  testWidgets('应用外壳渲染主视图（空态）', (tester) async {
    final db = AppDatabase.memory();
    final controller = newController(db);
    await controller.bootstrap();

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildShell(controller));
    await tester.pumpAndSettle();

    expect(find.text('随手记 Sui'), findsOneWidget);
    expect(find.text('全部笔记'), findsWidgets);
    expect(find.text('暂无笔记'), findsOneWidget);

    await db.close();
  });

  testWidgets('新建笔记本后出现在树中', (tester) async {
    final db = AppDatabase.memory();
    final controller = newController(db);
    await controller.bootstrap();

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildShell(controller));
    await tester.pumpAndSettle();

    await controller.createNotebook('工作');
    await tester.pumpAndSettle();

    expect(find.text('工作'), findsOneWidget);

    await db.close();
  });

  testWidgets('未配置服务端时同步入口显示未连接，可打开设置对话框', (tester) async {
    final db = AppDatabase.memory();
    final controller = newController(db);
    await controller.bootstrap();

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(buildShell(controller));
    await tester.pumpAndSettle();

    expect(controller.syncState, SyncState.unconfigured);
    expect(find.byTooltip('未连接服务端 · 点击配置'), findsOneWidget);

    await tester.tap(find.byTooltip('同步设置'));
    await tester.pumpAndSettle();

    expect(find.text('同步设置'), findsOneWidget);
    expect(find.text('服务端地址'), findsOneWidget);
    expect(find.text('注册并连接'), findsOneWidget);
    expect(find.text('登录并连接'), findsOneWidget);

    await db.close();
  });

  testWidgets('配置 Token 后设备 ID 已生成并持久化', (tester) async {
    final db = AppDatabase.memory();
    final controller = newController(db);
    await controller.bootstrap();

    final cfg = await controller.settings.loadSyncConfig();
    expect(cfg.deviceId, isNotEmpty);
    expect(cfg.isConfigured, isFalse);

    await db.close();
  });

  test('BUG3 空笔记禁止保存：标题与正文皆空时不写入', () async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'widget-test');
    final controller = AppController(repository: repo, database: db);
    await controller.bootstrap();
    await controller.createNote();
    final id = controller.selectedNoteId!;
    final before = await repo.getNote(id);

    await controller.saveNote(id, title: '', content: '', tags: const []);
    final after = await repo.getNote(id);

    expect(after!.version, before!.version);
    expect(after.revisionCount, before.revisionCount);
    await db.close();
  });

  test('BUG3 空笔记禁止保存：有内容时正常保存', () async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'widget-test');
    final controller = AppController(repository: repo, database: db);
    await controller.bootstrap();
    await controller.createNote();
    final id = controller.selectedNoteId!;
    final before = await repo.getNote(id);

    await controller.saveNote(id, title: '标题', content: '', tags: const []);
    final after = await repo.getNote(id);

    // Notes.version 是服务端基线镜像，本地保存不推进（sync-protocol §3）；
    // 变更以新增修订体现。
    expect(after!.version, before!.version);
    expect(after.revisionCount, before.revisionCount + 1);
    expect(after.title, '标题');
    await db.close();
  });

  test('BUG3 旧笔记清空后仍应保存', () async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'widget-test');
    final controller = AppController(repository: repo, database: db);
    await controller.bootstrap();
    await controller.createNote();
    final id = controller.selectedNoteId!;

    await controller.saveNote(id, title: '', content: '原有内容', tags: const []);
    final withContent = await repo.getNote(id);
    expect(withContent!.contentMarkdown, '原有内容');

    await controller.saveNote(id, title: '', content: '', tags: const []);
    final cleared = await repo.getNote(id);
    expect(cleared!.contentMarkdown, '');
    // 基线镜像不随本地保存推进，但清空作为一次内容修订被记录。
    expect(cleared.version, withContent.version);
    expect(cleared.revisionCount, greaterThan(withContent.revisionCount));
    await db.close();
  });
}
