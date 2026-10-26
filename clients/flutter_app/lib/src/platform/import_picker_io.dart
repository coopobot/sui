import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;

/// 原生端（桌面 / 移动）支持「选择文件夹」导入（FR-60 / AC-234）。
const bool importFolderPickSupported = true;

/// 资源单文件上限，与 `ImportOptions.maxFileBytes`（20 MiB）同口径：
/// 超限**根本不读进内存**，直接判为「取不到字节」→ 由 note_core 走降级（FR-61）。
const int _maxBytes = 20 * 1024 * 1024;

/// 单批文件数上限（BR-60.3）；递归收集到此即停，避免一次误选大目录把内存打满。
const int _maxFiles = 500;

/// 递归时跳过的目录名（隐藏目录另按 `.` 前缀跳过）；`.git` 等既无笔记又可能有环。
const Set<String> _skipDirs = {'node_modules', '.git', 'build', 'dist', 'blobs'};

/// 多选文件（桌面 / 移动）：`withData: true` 直接拿字节，平台层只负责读，
/// 转换与落库全在 `note_core`（BR-60.9）。
Future<List<ImportSourceFile>> pickImportFiles() async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    withData: true,
    type: FileType.custom,
    allowedExtensions: kImportSupportedExtensions,
    dialogTitle: '选择要导入的文件',
  );
  if (result == null) return const [];
  final out = <ImportSourceFile>[];
  for (final f in result.files) {
    final bytes = f.bytes;
    if (bytes == null) continue; // 个别平台 / 超大文件可能拿不到字节：跳过
    final path = f.path ?? '';
    out.add(ImportSourceFile(
      name: f.name,
      bytes: bytes,
      pathHint: path,
      // 只有拿到真实路径（非 Web）才能解析 HTML 里的相对资源。
      resolveResource:
          path.isEmpty ? null : (ref) => resolveImportResource(path, ref),
    ));
  }
  return out;
}

/// 选择文件夹并**递归**收集受支持扩展名的文件（FR-60 / AC-234）。
Future<List<ImportSourceFile>> pickImportFolder() async {
  final dir =
      await FilePicker.platform.getDirectoryPath(dialogTitle: '选择要导入的文件夹');
  if (dir == null) return const [];
  return collectImportSourceFiles(dir);
}

/// **递归收集**目录下受支持扩展名的文件（FR-60 / AC-234）。
///
/// 独立成公开函数是为了**可测**：目录选择器要弹系统对话框，而「收集规则」是纯逻辑。
/// 规则：稳定顺序（按路径排序，报告可复现）、跳过隐藏 / 无关 / 符号链接目录（防目录环）、
/// 跳过**印象笔记导出的资源目录**（见 [_isResourceBucket]）、按 [kImportSupportedExtensions]
/// 过滤、单批上限 [_maxFiles]。
Future<List<ImportSourceFile>> collectImportSourceFiles(String directory) async {
  final out = <ImportSourceFile>[];
  await _collect(Directory(directory), out);
  return out;
}

/// 该目录是否**印象笔记导出的资源目录**（`<笔记标题>_files` / `<笔记标题>.resources` /
/// `<笔记标题> files`），**且同级确实存在同名笔记文件**。
///
/// 实测（2026-10-12）：`…/科技自媒体行业分析_files/org.txt` 会被递归收集并当成一篇笔记导入
/// （标题 `org`、22 KB）——那是导出器的旁挂产物，不是用户的笔记。加上「同级有
/// `<stem>.<受支持扩展名>`」这一条件后，既挡掉这类旁挂文件，也不会误伤用户自己的
/// `foo_files` 笔记目录（那种目录通常没有同名的 `foo.html`）。
bool _isResourceBucket(Directory dir) {
  final name = p.basename(dir.path);
  for (final suffix in const [' files', '_files', '.resources']) {
    if (!name.endsWith(suffix) || name.length <= suffix.length) continue;
    final stem = name.substring(0, name.length - suffix.length);
    final parent = dir.parent.path;
    for (final ext in kImportSupportedExtensions) {
      if (File(p.join(parent, '$stem.$ext')).existsSync()) return true;
    }
  }
  return false;
}

