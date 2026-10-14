// ignore_for_file: prefer_initializing_formals —— 依赖注入的构造参数与字段不同名（见下）
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/app_i18n.dart';

/// 前台服务没能起来（系统拒绝、或起来后又立刻倒了）。
///
/// 2026-09-19 真机实测（三星 S23 Ultra / Android 14）得到的两个事实：
/// 1. `startForegroundService` 是**异步**的——Dart 这边拿到回执时 `onStartCommand`
///    往往还没跑，所以「起没起」不能靠回执判断，只能读回状态
///    （见 [AndroidCallKeepAlive.start] 里的轮询）；
/// 2. 系统会**真的拒绝**：通知权限框把 App 顶到后台的那一瞬间去起 mic 类型的前台
///    服务，会被 while-in-use 校验拦下（`validateForegroundServiceType`），
///    服务侧抛 SecurityException。那种情况必须以「失败」收场（而不是假装成功）。
class CallKeepAliveException implements Exception {
  const CallKeepAliveException(this.message);

  final String message;

  @override
  String toString() => 'CallKeepAliveException($message)';
}

/// 通话期间的前台服务（S6.5）—— 安卓侧的 Dart 入口。
///
/// 解决的问题：App 切到后台/锁屏之后，进程随时会被系统冻结，媒体与 WS 信令就断在
/// 那儿（对方听到的是「打一半没了」）。安卓唯一的解法是通话期间挂一个**带常驻通知
/// 的前台服务**。Kotlin 那半在 `CallForegroundService.kt`（自己写的，没引插件，
/// 理由见 REFACTOR_PLAN 的 S6.5）。
///
/// 抽成接口的理由与 `MediaSaver` / 媒体层一样：平台能力只有真机能跑，而
/// **「每条结束路径都要停干净」这件事必须能在单测里钉住**（漏一条就会留下
/// 「麦克风正在使用」的常驻通知，用户会当成病毒）。
abstract interface class CallKeepAlive {
  /// 这个平台有没有「通话期间不让系统把进程冻住」这条路。
  ///
  /// 两端都有，但**不是同一件事**：
  /// * 安卓 = 前台服务（带常驻通知，见 [AndroidCallKeepAlive]）；
  /// * iOS = 一条活着的音频会话 + `UIBackgroundModes: audio`（见 [IosCallKeepAlive]）。
  ///
  /// 所以这个值只该被「要不要起保活」这类判断用；
  /// 「通知栏那条通话中」是安卓独有的，界面要单独判（见
  /// `features/call/call_keep_alive_notification_row.dart`）。
  bool get supported;

  /// 起保活。文案按当前语言拼好（安卓那条常驻通知里是中文/英文得跟着语言走）。
  ///
  /// 失败会**抛**（调用方自己决定怎么处理：控制器只记日志，绝不让保活失败影响通话）。
  Future<void> start({required bool video, required String peerName});

  /// 停服务（幂等：没起过也随便调）。
  Future<void> stop();

  /// 屏幕共享（S6.7）期间把前台服务的类型**加上 / 去掉** `mediaProjection`。
  ///
  /// 为什么不另起一个服务：安卓允许**一个前台服务同时声明多个类型**，所以这里
  /// 只是让同一个服务用多一位类型重新 `startForeground` —— 同一颗通知、同一个进程，
  /// 用户不会看到第二条通知，也不会多一个“正在使用”图标。
  ///
  /// ⚠️ 顺序是硬要求（Android 14）：**先拿到用户对投屏的同意 → 再升级类型 →
  /// 最后才 `getDisplayMedia()`**（否则取 MediaProjection 时抛 SecurityException）。
  /// 调用方在 `CallController.toggleScreenShare` 里按这个顺序排。
  Future<void> setScreenSharing({required bool enabled});

  /// 服务当前在不在跑（诊断面板那一行：「前台服务：运行中 (mic)」）
  Future<bool> isRunning();

