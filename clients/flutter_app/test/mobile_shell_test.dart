/// M19 / FR-111\~FR-116 移动端底部导航与编辑工具坞的 widget 测试。
///
/// 画布 390 × 844（iPhone 14/15 逻辑分辨率），另测 360 × 800 与横屏 844 × 390。
/// **禁用 `pumpAndSettle()`**（周期同步定时器会静默超时，Agents.md §5.2），
/// 全部用有界 `pump` 推进。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/mobile/mobile_shell.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_list.dart';
import 'package:sui_flutter_app/src/ui/note_properties_panel.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';
import 'package:sui_flutter_app/src/ui/notebook_tree.dart';

/// 有界推进：30 × 16ms = 480ms，远小于 30s 周期同步。
Future<void> _settle(WidgetTester tester,
    {Duration step = const Duration(milliseconds: 16), int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

Future<AppController> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Future<void> Function(AppController controller)? seed,
}) async {
  final db = AppDatabase.memory();
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'mobile-shell-test'),
    database: db,
  );
  addTearDown(db.close);
  await controller.bootstrap();
  if (seed != null) await seed(controller);
  controller.selectNote(null);

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

Future<Notebook> _seedNotebookWithNotes(AppController controller) async {
  final nb = await controller.createNotebook('工作');
  await controller.createNote(notebookId: nb.id, title: '产品设计');
  final noteId = controller.selectedNoteId!;
  await controller.saveNote(noteId,
      title: '产品设计', content: '正文', tags: const ['产品设计', '阅读']);
  controller.selectNote(null);
  return nb;
}

