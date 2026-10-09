import 'package:drift/native.dart';
import 'package:note_core/note_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// M12：**v7 → v8 老库升级**门禁（FR-53 / BR-53.6）。
///
/// 要点：升级后三张表都要有同步状态列，且**保守初值**——绝不预置「已同步」
/// （离线时无法判断云端是否仍持有），首次连接核对后由同步层整体重算。
void main() {
  test('v7 老库升级 v8：补列生效、既有数据不丢、状态取保守初值', () async {
    final raw = sqlite3.openInMemory();

    // v7 形态：notebooks / notes / tags 均**没有** sync_* 列。
    raw.execute('''
      CREATE TABLE notebooks (
        id TEXT NOT NULL PRIMARY KEY,
        parent_id TEXT,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        version INTEGER NOT NULL DEFAULT 0,
        encrypted INTEGER NOT NULL DEFAULT 0,
        crypto_meta TEXT NOT NULL DEFAULT '',
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
        encrypted INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER
      );
    ''');
    raw.execute('''
      CREATE TABLE revisions (
        id TEXT NOT NULL PRIMARY KEY,
        note_id TEXT NOT NULL,
        version INTEGER NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        content_markdown TEXT NOT NULL,
        diff_delta TEXT,
        server_version INTEGER,
        source_device TEXT NOT NULL DEFAULT '',
        is_conflict INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
    ''');
    raw.execute('''
      CREATE TABLE tags (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        version INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    // 升级前就存在的数据：三种初值形态各一。
    raw.execute('INSERT INTO notebooks '
        '(id, name, version, created_at, updated_at) '
        "VALUES ('nb-old', '老笔记本（有基线）', 7, 1700000000, 1700000000)");
    raw.execute('INSERT INTO notebooks '
        '(id, name, version, created_at, updated_at) '
        "VALUES ('nb-new', '老笔记本（无基线）', 0, 1700000000, 1700000000)");
    raw.execute('INSERT INTO notes '
        '(id, title, content_markdown, version, created_at, updated_at) '
        "VALUES ('n-synced', '老标题', '老正文', 7, 1700000000, 1700000000)");
    raw.execute('INSERT INTO notes '
        '(id, title, content_markdown, version, created_at, updated_at) '
        "VALUES ('n-local', '本地标题', '本地正文', 0, 1700000000, 1700000000)");
    raw.execute('INSERT INTO notes '
        '(id, title, content_markdown, version, created_at, updated_at) '
        "VALUES ('n-draft', '草稿标题', '草稿正文', 0, 1700000000, 1700000000)");
    // `n-draft` 有一条**未被服务端确认**的修订（server_version IS NULL）。
    raw.execute('INSERT INTO revisions '
        '(id, note_id, version, content_markdown, created_at) '
        "VALUES ('r1', 'n-draft', 1, '草稿正文', 1700000000)");
    raw.execute('INSERT INTO tags '
        '(id, name, version, created_at, updated_at) '
        "VALUES ('tg-old', '老标签', 3, 1700000000, 1700000000)");
    raw.execute('PRAGMA user_version = 7');

    final db = AppDatabase(NativeDatabase.opened(raw));
    final repo = NoteRepository(db, deviceId: 'd');

    // 既有数据不丢。
    final nb = await repo.getNotebook('nb-old');
    expect(nb, isNotNull, reason: '升级后老笔记本必须还在');
    expect(nb!.name, '老笔记本（有基线）');
    expect(nb.version, 7, reason: '基线镜像不被迁移改写');

    final note = await repo.getNote('n-synced');
    expect(note, isNotNull);
    expect(note!.title, '老标题');
    expect(note.contentMarkdown, '老正文');

    // 保守初值：绝不预置「已同步」（BR-53.6）。
    expect(nb.syncState, EntitySyncState.pending,
        reason: '有服务端基线但本端无法离线确认 → 待上传（不得标已同步）');
    expect((await repo.getNotebook('nb-new'))!.syncState,
        EntitySyncState.localOnly, reason: 'version == 0 → 从未被服务端确认');
    expect((await repo.getNote('n-synced'))!.syncState,
        EntitySyncState.pending);
    expect((await repo.getNote('n-local'))!.syncState,
        EntitySyncState.localOnly);
    expect((await repo.getNote('n-draft'))!.syncState,
        EntitySyncState.pending,
        reason: '存在未确认修订 → 待上传（哪怕基线为 0）');
    expect((await repo.getTag('tg-old'))!.syncState, EntitySyncState.pending);

    // 新列必须真的可写（证明 ALTER 生效，而不是查询走默认值）。
    await repo.markSynced(SyncEntityKind.note, 'n-synced', serverVersion: 7);
    expect((await repo.getNote('n-synced'))!.syncState,
        EntitySyncState.synced);
    await repo.markFailed(
        SyncEntityKind.notebook, 'nb-old', '网络不可达（测试）');
    final failed = await repo.getNotebook('nb-old');
    expect(failed!.syncState, EntitySyncState.failed);
    expect(failed.syncError, contains('网络不可达'));

    // 上行候选：三张表都要能被取到（状态列可用）。
    expect(await repo.countNeedingUpload(), 5);

    await db.close();
  });
}
