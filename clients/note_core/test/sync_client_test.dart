import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;
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

    // 回归 BUG：push 成功后必须把服务端基线镜像回写本地 Notes.version，
    // 否则离线编辑会不断抬升本地版本、与服务端版本永久发散
    // （现象：服务端 33 / 客户端 37、39；离线端重连后无法收敛）。
    test('push 成功回写 Notes.version = appliedVersion', () async {
      final note = await repo.createNote(title: 'A', contentMarkdown: '# A');
      final syncer = newClient((req) async => jsonResponse(200, {
            'ok': true,
            'results': [
              {'id': note.id, 'accepted': true, 'appliedVersion': 7}
            ]
          }));

      await syncer.enqueue(note);
      await syncer.push();

      final after = await repo.getNote(note.id);
      expect(after!.version, 7, reason: 'Notes.version 是服务端基线镜像');
      syncer.close();
    });

    // 回归 BUG：离线期间本地多次编辑不得抬升 Notes.version（基线镜像），
    // 本地修订使用独立编号；一次 push 后版本即与服务端收敛。
    test('离线多次编辑后一次 push：本地基线版本不无限增长', () async {
      final note = await repo.createNote(title: 'A', contentMarkdown: 'v1');
      await repo.updateNoteContent(note.id, contentMarkdown: 'v2');
      await repo.updateNoteContent(note.id, contentMarkdown: 'v3');
      final edited =
          await repo.updateNoteContent(note.id, contentMarkdown: 'v4');
      expect(edited.version, note.version, reason: '本地编辑不推进基线镜像');

      final syncer = newClient((req) async => jsonResponse(200, {
            'ok': true,
            'results': [
              {'id': note.id, 'accepted': true, 'appliedVersion': 1}
            ]
          }));

      await syncer.enqueue(edited);
      await syncer.push();

      final after = await repo.getNote(note.id);
      expect(after!.version, 1, reason: '回写服务端 appliedVersion');
      // 本地修订链保持连续 1..4，未与服务端版本撞号
      final revs = await repo.listRevisions(note.id);
      expect(revs.map((r) => r.version).toList(), [4, 3, 2, 1]);
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

      // M12：冲突会在**同一轮内**以新基线重发一次（故 push 被调用两次）；
      // 第二次仍冲突则不再重复合并（避免冲突标记膨胀），保留「冲突」态待下轮。
      expect(pushCalls, 2);
      expect(pullCalls, greaterThanOrEqualTo(1));
      expect(results.first.accepted, isFalse);
      expect(syncer.outboxLength, 1);
      final merged = await repo.getNote(note.id);
      expect(merged!.contentMarkdown, contains('远端正文'));
      expect(merged.contentMarkdown, contains('本地正文'));
      expect(merged.contentMarkdown, contains('sui:conflict'));
      expect(merged.syncState, EntitySyncState.conflict);

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
      // 远端笔记以服务端版本为基线镜像（sync-protocol §3）。
      expect(fetched.version, 3);
      syncer.close();
    });

    // 回归 BUG：「本地已有」笔记下行时正文/标题/版本未落库。
    // 现象：对端编辑了本机已有的笔记（尤其带附件），本机 pull 后附件映射会更新，
    // 正文却停留在旧版本。修复后 pull 的「本地已有」分支同样应用服务端正文与版本。
    test('BUG 修复：pull 更新已存在笔记的正文/标题/版本（无待推草稿）', () async {
      // M12：本端无改动 = 同步状态为「已同步」（等价于旧模型的「Outbox 无草稿」）。
      // 这里以服务端来源落库（fromWire）模拟「本机已有、且没有未上传改动」。
      final local = await repo.createNote(
        title: '旧标题',
        contentMarkdown: '旧正文',
        version: 1,
        fromWire: true,
      );
      final syncer = newClient((req) async => jsonResponse(200, {
            'ok': true,
            'notes': [
              {
                'id': local.id,
                'title': '新标题',
                'content': '对端编辑后的新正文',
                'version': 2,
                'isDeleted': false,
                'updatedAt': '2026-09-24T12:00:00Z',
              }
            ]
          }));

      await syncer.pull();
      final updated = await repo.getNote(local.id);
      expect(updated!.title, '新标题');
      expect(updated.contentMarkdown, '对端编辑后的新正文');
      expect(updated.version, 2);
      // 版本号与历史链一致：幂等补一条同版本修订，不重复。
      final revs = await repo.listRevisions(local.id);
      expect(revs.where((r) => r.version == 2), hasLength(1));
      syncer.close();
    });

    // 回归 BUG：本地有未上行的草稿时，pull 不得用远端内容覆盖本地。
    test('BUG 修复：存在待推草稿时 pull 不覆盖本地正文', () async {
      final local =
          await repo.createNote(title: '本地标题', contentMarkdown: '本地未上传草稿');
      final syncer = newClient((req) async => jsonResponse(200, {
            'ok': true,
            'notes': [
              {
                'id': local.id,
                'title': '远端标题',
                'content': '远端正文',
                'version': 2,
                'isDeleted': false,
                'updatedAt': '2026-09-24T12:00:00Z',
              }
            ]
          }));

      await syncer.enqueue(local);
      await syncer.pull();
      final kept = await repo.getNote(local.id);
      expect(kept!.contentMarkdown, '本地未上传草稿');
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

    group('笔记本 / 标签同步', () {
      test('push 携带笔记本与标签上行（无笔记变更也能推送）', () async {
        final nb = await repo.createNotebook(name: '工作');
        final tag = await repo.createTag(name: '重要');
        var pushCalls = 0;
        Map<String, dynamic>? body;
        final syncer = newClient((req) async {
          if (req.url.path == '/api/v1/sync/push') {
            pushCalls++;
            body = jsonDecode(req.body) as Map<String, dynamic>;
            return jsonResponse(200, {
              'ok': true,
              'results': [],
              'notebookResults': [
                {'id': nb.id, 'accepted': true, 'appliedVersion': 1}
              ],
              'tagResults': [
                {'id': tag.id, 'accepted': true, 'appliedVersion': 1}
              ],
            });
          }
          return jsonResponse(200, {'ok': true, 'notes': []});
        });

        await syncer.enqueueNotebook(nb);
        await syncer.enqueueTag(tag);
        await syncer.push();

        expect(pushCalls, 1);
        final nbs = (body!['notebooks'] as List).cast<Map<String, dynamic>>();
        expect(nbs.length, 1);
        expect(nbs.first['id'], nb.id);
        expect(nbs.first['name'], '工作');
        expect(nbs.first['baseVersion'], 0);
        // M12：本地新建 = 服务端基线 0（`version` 与 `baseVersion` 同源，均为基线镜像）。
        expect(nbs.first['version'], 0);
        final tags = (body!['tags'] as List).cast<Map<String, dynamic>>();
        expect(tags.length, 1);
        expect(tags.first['id'], tag.id);
        expect(tags.first['name'], '重要');

        // 接受后 dirty 清空：再 push 无待推内容，不再发请求。
        await syncer.push();
        expect(pushCalls, 1);
        syncer.close();
      });

      test('pull 下行笔记本与标签并落库', () async {
        final syncer = newClient((req) async => jsonResponse(200, {
              'ok': true,
              'notebooks': [
                {
                  'id': 'nb-r',
                  'parentId': null,
                  'name': '工作',
                  'sortOrder': 1,
                  'version': 2,
                  'isDeleted': false,
                  'updatedAt': '2026-09-23T12:00:00Z',
                }
              ],
              'tags': [
                {
                  'id': 'tg-r',
                  'name': '重要',
                  'version': 3,
                  'isDeleted': false,
                  'updatedAt': '2026-09-23T12:00:00Z',
                }
              ],
              'notes': [],
            }));

        final count = await syncer.pull();
        expect(count, 2);
        final nb = await repo.getNotebook('nb-r');
        expect(nb, isNotNull);
        expect(nb!.name, '工作');
        expect(nb.version, 2);
        final tag = await repo.getTag('tg-r');
        expect(tag, isNotNull);
        expect(tag!.name, '重要');
        expect(tag.version, 3);
        syncer.close();
      });

      test('BUG5 pull 下行根级笔记本的空串 parentId 归一为 null', () async {
        final syncer = newClient((req) async => jsonResponse(200, {
              'ok': true,
              'notebooks': [
                {
                  'id': 'nb-empty',
                  'parentId': '',
                  'name': '工作',
                  'sortOrder': 0,
                  'version': 1,
                  'isDeleted': false,
                  'updatedAt': '2026-09-23T12:00:00Z',
                }
              ],
              'tags': [],
              'notes': [],
            }));

        await syncer.pull();
        final nb = await repo.getNotebook('nb-empty');
        expect(nb, isNotNull);
        expect(nb!.parentId, isNull);
        final roots =
            (await repo.listNotebooks()).where((n) => n.parentId == null);
        expect(roots.map((n) => n.id), contains('nb-empty'));
        syncer.close();
      });

      test('pull 下行笔记的 notebookId 与 tagIds', () async {
        final syncer = newClient((req) async => jsonResponse(200, {
              'ok': true,
              'notebooks': [
                {
                  'id': 'nb-1',
                  'name': '工作',
                  'sortOrder': 0,
                  'version': 1,
                  'isDeleted': false,
                  'updatedAt': '2026-09-23T12:00:00Z',
                }
              ],
              'tags': [
                {
                  'id': 'tg-1',
                  'name': '重要',
                  'version': 1,
                  'isDeleted': false,
                  'updatedAt': '2026-09-23T12:00:00Z',
                }
              ],
              'notes': [
                {
                  'id': 'n1',
                  'title': '带分组',
                  'content': '# 内容',
                  'notebookId': 'nb-1',
                  'tagIds': ['tg-1'],
                  'version': 1,
                  'isDeleted': false,
                  'updatedAt': '2026-09-23T12:00:00Z',
                }
              ],
            }));

        await syncer.pull();
        final note = await repo.getNote('n1');
        expect(note, isNotNull);
        expect(note!.notebookId, 'nb-1');
        final tags = await repo.tagsOfNote('n1');
        expect(tags.map((t) => t.id), contains('tg-1'));
        syncer.close();
      });

      test('pull 跳过本地脏笔记本（本地优先，不被远端覆盖）', () async {
        final local = await repo.createNotebook(name: '本地名');
        final syncer = newClient((req) async {
          if (req.url.path == '/api/v1/sync/push') {
            return jsonResponse(200, {
              'ok': true,
              'results': [],
              'notebookResults': [
                {'id': local.id, 'accepted': false, 'serverVersion': 5}
              ],
              'tagResults': [],
            });
          }
          return jsonResponse(200, {
            'ok': true,
            'notebooks': [
              {
                'id': local.id,
                'name': '远端名',
                'sortOrder': 0,
                'version': 5,
                'isDeleted': false,
                'updatedAt': '2026-09-23T12:00:00Z',
              }
            ],
            'tags': [],
            'notes': [],
          });
        });

        syncer.enqueueNotebook(local);
        await syncer.push(); // 冲突 → 保留 dirty
        await syncer.pull(); // 脏项应被跳过

        final still = await repo.getNotebook(local.id);
        expect(still!.name, '本地名');
        // M12：冲突后基线**对齐服务端版本**（下轮以它为 base 重发本地字段），
        // 且本地仍是「待上传」（pull 不覆盖脏项）。
        expect(still.version, 5);
        expect(still.syncState, isNot(EntitySyncState.synced));
        syncer.close();
      });

      test('push 笔记本冲突 → base 刷新为服务端版本并保留待推', () async {
        final nb = await repo.createNotebook(name: '工作');
        final sentBases = <int>[];
        final syncer = newClient((req) async {
          final b = jsonDecode(req.body) as Map<String, dynamic>;
          final nbs = (b['notebooks'] as List?)?.cast<Map<String, dynamic>>();
          if (nbs != null && nbs.isNotEmpty) {
            sentBases.add(nbs.first['baseVersion'] as int);
          }
          return jsonResponse(200, {
            'ok': true,
            'results': [],
            'notebookResults': [
              {'id': nb.id, 'accepted': false, 'serverVersion': 3}
            ],
            'tagResults': [],
          });
        });

        syncer.enqueueNotebook(nb);
        await syncer.push();
        await syncer.push(); // dirty 未清 → 再发，base 已刷新为 3

        expect(sentBases, [0, 3]);
        syncer.close();
      });

      test('push 笔记携带 notebookId 与 tagIds', () async {
        final nb = await repo.createNotebook(name: '工作');
        final note = await repo.createNote(
          title: 'A',
          contentMarkdown: '# A',
          notebookId: nb.id,
          tags: ['重要'],
        );
        Map<String, dynamic>? sentItem;
        final syncer = newClient((req) async {
          final b = jsonDecode(req.body) as Map<String, dynamic>;
          sentItem =
              ((b['items'] as List).first as Map).cast<String, dynamic>();
          return jsonResponse(200, {
            'ok': true,
            'results': [
              {'id': note.id, 'accepted': true, 'appliedVersion': 1}
            ]
          });
        });

        await syncer.enqueue(note);
        await syncer.push();

        expect(sentItem!['notebookId'], nb.id);
        final tagIds = (sentItem!['tagIds'] as List).cast<String>();
        expect(tagIds, hasLength(1));
        syncer.close();
      });
    });

    group('附件字节上传', () {
      late Directory tmpDir;
      late CachedBlobStore store;

      setUp(() {
        tmpDir = Directory.systemTemp.createTempSync('sui-sync-blob');
        store = CachedBlobStore(
          local: LocalBlobStore(p.join(tmpDir.path, 'blobs')),
          meta: SqliteBlobCacheMeta(db),
          maxBytes: 8 * 1024 * 1024,
        );
      });

      tearDown(() async {
        await store.dispose();
        tmpDir.deleteSync(recursive: true);
      });

      /// 挂一个「本机新加、服务端还没有」的附件。
      Future<Uint8List> attachLocalBytes(String noteId) async {
        final bytes = Uint8List.fromList('attachment-body'.codeUnits);
        final hash = sha256Hex(bytes);
        await store.put(sha256: hash, bytes: bytes);
        await repo.addAttachment(
          noteId: noteId,
          filename: 'a.txt',
          mimeKind: 'text',
          byteSize: bytes.length,
          sha256: hash,
        );
        return bytes;
      }

      test('sync 先补传字节再 push 映射；成功后不再重传', () async {
        final note = await repo.createNote(title: 'A');
        final bytes = await attachLocalBytes(note.id);
        final hash = sha256Hex(bytes);

        final order = <String>[];
        final putPaths = <String>[];
        final syncer = SyncClient(
          repository: repo,
          baseUrl: 'http://test',
          deviceId: 'test-device',
          token: 'tok',
          blobStore: store,
          httpClient: MockClient((req) async {
            if (req.method == 'PUT') {
              order.add('blob');
              putPaths.add(req.url.path);
              expect(req.bodyBytes, bytes, reason: '上传的应是本地原始字节');
              return jsonResponse(200, {'ok': true});
            }
            if (req.url.path == '/api/v1/sync/push') {
              order.add('push');
              return jsonResponse(200, {
                'ok': true,
                'results': [
                  {'id': note.id, 'accepted': true, 'appliedVersion': 1}
                ]
              });
            }
            if (req.url.path == '/api/v1/sync/pull') {
              order.add('pull');
              return jsonResponse(200, {'ok': true, 'notes': []});
            }
            return Response('not found', 404);
          }),
        );

        await syncer.enqueue(note);
        await syncer.sync();

        expect(putPaths, ['/api/v1/blobs/$hash']);
        expect(order, ['blob', 'push', 'pull'],
            reason: '字节必须先到服务端，映射才允许对端看到');
        expect((await store.entry(hash))!.uploadedAt, isNotNull);
        expect(await store.pendingUploads(), isEmpty);

        // 再同步一轮：已确认上传，不应重复 PUT。
        await syncer.sync();
        expect(putPaths, hasLength(1));
        syncer.close();
      });

      test('上传失败不阻断同步：字节留本地，下轮补传', () async {
        final note = await repo.createNote(title: 'A');
        final bytes = await attachLocalBytes(note.id);
        final hash = sha256Hex(bytes);

        var failPut = true;
        var putCalls = 0;
        final syncer = SyncClient(
          repository: repo,
          baseUrl: 'http://test',
          deviceId: 'test-device',
          token: 'tok',
          blobStore: store,
          httpClient: MockClient((req) async {
            if (req.method == 'PUT') {
              putCalls++;
              if (failPut) return Response('boom', 500);
              return jsonResponse(200, {'ok': true});
            }
            if (req.url.path == '/api/v1/sync/push') {
              return jsonResponse(200, {
                'ok': true,
                'results': [
                  {'id': note.id, 'accepted': true, 'appliedVersion': 1}
                ]
              });
            }
            return jsonResponse(200, {'ok': true, 'notes': []});
          }),
        );

        await syncer.enqueue(note);
        await syncer.sync(); // 上传失败，但 push/pull 照常

        expect(putCalls, 1);
        expect((await store.entry(hash))!.uploadedAt, isNull);
        expect(await store.pendingUploads(), hasLength(1));
        expect(await store.exists(hash), isTrue, reason: '字节仍在本地，不会丢');

        failPut = false;
        await syncer.sync();
        expect(putCalls, 2);
        expect((await store.entry(hash))!.uploadedAt, isNotNull);
        syncer.close();
      });

      test('本地没有字节的映射不会被上传（避免触发按需下载）', () async {
        final note = await repo.createNote(title: 'A');
        // 只挂映射，不落字节（等价于远端映射刚下行、还没下载的状态）。
        await repo.addAttachment(
          noteId: note.id,
          filename: 'remote.png',
          mimeKind: 'image',
          byteSize: 100,
          sha256: 'sha-remote',
        );

        var putCalls = 0;
        final syncer = SyncClient(
          repository: repo,
          baseUrl: 'http://test',
          deviceId: 'test-device',
          token: 'tok',
          blobStore: store,
          httpClient: MockClient((req) async {
            if (req.method == 'PUT') {
              putCalls++;
              return jsonResponse(200, {'ok': true});
            }
            return jsonResponse(200, {'ok': true, 'notes': []});
          }),
        );

        expect(await syncer.backfillBlobs(), 0);
        expect(putCalls, 0);
        expect(await syncer.uploadBlob('sha-remote'), isFalse);
        syncer.close();
      });
    });
  });
}

typedef MockClientHandler = Future<Response> Function(Request request);