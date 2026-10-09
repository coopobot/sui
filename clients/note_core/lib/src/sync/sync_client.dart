/// 客户端同步引擎（离线优先 + 增量同步 + 冲突检测 + 逐项状态与核对补齐）。
///
/// 基于设计文档 §6 与 [ADR-019]：
/// - 本地 = 事实来源；所有编辑先落本地 SQLite，并**在库中标记「待上传」**。
/// - 推送：按库中状态**重建**上行批次（状态即队列，无内存 Outbox）；冲突（base 撞车）时
///   走「字段级合并 / 双侧保留」策略；**服务端没有该实体时基线归零重发**（自愈）。
/// - 拉取：按 `updated_at` 增量拉取服务端权威变更，合并进本地；游标**持久化**并回退 1 秒
///   以免「同一秒多条」永久漏拉。
/// - 核对补齐（reconcile）：`ping`（取实例身份）→ `pull?since=epoch` → 逐项判定 →
///   分批 push（仅本地 / 待上传 / 冲突）→ 回写状态与失败原因。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../blob/blob_store.dart';
import '../blob/cached_blob_store.dart';
import '../models/attachment.dart';
import '../models/note.dart';
import '../models/notebook.dart';
import '../models/tag.dart';
import '../repository/note_repository.dart';
import '../repository/settings_store.dart';
import 'entity_sync_state.dart';
import '../util/hashes.dart';

/// 同步客户端：协调本地仓储与远端服务。
///
/// 注入 [http.Client] 便于测试 mock。
class SyncClient {
  SyncClient({
    required this.repository,
    required this.baseUrl,
    required this.deviceId,
    required this.token,
    this.refreshToken = '',
    this.blobStore,
    http.Client? httpClient,
    this.settings,
    this.onTokensRefreshed,
    this.onAuthExpired,
  }) : _http = httpClient ?? http.Client();

  final NoteRepository repository;
  final String baseUrl;
  final String deviceId;

  /// 访问令牌（短时有效）。刷新成功后**就地更新**（M10/FR-49）。
  String token;

  /// 刷新令牌（**单次使用**；刷新成功后就地更新）。为空表示无法透明刷新。
  String refreshToken;

  /// 附件缓存（方案 B：按需拉取 + LRU）。为空表示未启用附件同步。
  final BlobStore? blobStore;

  /// 本地设置（M12：持久化拉取游标 `sync.lastPull` 与云端实例身份 `sync.instanceId`）。
  ///
  /// 为空时退化为「进程内游标 + 不做实例变更检测」（测试与一次性调用场景）。
  final SettingsStore? settings;

  /// 令牌刷新成功后的回调：上层据此**持久化新令牌并重连 WebSocket**
  /// （WS 子协议里带的是旧访问令牌，不重连则实时通知静默失效）。
  final Future<void> Function(String accessToken, String refreshToken)? onTokensRefreshed;

  /// 刷新令牌失效（refresh-expired / refresh-revoked）时的回调：上层提示重新登录。
  final Future<void> Function()? onAuthExpired;

  final http.Client _http;

  /// 进行中的刷新（**单飞**）：刷新令牌单次使用，并发重复刷新会被服务端判为重放并吊销会话。
  Future<bool>? _refreshInflight;

  /// 进程内游标（[settings] 为空时的退化路径）。
  DateTime _memoryCursor = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// 待上传条数（界面角标 / [outboxLength]）；由 [refreshQueuedCount] 刷新。
  int _queuedCount = 0;
  int get outboxLength => _queuedCount;

  /// 单次上行批次上限（遵守服务端单次条目上限，BR-54.4）。
  static const int pushBatchSize = 200;

  /// 刷新待上传条数缓存。
  Future<void> refreshQueuedCount() async {
    _queuedCount = await repository.countNeedingUpload();
  }

  // ---------- 标记待上传（M12：队列由库状态驱动） ----------

  /// 标记该笔记「有未上传改动」。
  ///
  /// M12 起上行批次由库中 `sync_state` **重建**（状态即队列，ADR-019 决策 2），
  /// 故本方法不再持有任何载荷，只做状态标记——保留它是为了让既有调用点
  /// （控制器 / 测试）语义不变，也避免「入队内容」与库中内容出现两份真相。
  Future<void> enqueue(Note note) async {
    await repository.markPending(SyncEntityKind.note, note.id);
    await refreshQueuedCount();
  }

  /// 标记该笔记本「有未上传改动」。
  Future<void> enqueueNotebook(Notebook notebook) async {
    await repository.markPending(SyncEntityKind.notebook, notebook.id);
    await refreshQueuedCount();
  }

  /// 标记该标签「有未上传改动」。
  Future<void> enqueueTag(Tag tag) async {
    await repository.markPending(SyncEntityKind.tag, tag.id);
    await refreshQueuedCount();
  }

  // ---------- 上行（状态即队列） ----------

  /// 把库中「需要上行」的实体推给服务端，返回**逐项结果**（笔记 + 笔记本 + 标签）。
  ///
  /// 每篇笔记带上它当前的**全部**附件映射（含墓碑，否则删除无法传播）与标签关联——
  /// 映射只是元数据、极小，随笔记走天然幂等；附件字节另走 `/blobs/{hash}`。
  ///
  /// 「服务端没有该实体」（`notFound` / `serverVersion == 0`）的项在本轮内**归零基线并重发一次**，
  /// 无需等下一个同步周期（ADR-019 决策 3，修复旧实现的永久冲突）。
  Future<List<PushResultItem>> push({bool includeHeld = false}) async {
    final first = await _pushOnce(includeHeld: includeHeld);
    var results = first.results;
    // 「服务端没有该实体」的项已在 _pushOnce 内基线归零：同一轮内立刻重发，
    // 不必等下一个同步周期（笔记 / 笔记本 / 标签三类都覆盖）。
    if (first.rebased.hasAny) {
      final second = await _pushOnce(
        onlyNoteIds: first.rebased.notes.isEmpty ? null : first.rebased.notes,
        onlyNotebookIds:
            first.rebased.notebooks.isEmpty ? null : first.rebased.notebooks,
        onlyTagIds: first.rebased.tags.isEmpty ? null : first.rebased.tags,
        includeHeld: includeHeld,
        // 重发轮**不再合并**：本轮已合并过，若服务端又变了就记「冲突」等下轮/人工，
        // 否则每次 push 都会再拼一段冲突标记，内容无界膨胀。
        allowMerge: false,
      );
      results = [...results, ...second.results];
    }
    await refreshQueuedCount();
    return results;
  }

