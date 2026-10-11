/// 主窗口这一侧：把「文章 / 灵听 / 媒体号」开到**系统级独立窗口**里（2026-10-04）。
///
/// 界面那边只管调 [DesktopWindowService.openArticle] / [openLingting] / [openNews]，
/// 「是新建一颗引擎，还是把已有的那颗叫回来」都在这里。
///
/// 三条规矩：
/// * **一个 kind 一颗窗口**：每颗窗口都是一整颗 Flutter 引擎（实测 +≈56MB），
///   所以不叠第二个；再点就把原来那颗抬到最前；
/// * **✕ 是真关掉**：native 那边把窗销毁（引擎跟着释放），所以「叫回来」这件事
///   只对**还活着**的窗口成立 —— 判断靠 ping，见 [_findAlive]；
/// * **换内容走 IPC**：文章窗只有一颗，点第二篇时让它自己换成那一篇
///   （`gracelink/window/<kind>` 那条线，子窗口侧见 `child_window_app.dart`）。
library;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/desktop_shell.dart';
import '../../domain/news/news_card.dart';
import 'window_args.dart';

/// 开窗这件事的接口（测试里换掉它就能断言「点了灵听到底去开没开窗口」）。
abstract class DesktopWindowService {
  /// 文章开（或唤起到）独立窗口；本机没有这一篇时 [shared] 会跟着递过去
  Future<void> openArticle({
    required String id,
    required String title,
    NewsCard? shared,
  });

  /// 灵听（整条频道）开（或唤起到）独立窗口
  Future<void> openLingting({required String title});

  /// 媒体号（资讯列表整条）开（或唤起到）独立窗口
  Future<void> openNews({required String title});

  /// 外链开（或唤起到）**网页窗**：Windows 那边就是内嵌的 WebView2
  /// （用户 2026-10-04：「不要都用浏览器打开，像微信电脑端那样做成 webview」）。
  Future<void> openWeb({required String url, required String title});
}

/// 桌面「外链开成系统级独立窗口」的总开关。
///
/// 生产桌面默认开（![desktopFeaturesEnabled] 在测试里是假 —— 那批用例钉的是
/// 「点一下推了哪条路由」，不该被换成一扇真窗口）；**独立窗口那几颗引擎自己
/// 会把它改成开**：它们本来就是桌面上的一扇窗（见 `child_window_app.dart`），
/// 所以在媒体号窗里点「阅读原文」，网页照样开成另一扇窗。
final desktopLinkWindowProvider = Provider<bool>(
  (ref) => ref.watch(desktopFeaturesProvider),
);

final desktopWindowServiceProvider = Provider<DesktopWindowService>(
  (ref) => MultiWindowDesktopWindowService(),
);

/// 真去跟 `desktop_multi_window` 打交道的那一份。
class MultiWindowDesktopWindowService implements DesktopWindowService {
  @override
  Future<void> openArticle({
    required String id,
    required String title,
    NewsCard? shared,
  }) => _open(DesktopWindowArgs.article(id: id, title: title, shared: shared));

  @override
  Future<void> openLingting({required String title}) =>
      _open(DesktopWindowArgs.lingting(title: title));

  @override
  Future<void> openNews({required String title}) =>
      _open(DesktopWindowArgs.news(title: title));

  @override
  Future<void> openWeb({required String url, required String title}) =>
      _open(DesktopWindowArgs.web(url: url, title: title));

  Future<void> _open(DesktopWindowArgs request) async {
    try {
      final existing = await _findAlive(request.kind);
      if (existing != null) {
        // 「已经有这颗窗口」：把它抬到最前（它可能被别的窗口压着），
        // 再把内容换成这次要的（灵听 / 媒体号不需要换内容）。
        await existing.show();
        if (request.kind == DesktopWindowKind.article) {
          await _tellArticle(existing, request);
        } else if (request.kind == DesktopWindowKind.web) {
          await _tellWeb(existing, request);
        }
        return;
      }
      await WindowController.create(
        WindowConfiguration(
          arguments: request.encode(),
          // 窗口自己那边：设好标题/大小/居中再 show（不然先闪一下 800×600）
          hiddenAtLaunch: true,
        ),
      );
      debugPrint('[窗口] 开了 ${request.kind.name} 窗口：${request.title}');
    } on Object catch (error, stack) {
      // 开不出来不该把点它的那个动作也带崩：记一笔就算了
      debugPrint('[窗口] 开 ${request.kind.name} 窗口失败：$error\n$stack');
    }
  }

