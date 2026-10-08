import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../platform/app_lifecycle.dart';
import '../platform/attachment_opener.dart';
import 'desktop_commands.dart';
import 'markdown_editor.dart';
import 'note_window_manager.dart';

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

/// 编辑模式（`formatted` / `source` / `preview`）的持久化名称（M7-T06，键 `ui.editorMode`）。
///
/// 枚举本身定义在 `markdown_editor.dart`（编辑器与壳层共用同一类型）。
extension EditorModeName on EditorMode {
  String get persistentName => switch (this) {
        EditorMode.formatted => 'formatted',
        EditorMode.source => 'source',
        EditorMode.preview => 'preview',
      };
}

/// 反向解析编辑模式持久化字符串；非法或为空时回落到默认 [EditorMode.formatted]。
EditorMode editorModeFromName(String? name) {
  switch (name) {
    case 'source':
      return EditorMode.source;
    case 'preview':
      return EditorMode.preview;
    default:
      return EditorMode.formatted;
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
    NoteWindowManager? windowManager,
    WindowEventHub? windowEventHub,
    Duration? autoRelockIdle,
  })  : _repository = repository,
        _db = database,
        _dataDir = dataDir,
        _windowManager = windowManager,
        _autoRelockIdle = autoRelockIdle ?? const Duration(minutes: 15) {
    // 订阅窗口事件枢纽（M8 · 详细设计 §4 / §5.1）。
    //
    // `runMultiApp` 的观察者由 `MultiAppConfig` 先于 `globalScope` 构造，此刻本控制器
    // 尚未创建，观察者无法直接持有它；故观察者只转发到平台无关的 [WindowEventHub]，
    // 本控制器在此登记为接收方（见 `ui/note_window_manager.dart`）。
    _windowEventHub = windowEventHub;
    windowEventHub?.bind(
      onWindowOpened: onWindowOpened,
      onWindowClosed: onWindowClosed,
      onViewFocused: setActiveViewKey,
    );
  }

  final NoteRepository _repository;
  final AppDatabase _db;

  /// 原生平台的数据目录（用于附件缓存落盘）；Web 为 null。
  final String? _dataDir;

  /// 独立笔记窗口管理器（M8 · 详细设计 §4）。
  ///
  /// 桌面端入口注入真实实现；Web / 移动端 / 单测为 `null`——此时
  /// [openNoteInWindow] **优雅降级**为在主窗口内选中该笔记（BR-42.5 / AC-128）。
  final NoteWindowManager? _windowManager;

  /// 窗口事件枢纽（M8 · 详细设计 §4）：订阅后接收窗口开 / 关 / 聚焦事件。
  ///
  /// 由桌面端入口经 [SharedAppScope] 注入；Web / 移动端 / 单测为 `null`（无窗口事件）。
  WindowEventHub? _windowEventHub;

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

  /// 本机偏好键：左侧栏（笔记本树）是否折叠（M7-T06，FR-40）。值 `'true'` / `'false'`。
  static const _kLeftPanelCollapsed = 'ui.leftPanelCollapsed';

  /// 本机偏好键：中栏（笔记列表）是否折叠（M7-T06，FR-40）。值 `'true'` / `'false'`。
  static const _kNoteListCollapsed = 'ui.noteListCollapsed';

  /// 本机偏好键：编辑器三态（M7-T06，FR-41 / 详细设计 §5.1）。值见 [EditorModeName.persistentName]。
  static const _kEditorMode = 'ui.editorMode';

  /// 本机偏好键：**独立笔记窗口**的编辑三态（M8 · 详细设计 §5.2 / §8）。
  ///
  /// 窗口局部状态：与主窗口的 [_kEditorMode] **各自独立**、互不联动（独立窗口默认
  /// `formatted`），且不参与同步。
  static const _kWindowNoteEditorMode = 'ui.window.note.editorMode';

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

  /// 左侧栏（笔记本树）折叠态（M7-T06，FR-40）：`true` = 已折叠隐藏。
  bool _leftPanelCollapsed = false;

  /// 中栏（笔记列表）折叠态（M7-T06，FR-40）：`true` = 已折叠隐藏。
  bool _noteListCollapsed = false;

  /// 编辑器三态（M7-T06，§5.1）：本地视图偏好，不随切换笔记重置。
  EditorMode _editorMode = EditorMode.formatted;

  String? get selectedNotebookId => _selectedNotebookId;
  String? get selectedNoteId => _selectedNoteId;
  bool get showRevisionPanel => _showRevisionPanel;
  bool get inboxMode => _inboxMode;

  /// 当前搜索词（只读）。供 `NoteList` 的搜索框在重挂载后复原文本（AC-112）：
  /// 中栏折叠时 `NoteList` 被卸载，若搜索框无控制器，再展开时框内为空而列表仍是
  /// 筛选结果，出现「框空但结果已筛」的呈现分裂。
  String get query => _query;

  /// 左侧栏是否折叠（FR-40）。
  bool get leftPanelCollapsed => _leftPanelCollapsed;

  /// 中栏笔记列表是否折叠（FR-40）。
  bool get noteListCollapsed => _noteListCollapsed;

  /// 当前编辑器模式（FR-41 / §5.1）。
  EditorMode get editorMode => _editorMode;

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

  /// 读取布尔型本机偏好：仅 `'true'` 视为真，其余（含 `null` / 非法值）为假。
  static bool _boolPref(String? raw) => raw == 'true';

  /// 尽力持久化本机 UI 偏好：**落盘失败只记录、不抛出**。
  ///
  /// UI 刷新不得依赖落盘成功——写库异常（磁盘满 / 数据库被占用 / 表缺失等）若向上
  /// 抛出，会把其后的 `notifyListeners()` 一起吞掉，表现为「点了没反应」（M7-T12 实测）。
  /// 故所有「改内存态 → 落盘」的偏好写入统一走本方法。
  Future<void> _persistPref(String key, String value) async {
    try {
      await _settings.set(key, value);
    } catch (error, stackTrace) {
      debugPrint('[AppController] 本机偏好写入失败：$key=$value → $error');
      debugPrintStack(stackTrace: stackTrace, maxFrames: 8);
    }
  }

  /// 首次加载：读同步配置 → 装配附件缓存 → 载入本地数据 → 若已配置则连接。
  Future<void> bootstrap() async {
    _config = await _settings.loadSyncConfig();
    _cacheLimitBytes = await _settings.cacheLimitBytes();
    _sortMode = noteSortModeFromName(await _settings.get(_kNoteSortMode));
    _tagSortMode = tagSortModeFromName(await _settings.get(_kTagSortMode));
    _leftPanelCollapsed = _boolPref(await _settings.get(_kLeftPanelCollapsed));
    _noteListCollapsed = _boolPref(await _settings.get(_kNoteListCollapsed));
    _editorMode = editorModeFromName(await _settings.get(_kEditorMode));
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
    await _persistPref(_kTagSortMode, mode.persistentName);
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
    _applySort();
    notifyListeners();
    await _persistPref(_kNoteSortMode, mode.persistentName);
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
    final target = notebookId ?? _selectedNotebookId;
    final Note note;
    try {
      note = await _repository.createNote(notebookId: target, title: title);
    } on NotebookDecryptException catch (e) {
      // M10-T29（§11）：往**未解锁**的加密笔记本新建笔记必须被拒绝，否则就是明文入库。
      _lockedNotice = '目标笔记本已锁定，无法新建：$e';
      notifyListeners();
      return;
    }
    _touchUnlockActivity();
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
    // M10-T29（§11）：未解锁不得写入——此时 `current` 是**占位**，写下去会把占位当内容
    // 覆盖密文。最常见的触发场景：编辑过程中被空闲自动回锁。
    if (current.locked) {
      _lockedNotice = '加密笔记本已回锁，请重新解锁后再编辑';
      notifyListeners();
      return;
    }
    // 解锁态编辑算「活动」，续期空闲回锁。
    _touchUnlockActivity();

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
    // 独立窗口承载的笔记：刷新其摘要缓存，让窗口标题随编辑更新（AC-125）。
    if (_windowNoteSummaries.containsKey(id)) {
      final summary = await _repository.getNoteSummary(id);
      if (summary != null) _windowNoteSummaries[id] = summary;
    }
    await refreshNotes();
    await refreshTagSummaries();
    await _enqueueAndSchedule(note);
  }

  Future<void> deleteNote(String id) async {
    await _repository.markNoteDeleted(id);
    if (_selectedNoteId == id) _selectedNoteId = null;
    // 异常自愈（BR-43.6）：笔记被删除时关闭其独立窗口，避免悬空窗口。
    if (_openNotes.containsKey(id)) await closeNoteWindow(id);
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
    // 异常自愈（BR-43.6）：笔记转为归档后不再出现在默认列表，关闭其独立窗口。
    if (note.archived == false && _openNotes.containsKey(id)) {
      await closeNoteWindow(id);
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
      // 落盘失败只记录、不抛出：连接流程不应因「配置写库失败」整体中断
      // （否则其后的 notifyListeners() 被吞，界面停留在旧状态）。
      try {
        await _settings.saveSyncConfig(
          baseUrl: normalized.baseUrl,
          token: normalized.token,
          refreshToken: normalized.refreshToken,
        );
      } catch (error, stackTrace) {
        debugPrint('[AppController] 同步配置写入失败：${normalized.baseUrl} → $error');
        debugPrintStack(stackTrace: stackTrace, maxFrames: 8);
      }
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
      refreshToken: normalized.refreshToken,
      blobStore: _blobStore,
      onTokensRefreshed: _onTokensRefreshed,
      onAuthExpired: _onAuthExpired,
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
    // 同 connect：清理落盘失败不应阻断断开流程与界面刷新。
    try {
      await _settings.clearSyncConfig();
    } catch (error, stackTrace) {
      debugPrint('[AppController] 同步配置清理失败 → $error');
      debugPrintStack(stackTrace: stackTrace, maxFrames: 8);
    }
    // 刷新令牌一并清掉：断开后不应残留长期凭证（M10/BR-49.4）。
    _config = _config.copyWith(baseUrl: '', token: '', refreshToken: '');
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
      final session = await _authClient()
          .register(baseUrl: baseUrl, username: username, password: password);
      await connect(SyncConfig(
        baseUrl: baseUrl,
        token: session.accessToken,
        refreshToken: session.refreshToken,
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
      final session = await _authClient()
          .login(baseUrl: baseUrl, username: username, password: password);
      await connect(SyncConfig(
        baseUrl: baseUrl,
        token: session.accessToken,
        refreshToken: session.refreshToken,
        deviceId: _config.deviceId,
      ));
      return null;
    } catch (e) {
      return _describeError(e);
    }
  }

  /// 直接以「地址 + 已有令牌」连接。
  ///
  /// [refreshToken] 可选：留空则只能用到访问令牌过期为止（M10 起访问令牌默认 30 分钟），
  /// 之后须重新登录。
  Future<void> connectWithToken({
    required String baseUrl,
    required String token,
    String refreshToken = '',
  }) =>
      connect(SyncConfig(
        baseUrl: baseUrl,
        token: token,
        refreshToken: refreshToken,
        deviceId: _config.deviceId,
      ));

  /// 调整附件缓存上限（字节）。立即对已装配的缓存生效并回收超出部分。
  Future<void> setCacheLimitBytes(int bytes) async {
    _cacheLimitBytes = bytes;
    await _blobStore?.setCapacity(bytes);
    notifyListeners();
    try {
      await _settings.setCacheLimitBytes(bytes);
    } catch (error, stackTrace) {
      debugPrint('[AppController] 附件缓存上限写入失败：$bytes → $error');
      debugPrintStack(stackTrace: stackTrace, maxFrames: 8);
    }
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

  /// 令牌刷新成功（M10/FR-49）：落盘新令牌并**重连 WS**。
  ///
  /// 必须重连：WS 子协议里带的是旧访问令牌，不重连则实时通知静默失效（只剩 30s 兜底拉取）。
  Future<void> _onTokensRefreshed(
      String accessToken, String refreshToken) async {
    _config = _config.copyWith(
      token: accessToken,
      refreshToken: refreshToken,
    );
    try {
      await _settings.saveSyncConfig(
        baseUrl: _config.baseUrl,
        token: accessToken,
        refreshToken: refreshToken,
      );
    } catch (error) {
      debugPrint('[AppController] 刷新后的令牌写入失败 → $error');
    }
    await _reopenWs();
    notifyListeners();
  }

  /// 刷新令牌失效（refresh-expired / refresh-revoked）：提示重新登录。
  ///
  /// 只置错误态、**不清本地配置与数据**：用户重新登录即可（避免误清丢数据）。
  Future<void> _onAuthExpired() async {
    _syncError = '登录已失效，请重新登录';
    _syncState = SyncState.error;
    notifyListeners();
  }

  /// 先关旧连接再用当前令牌重新握手。
  Future<void> _reopenWs() async {
    await _wsSub?.cancel();
    _wsSub = null;
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      try {
        await ws.sink.close().timeout(const Duration(milliseconds: 500));
      } catch (_) {}
    }
    _openWs();
  }

  /// 订阅服务端变更广播：收到通知即拉取（多端即时感知）。
  void _openWs() {
    final base = _config.baseUrl;
    if (base.isEmpty) return;
    final scheme = base.startsWith('https') ? 'wss' : 'ws';
    final host = base.replaceFirst(RegExp('^https?'), scheme);
    try {
      // M10（auth.md §4.5）：WS 鉴权令牌走**子协议**——WebSocket 握手无法自定义请求头，
      // 子协议是 Web 端唯一可用通道；查询串 ?token= 已移除（会进访问日志与浏览器历史）。
      // 服务端会回选同一子协议值，故此处字符串必须与 Go 侧 `ws.SubprotocolPrefix` 一致。
      final ch = WebSocketChannel.connect(
        Uri.parse('$host/api/v1/ws'),
        protocols: ['bearer.${_config.token}'],
      );
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
        401 => _authErrorText(e.body),
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

  /// 401 的文案按服务端**可区分错误码**给出（auth.md §5）：
  /// 令牌类问题与「用户名 / 密码错误」不是一回事，混为一谈会误导用户反复试密码。
  String _authErrorText(String body) {
    if (body.contains('refresh-expired') || body.contains('refresh-revoked')) {
      return '登录已失效，请重新登录';
    }
    if (body.contains('token-expired')) {
      return '登录状态已过期（正在自动刷新）';
    }
    if (body.contains('invalid_token')) {
      return '登录已失效，请重新登录';
    }
    return '用户名或密码错误';
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

  // ---- 桌面壳层：面板折叠与编辑模式（M7-T06，FR-40 / FR-41） ----

  /// 切换左侧栏折叠态并持久化。
  Future<void> toggleLeftPanel() => setLeftPanelCollapsed(!_leftPanelCollapsed);

  /// 切换中栏笔记列表折叠态并持久化。
  Future<void> toggleNoteList() => setNoteListCollapsed(!_noteListCollapsed);

  /// 幂等置位左侧栏折叠态（供「视图」菜单勾选项使用）。
  ///
  /// 只改呈现：不清空 `selectedNotebookId` / `selectedNoteId` / 查询词 / 标签筛选 /
  /// 排序，不写笔记、不入同步队列、不产生修订（BR-40.2）；折叠态为本机偏好，
  /// 不写入同步净荷（BR-40.3）。
  Future<void> setLeftPanelCollapsed(bool collapsed) async {
    if (collapsed == _leftPanelCollapsed) return;
    _leftPanelCollapsed = collapsed;
    // 先刷新界面、再落盘：折叠是纯呈现，持久化失败不得阻断 UI（M7-T12 实测缺陷）。
    notifyListeners();
    await _persistPref(_kLeftPanelCollapsed, collapsed ? 'true' : 'false');
  }

  /// 幂等置位中栏笔记列表折叠态。
  Future<void> setNoteListCollapsed(bool collapsed) async {
    if (collapsed == _noteListCollapsed) return;
    _noteListCollapsed = collapsed;
    notifyListeners();
    await _persistPref(_kNoteListCollapsed, collapsed ? 'true' : 'false');
  }

  /// 置位编辑器模式并持久化（详细设计 §5.1）。
  ///
  /// 修正性改进：模式不再随切换笔记重置（视图偏好理应稳定）；三态仍共享同一
  /// Markdown 正本，切换只改呈现，不保存、不入修订（守 BR-23.1）。
  Future<void> setEditorMode(EditorMode mode) async {
    if (mode == _editorMode) return;
    _editorMode = mode;
    notifyListeners();
    await _persistPref(_kEditorMode, mode.persistentName);
  }

  /// 读取**独立笔记窗口**的编辑三态偏好（M8 · 详细设计 §5.2 / §8）。
  ///
  /// 窗口局部状态，与主窗口三态各自独立；缺省 [EditorMode.formatted]。由
  /// `SuiNoteWindow` 在首帧读取。
  Future<EditorMode> loadWindowNoteEditorMode() async =>
      editorModeFromName(await _settings.get(_kWindowNoteEditorMode));

  /// 持久化**独立笔记窗口**的编辑三态偏好（尽力落盘，失败只记录不抛出）。
  Future<void> saveWindowNoteEditorMode(EditorMode mode) =>
      _persistPref(_kWindowNoteEditorMode, mode.persistentName);

  // ---- 桌面壳层：编辑器命令桥与退出（M7-T08 / M7-T10，FR-41 / 详细设计 §4.2 §5.1 §7） ----

  /// 各视图的编辑器命令桥注册表（M8 收敛点，详细设计 §5.1）。
  ///
  /// 撤销 / 重做 / 剪切 / 复制 / 粘贴 / 全选 / 导出 / 回写刷新的真实实现都在
  /// 编辑器内部（`_NoteEditorState`），壳层触达不到，故由编辑器在 `initState`
  /// 按**视图键**注册自身、`dispose` 注销。
  ///
  /// M7 曾用单一可空 target（当时主窗口只有一个编辑器）；引入多窗口后（ADR-012）
  /// 改为按视图键索引，避免多个独立笔记窗口抢同一 target：`viewKey` 主窗口固定
  /// [kMainViewKey]，独立窗口取窗口句柄（详细设计 §5.1）。
  final Map<Object, EditorCommandTarget> _editorTargets = {};

  /// 当前活动（焦点）视图的键（详细设计 §5.1）：菜单 / 快捷键命令派发到**当前活动
  /// 窗口**对应的 target。默认主窗口，由窗口焦点事件（`SuiWindowObserver`）更新。
  Object _activeViewKey = kMainViewKey;

  /// 当前活动视图键：供命令置灰谓词与执行体取**本视图自己的**目标（§5.1）。
  Object get activeViewKey => _activeViewKey;

  /// 更新活动视图键（由窗口焦点事件回调；不通知——命令可用性在菜单展开时现算）。
  void setActiveViewKey(Object viewKey) {
    _activeViewKey = viewKey;
  }

  /// 取 [viewKey] 视图自己的编辑器命令桥；该视图未挂载编辑器时为 `null`（§5.1）。
  EditorCommandTarget? targetFor(Object viewKey) => _editorTargets[viewKey];

  /// 正文编辑类命令是否可用（BR-41.4 / AC-119）。
  ///
  /// 未选笔记 / 预览模式（只读呈现）/ 当前活动视图未挂载编辑器时一律不可用，
  /// 对应菜单项置灰。
  bool get canEditContent =>
      _selectedNoteId != null &&
      _editorMode != EditorMode.preview &&
      targetFor(_activeViewKey) != null;

  /// 登记某视图的编辑器命令桥（由 `_NoteEditorState.initState` 调用）。
  ///
  /// 刻意不 `notifyListeners()`：注册发生在构建阶段，通知会触发祖先 `markNeedsBuild`
  /// 而撞上「构建期重建」断言；菜单项可用性由 `isEnabled` 在菜单展开时现算，无需通知。
  void registerEditorTarget(Object viewKey, EditorCommandTarget target) {
    if (identical(_editorTargets[viewKey], target)) return;
    _editorTargets[viewKey] = target;
  }

  /// 注销某视图的编辑器命令桥（由 `_NoteEditorState.dispose` 调用）。同样不作通知，理由同
  /// [registerEditorTarget]。
  ///
  /// **必须带身份校验**：同一视图键下编辑器会交替替换——`NoteEditor(key: ValueKey(noteId))`
  /// 让「无笔记 → 选中笔记」时旧元素被替换，Flutter 在同一帧内**先** `initState` 新实例（注册）
  /// **后**才 `dispose` 旧实例（注销）。若只按键移除，旧实例会把新实例刚登记的 target 一并删掉。
  void unregisterEditorTarget(Object viewKey, EditorCommandTarget target) {
    if (identical(_editorTargets[viewKey], target)) {
      _editorTargets.remove(viewKey);
    }
  }

  // ---- 独立笔记窗口注册表（M8 · 详细设计 §4 / §5.3 / §7） ----

  /// 已打开的笔记窗口：`noteId → 窗口句柄`（主 isolate 单一事实来源，§4.1）。
  ///
  /// 键为 `noteId`（BR-43.3 天然唯一，与「一笔记一窗口」一一对应）；句柄即独立窗口
  /// 的视图键，用于取该窗口自己的编辑器命令桥（[targetFor]）。注册表是**内存态**，
  /// 重启不恢复（§4.1）。
  final Map<String, Object> _openNotes = {};

  /// 独立笔记窗口承载的笔记摘要缓存（`noteId → NoteSummary`）。
  ///
  /// 中栏列表 [_notes] 始终是**筛选后**结果（受笔记本 / 标签 / 搜索 / 视图影响），
  /// 独立窗口的笔记可能不在其中。为使独立窗口的标题与编辑器解析不受主窗口中栏筛选
  /// 影响（BR-42.2 / AC-125），打开窗口时按 id 取一次摘要缓存于此，笔记保存时刷新、
  /// 窗口关闭时清理。
  final Map<String, NoteSummary> _windowNoteSummaries = {};

  /// 按 id 取笔记，**不受中栏筛选 / 排序影响**（供独立窗口与编辑器解析，AC-125）。
  ///
  /// 先查当前中栏列表 [_notes]，再回落到独立窗口缓存 [_windowNoteSummaries]。
  Note? noteById(String? id) {
    if (id == null) return null;
    for (final s in _notes) {
      if (s.note.id == id) return s.note;
    }
    return _windowNoteSummaries[id]?.note;
  }

  /// 按 id 取笔记标签，**不受中栏筛选影响**（供编辑器解析，AC-125）。
  List<String> tagsById(String? id) {
    if (id == null) return const [];
    for (final s in _notes) {
      if (s.note.id == id) return s.tags;
    }
    return _windowNoteSummaries[id]?.tags ?? const [];
  }

  /// 活动窗口句柄集合（含主窗口）；集合清空即退出（§7「无窗口即退出」，防驻留）。
  ///
  /// **预置主窗口** [kMainViewKey]：主窗口是应用入口视图，`multiview_desktop` 的
  /// `registerInitialWindow` 刻意**不**触发 `onWindowOpened`（仅次级窗口触发），
  /// 故必须在此预置；否则关掉第一个独立窗口时集合会误判为空而提前退出进程。
  /// 主窗口的关闭仍会经 `onWindowClosed` 送达（其公开视图 id 恒为 `1`，由
  /// `SuiWindowObserver` 折算为 [kMainViewKey]）。
  final Set<Object> _activeWindows = {kMainViewKey};

  /// 是否已进入退出流程（防止关闭回调重入重复退出）。
  bool _quitting = false;

  /// 占用态变化信号：已打开的笔记集合变化时自增，供笔记列表刷新占用态标识（BR-43.5）。
  final ValueNotifier<int> _openNotesChanged = ValueNotifier<int>(0);

  /// 供列表监听的占用态变化信号（BR-43.5）。
  ValueListenable<int> get openNotesChanged => _openNotesChanged;

  /// 当前活动窗口数（含主窗口）。
  int get activeWindowCount => _activeWindows.length;

  /// [noteId] 是否已在独立窗口打开（BR-43.5，供列表渲染占用态标识）。
  bool isNoteOpen(String noteId) => _openNotes.containsKey(noteId);

  /// 已打开的笔记窗口句柄（只读快照，供测试与调试）。
  Map<String, Object> get openNoteHandles => Map.unmodifiable(_openNotes);

  /// 打开（或聚焦）承载 [noteId] 的独立笔记窗口（§4.3 去重聚焦）。
  ///
  /// - 已打开且句柄仍有效 → 仅聚焦（BR-43.1 / BR-43.2），不新开；
  /// - 句柄失效（系统已关但回调未及）→ 清理后按「未打开」处理（BR-43.6 异常自愈）；
  /// - 未注入窗口管理器（Web / 移动端 / 单测）→ **优雅降级**为主窗口内选中该笔记
  ///   （BR-42.5 / AC-128）。
  ///
  /// **不改动主窗口选中**（BR-42.2 两面并行）：独立窗口打开后主窗口照常呈现并可编辑该笔记，
  /// 两窗口共享同一 `AppController` 与同一 Markdown 正本、编辑实时互相同步。
  Future<void> openNoteInWindow(String noteId) async {
    final manager = _windowManager;
    if (manager == null) {
      selectNote(noteId);
      return;
    }
    final existing = _openNotes[noteId];
    if (existing != null) {
      if (manager.isNoteWindowValid(existing)) {
        await focusWindow(noteId);
        return;
      }
      _openNotes.remove(noteId); // 自愈：清理失效句柄（BR-43.6）
      _windowNoteSummaries.remove(noteId);
    }
    // 先缓存摘要，使独立窗口首帧即可解析标题与内容（不受中栏筛选影响）。
    final summary = await _repository.getNoteSummary(noteId);
    if (summary == null) return; // 笔记已不存在 → 异常自愈，不新开窗口（BR-43.6）
    _windowNoteSummaries[noteId] = summary;
    final handle = await manager.openNoteWindow(noteId);
    if (handle == null) {
      _windowNoteSummaries.remove(noteId);
      return;
    }
    _openNotes[noteId] = handle;
    setActiveViewKey(handle);
    _openNotesChanged.value++;
  }

  /// 置前并聚焦 [noteId] 对应的独立窗口（BR-43.2；若最小化则先还原）。
  Future<void> focusWindow(String noteId) async {
    final handle = _openNotes[noteId];
    if (handle == null) return;
    setActiveViewKey(handle);
    _windowManager?.focusNoteWindow(handle);
  }

  /// 关闭 [noteId] 的独立窗口（供「关闭窗口」入口调用）。
  Future<void> closeNoteWindow(String noteId) async {
    final handle = _openNotes[noteId];
    if (handle == null) return;
    await _windowManager?.closeNoteWindow(handle);
    // 真实关闭回调会经 [onWindowClosed] 释放占用；此处兜底，避免句柄悬挂。
    onWindowClosed(handle);
  }

  /// 窗口打开回调（由 `SuiWindowObserver` 转发，§7）：登记活动窗口。
  void onWindowOpened(Object handle) {
    _activeWindows.add(handle);
  }

  /// 窗口关闭回调（由 `SuiWindowObserver` 转发，§4.1 / §7）。
  ///
  /// 移出注册表并释放该 `noteId` 占用（BR-43.4），同步维护活动窗口集合；
  /// 集合清空则退出进程（§7「无窗口即退出」，防驻留）。
  void onWindowClosed(Object handle) {
    // 幂等：兜底路径与真实关闭回调可能各来一次，第二次直接忽略。
    final tracked = _activeWindows.remove(handle);
    final knownNote = _openNotes.containsValue(handle);
    if (!tracked && !knownNote) return;
    final closedNoteIds =
        _openNotes.entries.where((e) => e.value == handle).map((e) => e.key).toList();
    _openNotes.removeWhere((_, value) => value == handle);
    for (final id in closedNoteIds) {
      _windowNoteSummaries.remove(id);
    }
    _editorTargets.remove(handle);
    if (_activeViewKey == handle) _activeViewKey = kMainViewKey;
    _openNotesChanged.value++;
    if (_activeWindows.isEmpty) {
      exitApp();
    }
  }

  /// 「查找笔记」请求信号（详细设计 §4.3）。
  ///
  /// 现有能力中没有「笔记内查找」，故「查找」定义为：先展开中栏，再聚焦其搜索框。
  /// 用自增计数器而非布尔量——布尔量第二次触发不会变化，`NoteList` 便收不到通知。
  final ValueNotifier<int> _findNotesRequests = ValueNotifier<int>(0);

  /// 供 `NoteList` 监听的「查找笔记」请求信号。
  ValueListenable<int> get findNotesRequests => _findNotesRequests;

  /// 尚未被 `NoteList` 消费的「查找」请求。
  ///
  /// 「查找」命令会先展开中栏再发信号，而 `setNoteListCollapsed` 的通知在下一次
  /// 建帧时才生效——此刻中栏尚未挂载，纯 `ValueNotifier` 通知会落空。故用此标志
  /// 让随后建起来的 `NoteList` 在 `initState` 补一次聚焦（AC-120）。
  bool _findNotesPending = false;

  /// 请求聚焦笔记列表的搜索框（「编辑 → 查找」）。
  void requestFindNotes() {
    _findNotesPending = true;
    _findNotesRequests.value++;
  }

  /// 消费待处理的「查找」请求；有则返回 `true`（由 `NoteList` 调用，AC-120）。
  bool consumeFindNotesRequest() {
    if (!_findNotesPending) return false;
    _findNotesPending = false;
    return true;
  }

  /// 「文件 → 退出应用」（详细设计 §7）：先结束**所有**窗口编辑器的防抖落库，再尽力推送
  /// 一次，最后关闭全部独立窗口并退出进程。
  ///
  /// 本地写入本身不防抖，落库随编辑即时发生；但推送到服务端受 `_syncDebounce`
  /// （700ms）与 30s 周期器节制——进程一结束周期器不再触发，故退出前必须补一次
  /// 尽力推送，否则本次改动可能停在本地。
  ///
  /// M8 起是多窗口：需对**每个**视图各自的编辑器命令桥补一次回写（§7 第 1 步），
  /// 否则独立笔记窗口里尚未落库的 400ms 防抖内容会随窗口销毁而丢失。
  Future<void> quitApplication() async {
    if (_quitting) return;
    _quitting = true;
    // 1. 结束所有窗口编辑器的 400ms 防抖，写回本地库。
    await Future.wait(
      _editorTargets.values.map((t) => t.flushPendingEdits()),
    );
    // 2. 尽力推送一次（超时 / 失败都不阻塞退出）。
    await _flushPendingSync();
    // 3. 关闭全部独立窗口，随后退出进程（主窗口随进程退出结束）。
    try {
      await _windowManager?.closeAllNoteWindows();
    } catch (_) {
      // 忽略：退出优先。
    }
    exitApp();
  }

  /// 退出前的尽力推送：取消防抖并立即同步，带短超时。
  ///
  /// 超时 / 失败都不阻塞退出——本地库已经落盘，宁可丢一次推送也不能卡住退出。
  Future<void> _flushPendingSync() async {
    _syncDebounce?.cancel();
    _syncDebounce = null;
    if (_syncClient == null) return;
    try {
      await syncNow().timeout(const Duration(seconds: 3));
    } catch (_) {
      // 忽略：退出优先（详细设计 §7）。
    }
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

  /// 刷新并**返回** [noteId] 的附件列表。
  ///
  /// 多窗口下多个编辑器可能并发刷新**不同**笔记，共享的 [attachments] 字段会被
  /// 「后到者」覆盖，故调用方必须以本方法的**返回值**为准，不得回读 [attachments]
  /// （详细设计 §5.2 · 避免窗口间串扰）。
  Future<List<Attachment>> refreshAttachments(String noteId) async {
    final list = await _repository.listAttachments(noteId: noteId);
    _attachments = list;
    notifyListeners();
    return list;
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
  ///
  /// 返回该笔记**刷新后**的附件列表（无 `noteId` 时为 `null`），供调用方直接采用，
  /// 避免回读共享字段（详细设计 §5.2）。
  Future<List<Attachment>?> removeAttachment(Attachment a) async {
    await _repository.removeAttachment(a.id);
    final noteId = a.noteId;
    if (noteId == null) return null;
    final list = await refreshAttachments(noteId);
    final note = await _repository.getNote(noteId);
    if (note != null) await _enqueueAndSchedule(note);
    return list;
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

  // ---- 外部打开与回写（FR-47 / 详细设计 §12.2 / §12.3） ----

  /// 外部编辑变更监视：附件 id → 定时器（每 2s 重读一次临时文件）。
  final Map<String, Timer> _externalWatchers = {};

  /// 用系统默认应用打开附件（FR-47 / BR-47.2 / AC-149）。
  ///
  /// 字节先经 [openAttachment] 就绪（本地命中或按需下载），再落系统临时文件交系统
  /// 壳层打开；成功返回 true，当前平台不支持（Web / 移动端在零依赖下无法唤起系统
  /// 应用）返回 false，由 UI 降级为内置预览。打开后启动**变更监视**，外部应用一
  /// 保存即回写（AC-150）。
  Future<bool> openAttachmentExternally(Attachment a) async {
    final bytes = await openAttachment(a);
    if (bytes == null) return false;
    final path = await openExternally(filename: a.filename, bytes: bytes);
    if (path == null) return false;
    _watchExternalEdit(a, path);
    return true;
  }

  /// 监视外部编辑（§12.3 步骤①「检测」）：每 2s 重读临时文件，连续两次读到
  /// 「不同于原内容且彼此一致」的字节，即视为外部应用已保存完成 → 回写。
  void _watchExternalEdit(Attachment a, String path) {
    _externalWatchers[a.id]?.cancel();
    String? lastHash;
    final timer = Timer.periodic(const Duration(seconds: 2), (t) async {
      final current = await readExternalFile(path);
      if (current == null) return;
      final hash = sha256Hex(current);
      if (hash == a.sha256 || lastHash != hash) {
        lastHash = hash;
        return;
      }
      // 连续两次读到相同、且不同于原始内容的新字节 → 判定保存完成。
      t.cancel();
      _externalWatchers.remove(a.id);
      await replaceAttachmentBytes(a, current);
      await cleanupExternalFile(path);
    });
    _externalWatchers[a.id] = timer;
  }

  /// 外部编辑回写（FR-47 / AC-150 / 详细设计 §12.3）：把新字节重新入库为当前附件。
  ///
  /// 内容寻址下回写 = 新区块 + 换引用：
  /// ① 新字节落 BlobStore（新 sha256，天然去重、**绝不覆盖旧值**）；
  /// ② 附件映射改指新 hash（旧引用 −1、新引用 +1，见
  ///    [NoteRepository.updateAttachmentSha]）；
  /// ③ **仅当引用语法本身变化时**改写本笔记正本里的 `sui://<旧>` → `sui://<新>`：
  ///    不无谓触碰正本（§12.4），但 hash 变了就必须改写，否则渲染层解析不到新字节；
  /// ④ 入队同步，让对端按需拉到新字节（BR-47.4）。
  /// 字节与原内容一致（sha256 未变）时返回 false（无变更）。
  Future<bool> replaceAttachmentBytes(Attachment a, Uint8List bytes) async {
    final store = _blobStore;
    if (store == null) return false;
    final newSha = sha256Hex(bytes);
    if (newSha == a.sha256) return false;
    await store.put(sha256: newSha, bytes: bytes);
    final updated = await _repository.updateAttachmentSha(
      a.id,
      newSha256: newSha,
      newByteSize: bytes.length,
    );
    if (updated == null) return false;

    final noteId = a.noteId;
    if (noteId != null) {
      final note = await _repository.getNote(noteId);
      if (note != null) {
        final oldRef = 'sui://${a.sha256}';
        if (note.contentMarkdown.contains(oldRef)) {
          await saveNote(
            noteId,
            content: note.contentMarkdown.replaceAll(oldRef, 'sui://$newSha'),
          );
        }
      }
      await refreshAttachments(noteId);
    }

    final client = _syncClient;
    if (client != null) {
      try {
        await client.uploadBlob(newSha);
      } on Exception {
        // 断网：新字节已在本地（未标 uploadedAt），同步周期 backfill 补传。
      }
    }
    notifyListeners();
    return true;
  }


  // ---- 加密笔记本：解锁 / 回锁 / 空闲自动回锁（M10-T29 / FR-51，详细设计 §6.1 / §7） ----

  /// 解锁态的**空闲自动回锁**时限（§7：默认 15 分钟；可注入以便测试）。
  final Duration _autoRelockIdle;

  Timer? _relockTimer;

  /// 最近一次「因未解锁被拒」的提示（编辑被回锁拦下 / 往锁定笔记本新建被拒）。
  String? _lockedNotice;
  String? get lockedNotice => _lockedNotice;

  void clearLockedNotice() {
    if (_lockedNotice == null) return;
    _lockedNotice = null;
    notifyListeners();
  }

  /// 该笔记本当前是否已解锁（`K_nb` 只在**本端内存**，不持久化，§7）。
  bool isNotebookUnlocked(String? notebookId) =>
      notebookId != null && _repository.isNotebookUnlocked(notebookId);

  /// 是否存在任一已解锁的加密笔记本（UI 据此显示「全部锁定」入口）。
  bool get hasUnlockedNotebook =>
      _repository.keyStore.unlockedNotebookIds.isNotEmpty;

  /// 当前选中笔记的摘要（未选中 / 不在当前列表时为 null）。
  NoteSummary? get selectedNoteSummary {
    final id = _selectedNoteId;
    if (id == null) return null;
    for (final s in _notes) {
      if (s.note.id == id) return s;
    }
    return null;
  }

  /// 选中笔记是否「加密且未解锁」：UI 据此渲染**占位面板**而不是编辑器（§6.3）。
  bool get selectedNoteLocked => selectedNoteSummary?.note.locked ?? false;

  /// 选中笔记所属笔记本（解锁 / 手动锁定入口用）。
  String? get selectedNoteNotebookId => selectedNoteSummary?.note.notebookId;


  /// 解锁加密笔记本。密码错误返回 `false`（不抛异常，由 UI 提示「锁定密码错误」）。
  Future<bool> unlockNotebook(String notebookId, String password) async {
    try {
      await _repository.unlockNotebook(notebookId, password);
    } on NotebookUnlockException {
      return false;
    } on CryptoMetaFormatException catch (e) {
      // §11：`crypto_meta` 损坏 → 明确提示，**不**当明文处理。
      _lockedNotice = '加密笔记本元数据损坏：$e';
      notifyListeners();
      return false;
    }
    _lockedNotice = null;
    _touchUnlockActivity();
    // 解锁后列表要立刻从占位换成明文。
    await refreshNotes();
    return true;
  }

  /// 手动回锁单个笔记本（§7「锁定」按钮）。
  Future<void> lockNotebook(String notebookId) async {
    _repository.lockNotebook(notebookId);
    await _afterLockChange();
  }

  /// 全部回锁（登出 / 关闭应用 / 会话结束 / 空闲超时）。
  Future<void> lockAllNotebooks() async {
    _repository.lockAllNotebooks();
    await _afterLockChange();
  }

  Future<void> _afterLockChange() async {
    if (!hasUnlockedNotebook) {
      _relockTimer?.cancel();
      _relockTimer = null;
    }
    // 内存里已不持有 `K_nb`，界面必须立刻回到占位（不能继续显示刚才的明文）。
    await refreshNotes();
    notifyListeners();
  }

  /// 续期空闲回锁计时：任何「解锁态操作」都算活动（§7）。
  void _touchUnlockActivity() {
    if (!hasUnlockedNotebook) return;
    _relockTimer?.cancel();
    _relockTimer = Timer(_autoRelockIdle, () {
      _relockTimer = null;
      // 自动回锁与手动回锁走同一路径：清内存密钥 + 界面回占位。
      unawaited(lockAllNotebooks());
    });
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    _syncTicker?.cancel();
    _relockTimer?.cancel();
    for (final t in _externalWatchers.values) {
      t.cancel();
    }
    _externalWatchers.clear();
    _wsSub?.cancel();
    _ws?.sink.close();
    _syncClient?.close();
    _blobStore?.dispose();
    _auth?.close();
    _windowEventHub?.unbind();
    _editorTargets.clear();
    _openNotes.clear();
    _activeWindows.clear();
    _openNotesChanged.dispose();
    _findNotesRequests.dispose();
    super.dispose();
  }
}
