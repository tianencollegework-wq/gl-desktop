import Cocoa
import FlutterMacOS

/// `gracelinkim/child_window` 在 macOS 这一侧 —— 与 `windows/runner/flutter_window.cpp`
/// 里那条通道**同一套约定**（Dart 侧见
/// `lib/features/desktop_window/desktop_window_native.dart`）。
///
/// ── 为什么需要它 ────────────────────────────────────────────────────────────
/// 桌面上的每一扇子窗（文章 / 灵听 / 媒体号 / 网页窗 / 通话窗）都是带
/// `hiddenAtLaunch: true` 建的：**先藏起来**，等窗口自己这边把标题 / 尺寸 / 居中
/// 设好再 `show`，这样才不会先闪一下 800×600 的默认样子（见
/// `desktop_window_service.dart` 与 `call_window_host.dart` 里那一行注释）。
///
/// 也就是说：**没有这条通道，窗口就永远不会 show**。Windows 那边
/// `windows/runner/flutter_window.cpp` 实现了它；macOS 一直到 2026-10-15 都没有，
/// 于是 Mac 上点「文章 / 灵听 / 媒体号 / 网页窗」以及来电话时的通话窗，
/// 全都表现为「点了没反应」—— 窗口其实真的建出来了，只是永远藏着。
/// 这一条把 Mac 上那半边补上（窗口本身、缩放、Dock 项都交给 AppKit）。
///
/// ── 怎么挂上 ────────────────────────────────────────────────────────────────
/// 子窗是 `desktop_multi_window` 建的，它的 macOS 实现给了一个公开回调
/// （`FlutterMultiWindowPlugin.setOnWindowCreatedCallback`），把每扇新窗的
/// `FlutterViewController` 递出来。在**主引擎**里注册一次即可
/// （见 `MainFlutterWindow.swift` 的 `awakeFromNib`），之后每扇子窗都能挂上。
///
/// ── ✕ 的语义（照 Windows 那一套搬）──────────────────────────────────────────
/// * **没声明过的窗**（文章 / 网页 / 媒体号 / 灵听）：✕ 就是关掉，不经过 Dart；
/// * **声明过的窗**（通话窗那颗 webrtc 媒体引擎，Dart 侧 `onCloseRequested` 会先
///   发一条 `guardClose`）：✕ 先回一条 `close_requested` 让 Dart 自己收摊，
///   收完它来叫 `close`；等不到就 [closeGraceSeconds] 秒后照样关。
///   没有这道兜底，那扇窗会**永远关不掉**（Windows 上真机踩过，见那边的注释）。
final class ChildWindowChannel: NSObject, NSWindowDelegate {
  /// 通道名（与 Dart 侧 `DesktopWindowNative._channel` 一致）
  static let channelName = "gracelinkim/child_window"

  /// 问过 Dart「你收不收摊」之后等多久算「它不打算答了」。
  ///
  /// 与 Windows 的 `kChildCloseGraceMs`（5000ms）同值：Dart 那边收摊本身是
  /// 3 秒封顶（见 `call_window.dart`），这里给得比它宽一点。
  static let closeGraceSeconds: TimeInterval = 5

  /// 挂过的每一扇窗。
  ///
  /// `NSWindow.delegate` 是**弱引用**，所以这份表还负责**持有**这些 handler；
  /// 按窗口对象记账，窗一关就把登记收掉（`NSWindow` 的对象会被系统复用）。
  private static var attached: [ObjectIdentifier: ChildWindowChannel] = [:]

  private let window: NSWindow
  private let channel: FlutterMethodChannel

  /// Dart 声明过「这扇窗的 ✕ 先交给我收摊」（`guardClose`）
  private var guarded = false

  /// 已经问过 Dart 一次了 —— 再按 ✕ 就是用户在催，安静等着（见 [windowShouldClose]）
  private var asked = false

  /// 已经在关了（`close` 与兜底定时器都会走到这里，只关一次）
  private var closing = false

  private var graceTimer: Timer?