  /// 有没有通知权限（安卓 13+）。**只查，不请求**。
  ///
  /// 为什么强调「不请求」：系统权限框会把 App 顶到后台，而 Android 14 不允许从
  /// 后台起 mic/camera 类型的前台服务（真机上验证过：那个框弹出的瞬间起服务，
  /// 会被 `validateForegroundServiceType` 拒掉）。所以**通话路径里只读状态**，
  /// 申请留给 [requestNotificationPermission] 那种用户明示的入口。
  /// 拒绝也**不影响服务运行**，只是通知不显示。
  Future<bool> hasNotificationPermission();

  /// 主动申请通知权限（只在设置页 / 自检面板这种用户明示的入口调）。
  Future<bool> requestNotificationPermission();
}

/// 安卓实现：一条 MethodChannel（`MainActivity` + `CallForegroundService`）
class AndroidCallKeepAlive implements CallKeepAlive {
  const AndroidCallKeepAlive({
    // 通道从外面注入：单测要替掉那条原生通道（同名参数写不成 `this._channel`，
    // 所以这个 `prefer_initializing_formals` 在本文件里整体忽略）
    MethodChannel? channel,
    this.startTimeout = const Duration(seconds: 2),
    this.pollInterval = const Duration(milliseconds: 100),
    this.typeTimeout = const Duration(seconds: 5),
  }) : _channel = channel;

  final MethodChannel? _channel;

  /// 起服务之后最多等多久算失败（异步启动，只能读回确认）
  final Duration startTimeout;

  /// 读回状态的间隔
  final Duration pollInterval;

  /// 等前台服务类型升降生效的上限（屏幕共享那一步用）。
  ///
  /// 比 [startTimeout] 宽：这一步卡住只影响共享，不该因为机器慢一点就把共享判死。
  final Duration typeTimeout;

  /// `ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION`（安卓那个枚举的位值）。
  static const int _mediaProjectionType = 32;

  static const MethodChannel _defaultChannel = MethodChannel(
    'gracelinkim/call_service',
  );

  MethodChannel get _methodChannel => _channel ?? _defaultChannel;

  @override
  bool get supported => true;