void main() {
  testWidgets('五标签齐备、无抽屉、活动态在「笔记」', (tester) async {
    await _pump(tester);

    expect(find.byType(MobileNavBar), findsOneWidget);
    expect(find.byType(Drawer), findsNothing);
    for (final label in const ['笔记', '收件箱', '笔记本', '标签', '我的']) {
      expect(find.text(label), findsWidgets, reason: '底部导航应有「$label」');
    }
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, 0);
    expect(nav.destinations.length, 5);
    // FAB 在笔记 Tab 存在（新建笔记）。
    expect(find.byKey(const ValueKey('mobile-fab')), findsOneWidget);
  });

  testWidgets('Tab 保活：搜索词在切换「我的」后不丢', (tester) async {
    final controller = await _pump(tester);

    await tester.enterText(find.byType(TextField).first, '关键词');
    await _settle(tester);
    expect(controller.query, '关键词');

    await tester.tap(find.byKey(const ValueKey('mobile-tab-4')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-tab-0')));
    await _settle(tester);

    expect(controller.query, '关键词');
    final search = tester.widget<TextField>(find.byType(TextField).first);
    expect(search.controller?.text, '关键词');
  });

  testWidgets('笔记本 Tab：点笔记本只筛列表、不进编辑器、底栏仍高亮「笔记」',
      (tester) async {
    late Notebook nb;
    final controller = await _pump(tester, seed: (controller) async {
      nb = await _seedNotebookWithNotes(controller);
    });

    await tester.tap(find.byKey(const ValueKey('mobile-tab-2')));
    await _settle(tester);
    expect(find.text('笔记本'), findsWidgets);
    expect(find.descendant(of: find.byType(NotebookTree), matching: find.text('工作')), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(NotebookTree), matching: find.text('工作')));
    await _settle(tester);

    expect(controller.selectedNotebookId, nb.id);
    expect(controller.selectedNoteId, isNull);
    expect(find.byType(NoteEditor), findsNothing);
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, 0);
  });

  testWidgets('笔记本长按：底部操作面板项与桌面菜单同源', (tester) async {
    await _pump(tester, seed: (controller) async {
      await _seedNotebookWithNotes(controller);
    });

    await tester.tap(find.byKey(const ValueKey('mobile-tab-2')));
    await _settle(tester);
    await tester.longPress(
        find.descendant(of: find.byType(NotebookTree), matching: find.text('工作')));
    await _settle(tester);

    for (final label in const [
      '重命名',
      '新建子笔记本',
      '上移',
      '下移',
      '默认字体…',
      '设为加密笔记本',
      '删除',
      '立即上传 / 重试',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '长按面板应有「$label」');
    }
  });

  testWidgets('新建笔记本：名称空时置灰、可创建、成功后回笔记本 Tab',
      (tester) async {
    final controller = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('mobile-tab-2')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-fab')));
    await _settle(tester);

    expect(find.text('新建笔记本'), findsOneWidget);
    final create = find.byKey(const ValueKey('mobile-new-notebook-create'));
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.enterText(
        find.byKey(const ValueKey('mobile-new-notebook-name')), '项目 A');
    await _settle(tester);
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);

    // 父级选择页：默认顶层 + 加密笔记本不可选由 §38.2 单测另测，这里验证可达。
    await tester.tap(find.byKey(const ValueKey('mobile-new-notebook-parent')));
    await _settle(tester);
    expect(find.text('选择父级'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-parent-top')));
    await _settle(tester);

    await tester.tap(create);
    await _settle(tester, frames: 60);

    expect(controller.notebooks.any((n) => n.name == '项目 A'), isTrue);
    expect(find.text('已创建「项目 A」'), findsOneWidget);
  });

  testWidgets('标签多选：底部操作条 + 查看 N 篇切回笔记 Tab 并保留 chips',
      (tester) async {
    final controller = await _pump(tester, seed: (controller) async {
      await _seedNotebookWithNotes(controller);
    });

    await tester.tap(find.byKey(const ValueKey('mobile-tab-3')));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('mobile-tag-产品设计')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-tag-阅读')));
    await _settle(tester);

    expect(find.byType(MobileNavBar), findsNothing, reason: '多选时底栏被操作条替代');
    expect(find.text('已选 2 个标签'), findsOneWidget);
    expect(find.text('取交集'), findsOneWidget);
    expect(controller.notes.length, 1);

    await tester.tap(find.byKey(const ValueKey('mobile-tag-view')));
    await _settle(tester);

    expect(find.byType(MobileNavBar), findsOneWidget);
    expect(controller.selectedTagNames, containsAll(['产品设计', '阅读']));
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, 0);
  });

  testWidgets('我的：入口收口可达；归档打开独立面板', (tester) async {
    final controller = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('mobile-tab-4')));
    await _settle(tester);

    for (final label in const [
      '同步',
      '立即同步',
      '归档',
      '回收站',
      '附件缓存',
      '通用',
      '默认编辑模式',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '我的页应有「$label」');
    }
    // M19：移动端不提供导入入口（桌面端保留）。
    expect(find.text('导入文件'), findsNothing);

    await tester.tap(find.text('归档'));
    await _settle(tester);
    expect(controller.archivedView, isFalse);
    expect(find.text('搜索归档笔记…'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await _settle(tester);
    expect(find.byKey(const ValueKey('mobile-tab-4')), findsOneWidget);
  });

  testWidgets('同步「仅本地」：就地提示，不打开二级页面', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-tab-4')));
    await _settle(tester);

    await tester.tap(find.text('立即同步'));
    await _settle(tester);

    // 与顶栏云按钮同口径：同步行只做同步，不导航。
    expect(find.text('未连接服务端，请先在「账号」中连接'), findsOneWidget);
    expect(find.text('服务端地址'), findsNothing);
    expect(find.text('同步与账号'), findsNothing);
  });

  testWidgets('我的二级页：账号 / 缓存 / 外观 / 关于均可打开', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-tab-4')));
    await _settle(tester);

    // 账号：只保留服务器 / 账号 / 设备，不出现同步工具。
    await tester.tap(find.text('随手记 Sui'));
    await _settle(tester);
    expect(find.text('账号'), findsWidgets);
    expect(find.text('服务端地址'), findsOneWidget);
    expect(find.text('本机设备 ID'), findsOneWidget);
    expect(find.text('全部重新同步'), findsNothing);
    await tester.tap(find.byType(BackButton));
    await _settle(tester);

    // 回收站：清空按钮置灰。
    await tester.tap(find.text('回收站'));
    await _settle(tester);
    final clear = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '清空回收站'),
    );
    expect(clear.onPressed, isNull);
    await tester.tap(find.byType(BackButton));
    await _settle(tester);

    // 附件缓存
    await tester.tap(find.text('附件缓存'));
    await _settle(tester);
    expect(find.text('上限 (MB)'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await _settle(tester);

    // 外观（在下方，先滚动到可见）
    await tester.scrollUntilVisible(
      find.text('外观'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('外观'));
    await _settle(tester);
    expect(find.text('主题'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await _settle(tester);

    // 关于：检查更新置灰。
    await tester.scrollUntilVisible(
      find.text('关于'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('关于'));
    await _settle(tester);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('暂不可用'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await _settle(tester);
    expect(find.byKey(const ValueKey('mobile-tab-4')), findsOneWidget);
  });

  testWidgets('编辑器：一行顶栏 + 底部工具坞 + 更多面板', (tester) async {
    final controller = await _pump(tester, seed: (controller) async {
      await _seedNotebookWithNotes(controller);
    });

    // 进入笔记 Tab → 点笔记行 → 编辑页。
    await tester.tap(find.descendant(of: find.byType(NoteList), matching: find.text('产品设计')).first);
    await _settle(tester);
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(controller.selectedNoteId, isNotNull);

    // 工具坞存在，且顶部不再有格式工具栏（工具坞里的「加粗」是唯一一处）。
    expect(find.byKey(const ValueKey('mobile-dock')), findsOneWidget);
    expect(find.byTooltip('编辑模式'), findsOneWidget);
    expect(find.byIcon(Icons.format_bold), findsOneWidget);
    // 编辑页没有底部主导航（FR-116：编辑页本就没有导航）。
    expect(find.byType(MobileNavBar), findsNothing);

    // 更多面板。
    await tester.tap(find.byTooltip('更多'));
    await _settle(tester);
    for (final label in const [
      '属性信息',
      '版本历史',
      '笔记内查找',
      '标签',
      '导出 Markdown',
      '删除笔记',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '更多面板应有「$label」');
    }

    await tester.tap(find.text('属性信息'));
    await _settle(tester);
    expect(find.byType(NotePropertiesPanel), findsOneWidget);

    // 顶栏返回先关属性面板回编辑页。
    await tester.tap(find.byType(BackButton));
    await _settle(tester);
    expect(find.byType(NotePropertiesPanel), findsNothing);
    expect(find.byType(NoteEditor), findsOneWidget);
  });

  testWidgets('编辑器工具坞：键盘弹出时上移约键盘高度', (tester) async {
    await _pump(tester, seed: (controller) async {
      await _seedNotebookWithNotes(controller);
    });
    await tester.tap(find.descendant(of: find.byType(NoteList), matching: find.text('产品设计')).first);
    await _settle(tester);

    final dock = find.byKey(const ValueKey('mobile-dock'));
    final before = tester.getBottomLeft(dock).dy;

    final inset = 300 * tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: inset);
    addTearDown(tester.view.resetViewInsets);
    await _settle(tester);

    final after = tester.getBottomLeft(dock).dy;
    expect(before - after, closeTo(300, 2),
        reason: '工具坞底边应贴键盘上沿（键盘高 300）');
  });

  testWidgets('Android 重复返回事件：编辑页 → 列表，不直接退出应用', (tester) async {
    final controller = await _pump(tester, seed: (controller) async {
      await _seedNotebookWithNotes(controller);
    });
    await tester.tap(
        find.descendant(of: find.byType(NoteList), matching: find.text('产品设计')).first);
    await _settle(tester);
    expect(controller.selectedNoteId, isNotNull);

    // 捕获 SystemNavigator.pop（真正退出应用的通道）。
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    const codec = JSONMessageCodec();
    Future<void> systemBack() => tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(
      'flutter/navigation',
      codec.encodeMessage(<String, dynamic>{'method': 'popRoute'}),
      (_) {},
    );

    // Android 16 同一次手势可能派发两次 popRoute：第二次不得退出应用。
    await systemBack();
    await tester.pump(const Duration(milliseconds: 50));
    await systemBack();
    await tester.pump(const Duration(milliseconds: 50));

    expect(controller.selectedNoteId, isNull);
    expect(find.byType(NoteList), findsWidgets);
    expect(calls.where((c) => c.method == 'SystemNavigator.pop'), isEmpty);
  });

  testWidgets('收件箱 Tab：只列剪藏笔记、带角标、切回笔记恢复全部',
      (tester) async {
    final controller = await _pump(tester, seed: (controller) async {
      await controller.repository.createNote(
        title: '网页剪藏',
        sourceUrl: 'https://example.com/a',
        sourceDevice: 'clip:test',
        tags: const [kWebClipTagName],
      );
      await controller.createNote(title: '普通笔记');
      await controller.refreshNotes();
    });

    // 角标显示剪藏数量（1）。
    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isTrue);

    await tester.tap(find.byKey(const ValueKey('mobile-tab-1')));
    await _settle(tester);
    expect(controller.inboxMode, isTrue);
    expect(controller.notes.length, 1);
    expect(find.text('收件箱'), findsWidgets);
    expect(find.text('网页剪藏'), findsWidgets);
    expect(find.text('普通笔记'), findsNothing);

    // 切回笔记 Tab：恢复全部笔记（不再是收件箱）。
    await tester.tap(find.byKey(const ValueKey('mobile-tab-0')));
    await _settle(tester);
    expect(controller.inboxMode, isFalse);
    expect(controller.notes.length, 2);
  });

  testWidgets('父级选择：加密笔记本显示锁且不可选', (tester) async {
    final controller = await _pump(tester, seed: (controller) async {
      await controller.repository.createNotebook(name: '加密本', encrypted: true);
      await controller.refreshNotebooks();
    });

    await tester.tap(find.byKey(const ValueKey('mobile-tab-2')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-fab')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('mobile-new-notebook-parent')));
    await _settle(tester);

    final row = find.descendant(
      of: find.byType(ListTile),
      matching: find.text('加密本'),
    );
    expect(row, findsOneWidget);
    final tile = tester.widget<ListTile>(find.ancestor(
      of: row,
      matching: find.byType(ListTile),
    ));
    expect(tile.enabled, isFalse);
    expect(find.text('加密笔记本不能作为父级'), findsOneWidget);
    // 点选无效：仍在选择页。
    await tester.tap(row, warnIfMissed: false);
    await _settle(tester);
    expect(find.text('选择父级'), findsOneWidget);
    expect(controller.notebooks.any((n) => n.name == '加密本'), isTrue);
  });

  testWidgets('窄屏 360 × 800：五标签仍在、无溢出', (tester) async {
    await _pump(tester, size: const Size(360, 800));
    expect(find.byType(MobileNavBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横屏 844 × 390：五标签仍在、无溢出', (tester) async {
    await _pump(tester, size: const Size(844, 390));
    expect(find.byType(MobileNavBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