/// 递归收集：稳定顺序（按路径排序，报告可复现）、跳过隐藏 / 无关 / 符号链接目录（防目录环）。
Future<void> _collect(Directory dir, List<ImportSourceFile> out) async {
  if (out.length >= _maxFiles) return;
  List<FileSystemEntity> entries;
  try {
    entries = await dir.list(followLinks: false).toList();
  } on FileSystemException {
    return; // 无权限目录：跳过，不中断整批
  }
  entries.sort((a, b) => a.path.compareTo(b.path));
  for (final e in entries) {
    if (out.length >= _maxFiles) return;
    if (e is Directory) {
      final name = p.basename(e.path);
      if (name.startsWith('.') || _skipDirs.contains(name)) continue;
      if (await FileSystemEntity.isLink(e.path)) continue;
      // 印象笔记导出的资源目录（`<stem>_files` 等）：里面的旁挂文件不是笔记。
      if (_isResourceBucket(e)) continue;
      await _collect(e, out);
    } else if (e is File) {
      final name = p.basename(e.path);
      if (!isSupportedImportFileName(name)) continue;
      final bytes = await _readCapped(e);
      if (bytes == null) continue;
      out.add(ImportSourceFile(
        name: name,
        bytes: bytes,
        pathHint: e.path,
        resolveResource: (ref) => resolveImportResource(e.path, ref),
      ));
    }
  }
}

/// 把 HTML（[htmlPath]）里的相对引用解析为**本机字节**（详细设计 §7 的候选回退表）。
///
/// 候选顺序：① 相对 HTML 所在目录的直接路径；② `<stem> files/`（**印象笔记实测命名**）；
/// ③ `<stem>_files/`；④ `<stem>.resources/`；⑤ `resources/`；⑥ 同目录同名文件。
/// 只读 HTML 所在目录**之内**的文件（拒绝 `..` 逃逸，守输入边界口径）；任何失败返回 null，
/// 由 `note_core` 记「未本地化资源」并降级（AC-248）。
Future<Uint8List?> resolveImportResource(
    String htmlPath, String reference) async {
  var ref = reference.trim().replaceAll('\\', '/');
  if (ref.isEmpty) return null;
  if (ref.toLowerCase().startsWith('file://')) {
    ref = ref.substring('file://'.length);
  }
  // 带 scheme（http / https / data / evernote…）不在这里处理：远端图片保持 URL、导入不出网。
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*:').hasMatch(ref)) return null;
  try {
    ref = Uri.decodeComponent(ref);
  } on ArgumentError {
    // 百分号编码不合法：按原样再试
  } on FormatException {
    // 同上
  }

  final dir = p.dirname(htmlPath);
  final stem = p.basenameWithoutExtension(htmlPath);
  final base = p.basename(ref);
  final candidates = <String>[
    if (ref.contains('/')) p.join(dir, ref),
    p.join(dir, '$stem files', base),
    p.join(dir, '${stem}_files', base),
    p.join(dir, '$stem.resources', base),
    p.join(dir, 'resources', base),
    p.join(dir, base),
  ];
  for (final c in candidates) {
    final path = p.normalize(c);
    if (!_inside(dir, path)) continue;
    final bytes = await _readCapped(File(path));
    if (bytes != null) return bytes;
  }
  return null;
}

/// [path] 是否落在 [dir] 之内（规范化 + 绝对化后比较，防 `..` 逃逸）。
bool _inside(String dir, String path) {
  final d = p.normalize(p.absolute(dir));
  final f = p.normalize(p.absolute(path));
  return f == d || p.isWithin(d, f);
}

/// 读取文件字节；不存在 / 读失败 / 超限都返回 null（不抛，交由降级路径处理）。
Future<Uint8List?> _readCapped(File file) async {
  try {
    if (!await file.exists()) return null;
    if (await file.length() > _maxBytes) return null;
    return await file.readAsBytes();
  } on FileSystemException {
    return null;
  }
}
