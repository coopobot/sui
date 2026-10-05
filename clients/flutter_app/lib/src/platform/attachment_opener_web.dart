import 'dart:typed_data';

/// Web 端无系统壳层（浏览器不暴露「用默认应用打开本地文件」的能力），
/// 返回 `null` 让调用方降级为**内置预览**（BR-47.5）。
///
/// 注意：这里刻意不引入 `package:web` / `dart:html` 触发浏览器下载——`web` 目前
/// 只是传递依赖，直接引用会触发 `depend_on_referenced_packages`，而依赖增删须先经
/// 批准（Agents.md §6 第 4 条）。故 Web 降级口径落在「内置预览 + 提示」。
Future<String?> openExternally({
  required String filename,
  required Uint8List bytes,
}) async =>
    null;

/// Web 端无临时文件，恒返回 null。
Future<Uint8List?> readExternalFile(String path) async => null;

/// Web 端无临时文件，空实现。
Future<void> cleanupExternalFile(String path) async {}
