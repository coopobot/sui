import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// M10-T30：内容寻址摘要白名单的门禁（FR-52 / BR-52.1，客户端侧同源缺陷）。
///
/// 摘要是**外部输入**（服务端下发的映射与正文 `sui://` 引用），若直接拼进文件路径或 URL，
/// 就能用 `../../` 这类取值越出 Blob 根目录 / 打到任意接口路径。
///
/// 语义约定（见 `local_blob_store_io.dart` 注释）：
///   - **写入严格拒绝**：非法摘要是调用方编程错误；
///   - **读取 / 存在性 / 删除按「不存在」处理**：非法摘要永不可能存在，返回「无」既真实，
///     又不会让 LRU 淘汰、待上传盘点或 UI 读取因一行脏数据整体失败。
void main() {
  final validHash = 'a' * 64;

  group('isValidSha256', () {
    test('只接受定长 64 位小写十六进制', () {
      expect(isValidSha256(validHash), isTrue);
      expect(isValidSha256('0123456789abcdef' * 4), isTrue);
      for (final bad in <String>[
        '',
        'abc',
        'A' * 64, // 大写
        'a' * 63,
        'a' * 65,
        'z' * 64, // 非 hex
        r'../../pwned',
        r'..%2f..%2fpwned',
        'a' * 32,
      ]) {
        expect(isValidSha256(bad), isFalse, reason: bad);
      }
    });
  });

  group('LocalBlobStore 摘要白名单', () {
    late Directory tmp;
    late LocalBlobStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sui_blob_guard_');
      store = LocalBlobStore(p.join(tmp.path, 'blobs'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('写入非法摘要被拒且不落盘', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      for (final bad in <String>[
        '',
        'abc',
        'A' * 64,
        'a' * 63,
        'z' * 64,
        r'../../pwned',
        r'..%2f..%2fpwned',
      ]) {
        expect(() => store.put(sha256: bad, bytes: bytes), throwsArgumentError,
            reason: 'put($bad)');
      }
      // 越界文件不应出现，且不该产生任何目录副作用
      expect(File(p.join(tmp.path, 'pwned')).existsSync(), isFalse);
      expect(Directory(p.join(tmp.path, 'blobs')).existsSync(), isFalse,
          reason: '非法取值不应产生任何目录/文件副作用');
    });

    test('读取 / 存在性 / 删除按「不存在」处理（不抛异常打断维护路径）', () async {
      for (final bad in <String>['abc', 'A' * 64, r'../../pwned']) {
        expect(await store.read(bad), isNull, reason: 'read($bad)');
        expect(await store.exists(bad), isFalse, reason: 'exists($bad)');
        await store.delete(bad); // 不应抛
      }
    });

    test('合法摘要正常读写（不回归）', () async {
      final bytes = Uint8List.fromList([7, 8, 9]);
      await store.put(sha256: validHash, bytes: bytes);
      expect(await store.exists(validHash), isTrue);
      expect(await store.read(validHash), bytes);
      expect(
        File(p.join(tmp.path, 'blobs', validHash.substring(0, 2), validHash))
            .existsSync(),
        isTrue,
        reason: '分片目录结构不变',
      );
    });
  });

  group('SyncClient 摘要白名单', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.memory());
    tearDown(() => db.close());

    test('非法摘要不触网：上传返回 false、下载抛 ArgumentError', () async {
      var calls = 0;
      final tmp = Directory.systemTemp.createTempSync('sui_blob_net_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final syncer = SyncClient(
        repository: NoteRepository(db, deviceId: 'd'),
        baseUrl: 'http://test',
        deviceId: 'd',
        token: 'tok',
        refreshToken: 'ref',
        blobStore: LocalBlobStore(p.join(tmp.path, 'blobs')),
        httpClient: MockClient((req) async {
          calls++;
          return Response('{}', 200);
        }),
      );

      expect(await syncer.uploadBlob(r'../../etc/passwd'), isFalse);
      await expectLater(syncer.ensureBlob('not-a-hash'), throwsArgumentError);
      expect(calls, 0, reason: '非法摘要不得发起任何 HTTP 请求');
      syncer.close();
    });
  });
}
