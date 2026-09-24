import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

/// 原生平台连接。
///
/// [inMemory] 为真时返回纯内存库（测试用）；否则在 `[basePath]/sui.sqlite`
/// 落盘，[basePath] 为空则用当前工作目录。
QueryExecutor openConnection({String? basePath, bool inMemory = false}) {
  if (inMemory) return NativeDatabase.memory();
  final dir = basePath ?? Directory.current.path;
  Directory(dir).createSync(recursive: true);
  return NativeDatabase(File(p.join(dir, 'sui.sqlite')));
}