/// 桌面「系统级独立窗口」里跑的那张界面（**第二颗 Flutter 引擎**，2026-10-04）。
///
/// 用户要的是微信 PC 那种：文章、灵听点开是**真正的系统窗口** —— 能拖出主窗口
/// 范围、任务栏单独一项、能 alt-tab 来回切。做到这一步只有一条路：每个窗口一颗
/// 独立引擎（`desktop_multi_window`，见 `REFACTOR_PLAN.md` 的 S12.22）。
///
/// 代价是这颗引擎**什么都没有**：没有主窗口那份 Riverpod 容器、没有 WS、没有
/// drift。所以这里自己起一份最小环境：
///
/// * 本地凭据（`CredentialStore`）与灵听那份（`LingtingStore`）—— 都是
///   `SharedPreferences`，两个引擎读的是同一个文件；
/// * 语言包（`AppI18n`）—— 窗口里的文案要跟主窗口一个语言；
/// * 一张小路由（[newsRoutes] / [lingtingRoutes]，与主 App 共用同一份表）；
/// * `desktopFeaturesProvider` 在这一支里关掉：窗口本来就几百像素宽，
///   按手机版式排（也不会再套一层桌面外壳）。
///
/// 反过来，聊天那几样**刻意不进来**：WS 长连接、消息数据库、推送注册 ——
/// 窗口里一个都用不到，多建一份只会互相打架（同一份 drift 文件两个 isolate 写）。
library;

import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/store/credential_store.dart';
import '../../core/store/lingting_store.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/news/news_card.dart';
import '../call/call_window.dart';
import 'desktop_link_window.dart';
import 'desktop_web_window.dart';
import 'desktop_window_native.dart';
import 'desktop_window_service.dart';
import 'web_tabs.dart';
import 'window_args.dart';

/// 子引擎的入口。是窗口进程 → 起窗口界面并返回 true；否则返回 false（主窗口
/// 那条启动链继续往下走）。
Future<bool> runDesktopChildWindow(List<String> args) async {
  final windowArgs = windowArgsOf(args);
  if (windowArgs == null) return false;

  WidgetsFlutterBinding.ensureInitialized();

  // 本地凭据与灵听那份：两个引擎读的是同一个 SharedPreferences。
  final store = await CredentialStore.init();
  await LingtingStore.init();
  // 语言：跟主窗口一个来源（用户手动选过就用他那份，没选过跟系统）
  await AppI18n.load(store.language ?? LocaleController.systemLocaleCode());

  runApp(
    ProviderScope(
      // 窗口里按手机版式排（见文件头注释）；但「宽度封顶居中」那只壳要开着 ——
      // 它默认跟着桌面功能开关走，而那个开关在窗口里是关的（测试环境同理）
      overrides: [
        desktopFeaturesProvider.overrideWithValue(false),
        desktopShellProvider.overrideWithValue(true),
        // 窗里点外链，照样开成**另一扇窗口**（用户 2026-10-04 要的「网页也开成
        // 独立窗口」）：这条与本窗口自己那套手机版式无关 —— 版式归
        // `contentMaxWidth` 管，这条只管「点链接去哪儿」。
        desktopLinkWindowProvider.overrideWithValue(true),
        // 本颗引擎就是**网页窗**：里面的内嵌浏览器不该再开一扇网页窗（自己套自己）。
        // 网页窗现在是标签那套界面（不推 `/mine/webview`），这条留着是防
        // 「这颗引擎里再冒出内嵌浏览器那一页」时又套出第二扇窗。
        if (windowArgs.kind == DesktopWindowKind.web)
          webWindowHostProvider.overrideWithValue(true),
      ],
      child: DesktopChildRoot(args: windowArgs),
    ),
  );
  return true;
}

/// 窗口的界面：一张小路由 + 一个 MaterialApp，外加跟 native / 主窗口的两条线。
class DesktopChildRoot extends ConsumerStatefulWidget {
  const DesktopChildRoot({super.key, required this.args});

