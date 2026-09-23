import 'package:flutter/foundation.dart';
import 'package:note_core/note_core.dart';

/// 应用状态中枢：持有仓储，向 UI 暴露笔记本树/笔记列表/当前选中状态。
///
/// M1 用内存 ChangeNotifier（简单可靠）；后续如需更细粒度局部刷新，可
/// 引入 watch/select，但当前规模以清晰为先。
class AppController extends ChangeNotifier {
  AppController({required NoteRepository repository})
      : _repository = repository;

  final NoteRepository _repository;
  NoteRepository get repository => _repository;

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

  String? get selectedNotebookId => _selectedNotebookId;
  String? get selectedNoteId => _selectedNoteId;
  bool get showRevisionPanel => _showRevisionPanel;

  bool get hasSelection => _selectedNotebookId != null || _query.isNotEmpty;

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
      notebookId: _selectedNotebookId,
      search: _query.isEmpty ? null : _query,
      includeArchived: _includeArchived,
    );
    notifyListeners();
  }

  void selectNotebook(String? id) {
    _selectedNotebookId = id;
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
}