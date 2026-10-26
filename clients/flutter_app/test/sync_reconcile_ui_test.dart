/// M12-T14：全局「全部重新同步」与换库对话框的界面接线（FR-54 / FR-55 / ui-spec §20.5 / §20.6）。
///
/// 覆盖：进度 + 取消 + 逐项结果 + 单项重试、桌面菜单栏同源命令、换库三选一各自
/// 调用正确的控制器路径。全部用**假控制器**，不依赖真实服务端（快、可复现）。
///
/// **纪律**：全程**禁用 `pumpAndSettle()`**，改用有界 `pump`（Agents.md §5.2）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/app_menu_bar.dart';
import 'package:sui_flutter_app/src/ui/desktop_commands.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';
import 'package:sui_flutter_app/src/ui/sync_settings_dialog.dart';

/// 有界推进（30 × 16ms = 480ms）。
Future<void> _settle(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 16),
  int frames = 30,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 假控制器：只记录调用与结果，不碰网络（核对补齐的真实语义由 note_core 测试覆盖）。
class _FakeSyncController extends AppController {
  _FakeSyncController({
    required super.repository,
    required super.database,
    this.pendingChange,
  });

  CloudInstanceChange? pendingChange;
  int unsynced = 3;
  ReconcileProgress progressToEmit = const ReconcileProgress(
      phase: 'upload', done: 1, total: 2, detail: '正在上传本机数据');
  ReconcileResult result =
      const ReconcileResult(downloaded: 0, uploaded: 0, issues: <SyncIssue>[]);

  /// 非空时由测试手动完成（用于观察「执行中」的进度 / 取消）。
  Completer<ReconcileResult?>? gate;

  int reconcileCalls = 0;
  bool? lastPushLocal;
  bool? lastHasUserDecision;
  CancelToken? lastCancel;
  final List<(SyncEntityKind, String)> retryCalls = <(SyncEntityKind, String)>[];
  String? retryError;

  bool? resolveUseLocal;
  int dismissCalls = 0;

  @override
  bool get canReconcile => true;

  @override
  bool get syncConfigured => true;

  @override
  int get unsyncedCount => unsynced;

  @override
  CloudInstanceChange? get pendingCloudChange => pendingChange;

  @override
  Future<ReconcileResult?> reconcileAll({
    bool pushLocal = true,
    bool hasUserDecision = false,
    void Function(ReconcileProgress progress)? onProgress,
    CancelToken? cancel,
  }) async {
    reconcileCalls++;
    lastPushLocal = pushLocal;
    lastHasUserDecision = hasUserDecision;
    lastCancel = cancel;
    onProgress?.call(progressToEmit);
    final g = gate;
    if (g != null) return g.future;
    return result;
  }

  @override
  Future<String?> retrySyncFor(SyncEntityKind kind, String id) async {
    retryCalls.add((kind, id));
    return retryError;
  }

  @override
  Future<ReconcileResult?> resolveCloudChange({required bool useLocal}) async {
    resolveUseLocal = useLocal;
    pendingChange = null;
    notifyListeners();
    return result;
  }

  @override
  void dismissCloudChange() {
    dismissCalls++;
    pendingChange = null;
    notifyListeners();
  }
}

/// 起一个带换库待决状态的 `NoteShell`（宽屏桌面形态）。
Future<_FakeSyncController> _pumpShell(
  WidgetTester tester, {
  required String? previous,
  bool cloudEmpty = false,
}) async {
  final db = AppDatabase.memory();
  addTearDown(db.close);
  final fake = _FakeSyncController(
    repository: NoteRepository(db, deviceId: 'm12t14'),
    database: db,
    pendingChange: CloudInstanceChange(
      previous: previous,
      current: 'inst-new',
      cloudEmpty: cloudEmpty,
    ),
  );
  await fake.bootstrap();

  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: fake,
      child: const MaterialApp(home: NoteShell()),
    ),
  );
  await _settle(tester);
  return fake;
}