  Future<({List<PushResultItem> results, _RebaseSet rebased})> _pushOnce({
    Set<String>? onlyNoteIds,
    Set<String>? onlyNotebookIds,
    Set<String>? onlyTagIds,
    bool includeHeld = false,
    bool allowMerge = true,
  }) async {
    final batch = await _collectBatch(
      onlyNoteIds: onlyNoteIds,
      onlyNotebookIds: onlyNotebookIds,
      onlyTagIds: onlyTagIds,
      includeHeld: includeHeld,
    );
    if (batch.isEmpty) {
      return (results: const <PushResultItem>[], rebased: _RebaseSet());
    }
    final body = await _buildBody(batch);
    final String resp;
    try {
      resp = await _authPost('/api/v1/sync/push', jsonEncode(body));
    } catch (e) {
      // 整批失败：逐项记「同步失败」+ 原因（保持可重试），再向上抛以驱动界面状态。
      await _markBatchFailed(batch, _errorText(e));
      rethrow;
    }
    final data = jsonDecode(resp) as Map<String, dynamic>;
    final results = (data['results'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => PushResultItem.fromJson(e))
        .toList();
    final nbResults = (data['notebookResults'] as List?)
        ?.cast<Map<String, dynamic>>()
        .map((e) => PushResultItem.fromJson(e))
        .toList();
    final tagResults = (data['tagResults'] as List?)
        ?.cast<Map<String, dynamic>>()
        .map((e) => PushResultItem.fromJson(e))
        .toList();

    final rebased = _RebaseSet();
    for (final r in results) {
      final queued = batch.notes.where((e) => e.id == r.id).firstOrNull;
      if (r.accepted) {
        // 回写服务端基线镜像 + 精确回填该条修订的 server_version（§9.5）。
        await repository.markSynced(SyncEntityKind.note, r.id,
            serverVersion: r.appliedVersion);
        if (queued != null && queued.revisionVersion > 0) {
          await repository.setRevisionServerVersion(
              r.id, queued.revisionVersion, r.appliedVersion);
        }
        continue;
      }
      if (r.notFound) {
        // 服务端从未持有 → 基线归零，本轮内重发即被接受。
        await repository.resetSyncBaseline(SyncEntityKind.note, r.id);
        rebased.notes.add(r.id);
        continue;
      }
      if (!allowMerge) {
        // 重发轮再次冲突：不再就地合并（避免重复拼接冲突标记），保留「冲突」态。
        await repository.markConflict(SyncEntityKind.note, r.id,
            reason: '云端在同步过程中又更新了，下次同步将继续合并');
        continue;
      }
      // 真冲突：以服务端版本为 base 重放本地草稿（明文层启发式合并，绝不丢字），
      // 并在**同一轮**内重发——否则要等下一个 30s 周期才收敛。
      final ok = await _rebaseAndMerge(r.id, r.serverVersion);
      if (ok) {
        await repository.markPending(SyncEntityKind.note, r.id);
        rebased.notes.add(r.id);
      } else {
        await repository.markConflict(SyncEntityKind.note, r.id,
            reason: '云端已更新，本机也有未上传改动（加密笔记本未解锁时不就地合并）');
      }
    }
    for (final r in nbResults ?? const <PushResultItem>[]) {
      if (r.accepted) {
        await repository.markSynced(SyncEntityKind.notebook, r.id,
            serverVersion: r.appliedVersion);
      } else if (r.notFound) {
        await repository.resetSyncBaseline(SyncEntityKind.notebook, r.id);
        rebased.notebooks.add(r.id);
      } else {
        // 笔记本无内容合并：直接以服务端版本为 base，下轮重发（本端字段为准）。
        await repository.markPending(SyncEntityKind.notebook, r.id);
        await repository.setNotebookServerVersion(r.id, r.serverVersion);
      }
    }
    for (final r in tagResults ?? const <PushResultItem>[]) {
      if (r.accepted) {
        await repository.markSynced(SyncEntityKind.tag, r.id,
            serverVersion: r.appliedVersion);
      } else if (r.notFound) {
        await repository.resetSyncBaseline(SyncEntityKind.tag, r.id);
        rebased.tags.add(r.id);
      } else {
        await repository.markPending(SyncEntityKind.tag, r.id);
        await repository.setTagServerVersion(r.id, r.serverVersion);
      }
    }
    // 返回值含**全部类别**的逐项结果：核对补齐的「上行成功条数」与界面逐项结果都据此统计，
    // 只算笔记会少报笔记本 / 标签（端到端冒烟曾实测到这一点）。
    return (
      results: [
        ...results,
        ...?nbResults,
        ...?tagResults,
      ],
      rebased: rebased,
    );
  }

  Future<_PushBatch> _collectBatch({
    Set<String>? onlyNoteIds,
    Set<String>? onlyNotebookIds,
    Set<String>? onlyTagIds,
    bool includeHeld = false,
  }) async {
    final noteIds = onlyNoteIds?.toList() ??
        await repository.idsNeedingUpload(SyncEntityKind.note,
            includeHeld: includeHeld, limit: pushBatchSize);
    final batch = _PushBatch();
    for (final id in noteIds) {
      batch.notes.add(_QueuedNote(
          id, await repository.maxRevisionVersion(id)));
    }
    if (onlyNotebookIds != null) {
      batch.notebooks.addAll(onlyNotebookIds);
    } else if (onlyNoteIds == null && onlyTagIds == null) {
      batch.notebooks.addAll(await repository.idsNeedingUpload(
          SyncEntityKind.notebook,
          includeHeld: includeHeld,
          limit: pushBatchSize));
    }
    if (onlyTagIds != null) {
      batch.tags.addAll(onlyTagIds);
    } else if (onlyNoteIds == null && onlyNotebookIds == null) {
      batch.tags.addAll(await repository.idsNeedingUpload(SyncEntityKind.tag,
          includeHeld: includeHeld, limit: pushBatchSize));
    }
    if (includeHeld) {
      // 本轮把这些「被用户按住」的项认领为待上传：清除按住标记；
      // 失败则落到「同步失败」态照旧重试（不再需要用户再点一次）。
      for (final q in batch.notes) {
        await repository.clearSyncHold(SyncEntityKind.note, q.id);
      }
      for (final id in batch.notebooks) {
        await repository.clearSyncHold(SyncEntityKind.notebook, id);
      }
      for (final id in batch.tags) {
        await repository.clearSyncHold(SyncEntityKind.tag, id);
      }
    }
    return batch;
  }

  Future<Map<String, dynamic>> _buildBody(_PushBatch batch) async {
    final items = <Map<String, dynamic>>[];
    for (final q in batch.notes) {
      final note = await repository.getNote(q.id);
      if (note == null) continue; // 本地已硬删 → 跳过
      // 加密笔记：净荷只放**存储形态**（密文）。编辑器给的是明文，直接入队就会把明文发到服务端
      // ——这是端到端加密最容易被忽视的泄漏点。
      var title = note.title;
      var content = note.contentMarkdown;
      if (note.encrypted) {
        final stored = await repository.getStoredNote(q.id);
        if (stored != null) {
          title = stored.title;
          content = stored.contentMarkdown;
        }
      }
      final attachments = await repository.listAttachments(
        noteId: q.id,
        includeDeleted: true,
      );
      final tags = await repository.tagsOfNote(q.id);
      items.add({
        'id': q.id,
        'title': title,
        'content': content,
        'baseVersion': note.version,
        'version': note.version,
        'isDeleted': note.isDeleted,
        'archived': note.archived,
        // M10-T29：加密态随笔记上行（服务端只搬运；正文 / 标题此时为密文）。
        'encrypted': note.encrypted,
        'sourceDevice': deviceId,
        if (note.notebookId != null) 'notebookId': note.notebookId,
        if (tags.isNotEmpty) 'tagIds': tags.map((t) => t.id).toList(),
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
      });
    }
    final notebooksPayload = <Map<String, dynamic>>[];
    for (final id in batch.notebooks) {
      final nb = await repository.getNotebook(id);
      if (nb == null) continue;
      notebooksPayload.add({
        'id': id,
        'parentId': nb.parentId,
        'name': nb.name,
        'sortOrder': nb.sortOrder,
        'baseVersion': nb.version,
        'version': nb.version,
        'isDeleted': nb.isDeleted,
        'encrypted': nb.encrypted,
        if (nb.cryptoMeta.isNotEmpty) 'cryptoMeta': nb.cryptoMeta,
        'sourceDevice': deviceId,
      });
    }
    final tagsPayload = <Map<String, dynamic>>[];
    for (final id in batch.tags) {
      final tag = await repository.getTag(id);
      if (tag == null) continue;
      tagsPayload.add({
        'id': id,
        'name': tag.name,
        'baseVersion': tag.version,
        'version': tag.version,
        'isDeleted': tag.isDeleted,
        'sourceDevice': deviceId,
      });
    }
    return {
      'clientId': deviceId,
      'items': items,
      if (notebooksPayload.isNotEmpty) 'notebooks': notebooksPayload,
      if (tagsPayload.isNotEmpty) 'tags': tagsPayload,
    };
  }

  Future<void> _markBatchFailed(_PushBatch batch, String error) async {
    for (final q in batch.notes) {
      await repository.markFailed(SyncEntityKind.note, q.id, error);
    }
    for (final id in batch.notebooks) {
      await repository.markFailed(SyncEntityKind.notebook, id, error);
    }
    for (final id in batch.tags) {
      await repository.markFailed(SyncEntityKind.tag, id, error);
    }
  }

  /// 冲突处置：把本地草稿**重放到服务端当前版本之上**（base 改为服务端版本）。
  ///
  /// 返回 `true` 表示已就绪（下轮 push 即可成功）；`false` 表示无法就地合并
  /// （加密笔记本未解锁）→ 保持「冲突」并提示解锁。
  Future<bool> _rebaseAndMerge(String noteId, int serverVersion) async {
    final server = await _fetchNoteFromServer(noteId);
    if (server == null) {
      // 服务端其实没有它（例如刚被回滚）→ 走自愈路径。
      await repository.resetSyncBaseline(SyncEntityKind.note, noteId);
      return true;
    }
    final stored = await repository.getStoredNote(noteId);
    if (stored == null) return false;
    var localTitle = stored.title;
    var localContent = stored.contentMarkdown;
    var serverTitle = server.title;
    var serverContent = server.content;
    if (stored.encrypted) {
      final notebookId = stored.notebookId;
      if (notebookId == null || !repository.isNotebookUnlocked(notebookId)) {
        // 未解锁端**不就地合并**：两侧都只是密文，合并等于把密文当正文。
        return false;
      }
      final l = await repository.decryptStoredFields(
        notebookId: notebookId,
        noteId: noteId,
        title: localTitle,
        content: localContent,
      );
      final s = await repository.decryptStoredFields(
        notebookId: notebookId,
        noteId: noteId,
        title: serverTitle,
        content: serverContent,
      );
      localTitle = l.title;
      localContent = l.content;
      serverTitle = s.title;
      serverContent = s.content;
    }
    final mergedTitle =
        localTitle.length >= serverTitle.length ? localTitle : serverTitle;
    final mergedContent = _mergeContent(localContent, serverContent);
    // 写入本地新草稿（加密笔记本由写入接缝重新加密落库），并把 base 对齐服务端版本。
    await repository.updateNoteContent(
      noteId,
      title: mergedTitle,
      contentMarkdown: mergedContent,
    );
    await repository.setNoteServerVersion(noteId, serverVersion);
    return true;
  }

  String _mergeContent(String a, String b) {
    if (a == b) return a;
    // 简单启发式：若 a 包含 b 或 b 包含 a，取较长的；否则做段级拼接保留双方。
    if (a.contains(b)) return a;
    if (b.contains(a)) return b;
    // 冲突标记：保留两端，用分隔符。这对应「双版本保留」策略的降级路径。
    return '$b\n\n<!-- [sui:conflict] 服务端版本 ↕ 本地草稿 -->\n\n$a';
  }

  String _errorText(Object e) {
    final text = e.toString();
    return text.length > 300 ? text.substring(0, 300) : text;
  }

  // ---------- 下行 ----------

  /// 增量拉取：同步自上次以来的服务端权威变更，返回处理的条数。
  ///
  /// 游标**持久化**并带 `−1s` 安全回退（服务端 `updated_at` 只到秒 + 查询严格大于 ⇒
  /// 同一秒内多条会被永久跳过，B24-③）；重放最后 1 秒因下行幂等而安全。
  /// 探测到**云端实例身份变化**时抛 [CloudInstanceChangedException]，**不落任何数据**。
  Future<int> pull() async {
    final page = await _fetchPage(await _readCursor());
    final change = await _detectInstanceChange(page);
    if (change != null) throw CloudInstanceChangedException(change);
    final count = await _applyPage(page);
    await _writeCursor(page.maxUpdatedAt);
    await refreshQueuedCount();
    return count;
  }

  Future<_RemotePage> _fetchPage(DateTime since) async {
    final uri = Uri.parse(
        '$baseUrl/api/v1/sync/pull?since=${since.toUtc().toIso8601String()}');
    final resp = await _withAuth((h) => _http.get(uri, headers: h), json: true);
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, resp.body);
    }
    return _RemotePage.parse(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// 换库 / 重建判定（ADR-019 决策 4/6）。
  ///
  /// 返回非空 = 需要用户决策（调用方弹窗，选择前**不上传、不清空**）；
  /// 返回空 = 身份一致或首次连接正常记录（已就地写入身份）。
  Future<CloudInstanceChange?> _detectInstanceChange(_RemotePage page) async {
    final store = settings;
    if (store == null || page.instanceId.isEmpty) return null;
    final known = await store.instanceId();
    if (known != null) {
      if (known == page.instanceId) return null;
      return CloudInstanceChange(
        previous: known,
        current: page.instanceId,
        cloudEmpty: page.isEmpty,
      );
    }
    // 首次连接：云端为空而本机有存活实体 → 同样交由用户决策，绝不静默上传。
    if (page.isEmpty && await _hasLocalEntities()) {
      return CloudInstanceChange(
        previous: null,
        current: page.instanceId,
        cloudEmpty: true,
      );
    }
    await store.setInstanceId(page.instanceId);
    return null;
  }

  Future<bool> _hasLocalEntities() async {
    for (final kind in SyncEntityKind.values) {
      if ((await repository.allIds(kind)).isNotEmpty) return true;
    }
    return false;
  }

  /// 落库服务端下行页（笔记本 → 标签 → 笔记）。返回处理条数。
  Future<int> _applyPage(_RemotePage page) async {
    var count = 0;
    for (final nb in page.notebooks) {
      final nbId = nb['id'] as String;
      final nbVer = nb['version'] as int;
      final nbUpdated = DateTime.parse(nb['updatedAt'] as String);
      final localNb = await repository.getNotebook(nbId);
      if (localNb != null && !localNb.syncState.isSynced) {
        // 本地有未上传改动：**不覆盖**；服务端版本也变过则记冲突（本端字段为准，下轮重发）。
        if (nbVer != localNb.version) {
          await repository.markConflict(SyncEntityKind.notebook, nbId,
              reason: '云端与本地都改了');
        }
        continue;
      }
      // BUG5：下行根级笔记本 parentId 可能是空串，须归一为 null。
      final rawParentId = nb['parentId'] as String?;
      await repository.upsertRemoteNotebook(
        id: nbId,
        parentId:
            (rawParentId == null || rawParentId.isEmpty) ? null : rawParentId,
        name: nb['name'] as String? ?? '',
        sortOrder: (nb['sortOrder'] as int?) ?? 0,
        isDeleted: nb['isDeleted'] as bool? ?? false,
        version: nbVer,
        updatedAt: nbUpdated,
        encrypted: (nb['encrypted'] as bool?) ?? false,
        cryptoMeta: nb['cryptoMeta'] as String? ?? '',
      );
      count++;
    }

    for (final tg in page.tags) {
      final tagId = tg['id'] as String;
      final tagVer = tg['version'] as int;
      final tagUpdated = DateTime.parse(tg['updatedAt'] as String);
      final localTag = await repository.getTag(tagId);
      if (localTag != null && !localTag.syncState.isSynced) {
        if (tagVer != localTag.version) {
          await repository.markConflict(SyncEntityKind.tag, tagId,
              reason: '云端与本地都改了');
        }
        continue;
      }
      await repository.upsertRemoteTag(
        id: tagId,
        name: tg['name'] as String? ?? '',
        isDeleted: tg['isDeleted'] as bool? ?? false,
        version: tagVer,
        updatedAt: tagUpdated,
      );
      count++;
    }

    for (final n in page.notes) {
      final id = n['id'] as String;
      final ver = n['version'] as int;
      final isDeleted = n['isDeleted'] as bool;
      // M10-T29：加密态镜像（未解锁端据此显示占位、并且**不**尝试解析正文）。
      final remoteEncrypted = (n['encrypted'] as bool?) ?? false;
      final updatedAt = DateTime.parse(n['updatedAt'] as String);

      final local = await repository.getNote(id);
      if (local == null) {
        // 新笔记（或远端删除的墓碑）：墓碑无需落库。
        if (isDeleted) continue;
        await repository.createNote(
          id: id,
          notebookId: n['notebookId'] as String?,
          title: n['title'] as String? ?? '',
          contentMarkdown: n['content'] as String? ?? '',
          archived: (n['archived'] as bool?) ?? false,
          sourceDevice: (n['sourceDevice'] as String?) ?? '',
          version: ver,
          encrypted: remoteEncrypted,
          // 线上入口：净荷已是**存储形态**（加密笔记本内即密文），**绝不二次加密**。
          fromWire: true,
        );
        await _applyRemoteTags(id, n);
        await _applyRemoteAttachments(id, n);
        count++;
        continue;
      }

      // 本地已有：本地有任何未同步记账时以**本地为准**（不清掉未上行的编辑），
      // 但服务端版本也变过 → 记「冲突」，由合并 / 用户处置。
      final localDirty = !local.syncState.isSynced;
      if (localDirty && ver != local.version) {
        await repository.markConflict(SyncEntityKind.note, id,
            reason: '云端与本地都改了');
      }
      final remoteArchived = (n['archived'] as bool?) ?? false;
      if (!localDirty && !isDeleted) {
        await repository.applyRemoteNoteContent(
          id,
          title: n['title'] as String? ?? '',
          contentMarkdown: n['content'] as String? ?? '',
          version: ver,
          updatedAt: updatedAt,
          sourceDevice: n['sourceDevice'] as String?,
        );
      }
      if (!localDirty && remoteArchived != local.archived) {
        await repository.applyRemoteArchived(id, remoteArchived,
            updatedAt: updatedAt);
      }
      if (remoteEncrypted != local.encrypted) {
        await repository.applyRemoteEncrypted(id, remoteEncrypted);
      }
      final remoteNotebookId = n['notebookId'] as String?;
      if (remoteNotebookId != null) {
        await repository.updateNoteNotebook(id, remoteNotebookId);
      }
      await _applyRemoteTags(id, n);
      await _applyRemoteAttachments(id, n);
      if (isDeleted && !local.isDeleted) {
        await repository.markNoteDeleted(id, fromRemote: true);
        count++;
      }
      if (!localDirty) {
        // 下行收口：置「已同步」并回写服务端基线镜像（含核对时间）。
        await repository.markSynced(SyncEntityKind.note, id, serverVersion: ver);
      }
    }
    return count;
  }

  /// 落库服务端随笔记下行的附件映射（幂等）。
  ///
  /// 只写元数据与本地引用计数；**字节不在这里拉**——打开附件时才走
  /// [ensureBlob] 按需下载（方案 B）。
  Future<void> _applyRemoteAttachments(
    String noteId,
    Map<String, dynamic> note,
  ) async {
    final list = (note['attachments'] as List?)?.cast<Map<String, dynamic>>();
    if (list == null || list.isEmpty) return;
    for (final a in list) {
      await repository.upsertRemoteAttachment(
        Attachment.fromJson(a, noteId: noteId),
      );
    }
  }

  /// 落库服务端随笔记下行的标签关联（幂等）。
  Future<void> _applyRemoteTags(
    String noteId,
    Map<String, dynamic> note,
  ) async {
    final tagIds = (note['tagIds'] as List?)?.cast<String>();
    if (tagIds == null) return;
    await repository.syncNoteTags(noteId, tagIds);
  }

  // ---------- 核对补齐（FR-54 / FR-55） ----------

  /// 「全部重新同步」：核对云端权威态与本端全部实体，并按需补齐。
  ///
  /// [pushLocal] 为假时表示用户选择了**以云端为准**：只做下行，本端多出的实体
  /// **不删除**、仅标记「仅本地」且**不上行**（BR-55.2）。
  /// [hasUserDecision] 为真表示换库已获用户决策（此时接受并记录新实例身份）。
  Future<ReconcileResult> reconcile({
    bool pushLocal = true,
    bool hasUserDecision = false,
    void Function(ReconcileProgress progress)? onProgress,
    CancelToken? cancel,
  }) async {
    final issues = <SyncIssue>[];
    var downloaded = 0;
    var uploaded = 0;
    var cancelled = false;

    onProgress?.call(const ReconcileProgress(
        phase: 'check', done: 0, total: 1, detail: '正在核对云端数据'));
    final page = await _fetchPage(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));

    final change = await _detectInstanceChange(page);
    if (change != null && !hasUserDecision) {
      throw CloudInstanceChangedException(change);
    }
    final store = settings;
    if (hasUserDecision && store != null && page.instanceId.isNotEmpty) {
      // 用户已决断：接受并记录新身份（下次连接不再重复询问）。
      await store.setInstanceId(page.instanceId);
    }

    // 1) 应用云端权威态（本地有未上传改动者不覆盖，仅记冲突）。
    downloaded = await _applyPage(page);

    // 2) 云端缺失的本端实体 → 仅本地（并视用户选择决定是否补齐）。
    final serverIds = <SyncEntityKind, Set<String>>{
      SyncEntityKind.note: page.notes.map((e) => e['id'] as String).toSet(),
      SyncEntityKind.notebook:
          page.notebooks.map((e) => e['id'] as String).toSet(),
      SyncEntityKind.tag: page.tags.map((e) => e['id'] as String).toSet(),
    };
    for (final kind in SyncEntityKind.values) {
      for (final id in await repository.allIds(kind)) {
        if (serverIds[kind]!.contains(id)) continue;
        // 用户选「以云端为准」→ 保留在本机但**按住**（不再自动上行）；
        // 选「用本地补齐」→ 不按住，交由第 3 步上行。
        await repository.markLocalOnly(kind, id, hold: !pushLocal);
      }
    }

    // 3) 补齐上行（含「仅本地」项；以云端为准时整段跳过）。
    if (cancel?.isCancelled ?? false) {
      // 进入上传阶段前就已被取消：如实回报 cancelled（不静默当作「无需上传」）。
      cancelled = true;
    } else if (pushLocal) {
      var round = 0;
      while (round < 50) {
        round++;
        final total = await repository.countNeedingUpload();
        if (total == 0) break;
        onProgress?.call(ReconcileProgress(
            phase: 'upload',
            done: uploaded,
            total: uploaded + total,
            detail: '正在上传本机数据'));
        final before = await repository.countNeedingUpload();
        final results = await push(includeHeld: true);
        uploaded += results.where((r) => r.accepted).length;
        if (cancel?.isCancelled ?? false) {
          cancelled = true;
          break;
        }
        final after = await repository.countNeedingUpload();
        // 无进展（例如加密笔记本未解锁的冲突项）→ 停止，避免空转。
        if (after >= before) break;
      }
    }

    // 4) 收口：汇总未同步项（供界面「逐项结果」展示）。
    for (final kind in SyncEntityKind.values) {
      for (final id in await repository.idsNeedingUpload(kind,
          includeHeld: true, limit: 500)) {
        final state = await repository.syncStateOf(kind, id);
        final row = await _labelOf(kind, id);
        issues.add(SyncIssue(
          kind: kind,
          id: id,
          label: row.$1,
          state: state,
          error: row.$2,
        ));
      }
    }
    await refreshQueuedCount();
    final s = settings;
    if (s != null) await s.setLastReconcileAt(DateTime.now());
    onProgress?.call(const ReconcileProgress(
        phase: 'done', done: 1, total: 1, detail: '核对完成'));
    return ReconcileResult(
      downloaded: downloaded,
      uploaded: uploaded,
      issues: issues,
      cancelled: cancelled,
    );
  }

