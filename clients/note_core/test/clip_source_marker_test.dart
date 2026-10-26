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

const _clipURL = 'https://www.news.cn/';

/// v0.13.2（BR-05.1 / BR-05.4 / BR-08.4 / BR-13.2 / AC-264\~AC-267）：
/// 剪藏来源标记 `sourceUrl` **只下行不上行**，且不因本机 push 而丢失——
/// 「收件箱」据它判定，而不是据会被改写的 `sourceDevice`。
void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late List<Map<String, dynamic>> pushed;

  setUp(() {
    db = AppDatabase.memory();
    repo = NoteRepository(db, deviceId: 'dev-desktop');
    pushed = [];
  });

  tearDown(() => db.close());

  SyncClient buildSyncer() => SyncClient(
        repository: repo,
        baseUrl: 'http://test',
        deviceId: 'dev-desktop',
        token: 'tok',
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/sync/pull') {
            return _json(200, {
              'ok': true,
              'tags': const [],
              'notebooks': const [],
              'notes': [
                {
                  'id': 'clip-news',
                  'title': '新华网_让新闻离你更近',
                  'content': '> 来源：[$_clipURL]($_clipURL)\n\n正文',
                  'version': 1,
                  'isDeleted': false,
                  'archived': false,
                  'sourceDevice': 'clip:web-extension',
                  'sourceUrl': _clipURL,
                  'updatedAt': '2026-10-13T00:00:00Z',
                }
              ],
            });
          }
          if (req.url.path == '/api/v1/sync/push') {
            pushed.add(jsonDecode(req.body) as Map<String, dynamic>);
            return _json(200, {
              'ok': true,
              'results': const [],
              'notebookResults': const [],
              'tagResults': const [],
            });
          }
          return _json(404, {'ok': false});
        }),
      );

  test('pull 下行 sourceUrl → 本地持有不可变剪藏来源标记（AC-264）', () async {
    await buildSyncer().pull();

    final note = await repo.getNote('clip-news');
    expect(note, isNotNull);
    expect(note!.sourceUrl, _clipURL);
    expect(note.sourceDevice, 'clip:web-extension');
    expect(note.isClip, isTrue);
  });

  test('本机编辑后重推：净荷不带 sourceUrl，本地仍判定为剪藏（AC-264 / BR-08.4）', () async {
    final syncer = buildSyncer();
    await syncer.pull();

    final edited = await repo.updateNoteContent('clip-news',
        contentMarkdown: '> 来源：[$_clipURL]($_clipURL)\n\n正文 + 本地补充');
    await syncer.enqueue(edited);
    await syncer.push();

    expect(pushed, hasLength(1), reason: '本地编辑应产生一次上行');
    final items = pushed.first['items'] as List<dynamic>;
    final item = items.first as Map<String, dynamic>;
    expect(item.containsKey('sourceUrl'), isFalse,
        reason: 'sourceUrl 只下行不上行——允许上行等于让客户端可以伪造 / 抹掉来源标记');
    expect((await repo.getNote('clip-news'))!.isClip, isTrue,
        reason: '本机 push 不得让剪藏笔记退出收件箱');
  });

  test('判据口径：sourceUrl 为主、clip: 前缀兜底、普通笔记不是剪藏（AC-266）', () async {
    await repo.createNote(id: 'n-url', title: 'a', sourceUrl: _clipURL);
    await repo.createNote(
        id: 'n-legacy', title: 'b', sourceDevice: 'clip:web-extension');
    await repo.createNote(id: 'n-plain', title: 'c', sourceDevice: 'dev-desktop');

    expect((await repo.getNote('n-url'))!.isClip, isTrue);
    expect((await repo.getNote('n-legacy'))!.isClip, isTrue,
        reason: '空 URL 剪藏 / 老服务端不下发 sourceUrl 时回落 clip: 前缀');
    expect((await repo.getNote('n-plain'))!.isClip, isFalse);
  });

  test('source_device 被服务端改写后仍为剪藏——BR-05.4 的核心（AC-265）', () async {
    await buildSyncer().pull();

    // 模拟「本机 push 被接受 → 下一次 pull」：服务端已把 source_device 改成推送设备。
    await repo.applyRemoteNoteContent(
      'clip-news',
      title: '新华网_让新闻离你更近',
      contentMarkdown: '正文',
      version: 2,
      updatedAt: DateTime.utc(2026, 10, 13, 1),
      sourceDevice: 'dev-desktop',
      sourceUrl: _clipURL,
    );

    final note = await repo.getNote('clip-news');
    expect(note!.sourceDevice, 'dev-desktop');
    expect(note.isClip, isTrue,
        reason: 'source_device 只是「最近一次修改的设备」，被改写不应让笔记退出收件箱');
  });
}
