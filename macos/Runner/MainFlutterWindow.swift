import Cocoa
import FlutterMacOS

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

    super.awakeFromNib()
  }
}
