import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';

/// M10-T29：控制器侧的解锁 / 回锁 / 空闲自动回锁门禁（详细设计 §6.1 / §7 / §11）。
///
/// 关注点：`K_nb` **只在内存**（回锁即失效）、界面必须**立刻**从明文退回占位、
/// 被回锁拦住时**绝不能写入**（否则占位会被当成内容覆盖密文）。
void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late AppController controller;

  const password = 'pw';
  const idle = Duration(milliseconds: 120);

  setUp(() {
    db = AppDatabase.memory();
    repo = NoteRepository(db, deviceId: 'd');
    controller = AppController(
      repository: repo,
      database: db,
      autoRelockIdle: idle,
    );
  });

  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  /// 造一个加密笔记本，并返回它的 `K_nb`（供夹具直接产出存储形态的密文）。
  Future<({String nbId, NotebookKey key})> seedEncryptedNotebook() async {
    final created = await NotebookCrypto.create(
      password: password,
      salt: List<int>.filled(16, 3),
    );
    final nb = await repo.createNotebook(
      name: '私密',
      encrypted: true,
      cryptoMeta: created.meta.toJson(),
    );
    return (nbId: nb.id, key: created.key);
  }

  /// 以**线上形态**落一条密文笔记（未解锁时本地写入按设计会被拒绝，故走 `fromWire`）。
  Future<String> seedCipherNote(
    String nbId,
    NotebookKey key,
    String title,
    String body,
  ) async {
    const noteId = 'note-1';
    final c = NotebookFieldCipher(key);
    await repo.createNote(
      id: noteId,
      notebookId: nbId,
      title: await c.encrypt(
        notebookId: nbId,
        noteId: noteId,
        field: NotebookField.title,
        plaintext: title,
      ),
      contentMarkdown: await c.encrypt(
        notebookId: nbId,
        noteId: noteId,
        field: NotebookField.content,
        plaintext: body,
      ),
      encrypted: true,
      fromWire: true,
    );
    return noteId;
  }

  test('解锁：密码错误返回 false 且保持锁定；正确密码返回 true', () async {
    final s = await seedEncryptedNotebook();

    expect(await controller.unlockNotebook(s.nbId, 'bad'), isFalse);
    expect(controller.isNotebookUnlocked(s.nbId), isFalse);
    expect(controller.hasUnlockedNotebook, isFalse);

    expect(await controller.unlockNotebook(s.nbId, password), isTrue);
    expect(controller.isNotebookUnlocked(s.nbId), isTrue);
    expect(controller.hasUnlockedNotebook, isTrue);
  });

  test('列表：解锁前是占位、解锁后是明文、回锁后立刻回到占位', () async {
    final s = await seedEncryptedNotebook();
    await seedCipherNote(s.nbId, s.key, '秘密标题', '秘密正文');

    await controller.refreshNotes();
    expect(controller.notes.single.note.locked, isTrue);
    expect(controller.notes.single.note.title,
        NoteRepository.lockedPlaceholderTitle);
    expect(controller.notes.single.note.contentMarkdown, isEmpty);

    await controller.unlockNotebook(s.nbId, password);
    expect(controller.notes.single.note.locked, isFalse);
    expect(controller.notes.single.note.title, '秘密标题');
    expect(controller.notes.single.note.contentMarkdown, '秘密正文');

    await controller.lockNotebook(s.nbId);
    expect(controller.notes.single.note.locked, isTrue);
    expect(controller.notes.single.note.title,
        NoteRepository.lockedPlaceholderTitle);
    expect(controller.isNotebookUnlocked(s.nbId), isFalse);
  });

  test('空闲超时：无操作即自动回锁（§7）', () async {
    final s = await seedEncryptedNotebook();
    await controller.unlockNotebook(s.nbId, password);
    expect(controller.hasUnlockedNotebook, isTrue);

    await Future<void>.delayed(idle + const Duration(milliseconds: 150));
    expect(controller.hasUnlockedNotebook, isFalse, reason: '空闲应自动回锁');
    expect(controller.isNotebookUnlocked(s.nbId), isFalse);
  });

  test('持续活动会续期：不应在编辑过程中被回锁', () async {
    final s = await seedEncryptedNotebook();
    await controller.unlockNotebook(s.nbId, password);

    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await controller.createNote(notebookId: s.nbId); // 解锁态操作 = 活动
    }
    expect(controller.hasUnlockedNotebook, isTrue, reason: '持续活动不得被回锁');

    await Future<void>.delayed(idle + const Duration(milliseconds: 200));
    expect(controller.hasUnlockedNotebook, isFalse);
  });

  test('被回锁拦住时保存：给提示、**不写入**（密文不被占位覆盖）', () async {
    final s = await seedEncryptedNotebook();
    await controller.unlockNotebook(s.nbId, password);
    final created = await repo.createNote(
      notebookId: s.nbId,
      title: 'T',
      contentMarkdown: 'C',
    );
    final before = (await repo.getStoredNote(created.id))!.contentMarkdown;

    await controller.lockAllNotebooks();
    await controller.saveNote(created.id, content: '新内容');

    expect(controller.lockedNotice, isNotNull);
    expect((await repo.getStoredNote(created.id))!.contentMarkdown, before,
        reason: '被拒的写入不得改动密文');

    controller.clearLockedNotice();
    expect(controller.lockedNotice, isNull);
  });

  test('往未解锁的加密笔记本新建：给提示且不产生笔记', () async {
    final s = await seedEncryptedNotebook();
    await controller.createNote(notebookId: s.nbId);

    expect(controller.lockedNotice, isNotNull);
    await controller.refreshNotes();
    expect(controller.notes, isEmpty, reason: '未解锁不得新建（否则就是明文入库）');
  });

  test('普通笔记本不受影响：编辑照常保存', () async {
    final plain = await repo.createNotebook(name: '普通');
    final n = await repo.createNote(notebookId: plain.id, title: 'T');
    await controller.saveNote(n.id, content: '正文');
    expect(controller.lockedNotice, isNull);
    expect((await repo.getNote(n.id))!.contentMarkdown, '正文');
  });
}
