import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;
import 'package:web_socket_channel/web_socket_channel.dart';

/// 同步连接状态（供 UI 展示）。
enum SyncState {
  /// 尚未配置服务端地址 / Token。
  unconfigured,

  /// 已连接、空闲。
  idle,

  /// 正在 push / pull。
  syncing,

  /// 最近一次同步失败（[AppController.syncError] 有原因）。
  error,
}

/// 附件的可用性：字节在本地还是只在服务端，以及服务端是否已持有。
///
/// 方案 B 下「本地有字节」与「服务端有字节」是两个独立事实，UI 必须分开表达，
/// 否则用户看到「已缓存」会误以为换台设备也一定能打开。
enum AttachmentAvailability {
  /// 本地有字节，且服务端已确认持有 —— 真正的多端可用。
  cached,

  /// 本地有字节，但服务端还没拿到（刚挂上、尚未上传成功）。
  pendingUpload,

  /// 本地有字节，但当前没连服务端 —— 仅本机可用。
  localOnly,

  /// 本地没有字节，需要按需下载。
  remoteOnly,
}

/// 笔记列表排序方式（M2-T08）。
///
/// 选择记忆为本机偏好：写入 [SettingsStore] 的 `notes.sortMode` 键，重启后保留。
/// 默认按更新时间倒序，置顶笔记始终排在最前（BR-05.2 / FR-05）。
enum NoteSortMode {
  /// 更新时间倒序（默认）。
  updatedAt,

  /// 创建时间倒序。
  createdAt,

  /// 标题升序（忽略大小写）。
  title,
}

extension NoteSortModeName on NoteSortMode {
  String get persistentName => switch (this) {
        NoteSortMode.updatedAt => 'updatedAt',
        NoteSortMode.createdAt => 'createdAt',
        NoteSortMode.title => 'title',
      };
}

/// 反向解析持久化字符串；非法或为空时回落到默认 [NoteSortMode.updatedAt]。
NoteSortMode noteSortModeFromName(String? name) {
  switch (name) {
    case 'createdAt':
      return NoteSortMode.createdAt;
    case 'title':
      return NoteSortMode.title;
    default:
      return NoteSortMode.updatedAt;
  }
}

/// 标签总览的排序方式（FR-22）。
enum TagSortMode {
  /// 按关联笔记数量降序（默认）。
  countDesc,

  /// 按标签名称升序（忽略大小写）。
  nameAsc,
}

extension TagSortModeName on TagSortMode {
  String get persistentName => switch (this) {
        TagSortMode.countDesc => 'countDesc',
        TagSortMode.nameAsc => 'nameAsc',
      };
}

TagSortMode tagSortModeFromName(String? name) {
  switch (name) {
    case 'nameAsc':
      return TagSortMode.nameAsc;
    default:
      return TagSortMode.countDesc;
  }
}

/// 笔记列表视图模式（FR-25 归档视图 / FR-26 回收站）。
enum NoteViewMode {
  /// 常规视图：可按笔记本 / 标签 / 搜索筛选的未删除、未归档笔记。
  all,

  /// 归档视图：全部已归档笔记，支持「取消归档」。
  archived,

  /// 回收站：全部已删除（墓碑）笔记，支持「还原」。
  trash,
}

/// 应用状态中枢：持有仓储与同步客户端，向 UI 暴露笔记本树/笔记列表/同步状态。
///
/// 离线优先：所有编辑先落本地 SQLite，再入 Outbox 异步推送；同步失败不影响
/// 本地可用性，仅把 [syncState] 置为 [SyncState.error] 并保留原因。
class AppController extends ChangeNotifier {
  AppController({
    required NoteRepository repository,
    required AppDatabase database,
    String? dataDir,
  })  : _repository = repository,
        _db = database,
        _dataDir = dataDir;

  final NoteRepository _repository;
  final AppDatabase _db;

  /// 原生平台的数据目录（用于附件缓存落盘）；Web 为 null。
  final String? _dataDir;

  NoteRepository get repository => _repository;

  late final SettingsStore _settings = SettingsStore(_db);
  SettingsStore get settings => _settings;

  AuthClient? _auth;

  SyncClient? _syncClient;

  /// 同步客户端：未配置服务端时为 null。
  SyncClient? get syncClient => _syncClient;

  CachedBlobStore? _blobStore;

  /// 附件缓存（方案 B：按需拉取 + LRU 上限）。
  ///
  /// 生命周期与「连接」解耦：启动即建、断开连接后保留 —— 离线也要能挂载与
  /// 查看附件，不该因为没连服务端就连本地附件都用不了。
  CachedBlobStore? get blobStore => _blobStore;

