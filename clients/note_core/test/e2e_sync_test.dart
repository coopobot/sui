@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart';
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  const port = 18099;
  const serverUrl = 'http://127.0.0.1:$port';
  late Process server;
  late String dataDir;
  late String serverBin;

  setUpAll(() async {
    final repoRoot = Directory.current.parent.parent.path;
    final serverDir = '$repoRoot/server';
    dataDir =
        '${Directory.systemTemp.path}/sui-e2e-${DateTime.now().millisecondsSinceEpoch}';
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
    await _waitUntilReady(serverUrl);
  });

  tearDownAll(() async {
    server.kill();
    await server.exitCode;
    try {
      await Directory(dataDir).delete(recursive: true);
    } catch (_) {}
  });

  test('端到端：注册 + push + pull + 冲突合并 + 再次推送成功', () async {
    final client = Client();
    final regResp = await client.post(
      Uri.parse('$serverUrl/api/v1/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': 'alice', 'password': 'x'}),
    );
    expect(regResp.statusCode, 200);
    final token = (jsonDecode(regResp.body) as Map)['token'] as String;

    final dbA = AppDatabase.memory();
    final repoA = NoteRepository(dbA, deviceId: 'dev-a');
    final syncA = SyncClient(
      repository: repoA,
      baseUrl: serverUrl,
      deviceId: 'dev-a',
      token: token,
    );
    final note = await repoA.createNote(
      title: 'E2E 笔记',
      contentMarkdown: '# 端到端\n\n初始内容',
    );
    await syncA.enqueue(note);
    final pushA = await syncA.push();
    expect(pushA.first.accepted, isTrue);
    expect(pushA.first.appliedVersion, 1);

    final dbB = AppDatabase.memory();
    final repoB = NoteRepository(dbB, deviceId: 'dev-b');
    final syncB = SyncClient(
      repository: repoB,
      baseUrl: serverUrl,
      deviceId: 'dev-b',
      token: token,
    );
    final pulled = await syncB.pull();
    expect(pulled, greaterThanOrEqualTo(1));
    final fetched = await repoB.getNote(note.id);
    expect(fetched, isNotNull);
    expect(fetched!.title, 'E2E 笔记');

    final bUpdated = await repoB.updateNoteContent(
      note.id,
      title: 'B 改了标题',
      contentMarkdown: 'B 的正文',
    );
    await syncB.enqueue(bUpdated);
    final pushB = await syncB.push();
    expect(pushB.first.accepted, isTrue);

    final aUpdated = await repoA.updateNoteContent(
      note.id,
      title: 'A 也改了标题',
      contentMarkdown: 'A 的正文',
    );
    await syncA.enqueue(aUpdated);
    final pushAConflict = await syncA.push();
    expect(pushAConflict.first.accepted, isFalse);
    expect(pushAConflict.first.serverVersion, 2);

    final merged = await repoA.getNote(note.id);
    expect(merged!.contentMarkdown, contains('B 的正文'));
    expect(merged.contentMarkdown, contains('A 的正文'));
    expect(merged.contentMarkdown, contains('sui:conflict'));

    final pushAgain = await syncA.push();
    expect(pushAgain.first.accepted, isTrue);
    expect(pushAgain.first.appliedVersion, 3);

    syncA.close();
    syncB.close();
    client.close();
    await dbA.close();
    await dbB.close();
  });

  test('端到端：附件映射随笔记同步，字节按需下载', () async {
    final client = Client();
    final regResp = await client.post(
      Uri.parse('$serverUrl/api/v1/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': 'bob', 'password': 'x'}),
    );
    expect(regResp.statusCode, 200);
    final token = (jsonDecode(regResp.body) as Map)['token'] as String;

    // 附件字节内容寻址：hash = sha256(bytes)
    final bytes = Uint8List.fromList(utf8.encode('附件字节内容 hello'));
    final hash = sha256.convert(bytes).toString();

    // 设备 A：上传字节 → 建笔记 → 挂附件 → 推送
    final putResp = await client.put(
      Uri.parse('$serverUrl/api/v1/blobs/$hash'),
      headers: {'Authorization': 'Bearer $token'},
      body: bytes,
    );
    expect(putResp.statusCode, 200);

    final dbA = AppDatabase.memory();
    final repoA = NoteRepository(dbA, deviceId: 'dev-a');
    final syncA = SyncClient(
      repository: repoA,
      baseUrl: serverUrl,
      deviceId: 'dev-a',
      token: token,
    );
    final note = await repoA.createNote(
      title: '带附件的笔记',
      contentMarkdown: '![](sui://$hash)',
    );
    await repoA.addAttachment(
      noteId: note.id,
      filename: '说明.txt',
      mimeKind: 'text',
      byteSize: bytes.length,
      sha256: hash,
    );
    await syncA.enqueue(note);
    final pushA = await syncA.push();
    expect(pushA.first.accepted, isTrue);

    // 设备 B：拉取 → 拿到附件映射（字节尚未下载）
    final blobRoot =
        '${Directory.systemTemp.path}/sui-e2e-blobs-${DateTime.now().millisecondsSinceEpoch}';
    final dbB = AppDatabase.memory();
    final repoB = NoteRepository(dbB, deviceId: 'dev-b');
    final blobStore = CachedBlobStore(
      local: LocalBlobStore(blobRoot),
      meta: SqliteBlobCacheMeta(dbB),
    );
    final syncB = SyncClient(
      repository: repoB,
      baseUrl: serverUrl,
      deviceId: 'dev-b',
      token: token,
      blobStore: blobStore,
    );
    await syncB.pull();

    final attsB = await repoB.listAttachments(noteId: note.id);
    expect(attsB.length, 1);
    expect(attsB.first.filename, '说明.txt');
    expect(attsB.first.sha256, hash);
    expect(await blobStore.exists(hash), isFalse, reason: '映射同步不应顺带拉字节');

    // 按需下载：首次拉字节，之后命中本地缓存
    final fetched = await syncB.ensureBlob(hash);
    expect(utf8.decode(fetched), '附件字节内容 hello');
    expect(await blobStore.exists(hash), isTrue);
    expect(await blobStore.read(hash), isNotNull);

    syncA.close();
    syncB.close();
    client.close();
    await dbA.close();
    await dbB.close();
    try {
      await Directory(blobRoot).delete(recursive: true);
    } catch (_) {}
  });

  test('端到端：新设备首拉完整分组树与标签并本地落库', () async {
    final client = Client();
    final regResp = await client.post(
      Uri.parse('$serverUrl/api/v1/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': 'carol', 'password': 'x'}),
    );
    expect(regResp.statusCode, 200);
    final token = (jsonDecode(regResp.body) as Map)['token'] as String;

    // 设备 A：建两级分组 + 标签 + 归属分组的笔记，全部推送。
    final dbA = AppDatabase.memory();
    final repoA = NoteRepository(dbA, deviceId: 'dev-a');
    final syncA = SyncClient(
      repository: repoA,
      baseUrl: serverUrl,
      deviceId: 'dev-a',
      token: token,
    );
    final rootNb = await repoA.createNotebook(name: '工作');
    final childNb =
        await repoA.createNotebook(parentId: rootNb.id, name: '项目A');
    final tag = await repoA.createTag(name: '重要');
    final note = await repoA.createNote(
      title: '归属笔记',
      contentMarkdown: '# 归属\n\n在项目A下',
      notebookId: childNb.id,
      tags: ['重要'],
    );
    await syncA.enqueue(note);
    syncA.enqueueNotebook(rootNb);
    syncA.enqueueNotebook(childNb);
    syncA.enqueueTag(tag);
    final pushA = await syncA.push();
    expect(pushA.first.accepted, isTrue);

    // 设备 B：全新空库（新设备），首拉 since=0 应拿到完整分组树、标签与关联。
    final dbB = AppDatabase.memory();
    final repoB = NoteRepository(dbB, deviceId: 'dev-b');
    final syncB = SyncClient(
      repository: repoB,
      baseUrl: serverUrl,
      deviceId: 'dev-b',
      token: token,
    );
    final pulled = await syncB.pull();
    expect(pulled, greaterThanOrEqualTo(4));

    // 分组树：两级、父子关系正确。
    final tree = await repoB.listNotebooksTree();
    expect(tree.map((n) => n.name), containsAll(['工作', '项目A']));
    final rootB = await repoB.getNotebook(rootNb.id);
    final childB = await repoB.getNotebook(childNb.id);
    expect(rootB, isNotNull);
    expect(childB, isNotNull);
    expect(childB!.parentId, rootNb.id);

    // 标签落库。
    final tagsB = await repoB.listTags();
    expect(tagsB.map((t) => t.id), contains(tag.id));

    // 笔记的 notebookId 与 tagIds 关联落库。
    final noteB = await repoB.getNote(note.id);
    expect(noteB, isNotNull);
    expect(noteB!.notebookId, childNb.id);
    final noteTagsB = await repoB.tagsOfNote(note.id);
    expect(noteTagsB.map((t) => t.name), contains('重要'));

    syncA.close();
    syncB.close();
    client.close();
    await dbA.close();
    await dbB.close();
  });
}

/// 轮询 `/healthz` 直到服务端就绪。
///
/// 原先用固定 `sleep 1.5s`：机器一忙（并行编译、CI 冷启动）就赶不上，
/// 表现为连接被拒的假失败。改成探活，快机器上几乎是立即返回。
Future<void> _waitUntilReady(String baseUrl, {Duration timeout = const Duration(seconds: 20)}) async {
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
