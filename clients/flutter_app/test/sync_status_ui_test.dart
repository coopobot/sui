/// M12-T14：逐项同步状态的界面接线（FR-53 / ui-spec §20.1~§20.4）。
///
/// 覆盖：列表行 / 树节点五态图标（含 `仅本地` 与**空笔记本**）、未配置同步的保守呈现、
/// 窄屏状态点降级、单项「立即上传 / 重试」的可用性与执行路径。
///
/// **纪律**：全程**禁用 `pumpAndSettle()`**，改用有界 `pump`（Agents.md §5.2）。
///
/// 说明：本文件用 [_ConfiguredController] 把「已连接」这一**呈现前提**注入进来
/// （`syncConfigured` 是只读计算属性），从而无需真实服务端即可观察五态区分；
/// 未连接的保守呈现另有用例单独覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/note_list.dart';
import 'package:sui_flutter_app/src/ui/notebook_tree.dart';
import 'package:sui_flutter_app/src/ui/sync_status_icon.dart';

/// 「已连接」但**不接网络**的控制器：状态图标据此区分五态，而不是一律降级为「仅本地」。
class _ConfiguredController extends AppController {
  _ConfiguredController({required super.repository, required super.database});

  @override
  bool get syncConfigured => true;
}

/// 有界推进（30 × 16ms = 480ms，远小于 30s 周期同步器）。
Future<void> _settle(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 16),
  int frames = 30,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 宿主：`ListenableBuilder` 让 controller 的通知真的重跑子树（等价外壳的 `watch`）。
Widget _host(AppController controller, Widget Function() build) {
  return MaterialApp(
    home: Scaffold(
      body: ListenableBuilder(
        listenable: controller,
        builder: (_, __) => build(),
      ),
    ),
  );
}

/// 精确到「某状态的同步图标」——避免与其它 `Icons.*` 混淆。
Finder _iconOf(EntitySyncState state) => find.byWidgetPredicate(
      (w) => w is SyncStatusIcon && w.state == state,
    );

/// 打开中的「单项同步」菜单项（`noteMenuItems` 内的同步项）。
PopupMenuItem<String> _syncMenuItemOf(WidgetTester tester) =>
    tester.widget<PopupMenuItem<String>>(
      find.byWidgetPredicate(
        (w) => w is PopupMenuItem<String> && w.value == 'sync',
      ),
    );

/// 按五态给「某笔记本 + 某笔记」同时打上状态（状态记账由 note_core 提供）。
Future<void> _applyState(
  NoteRepository repo,
  EntitySyncState state, {
  required String notebookId,
  required String noteId,
}) async {
  switch (state) {
    case EntitySyncState.synced:
      await repo.markSynced(SyncEntityKind.notebook, notebookId, serverVersion: 2);
      await repo.markSynced(SyncEntityKind.note, noteId, serverVersion: 3);
    case EntitySyncState.pending:
      await repo.markPending(SyncEntityKind.notebook, notebookId);
      await repo.markPending(SyncEntityKind.note, noteId);
    case EntitySyncState.localOnly:
      await repo.markLocalOnly(SyncEntityKind.notebook, notebookId);
      await repo.markLocalOnly(SyncEntityKind.note, noteId);
    case EntitySyncState.conflict:
      await repo.markConflict(SyncEntityKind.notebook, notebookId,
          reason: '云端与本地都改了');
      await repo.markConflict(SyncEntityKind.note, noteId,
          reason: '云端与本地都改了');
    case EntitySyncState.failed:
      await repo.markFailed(SyncEntityKind.notebook, notebookId, '网络中断');
      await repo.markFailed(SyncEntityKind.note, noteId, '网络中断');
  }
}

