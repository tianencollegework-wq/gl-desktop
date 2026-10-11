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
