import 'package:drift/drift.dart';

import '../crypto/notebook_crypto.dart';
import '../crypto/notebook_key_store.dart';
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

  /// 解锁态的 `K_nb` **内存映射**（M10-T29 / FR-51）：不落库、不上行，回锁即删。
  final NotebookKeyStore keyStore;

  /// 未解锁时的占位标题（§6.3）。
  static const lockedPlaceholderTitle = '🔒 加密笔记';

  /// 密文损坏 / 篡改时的占位标题（§11：既**不**当明文，也不让用户误以为是密码错）。
  static const damagedPlaceholderTitle = '⚠️ 加密笔记无法解密';

  NoteRepository(this.db, {this.deviceId = '', NotebookKeyStore? keyStore})
      : keyStore = keyStore ?? NotebookKeyStore();

  // ---- 加密笔记本：解锁 / 回锁 / 展示形态（M10-T29 / FR-51） ----

  /// 解锁加密笔记本：读 `crypto_meta` → 派生 `K_nb` → 驻留内存。
  ///
  /// 密码错误抛 [NotebookUnlockException]；`crypto_meta` 缺失 / 损坏抛
  /// [CryptoMetaFormatException]（§11：**不**静默当明文）。
  Future<void> unlockNotebook(String notebookId, String password) async {
    final nb = await getNotebook(notebookId);
    if (nb == null) {
      throw StateError('笔记本不存在：$notebookId');
    }
    if (!nb.encrypted) {
      throw StateError('该笔记本不是加密笔记本：$notebookId');
    }
    final meta = CryptoMeta.fromJson(nb.cryptoMeta);
    keyStore.unlock(
      notebookId,
      await NotebookCrypto.unlock(password: password, meta: meta),
    );
  }

  /// 回锁单个笔记本（手动「锁定」按钮 / 切换笔记本时的可选立即回锁）。
  bool lockNotebook(String notebookId) => keyStore.lock(notebookId);

  /// 全部回锁（登出 / 关闭应用 / 会话结束）。
  void lockAllNotebooks() => keyStore.lockAll();

  /// 该笔记本当前是否已解锁。
  bool isNotebookUnlocked(String notebookId) => keyStore.isUnlocked(notebookId);

  /// 把**存储形态**的笔记转成**展示形态**。
  ///
  /// * 未加密 → 原样返回；
  /// * 已加密且已解锁 → 解密为明文（编辑器 / 合并逻辑仍以 Markdown 明文为正本，§6.2）；
  /// * 已加密但**未解锁** → 返回占位并置 [Note.locked]；
  /// * 密文**损坏 / 被篡改**（含 AAD 绑定不符）→ 同样占位（用 [damagedPlaceholderTitle] 区分）。
  ///
  /// 任何分支都**不会**把密文当作明文交给上层。
  Future<Note> toDisplayNote(Note stored) async {
    if (!stored.encrypted) return stored;
    final key = keyStore.keyFor(stored.notebookId);
    if (key == null) return _placeholderNote(stored);
    final cipher = NotebookFieldCipher(key);
    final nbId = stored.notebookId ?? '';
    try {
      return stored.copyWith(
        title: await _decryptField(
            cipher, nbId, stored.id, NotebookField.title, stored.title),
        contentMarkdown: await _decryptField(
            cipher, nbId, stored.id, NotebookField.content, stored.contentMarkdown),
      );
    } on NotebookDecryptException {
      return _placeholderNote(stored, damaged: true);
    }
  }

  static Future<String> _decryptField(NotebookFieldCipher cipher, String notebookId,
      String noteId, NotebookField field, String stored) async {
    if (stored.isEmpty) return '';
    return cipher.decrypt(
        notebookId: notebookId, noteId: noteId, field: field, envelope: stored);
  }

  Note _placeholderNote(Note stored, {bool damaged = false}) => stored.copyWith(
        title: damaged ? damagedPlaceholderTitle : lockedPlaceholderTitle,
        contentMarkdown: '',
        locked: true,
      );

  /// 加密行由 Dart 侧对**解密后明文**再判定；明文行的命中已由 SQL 保证。
  static bool _matchesSearch(Note n, String? search) {
    if (search == null || search.isEmpty) return true;
    if (!n.encrypted) return true;
    final s = search.toLowerCase();
    return n.title.toLowerCase().contains(s) ||
        n.contentMarkdown.toLowerCase().contains(s);
  }

  /// 下一条本地修订编号：`max(现存 revision.version) + 1`。
  ///
  /// 与 `Notes.version`（服务端基线镜像）解耦：本地多次编辑不会把编号推到服务端
  /// 版本之上，也不会与服务端下发的版本号撞号（sync-protocol §3）。
  Future<int> _nextRevisionVersion(String noteId) async {
    final row = await (db.selectOnly(db.revisions)
          ..addColumns([db.revisions.version.max()])
          ..where(db.revisions.noteId.equals(noteId)))
        .getSingle();
    return (row.read(db.revisions.version.max()) ?? 0) + 1;
  }

  /// 同步上行成功后回写服务端基线镜像（`Notes.version = appliedVersion`）。
  Future<void> setNoteServerVersion(String id, int version) async {
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(version: Value(version)));
  }

  /// ---- 笔记本 ----

  Future<Notebook> createNotebook({
    String? id,
    String? parentId,
    required String name,
    int? sortOrder,
    DateTime? now,
    bool encrypted = false,
    String cryptoMeta = '',
  }) async {
    final t = now ?? DateTime.now();
    final nid = id ?? newId();
    final pid = _normalizeParentId(parentId);
    final order = sortOrder ?? await _nextNotebookSortOrder(pid);
    await db.into(db.notebooks).insert(NotebooksCompanion.insert(
          id: nid,
          parentId: Value(pid),
          name: name,
          sortOrder: Value(order),
          version: const Value(1),
          encrypted: Value(encrypted),
          cryptoMeta: Value(cryptoMeta),
          createdAt: t,
          updatedAt: t,
        ));
    return (await getNotebook(nid))!;
  }

  /// 同级下一条排序权重：`max(现存 sortOrder) + 1`（含墓碑，避免复号）。
  ///
  /// 新建笔记本据此追加到同级末尾。若一律写默认 0，同级会全部并列，
  /// 上移 / 下移交换等值等于空操作，顺序永远不变（笔记本排序失效的根因）。
  Future<int> _nextNotebookSortOrder(String? parentId) async {
    final maxExpr = db.notebooks.sortOrder.max();
    final q = db.selectOnly(db.notebooks)..addColumns([maxExpr]);
    if (parentId == null) {
      q.where(db.notebooks.parentId.isNull());
    } else {
      q.where(db.notebooks.parentId.equals(parentId));
    }
    final row = await q.getSingle();
    return (row.read(maxExpr) ?? -1) + 1;
  }

  Future<Notebook?> getNotebook(String id) async {
    final row = await (db.select(db.notebooks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row?.toModel();
  }

  Future<List<Notebook>> listNotebooks({bool includeDeleted = false}) async {
    final q = db.select(db.notebooks)
      ..orderBy([
        (t) => OrderingTerm.asc(t.sortOrder),
        (t) => OrderingTerm.asc(t.createdAt),
        (t) => OrderingTerm.asc(t.id),
      ]);
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
    int? version,
    bool encrypted = false,
  }) async {
    final t = now ?? DateTime.now();
    final nid = id ?? newId();
    final src = sourceDevice ?? deviceId;
    // Notes.version 是服务端基线镜像：本地新建（尚未同步）基线为 0；
    // 由 pull 落库的远端笔记以服务端版本为基线。首条修订独立编号：
    // 新建时为 1，远端落库时沿用服务端版本号（sync-protocol §3）。
    final baseVersion = version ?? 0;
    final firstRevision = version ?? 1;
    await db.transaction(() async {
      await db.into(db.notes).insert(NotesCompanion.insert(
            id: nid,
            notebookId: Value(notebookId),
            title: Value(title),
            contentMarkdown: Value(contentMarkdown),
            pinned: Value(pinned),
            archived: Value(archived),
            version: Value(baseVersion),
            encrypted: Value(encrypted),
            createdAt: t,
            updatedAt: t,
            sourceDevice: Value(src),
          ));
      if (tags.isNotEmpty) {
        await _replaceTags(nid, tags);
      }
      // 首条修订：pull 落库时 server_version = 服务端版本；本地新建为 null（§9.4）
      await db.into(db.revisions).insert(RevisionsCompanion.insert(
            id: newId(),
            noteId: nid,
            version: firstRevision,
            title: Value(title),
            contentMarkdown: contentMarkdown,
            sourceDevice: Value(src),
            serverVersion: version != null ? Value(version) : const Value.absent(),
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
    if (row == null) return null;
    // 接缝：存储形态 → 展示形态（解锁则解密；未解锁 / 损坏则占位）。所有返回笔记的
    // API（createNote / updateNoteContent / moveNoteToNotebook / restoreNote /
    // restoreRevision）最终都经过这里，故接缝只需一处。
    return toDisplayNote(row.toModel());
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
    // 本地修订编号取 max(现存 revision.version) + 1，与「服务端基线镜像」
    // （Notes.version）解耦；本地编辑不得推进 Notes.version（sync-protocol §3）。
    final nextVersion = await _nextRevisionVersion(id);

    await db.transaction(() async {
      await _replaceTags(
          id,
          tags ??
              await tagsOfNote(id).then((v) => v.map((e) => e.name).toList()));
      await (db.update(db.notes)..where((n) => n.id.equals(id)))
          .write(NotesCompanion(
        title: Value(nextTitle),
        contentMarkdown: Value(nextContent),
        updatedAt: Value(t),
      ));
      await db.into(db.revisions).insert(RevisionsCompanion.insert(
            id: newId(),
            noteId: id,
            version: nextVersion,
            title: Value(nextTitle),
            contentMarkdown: nextContent,
            sourceDevice: Value(deviceId),
            // 本地编辑产生的草稿：server_version = null（§9.4）
            serverVersion: const Value.absent(),
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
      // 加密行的密文不可能匹配明文关键词，故整体取出，稍后对**解密后明文**过滤（§9.2）。
      q.where((n) =>
          n.encrypted.equals(true) |
          n.title.lower().like(like) |
          n.contentMarkdown.lower().like(like));
    }
    q.orderBy([(n) => OrderingTerm.desc(n.updatedAt)]);

    final summaries = <NoteSummary>[];
    for (final r in await q.get()) {
      final n = await toDisplayNote(r.toModel());
      if (!_matchesSearch(n, search)) continue;
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

  /// 用户发起的归档/取消归档（FR-25）：写入归档位，让 sync 感知到这次变更
  /// （BR-19.7）。
  ///
  /// 与 [applyRemoteArchived] 区别：后者用于同步下行。
  /// 不写 revision：归档不属于内容修订，避免污染版本链。
  /// 不改 `version`：它是服务端基线镜像，本地编辑不得推进（sync-protocol §3）。
  Future<void> archiveNote(String id, bool archived) async {
    final note = await getNote(id);
    if (note == null) throw StateError('note not found: $id');
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(
      archived: Value(archived),
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
      // 撞号安全：历史遗留库可能对同一 (noteId, version) 存有重复行，
      // 用 get() 判空而非 getSingleOrNull()，避免 "Too many elements"。
      final exists = await (db.select(db.revisions)
            ..where((r) => r.noteId.equals(id) & r.version.equals(version))
            ..limit(1))
          .get();
      if (exists.isEmpty) {
        await db.into(db.revisions).insert(RevisionsCompanion.insert(
              id: newId(),
              noteId: id,
              version: version,
              title: Value(title),
              contentMarkdown: contentMarkdown,
              sourceDevice: Value(sourceDevice ?? note.sourceDevice),
              // 远端内容落库：server_version = 服务端版本（§9.4，幂等跳过已存在版本）
              serverVersion: Value(version),
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

  /// 用户发起的「移动到…」：写入新的 notebookId，让 sync 感知笔记变更
  /// （BR-19.7 / BR-20.1）。
  ///
  /// 与 [updateNoteNotebook] 区别：后者用于同步下行。
  /// 不写 revision：归属变更不属于内容修订，避免污染版本链。
  /// 不改 `version`：它是服务端基线镜像，本地编辑不得推进（sync-protocol §3）。
  Future<Note> moveNoteToNotebook(String id, String? notebookId) async {
    final note = await getNote(id);
    if (note == null) throw StateError('note not found: $id');
    await (db.update(db.notes)..where((n) => n.id.equals(id)))
        .write(NotesCompanion(
      notebookId: Value(notebookId),
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
          n.encrypted.equals(true) |
          n.title.lower().like(like) |
          n.contentMarkdown.lower().like(like));
    }
    q.orderBy([(n) => OrderingTerm.desc(n.updatedAt)]);
    final summaries = <NoteSummary>[];
    for (final r in await q.get()) {
      final n = await toDisplayNote(r.toModel());
      if (!_matchesSearch(n, search)) continue;
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
          n.encrypted.equals(true) |
          n.title.lower().like(like) |
          n.contentMarkdown.lower().like(like));
    }
    q.orderBy([(n) => OrderingTerm.desc(n.deletedAt)]);
    final summaries = <NoteSummary>[];
    for (final r in await q.get()) {
      final n = await toDisplayNote(r.toModel());
      if (!_matchesSearch(n, search)) continue;
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
  ///
  /// 撞号安全：历史遗留库可能有重复行，取其中一条，避免 getSingleOrNull()
  /// 抛 "Too many elements"。
  Future<Revision?> getRevision(String noteId, int version) async {
    final row = await (db.select(db.revisions)
          ..where((t) => t.noteId.equals(noteId) & t.version.equals(version))
          ..limit(1))
        .getSingleOrNull();
    return row?.toModel();
  }

  /// 列出本地已同步的修订行（`server_version IS NOT NULL`）——离线历史骨架。
  ///
  /// 在线时历史以服务端 `GET /notes/{id}/revisions` 为准；离线回退用本方法
  /// 取本地已落库的版本节点（sync-protocol §8.3）。
  Future<List<Revision>> listSyncedRevisions(String noteId) async {
    final rows = await (db.select(db.revisions)
          ..where((t) => t.noteId.equals(noteId) & t.serverVersion.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.serverVersion)]))
        .get();
    return rows.map((r) => r.toModel()).toList();
}

  /// 列出最近一次已同步版本**之后**的本地草稿（未同步分组）。
  ///
  /// 取 `server_version IS NULL` 且 `version > MAX(server_version IS NOT NULL`
  /// 的行) 的行；按 `version ASC` 返回，用于未同步分组逐条展示（§8.3）。
  Future<List<Revision>> listUnsyncedRevisions(String noteId) async {
    final maxSynced = await (db.selectOnly(db.revisions)
          ..addColumns([db.revisions.version.max()])
          ..where(db.revisions.noteId.equals(noteId) &
              db.revisions.serverVersion.isNotNull()))
        .getSingle();
    final baseVersion = maxSynced.read(db.revisions.version.max()) ?? 0;
    final rows = await (db.select(db.revisions)
          ..where((t) =>
              t.noteId.equals(noteId) &
              t.serverVersion.isNull() &
              t.version.isBiggerThanValue(baseVersion))
          ..orderBy([(t) => OrderingTerm.asc(t.version)]))
        .get();
    return rows.map((r) => r.toModel()).toList();
}

  /// push 成功后回填 `server_version = appliedVersion` 到指定修订行（§9.5）。
  ///
  /// 精确回填到 `pushedRevisionVersion` 对应的那条，不受在途期间新编辑
  /// 产生的更高 version revision 干扰。
  Future<void> setRevisionServerVersion(
    String noteId,
    int revisionVersion,
    int serverVersion,
) async {
    await (db.update(db.revisions)
          ..where((t) =>
              t.noteId.equals(noteId) & t.version.equals(revisionVersion)))
        .write(RevisionsCompanion(serverVersion: Value(serverVersion)));
}

  /// 当前本地最大修订号 `MAX(revisions.version)`（无则 0）。
  /// 供 SyncClient 在 enqueue 时记录 `pushedRevisionVersion`（§9.5）。
  Future<int> maxRevisionVersion(String noteId) async {
    final row = await (db.selectOnly(db.revisions)
          ..addColumns([db.revisions.version.max()])
          ..where(db.revisions.noteId.equals(noteId)))
        .getSingle();
    return row.read(db.revisions.version.max()) ?? 0;
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
    // 恢复到历史版本 = 一次本地内容编辑：修订编号取 max(现存)+1，
    // 不改 Notes.version（服务端基线镜像，sync-protocol §3）。
    final nextVersion = await _nextRevisionVersion(noteId);

    await db.transaction(() async {
      await (db.update(db.notes)..where((n) => n.id.equals(noteId)))
          .write(NotesCompanion(
        title: Value(rev.title),
        contentMarkdown: Value(rev.contentMarkdown),
        updatedAt: Value(t),
      ));
      await db.into(db.revisions).insert(RevisionsCompanion.insert(
            id: newId(),
            noteId: noteId,
            version: nextVersion,
            title: Value(rev.title),
            contentMarkdown: rev.contentMarkdown,
            sourceDevice: Value(deviceId),
            // 还原后内容需重新 push：server_version = null（§9.4）
            serverVersion: const Value.absent(),
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

  /// 外部编辑回写（FR-47 / §12.3）：把附件 [id] 的映射换到新内容地址 [newSha256]。
  ///
  /// 内容寻址下「同一 sha256 绝不就地覆盖」（BR-47.3 / ADR-013 决策5），故回写的
  /// 本质是**换引用**：新字节已由调用方经 BlobStore 落盘（天然去重），此处只做
  /// ① 改 `attachments.sha256`（连带 `byte_size`、`storage_ref`）；
  /// ② 引用计数迁移——旧 sha −1、新 sha +1（旧值归零后由 LRU / GC 回收）。
  /// 新旧一致或无该行时视为无变更，返回 `null`。
  Future<Attachment?> updateAttachmentSha(
    String id, {
    required String newSha256,
    required int newByteSize,
  }) async {
    final changed = await db.transaction(() async {
      final prev = await (db.select(db.attachments)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (prev == null || prev.isDeleted || prev.sha256 == newSha256) {
        return false;
      }
      await (db.update(db.attachments)..where((t) => t.id.equals(id)))
          .write(AttachmentsCompanion(
        sha256: Value(newSha256),
        byteSize: Value(newByteSize),
        storageRef: Value(newSha256),
      ));
      await _adjustBlobRef(prev.sha256, -1);
      await _adjustBlobRef(newSha256, 1, byteSize: newByteSize);
      return true;
    });
    if (!changed) return null;
    return _attachmentById(id);
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
    bool encrypted = false,
    String cryptoMeta = '',
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
            encrypted: Value(encrypted),
            cryptoMeta: Value(cryptoMeta),
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
        encrypted: Value(encrypted),
        cryptoMeta: Value(cryptoMeta),
        updatedAt: Value(t),
      ));
    }
  }

  /// 应用远端的「加密态」镜像（M10-T29）：笔记归属的笔记本是否为加密笔记本。
  ///
  /// 与正文 / 标题分开落库：未解锁端也要能正确显示占位，故该标记必须**随 pull 立即生效**，
  /// 不受「有未提交草稿时不覆盖正文」的约束。
  Future<void> applyRemoteEncrypted(String noteId, bool encrypted) async {
    await (db.update(db.notes)..where((n) => n.id.equals(noteId)))
        .write(NotesCompanion(encrypted: Value(encrypted)));
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
        encrypted: encrypted,
        cryptoMeta: cryptoMeta,
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
        encrypted: encrypted,
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
        serverVersion: serverVersion,
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
