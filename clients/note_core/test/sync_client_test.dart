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
  });
}

typedef MockClientHandler = Future<Response> Function(Request request);