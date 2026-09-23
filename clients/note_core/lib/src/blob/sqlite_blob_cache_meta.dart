import 'package:drift/drift.dart';

import '../db/app_database.dart';
import 'cached_blob_store.dart';

/// 基于 SQLite（drift）的附件缓存记账实现。
///
/// 表：`blob_refs`（sha256 / byteSize / lastAccessAt / refCount）。
class SqliteBlobCacheMeta implements BlobCacheMeta {
  final AppDatabase db;

  SqliteBlobCacheMeta(this.db);

  @override
  Future<BlobCacheEntry?> entry(String sha256) async {
    final row = await (db.select(db.blobRefs)..where((t) => t.sha256.equals(sha256)))
        .getSingleOrNull();
    if (row == null) return null;
    return BlobCacheEntry(
      sha256: row.sha256,
      byteSize: row.byteSize,
      lastAccessAt: row.lastAccessAt,
      refCount: row.refCount,
    );
  }

  @override
  Future<void> upsert({
    required String sha256,
    required int byteSize,
    int refCountDelta = 0,
    DateTime? lastAccessAt,
  }) async {
    final at = lastAccessAt ?? DateTime.now();
    final existing = await entry(sha256);
    if (existing == null) {
      await db.into(db.blobRefs).insert(BlobRefsCompanion.insert(
            sha256: sha256,
            byteSize: Value(byteSize),
            lastAccessAt: at,
            refCount: Value(refCountDelta),
          ));
      return;
    }
    await (db.update(db.blobRefs)..where((t) => t.sha256.equals(sha256)))
        .write(BlobRefsCompanion(
      byteSize: Value(byteSize > 0 ? byteSize : existing.byteSize),
      lastAccessAt: Value(at),
      refCount: Value(existing.refCount + refCountDelta),
    ));
  }

  @override
  Future<void> touch(String sha256, DateTime at) async {
    await (db.update(db.blobRefs)..where((t) => t.sha256.equals(sha256)))
        .write(BlobRefsCompanion(lastAccessAt: Value(at)));
  }

  @override
  Future<List<BlobCacheEntry>> entries() async {
    final rows = await db.select(db.blobRefs).get();
    return rows
        .map((r) => BlobCacheEntry(
              sha256: r.sha256,
              byteSize: r.byteSize,
              lastAccessAt: r.lastAccessAt,
              refCount: r.refCount,
            ))
        .toList();
  }

  @override
  Future<int> totalBytes() async {
    final rows = await db.select(db.blobRefs).get();
    return rows.fold<int>(0, (sum, r) => sum + r.byteSize);
  }

  @override
  Future<void> remove(String sha256) async {
    await (db.delete(db.blobRefs)..where((t) => t.sha256.equals(sha256))).go();
  }
}
