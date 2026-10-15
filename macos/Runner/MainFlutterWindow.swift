import Cocoa
import FlutterMacOS
// 子窗口是由它建的：它给了 `setOnWindowCreatedCallback`，我们在下面用它拿
// 「每扇新子窗的 FlutterViewController」，好把自家那条 `gracelinkim/child_window`
// 挂上去（见 `ChildWindowChannel.swift`）。
// 模块名与 `macos/Flutter/GeneratedPluginRegistrant.swift` 里那份一致。
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  /// 内容区最小尺寸（逻辑像素）。
  ///
  /// 与 Windows runner 的 `kMinClientWidth` / `kMinClientHeight` 同一个数：窗口窄到
  /// kDesktopFrameMinWidth 以下就会从三栏退回**手机版式**，而那一版是把账号密码表单
  /// 直接摊在页面上的 —— 等于绕开「密码登陆只对美国出口 IP 开放」那道闸门
  /// （见 lib/features/login/password_login_policy.dart）。
  ///
  /// 用例 test/core/desktop_window_min_size_test.dart 直接读这个文件把数字钉住：
  /// 改小会红，改写法也要同步那条用例。
  static let minClientSize = NSSize(width: 900, height: 600)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.contentMinSize = MainFlutterWindow.minClientSize

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 子窗那条自家通道：`desktop_multi_window` 每建出一扇子窗都会回调一次。
    // **必须在建出任何子窗之前注册** —— 它是全局静态回调，晚注册的那些窗口
    // 就没人接了（Dart 那边看到的现象是「点了没反应」，见 `ChildWindowChannel`
    // 文件头：子窗是 `hiddenAtLaunch` 建的，没人叫它 `show` 就永远藏着）。
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      ChildWindowChannel.attach(to: controller)
    }

    // 版本号（「检查更新」报给服务端的内部号）与菜单栏那一套
    AppInfoChannel.register(with: flutterViewController.engine.binaryMessenger)
    TrayIcon.register(with: flutterViewController.engine.binaryMessenger)
    TrayIcon.shared.mainWindow = self

    super.awakeFromNib()
  }

  /// 点 ✕（或 ⌘W）：**缩回菜单栏，不退出**（与 Windows 的托盘同一套行为）。
  ///
  /// 为什么不走 delegate 那一手：主窗的 delegate 是 MainMenu.xib 接给
  /// `AppDelegate` 的，抢过来会连带影响 Flutter 自己那套；`performClose` 是
  /// 窗口自己的方法，✕ 与 ⌘W 都从这里过，改这一处最窄。
  ///
  /// ⚠️ **菜单栏图标没建起来时维持老行为（关掉就退出）**：见 `TrayIcon.isReady`
  /// 的说明 —— 「关窗留后台」开着却叫不回来，比直接退出更糟。
  override func performClose(_ sender: Any?) {
    guard TrayIcon.shared.isReady else {
      super.performClose(sender)
      return
    }
    TrayIcon.shared.hideMainWindow()
  }
}
