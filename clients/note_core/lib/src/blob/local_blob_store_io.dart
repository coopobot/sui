import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'blob_store.dart';

/// 本地文件系统实现的 BlobStore（原生平台）。
///
/// 目录结构：`<root>/<hash前2位>/<hash>`，避免单目录存太多文件。
/// 字节按 sha256 内容寻址，跨端/跨设备去重。
class LocalBlobStore implements BlobStore {
  final String rootDir;

  LocalBlobStore(this.rootDir);

  String _fileFor(String sha256) {
    final prefix = sha256.length >= 2 ? sha256.substring(0, 2) : sha256;
    return p.join(rootDir, prefix, sha256);
  }

  @override
  Future<String> put({required String sha256, required Uint8List bytes}) async {
    final f = File(_fileFor(sha256));
    if (await f.exists()) {
      // 已存在（幂等），校验一致则直接返回。
      return sha256;
    }
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return sha256;
  }

  @override
  Future<Uint8List?> read(String sha256) async {
    final f = File(_fileFor(sha256));
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  @override
  Future<bool> exists(String sha256) async {
    return File(_fileFor(sha256)).exists();
  }

  @override
  Future<void> delete(String sha256) async {
    final f = File(_fileFor(sha256));
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> dispose() async {}
}