  final DesktopWindowArgs args;

  @override
  ConsumerState<DesktopChildRoot> createState() => _DesktopChildRootState();
}

class _DesktopChildRootState extends ConsumerState<DesktopChildRoot> {
  late final GoRouter _router = GoRouter(
    initialLocation: _initialLocation,
    routes: _routes,
  );

  /// 主窗口 ↔ 这颗窗口的那条线（一个 kind 一条）。
  ///
  /// **单向模式**（2026-10-04 改）：双向那条路只允许「成对的两个引擎」互相调，
  /// 而调用方（主窗口、或另一位子窗口）压根没注册过这条通道 —— 于是打过来的
  /// `ping` 全部回 `CHANNEL_UNREGISTERED`，`_findAlive` 每次都以为「那颗窗已经
  /// 关了」，一个 kind 就叠出第二扇。改成单向：**谁都能调、只有装得上手的
  /// 这一颗能注册**，正好是我们要的样子（见 `desktop_window_service.dart`）。
  late final WindowMethodChannel _channel = WindowMethodChannel(
    _channelName,
    mode: ChannelMode.unidirectional,
  );

  /// 网页窗那一排标签（只有 web 这一支有）。
  ///
  /// 为什么不像别的窗口那样把内容交给 `GoRouter` 管：标签是**窗口自己的状态**
  /// —— 切标签不是导航，关掉最后一个标签也不是「退到哪一页」，而是关掉整扇窗
  /// （见 `desktop_web_window.dart`）。路由只管把这一张界面摆出来。
  late final WebTabsController? _tabs =
      widget.args.kind == DesktopWindowKind.web
      ? WebTabsController(url: widget.args.url, title: widget.args.title)
      : null;

  List<RouteBase> get _routes => switch (widget.args.kind) {
    // 文章窗与媒体号窗共用同一份资讯路由：文章窗起来之后直接推到那一篇上，
    // 媒体号窗就停在列表上（点进去的文章在这颗窗口里往下推）
    DesktopWindowKind.article || DesktopWindowKind.news => <RouteBase>[
      ...newsRoutes(),
      // 「阅读原文」也是外链：内嵌浏览器 + 两道闸门在这颗引擎里也得挂着，
      // 不然点下去直接 404（2026-10-04 用户报的那条）
      ...externalLinkRoutes(),
    ],
    DesktopWindowKind.lingting => <RouteBase>[
      ...lingtingRoutes(),
      ...externalLinkRoutes(),
    ],
    // 网页窗：顶上一条标签栏 + 当前那一页（多标签，2026-10-04）。
    // 闸门不进来：能开这扇窗的地址**已经过完闸门**了（确认页点下「继续访问」
    // 或官方站点直进，见 `core/ui/link_opener.dart`）。
    DesktopWindowKind.web => <RouteBase>[
      GoRoute(
        path: AppRoutes.webview,
        builder: (context, state) => DesktopWebWindow(controller: _tabs!),
      ),
    ],
    // 通话窗（2026-10-04）：一颗窗口一通电话，里面就是那张微信 PC 版式的界面
    // ——真媒体引擎也在这颗引擎里（见 `call_window.dart`）。
    DesktopWindowKind.call => <RouteBase>[
      GoRoute(
        path: AppRoutes.call,
        builder: (context, state) => DesktopCallWindow(args: widget.args),
      ),
    ],
  };

  String get _initialLocation => switch (widget.args.kind) {
    DesktopWindowKind.article || DesktopWindowKind.news => AppRoutes.newsList,
    DesktopWindowKind.lingting => AppRoutes.lingtingHome,
    // 网页窗那一条路由不带参数：地址在 `_tabs` 里
    DesktopWindowKind.web => AppRoutes.webview,
    DesktopWindowKind.call => AppRoutes.call,
  };