  SyncConfig _config = const SyncConfig();
  SyncConfig get syncConfig => _config;

  SyncState _syncState = SyncState.unconfigured;
  SyncState get syncState => _syncState;

  DateTime? _lastSyncedAt;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  String? _syncError;
  String? get syncError => _syncError;

  int _cacheLimitBytes = 512 * 1024 * 1024;
  int get cacheLimitBytes => _cacheLimitBytes;

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _syncDebounce;
  Timer? _syncTicker;

  /// 连接代次：每次断开 / 重连自增一次。正在跑的同步会记下自己的代次，
  /// 结束后若代次已变，说明连接已被替换，其结果（成功或失败）都必须丢弃，
  /// 否则会用「已关闭的 http.Client」报错污染新连接的同步状态。
  int _connGeneration = 0;

  /// 周期兜底同步间隔。
  ///
  /// 离线期间的本地改动只能积在 Outbox：WS 断了等不到广播，用户也可能不再编辑
  /// 触发防抖推送。没有这个定时器，「断网可读可写、联网后自动同步」就只在
  /// 「用户恰好又编辑了一次」时才成立。空闲时 push 无内容、pull 无增量，开销极小。
  static const _syncInterval = Duration(seconds: 30);

  /// 本机偏好键：笔记列表排序方式（M2-T08）。值见 [NoteSortMode.persistentName]。
  static const _kNoteSortMode = 'notes.sortMode';

  /// 本机偏好键：标签总览排序方式（M2-T10）。值见 [TagSortMode.persistentName]。
  static const _kTagSortMode = 'tags.sortMode';

  List<Notebook> _notebooks = [];
  List<NoteSummary> _notes = [];
  List<Tag> _tags = [];

  /// 当前排序方式。默认更新时间倒序（置顶优先）。
  NoteSortMode _sortMode = NoteSortMode.updatedAt;

  /// 标签总览：标签 + 关联笔记数（FR-22 / BR-22.1）。
  List<TagSummary> _tagSummaries = [];

  /// 标签排序方式（FR-22）：默认按数量降序。
  TagSortMode _tagSortMode = TagSortMode.countDesc;

  /// 当前选中用于筛选笔记的标签（BR-22.2：多标签取交集）。
  final List<String> _selectedTagNames = [];

  List<Notebook> get notebooks => _notebooks;
  List<NoteSummary> get notes => _notes;
  List<Tag> get tags => _tags;
  NoteSortMode get sortMode => _sortMode;
  List<TagSummary> get tagSummaries => _tagSummaries;
  TagSortMode get tagSortMode => _tagSortMode;
  List<String> get selectedTagNames => List.unmodifiable(_selectedTagNames);
  bool get hasTagFilter => _selectedTagNames.isNotEmpty;

  String? _selectedNotebookId;
  String? _selectedNoteId;
  String _query = '';
  NoteViewMode _viewMode = NoteViewMode.all;
  bool _showRevisionPanel = false;
  bool _inboxMode = false;

  String? get selectedNotebookId => _selectedNotebookId;
  String? get selectedNoteId => _selectedNoteId;
  bool get showRevisionPanel => _showRevisionPanel;
  bool get inboxMode => _inboxMode;

  /// 当前视图模式（FR-25 / FR-26）。
  NoteViewMode get viewMode => _viewMode;

  /// 是否处于「归档」视图（FR-25）。
  bool get archivedView => _viewMode == NoteViewMode.archived;

  /// 是否处于「回收站」视图（FR-26）。
  bool get trashView => _viewMode == NoteViewMode.trash;

  /// 是否处于常规「全部笔记」视图（非归档 / 回收站，且无笔记本 / 收件箱 / 搜索）。
  bool get isAllNotesView =>
      _viewMode == NoteViewMode.all &&
      !_inboxMode &&
      _selectedNotebookId == null &&
      _query.isEmpty;

  bool get hasSelection =>
      _selectedNotebookId != null || _query.isNotEmpty || _inboxMode;

  /// 首次加载：读同步配置 → 装配附件缓存 → 载入本地数据 → 若已配置则连接。
  Future<void> bootstrap() async {
    _config = await _settings.loadSyncConfig();
    _cacheLimitBytes = await _settings.cacheLimitBytes();
    _sortMode = noteSortModeFromName(await _settings.get(_kNoteSortMode));
    _tagSortMode = tagSortModeFromName(await _settings.get(_kTagSortMode));
    _blobStore = CachedBlobStore(
      local: LocalBlobStore(_blobRoot()),
      meta: SqliteBlobCacheMeta(_db),
      maxBytes: _cacheLimitBytes,
    );
    await refreshNotebooks();
    await refreshTags();
    await refreshTagSummaries();
    await refreshNotes();
    if (_config.isConfigured) {
      await connect(_config, persist: false);
    }
  }

