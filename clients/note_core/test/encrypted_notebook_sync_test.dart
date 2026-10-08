import 'dart:convert';

import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

Response _json(int status, Object body) => Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

/// M10-T29：加密笔记本的**客户端模型与线上字段**。
///
/// 关注点：加密态必须能落库、能随 push / pull 往返，且**密文原样搬运**（客户端在未解锁时
/// 也不得对内容做任何加工）；`encrypted` 镜像是「未解锁端显示占位、且不尝试解析」的依据。
void main() {
  group('加密笔记本（M10-T29）：模型与线上字段', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.memory();
      repo = NoteRepository(db, deviceId: 'dev-a');
    });

    tearDown(() => db.close());

    // 一段真实形态的 crypto_meta（**非敏感**元数据：无 K_nb、无锁定密码）。
    const meta = '{"v":1,"kdf":"argon2id","m":65536,"t":3,"p":1,'
        '"salt":"AAECAwQFBgcICQoLDA0ODw==",'
        '"verifier":"qrvM3e7/AAECAwQFBgcICQoLDA0ODw=="}';

    test('笔记本 encrypted / cryptoMeta 本地往返', () async {
      final nb = await repo.createNotebook(
        name: '私密',
        encrypted: true,
        cryptoMeta: meta,
      );
      expect(nb.encrypted, isTrue);
      expect(nb.cryptoMeta, meta);

      final again = await repo.getNotebook(nb.id);
      expect(again!.encrypted, isTrue);
      expect(again.cryptoMeta, meta);
    });

    test('默认普通笔记本：encrypted=false、cryptoMeta 为空', () async {
      final nb = await repo.createNotebook(name: '普通');
      expect(nb.encrypted, isFalse);
      expect(nb.cryptoMeta, isEmpty);
    });

    test('笔记 encrypted 镜像本地往返（默认为普通）', () async {
      final nb = await repo.createNotebook(name: '私密', encrypted: true);
      final enc = await repo.createNote(
        notebookId: nb.id,
        title: 'AQEAAAA=',
        encrypted: true,
      );
      expect(enc.encrypted, isTrue);
      expect((await repo.getNote(enc.id))!.encrypted, isTrue);

      final plain = await repo.createNote(title: 'p');
      expect(plain.encrypted, isFalse);
    });

    test('远端下行：upsertRemoteNotebook 落 encrypted / cryptoMeta', () async {
      await repo.upsertRemoteNotebook(
        id: 'nb-x',
        name: '私密',
        version: 2,
        encrypted: true,
        cryptoMeta: meta,
      );
      final nb = await repo.getNotebook('nb-x');
      expect(nb!.encrypted, isTrue);
      expect(nb.cryptoMeta, meta);
    });

    test('applyRemoteEncrypted 立即切换（未解锁端据此显示占位）', () async {
      final n = await repo.createNote(title: 't');
      expect(n.encrypted, isFalse);
      await repo.applyRemoteEncrypted(n.id, true);
      expect((await repo.getNote(n.id))!.encrypted, isTrue);
    });

    test('push 携带 encrypted / cryptoMeta；pull 落库且密文原样', () async {
      final pushed = <Map<String, dynamic>>[];
      final syncer = SyncClient(
        repository: repo,
        baseUrl: 'http://test',
        deviceId: 'dev-a',
        token: 'tok',
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/sync/push') {
            pushed.add(jsonDecode(req.body) as Map<String, dynamic>);
            return _json(200, {
              'ok': true,
              'results': [],
              'notebookResults': [],
              'tagResults': [],
            });
          }
          if (req.url.path == '/api/v1/sync/pull') {
            return _json(200, {
              'ok': true,
              'tags': [],
              'notes': [
                {
                  'id': 'note-remote',
                  'title': 'AQEAAAA=',
                  'content': 'AQEAAAA=',
                  'version': 3,
                  'isDeleted': false,
                  'archived': false,
                  'notebookId': 'nb-remote',
                  'sourceDevice': 'dev-b',
                  'updatedAt': '2026-10-08T00:00:00Z',
                  'encrypted': true,
                }
              ],
              'notebooks': [
                {
                  'id': 'nb-remote',
                  'name': '私密',
                  'sortOrder': 0,
                  'version': 2,
                  'isDeleted': false,
                  'sourceDevice': 'dev-b',
                  'updatedAt': '2026-10-08T00:00:00Z',
                  'encrypted': true,
                  'cryptoMeta': meta,
                }
              ],
            });
          }
          return _json(404, {'ok': false});
        }),
      );

      final nb = await repo.createNotebook(
        name: '私密',
        encrypted: true,
        cryptoMeta: meta,
      );
      final note = await repo.createNote(
        notebookId: nb.id,
        title: 'AQEAAAA=',
        contentMarkdown: 'AQEAAAA=',
        encrypted: true,
      );
      await syncer.enqueue(note);
      syncer.enqueueNotebook(nb);
      await syncer.push();

      expect(pushed, hasLength(1));
      final nbPayload =
          (pushed.first['notebooks'] as List).cast<Map<String, dynamic>>();
      expect(nbPayload.single['encrypted'], isTrue);
      expect(nbPayload.single['cryptoMeta'], meta);
      final items = (pushed.first['items'] as List).cast<Map<String, dynamic>>();
      expect(items.single['encrypted'], isTrue);

      await syncer.pull();
      // 存储层：密文**原样落库**（不经任何解密 / 改写）——故直接读行来断言。
      final row = await (db.select(db.notes)..where((n) => n.id.equals('note-remote')))
          .getSingle();
      expect(row.title, 'AQEAAAA=', reason: '密文必须原样落库');
      expect(row.contentMarkdown, 'AQEAAAA=');
      expect(row.encrypted, isTrue);

      // 展示层（M10-T29 读取接缝）：未解锁 → 占位，绝不把密文当明文交给上层。
      final display = await repo.getNote('note-remote');
      expect(display, isNotNull);
      expect(display!.locked, isTrue);
      expect(display.title, NoteRepository.lockedPlaceholderTitle);
      expect(display.contentMarkdown, isEmpty);

      final remoteNb = await repo.getNotebook('nb-remote');
      expect(remoteNb!.encrypted, isTrue);
      expect(remoteNb.cryptoMeta, meta);
      syncer.close();
    });
  });
}
