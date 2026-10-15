import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **iOS 那份配置与原生实现的守卫**（2026-10-14 起 iOS 版开工）。
///
/// 为什么非要有它：iOS 版**本机编不出来** —— 开发机是 Windows（`flutter build ios`
/// 只能在 macOS 上跑），而 12 月买号之前连 CI 都还没有签名可用。也就是说，
/// 这里配错任何一条，反馈周期是「等到第一次上 Xcode」——那时已经过去一个多月了。
/// 所以照 `macos_runner_test.dart` 那个路子：**直接读文件把它钉住**。
///
/// 钉的都是「配错了不会让 `flutter analyze` / 任何 Dart 用例变红，只有真机
/// （或者真用户）才撞上」的那几样：
/// * 权限文案缺一条 → **进程直接崩**（不是「拒绝了」）；
/// * 少一个 `UIBackgroundModes` → 切后台就断线，而日志里什么都没说；
/// * 包名还是 `com.example.*` → 签名、推送、后台的 `update.json` 全都要重来；
/// * `IPHONEOS_DEPLOYMENT_TARGET` 低于插件的下限 → Xcode 第一条错误就是它；
/// * 通道方法名与 Dart 侧对不上 → 功能**静默消失**（`MissingPluginException`
///   在 `app_permissions.dart` 那类地方被收成「平台不支持」）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 行尾统一成 `\n`：这些文件在 Windows 上是 CRLF，写死 `\n` 的断言会全部落空
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  // ── 够用的 plist 读取（string / true / false / string 数组）──────────────
  // 不引 xml 依赖：这里只要那几种写法，正则比拉一个包便宜。
  //
  // ⚠️ 先把 XML 注释整段去掉再匹配：这批文件里几乎每个 key 前面都有一大段
  // 「为什么是它」的注释，不剥掉的话 `<key>X</key>\s*<value/>` 全部落空 ——
  // 而且注释里恰恰会提到我们要断言的东西（比如「真要开某个域名得加
  // NSExceptionDomains」），拿原文去 contains 也会误判。
  String readPlist(String path) =>
      read(path).replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  // ⚠️ 正则一律写成 **raw 字符串**（`r'...'`）：普通字符串里的 `\s` 会被 Dart
  // 当成转义序列吃掉，`\s*` 变成 `s*` —— 正则于是去找一个真的字母 s，
  // 而且**不报错**：断言只会莫名其妙地拿到 null。（这个坑当场踩过一次。）
  String? plistString(String path, String key) => RegExp(
    r'<key>'
    '$key'
    r'</key>\s*<string>([^<]*)</string>',
  ).firstMatch(readPlist(path))?.group(1);

  bool? plistBool(String path, String key) {
    final match = RegExp(
      r'<key>'
      '$key'
      r'</key>\s*<(true|false)/>',
    ).firstMatch(readPlist(path));
    return match == null ? null : match.group(1) == 'true';
  }

  List<String> plistStrings(String path, String key) {
    final match = RegExp(
      r'<key>'
      '$key'
      r'</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(readPlist(path));
    if (match == null) return const <String>[];
    return RegExp(
      '<string>([^<]*)</string>',
    ).allMatches(match.group(1)!).map((entry) => entry.group(1)!).toList();
  }

  const info = 'ios/Runner/Info.plist';
  const swift = 'ios/Runner/AppDelegate.swift';
  const pbxproj = 'ios/Runner.xcodeproj/project.pbxproj';
  const entitlements = 'ios/Runner/Runner.entitlements';

  group('Info.plist：权限文案', () {
    test('五条文案一条都不能少，而且不能是空字符串', () {
      // 缺了它们 iOS 不是「静默拒绝」，是**进程当场崩**（与 macOS 那份同一个坑）。
      // 值里带「中文 / English」是仓库里的惯例（plist 放不下两种语言）。
      const keys = <String>[
        'NSCameraUsageDescription', // 扫码、拍照、视频通话
        'NSMicrophoneUsageDescription', // 语音消息、通话
        'NSPhotoLibraryUsageDescription', // 存图到相册（gal）
        'NSPhotoLibraryAddUsageDescription', // 只往相册里写
        'NSLocalNetworkUsageDescription', // 局域网内通话（WebRTC）
      ];
      for (final key in keys) {
        final value = plistString(info, key);
        expect(value, isNotNull, reason: '$info 少了 $key（iOS 上会直接崩）');
        expect(value!.trim(), isNotEmpty, reason: '$key 是空字符串 —— 等于没写');
        // 仓库惯例：中文在前、英文跟在后面（plist 只能放一句，不做多语言）
        expect(value, matches(RegExp(r'[\u4e00-\u9fff]')), reason: '$key 缺中文');
        expect(value, matches(RegExp(r'[A-Za-z]')), reason: '$key 缺英文');
      }
    });
  });

  group('Info.plist：后台与合规那几条', () {
    test('后台模式必须有 voip（CallKit 那条路的硬要求），且不多不少', () {
      // 2026-10-15：CallKit + PushKit 上来了，这一条从「故意没有 voip」**翻过来**。
      //
      // `voip` 管的是「App 已经被划掉之后，别人打电话还能把你叫醒」—— 缺了它
      // PushKit 就收不到 VoIP 推送，而那种失败在客户端是**静默的**（推送不来而已，
      // 没有任何报错），所以它必须被钉住。
      // 依据：苹果的 Configuring background execution modes 里列着 Voice over IP → voip；
      // 网上「iOS 13 之后不用声明了」是把两件事搞混 —— iOS 13 改的是「收到 VoIP 推送
      // 必须**立刻**报给 CallKit」，不是取消这个后台模式。
      expect(plistStrings(info, 'UIBackgroundModes'), <String>[
        'audio',
        'remote-notification',
        'voip',
      ]);
    });

    test('出口合规答 false（不答或答 true 都会让每次上传多一道手续）', () {
      expect(plistBool(info, 'ITSAppUsesNonExemptEncryption'), isFalse);
    });

    test('ATS 只放开局域网，公网明文 http 依旧不行', () {
      expect(plistBool(info, 'NSAllowsLocalNetworking'), isTrue);
      // 这两条一开就等于「所有明文都放行」：真要开某个域名得写 NSExceptionDomains，
      // 而不是把整扇门拆掉。（判 key 而不是 contains —— 注释里会提到它们。）
      final plist = readPlist(info);
      expect(plist, isNot(contains('<key>NSAllowsArbitraryLoads</key>')));
      expect(plist, isNot(contains('<key>NSExceptionDomains</key>')));
    });

    test('canOpenURL 白名单里有 tel 与 app-settings', () {
      // url_launcher 的 iOS 实现里 `canLaunchUrl` 走的就是这份清单，
      // 没列的 scheme 会被直接判成「打不开」= 点一下什么都不发生。
      // 我们真的会用到的两条：打电话（user_detail_page）、去系统设置（app_settings）。
      final schemes = plistStrings(info, 'LSApplicationQueriesSchemes');
      expect(schemes, containsAll(<String>['tel', 'app-settings']));
    });

    test('七种语言都要声明，而且与 assets/i18n 下的语言包一一对应', () {
      // iOS **只看 Info.plist**：不写这一段，用户在「设置 › 通用 › 语言与地区 › App」
      // 里根本看不到 Gracelink，系统也不会替应用切语言。
      final declared = plistStrings(info, 'CFBundleLocalizations');
      final shipped = Directory('assets/i18n')
          .listSync()
          .where((entry) => entry.path.endsWith('.json'))
          .map((entry) => entry.path.split(RegExp(r'[/\\]')).last)
          .map((name) => name.substring(0, name.length - '.json'.length))
          .toSet();
      expect(declared.toSet(), shipped, reason: '多声明与少声明都会出问题');
    });
  });

  group('签名身份（entitlements / 包名 / 最低系统）', () {
    test('推送那条 entitlement 在，值是 development（发布时由描述文件覆盖成 production）', () {
      expect(plistString(entitlements, 'aps-environment'), 'development');
    });

    test('三份构建配置都接上了 entitlements（少了哪一份，那一份就没有推送）', () {
      final project = read(pbxproj);
      expect(
        RegExp(
          r'CODE_SIGN_ENTITLEMENTS = Runner/Runner\.entitlements;',
        ).allMatches(project).length,
        3,
        reason: 'Debug / Release / Profile 三份都要接（与 macOS 那份同一个路子）',
      );
      expect(File(entitlements).existsSync(), isTrue);
    });

    test('包名是 cc.gracelink.im，与 macOS 那份**同一个身份**', () {
      final project = read(pbxproj);
      expect(
        RegExp(
          r'PRODUCT_BUNDLE_IDENTIFIER = cc\.gracelink\.im;',
        ).allMatches(project).length,
        3,
      );
      // RunnerTests 那个 target 另写一份（跟着一起改，别只改一半）
      expect(project, contains('cc.gracelink.im.RunnerTests'));
      expect(
        project,
        isNot(contains('com.example')),
        reason: 'Flutter 模板留下的包名：留着它就没法签名（Apple 不认 com.example）',
      );
      // 与 macOS 对齐：同一个 App ID、同一张开发者票
      expect(
        read('macos/Runner/Configs/AppInfo.xcconfig'),
        contains('cc.gracelink.im'),
      );
    });

    test('最低系统 ≥ 15.0（firebase_core / firebase_messaging 的下限）', () {
      // 低于它会怎样：Xcode 第一条错误才是「xxx requires a higher minimum
      // deployment target」—— 而本机看不到，CI 上要跑一遍才知道。
      // 复核用 `node tool/audit/ios_support.js`（它把每个插件的下限都列出来）。
      final targets = RegExp(
        r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);',
      ).allMatches(read(pbxproj)).map((match) => match.group(1)!).toList();
      expect(targets, hasLength(3));
      for (final target in targets) {
        expect(
          double.parse(target),
          greaterThanOrEqualTo(15.0),
          reason: 'firebase 那两条插件要 15.0（当前 $target）',
        );
      }
    });
  });

  group('上传 App Store / TestFlight 要的那份隐私清单', () {
    const privacy = 'ios/Runner/PrivacyInfo.xcprivacy';

    test('清单在，且明确「不做追踪」', () {
      expect(File(privacy).existsSync(), isTrue);
      expect(plistBool(privacy, 'NSPrivacyTracking'), isFalse);
    });

    test('它在工程里被引用了 —— 光把文件放进 ios/Runner/ 是不会进包的', () {
      // Xcode 只打包「在工程里被引用、且在某一个 build phase 里」的文件。
      // 只放文件不接引用：出来的包里**没有**这份清单 → 上传 App Store 那一步被挡，
      // 而模拟器、单测、本地构建里都看不出任何异常（最贵的那类错）。
      final project = read(pbxproj);
      const name = 'PrivacyInfo.xcprivacy';

      // ① PBXBuildFile：它参与构建，并指向 ② 那个文件引用
      final build = project
          .split('\n')
          .firstWhere(
            (line) =>
                line.contains('$name in Resources') &&
                line.contains('PBXBuildFile'),
            orElse: () => '',
          );
      expect(build, isNotEmpty, reason: 'pbxproj 里没有 $name 的 PBXBuildFile');
      final buildId = RegExp('[0-9A-F]{24}').firstMatch(build)!.group(0)!;
      final refId = RegExp(
        '[0-9A-F]{24}',
      ).firstMatch(build.split('fileRef = ').last)!.group(0)!;

      // ② PBXFileReference：证明那个 id 真的是这个文件（而不是随手写的）
      expect(
        project,
        contains('$refId /* $name */ = {isa = PBXFileReference;'),
        reason: 'PBXBuildFile 指向的 $refId 找不到对应的 PBXFileReference',
      );

      // ③ 那一相里要有它：缺了这条，文件在工程里但**不会进包**
      final phase = project.substring(
        project.indexOf('97C146EC1CF9000F007C117D /* Resources */'),
      );
      expect(
        phase.substring(0, phase.indexOf('End PBXResourcesBuildPhase')),
        contains('$buildId /* $name in Resources */,'),
        reason: 'Resources 那一相里没有 $name —— 它不会被打进 .app',
      );

      // ④ Runner 那个 group 的孩子里要有它（Xcode 导航栏里看得到，改的时候找得到）
      final group = project.substring(
        project.indexOf('97C146F01CF9000F007C117D /* Runner */ = {'),
      );
      final children = group.substring(0, group.indexOf('End PBXGroup'));
      expect(children, contains('$refId /* $name */,'));
      // 顺带：entitlements 也在导航栏里（买号那天在 Xcode 里找得到它）
      expect(children, contains('/* Runner.entitlements */,'));
    });

    test('收集的数据类型按实际情况写（消息 / 图片 / 语音 / 账号 / 设备标识）', () {
      // 我们自己的服务器就是运营方，所以这些属于「收集」而不是「仅设备内处理」。
      // 上架前要按当时的真实情况再核一遍。
      final declared = RegExp(
        r'NSPrivacyCollectedDataType</key>\s*<string>([^<]+)</string>',
      ).allMatches(read(privacy)).map((match) => match.group(1)!).toSet();
      expect(
        declared,
        containsAll(<String>[
          'NSPrivacyCollectedDataTypeEmailsOrTextMessages',
          'NSPrivacyCollectedDataTypePhotosorVideos',
          'NSPrivacyCollectedDataTypeAudioData',
          'NSPrivacyCollectedDataTypeUserID',
          'NSPrivacyCollectedDataTypeDeviceID',
        ]),
      );
    });
  });

  // ── iOS 来电铃声（2026-10-15）─────────────────────────────────────────────
  //
  // 为什么为它单开一组：安卓来电放的是**用户自己手机的铃声**（系统铃声 uri），
  // iOS 上不行 —— 系统只认「打进 app 包里的一个 ≤30 秒的音频文件」，没带就退化成
  // 一声默认提示音。表现是「这个软件来电不响」，而它只有真机看得出来。
  // 所以这里把两件事钉死：文件本身合法、它真的进了包。
  group('iOS 来电铃声（没它，锁屏上只有一声「叮」）', () {
    const wav = 'ios/Runner/call_ring.wav';

    test('文件在，且真的是 iOS 认的那种（线性 PCM / 单声道 / ≤30 秒）', () {
      final file = File(wav);
      expect(
        file.existsSync(),
        isTrue,
        reason: '缺 $wav —— 用 `bash tool/audio/make-ios-ringtone.sh` 生成',
      );

      final bytes = file.readAsBytesSync();
      // WAV 是最简单的 RIFF 容器：12 字节头 + 一串「块」。这里只认 fmt 与 data。
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');

      int u16(int at) => bytes[at] | bytes[at + 1] << 8;
      int u32(int at) => u16(at) | u16(at + 2) << 16;

      int? format, channels, bits, byteRate, dataSize;
      var at = 12;
      while (at + 8 <= bytes.length) {
        final id = String.fromCharCodes(bytes.sublist(at, at + 4));
        final size = u32(at + 4);
        if (id == 'fmt ') {
          format = u16(at + 8);
          channels = u16(at + 10);
          byteRate = u32(at + 16);
          bits = u16(at + 22);
        } else if (id == 'data') {
          dataSize = size;
        }
        // 块长度是偶数（奇数要补一个填充字节）
        at += 8 + size + (size.isOdd ? 1 : 0);
      }

      expect(
        format,
        1,
        reason: '不是线性 PCM（format=1）—— iOS 只认 PCM / IMA4 / µ-law / a-law',
      );
      expect(channels, 1, reason: '单声道就够了，双声道白白大一倍');
      expect(bits, 16);
      expect(dataSize, isNotNull, reason: '没找到 data 块，这不是一个正常的 WAV');

      final seconds = dataSize! / byteRate!;
      expect(
        seconds,
        greaterThan(20),
        reason: '太短就又成一声「叮」了（现在 ${seconds.toStringAsFixed(1)} 秒）',
      );
      expect(
        seconds,
        lessThanOrEqualTo(30),
        reason:
            'iOS **不会循环**，超 30 秒的部分直接被砍'
            '（现在 ${seconds.toStringAsFixed(1)} 秒）',
      );
    });

    test('它进了包 —— 光把文件丢进 ios/Runner/ 是不会被打进 .app 的', () {
      // 与 PrivacyInfo.xcprivacy 同一个坑、同一套检查（见上面那一组）：
      // Xcode 只打包「被工程引用、且落在某个 build phase 里」的文件，
      // 而漏了这一步在模拟器、单测、本地构建里都看不出任何异常。
      final project = read(pbxproj);
      const name = 'call_ring.wav';

      final build = project
          .split('\n')
          .firstWhere(
            (line) =>
                line.contains('$name in Resources') &&
                line.contains('PBXBuildFile'),
            orElse: () => '',
          );
      expect(build, isNotEmpty, reason: 'pbxproj 里没有 $name 的 PBXBuildFile');
      final buildId = RegExp('[0-9A-F]{24}').firstMatch(build)!.group(0)!;
      final refId = RegExp(
        '[0-9A-F]{24}',
      ).firstMatch(build.split('fileRef = ').last)!.group(0)!;

      expect(
        project,
        contains('$refId /* $name */ = {isa = PBXFileReference;'),
        reason: 'PBXBuildFile 指向的 $refId 找不到对应的 PBXFileReference',
      );

      final phase = project.substring(
        project.indexOf('97C146EC1CF9000F007C117D /* Resources */'),
      );
      expect(
        phase.substring(0, phase.indexOf('End PBXResourcesBuildPhase')),
        contains('$buildId /* $name in Resources */,'),
        reason: 'Resources 那一相里没有 $name —— 它不会被打进 .app，来电又只剩一声叮',
      );
    });
  });

  group('应用图标与启动图（模板那几张必须被换掉）', () {
    const icons = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    const launch = 'ios/Runner/Assets.xcassets/LaunchImage.imageset';

    /// 直接从 PNG 头里读宽 / 高 / 颜色类型，**不引任何东西**：
    /// PNG 的 IHDR 固定在 8…25 字节（签名 8 字节 + 长度 4 + "IHDR" 4 + 宽 4 + 高 4 +
    /// 位深 1 + **颜色类型 1**）。知道这六个数字就够把三件事全拓住：
    /// 模板图没换、尺寸不对、以及**带了 alpha 通道**（苹果在 App Store 那一步会拒）。
    ({int width, int height, int colorType}) pngOf(String path) {
      final bytes = File(path).readAsBytesSync();
      const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
      for (var i = 0; i < signature.length; i++) {
        if (bytes[i] != signature[i]) fail('$path 不是 PNG（签名不对）');
      }
      int be32(int offset) =>
          (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      return (width: be32(16), height: be32(20), colorType: bytes[25]);
    }

    test('Contents.json 里列的每一张都在、尺寸对得上、且没有 alpha 通道', () {
      final manifest =
          jsonDecode(File('$icons/Contents.json').readAsStringSync())
              as Map<String, Object?>;
      final images = (manifest['images']! as List<Object?>)
          .cast<Map<String, Object?>>();

      // 同一张图会在多个 idiom 下重复出现（iphone 与 ipad 共用 20x20@2x 那份）
      final expected = <String, int>{};
      for (final entry in images) {
        final size = (entry['size']! as String).split('x').first;
        final scale = (entry['scale']! as String).replaceAll('x', '');
        expected[entry['filename']! as String] =
            (double.parse(size) * int.parse(scale)).round();
      }

      // 15 张（iphone / ipad / ios-marketing 三种 idiom 去重后的张数）：
      // 少一张 Xcode 只会报一句「missing icon」，而那句要等到买完号第一次上
      // Xcode 才会看到。
      expect(expected, hasLength(15));

      for (final entry in expected.entries) {
        final path = '$icons/${entry.key}';
        expect(File(path).existsSync(), isTrue, reason: '缺 ${entry.key}');
        final png = pngOf(path);
        expect(
          <int>[png.width, png.height],
          <int>[entry.value, entry.value],
          reason: '${entry.key} 应该是 ${entry.value}×${entry.value}',
        );
        // 2 = truecolor（无 alpha）、0 = 灰度（无 alpha）；
        // 4 / 6 = 带 alpha → App Store 会拒（“icon can't be transparent”）
        expect(
          png.colorType == 2 || png.colorType == 0,
          isTrue,
          reason: '${entry.key} 带了 alpha 通道（颜色类型 ${png.colorType}）',
        );
        // 模板图是 Flutter 自己的青色标，换掉之后文件不会这么小
        expect(
          File(path).lengthSync(),
          greaterThan(200),
          reason: '${entry.key} 小得不像真图标（换过了吗？）',
        );
      }
    });

    test('启动图不是模板那三张 1×1 的空图', () {
      // Flutter 模板给的是 1×1 的透明 PNG（等于没有）：App 一启动就是一片白，
      // 而应用内启动页画的是「白底 + logo」—— 接上它，启动才不白那一下。
      const files = <String, int>{
        'LaunchImage.png': 168,
        'LaunchImage@2x.png': 336,
        'LaunchImage@3x.png': 504,
      };
      for (final entry in files.entries) {
        final path = '$launch/${entry.key}';
        expect(File(path).existsSync(), isTrue, reason: '缺 ${entry.key}');
        final png = pngOf(path);
        expect(
          <int>[png.width, png.height],
          <int>[entry.value, entry.value],
          reason: '${entry.key} 应该是 ${entry.value}×${entry.value}',
        );
      }
    });
  });

  group('AppDelegate：通道与方法名要和 Dart 侧对得上', () {
    /// 每个通道必须实现的方法（Dart 侧真的会调的那些，见 lib/core/platform/）
    const required = <String, List<String>>{
      'gracelinkim/app_info': <String>['version'],
      'gracelinkim/permissions': <String>['check', 'request'],
      'gracelinkim/app_settings': <String>[
        'openAppSettings',
        'openNotificationSettings',
        'notificationPermission',
        'isIgnoringBatteryOptimizations',
        'requestIgnoreBatteryOptimizations',
        'fullScreenIntentAllowed',
        'openFullScreenIntentSettings',
      ],
      'gracelinkim/call_service': <String>[
        'start',
        'stop',
        'isRunning',
        'lastError',
        'notificationPermission',
        'requestNotificationPermission',
      ],
      'gracelinkim/callkit': <String>[
        'isAvailable',
        'reportIncomingCall',
        'reportEnded',
        'takePendingCall',
        'voipToken',
        'lastError',
      ],
    };

    /// 某个 handler 函数的函数体（从 `func handleX(` 到下一个 `func `）
    String bodyOf(String name) {
      final source = read(swift);
      final start = source.indexOf('func $name(');
      expect(start, isNot(-1), reason: '$swift 里找不到 $name');
      final rest = source.substring(start);
      final next = rest.indexOf('\n  private static func ', 1);
      return next == -1 ? rest : rest.substring(0, next);
    }

    test('五条通道都注册了（方法名逐字对得上）', () {
      final source = read(swift);
      const handlers = <String, String>{
        'gracelinkim/app_info': 'handleAppInfo',
        'gracelinkim/permissions': 'handlePermissions',
        'gracelinkim/app_settings': 'handleAppSettings',
        'gracelinkim/call_service': 'handleCallService',
        'gracelinkim/callkit': 'handleCallKit',
      };
      for (final entry in required.entries) {
        expect(
          source,
          contains('FlutterMethodChannel(name: "${entry.key}"'),
          reason: '通道名要与 Dart 侧一字不差：${entry.key}',
        );
        final body = bodyOf(handlers[entry.key]!);
        for (final method in entry.value) {
          expect(
            body,
            contains('"$method"'),
            reason:
                '${entry.key} 少了 "$method" —— Dart 侧调它时是 '
                'MissingPluginException，而多数封装把它收成「平台不支持」（功能静默消失）',
          );
        }
      }
    });

    test('iOS 上刻意没有的两条通道：pip 与 call_window（画中画 / 盖锁屏都是 CallKit 的事）', () {
      // 判的是「有没有注册」，不是「有没有提到」—— 文件头那张对照表里正列着它们。
      final source = read(swift);
      expect(
        source,
        isNot(contains('FlutterMethodChannel(name: "gracelinkim/pip"')),
      );
      expect(
        source,
        isNot(contains('FlutterMethodChannel(name: "gracelinkim/call_window"')),
      );
    });

    test('iOS 上不存在的两个方法名回 notImplemented，不假装成功', () {
      // screenSharing（没有前台服务的类型位）/ foregroundTypes（同上）
      final body = bodyOf('handleCallService');
      expect(body, contains('FlutterMethodNotImplemented'));
    });

    test('通话音频会话能从中断里自己爬回来（来电 / 闹钟 / Siri 之后不会静默变哑）', () {
      final source = read(swift);
      // 「通话还在不在」与「会话此刻真不真活着」**必须分开记**：合成一个值只能
      // 二选一 —— 要么中断期间 isRunning 撒谎说「在跑」（诊断面板显示一切正常，
      // 而用户那边早就没声音了），要么中断结束后永远不恢复。两个都得对。
      expect(source, contains('private var wanted = false'));
      expect(source, contains('private(set) var active = false'));
      expect(
        source,
        contains('AVAudioSession.interruptionNotification'),
        reason: '系统只通知我们它把会话拿走了，恢复要自己来',
      );
      expect(
        source,
        contains('AVAudioSession.mediaServicesWereResetNotification'),
        reason: '媒体服务被重启后所有音频对象都失效，会话得重设一遍',
      );
      // 恢复要按**同一份**分类重设（共用 apply()）：少一个选项就是
      // 「被电话打断一次之后视频通话不再外放」那种只有真机能发现的错
      expect(source, contains('private func apply() throws'));
      expect(source, contains('shouldResume'));
      expect(source, contains('guard wanted'));
      // 挂断要把观察者摘掉：不摘的话下一通电话的回调会叠加
      expect(source, contains('removeObservers()'));
      // 通话那套分类本身不能被顺手改掉
      expect(source, contains('.playAndRecord'));
      expect(source, contains('.voiceChat'));
      expect(source, contains('.videoChat'));
      expect(source, contains('notifyOthersOnDeactivation'));
    });

    test('Dart 侧每一条 gracelinkim/ 通道都「要么 iOS 实现了、要么写明了为什么没有」', () {
      // 新加一条通道时这条用例会红 —— 那正是我们要的：先在脑子里过一遍
      // 「iPhone 上这条通道谁来实现」，而不是等用户发现功能没了。
      const implementedOnIos = <String>{
        'gracelinkim/app_info',
        'gracelinkim/permissions',
        'gracelinkim/app_settings',
        'gracelinkim/call_service',
        'gracelinkim/callkit',
      };
      const notOnIos = <String, String>{
        'gracelinkim/pip': '安卓画中画；iOS 的画中画要 AVPictureInPictureController，还没做',
        'gracelinkim/call_window': '安卓「盖锁屏」；iOS 没有这个开关',
        'gracelinkim/media_session': 'Windows 的系统媒体卡片（SMTC）',
        'gracelinkim/child_window': '桌面的独立小窗（desktop_multi_window）',
        'gracelinkim/tray': '桌面的托盘图标',
      };

      final found = <String>{};
      for (final entry in Directory('lib').listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;
        final source = entry.readAsStringSync().replaceAll('\r\n', '\n');
        for (final match in RegExp(
          "'gracelinkim/([a-z_]+)'",
        ).allMatches(source)) {
          found.add('gracelinkim/${match.group(1)}');
        }
      }

      final unaccounted = found
          .difference(implementedOnIos)
          .difference(notOnIos.keys.toSet());
      expect(unaccounted, isEmpty, reason: '这些通道没说清 iOS 上谁来实现：$unaccounted');
      // 反向也要成立：写在这里的通道名真的还在用（写错了名字同样该被发现）
      expect(implementedOnIos.difference(found), isEmpty);
      expect(notOnIos.keys.toSet().difference(found), isEmpty);
    });
  });

  group('来电那条路：CallKit + PushKit 的硬要求（2026-10-15）', () {
    /// 从某个标记开始的那段源码（切到下一个成员函数 / MARK 为止）。
    ///
    /// 比 `contains(read(swift))` 强的地方：断言必须落在**那个函数里面** ——
    /// 否则「同一条规矩在别处写过一遍」会骗过它。
    String sliceFrom(String marker) {
      final source = read(swift);
      final start = source.indexOf(marker);
      expect(start, isNot(-1), reason: '$swift 里找不到「$marker」');
      final rest = source.substring(start);
      final ends = <int>[
        rest.indexOf('\n  func ', 1),
        rest.indexOf('\n  private func ', 1),
        rest.indexOf('\n  // MARK', 1),
      ].where((index) => index > 0).toList()..sort();
      return ends.isEmpty ? rest : rest.substring(0, ends.first);
    }

    test('收到 VoIP 推送就在那个回调里报给 CallKit（苹果的硬规则）', () {
      // iOS 13 起：收到 VoIP 推送必须**立刻**报给 CallKit。先绕去别处再报会被
      // 当成滥用 VoIP 推送 —— 后果是系统直接掐掉 App（不是「弹不出来」那么轻）。
      final body = sliceFrom(
        'didReceiveIncomingPushWith payload: PKPushPayload',
      );
      expect(
        body,
        contains('reportIncoming('),
        reason: '推送回调里没上报：苹果会把这条推送算成滥用',
      );
      expect(body, contains('callerName:'), reason: '报的时候要带上是谁在打');
      expect(
        body,
        contains('once.run(completion)'),
        reason:
            'PushKit 那条 completion 必须被调到'
            '（没调 = 这条推送没处理完，同样会被掐）',
      );
      expect(
        body,
        contains('asyncAfter'),
        reason: '上报的回执万一不来，也要有兜底把 completion 放掉',
      );
    });

    test('注册在 didFinishLaunching 里（不能等 Flutter 引擎）', () {
      final source = read(swift);
      final launch = source.indexOf('didFinishLaunchingWithOptions');
      final engine = source.indexOf('func didInitializeImplicitFlutterEngine');
      expect(launch, isNot(-1), reason: '找不到 didFinishLaunchingWithOptions');
      expect(engine, greaterThan(launch));
      expect(
        source.substring(launch, engine),
        contains('registerVoipPush()'),
        reason:
            'App 被划掉之后 iOS 靠这条注册把进程拉起来送 VoIP 推送；'
            '注册晚了就会漏掉「冷启动那一通电话」',
      );
    });

    test('接听 / 拒接真的转给 Dart（接电话的是状态机，不是原生）', () {
      final answer = sliceFrom('perform action: CXAnswerCallAction');
      expect(answer, contains('sendAction(kind: "answer"'));
      expect(
        answer,
        contains('action.fulfill'),
        reason: '系统那一侧要收干净，否则那个界面会一直转圈',
      );

      final end = sliceFrom('perform action: CXEndCallAction');
      expect(end, contains('sendAction(kind: "end"'));
      expect(end, contains('action.fulfill'));
    });

    test('同一通不能报两次，结束也不能漏报（漏了锁屏上那个界面会一直挂着）', () {
      final source = read(swift);
      expect(
        source,
        contains('reportedCalls[existing] == callId'),
        reason: '同一通重复上报，锁屏上会变成两条一模一样的来电',
      );
      expect(source, contains('alreadyReported'));
      expect(
        source,
        contains('reportCall(with: uuid, endedAt: Date(), reason: reason)'),
        reason: '对端挂了 / 本机取消之后，系统那个来电界面必须被收掉',
      );
    });

    test('系统的音频会话交给 CallAudioSession（与保活那条路共用一份）', () {
      final source = read(swift);
      expect(source, contains('CXProviderDelegate'));
      expect(source, contains('PKPushRegistryDelegate'));
      expect(
        source,
        contains('CallAudioSession.shared.start(video: currentVideo)'),
        reason: '分类只有一处设置（apply()）：两边各写一份，迟早会漏掉一个选项',
      );
      expect(source, contains('CallAudioSession.shared.stop()'));
      expect(
        source,
        contains('providerDidReset'),
        reason: '系统把通话整个重置了（用户强制退出这类），本地也得跟着清',
      );
    });
  });
}
