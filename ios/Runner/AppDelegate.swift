import AVFAudio
import AVFoundation
import Flutter
import UIKit
import UserNotifications

/// iOS 的入口，同时是**我们自己的那几条平台通道**的实现处。
///
/// 为什么都挤在这一个文件里：iOS 加一个新的 .swift 文件必须同时改
/// `Runner.xcodeproj/project.pbxproj`（PBXFileReference + PBXBuildFile +
/// Sources 那一相），而本机没有 Xcode，改坏一个字符的代价是「工程都打不开」。
/// 这份文件已经在工程里了，所以原生代码先落在这里 —— 真长出第二个文件的时候，
/// 记得是「改工程」而不是「多拷一份」。
///
/// 与安卓的分工（`android/.../MainActivity.kt` 是那边对应的那份）：
///
/// | 通道 | 安卓怎么做 | iOS 怎么做 |
/// |---|---|---|
/// | `gracelinkim/app_info` | `PackageManager` 读版本 | `Bundle` 读版本 |
/// | `gracelinkim/permissions` | `ActivityCompat` 查/申请 | `AVCaptureDevice` + `AVAudioApplication` + `UNUserNotificationCenter` |
/// | `gracelinkim/app_settings` | 跳应用详情页 / 通知设置页 / 电池优化 | 只有 `openSettingsURLString` 一条路（iOS 没有更细的页面） |
/// | `gracelinkim/call_service` | **前台服务**（常驻通知 + 类型位） | **后台音频会话**（`UIBackgroundModes: audio` + 一条活着的 `AVAudioSession`） |
/// | `gracelinkim/pip` / `call_window` | 系统画中画 / 盖锁屏 | **没有**（iOS 走 CallKit，那是买号之后的下一步，见 docs/release/ios-plan.md） |
///
/// Dart 侧跟着改的地方：`lib/core/platform/`（call_keep_alive / background_health）。
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 我们自己的通道走 `applicationRegistrar` —— 引擎专门给了它一条
    // 「应用级通道」的路（`pluginRegistry` 那份是给插件的：借它注册我们自己的东西，
    // 会在插件表里留下一个并不存在的插件，排查冲突时很有迷惑性）。
    //
    // 顺序：插件注册完再挂我们自己的。插件里有碰 AVAudioSession 的
    // （flutter_webrtc），先把它们的初始化走完再让人碰会话，少一类竞态。
    GracelinkPlatform.register(with: engineBridge.applicationRegistrar.messenger())
  }
}

// MARK: - 平台通道