  Future<void> refreshNotebooks() async {
    _notebooks = await _repository.listNotebooks();
    notifyListeners();
  }

  Future<void> refreshTags() async {
    _tags = await _repository.listTags();
    notifyListeners();
  }

  /// 加载标签总览数据（标签 + 关联笔记数），并按当前 [tagSortMode] 排序。
  Future<void> refreshTagSummaries() async {
    final summaries = await _repository.listTagSummaries();
    switch (_tagSortMode) {
      case TagSortMode.countDesc:
        summaries.sort((a, b) => b.noteCount.compareTo(a.noteCount));
        break;
      case TagSortMode.nameAsc:
        summaries.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
    }
    _tagSummaries = summaries;
    notifyListeners();
  }

  /// 切换标签筛选状态（BR-22.2：多选取交集，再点已选标签即取消）。
  void toggleTag(String name) {
    if (_selectedTagNames.contains(name)) {
      _selectedTagNames.remove(name);
    } else {
      _selectedTagNames.add(name);
    }
    refreshNotes();
  }

  /// 清空全部标签筛选。
  void clearTags() {
    if (_selectedTagNames.isEmpty) return;
    _selectedTagNames.clear();
    refreshNotes();
  }

  /// 切换标签排序方式（记忆为本机偏好，M2-T10）。
  Future<void> setTagSortMode(TagSortMode mode) async {
    if (mode == _tagSortMode) return;
    _tagSortMode = mode;
    await _settings.set(_kTagSortMode, mode.persistentName);
    // 立即重排已加载的列表，避免再查一次库。
    switch (mode) {
      case TagSortMode.countDesc:
        _tagSummaries.sort((a, b) => b.noteCount.compareTo(a.noteCount));
        break;
      case TagSortMode.nameAsc:
        _tagSummaries.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
    }
    notifyListeners();
  }

  Future<void> refreshNotes() async {
    // 归档视图 / 回收站：独立数据源，不参与笔记本 / 标签筛选（FR-25 / FR-26）。
    switch (_viewMode) {
      case NoteViewMode.archived:
        _notes = await _repository.listArchivedNotes(
          search: _query.isEmpty ? null : _query,
        );
        notifyListeners();
        return;
      case NoteViewMode.trash:
        _notes = await _repository.listDeletedNotes(
          search: _query.isEmpty ? null : _query,
        );
        notifyListeners();
        return;
      case NoteViewMode.all:
        break;
    }
    // 收件箱模式下不应用标签筛选（收件箱只看剪藏，标签筛选与之冲突）。
    final useTagFilter = !_inboxMode && _selectedTagNames.isNotEmpty;
    if (useTagFilter) {
      _notes = await _repository.listNotesByTags(
        _selectedTagNames,
        notebookId: _selectedNotebookId,
        search: _query.isEmpty ? null : _query,
        includeArchived: false,
      );
    } else {
      _notes = await _repository.listNotes(
        notebookId: _inboxMode ? null : _selectedNotebookId,
        search: _query.isEmpty ? null : _query,
        includeArchived: false,
      );
    }
    // 收件箱模式：只显示来自剪藏的笔记
    if (_inboxMode) {
      _notes =
          _notes.where((n) => n.note.sourceDevice.startsWith('clip:')).toList();
    }
    _applySort();
    notifyListeners();
  }

  /// 按当前 [sortMode] 对 `_notes` 原地排序：置顶始终排前，其余按模式。
  ///
  /// 仓储默认按 `updatedAt desc` 取数，但切到创建时间 / 标题后需要在内存里重排，
  /// 避免在仓储加分支条件——排序是 UI 偏好，不应侵入查询语义。
  void _applySort() {
    _notes = [..._notes]..sort((a, b) {
        // BR-05.2 / FR-05：置顶最前，与排序模式无关。
        if (a.note.pinned != b.note.pinned) {
          return a.note.pinned ? -1 : 1;
        }
        switch (_sortMode) {
          case NoteSortMode.updatedAt:
            return b.note.updatedAt.compareTo(a.note.updatedAt);
          case NoteSortMode.createdAt:
            return b.note.createdAt.compareTo(a.note.createdAt);
          case NoteSortMode.title:
            return a.note.title
                .toLowerCase()
                .compareTo(b.note.title.toLowerCase());
        }
      });
  }

