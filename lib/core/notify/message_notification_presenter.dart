import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/chat/message_notification.dart';
import '../../domain/group_call/group_call_push.dart' show groupCallPushType;
import '../i18n/app_i18n.dart';
import '../util/json_value.dart' show asMap, asText;

/// 把「一条新消息」画成系统通知栏（老端靠 uni-app 的 **push 模块**
/// `uni.createPushMessage` 做这件事；Flutter 端的等价物就是这个接口）。
///
/// 抽成接口的理由与 `MediaSaver` / `CallKeepAlive` / `AppInstaller` 一样：
/// 通知是平台能力，单测里跑不了；而「该不该弹、弹什么」的判断必须能钉住。
/// 一条要弹到通知栏上的**来电**（S8.1h）。
///
/// 与消息通知是两个独立渠道：用户静音「消息」时**不该把来电一起静音**，
/// 反过来也一样。
@immutable
class IncomingCallNotification {
  const IncomingCallNotification({
    required this.title,
    required this.body,
    required this.payload,
  });

  /// 通知标题（来电人昵称；取不到时上游会给通用文案）
  final String title;

  /// 通知正文（「[语音通话]」/「[视频通话]」）—— 由调用方算好，
  /// 与聊天列表、消息通知共用同一套文案规则
  final String body;

  /// 整条 `calling` 报文（JSON 字符串）。
  ///
  /// 点通知 / 冷启动时要靠它重建会话 —— 这就是为什么不用「会话 id」当 payload：
  /// App 被杀时，只靠会话 id 是接不起一通电话的。
  final String payload;

  @override
  bool operator ==(Object other) =>
      other is IncomingCallNotification &&
      other.title == title &&
      other.body == body &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(title, body, payload);
}

abstract interface class MessageNotificationPresenter {
  /// 初始化（建通知渠道、注册点击回调）。
  ///
  /// 返回**待处理的会话 id**：App 是被「点通知」拉起来的时候，那条通知指向哪个会话
  /// （进程当时已经没了，所以只能在这里把意图交回去）。
  Future<String?> initialize({required ValueChanged<String> onOpen});

  /// 通知权限开着没（安卓 13+ 要用户授权）
  Future<bool> enabled();

  /// 申请通知权限（已授权时是空操作）
  Future<bool> requestPermission();

  /// 弹一条通知（同一个会话会覆盖上一条）
  Future<void> show(MessageNotification notification);

  /// 清掉某个会话的通知（进聊天页时用）
  Future<void> cancel(String conversationId);

  /// 清掉全部（退出登录时用）
  Future<void> cancelAll();

  // ------------------------------------------------------------ 来电（S8.1h）

  /// 弹一条**来电**通知：独立渠道、最高重要性、全屏、响铃。
  ///
  /// 全屏（full-screen intent）是「锁屏/息屏时直接亮屏弹来电界面」的关键；
  /// 安卓 14 起要用户在系统里允许（入口在设置页那一行，见 `FullScreenIntentRow`），
  /// 没允许时系统降级成横幅 + 响铃 —— 不是错误，所以这里不报错。
  Future<void> showIncomingCall(IncomingCallNotification call);

  /// 收掉来电通知（接听 / 拒接 / 对方挂断 / 响铃超时都要收）
  Future<void> cancelIncomingCall();

  /// 用户点开**来电**通知时回调（App 还在跑那条路）。参数是那条 `calling` 报文。
  void onIncomingCallOpen(ValueChanged<String> handler);

  /// App 是**被来电通知**拉起来的？是的话把那条 `calling` 报文交回来。
  ///
  /// 只能取一次（取完就忘）：进程当时已经没了，这是把「用户点的是哪条通知」
  /// 带回业务层的唯一机会。必须在 [initialize] 之后调（实现里会等它）。
  Future<String?> takeLaunchIncomingCall();

  // ------------------------------------------------------- 群通话邀请（S6.14）

