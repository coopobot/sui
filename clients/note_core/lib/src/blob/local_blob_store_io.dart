import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../util/hashes.dart';
import 'blob_store.dart';

/// 本地文件系统实现的 BlobStore（原生平台）。
///
/// 目录结构：`<root>/<hash前2位>/<hash>`，避免单目录存太多文件。
/// 字节按 sha256 内容寻址，跨端/跨设备去重。
///
/// M10-T30：摘要是**外部输入**（服务端下发的 `storageRef`、正文 `sui://` 引用），
/// 因此拼路径前先过白名单，并断言结果仍在 [rootDir] 之内。语义上分两侧：
///
///   - **写入（[put]）严格拒绝**非法摘要——那是调用方的编程错误；
///   - **读取 / 存在性 / 删除按「不存在」处理**——非法摘要在本存储里**永不可能存在**
///     （写入已被拒），返回「无」既真实、又不会让维护性扫描（LRU 淘汰、待上传盘点）
///     或 UI 读取因一行脏数据整体失败。
class LocalBlobStore implements BlobStore {
  final String rootDir;

  LocalBlobStore(this.rootDir);

  String _fileFor(String sha256) {
    if (!isValidSha256(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', '不是合法的内容寻址摘要');
    }
    final file = p.join(rootDir, sha256.substring(0, 2), sha256);
    if (!_insideRoot(file)) {
      throw ArgumentError.value(sha256, 'sha256', '解析出的路径越出 Blob 根目录');
    }
    return file;
  }

  /// 断言 [candidate] 仍位于 [rootDir] 之内（归一到绝对路径后比较）。
  bool _insideRoot(String candidate) {
    final root = p.absolute(rootDir);
    final full = p.absolute(candidate);
    return full == root || p.isWithin(root, full);
  }

  @override
  Future<String> put({required String sha256, required Uint8List bytes}) async {
    if (!isValidSha256(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', '不是合法的内容寻址摘要');
    }
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
    if (!isValidSha256(sha256)) return null;
    final f = File(_fileFor(sha256));
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  @override
  Future<bool> exists(String sha256) async {
    if (!isValidSha256(sha256)) return false;
    return File(_fileFor(sha256)).exists();
  }

  @override
  Future<void> delete(String sha256) async {
    if (!isValidSha256(sha256)) return; // 不存在可删之物
    final f = File(_fileFor(sha256));
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> dispose() async {}
}
