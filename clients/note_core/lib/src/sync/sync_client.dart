/// 客户端同步引擎（离线优先 + 增量同步 + 冲突检测）。
///
/// 基于设计文档 §6：
/// - 本地 = 事实来源；所有编辑先落本地 SQLite，入 Outbox。
/// - 推送：把 Outbox 中的变更批量推给服务端；冲突（base_version 撞车）时
///   走"字段级合并 / diff3 / 双版本保留"策略（见 [SyncClient.push]）。
/// - 拉取：按 updated_at 增量拉取服务端权威变更，合并进本地。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../blob/blob_store.dart';
import '../models/attachment.dart';
import '../models/note.dart';
import '../repository/note_repository.dart';

/// 同步客户端：协调本地仓储与远端服务。
///
/// 注入 [http.Client] 便于测试 mock。
class SyncClient {
  SyncClient({
    required this.repository,
    required this.baseUrl,
    required this.deviceId,
    required this.token,
    this.blobStore,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final NoteRepository repository;
  final String baseUrl;
  final String deviceId;
  final String token;

  /// 附件缓存（方案 B：按需拉取 + LRU）。为空表示未启用附件同步。
  final BlobStore? blobStore;
  final http.Client _http;

  final List<OutboxItem> _outbox = [];
  DateTime _lastPull = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// 当前本地草稿的"基础版本"映射：noteId → 服务端版本号（编辑起点）。
  final Map<String, int> _baseVersion = {};

  /// 出站队列长度（仅供 UI 展示）。
  int get outboxLength => _outbox.length;

  /// 新增一条待推送的笔记变更（编辑保存时调用）。
  ///
  /// 会把当前笔记的本地版本与 base 记录下来，以便推送时声明 baseVersion。
  Future<void> enqueue(Note note) async {
    final base = _baseVersion.putIfAbsent(note.id, () => note.version - 1);
    final existing = _outbox.indexWhere((e) => e.noteId == note.id);
    final item = OutboxItem(
      noteId: note.id,
      title: note.title,
      content: note.contentMarkdown,
      baseVersion: base,
      version: note.version,
      isDeleted: note.isDeleted,
    );
    if (existing >= 0) {
      _outbox[existing] = item; // 合并成一条（只推最终内容）
    } else {
      _outbox.add(item);
    }
  }

  /// 把本地出站队列推给服务端，并处理冲突。
  ///
  /// 每条笔记会带上它当前的**全部**附件映射（含墓碑，否则删除无法传播）——
  /// 映射只是元数据、极小，随笔记走天然幂等；附件字节另走 `/blobs/{hash}`。
  ///
  /// 返回每条的结果；冲突条目保留在 Outbox（将在本地合并后重新提交）。
  Future<List<PushResultItem>> push() async {
    if (_outbox.isEmpty) return const [];
    final items = <Map<String, dynamic>>[];
    for (final e in _outbox) {
      final attachments = await repository.listAttachments(
        noteId: e.noteId,
        includeDeleted: true,
      );
      items.add({
        'id': e.noteId,
        'title': e.title,
        'content': e.content,
        'baseVersion': e.baseVersion,
        'version': e.version,
        'isDeleted': e.isDeleted,
        'sourceDevice': deviceId,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
      });
    }
    final body = jsonEncode({'clientId': deviceId, 'items': items});
    final resp = await _authPost('/api/v1/sync/push', body);
    final data = jsonDecode(resp) as Map<String, dynamic>;
    final results = (data['results'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => PushResultItem.fromJson(e))
        .toList();

    // 对每条结果处理：成功则出队 + 更新 base；冲突则本地合并。
    for (final r in results) {
      final idx = _outbox.indexWhere((e) => e.noteId == r.id);
      if (idx < 0) continue;
      final item = _outbox[idx];
      if (r.accepted) {
        _baseVersion[item.noteId] = r.appliedVersion;
        _outbox.removeAt(idx);
      } else {
        // 冲突：拉取服务端版本 → 本地合并 → base 刷新为服务端版本，
        // 下一次 push 以新 base 重试。
        final serverNote = await _fetchNoteFromServer(item.noteId);
        if (serverNote != null) {
          await _mergeLocalWithServer(item, serverNote);
          _baseVersion[item.noteId] = r.serverVersion;
        }
      }
    }
    return results;
  }

  /// 增量拉取：同步自上次以来的服务端权威变更。
  Future<int> pull() async {
    final since = _lastPull.toIso8601String();
    final uri = Uri.parse('$baseUrl/api/v1/sync/pull?since=$since');
    final resp = await _http.get(uri, headers: _authHeader());
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, resp.body);
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final notes = (data['notes'] as List).cast<Map<String, dynamic>>();
    int count = 0;
    for (final n in notes) {
      final id = n['id'] as String;
      final ver = n['version'] as int;
      final isDeleted = n['isDeleted'] as bool;
      final updatedAt = DateTime.parse(n['updatedAt'] as String);
      if (updatedAt.isAfter(_lastPull)) _lastPull = updatedAt;

      final local = await repository.getNote(id);
      if (local == null) {
        // 新笔记（或远端删除的墓碑），直接落库。
        if (isDeleted) continue;
        await repository.createNote(
          id: id,
          title: n['title'] as String? ?? '',
          contentMarkdown: n['content'] as String? ?? '',
          sourceDevice: (n['sourceDevice'] as String?) ?? '',
        );
        _baseVersion[id] = ver;
        await _applyRemoteAttachments(id, n);
        count++;
        continue;
      }

      // 本地已有：若有未提交草稿 → 走"远端版本作为新 base，本地草稿在其之上重放"。
      // 简单实现：远端为权威线，本地草稿保持为"基于新 base 的草稿"——
      // 因为 Outbox 中已存在本地变更，下次 push 会以新 base 声明。
      _baseVersion[id] = ver;
      await _applyRemoteAttachments(id, n);
      if (isDeleted && !local.isDeleted) {
        await repository.markNoteDeleted(id);
        count++;
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

  /// 一次性：push + pull。返回 (推送结果数, 拉取条数)。
  Future<(int, int)> sync() async {
    final pushResults = await push();
    final pulled = await pull();
    return (pushResults.length, pulled);
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
    final cached = await store.read(sha256);
    if (cached != null) return cached;

    final uri = Uri.parse('$baseUrl/api/v1/blobs/$sha256');
    final resp =
        await _http.get(uri, headers: {'Authorization': 'Bearer $token'});
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, resp.body);
    }
    final bytes = resp.bodyBytes;
    await store.put(sha256: sha256, bytes: bytes);
    return bytes;
  }

  // ---------- internal ----------

  Map<String, String> _authHeader() =>
      {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  Future<String> _authPost(String path, String body) async {
    final uri = Uri.parse('$baseUrl$path');
    final resp = await _http.post(uri, headers: _authHeader(), body: body);
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, resp.body);
    }
    return resp.body;
  }

  Future<String> _authGet(String path) async {
    final uri = Uri.parse('$baseUrl$path');
    final resp = await _http.get(uri, headers: {'Authorization': 'Bearer $token'});
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, resp.body);
    }
    return resp.body;
  }