  /// 单项「立即上传 / 重试」（FR-54 / BR-54.1）：只影响该项。
  Future<EntitySyncState> retryOne(SyncEntityKind kind, String id) async {
    var state = await repository.syncStateOf(kind, id);
    if (state == EntitySyncState.synced) return state;
    // 单项重试是显式动作：解除「以云端为准」的按住标记。
    await repository.clearSyncHold(kind, id);
    if (kind == SyncEntityKind.note) {
      final server = await _fetchNoteFromServer(id);
      if (server == null) {
        // 服务端没有它 → 基线归零，直接可发。
        await repository.resetSyncBaseline(kind, id);
      } else if (state == EntitySyncState.conflict ||
          server.version != (await repository.getNote(id))?.version) {
        final ok = await _rebaseAndMerge(id, server.version);
        if (!ok) return EntitySyncState.conflict; // 加密笔记本未解锁 → 保持冲突
      }
    } else if (state == EntitySyncState.conflict) {
      await repository.markPending(kind, id);
    }
    await repository.markPending(kind, id);
    switch (kind) {
      case SyncEntityKind.note:
        await _pushOnce(onlyNoteIds: {id});
      case SyncEntityKind.notebook:
        await _pushOnce(onlyNotebookIds: {id});
      case SyncEntityKind.tag:
        await _pushOnce(onlyTagIds: {id});
    }
    await refreshQueuedCount();
    state = await repository.syncStateOf(kind, id);
    return state;
  }

