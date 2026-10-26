import 'package:drift/native.dart';
import 'package:note_core/note_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// v0.13.2：**v9 → v10 老库升级**门禁（BR-05.1 / BR-05.4 / AC-267）。
///
/// 要点：幂等补 `source_url` 列（默认 `''`）、既有数据一字不丢；
/// 老库里的剪藏笔记在**升级后还没有 pull 到 `sourceUrl`** 时，仍凭 `source_device`
/// 的 `clip:` 前缀留在收件箱（回落判据，与升级前行为一致）。
void main() {
  test('v9 老库升级 v10：补 source_url 列、老数据不丢、剪藏判据回落 clip: 前缀', () async {
    final raw = sqlite3.openInMemory();

    // v9 形态：notes 已有 M12 的 sync_* 列与 M13 的 import_fingerprint，但**没有** source_url。
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
        sync_state INTEGER NOT NULL DEFAULT 1,
        sync_error TEXT NOT NULL DEFAULT '',
        sync_error_at INTEGER,
        sync_checked_at INTEGER,
        sync_hold INTEGER NOT NULL DEFAULT 0,
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
        sync_state INTEGER NOT NULL DEFAULT 1,
        sync_error TEXT NOT NULL DEFAULT '',
        sync_error_at INTEGER,
        sync_checked_at INTEGER,
        sync_hold INTEGER NOT NULL DEFAULT 0,
        import_fingerprint TEXT NOT NULL DEFAULT '',
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
        sync_state INTEGER NOT NULL DEFAULT 1,
        sync_error TEXT NOT NULL DEFAULT '',
        sync_error_at INTEGER,
        sync_checked_at INTEGER,
        sync_hold INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    // 升级前的老数据：一篇「剪藏」（只剩 clip: 前缀，source_device 已被 push 覆盖过）
    // 与一篇「剪藏但 source_device 也已被覆盖」的笔记，加一篇普通笔记。
    raw.execute('INSERT INTO notes '
        '(id, title, content_markdown, version, source_device, created_at, updated_at) '
        "VALUES ('n-clip', '新华网剪藏', '老正文', 3, "
        "'clip:web-extension', 1700000000, 1700000000)");
    raw.execute('INSERT INTO notes '
        '(id, title, content_markdown, version, source_device, created_at, updated_at) '
        "VALUES ('n-overwritten', '被覆盖过标记的剪藏', '老正文 2', 4, "
        "'dev-desktop', 1700000000, 1700000000)");
    raw.execute('INSERT INTO notes '
        '(id, title, content_markdown, version, source_device, created_at, updated_at) '
        "VALUES ('n-plain', '手写笔记', '手写正文', 1, 'dev-a', 1700000000, 1700000000)");
    raw.execute('PRAGMA user_version = 9');

    final db = AppDatabase(NativeDatabase.opened(raw));
    final repo = NoteRepository(db, deviceId: 'd');

    // 既有数据不丢。
    final clip = await repo.getNote('n-clip');
    expect(clip, isNotNull, reason: '升级后老笔记必须还在');
    expect(clip!.title, '新华网剪藏');
    expect(clip.contentMarkdown, '老正文');
    expect(clip.version, 3, reason: '基线镜像不被迁移改写');

    // 新列默认空串 + 回落判据成立。
    expect(clip.sourceUrl, isEmpty, reason: '迁移只补列，不凭空造来源标记');
    expect(clip.isClip, isTrue, reason: 'clip: 前缀兜底判据在升级后仍成立');

    final overwritten = await repo.getNote('n-overwritten');
    expect(overwritten!.sourceUrl, isEmpty);
    expect(overwritten.isClip, isFalse,
        reason: '仅凭被改写掉的 source_device 无法复原——由升级后第一次 pull 的 sourceUrl 送回收件箱');
    expect((await repo.getNote('n-plain'))!.isClip, isFalse);

    // 新列必须真的可写（证明 ALTER 生效，而不是查询走默认值）。
    await repo.applyRemoteNoteContent(
      'n-overwritten',
      title: '被覆盖过标记的剪藏',
      contentMarkdown: '老正文 2',
      version: 5,
      updatedAt: DateTime.utc(2026, 10, 13),
      sourceDevice: 'dev-desktop',
      sourceUrl: 'https://www.news.cn/',
    );
    final after = await repo.getNote('n-overwritten');
    expect(after!.sourceUrl, 'https://www.news.cn/');
    expect(after.isClip, isTrue, reason: 'pull 下行 sourceUrl 后重新回到收件箱（AC-267）');

    await db.close();
  });
}
