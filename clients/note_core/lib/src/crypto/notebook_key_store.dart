import 'notebook_crypto.dart';

/// 解锁态的 `K_nb` **内存映射**（M10-T29 / FR-51）。
///
/// * **不持久化**：回锁 = 删除条目（BR-51.4）；应用退出 / 登出即全部消失。
/// * **不上行**：`K_nb` 绝不进入同步净荷或数据库（BR-51.5）。
/// * Dart 无法保证擦除内存中的字节，故「回锁」的实际效果是**丢弃引用**——属已知限制。
class NotebookKeyStore {
  final Map<String, NotebookKey> _keys = {};

  /// 该笔记本当前是否已解锁。
  bool isUnlocked(String notebookId) => _keys.containsKey(notebookId);

  /// 取密钥；未解锁返回 `null`（[notebookId] 为空时同样视为无密钥）。
  NotebookKey? keyFor(String? notebookId) =>
      notebookId == null ? null : _keys[notebookId];

  /// 当前已解锁的笔记本集合（只读快照，供 UI 展示锁定态）。
  Set<String> get unlockedNotebookIds => Set.unmodifiable(_keys.keys);

  /// 解锁（放入密钥）。重复解锁覆盖旧值。
  void unlock(String notebookId, NotebookKey key) => _keys[notebookId] = key;

  /// 回锁单个笔记本；返回是否确有条目被移除。
  bool lock(String notebookId) => _keys.remove(notebookId) != null;

  /// 全部回锁（登出 / 关闭应用 / 会话结束）。
  void lockAll() => _keys.clear();
}
