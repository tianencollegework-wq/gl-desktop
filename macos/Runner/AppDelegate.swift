import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 菜单栏图标建起来之后，关掉最后一扇窗**不再退出**（与 Windows 那边
    // 「关窗只是缩回托盘」同一个行为，见 `TrayIcon.swift`）。
    // 图标没起来就维持老行为：没有回来的路，退出比藏着强。
    return !TrayIcon.shared.isReady
  }

  /// 点 Dock 图标：把主窗口叫回来。
  ///
  /// 为什么必须自己写这一手：「缩回菜单栏」之后窗口是 `orderOut` 掉的，
  /// 系统认为它还在（`applicationShouldTerminateAfterLastWindowClosed` 也回 false），
  /// 于是点 Dock 图标默认什么都不做 —— 那一瞬间用户会以为程序死了。
  /// 有了它，「菜单栏图标」与「Dock 图标」是两条独立的回来的路。
  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      TrayIcon.shared.showMainWindow()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
