import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/features/desktop_window/desktop_web_window.dart';
import 'package:gracelinkim/features/desktop_window/web_tabs.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

/// 网页窗「多标签」那一关的自检（**不是单测**，要在 Windows 真机上跑）。
///
/// 多标签的技术前提只有一条：**同一颗引擎（同一扇窗）里能同时活着两颗
/// WebView2**。这事在 S12.25 踩过一次坑 —— WebView2 要求每个线程一个
/// `DispatcherQueueController`，而插件是**每颗引擎一份平台对象**（建 DQC 的地方），
/// 于是第二扇**窗口**（第二颗引擎）起不来（报 `unsupported_platform`）。同一颗
/// 引擎里的第二个 `WebviewController` 共用那份平台对象，按插件的设计是能开多个
/// 的（`WebviewWindowsPlugin::instances_` 本来就是一张表、环境还是引用计数的）
/// —— 但「设计上能开」不等于「这台机器上真能开」，所以钉一条自检：
/// 两颗同时 initialize、同时真加载两个站点，看标题回来没有。
///
/// 跑法：
/// ```
/// flutter test integration_test/web_tabs_smoke_test.dart -d windows
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 等这颗 controller 报出不空的页面标题（`title` 那条流是广播流，
  /// 没人听的时候事件会掉，所以**先挂上再加载**）。
  Future<String> waitTitle(WebviewController controller) async {
    final titles = <String>[];
    final subscription = controller.title.listen((value) {
      final clean = value.trim();
      if (clean.isNotEmpty) titles.add(clean);
    });
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (titles.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await subscription.cancel();
    return titles.isEmpty ? '' : titles.last;
  }

  testWidgets('一扇窗里两颗 WebView2：都起得来、都真加载了页面', (tester) async {
    final first = WebviewController();
    final second = WebviewController();
    try {
      await first.initialize();
      await second.initialize();
      expect(first.value.isInitialized, isTrue);
      expect(second.value.isInitialized, isTrue);
      // ignore: avoid_print
      print('[SMOKE] tabs two WebView2 initialized');

      // 同时加载（多标签窗里也是这个形状：几个标签各自在加载）
      await first.loadUrl('https://www.cnbeta.com.tw/');
      await second.loadUrl('https://www.ithome.com/');

      final results = await Future.wait(<Future<String>>[
        waitTitle(first),
        waitTitle(second),
      ]);
      // ignore: avoid_print
      print('[SMOKE] tabs titles A=${results[0]} B=${results[1]}');
      expect(results[0], isNotEmpty, reason: '第一颗没把页面标题报回来');
      expect(results[1], isNotEmpty, reason: '第二颗没把页面标题报回来');
    } finally {
      await first.dispose();
      await second.dispose();
      // ignore: avoid_print
      print('[SMOKE] tabs both disposed');
    }
  });

  testWidgets('网页窗那套界面：两个标签都真加载，标签条写的是页面标题', (tester) async {
    // 窗口里那份最小环境（与 `runDesktopChildWindow` 同一套来源）
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await LingtingStore.init();
    await AppI18n.load('zh-Hans');

    final tabs = WebTabsController(
      url: 'https://www.cnbeta.com.tw/',
      title: 'www.cnbeta.com.tw',
    );
    const captureKey = ValueKey<String>('tabs-capture');
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: ProviderScope(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: DesktopWebWindow(controller: tabs),
          ),
        ),
      ),
    );
    await tester.pump();

    // 主窗口又点了一条外链：第二个标签（看这扇窗会不会把两页都真架起来）
    tabs.open(url: 'https://www.ithome.com/', title: 'www.ithome.com');
    await tester.pump();

    // 真等两页把标题报回来（真网络 + 真 WebView2）
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (tabs.tabs.any((tab) => tab.pageTitle.isEmpty) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    });
    await tester.pump(const Duration(milliseconds: 400));

    // ignore: avoid_print
    print(
      '[SMOKE] tabs labels='
      '${tabs.tabs.map((tab) => tab.label).toList()}',
    );
    expect(tabs.tabs.length, 2);
    expect(tabs.tabs[0].pageTitle, contains('cnBeta'));
    expect(tabs.tabs[1].pageTitle, contains('IT之家'));

    // 把这一屏 Flutter 图层存成图片：机器锁屏时也能拿它核对外观（标签条是纯
    // Flutter 画的；webview 是插件纹理，不进这一张）
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      'build/web_tabs_capture.png',
    ).writeAsBytesSync(data!.buffer.asUint8List());
    // ignore: avoid_print
    print('[SMOKE] tabs capture=${image.width}x${image.height}');
  });
}
