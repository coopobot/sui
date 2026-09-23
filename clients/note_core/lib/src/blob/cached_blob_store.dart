import 'dart:typed_data';

import 'blob_store.dart';
import 'local_blob_store.dart';

/// 附件缓存元数据项（LRU 记账）。
class BlobCacheEntry {
  final String sha256;
  final int byteSize;
  final DateTime lastAccessAt;
  final int refCount;

  const BlobCacheEntry({
    required this.sha256,
    required this.byteSize,
    required this.lastAccessAt,
    this.refCount = 0,
  });
}

/// 缓存元数据存取抽象。
///
/// `CachedBlobStore` 不直接依赖 drift，元数据可落 SQLite（生产）或内存
/// （测试），由实现方提供。
abstract interface class BlobCacheMeta {
  /// 查询单项；不存在返回 null。
  Future<BlobCacheEntry?> entry(String sha256);

  /// 写入或更新记账（refCount 为增量语义，可传正负值）。
  Future<void> upsert({
    required String sha256,
    required int byteSize,
    int refCountDelta = 0,
    DateTime? lastAccessAt,
  });

  /// 刷新访问时间（LRU 命中）。
  Future<void> touch(String sha256, DateTime at);

  /// 全部记账项（供 LRU 排序）。
  Future<List<BlobCacheEntry>> entries();

  /// 当前已缓存总字节数。
  Future<int> totalBytes();

  /// 删除记账项（物理字节由调用方负责）。
  Future<void> remove(String sha256);
}

/// 带容量上限与 LRU 淘汰的附件缓存（方案 B）。
///
/// 分层：
/// - 物理层：委托 [LocalBlobStore]（sha256 分片落盘）
/// - 记账层：通过 [meta] 维护 size / lastAccessAt / refCount
/// - 下载层：`read` 未命中时调用 [fetcher] 按需拉取（如 `GET /blobs/{hash}`）
///
/// 存储压力 = 固定上限 [maxBytes]，与附件总量解耦。淘汰策略：
/// 1. 先淘汰无引用的孤儿（refCount <= 0）
/// 2. 仍超限则按最旧访问时间淘汰（被淘汰后再次打开会重新下载）
class CachedBlobStore implements BlobStore {
  final LocalBlobStore _local;
  final BlobCacheMeta _meta;
  final int maxBytes;
  final Future<Uint8List> Function(String sha256)? fetcher;

  CachedBlobStore({
    required LocalBlobStore local,
    required BlobCacheMeta meta,
    this.maxBytes = 512 * 1024 * 1024,
    this.fetcher,
  })  : _local = local,
        _meta = meta;

  /// 当前已缓存总字节数（UI 展示/设置页用）。
  Future<int> get cachedBytes => _meta.totalBytes();

  /// 当前缓存上限。
  int get capacity => maxBytes;

  @override
  Future<String> put({required String sha256, required Uint8List bytes}) async {
    final hash = await _local.put(sha256: sha256, bytes: bytes);
    await _meta.upsert(
      sha256: hash,
      byteSize: bytes.length,
      refCountDelta: 1,
      lastAccessAt: DateTime.now(),
    );
    await _evictIfNeeded();
    return hash;
  }

  @override
  Future<Uint8List?> read(String sha256) async {
    final cached = await _local.read(sha256);
    if (cached != null) {
      await _meta.touch(sha256, DateTime.now());
      return cached;
    }
    // 未命中 → 按需下载（无下载源则视为不存在）。
    final fetch = fetcher;
    if (fetch == null) return null;
    final bytes = await fetch(sha256);
    if (bytes.isEmpty) return null;
    await put(sha256: sha256, bytes: bytes);
    return bytes;
  }

  @override
  Future<bool> exists(String sha256) => _local.exists(sha256);

  @override
  Future<void> delete(String sha256) async {
    await _local.delete(sha256);
    await _meta.remove(sha256);
  }

  /// 显式记录一次引用变化（附件挂到笔记 / 删除笔记时由上层调用）。
  Future<void> updateRef(String sha256, int delta) async {
    await _meta.upsert(sha256: sha256, byteSize: 0, refCountDelta: delta);
    await _evictIfNeeded();
  }

  /// 手动淘汰全部无引用孤儿（清理残留）。
  Future<void> sweepOrphans() async {
    final entries = await _meta.entries();
    for (final e in entries) {
      if (e.refCount > 0) continue;
      await _drop(e);
    }
  }

  @override
  Future<void> dispose() async => _local.dispose();

  Future<void> _evictIfNeeded() async {
    var total = await _meta.totalBytes();
    if (total <= maxBytes) return;
    final entries = await _meta.entries();
    entries.sort((a, b) => a.lastAccessAt.compareTo(b.lastAccessAt));

    // 1. 先清孤儿（无引用）。
    for (final e in entries) {
      if (total <= maxBytes) break;
      if (e.refCount > 0) continue;
      await _drop(e);
      total -= e.byteSize;
    }
    // 2. 仍超限 → 按最旧访问淘汰（可重新下载）。
    for (final e in entries) {
      if (total <= maxBytes) break;
      if (e.refCount <= 0) continue;
      await _drop(e);
      total -= e.byteSize;
    }
  }

  Future<void> _drop(BlobCacheEntry e) async {
    await _local.delete(e.sha256);
    await _meta.remove(e.sha256);
  }
}
