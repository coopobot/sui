// drift 也导出 `isNotNull`（查询构造用），与 matcher 同名 —— 这里隐藏前者。
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:note_core/note_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// M10-T29：**旧库升级**门禁（v6 → v7）。
///
/// 背景：其余测试都走 `onCreate`（新库）路径，`onUpgrade` 里的 `ALTER TABLE` **从未在真实
/// v6 形态的库上跑过**。而「老用户升级后打不开库 / 丢数据」是高危后果——故这里手工造一个
/// v6 形态的库（M10 之前的列集合），再用真实迁移路径打开它。
void main() {
  test('v6 老库升级 v7：补列生效、既有数据不丢、默认非加密', () async {
    final raw = sqlite3.openInMemory();

    // v6 形态：notebooks 无 encrypted / crypto_meta；notes 无 encrypted。
    raw.execute('''
      CREATE TABLE notebooks (
        id TEXT NOT NULL PRIMARY KEY,
        parent_id TEXT,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        version INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    raw.execute('''
      CREATE TABLE notes (
        id TEXT NOT NULL PRIMARY KEY,
        notebook_id TEXT,
        title TEXT NOT NULL DEFAULT '',
        content_markdown TEXT NOT NULL DEFAULT '',
        pinned INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        revision_count INTEGER NOT NULL DEFAULT 0,
        version INTEGER NOT NULL DEFAULT 0,
        source_device TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER
      );
    ''');

    // 升级前就存在的数据（必须原样保留）。
    raw.execute('INSERT INTO notebooks '
        '(id, name, sort_order, is_deleted, version, created_at, updated_at) '
        "VALUES ('nb-old', '老笔记本', 3, 0, 7, 1700000000, 1700000000)");
    raw.execute('INSERT INTO notes '
        '(id, notebook_id, title, content_markdown, version, created_at, updated_at) '
        "VALUES ('n-old', 'nb-old', '老标题', '老正文', 7, 1700000000, 1700000000)");
    raw.execute('PRAGMA user_version = 6');

    // 用真实迁移路径打开（schemaVersion 7 → 触发 onUpgrade(6,7)）。
    final db = AppDatabase(NativeDatabase.opened(raw));
    final repo = NoteRepository(db, deviceId: 'd');

    final nb = await repo.getNotebook('nb-old');
    expect(nb, isNotNull, reason: '升级后老笔记本必须还在');
    expect(nb!.name, '老笔记本');
    expect(nb.sortOrder, 3);
    expect(nb.version, 7);
    expect(nb.encrypted, isFalse, reason: '补列默认必须是「普通笔记本」');
    expect(nb.cryptoMeta, isEmpty);

    final note = await repo.getNote('n-old');
    expect(note, isNotNull, reason: '升级后老笔记必须还在');
    expect(note!.title, '老标题');
    expect(note.contentMarkdown, '老正文');
    expect(note.notebookId, 'nb-old');
    expect(note.encrypted, isFalse);

    // 新列必须真的可写（证明 ALTER 生效，而不只是查询走默认值）。
    // 注：这里直接写列，避免在夹具里复刻整库 DDL（createNote 还要写 revisions 表）。
    await repo.upsertRemoteNotebook(
      id: 'nb-new',
      name: '新',
      version: 1,
      encrypted: true,
      cryptoMeta: '{"v":1}',
    );
    final created = await repo.getNotebook('nb-new');
    expect(created!.encrypted, isTrue);
    expect(created.cryptoMeta, '{"v":1}');

    await (db.update(db.notes)..where((n) => n.id.equals('n-old')))
        .write(const NotesCompanion(encrypted: Value(true)));
    expect((await repo.getNote('n-old'))!.encrypted, isTrue,
        reason: 'notes.encrypted 的 ALTER 必须真的生效');

    await db.close();
  });
}