  /// 弹一条**群通话邀请**：群里有人开语音，点它进那个群的群通话页（进去就是加入）。
  ///
  /// 与来电**刻意分成两个通知位**（各有各的 id、各收各的）：
  ///
  /// * 两件事会同时发生（正在响一通 1:1 来电时群里又开了一场语音），共用一个 id
  ///   会让后来者把前一条顶掉 —— 顶掉的如果是来电，就是漏接一通电话；
  /// * 样式也不一样：来电要**全屏**（息屏时直接弹来电界面），群邀请不该全屏
  ///   （它不是指名道姓找你的电话，只是一句「有人在群里开了语音」）。
  ///
  /// 相同的是**渠道**：与来电走同一条「响铃」渠道 —— 这正是要的，邀请也得响铃。
  Future<void> showGroupCallRing(IncomingCallNotification invite);

  /// 收掉群通话邀请（这通群语音结束了，服务端会补一条静默推送来叫这一步）。
  Future<void> cancelGroupCallRing();

  /// 用户点开**群通话邀请**时回调（App 还在跑那条路）。参数是那条邀请报文。
  void onGroupCallOpen(ValueChanged<String> handler);

  /// App 是**被群通话邀请**拉起来的？是的话把那条报文的 JSON 交回来。
  ///
  /// 与 [takeLaunchIncomingCall] 一样只能取一次（进程当时已经没了），
  /// 也必须等 [initialize] 完成后再调。
  Future<String?> takeLaunchGroupCall();
}

/// 通知 payload 的三种形状（S6.14）。
///
/// 消息通知的 payload 一直是**纯会话 id**；通话那两类放的是**整条报文 JSON**
/// （1:1 是 `calling` 帧，群通话是 `group_call` 帧）—— 点通知时要按形状分流到
/// 三个不同的落点（会话页 / 来电链路 / 群通话页）。
enum _PayloadKind { conversation, incomingCall, groupCall }

