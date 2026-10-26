/// 修订历史面板回归测试（产品 AC-26/AC-27）。
///
/// 回归 BUG：进入二级版本详情后「回退卡住」。根因是详情区把
/// `MarkdownPreview`（内部为 `Markdown`，即自带滚动的 `ListView`）嵌进
/// `SingleChildScrollView`，使内部视口高度无界，触发
/// "Vertical viewport was given unbounded height" 断言，界面卡死。
/// 修复后详情使用有界高度（Expanded），由 Markdown 自行滚动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/revision_panel.dart';

void main() {
  testWidgets('进入修订详情不因无界高度卡死，且可返回列表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final db = AppDatabase.memory();
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'rev-panel-test'),
      database: db,
    );
    await controller.bootstrap();
    await controller.createNote();
    final id = controller.selectedNoteId!;
    await controller.saveNote(
      id,
      title: '标题',
      content: '# 第二版\n\n正文内容',
      tags: const <String>[],
    );
    await controller.saveNote(
      id,
      title: '标题',
      content: '# 第三版\n\n正文内容',
      tags: const <String>[],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(body: RevisionPanel(noteId: id)),
        ),
      ),
    );
    // 放行 _loadRevisions 的异步加载。
    await tester.pump();
    await tester.pump();

    // 一级：历史列表渲染出多个版本。
    expect(find.textContaining('历史版本'), findsOneWidget);
    expect(find.byType(ListTile), findsWidgets);

    // 进入二级：点非当前版本项打开详情。
    await tester.tap(find.byType(ListTile).at(1));
    await tester.pump();
    await tester.pump();

    // 核心断言：详情渲染不得抛异常（无界高度会在此抛出）。
    expect(
      tester.takeException(),
      isNull,
      reason: '进入版本详情不得因无界高度断言（回退卡住的根因）',
    );

    // 二级详情可见，且存在返回按钮。
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    // 返回一级列表。
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.textContaining('历史版本'), findsOneWidget);

    await db.close();
  });
}
