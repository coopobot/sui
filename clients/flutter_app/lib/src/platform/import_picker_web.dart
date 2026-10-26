import 'package:file_picker/file_picker.dart';
import 'package:note_core/note_core.dart';

/// Web 端**不支持**「选择文件夹」（浏览器沙箱没有目录路径）→ 界面不渲染该入口
/// （FR-60 / AC-234）。
const bool importFolderPickSupported = false;

/// Web：多选文件（`withData: true` 直接拿字节）。
///
/// **没有**相对资源解析：`resolveResource` 恒为 null → HTML 里的 `.resources` /
/// `<stem> files/` 等相对引用一律走「未本地化资源」降级（BR-60.9 / AC-248）。
Future<List<ImportSourceFile>> pickImportFiles() async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    withData: true,
    type: FileType.custom,
    allowedExtensions: kImportSupportedExtensions,
    dialogTitle: '选择要导入的文件',
  );
  if (result == null) return const [];
  return [
    for (final f in result.files)
      if (f.bytes != null) ImportSourceFile(name: f.name, bytes: f.bytes!),
  ];
}

/// Web 端不支持文件夹导入（UI 已隐藏入口，这里再兜一层）。
Future<List<ImportSourceFile>> pickImportFolder() async => const [];
