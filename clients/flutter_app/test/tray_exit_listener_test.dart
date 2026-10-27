/// M17 / FR-95：Windows 托盘退出请求经 `sui/platform` 路由到显式退出收尾。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sui_flutter_app/src/ui/tray_exit_listener.dart';

Future<void> _sendTrayExit() {
  final message = const StandardMethodCodec().encodeMethodCall(
    const MethodCall('trayExitRequested'),
  );
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'sui/platform',
    message,
    (ByteData? _) {},
  );
}

void main() {
  testWidgets('Windows：托盘退出请求调用 onExit 一次', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      var calls = 0;
      await tester.pumpWidget(
        TrayExitListener(
          onExit: () async => calls++,
          child: const SizedBox.shrink(),
        ),
      );
      await tester.pump();

      await _sendTrayExit();
      await tester.pump();
      expect(calls, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('非 Windows：不注册托盘退出处理器', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      var calls = 0;
      await tester.pumpWidget(
        TrayExitListener(
          onExit: () async => calls++,
          child: const SizedBox.shrink(),
        ),
      );
      await tester.pump();

      await _sendTrayExit();
      await tester.pump();
      expect(calls, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
