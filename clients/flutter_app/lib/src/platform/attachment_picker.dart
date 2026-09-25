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

/// 打开系统文件选择器（可多选）。用户取消时返回空列表。
Future<List<PickedAttachment>> pickAttachments() async {
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