  /// 取实体的展示名与失败原因（结果列表用）：(label, error)。
  Future<(String, String)> _labelOf(SyncEntityKind kind, String id) async {
    switch (kind) {
      case SyncEntityKind.note:
        final n = await repository.getNote(id);
        final title = (n?.title ?? '').trim();
        return (title.isEmpty ? '(无标题笔记)' : title, n?.syncError ?? '');
      case SyncEntityKind.notebook:
        final nb = await repository.getNotebook(id);
        return (nb?.name ?? '(笔记本)', nb?.syncError ?? '');
      case SyncEntityKind.tag:
        final t = await repository.getTag(id);
        return (t?.name ?? '(标签)', t?.syncError ?? '');
    }
  }

  // ---------- 一次性：push + pull ----------

  /// 一次性：push + pull。返回 (推送结果数, 拉取条数)。
  ///
  /// 顺序有意为之：**先补传附件字节，再 push 映射**。反过来会出现对端已经
  /// 收到映射、却下载不到字节的空窗。
  Future<(int, int)> sync() async {
    await backfillBlobs();
    final pushResults = await push();
    final pulled = await pull();
    return (pushResults.length, pulled);
  }

  /// 把本地新增、服务端尚未持有的附件字节补齐上传。返回成功条数。
  ///
  /// 挂在同步周期上而非单独的失败重试队列：新增附件时若断网，字节留在本地，
  /// 联网后自动补传，天然幂等。
  Future<int> backfillBlobs() async {
    final store = blobStore;
    if (store is! CachedBlobStore) return 0;
    var uploaded = 0;
    for (final e in await store.pendingUploads()) {
      try {
        if (await uploadBlob(e.sha256)) uploaded++;
      } on Exception {
        // 单条失败不阻断其余附件；下个周期继续。
      }
    }
    return uploaded;
  }

