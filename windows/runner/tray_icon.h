#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

// 顺序不能反：`shellapi.h` 要用 `windows.h` 里那堆东西（HDROP、DECLSPEC_IMPORT…），
// 自己不会去带它 —— 先 include shellapi 的话它会从第 68 行开始整片报错。
#include <windows.h>

#include <shellapi.h>

#include <string>

/// 系统托盘里那一颗图标（S12.36）。
///
/// 用户 2026-10-06 提的：「像微信还有一些软件，你从 Windows 底部栏右边那个小
/// 箭头点开还能看到 —— 应用没有真正被关掉」。所以要的是**关窗只缩起来**：
/// 进程、WebSocket、铃声全都留着，来电和消息照样收得到；真退出只有菜单里那一项。
///
/// 菜单与气泡里的字都由 Dart 递进来（跟着 App 的语言走，见
/// `lib/features/desktop_window/tray_native.dart`），原生这边**只留一句中文兜底**
/// —— 语言包那 7 份是唯一的事实来源。
class TrayIcon {
 public:
  /// 托盘图标的鼠标事件发到宿主窗口的这条消息上。
  /// `NOTIFYICON_VERSION_4` 下：`lparam` 低 16 位是鼠标消息、高 16 位是图标 id。
  static constexpr UINT kCallbackMessage = WM_APP + 90;
  static constexpr int kMenuOpen = 1;
  static constexpr int kMenuExit = 2;

  TrayIcon() = default;
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  /// 加图标（`owner` = 收事件与弹菜单的那扇窗）。外壳没就绪 / 被策略挡了返回 false。
  bool Add(HWND owner, const std::wstring& tooltip);
  void Remove();
  bool added() const { return added_; }

  /// 换菜单与气泡的文字（语言变了就重配一次）
  void SetLabels(std::wstring open, std::wstring exit, std::wstring balloon);
  const std::wstring& balloon() const { return balloon_; }

  /// 冒个气泡（第一次缩进托盘时提示一句，跟微信一样）
  void ShowBalloon(const std::wstring& title, const std::wstring& text);

  /// 右键：弹菜单并把用户点的那一项**返回**（0 = 没选 / 点空了）。
  /// 用 `TrackPopupMenu` 的 `TPM_RETURNCMD`：回来的是命令 id，不是异步消息，
  /// 宿主那边一条 `switch` 就能处理完。
  int ShowMenu(HWND owner);

 private:
  void RebuildMenu();
  void DropMenu();

  NOTIFYICONDATAW data_{};
  HMENU menu_ = nullptr;
  std::wstring tooltip_;
  std::wstring open_label_;
  std::wstring exit_label_;
  std::wstring balloon_;
  bool added_ = false;
};

#endif  // RUNNER_TRAY_ICON_H_
