import 'dart:io';

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// 落盘库（`AppDatabase.file`）的持久化回归测试。
///
/// 覆盖「重启不丢数据」这一离线优先的核心承诺：写入 → 关闭 → 重新打开
/// 同一目录 → 数据仍在，且确实生成了 sqlite 文件。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sui-persist');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('文件库落盘：关闭重开后数据保留', () async {
    final db1 = AppDatabase.file(basePath: dir.path);
    final repo1 = NoteRepository(db1, deviceId: 'dev-1');
    final nb = await repo1.createNotebook(name: '工作');
    final note = await repo1.createNote(notebookId: nb.id, title: '持久化');
    await repo1.updateNoteContent(note.id, contentMarkdown: '正文内容');
    await db1.close();

    expect(File('${dir.path}/sui.sqlite').existsSync(), isTrue,
        reason: '应生成 sqlite 文件');

    final db2 = AppDatabase.file(basePath: dir.path);
    final repo2 = NoteRepository(db2, deviceId: 'dev-1');
    expect((await repo2.listNotebooks()).map((n) => n.name), contains('工作'));
    final reloaded = await repo2.getNote(note.id);
    expect(reloaded?.title, '持久化');
    expect(reloaded?.contentMarkdown, '正文内容');
    await db2.close();
  });

  test('目录不存在时自动创建', () async {
    final nested = '${dir.path}/a/b/c';
    final db = AppDatabase.file(basePath: nested);
    final repo = NoteRepository(db);
    await repo.createNotebook(name: '嵌套');
    await db.close();
    expect(File('$nested/sui.sqlite').existsSync(), isTrue);
  });
}