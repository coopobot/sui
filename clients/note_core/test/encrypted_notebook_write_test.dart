import 'package:drift/drift.dart' hide isNotNull;
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T29：**写入接缝**（本地加密落库 / 线上原样落库 / 未解锁拒绝写入）门禁。
///
/// 这组用例守的是两类致命错误：**明文写进加密笔记本**（泄漏）与**同一内容被加密两次**
/// （跨端读不出来）。故断言都直接读库内行，而不是只看 `getNote` 的展示结果。
void main() {
  group('加密笔记本（M10-T29）：写入接缝', () {
    late AppDatabase db;
    late NoteRepository repo;
    late NotebookKey key;
    late String nbId;

    const password = 'lock-me';

    setUp(() async {
      db = AppDatabase.memory();
      repo = NoteRepository(db, deviceId: 'd');
      final created = await NotebookCrypto.create(
        password: password,
        salt: List<int>.filled(16, 7),
      );
      key = created.key;
      final nb = await repo.createNotebook(
        name: '私密',
        encrypted: true,
        cryptoMeta: created.meta.toJson(),
      );
      nbId = nb.id;
    });

    tearDown(() => db.close());

    Future<NoteRow> storedNote(String id) async =>
        (db.select(db.notes)..where((n) => n.id.equals(id))).getSingle();

    Future<RevisionRow> storedRevision(String noteId, int version) async =>
        (db.select(db.revisions)
              ..where((r) => r.noteId.equals(noteId) & r.version.equals(version)))
            .getSingle();

    test('本地新建：笔记与首条修订都落密文，解锁态读回明文', () async {
      await repo.unlockNotebook(nbId, password);
      final n = await repo.createNote(
        notebookId: nbId,
        title: '秘密标题',
        contentMarkdown: '# 秘密正文',
      );

      final row = await storedNote(n.id);
      expect(row.encrypted, isTrue);
      expect(NotebookFieldCipher.isEnvelope(row.title), isTrue,
          reason: '标题必须加密落库');
      expect(NotebookFieldCipher.isEnvelope(row.contentMarkdown), isTrue);
      expect(row.contentMarkdown.contains('秘密'), isFalse,
          reason: '库内不得出现明文片段');

      final rev = await storedRevision(n.id, 1);
      expect(NotebookFieldCipher.isEnvelope(rev.contentMarkdown), isTrue,
          reason: '修订必须与笔记同形态（历史也不得留明文）');

      final display = (await repo.getNote(n.id))!;
      expect(display.locked, isFalse);
      expect(display.title, '秘密标题');
      expect(display.contentMarkdown, '# 秘密正文');
    });

    test('本地编辑：笔记与新增修订都落密文，读回明文', () async {
      await repo.unlockNotebook(nbId, password);
      final n = await repo.createNote(
        notebookId: nbId,
        title: 't1',
        contentMarkdown: 'c1',
      );
      final updated = await repo.updateNoteContent(
        n.id,
        title: 't2',
        contentMarkdown: 'c2',
      );
      expect(updated.title, 't2');

      final row = await storedNote(n.id);
      expect(NotebookFieldCipher.isEnvelope(row.title), isTrue);
      expect(NotebookFieldCipher.isEnvelope(row.contentMarkdown), isTrue);

      final rev = await storedRevision(n.id, 2);
      expect(NotebookFieldCipher.isEnvelope(rev.title), isTrue);
      expect((await repo.getNote(n.id))!.contentMarkdown, 'c2');
    });

    test('未解锁：本地写入被拒，且密文分毫未动', () async {
      await repo.unlockNotebook(nbId, password);
      final n = await repo.createNote(
        notebookId: nbId,
        title: 't',
        contentMarkdown: 'c',
      );
      final before = (await storedNote(n.id)).contentMarkdown;

      repo.lockNotebook(nbId);
      await expectLater(
        repo.updateNoteContent(n.id, title: 'x', contentMarkdown: 'y'),
        throwsA(isA<NotebookDecryptException>()),
      );
      expect((await storedNote(n.id)).contentMarkdown, before,
          reason: '拒绝写入不得改动密文');

      await expectLater(
        repo.createNote(notebookId: nbId, title: 'n', contentMarkdown: 'n'),
        throwsA(isA<NotebookDecryptException>()),
        reason: '未解锁不得往加密笔记本里新建明文笔记',
      );
    });

    test('线上入口（fromWire）：逐字节原样落库，绝不二次加密', () async {
      final cipher = NotebookFieldCipher(key);
      const noteId = 'note-from-wire';
      final envTitle = await cipher.encrypt(
        notebookId: nbId,
        noteId: noteId,
        field: NotebookField.title,
        plaintext: '来自对端',
      );
      final envBody = await cipher.encrypt(
        notebookId: nbId,
        noteId: noteId,
        field: NotebookField.content,
        plaintext: '对端正文',
      );

      await repo.createNote(
        id: noteId,
        notebookId: nbId,
        title: envTitle,
        contentMarkdown: envBody,
        encrypted: true,
        fromWire: true,
      );

      final row = await storedNote(noteId);
      expect(row.title, envTitle, reason: '线上入口必须逐字节原样落库');
      expect(row.contentMarkdown, envBody);
      expect(row.encrypted, isTrue);

      // 只有**一层**加密：解锁后解出来就是原文（若被二次加密，解出的仍是密文）。
      await repo.unlockNotebook(nbId, password);
      final display = (await repo.getNote(noteId))!;
      expect(display.locked, isFalse);
      expect(display.title, '来自对端');
      expect(display.contentMarkdown, '对端正文');
    });

    test('普通笔记本不受影响：明文落库、不是封装', () async {
      final plain = await repo.createNotebook(name: '普通');
      final n = await repo.createNote(
        notebookId: plain.id,
        title: '普通标题',
        contentMarkdown: '普通正文',
      );
      final row = await storedNote(n.id);
      expect(row.encrypted, isFalse);
      expect(row.title, '普通标题');
      expect(NotebookFieldCipher.isEnvelope(row.title), isFalse);
      expect((await repo.getNote(n.id))!.contentMarkdown, '普通正文');
    });
  });
}