  /// 起服务，并**确认它真的起来了**。
  ///
  /// 为什么不能只看回执：`startForegroundService` 只是把意图交给系统，
  /// 服务真正 `startForeground` 是几百毫秒之后的事（真机实测：回执回来时读回
  /// 还是 `false`）。所以这里轮询确认——起不来就抛，让控制器记进诊断面板，
  /// 而不是假装成功（那种“看起来保活了、其实没保”的情况最难查）。
  @override
  Future<void> start({required bool video, required String peerName}) async {
    final i18n = AppI18n.instance;
    try {
      await _methodChannel.invokeMethod<void>('start', <String, dynamic>{
        'video': video,
        'title': i18n.t(
          video ? 'call.ongoingVideo' : 'call.ongoingVoice',
          <String, String>{'name': peerName},
        ),
        'text': i18n.t('call.keepBack'),
      });
    } on PlatformException catch (error) {
      // ⚠️ 2026-10-13：安卓 12 起**从后台启动前台服务会被系统拒绝**
      // （`ForegroundServiceStartNotAllowedException`，有的 ROM 给 `SecurityException`），
      // 而它正是在「刚取到媒体、正要起保活」那一刻被调用的 —— 国产 ROM 对后台启动更严。
      // 原生侧现在把这类系统拒绝翻成 PlatformException 回上来（以前是未捕获的
      // Java 异常 = 进程当场死 = 用户看到的「一打电话就闪退」）。
      // 这里收成 [CallKeepAliveException]：系统原文进诊断面板，**通话继续**。
      throw CallKeepAliveException('前台服务没起来：${_systemText(error)}');
    }

    final deadline = DateTime.now().add(startTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isRunning()) return;
      await Future<void>.delayed(pollInterval);
    }
    throw CallKeepAliveException('前台服务没有起来：${await _lastErrorReason()}');
  }

  /// 系统原文（拿不到 message 就退回 code）：诊断面板里要看清「到底为什么被拒」
  static String _systemText(PlatformException error) {
    final message = error.message ?? '';
    return message.isEmpty ? error.code : message;
  }

  /// 服务侧记下的失败原因。
  ///
  /// Android 14 在 while-in-use 校验不过时会抛 SecurityException（比如从这个
  /// App 从后台起 mic 类型的前台服务），原因必须能说出来 —— 否则真机上只剩
  /// 「保活就是不生效」这句毫无用处的结论。
  Future<String> _lastErrorReason() async {
    try {
      final reason = await _methodChannel.invokeMethod<String>('lastError');
      if (reason != null && reason.isNotEmpty) return reason;
    } catch (error) {
      debugPrint('[保活] 读取失败原因失败：$error');
    }
    return '系统没有给出原因（可能被电源策略直接拒绝）';
  }

  @override
  Future<void> stop() => _methodChannel.invokeMethod<void>('stop');

  @override
  Future<void> setScreenSharing({required bool enabled}) async {
    final i18n = AppI18n.instance;
    await _methodChannel.invokeMethod<void>('screenSharing', <String, dynamic>{
      'enabled': enabled,
      // 共享时通知里那句改成「正在共享屏幕」，否则还是「点击回到通话」
      'text': i18n.t(enabled ? 'call.sharingNotice' : 'call.keepBack'),
    });
    await _awaitScreenSharingType(enabled);
  }

  /// 等前台服务的类型位**真的**加上/去掉 `mediaProjection` 再返回。
  ///
  /// 与 [start] 同一个坑，而且真机上已经撞到了：`startService` 只是把意图交给系统，
  /// 服务重新 `startForeground` 是几百毫秒之后的事。而调用方紧接着就要去
  /// `getDisplayMedia()`，Android 14 又要求「取投影之前已经有一个带 mediaProjection
  /// 类型的服务在跑」—— 不等就会抛 SecurityException。
  ///
  /// 真机症状非常典型：**第一次点「共享屏幕」必定失败，再点一次就成功**
  /// （第一次那笔类型升级这时才落地）。所以这里必须读回确认。
  Future<void> _awaitScreenSharingType(bool enabled) async {
    final deadline = DateTime.now().add(typeTimeout);
    while (true) {
      final types = await _foregroundTypes();
      // 读不到（老原生侧没这个方法）就不拦：宁可少一层保护，
      // 也不要在没有这条风险的平台上把共享判成失败
      if (types == null) return;
      if (_hasProjection(types) == enabled) return;
      if (!DateTime.now().isBefore(deadline)) {
        throw CallKeepAliveException(
          enabled
              ? '前台服务没有升上 mediaProjection 类型：${await _lastErrorReason()}'
              : '前台服务没有摘掉 mediaProjection 类型',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  static bool _hasProjection(int types) => (types & _mediaProjectionType) != 0;

  /// 读回当前前台服务的类型位（`CallForegroundService.types`）
  Future<int?> _foregroundTypes() async {
    try {
      return await _methodChannel.invokeMethod<int>('foregroundTypes');
    } catch (error) {
      debugPrint('[保活] 查询前台服务类型失败：$error');
      return null;
    }
  }

  @override
  Future<bool> isRunning() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isRunning') ?? false;
    } catch (error) {
      // 诊断用的一行字，拿不到就当没在跑（不要因此弹提示）
      debugPrint('[保活] 查询前台服务状态失败：$error');
      return false;
    }
  }

  @override
  Future<bool> hasNotificationPermission() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'notificationPermission',
          ) ??
          true;
    } catch (error) {
      debugPrint('[保活] 查询通知权限失败：$error');
      return false;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } catch (error) {
      debugPrint('[保活] 申请通知权限失败：$error');
      return false;
    }
  }
}

