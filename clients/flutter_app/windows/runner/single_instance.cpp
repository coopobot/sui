#include "single_instance.h"

#include <cwchar>
#include <string>

namespace {

// 命名互斥量的名字。`Local\` = 会话内唯一（同一账户的多个会话各自一个实例）。
constexpr wchar_t kMutexName[] = L"Local\\SuiFlutterApp.SingleInstance";
// 「唤到前台」消息名。`RegisterWindowMessageW` 保证同一字符串在所有进程里得到同一 id。
constexpr wchar_t kActivateMessageName[] =
    L"SuiFlutterApp.SingleInstance.ActivateMainWindow";

// 主窗口类名（与 `win32_window.cpp` / multiview_desktop 插件的宿主窗口一致）。
constexpr wchar_t kRunnerWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kHostWindowClassName[] = L"MULTIVIEW_DESKTOP_HOST_WINDOW";

// 二次启动时等已有实例主窗口出现的轮次与间隔（30 × 120ms ≈ 3.6s）：覆盖首实例
// 「冷启动 + 首帧渲染 + 建托盘」的耗时。
constexpr int kFindWindowAttempts = 30;
constexpr DWORD kFindWindowIntervalMs = 120;
// 已有实例疑似正在退出时的观察窗口：超过它还没有窗口、也没释放互斥量，就按
// 「已有实例仍在跑」处理（本进程退出）。
constexpr DWORD kTakeOverWaitMs = 4000;

// 主实例持有的互斥量句柄。故意**不关闭**：进程存活期间靠它维持「名字存在」，
// 进程退出时由系统回收（此时对象若被标记为废弃，二次启动的进程可接替）。
HANDLE g_mutex = nullptr;

UINT ActivateMessageId() {
  static const UINT id = ::RegisterWindowMessageW(kActivateMessageName);
  return id;
}

std::wstring CurrentExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  while (true) {
    const DWORD length = ::GetModuleFileNameW(nullptr, path.data(),
                                              static_cast<DWORD>(path.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < path.size()) {
      path.resize(length);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

// 取另一个进程的可执行文件全路径；打不开（权限 / 已退出）时返回空串。
std::wstring ProcessImagePath(DWORD process_id) {
  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (process == nullptr) {
    return std::wstring();
  }
  std::wstring path(MAX_PATH, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  const BOOL ok = ::QueryFullProcessImageNameW(process, 0, path.data(), &size);
  ::CloseHandle(process);
  if (!ok) {
    return std::wstring();
  }
  path.resize(size);
  return path;
}

bool SameExecutable(const std::wstring& left, const std::wstring& right) {
  if (left.empty() || right.empty()) {
    return false;
  }
  return ::CompareStringOrdinal(left.c_str(), -1, right.c_str(), -1, TRUE) ==
         CSTR_EQUAL;
}

struct FindWindowContext {
  DWORD current_process_id = 0;
  std::wstring executable;
  HWND runner_window = nullptr;
  HWND host_window = nullptr;
};

BOOL CALLBACK EnumWindowsProc(HWND hwnd, LPARAM lparam) {
  auto* context = reinterpret_cast<FindWindowContext*>(lparam);
  if (hwnd == nullptr || !::IsWindow(hwnd)) {
    return TRUE;
  }

  DWORD process_id = 0;
  ::GetWindowThreadProcessId(hwnd, &process_id);
  if (process_id == 0 || process_id == context->current_process_id) {
    return TRUE;
  }

  wchar_t class_name[128] = {};
  if (::GetClassNameW(hwnd, class_name, 128) == 0) {
    return TRUE;
  }
  const bool is_runner =
      wcscmp(class_name, kRunnerWindowClassName) == 0;
  const bool is_host = wcscmp(class_name, kHostWindowClassName) == 0;
  if (!is_runner && !is_host) {
    return TRUE;
  }

  // 这两个类名是**所有 Flutter 应用共用**的：必须再按可执行文件全路径过滤，
  // 否则会把别的 Flutter 应用的窗口当成「自己」唤到前台（ADR-034 决策依据）。
  if (!SameExecutable(ProcessImagePath(process_id), context->executable)) {
    return TRUE;
  }

  if (is_runner) {
    context->runner_window = hwnd;
    return FALSE;  // 主窗口就是目标，停止枚举。
  }
  if (context->host_window == nullptr) {
    context->host_window = hwnd;  // 只剩独立窗口时用它兜底。
  }
  return TRUE;
}

HWND FindRunningMainWindow(const std::wstring& executable) {
  FindWindowContext context;
  context.current_process_id = ::GetCurrentProcessId();
  context.executable = executable;
  ::EnumWindows(EnumWindowsProc, reinterpret_cast<LPARAM>(&context));
  return context.runner_window != nullptr ? context.runner_window
                                          : context.host_window;
}

void SignalExistingInstance(HWND window) {
  // 前台锁默认只允许**当前前台进程**把别人切到前台：二次启动的进程此刻通常就是
  // 前台，先把这份权利敞开，已有实例的 `SetForegroundWindow` 才不会被系统忽略。
  ::AllowSetForegroundWindow(ASFW_ANY);
  ::PostMessage(window, ActivateMessageId(), 0, 0);
}

// 已有实例是否真的退出：等它释放 / 废弃互斥量，成功则把该句柄留下当作本进程的
// 「主实例」凭据（进程存活期间对象不消失）。
bool TryTakeOverMutex() {
  HANDLE existing = ::OpenMutexW(SYNCHRONIZE, FALSE, kMutexName);
  if (existing != nullptr) {
    const DWORD wait = ::WaitForSingleObject(existing, kTakeOverWaitMs);
    if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
      g_mutex = existing;
      return true;
    }
    ::CloseHandle(existing);
    return false;
  }
  if (::GetLastError() != ERROR_FILE_NOT_FOUND) {
    return false;
  }
  // 名字已不存在（首实例在两次调用之间退出了）：直接建一个新的。
  HANDLE created = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (created == nullptr) {
    return false;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(created);
    return false;
  }
  g_mutex = created;
  return true;
}

}  // namespace

UINT SingleInstanceActivateMessageId() { return ActivateMessageId(); }

SingleInstanceResult AcquireSingleInstance() {
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (mutex == nullptr) {
    // 极端情况（句柄耗尽 / 受限环境）：**不阻断启动**。宁可偶尔多一个实例，
    // 也不能让应用起不来。
    return SingleInstanceResult::kPrimary;
  }
  if (::GetLastError() != ERROR_ALREADY_EXISTS) {
    g_mutex = mutex;
    return SingleInstanceResult::kPrimary;
  }
  ::CloseHandle(mutex);  // 已存在：本进程不是创建者，不留句柄。

  const std::wstring executable = CurrentExecutablePath();

  // ① 等已有实例的主窗口出现并唤醒它（首实例可能还在冷启动）。
  for (int attempt = 0; attempt < kFindWindowAttempts; ++attempt) {
    if (const HWND window = FindRunningMainWindow(executable)) {
      SignalExistingInstance(window);
      return SingleInstanceResult::kSecondaryActivated;
    }
    if (attempt + 1 < kFindWindowAttempts) {
      ::Sleep(kFindWindowIntervalMs);
    }
  }

  // ② 始终没窗口：可能首实例正在退出——等它释放互斥量后由本进程接替。
  if (TryTakeOverMutex()) {
    return SingleInstanceResult::kPrimary;
  }

  // ③ 接替也失败：首实例大概只是建窗口慢。再找一轮，找到仍按「唤醒后退出」处理。
  if (const HWND window = FindRunningMainWindow(executable)) {
    SignalExistingInstance(window);
    return SingleInstanceResult::kSecondaryActivated;
  }
  return SingleInstanceResult::kSecondaryNoWindow;
}