  String get _channelName => 'gracelink/window/${widget.args.kind.name}';

  @override
  void initState() {
    super.initState();
    // 文章窗：从列表起手、再推到那篇文章上 —— 这样窗口里那支返回箭头能回到
    // 资讯列表（微信 PC 的文章窗也是能往回翻的），而不是一发文章就回不去。
    final id = widget.args.id;
    if (widget.args.kind == DesktopWindowKind.article && id.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        // 卡片本体要一起带上：本机列表里没这一篇时详情页就靠它渲染
        (_) => _openArticle(id, card: widget.args.shared),
      );
    }
    unawaited(_setup());
  }

  @override
  void dispose() {
    _tabs?.dispose();
    _router.dispose();
    super.dispose();
  }

  /// 让窗口出来，然后把跟主窗口那条线接上。
  ///
  /// 顺序有两道讲究：
  /// * 窗口是 `hiddenAtLaunch` 建的（不然会先闪一下原生默认的 800×600），
  ///   所以标题/大小/居中必须**在显形之前**设好；
  /// * 跟主窗口那条线**排在显形之后**，而且不能叫它把开窗拖住：
  ///   通道那头没回應时 `setMethodCallHandler` 会一直等（写这一版时先挂线、
  ///   结果窗口永远出不来），窗口自己出来才是正事，“换一篇”晚一拍没关系。
  Future<void> _setup() async {
    final geometry = _geometryOf(widget.args);
    await DesktopWindowNative.setTitle(_title);
    if (geometry != null) {
      await DesktopWindowNative.setSize(geometry.width, geometry.height);
    }
    await DesktopWindowNative.center();
    await DesktopWindowNative.show();
    debugPrint(
      '[窗口] ${widget.args.kind.name} 窗口就绪：'
      'title=$_title id=${widget.args.id}',
    );

    // 通话窗**自己**占着这条线（它的页面要接 media/state/bye，见 `call_window.dart`）：
    // 一条通道在单向模式下只允许一颗引擎注册，两边都注册的话后到的那个直接报错，
    // 而**先到的那个赢** —— 那条线就会落到下面这个只会 open_article/ping/open_url
    // 的通用处理上，主窗口的媒体指令全部变成「不认识这个调用」。所以这里让开。
    if (widget.args.kind != DesktopWindowKind.call) {
      try {
        await _channel.setMethodCallHandler(_onMainCall);
      } on Object catch (error) {
        debugPrint('[窗口] 主窗口那条线没挂上（换内容/对账会失效）：$error');
      }
    }
  }

  String get _title {
    final given = widget.args.title;
    if (given.isNotEmpty) return given;
    // 网页窗顶上就是域名（微信 PC 那扇浏览器窗口也是这么写的）
    if (widget.args.kind == DesktopWindowKind.web) {
      return webWindowTitleOf(widget.args.url);
    }
    return ref.read(appI18nProvider).t('lingting.title');
  }

  /// 主窗口叫我们做的事：换一篇 / 打个招呼。
  Future<dynamic> _onMainCall(MethodCall call) async {
    switch (call.method) {
      case 'open_article':
        final data = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : <String, dynamic>{};
        final id = (data['id'] as String?) ?? '';
        if (id.isNotEmpty) {
          final card = _cardOf(data['card']);
          await DesktopWindowNative.setTitle(
            (data['title'] as String?) ?? _title,
          );
          await Future<void>.delayed(Duration.zero);
          _openArticle(id, card: card);
        }
        return <String, dynamic>{'ok': true};
      case 'ping':
        return <String, dynamic>{
          'kind': widget.args.kind.name,
          // 网页窗那行字跟着**当前标签**走（别拿开窗时那一条去回答对账）
          'title': _tabs?.active?.label ?? _title,
        };
      // 主窗口又点了一条外链：**多开一个标签**（同址去重切过去，见
      // `web_tabs.dart`）。另外几件事界面自己接着做 —— 标签条跟着重画、
      // 原生标题栏换成当前标签（`DesktopWebWindow` 那条监听）。
      case 'open_url':
        final data = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : <String, dynamic>{};
        final url = (data['url'] as String?) ?? '';
        if (url.isNotEmpty) {
          _tabs?.open(url: url, title: (data['title'] as String?) ?? '');
        }
        return <String, dynamic>{'ok': true};
      default:
        throw MissingPluginException('窗口不认识这个调用：${call.method}');
    }
  }

  /// 换文章：本来就在看文章 → **换掉**那一页（返回仍然回列表，不会越翻越深）；
  /// 人已经退回到列表了 → 正常推一篇回去。
  void _openArticle(String id, {NewsCard? card}) {
    final location = '${AppRoutes.newsDetail}?id=${Uri.encodeComponent(id)}';
    final onDetail = _router.state.uri.path == AppRoutes.newsDetail;
    if (onDetail) {
      _router.pushReplacement(location, extra: card);
    } else {
      _router.push(location, extra: card);
    }
  }

  static NewsCard? _cardOf(Object? raw) {
    if (raw is Map) return NewsCard.fromExt(Map<String, dynamic>.from(raw));
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final locale = LocaleController.flutterLocaleOf(
      ref.watch(localeProvider).code,
    );
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Gracelink',
      theme: AppTheme.light,
      routerConfig: _router,
      locale: locale,
      supportedLocales: <Locale>[
        for (final option in LocaleController.options)
          LocaleController.flutterLocaleOf(option.code),
      ],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // 宽度封顶、居中（见 [DesktopShell]）：窗口最大化之后内容不跟着胀大 ——
      // 封顶这档就是这颗窗口默认开出来的宽度，所以默认大小下一点没变。
      //
      // 网页窗例外：它装的就是一页网页，没有手机版式那回事，套上 500 的封顶
      // 只会把网页压成一条（而且外面那层灰底会露出两道边）。
      // 网页窗与通话窗例外：网页窗装的是一页网页，通话窗是固定版式的整幅界面，
      // 套上那 500 的封顶只会把它们压成一条。
      builder: (context, child) =>
          widget.args.kind == DesktopWindowKind.web ||
              widget.args.kind == DesktopWindowKind.call
          ? child ?? const SizedBox.shrink()
          : DesktopShell(
              contentMaxWidth: _geometryOf(widget.args)?.width,
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.3,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
    );
  }
}

