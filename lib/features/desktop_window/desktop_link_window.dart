/// 桌面上「这个外链交给另一扇窗口」这一件事（2026-10-04）。
///
/// 用户的原话：「为什么好像都要将链接从浏览器打开，不能像微信电脑端一样做一个
/// webview 吗？如果可以请把 webview 网页的窗口也独立窗口打开」——
/// 于是桌面上点外链的去处从「本窗里推一页」变成「开一扇独立的网页窗」
/// （窗口内容见 `child_window_app.dart` 的 [DesktopWindowKind.web] 那一支，
/// 里面装的是真 WebView2，见 `core/platform/webview_host.dart`）。
///
/// 为什么单独一个文件而不是写在 `core/ui/link_opener.dart` 里：
/// 那个文件已经 import 了 `core/router/app_router.dart`（它要用 `AppRoutes`），
/// 而路由表又要 import 确认页、确认页要回来问「这一下是不是要开窗」——
/// 写在一起就是一圈循环 import。这一份不碰路由，两头都能安全 import。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_window_service.dart';
import 'window_args.dart';

/// 「这一页是不是就跑在网页窗里」——只有网页窗那颗引擎为真。
///
/// 用途只有一个：内嵌浏览器那一页（`/mine/webview`）在桌面上会把「打开」这件事
/// 交给网页窗（见 [WebViewPage] 那段的跳转），而网页窗里那一页自己不能也这么干
/// （自己套自己，永远转下去）。
final webWindowHostProvider = Provider<bool>((ref) => false);

/// 把 [url] 交给**网页窗**（开一扇；已经有那扇就把它抬起来、让它自己多开一个
/// 标签）。
///
/// 返回 true 表示已经交出去了（调用方就别再在本窗里推那页路由）；
/// 手机 / 窄窗 / 测试环境（[desktopLinkWindowProvider] 是假）原样返回 false，
/// 老路子（`/mine/webview` 那一页）照走。
bool openExternalLinkWindow(BuildContext context, String url) {
  if (url.isEmpty) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  if (!container.read(desktopLinkWindowProvider)) return false;
  unawaited(
    container
        .read(desktopWindowServiceProvider)
        .openWeb(url: url, title: webWindowTitleOf(url)),
  );
  return true;
}