  /// 切换排序方式：写回 [SettingsStore] 持久化（本机偏好），并在内存里重排当前列表。
  Future<void> setSortMode(NoteSortMode mode) async {
    if (mode == _sortMode) return;
    _sortMode = mode;
    await _settings.set(_kNoteSortMode, mode.persistentName);
    _applySort();
    notifyListeners();
  }

  void selectNotebook(String? id) {
    _selectedNotebookId = id;
    _inboxMode = false;
    _viewMode = NoteViewMode.all;
    _selectedNoteId = null;
    refreshNotes();
  }

  void selectInbox() {
    _inboxMode = true;
    _selectedNotebookId = null;
    _viewMode = NoteViewMode.all;
    _selectedNoteId = null;
    // 收件箱只看剪藏，与标签筛选语义冲突，清空选中标签。
    _selectedTagNames.clear();
    refreshNotes();
  }

  /// 切到归档视图（FR-25）：列出全部已归档笔记。
  void selectArchivedView() {
    _viewMode = NoteViewMode.archived;
    _inboxMode = false;
    _selectedNotebookId = null;
    _selectedNoteId = null;
    _selectedTagNames.clear();
    refreshNotes();
  }

  /// 切到回收站（FR-26）：列出全部已删除（墓碑）笔记。
  void selectTrashView() {
    _viewMode = NoteViewMode.trash;
    _inboxMode = false;
    _selectedNotebookId = null;
    _selectedNoteId = null;
    _selectedTagNames.clear();
    refreshNotes();
  }

  void selectNote(String? id) {
    _selectedNoteId = id;
    notifyListeners();
  }

  /// 在标题/正文中搜索。空串清空过滤。
  void search(String q) {
    _query = q;
    refreshNotes();
  }

  Future<void> createNotebook(String name, {String? parentId}) async {
    final nb = await _repository.createNotebook(name: name, parentId: parentId);
    await refreshNotebooks();
    _enqueueNotebook(nb);
  }

  /// 重命名笔记本并入同步队列（FR-29）。
  Future<void> renameNotebook(String id, String name) async {
    final nb = await _repository.renameNotebook(id, name);
    await refreshNotebooks();
    _enqueueNotebook(nb);
  }

  Future<void> createNote({String? notebookId, String title = ''}) async {
    final note = await _repository.createNote(
      notebookId: notebookId ?? _selectedNotebookId,
      title: title,
    );
    _selectedNoteId = note.id;
    await refreshNotes();
    notifyListeners();
    await _enqueueAndSchedule(note);
  }

  Future<void> saveNote(
    String id, {
    String? title,
    String? content,
    List<String>? tags,
  }) async {
    // BUG3：空笔记禁止保存——仅当笔记此前从未有内容（新建/空笔记）且本次
    // 标题与正文仍为空时，才拒绝写入与推送，避免产生无意义的空笔记、空修订
    // 与无谓的同步上行；反之，旧笔记原本有内容、被清空后仍应继续保存。
    final current = await _repository.getNote(id);
    if (current == null) return;
    final nextTitle = title ?? current.title;
    final nextContent = content ?? current.contentMarkdown;
    final hadContent = current.title.trim().isNotEmpty ||
        current.contentMarkdown.trim().isNotEmpty;
    if (!hadContent && nextTitle.trim().isEmpty && nextContent.trim().isEmpty) {
      return;
    }

    final note = await _repository.updateNoteContent(
      id,
      title: title,
      contentMarkdown: content,
      tags: tags,
    );
    await refreshNotes();
    await refreshTagSummaries();
    await _enqueueAndSchedule(note);
  }

  Future<void> deleteNote(String id) async {
    await _repository.markNoteDeleted(id);
    if (_selectedNoteId == id) _selectedNoteId = null;
    await refreshNotes();
    await refreshTagSummaries();
    notifyListeners();
    final note = await _repository.getNote(id);
    if (note != null) await _enqueueAndSchedule(note);
  }

  /// 从回收站还原笔记（FR-26）：清除墓碑、必要时归入「全部笔记」，并重新入队同步。
  Future<void> restoreNote(String id) async {
    final note = await _repository.restoreNote(id);
    if (_selectedNoteId == id) _selectedNoteId = null;
    await refreshNotes();
    await refreshTagSummaries();
    notifyListeners();
    if (note != null) await _enqueueAndSchedule(note);
  }

  /// 切换置顶（FR-05 / BR-05.2）。置顶恒优先于排序字段。
  Future<void> togglePinNote(String id) async {
    final note = _notes.where((s) => s.note.id == id).firstOrNull?.note;
    if (note == null) return;
    await _repository.pinNote(id, !note.pinned);
    await refreshNotes();
    final updated = await _repository.getNote(id);
    if (updated != null) await _enqueueAndSchedule(updated);
  }

