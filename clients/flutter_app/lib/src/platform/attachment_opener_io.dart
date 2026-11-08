import 'dart:io';

import 'package:flutter/services.dart';
import 'package:note_core/note_core.dart' show mimeTypeFor;
import 'package:path_provider/path_provider.dart';

import 'attachment_open_result.dart';
import 'platform_seams.dart';

/// 自研平台通道（Windows / Android 原生实现的唯一入口，见 ADR-028 / ADR-040）。
const MethodChannel _channel = MethodChannel('sui/platform');

/// 原生 `openFile` 的返回码（与 `MainActivity.kt` 逐字对应）。
const String _codeOk = 'ok';
const String _codeNoHandler = 'nohandler';
const String _codeError = 'error';

/// 把 [bytes] 写成**系统临时目录**下的同名临时文件，再交给系统用默认应用打开。
///
/// 平台分派见 [shellOpenCommand]（桌面三平台）与 [_androidOpenFile]（Android）：
/// 返回 [ExternalOpenResult]，成功时带回临时文件绝对路径（回写时据此重读，
/// BR-47.3）与是否启动回写监视。
///
/// 临时文件刻意落在系统临时目录：不进仓库、不写 blob 根，交给系统自动回收
/// （§12.2）。失败 / 平台不支持时**清理**该目录，不留垃圾。
Future<ExternalOpenResult> openExternally({
  required String filename,
  required Uint8List bytes,
}) async {
  final os = debugOpenTargetOsOverride ?? Platform.operatingSystem;
  Directory? dir;
  try {
    dir = await _createTempDir(os);
    final file = File('${dir.path}${Platform.pathSeparator}${_safeName(filename)}');
    await file.writeAsBytes(bytes, flush: true);
    final result = await _launch(os, file.path, _safeName(filename));
    if (result.isOpened) return result;
    await _discard(dir);
    return result;
  } catch (_) {
    // 落盘 / 唤起失败：走降级路径（下方统一清理）。
    await _discard(dir);
    return const ExternalOpenResult(ExternalOpenOutcome.failed);
  }
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

/// 桌面三平台的壳层唤起命令（**纯函数**，可单测）。
///
/// 返回 null 表示「该平台没有可用壳层」——Android / iOS 没有 POSIX shell，
/// 桌面那套 `cmd /c start` / `open` / `xdg-open` 在那里根本不存在（ADR-040 背景表 ④）。
/// Android 走自研通道（[openExternally] 的 `_androidOpenFile` 分支），不经过这里。
List<String>? shellOpenCommand(String os, String path) {
  if (os == 'windows') {
    // `start` 是 cmd 内建命令：首参固定为窗口标题（空串占位），随后才是目标路径。
    return ['cmd', '/c', 'start', '', path];
  }
  if (os == 'macos') return ['open', path];
  if (os == 'linux') return ['xdg-open', path];
  return null;
}

/// 原生 `openFile` 返回码 → 结果三态（**纯函数**，可单测）。
///
/// 返回码缺失（通道未实现 / 旧版原生）一律视为**平台不支持**：
/// iOS 与未升级的原生侧都落到这里，提示口径与 Web 一致（AC-642）。
ExternalOpenOutcome outcomeForAndroidCode(String? code) {
  switch (code) {
    case _codeOk:
      return ExternalOpenOutcome.opened;
    case _codeNoHandler:
      return ExternalOpenOutcome.noHandler;
    case _codeError:
      return ExternalOpenOutcome.failed;
    default:
      return ExternalOpenOutcome.unsupported;
  }
}

/// 交系统唤起；不支持 / 无应用的平台返回对应结果而不是抛异常。
Future<ExternalOpenResult> _launch(String os, String path, String filename) async {
  if (os == 'android') {
    final mime = mimeTypeFor(filename);
    try {
      final code = await _androidOpenFile(path, filename, mime);
      final outcome = outcomeForAndroidCode(code);
      return ExternalOpenResult(
        outcome,
        // 只有真正交给系统时才带回路径：失败时调用方不该拿到一个已被清理的路径。
        path: outcome == ExternalOpenOutcome.opened ? path : null,
        // 只读授权 → 不回写、不空转监视（ADR-040 决策 2 / BR-110.6）。
        watchForEdits: false,
      );
    } on MissingPluginException {
      return const ExternalOpenResult.unsupported();
    } catch (_) {
      return const ExternalOpenResult(ExternalOpenOutcome.failed);
    }
  }

  final command = shellOpenCommand(os, path);
  if (command == null) return const ExternalOpenResult.unsupported();
  try {
    if (os != 'windows') {
      // macOS / Linux 能拿到退出码，可区分「已打开」与「壳层失败」。
      final run = await Process.run(command.first, command.sublist(1));
      if (run.exitCode != 0) {
        return const ExternalOpenResult(ExternalOpenOutcome.failed);
      }
    } else {
      // `start` 自身立即返回、拿不到目标应用的退出码 → 视为已交给系统
      // （与修复前口径一致，不改变桌面端行为）。
      await Process.start(command.first, command.sublist(1));
    }
    return ExternalOpenResult(
      ExternalOpenOutcome.opened,
      path: path,
      watchForEdits: true,
    );
  } catch (_) {
    return const ExternalOpenResult(ExternalOpenOutcome.failed);
  }
}

/// 交原生 `ACTION_VIEW` 发意图（Android）。
///
/// 原生侧只做「把内容 URI 交给系统」这一件事：MIME 判定、文件名清洗、临时文件落盘
/// 全在 Dart 侧，便于单测（与 ADR-028「原生只取字节 / 发意图」同一取向）。
Future<String?> _androidOpenFile(String path, String filename, String mime) async {
  final override = debugAndroidOpenFileOverride;
  if (override != null) {
    return override(path: path, filename: filename, mime: mime);
  }
  return _channel.invokeMethod<String>('openFile', {
    'path': path,
    'filename': filename,
    'mime': mime,
  });
}

/// 授权给 `FileProvider` 的**固定**子目录名（与 `res/xml/sui_file_paths.xml` 逐字一致）。
///
/// 必须是固定目录：`FileProvider` 的 `<cache-path>` 按**路径精确匹配**，
/// 而 `createTemp('sui_att_')` 会生成 `sui_att_XXXXXX`（带随机后缀）→ `getUriForFile`
/// 找不到匹配的 root 会抛 `IllegalArgumentException`（模拟器实测踩过，见 ADR-040）。
///
/// **公开**（非私有）：测试要拿它和 `res/xml/sui_file_paths.xml` 的 `path` 逐字比对——
/// 两者是同一份契约，曾经只改了一边，模拟器上表现为「点开没反应」（ADR-040 实测回填）。
const String kAndroidAttachmentScopeDir = 'sui_att';
const String _androidScopeDir = kAndroidAttachmentScopeDir;

/// 建临时目录。
///
/// Android 上明确取 `cacheDir`（path_provider）：它与清单里 `FileProvider` 的
/// `<cache-path path="sui_att">` 对齐，而 `Directory.systemTemp` 的落点取决于引擎是否
/// 注入 `TMPDIR`，不适合作为授权范围的前提（ADR-040 决策 2）。
///
/// 布局：`<cacheDir>/sui_att/att_XXXXXX/`，临时文件写在最内层——
/// 授权根只是 `sui_att` 这一棵子树，唯一性由内层随机目录提供。
Future<Directory> _createTempDir(String os) async {
  final basePath = debugOpenTempBasePathOverride;
  if (os != 'android') {
    final base = basePath != null ? Directory(basePath) : Directory.systemTemp;
    return base.createTemp('sui_att_');
  }
  final base = basePath != null ? Directory(basePath) : await getTemporaryDirectory();
  final scope = Directory('${base.path}${Platform.pathSeparator}$_androidScopeDir');
  await scope.create(recursive: true);
  return scope.createTemp('att_');
}

/// 清理临时目录（尽力而为）。
///
/// Android 的授权根 `sui_att` 是**共享**的：仅当它已空（本批临时目录都清完了）才一并删掉，
/// 免得在缓存目录里留下空壳，也避免误删别的打开动作正在用的子目录。
Future<void> _discard(Directory? dir) async {
  if (dir == null) return;
  final parent = dir.parent;
  try {
    await dir.delete(recursive: true);
  } catch (_) {}
  if (parent.path.endsWith(_androidScopeDir)) {
    try {
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } catch (_) {}
  }
}

/// 去掉文件名里的路径成分，避免 `..` / 分隔符逃逸临时目录。
String _safeName(String name) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  return base.isEmpty ? 'attachment' : base;
}
