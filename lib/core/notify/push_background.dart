import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/notify/message_notification_presenter.dart';
import '../../core/store/credential_store.dart';
import '../../core/util/json_value.dart';
import '../../domain/call/incoming_call_push.dart';
import '../../domain/chat/message_notification.dart';
import '../../domain/group_call/group_call_push.dart';

/// FCM 数据消息的**后台入口**（S8.1）。
///
/// 服务端只发数据消息（理由见后端 `PushMessage`），所以通知栏必须由客户端画出来 ——
/// 而「App 没在跑」的时候，就是这里在画：firebase_messaging 会为这个回调**单独起一个
/// isolate**，它醒来 → 弹一条通知 → 结束，全程不需要 App 界面活着。
///
/// 三条必须记住的规矩（少一条就是收不到通知）：
/// 1. **必须是顶层函数**，并且带 `@pragma('vm:entry-point')`
///    （release 构建会把「没人调用」的函数摇掉，包括这个）；
/// 2. 在 `runApp` 之前用 [startPushBackgroundHandler] 注册；
/// 3. isolate 是全新的：插件（`DartPluginRegistrant`）与本地存储/语言包都要重新准备。
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // 后台 isolate 里没有注册过插件：不调这一句，shared_preferences 这类会直接抛
  DartPluginRegistrant.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  } on Object catch (error) {
    debugPrint('[推送] 后台 isolate 初始化 Firebase 失败：$error');
    return;
  }
  await PushNotificationHandler().handle(message.data);
}

/// 注册后台入口。整段吞异常：Firebase 没配好（缺 google-services.json、包名不一致）
/// 时只是收不到推送，**不能**让应用起不来。
void startPushBackgroundHandler() {
  if (!(Platform.isAndroid || Platform.isIOS)) return;
  try {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } on Object catch (error) {
    debugPrint('[推送] 注册后台推送入口失败（推送不可用）：$error');
  }
}

/// 把一条推送数据弹成通知。抽成类（而不是写在上面那个函数里）是为了**能单测**：
/// 通知内容与「哪些推送该弹」的规则不该只能靠真机推着试。
class PushNotificationHandler {
  PushNotificationHandler({
    this.presenter,
    String Function()? readMyUserId,
    String Function(String key, String fallback)? translate,
  }) : _readMyUserId = readMyUserId ?? _myUserIdFromStore,
       _translate = translate ?? _translateFromI18n;

  /// 允许测试注入；真机上为空，那时在后台 isolate 里自己组装一个
  final MessageNotificationPresenter? presenter;
  final String Function() _readMyUserId;

  /// 语言包取词；语言包没加载成功时用第二参数（服务端给的预览）兜底 ——
  /// 它只被用在「非文本消息的类型占位」上，而服务端给的预览正是同一句话。
  final String Function(String key, String fallback) _translate;

  bool _prepared = false;

  /// 最后一条**被我们弹成来电通知**的那通电话的 id（`calling` 报文的 `call_id`）。
  ///
  /// 收尾帧（[isCallCancelPush]）要拿它比对，否则会出现：新的一通已经响起来了，
  /// 上一通那条「已结束」才姗姗来迟 —— 不带 id 地无条件收通知，就把正在响的收了。
  ///
  /// 静态是因为它必须**跨后台 isolate 的多次唤醒**存活（FCM 每次唤醒可能复用同一个
  /// headless 引擎，也可能是新的）。读不到（App 刚被杀、这是第一次唤醒）时按
  /// 「没有正在响的来电」处理 —— 那时收一条不存在的通知本来也无害。
  static String? _lastRingingCallId;

  /// 最后一条**被我们弹成群通话邀请**的那通群语音的 id（S6.14）。
  ///
  /// 与上面那份**分开记**：1:1 来电与群邀请是两个通知位（`callNotificationId`
  /// 与 `groupCallNotificationId`），各自的结束帧只能收各自那条。
  static String? _lastGroupCallId;

  /// 只给单测用：清掉「最后响过的那通」。
  ///
  /// 它是**进程级**状态，测试之间会互相带 —— 上一条用例留下的 id 会让下一条
  /// 以为还有一通在响，于是收尾帧被当成「上一通的」跳过。
  @visibleForTesting
  static void debugResetRingingCall() {
    _lastRingingCallId = null;
    _lastGroupCallId = null;
  }

  /// 后台 isolate 里没有 `main()` 那套初始化：这里补上语言包
  /// （`cid`/`myUserId` 也一样要从本地存储读）。失败只记日志，不挡通知。
  Future<void> _prepare() async {
    if (_prepared) return;
    _prepared = true;
    try {
      final store = await CredentialStore.init();
      // 语言：手动选过就用他那份，没选过跟系统（后台 isolate 拿不到系统语言时
      // `systemLocaleCode()` 自己会落英语，见它自己的注释）
      await AppI18n.load(store.language ?? LocaleController.systemLocaleCode());
    } on Object catch (error) {
      debugPrint('[推送] 后台 isolate 准备失败（用服务端预览兜底）：$error');
    }
  }