/// iOS 实现：同一条通道（`gracelinkim/call_service`），做的却是另一件事 ——
/// **不是起服务，是把音频会话激活**。
///
/// 机制：iOS 上没有「常驻通知 + 前台服务」这种东西，切后台之后进程能不能活着由
/// **两件事**决定：Info.plist 里声明的 `UIBackgroundModes: audio`，以及一条真的
/// 处于 active 的 `AVAudioSession`。通话本来就在采麦克风，所以只要把会话设成
/// `playAndRecord` / `voiceChat` 并激活，系统就不会冻死我们 —— 效果与安卓那条
/// 前台服务一样（对方不会再听到「打一半没了」），只是**没有那条常驻通知**
/// （iOS 上那是系统来电界面 / CallKit 的事，属于买号之后那条路，
/// 见 docs/release/ios-plan.md）。
///
/// 与安卓实现的三个差别（都不是省略，是那边没有这些东西）：
/// * **不用轮询确认**：`setActive` 是同步的，回执回来时状态已经定了；安卓那边
///   `startForegroundService` 是异步的，非得读回一次才知道起没起；
/// * **没有通知文案**：`title` / `text` 是安卓常驻通知里那两行字，iOS 用不上
///   （所以 start 只把 `video` 发过去）；
/// * **没有类型位**：`setScreenSharing` 在 iOS 上是空的 —— 投屏要 ReplayKit 的
///   广播扩展，界面上那颗钮本来就不画（`supportsScreenShare` 不含 iOS）。
class IosCallKeepAlive implements CallKeepAlive {
  // 可注入的 `channel` 是为了单测能替掉那条通道（本文件顶部已整体忽略
  // prefer_initializing_formals）
  const IosCallKeepAlive({MethodChannel? channel}) : _channel = channel;

  final MethodChannel? _channel;

  static const MethodChannel _defaultChannel = MethodChannel(
    'gracelinkim/call_service',
  );

  MethodChannel get _methodChannel => _channel ?? _defaultChannel;

  @override
  bool get supported => true;

  @override
  Future<void> start({required bool video, required String peerName}) async {
    try {
      // peerName 不发：原生那一侧没有地方用它（没有通知可画）
      await _methodChannel.invokeMethod<void>('start', <String, dynamic>{
        'video': video,
      });
    } on MissingPluginException {
      // 旧安装包 / 还没实现这条通道：当成「起不来」，让控制器记一行诊断
      throw const CallKeepAliveException('这个 iOS 包里还没有保活通道（旧版本）');
    } on PlatformException catch (error) {
      // 原生侧把 `AVAudioSession` 那一步的报错原文抛上来（起不来/被别的应用占着）
      throw CallKeepAliveException('后台音频会话没起来：${_systemText(error)}');
    }
  }

  @override
  Future<void> stop() => _methodChannel.invokeMethod<void>('stop');

  @override
  Future<void> setScreenSharing({required bool enabled}) async {
    // iOS 上没有「给服务加一个投屏类型位」这回事（投屏要 ReplayKit 的广播扩展，
    // 那条路没做）。调用方被 `supportsScreenShare` 挡着，正常走不到这里；
    // 真调到了也什么都不做 —— 绝不能假装「升级成功了」，那样上层会去取屏，
    // 而 iOS 上取不到，失败会以更难懂的样子露出来。
  }

  @override
  Future<bool> isRunning() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isRunning') ?? false;
    } catch (error) {
      // 诊断用的一行字，拿不到就当没在跑（不要因此弹提示）
      debugPrint('[保活] 查询音频会话状态失败：$error');
      return false;
    }
  }

  @override
  Future<bool> hasNotificationPermission() async {
    try {
      return await _methodChannel.invokeMethod<bool>('notificationPermission') ??
          true;
    } catch (error) {
      debugPrint('[保活] 查询通知权限失败：$error');
      return false;
    }
  }

  @override
  Future<bool> requestNotificationPermission() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } catch (error) {
      debugPrint('[保活] 申请通知权限失败：$error');
      return false;
    }
  }

  /// 系统原文（拿不到 message 就退回 code）：诊断面板里要看清到底为什么没起来
  static String _systemText(PlatformException error) {
    final message = error.message ?? '';
    return message.isEmpty ? error.code : message;
  }
}

/// 没有保活的平台（桌面：进程挂了就挂了，那边也没有「通话中」的进程要被冻住）。
class NoopCallKeepAlive implements CallKeepAlive {
  const NoopCallKeepAlive();

  @override
  bool get supported => false;

  @override
  Future<void> start({required bool video, required String peerName}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setScreenSharing({required bool enabled}) async {}

  @override
  Future<bool> isRunning() async => false;

  @override
  Future<bool> hasNotificationPermission() async => true;

  @override
  Future<bool> requestNotificationPermission() async => true;
}

final callKeepAliveProvider = Provider<CallKeepAlive>((ref) {
  if (Platform.isAndroid) return const AndroidCallKeepAlive();
  if (Platform.isIOS) return const IosCallKeepAlive();
  return const NoopCallKeepAlive();
});