  /// 切换归档（FR-05）。归档后的笔记不出现在默认列表，但可在归档视图查看。
  Future<void> toggleArchiveNote(String id) async {
    final note = _notes.where((s) => s.note.id == id).firstOrNull?.note;
    if (note == null) return;
    await _repository.archiveNote(id, !note.archived);
    if (_selectedNoteId == id && note.archived == false) {
      // 当前选中的笔记被归档后不再可见，清空选中以避免编辑区悬空。
      _selectedNoteId = null;
    }
    await refreshNotes();
    final updated = await _repository.getNote(id);
    if (updated != null) await _enqueueAndSchedule(updated);
  }

  /// 把笔记移动到目标笔记本（BR-20.1）。`null` 表示移出到「全部笔记 / 收件箱」。
  Future<void> moveNoteToNotebook(String id, String? notebookId) async {
    final note = await _repository.moveNoteToNotebook(id, notebookId);
    await refreshNotes();
    await _enqueueAndSchedule(note);
  }

  /// 删除笔记本：软删除 + 级联处置（BR-20.3 / BR-20.4）。
  ///
  /// - 笔记不随之删除：把该笔记本下未删除笔记移入回收站（软删除，FR-26），
  ///   可在「回收站」还原，避免误删内容。
  /// - 子笔记本上提到被删节点的父级：保留层级但避免悬挂引用。
  /// - 软删除的笔记本作为墓碑参与同步（BR-19.5），子笔记本与笔记因 reparent /
  ///   软删除各自 bump version，也独立入队同步。
  Future<void> deleteNotebook(String id) async {
    final target = _notebooks.where((n) => n.id == id).firstOrNull;
    if (target == null) return;
    final newParentId = target.parentId;

    // 1) 子笔记本上提到被删节点的父级。
    final children = _notebooks.where((n) => n.parentId == id).toList();
    for (final child in children) {
      final reparented =
          await _repository.reparentNotebook(child.id, newParentId);
      _enqueueNotebook(reparented);
    }

    // 2) 该笔记本下的笔记进入回收站（FR-26）：软删除后可在「回收站」还原，
    //    不随笔记本本体一并清除，避免误删内容。
    final occupants =
        await _repository.listNotes(notebookId: id, includeArchived: true);
    for (final s in occupants) {
      if (s.note.isDeleted) continue;
      await _repository.markNoteDeleted(s.note.id);
      final tombstoned = await _repository.getNote(s.note.id);
      if (tombstoned != null) await _enqueueAndSchedule(tombstoned);
    }

    // 3) 软删除笔记本本体。
    await _repository.removeNotebook(id);
    final tombstoned = await _repository.getNotebook(id);
    if (tombstoned != null) _enqueueNotebook(tombstoned);

    if (_selectedNotebookId == id) {
      _selectedNotebookId = null;
      _inboxMode = false;
    }
    await refreshNotebooks();
    await refreshNotes();
  }

  /// 在同级内上移笔记本（与上一个兄弟交换位置）。
  Future<void> moveNotebookUp(String id) async {
    final siblings = _siblingsOf(id);
    final idx = siblings.indexWhere((n) => n.id == id);
    if (idx <= 0) return;
    final reordered = [...siblings];
    reordered.insert(idx - 1, reordered.removeAt(idx));
    await _applyNotebookOrder(reordered);
  }

  /// 在同级内下移笔记本（与下一个兄弟交换位置）。
  Future<void> moveNotebookDown(String id) async {
    final siblings = _siblingsOf(id);
    final idx = siblings.indexWhere((n) => n.id == id);
    if (idx < 0 || idx >= siblings.length - 1) return;
    final reordered = [...siblings];
    reordered.insert(idx + 1, reordered.removeAt(idx));
    await _applyNotebookOrder(reordered);
  }

