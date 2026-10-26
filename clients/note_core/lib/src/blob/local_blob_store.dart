/// LocalBlobStore 的平台条件导入。
///
/// - 原生：文件系统分片存储（`<root>/<hash前2位>/<hash>`）。
/// - Web：进程内内存缓存（浏览器无文件系统；BlobStore 本就是缓存语义）。
///
/// 分层目的：让 Web 构建不引入 `dart:io`。
library;

export 'local_blob_store_io.dart'
    if (dart.library.js_interop) 'local_blob_store_web.dart';