/// 真机实现：官方 `flutter_local_notifications`
class LocalMessageNotificationPresenter
    implements MessageNotificationPresenter {
  LocalMessageNotificationPresenter({
    FlutterLocalNotificationsPlugin? plugin,
    String Function(String key)? translate,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _t = translate ?? ((key) => key);

  final FlutterLocalNotificationsPlugin _plugin;
  final String Function(String key) _t;

  /// 通知渠道 id。**改这个字符串等于换了条渠道**：渠道名/重要性在系统里是按 id
  /// 记的，改 id 会让用户之前设过的「静音这条渠道」失效，所以定下来就别动。
  static const String channelId = 'gracelinkim_message';

  /// 来电通知的渠道 id（S8.1h）。
  ///
  /// 与消息那条**刻意分开**：用户静音「消息」时不该把来电一起静音；
  /// 系统里也能给来电单独设铃声。
  ///
  /// ⚠️ **id 改过两次，不要再改回去**（渠道的重要性/声音/铃声由**第一次创建它的那次**
  /// 决定，之后谁都改不了，只能换一个新 id 才拿得到新设置）：
  ///
  /// * 第一版 `gracelinkim_call`：与安卓那个「通话中」前台服务的常驻通知渠道**撞了同一个
  ///   id**，服务先把它创成了 LOW + 静音 —— 来电通知于是永远没有横幅、没有声音、全屏也
  ///   不生效（真机 2026-09-20：「只有一行文案」）。前台服务已换到 `gracelinkim_call_service`。
  /// * 第二版 `gracelinkim_call_incoming`：重要性对了（真机 dump 实测 `mImportance=5`），
  ///   但铃声用的是**系统默认通知音**（一声「叮」）—— 真机上「通知响了但不是铃声」。
  ///   这一版换成系统**来电铃声** + `USAGE_NOTIFICATION_RINGTONE`，并把开关从
  ///   `ongoing` 放开（见 [showIncomingCall] 的注释）。
  static const String callChannelId = 'gracelinkim_call_ring';

  /// 来电通知的铃声：系统的**当前来电铃声**（不是通知提示音）。
  ///
  /// 真机实测这个 uri 能被解析（`content query --uri content://settings/system/ringtone`
  /// 返回用户实际设的那首），所以「通知响起来就是他手机的铃声」。
  ///
  /// 说明一句**系统的硬限制**：通知声音不能循环，也不会自己去停 —— 它跟着通知走，
  /// 通知被收掉（接听/拒接/45 秒超时/对方取消）声音才停。所以真正的「一直响到你接」
  /// 只能由正在运行的 App 去放（[CallTones] 那条链就是这么做的），通知这条只是
  /// 在 App 还没起来的那几秒把铃声接上。
  static const String callRingtoneUri = 'content://settings/system/ringtone';

  /// iOS 那份铃声（2026-10-15）。与安卓的 [callRingtoneUri]**不是一回事**，
  /// 这里的规矩是苹果定的三条，缺一条就退化成一声「叮」：
  ///
  /// * 文件必须在 **app 包里**（Xcode 的 Resources 那一相）—— 不能放 Flutter 的
  ///   `assets/`，系统根本看不见那里；本文件对的是 `ios/Runner/call_ring.wav`，
  ///   由 `tool/audio/make-ios-ringtone.sh` 生成（应用内那个铃声接 6 遍 ≈ 26.6 秒）；
  /// * 格式只认 Linear PCM / IMA4 / µ-law / a-law（装在 .wav / .caf / .aiff 里），
  ///   mp3 用不了；
  /// * **最长 30 秒且不会循环** —— 所以那 26 秒是故意做满的，不是随便截的一段。
  ///
  /// 少了它，朋友在锁屏上只会听到默认提示音就结束，根本来不及接 ——
  /// 安卓上从来不是这个问题（那边放的是用户自己手机的铃声）。
  static const String callRingtoneFile = 'call_ring.wav';

  /// iOS 上「来电 / 群邀请」那条通知的参数。**两处共用一个**，抽出来的第二个理由是
  /// 可测：[showIncomingCall] 里那句 `Platform.isAndroid || Platform.isIOS` 让这段构造
  /// 在宿主机的单测里根本走不到（Windows / macOS 上直接 return），
  /// 而它一旦掉了 `sound:`，表现是「真机上又只剩一声叮」—— 那种错必顶在单测里。
  @visibleForTesting
  static DarwinNotificationDetails callNotificationIos() =>
      DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        // 铃声：包里那个 26.6 秒的 WAV（见 [callRingtoneFile]）。
        // iOS 不会循环，所以文件本身就是「足够长的一遍」。
        sound: callRingtoneFile,
        // 时效性通知：能穿透「专注模式」，锁屏上也会更显眼
        interruptionLevel: InterruptionLevel.timeSensitive,
      );

  /// 来电通知的固定 id：同一时刻只可能有一通来电，固定 id 让「收掉」不用记状态
  static const int callNotificationId = 0x0CA11;

  /// 来电通知最多挂多久（毫秒）。与状态机的响铃上限（`CallMachine.incomingRingTimeoutSeconds`）
  /// 对齐：两边都收掉，才不会出现「通话早结束了、通知还在响」。
  static const int incomingCallTimeoutMs = 45 * 1000;

  /// 群通话邀请的通知 id（S6.14）。
  ///
  /// 与来电**分开**（理由见 [MessageNotificationPresenter.showGroupCallRing]）：
  /// 共用一个 id 的话，群里开一场语音会把正在响的 1:1 来电顶掉。
  static const int groupCallNotificationId = 0x0CA12;

  /// 群通话邀请最多挂多久（毫秒）。
  ///
  /// 比来电的 45 秒长得多：**声音只在弹出那一下响**（系统的硬限制，通知声音不能循环），
  /// 所以挂久一点不会吵；而群里那通可能还在继续，早点收掉等于让人错过它。
  /// 真正的收尾是服务端那条静默推送（房间空了），这里只是兜底。
  static const int groupCallTimeoutMs = 5 * 60 * 1000;

  /// 小图标：`android/app/src/main/res/drawable/ic_notification.xml`
  /// （白底实心的铃铛。安卓只把图标的**透明度**当形状用，所以必须是单色剪影）
  static const String icon = 'ic_notification';

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// [initialize] 那一次异步。`takeLaunchIncomingCall()` 要等它 ——
  /// 两个宿主（NotificationHost / CallPushHost）的 initState 先后顺序不确定，
  /// 不能让「冷启动是哪条通知」这件事依赖 widget 树的顺序。
  Future<String?>? _initFuture;

  /// 冷启动时那条来电报文（只存不发给 onOpen，由 CallPushHost 取走）
  String? _launchCallPayload;

  /// 冷启动时那条**群通话邀请**报文（S6.14，由 GroupCallPushHost 取走）
  String? _launchGroupCallPayload;

  /// 用户点开来电通知时的回调
  ValueChanged<String>? _onCallOpen;

  /// 用户点开群通话邀请时的回调（S6.14）
  ValueChanged<String>? _onGroupCallOpen;

  @override
  Future<String?> initialize({required ValueChanged<String> onOpen}) {
    final future = _initialize(onOpen);
    _initFuture = future;
    return future;
  }

  Future<String?> _initialize(ValueChanged<String> onOpen) async {
    // 桌面 / 测试环境没有这条通道：直接跳过（真机上这里不会进）
    if (!(Platform.isAndroid || Platform.isIOS)) return null;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(icon),
        // iOS 不给通知权限，等 ensurePermission 时再要（与老端一致：
        // 登录后弹一次，而不是装完就要）
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      // Dart 侧收点击：App 还在跑（进程活着）时走这里。
      // 三类通知共用这条回调，靠 payload 的形状分流（见 [_kindOfPayload]）。
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload ?? '';
        if (payload.isEmpty) return;
        final kind = _kindOfPayload(payload);
        // 真机排查用（2026-10-08「点通知白屏」）：这一行是「这条通知被分到哪一类、
        // 带的什么 payload」的唯一记录 —— 分错类就会跳到错的页面（payload 截断，
        // 通话那两类是一整条报文，全打出来会刷满日志）
        debugPrint('[通知] 点了通知：$kind / ${_short(payload)}');
        switch (kind) {
          case _PayloadKind.incomingCall:
            _onCallOpen?.call(payload);
            return;
          case _PayloadKind.groupCall:
            _onGroupCallOpen?.call(payload);
            return;
          case _PayloadKind.conversation:
            onOpen(payload);
        }
      },
    );

    // App 是被通知拉起来的（进程当时已经没了）：这里把意图交回去
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      final payload = launch?.notificationResponse?.payload ?? '';
      final kind = _kindOfPayload(payload);
      debugPrint('[通知] App 是被通知拉起来的：$kind / ${_short(payload)}');
      switch (kind) {
        case _PayloadKind.incomingCall:
          // 来电不归这里处理（要建整个通话会话），留给 CallPushHost 取走
          _launchCallPayload = payload;
          return null;
        case _PayloadKind.groupCall:
          // 群通话邀请要等界面起来才能进那个群通话页，留给 GroupCallPushHost 取走
          _launchGroupCallPayload = payload;
          return null;
        case _PayloadKind.conversation:
          if (payload.isNotEmpty) return payload;
      }
    }
    return null;
  }

  /// 日志里那句 payload（长的截断）：真机上「点通知白屏」排查要用
  static String _short(String payload) => payload.length > 160
      ? '${payload.substring(0, 160)}…（共 ${payload.length} 字）'
      : payload;

  /// 这条通知的 payload 是哪一类（S6.14）。
  ///
  /// **群通话那条必须判在最前面**：它的报文里那句 `groupCalling` 恰好躲过了下面
  /// 那个「包含 calling」的老判据（大小写不同），顺序反了就会被当成普通消息通知，
  /// 点进去是聊天页而不是群通话页。
  static _PayloadKind _kindOfPayload(String payload) {
    final text = payload.trimLeft();
    if (!text.startsWith('{')) return _PayloadKind.conversation;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final frame = decoded.cast<String, dynamic>();
        if (asText(frame['type']) == groupCallPushType) {
          return _PayloadKind.groupCall;
        }
        // 退路：`type` 缺失但 `extends.event` 是群通话那两种之一，也认
        final event = asText(asMap(frame['extends'])['event']);
        if (event.startsWith('groupCall')) return _PayloadKind.groupCall;
      }
    } on FormatException {
      // 解不开就当它不是通话报文，走下面那条老判据
    }
    if (_looksLikeCallPayload(payload)) return _PayloadKind.incomingCall;
    return _PayloadKind.conversation;
  }

  /// 这条通知的 payload 是不是一通来电。
  ///
  /// 消息通知的 payload 一直是**纯会话 id**，只有来电才放 JSON 报文，
  /// 所以「以 `{` 开头」就足够分辨；再加一个 `calling` 校验防止误判。
  /// （群通话邀请由 [_kindOfPayload] 在前面先认走，见那里的注释。）
  static bool _looksLikeCallPayload(String payload) {
    final text = payload.trimLeft();
    return text.startsWith('{') && text.contains('calling');
  }

  @override
  Future<bool> enabled() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _android?.areNotificationsEnabled() ?? true;
    } on Object catch (error) {
      debugPrint('[通知] 读不到通知权限：$error');
      return true;
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _android?.requestNotificationsPermission() ??
          await enabled();
    } on Object catch (error) {
      debugPrint('[通知] 申请通知权限失败：$error');
      return false;
    }
  }

  @override
  Future<void> show(MessageNotification notification) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    final android = AndroidNotificationDetails(
      channelId,
      _t('notify.channelName'),
      channelDescription: _t('notify.channelDesc'),
      icon: icon,
      // 消息通知要「响一声 + 弹横幅」，所以是 high；不要用 max（那是来电那种）
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      // 长文本展开显示（安卓默认只显示一行）
      styleInformation: BigTextStyleInformation(notification.body),
    );
    try {
      await _plugin.show(
        id: _idOf(notification.conversationId),
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
          android: android,
          iOS: DarwinNotificationDetails(),
        ),
        // 点通知要把会话 id 带回来
        payload: notification.conversationId,
      );
    } on Object catch (error) {
      // 通知弹不出来不能影响收消息
      debugPrint('[通知] 弹出失败：$error');
    }
  }

  @override
  Future<void> cancel(String conversationId) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _plugin.cancel(id: _idOf(conversationId));
    } on Object catch (error) {
      debugPrint('[通知] 清除失败：$error');
    }
  }

  @override
  Future<void> cancelAll() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _plugin.cancelAll();
    } on Object catch (error) {
      debugPrint('[通知] 清空失败：$error');
    }
  }

  // ------------------------------------------------------------ 来电（S8.1h）

  @override
  void onIncomingCallOpen(ValueChanged<String> handler) {
    _onCallOpen = handler;
  }

  @override
  void onGroupCallOpen(ValueChanged<String> handler) {
    _onGroupCallOpen = handler;
  }

  @override
  Future<String?> takeLaunchGroupCall() async {
    final init = _initFuture;
    if (init != null) {
      try {
        await init;
      } on Object catch (_) {}
    }
    final payload = _launchGroupCallPayload;
    _launchGroupCallPayload = null;
    return payload;
  }

  @override
  Future<String?> takeLaunchIncomingCall() async {
    final init = _initFuture;
    if (init != null) {
      // 初始化失败不该让来电也一起丢：内部已经记过日志了
      try {
        await init;
      } on Object catch (_) {}
    }
    final payload = _launchCallPayload;
    _launchCallPayload = null;
    return payload;
  }

  @override
  Future<void> showIncomingCall(IncomingCallNotification call) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    final android = AndroidNotificationDetails(
      callChannelId,
      _t('notify.callChannelName'),
      channelDescription: _t('notify.callChannelDesc'),
      icon: icon,
      // 来电用 max（横幅 + 声音 + 在有的系统上直接亮屏），
      // 消息那条是 high —— 两者不要混用，否则系统会把来电也当成普通提醒
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      // 全屏：息屏 / 锁屏时直接弹来电界面。
      // ⚠️ 安卓 14 起要用户在系统里允许，没允许时**系统自己降级成横幅 + 响铃**
      // （不是错误，所以这里不报错、也不拦住这条通知）。
      fullScreenIntent: true,
      // 铃声：系统的来电铃声 + 「来电」音轨（音量跟着铃声走，而不是通知音量）。
      // 不指定的话系统用的是默认**通知**提示音 —— 一声「叮」，真机上会被当成没有铃声。
      sound: const UriAndroidNotificationSound(callRingtoneUri),
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      playSound: true,
      enableVibration: true,
      // ⚠️ **不能是 ongoing**（真机 2026-09-20：主叫取消后被叫那条通知一直挂着）：
      //   * `ongoing` 的通知系统不许它超时自收，下面那句 `timeoutAfter` 就形同虚设；
      //   * 而且用户想手动划掉也划不掉 —— 一通早就结束的电话留一条撤不掉的通知，
      //     比「能被误划掉」糟糕得多。
      // 收掉它的三条路：接听/拒接、45 秒超时、对方取消（服务端会补一条静默推送）。
      ongoing: false,
      autoCancel: false,
      timeoutAfter: incomingCallTimeoutMs,
    );
    try {
      await _plugin.show(
        id: callNotificationId,
        title: call.title,
        body: call.body,
        notificationDetails: NotificationDetails(
          android: android,
          iOS: callNotificationIos(),
        ),
        // 来电的 payload 是**整条报文**：点它 / 冷启动都要靠它重建会话
        payload: call.payload,
      );
    } on Object catch (error) {
      // 通知弹不出来不能让这条推送白到；真机上靠日志定位
      debugPrint('[通知] 来电通知失败：$error');
    }
  }

  @override
  Future<void> cancelIncomingCall() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _plugin.cancel(id: callNotificationId);
    } on Object catch (error) {
      debugPrint('[通知] 收掉来电通知失败：$error');
    }
  }

  // ------------------------------------------------------- 群通话邀请（S6.14）

  @override
  Future<void> showGroupCallRing(IncomingCallNotification invite) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    final android = AndroidNotificationDetails(
      // 与来电**同一条渠道**（要的就是铃声；单独开一条渠道只会多一个「静音」开关），
      // 但下面的参数与来电不一样（不全屏、能自己超时消失）。
      callChannelId,
      _t('notify.callChannelName'),
      channelDescription: _t('notify.callChannelDesc'),
      icon: icon,
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      // 铃声与音轨跟来电一致：跟手机的铃声走，而不是通知音量。
      sound: const UriAndroidNotificationSound(callRingtoneUri),
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      playSound: true,
      enableVibration: true,
      // ⚠️ **刻意不全屏**（与来电的差别就在这一条）：群邀请不是指名道姓找你的电话，
      // 息屏时把整屏顶掉不合适；安卓 14 也不会为此弹那个「允许全屏通知」的授权。
      fullScreenIntent: false,
      // 能划掉、能自己消失：这通群语音结束时会由服务端补一条静默推送收掉，
      // 但线上总会有（App 被杀、没网、服务端没能推成功）的时候，留个兜底。
      ongoing: false,
      autoCancel: true,
      timeoutAfter: groupCallTimeoutMs,
    );
    try {
      await _plugin.show(
        id: groupCallNotificationId,
        title: invite.title,
        body: invite.body,
        notificationDetails: NotificationDetails(
          android: android,
          // 与来电同一份参数（同一条渠道、同一个铃声）：群邀请也是「马上就没了」
          // 的东西，静音掉等于邀不到人
          iOS: callNotificationIos(),
        ),
        // 与来电一样带上**整条报文**：点它 / 冷启动都要靠它进那个群通话页
        //（群名、群会话 id 都在里面 —— 只给一个群号是进不去的）
        payload: invite.payload,
      );
    } on Object catch (error) {
      debugPrint('[通知] 群通话邀请通知失败：$error');
    }
  }

  @override
  Future<void> cancelGroupCallRing() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _plugin.cancel(id: groupCallNotificationId);
    } on Object catch (error) {
      debugPrint('[通知] 收掉群通话邀请失败：$error');
    }
  }

  /// 通知 id：同一个会话共用一个 id，所以「同一个会话来 10 条」在通知栏里
  /// 只占一条（老端那条 `createPushMessage` 也是这样，一条盖一条）。
  static int _idOf(String conversationId) =>
      conversationId.hashCode & 0x7fffffff;
}

final messageNotificationPresenterProvider =
    Provider<MessageNotificationPresenter>(
      (ref) => LocalMessageNotificationPresenter(
        translate: (key) => ref.read(appI18nProvider).t(key),
      ),
    );
