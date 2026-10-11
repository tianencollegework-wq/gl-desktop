#include "tray_icon.h"

#include <iostream>

#include "resource.h"

namespace {

/// 一颗进程共用一份图标：`uID` 只是同一扇窗口下多颗图标时的区分
constexpr UINT kIconId = 1;

/// Dart 那边还没把文案配过来时先顶一下（正常只在启动的头几百毫秒用得上）
constexpr const wchar_t kFallbackOpen[] = L"打开 Gracelink";
constexpr const wchar_t kFallbackExit[] = L"退出";

}  // namespace

TrayIcon::~TrayIcon() {
  Remove();
}

bool TrayIcon::Add(HWND owner, const std::wstring& tooltip) {
  if (added_) {
    return true;
  }
  if (owner == nullptr) {
    return false;
  }
  tooltip_ = tooltip;

  data_ = NOTIFYICONDATAW{};
  data_.cbSize = sizeof(NOTIFYICONDATAW);
  data_.hWnd = owner;
  data_.uID = kIconId;
  data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  data_.uCallbackMessage = kCallbackMessage;
  // 小图标（通知区就那么点大）：拿 16x16 那一档，别指望 256 那张大图缩得好
  const int icon_width = ::GetSystemMetrics(SM_CXSMICON);
  const int icon_height = ::GetSystemMetrics(SM_CYSMICON);
  data_.hIcon = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      icon_width, icon_height, LR_DEFAULTCOLOR));
  ::lstrcpynW(data_.szTip, tooltip.c_str(), ARRAYSIZE(data_.szTip));

  if (!::Shell_NotifyIconW(NIM_ADD, &data_)) {
    // 外壳没起（比如在服务里跑）或通知区被策略关掉了：不是错，静默降级。
    std::cerr << "[托盘] 图标加不上（外壳没起？）(tray-add-failed)" << std::endl;
    return false;
  }
  // V4：回调消息的语义更清楚（低 16 位 = 鼠标消息），右键菜单也不会卡着不消失
  data_.uVersion = NOTIFYICON_VERSION_4;
  ::Shell_NotifyIconW(NIM_SETVERSION, &data_);
  added_ = true;
  std::cerr << "[托盘] 图标已就位 (tray-ready)" << std::endl;
  return true;
}

void TrayIcon::Remove() {
  if (added_) {
    ::Shell_NotifyIconW(NIM_DELETE, &data_);
    added_ = false;
  }
  if (data_.hIcon != nullptr) {
    ::DestroyIcon(data_.hIcon);
    data_.hIcon = nullptr;
  }
  DropMenu();
}

void TrayIcon::SetLabels(std::wstring open,
                         std::wstring exit,
                         std::wstring balloon) {
  open_label_ = std::move(open);
  exit_label_ = std::move(exit);
  balloon_ = std::move(balloon);
  // 菜单是弹的那一刻现建的（见 [RebuildMenu]）：这里只要把旧的重置掉，
  // 下一次右键就是新文字。
  DropMenu();
}

void TrayIcon::ShowBalloon(const std::wstring& title, const std::wstring& text) {
  if (!added_ || text.empty()) {
    return;
  }
  ::lstrcpynW(data_.szInfoTitle, title.c_str(), ARRAYSIZE(data_.szInfoTitle));
  ::lstrcpynW(data_.szInfo, text.c_str(), ARRAYSIZE(data_.szInfo));
  // 不用系统那几种提示图标：说话的是我们自己的托盘图标，再加一个感叹号反而乱
  data_.dwInfoFlags = NIIF_NONE;
  data_.uFlags = NIF_INFO | NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  ::Shell_NotifyIconW(NIM_MODIFY, &data_);
}

int TrayIcon::ShowMenu(HWND owner) {
  if (!added_ || owner == nullptr) {
    return 0;
  }
  RebuildMenu();
  if (menu_ == nullptr) {
    return 0;
  }
  POINT cursor{};
  ::GetCursorPos(&cursor);
  // TrackPopupMenu 的两条经典要求（不做就会「点了没反应 / 菜单不消失」）：
  // ① 菜单归属的窗口得在前台；② 选完之后补一条空消息。
  ::SetForegroundWindow(owner);
  const int command =
      ::TrackPopupMenu(menu_,
                       TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON |
                           TPM_BOTTOMALIGN,
                       cursor.x, cursor.y, 0, owner, nullptr);
  ::PostMessageW(owner, WM_NULL, 0, 0);
  return command;
}

void TrayIcon::RebuildMenu() {
  DropMenu();
  menu_ = ::CreatePopupMenu();
  if (menu_ == nullptr) {
    return;
  }
  ::AppendMenuW(menu_, MF_STRING, kMenuOpen,
                open_label_.empty() ? kFallbackOpen : open_label_.c_str());
  ::AppendMenuW(menu_, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu_, MF_STRING, kMenuExit,
                exit_label_.empty() ? kFallbackExit : exit_label_.c_str());
}

void TrayIcon::DropMenu() {
  if (menu_ != nullptr) {
    ::DestroyMenu(menu_);
    menu_ = nullptr;
  }
}