  /// 把本地附件字节上传到服务端（幂等）。
  ///
  /// 只上传**本机确实持有**的字节；本地没有、[blobStore] 未配置或服务端拒绝
  /// 时返回 false。成功后标记该 hash「服务端已持有」，后续周期不再重传。
  Future<bool> uploadBlob(String sha256) async {
    final store = blobStore;
    if (store == null || sha256.isEmpty) return false;
    // M10-T30：摘要来自外部（附件映射 / 正文 sui:// 引用），拼 URL 与落盘前先过白名单。
    if (!isValidSha256(sha256)) return false;
    // exists 走本地物理层，避免 read 未命中时触发一次按需下载。
    if (!await store.exists(sha256)) return false;
    final bytes = await store.read(sha256);
    if (bytes == null || bytes.isEmpty) return false;

    final uri =
        Uri.parse('$baseUrl/api/v1/blobs/${Uri.encodeComponent(sha256)}');
    // 内容寻址上传是幂等的，重放安全。
    final resp = await _withAuth(
      (h) => _http.put(
        uri,
        headers: {...h, 'Content-Type': 'application/octet-stream'},
        body: bytes,
      ),
    );
    if (resp.statusCode != 200) return false;
    if (store is CachedBlobStore) await store.markUploaded(sha256);
    return true;
  }