/// 我们自己的三条通道（+ 通话音频会话）。方法名与安卓那份**逐字对齐**：
/// 两边差一个字，Dart 侧拿到的就是 `MissingPluginException` —— 而那在
/// `app_permissions.dart` 这类地方会被收成「平台不支持」，于是功能静默消失。
enum GracelinkPlatform {
  static func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "gracelinkim/app_info", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        handleAppInfo(call, result)
      }
    FlutterMethodChannel(name: "gracelinkim/permissions", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        handlePermissions(call, result)
      }
    FlutterMethodChannel(name: "gracelinkim/app_settings", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        handleAppSettings(call, result)
      }
    FlutterMethodChannel(name: "gracelinkim/call_service", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        handleCallService(call, result)
      }
  }

  // MARK: 版本号（lib/core/platform/app_version.dart）

  private static func handleAppInfo(_ call: FlutterMethodCall, _ result: FlutterResult) {
    switch call.method {
    case "version":
      let info = Bundle.main.infoDictionary ?? [:]
      // CFBundleShortVersionString = pubspec 里 `version:` 加号前那一半（1.0.1），
      // CFBundleVersion = 加号后那一半（261013）—— 与安卓那条通道同一个形状：
      // 检查更新上报的就是这两个值。
      let name = info["CFBundleShortVersionString"] as? String ?? ""
      let raw = info["CFBundleVersion"] as? String ?? ""
      result(["name": name, "code": Int(raw) ?? 0])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 运行时权限（lib/core/platform/app_permissions.dart）

  /// 与安卓那份同一套语义：
  /// * `check` —— **只查，绝不弹框**；
  /// * `request` —— 差什么问一次；用户已经拒过的（系统不会再弹）回
  ///   `permanentlyDenied`，Dart 那边据此停止空跑、改成指路系统设置；
  /// * 不认识的名字回 `unsupported`（Dart 侧当「不需要」，绝不误拦）。
  ///
  /// ⚠️ `result` 上的 `@escaping` 是必需的，不是修饰：这几条通道都是**异步回复**的
  /// （权限框、通知设置页、`requestAuthorization` 的回调），而 Swift 里函数的闭包
  /// 参数**默认非逃逸** —— 把非逃逸参数塞进逃逸闭包，编译器报
  /// `Passing non-escaping parameter 'result' to function expecting an @escaping closure`。
  /// 2026-10-14 的 iOS 首编就死在这一条上（AppDelegate.swift:106），而本机没有 Mac，
  /// 只能等 CI 那台机器编一遍才知道 —— 下面四个带 `@escaping` 的地方是同一处病根。
  private static func handlePermissions(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    guard let arguments = call.arguments as? [String: Any],
          let names = arguments["names"] as? [String] else {
      result(FlutterError(code: "bad_args", message: "缺少 names", details: nil))
      return
    }
    let shouldRequest = call.method == "request"
    guard call.method == "check" || shouldRequest else {
      result(FlutterMethodNotImplemented)
      return
    }
    queryPermissions(names: names, request: shouldRequest, result: result)
  }

  private static func queryPermissions(
    names: [String],
    request: Bool,
    result: @escaping FlutterResult
  ) {
    // 三个查询里有的是异步回调、有的同步返回，凑齐了再回一次话 ——
    // 安卓那条通道也是「一次调用回一整张表」（多问几次也没意义）。
    let group = DispatchGroup()
    let lock = NSLock()
    var states: [String: String] = [:]

    func put(_ name: String, _ state: String) {
      lock.lock()
      states[name] = state
      lock.unlock()
    }

    for name in names {
      switch name {
      case "camera":
        // 摄像头：授权框只能由原生弹（Dart 拿不到 AVCaptureDevice）。
        // 与麦克风同一条规矩：只有 `notDetermined` 才值得弹，已经拒过的
        // 再调 requestAccess 也是白调（系统静默回 false、不会再弹框）。
        group.enter()
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        if request, camera == .notDetermined {
          AVCaptureDevice.requestAccess(for: .video) { granted in
            put(name, granted ? "granted" : "permanentlyDenied")
            group.leave()
          }
        } else {
          put(
            name,
            camera == .authorized ? "granted" : (request ? "permanentlyDenied" : "denied"))
          group.leave()
        }

      case "microphone":
        group.enter()
        switch microphoneState() {
        case "granted":
          put(name, "granted")
          group.leave()
        case "undetermined" where request:
          requestMicrophone { granted in
            put(name, granted ? "granted" : "permanentlyDenied")
            group.leave()
          }
        case "undetermined":
          // 还没问过 = 还没授权：`check` 要按「没拿到」报，启动那一步才会去申请
          put(name, "denied")
          group.leave()
        default:
          // 用户已经拒过一次：iOS 不会再弹框（与安卓第二次拒绝之后一样）
          put(name, request ? "permanentlyDenied" : "denied")
          group.leave()
        }

      case "notifications":
        group.enter()
        notificationState { state in
          switch state {
          case "granted":
            put(name, "granted")
            group.leave()
          case "undetermined" where request:
            requestNotifications { granted in
              put(name, granted ? "granted" : "permanentlyDenied")
              group.leave()
            }
          case "undetermined":
            // `check` 那一下：还没问过 = 还没授权（启动那一步才会去申请）
            put(name, "denied")
            group.leave()
          default:
            // 已经拒过：系统不会再弹框
            put(name, request ? "permanentlyDenied" : "denied")
            group.leave()
          }
        }

      default:
        put(name, "unsupported")
      }
    }

    group.notify(queue: .main) {
      result(states)
    }
  }

  // MARK: 系统设置页（lib/core/platform/app_settings.dart / background_health.dart）

  private static func handleAppSettings(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    switch call.method {
    case "openAppSettings", "openNotificationSettings":
      // iOS 没有「本应用的通知设置」这种深链，能到的最深处就是本应用的设置页
      // （通知、麦克风、相机、照片都在那一页里）。安卓那边是两个不同的页面，
      // 这边合成一个 —— 多跳一步总比跳到不存在的页面强。
      openAppSettings(result: result)

    case "notificationPermission":
      notificationState { state in
        result(state == "granted")
      }

    case "isIgnoringBatteryOptimizations":
      // iOS 没有「电池优化白名单」这回事：后台能不能干活由
      // `UIBackgroundModes`（Info.plist 里已声明 audio / remote-notification）
      // 与音频会话决定。恒 true = 不撑起那条红提示条（它的文案是安卓那套）。
      result(true)

    case "requestIgnoreBatteryOptimizations",
         "openFullScreenIntentSettings":
      // 这两条在 iOS 上没有对应的系统页面：回 false = 没跳成（调用方只是不弹提示）
      result(false)

    case "fullScreenIntentAllowed":
      // 安卓 14 那个「全屏通知」开关在 iOS 上不存在 —— 来电界面是我们自己画的
      // （CallKit 那条路以后再说）。恒 true = 不在拨号前弹那句提醒。
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }
    }
  }

  // MARK: 通话期间的后台音频（lib/core/platform/call_keep_alive.dart）

  /// iOS 的**通话保活**：不是前台服务，而是「一条活着且正在用的音频会话」。
  ///
  /// 规则就一条：`UIBackgroundModes: audio` + 处于 active 的
  /// `AVAudioSession(playAndRecord)` ⇒ 系统不会把进程冻住，麦克风也一直在。
  /// 所以这里要做的不是「起服务」，而是**在通话开始时把会话设好并激活**、
  /// **结束时关掉**（不关的话别的播放器起不来，而且麦克风指示灯一直亮着）。
  ///
  /// 分类与模式照 WebRTC 那套来（`flutter_webrtc` 的 AudioUtils 也是这么设的），
  /// 免得两边来回改同一份会话设置：
  /// * 语音通话 → `.playAndRecord` + `.voiceChat`（回声消除那条路）
  /// * 视频通话 → 同一个分类 + `.videoChat`
  /// * 选项里带上蓝牙（耳机通话）与外放（视频通话默认外放，与安卓一致）
  private static func handleCallService(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      // title / text 在 iOS 上没有用（那是安卓常驻通知里的文案），收下不报错
      let video = arguments["video"] as? Bool ?? false
      do {
        try CallAudioSession.shared.start(video: video)
        result(nil)
      } catch {
        CallAudioSession.shared.remember(error)
        // Dart 侧会把它翻成 CallKeepAliveException 记进诊断面板，
        // **通话继续**（保活失败不该掐断一通电话）
        result(
          FlutterError(
            code: "audio_session",
            message: error.localizedDescription,
            details: nil))
      }

    case "stop":
      CallAudioSession.shared.stop()
      result(nil)

    case "isRunning":
      result(CallAudioSession.shared.active)

    case "lastError":
      // 诊断面板那一行「前台服务：…」在 iOS 上说到底是哪一步没成
      result(CallAudioSession.shared.lastError ?? "")

    case "notificationPermission":
      notificationState { state in
        result(state == "granted")
      }

    case "requestNotificationPermission":
      requestNotifications { granted in
        result(granted)
      }

    default:
      // screenSharing / foregroundTypes：iOS 上**故意没有**这两条
      // （投屏要 ReplayKit 的广播扩展，会话类型位是安卓前台服务才有的东西）。
      // 回 notImplemented 而不是假装成功 —— 谁真调到了就该在日志里露出来。
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - 通话音频会话

/// 通话期间那条活着的音频会话（见 [GracelinkPlatform.handleCallService]）。
///
/// 单例：`AVAudioSession` 本身是**进程级**的，通话页与群通话页会先后动它，
/// 各自持一份状态必然对不上（谁最后 setActive(false) 谁说了算）。
final class CallAudioSession {
  static let shared = CallAudioSession()

  private init() {}

  /// 会话此刻**真的**活着吗 —— 通道里 isRunning 报出去的就是它。
  private(set) var active = false
  private(set) var lastError: String?

  /// 「这通电话还在进行中吗」：由 start / stop 改，系统事件不会动它。
  ///
  /// 为什么与 [active] 分开记：系统（来电、闹钟、Siri、别的应用抢喇叭）会把我们的
  /// 会话**顶掉**，那一刻会话确实死了、可通话并没有结束。合成一个值只能二选一：
  /// 要么中断期间 isRunning 撒谎说「在跑」（诊断面板显示一切正常、用户那边早就
  /// 没声音了），要么中断结束后永远不恢复。分开记，两件事才都能做对。
  private var wanted = false

  /// 这通是语音还是视频：中断恢复时要按**同一份**分类重设
  private var video = false

  /// 系统事件的观察者（第一通电话挂上、挂断时摘掉）
  private var observers: [NSObjectProtocol] = []

  func remember(_ error: Error) {
    lastError = error.localizedDescription
  }

  func start(video: Bool) throws {
    self.video = video
    wanted = true
    observeSystemEvents()
    try apply()
    active = true
    lastError = nil
    NSLog("[保活] 音频会话已激活（video=\(video)）")
  }

  /// 设分类 + 激活。**只有这一处**做这两步（start 与「中断恢复」「媒体服务重启」都走它）。
  ///
  /// 为什么强调共用：恢复时少设一样东西（比如掉了 defaultToSpeaker），表现就是
  /// 「被电话打断一次之后，视频通话不再外放了」—— 这种错只有真机能发现，而两份
  /// 各写一遍的代码正是它的温床。
  private func apply() throws {
    let session = AVAudioSession.sharedInstance()
    let mode: AVAudioSession.Mode = video ? .videoChat : .voiceChat
    // 已授权里给上蓝牙耳机与「视频默认外放」；这两条只有 playAndRecord 分类认。
    let options: AVAudioSession.CategoryOptions = [
      .allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker,
    ]
    try session.setCategory(.playAndRecord, mode: mode, options: options)
    try session.setActive(true)
  }

  func stop() {
    // 先记下「这通结束了」：中断恢复那条路正是按它判断还要不要再激活
    wanted = false
    removeObservers()
    guard active else { return }
    active = false
    do {
      // notifyOthersOnDeactivation：把我们打断的别的应用（音乐、播客）还回去，
      // 不这么做的话通话结束后那些应用会一直停着。
      try AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
      NSLog("[保活] 音频会话已关闭")
    } catch {
      // 关不掉只影响「别人能不能接着放」，通话本身已经结束了：记一行就够
      remember(error)
      NSLog("[保活] 关闭音频会话失败：\(error.localizedDescription)")
    }
  }

  // MARK: 系统事件（中断 / 媒体服务重启）

  /// 挂上观察者。**幂等**：连着打第二通电话时不会再挂一遍（那样会收到重复回调）。
  private func observeSystemEvents() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
      ) { [weak self] notification in
        self?.handleInterruption(notification)
      })
    observers.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleMediaServicesReset()
      })
  }

  private func removeObservers() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }

  /// 会话被系统打断（来电 / 闹钟 / Siri / 别的应用抢喇叭）时系统只通知我们，
  /// **恢复要自己来**：中断结束后按「通话还在不在」决定要不要重设并重新激活。
  private func handleInterruption(_ notification: Notification) {
    guard
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }

    switch type {
    case .began:
      // 会话被系统拿走了：状态必须**如实**变成「没在跑」。
      // 说「在跑」而实际没声音，是比「没跑」难查得多的一种假象。
      active = false
      lastError = "系统打断了音频会话（来电 / 闹钟 / 其它应用）"
      NSLog("[保活] 音频会话被打断（通话仍在进行）")

    case .ended:
      // shouldResume 只在系统认为「该接着用」时才给（电话已挂断、Siri 插了一句就完）
      let options = AVAudioSession.InterruptionOptions(
        rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      )
      guard wanted, options.contains(.shouldResume) else { return }
      do {
        try apply()
        active = true
        lastError = nil
        NSLog("[保活] 中断结束，音频会话已恢复")
      } catch {
        remember(error)
        NSLog("[保活] 中断结束后恢复失败：\(error.localizedDescription)")
      }

    @unknown default:
      break
    }
  }

  /// 媒体服务被系统整个重启（极少见，一旦发生，所有音频对象都失效、会话被清空）。
  /// 通话还在的话按原样重设一遍，否则这通电话会变成「一边听得见、一边听不见」。
  private func handleMediaServicesReset() {
    guard wanted else { return }
    do {
      try apply()
      active = true
      lastError = nil
      NSLog("[保活] 媒体服务重启后已重设音频会话")
    } catch {
      remember(error)
      NSLog("[保活] 媒体服务重启后重设失败：\(error.localizedDescription)")
    }
  }
}

