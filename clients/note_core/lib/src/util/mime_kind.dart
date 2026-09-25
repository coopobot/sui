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