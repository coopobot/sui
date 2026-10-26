/// M15 / FR-82 独立笔记窗口测试（ui-spec §26.6 / BR-82.1\~82.3）+ 窗口局部属性面板。
///
/// 覆盖：独立窗口**不渲染 Flutter 侧顶栏**（去掉「标题 + 同步 + 设置」那一行）；
/// 标题仍可编辑（BR-82.3）；窗口右栏「属性 ↔ 版本历史」二选一并保持**窗口局部**
/// （不影响主窗口的全局开关，ui-spec §26.6 / BR-74.5）。
///
/// **纪律**：全程**禁用 `pumpAndSettle()`**（Agents.md §5.2），改用有界 `pump`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_properties_panel.dart';
import 'package:sui_flutter_app/src/ui/note_window.dart';
import 'package:sui_flutter_app/src/ui/note_window_manager.dart';
import 'package:sui_flutter_app/src/ui/revision_panel.dart';

/// 有界推进：30 × 16ms = 480ms，远小于 30s 周期同步器（Agents.md §5.2）。
Future<void> _settle(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 本窗口的公开视图 id（独立窗口的句柄口径）。
const int _windowViewId = 77;

void main() {
  /// 建库 + 建一篇笔记 + 把 [SuiNoteWindow] 挂起来。
  Future<AppController> pumpWindow(WidgetTester tester) async {
    final db = AppDatabase.memory();
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'm15-window-test'),
      database: db,
    );
    addTearDown(() async {
      controller.dispose();
      await db.close();
    });
    await controller.bootstrap();

    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await controller.createNote();
    final noteId = controller.selectedNoteId!;
    await controller.saveNote(noteId, title: '窗口笔记', content: '窗口正文');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: SuiNoteWindow(noteId: noteId, viewId: _windowViewId),
        ),
      ),
    );
    await _settle(tester);
    return controller;
  }

  testWidgets('独立窗口不渲染 Flutter 侧顶栏，标题与正文仍可编辑（FR-82 / BR-82.1 / BR-82.3）',
      (tester) async {
    await pumpWindow(tester);

    // **核心**：没有 AppBar —— 原先「笔记标题 + 同步图标 + 设置图标」那一行已删除。
    expect(find.byType(AppBar), findsNothing);
    // 同步 / 设置入口不在独立窗口常驻（入口保留在主窗口）。
    expect(find.byTooltip('同步设置'), findsNothing);

    // 能力不丢：编辑器在，且标题（可编辑标题框）与正文都在（BR-82.3）。
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(find.text('窗口笔记'), findsWidgets);
    expect(find.text('窗口正文'), findsWidgets);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('窗口局部属性面板：按视图键开合，不影响主窗口开关（FR-74 / ui-spec §26.6）',
      (tester) async {
    final controller = await pumpWindow(tester);

    // 活动视图＝本窗口句柄（真实路径由窗口聚焦事件写入，见 SuiWindowObserver）。
    controller.setActiveViewKey(_windowViewId);
    controller.togglePropertiesPanel();
    await _settle(tester);

    expect(controller.propertiesPanelVisibleFor(_windowViewId), isTrue);
    expect(find.byType(NotePropertiesPanel), findsOneWidget);
    // 主窗口的全局开关**完全不受影响**（窗口局部状态）。
    expect(controller.showPropertiesPanel, isFalse);
    expect(controller.propertiesPanelVisibleFor(kMainViewKey), isFalse);

    // 再切一次即关闭。
    controller.togglePropertiesPanel();
    await _settle(tester);
    expect(find.byType(NotePropertiesPanel), findsNothing);
    expect(controller.showPropertiesPanel, isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('窗口右栏「属性 ↔ 版本历史」二选一，属性优先（BR-74.5）', (tester) async {
    final controller = await pumpWindow(tester);

    // 先用编辑器自带的「版本历史」入口打开历史栏（窗口局部状态）。
    await tester.tap(find.byTooltip('版本历史'));
    await _settle(tester, frames: 10);
    expect(find.byType(RevisionPanel), findsOneWidget);

    // 再开属性 → 同一槽位替换，不并列。
    controller.setPropertiesPanelVisibleFor(_windowViewId, true);
    await _settle(tester, frames: 10);
    expect(find.byType(NotePropertiesPanel), findsOneWidget);
    expect(find.byType(RevisionPanel), findsNothing);

    // 关属性 → 历史栏（仍处于打开态）重新露出。
    controller.setPropertiesPanelVisibleFor(_windowViewId, false);
    await _settle(tester, frames: 10);
    expect(find.byType(NotePropertiesPanel), findsNothing);
    expect(find.byType(RevisionPanel), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('窗口关闭后窗口局部偏好被清理，不随句柄泄漏（FR-74）', (tester) async {
    final controller = await pumpWindow(tester);
    // 真实路径：窗口打开时登记（`SuiWindowObserver` → onWindowOpened），关闭时释放。
    controller.onWindowOpened(_windowViewId);
    controller.setPropertiesPanelVisibleFor(_windowViewId, true);
    await _settle(tester, frames: 4);
    expect(controller.propertiesPanelVisibleFor(_windowViewId), isTrue);

    // 模拟窗口关闭回调（SuiWindowObserver 转发）。
    controller.onWindowClosed(_windowViewId);
    expect(controller.propertiesPanelVisibleFor(_windowViewId), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
