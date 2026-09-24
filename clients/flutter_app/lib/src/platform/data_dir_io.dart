import 'package:path_provider/path_provider.dart';

/// 原生平台数据目录：应用支持目录下的 `sui` 子目录。
///
/// 用「应用支持目录」而非「文档目录」：数据库属于应用内部状态，不应
/// 暴露在用户可见的文件列表里，也避免被 iCloud/云盘同步误处理。
Future<String?> resolveDataDir() async {
  final base = await getApplicationSupportDirectory();
  return '${base.path}/sui';
}