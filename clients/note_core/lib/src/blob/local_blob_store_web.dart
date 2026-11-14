import 'dart:typed_data';

import '../util/hashes.dart';
import 'blob_store.dart';

/// Web 端 BlobStore：进程内内存实现。
///
/// Web 端没有文件系统，且 BlobStore 在方案 B 中本就是**缓存**语义（正本在
/// 服务端，按需拉取）。因此这里用内存表承载本次会话的缓存，页面刷新后
/// 重新按需下载即可，不构成数据丢失。
///
/// [rootDir] 在 Web 无意义，保留参数只为与原生实现签名一致。
///
/// M10-T30：与原生实现**同语义**——写入拒绝非法摘要；读取 / 存在性 / 删除按「不存在」
/// 处理（各端行为一致，避免「只有某端才校验」）。
class LocalBlobStore implements BlobStore, RangeReadableBlobStore {
  final String rootDir;

  LocalBlobStore(this.rootDir);

  final Map<String, Uint8List> _bytes = {};

  @override
  Future<String> put({required String sha256, required Uint8List bytes}) async {
    if (!isValidSha256(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', '不是合法的内容寻址摘要');
    }
    _bytes[sha256] = bytes;
    return sha256;
  }

  @override
  Future<Uint8List?> read(String sha256) async =>
      isValidSha256(sha256) ? _bytes[sha256] : null;

  @override
  Future<bool> exists(String sha256) async =>
      isValidSha256(sha256) && _bytes.containsKey(sha256);

  @override
  Future<int?> byteLength(String sha256) async {
    if (!isValidSha256(sha256)) return null;
    return _bytes[sha256]?.length;
  }

  /// Web 端数据本就在内存：区间读取只是列表切片（无法避免整文件已驻留）。
  @override
  Future<Uint8List?> readRange(String sha256, int start, int length) async {
    if (!isValidSha256(sha256) || start < 0 || length <= 0) return null;
    final bytes = _bytes[sha256];
    if (bytes == null || start >= bytes.length) return null;
    final end =
        (start + length <= bytes.length) ? start + length : bytes.length;
    return Uint8List.sublistView(bytes, start, end);
  }

  @override
  Future<void> delete(String sha256) async {
    if (!isValidSha256(sha256)) return;
    _bytes.remove(sha256);
  }

  @override
  Future<void> dispose() async {
    _bytes.clear();
  }
}
