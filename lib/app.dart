import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/i18n/app_i18n.dart';
import 'core/i18n/locale_controller.dart';
import 'core/platform/desktop_shell.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/ui/notice_handler.dart';
import 'features/call/call_host.dart';
import 'features/call/call_push_host.dart';
import 'features/group_call/group_call_banner_host.dart';
import 'features/group_call/group_call_mini_bar.dart';
import 'features/group_call/group_call_push_host.dart';
import 'features/desktop_window/tray_native.dart';
import 'features/notify/notification_host.dart';

/// 应用根 Widget。
///
/// 语言跟随 [localeProvider]：登录页右上角 / 我的-界面与显示里能选
/// 「跟随系统」与简体 / 繁体 / 英 / 日 / 西 / 法 / 德；选过具体语言就存本地、
/// 重启后保持，选「跟随系统」（或从没选过）则看系统（对不上落英语，
/// 见 [LocaleController]）—— 而且**系统语言在设置里一改，界面就跟着换**，
/// 靠的就是下面那个 [WidgetsBindingObserver]。
class GracelinkApp extends ConsumerStatefulWidget {
  const GracelinkApp({super.key});

  @override
  ConsumerState<GracelinkApp> createState() => _GracelinkAppState();
}

class _GracelinkAppState extends ConsumerState<GracelinkApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // 系统语言变了要能收到（安卓：「设置 → 语言与输入」一改就发这条通知）
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 系统语言变了：**只有「跟随系统」那一档**才跟着换。
  ///
  /// 换语言要读语言包（异步），这里不能等它 —— 换好之后 `localeProvider`
  /// 会通知界面重建，用户看到的就是新语言。
  @override
  void didChangeLocales(List<Locale>? locales) {
    unawaited(ref.read(localeProvider.notifier).syncWithSystem());
  }

  @override
  Widget build(BuildContext context) {
    final choice = ref.watch(localeProvider);
    final locale = LocaleController.flutterLocaleOf(choice.code);

    // 托盘（Windows 桌面，S12.36）：关窗只是缩回托盘，那两项菜单的字得跟着
    // 语言走。这里每次重建都叫一次，同一语言它自己会去重（见 [TrayNative.configure]）；
    // 非 Windows / 老 runner 上静默忽略。
    unawaited(TrayNative.configure(ref.watch(appI18nProvider)));

    return MaterialApp.router(
      // 任务切换器/系统里显示的那个名字（用户 2026-09-27：把默认的「IM」
      // 那些叫法统一成 Gracelink）
      title: 'Gracelink',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      // 网络层的提示通过这个 key 弹出来（见 NoticeHandler）
      scaffoldMessengerKey: appMessengerKey,
      routerConfig: ref.watch(appRouterProvider),
      // 通知宿主在最外层：它要跟踪前后台（决定收消息是响一声还是弹通知），
      // 还得能在任何页面上把「点通知」跳到对应会话；
      // 推送来电的宿主紧挨着它：App 被**来电通知**冷启动时要抢在界面之前把
      // 那通电话接进通话链路（S8.1h）—— 它和通知宿主看的是同一批通知，
      // 所以必须在同一层（谁先 initState 都不影响：两边都走 presenter 自己缓存的那份）；
      // 群通话邀请的宿主再套一层（S6.14）：同一份通知里还有「群里有人开语音」那一条，
      // 点它要进的是群通话页（不是来电链路），落点不同、各管各的；
      // 再往外是**群通话的应用内横幅**（S6.15）：App 开着的人不走通知那条路，
      // 靠它把「有人在群里开了语音」飘在屏幕最上面（会话列表那一行还留着标记）；
      // 它的里侧是**群通话小窗**（S6.17）：退出通话页之后那一通话还在跑，
      // 靠这颗可拖的药丸告诉用户「你还在通话里」并点回页面；
      // 通话页盖在所有页面之上：会话一起来就 push、结束就 pop（S6.3）。
      //
      // 外面再套一层**字号上限**（2026-09-25 排查时加的）：全站版式是按
      // `rpx`（屏宽比例）画的，行高、按钮高度、导航栏都是写死的数字 —— 系统的
      // 「超大字号」（无障碍里的 2.0×）会把文字撑出容器，轻则省略号、重则红黄
      // 条纹的溢出警告。微信这类 App 也是把系统字号的影响控在一个幅度内，
      // 这里放宽到 1.3 倍：想看清的放大 30% 够用，版式不会散。
      // 只封上限、不动下限（用户调小便按调小的来）。
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        // 桌面形态（2026-10-03）：Windows 上窗口可以拉得很宽，而整站版式
        // 是按手机屏宽画的（`rpx` = 屏宽 / 750）。把内容封顶居中，
        // 顺带把子树看到的宽度改成 500 —— 那些尺寸就都回到手机那一档了。
        // 窄窗口（≤500）时它什么都不做；测试里默认关着（见 desktopShellProvider）。
        child: DesktopShell(
          child: NotificationHost(
            child: CallPushHost(
              child: GroupCallPushHost(
                child: GroupCallBannerHost(
                  child: GroupCallMiniBarHost(
                    child: CallHost(child: child ?? const SizedBox.shrink()),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      locale: locale,
      // Material / Cupertino 自己那套文案（日期选择器、弹出菜单的无障碍标签…）
      // 按同一份名单走；中文带脚本，否则 GlobalMaterialLocalizations 认不出来
      supportedLocales: <Locale>[
        for (final option in LocaleController.options)
          LocaleController.flutterLocaleOf(option.code),
      ],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