  /// 确保附件字节已缓存在本地（方案 B 按需下载入口）。
  ///
  /// 命中缓存直接返回；未命中则 `GET /api/v1/blobs/{hash}` 下载并写入
  /// [blobStore]（LRU 容量记账由缓存层处理）。未配置 [blobStore] 时抛异常。
  Future<Uint8List> ensureBlob(String sha256) async {
    final store = blobStore;
    if (store == null) {
      throw StateError('blobStore 未配置，无法按需下载附件');
    }
    // M10-T30：非白名单摘要直接拒绝（只拒绝、不清洗）。
    if (!isValidSha256(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', '不是合法的内容寻址摘要');
    }
    final cached = await store.read(sha256);
    if (cached != null) return cached;

    final uri =
        Uri.parse('$baseUrl/api/v1/blobs/${Uri.encodeComponent(sha256)}');
    final resp = await _withAuth((h) => _http.get(uri, headers: h));
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, resp.body);
    }
    final bytes = resp.bodyBytes;
    await store.put(sha256: sha256, bytes: bytes);
    return bytes;
  }

  // ---------- internal ----------

  /// 读取持久化游标（未配置 settings 时退回进程内游标）。
  Future<DateTime> _readCursor() async {
    final store = settings;
    if (store == null) return _memoryCursor;
    return await store.lastPull() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  /// 写入游标：取 `max(updated_at) − 1s`（下限不回退），保证同一秒多条不漏拉。
  Future<void> _writeCursor(DateTime? maxUpdated) async {
    if (maxUpdated == null) return;
    final safe = maxUpdated.subtract(const Duration(seconds: 1));
    final store = settings;
    if (store == null) {
      if (safe.isAfter(_memoryCursor)) _memoryCursor = safe;
      return;
    }
    final current = await store.lastPull();
    if (current == null || safe.isAfter(current)) {
      await store.setLastPull(safe);
    }
  }

  /// 请求头：访问令牌 + 可选 JSON 内容类型。
  Map<String, String> _headers({bool json = false}) => {
        'Authorization': 'Bearer $token',
        if (json) 'Content-Type': 'application/json',
      };

  /// 带鉴权发一次请求；命中**可刷新的 401** 时**单飞刷新 + 原样重放一次**（auth.md §8.5）。
  ///
  /// 可刷新 = `token-expired`（已过期）**或** `invalid_token`（服务端不认识本端令牌，例如会话
  /// 在别处被轮换、服务端数据回滚）。两者都**只尝试一次**：刷新失败即走 [onAuthExpired]
  /// 提示重新登录，故不存在「刷新—失败」死循环。
  Future<http.Response> _withAuth(
    Future<http.Response> Function(Map<String, String> headers) send, {
    bool json = false,
  }) async {
    Future<http.Response> once() => send(_headers(json: json));
    final first = await once();
    if (first.statusCode != 401 || !_isRefreshable(first.body)) return first;
    if (!await _refreshAccessToken()) return first;
    return once();
  }

  /// 401 响应是否属于「值得尝试一次刷新」的令牌问题。
  static bool _isRefreshable(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final code = data['error'] as String?;
      return code == 'token-expired' || code == 'invalid_token';
    } on FormatException {
      return false;
    }
  }

  /// 单飞刷新：并发请求同时过期时只发一次刷新请求。
  Future<bool> _refreshAccessToken() {
    final inflight = _refreshInflight;
    if (inflight != null) return inflight;
    final future = _doRefresh();
    _refreshInflight = future;
    return future.whenComplete(() => _refreshInflight = null);
  }

  /// 以刷新令牌换发新的一对令牌，并回调上层持久化 / 重连。
  Future<bool> _doRefresh() async {
    if (refreshToken.isEmpty) {
      await onAuthExpired?.call();
      return false;
    }
    try {
      final uri = Uri.parse('$baseUrl/api/v1/refresh');
      final resp = await _http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      );
      if (resp.statusCode != 200) {
        // refresh-expired / refresh-revoked：须重新登录（服务端可能已吊销整个会话）。
        await onAuthExpired?.call();
        return false;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final access = (data['access_token'] as String?) ?? '';
      final refresh = (data['refresh_token'] as String?) ?? '';
      if (access.isEmpty) {
        await onAuthExpired?.call();
        return false;
      }
      token = access;
      if (refresh.isNotEmpty) refreshToken = refresh;
      await onTokensRefreshed?.call(token, refreshToken);
      return true;
    } catch (_) {
      // 网络异常：不改登录态，等下一次同步重试。
      return false;
    }
  }

  Future<String> _authPost(String path, String body) async {
    final uri = Uri.parse('$baseUrl$path');
    final resp = await _withAuth((h) =>
        _http.post(uri, headers: h, body: body), json: true);
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, resp.body);
    }
    return resp.body;
  }

  Future<String> _authGet(String path) async {
    final uri = Uri.parse('$baseUrl$path');
    final resp = await _withAuth((h) => _http.get(uri, headers: h));
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, resp.body);
    }
    return resp.body;
  }

  /// 从服务端拉取某条笔记的当前内容（冲突 / 自愈判定用）。
  /// 简化：pull 自 epoch 0 + 过滤 id；当前 API 没有单条接口。
  Future<_ServerNote?> _fetchNoteFromServer(String id) async {
    final uri =
        Uri.parse('$baseUrl/api/v1/sync/pull?since=1970-01-01T00:00:00Z');
    final resp = await _withAuth((h) => _http.get(uri, headers: h), json: true);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (data['notes'] as List).cast<Map<String, dynamic>>();
    final m = list.where((e) => e['id'] == id).firstOrNull;
    if (m == null) return null;
    return _ServerNote(
      id: m['id'] as String,
      title: m['title'] as String? ?? '',
      content: m['content'] as String? ?? '',
      version: m['version'] as int,
      isDeleted: m['isDeleted'] as bool,
      sourceDevice: (m['sourceDevice'] as String?) ?? '',
    );
  }

  void close() => _http.close();

  // ---- 修订历史 ----

  /// 从服务端拉取指定笔记的修订历史列表。
  Future<List<RemoteRevision>> fetchRemoteRevisions(String noteId) async {
    final resp = await _authGet('/api/v1/notes/$noteId/revisions');
    final data = jsonDecode(resp) as Map<String, dynamic>;
    final revs = (data['revisions'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => RemoteRevision(
              version: e['version'] as int,
              title: (e['title'] as String?) ?? '',
              content: e['content'] as String,
              sourceDevice: (e['sourceDevice'] as String?) ?? '',
              isConflict: (e['isConflict'] as bool?) ?? false,
              createdAt: DateTime.parse(e['createdAt'] as String),
            ))
        .toList();
    return revs;
  }

  /// 从服务端拉取指定版本的修订详情。
  Future<RemoteRevision?> fetchRemoteRevision(
      String noteId, int version) async {
    try {
      final resp = await _authGet('/api/v1/notes/$noteId/revisions/$version');
      final data = jsonDecode(resp) as Map<String, dynamic>;
      final rev = data['revision'] as Map<String, dynamic>;
      return RemoteRevision(
        version: rev['version'] as int,
        title: (rev['title'] as String?) ?? '',
        content: rev['content'] as String,
        sourceDevice: (rev['sourceDevice'] as String?) ?? '',
        isConflict: (rev['isConflict'] as bool?) ?? false,
        createdAt: DateTime.parse(rev['createdAt'] as String),
      );
    } on HttpException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }
}