  /// 把这条外链交给网页窗（它自己**新开一个标签**）。
  ///
  /// 与文章窗那条一样的道理：这颗窗口只有一颗，连着点两条外链不该叠出两扇窗
  /// —— 第二条把第一颗抬起来、让它自己多开一页（同一条地址点了两遍就切过去，
  /// 去重那一步在子窗 `web_tabs.dart` 里）。
  Future<void> _tellWeb(
    WindowController window,
    DesktopWindowArgs request,
  ) async {
    try {
      await WindowMethodChannel(
        'gracelink/window/${DesktopWindowKind.web.name}',
        mode: ChannelMode.unidirectional,
      ).invokeMethod<dynamic>('open_url', <String, dynamic>{
        'url': request.url,
        'title': request.title,
      });
    } on Object catch (error) {
      // 同 `_tellArticle`：引擎刚起来时那条线可能还没挂上，忽略这一次即可
      debugPrint('[窗口] 让网页窗换个地址失败（忽略）：$error');
    }
  }

  /// 台面上那颗还活着的窗口（没有就返回 null）。
  ///
  /// 为什么要一个个**探**过去，而不是 `getAll()` 里看到就算数：✕ 现在是真销毁
  /// （见 `windows/runner/flutter_window.cpp`：销毁子窗口不会带走进程），而
  /// `desktop_multi_window` 自己的窗口表**没有清理那一步** ——
  /// `MultiWindowManager::RemoveWindow` 在插件里压根没被调用过，窗口销毁之后
  /// `getAll()` 还会照样把它列出来。照着这条“幽灵”去 `show()` 会石沉大海
  /// （原生那边 `ShowWindow(nullptr, ...)` 静默失败），用户点一下没反应。
  /// 所以：叫得出来（能 ping 通）才算数，叫不出来就当它已经关了。
  Future<WindowController?> _findAlive(DesktopWindowKind kind) async {
    for (final window in await WindowController.getAll()) {
      if (DesktopWindowArgs.decode(window.arguments)?.kind != kind) continue;
      if (await _revive(window, kind)) return window;
    }
    return null;
  }

  /// 把（可能已经不在的）窗口叫出来，并确认它真的在。
  Future<bool> _revive(WindowController window, DesktopWindowKind kind) async {
    try {
      await window.show();
      await WindowMethodChannel(
            'gracelink/window/${kind.name}',
            mode: ChannelMode.unidirectional,
          )
          .invokeMethod<dynamic>('ping')
          .timeout(const Duration(milliseconds: 800));
      return true;
    } on Object catch (error) {
      debugPrint('[窗口] 那颗 ${kind.name} 窗口叫不出来了，当作已经关掉：$error');
      return false;
    }
  }

  /// 告诉文章窗「换成这一篇」
  Future<void> _tellArticle(
    WindowController window,
    DesktopWindowArgs request,
  ) async {
    try {
      await WindowMethodChannel(
        'gracelink/window/${DesktopWindowKind.article.name}',
        mode: ChannelMode.unidirectional,
      ).invokeMethod<dynamic>('open_article', <String, dynamic>{
        'id': request.id,
        'title': request.title,
        if (request.shared != null) 'card': request.shared!.toExt(),
      });
    } on Object catch (error) {
      // 子引擎要是还没起来（刚 create 那会儿），这次换内容就算了；
      // 那条线是双向的，等它起来主窗口再点一次就能对上
      debugPrint('[窗口] 让文章窗换一篇失败（忽略）：$error');
    }
  }
}
