import 'dart:io';
import 'dart:typed_data';

import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _Meta implements BlobCacheMeta {
  final Map<String, BlobCacheEntry> _m = {};

  @override
  Future<BlobCacheEntry?> entry(String sha256) async => _m[sha256];

  @override
  Future<void> upsert({
    required String sha256,
    required int byteSize,
    int refCountDelta = 0,
    DateTime? lastAccessAt,
    DateTime? uploadedAt,
  }) async {
    _m[sha256] = BlobCacheEntry(
      sha256: sha256,
      byteSize: byteSize,
      lastAccessAt: lastAccessAt ?? DateTime.now(),
      refCount: refCountDelta,
      uploadedAt: uploadedAt,
    );
  }

  @override
  Future<void> touch(String sha256, DateTime at) async {}

  @override
  Future<void> markUploaded(String sha256, DateTime at) async {}

  @override
  Future<List<BlobCacheEntry>> entries() async => _m.values.toList();

  @override
  Future<int> totalBytes() async =>
      _m.values.fold<int>(0, (a, e) => a + e.byteSize);

  @override
  Future<void> remove(String sha256) async => _m.remove(sha256);
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sui-stream-');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('putFromFile 流式入库：hash / 大小 / 区间读一致', () async {
    final src = File(p.join(dir.path, 'big.bin'));
    final bytes = Uint8List.fromList(
      List<int>.generate(2 << 20, (i) => i % 251),
    );
    await src.writeAsBytes(bytes);

    final store = LocalBlobStore(p.join(dir.path, 'blobs'));
    final hash = await store.putFromFile(src.path);

    expect(hash, hasLength(64));
    expect(await store.byteLength(hash), bytes.length);
    final range = await store.readRange(hash, 1 << 20, 1 << 20);
    expect(range, isNotNull);
    expect(range, equals(bytes.sublist(1 << 20, 2 << 20)));
  });

  test('CachedBlobStore 委托 putFromFile / readRange', () async {
    final src = File(p.join(dir.path, 'big.bin'));
    final bytes = Uint8List.fromList(List<int>.filled(1 << 20, 7));
    await src.writeAsBytes(bytes);

    final local = LocalBlobStore(p.join(dir.path, 'blobs'));
    final cache =
        CachedBlobStore(local: local, meta: _Meta(), maxBytes: 8 << 20);
    final hash = await cache.putFromFile(src.path);

    expect(await cache.byteLength(hash), bytes.length);
    expect(
        await cache.readRange(hash, 0, 1024), equals(bytes.sublist(0, 1024)));
  });
}
