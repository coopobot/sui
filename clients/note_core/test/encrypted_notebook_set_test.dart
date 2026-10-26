import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M10-T29 / FR-51：**设为加密笔记本**（详细设计 §5.1）门禁。
///
/// 这条流程的真实风险**不是**派生密钥（那是原语层，已由 Spike 向量门禁覆盖），而是**漏转**：
/// 只翻 `notebooks.encrypted` 却忘了把现有笔记 / 其修订就地加密，就会在「加密笔记本」里
/// 留下**明文正文与明文历史**——而且从界面看不出来（加密笔记本列表本来是占位）。
void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.memory();
    repo = NoteRepository(db, deviceId: 'set-enc');
  });

  tearDown(() => db.close());

  test('设为加密：现有笔记与其修订一并加密，明文本地不再存在', () async {
    final nb = await repo.createNotebook(name: '要加密的');
    final a = await repo.createNote(
        notebookId: nb.id, title: '标题A', contentMarkdown: '# 正文A');
    final b = await repo.createNote(
        notebookId: nb.id, title: '标题B', contentMarkdown: '正文B');
    // 造一条修订（历史也必须加密，否则加密笔记本里留有明文历史）
    await repo.updateNoteContent(a.id, contentMarkdown: '# 正文A 第二版');

    final before = await repo.getStoredNote(a.id);
    expect(before!.encrypted, isFalse, reason: '加密前应为明文存储');

    final res = await repo.setNotebookEncrypted(nb.id, 'lock-pw');

    // ① 笔记本翻标记 + 元数据 + 版本推进
    expect(res.notebook.encrypted, isTrue);
    expect(res.notebook.cryptoMeta, contains('salt'));
    expect(res.notebook.cryptoMeta, contains('verifier'));
    expect(res.notebook.version, greaterThan(nb.version),
        reason: '版本须推进以供上行冲突判定');

    // ② 现有笔记在**存储层**已是密文，明文片段不再出现
    for (final id in [a.id, b.id]) {
      final stored = (await repo.getStoredNote(id))!;
      expect(stored.encrypted, isTrue);
      expect(NotebookFieldCipher.isEnvelope(stored.title), isTrue,
          reason: '标题必须是自描述密文封装');
      expect(stored.title, isNot(contains('标题')));
      if (stored.contentMarkdown.isNotEmpty) {
        expect(NotebookFieldCipher.isEnvelope(stored.contentMarkdown), isTrue);
        expect(stored.contentMarkdown, isNot(contains('正文')));
      }
    }

    // ③ 修订历史同样加密
    final revs = await (db.select(db.revisions)
          ..where((r) => r.noteId.equals(a.id)))
        .get();
    expect(revs, isNotEmpty, reason: '本用例应先产生一条修订');
    for (final r in revs) {
      if (r.contentMarkdown.isEmpty) continue;
      expect(NotebookFieldCipher.isEnvelope(r.contentMarkdown), isTrue,
          reason: '修订正文必须是密文');
      expect(r.contentMarkdown, isNot(contains('正文')));
    }

    // ④ 设为加密后**保持已解锁**，展示形态仍是明文（编辑器不受影响）
    expect(repo.isNotebookUnlocked(nb.id), isTrue);
    final disp = (await repo.getNote(a.id))!;
    expect(disp.locked, isFalse);
    expect(disp.title, '标题A');
    expect(disp.contentMarkdown, contains('第二版'));

    // ⑤ 回锁后立即变占位（密钥只在内存）
    repo.lockAllNotebooks();
    final locked = (await repo.getNote(a.id))!;
    expect(locked.locked, isTrue);
    expect(locked.title, NoteRepository.lockedPlaceholderTitle);

    // ⑥ 用锁定密码可重新解锁并读回
    await repo.unlockNotebook(nb.id, 'lock-pw');
    expect((await repo.getNote(a.id))!.contentMarkdown, contains('第二版'));

    // ⑦ 已是加密笔记本 → 不可重复设置
    await expectLater(
      repo.setNotebookEncrypted(nb.id, 'another'),
      throwsA(isA<StateError>()),
    );
  });

  test('设为加密不越过笔记本边界', () async {
    final enc = await repo.createNotebook(name: '加密的');
    final plain = await repo.createNotebook(name: '普通的');
    final n1 = await repo.createNote(
        notebookId: enc.id, title: 'T1', contentMarkdown: 'C1');
    final n2 = await repo.createNote(
        notebookId: plain.id, title: 'T2', contentMarkdown: 'C2');

    await repo.setNotebookEncrypted(enc.id, 'pw');

    final s1 = (await repo.getStoredNote(n1.id))!;
    final s2 = (await repo.getStoredNote(n2.id))!;
    expect(s1.encrypted, isTrue);
    expect(NotebookFieldCipher.isEnvelope(s1.title), isTrue);
    expect(s2.encrypted, isFalse, reason: '其它笔记本必须保持明文');
    expect(s2.contentMarkdown, 'C2');
    expect((await repo.getNotebook(plain.id))!.encrypted, isFalse);
  });
}
