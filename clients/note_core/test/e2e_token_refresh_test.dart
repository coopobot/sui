@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T34 / FR-49：**令牌过期透明刷新的端到端**。
///
/// 为什么用「垃圾访问令牌」而不是真等 30 分钟 TTL：服务端对不可用访问令牌返回
/// `invalid_token`，而 §8.5 明确允许「持有刷新令牌时对 `invalid_token` 也做**一次性刷新 + 重放**」，
/// 与 `token-expired` 走同一条代码路径。这样既验证了真实服务端的刷新链路，又不引入等待。
void main() {
  const port = 18094;
  const serverUrl = 'http://127.0.0.1:$port';
  late Process server;
  late String dataDir;
  late String serverBin;
  late AuthSession session;

  setUpAll(() async {
    final repoRoot = Directory.current.parent.parent.path;
    final serverDir = '$repoRoot/server';
    dataDir =
        '${Directory.systemTemp.path}/sui-refresh-e2e-${DateTime.now().millisecondsSinceEpoch}';
    await Directory(dataDir).create(recursive: true);
    serverBin = '$dataDir/sui-server';

    final build = await Process.run(
      '/home/aiuser/go-sdk/go/bin/go',
      ['build', '-o', serverBin, './cmd/sui-server'],
      workingDirectory: serverDir,
    );
    if (build.exitCode != 0) {
      fail('build server failed: ${build.stderr}\nstdout: ${build.stdout}');
    }
    server = await Process.start(
      serverBin,
      const [],
      environment: {'SUI_ADDR': '127.0.0.1:$port', 'SUI_DATA': dataDir},
    );
    server.stdout.drain<void>();
    server.stderr.drain<void>();
    await _waitUntilReady('$serverUrl/healthz');

    final client = http.Client();
    try {
      final reg = await client.post(
        Uri.parse('$serverUrl/api/v1/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': 'refresh', 'password': 'x'}),
      );
      if (reg.statusCode != 200) {
        fail('首启注册失败：${reg.statusCode} ${reg.body}');
      }
      // 再登录一次拿「一对完整令牌」（含刷新令牌），供刷新链路使用。
      session = await AuthClient()
          .login(baseUrl: serverUrl, username: 'refresh', password: 'x');
    } finally {
      client.close();
    }
  });

  tearDownAll(() async {
    server.kill();
    await server.exitCode;
    try {
      await Directory(dataDir).delete(recursive: true);
    } catch (_) {}
  });

  test('不可用访问令牌 + 有效刷新令牌 → 一次性刷新并重放成功', () async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'refresh-e2e');
    var refreshed = 0;
    String? newAccess;
    final sync = SyncClient(
      repository: repo,
      baseUrl: serverUrl,
      deviceId: 'refresh-e2e',
      token: 'garbage-access-token', // ← 服务端必然判 invalid_token
      refreshToken: session.refreshToken,
      onTokensRefreshed: (access, refresh) async {
        refreshed++;
        newAccess = access;
      },
    );

    // pull 内部：401 → 刷新 → **重放原请求一次** → 成功。
    final count = await sync.pull();
    expect(count, greaterThanOrEqualTo(0));
    expect(refreshed, 1, reason: '应恰好刷新一次（并发去重 / 单飞）');
    expect(newAccess, isNotNull);
    expect(sync.token, newAccess, reason: '刷新后客户端令牌应就地更新');
    expect(sync.refreshToken, isNotEmpty, reason: '刷新会轮换刷新令牌');

    // 新令牌确实可用：再拉一次不应再触发刷新。
    await sync.pull();
    expect(refreshed, 1, reason: '续用新令牌不应再次刷新');

    sync.close();
    await db.close();
  });

  test('无刷新令牌时不得空转：明确失败且不触发刷新回调', () async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'no-refresh-e2e');
    var refreshed = 0;
    final sync = SyncClient(
      repository: repo,
      baseUrl: serverUrl,
      deviceId: 'no-refresh-e2e',
      token: 'garbage-access-token',
      // refreshToken 缺省为空 → 无法透明刷新
      onTokensRefreshed: (_, __) async => refreshed++,
    );

    await expectLater(sync.pull(), throwsA(isA<HttpException>()));
    expect(refreshed, 0, reason: '没有刷新令牌就不该尝试刷新');

    sync.close();
    await db.close();
  });
}

Future<void> _waitUntilReady(String url) async {
  final client = HttpClient();
  try {
    for (var i = 0; i < 100; i++) {
      try {
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close();
        await resp.drain<void>();
        if (resp.statusCode == 200) return;
      } catch (_) {
        // 尚未就绪
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('服务端 10s 内未就绪：$url');
  } finally {
    client.close();
  }
}