  /// 取某笔记本的同级列表，按 (sortOrder, createdAt, id) 稳定排序。
  ///
  /// 历史数据可能同级 sortOrder 全部并列（早期版本新建时未分配），
  /// 此时以 createdAt / id 兜底，保证上移 / 下移有确定的相对位置。
  List<Notebook> _siblingsOf(String id) {
    final parentId = _parentOf(id);
    return _notebooks.where((n) => n.parentId == parentId).toList()
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        if (byOrder != 0) return byOrder;
        final byCreated = a.createdAt.compareTo(b.createdAt);
        if (byCreated != 0) return byCreated;
        return a.id.compareTo(b.id);
      });
  }

  /// 按给定顺序把同级 sortOrder 归一化为 0..n-1，仅写变化的行并各自入同步队列。
  ///
  /// 归一化同时修复存量数据「同级 sortOrder 并列」的问题：交换等值原本是空操作，
  /// 归一化后新顺序才真正落库并触发侧栏刷新。
  Future<void> _applyNotebookOrder(List<Notebook> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].sortOrder == i) continue;
      final updated = await _repository.reorderNotebook(ordered[i].id, i);
      _enqueueNotebook(updated);
    }
    await refreshNotebooks();
  }

  /// 取笔记本的 parentId（找不到时返回 null，视为根级）。
  String? _parentOf(String id) =>
      _notebooks.where((n) => n.id == id).firstOrNull?.parentId;

  /// 笔记本变更入同步队列（仅当已连服务端时有效）。
  void _enqueueNotebook(Notebook notebook) {
    final client = _syncClient;
    if (client == null) return;
    client.enqueueNotebook(notebook);
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 700), syncNow);
  }

  // ---- 同步 ----

  /// 配置并连接服务端。[persist] 为真时把配置写入本地库。
  ///
  /// 传入未填齐（无地址或无 Token）的配置等价于「断开」。
  Future<void> connect(SyncConfig cfg, {bool persist = true}) async {
    await _teardownConnection();
    final normalized =
        cfg.copyWith(baseUrl: SyncConfig.normalizeBaseUrl(cfg.baseUrl));
    _config = normalized;
    if (persist) {
      await _settings.saveSyncConfig(
        baseUrl: normalized.baseUrl,
        token: normalized.token,
      );
    }
    if (!normalized.isConfigured) {
      _syncState = SyncState.unconfigured;
      _syncError = null;
      notifyListeners();
      return;
    }

    _blobStore ??= CachedBlobStore(
      local: LocalBlobStore(_blobRoot()),
      meta: SqliteBlobCacheMeta(_db),
      maxBytes: _cacheLimitBytes,
    );
    _syncClient = SyncClient(
      repository: _repository,
      baseUrl: normalized.baseUrl,
      deviceId: normalized.deviceId,
      token: normalized.token,
      blobStore: _blobStore,
    );
    _syncState = SyncState.idle;
    _syncError = null;
    notifyListeners();

    _openWs();
    _syncTicker?.cancel();
    _syncTicker = Timer.periodic(_syncInterval, (_) => syncNow());
    await syncNow();
  }

  /// 断开连接：清掉地址与 Token（保留 deviceId 与本地数据）。
  Future<void> disconnect() async {
    await _settings.clearSyncConfig();
    _config = _config.copyWith(baseUrl: '', token: '');
    await _teardownConnection();
    _syncState = SyncState.unconfigured;
    _syncError = null;
    notifyListeners();
  }

  /// 立即同步（push + pull）。未连接时为空操作。
  Future<void> syncNow() async {
    final client = _syncClient;
    if (client == null) return;
    if (_syncState == SyncState.syncing) return;

    final generation = _connGeneration;
    _syncState = SyncState.syncing;
    _syncError = null;
    notifyListeners();
    try {
      await client.sync();
      if (generation != _connGeneration) return;
      _lastSyncedAt = DateTime.now();
      _syncState = SyncState.idle;
      await refreshNotebooks();
      await refreshTags();
      await refreshNotes();
    } catch (e) {
      if (generation != _connGeneration) return;
      _syncError = _describeError(e);
      _syncState = SyncState.error;
    }
    notifyListeners();
  }

  /// 探测服务端：版本号 + 是否已完成首启建号（M4/BR-33.4）。
  Future<({String version, bool initialized})> probeServer(String baseUrl) =>
      _authClient().pingInfo(baseUrl);

  /// 探测服务端连通性，成功返回服务端版本号，失败抛异常（UI 捕获展示）。
  Future<String> testConnection(String baseUrl) async =>
      (await probeServer(baseUrl)).version;

  /// 注册新账号并连接。成功返回 null，失败返回可展示的错误文案。
  Future<String?> registerAndConnect({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    try {
      final token = await _authClient()
          .register(baseUrl: baseUrl, username: username, password: password);
      await connect(SyncConfig(
        baseUrl: baseUrl,
        token: token,
        deviceId: _config.deviceId,
      ));
      return null;
    } catch (e) {
      return _describeError(e);
    }
  }

  /// 登录并连接。成功返回 null，失败返回可展示的错误文案。
  Future<String?> loginAndConnect({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    try {
      final token = await _authClient()
          .login(baseUrl: baseUrl, username: username, password: password);
      await connect(SyncConfig(
        baseUrl: baseUrl,
        token: token,
        deviceId: _config.deviceId,
      ));
      return null;
    } catch (e) {
      return _describeError(e);
    }
  }

  /// 直接以「地址 + 已有 Token」连接。
  Future<void> connectWithToken({
    required String baseUrl,
    required String token,
  }) =>
      connect(SyncConfig(
        baseUrl: baseUrl,
        token: token,
        deviceId: _config.deviceId,
      ));

  /// 调整附件缓存上限（字节）。立即对已装配的缓存生效并回收超出部分。
  Future<void> setCacheLimitBytes(int bytes) async {
    _cacheLimitBytes = bytes;
    await _settings.setCacheLimitBytes(bytes);
    await _blobStore?.setCapacity(bytes);
    notifyListeners();
  }

  Future<void> _enqueueAndSchedule(Note note) async {
    final client = _syncClient;
    if (client == null) return;
    await client.enqueue(note);
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 700), syncNow);
  }

  String _blobRoot() => _dataDir == null ? '' : p.join(_dataDir, 'blobs');

  AuthClient _authClient() => _auth ??= AuthClient();

  Future<void> _teardownConnection() async {
    _connGeneration++;
    _syncDebounce?.cancel();
    _syncDebounce = null;
    _syncTicker?.cancel();
    _syncTicker = null;
    await _wsSub?.cancel();
    _wsSub = null;
    // 关闭握手可能因半开连接永不完成：限时等待，避免断连卡死。
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      try {
        await ws.sink.close().timeout(const Duration(milliseconds: 500));
      } catch (_) {}
    }
    _syncClient?.close();
    _syncClient = null;
    // 附件缓存不随连接销毁：本地字节与记账都要留着（离线可用）。
  }

  /// 订阅服务端变更广播：收到通知即拉取（多端即时感知）。
  void _openWs() {
    final base = _config.baseUrl;
    if (base.isEmpty) return;
    final scheme = base.startsWith('https') ? 'wss' : 'ws';
    final host = base.replaceFirst(RegExp('^https?'), scheme);
    try {
      // M4/BR-35.x：WS 端点须鉴权；token 走查询串（浏览器 WebSocket 握手
      // 无法自定义 Authorization 头）。
      final ch = WebSocketChannel.connect(Uri.parse(
        '$host/api/v1/ws?token=${Uri.encodeQueryComponent(_config.token)}',
      ));
      _ws = ch;
      _wsSub = ch.stream.listen(
        (_) => _onRemoteChange(),
        onError: (_) {}, // WS 不可用不影响手动触发与周期兜底同步
        onDone: () {},
      );
    } catch (_) {
      // 连接失败静默降级：同步仍可手动触发与周期兜底。
    }
  }

  void _onRemoteChange() {
    if (_syncState == SyncState.syncing) return;
    syncNow();
  }

  String _describeError(Object e) {
    if (e is HttpException) {
      return switch (e.statusCode) {
        409 => '用户已存在，请改用「登录」',
        403 => '该服务端已初始化（单用户实例），请改用「登录并连接」',
        401 => '用户名或密码错误',
        400 => '请求无效（用户名/密码不能为空）',
        _ => 'HTTP ${e.statusCode}: ${e.body}',
      };
    }
    final msg = e.toString();
    // Web 上网络层失败表现为「Failed to fetch」，原生上是 SocketException，
    // 给出可操作提示而不是把底层异常直接抛给用户。
    if (msg.contains('Failed to fetch') ||
        msg.contains('SocketException') ||
        msg.contains('Connection refused')) {
      return '无法连接服务端，请检查「服务端地址」是否正确、服务是否已启动';
    }
    return msg;
  }

  // ---- 修订历史 ----

  void toggleRevisionPanel() {
    _showRevisionPanel = !_showRevisionPanel;
    notifyListeners();
  }

  void setRevisionPanelVisible(bool visible) {
    _showRevisionPanel = visible;
    notifyListeners();
  }

  Future<List<Revision>> listRevisions(String noteId) async {
    return await _repository.listRevisions(noteId);
  }

  /// 在线拉取服务端修订历史（sync-protocol §8.3）。
  /// 服务端未配置或请求失败时返回空列表（UI 回退到本地已同步行）。
  Future<List<RemoteRevision>> fetchRemoteRevisions(String noteId) async {
    final sc = _syncClient;
    if (sc == null) return const [];
    try {
      return await sc.fetchRemoteRevisions(noteId);
    } catch (_) {
      return const [];
    }
}

  /// 本地已同步修订节点（离线历史骨架，§8.3）。
  Future<List<Revision>> listSyncedRevisions(String noteId) async {
    return await _repository.listSyncedRevisions(noteId);
}

  /// 本地未同步草稿分组（§8.3）。
  Future<List<Revision>> listUnsyncedRevisions(String noteId) async {
    return await _repository.listUnsyncedRevisions(noteId);
}

  /// 恢复到指定历史版本。恢复后刷新笔记列表和编辑器内容。
  Future<void> restoreRevision(String noteId, int version) async {
    await _repository.restoreRevision(noteId, version);
    await refreshNotes();
    notifyListeners();
    // 恢复同样是一次本地内容变更：入队并调度推送，否则其他端看不到恢复结果。
    final note = await _repository.getNote(noteId);
    if (note != null) await _enqueueAndSchedule(note);
  }

  // ---- 附件（方案 B：按需拉取 + LRU 缓存） ----

  List<Attachment> _attachments = [];
  List<Attachment> get attachments => _attachments;

  Future<void> refreshAttachments(String noteId) async {
    _attachments = await _repository.listAttachments(noteId: noteId);
    notifyListeners();
  }

  /// 把选中的文件挂到笔记上：落本地字节 → 建映射（引用计数 +1）→
  /// 尝试上传字节 → 入队同步。返回新建的 [Attachment]。
  ///
  /// 上传失败不算失败：字节已在本地、映射已入库，同步周期会自动补传
  /// （[SyncClient.backfillBlobs]），因此断网也能照常添加附件。
  Future<Attachment> addAttachmentFromBytes({
    required String noteId,
    required String filename,
    required Uint8List bytes,
  }) async {
    final store = _blobStore;
    if (store == null) {
      throw StateError('附件缓存未初始化');
    }
    final hash = sha256Hex(bytes);
    await store.put(sha256: hash, bytes: bytes);
    final att = await _repository.addAttachment(
      noteId: noteId,
      filename: filename,
      mimeKind: mimeKindFor(filename),
      byteSize: bytes.length,
      sha256: hash,
    );
    await refreshAttachments(noteId);

    final client = _syncClient;
    if (client != null) {
      try {
        await client.uploadBlob(hash);
      } on Exception {
        // 断网/服务端不可用：留给同步周期补传。
      }
    }
    final note = await _repository.getNote(noteId);
    if (note != null) await _enqueueAndSchedule(note);
    return att;
  }

  /// 摘除附件（墓碑 + 释放引用），并入队同步让对端收敛。
  Future<void> removeAttachment(Attachment a) async {
    await _repository.removeAttachment(a.id);
    final noteId = a.noteId;
    if (noteId != null) {
      await refreshAttachments(noteId);
      final note = await _repository.getNote(noteId);
      if (note != null) await _enqueueAndSchedule(note);
    }
  }

  /// 附件在「本地 / 服务端」两侧的可用状态（卡片展示用）。
  Future<AttachmentAvailability> attachmentAvailability(Attachment a) async {
    final store = _blobStore;
    if (store == null) return AttachmentAvailability.remoteOnly;
    if (!await store.exists(a.sha256)) return AttachmentAvailability.remoteOnly;
    final client = _syncClient;
    if (client == null) return AttachmentAvailability.localOnly;
    final entry = await store.entry(a.sha256);
    return entry?.uploadedAt == null
        ? AttachmentAvailability.pendingUpload
        : AttachmentAvailability.cached;
  }

  /// 当前附件缓存占用与上限（设置页展示）。
  Future<(int, int)> attachmentCacheUsage() async {
    final store = _blobStore;
    if (store == null) return (0, _cacheLimitBytes);
    return (await store.cachedBytes, store.capacity);
  }

  final Set<String> _downloading = {};

  /// 附件是否正在按需下载中（用于 UI 展示下载进度状态）。
  bool isDownloading(String sha256) => _downloading.contains(sha256);

  /// 取附件字节：本地命中直接返回，未命中按需下载；未配置同步时返回 null。
  Future<Uint8List?> loadAttachmentBytes(String sha256) async {
    final store = _blobStore;
    if (store == null) return null;
    final local = await store.read(sha256);
    if (local != null) return local;
    final client = _syncClient;
    if (client == null) return null;
    return client.ensureBlob(sha256);
  }

  /// 打开附件（带下载状态标记，供卡片展示进度）。
  Future<Uint8List?> openAttachment(Attachment a) async {
    final sha = a.sha256;
    _downloading.add(sha);
    notifyListeners();
    try {
      return await loadAttachmentBytes(sha);
    } finally {
      _downloading.remove(sha);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    _syncTicker?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    _syncClient?.close();
    _blobStore?.dispose();
    _auth?.close();
    super.dispose();
  }
}