void main() {
  testWidgets('「全部重新同步」：进度可见、可取消、结束后给出逐项结果与单项重试', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final fake = _FakeSyncController(
      repository: NoteRepository(db, deviceId: 'm12t14'),
      database: db,
    );
    await fake.bootstrap();
    fake.unsynced = 3;
    final gate = Completer<ReconcileResult?>();
    fake.gate = gate;

    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SyncReconcilePanel(controller: fake),
        ),
      ),
    ));
    await tester.pump();

    // 入口 + 未同步计数（ui-spec §20.5）。
    expect(find.text('全部重新同步'), findsOneWidget);
    expect(find.text('未同步：3 项'), findsOneWidget);

    // 执行中：进度（已核对 / 总数 + 当前项）与取消都在就地可达。
    await tester.tap(find.text('全部重新同步'));
    await tester.pump();
    await tester.pump();
    expect(fake.reconcileCalls, 1);
    expect(fake.lastPushLocal, isTrue);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('正在上传：1/2'), findsOneWidget);
    expect(find.textContaining('正在上传本机数据'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(fake.lastCancel?.isCancelled, isTrue,
        reason: '取消应把取消令牌置位（不回退已成功的项，BR-54.4）');

    // 结束：逐项结果（名称 + 状态 + 原因），失败项行内可单项重试（BR-54.5）。
    gate.complete(const ReconcileResult(
      downloaded: 2,
      uploaded: 1,
      issues: <SyncIssue>[
        SyncIssue(
            kind: SyncEntityKind.note,
            id: 'n1',
            label: '笔记A',
            state: EntitySyncState.failed,
            error: '网络中断'),
        SyncIssue(
            kind: SyncEntityKind.notebook,
            id: 'nb1',
            label: '笔记本B',
            state: EntitySyncState.localOnly),
      ],
    ));
    await _settle(tester);

    expect(find.textContaining('已完成：下行 2 项 · 上行 1 项'), findsOneWidget);
    expect(find.text('笔记A（同步失败）'), findsOneWidget);
    expect(find.text('网络中断'), findsOneWidget);
    expect(find.text('笔记本B（仅本地）'), findsOneWidget);
    expect(find.text('重试'), findsNWidgets(2));

    // 单项重试：只影响该项（BR-54.1）。
    fake.retryError = '该项仍未同步完成（当前状态：待上传）';
    await tester.tap(find.text('重试').first);
    await _settle(tester);
    expect(fake.retryCalls, <(SyncEntityKind, String)>[
      (SyncEntityKind.note, 'n1'),
    ]);
    expect(find.textContaining('该项仍未同步完成'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('菜单命令「全部重新同步」：登记在命令单一来源里，未连接时置灰（§20.5）',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'm12t14'),
      database: db,
    );
    await controller.bootstrap();

    final command = desktopCommands[DesktopCommandId.reconcileAll]!;
    expect(command.label, '全部重新同步');
    expect(controller.canReconcile, isFalse, reason: '未配置同步时无可用命令');
    expect(command.isEnabled(controller), isFalse);
  });

  testWidgets('桌面菜单栏「同步 → 全部重新同步」与设置对话框同源（同一实现）', (tester) async {
    // 平台覆盖必须在**用例体内**复位（desktop_shell_test 同口径）。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final fake = _FakeSyncController(
        repository: NoteRepository(db, deviceId: 'm12t14'),
        database: db,
      );
      await fake.bootstrap();

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: fake,
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: AppMenuBar(controller: fake)),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('同步'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final item = find.widgetWithText(MenuItemButton, '全部重新同步');
      expect(item, findsOneWidget);
      expect(tester.widget<MenuItemButton>(item).enabled, isTrue);

      await tester.tap(item);
      await _settle(tester);
      // 菜单命令打开的就是同一块面板（进度 / 结果 / 重试口径一致）。
      expect(find.byType(SyncReconcilePanel), findsOneWidget);
      expect(fake.reconcileCalls, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('换库对话框：文案 / 风险提示齐备，默认焦点在「取消」', (tester) async {
    const change = CloudInstanceChange(
      previous: 'inst-old',
      current: 'inst-new-instance',
      cloudEmpty: false,
    );
    CloudChangeChoice? picked;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                picked = await showCloudInstanceChangeDialog(context, change);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await _settle(tester);

    expect(find.text('云端数据已更换 / 重建'), findsOneWidget);
    expect(find.textContaining('不是同一个'), findsOneWidget);
    expect(find.textContaining('不会上传任何本地数据，也不会清空任何一端数据'),
        findsOneWidget);
    expect(find.textContaining('本机记录：inst-old'), findsOneWidget);
    expect(find.text('用本地数据补齐到云端'), findsOneWidget);
    expect(find.text('以云端为准（不补齐）'), findsOneWidget);
    // 「以云端为准」必须说明本地数据不删除、只降级为「仅本地」（AC-191）。
    expect(find.textContaining('不删除、不覆盖'), findsOneWidget);
    expect(find.textContaining('仅本地'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // 非破坏性默认：焦点落在「取消」，绝不以「用本地补齐」为默认动作。
    final cancelTile = tester.widget<ListTile>(
      find
          .ancestor(of: find.text('取消'), matching: find.byType(ListTile))
          .first,
    );
    expect(cancelTile.autofocus, isTrue);

    await tester.tap(find.text('以云端为准（不补齐）'));
    await _settle(tester);
    expect(picked, CloudChangeChoice.useCloud);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('换库（实例已更换）：外壳自动弹窗，「用本地数据补齐到云端」走 pushLocal',
      (tester) async {
    final fake = await _pumpShell(tester, previous: 'inst-old');
    expect(find.text('云端数据已更换 / 重建'), findsOneWidget);

    await tester.tap(find.text('用本地数据补齐到云端'));
    await _settle(tester);
    expect(fake.resolveUseLocal, isTrue);
    expect(find.text('云端数据已更换 / 重建'), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('换库（首次连接即发现云端为空）：文案切换为「云端为空而本机有数据」',
      (tester) async {
    final fake = await _pumpShell(tester, previous: null, cloudEmpty: true);
    expect(find.textContaining('云端为空，而本机已有数据'), findsOneWidget);

    await tester.tap(find.text('以云端为准（不补齐）'));
    await _settle(tester);
    expect(fake.resolveUseLocal, isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('换库：点「取消」只清待决状态，不动任何一端数据', (tester) async {
    final fake = await _pumpShell(tester, previous: 'inst-old');

    await tester.tap(find.text('取消'));
    await _settle(tester);
    expect(fake.dismissCalls, 1);
    expect(fake.resolveUseLocal, isNull);
    expect(fake.reconcileCalls, 0, reason: '取消不得触发任何核对 / 上传');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
