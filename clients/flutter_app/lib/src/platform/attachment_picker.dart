import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// 一次「选择文件」的结果：文件名 + 字节。
///
/// 统一带字节（`withData: true`）：note_core 是纯 Dart 包、不能碰 `dart:io`，
/// 所以文件读取放在平台层完成，Web / 桌面 / 移动拿到的东西完全一致。
class PickedAttachment {
  const PickedAttachment({required this.filename, required this.bytes});

  final String filename;
  final Uint8List bytes;
}

/// **测试接缝**（生产代码从不写入；与 `platform_seams.dart` 同一范式）：
/// 非 null 时 [pickAttachments] 直接委托给它，用于在 widget 测试里模拟「选文件」。
///
/// 返回一个**未完成的 `Future`** 即可把「选文件」阶段挂起，从而稳定复现
/// 「批次进行中再次点添加附件」这类并发场景（`v0.16.3` / FR-91）。
Future<List<PickedAttachment>> Function()? debugAttachmentPickerOverride;

/// 打开系统文件选择器（可多选）。用户取消时返回空列表。
Future<List<PickedAttachment>> pickAttachments() async {
  final override = debugAttachmentPickerOverride;
  if (override != null) return override();
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    withData: true,
    dialogTitle: '选择附件',
  );
  if (result == null) return const [];
  return [
    for (final f in result.files)
      // withData 在部分平台可能拿不到字节（超大文件等），这类项直接跳过。
      if (f.bytes != null)
        PickedAttachment(filename: f.name, bytes: f.bytes!),
  ];
}