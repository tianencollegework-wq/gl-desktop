import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// **macOS runner 那份配置的守卫**（2026-10-11 起 macOS 版开工）。
///
/// 这里钉住的四件事有同一个特点：**配错了不会让 `flutter analyze` / 编译报错，
/// 也不会让任何 Dart 用例变红** —— 只有真机（或者真用户）才会撞上，
/// 而那时我们已经发出去一个包了。所以直接读 `macos/` 下的源码/资源把它钉住
/// （与 `branding_test.dart` 读 `Runner.rc`、`desktop_window_min_size_test.dart`
/// 读 `win32_window.cpp` 是同一个路子）。
///
/// 逐条为什么会出错写在各 group 里。原始判断与后续待办见
/// `docs/release/macos-plan.md` 第六节。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 行尾统一成 `\n`：这几个文件在 Windows 上是 CRLF，写死 `\n` 的断言会全部落空
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// plist / entitlements 里所有的 `<key>…</key>` 名字
  Set<String> keysOf(String path) => RegExp(r'<key>([^<]+)</key>')
      .allMatches(read(path))
      .map((match) => match.group(1)!)
      .toSet();

  group('沙箱（entitlements）', () {
    const release = 'macos/Runner/Release.entitlements';
    const debug = 'macos/Runner/DebugProfile.entitlements';

    test('两份都必须有 network.client —— 没有它沙箱下连不出网', () {
      // Flutter 模板两份都没给这条：debug 里只有意思相反的 network.server
      //（那是给 VM service 的）。漏了它的症状是「本机 flutter run 好好的，
      // 打出来的包登录一直转圈」，从日志看不出所以然。
      for (final file in <String>[release, debug]) {
        expect(
          keysOf(file),
          contains('com.apple.security.network.client'),
          reason: '$file 少了沙箱联网许可（登录 / 收消息全都要它）',
        );
      }
    });

    test('Debug 那份 = Release 那份 + 两条调试专用的', () {
      // 只改一份的话会造出「本机跑得好好的、发出去连不上/存不了」这种最难查的组合
      final releaseKeys = keysOf(release);
      final debugKeys = keysOf(debug);
      const debugOnly = <String>{
        'com.apple.security.cs.allow-jit', // 调试要 JIT
        'com.apple.security.network.server', // VM service 要监听
      };
      expect(
        debugKeys.difference(releaseKeys),
        debugOnly,
        reason: 'Debug 比 Release 多的只能是这两条；其余必须一致',
      );
      expect(
        releaseKeys.difference(debugKeys),
        isEmpty,
        reason: 'Release 有的，Debug 也得有（否则调试时看不到真实行为）',
      );
    });

    test('只有这几条是我们有意加的（多出来的键要先去查清再放进来）', () {
      // 2026-10-15 刚查清的一个例子：屏幕共享在 Mac 上"看起来该加一条 screen-capture"，
      // 而 **Apple 的 entitlements 列表里没有那个写法** —— 普通屏幕捕获要的是人在
      // 「系统设置 → 隐私与安全性 → 屏幕录制」里那一下授权，插件自己会去请求
      //（flutter_webrtc 的 `requestCapturePermission` → `CGRequestScreenCaptureAccess`）。
      // 塞一个来源不明的键，结果是“以为配好了”、而真正的授权根本没要到。
      // 所以这里用白名单：想加新键，得先把它加到这份名单里并在上面写清为什么。
      const allowed = <String>{
        'com.apple.security.app-sandbox',
        'com.apple.security.network.client',
        'com.apple.security.device.camera',
        'com.apple.security.device.microphone',
        'com.apple.security.files.user-selected.read-write',
        'com.apple.security.files.downloads.read-write',
        'com.apple.security.personal-information.photos-library',
        // 这两条只有 Debug 那份有（见下一条用例）
        'com.apple.security.cs.allow-jit',
        'com.apple.security.network.server',
      };
      for (final file in <String>[release, debug]) {
        final extra = keysOf(file).difference(allowed);
        expect(
          extra,
          isEmpty,
          reason: '$file 里有没被认过、也没注理由的键：${extra.toList()..sort()}',
        );
      }
    });

    test('扫码/通话/存图那几条权限都在', () {
      final keys = keysOf(release);
      for (final key in <String>[
        'com.apple.security.device.camera', // 扫码登录、拍照发图、视频通话
        'com.apple.security.device.microphone', // 语音消息、语音/视频通话
        'com.apple.security.files.user-selected.read-write', // 用户选的发/存文件
        'com.apple.security.files.downloads.read-write', // 存到「下载」
        'com.apple.security.personal-information.photos-library', // 存到「照片」（gal）
      ]) {
        expect(keys, contains(key), reason: '$release 少了 $key');
      }
    });
  });

  group('Info.plist：系统弹权限框时要显示的那句话', () {
    test('相机 / 麦克风 / 照片那几条都在', () {
      // 缺了它们不是「被拒绝」，是**直接崩** —— TCC 里那条权限项是空字符串时
      // 系统会杀掉进程。
      final keys = keysOf('macos/Runner/Info.plist');
      for (final key in <String>[
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
        'NSPhotoLibraryAddUsageDescription',
        'NSPhotoLibraryUsageDescription', // gal 存到相簿那条
        'NSLocalNetworkUsageDescription', // 局域网内通话互相发现
      ]) {
        expect(keys, contains(key), reason: 'macos/Runner/Info.plist 少了 $key');
      }
    });

    test('版本号仍然跟着 pubspec 走（别写死）', () {
      final plist = read('macos/Runner/Info.plist');
      expect(plist, contains(r'$(FLUTTER_BUILD_NAME)'));
      expect(plist, contains(r'$(FLUTTER_BUILD_NUMBER)'));
    });
  });

  group('身份（bundle id）', () {
    test('不是模板占位的 com.example，且与安卓 applicationId 对齐', () {
      final xcconfig = read('macos/Runner/Configs/AppInfo.xcconfig');
      expect(
        xcconfig,
        isNot(contains('com.example')),
        reason: '模板占位的包名会出现在签名/安全对话框与「关于」上',
      );
      final bundleId = RegExp(
        r'PRODUCT_BUNDLE_IDENTIFIER = ([\w.\-]+)',
      ).firstMatch(xcconfig)?.group(1);
      expect(bundleId, isNotNull, reason: 'AppInfo.xcconfig 里找不到包名');

      // 安卓那份是真源（已经发出去过安装包）：macOS 必须跟着它
      final gradle = read('android/app/build.gradle.kts');
      final androidId = RegExp(
        r'applicationId = "([\w.\-]+)"',
      ).firstMatch(gradle)?.group(1);
      expect(androidId, isNotNull, reason: '安卓那份找不到 applicationId');
      expect(
        bundleId,
        androidId,
        reason: '同一个软件在不同平台上不该是两个身份',
      );
    });

    test('整个 macos/ 里没有一处还写着 com.example', () {
      final offenders = <String>[];
      for (final entity in Directory('macos').listSync(recursive: true)) {
        if (entity is! File) continue;
        // 二进制图标读成字符串没意义，也容易误报
        if (entity.path.endsWith('.png')) continue;
        if (!entity.readAsStringSync().contains('com.example')) continue;
        offenders.add(entity.path.replaceAll(r'\', '/'));
      }
      expect(
        offenders,
        isEmpty,
        reason: '这些文件里还留着模板占位包名：${offenders.join('、')}',
      );
    });
  });

  group('部署目标（能装的最低 macOS 版本）', () {
    // 2026-10-11 第一次 CI 构建就死在这条上，原文：
    //   error: The package product 'gal' requires minimum platform version 11.0
    //          for the macOS platform, but this target supports 10.15
    // Flutter 模板给的是 10.15，而 `gal`（存图到相簿那个包）要 11.0。
    // 这类错**本地永远看不见**（本机是 Windows，编不了 macOS），
    // 所以把下限钉在这里，改错了至少本地能拦住。
    test('三个配置是同一个下限，且不低于 11.0', () {
      final pbxproj = read('macos/Runner.xcodeproj/project.pbxproj');
      final targets = RegExp(r'MACOSX_DEPLOYMENT_TARGET = ([\d.]+);')
          .allMatches(pbxproj)
          .map((match) => match.group(1)!)
          .toList();
      expect(targets, isNotEmpty, reason: 'project.pbxproj 里找不到部署目标');
      expect(
        targets.toSet(),
        hasLength(1),
        reason:
            'Debug / Release / Profile 三份必须一致（实测是 $targets）：'
            '只改一份会造出「调试好好的、发出去起不来」，而这里看不见',
      );
      expect(
        double.parse(targets.first),
        greaterThanOrEqualTo(11.0),
        reason: 'gal 要求 macOS 11.0；写回 10.15 会在 xcodebuild 那一步直接失败',
      );
    });
  });

  group('AppIcon：必须是自家的标，不是 Flutter 默认那张', () {
    const dir = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
    const sizes = <int>[16, 32, 64, 128, 256, 512, 1024];

    test('七张都在、尺寸与 Contents.json 对得上', () {
      for (final size in sizes) {
        final file = File('$dir/app_icon_$size.png');
        expect(file.existsSync(), isTrue, reason: '缺 $dir/app_icon_$size.png');
      }
      // Contents.json 就是拿这七个文件名搭的；删一张 Xcode 会报错但不明显
      final contents = read('$dir/Contents.json');
      for (final size in sizes) {
        expect(contents, contains('app_icon_$size.png'));
      }
    });

    test('1024 那张：圆角底座 + 品牌蓝 + 白色图形 + 四角透明', () async {
      // 官网那次已经把「默认图标被当成自家 logo」踩过一次（见 BrandMark.astro）：
      // Flutter 默认那张是青色图形 + 四角透明，这里的判据刚好能把它挡掉。
      final stats = await _iconStats('$dir/app_icon_1024.png');
      expect(stats.transparentCorners, isTrue, reason: 'macOS 图标四角应当是透明的');
      expect(
        stats.brandBlueRatio,
        greaterThan(0.4),
        reason:
            '底座应当是那个品牌蓝（源图 tool/audit/icon-fg.png 实测 #008CFF，'
            '占画布的 80.47% 见方，扣掉圆角约 0.63）',
      );
      expect(
        stats.nearWhiteRatio,
        greaterThan(0.01),
        reason: '白色图形（鸽形）要在，纯色块不是我们的标',
      );
      expect(
        stats.opaqueRatio,
        inInclusiveRange(0.55, 0.70),
        reason: '图标本体是画布的 824/1024（扣圆角后约 0.63），铺满 = 尺寸规则错了',
      );
    });
  });

  /// 2026-10-15：把 macOS 缺的那几条**自家原生通道**补上（子窗 / 版本号 / 菜单栏）。
  ///
  /// 这一组钉的是「Dart 与 Swift 两边叫得不一样」这种错 —— 它**永远不会报错**：
  /// `DesktopWindowNative` 的每个调用都吞异常（非 Windows / 通道没注册就静默忽略），
  /// 所以少一个方法名、键拼错一个字母，现象只是「窗口永远不出现」「内部号永远是 0」，
  /// 而本机是 Windows，编不了 macOS，只能到 CI（或真用户）才发现。
  group('原生通道（child_window / app_info / tray）', () {
    /// `invokeMethod<void>('setTitle', …)` 这类调用里的方法名
    Set<String> dartInvoked(String source) => RegExp(
      r"invokeMethod(?:<[^>]*>)?\(\s*'([^']+)'",
    ).allMatches(source).map((match) => match.group(1)!).toSet();

    /// Swift 那边 `switch call.method` 里认的名字
    Set<String> swiftCases(String source) => RegExp(r'case "([^"]+)":')
        .allMatches(source)
        .map((match) => match.group(1)!)
        .toSet();

    test('子窗通道：Dart 调的每个方法 macOS 那边都实现了（画中画 / 拖窗除外）', () {
      final invoked = dartInvoked(
        read('lib/features/desktop_window/desktop_window_native.dart'),
      );
      expect(
        invoked,
        containsAll(<String>['setTitle', 'setSize', 'center', 'show', 'close']),
        reason: '方法名表是从 Dart 那侧扫出来的，扫不到就说明正则或写法变了',
      );
      final implemented = swiftCases(read('macos/Runner/ChildWindowChannel.swift'));

      // Windows 专有（画中画小窗与拖窗）：macOS 上如实回 NotImplemented，
      // Dart 那边靠 setPip 的 false 退回没有小窗的版式 —— 不算缺口
      const windowsOnly = <String>{
        'setPip',
        'dragBegin',
        'dragUpdate',
        'dragEnd',
      };
      expect(
        invoked.difference(windowsOnly).difference(implemented),
        isEmpty,
        reason: '这些方法 Dart 会调，而 macOS 那份没实现 —— 现象是窗口永远不 show',
      );
      expect(
        implemented.difference(invoked),
        isEmpty,
        reason: 'macOS 实现了一个 Dart 从不调的名字（多半是拼错了）',
      );
    });

    test('✕ 那条回调和两边叫同一个名字（close_requested）', () {
      expect(
        read('macos/Runner/ChildWindowChannel.swift'),
        contains('"close_requested"'),
        reason: 'macOS 不再问 Dart 就直接关：通话窗那颗媒体引擎会连着引擎一起被拆',
      );
      expect(
        read('lib/features/desktop_window/desktop_window_native.dart'),
        contains("'close_requested'"),
        reason: 'Dart 那边接的就是这个名字',
      );
    });

    test('子窗通道在**建出任何子窗之前**挂上（插件那个回调）', () {
      final window = read('macos/Runner/MainFlutterWindow.swift');
      expect(
        window,
        contains('setOnWindowCreatedCallback'),
        reason: '子窗是 hiddenAtLaunch 建的，没人叫它 show 就永远藏着',
      );
      expect(window, contains('ChildWindowChannel.attach'));
      expect(window, contains('FlutterMultiWindowPlugin'));
    });

    test('Runner 下每个 .swift 都进了 Xcode 工程的编译清单', () {
      // 新增 Swift 忘了加进 target：本机报不出来（编不了 macOS），
      // 到 CI 才变成「找不到符号」，而且那时已经推上去了
      final pbxproj = read('macos/Runner.xcodeproj/project.pbxproj');
      final swiftFiles = Directory('macos/Runner')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.swift'))
          .map((file) => file.uri.pathSegments.last)
          .toList();
      expect(swiftFiles, isNotEmpty, reason: 'macos/Runner 下一个 .swift 都没读到');
      for (final file in swiftFiles) {
        expect(
          pbxproj,
          contains('/* $file in Sources */'),
          reason: '$file 没进 pbxproj 的 Sources build phase',
        );
      }
    });

    test('版本号：macOS 那份回的键与 Dart 读的键对齐', () {
      final swift = read('macos/Runner/AppInfoChannel.swift');
      expect(swift, contains('gracelinkim/app_info'));
      expect(swift, contains('"version"'), reason: 'Dart 调的是 version');
      expect(swift, contains('"name"'));
      expect(swift, contains('"code"'));
      expect(
        read('lib/core/platform/app_version.dart'),
        contains('gracelinkim/app_info'),
        reason: '通道名两边得一模一样',
      );
    });

    test('菜单栏：Dart 递的三个键 macOS 那边都接、且关窗行为有闸门', () {
      final swift = read('macos/Runner/TrayIcon.swift');
      final dart = read('lib/features/desktop_window/tray_native.dart');
      expect(swift, contains('gracelinkim/tray'));
      for (final key in <String>['open', 'exit', 'balloon']) {
        expect(dart, contains("'$key'"), reason: 'Dart 递过去的键少了 $key');
        expect(swift, contains('"$key"'), reason: 'macOS 那边没接 $key');
      }
      // 「关窗缩回后台」必须守在图标建起来之后 —— 否则用户关掉窗口就叫不回来了
      expect(read('macos/Runner/MainFlutterWindow.swift'),
          contains('TrayIcon.shared.isReady'));
      expect(read('macos/Runner/AppDelegate.swift'),
          contains('TrayIcon.shared.isReady'));
    });
  });
}

/// 一张图里我们关心的几个比例（与 `branding_test.dart` 的 `_stats` 同一个手法）
Future<
  ({
    double opaqueRatio,
    double brandBlueRatio,
    double nearWhiteRatio,
    bool transparentCorners,
  })
>
_iconStats(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final image = (await codec.getNextFrame()).image;
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

  var opaque = 0, blue = 0, white = 0;
  final total = image.width * image.height;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final i = (y * image.width + x) * 4;
      final r = data.getUint8(i),
          g = data.getUint8(i + 1),
          b = data.getUint8(i + 2),
          a = data.getUint8(i + 3);
      if (a <= 8) continue;
      opaque++;
      // 底座实测 #008CFF（0,140,255）；缩放会带一点色偏，判据放宽成「亮蓝」。
      // 这条够特：Flutter 默认那张标铺不开这个比例（它的不透明面积小得多）
      if (r < 130 && g >= 100 && g <= 200 && b > 200) blue++;
      if (r > 235 && g > 240 && b > 245) white++;
    }
  }
  int alphaAt(int x, int y) => data.getUint8((y * image.width + x) * 4 + 3);
  final corners = <int>[
    alphaAt(0, 0),
    alphaAt(image.width - 1, 0),
    alphaAt(0, image.height - 1),
    alphaAt(image.width - 1, image.height - 1),
  ];
  image.dispose();
  return (
    opaqueRatio: opaque / total,
    brandBlueRatio: blue / total,
    nearWhiteRatio: white / total,
    transparentCorners: corners.every((alpha) => alpha <= 8),
  );
}
