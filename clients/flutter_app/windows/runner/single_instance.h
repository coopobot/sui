#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// Windows 后台常驻的**单实例**约束（v0.17.1 / FR-97 / ADR-034）。
//
// 后台常驻（M17 / FR-95）让进程在关闭主窗口后继续存活；此时用户再次双击 exe，
// 旧行为会另起一个进程，于是托盘里多出一个图标、两个实例各自同步。这里用**命名
// 互斥量**把进程收敛为唯一实例：
//
// * 拿得到互斥量 → 本进程是主实例，照常创建窗口与托盘图标；
// * 拿不到 → 已有实例在跑：把它的主窗口唤到前台（托盘隐藏 / 最小化都会先还原），
//   本进程随后**立即退出**（不建引擎、不注册托盘、不写库）。
//
// 互斥量名带 `Local\` 前缀：**同一登录会话**内唯一。不同 Windows 账户 / 不同会话
// 各自只允许一个实例——与「通知区域只有一个图标」的用户预期一致。
enum class SingleInstanceResult {
  // 当前进程是唯一实例：调用方继续正常启动。
  kPrimary,
  // 已有实例在运行，且已收到「唤到前台」请求：调用方应立即退出。
  kSecondaryActivated,
  // 已有实例在运行但没能在限期内找到它的主窗口（例如它正在退出）：调用方仍应
  // 立即退出，避免出现第二个常驻实例。极端情况下（首实例其实已退出）本函数
  // 会先尝试**接替**成为主实例并返回 [kPrimary]。
  kSecondaryNoWindow,
};

// 尝试成为唯一实例。必须在创建任何窗口 / 引擎**之前**调用（`wWinMain` 里紧跟
// `MultiViewDesktopTryForwardTaskbarMenuActivation()` 之后）。
SingleInstanceResult AcquireSingleInstance();

// 「唤到前台」消息 id。用 `RegisterWindowMessageW` 注册，故**跨进程可用**：
// 二次启动的进程按 id 发消息，已有实例的主窗口在自己的 `MessageHandler` 里识别。
UINT SingleInstanceActivateMessageId();

#endif  // RUNNER_SINGLE_INSTANCE_H_
