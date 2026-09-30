import 'package:drift/drift.dart';

import 'connection/connection.dart';

part 'app_database.g.dart';

/// 笔记本（支持树形嵌套）。
@DataClassName('NotebookRow')
class Notebooks extends Table {
  TextColumn get id => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 标签（扁平，跨笔记组合）。
@DataClassName('TagRow')
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get version => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 笔记本体（canonical 正本 = contentMarkdown）。
@DataClassName('NoteRow')
class Notes extends Table {
  TextColumn get id => text()();
  TextColumn get notebookId => text().nullable()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get contentMarkdown => text().withDefault(const Constant(''))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  IntColumn get revisionCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  // 同步相关：version 是服务端基线镜像（仅由同步层回写）；本地草稿编号见 revisions.version
  IntColumn get version => integer().withDefault(const Constant(0))();
  TextColumn get sourceDevice => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 笔记 — 标签（多对多）。
@DataClassName('NoteTagRow')
class NoteTags extends Table {
  TextColumn get noteId => text().references(Notes, #id)();
  TextColumn get tagId => text().references(Tags, #id)();

  @override
  Set<Column> get primaryKey => {noteId, tagId};
}

/// 修订记录（历史）：存快照 + diff 增量。
@DataClassName('RevisionRow')
class Revisions extends Table {
  TextColumn get id => text()();
  TextColumn get noteId => text().references(Notes, #id)();
  IntColumn get version => integer()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get contentMarkdown => text()();
  TextColumn get diffDelta => text().nullable()();
  IntColumn get serverVersion => integer().nullable()();
  TextColumn get sourceDevice => text().withDefault(const Constant(''))();
  BoolColumn get isConflict => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 附件元数据（字节存 BlobStore，这里只存引用 + hash）。
@DataClassName('AttachmentRow')
class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get noteId => text().references(Notes, #id).nullable()();
  TextColumn get filename => text()();
  TextColumn get mimeKind => text()();
  IntColumn get byteSize => integer().withDefault(const Constant(0))();
  TextColumn get sha256 => text()();
  TextColumn get storageRef => text()();
  TextColumn get thumbnailRef => text().nullable()();
  IntColumn get embeddedPos => integer().withDefault(const Constant(0))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 本地附件缓存记账（CachedBlobStore 的 LRU 元数据）。
///
/// 每行 = 一个已知的字节内容：size 用于容量记账，lastAccessAt 用于
/// LRU 淘汰排序，refCount 表示被多少篇笔记引用（>0 才允许保留）。
///
/// [uploadedAt] 记录「服务端已确认持有该字节」的时刻，null 表示尚未确认：
/// 本机新挂载的附件在字节成功 PUT 到服务端前都是 null，由同步周期补齐。
/// 注意本表存在行 **不等于** 本地有字节（远端映射下行时也会建行）。
@DataClassName('BlobRefRow')
class BlobRefs extends Table {
  TextColumn get sha256 => text()();
  IntColumn get byteSize => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAccessAt => dateTime()();
  IntColumn get refCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get uploadedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {sha256};
}

/// 应用级键值配置（服务端地址 / Token / 本机 deviceId 等）。
///
/// 与业务表分开：这里存的是「本机如何连服务端」这类设备级偏好，
/// 不参与同步，也不需要跨端一致。
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [
  Notebooks,
  Tags,
  Notes,
  NoteTags,
  Revisions,
  Attachments,
  BlobRefs,
  Settings,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// 纯内存库（测试用）。
  AppDatabase.memory() : super(openConnection(inMemory: true));

  /// 落地库：原生在 [basePath]/sui.sqlite；Web 走浏览器持久化（忽略 [basePath]）。
  factory AppDatabase.file({String? basePath}) =>
      AppDatabase(openConnection(basePath: basePath));

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from == 1) {
            await m.addColumn(revisions, revisions.title);
          }
          if (from <= 2) {
            await m.createTable(blobRefs);
          }
          if (from <= 3) {
            await m.createTable(settings);
          }
          if (from <= 4) {
            await m.addColumn(blobRefs, blobRefs.uploadedAt);
          }
          if (from <= 5) {
            await m.addColumn(revisions, revisions.serverVersion);
            await _migrateToV6();
          }
        },
      );

  /// v5 -> v6：修正版本模型（sync-protocol §3）。
  ///
  /// 旧库把「本地修订计数器」与「服务端基线」混用于 `Notes.version`，导致版本发散、
  /// 历史出现同号重复行（触发 "Too many elements"）。这里做一次幂等修复：
  ///   1. 去重 `revisions`：同一 (note_id, version) 仅保留一行；
  ///   2. 重算每条笔记的 `revision_count`；
  ///   3. 把 `Notes.version` 归一到「现存最大修订号」，作为服务端基线镜像起点。
  Future<void> _migrateToV6() async {
    await customStatement('DELETE FROM revisions WHERE rowid NOT IN '
        '(SELECT MIN(rowid) FROM revisions GROUP BY note_id, version)');
    await customStatement('UPDATE notes SET revision_count = COALESCE('
        '(SELECT COUNT(*) FROM revisions WHERE revisions.note_id = notes.id), 0)');
    await customStatement('UPDATE notes SET version = COALESCE('
        '(SELECT MAX(version) FROM revisions WHERE revisions.note_id = notes.id), 0)');
  }

  /// 便捷：硬删除某笔记及其所有关联（测试/清理用）。
  Future<void> removeNoteCascade(String noteId) => transaction(() async {
        await (delete(noteTags)..where((t) => t.noteId.equals(noteId))).go();
        await (delete(attachments)..where((t) => t.noteId.equals(noteId))).go();
        await (delete(revisions)..where((t) => t.noteId.equals(noteId))).go();
        await (delete(notes)..where((t) => t.id.equals(noteId))).go();
      });
}