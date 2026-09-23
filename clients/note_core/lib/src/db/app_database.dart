import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

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

@DriftDatabase(tables: [
  Notebooks,
  Tags,
  Notes,
  NoteTags,
  Revisions,
  Attachments,
  BlobRefs,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// 纯内存库（测试用）。
  AppDatabase.memory() : super(NativeDatabase.memory());

  /// 落地库：文件在 [basePath]/sui.sqlite；[basePath] 为空则用当前目录。
  factory AppDatabase.file({String? basePath}) {
    final dir = basePath ?? Directory.current.path;
    final file = p.join(dir, 'sui.sqlite');
    return AppDatabase(NativeDatabase(File(file)));
  }

  @override
  int get schemaVersion => 3;

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