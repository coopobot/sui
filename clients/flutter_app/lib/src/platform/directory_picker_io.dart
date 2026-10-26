import 'package:file_picker/file_picker.dart';

/// 打开系统目录选择器；用户取消返回 null。
///
/// M12 修订 / FR-58：「更改存储位置」用（桌面端）。
Future<String?> pickDirectoryDialog({String? dialogTitle}) {
  return FilePicker.platform.getDirectoryPath(
    dialogTitle: dialogTitle ?? '选择文件夹',
  );
}
