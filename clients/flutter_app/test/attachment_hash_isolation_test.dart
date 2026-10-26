/// 补丁 `v0.16.4`（FR-92 / AC-532）：**大附件散列不冻结 UI isolate**。
///
/// 22 MB 的 `sha256Hex` 同线程实测 325 ms 连续阻塞；`AppController` 对 ≥ 1 MiB 的
/// 附件字节改走 `compute`（工作 isolate）。本用例用「主 isolate 停顿检测」把这条
/// 性能契约钉住：旧实现（同线程散列）会稳定超过 200 ms 而失败。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';

void main() {
  test('22 MB 附件散列走工作 isolate：主 isolate 最大停顿 < 200 ms', () async {
    final db = AppDatabase.memory();
    // 附件字节要落真实磁盘：用一次性目录，避免污染工作目录。
    final dir = Directory.systemTemp.createTempSync('sui-hash-iso-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'v0164-hash'),
      database: db,
      dataDir: dir.path,
    );
    await controller.bootstrap();
    await controller.createNote();

    final bytes = Uint8List(22 * 1024 * 1024);
    for (var i = 0; i < bytes.length; i += 4096) {
      bytes[i] = (i ~/ 4096) % 251;
    }

    final lag = _LagMonitor()..start();
    final att = await controller.addAttachmentFromBytes(
      noteId: controller.selectedNoteId!,
      filename: 'big.pdf',
      bytes: bytes,
    );
    // 让阻塞期间过期的 timer 先落地，再停表（否则漏报）。
    await Future<void>.delayed(const Duration(milliseconds: 30));
    lag.stop();

    expect(att.sha256, sha256Hex(bytes), reason: '散列结果必须与同线程一致');
    expect(
      lag.maxGapMs,
      lessThan(200),
      reason: '22 MB 散列不得冻结 UI isolate（同线程实测 325 ms）',
    );

    await db.close();
    controller.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

class _LagMonitor {
  Timer? _timer;
  final Stopwatch _since = Stopwatch();
  int maxGapMs = 0;

  void start() {
    _since
      ..reset()
      ..start();
    _timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final gap = _since.elapsedMilliseconds;
      if (gap > maxGapMs) maxGapMs = gap;
      _since
        ..reset()
        ..start();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
