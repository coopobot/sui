import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';

/// v0.13.2（BR-05.1 / BR-05.4 / AC-265 / AC-266）：
/// 「收件箱」按**不可变的剪藏来源标记**判定，而不是按 `source_device`。
///
/// 复现背景：真 Chrome + 真扩展对新华网做全页快照 → 浮层回「✓ 剪藏成功」，
/// 但桌面端收件箱里没有这篇笔记——因为该笔记被本机 push 过一次之后，
/// `source_device` 从 `clip:web-extension` 变成了本机 deviceId（实测：客户端库里
/// 那篇剪藏的 `source_device` = 本机 deviceId），而旧判据只认 `clip:` 前缀。
void main() {
  Future<(AppDatabase, AppController, NoteRepository)> boot() async {
    final db = AppDatabase.memory();
    final repo = NoteRepository(db, deviceId: 'dev-desktop');
    final controller = AppController(repository: repo, database: db);
    await controller.bootstrap();
    return (db, controller, repo);
  }

  testWidgets('剪藏的 source_device 被本机 push 改写后，仍在「收件箱」里', (tester) async {
    final (db, controller, repo) = await boot();
    addTearDown(db.close);

    // 服务端下行过的剪藏笔记：来源标记在，device 已被本机 push 覆盖。
    await repo.createNote(
      id: 'clip-news',
      title: '新华网_让新闻离你更近',
      contentMarkdown: '正文',
      version: 2,
      sourceDevice: 'dev-desktop',
      sourceUrl: 'https://www.news.cn/',
    );
    // 负例：普通手写笔记。
    await repo.createNote(id: 'plain-1', title: '手写笔记', sourceDevice: 'dev-desktop');

    controller.selectInbox();
    await controller.refreshNotes();

    expect(controller.inboxMode, isTrue);
    final ids = controller.notes.map((n) => n.note.id).toList();
    expect(ids, contains('clip-news'), reason: '剪藏笔记必须在收件箱里（旧判据下会消失）');
    expect(ids, isNot(contains('plain-1')), reason: '普通笔记不进收件箱');
  });

  testWidgets('仅剩 clip: 前缀的老库笔记仍在「收件箱」（回落判据）', (tester) async {
    final (db, controller, repo) = await boot();
    addTearDown(db.close);

    await repo.createNote(
      id: 'clip-legacy',
      title: '老剪藏',
      sourceDevice: 'clip:web-extension',
    );
    await repo.createNote(id: 'plain-2', title: '手写笔记 2');

    controller.selectInbox();
    await controller.refreshNotes();

    final ids = controller.notes.map((n) => n.note.id).toList();
    expect(ids, contains('clip-legacy'));
    expect(ids, isNot(contains('plain-2')));
  });
}
