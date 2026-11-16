/// v0.22.3（B50）回归：设置中心「同步与账号」面板**必须随控制器通知重建**。
///
/// 缺陷现场：面板用 `context.read` 取控制器、`SettingsDialog` 也直接构造
/// `const SyncSettingsPanel()`，父级不监听 → 面板冻结在「打开设置那一刻」的快照：
/// 后台同步结束后仍显示「同步中…」，且「全部重新同步」永久置灰。
///
/// **纪律**：全程**禁用 `pumpAndSettle()`**，改用有界 `pump`（Agents.md §5.2）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/sync_settings_dialog.dart';

/// 可外部改状态的假控制器：只覆盖**呈现层读取的**三个只读属性，不碰网络。
class _PanelController extends AppController {
  _PanelController({required super.repository, required super.database});

  SyncState state = SyncState.syncing;
  int unsynced = 2;

  @override
  SyncState get syncState => state;

  @override
  bool get canReconcile => true;

  @override
  int get unsyncedCount => unsynced;

  /// 模拟「后台那一轮同步结束」：改状态并通知（与真实控制器 `notifyListeners` 同路径）。
  void finishSync() {
    state = SyncState.idle;
    unsynced = 0;
    notifyListeners();
  }
}

void main() {
  testWidgets('面板随控制器通知刷新：同步中… → 已连接（不再冻结快照）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final controller = _PanelController(
      repository: NoteRepository(db, deviceId: 'panel-live'),
      database: db,
    );
    await controller.bootstrap();

    await tester.binding.setSurfaceSize(const Size(700, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SyncSettingsPanel()),
          ),
        ),
      ),
    );
    // 打开时正处于同步中：状态行、计数与按钮都应是「执行中」口径。
    await tester.pump();
    expect(find.text('同步中…'), findsOneWidget);
    expect(find.text('未同步：2 项'), findsOneWidget);
    final button =
        tester.widget<FilledButton>(find.byType(FilledButton).first);
    expect(button.onPressed, isNotNull, reason: '核对未在跑时按钮必须可用');

    // 后台同步结束：控制器通知后，面板必须自己刷新（修复前这里仍是「同步中…」）。
    controller.finishSync();
    await tester.pump();

    expect(find.text('同步中…'), findsNothing);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('未同步：0 项'), findsOneWidget);

    // 再回到「同步中」也要跟着变（双向，而不是只刷新一次）。
    controller.state = SyncState.error;
    controller.notifyListeners();
    await tester.pump();
    expect(find.textContaining('同步失败'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
