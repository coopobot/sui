@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T34 / FR-51：**加密笔记本的跨端端到端**（真实 Go 服务端 + 两个独立客户端）。
///
/// 这是 FR-51 最关键的跨端语义，单测无法替代：
///   * 服务端确实**只拿到密文**（协议层面直接看线上净荷，而不是只看本地库）；
///   * **未解锁端只拿密文**（占位、无明文、无预览）；
///   * 另一端用**同一锁定密码 + 同一 `crypto_meta`** 能派生同一 `K_nb` 并解密——
///     即密钥不随同步、但两端能各自重算出来（BR-51.6）。
// 顶层常量：`_pullRaw` 等顶层辅助函数也要用（放在 `main` 内会作用域不足）。
const port = 18095;
const serverUrl = 'http://127.0.0.1:$port';

void main() {
  const nbPassword = 'nb-pass';

  late Process server;
  late String dataDir;
  late String serverBin;
  late String token;

  setUpAll(() async {
    final repoRoot = Directory.current.parent.parent.path;
    final serverDir = '$repoRoot/server';
    dataDir =
        '${Directory.systemTemp.path}/sui-enc-e2e-${DateTime.now().millisecondsSinceEpoch}';
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

    // 首启建号（同一服务端实例只允许一次注册）。
    final client = http.Client();
    try {
      final resp = await client.post(
        Uri.parse('$serverUrl/api/v1/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': 'enc', 'password': 'x'}),
      );
      if (resp.statusCode != 200) {
        fail('首启注册失败：${resp.statusCode} ${resp.body}');
      }
      token = (jsonDecode(resp.body) as Map)['access_token'] as String;
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

  test('加密笔记本跨端：线上只有密文、未解锁端只显示占位、另一端可解锁读取', () async {
    // ---- A 端：设为加密笔记本 → 解锁 → 写入明文（落库即密文）----
    final dbA = AppDatabase.memory();
    final repoA = NoteRepository(dbA, deviceId: 'enc-a');
    final syncA = SyncClient(
      repository: repoA,
      baseUrl: serverUrl,
      deviceId: 'enc-a',
      token: token,
    );
    final created = await NotebookCrypto.create(
      password: nbPassword,
      salt: List<int>.filled(16, 9),
    );
    final nb = await repoA.createNotebook(
      name: '私密',
      encrypted: true,
      cryptoMeta: created.meta.toJson(),
    );
    await repoA.unlockNotebook(nb.id, nbPassword);
    final note = await repoA.createNote(
      notebookId: nb.id,
      title: '秘密标题',
      contentMarkdown: '# 秘密正文',
    );
    syncA.enqueueNotebook(nb);
    await syncA.enqueue(note);
    final pushed = await syncA.push();
    expect(pushed.first.accepted, isTrue);

    // ---- 协议层面直接看线上净荷：服务端**只应拿到密文** ----
    final wire = await _pullRaw(token);
    final wireNote =
        (wire['notes'] as List).cast<Map<String, dynamic>>().firstWhere(
              (n) => n['id'] == note.id,
            );
    expect(wireNote['encrypted'], isTrue);
    expect(wireNote['title'], isNot(contains('秘密')));
    expect(wireNote['content'], isNot(contains('秘密')));
    expect(NotebookFieldCipher.isEnvelope(wireNote['title'] as String), isTrue,
        reason: '标题必须是自描述密文封装');
    expect(
        NotebookFieldCipher.isEnvelope(wireNote['content'] as String), isTrue);
    final wireNb = (wire['notebooks'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((n) => n['id'] == nb.id);
    expect(wireNb['encrypted'], isTrue);
    expect((wireNb['cryptoMeta'] as String).contains('salt'), isTrue);
    expect((wireNb['cryptoMeta'] as String).contains('verifier'), isTrue);
    expect(wireNb['name'], '私密', reason: '笔记本名称保持明文（便于辨认该解锁哪个）');

    // ---- B 端：全新设备拉取 → 未解锁只有占位 ----
    final dbB = AppDatabase.memory();
    final repoB = NoteRepository(dbB, deviceId: 'enc-b');
    final syncB = SyncClient(
      repository: repoB,
      baseUrl: serverUrl,
      deviceId: 'enc-b',
      token: token,
    );
    expect(await syncB.pull(), greaterThan(0));

    final onB = (await repoB.getNote(note.id))!;
    expect(onB.encrypted, isTrue);
    expect(onB.locked, isTrue, reason: '未解锁端只拿密文');
    expect(onB.title, NoteRepository.lockedPlaceholderTitle);
    expect(onB.contentMarkdown, isEmpty);
    expect(onB.title, isNot(contains('秘密')));

    // 错误密码不得解锁。
    await expectLater(
      repoB.unlockNotebook(nb.id, 'wrong'),
      throwsA(isA<NotebookUnlockException>()),
    );
    expect(repoB.isNotebookUnlocked(nb.id), isFalse);

    // ---- B 端用**同一锁定密码**解锁：两端各自派生同一 `K_nb` ----
    await repoB.unlockNotebook(nb.id, nbPassword);
    final clear = (await repoB.getNote(note.id))!;
    expect(clear.locked, isFalse);
    expect(clear.title, '秘密标题');
    expect(clear.contentMarkdown, '# 秘密正文');

    // 回锁后立刻回到占位（内存密钥被丢弃）。
    repoB.lockAllNotebooks();
    expect((await repoB.getNote(note.id))!.locked, isTrue);

    syncA.close();
    syncB.close();
    await dbA.close();
    await dbB.close();
  });
}

Future<Map<String, dynamic>> _pullRaw(String token) async {
  final client = http.Client();
  try {
    final resp = await client.get(
      Uri.parse('$serverUrl/api/v1/sync/pull?since=1970-01-01T00:00:00Z'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resp.statusCode != 200) {
      fail('pull 失败：${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
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
