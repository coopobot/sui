import 'package:flutter/foundation.dart';
import 'package:note_core/note_core.dart';

/// 应用状态中枢：持有仓储，向 UI 暴露笔记本树/笔记列表/当前选中状态。
///
/// M1 用内存 ChangeNotifier（简单可靠）；后续如需更细粒度局部刷新，可
/// 引入 watch/select，但当前规模以清晰为先。
class AppController extends ChangeNotifier {
  AppController({required NoteRepository repository, this.syncClient})
      : _repository = repository;

  final NoteRepository _repository;
  NoteRepository get repository => _repository;

  /// 同步客户端（可选）：提供附件按需下载等跨端能力；未配置时附件只读本地缓存。
  final SyncClient? syncClient;

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

  bool get hasSelection => _selectedNotebookId != null || _query.isNotEmpty || _inboxMode;

  /// 首次加载全部数据。
  Future<void> bootstrap() async {
    await refreshNotebooks();
    await refreshTags();
    await refreshNotes();
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
      _notes = _notes.where((n) => n.note.sourceDevice.startsWith('clip:')).toList();
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
  }

  Future<void> saveNote(
    String id, {
    String? title,
    String? content,
    List<String>? tags,
  }) async {
    await _repository.updateNoteContent(
      id,
      title: title,
      contentMarkdown: content,
      tags: tags,
    );
    await refreshNotes();
  }

  Future<void> deleteNote(String id) async {
    await _repository.markNoteDeleted(id);
    if (_selectedNoteId == id) _selectedNoteId = null;
    await refreshNotes();
    notifyListeners();
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

  /// 附件字节是否已在本地缓存（未下载 ⇄ 已缓存）。
  Future<bool> isAttachmentCached(Attachment a) async {
    final store = syncClient?.blobStore;
    if (store == null) return false;
    return store.exists(a.sha256);
  }

  final Set<String> _downloading = {};

  /// 附件是否正在按需下载中（用于 UI 展示下载进度状态）。
  bool isDownloading(String sha256) => _downloading.contains(sha256);

  /// 打开 / 下载附件字节：命中缓存直接返回，未命中按需下载。
  /// 未配置同步客户端时返回 null（仅展示元数据）。
  Future<Uint8List?> openAttachment(Attachment a) async {
    final client = syncClient;
    if (client == null) return null;
    final sha = a.sha256;
    _downloading.add(sha);
    notifyListeners();
    try {
      return await client.ensureBlob(sha);
    } finally {
      _downloading.remove(sha);
      notifyListeners();
    }
  }
}