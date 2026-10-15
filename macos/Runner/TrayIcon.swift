import Cocoa
import FlutterMacOS

/// macOS 的「菜单栏图标 + 关窗缩回后台」，对应 Windows 那边的托盘
/// （`windows/runner/tray_icon.cpp` 与 `flutter_window.cpp` 的 `WM_CLOSE` 那一手）。
///
/// 要的行为与 Windows 一致（用户 2026-10-06 定的是微信那套：「应用没有真正被关掉」）：
/// ✕ 只是把窗口**收起来** —— 进程、WebSocket、铃声都留着，来电与消息照样收得到；
/// 真退出只有菜单栏里那一项与 ⌘Q。
///
/// 文案**由 Dart 递进来**（通道 `gracelinkim/tray` 的 `configure`，见
/// `lib/features/desktop_window/tray_native.dart`）：菜单上的字要跟着 App 语言走，
/// 而 7 份语言包只有 Dart 读得到，原生这边一个字都不翻译（与 Windows 同一个分工）。
///
/// ⚠️ **没配好之前一律维持老行为（✕ = 退出）**：[isReady] 是那道闸门 ——
/// 图标没建起来就把「关窗缩回后台」开着，用户关掉窗口之后就再也叫不回来了，
/// 那比直接退出更糟（`docs/release/macos-plan.md` 第五节当时就是为此没敢先写一半）。
final class TrayIcon: NSObject {
  static let shared = TrayIcon()

  static let channelName = "gracelinkim/tray"

  /// 通道得我们持有：Flutter 那边只留处理函数
  private static var channels: [FlutterMethodChannel] = []

  private var statusItem: NSStatusItem?
  private var openTitle = "打开 Gracelink"
  private var exitTitle = "退出"

  /// 真实建出来了没有（见文件头那条警告）
  var isReady: Bool { statusItem != nil }

  /// 主窗口：缩回之后要能叫回来。弱引用 —— 窗口归 AppKit 管，这里只借用一下。
  weak var mainWindow: NSWindow?

  private override init() {
    super.init()
  }

  /// 挂上 `gracelinkim/tray` 通道（在主引擎里注册一次，见 `MainFlutterWindow`）
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: TrayIcon.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "configure" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let payload = call.arguments as? [String: Any]
      TrayIcon.shared.configure(
        open: (payload?["open"] as? String) ?? "",
        exit: (payload?["exit"] as? String) ?? "",
        balloon: (payload?["balloon"] as? String) ?? ""
      )
      result(true)
    }
    channels.append(channel)
  }

  /// Dart 把当前语言的文案配过来（同一语言它自己会去重）
  private func configure(open: String, exit: String, balloon: String) {
    if !open.isEmpty { openTitle = open }
    if !exit.isEmpty { exitTitle = exit }
    if statusItem == nil { create() }
    // Windows 那边第一次缩回时弹一个气泡提示；macOS 的等价物是鼠标停在图标上
    // 那一行提示 —— 不弹系统通知（那要先要通知权限，为一个提示不值当）
    statusItem?.button?.toolTip = balloon.isEmpty ? "Gracelink" : balloon
    rebuildMenu()
  }

  private func create() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      // 图标优先用系统符号（自动跟着菜单栏的明暗与强调色走，也能当模板图渲染）；
      // 拿不到符号的机器就退回 App 图标 —— 不为一个图标在这里画一张图。
      let symbol = NSImage(
        systemSymbolName: "bubble.left.and.bubble.right",
        accessibilityDescription: "Gracelink"
      )
      symbol?.isTemplate = true
      let image = symbol ?? NSImage(named: NSImage.applicationIconName)
      image?.size = NSSize(width: 18, height: 18)
      button.image = image
    }
    statusItem = item
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    let open = NSMenuItem(title: openTitle, action: #selector(restore(_:)), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(.separator())
    let exit = NSMenuItem(title: exitTitle, action: #selector(quit(_:)), keyEquivalent: "")
    exit.target = self
    menu.addItem(exit)
    statusItem?.menu = menu
  }

  @objc private func restore(_ sender: Any?) {
    showMainWindow()
  }

  @objc private func quit(_ sender: Any?) {
    NSApp.terminate(nil)
  }

  /// 把主窗口叫回来（菜单栏那一项、以及点 Dock 图标都走这里）
  func showMainWindow() {
    guard let window = mainWindow else { return }
    window.setIsVisible(true)
    window.makeKeyAndOrderFront(nil)
    ChildWindowChannel.activateApp()
  }

  /// ✕ 缩回后台：窗口藏起来，进程一切照旧（与 Windows 的 `HideToTray` 同一个意思）
  func hideMainWindow() {
    mainWindow?.orderOut(nil)
  }
}
