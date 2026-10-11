import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/config/app_info.dart';

/// **品牌**与「发现」那一栏的图标守卫（用户 2026-09-27 的两条要求）：
///
/// * 「软件默认的『IM』、『raingad-im』等等全部改成 Gracelink，logo 也改成现在
///   软件用的 logo」—— 上游产品的默认名与服务端那张旧 logo 都不该再露出来；
/// * 「发现页面…现在就搞一栏，就是『灵听』，然后 logo 用我给你上传的这张」——
///   那一栏的图必须是用户给的那张（红音符 + 环绕的叶子）。
///
/// 这些都是「配错了也不会崩，只是品牌看着很山寨」的东西，所以在这里钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 行尾统一成 `\n`：这几个文件在 Windows 上是 CRLF，写死了 `\n` 的断言会全部落空
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');
  String readCode(String path) =>
      read(path).replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  group('站点名：老端那几个默认名换成 Gracelink', () {
    test('空 / IM / Raingad-IM / gracelinkim 都当「没配名字」', () {
      for (final legacy in <String>[
        '',
        'IM',
        'im',
        'Raingad-IM',
        'raingad-im',
        'RAINGAD_IM',
        'raingad im',
        'gracelinkim',
        'Gracelink IM',
        'Raingad',
      ]) {
        expect(
          AppInfo.siteName(legacy),
          'Gracelink',
          reason: '「$legacy」是上游的默认名，不该显示出来',
        );
      }
    });

    test('管理员自己起过的名字原样显示（哪怕里面带着 IM）', () {
      expect(AppInfo.siteName('示例IM'), '示例IM');
      expect(AppInfo.siteName('恩信'), '恩信');
      expect(AppInfo.siteName('Acme 通信'), 'Acme 通信');
    });

    test('登录页底下那行是「Gracelink for 版本号」', () {
      expect(
        AppInfo.footer(AppInfo.siteName('Raingad-IM')),
        'Gracelink for 1.0.0',
      );
    });
  });

  group('各平台的显示名/标题都是 Gracelink', () {
    test('安卓：中文包是恩信、英文包是 Gracelink', () {
      expect(
        read('android/app/src/main/res/values/strings.xml'),
        contains('<string name="app_name">恩信</string>'),
      );
      expect(
        read('android/app/src/main/res/values-en/strings.xml'),
        contains('<string name="app_name">Gracelink</string>'),
      );
    });

    test('iOS：桌面图标下的名字不再是 Gracelinkim', () {
      final plist = readCode('ios/Runner/Info.plist');
      expect(
        plist,
        contains(
          '<key>CFBundleDisplayName</key>\n\t<string>Gracelink</string>',
        ),
      );
      expect(plist, isNot(contains('Gracelinkim')));
    });

    test('Web / 桌面：标题与产品名都不是 gracelinkim', () {
      expect(read('web/index.html'), contains('<title>Gracelink</title>'));
      expect(read('web/index.html'), isNot(contains('>gracelinkim<')));
      final manifest = read('web/manifest.json');
      expect(manifest, contains('"name": "Gracelink"'));
      expect(manifest, contains('"short_name": "Gracelink"'));
      expect(manifest, isNot(contains('gracelinkim')));
      expect(
        read('macos/Runner/Configs/AppInfo.xcconfig'),
        contains('PRODUCT_NAME = Gracelink'),
      );
      final runnerRc = read('windows/runner/Runner.rc');
      expect(runnerRc, contains('"ProductName", "Gracelink"'));
      // 2026-10-09：模板里的 com.example 会出现在「属性 → 详细信息」和签名那类
      // 安全对话框上，对外发的包里不该有它（发行/法律相关那两行也一并换掉）
      expect(runnerRc, isNot(contains('com.example')));
      expect(runnerRc, contains('"CompanyName", "Gracelink"'));
      expect(runnerRc, contains('Copyright (C) 2026 Gracelink'));
    });

    test('语言包里没有「Gracelink IM」这种半截品牌名', () {
      for (final file in <String>[
        'assets/i18n/zh-Hans.json',
        'assets/i18n/en.json',
      ]) {
        final text = read(file);
        expect(text, isNot(contains('Gracelink IM')));
        expect(text, isNot(contains('Raingad')));
        expect(text, isNot(contains('raingad')));
      }
    });
  });

  group('logo', () {
    test('应用自己那张在包里，且是那张白底带字的主 logo', () async {
      expect(AppInfo.logoAsset, 'assets/images/logo.png');
      final stats = await _stats(AppInfo.logoAsset);
      expect(stats.width, stats.height, reason: '主 logo 是方的');
      expect(stats.opaqueCorners, isTrue, reason: '主 logo 是白底不透明的');
    });

    test('「灵听」那一栏是用户上传的那张（红音符 + 叶子），不是别的图', () async {
      const asset = 'assets/images/lingting_logo.png';
      expect(File(asset).existsSync(), isTrue);
      final stats = await _stats(asset);
      expect(
        stats.redRatio,
        greaterThan(0.1),
        reason: '那张图的主角是红色的音符（红像素占比不该只有零星几点）',
      );
      expect(
        stats.tealRatio,
        greaterThan(0.03),
        reason: '音符四周那圈青秃叶子也要在（纯红的图不是这一张）',
      );
      expect(
        stats.opaqueCorners,
        isFalse,
        reason: '这张是带透明通道的图（放在白底列表里不该看出一个方框）',
      );
    });
  });
}

/// 一张图的基本统计：红/青两色占比 + 四角是否不透明
Future<
  ({
    int width,
    int height,
    double redRatio,
    double tealRatio,
    bool opaqueCorners,
  })
>
_stats(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final image = (await codec.getNextFrame()).image;
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

  var red = 0, teal = 0, total = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final i = (y * image.width + x) * 4;
      final r = data.getUint8(i),
          g = data.getUint8(i + 1),
          b = data.getUint8(i + 2),
          a = data.getUint8(i + 3);
      if (a <= 8) continue;
      total++;
      if (r > 150 && g < 90 && b < 90) red++;
      // 叶子那圈青蓝色（`#408090` 上下）：红少、绿蓝都亮
      if (r < 120 && g > 100 && b > 100) teal++;
    }
  }
  int alphaAt(int x, int y) => data.getUint8((y * image.width + x) * 4 + 3);
  final corners = <int>[
    alphaAt(0, 0),
    alphaAt(image.width - 1, 0),
    alphaAt(0, image.height - 1),
    alphaAt(image.width - 1, image.height - 1),
  ];
  final width = image.width, height = image.height;
  image.dispose();
  return (
    width: width,
    height: height,
    redRatio: total == 0 ? 0.0 : red / total,
    tealRatio: total == 0 ? 0.0 : teal / total,
    opaqueCorners: corners.every((alpha) => alpha > 200),
  );
}
