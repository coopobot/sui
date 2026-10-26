import 'dart:io';
import 'dart:typed_data';

/// 把 [bytes] 写成**系统临时目录**下的同名临时文件，再交给系统壳层用默认应用打开。
///
/// 返回临时文件绝对路径（回写时据此重读，BR-47.3）；若当前平台无可用壳层
/// （Android / iOS 无 POSIX shell，零依赖下无法唤起系统应用）则清理临时文件后返回
/// `null`，由调用方降级为**内置预览**。
///
/// 临时文件刻意落在系统临时目录：不进仓库、不写 blob 根，交给系统自动回收
/// （§12.2）。
Future<String?> openExternally({
  required String filename,
  required Uint8List bytes,
}) async {
  Directory? dir;
  try {
    dir = await Directory.systemTemp.createTemp('sui_att_');
    final file = File('${dir.path}${Platform.pathSeparator}${_safeName(filename)}');
    await file.writeAsBytes(bytes, flush: true);
    final launched = await _launch(file.path);
    if (launched) return file.path;
  } catch (_) {
    // 落盘 / 唤起失败：走降级路径（下方统一清理）。
  }
  if (dir != null) {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
  return null;
}

/// 读回外部编辑器保存后的临时文件字节（文件已被删除 / 不可读时返回 null）。
Future<Uint8List?> readExternalFile(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    return await f.readAsBytes();
  } catch (_) {
    return null;
  }
}

/// 清理临时文件及其所在目录（尽力而为，失败不抛出）。
Future<void> cleanupExternalFile(String path) async {
  try {
    final f = File(path);
    final dir = f.parent;
    if (await f.exists()) await f.delete();
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {}
}

/// 去掉文件名里的路径成分，避免 `..` / 分隔符逃逸临时目录。
String _safeName(String name) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  return base.isEmpty ? 'attachment' : base;
}

/// 桌面三平台的系统壳层唤起；不支持时返回 false。
Future<bool> _launch(String path) async {
  try {
    if (Platform.isWindows) {
      // `start` 是 cmd 内建命令：首参固定为窗口标题（空串占位），随后才是目标路径。
      await Process.start('cmd', ['/c', 'start', '', path]);
      return true;
    }
    if (Platform.isMacOS) {
      return (await Process.run('open', [path])).exitCode == 0;
    }
    if (Platform.isLinux) {
      return (await Process.run('xdg-open', [path])).exitCode == 0;
    }
  } catch (_) {
    return false;
  }
  return false;
}
