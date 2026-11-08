/// 由文件名推断附件大类。
///
/// 只做「大类」而非精确 MIME：附件卡片按它选图标，同步协议里 `mimeKind`
/// 也只是展示用途。不做内容嗅探 —— 字节已经在本地，没必要为图标多读一遍。
String mimeKindFor(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return 'other';
  final ext = filename.substring(dot + 1).toLowerCase();
  return _byExtension[ext] ?? 'other';
}

const _byExtension = <String, String>{
  'png': 'image',
  'jpg': 'image',
  'jpeg': 'image',
  'gif': 'image',
  'webp': 'image',
  'bmp': 'image',
  'svg': 'image',
  'heic': 'image',
  'heif': 'image',
  'tif': 'image',
  'tiff': 'image',
  'pdf': 'pdf',
  'mp4': 'video',
  'mov': 'video',
  'mkv': 'video',
  'avi': 'video',
  'webm': 'video',
  'mp3': 'audio',
  'wav': 'audio',
  'm4a': 'audio',
  'flac': 'audio',
  'ogg': 'audio',
  'aac': 'audio',
  'txt': 'text',
  'md': 'text',
  'csv': 'text',
  'json': 'text',
  'log': 'text',
  'zip': 'archive',
  'tar': 'archive',
  'gz': 'archive',
  '7z': 'archive',
  'rar': 'archive',
};

/// 由文件名推断**文件 MIME 类型**（交给系统挑「用哪个应用打开」，FR-110 / ADR-040）。
///
/// 与 [mimeKindFor] 的分工：那个给 UI 选图标用**大类**，这个给系统 `ACTION_VIEW`
/// 用**真实 MIME** —— 两者不可互换（把 `image` 当 MIME 传给系统，会一个应用都匹配不上）。
///
/// **推断不出来时返回 `*/*`**，而不是 `application/octet-stream`：`*/*` 仍会弹出
/// 系统应用选择器，让用户自己挑；`application/octet-stream` 在多数 ROM 上只能匹配到
/// 「另存 / 文件管理器」，等于把「类型没识别对」伪装成「打不开」（BR-110.3）。
String mimeTypeFor(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return '*/*';
  final ext = filename.substring(dot + 1).toLowerCase();
  return _mimeByExtension[ext] ?? '*/*';
}

const _mimeByExtension = <String, String>{
  // 图片
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'svg': 'image/svg+xml',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  // 文档
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'log': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'json': 'application/json',
  'html': 'text/html',
  'htm': 'text/html',
  'xml': 'application/xml',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  // 音视频
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'avi': 'video/x-msvideo',
  'webm': 'video/webm',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'm4a': 'audio/mp4',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'aac': 'audio/aac',
  // 压缩包
  'zip': 'application/zip',
  'tar': 'application/x-tar',
  'gz': 'application/gzip',
  '7z': 'application/x-7z-compressed',
  'rar': 'application/vnd.rar',
};