/// 每颗窗口开出来多大（逻辑像素；原生那边按窗口所在显示器的 DPI 折算）。
///
/// 宽度这一档同时是**内容封顶宽度**（见 build 里的 [DesktopShell]）：窗口被拉宽
/// /最大化之后内容还是这个宽度、居中摆，不会跟着 `rpx` 一起胀大。
Size? _geometryOf(DesktopWindowArgs args) => switch (args.kind) {
  // 文章要能读正文：比灵听那条列宽一点
  DesktopWindowKind.article => const Size(560, 720),
  // 灵听是整条频道（列表 + 播放页），手机竖屏那个比例
  DesktopWindowKind.lingting => const Size(520, 700),
  // 媒体号：一列资讯（带大图），比文章窗略宽、矮一点
  DesktopWindowKind.news => const Size(560, 760),
  // 网页窗：一页网页，按浏览器那档给（也正因为如此，上面 build 里它不套
  // `DesktopShell` 那个宽度封顶）
  DesktopWindowKind.web => const Size(1000, 720),
  // 通话窗：微信 PC 那个通话窗就是个不大不小的方窗；视频那一档要能放下
  // 「对方铺满 + 右上角自己的小窗」，所以宽一点（真正的尺寸在
  // `call_window.dart::_setup` 里又按视频与否定了一次，这条只管兜底）
  DesktopWindowKind.call =>
    args.video ? const Size(600, 700) : const Size(420, 620),
};
