@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:note_core/note_core.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';

/// 同步链路接线验证：`AppController` 真的能连上服务端并完成 push/pull。
///
/// 这是修复「SyncClient 从未实例化」的回归测试 —— 不 mock，起真服务端进程，
/// 走「注册 → 本地建笔记 → 同步 → 另一台设备拉到」的完整路径。
void main() {
  const port = 18098;
  const serverUrl = 'http://127.0.0.1:$port';

  late Process server;
  late String dataDir;
  late String serverBin;

  setUpAll(() async {
    final repoRoot = Directory.current.parent.parent.path;
    dataDir =
        '${Directory.systemTemp.path}/sui-wiring-${DateTime.now().millisecondsSinceEpoch}';
    await Directory(dataDir).create(recursive: true);
    serverBin = '$dataDir/sui-server';

    final build = await Process.run(
      '/home/aiuser/go-sdk/go/bin/go',
      ['build', '-o', serverBin, './cmd/sui-server'],
      workingDirectory: '$repoRoot/server',
    );
    if (build.exitCode != 0) {
      fail('build server failed: ${build.stderr}\n${build.stdout}');
    }

    server = await Process.start(serverBin, const [], environment: {
      'SUI_ADDR': '127.0.0.1:$port',
      'SUI_DATA': dataDir,
    });
    // 排空子进程输出：管道无人读取时，服务端写满缓冲会阻塞在网络循环上，
    // 表现为「客户端同步完成、服务端毫无反应」（M10 排查记录）。
    server.stdout.drain<void>();
    server.stderr.drain<void>();
    await _waitUntilReady(serverUrl);
  });

  tearDownAll(() async {
    server.kill();
    await server.exitCode;
    try {
      await Directory(dataDir).delete(recursive: true);
    } catch (_) {}
  });

  test('AppController：注册连接 → 本地新建 → 同步 → 另一设备拉取到', () async {
    final dbA = AppDatabase.memory();
    final a = AppController(
      repository: NoteRepository(dbA, deviceId: 'dev-a'),
      database: dbA,
    );
    await a.bootstrap();
    expect(a.syncState, SyncState.unconfigured);
    expect(a.syncClient, isNull, reason: '未配置时不应有同步客户端');

    // 注册并连接：会实例化 SyncClient 并注入 CachedBlobStore
    final error = await a.registerAndConnect(
      baseUrl: serverUrl,
      username: 'wiring-user',
      password: 'pw',
    );
    expect(error, isNull, reason: '注册应成功，实际错误：$error');
    expect(a.syncClient, isNotNull, reason: 'SyncClient 应已实例化');
    expect(a.blobStore, isNotNull, reason: 'CachedBlobStore 应已注入');
    expect(a.syncState, SyncState.idle);
    expect(a.syncConfig.token, isNotEmpty);

    // 本地新建 → 自动入 Outbox → 立即同步推上去
    await a.createNote(title: '接线验证');
    await a.syncNow();
    expect(a.syncState, SyncState.idle, reason: '同步不应失败：${a.syncError}');

    // 第二台设备：同账号登录 → 拉到这条笔记
    final dbB = AppDatabase.memory();
    final b = AppController(
      repository: NoteRepository(dbB, deviceId: 'dev-b'),
      database: dbB,
    );
    await b.bootstrap();
    final loginError = await b.loginAndConnect(
      baseUrl: serverUrl,
      username: 'wiring-user',
      password: 'pw',
    );
    expect(loginError, isNull, reason: '登录应成功，实际错误：$loginError');
    await b.syncNow();

    final titles = b.notes.map((n) => n.note.title).toList();
    expect(titles, contains('接线验证'), reason: '第二台设备应拉到同步的笔记');
    expect(b.syncConfig.deviceId, isNot(a.syncConfig.deviceId),
        reason: '两台设备应各有独立 deviceId');

    // 断开后不再有同步客户端
    await a.disconnect();
    expect(a.syncClient, isNull);
    expect(a.syncState, SyncState.unconfigured);
    expect(a.syncConfig.deviceId, isNotEmpty, reason: 'deviceId 断开后仍保留');

    await dbA.close();
    await dbB.close();
  });
}

/// 轮询 `/healthz` 直到服务端就绪。
///
/// 原先用固定 `sleep 1.5s`：机器一忙就赶不上，表现为连接被拒的假失败。
/// 改成探活，快机器上几乎是立即返回。
Future<void> _waitUntilReady(String baseUrl,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final client = Client();
  final deadline = DateTime.now().add(timeout);
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final resp = await client.get(Uri.parse('$baseUrl/healthz'));
        if (resp.statusCode == 200) return;
      } catch (_) {
        // 还没起来（连接被拒），继续等。
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    fail('服务端 ${timeout.inSeconds}s 内未就绪：$baseUrl');
  } finally {
    client.close();
  }
}