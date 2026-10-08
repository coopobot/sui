import 'dart:convert';

// drift 也导出 `isNotNull`（查询构造用），与 matcher 同名 —— 隐藏前者。
import 'package:drift/drift.dart' hide isNotNull;
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T29：**读取接缝**（解锁 / 回锁 / 占位 / 搜索）门禁。
///
/// 库内一律是**存储形态**（密文）；本测试直接把行改写成密文来模拟「本机写入 / 对端下行」后的
/// 真实状态，再验证：未解锁只给占位（**密文绝不当明文外泄**）、解锁后给明文、回锁立刻恢复占位，
/// 以及加密笔记本的搜索只在**解密后的明文**上命中（§9.2）。
void main() {
  group('加密笔记本（M10-T29）：解锁 / 回锁与读取接缝', () {
    late AppDatabase db;
    late NoteRepository repo;
    late NotebookKey key;
    late String nbId;
    late String noteId;

    const password = 'lock-me';
    const secretTitle = '秘密标题';
    const secretBody = '# 秘密正文\n不该出现在明文处';

    setUp(() async {
      db = AppDatabase.memory();
      repo = NoteRepository(db, deviceId: 'd');

      final created = await NotebookCrypto.create(
        password: password,
        salt: List<int>.filled(16, 9),
      );
      key = created.key;

      final nb = await repo.createNotebook(
        name: '私密',
        encrypted: true,
        cryptoMeta: created.meta.toJson(),
      );
      nbId = nb.id;
      final note = await repo.createNote(
        notebookId: nbId,
        title: 'seed',
        contentMarkdown: 'seed',
      );
      noteId = note.id;

      // 改写成存储形态（密文）——模拟真实的库内状态。
      final cipher = NotebookFieldCipher(key);
      await (db.update(db.notes)..where((n) => n.id.equals(noteId)))
          .write(NotesCompanion(
        title: Value(await cipher.encrypt(
          notebookId: nbId,
          noteId: noteId,
          field: NotebookField.title,
          plaintext: secretTitle,
        )),
        contentMarkdown: Value(await cipher.encrypt(
          notebookId: nbId,
          noteId: noteId,
          field: NotebookField.content,
          plaintext: secretBody,
        )),
        encrypted: Value(true),
      ));
    });

    tearDown(() => db.close());

    test('未解锁：读取得到占位、locked=true，密文不外泄', () async {
      final n = (await repo.getNote(noteId))!;
      expect(n.locked, isTrue);
      expect(n.title, NoteRepository.lockedPlaceholderTitle);
      expect(n.contentMarkdown, isEmpty);
      expect(n.title.contains('秘密'), isFalse);
      expect(n.contentMarkdown.contains('秘密'), isFalse);

      final list = await repo.listNotes(notebookId: nbId);
      expect(list.single.note.locked, isTrue);
      expect(list.single.note.title, NoteRepository.lockedPlaceholderTitle);
    });

    test('解锁后：读取为明文（单条与列表一致）', () async {
      await repo.unlockNotebook(nbId, password);
      expect(repo.isNotebookUnlocked(nbId), isTrue);

      final n = (await repo.getNote(noteId))!;
      expect(n.locked, isFalse);
      expect(n.title, secretTitle);
      expect(n.contentMarkdown, secretBody);

      final list = await repo.listNotes(notebookId: nbId);
      expect(list.single.note.title, secretTitle);
      expect(list.single.note.contentMarkdown, secretBody);
    });

    test('回锁（单个 / 全部）后立刻恢复占位', () async {
      await repo.unlockNotebook(nbId, password);
      expect((await repo.getNote(noteId))!.title, secretTitle);

      expect(repo.lockNotebook(nbId), isTrue);
      expect((await repo.getNote(noteId))!.locked, isTrue);
      expect(repo.lockNotebook(nbId), isFalse, reason: '重复回锁应为无操作');

      await repo.unlockNotebook(nbId, password);
      repo.lockAllNotebooks();
      expect(repo.isNotebookUnlocked(nbId), isFalse);
      expect((await repo.getNote(noteId))!.locked, isTrue);
    });

    test('锁定密码错误：抛 NotebookUnlockException，且保持未解锁', () async {
      await expectLater(
        repo.unlockNotebook(nbId, 'wrong'),
        throwsA(isA<NotebookUnlockException>()),
      );
      expect(repo.isNotebookUnlocked(nbId), isFalse);
      expect((await repo.getNote(noteId))!.locked, isTrue);
    });

    test('对非加密笔记本解锁 → 明确报错（不静默成功）', () async {
      final plain = await repo.createNotebook(name: '普通');
      await expectLater(
        repo.unlockNotebook(plain.id, password),
        throwsA(isA<StateError>()),
      );
    });

    test('密文被篡改：占位并标为「无法解密」，绝不吐明文', () async {
      final row = await (db.select(db.notes)..where((n) => n.id.equals(noteId)))
          .getSingle();
      final bytes = base64.decode(row.contentMarkdown);
      final flipped = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 0x01;
      await (db.update(db.notes)..where((n) => n.id.equals(noteId)))
          .write(NotesCompanion(contentMarkdown: Value(base64.encode(flipped))));

      await repo.unlockNotebook(nbId, password);
      final n = (await repo.getNote(noteId))!;
      expect(n.locked, isTrue);
      expect(n.title, NoteRepository.damagedPlaceholderTitle);
      expect(n.contentMarkdown, isEmpty);
    });

    test('AAD 绑定：把密文搬到另一条笔记 → 解不开（占位）', () async {
      final other = await repo.createNote(
        notebookId: nbId,
        title: 'o',
        contentMarkdown: 'o',
      );
      final row = await (db.select(db.notes)..where((n) => n.id.equals(noteId)))
          .getSingle();
      await (db.update(db.notes)..where((n) => n.id.equals(other.id)))
          .write(NotesCompanion(
        title: Value(row.title),
        encrypted: Value(true),
      ));

      await repo.unlockNotebook(nbId, password);
      final o = (await repo.getNote(other.id))!;
      expect(o.locked, isTrue, reason: 'AAD 绑定 noteId，搬运后必须解不开');
    });

    test('搜索：未解锁不命中，解锁后在明文上命中（§9.2）', () async {
      expect(await repo.listNotes(search: '秘密'), isEmpty);

      await repo.unlockNotebook(nbId, password);
      final hit = await repo.listNotes(search: '秘密');
      expect(hit, hasLength(1));
      expect(hit.single.note.title, secretTitle);
      // 关键词只出现在正文里也要能命中（证明解密发生在过滤之前）
      expect(await repo.listNotes(search: '不该出现'), hasLength(1));
    });

    test('归档列表的搜索同样遵守「未解锁不命中 / 解锁后命中」', () async {
      await repo.archiveNote(noteId, true);
      expect(await repo.listArchivedNotes(search: '秘密'), isEmpty);

      await repo.unlockNotebook(nbId, password);
      expect(await repo.listArchivedNotes(search: '秘密'), hasLength(1));
    });

    test('普通笔记不受影响：无占位、可搜索、可编辑往返', () async {
      final plain = await repo.createNote(
        title: '普通笔记',
        contentMarkdown: '明文正文',
      );
      final n = (await repo.getNote(plain.id))!;
      expect(n.locked, isFalse);
      expect(n.title, '普通笔记');
      expect(n.contentMarkdown, '明文正文');

      expect(await repo.listNotes(search: '明文正文'), hasLength(1));

      final updated = await repo.updateNoteContent(
        plain.id,
        title: '普通笔记2',
        contentMarkdown: '明文正文2',
      );
      expect(updated.title, '普通笔记2');
      expect(updated.contentMarkdown, '明文正文2');
    });
  });
}
