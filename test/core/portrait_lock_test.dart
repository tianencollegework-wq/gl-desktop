import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **锁死竖屏**的守卫（用户 2026-09-27：「能不能强制软件竖屏，不允许横屏」）。
///
/// 这件事有三道，少一道就会在某个系统上被转过来，而且**平时看不出来**
/// （安卓上 `flutter create` 的模板、iOS 上则是那份 plist 自己说了算）：
///
/// 1. Android 清单里那个 Activity 的 `android:screenOrientation="portrait"`
///    —— 这是安卓侧的硬锁，也是唯一一道「系统压根不许转」的；
/// 2. iOS 的 `UISupportedInterfaceOrientations`（含 `~ipad` 那份）只留竖屏
///    —— iOS 侧的方向是**清单与 Dart 偏好的交集**，plist 里留着横屏就等于没锁；
/// 3. `main()` 里的 `SystemChrome.setPreferredOrientations` —— 桌面/其它平台靠它。
///
/// 全站版式是按竖屏宽度用 `rpx`（750 = 屏宽）算的，横过来只会到处溢出，
/// 所以这三处哪一处被人顺手删掉，都该在这里红一次。
void main() {
  String read(String path) => File(path).readAsStringSync();

  /// 剥掉注释再查：这几份文件的注释里正解释着「要锁竖屏」，不剥掉会查到自己
  String readCode(String path) =>
      read(path).replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  test('安卓：那个 Activity 硬锁竖屏，且没有别的方向兜底', () {
    final manifest = readCode('android/app/src/main/AndroidManifest.xml');

    expect(
      manifest,
      contains('android:screenOrientation="portrait"'),
      reason: '少了这一行，安卓上把手机横过来就会转屏',
    );
    for (final bad in <String>[
      'landscape',
      'sensor',
      'fullSensor',
      'unspecified',
      'userLandscape',
      'reverseLandscape',
    ]) {
      expect(
        manifest.toLowerCase(),
        isNot(contains('android:screenOrientation="$bad"'.toLowerCase())),
        reason: '清单里不该有 "$bad" 这个方向（会被系统当成可横屏）',
      );
    }
  });

  test('iOS：支持方向里只有竖屏（iPhone 与 iPad 两份都要）', () {
    final plist = readCode('ios/Runner/Info.plist');

    // 两份数组：手机那份只有 Portrait；iPad 那份允许倒着的竖屏（平板常平放）
    expect(plist, contains('<key>UISupportedInterfaceOrientations</key>'));
    expect(plist, contains('<key>UISupportedInterfaceOrientations~ipad</key>'));
    expect(
      plist,
      isNot(contains('UIInterfaceOrientationLandscape')),
      reason: 'plist 里留着横屏 = iOS 上照样能转过来（Dart 那边拦不住）',
    );
    expect(plist, contains('<string>UIInterfaceOrientationPortrait</string>'));

    // 横屏那几个键也别以别的形式留着
    expect(plist, isNot(contains('UIInterfaceOrientationMaskLandscape')));
  });

  test('Dart 侧：启动时就声明「只要正着的竖屏」', () {
    final main = read('lib/main.dart');

    expect(main, contains('SystemChrome.setPreferredOrientations'));
    expect(main, contains('DeviceOrientation.portraitUp'));
    expect(
      main,
      isNot(contains('DeviceOrientation.landscape')),
      reason: 'landscape 一旦出现在这个列表里，等于把竖屏锁解开了',
    );
    // 而且要 `await`：这是个平台调用，不 await 的话首帧可能已经按旧方向画了
    expect(main, contains('await SystemChrome.setPreferredOrientations'));
  });
}