// MARK: - 权限查询的小工具

/// 麦克风当前状态：`granted` / `undetermined`（还没问过）/ `denied`。
///
/// 「还没问过」必须与「拒了」分开报，否则启动那一步永远不知道该不该弹框：
/// iOS 与安卓一样，用户拒过一次之后系统就不再弹了。
///
/// iOS 17 起 `AVAudioSession.recordPermission` 被 `AVAudioApplication` 取代；
/// 两个都写、用 #available 分开，是因为最低版本是 15.0（旧机器也要能跑）。
/// 这里只写字面量 `.granted` / `.undetermined`，不写类型名 —— 两个 SDK 里
/// 那个嵌套枚举的 Swift 名字不一样，写死类型名在其中一个上就编不过。
private func microphoneState() -> String {
  if #available(iOS 17.0, *) {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return "granted"
    case .undetermined: return "undetermined"
    default: return "denied"
    }
  }
  switch AVAudioSession.sharedInstance().recordPermission {
  case .granted: return "granted"
  case .undetermined: return "undetermined"
  default: return "denied"
  }
}

/// 弹一次麦克风授权框（只在「还没问过」时调用才有意义）
private func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
  if #available(iOS 17.0, *) {
    AVAudioApplication.requestRecordPermission { granted in
      completion(granted)
    }
  } else {
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      completion(granted)
    }
  }
}

