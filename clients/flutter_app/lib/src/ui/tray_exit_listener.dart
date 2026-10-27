import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 监听 Windows runner 的「托盘退出」请求，并复用显式退出路径（M17 / FR-95）。
///
/// 原生托盘菜单选择「退出随手记 Sui」后，会经自研通道 `sui/platform` 调用
/// `trayExitRequested`。本组件收到后执行 [onExit]（生产路径为
/// `AppController.quitApplication`）：先 flush 各窗口编辑器、尽力同步一次，
/// 再结束进程（BR-95.3）。
///
/// 只在 **Windows** 注册；Web / 移动端 / macOS / Linux 直接透传子组件，
/// 不改变既有行为。
class TrayExitListener extends StatefulWidget {
  const TrayExitListener({
    super.key,
    required this.onExit,
    required this.child,
  });

  /// 与原生 runner 约定的平台通道（见 `windows/runner/sui_platform_channel.cpp`）。
  static const MethodChannel channel = MethodChannel('sui/platform');

  /// 收到托盘退出请求后执行的收尾动作。
  final Future<void> Function() onExit;

  final Widget child;

  @override
  State<TrayExitListener> createState() => _TrayExitListenerState();
}

class _TrayExitListenerState extends State<TrayExitListener> {
  bool _registered = false;

  @override
  void initState() {
    super.initState();
    // runner 仅存在于 Windows；其它平台不注册，避免无意义的通道占用。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      TrayExitListener.channel.setMethodCallHandler(_handle);
      _registered = true;
    }
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method == 'trayExitRequested') {
      await widget.onExit();
    }
  }

  @override
  void dispose() {
    if (_registered) {
      TrayExitListener.channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
