import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'attachment_save.dart';
import 'platform_seams.dart';

/// 把附件字节保存到用户本机（FR-117 / ADR-042）。
///
/// 分派：
/// * **桌面三平台** —— `FilePicker.saveFile` 弹出系统另存框并**只返回路径**，
///   随后由本函数用 `dart:io` 写盘（`file_picker` 在桌面上忽略 `bytes`，
///   照搬 Android 用法会「提示成功但文件为空」，见 ADR-042 决策 1）。
/// * **Android / iOS** —— `FilePicker.saveFile(bytes: …)` 走系统「创建文档」，
///   插件在 `onActivityResult` 里写入用户选定的 URI；本函数**不再写一次**。
///   Android 返回的是插件拼出的 `Downloads/<名>`，可能与实际所选位置不符，
///   故不放进 `location`（BR-117.7 的提示只说「所选位置」）。
/// * 其它平台 —— `unsupported`。
///
/// 取消返回 `cancelled`（UI 不提示）；写盘 / 插件异常返回 `failed`，均不抛出
/// （BR-117.6 / BR-117.7）。
Future<AttachmentSaveResult> saveAttachmentToDevice({
  required String filename,
  required Uint8List bytes,
}) async {
  final override = debugAttachmentSaveOverride;
  if (override != null) return override(filename: filename, bytes: bytes);

  final name = sanitizeAttachmentFilename(filename);
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存附件',
        fileName: name,
        bytes: bytes,
      );
      if (path == null) {
        return const AttachmentSaveResult(AttachmentSaveOutcome.cancelled);
      }
      return const AttachmentSaveResult(AttachmentSaveOutcome.saved);
    }

    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return const AttachmentSaveResult(AttachmentSaveOutcome.unsupported);
    }

    // 默认打开「下载」目录；拿不到就交给系统默认目录（各平台实现不同）。
    String? initialDirectory;
    try {
      initialDirectory = (await getDownloadsDirectory())?.path;
    } catch (_) {}

    final dialogOverride = debugSavePathOverride;
    final path = dialogOverride != null
        ? await dialogOverride(filename: name)
        : await FilePicker.platform.saveFile(
            dialogTitle: '保存附件',
            fileName: name,
            initialDirectory: initialDirectory,
            lockParentWindow: true,
          );
    if (path == null) {
      return const AttachmentSaveResult(AttachmentSaveOutcome.cancelled);
    }

    await File(path).writeAsBytes(bytes, flush: true);
    return AttachmentSaveResult(AttachmentSaveOutcome.saved, location: path);
  } catch (_) {
    return const AttachmentSaveResult(AttachmentSaveOutcome.failed);
  }
}
