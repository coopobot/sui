/// Web 端没有文件系统路径，持久化由浏览器存储（OPFS / IndexedDB）负责。
Future<String?> resolveDataDir() async => null;