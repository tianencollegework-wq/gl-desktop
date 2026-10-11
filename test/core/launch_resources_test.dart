import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// 启动屏配置守卫（2026-09-26 加）。
///
/// 启动屏是「最容易悄悄坏掉又没人发现」的一块：它一半在 Android 资源里、
/// 一半在 Dart 里，错了也不会崩，只是每次冷启动闪一下 / 品牌名出现两次。
/// 这份用例把三件事钉死：
///
/// * 深色系统下也是白底（本 App 只有亮色主题，模板默认的 night 主题会先黑一屏）；
/// * Android 12+ 的强制启动屏用的是**带透明留白**的图标 —— 系统会把图标按
///   直径 = 画布 2/3 的圆裁掉，原图直接交上去会掉四角和底下那行 GraceLink；
/// * 两套启动图在五档密度里都齐全。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const res = 'android/app/src/main/res';
  const buckets = <String>['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'];

  String read(String path) => File(path).readAsStringSync();

  /// 去掉注释再查：这些文件的注释里正解释着「以前用的是 ?android:colorBackground」，
  /// 不剥掉会把自己注释里的字当成配置命中。
  String readXml(String path) =>
      read(path).replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  test('五档密度都有两张启动图', () {
    for (final bucket in buckets) {
      for (final name in <String>['launch_logo.png', 'launch_logo_pad.png']) {
        expect(
          File('$res/mipmap-$bucket/$name').existsSync(),
          isTrue,
          reason:
              'mipmap-$bucket/$name 缺了（生成脚本 tool/probe/make_launch_logo.js）',
        );
      }
    }
  });

  test('Android 11 及以下的启动窗口：白底 + 居中贴原图，不跟随系统深浅色', () {
    final xml = readXml('$res/drawable-v21/launch_background.xml');
    expect(
      xml,
      contains('@android:color/white'),
      reason: '启动窗口底色必须锁死白色（本 App 只有亮色主题）',
    );
    expect(
      xml,
      isNot(contains('?android:colorBackground')),
      reason: '跟随系统 = 深色下先黑一屏再闪白',
    );
    expect(xml, contains('@mipmap/launch_logo'), reason: '启动窗口要摆上 logo');
    expect(xml, contains('android:gravity="center"'), reason: '原图必须居中、不拉伸不裁切');
  });

  test('Android 12+ 的强制启动屏：白底 + 带留白的图标', () {
    final xml = readXml('$res/values-v31/styles.xml');
    expect(xml, contains('android:windowSplashScreenBackground'));
    expect(xml, contains('@android:color/white'));
    expect(xml, contains('android:windowSplashScreenAnimatedIcon'));
    expect(
      xml,
      contains('@mipmap/launch_logo_pad'),
      reason: '要交带留白的那张，直接交 launch_logo 会被圆形蒙版切掉四角',
    );
  });

  test('没有 values-night：夜里也是白底，且不会盖掉 12+ 的启动屏属性', () {
    expect(
      File('$res/values-night/styles.xml').existsSync(),
      isFalse,
      reason:
          'values-night 的优先级高于 values-v31：留着它，12+ 的启动屏属性会被盖掉，'
          '深色系统下还会先黑一屏',
    );
    expect(
      readXml('$res/values/styles.xml'),
      isNot(contains('?android:colorBackground')),
      reason: '基础主题里也不该再跟随系统背景',
    );
  });

  test('12+ 那张图标四周真的留了透明边（蒙版圆只切到留白）', () async {
    // 官方规格：288dp 画布、可见区是直径 192dp 的圆 = 画布的 2/3。
    // 生成脚本把原图缩到 62%，四角稳稳落在圆里。
    const maskRatio = 2 / 3;
    for (final bucket in buckets) {
      final file = File('$res/mipmap-$bucket/launch_logo_pad.png');
      final image = await _decode(file.readAsBytesSync());
      final box = await _opaqueBounds(image);
      final width = image.width, height = image.height;

      expect(
        box.width / width,
        lessThan(maskRatio),
        reason: 'mipmap-$bucket：原图比蒙版圆还宽，会被切掉左右两边',
      );
      expect(
        box.height / height,
        lessThan(maskRatio),
        reason: 'mipmap-$bucket：原图比蒙版圆还高，会被切掉上下两边',
      );
      // 原图要在正中间（四周留白对称），否则看着像没对齐
      expect((box.minX + box.maxX) / 2, closeTo((width - 1) / 2, 1.5));
      expect((box.minY + box.maxY) / 2, closeTo((height - 1) / 2, 1.5));
      // 四角必须是透的：蒙版圆切到的就是这四个角
      for (final corner in <List<int>>[
        <int>[0, 0],
        <int>[width - 1, 0],
        <int>[0, height - 1],
        <int>[width - 1, height - 1],
      ]) {
        expect(
          await _alphaAt(image, corner[0], corner[1]),
          0,
          reason: 'mipmap-$bucket 的 ${corner[0]},${corner[1]} 不是透明的',
        );
      }
      image.dispose();
    }
  });

  test('≤11 那张是整张原图：满幅不透明（白底会和启动窗口的白融成一片）', () async {
    for (final bucket in buckets) {
      final file = File('$res/mipmap-$bucket/launch_logo.png');
      final image = await _decode(file.readAsBytesSync());
      for (final corner in <List<int>>[
        <int>[0, 0],
        <int>[image.width - 1, 0],
        <int>[0, image.height - 1],
        <int>[image.width - 1, image.height - 1],
      ]) {
        expect(
          await _alphaAt(image, corner[0], corner[1]),
          255,
          reason: 'mipmap-$bucket 的 ${corner[0]},${corner[1]} 应该是原图的白底',
        );
      }
      // 方形，且和 12+ 那张同源
      expect(image.width, image.height);
      image.dispose();
    }
  });
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

Future<ByteData?> _pixels(ui.Image image) =>
    image.toByteData(format: ui.ImageByteFormat.rawRgba);

Future<int> _alphaAt(ui.Image image, int x, int y) async {
  final data = (await _pixels(image))!;
  return data.getUint8((y * image.width + x) * 4 + 3);
}

/// 不透明像素的包围盒（alpha > 8 算不透明，避开缩放的羽化边）
Future<({int minX, int minY, int maxX, int maxY, int width, int height})>
_opaqueBounds(ui.Image image) async {
  final data = (await _pixels(image))!;
  var minX = image.width, minY = image.height, maxX = -1, maxY = -1;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      if (data.getUint8((y * image.width + x) * 4 + 3) <= 8) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  return (
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    width: maxX - minX + 1,
    height: maxY - minY + 1,
  );
}