  /// [raw] 就是 `RemoteMessage.data`（FCM 的数据消息里所有值都是字符串）
  Future<void> handle(Map<String, dynamic> raw) async {
    final data = <String, String>{
      for (final entry in raw.entries) entry.key: entry.value?.toString() ?? '',
    };
    await _prepare();

    // ① 「这通电话已经结束了」的收尾帧（S8.1n）：**最先判**，而且不弹任何通知 ——
    //    它唯一的任务是把那条来电通知收掉（详见 [isCallCancelPush] 的文件注释）。
    //    放在来电之前判：两者都是 `type=webrtc`，先后顺序反了就等于没实现。
    if (isCallCancelPush(data)) {
      await _cancelIncomingCall(callCancelIdOf(data));
      return;
    }

    // ② 群通话（S6.14）：群里有人开了语音（邀请）/ 这通群语音已经结束（收通知）。
    //    同样要判在普通消息之前：它是另一类 `type`，但形状与来电一样是「一对帧」。
    if (isGroupCallEndPush(data)) {
      await _cancelGroupCallRing(groupCallPushIdOf(data));
      return;
    }
    if (isGroupCallRingPush(data)) {
      await _showGroupCallRing(data);
      return;
    }

    // ③ 来电走另一条展示路径（S8.1h）：它不是一条「消息通知」——
    //    要独立渠道、最高重要性、全屏、响铃，而且 payload 必须留整条报文
    //    （点它 / 冷启动要靠它重建会话，只给会话 id 是接不起一通电话的）。
    if (isIncomingCallPush(data)) {
      await _showIncomingCall(data);
      return;
    }

    final notification = messageNotificationFromPush(
      data: data,
      myUserId: _readMyUserId(),
      translate: (key) => _translate(key, data['content'] ?? ''),
    );
    if (notification == null) {
      debugPrint('[推送] 这条推送不该弹通知，已跳过：${data['contact_id'] ?? ''}');
      return;
    }

    try {
      final injected = presenter;
      if (injected != null) {
        await injected.show(notification);
        return;
      }
      // 直接 show，**不调 initialize**：这一层不需要它（图标在每条通知的
      // details 里已经给了，通知渠道在第一次 show 时会自己建），而它会把点击回调
      // 的 handle 写进本地存储 —— 后台 isolate 里没必要去碰那个（点击由主 isolate
      // 处理，见 NotificationHost）。
      final backgroundPresenter = LocalMessageNotificationPresenter(
        translate: (key) => _translate(key, ''),
      );
      await backgroundPresenter.show(notification);
    } on Object catch (error) {
      // 通知弹不出来不能影响这条推送的处理（更不能让 isolate 崩掉刷一屏日志）
      debugPrint('[推送] 弹通知失败：$error');
    }
  }

  /// 把一条**离线来电**弹成来电通知（S8.1h）。
  ///
  /// 后台 isolate 能做到的只有这么多：点亮屏幕 + 响铃 + 把整条报文留在通知里。
  /// 真正「进来电页、能接听」是主 isolate 的事（见 `CallPushHost`）——
  /// 后台 isolate 里没有界面、也不该去建长连接。
  ///
  /// 超龄的来电直接丢掉（[IncomingCallPush.isFresh]）：主叫 60 秒就挂了，
  /// 这时才叫醒你只会响起一秒然后对方挂断，比不响更烦人。
  Future<void> _showIncomingCall(Map<String, String> data) async {
    final call = incomingCallFromPush(data: data, myUserId: _readMyUserId());
    if (call == null) {
      debugPrint('[推送] 这条来电认不出来（或是我自己发的），已跳过');
      return;
    }
    if (!call.isFresh(DateTime.now())) {
      debugPrint('[推送] 来电已超龄（${call.sentAt}），不再响铃：${call.peerId}');
      return;
    }
    final styled = call.toNotification((key) => _translate(key, ''));
    final notice = IncomingCallNotification(
      title: styled.title,
      body: styled.body,
      // payload 用**服务端原样的那份**（不是我们重新序列化的）：
      // 主 isolate 要拿它当 `calling` 报文用，重新序列化没必要也不该
      payload: data['payload'] ?? '',
    );
    // 记下这一通是谁，收尾帧要靠它挡「别把新响的那通收了」。
    // 取 `id`：那是主叫在 `calling` 帧里带的那通电话的 id（uuid），
    // 服务端收尾帧里给的 `call_id` 就是同一个值。
    _lastRingingCallId = _callIdOfSignal(call.signal);
    try {
      final injected = presenter;
      if (injected != null) {
        await injected.showIncomingCall(notice);
        return;
      }
      await LocalMessageNotificationPresenter(
        translate: (key) => _translate(key, ''),
      ).showIncomingCall(notice);
    } on Object catch (error) {
      debugPrint('[推送] 弹来电通知失败：$error');
    }
  }

