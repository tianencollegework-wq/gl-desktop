import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/router/app_router.dart';
import 'core/config/app_config.dart';
import 'core/i18n/app_i18n.dart';
import 'core/i18n/locale_controller.dart';
import 'core/notify/push_background.dart';
import 'core/router/session_guard.dart';
import 'core/store/cleared_chats.dart';
import 'core/store/credential_store.dart';
import 'core/store/lingting_store.dart';
import 'core/store/saved_accounts.dart';
import 'core/store/session_store.dart';
import 'core/ui/notice_handler.dart';
import 'domain/call/call_sync_service.dart';
import 'domain/chat/chat_sync_service.dart';
import 'domain/lingting/lingting_audio_handler.dart';
import 'domain/session/session_service.dart';
import 'features/desktop_window/child_window_app.dart';
import 'features/group_call/group_call_session.dart';
import 'features/group_call/group_call_sync.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面「系统级独立窗口」（文章 / 灵听）那颗引擎到这里就分流（2026-10-04）：
  // 窗口进程只跑窗口那张界面（自己一份最小环境），**不**连 WS、不建 drift、
  // 不注册推送 —— 见 `features/desktop_window/child_window_app.dart`。
  if (await runDesktopChildWindow(args)) return;

  // 0pre. **锁死竖屏**（用户 2026-09-27：「能不能强制软件竖屏，不允许横屏」）。
  //
  // 安卓那一侧还有一道硬锁（`AndroidManifest.xml` 里的
  // `android:screenOrientation="portrait"`）—— 两道都要：manifest 管的是
  // 「系统准不准转」，这里管的是「Flutter 自己的方向偏好」（iOS 侧就靠它）。
  //
  // 只给 `portraitUp`：连倒着的竖屏也不要（微信也一样），
  // 全站版式是按竖屏宽度用 `rpx` 算的，横过来只会到处溢出。
  // ⚠️ 这一步**必须有上限**（2026-10-08 真机白屏的病因就在这一句）：
  //
  // audio_service 的暖机（推送到达时把进程拉起来那一下）会建一个**还没有 Activity
  // 的引擎**并把 `main()` 跑起来。那种引擎里平台侧收下这条消息却**永远不会回**，
  // 原来那个 `await` 就卡死在这里 —— 后面每一行都不执行、`runApp` 到不了，
  // 系统只好一直停在白底启动图上；用户此时点通知，也只是把这块白底唤醒。
  //
  // 超时纯当保险：正常（有界面）启动时平台侧毫秒级就回复；
  // 安卓「锁死竖屏」的硬锁在 `AndroidManifest.xml`（`screenOrientation="portrait"`），
  // 这一句只是 Flutter 自己的方向偏好，晚一步 / 收不到都不影响竖屏。
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]).timeout(
    const Duration(seconds: 2),
    // 走到这里说明是「无界面引擎」（推送把进程拉起来时 audio_service 的暖机），
    // 平台侧不会回这条消息 —— 这一行就是那种情况的信号，别当报错看。
    onTimeout: () => debugPrint('[启动] 没有界面可锁方向，先继续'),
  );

  // 0. 推送的后台入口（S8.1）：必须在 runApp 之前注册 ——
  //    App 没在跑时由它在后台 isolate 里弹通知。内部整段吞异常。
  startPushBackgroundHandler();

  // 1. 域名自检（老端对齐，不匹配只警告，原因见 AppConfig 注释）
  const config = AppConfig.current;
  config.logSelfCheck();

  // 2. 本地存储与语言包
  final store = await CredentialStore.init();
  // 灵听（音乐频道）自己那份凭据与偏好：另一套账号体系，单独存
  await LingtingStore.init();
  // 语言：手动选过就用他那份，没选过就跟系统语言（对不上落英语）
  await AppI18n.load(store.language ?? LocaleController.systemLocaleCode());
  // 「清空聊天记录」的名单也在本地存储里，读回来之后仓库层才能把旧消息丢掉
  ClearedChatsStore.instance.reload();
  // 可切换账号（S10.1）那份列表：切换页与「退出登录后条目还在」都要读它
  SavedAccountsStore.instance.reload();

  // 2b. 灵听（音乐）的媒体会话：通知栏/锁屏/耳机键那一份。
  //     必须在 runApp 之前建 —— 它是**常驻**的媒体会话，不归任何页面管。
  //     起不来也只是没有通知栏那一份，播放不受影响（内部整段吞异常）。
  await initLingtingAudioService();

  // 3. 容器
  final container = ProviderContainer();

  // 4. 路由守卫跟随会话状态（登录 / 登出 / 被顶下线都会触发重新跳转）
  container.listen<SessionState>(
    sessionStoreProvider,
    (previous, next) =>
        sessionGuard.update(ready: next.ready, hasSession: next.isLoggedIn),
    fireImmediately: true,
  );

  // 5. 会话链路：注册 WS 处理器 → 连 WS（就绪后自动 bindUid）→ 后台拉全局配置。
  //    注意这一步不 await 网络部分（bootstrap 内部也只是发起），界面不等它。
  await container.read(sessionServiceProvider).bootstrap();

  // 6. 聊天链路：注册消息推送处理器；登录态一变就同步一次会话列表
  //    （老端是进消息页时拉 `getContacts`，新端放在登录成功那一刻）
  final chatSync = container.read(chatSyncServiceProvider)..start();

  container.listen<SessionState>(sessionStoreProvider, (previous, next) {
    // 「换人了」：切换账号（S10.1）时登录态前后都是 true，不走下面那条「登录态翻转」，
    // 但当前账号确实变了 —— 上一个账号的通讯录、群语音那本账、正在跑的那一通
    // 都得收掉（`session_service.switchAccount` 只负责换令牌与重连）。
    final personChanged =
        previous != null && previous.userId != next.userId && next.isLoggedIn;
    if (previous?.isLoggedIn == next.isLoggedIn && !personChanged) return;

    if (!next.isLoggedIn || personChanged) {
      // 登出要清本地通讯录（异步），但不阻断界面切到登录页
      unawaited(chatSync.onLoggedOut());
      // 「谁在开群语音」那本账也跟着清（S6.15）：换个账号接着用时，
      // 不该还挂着上一个账号的群（横幅最多 20 秒，但会话列表那行标记是长住的）
      container.read(groupCallPresenceProvider).reset();
      // 正在跑的那一通群通话也收掉（S6.17）：它已经不属于任何页面了，
      // 换账号接着用时更不可能还是同一通（会话、保活、媒体一起收）
      unawaited(container.read(groupCallSessionProvider).reset());
    }
    if (next.isLoggedIn) {
      // 登录 / 切换账号之后对齐一次会话列表与通讯录
      unawaited(chatSync.onLoggedIn());
    }
  }, fireImmediately: true);

  // 7. 通话链路：注册 `webrtc` 信令处理器（来电、接通、挂断、ICE 都走这一条路）
  container.read(callSyncServiceProvider).start();

  // 7.5 群通话链路：`sfuRoom`（有人进来/走了/换了会话）→ 两件事一起接住：
  //    正在进行的那个房间立刻对账（没接它的话，别人进来了要等心跳或 5 秒一次的定期回查才发现），
  //    以及**没在通话里的人**的应用内横幅与会话列表标记（`live` / `started`，S6.15）。
  container.read(groupCallSyncServiceProvider).start();

  NoticeHandler(container).start();

  // 8. 点通知栏那一份回到播放页。
  //    只在「已经在别处」时补一刀：用户本来就在播放页时再 push 一次会叠一层。
  //    这个订阅与 App 同命（不需要取消）。
  AudioService.notificationClicked.listen((clicked) {
    if (!clicked) return;
    try {
      final router = container.read(appRouterProvider);
      if (router.routerDelegate.currentConfiguration.uri.path ==
          '/lingting/player') {
        return;
      }
      router.push('/lingting/player');
    } on Object catch (error) {
      debugPrint('[灵听] 点通知回播放页失败：$error');
    }
  });

  debugPrint('[启动] ${config.apiUrl} / ${config.wssUrl}');

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const GracelinkApp(),
    ),
  );
}