void main() {
  testWidgets('笔记列表行：五态状态图标齐备（含仅本地），且不挤压行尾操作菜单',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = NoteRepository(db, deviceId: 'sync-ui');
    final controller =
        _ConfiguredController(repository: repo, database: db);
    await controller.bootstrap();

    for (final state in EntitySyncState.values) {
      final nb = await repo.createNotebook(name: 'NB-${state.name}');
      final note = await repo.createNote(
        notebookId: nb.id,
        title: 'N-${state.name}',
        contentMarkdown: '正文',
      );
      await _applyState(repo, state, notebookId: nb.id, noteId: note.id);
    }
    await controller.refreshNotebooks();
    await controller.refreshNotes();

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        _host(controller, () => NoteList(controller: controller)));
    await _settle(tester);

    for (final state in EntitySyncState.values) {
      expect(_iconOf(state), findsOneWidget,
          reason: '列表行应出现「${state.label}」状态图标');
    }
    // 行尾操作（more_vert）仍在：状态图标占固定槽位，不影响其可达性（§20.2）。
    expect(find.byTooltip('笔记操作'), findsNWidgets(5));

    // 文案必须可行动：`仅本地` 点明云端没有该实体；`同步失败` 含原因与时间（BR-53.2）。
    expect(
      SyncStatusIcon.tooltipFor(
          state: EntitySyncState.localOnly, kind: SyncEntityKind.note),
      contains('云端没有该实体'),
    );
    expect(
      SyncStatusIcon.tooltipFor(
        state: EntitySyncState.failed,
        error: '网络中断',
        errorAt: DateTime(2026, 10, 9, 13, 5),
        kind: SyncEntityKind.note,
      ),
      allOf(contains('网络中断'), contains('10-09 13:05')),
    );
    // 加密笔记本未解锁：共性文案后追加一句（BR-53.5 / §20.7）。
    expect(
      SyncStatusIcon.tooltipFor(
        state: EntitySyncState.localOnly,
        kind: SyncEntityKind.notebook,
        encryptedLocked: true,
      ),
      contains('加密笔记本，未解锁'),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('笔记本树节点：五态齐备，空笔记本同样显示状态', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = NoteRepository(db, deviceId: 'sync-ui');
    final controller =
        _ConfiguredController(repository: repo, database: db);
    await controller.bootstrap();

    for (final state in EntitySyncState.values) {
      final nb = await repo.createNotebook(name: 'NB-${state.name}');
      // 空笔记本：**不建任何笔记**（AC-180：不得因「里面没有笔记」而不显示状态）。
      switch (state) {
        case EntitySyncState.synced:
          await repo.markSynced(SyncEntityKind.notebook, nb.id, serverVersion: 1);
        case EntitySyncState.pending:
          await repo.markPending(SyncEntityKind.notebook, nb.id);
        case EntitySyncState.localOnly:
          await repo.markLocalOnly(SyncEntityKind.notebook, nb.id);
        case EntitySyncState.conflict:
          await repo.markConflict(SyncEntityKind.notebook, nb.id,
              reason: '云端与本地都改了');
        case EntitySyncState.failed:
          await repo.markFailed(SyncEntityKind.notebook, nb.id, '网络中断');
      }
    }
    await controller.refreshNotebooks();
    await controller.refreshNotes();
    expect(controller.notes, isEmpty, reason: '本用例的笔记本都是空的');

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        _host(controller, () => NotebookTree(controller: controller)));
    await _settle(tester);

    for (final state in EntitySyncState.values) {
      expect(_iconOf(state), findsOneWidget,
          reason: '空笔记本节点也应出现「${state.label}」状态图标');
    }
    expect(find.byWidgetPredicate((w) => w is SyncStatusIcon), findsNWidgets(5));

    // 单项菜单项与笔记行尾菜单**同源**：可用性只看 `offersManualUpload`。
    expect(
      (syncMenuItem(EntitySyncState.pending) as PopupMenuItem<String>).enabled,
      isTrue,
    );
    expect(
      (syncMenuItem(EntitySyncState.synced) as PopupMenuItem<String>).enabled,
      isFalse,
    );
    expect(
      (syncMenuItem(EntitySyncState.conflict) as PopupMenuItem<String>).enabled,
      isFalse,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('未配置同步：本地实体呈现「仅本地」而非「已同步」（BR-53.6）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = NoteRepository(db, deviceId: 'sync-ui');
    final controller = AppController(repository: repo, database: db);
    await controller.bootstrap();

    final nb = await repo.createNotebook(name: '工作');
    final note = await repo.createNote(notebookId: nb.id, title: '看起来已同步');
    await _applyState(repo, EntitySyncState.synced,
        notebookId: nb.id, noteId: note.id);
    await controller.refreshNotebooks();
    await controller.refreshNotes();

    expect(controller.syncConfigured, isFalse);
    expect(
      displaySyncState(EntitySyncState.synced, configured: false),
      EntitySyncState.localOnly,
    );

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(
      controller,
      () => Column(
        children: [
          SizedBox(height: 400, child: NotebookTree(controller: controller)),
          Expanded(child: NoteList(controller: controller)),
        ],
      ),
    ));
    await _settle(tester);

    expect(_iconOf(EntitySyncState.synced), findsNothing,
        reason: '未配置同步时不得显示「已同步」');
    // 笔记本 + 笔记各一枚：都降级为「仅本地」。
    expect(_iconOf(EntitySyncState.localOnly), findsNWidgets(2));
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('窄屏：状态收敛为单一状态点（§20.3）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = NoteRepository(db, deviceId: 'sync-ui');
    final controller =
        _ConfiguredController(repository: repo, database: db);
    await controller.bootstrap();

    final nb = await repo.createNotebook(name: '工作');
    final note = await repo.createNote(notebookId: nb.id, title: '待上传');
    await _applyState(repo, EntitySyncState.pending,
        notebookId: nb.id, noteId: note.id);
    await controller.refreshNotebooks();
    await controller.refreshNotes();

    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        _host(controller, () => NoteList(controller: controller)));
    await _settle(tester);

    final icon = tester.widget<SyncStatusIcon>(_iconOf(EntitySyncState.pending));
    expect(icon.dotOnly, isTrue, reason: '窄屏不显示图标轮廓，只出状态点');
    expect(icon.size, lessThan(16));
    // 语义（tooltip）仍在，不因窄屏丢失。
    expect(
      SyncStatusIcon.tooltipFor(
          state: EntitySyncState.pending, kind: SyncEntityKind.note),
      contains('本机有未上传改动'),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('单项菜单项只在 offersManualUpload 为真时可用（置灰并给出理由）',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = NoteRepository(db, deviceId: 'sync-ui');
    final controller =
        _ConfiguredController(repository: repo, database: db);
    await controller.bootstrap();

    final nb = await repo.createNotebook(name: '工作');
    final note = await repo.createNote(notebookId: nb.id, title: '待上传笔记');
    await repo.markPending(SyncEntityKind.note, note.id);
    await repo.markPending(SyncEntityKind.notebook, nb.id);
    await controller.refreshNotebooks();
    await controller.refreshNotes();

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        _host(controller, () => NoteList(controller: controller)));
    await _settle(tester);

    // ① 待上传：可用；点击后走控制器并给出结果（本用例无真实连接 → 明确原因）。
    await tester.tap(find.byTooltip('笔记操作'));
    await _settle(tester);
    expect(find.text('立即上传 / 重试'), findsOneWidget);
    expect(_syncMenuItemOf(tester).enabled, isTrue);
    await tester.tap(find.text('立即上传 / 重试'));
    await _settle(tester);
    expect(find.text('尚未配置同步服务端'), findsOneWidget);

    // ② 已同步：置灰（无可上行改动）。
    await repo.markSynced(SyncEntityKind.note, note.id, serverVersion: 2);
    await controller.refreshNotes();
    await _settle(tester);
    await tester.tap(find.byTooltip('笔记操作'));
    await _settle(tester);
    expect(_syncMenuItemOf(tester).enabled, isFalse);
    expect(find.text('已同步，无可上行改动'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);

    // ③ 冲突：不直接提供上传，只给「需先解锁 / 将自动合并」的说明。
    await repo.markConflict(SyncEntityKind.note, note.id, reason: '云端与本地都改了');
    await controller.refreshNotes();
    await _settle(tester);
    await tester.tap(find.byTooltip('笔记操作'));
    await _settle(tester);
    expect(_syncMenuItemOf(tester).enabled, isFalse);
    expect(find.text('查看冲突 / 合并'), findsOneWidget);
    expect(find.textContaining('自动合并'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
