import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T29：**跨加密边界的移动**门禁。
///
/// 移动是最容易留下「形态错位」的操作：把明文移进加密笔记本（泄漏）、把密文移进普通笔记本
/// （显示乱码）、或只转换正文而**漏掉历史修订**（加密笔记本里留下明文历史）。
void main() {
  group('加密笔记本（M10-T29）：移入 / 移出与形态转换', () {
    late AppDatabase db;
    late NoteRepository repo;
    late String encNb;
    late String encNb2;
    late String plainNb;

    const password = 'pw';

    setUp(() async {
      db = AppDatabase.memory();
      repo = NoteRepository(db, deviceId: 'd');
      final c1 = await NotebookCrypto.create(
        password: password,
        salt: List<int>.filled(16, 1),
      );
      final c2 = await NotebookCrypto.create(
        password: password,
        salt: List<int>.filled(16, 2),
      );
      encNb = (await repo.createNotebook(
        name: '私密1',
        encrypted: true,
        cryptoMeta: c1.meta.toJson(),
      ))
          .id;
      encNb2 = (await repo.createNotebook(
        name: '私密2',
        encrypted: true,
        cryptoMeta: c2.meta.toJson(),
      ))
          .id;
      plainNb = (await repo.createNotebook(name: '普通')).id;
    });

    tearDown(() => db.close());

    Future<NoteRow> row(String id) async =>
        (db.select(db.notes)..where((n) => n.id.equals(id))).getSingle();

    Future<List<RevisionRow>> revisions(String id) async =>
        (db.select(db.revisions)..where((r) => r.noteId.equals(id))).get();

    test('普通 → 加密：笔记与**既有修订**都转为密文', () async {
      final n = await repo.createNote(
        notebookId: plainNb,
        title: '标题',
        contentMarkdown: '正文一',
      );
      await repo.updateNoteContent(n.id, contentMarkdown: '正文二'); // 制造第二条修订

      await repo.unlockNotebook(encNb, password);
      final moved = await repo.moveNoteToNotebook(n.id, encNb);

      expect(moved.notebookId, encNb);
      expect(moved.encrypted, isTrue);
      final r = await row(n.id);
      expect(NotebookFieldCipher.isEnvelope(r.title), isTrue);
      expect(r.contentMarkdown.contains('正文二'), isFalse, reason: '库内不得留明文');

      final revs = await revisions(n.id);
      expect(revs.length, greaterThanOrEqualTo(2));
      for (final rv in revs) {
        expect(
          rv.contentMarkdown.isEmpty ||
              NotebookFieldCipher.isEnvelope(rv.contentMarkdown),
          isTrue,
          reason: '既有修订必须一并转密文（历史不得留明文）',
        );
      }

      // 解锁态读回明文
      expect((await repo.getNote(n.id))!.contentMarkdown, '正文二');
    });

    test('加密 → 普通：笔记与修订都还原为明文', () async {
      await repo.unlockNotebook(encNb, password);
      final n = await repo.createNote(
        notebookId: encNb,
        title: '标题',
        contentMarkdown: '正文一',
      );
      await repo.updateNoteContent(n.id, contentMarkdown: '正文二');

      final moved = await repo.moveNoteToNotebook(n.id, plainNb);
      expect(moved.encrypted, isFalse);
      final r = await row(n.id);
      expect(NotebookFieldCipher.isEnvelope(r.title), isFalse);
      expect(r.contentMarkdown, '正文二');
      for (final rv in await revisions(n.id)) {
        expect(NotebookFieldCipher.isEnvelope(rv.contentMarkdown), isFalse,
            reason: '移出后修订也必须是明文（否则普通笔记本里出现乱码）');
      }
    });

    test('加密 → 加密换本：用目标密钥与目标 AAD 重新加密', () async {
      await repo.unlockNotebook(encNb, password);
      final n = await repo.createNote(
        notebookId: encNb,
        title: 'T',
        contentMarkdown: 'C',
      );
      final before = (await row(n.id)).contentMarkdown;

      await repo.unlockNotebook(encNb2, password);
      await repo.moveNoteToNotebook(n.id, encNb2);

      final after = (await row(n.id)).contentMarkdown;
      expect(after, isNot(before), reason: 'AAD 绑定 notebookId，换本必须重新加密');
      expect((await repo.getNote(n.id))!.contentMarkdown, 'C');
    });

    test('移入加密笔记本但**未解锁**：拒绝移动，且库内仍是明文', () async {
      final n = await repo.createNote(
        notebookId: plainNb,
        title: '标题',
        contentMarkdown: '正文',
      );
      await expectLater(
        repo.moveNoteToNotebook(n.id, encNb),
        throwsA(isA<NotebookDecryptException>()),
      );
      final r = await row(n.id);
      expect(r.notebookId, plainNb, reason: '拒绝移动不得改动归属');
      expect(r.encrypted, isFalse);
      expect(r.title, '标题', reason: '拒绝移动不得改动内容');
    });

    test('从**未解锁**的加密笔记本移出：拒绝移动，库内密文不变', () async {
      await repo.unlockNotebook(encNb, password);
      final n = await repo.createNote(
        notebookId: encNb,
        title: 'T',
        contentMarkdown: 'C',
      );
      final before = (await row(n.id)).contentMarkdown;

      repo.lockNotebook(encNb);
      await expectLater(
        repo.moveNoteToNotebook(n.id, plainNb),
        throwsA(isA<NotebookDecryptException>()),
      );
      final r = await row(n.id);
      expect(r.notebookId, encNb);
      expect(r.contentMarkdown, before, reason: '拒绝移动不得改动密文');
    });

    test('同本移动是幂等的（未解锁也不报错）', () async {
      await repo.unlockNotebook(encNb, password);
      final n = await repo.createNote(
        notebookId: encNb,
        title: 'T',
        contentMarkdown: 'C',
      );
      repo.lockNotebook(encNb);
      final same = await repo.moveNoteToNotebook(n.id, encNb);
      expect(same.locked, isTrue, reason: '同本移动不应尝试解密');
      expect(same.notebookId, encNb);
    });

    test('普通 → 普通：行为不变', () async {
      final other = await repo.createNotebook(name: '另一个普通');
      final n = await repo.createNote(
        notebookId: plainNb,
        title: '标题',
        contentMarkdown: '正文',
      );
      final moved = await repo.moveNoteToNotebook(n.id, other.id);
      expect(moved.notebookId, other.id);
      expect(moved.encrypted, isFalse);
      expect(moved.title, '标题');
      expect(moved.contentMarkdown, '正文');
    });
  });
}