  /// 给一扇刚建出来的子窗挂上这条通道。
  static func attach(to controller: FlutterViewController) {
    guard let window = controller.view.window else { return }
    let key = ObjectIdentifier(window)
    if attached[key] != nil { return }
    attached[key] = ChildWindowChannel(
      window: window,
      messenger: controller.engine.binaryMessenger
    )
  }

  private init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    self.channel = FlutterMethodChannel(
      name: ChildWindowChannel.channelName,
      binaryMessenger: messenger
    )
    super.init()

    // 子窗的 delegate 本来是空的（插件只设了 `isReleasedWhenClosed`），
    // 所以我们接过来不会跟谁打架 —— 只有接过来才拦得到 ✕。
    window.delegate = self

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: window
    )
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setTitle":
      guard let title = call.arguments as? String else {
        result(
          FlutterError(code: "bad_args", message: "setTitle 需要一个字符串", details: nil))
        return
      }
      window.title = title
      result(true)

    case "setSize":
      // 逻辑像素：macOS 上一个「点」就是 Dart 那边的一个逻辑像素，
      // 不需要像 Windows 那样按窗口所在显示器的 DPI 折算。
      guard let size = call.arguments as? [String: Any],
        let width = (size["w"] as? NSNumber)?.doubleValue,
        let height = (size["h"] as? NSNumber)?.doubleValue,
        width > 0, height > 0
      else {
        result(FlutterError(code: "bad_args", message: "setSize 需要一个 {w,h}", details: nil))
        return
      }
      window.setContentSize(NSSize(width: width, height: height))
      result(true)

    case "center":
      window.center()
      result(true)

    case "show":
      // 对一扇 `setIsVisible(false)` 的窗，`orderFront` 是不管用的，
      // 得先让它可见（插件建窗时就是藏着的）
      window.setIsVisible(true)
      window.makeKeyAndOrderFront(nil)
      ChildWindowChannel.activateApp()
      result(true)

    case "guardClose":
      guarded = true
      result(true)

    case "close":
      // 「我收完摊了，拆吧」：直接走销毁这条，不再回头去问 Dart
      //（否则两边你问我我问你就转不完了，与 Windows 那边的注释同一个理由）
      closeForReal()
      result(true)

    default:
      // 画中画小窗与拖窗（`setPip` / `dragBegin` / `dragUpdate` / `dragEnd`）
      // 是 Windows 专有的：这里如实回「不认识」，Dart 那边会退回没有小窗的版式，
      // 而不是假装成功（见 `DesktopWindowNative.setPip` 的返回约定）。
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - ✕

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closing { return true }

    // 没声明过要自己收摊的窗：✕ 就是关掉，直接放行给系统
    if !guarded { return true }

    if asked {
      // 又按了一下（用户不耐烦了）：Dart 那边收摊可能还在半路，这时候拆下去
      // 会把那颗引擎连着媒体一起拆 —— 安静地忽略，等它自己关
      return false
    }

    asked = true
    channel.invokeMethod("close_requested", arguments: nil)
    graceTimer = Timer.scheduledTimer(
      withTimeInterval: ChildWindowChannel.closeGraceSeconds,
      repeats: false
    ) { [weak self] _ in
      // 兜底：Dart 没答（或答了却没走完）也不能把这扇窗留在那儿点 ✕ 没反应
      self?.closeForReal()
    }
    return false
  }

  /// 真的把这扇窗关掉。
  ///
  /// **先把 `contentViewController` 置空**：那颗 `FlutterViewController`（连同它
  /// 那颗引擎）是挂在窗口上的，只 `close()` 的话窗口只是不可见、引擎会一直留着
  /// （一颗 ≈56MB）。置空之后 ARC 才会释放它 —— 与 Windows 那边「窗口和引擎
  /// 一起释放」同一个意思。
  private func closeForReal() {
    if closing { return }
    closing = true
    graceTimer?.invalidate()
    graceTimer = nil
    window.contentViewController = nil
    window.close()
  }

  @objc private func windowWillClose(_ notification: Notification) {
    graceTimer?.invalidate()
    graceTimer = nil
    ChildWindowChannel.attached[ObjectIdentifier(window)] = nil
  }

  /// 把 App 拉到前台（`activate(ignoringOtherApps:)` 在 macOS 14 起废弃）
  static func activateApp() {
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}
