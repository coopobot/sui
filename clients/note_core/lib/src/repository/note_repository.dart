import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../models/attachment.dart';
import '../models/note.dart';
import '../models/notebook.dart';
import '../models/revision.dart';
import '../models/tag.dart';
import '../util/ids.dart';

/// 笔记仓储：对本地库（drift/SQLite）的领域操作。
///
/// M1 聚焦离线完整的本地增删改查；同步（M2）将基于此处的能力扩展。
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
          parentId: Value(parentId),
          name: name,
          sortOrder: Value(sortOrder),
          createdAt: t,
          updatedAt: t,
        ));
    return (await getNotebook(nid))!;
  }

  Future<Notebook?> getNotebook(String id) async {
    final row = await (db.select(db.notebooks)
          ..where((t) => t.id.equals(id)))
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

  Future<List<Notebook>> listNotebooksTree({bool includeDeleted = false}) async {
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
    await (db.update(db.notebooks)..where((t) => t.id.equals(id)))
        .write(NotebooksCompanion(
      isDeleted: const Value(true),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// ---- 标签 ----

  Future<Tag> createTag({String? id, required String name, DateTime? now}) async {
    final t = now ?? DateTime.now();
    final tagId = id ?? newId();
    await db.into(db.tags).insert(TagsCompanion.insert(
          id: tagId,
          name: name,
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

  Future<List<Tag>> listTags() async {
    final rows = await (db.select(db.tags)
          ..where((t) => t.isDeleted.equals(false)))
        .get();
    return rows.map((r) => r.toModel()).toList();
  }

  Future<List<Tag>> fetchOrCreateTags(List<String> names) async {
    final out = <Tag>[];
    for (final name in names.map((e) => e.trim()).where((e) => e.isNotEmpty)) {
      final existing = await (db.select(db.tags)
            ..where((t) => t.name.equals(name) & t.isDeleted.equals(false)))
          .getSingleOrNull();
      out.add(existing != null ? existing.toModel() : await createTag(name: name));
    }
    return out;
  }

  Future<void> removeTag(String id) async {
    await (db.update(db.tags)..where((t) => t.id.equals(id)))
        .write(TagsCompanion(isDeleted: const Value(true)));
  }

  /// ---- 笔记 ----

  Future<Note> createNote({
    String? id,
    String? notebookId,
    String title = '',
    String contentMarkdown = '',
    List<String> tags = const [],
    bool pinned = false,
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
      await _replaceTags(id, tags ?? await tagsOfNote(id).then((v) => v.map((e) => e.name).toList()));
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
    final q = db.select(notes$)
      ..where((n) => n.isDeleted.equals(false));
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
      summaries.add(NoteSummary(note: n, tags: (await tagsOfNote(n.id)).map((t) => t.name).toList()));
    }
    return summaries;
  }

  Future<void> archiveNote(String id, bool archived) async {
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(
      archived: Value(archived),
      updatedAt: Value(DateTime.now()),
    ));
  }

  Future<void> pinNote(String id, bool pinned) async {
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(
      pinned: Value(pinned),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// 软删除（墓碑）。逻辑删除保持跨端同步收敛。
  Future<void> markNoteDeleted(String id, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(
      isDeleted: const Value(true),
      deletedAt: Value(t),
      updatedAt: Value(t),
    ));
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

  Future<List<Attachment>> listAttachments({String? noteId}) async {
    final q = db.select(db.attachments)
      ..where((t) => t.isDeleted.equals(false));
    if (noteId != null) {
      q.where((t) => t.noteId.isValue(noteId));
    }
    final rows = await q.get();
    return rows.map((r) => r.toModel()).toList();
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
        parentId: parentId,
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