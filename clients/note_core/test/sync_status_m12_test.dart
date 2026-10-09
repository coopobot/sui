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

Map<String, dynamic> remoteNote(
  String id,
  String title,
  int version,
  String updatedAt,
) =>
    {
      'id': id,
      'title': title,
      'content': '远端正文',
      'version': version,
      'isDeleted': false,
      'updatedAt': updatedAt,
    };

/// M12（FR-53 / FR-54 / FR-55）门禁：逐项同步状态、自愈、核对补齐、游标与幂等。
///
/// 对应验收 AC-180\~AC-197；亦覆盖 B24 的三个成因（换库后无法上行 / 上传意图丢失 / 同秒漏拉）。
void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late SettingsStore settings;

  setUp(() {
    db = AppDatabase.memory();
    repo = NoteRepository(db, deviceId: 'dev');
    settings = SettingsStore(db);
  });

  tearDown(() => db.close());

  SyncClient newClient(MockClientHandler handler, {bool withSettings = false}) =>
      SyncClient(
        repository: repo,
        baseUrl: 'http://test',
        deviceId: 'dev',
        token: 'tok',
        settings: withSettings ? settings : null,
        httpClient: MockClient(handler),
      );

  group('M12 写路径 → 逐项状态（AC-180 / AC-182）', () {
    test('新建笔记 = 仅本地；本地编辑后仍是需要上行的状态；空笔记本一视同仁', () async {
      final note = await repo.createNote(title: 'A');
      expect((await repo.getNote(note.id))!.syncState,
          EntitySyncState.localOnly,
          reason: '本地新建、云端从未持有 → 仅本地');

      await repo.updateNoteContent(note.id, contentMarkdown: 'v2');
      expect((await repo.getNote(note.id))!.syncState,
          EntitySyncState.localOnly,
          reason: '基线仍为 0（云端从未确认）→ 仍是仅本地，但属于需要上行的状态');

      // 空笔记本同样有状态（不得因「里面没有笔记」而跳过）。
      final emptyNb = await repo.createNotebook(name: '空笔记本');
      expect((await repo.getNotebook(emptyNb.id))!.syncState,
          EntitySyncState.localOnly);

      final tag = await repo.createTag(name: '标签');
      expect((await repo.getTag(tag.id))!.syncState, EntitySyncState.localOnly);

      expect(await repo.countNeedingUpload(), 3,
          reason: '新建项都会被周期上行带走');
    });

    test('已同步笔记被本地编辑 → 待上传；push 成功 → 已同步 + 基线回写', () async {
      final note =
          await repo.createNote(title: 'A', version: 3, fromWire: true);
      expect((await repo.getNote(note.id))!.syncState, EntitySyncState.synced,
          reason: '下行落库即已同步');

      await repo.updateNoteContent(note.id, contentMarkdown: 'v2');
      expect((await repo.getNote(note.id))!.syncState, EntitySyncState.pending,
          reason: '有服务端基线（version>0）且有未上传改动 → 待上传');

      final client = newClient((req) async => jsonResponse(200, {
            'ok': true,
            'results': [
              {'id': note.id, 'accepted': true, 'appliedVersion': 4}
            ],
          }));
      await client.push();
      final after = await repo.getNote(note.id);
      expect(after!.syncState, EntitySyncState.synced);
      expect(after.version, 4, reason: '回写服务端基线镜像');
      client.close();
    });

    test('上行整批失败 → 逐项记「同步失败」+ 原因（可重试）', () async {
      final note = await repo.createNote(title: 'A');
      final client = newClient((req) async => Response('boom', 500));
      await expectLater(client.push(), throwsA(isA<HttpException>()));
      final after = await repo.getNote(note.id);
      expect(after!.syncState, EntitySyncState.failed);
      expect(after.syncError, isNotEmpty, reason: '必须保留原因（AC-174）');
      expect(after.syncErrorAt, isNotNull);
      client.close();
    });
  });

  group('M12 自愈：服务端没有该实体（AC-192 / B24-①）', () {
    test('本地基线 126 + 服务端无该笔记 → 同轮归零重发并成功（旧服务端表达）', () async {
      final note =
          await repo.createNote(title: 'A', version: 126, fromWire: true);
      await repo.updateNoteContent(note.id, contentMarkdown: '本地草稿');

      final bases = <int>[];
      var round = 0;
      final client = newClient((req) async {
        if (req.url.path != '/api/v1/sync/push') {
          return jsonResponse(200, {'ok': true, 'notes': []});
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final items = (body['items'] as List).cast<Map<String, dynamic>>();
        if (items.isNotEmpty) bases.add(items.first['baseVersion'] as int);
        round++;
        if (round == 1) {
          // 旧服务端形态：不带 notFound、serverVersion 缺省（= 0）。
          return jsonResponse(200, {
            'ok': true,
            'results': [
              {'id': note.id, 'accepted': false}
            ],
          });
        }
        return jsonResponse(200, {
          'ok': true,
          'results': [
            {'id': note.id, 'accepted': true, 'appliedVersion': 1}
          ],
        });
      });

      final results = await client.push();
      expect(bases, [126, 0],
          reason: '第一轮被拒（服务端没有它）→ 基线归零 → **同一轮**重发');
      expect(results.last.accepted, isTrue);
      final after = await repo.getNote(note.id);
      expect(after!.syncState, EntitySyncState.synced);
      expect(after.version, 1);
      client.close();
    });

    test('新服务端形态（notFound: true）同样自愈', () async {
      final nb = await repo.createNotebook(name: '空笔记本');
      final bases = <int>[];
      var round = 0;
      final client = newClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final nbs =
            (body['notebooks'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (nbs.isNotEmpty) bases.add(nbs.first['baseVersion'] as int);
        round++;
        if (round == 1) {
          return jsonResponse(200, {
            'ok': true,
            'results': [],
            'notebookResults': [
              {
                'id': nb.id,
                'accepted': false,
                'serverVersion': 0,
                'notFound': true,
              }
            ],
          });
        }
        return jsonResponse(200, {
          'ok': true,
          'results': [],
          'notebookResults': [
            {'id': nb.id, 'accepted': true, 'appliedVersion': 1}
          ],
        });
      });

      await repo.markPending(SyncEntityKind.notebook, nb.id);
      await client.push();
      expect(bases, [0, 0], reason: '基线本就是 0；notFound 后同轮重发');
      expect((await repo.getNotebook(nb.id))!.syncState,
          EntitySyncState.synced);
      client.close();
    });
  });

  group('M12 冲突合并与加密边界（AC-187 / AC-176）', () {
    test('真冲突 → 明文层合并（绝不丢字）并以服务端版本为 base 重发', () async {
      final note =
          await repo.createNote(title: '本地标题', version: 2, fromWire: true);
      await repo.updateNoteContent(note.id, contentMarkdown: '本地新内容');

      final bases = <int>[];
      var pushRound = 0;
      final client = newClient((req) async {
        if (req.url.path != '/api/v1/sync/push') {
          // 冲突分支会拉服务端当前内容（_fetchNoteFromServer）
          return jsonResponse(200, {
            'ok': true,
            'notes': [remoteNote(note.id, '服务端标题更长了', 5, '2026-01-01T00:00:05Z')],
          });
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final items = (body['items'] as List).cast<Map<String, dynamic>>();
        if (items.isNotEmpty) bases.add(items.first['baseVersion'] as int);
        pushRound++;
        if (pushRound == 1) {
          return jsonResponse(200, {
            'ok': true,
            'results': [
              {
                'id': note.id,
                'accepted': false,
                'serverVersion': 5,
                'notFound': false,
              }
            ],
          });
        }
        return jsonResponse(200, {
          'ok': true,
          'results': [
            {'id': note.id, 'accepted': true, 'appliedVersion': 6}
          ],
        });
      });

      await client.push();
      expect(bases, [2, 5], reason: '冲突后以服务端版本为 base 重发');
      final merged = await repo.getNote(note.id);
      expect(merged!.contentMarkdown, contains('本地新内容'),
          reason: '本地内容必须保留（绝不丢字）');
      expect(merged.contentMarkdown, contains('远端正文'),
          reason: '服务端内容也必须保留');
      expect(merged.syncState, EntitySyncState.synced);
      expect(merged.version, 6);
      client.close();
    });

    test('加密笔记本未解锁的冲突 → 不就地合并，保持「冲突」', () async {
      final nb = await repo.createNotebook(name: '密本');
      await repo.setNotebookEncrypted(nb.id, 'pw');
      final note = await repo.createNote(
        notebookId: nb.id,
        title: 't',
        contentMarkdown: 'c',
      );
      repo.lockNotebook(nb.id);
      await repo.markPending(SyncEntityKind.note, note.id);

      final client = newClient((req) async {
        if (req.url.path != '/api/v1/sync/push') {
          return jsonResponse(200, {
            'ok': true,
            'notes': [remoteNote(note.id, 'x', 5, '2026-01-01T00:00:05Z')],
          });
        }
        return jsonResponse(200, {
          'ok': true,
          'results': [
            {'id': note.id, 'accepted': false, 'serverVersion': 5}
          ],
        });
      });

      await client.push();
      final after = await repo.getNote(note.id);
      expect(after!.syncState, EntitySyncState.conflict,
          reason: '未解锁端不得把密文当正文合并');
      expect(repo.isNotebookUnlocked(nb.id), isFalse);
      expect(after.syncError, isNotEmpty, reason: '冲突需给出缘由（含「先解锁」）');
      client.close();
    });
  });

  group('M12 核对补齐与换库决策（AC-191 / AC-193 / BR-55.2）', () {
    test('「以云端为准」→ 本端多出的项保留在本机、且**不再自动上行**', () async {
      final note = await repo.createNote(title: '本地专有');
      final pushed = <String>[];
      final client = newClient((req) async {
        if (req.url.path != '/api/v1/sync/push') {
          return jsonResponse(200, {
            'ok': true,
            'notes': [],
            'notebooks': [],
            'tags': [],
            'instanceId': 'inst-x',
          });
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        for (final it
            in (body['items'] as List).cast<Map<String, dynamic>>()) {
          pushed.add(it['id'] as String);
        }
        return jsonResponse(200, {'ok': true, 'results': []});
      }, withSettings: true);

      final result =
          await client.reconcile(pushLocal: false, hasUserDecision: true);
      expect(pushed, isEmpty, reason: '「以云端为准」不得上传任何本端数据');
      expect(result.uploaded, 0);
      final after = await repo.getNote(note.id);
      expect(after!.syncState, EntitySyncState.localOnly,
          reason: '数据保留在本机，仅降级为「仅本地」');
      expect(after.title, '本地专有', reason: '不删除、不覆盖');

      // 周期同步也不得把它带走（已被按住）。
      await client.push();
      expect(pushed, isEmpty);
      client.close();
    });

    test('「用本地补齐」→ 上传本端专有项（B24 场景复原）', () async {
      final note = await repo.createNote(title: '本地专有');
      final emptyNb = await repo.createNotebook(name: '空笔记本');
      final pushed = <String>[];
      final client = newClient((req) async {
        if (req.url.path != '/api/v1/sync/push') {
          return jsonResponse(200, {
            'ok': true,
            'notes': [],
            'notebooks': [],
            'tags': [],
            'instanceId': 'inst-x',
          });
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final items = (body['items'] as List).cast<Map<String, dynamic>>();
        final nbs =
            (body['notebooks'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        pushed.addAll(items.map((e) => e['id'] as String));
        pushed.addAll(nbs.map((e) => e['id'] as String));
        return jsonResponse(200, {
          'ok': true,
          'results': [
            for (final it in items)
              {'id': it['id'], 'accepted': true, 'appliedVersion': 1}
          ],
          'notebookResults': [
            for (final it in nbs)
              {'id': it['id'], 'accepted': true, 'appliedVersion': 1}
          ],
        });
      }, withSettings: true);

      await client.reconcile(pushLocal: true, hasUserDecision: true);
      expect(pushed, containsAll([note.id, emptyNb.id]),
          reason: '含空笔记本：本端专有项全部补齐上行');
      expect((await repo.getNote(note.id))!.syncState,
          EntitySyncState.synced);
      expect((await repo.getNotebook(emptyNb.id))!.syncState,
          EntitySyncState.synced);
      expect(await repo.countNeedingUpload(), 0);
      client.close();
    });

    test('实例身份变化 → pull 抛异常且**不落任何数据**、不更新身份', () async {
      await settings.setInstanceId('inst-old');
      final client = newClient(
        (req) async => jsonResponse(200, {
          'ok': true,
          'instanceId': 'inst-new',
          'notes': [remoteNote('remote-1', '远端', 1, '2026-01-01T00:00:00Z')],
        }),
        withSettings: true,
      );

      await expectLater(
        client.pull(),
        throwsA(isA<CloudInstanceChangedException>()),
      );
      expect(await repo.getNote('remote-1'), isNull,
          reason: '用户未决断前不得落任何数据（BR-55.2）');
      expect(await settings.instanceId(), 'inst-old',
          reason: '未决断前不得更新实例身份（否则下次不再提示）');
      client.close();
    });

    test('首次连接即发现云端为空而本机有数据 → 同样交由用户决策', () async {
      await repo.createNote(title: '本地');
      final client = newClient(
        (req) async => jsonResponse(200, {
          'ok': true,
          'instanceId': 'inst-fresh',
          'notes': [],
          'notebooks': [],
          'tags': [],
        }),
        withSettings: true,
      );
      await expectLater(
        client.pull(),
        throwsA(isA<CloudInstanceChangedException>()),
      );
      expect(await settings.instanceId(), isNull);
      client.close();
    });
  });

  group('M12 游标与幂等（AC-196 / B24-③）', () {
    test('同一秒多条 + 游标 −1s 回退：全部到达且重放幂等', () async {
      final client = newClient(
        (req) async => jsonResponse(200, {
          'ok': true,
          'instanceId': 'inst-1',
          'notes': [
            remoteNote('n1', 'A', 1, '2026-01-01T00:00:05Z'),
            remoteNote('n2', 'B', 1, '2026-01-01T00:00:05Z'),
          ],
        }),
        withSettings: true,
      );

      expect(await client.pull(), 2);
      expect(await settings.lastPull(), DateTime.utc(2026, 1, 1, 0, 0, 4),
          reason: '游标 = max(updated_at) − 1s（同一秒多条不漏拉）');
      expect(await client.pull(), 0,
          reason: '重放同一版本必须幂等：不重复落库、不计入处理数');
      expect((await repo.getNote('n1'))!.syncState, EntitySyncState.synced);
      final revs = await repo.listRevisions('n1');
      expect(revs.where((r) => r.version == 1), hasLength(1),
          reason: '幂等：同版本修订只有一条');
      client.close();
    });
  });

  group('M12 单项重试（AC-186）', () {
    test('只影响该项，其余保持原状', () async {
      final a = await repo.createNote(title: 'A');
      final b = await repo.createNote(title: 'B');
      final pushed = <String>[];
      final client = newClient((req) async {
        if (req.url.path != '/api/v1/sync/push') {
          return jsonResponse(200, {'ok': true, 'notes': []});
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final items = (body['items'] as List).cast<Map<String, dynamic>>();
        pushed.addAll(items.map((e) => e['id'] as String));
        return jsonResponse(200, {
          'ok': true,
          'results': [
            for (final it in items)
              {'id': it['id'], 'accepted': true, 'appliedVersion': 1}
          ],
        });
      });

      expect(await client.retryOne(SyncEntityKind.note, a.id),
          EntitySyncState.synced);
      expect(pushed, [a.id], reason: '单项操作只发这一项');
      expect((await repo.getNote(b.id))!.syncState,
          EntitySyncState.localOnly,
          reason: '其余实体不受影响（BR-54.1）');
      client.close();
    });
  });
  group('M12 状态不外泄 / 幂等 / 可取消（AC-183 / AC-188）', () {
    test('push 净荷不含同步状态字段，且正本一字不动', () async {
      final note = await repo.createNote(title: 'A', contentMarkdown: '# 正本');
      await repo.markFailed(SyncEntityKind.note, note.id, '（测试）先前的失败');
      Map<String, dynamic>? sent;
      final client = newClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        sent = ((body['items'] as List).first as Map).cast<String, dynamic>();
        return jsonResponse(200, {
          'ok': true,
          'results': [
            {'id': note.id, 'accepted': true, 'appliedVersion': 1}
          ],
        });
      });

      await client.push();
      expect(
        sent!.keys.any((k) => k.toLowerCase().contains('sync')),
        isFalse,
        reason: '同步状态是纯本地记账，不得进入 push 净荷（BR-53.3 / AC-183）',
      );
      expect(sent!['content'], '# 正本', reason: '正本按原样上行，不被状态污染');
      final after = await repo.getNote(note.id);
      expect(after!.contentMarkdown, '# 正本', reason: '本地正本一字不动');
      client.close();
    });

    test('核对补齐可重复执行不增殖；进入上传前已取消则不上行', () async {
      final note = await repo.createNote(title: 'A');
      final serverNotes = <String>{};
      var pushes = 0;
      final client = newClient((req) async {
        if (req.url.path != '/api/v1/sync/push') {
          return jsonResponse(200, {
            'ok': true,
            'instanceId': 'inst-1',
            'notebooks': [],
            'tags': [],
            'notes': [
              for (final id in serverNotes)
                remoteNote(id, 'A', 1, '2026-01-01T00:00:01Z'),
            ],
          });
        }
        pushes++;
        final items = ((jsonDecode(req.body) as Map<String, dynamic>)['items']
                as List)
            .cast<Map<String, dynamic>>();
        for (final it in items) {
          serverNotes.add(it['id'] as String);
        }
        return jsonResponse(200, {
          'ok': true,
          'results': [
            for (final it in items)
              {'id': it['id'], 'accepted': true, 'appliedVersion': 1}
          ],
        });
      }, withSettings: true);

      // 首次核对补齐：本端专有项上行并转「已同步」。
      await client.reconcile(pushLocal: true, hasUserDecision: true);
      expect((await repo.getNote(note.id))!.syncState,
          EntitySyncState.synced);
      final pushesAfterFirst = pushes;

      // 第二次核对：已同步且云端已持有 → 不再上行（幂等、不增殖）。
      final second =
          await client.reconcile(pushLocal: true, hasUserDecision: true);
      expect(second.uploaded, 0, reason: '无待上行项 → 不上行');
      expect(pushes, pushesAfterFirst, reason: '幂等：不产生重复上行请求');
      expect((await repo.getNote(note.id))!.syncState,
          EntitySyncState.synced);
      expect(serverNotes, hasLength(1), reason: '不产生重复实体');

      // 预取消：进入上传阶段前就取消 → 如实回报，且**不得**静默上传。
      final note2 = await repo.createNote(title: 'B');
      final token = CancelToken()..cancel();
      final cancelledRun = await client.reconcile(
        pushLocal: true,
        hasUserDecision: true,
        cancel: token,
      );
      expect(cancelledRun.cancelled, isTrue);
      expect((await repo.getNote(note2.id))!.syncState,
          isNot(EntitySyncState.synced),
          reason: '取消后不得静默上传');
      expect(serverNotes, hasLength(1), reason: '取消后云端不应新增实体');
      client.close();
    });
  });
}