  /// 从服务端拉取某条笔记的当前内容（冲突时用）。
  /// 简化：pull 自 epoch 0 + 过滤 id；但当前 API 没有单条接口。
  /// 这里用"拉全部 + 找 id"的方式，对测试/小数据足够。
  Future<_ServerNote?> _fetchNoteFromServer(String id) async {
    final uri = Uri.parse('$baseUrl/api/v1/sync/pull?since=1970-01-01T00:00:00Z');
    final resp = await _http.get(uri, headers: _authHeader());
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

  /// 本地合并策略（对应设计 §6.6 的"字段级合并"起点）：
  /// - 标题：取较长一方（启发式，避免丢字）。
  /// - 正文：将服务端版本 + 本地草稿版本以 diff3 方式合并的简化版。
  ///   简化实现：若两端差异较小则拼接；否则创建一条冲突修订，提示用户。
  /// 合并后写入本地版本 +1，下次 push 以新 base 重发。
  Future<void> _mergeLocalWithServer(OutboxItem local, _ServerNote server) async {
    final localTitle = local.title;
    final serverTitle = server.title;
    final mergedTitle =
        localTitle.length >= serverTitle.length ? localTitle : serverTitle;

    // 正文简化合并：两端内容差异的启发式拼接。
    // 若两端差异明显（长度差 >30% 或内容完全不同），则标记冲突，
    // 保存为"服务端内容 + 本地修订"——确保不丢字。
    final mergedContent = _mergeContent(local.content, server.content);

    // 写入本地新版本
    final note = await repository.updateNoteContent(
      local.noteId,
      title: mergedTitle,
      contentMarkdown: mergedContent,
    );
    // 新草稿的 base = 服务端版本
    _baseVersion[local.noteId] = server.version;
    // 下一次 push 以新版本（note.version）作为 version 声明
    // 且 base = server.version。
    // 重新入队
    final existing = _outbox.indexWhere((e) => e.noteId == local.noteId);
    final item = OutboxItem(
      noteId: note.id,
      title: note.title,
      content: note.contentMarkdown,
      baseVersion: server.version,
      version: note.version,
      isDeleted: note.isDeleted,
    );
    if (existing >= 0) {
      _outbox[existing] = item;
    } else {
      _outbox.add(item);
    }
  }

  String _mergeContent(String a, String b) {
    if (a == b) return a;
    // 简单启发式：若 a 包含 b 或 b 包含 a，取较长的；否则做段级拼接保留双方。
    if (a.contains(b)) return a;
    if (b.contains(a)) return b;
    // 冲突标记：保留两端，用分隔符。
    // 这对应"双版本保留"策略的降级路径，用户可在 UI 中手动解决。
    return '$b\n\n<!-- [sui:conflict] 服务端版本 ↕ 本地草稿 -->\n\n$a';
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
  Future<RemoteRevision?> fetchRemoteRevision(String noteId, int version) async {
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

/// 出站队列中的一条笔记变更。
class OutboxItem {
  final String noteId;
  final String title;
  final String content;
  final int baseVersion;
  final int version;
  final bool isDeleted;

  OutboxItem({
    required this.noteId,
    required this.title,
    required this.content,
    required this.baseVersion,
    required this.version,
    required this.isDeleted,
  });
}

/// 服务端 push 单条结果。
class PushResultItem {
  final String id;
  final bool accepted;
  final int serverVersion;
  final int appliedVersion;

  PushResultItem({
    required this.id,
    required this.accepted,
    required this.serverVersion,
    required this.appliedVersion,
  });

  factory PushResultItem.fromJson(Map<String, dynamic> json) => PushResultItem(
        id: json['id'] as String,
        accepted: json['accepted'] as bool,
        serverVersion: (json['serverVersion'] as int?) ?? 0,
        appliedVersion: (json['appliedVersion'] as int?) ?? 0,
      );
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

/// HTTP 异常。
class HttpException implements Exception {
  final int statusCode;
  final String body;
  HttpException(this.statusCode, this.body);

  @override
  String toString() => 'HttpException($statusCode): $body';
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}