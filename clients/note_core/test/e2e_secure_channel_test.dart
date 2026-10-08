@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T27 / FR-50：**受保护通道的跨语言端到端**（Dart 客户端 ↔ 真实 Go 服务端）。
///
/// 这是通道实现唯一还缺的验证：单元测试只能证「客户端自洽」与「封装与 Spike 向量一致」，
/// 而**握手 → 逐请求封装 → 服务端解封 → 响应加密 → 客户端解封**这条全链路，必须在真服务端上跑一次。
///
/// 覆盖：加密注册（含口令）、加密 push/pull（JSON 正文）、**二进制附件字节**走通道、
/// TOFU 指纹稳定与「指纹不符即阻断」。
void main() {
  const port = 18096;
  const serverUrl = 'http://127.0.0.1:$port';
  late Process server;
  late String dataDir;
  late String serverBin;

  setUpAll(() async {
    final repoRoot = Directory.current.parent.parent.path;
    final serverDir = '$repoRoot/server';
    dataDir =
        '${Directory.systemTemp.path}/sui-chan-e2e-${DateTime.now().millisecondsSinceEpoch}';
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
      environment: {
        'SUI_ADDR': '127.0.0.1:$port',
        'SUI_DATA': dataDir,
      },
    );
    // 排空子进程输出：管道无人读取时服务端写满缓冲会阻塞（M10 排查记录）。
    server.stdout.drain<void>();
    server.stderr.drain<void>();
    await _waitUntilReady('$serverUrl/healthz');
  });

  tearDownAll(() async {
    server.kill();
    await server.exitCode;
    try {
      await Directory(dataDir).delete(recursive: true);
    } catch (_) {}
  });

  test('通道全链路：加密注册 → 加密 push/pull → 二进制附件字节往返', () async {
    final trust = InMemoryChannelTrust();

    // 1) 加密注册（口令在线上是密文）：AuthClient 走通道感知客户端。
    final auth = AuthClient(
      httpClient: channelAwareClient(baseUrl: serverUrl, trust: trust),
    );
    final session = await auth.register(
      baseUrl: serverUrl,
      username: 'chan',
      password: 'pw',
    );
    expect(session.accessToken, isNotEmpty,
        reason: '加密请求必须被 Go 服务端正确解封并处理');
    expect(session.refreshToken, isNotEmpty);

    // TOFU：首次握手应记录指纹。
    final fp = await trust.fingerprint;
    expect(fp, isNotNull);
    expect(fp, matches(RegExp(r'^[0-9A-F]{4}(-[0-9A-F]{4}){3}$')));

    // 2) 加密 push + pull：JSON 正文双向封装 / 解封。
    final dbA = AppDatabase.memory();
    final repoA = NoteRepository(dbA, deviceId: 'chan-a');
    final syncA = SyncClient(
      repository: repoA,
      baseUrl: serverUrl,
      deviceId: 'chan-a',
      token: session.accessToken,
      httpClient: channelAwareClient(baseUrl: serverUrl, trust: trust),
    );
    final note = await repoA.createNote(
      title: '通道笔记',
      contentMarkdown: '# 经过受保护通道\n\n正文含中文与 emoji 🎯',
    );
    await syncA.enqueue(note);
    final pushed = await syncA.push();
    expect(pushed.first.accepted, isTrue);

    final dbB = AppDatabase.memory();
    final repoB = NoteRepository(dbB, deviceId: 'chan-b');
    final syncB = SyncClient(
      repository: repoB,
      baseUrl: serverUrl,
      deviceId: 'chan-b',
      token: session.accessToken,
      httpClient: channelAwareClient(baseUrl: serverUrl, trust: trust),
    );
    final pulled = await syncB.pull();
    expect(pulled, greaterThan(0));
    final onB = await repoB.getNote(note.id);
    expect(onB, isNotNull);
    expect(onB!.title, '通道笔记');
    expect(onB.contentMarkdown, contains('emoji 🎯'));

    // 3) 二进制路径：附件字节经通道往返必须逐字节一致（响应是二进制而非 JSON）。
    final raw = channelAwareClient(baseUrl: serverUrl, trust: trust)!;
    final bytes = Uint8List.fromList(
      List<int>.generate(4096, (i) => (i * 7) % 251),
    );
    final hash = sha256Hex(bytes);
    final put = await raw.put(
      Uri.parse('$serverUrl/api/v1/blobs/$hash'),
      headers: {'Authorization': 'Bearer ${session.accessToken}'},
      body: bytes,
    );
    expect(put.statusCode, 200, reason: '密文附件必须被服务端解封并落盘');
    final got = await raw.get(
      Uri.parse('$serverUrl/api/v1/blobs/$hash'),
      headers: {'Authorization': 'Bearer ${session.accessToken}'},
    );
    expect(got.statusCode, 200);
    expect(got.bodyBytes, bytes, reason: '二进制内容必须逐字节一致');

    raw.close();
    auth.close();
    syncA.close();
    syncB.close();
    await dbA.close();
    await dbB.close();
  });

  test('TOFU：本地已记录指纹与服务端不符 → 阻断（不发出任何请求）', () async {
    final wrong = InMemoryChannelTrust('AAAA-BBBB-CCCC-DDDD');
    final auth = AuthClient(
      httpClient: channelAwareClient(baseUrl: serverUrl, trust: wrong),
    );
    await expectLater(
      auth.pingInfo(serverUrl),
      throwsA(isA<ChannelTrustException>()),
      reason: '指纹变化必须阻断并提示重新核对（疑似中间人）',
    );
    auth.close();
  });

  test('两个独立客户端看到同一指纹（信任根稳定）', () async {
    final t1 = InMemoryChannelTrust();
    final t2 = InMemoryChannelTrust();
    final a1 = AuthClient(
      httpClient: channelAwareClient(baseUrl: serverUrl, trust: t1),
    );
    final a2 = AuthClient(
      httpClient: channelAwareClient(baseUrl: serverUrl, trust: t2),
    );
    await a1.pingInfo(serverUrl);
    await a2.pingInfo(serverUrl);
    expect(await t1.fingerprint, await t2.fingerprint);
    a1.close();
    a2.close();
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