  /// 一通电话的 id：`calling` 报文里是 `id`（主叫生成的 uuid），服务端反而会用它
  /// 去定位那条通话记录。`msg_id` 只是退路（老报文可能有它没 `id`）。
  static String _callIdOfSignal(Map<String, dynamic> signal) {
    final id = asText(signal['id']).trim();
    if (id.isNotEmpty) return id;
    return asText(signal['msg_id']).trim();
  }

  /// 把一条**群通话邀请**弹成响铃通知（S6.14）。
  ///
  /// 与离线来电那条的区别只在于「这是什么」：来电那边是「有人指名道姓在打你」
  /// （要全屏、要能接），这一条是「群里有人在开语音」（响了、点进去就是加入）。
  /// 后台 isolate 能做的仍然只有「点亮屏幕 + 响铃 + 把整条报文留在通知里」——
  /// 真正进那个群通话页是主 isolate 的事（见 `GroupCallPushHost`）。
  ///
  /// 超龄的邀请直接丢掉（[GroupCallPush.isFresh]）：服务端那条推送只活 60 秒，
  /// 这时才叫醒你，群里那通可能早就散了。
  Future<void> _showGroupCallRing(Map<String, String> data) async {
    final invite = groupCallFromPush(data: data);
    if (invite == null) {
      debugPrint('[推送] 这条群通话邀请认不出来，已跳过');
      return;
    }
    if (!invite.isFresh(DateTime.now())) {
      debugPrint(
        '[推送] 群通话邀请已超龄（${invite.sentAt}），不再响铃：${invite.conversationId}',
      );
      return;
    }
    final styled = invite.toNotification(
      (key, fallback) => _translate(key, fallback),
    );
    final notice = IncomingCallNotification(
      title: styled.title,
      body: styled.body,
      // payload 用**服务端原样的那份**（理由与来电一样：主 isolate 拿它当报文用）
      payload: invite.payload,
    );
    // 记下这是哪一通，结束帧要靠它挡「别把新响的那通收了」
    _lastGroupCallId = invite.callId;
    try {
      final injected = presenter;
      if (injected != null) {
        await injected.showGroupCallRing(notice);
        return;
      }
      await LocalMessageNotificationPresenter(
        translate: (key) => _translate(key, ''),
      ).showGroupCallRing(notice);
    } on Object catch (error) {
      debugPrint('[推送] 弹群通话邀请失败：$error');
    }
  }

  /// 收掉那条群通话邀请（S6.14）。判据与 1:1 那份完全一样，只是通知位不同。
  Future<void> _cancelGroupCallRing(String callId) async {
    final ringing = _lastGroupCallId;
    if (ringing != null &&
        ringing.isNotEmpty &&
        callId.isNotEmpty &&
        ringing != callId) {
      debugPrint('[推送] 这条结束帧是上一通群语音的（$callId ≠ $ringing），不动当前邀请');
      return;
    }
    _lastGroupCallId = null;
    try {
      final injected = presenter;
      if (injected != null) {
        await injected.cancelGroupCallRing();
      } else {
        await LocalMessageNotificationPresenter(
          translate: (key) => _translate(key, ''),
        ).cancelGroupCallRing();
      }
      debugPrint('[推送] 群语音已结束，邀请通知已收掉');
    } on Object catch (error) {
      debugPrint('[推送] 收掉群通话邀请失败：$error');
    }
  }

  /// 收掉那条来电通知（S8.1n）。
  ///
  /// [callId] 是要收的那通电话的 id：与正在响的那通**不一致时不动**（新的一通已经
  /// 响起来了，上一通那条收尾帧不该把它收了）；我们手上没有 id（App 刚被杀、这是
  /// 第一次唤醒）时按「没有正在响的」处理，照样发一次取消 —— 一条不存在的通知
  /// 取消掉没有任何副作用，而漏收的代价是「对方早挂了、我这儿还响着」。
  Future<void> _cancelIncomingCall(String callId) async {
    final ringing = _lastRingingCallId;
    if (ringing != null &&
        ringing.isNotEmpty &&
        callId.isNotEmpty &&
        ringing != callId) {
      debugPrint('[推送] 这条收尾帧是上一通的（$callId ≠ $ringing），不动当前来电');
      return;
    }
    _lastRingingCallId = null;
    try {
      final injected = presenter;
      if (injected != null) {
        await injected.cancelIncomingCall();
      } else {
        await LocalMessageNotificationPresenter(
          translate: (key) => _translate(key, ''),
        ).cancelIncomingCall();
      }
      debugPrint('[推送] 主叫已取消这通电话，来电通知已收掉');
    } on Object catch (error) {
      debugPrint('[推送] 收掉来电通知失败：$error');
    }
  }

  /// 本地存着的登录用户 id（用来挡「自己发的推送」）。读不到就是空串，
  /// 那时靠服务端排掉发送人（它确实排了）。
  static String _myUserIdFromStore() {
    try {
      return asText(CredentialStore.instance.userInfo?['user_id']);
    } on Object catch (_) {
      return '';
    }
  }

  static String _translateFromI18n(String key, String fallback) {
    try {
      return AppI18n.instance.t(key);
    } on Object catch (_) {
      return fallback.isEmpty ? key : fallback;
    }
  }
}
