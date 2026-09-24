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
  // 同步相关：base 指向服务端权威版本；本地未同步草稿走同表版本计数
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
/// 每行 = 一个已缓存的字节内容：size 用于容量记账，lastAccessAt 用于
/// LRU 淘汰排序，refCount 表示被多少篇笔记引用（>0 才允许保留）。
@DataClassName('BlobRefRow')
class BlobRefs extends Table {
  TextColumn get sha256 => text()();
  IntColumn get byteSize => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastAccessAt => dateTime()();
  IntColumn get refCount => integer().withDefault(const Constant(0))();

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
  int get schemaVersion => 4;

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
        },
      );

  /// 便捷：硬删除某笔记及其所有关联（测试/清理用）。
  Future<void> removeNoteCascade(String noteId) => transaction(() async {
        await (delete(noteTags)..where((t) => t.noteId.equals(noteId))).go();
        await (delete(attachments)..where((t) => t.noteId.equals(noteId))).go();
        await (delete(revisions)..where((t) => t.noteId.equals(noteId))).go();
        await (delete(notes)..where((t) => t.id.equals(noteId))).go();
      });
}