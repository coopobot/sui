import 'dart:convert';

import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

Response jsonResponse(int status, Object body) {
  final bytes = utf8.encode(jsonEncode(body));
  return Response.bytes(
    bytes,
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('SyncClient', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.memory();
      repo = NoteRepository(db, deviceId: 'test-device');
    });

    tearDown(() => db.close());

    SyncClient newClient(MockClientHandler handler) => SyncClient(
          repository: repo,
          baseUrl: 'http://test',
          deviceId: 'test-device',
          token: 'tok',
          httpClient: MockClient(handler),
        );

    test('push 成功：出队', () async {
      final note = await repo.createNote(title: 'A', contentMarkdown: '# A');
      final syncer = newClient((req) async {
        expect(req.url.path, '/api/v1/sync/push');
        expect(req.headers['authorization'], 'Bearer tok');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final items = (body['items'] as List).cast<Map<String, dynamic>>();
        expect(items.length, 1);
        expect(items.first['id'], note.id);
        expect(items.first['baseVersion'], 0);
        return jsonResponse(200, {
          'ok': true,
          'results': [
            {'id': note.id, 'accepted': true, 'appliedVersion': 1}
          ]
        });
      });

      await syncer.enqueue(note);
      expect(syncer.outboxLength, 1);
      final results = await syncer.push();
      expect(results.length, 1);
      expect(results.first.accepted, isTrue);
      expect(syncer.outboxLength, 0);
      syncer.close();
    });

    test('push 冲突 → 本地合并 + 重新入队（base 刷新为服务端版本）', () async {
      final note =
          await repo.createNote(title: '本地标题', contentMarkdown: '本地正文');
      int pushCalls = 0;
      int pullCalls = 0;
      final syncer = newClient((req) async {
        if (req.method == 'POST' && req.url.path == '/api/v1/sync/push') {
          pushCalls++;
          return jsonResponse(200, {
            'ok': true,
            'results': [
              {
                'id': note.id,
                'accepted': false,
                'serverVersion': 2,
                'appliedVersion': 0,
              }
            ]
          });
        }
        if (req.method == 'GET' && req.url.path == '/api/v1/sync/pull') {
          pullCalls++;
          return jsonResponse(200, {
            'ok': true,
            'notes': [
              {
                'id': note.id,
                'title': '远端标题',
                'content': '远端正文',
                'version': 2,
                'isDeleted': false,
                'updatedAt': '2026-09-23T00:00:00Z',
              }
            ]
          });
        }
        return Response('not found', 404);
      });

      await syncer.enqueue(note);
      final results = await syncer.push();

      expect(pushCalls, 1);
      expect(pullCalls, greaterThanOrEqualTo(1));
      expect(results.first.accepted, isFalse);
      expect(syncer.outboxLength, 1);
      final merged = await repo.getNote(note.id);
      expect(merged!.contentMarkdown, contains('远端正文'));
      expect(merged.contentMarkdown, contains('本地正文'));
      expect(merged.contentMarkdown, contains('sui:conflict'));

      syncer.close();
    });

    test('pull 新笔记落库', () async {
      final syncer = newClient((req) async {
        expect(req.url.queryParameters['since'], isNotEmpty);
        return jsonResponse(200, {
          'ok': true,
          'notes': [
            {
              'id': 'remote-note',
              'title': '远端',
              'content': '# 远端内容',
              'version': 3,
              'isDeleted': false,
              'updatedAt': '2026-09-23T12:00:00Z',
            }
          ]
        });
      });

      final count = await syncer.pull();
      expect(count, 1);
      final fetched = await repo.getNote('remote-note');
      expect(fetched, isNotNull);
      expect(fetched!.title, '远端');
      expect(fetched.version, 1);
      syncer.close();
    });

    test('未授权返回 401 抛异常', () async {
      final syncer = newClient((req) async => Response('unauthorized', 401));
      expect(syncer.pull(), throwsA(isA<HttpException>()));
      syncer.close();
    });

    test('push 携带附件映射（含墓碑，供对端收敛删除）', () async {
      final note = await repo.createNote(title: 'A', contentMarkdown: '# A');
      await repo.addAttachment(
        noteId: note.id,
        filename: '图.png',
        mimeKind: 'image',
        byteSize: 1024,
        sha256: 'sha-att',
      );
      Map<String, dynamic>? sentItem;
      final syncer = newClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        sentItem =
            ((body['items'] as List).first as Map).cast<String, dynamic>();
        return jsonResponse(200, {
          'ok': true,
          'results': [
            {'id': note.id, 'accepted': true, 'appliedVersion': 1}
          ]
        });
      });

      await syncer.enqueue(note);
      await syncer.push();

      final atts =
          (sentItem!['attachments'] as List).cast<Map<String, dynamic>>();
      expect(atts.length, 1);
      expect(atts.first['filename'], '图.png');
      expect(atts.first['sha256'], 'sha-att');
      expect(atts.first['byteSize'], 1024);
      expect(atts.first['isDeleted'], isFalse);
      syncer.close();
    });

    test('pull 落库附件映射并计入本地引用（LRU 保护）；墓碑后归零', () async {
      var tombstoned = false;
      final syncer = newClient((req) async => jsonResponse(200, {
            'ok': true,
            'notes': [
              {
                'id': 'remote-note',
                'title': '带附件',
                'content': '![](sui://sha-att)',
                'version': 1,
                'isDeleted': false,
                'updatedAt': '2026-09-23T12:00:00Z',
                'attachments': [
                  {
                    'id': 'att-r1',
                    'filename': '远端图.png',
                    'mimeKind': 'image',
                    'byteSize': 2048,
                    'sha256': 'sha-att',
                    'storageRef': 'sha-att',
                    'embeddedPos': 0,
                    'isDeleted': tombstoned,
                    'createdAt': '2026-09-23T11:00:00Z',
                  }
                ],
              }
            ]
          }));

      await syncer.pull();
      final atts = await repo.listAttachments(noteId: 'remote-note');
      expect(atts.length, 1);
      expect(atts.first.filename, '远端图.png');
      expect(atts.first.byteSize, 2048);

      final meta = SqliteBlobCacheMeta(db);
      expect((await meta.entry('sha-att'))!.refCount, 1);

      // 远端墓碑化：默认查询不再返回，引用计数归零（可被 LRU 回收）
      tombstoned = true;
      await syncer.pull();
      expect(await repo.listAttachments(noteId: 'remote-note'), isEmpty);
      expect((await meta.entry('sha-att'))!.refCount, 0);
      syncer.close();
    });
  });
}

typedef MockClientHandler = Future<Response> Function(Request request);