import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// 内存 BlobStore：只保存一份字节，供 [SyncClient.uploadBlob] 读取。
class _FakeBlobStore implements BlobStore {
  _FakeBlobStore(this.bytes);
  Uint8List bytes;

  @override
  Future<String> put({required String sha256, required Uint8List bytes}) async {
    this.bytes = bytes;
    return sha256;
  }

  @override
  Future<Uint8List?> read(String sha256) async => bytes;

  @override
  Future<bool> exists(String sha256) async => true;

  @override
  Future<void> delete(String sha256) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  const hash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  late AppDatabase db;
  late SyncClient client;

  SyncClient buildClient(
    Uint8List payload,
    MockClient httpClient,
  ) {
    db = AppDatabase.memory();
    addTearDown(db.close);
    return SyncClient(
      repository: NoteRepository(db, deviceId: 't'),
      baseUrl: 'http://example.test',
      deviceId: 't',
      token: 'tok',
      blobStore: _FakeBlobStore(payload),
      httpClient: httpClient,
    );
  }

  test('≤16 MiB 仍走整包 PUT', () async {
    final payload = Uint8List(1 << 20);
    var initCalls = 0;
    var wholePuts = 0;
    client = buildClient(
      payload,
      MockClient((req) async {
        if (req.url.path.endsWith('/upload')) initCalls++;
        if (req.method == 'PUT' && req.url.path.endsWith('/blobs/$hash')) {
          wholePuts++;
          expect(req.bodyBytes.length, payload.length);
        }
        return http.Response('{"ok":true}', 200);
      }),
    );
    expect(await client.uploadBlob(hash), isTrue);
    expect(initCalls, 0);
    expect(wholePuts, 1);
  });

  test('>16 MiB 按 8 MiB 分片并 complete', () async {
    final payload = Uint8List(20 << 20);
    final parts = <int, int>{};
    var complete = 0;
    client = buildClient(
      payload,
      MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'POST' && path.endsWith('/upload')) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'size': payload.length,
              'chunkSize': 8 << 20,
              'uploaded': <int>[],
              'complete': false,
            }),
            200,
          );
        }
        if (req.method == 'PUT' && path.contains('/upload/')) {
          final idx = int.parse(path.split('/').last);
          parts[idx] = req.bodyBytes.length;
          return http.Response('{"ok":true}', 200);
        }
        if (req.method == 'POST' && path.endsWith('/complete')) {
          complete++;
          return http.Response('{"ok":true,"size":${payload.length}}', 200);
        }
        fail('unexpected ${req.method} ${req.url}');
      }),
    );
    expect(await client.uploadBlob(hash), isTrue);
    expect(parts.keys.toList()..sort(), [0, 1, 2]);
    expect(parts[0], 8 << 20);
    expect(parts[1], 8 << 20);
    expect(parts[2], 4 << 20);
    expect(complete, 1);
  });

  test('续传：init 返回 [0,2] 时只补第 1 片', () async {
    final payload = Uint8List(20 << 20);
    final sent = <int>[];
    client = buildClient(
      payload,
      MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'POST' && path.endsWith('/upload')) {
          return http.Response(
            jsonEncode({
              'ok': true,
              'size': payload.length,
              'chunkSize': 8 << 20,
              'uploaded': [0, 2],
              'complete': false,
            }),
            200,
          );
        }
        if (req.method == 'PUT' && path.contains('/upload/')) {
          sent.add(int.parse(path.split('/').last));
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"ok":true}', 200);
      }),
    );
    expect(await client.uploadBlob(hash), isTrue);
    expect(sent, [1]);
  });

  test('旧服务端（init 404）回退整包 PUT', () async {
    final payload = Uint8List(20 << 20);
    var wholePuts = 0;
    client = buildClient(
      payload,
      MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'POST' && path.endsWith('/upload')) {
          return http.Response('{"ok":false,"error":"not found"}', 404);
        }
        if (req.method == 'PUT' && path.endsWith('/blobs/$hash')) {
          wholePuts++;
          expect(req.bodyBytes.length, payload.length);
          return http.Response('{"ok":true}', 200);
        }
        fail('unexpected ${req.method} ${req.url}');
      }),
    );
    expect(await client.uploadBlob(hash), isTrue);
    expect(wholePuts, 1);
  });
}
