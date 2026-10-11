#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <tlhelp32.h>
#include <windows.h>

#include <algorithm>
#include <iostream>

#include "flutter_window.h"
#include "utils.h"

#ifndef NDEBUG
// ---- 诊断用（仅 debug 构建）：崩的那一瞬间把调用栈拍到 crash_stack.txt
//
// 为什么用矢量异常处理器（VEH）：引擎 / CRT 都可能装自己的
// SetUnhandledExceptionFilter（最后装的那个赢），VEH 抢在所有人前面，
// 而且这时进程还活着 —— 能直接读线程栈上的返回地址。事后用 build/diaprobe
// 那个小工具（读 flutter_windows.dll.pdb）把「模块 + RVA」翻成函数名。
//
// 两条纪律（都踩过）：
// 1. 只处理**致命**异常 —— 0x406d1388（线程命名）这类无害异常每次启动都有，
//    照单全收会把启动卡死；
// 2. 全程只走 Win32（CreateFileW/WriteFile），**不碰 CRT**（std::ofstream 要拿
//    锁 / 堆）—— 在异常上下文里碰它们会把进程卡成死转。
namespace {

volatile LONG g_crash_stack_written = 0;

bool FatalExceptionCode(DWORD code) {
  switch (code) {
    case EXCEPTION_ACCESS_VIOLATION:     // 0xC0000005
    case EXCEPTION_ILLEGAL_INSTRUCTION:  // 0xC000001D
    case EXCEPTION_IN_PAGE_ERROR:        // 0xC0000006
    case EXCEPTION_STACK_OVERFLOW:       // 0xC00000FD
    case EXCEPTION_ARRAY_BOUNDS_EXCEEDED:
    case 0xC0000374:  // 堆损坏
    case 0xC0000409:  // fail fast
    case 0xC000041D:  // 回调里的未处理异常
    case 0xC0000602:  // fail fast 变体
      return true;
    default:
      return false;
  }
}

void WriteRaw(HANDLE file, const char* text) {
  DWORD written = 0;
  ::WriteFile(file, text, static_cast<DWORD>(::lstrlenA(text)), &written,
              nullptr);
}

void WriteHex(HANDLE file, uintptr_t value) {
  char buffer[18];
  buffer[0] = '0';
  buffer[1] = 'x';
  buffer[17] = '\0';
  int index = 17;
  if (value == 0) {
    buffer[--index] = '0';
  }
  while (value != 0 && index > 2) {
    const int digit = static_cast<int>(value & 0xF);
    buffer[--index] =
        static_cast<char>(digit < 10 ? '0' + digit : 'a' + digit - 10);
    value >>= 4;
  }
  WriteRaw(file, buffer + index);
}

LONG CALLBACK CrashStackHandler(EXCEPTION_POINTERS* info) {
  if (info == nullptr || info->ExceptionRecord == nullptr ||
      info->ContextRecord == nullptr) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  if (!FatalExceptionCode(info->ExceptionRecord->ExceptionCode)) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  if (::InterlockedExchange(&g_crash_stack_written, 1) != 0) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  HANDLE file = ::CreateFileW(L"crash_stack.txt", GENERIC_WRITE,
                              FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  WriteRaw(file, "exception_code=");
  WriteHex(file, info->ExceptionRecord->ExceptionCode);
  WriteRaw(file, "\nexception_address=");
  WriteHex(file,
           reinterpret_cast<uintptr_t>(info->ExceptionRecord->ExceptionAddress));
  if (info->ExceptionRecord->NumberParameters >= 2) {
    WriteRaw(file, "\nexception_data=");
    WriteHex(file, info->ExceptionRecord->ExceptionInformation[1]);
  }
  WriteRaw(file, "\n");
  // 模块表：把栈上的返回地址换算成「模块 + RVA」要用
  HANDLE snap = ::CreateToolhelp32Snapshot(TH32CS_SNAPMODULE |
                                               TH32CS_SNAPMODULE32,
                                           ::GetCurrentProcessId());
  if (snap != INVALID_HANDLE_VALUE) {
    MODULEENTRY32W module{};
    module.dwSize = sizeof(module);
    if (::Module32FirstW(snap, &module)) {
      do {
        char name[128] = {};
        ::WideCharToMultiByte(CP_UTF8, 0, module.szModule, -1, name,
                              sizeof(name) - 1, nullptr, nullptr);
        WriteRaw(file, "mod ");
        WriteHex(file, reinterpret_cast<uintptr_t>(module.modBaseAddr));
        WriteRaw(file, " ");
        WriteHex(file, static_cast<uintptr_t>(module.modBaseSize));
        WriteRaw(file, " ");
        WriteRaw(file, name);
        WriteRaw(file, "\n");
      } while (::Module32NextW(snap, &module));
    }
    ::CloseHandle(snap);
  }
  // 栈扫描：从 RSP 往上 512 个槽（8 字节一槽）。RSP 附近一定是映射着的
  const uintptr_t sp = static_cast<uintptr_t>(info->ContextRecord->Rsp);
  WriteRaw(file, "rip=");
  WriteHex(file, static_cast<uintptr_t>(info->ContextRecord->Rip));
  WriteRaw(file, " rsp=");
  WriteHex(file, sp);
  WriteRaw(file, "\n");
  for (int i = 0; i < 512; ++i) {
    const uintptr_t address = sp + static_cast<uintptr_t>(i) * 8;
    const auto* slot = reinterpret_cast<const uintptr_t*>(address);
    const uintptr_t value = *slot;
    if (value == 0) {
      continue;
    }
    WriteRaw(file, "stk ");
    WriteHex(file, address);
    WriteRaw(file, " ");
    WriteHex(file, value);
    WriteRaw(file, "\n");
  }
  ::CloseHandle(file);
  return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace
#endif

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

#ifndef NDEBUG
  ::AddVectoredExceptionHandler(1, CrashStackHandler);
#endif

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // 窗口尺寸与位置（2026-10-03 晚：改成**横屏**）。
  //
  // 第一版做成窄长条（420x760）是因为界面当时是手机版式。当天用户对着微信 PC
  // 端提了要求：「电脑是横屏手机是竖屏」—— 界面加了「左图标条 + 会话列 + 聊天区」
  // 那套三栏（lib/features/home/desktop_frame.dart），所以窗口默认也按电脑软件来：
  // 1200x800，屏幕居中。
  //
  // 窗口宽到 900 以上才走三栏（desktop_frame.dart）。**窄窗那套（手机版式）在
  // 电脑端已经进不去了**：2026-10-09 把窗口最小宽度抬到 900（见 win32_window.cpp
  // 的 WM_GETMINMAXINFO）—— 那一版会把账号密码表单直接摊出来，绕开「密码登陆
  // 只对美国出口 IP 开放」那道闸门（用户选的堵法：「抬高最小窗口宽度到 900」）。
  //
  // **单位是逻辑像素**（Win32Window::Create 会按显示器 DPI 缩放，见 win32_window.cpp）。
  // 而 Win32 这边量出来的是**物理像素**（本进程按显示器 DPI 感知），所以下面要
  // 先除以缩放比 —— 不折算的话，在 200% 缩放的屏幕上算出来的“居中”是拿物理尺寸
  // 当逻辑尺寸用的，窗口会跑到屏幕右下角、大半个露在屏幕外（首次数出来就是这样）。
  const int kInitialWidth = 1200;
  const int kInitialHeight = 800;

  // 主显示器的缩放比。`nullptr` = 问主显示器（与 Create 里那个 monitor 是同一个值）。
  const double scale = FlutterDesktopGetDpiForHWND(nullptr) / 96.0;

  // 用**工作区**而不是整屏：居中时不该把任务栏算进去（Windows 上 760 高 + 任务栏
  // 很容易被顶到屏幕外）。SystemParametersInfo 给的也是物理像素，同样要折算。
  RECT work_area{};
  if (!::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0)) {
    work_area = RECT{0, 0, GetSystemMetrics(SM_CXSCREEN),
                     GetSystemMetrics(SM_CYSCREEN)};
  }
  const int work_left = static_cast<int>(work_area.left / scale);
  const int work_top = static_cast<int>(work_area.top / scale);
  const int work_width =
      static_cast<int>((work_area.right - work_area.left) / scale);
  const int work_height =
      static_cast<int>((work_area.bottom - work_area.top) / scale);

  // 屏幕比窗口还矮/窄时（小笔记本、竖屏），把初始尺寸收一收 —— 但**不再小于
  // 最小客户区那一档（900x600，见 win32_window.cpp）**：比它小的话窗口虽然拉不小，
  // 一开出来却是手机版式（就是上面要挡的那一档）。
  // 左右/上下各留 40 逻辑像素：贴着工作区四边开的窗口不像应用，像全屏。
  const int width = std::min(kInitialWidth, std::max(900, work_width - 80));
  const int height = std::min(kInitialHeight, std::max(600, work_height - 80));
  // 原点也要带上工作区自己的偏移（任务栏在屏幕顶部时 rcWork.top 不是 0）
  Win32Window::Point origin(work_left + std::max(0, (work_width - width) / 2),
                            work_top + std::max(0, (work_height - height) / 2));
  Win32Window::Size size(width, height);
  if (!window.Create(L"Gracelink", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (true) {
    // S12.22 原意：desktop_multi_window 的子窗口被关掉时，线程队列里会多出一条
    // WM_QUIT —— 照单全收会把主窗口一起带走。主窗口还在、且不是它在关，这条
    // 就丢掉。
    //
    // S12.24 修正：`GetMessage` 取到 WM_QUIT 时**返回 0**，写成
    // `while (::GetMessage(...))` 的话循环会直接退出 —— 循环体里这条过滤
    // 代码永远执行不到（子窗口一弹 WM_QUIT 就把整个应用带走）。返回值单独判。
    const BOOL got = ::GetMessage(&msg, nullptr, 0, 0);
    if (got == -1) {
      break;  // 出错：别在这儿死循环
    }
    if (got == 0) {
      // 取到了一条 WM_QUIT
      if (::IsWindow(window.GetHandle()) &&
          !FlutterWindow::IsMainWindowClosing()) {
        std::cerr << "[窗口] 忽略一条子窗口带来的 WM_QUIT" << std::endl;
        continue;
      }
      break;
    }
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  std::cerr << "[窗口] 消息循环结束（"
            << (FlutterWindow::IsMainWindowClosing() ? "主窗口关闭" : "其它原因")
            << "）" << std::endl;

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
