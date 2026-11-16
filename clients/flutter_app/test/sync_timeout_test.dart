@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';

/// v0.22.3（B50）回归：同步 / 云端核对**不得无限停在「同步中」**。
///
/// 用一个「收下请求但永不响应」的本机 HTTP 服务端模拟半开连接（真实故障形态：
/// 服务端进程还在、端口通、但请求永远不回）。修复前 `syncNow` / `reconcileAll`
/// 的 Future 永不完成 → `syncState` 永远 `syncing`、「全部重新同步」永久置灰。
void main() {
  late HttpServer server;
  late List<HttpRequest> held;

  setUp(() async {
    held = <HttpRequest>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // 只接收、不写响应、不关连接 → 客户端永远等不到结果。
    server.listen(held.add);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// 连到一个「会挂住请求」的服务端；超时注入 400ms，让用例在秒级内跑完。
  Future<AppController> connectHanging({required String device}) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final controller = AppController(
      repository: NoteRepository(db, deviceId: device),
      database: db,
      syncTimeout: const Duration(milliseconds: 400),
      reconcileTimeout: const Duration(milliseconds: 400),
    );
    await controller.bootstrap();
    await controller.connect(
      SyncConfig(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'test-token',
      ),
      persist: false,
    );
    addTearDown(controller.disconnect);
    return controller;
  }

  test('连接时的云端核对超时：有界返回、落 error、按钮解锁', () async {
    final controller = await connectHanging(device: 'timeout-a');

    expect(held, isNotEmpty, reason: '请求应真的打到服务端并挂住');
    expect(controller.syncState, SyncState.error,
        reason: '核对超时后必须离开 syncing（否则界面永久「同步中…」）');
    expect(controller.syncError, contains('超时'));
    expect(controller.reconciling, isFalse);
    expect(controller.canReconcile, isTrue,
        reason: '超时后「全部重新同步」必须可用');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('单次同步超时：同样有界返回；自动重试在冷却期内不再发请求', () async {
    final controller = await connectHanging(device: 'timeout-b');

    // 显式触发（绕过冷却）→ 依旧挂住 → 400ms 后必须有界返回。
    await controller.syncNow(manual: true);
    expect(controller.syncState, SyncState.error);
    expect(controller.syncError, contains('同步超时'));

    // 自动触发（周期兜底 / WS / 防抖走同一入口）在冷却期内直接返回：
    // 不再把界面反复拉回「同步中」。
    final before = held.length;
    await controller.syncNow();
    expect(held.length, before, reason: '冷却期内自动同步不应再发请求');
    expect(controller.syncState, SyncState.error);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
