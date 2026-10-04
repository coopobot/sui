/// B19 / AC-137 回归：窄屏（Android 等移动端，`maxWidth < 900`）点编辑器工具栏
/// 「版本历史」**必须有可见结果**——窄屏无右侧栏可切换，改为**整页推入**同一
/// `RevisionPanel`（ui-spec §4.1/§6、requirements BR-12.3、high-level-design §7.7）。
///
/// 修复前根因：`RevisionPanel` **仅**在 `_WideLayout`（`maxWidth >= 900`）条件渲染，
/// `_NarrowLayout`（抽屉 + 堆栈）从不渲染它，`toggleRevisionPanel()` 只改状态、
/// 界面毫无变化 → 「点了没反应」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_list.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';
import 'package:sui_flutter_app/src/ui/revision_panel.dart';

/// 模拟 Android 系统返回：向 `flutter/navigation` 下发引擎在收到 back 时
/// 发送的同一条 `popRoute` 平台消息（与框架测试 `simulateSystemBack` 一致）。
Future<void> _simulateSystemBack() {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'flutter/navigation',
    const JSONMessageCodec().encodeMessage(<String, dynamic>{
      'method': 'popRoute',
    }),
    (ByteData? _) {},
  );
}

/// 在指定画布尺寸下渲染真实 [NoteShell]，并选中一篇含多个版本的笔记。
Future<AppController> _pumpShell(WidgetTester tester, Size size) async {
  final db = AppDatabase.memory();
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'narrow-shell-test'),
    database: db,
  );
  addTearDown(db.close);
  await controller.bootstrap();
  await controller.createNote(title: '历史');
  final id = controller.selectedNoteId!;
  // 再存一版，确保修订列表非空（否则面板显示「暂无历史版本」）。
  await controller.saveNote(
    id,
    title: '历史',
    content: '# 第二版\n\n正文',
    tags: const <String>[],
  );

  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: const MaterialApp(home: NoteShell()),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('窄屏：点「版本历史」整页推入修订面板（不再无反应）', (tester) async {
    final controller = await _pumpShell(tester, const Size(400, 800));

    // 初始在编辑页：修订面板尚未出现。
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(find.byType(RevisionPanel), findsNothing);

    // 点工具栏「版本历史」——这正是修复前「点了没反应」的入口。
    await tester.tap(find.byTooltip('版本历史'));
    await tester.pumpAndSettle();

    // 核心断言：修订面板可见（整页推入），状态同步为真。
    expect(controller.showRevisionPanel, isTrue);
    expect(find.byType(RevisionPanel), findsOneWidget);
    expect(find.byType(NoteEditor), findsNothing);
    // 面板自身内容渲染（表头 + 版本列表）。
    expect(find.textContaining('历史版本'), findsOneWidget);
    expect(find.byType(ListTile), findsWidgets);
  });

  testWidgets('窄屏：顶栏返回键先关面板回编辑页（不退回列表）', (tester) async {
    final controller = await _pumpShell(tester, const Size(400, 800));

    await tester.tap(find.byTooltip('版本历史'));
    await tester.pumpAndSettle();
    expect(find.byType(RevisionPanel), findsOneWidget);

    // 顶栏返回：关闭面板，回到编辑页。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(controller.showRevisionPanel, isFalse);
    expect(find.byType(RevisionPanel), findsNothing);
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(
      controller.selectedNoteId,
      isNotNull,
      reason: '返回应回到编辑页而非笔记列表',
    );
  });

  testWidgets('窄屏：系统返回键先关面板回编辑页，再按才退出编辑回列表', (tester) async {
    final controller = await _pumpShell(tester, const Size(400, 800));

    await tester.tap(find.byTooltip('版本历史'));
    await tester.pumpAndSettle();
    expect(find.byType(RevisionPanel), findsOneWidget);

    // 第一级系统返回：关面板回编辑页（修复前会直接退出应用）。
    await _simulateSystemBack();
    await tester.pumpAndSettle();
    expect(find.byType(RevisionPanel), findsNothing);
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(controller.selectedNoteId, isNotNull);

    // 第二级系统返回：退出编辑回列表。
    await _simulateSystemBack();
    await tester.pumpAndSettle();
    expect(controller.selectedNoteId, isNull);
    expect(find.byType(NoteList), findsOneWidget);
    expect(find.byType(NoteEditor), findsNothing);
  });
}
