import 'dart:typed_data';

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.memory();
    repo = NoteRepository(db, deviceId: 'test-device');
  });

  tearDown(() async {
    await db.close();
  });

  group('笔记本', () {
    test('创建并读取', () async {
      final nb = await repo.createNotebook(name: '工作');
      expect(nb.id, isNotEmpty);
      expect(nb.name, '工作');
      expect((await repo.getNotebook(nb.id))?.name, '工作');
    });

    test('子笔记本 parentId', () async {
      final parent = await repo.createNotebook(name: '项目A');
      final child = await repo.createNotebook(name: '需求', parentId: parent.id);
      expect(child.parentId, parent.id);
      final tree = await repo.listNotebooksTree();
      expect(tree, hasLength(2));
    });

    test('重命名递增版本', () async {
      final nb = await repo.createNotebook(name: '旧');
      final renamed = await repo.renameNotebook(nb.id, '新');
      expect(renamed.name, '新');
      expect(renamed.version, greaterThan(nb.version));
    });
  });

  group('标签', () {
    test('创建/tagsOfNote 关联', () async {
      final note = await repo.createNote(title: 'hello', tags: ['floridian']);
      final tags = await repo.tagsOfNote(note.id);
      expect(tags.map((t) => t.name), contains('floridian'));
    });

    test('fetchOrCreateTags 幂等', () async {
      final t1 = await repo.fetchOrCreateTags(['a']);
      final t2 = await repo.fetchOrCreateTags(['a']);
      expect(t1.first.id, t2.first.id);
    });
  });

  group('笔记 CRUD', () {
    test('创建含正文与修订', () async {
      final note = await repo.createNote(
        title: '我的第一篇',
        contentMarkdown: '# 标题\n正文内容',
      );
      expect(note.title, '我的第一篇');
      expect(note.revisionCount, 1);
      final revs = await repo.listRevisions(note.id);
      expect(revs, hasLength(1));
      expect(revs.first.version, 1);
    });

    test('更新内容追加修订', () async {
      final note = await repo.createNote(contentMarkdown: 'v1');
      final v2 =
          await repo.updateNoteContent(note.id, contentMarkdown: 'v2 修改');
      // Notes.version 是服务端基线镜像，本地编辑不推进（sync-protocol §3）。
      expect(v2.version, note.version);
      expect(v2.revisionCount, 2);
      final revs = await repo.listRevisions(note.id);
      expect(revs, hasLength(2));
      expect(revs.first.version, 2);
      expect(revs.first.contentMarkdown, 'v2 修改');
      expect(revs.last.contentMarkdown, 'v1');
    });

    test('listNotes 按笔记本过滤与排序', () async {
      final nb = await repo.createNotebook(name: '收件箱');
      await repo.createNote(
          title: 'A', notebookId: nb.id, contentMarkdown: 'aa');
      await repo.createNote(title: 'B', contentMarkdown: 'bb');
      final inNotebook = await repo.listNotes(notebookId: nb.id);
      final all = await repo.listNotes();
      expect(inNotebook.single.note.title, 'A');
      expect(all, hasLength(2));
    });

    test('软删除墓碑', () async {
      final note = await repo.createNote(title: '要删');
      await repo.markNoteDeleted(note.id);
      final listed = await repo.listNotes();
      expect(listed, isEmpty);
      final still = await repo.getNote(note.id);
      expect(still!.isDeleted, isTrue);
      expect(still.deletedAt, isNotNull);
    });

    test('归档/置顶', () async {
      final note = await repo.createNote(title: 'x');
      await repo.archiveNote(note.id, true);
      await repo.pinNote(note.id, true);
      final got = await repo.getNote(note.id);
      expect(got!.archived, isTrue);
      expect(got.pinned, isTrue);
      // Notes.version 是服务端基线镜像，归档/置顶不推进（sync-protocol §3）；
      // 变更由 sync 层的 dirty 标记与 updatedAt 感知，而非版本号。
      expect(got.version, note.version);
    });

    // 回归 BUG：历史遗留库可能对同一 (noteId, version) 存有重复修订行，
    // 旧代码用 getSingleOrNull() 读取会抛 StateError: Too many elements。
    test('撞号历史安全：同号重复修订不抛 Too many elements', () async {
      final note = await repo.createNote(contentMarkdown: 'v1');
      for (var i = 0; i < 2; i++) {
        await db.into(db.revisions).insert(RevisionsCompanion.insert(
              id: 'dup-$i',
              noteId: note.id,
              version: 5,
              contentMarkdown: 'dup',
              createdAt: DateTime.now(),
            ));
      }

      // 读取同号修订应返回其一而非抛异常。
      expect(await repo.getRevision(note.id, 5), isNotNull);

      // 同步下行应用同号修订（幂等去重）也不应抛异常。
      await repo.applyRemoteNoteContent(
        note.id,
        title: 'dup',
        contentMarkdown: 'dup',
        version: 5,
        updatedAt: DateTime.now(),
      );
      final revs = (await repo.listRevisions(note.id))
          .where((r) => r.version == 5)
          .toList();
      expect(revs, isNotEmpty);
    });
  });

  group('搜索', () {
    test('关键字命中标题与正文', () async {
      await repo.createNote(title: '登山计划', contentMarkdown: '记得带水');
      await repo.createNote(title: '买菜', contentMarkdown: '苹果、牛奶');
      final hit = await repo.listNotes(search: '登山');
      expect(hit, hasLength(1));
      expect(hit.single.note.title, '登山计划');
      final hit2 = await repo.listNotes(search: '牛奶');
      expect(hit2, hasLength(1));
    });
  });

  group('BlobStore', () {
    test('LocalBlobStore 幂等写入与读取', () async {
      final store = LocalBlobStore('/tmp/sui-test-blobs');
      final bytes = Uint8List.fromList(List.generate(1024, (i) => i % 256));
      final hash = sha256Hex(bytes);

      final hash1 = await store.put(sha256: hash, bytes: bytes);
      final hash2 = await store.put(sha256: hash, bytes: bytes);
      expect(hash1, hash2);
      expect(await store.exists(hash), isTrue);

      final read = await store.read(hash);
      expect(read, isNotNull);
      expect(read!.length, 1024);

      await store.delete(hash);
      expect(await store.exists(hash), isFalse);
    });
  });
}
