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

  /// 周期兜底同步间隔。
  ///
  /// 离线期间的本地改动只能积在 Outbox：WS 断了等不到广播，用户也可能不再编辑
  /// 触发防抖推送。没有这个定时器，「断网可读可写、联网后自动同步」就只在
  /// 「用户恰好又编辑了一次」时才成立。空闲时 push 无内容、pull 无增量，开销极小。
  static const _syncInterval = Duration(seconds: 30);

  List<Notebook> _notebooks = [];
  List<NoteSummary> _notes = [];
  List<Tag> _tags = [];

  List<Notebook> get notebooks => _notebooks;
  List<NoteSummary> get notes => _notes;
  List<Tag> get tags => _tags;

  String? _selectedNotebookId;
  String? _selectedNoteId;
  String _query = '';
  final bool _includeArchived = false;
  bool _showRevisionPanel = false;
  bool _inboxMode = false;

  String? get selectedNotebookId => _selectedNotebookId;
  String? get selectedNoteId => _selectedNoteId;
  bool get showRevisionPanel => _showRevisionPanel;
  bool get inboxMode => _inboxMode;

  bool get hasSelection =>
      _selectedNotebookId != null || _query.isNotEmpty || _inboxMode;

  /// 首次加载：读同步配置 → 装配附件缓存 → 载入本地数据 → 若已配置则连接。
  Future<void> bootstrap() async {
    _config = await _settings.loadSyncConfig();
    _cacheLimitBytes = await _settings.cacheLimitBytes();
    _blobStore = CachedBlobStore(
      local: LocalBlobStore(_blobRoot()),
      meta: SqliteBlobCacheMeta(_db),
      maxBytes: _cacheLimitBytes,
    );
    await refreshNotebooks();
    await refreshTags();
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

  Future<void> refreshNotes() async {
    _notes = await _repository.listNotes(
      notebookId: _inboxMode ? null : _selectedNotebookId,
      search: _query.isEmpty ? null : _query,
      includeArchived: _includeArchived,
    );
    // 收件箱模式：只显示来自剪藏的笔记
    if (_inboxMode) {
      _notes =
          _notes.where((n) => n.note.sourceDevice.startsWith('clip:')).toList();
    }
    notifyListeners();
  }

  void selectNotebook(String? id) {
    _selectedNotebookId = id;
    _inboxMode = false;
    _selectedNoteId = null;
    refreshNotes();
  }

  void selectInbox() {
    _inboxMode = true;
    _selectedNotebookId = null;
    _selectedNoteId = null;
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
    await _repository.createNotebook(name: name, parentId: parentId);
    await refreshNotebooks();
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
    final note = await _repository.updateNoteContent(
      id,
      title: title,
      contentMarkdown: content,
      tags: tags,
    );
    await refreshNotes();
    await _enqueueAndSchedule(note);
  }

  Future<void> deleteNote(String id) async {
    await _repository.markNoteDeleted(id);
    if (_selectedNoteId == id) _selectedNoteId = null;
    await refreshNotes();
    notifyListeners();
    final note = await _repository.getNote(id);
    if (note != null) await _enqueueAndSchedule(note);
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

    _syncState = SyncState.syncing;
    _syncError = null;
    notifyListeners();
    try {
      await client.sync();
      _lastSyncedAt = DateTime.now();
      _syncState = SyncState.idle;
      await refreshNotebooks();
      await refreshTags();
      await refreshNotes();
    } catch (e) {
      _syncError = _describeError(e);
      _syncState = SyncState.error;
    }
    notifyListeners();
  }

  /// 探测服务端连通性，成功返回服务端版本号，失败抛异常（UI 捕获展示）。
  Future<String> testConnection(String baseUrl) =>
      _authClient().ping(baseUrl);

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

  String _blobRoot() =>
      _dataDir == null ? '' : p.join(_dataDir, 'blobs');

  AuthClient _authClient() => _auth ??= AuthClient();

  Future<void> _teardownConnection() async {
    _syncDebounce?.cancel();
    _syncDebounce = null;
    _syncTicker?.cancel();
    _syncTicker = null;
    await _wsSub?.cancel();
    _wsSub = null;
    await _ws?.sink.close();
    _ws = null;
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
      final ch = WebSocketChannel.connect(Uri.parse('$host/api/v1/ws'));
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
        401 => '用户名或密码错误',
        400 => '请求无效（用户名/密码不能为空）',
        _ => 'HTTP ${e.statusCode}: ${e.body}',
      };
    }
    return e.toString();
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

  /// 恢复到指定历史版本。恢复后刷新笔记列表和编辑器内容。
  Future<void> restoreRevision(String noteId, int version) async {
    await _repository.restoreRevision(noteId, version);
    await refreshNotes();
    notifyListeners();
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