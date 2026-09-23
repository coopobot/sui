import 'dart:typed_data';

/// Blob 存储抽象。附件字节不随笔记同步走，按 [sha256] 内容寻址，按需读写。
///
/// 多端实现：
///  - 桌面/移动：本地文件系统（[LocalBlobStore]）
///  - Web：浏览器沙箱存储（IndexedDB/Cache API），后续补充
///  - 服务端：本地磁盘 / S3（见服务端 BlobStore）
abstract interface class BlobStore {
  /// 写入字节，返回内容地址（sha256）。重复写入同一内容幂等（返回同一 hash）。
  Future<String> put({required String sha256, required Uint8List bytes});

  /// 按内容地址读取字节；不存在返回 null。
  Future<Uint8List?> read(String sha256);

  /// 判断某地址是否已存在（上传去重用）。
  Future<bool> exists(String sha256);

  /// 删除某地址。引用计数（refcount）由上层仓储管理，这里只删物理字节。
  Future<void> delete(String sha256);

  /// 关闭并释放资源。
  Future<void> dispose();
}