import FlutterMacOS
import Foundation

/// `gracelinkim/app_info`：本机**版本名 + 内部号**（Dart 侧
/// `lib/core/platform/app_version.dart` 读它，「检查更新」拿这两样跟服务端清单比）。
///
/// 为什么要这条（与 Windows 那边同一个理由，见
/// `windows/runner/flutter_window.cpp` 的 `RegisterAppInfoChannel`）：在这之前只有
/// 安卓有实现（`MainActivity.kt` 走 PackageManager），桌面端调用会抛
/// `MissingPluginException`，Dart 侧退回「常量兜底」—— 于是报给「检查更新」的
/// **内部号永远是 0**，只能靠版本名去凑。
///
/// 数据来源是 `Info.plist` 里那两个由 Flutter 展开的键
/// （`$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`，已经有用例钉着它们还在，
/// 见 `test/core/macos_runner_test.dart`「版本号仍然跟着 pubspec 走」）：
/// 好处是不用再从 CMake / 工程里另传一份版本进来，`pubspec.yaml` 仍是唯一来源。
///
/// Windows 那份读的是编译期宏（CMake 递进来的 `FLUTTER_VERSION`），两边取到的
/// 都是发版时 pubspec 里那一个值。
enum AppInfoChannel {
  static let channelName = "gracelinkim/app_info"

  /// 攒着这些通道：Flutter 那边只留处理函数，对象本身得我们持有
  /// （与 Windows runner 里那个 `g_app_info_channels` 同一个做法）
  private static var channels: [FlutterMethodChannel] = []

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: AppInfoChannel.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "version" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let info = Bundle.main.infoDictionary
      let name = (info?["CFBundleShortVersionString"] as? String) ?? ""
      let code = Int((info?["CFBundleVersion"] as? String) ?? "") ?? 0
      if name.isEmpty {
        // 读不到就说读不到：Dart 那边会退回常量兜底并在日志里记一笔，
        // 不要回一个「看起来对」的假版本号
        result(
          FlutterError(
            code: "-1",
            message: "Info.plist 里没有 CFBundleShortVersionString",
            details: nil
          ))
        return
      }
      result(<String, Any>["name": name, "code": code])
    }
    channels.append(channel)
  }
}
