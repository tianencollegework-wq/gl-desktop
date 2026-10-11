#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "tray_icon.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // S12.22：主窗口（就是这一颗，子窗口是 desktop_multi_window 自己那套类）
  // 是不是正在关闭。消息循环靠它区分「主窗口关闭 → 该退出」与
  // 「子窗口关闭 → 别把整个应用带走」（后者实测会往线程里塞 WM_QUIT）。
  static bool IsMainWindowClosing() { return main_window_closing_; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // S12.36：关窗只缩回托盘（见 [TrayIcon]）。
  void HideToTray();
  void RestoreFromTray();
  void QuitFromTray();
  void OnTrayMessage(LPARAM lparam);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 见 [IsMainWindowClosing]。
  static bool main_window_closing_;

  // 系统托盘（S12.36）。
  TrayIcon tray_;

  // 现在是不是缩在托盘里（窗口不可见）。
  bool tray_hidden_ = false;

  // 那句「还在后台运行」的提示只冒一次（跟微信一样）：再关一次说明用户知道了。
  bool tray_balloon_shown_ = false;

  // 这次 `WM_CLOSE` 是**真退出**（从托盘菜单点进来的），不是缩窗。
  bool quitting_from_tray_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
