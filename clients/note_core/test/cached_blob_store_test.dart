import 'dart:io';
import 'dart:typed_data';

import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 内存版缓存记账（测试用，行为与 SQLite 版一致）。
class MemoryBlobCacheMeta implements BlobCacheMeta {
  final Map<String, BlobCacheEntry> _map = {};

  @override
  Future<BlobCacheEntry?> entry(String sha256) async => _map[sha256];

  @override
  Future<void> upsert({
    required String sha256,
    required int byteSize,
    int refCountDelta = 0,
    DateTime? lastAccessAt,
  }) async {
    final at = lastAccessAt ?? DateTime.now();
    final existing = _map[sha256];
    if (existing == null) {
      _map[sha256] = BlobCacheEntry(
        sha256: sha256,
        byteSize: byteSize,
        lastAccessAt: at,
        refCount: refCountDelta,
      );
      return;
    }
    _map[sha256] = BlobCacheEntry(
      sha256: sha256,
      byteSize: byteSize > 0 ? byteSize : existing.byteSize,
      lastAccessAt: at,
      refCount: existing.refCount + refCountDelta,
    );
  }

  @override
  Future<void> touch(String sha256, DateTime at) async {
    final e = _map[sha256];
    if (e == null) return;
    _map[sha256] = BlobCacheEntry(
      sha256: e.sha256,
      byteSize: e.byteSize,
      lastAccessAt: at,
      refCount: e.refCount,
    );
  }

  @override
  Future<List<BlobCacheEntry>> entries() async => _map.values.toList();

  @override
  Future<int> totalBytes() async =>
      _map.values.fold<int>(0, (sum, e) => sum + e.byteSize);

  @override
  Future<void> remove(String sha256) async => _map.remove(sha256);
}

void main() {
  late Directory tmpDir;
  late LocalBlobStore local;
  late MemoryBlobCacheMeta meta;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('sui-blob-test');
    local = LocalBlobStore(p.join(tmpDir.path, 'blobs'));
    meta = MemoryBlobCacheMeta();
  });

  tearDown(() async {
    await local.dispose();
    tmpDir.deleteSync(recursive: true);
  });

  String hashOf(String content) {
    // 测试用假 hash（真实场景为 sha256；这里只要稳定且唯一）。
    return content.hashCode.toRadixString(16).padLeft(8, '0');
  }

  test('put 后 read 返回相同字节（幂等）', () async {
    final store = CachedBlobStore(local: local, meta: meta, maxBytes: 1024);
    final bytes = Uint8List.fromList('hello'.codeUnits);
    final h = hashOf('hello');

    final h1 = await store.put(sha256: h, bytes: bytes);
    final h2 = await store.put(sha256: h, bytes: bytes);
    expect(h1, h);
    expect(h2, h);

    final read = await store.read(h);
    expect(read, bytes);
    expect(await store.exists(h), isTrue);
  });

  test('read 未命中时经 fetcher 按需下载并缓存', () async {
    var fetchCalls = 0;
    final store = CachedBlobStore(
      local: local,
      meta: meta,
      maxBytes: 1024,
      fetcher: (h) async {
        fetchCalls++;
        return Uint8List.fromList('downloaded-$h'.codeUnits);
      },
    );
    const h = 'abc12345';

    final first = await store.read(h);
    expect(first, isNotNull);
    expect(fetchCalls, 1);

    // 二次读命中缓存，不再触发下载。
    final second = await store.read(h);
    expect(second, first);
    expect(fetchCalls, 1);
  });

  test('无 fetcher 时未命中返回 null', () async {
    final store = CachedBlobStore(local: local, meta: meta, maxBytes: 1024);
    expect(await store.read('nohash00'), isNull);
  });

  test('容量超限按 LRU 淘汰最旧（含引用）', () async {
    final store = CachedBlobStore(local: local, meta: meta, maxBytes: 100);
    // 每个 40 字节 × 3 = 120 > 100，写入第三个时触发淘汰。
    final b1 = Uint8List.fromList(List.filled(40, 1));
    final b2 = Uint8List.fromList(List.filled(40, 2));
    final b3 = Uint8List.fromList(List.filled(40, 3));

    await store.put(sha256: 'h1', bytes: b1);
    await store.put(sha256: 'h2', bytes: b2);
    await store.put(sha256: 'h3', bytes: b3);

    // 最旧的 h1 被淘汰：物理字节删除 + 记账清除。
    expect(await store.exists('h1'), isFalse);
    expect(await store.read('h1'), isNull);
    expect(await store.exists('h2'), isTrue);
    expect(await store.exists('h3'), isTrue);
    expect(await store.cachedBytes, lessThanOrEqualTo(100));
  });

  test('孤儿（refCount=0）优先淘汰', () async {
    final store = CachedBlobStore(local: local, meta: meta, maxBytes: 100);
    final b1 = Uint8List.fromList(List.filled(40, 1));
    final b2 = Uint8List.fromList(List.filled(40, 2));

    // h1 保留引用；h2 引用归零成为孤儿。
    await store.put(sha256: 'h1', bytes: b1);
    await store.put(sha256: 'h2', bytes: b2);
    await store.updateRef('h2', -1);
    // 让孤儿 h2 反而更新（验证淘汰不看新旧，看引用状态）。
    await meta.touch('h2', DateTime.now().add(const Duration(seconds: 5)));

    // 再写一个 40 字节触发淘汰：应优先淘汰孤儿 h2。
    await store.put(
        sha256: 'h3', bytes: Uint8List.fromList(List.filled(40, 3)));

    expect(await store.exists('h2'), isFalse, reason: '孤儿应优先被淘汰');
    expect(await store.exists('h1'), isTrue, reason: '有引用的保留');
    expect(await store.exists('h3'), isTrue);
  });

  test('updateRef 增减引用计数；归零后可被孤儿清理', () async {
    final store = CachedBlobStore(local: local, meta: meta, maxBytes: 1024);
    final bytes = Uint8List.fromList('x'.codeUnits);

    await store.put(sha256: 'h1', bytes: bytes);
    await store.updateRef('h1', -1); // 引用归零

    await store.sweepOrphans();
    expect(await store.exists('h1'), isFalse);
  });

  test('delete 同时清除物理字节与记账', () async {
    final store = CachedBlobStore(local: local, meta: meta, maxBytes: 1024);
    await store.put(
        sha256: 'h1', bytes: Uint8List.fromList('data'.codeUnits));

    expect(await store.exists('h1'), isTrue);
    await store.delete('h1');
    expect(await store.exists('h1'), isFalse);
    expect(await meta.entry('h1'), isNull);
  });
}