/// 服务端一页 pull 响应（含实例身份与增量水位）。
class _RemotePage {
  _RemotePage({
    required this.notes,
    required this.notebooks,
    required this.tags,
    required this.maxUpdatedAt,
    required this.instanceId,
  });

  final List<Map<String, dynamic>> notes;
  final List<Map<String, dynamic>> notebooks;
  final List<Map<String, dynamic>> tags;
  final DateTime? maxUpdatedAt;
  final String instanceId;

  bool get isEmpty => notes.isEmpty && notebooks.isEmpty && tags.isEmpty;

  factory _RemotePage.parse(Map<String, dynamic> data) {
    final notes =
        (data['notes'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final notebooks =
        (data['notebooks'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final tags =
        (data['tags'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    DateTime? max;
    void bump(Object? iso) {
      if (iso is! String || iso.isEmpty) return;
      final t = DateTime.tryParse(iso);
      if (t == null) return;
      if (max == null || t.isAfter(max!)) max = t;
    }

    for (final n in notes) {
      bump(n['updatedAt']);
    }
    for (final n in notebooks) {
      bump(n['updatedAt']);
    }
    for (final n in tags) {
      bump(n['updatedAt']);
    }
    return _RemotePage(
      notes: notes,
      notebooks: notebooks,
      tags: tags,
      maxUpdatedAt: max,
      instanceId: (data['instanceId'] as String?) ?? '',
    );
  }
}

/// 服务端 push 单条结果。
class PushResultItem {
  final String id;
  final bool accepted;
  final int serverVersion;
  final int appliedVersion;

  /// M12（ADR-019 决策 3）：服务端**没有**该实体（不是版本冲突）。
  final bool notFound;

  PushResultItem({
    required this.id,
    required this.accepted,
    required this.serverVersion,
    required this.appliedVersion,
    this.notFound = false,
  });

  factory PushResultItem.fromJson(Map<String, dynamic> json) {
    final accepted = json['accepted'] as bool;
    final serverVersion = (json['serverVersion'] as int?) ?? 0;
    return PushResultItem(
      id: json['id'] as String,
      accepted: accepted,
      serverVersion: serverVersion,
      appliedVersion: (json['appliedVersion'] as int?) ?? 0,
      // 旧服务端不返回 `notFound`：此时 `accepted == false && serverVersion == 0`
      // 同样是「服务端没有该实体」（v0.11.3 之前的行为即如此），故按同一分支自愈。
      notFound: (json['notFound'] as bool?) ??
          (!accepted && serverVersion == 0),
    );
  }
}

class _ServerNote {
  final String id;
  final String title;
  final String content;
  final int version;
  final bool isDeleted;
  final String sourceDevice;

  _ServerNote({
    required this.id,
    required this.title,
    required this.content,
    required this.version,
    required this.isDeleted,
    required this.sourceDevice,
  });
}

/// 服务端返回的修订摘要。
class RemoteRevision {
  final int version;
  final String title;
  final String content;
  final String sourceDevice;
  final bool isConflict;
  final DateTime createdAt;

  RemoteRevision({
    required this.version,
    required this.title,
    required this.content,
    required this.sourceDevice,
    required this.isConflict,
    required this.createdAt,
  });
}

/// 云端实例身份变化（换库 / 重建 / 首次连接即发现云端为空）。
class CloudInstanceChange {
  const CloudInstanceChange({
    required this.previous,
    required this.current,
    required this.cloudEmpty,
  });

  /// 上次记录的实例身份；`null` 表示本端无记录（首次连接）。
  final String? previous;
  final String current;
  final bool cloudEmpty;
}

/// 探测到云端实例变化：**调用方须先取得用户决策**（选择前不上传、不清空）。
class CloudInstanceChangedException implements Exception {
  CloudInstanceChangedException(this.change);

  final CloudInstanceChange change;

  @override
  String toString() =>
      'CloudInstanceChangedException(previous: ${change.previous}, '
      'current: ${change.current}, cloudEmpty: ${change.cloudEmpty})';
}

/// 核对 / 补齐进度（界面进度条用）。
class ReconcileProgress {
  const ReconcileProgress({
    required this.phase,
    required this.done,
    required this.total,
    this.detail = '',
  });

  /// `check`（核对）/ `upload`（上传）/ `done`（完成）。
  final String phase;
  final int done;
  final int total;
  final String detail;
}

/// 核对结果：逐项未同步清单（供「逐项结果 + 重试」）。
class ReconcileResult {
  const ReconcileResult({
    required this.downloaded,
    required this.uploaded,
    required this.issues,
    this.cancelled = false,
  });

  final int downloaded;
  final int uploaded;
  final List<SyncIssue> issues;
  final bool cancelled;
}

/// 一条未同步项（界面结果列表 / 单项重试入口）。
class SyncIssue {
  const SyncIssue({
    required this.kind,
    required this.id,
    required this.label,
    required this.state,
    this.error = '',
  });

  final SyncEntityKind kind;
  final String id;
  final String label;
  final EntitySyncState state;
  final String error;
}

/// 协作式取消令牌（核对补齐可中途取消，BR-54.4）。
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// HTTP 异常。
class HttpException implements Exception {
  final int statusCode;
  final String body;
  HttpException(this.statusCode, this.body);

  @override
  String toString() => 'HttpException($statusCode): $body';
}
/// 上行批次中一篇笔记的入队元数据。
class _QueuedNote {
  _QueuedNote(this.id, this.revisionVersion);

  final String id;

  /// 入队时本地 `MAX(revisions.version)`，push 成功后据此精确回填 `server_version`。
  final int revisionVersion;
}

/// 本轮需要「以新基线**立刻重发**」的 id 集合。
///
/// 两种来源：① 服务端没有该实体（基线已归零，ADR-019 决策 3）；
/// ② 真冲突（已在明文层合并并把基线对齐服务端版本）。两者都在同一次 [SyncClient.push]
/// 内重发一轮，避免等到下一个同步周期。
class _RebaseSet {
  final Set<String> notes = {};
  final Set<String> notebooks = {};
  final Set<String> tags = {};

  bool get hasAny => notes.isNotEmpty || notebooks.isNotEmpty || tags.isNotEmpty;
}

/// 一次上行批次的构成（笔记 / 笔记本 / 标签各自的 id）。
class _PushBatch {
  final List<_QueuedNote> notes = [];
  final List<String> notebooks = [];
  final List<String> tags = [];

  bool get isEmpty => notes.isEmpty && notebooks.isEmpty && tags.isEmpty;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
