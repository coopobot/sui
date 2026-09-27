import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// 跑测试前先把 SQLite 原生库定位好。
///
/// `package:sqlite3` 在 Linux 上写死找 `libsqlite3.so`，但发行版运行时装的是
/// `libsqlite3.so.0` —— `.so` 这个开发用符号链接只有 `libsqlite3-dev` 才提供。
/// 缺了它 drift 会直接抛 `Failed to load dynamic library 'libsqlite3.so'`。
///
/// 原先靠 `~/.bashrc` 里 `export LD_LIBRARY_PATH=$HOME/.local/lib` 指向自建软链
/// 绕过（见 `docs/troubleshooting.md`），但 `.bashrc` 开头有「非交互式 shell
/// 直接 return」，`bash -lc` 这类非交互式调用根本读不到，脚本与 CI 跑测试必挂。
/// 这里在测试进程内兜底：按候选名依次尝试，第一个能加载的覆盖给 sqlite3。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _ensureSqliteLibrary();
  await testMain();
}

void _ensureSqliteLibrary() {
  final (operatingSystem, candidates) = switch (Platform.operatingSystem) {
    'linux' => (OperatingSystem.linux, const ['libsqlite3.so', 'libsqlite3.so.0']),
    'macos' => (OperatingSystem.macOS, const ['libsqlite3.dylib']),
    'windows' => (OperatingSystem.windows, const ['sqlite3.dll']),
    _ => (null, const <String>[]),
  };
  if (operatingSystem == null) return;

  for (final name in candidates) {
    try {
      final lib = DynamicLibrary.open(name);
      open.overrideFor(operatingSystem, () => lib);
      return;
    } catch (_) {
      // 打不开就换下一个候选名。
    }
  }
  // 全都打不开时保持 sqlite3 默认行为，让标准报错原样冒出来，便于定位。
}
