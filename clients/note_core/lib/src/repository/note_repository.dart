import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../models/attachment.dart';
import '../models/note.dart';
import '../models/notebook.dart';
import '../models/revision.dart';
import '../models/tag.dart';
import '../models/tag_summary.dart';
import '../util/ids.dart';

/// 笔记仓储：对本地库（drift/SQLite）的领域操作。
///
/// M1 聚焦离线完整的本地增删改查；同步（M2）将基于此处的能力扩展。
//
// BUG5：根级笔记本 parentId 必须统一为 null——空串会被 UI 判为非根节点，
// 导致「创建后闪没 / 多端不同步」。
String? _normalizeParentId(String? value) =>
    (value == null || value.isEmpty) ? null : value;

class NoteRepository {
  final AppDatabase db;
  final String deviceId;

  NoteRepository(this.db, {this.deviceId = ''});

  /// ---- 笔记本 ----

  Future<Notebook> createNotebook({
    String? id,
    String? parentId,
    required String name,
    int sortOrder = 0,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    final nid = id ?? newId();
    await db.into(db.notebooks).insert(NotebooksCompanion.insert(
          id: nid,
          parentId: Value(_normalizeParentId(parentId)),
          name: name,
          sortOrder: Value(sortOrder),
          version: const Value(1),
          createdAt: t,
          updatedAt: t,
        ));
    return (await getNotebook(nid))!;
  }

  Future<Notebook?> getNotebook(String id) async {
    final row = await (db.select(db.notebooks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row?.toModel();
  }

  Future<List<Notebook>> listNotebooks({bool includeDeleted = false}) async {
    final q = db.select(db.notebooks)
      ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]);
    if (!includeDeleted) {
      q.where((t) => t.isDeleted.equals(false));
    }
    final rows = await q.get();
    return rows.map((r) => r.toModel()).toList();
  }

  Future<List<Notebook>> listNotebooksTree(
      {bool includeDeleted = false}) async {
    final all = await listNotebooks(includeDeleted: includeDeleted);
    // 返回排序后的平铺列表；树形组装由 UI 层按 parentId 递归完成
    return all;
  }

  Future<Notebook> renameNotebook(String id, String name) async {
    final notebook = await getNotebook(id);
    if (notebook == null) throw StateError('notebook not found: $id');
    await (db.update(db.notebooks)..where((t) => t.id.equals(id)))
        .write(NotebooksCompanion(
      name: Value(name),
      updatedAt: Value(DateTime.now()),
      version: Value(notebook.version + 1),
    ));
    return (await getNotebook(id))!;
  }

  Future<void> removeNotebook(String id) async {
    final notebook = await getNotebook(id);
    if (notebook == null) return;
    await (db.update(db.notebooks)..where((t) => t.id.equals(id)))
        .write(NotebooksCompanion(
      isDeleted: const Value(true),
      version: Value(notebook.version + 1),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// 修改笔记本在同级中的排序权重（BR-20.2：sortOrder 随 FR-19 同步）。
  ///
  /// 仅写 sortOrder + version + updatedAt；UI 负责计算目标位置与兄弟交换。
  /// 不删除 / 不重命名，故无需写 revision（笔记本无修订表）。
  Future<Notebook> reorderNotebook(String id, int sortOrder) async {
    final notebook = await getNotebook(id);
    if (notebook == null) throw StateError('notebook not found: $id');
    await (db.update(db.notebooks)..where((t) => t.id.equals(id)))
        .write(NotebooksCompanion(
      sortOrder: Value(sortOrder),
      version: Value(notebook.version + 1),
      updatedAt: Value(DateTime.now()),
    ));
    return (await getNotebook(id))!;
  }

  /// 把笔记本挂到新的父节点下（级联删除时把子笔记本上提到被删节点的父级）。
  ///
  /// 不校验循环引用：调用方（AppController.deleteNotebook）保证目标 parentId
  /// 是被删节点的父级，结构上不可能形成环。
  Future<Notebook> reparentNotebook(String id, String? parentId) async {
    final notebook = await getNotebook(id);
    if (notebook == null) throw StateError('notebook not found: $id');
    await (db.update(db.notebooks)..where((t) => t.id.equals(id)))
        .write(NotebooksCompanion(
      parentId: Value(_normalizeParentId(parentId)),
      version: Value(notebook.version + 1),
      updatedAt: Value(DateTime.now()),
    ));
    return (await getNotebook(id))!;
  }

  /// ---- 标签 ----

  Future<Tag> createTag(
      {String? id, required String name, DateTime? now}) async {
    final t = now ?? DateTime.now();
    final tagId = id ?? newId();
    await db.into(db.tags).insert(TagsCompanion.insert(
          id: tagId,
          name: name,
          version: const Value(1),
          createdAt: t,
          updatedAt: t,
        ));
    return (await getTag(tagId))!;
  }

  Future<Tag?> getTag(String id) async {
    final row = await (db.select(db.tags)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row?.toModel();
  }

  Future<List<Tag>> listTags({bool includeDeleted = false}) async {
    final q = db.select(db.tags);
    if (!includeDeleted) {
      q.where((t) => t.isDeleted.equals(false));
    }
    final rows = await q.get();
    return rows.map((r) => r.toModel()).toList();
  }

  Future<List<Tag>> fetchOrCreateTags(List<String> names) async {
    final out = <Tag>[];
    for (final name in names.map((e) => e.trim()).where((e) => e.isNotEmpty)) {
      final existing = await (db.select(db.tags)
            ..where((t) => t.name.equals(name) & t.isDeleted.equals(false)))
          .getSingleOrNull();
      out.add(
          existing != null ? existing.toModel() : await createTag(name: name));
    }
    return out;
  }

  Future<void> removeTag(String id) async {
    final tag = await getTag(id);
    if (tag == null) return;
    await (db.update(db.tags)..where((t) => t.id.equals(id)))
        .write(TagsCompanion(
      isDeleted: const Value(true),
      version: Value(tag.version + 1),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// 列出全部标签及其关联笔记数量（FR-22 / BR-22.1）。
  ///
  /// 数量只统计**未软删除**的笔记；已软删除的笔记不计入。
  /// 无关联笔记的标签也会返回（count=0），便于在总览中展示但置灰。
  Future<List<TagSummary>> listTagSummaries() async {
    final tags = await listTags();
    final out = <TagSummary>[];
    for (final tag in tags) {
      final rows = await (db.select(db.noteTags).join([
        innerJoin(db.notes, db.notes.id.equalsExp(db.noteTags.noteId)),
      ])
            ..where(db.noteTags.tagId.equals(tag.id))
            ..where(db.notes.isDeleted.equals(false)))
          .get();
      out.add(TagSummary(tag: tag, noteCount: rows.length));
    }
    return out;
  }

  /// ---- 笔记 ----

  Future<Note> createNote({
    String? id,
    String? notebookId,
    String title = '',
    String contentMarkdown = '',
    List<String> tags = const [],
    bool pinned = false,
    bool archived = false,
    DateTime? now,
    String? sourceDevice,
  }) async {
    final t = now ?? DateTime.now();
    final nid = id ?? newId();
    final src = sourceDevice ?? deviceId;
    await db.transaction(() async {
      await db.into(db.notes).insert(NotesCompanion.insert(
            id: nid,
            notebookId: Value(notebookId),
            title: Value(title),
            contentMarkdown: Value(contentMarkdown),
            pinned: Value(pinned),
            archived: Value(archived),
            version: const Value(1),
            createdAt: t,
            updatedAt: t,
            sourceDevice: Value(src),
          ));
      if (tags.isNotEmpty) {
        await _replaceTags(nid, tags);
      }
      // 首条修订
      await db.into(db.revisions).insert(RevisionsCompanion.insert(
            id: newId(),
            noteId: nid,
            version: 1,
            title: Value(title),
            contentMarkdown: contentMarkdown,
            sourceDevice: Value(src),
            createdAt: t,
          ));
      await (db.update(db.notes)..where((n) => n.id.equals(nid)))
          .write(NotesCompanion(revisionCount: const Value(1)));
    });
    return (await getNote(nid))!;
  }

  Future<Note?> getNote(String id) async {
    final row = await (db.select(db.notes)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row?.toModel();
  }

  Future<NoteSummary?> getNoteSummary(String id) async {
    final note = await getNote(id);
    if (note == null) return null;
    final tags = await tagsOfNote(id);
    return NoteSummary(note: note, tags: tags.map((t) => t.name).toList());
  }

  Future<List<Tag>> tagsOfNote(String noteId) async {
    final rows = await (db.select(db.tags).join([
      innerJoin(db.noteTags, db.noteTags.tagId.equalsExp(db.tags.id)),
    ])
          ..where(db.noteTags.noteId.equals(noteId))
          ..where(db.tags.isDeleted.equals(false)))
        .get();
    return rows.map((r) => r.readTable(db.tags).toModel()).toList();
  }

  /// 更新笔记正文（同时写一条修订）。
  /// 返回更新后的 [Note]。
  Future<Note> updateNoteContent(
    String id, {
    String? title,
    String? contentMarkdown,
    List<String>? tags,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    final note = await getNote(id);
    if (note == null) throw StateError('note not found: $id');

    final nextTitle = title ?? note.title;
    final nextContent = contentMarkdown ?? note.contentMarkdown;
    final nextVersion = note.version + 1;

    await db.transaction(() async {
      await _replaceTags(
          id,
          tags ??
              await tagsOfNote(id).then((v) => v.map((e) => e.name).toList()));
      await (db.update(db.notes)..where((n) => n.id.equals(id)))
          .write(NotesCompanion(
        title: Value(nextTitle),
        contentMarkdown: Value(nextContent),
        version: Value(nextVersion),
        updatedAt: Value(t),
      ));
      await db.into(db.revisions).insert(RevisionsCompanion.insert(
            id: newId(),
            noteId: id,
            version: nextVersion,
            title: Value(nextTitle),
            contentMarkdown: nextContent,
            sourceDevice: Value(deviceId),
            createdAt: t,
          ));
      await (db.update(db.notes)..where((n) => n.id.equals(id)))
          .write(NotesCompanion(revisionCount: Value(note.revisionCount + 1)));
    });
    return (await getNote(id))!;
  }

  Future<List<NoteSummary>> listNotes({
    String? notebookId,
    String? search,
    bool includeArchived = false,
  }) async {
    final notes$ = db.notes;
    final q = db.select(notes$)..where((n) => n.isDeleted.equals(false));
    if (notebookId != null) {
      q.where((n) => n.notebookId.isValue(notebookId));
    }
    if (!includeArchived) {
      q.where((n) => n.archived.equals(false));
    }
    if (search != null && search.isNotEmpty) {
      final like = '%${search.toLowerCase()}%';
      q.where((n) =>
          n.title.lower().like(like) | n.contentMarkdown.lower().like(like));
    }
    q.orderBy([(n) => OrderingTerm.desc(n.updatedAt)]);

    final rows = await q.get();
    final notes = rows.map((r) => r.toModel()).toList();

    final summaries = <NoteSummary>[];
    for (final n in notes) {
      summaries.add(NoteSummary(
          note: n, tags: (await tagsOfNote(n.id)).map((t) => t.name).toList()));
    }
    return summaries;
  }

  /// 按多个标签筛选笔记（BR-22.2：多标签取**交集**）。
  ///
  /// 与 [listNotes] 共用过滤条件（笔记本 / 搜索 / 归档），额外要求每条笔记
  /// 同时关联 `tagNames` 中的**全部**标签。空 tagNames 时退化为 [listNotes]。
  /// 仅返回未软删除的笔记。
  Future<List<NoteSummary>> listNotesByTags(
    List<String> tagNames, {
    String? notebookId,
    String? search,
    bool includeArchived = false,
  }) async {
    final names = tagNames.where((n) => n.trim().isNotEmpty).toList();
    if (names.isEmpty) {
      return listNotes(
        notebookId: notebookId,
        search: search,
        includeArchived: includeArchived,
      );
    }
    // 分别取每个标签关联的 noteId 集合，然后求交集——在 Dart 层做集合运算，
    // 避免构造复杂的 EXISTS 子查询。交集语义满足 BR-22.2。
    Set<String>? intersection;
    for (final name in names) {
      final rows = await (db.select(db.noteTags).join([
        innerJoin(db.tags, db.tags.id.equalsExp(db.noteTags.tagId)),
        innerJoin(db.notes, db.notes.id.equalsExp(db.noteTags.noteId)),
      ])
            ..where(db.tags.name.equals(name))
            ..where(db.notes.isDeleted.equals(false)))
          .get();
      final ids = rows
          .map((r) => r.read(db.noteTags.noteId))
          .whereType<String>()
          .toSet();
      if (intersection == null) {
        intersection = ids;
      } else {
        intersection = intersection.intersection(ids);
      }
      // 中途交集为空，提前退出。
      if (intersection.isEmpty) return const [];
    }
    if (intersection == null || intersection.isEmpty) return const [];
    final ids = intersection;

    // 在交集内按笔记本 / 搜索 / 归档二次过滤，再排序。
    final notes$ = db.notes;
    final q = db.select(notes$)
      ..where((n) => n.isDeleted.equals(false))
      ..where((n) => n.id.isIn(ids));
    if (notebookId != null) {
      q.where((n) => n.notebookId.isValue(notebookId));
    }
    if (!includeArchived) {
      q.where((n) => n.archived.equals(false));
    }
    if (search != null && search.isNotEmpty) {
      final like = '%${search.toLowerCase()}%';
      q.where((n) =>
          n.title.lower().like(like) | n.contentMarkdown.lower().like(like));
    }
    q.orderBy([(n) => OrderingTerm.desc(n.updatedAt)]);

    final rows = await q.get();
    final notes = rows.map((r) => r.toModel()).toList();
    final summaries = <NoteSummary>[];
    for (final n in notes) {
      summaries.add(NoteSummary(
          note: n, tags: (await tagsOfNote(n.id)).map((t) => t.name).toList()));
    }
    return summaries;
  }

  /// 用户发起的归档/取消归档（FR-25）：写入归档位并 bump version，
  /// 让 sync 能感知到这次变更（BR-19.7）。
  ///
  /// 与 [applyRemoteArchived] 区别：后者用于同步下行，不改 version。
  /// 不写 revision：归档不属于内容修订，避免污染版本链。
  Future<void> archiveNote(String id, bool archived) async {
    final note = await getNote(id);
    if (note == null) throw StateError('note not found: $id');
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(
      archived: Value(archived),
      version: Value(note.version + 1),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// 同步下行：应用远端归档状态（不改 version，版本由同步层统一维护）。
  Future<void> applyRemoteArchived(
    String id,
    bool archived, {
    DateTime? updatedAt,
  }) async {
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(
      archived: Value(archived),
      updatedAt: Value(updatedAt ?? DateTime.now()),
    ));
  }

  /// 同步下行：应用远端笔记的正文与标题，并以服务端版本为权威写回版本号。
  ///
  /// pull 的「本地已有」分支原先只落归档/笔记本/标签/附件，从不写正文，
  /// 导致对端编辑后本端正文永不更新（带附件时尤为明显：附件映射已更新、
  /// 正文却停留在旧版本）。这里按服务端版本写回，并**幂等**补一条同版本
  /// 修订，保证本地历史链与版本号一致（AC-29）。
  ///
  /// 与 [updateNoteContent] 区别：后者面向本地编辑，版本自增并触发推送；
  /// 本方法用于同步下行，版本取服务端值，不触发推送。
  Future<void> applyRemoteNoteContent(
    String id, {
    required String title,
    required String contentMarkdown,
    required int version,
    required DateTime updatedAt,
    String? sourceDevice,
  }) async {
    final note = await getNote(id);
    if (note == null) return;
    await db.transaction(() async {
      await (db.update(db.notes)..where((n) => n.id.equals(id)))
          .write(NotesCompanion(
        title: Value(title),
        contentMarkdown: Value(contentMarkdown),
        version: Value(version),
        updatedAt: Value(updatedAt),
        sourceDevice: (sourceDevice != null && sourceDevice.isNotEmpty)
            ? Value(sourceDevice)
            : const Value.absent(),
      ));
      final exists = await (db.select(db.revisions)
            ..where((r) => r.noteId.equals(id) & r.version.equals(version)))
          .getSingleOrNull();
      if (exists == null) {
        await db.into(db.revisions).insert(RevisionsCompanion.insert(
              id: newId(),
              noteId: id,
              version: version,
              title: Value(title),
              contentMarkdown: contentMarkdown,
              sourceDevice: Value(sourceDevice ?? note.sourceDevice),
              createdAt: updatedAt,
            ));
        await (db.update(db.notes)..where((n) => n.id.equals(id)))
            .write(
                NotesCompanion(revisionCount: Value(note.revisionCount + 1)));
      }
    });
  }

  Future<void> pinNote(String id, bool pinned) async {
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(
      pinned: Value(pinned),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// 用户发起的「移动到…」：写入新的 notebookId 并 bump version，
  /// 让 sync 能感知到笔记变更（BR-19.7 / BR-20.1）。
  ///
  /// 与 [updateNoteNotebook] 区别：后者只覆盖 notebookId 不 bump version，
  /// 用于同步下行；本方法面向用户操作，需要触发推送。
  /// 不写 revision：归属变更不属于内容修订，避免污染版本链。
  Future<Note> moveNoteToNotebook(String id, String? notebookId) async {
    final note = await getNote(id);
    if (note == null) throw StateError('note not found: $id');
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(
      notebookId: Value(notebookId),
      version: Value(note.version + 1),
      updatedAt: Value(DateTime.now()),
    ));
    return (await getNote(id))!;
  }

  /// 逻辑删除笔记（墓碑，保持跨端同步收敛），并连带墓碑化它的附件映射。
  ///
  /// 附件映射必须一起墓碑化：否则对端拉到笔记墓碑后本地附件行仍然「活着」，
  /// 引用计数不减、映射也收敛不到删除态。
  Future<void> markNoteDeleted(String id, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    await db.transaction(() async {
      await (db.update(db.notes)..where((n) => n.id.equals(id)))
          .write(NotesCompanion(
        isDeleted: const Value(true),
        deletedAt: Value(t),
        updatedAt: Value(t),
      ));
      final atts = await (db.select(db.attachments)
            ..where((r) => r.noteId.isValue(id) & r.isDeleted.equals(false)))
          .get();
      for (final a in atts) {
        await (db.update(db.attachments)..where((r) => r.id.equals(a.id)))
            .write(const AttachmentsCompanion(isDeleted: Value(true)));
        if (a.sha256.isNotEmpty) await _adjustBlobRef(a.sha256, -1);
      }
    });
  }

  /// 列出归档笔记（FR-25 归档视图）：未删除且已归档。
  Future<List<NoteSummary>> listArchivedNotes({String? search}) async {
    final notes$ = db.notes;
    final q = db.select(notes$)
      ..where((n) => n.isDeleted.equals(false))
      ..where((n) => n.archived.equals(true));
    if (search != null && search.isNotEmpty) {
      final like = '%${search.toLowerCase()}%';
      q.where((n) =>
          n.title.lower().like(like) | n.contentMarkdown.lower().like(like));
    }
    q.orderBy([(n) => OrderingTerm.desc(n.updatedAt)]);
    final summaries = <NoteSummary>[];
    for (final r in await q.get()) {
      final n = r.toModel();
      summaries.add(NoteSummary(
          note: n, tags: (await tagsOfNote(n.id)).map((t) => t.name).toList()));
    }
    return summaries;
  }

  /// 列出回收站笔记（FR-26）：已软删除（墓碑）。
  Future<List<NoteSummary>> listDeletedNotes({String? search}) async {
    final notes$ = db.notes;
    final q = db.select(notes$)..where((n) => n.isDeleted.equals(true));
    if (search != null && search.isNotEmpty) {
      final like = '%${search.toLowerCase()}%';
      q.where((n) =>
          n.title.lower().like(like) | n.contentMarkdown.lower().like(like));
    }
    q.orderBy([(n) => OrderingTerm.desc(n.deletedAt)]);
    final summaries = <NoteSummary>[];
    for (final r in await q.get()) {
      final n = r.toModel();
      summaries.add(NoteSummary(
          note: n, tags: (await tagsOfNote(n.id)).map((t) => t.name).toList()));
    }
    return summaries;
  }

  /// 从回收站还原笔记（FR-26）：清除墓碑；若原笔记本已不存在则归入「全部笔记」。
  ///
  /// 还原会同时把该笔记的附件映射去墓碑，并补回引用计数。
  Future<Note?> restoreNote(String id) async {
    final note = await getNote(id);
    if (note == null) return null;
    String? notebookId = note.notebookId;
    if (notebookId != null) {
      final nb = await getNotebook(notebookId);
      if (nb == null || nb.isDeleted) notebookId = null;
    }
    await db.transaction(() async {
      await (db.update(db.notes)..where((n) => n.id.equals(id)))
          .write(NotesCompanion(
        isDeleted: const Value(false),
        deletedAt: const Value<DateTime?>(null),
        notebookId: Value(notebookId),
        version: Value(note.version + 1),
        updatedAt: Value(DateTime.now()),
      ));
      final atts = await (db.select(db.attachments)
            ..where((r) => r.noteId.isValue(id) & r.isDeleted.equals(true)))
          .get();
      for (final a in atts) {
        await (db.update(db.attachments)..where((r) => r.id.equals(a.id)))
            .write(const AttachmentsCompanion(isDeleted: Value(false)));
        if (a.sha256.isNotEmpty) {
          await _adjustBlobRef(a.sha256, 1, byteSize: a.byteSize);
        }
      }
    });
    return getNote(id);
  }

  Future<List<Revision>> listRevisions(String noteId) async {
    final rows = await (db.select(db.revisions)
          ..where((t) => t.noteId.equals(noteId))
          ..orderBy([(t) => OrderingTerm.desc(t.version)]))
        .get();
    return rows.map((r) => r.toModel()).toList();
  }

  /// 获取指定版本的修订。
  Future<Revision?> getRevision(String noteId, int version) async {
    final row = await (db.select(db.revisions)
          ..where((t) => t.noteId.equals(noteId) & t.version.equals(version)))
        .getSingleOrNull();
    return row?.toModel();
  }

  /// 恢复到指定历史版本：以旧内容创建一个新版本（不重写历史）。
  ///
  /// 返回恢复后的新 Note。
  Future<Note> restoreRevision(String noteId, int version) async {
    final rev = await getRevision(noteId, version);
    if (rev == null) {
      throw StateError('revision not found: note=$noteId ver=$version');
    }
    final note = await getNote(noteId);
    if (note == null) throw StateError('note not found: $noteId');

    final t = DateTime.now();
    final nextVersion = note.version + 1;

    await db.transaction(() async {
      await (db.update(db.notes)..where((n) => n.id.equals(noteId)))
          .write(NotesCompanion(
        title: Value(rev.title),
        contentMarkdown: Value(rev.contentMarkdown),
        version: Value(nextVersion),
        updatedAt: Value(t),
      ));
      await db.into(db.revisions).insert(RevisionsCompanion.insert(
            id: newId(),
            noteId: noteId,
            version: nextVersion,
            title: Value(rev.title),
            contentMarkdown: rev.contentMarkdown,
            sourceDevice: Value(deviceId),
            createdAt: t,
          ));
      await (db.update(db.notes)..where((n) => n.id.equals(noteId)))
          .write(NotesCompanion(revisionCount: Value(note.revisionCount + 1)));
    });
    return (await getNote(noteId))!;
  }

  Future<List<Attachment>> listAttachments({
    String? noteId,
    bool includeDeleted = false,
  }) async {
    final q = db.select(db.attachments);
    if (!includeDeleted) {
      q.where((t) => t.isDeleted.equals(false));
    }
    if (noteId != null) {
      q.where((t) => t.noteId.isValue(noteId));
    }
    final rows = await q.get();
    return rows.map((r) => r.toModel()).toList();
  }

  /// 应用一条远端附件映射（以 id 为键 upsert，幂等）。
  ///
  /// 与 [addAttachment] 的分工：这是同步下行路径，除了写 `attachments` 表，
  /// 还要维护 `blob_refs` 引用计数——否则本地 LRU 会把仍被笔记引用的附件
  /// 当孤儿淘汰掉（方案 B 的记账侧）。
  Future<void> upsertRemoteAttachment(Attachment att) async {
    await db.transaction(() async {
      final prev = await (db.select(db.attachments)
            ..where((t) => t.id.equals(att.id)))
          .getSingleOrNull();

      if (prev == null) {
        await db.into(db.attachments).insert(AttachmentsCompanion.insert(
              id: att.id,
              noteId: Value(att.noteId),
              filename: att.filename,
              mimeKind: att.mimeKind,
              byteSize: Value(att.byteSize),
              sha256: att.sha256,
              storageRef: att.storageRef,
              thumbnailRef: Value(att.thumbnailRef),
              embeddedPos: Value(att.embeddedPos),
              isDeleted: Value(att.isDeleted),
              createdAt: att.createdAt,
            ));
      } else {
        await (db.update(db.attachments)..where((t) => t.id.equals(att.id)))
            .write(AttachmentsCompanion(
          noteId: Value(att.noteId),
          filename: Value(att.filename),
          mimeKind: Value(att.mimeKind),
          byteSize: Value(att.byteSize),
          sha256: Value(att.sha256),
          storageRef: Value(att.storageRef),
          thumbnailRef: Value(att.thumbnailRef),
          embeddedPos: Value(att.embeddedPos),
          isDeleted: Value(att.isDeleted),
        ));
      }

      final wasActive =
          prev != null && !prev.isDeleted && prev.sha256.isNotEmpty;
      final nowActive = !att.isDeleted && att.sha256.isNotEmpty;
      if (!wasActive && nowActive) {
        await _adjustBlobRef(att.sha256, 1, byteSize: att.byteSize);
      } else if (wasActive && !nowActive) {
        await _adjustBlobRef(prev.sha256, -1);
      } else if (wasActive && nowActive && prev.sha256 != att.sha256) {
        await _adjustBlobRef(prev.sha256, -1);
        await _adjustBlobRef(att.sha256, 1, byteSize: att.byteSize);
      }
    });
  }

  /// 调整本地 `blob_refs` 引用计数（不存在且 delta>0 时补建记账行）。
  Future<void> _adjustBlobRef(
    String sha256,
    int delta, {
    int byteSize = 0,
  }) async {
    if (sha256.isEmpty || delta == 0) return;
    final existing = await (db.select(db.blobRefs)
          ..where((t) => t.sha256.equals(sha256)))
        .getSingleOrNull();
    if (existing == null) {
      if (delta < 0) return;
      await db.into(db.blobRefs).insert(BlobRefsCompanion.insert(
            sha256: sha256,
            byteSize: Value(byteSize),
            lastAccessAt: DateTime.now(),
            refCount: Value(delta),
          ));
      return;
    }
    final next = existing.refCount + delta;
    await (db.update(db.blobRefs)..where((t) => t.sha256.equals(sha256)))
        .write(BlobRefsCompanion(refCount: Value(next < 0 ? 0 : next)));
  }

  /// 为笔记挂载一个附件（写入附件元数据行 + 本地引用计数 +1）。
  ///
  /// [sha256] 为内容地址；字节本身已通过 BlobStore 落盘（此处只管引用）。
  /// 计数是方案 B 的关键一环：没有它，新挂载的附件会被 LRU 当孤儿淘汰。
  /// 返回新创建的 [Attachment]。
  Future<Attachment> addAttachment({
    String? id,
    required String noteId,
    required String filename,
    required String mimeKind,
    int byteSize = 0,
    required String sha256,
    String? storageRef,
    String? thumbnailRef,
    int embeddedPos = 0,
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    final aid = id ?? newId();
    await db.transaction(() async {
      await db.into(db.attachments).insert(AttachmentsCompanion.insert(
            id: aid,
            noteId: Value(noteId),
            filename: filename,
            mimeKind: mimeKind,
            byteSize: Value(byteSize),
            sha256: sha256,
            storageRef: storageRef ?? sha256,
            thumbnailRef: Value(thumbnailRef),
            embeddedPos: Value(embeddedPos),
            createdAt: t,
          ));
      if (sha256.isNotEmpty) {
        await _adjustBlobRef(sha256, 1, byteSize: byteSize);
      }
    });
    return (await _attachmentById(aid))!;
  }

  /// 软删除附件，并把引用计数减回去。
  ///
  /// 不减计数的话 blob 永远成不了孤儿，缓存只增不减（LRU 也救不回来）。
  Future<void> removeAttachment(String id) async {
    await db.transaction(() async {
      final prev = await (db.select(db.attachments)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (prev == null) return;
      await (db.update(db.attachments)..where((t) => t.id.equals(id)))
          .write(const AttachmentsCompanion(isDeleted: Value(true)));
      if (!prev.isDeleted && prev.sha256.isNotEmpty) {
        await _adjustBlobRef(prev.sha256, -1);
      }
    });
  }

  Future<Attachment?> _attachmentById(String id) async {
    final row = await (db.select(db.attachments)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row?.toModel();
  }

  /// ---- 同步下行：远端笔记本 / 标签 / 关联落库 ----

  /// Upsert 远端笔记本（pull 下行）。以 id 为键，version 以服务端为准。
  Future<void> upsertRemoteNotebook({
    required String id,
    String? parentId,
    required String name,
    int sortOrder = 0,
    bool isDeleted = false,
    int version = 0,
    DateTime? updatedAt,
  }) async {
    final t = updatedAt ?? DateTime.now();
    final existing = await getNotebook(id);
    final pid = _normalizeParentId(parentId);
    if (existing == null) {
      await db.into(db.notebooks).insert(NotebooksCompanion.insert(
            id: id,
            parentId: Value(pid),
            name: name,
            sortOrder: Value(sortOrder),
            isDeleted: Value(isDeleted),
            version: Value(version),
            createdAt: t,
            updatedAt: t,
          ));
    } else {
      await (db.update(db.notebooks)..where((t) => t.id.equals(id)))
          .write(NotebooksCompanion(
        parentId: Value(pid),
        name: Value(name),
        sortOrder: Value(sortOrder),
        isDeleted: Value(isDeleted),
        version: Value(version),
        updatedAt: Value(t),
      ));
    }
  }

  /// Upsert 远端标签（pull 下行）。
  Future<void> upsertRemoteTag({
    required String id,
    required String name,
    bool isDeleted = false,
    int version = 0,
    DateTime? updatedAt,
  }) async {
    final t = updatedAt ?? DateTime.now();
    final existing = await getTag(id);
    if (existing == null) {
      await db.into(db.tags).insert(TagsCompanion.insert(
            id: id,
            name: name,
            isDeleted: Value(isDeleted),
            version: Value(version),
            createdAt: t,
            updatedAt: t,
          ));
    } else {
      await (db.update(db.tags)..where((t) => t.id.equals(id)))
          .write(TagsCompanion(
        name: Value(name),
        isDeleted: Value(isDeleted),
        version: Value(version),
        updatedAt: Value(t),
      ));
    }
  }

  /// 以笔记为粒度整体替换标签关联（同步下行，按 tag ID 直接关联）。
  Future<void> syncNoteTags(String noteId, List<String> tagIds) async {
    await (db.delete(db.noteTags)..where((t) => t.noteId.equals(noteId))).go();
    for (final tagId in tagIds) {
      if (tagId.isEmpty) continue;
      await db.into(db.noteTags).insert(
            NoteTagsCompanion.insert(noteId: noteId, tagId: tagId),
          );
    }
  }

  /// 更新笔记的所属笔记本（同步下行）。
  Future<void> updateNoteNotebook(String noteId, String? notebookId) async {
    await (db.update(db.notes)..where((n) => n.id.equals(noteId)))
        .write(NotesCompanion(notebookId: Value(notebookId)));
  }

  Future<void> _replaceTags(String noteId, List<String> tagNames) async {
    await (db.delete(db.noteTags)..where((t) => t.noteId.equals(noteId))).go();
    if (tagNames.isEmpty) return;
    final tags = await fetchOrCreateTags(tagNames);
    for (final tag in tags) {
      await db.into(db.noteTags).insert(NoteTagsCompanion.insert(
            noteId: noteId,
            tagId: tag.id,
          ));
    }
  }
}

// ---- Row → Model 映射（避免 drift 数据类外泄到域层） ----

extension _NotebookRowEx on NotebookRow {
  Notebook toModel() => Notebook(
        id: id,
        parentId: _normalizeParentId(parentId),
        name: name,
        sortOrder: sortOrder,
        isDeleted: isDeleted,
        createdAt: createdAt,
        updatedAt: updatedAt,
        version: version,
      );
}

extension _TagRowEx on TagRow {
  Tag toModel() => Tag(
        id: id,
        name: name,
        isDeleted: isDeleted,
        createdAt: createdAt,
        updatedAt: updatedAt,
        version: version,
      );
}

extension _NoteRowEx on NoteRow {
  Note toModel() => Note(
        id: id,
        notebookId: notebookId,
        title: title,
        contentMarkdown: contentMarkdown,
        pinned: pinned,
        archived: archived,
        isDeleted: isDeleted,
        revisionCount: revisionCount,
        createdAt: createdAt,
        updatedAt: updatedAt,
        deletedAt: deletedAt,
        version: version,
        sourceDevice: sourceDevice,
      );
}

extension _RevisionRowEx on RevisionRow {
  Revision toModel() => Revision(
        id: id,
        noteId: noteId,
        version: version,
        title: title,
        contentMarkdown: contentMarkdown,
        diffDelta: diffDelta,
        sourceDevice: sourceDevice,
        isConflict: isConflict,
        createdAt: createdAt,
      );
}

extension _AttachmentRowEx on AttachmentRow {
  Attachment toModel() => Attachment(
        id: id,
        noteId: noteId,
        filename: filename,
        mimeKind: mimeKind,
        byteSize: byteSize,
        sha256: sha256,
        storageRef: storageRef,
        thumbnailRef: thumbnailRef,
        embeddedPos: embeddedPos,
        isDeleted: isDeleted,
        createdAt: createdAt,
      );
}