/// 通知权限当前状态：`granted` / `undetermined`（还没问过）/ `denied`。
/// **只查，不弹框。**
///
/// 三种状态都报出来（而不是先压成「开/没开」再回头猜）是因为「要不要弹框」
/// 完全由 `undetermined` 决定：用户拒过一次之后，`requestAuthorization`
/// 只会立刻回 false，不再弹任何框。
///
/// `.provisional`（安静推送）与 `.ephemeral`（App Clip）也算「开着」：
/// 那两种状态下通知是会显示出来的。
///
/// 全是异步回调、**不要在这里等**（平台通道的处理器跑在主线程上，
/// 拿信号量去等一个回调，轻则卡一帧、重则死锁）。
private func notificationState(_ completion: @escaping (String) -> Void) {
  UNUserNotificationCenter.current().getNotificationSettings { settings in
    let state: String
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      state = "granted"
    case .notDetermined:
      state = "undetermined"
    default:
      state = "denied"
    }
    // 苹果这个回调不在主线程上，而平台通道的**回复只能在主线程发**
    // （Flutter 那边会断言）。调这一步的小成本远比「偶发崩一下」划算。
    DispatchQueue.main.async { completion(state) }
  }
}

/// 弹一次通知授权框。已经问过的（authorized / denied）**不会再弹** ——
/// 那种情况下这个调用只是把当前状态如实回上去。
private func requestNotifications(_ completion: @escaping (Bool) -> Void) {
  UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
    granted, error in
    if let error = error {
      NSLog("[权限] 申请通知权限失败：\(error.localizedDescription)")
    }
    // 同上：回调不在主线程，回复要回主线程发
    DispatchQueue.main.async { completion(granted) }
  }
}
