import 'dart:typed_data';

import 'blob_store.dart';

/// Web 端 BlobStore：进程内内存实现。
///
/// Web 端没有文件系统，且 BlobStore 在方案 B 中本就是**缓存**语义（正本在
/// 服务端，按需拉取）。因此这里用内存表承载本次会话的缓存，页面刷新后
/// 重新按需下载即可，不构成数据丢失。
///
/// [rootDir] 在 Web 无意义，保留参数只为与原生实现签名一致。
class LocalBlobStore implements BlobStore {
  final String rootDir;

  LocalBlobStore(this.rootDir);

  final Map<String, Uint8List> _bytes = {};

  @override
  Future<String> put({required String sha256, required Uint8List bytes}) async {
    _bytes[sha256] = bytes;
    return sha256;
  }

  @override
  Future<Uint8List?> read(String sha256) async => _bytes[sha256];

  @override
  Future<bool> exists(String sha256) async => _bytes.containsKey(sha256);

  @override
  Future<void> delete(String sha256) async {
    _bytes.remove(sha256);
  }

  @override
  Future<void> dispose() async {
    _bytes.clear();
  }
}