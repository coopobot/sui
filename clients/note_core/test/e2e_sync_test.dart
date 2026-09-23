@TestOn('vm')
import 'dart:convert';
import 'dart:io';

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
    await Future.delayed(const Duration(milliseconds: 1500));
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
}
