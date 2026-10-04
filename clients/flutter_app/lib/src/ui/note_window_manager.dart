/// 主窗口（唯一的导航窗口）在命令目标注册表 / 窗口注册表中使用的固定视图键
/// （详细设计 §5.1）。
///
/// 主窗口是应用入口视图，句柄不由 `multiview_desktop` 分配，故用此固定字符串作为
/// 视图键；独立笔记窗口的视图键则取库分配的窗口句柄（桌面实现里为视图 id）。
const String kMainViewKey = 'main';

/// 独立笔记窗口管理器接缝（详细设计 §4 / §7 / §9.1）。
///
/// 多窗口能力由**桌面专属**的 `multiview_desktop` 提供（内部依赖 `dart:io` /
/// `dart:ffi`），不能进入 Web / 移动端构建。故 [AppController] 只依赖本**平台无关**
/// 接口，真实实现由桌面入口 `runMultiWindowApp` 注入；未注入（Web / Android / 单测）
/// 时，相关操作**优雅降级**为「在主窗口内选中该笔记」（BR-42.5 / AC-128）。
///
/// 抽成接口还有第二个目的：让窗口注册表逻辑（去重聚焦、关闭释放、异常自愈）可在
/// **无真实窗口**的单测里验证（详细设计 §9.1「`WindowManager` 接缝」）。
abstract interface class NoteWindowManager {
  /// 打开承载 [noteId] 的**新建**独立笔记窗口，返回窗口句柄（供注册表登记）。
  ///
  /// 句柄是**不透明**的 [Object]：桌面实现里为库分配的视图 id（`int`）。
  /// 去重与聚焦由 [AppController] 的注册表负责，本方法**只管新建**（§4.3）。
  Future<Object?> openNoteWindow(String noteId);

  /// 置前并聚焦句柄对应窗口；若已最小化则先还原（BR-43.2）。
  void focusNoteWindow(Object handle);

  /// 关闭句柄对应窗口（BR-43.4）。
  Future<void> closeNoteWindow(Object handle);

  /// 句柄指向的窗口是否仍有效（BR-43.6 异常自愈）。
  bool isNoteWindowValid(Object handle);

  /// 关闭全部窗口（「文件 → 退出应用」第 3 步，详细设计 §7）。
  Future<void> closeAllNoteWindows();
}

/// 窗口事件汇聚枢纽（详细设计 §4 / §5.1 / §7 / §9.1）。
///
/// 桌面实现的窗口观察者 `SuiWindowObserver`（见 `platform/multi_window_io.dart`）
/// 收到 `multiview_desktop` 的生命周期回调后，把事件**转发到本枢纽**；[AppController]
/// 在**创建时**（`runMultiApp` 的 `globalScope` 建树内）通过 [bind] 订阅。
///
/// 为什么要这层间接：`MultiAppConfig.observers` 必须先于 `globalScope` 构造，而
/// `AppController` 要到 `globalScope` 建树时才创建——两者时序相反，观察者在构造时
/// 拿不到控制器实例。故引入平台无关的枢纽：观察者只依赖它，控制器后到后订阅。
///
/// 抽成平台无关类型还有第二个目的：窗口注册表逻辑（打开 / 关闭 / 聚焦）可在**无真实
/// 窗口**的单测里直接调 `emit*` 驱动（详细设计 §9.1「`WindowManager` 接缝」）。
class WindowEventHub {
  void Function(Object handle)? _windowOpened;
  void Function(Object handle)? _windowClosed;
  void Function(Object handle)? _viewFocused;

  /// 由 [AppController] 创建时调用，登记三个转发目标。
  ///
  /// 句柄口径与 [NoteWindowManager] 一致：主窗口固定 [kMainViewKey]，独立窗口为其
  /// 窗口句柄（桌面实现里为库分配的视图 id）。
  void bind({
    required void Function(Object handle) onWindowOpened,
    required void Function(Object handle) onWindowClosed,
    required void Function(Object handle) onViewFocused,
  }) {
    _windowOpened = onWindowOpened;
    _windowClosed = onWindowClosed;
    _viewFocused = onViewFocused;
  }

  /// 解绑（控制器 `dispose` 时调用）；未绑定时各 `emit*` 静默忽略。
  void unbind() {
    _windowOpened = null;
    _windowClosed = null;
    _viewFocused = null;
  }

  /// 窗口**打开**（主窗口不触发：主窗口由控制器预置，见详细设计 §4.1）。
  void emitWindowOpened(Object handle) => _windowOpened?.call(handle);

  /// 窗口**关闭**（含主窗口；主窗口关闭即「最后一个窗口」）。
  void emitWindowClosed(Object handle) => _windowClosed?.call(handle);

  /// 某窗口**获得焦点**：更新活动视图键，令菜单 / 快捷键命令派发到该窗口（§5.1）。
  void emitViewFocused(Object handle) => _viewFocused?.call(handle);
}
