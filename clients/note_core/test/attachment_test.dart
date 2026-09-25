import 'dart:typed_data';

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// 附件挂载/摘除的记账闭环：附件行与 `blob_refs` 引用计数必须同步增减，
/// 否则 LRU 会把仍被引用的附件当孤儿淘汰（方案 B 的记账侧）。
void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late SqliteBlobCacheMeta meta;

  setUp(() {
    db = AppDatabase.memory();
    repo = NoteRepository(db, deviceId: 'test-device');
    meta = SqliteBlobCacheMeta(db);
  });

  tearDown(() => db.close());

  test('sha256Hex 为内容地址（稳定、区分内容）', () {
    final a = sha256Hex(Uint8List.fromList('hello'.codeUnits));
    final b = sha256Hex(Uint8List.fromList('hello'.codeUnits));
    final c = sha256Hex(Uint8List.fromList('hellp'.codeUnits));
    expect(a, b);
    expect(a, isNot(c));
    expect(a.length, 64);
    // 已知向量：sha256("hello")
    expect(a,
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
  });

  test('mimeKindFor 按扩展名归类，未知归 other', () {
    expect(mimeKindFor('图.PNG'), 'image');
    expect(mimeKindFor('doc.pdf'), 'pdf');
    expect(mimeKindFor('clip.mp4'), 'video');
    expect(mimeKindFor('a.mp3'), 'audio');
    expect(mimeKindFor('notes.md'), 'text');
    expect(mimeKindFor('pack.tar'), 'archive');
    expect(mimeKindFor('noext'), 'other');
    expect(mimeKindFor('trailing.'), 'other');
  });

  test('addAttachment 计入引用，removeAttachment 减回', () async {
    final note = await repo.createNote(title: 'A');
    final att = await repo.addAttachment(
      noteId: note.id,
      filename: '图.png',
      mimeKind: 'image',
      byteSize: 4096,
      sha256: 'sha-1',
    );

    final e1 = await meta.entry('sha-1');
    expect(e1!.refCount, 1);
    expect(e1.byteSize, 4096);

    await repo.removeAttachment(att.id);
    expect(await repo.listAttachments(noteId: note.id), isEmpty);
    expect((await meta.entry('sha-1'))!.refCount, 0, reason: '摘除后应成为孤儿');
  });

  test('同一附件重复摘除不重复扣减', () async {
    final note = await repo.createNote(title: 'A');
    final att = await repo.addAttachment(
      noteId: note.id,
      filename: 'a.txt',
      mimeKind: 'text',
      byteSize: 10,
      sha256: 'sha-2',
    );
    await repo.removeAttachment(att.id);
    await repo.removeAttachment(att.id);
    expect((await meta.entry('sha-2'))!.refCount, 0);
  });

  test('删除笔记连带墓碑化其附件并释放引用', () async {
    final note = await repo.createNote(title: 'A');
    await repo.addAttachment(
      noteId: note.id,
      filename: 'a.txt',
      mimeKind: 'text',
      byteSize: 10,
      sha256: 'sha-3',
    );
    await repo.addAttachment(
      noteId: note.id,
      filename: 'b.txt',
      mimeKind: 'text',
      byteSize: 20,
      sha256: 'sha-4',
    );
    expect((await meta.entry('sha-3'))!.refCount, 1);

    await repo.markNoteDeleted(note.id);

    // 墓碑随笔记一起同步，因此查询（含 includeDeleted）应能看到已删除的映射。
    final all = await repo.listAttachments(noteId: note.id, includeDeleted: true);
    expect(all, hasLength(2));
    expect(all.every((a) => a.isDeleted), isTrue);
    expect((await meta.entry('sha-3'))!.refCount, 0);
    expect((await meta.entry('sha-4'))!.refCount, 0);
  });

  test('同一 sha 被两篇笔记引用时计数为 2，摘一个仍有引用', () async {
    final n1 = await repo.createNote(title: 'A');
    final n2 = await repo.createNote(title: 'B');
    for (final n in [n1, n2]) {
      await repo.addAttachment(
        noteId: n.id,
        filename: 'same.txt',
        mimeKind: 'text',
        byteSize: 5,
        sha256: 'sha-5',
      );
    }
    expect((await meta.entry('sha-5'))!.refCount, 2);

    final first = (await repo.listAttachments(noteId: n1.id)).single;
    await repo.removeAttachment(first.id);
    expect((await meta.entry('sha-5'))!.refCount, 1, reason: '另一篇仍引用，不该被淘汰');
  });
}