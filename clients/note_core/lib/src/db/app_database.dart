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
  // M10-T29（FR-51）：是否加密笔记本 + 非敏感加密元数据（算法 / KDF 参数 / salt / verifier）。
  BoolColumn get encrypted => boolean().withDefault(const Constant(false))();
  TextColumn get cryptoMeta => text().withDefault(const Constant(''))();
  // M12（FR-53）：逐项同步状态 —— **纯本地记账**（不进同步净荷、服务端不存储）。
  // 0=已同步 / 1=待上传 / 2=仅本地 / 3=冲突 / 4=同步失败（见 EntitySyncState）。
  IntColumn get syncState => integer().withDefault(const Constant(1))();
  TextColumn get syncError => text().withDefault(const Constant(''))();
  DateTimeColumn get syncErrorAt => dateTime().nullable()();
  DateTimeColumn get syncCheckedAt => dateTime().nullable()();
  // M12：用户选择「以云端为准」后**按住**的项（`sync_state == 仅本地` 且不再自动上行）；
  // 单项重试 / 核对补齐会清除该标记（FR-55 / BR-55.2）。
  BoolColumn get syncHold => boolean().withDefault(const Constant(false))();

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
  // M12（FR-53）：逐项同步状态 —— **纯本地记账**（不进同步净荷、服务端不存储）。
  // 0=已同步 / 1=待上传 / 2=仅本地 / 3=冲突 / 4=同步失败（见 EntitySyncState）。
  IntColumn get syncState => integer().withDefault(const Constant(1))();
  TextColumn get syncError => text().withDefault(const Constant(''))();
  DateTimeColumn get syncErrorAt => dateTime().nullable()();
  DateTimeColumn get syncCheckedAt => dateTime().nullable()();
  // M12：用户选择「以云端为准」后**按住**的项（`sync_state == 仅本地` 且不再自动上行）；
  // 单项重试 / 核对补齐会清除该标记（FR-55 / BR-55.2）。
  BoolColumn get syncHold => boolean().withDefault(const Constant(false))();

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
  // M10-T29（FR-51）：镜像所属笔记本的加密状态（供列表占位与不解密搬运，避免联表）。
  BoolColumn get encrypted => boolean().withDefault(const Constant(false))();
  // M12（FR-53）：逐项同步状态 —— **纯本地记账**（不进同步净荷、服务端不存储）。
  // 0=已同步 / 1=待上传 / 2=仅本地 / 3=冲突 / 4=同步失败（见 EntitySyncState）。
  IntColumn get syncState => integer().withDefault(const Constant(1))();
  TextColumn get syncError => text().withDefault(const Constant(''))();
  DateTimeColumn get syncErrorAt => dateTime().nullable()();
  DateTimeColumn get syncCheckedAt => dateTime().nullable()();
  // M12：用户选择「以云端为准」后**按住**的项（`sync_state == 仅本地` 且不再自动上行）；
  // 单项重试 / 核对补齐会清除该标记（FR-55 / BR-55.2）。
  BoolColumn get syncHold => boolean().withDefault(const Constant(false))();

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
  int get schemaVersion => 8;

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
          if (from <= 6) {
            await _migrateToV7(m);
          }
          if (from <= 7) {
            await _migrateToV8(m);
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

  /// v6 -> v7：加密笔记本（M10-T29 / FR-51）——**幂等补列**，不改动既有数据。
  ///
  /// 三列均有默认值（`false` / `''`）：升级前的老库、以及**未解锁端**照旧把密文当不透明
  /// 字符串搬运与展示占位，不解析、不解密。
  Future<void> _migrateToV7(Migrator m) async {
    await m.addColumn(notebooks, notebooks.encrypted);
    await m.addColumn(notebooks, notebooks.cryptoMeta);
    await m.addColumn(notes, notes.encrypted);
  }

  /// v7 -> v8：逐项同步状态（M12 / FR-53）。
  ///
  /// **保守初值**（守 BR-53.6「不得凭空标为已同步」）：
  ///   * 存在未确认修订（`revisions.server_version IS NULL`）→ 待上传（列默认值）；
  ///   * 否则 `version == 0`（从未被任何服务端确认）→ 仅本地；
  ///   * 其余（`version > 0`，有服务端基线但本端无法离线确认）→ 待上传。
  /// 首次连接并完成核对后由同步层**整体重算**（BR-55.4）。
  Future<void> _migrateToV8(Migrator m) async {
    // 幂等 + 容错：真实 v7 库八表齐全；合成 / 部分库（如迁移用例的最小化夹具）可能缺表，
    // 逐表探测后再补列，避免「老库打不开」。
    if (await _hasTable('notes')) {
      await m.addColumn(notes, notes.syncState);
      await m.addColumn(notes, notes.syncError);
      await m.addColumn(notes, notes.syncErrorAt);
      await m.addColumn(notes, notes.syncCheckedAt);
      await m.addColumn(notes, notes.syncHold);
      final hasRevisions = await _hasTable('revisions');
      await customStatement('UPDATE notes SET sync_state = 2 WHERE version = 0'
          '${hasRevisions ? ' AND NOT EXISTS (SELECT 1 FROM revisions r '
              'WHERE r.note_id = notes.id AND r.server_version IS NULL)' : ''}');
    }
    if (await _hasTable('notebooks')) {
      await m.addColumn(notebooks, notebooks.syncState);
      await m.addColumn(notebooks, notebooks.syncError);
      await m.addColumn(notebooks, notebooks.syncErrorAt);
      await m.addColumn(notebooks, notebooks.syncCheckedAt);
      await m.addColumn(notebooks, notebooks.syncHold);
      await customStatement(
          'UPDATE notebooks SET sync_state = 2 WHERE version = 0');
    }
    if (await _hasTable('tags')) {
      await m.addColumn(tags, tags.syncState);
      await m.addColumn(tags, tags.syncError);
      await m.addColumn(tags, tags.syncErrorAt);
      await m.addColumn(tags, tags.syncCheckedAt);
      await m.addColumn(tags, tags.syncHold);
      await customStatement('UPDATE tags SET sync_state = 2 WHERE version = 0');
    }
  }

  /// 该库里是否已存在某张表（迁移容错用；只读 `sqlite_master`）。
  Future<bool> _hasTable(String name) async {
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }

  /// 便捷：硬删除某笔记及其所有关联（测试/清理用）。
  Future<void> removeNoteCascade(String noteId) => transaction(() async {
        await (delete(noteTags)..where((t) => t.noteId.equals(noteId))).go();
        await (delete(attachments)..where((t) => t.noteId.equals(noteId))).go();
        await (delete(revisions)..where((t) => t.noteId.equals(noteId))).go();
        await (delete(notes)..where((t) => t.id.equals(noteId))).go();
      });
}