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

void main() {
  testWidgets('应用外壳渲染主视图（空态）', (tester) async {
    final db = AppDatabase.memory();
    final controller =
        AppController(repository: NoteRepository(db, deviceId: 'widget-test'));
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
    final controller =
        AppController(repository: NoteRepository(db, deviceId: 'widget-test'));
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
}