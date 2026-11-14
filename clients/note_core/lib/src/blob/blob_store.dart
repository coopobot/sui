import 'dart:typed_data';

/// Blob 存储抽象。附件字节不随笔记同步走，按 [sha256] 内容寻址，按需读写。
///
/// 多端实现：
///  - 桌面/移动：本地文件系统（[LocalBlobStore]）
///  - Web：浏览器沙箱存储（IndexedDB/Cache API），后续补充
///  - 服务端：本地磁盘 / S3（见服务端 BlobStore）
/// 可选能力：按字节区间读取（大附件上传时**不把整文件读入内存**）。
///
/// 原生端（桌面 / Android / iOS）由文件系统实现；Web 的内存实现不需要实现本接口，
/// 上传时会退化为整文件读取（已知限制）。
/// 可选能力：从**本地文件路径**流式入库（不把整文件读入内存）。
///
/// 原生端（桌面 / Android / iOS）由文件系统实现：先流式计算 sha256，再复制文件；
/// Web 无文件路径，不实现。
abstract interface class FilePathBlobStore {
  /// 计算文件 sha256 并复制到内容寻址存储，返回 hash。
  Future<String> putFromFile(String path);
}

abstract interface class RangeReadableBlobStore {
  /// 返回字节总长度；不存在 / 非法摘要返回 null。
  Future<int?> byteLength(String sha256);

  /// 读取 `[start, start+length)`；不存在 / 区间非法返回 null。
  Future<Uint8List?> readRange(String sha256, int start, int length);
}

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
