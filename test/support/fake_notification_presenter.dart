import 'dart:async';

import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/domain/chat/message_notification.dart';

/// 通知层的**共用替身**（S6.14 起）。
///
/// 各测试文件里那几份自己写的替身（`call_push_host_test` / `notification_host_test`
/// / `message_notifier_test`）历史更久、各有各的小状态，先不动它们。这份是给新用例
/// 用的：只记录「谁弹了/谁被收掉了」，并且能把「用户点了通知」与「App 是被通知拉起来的」
/// 两条路手动播回来。
///
/// 三路通知**分开记**：消息通知、1:1 来电、群通话邀请各占一个通知位，
/// 「有没有走错通道」正是这几块要钉住的事。
class FakeNotificationPresenter implements MessageNotificationPresenter {
  final List<MessageNotification> shown = <MessageNotification>[];
  final List<String> cancelled = <String>[];

  /// 弹过的 1:1 来电通知
  final List<IncomingCallNotification> calls = <IncomingCallNotification>[];

  /// 弹过的群通话邀请（S6.14）
  final List<IncomingCallNotification> groupRings =
      <IncomingCallNotification>[];

  int cancelledCalls = 0;
  int cancelledGroupRings = 0;
  int cancelAllCount = 0;
  bool permissionGranted = true;

  /// 问过几次通知权限（第一次打开 App 那条路盯着它）
  int permissionRequests = 0;

  /// 冷启动时「App 是被哪条通知拉起来的」：消息那条给会话 id，通话那两条给报文
  String? pendingConversation;
  String? launchCall;
  String? launchGroup;

  /// 让「读冷启动那条来电报文」**卡在半路**（用例拿它自己决定什么时候放行）。
  ///
  /// 用来复刻启动那一刻的赛跑：`CallPushHost` 把启动那条链 `unawaited` 甩出去，
  /// 而它中间有 await、醒来之后还要碰 `ref` —— 那时界面可能已经被拆掉了
  /// （真机上是「刚起来就被划掉 / 切走」，CI 上就是那条启动自检用例跑完）。
  Completer<void>? launchCallGate;

  /// 模拟「用户点了通知栏里的那条」
  void tapConversation(String conversationId) => onOpen?.call(conversationId);
  void tapCall(String payload) => onCallOpen?.call(payload);
  void tapGroupCall(String payload) => onGroupOpen?.call(payload);

  ValueChanged<String>? onOpen;
  ValueChanged<String>? onCallOpen;
  ValueChanged<String>? onGroupOpen;

  @override
  Future<String?> initialize({required ValueChanged<String> onOpen}) async {
    this.onOpen = onOpen;
    return pendingConversation;
  }

  @override
  Future<bool> enabled() async => permissionGranted;

  @override
  Future<bool> requestPermission() async {
    permissionRequests += 1;
    permissionGranted = true;
    return true;
  }

  @override
  Future<void> show(MessageNotification notification) async =>
      shown.add(notification);

  @override
  Future<void> cancel(String conversationId) async =>
      cancelled.add(conversationId);

  @override
  Future<void> cancelAll() async => cancelAllCount += 1;

  // ------------------------------------------------------------- 1:1 来电

  @override
  Future<void> showIncomingCall(IncomingCallNotification call) async =>
      calls.add(call);

  @override
  Future<void> cancelIncomingCall() async => cancelledCalls += 1;

  @override
  void onIncomingCallOpen(ValueChanged<String> handler) => onCallOpen = handler;

  @override
  Future<String?> takeLaunchIncomingCall() async {
    final gate = launchCallGate;
    if (gate != null) await gate.future;
    final payload = launchCall;
    launchCall = null; // 只能取一次（进程当时已经没了）
    return payload;
  }

  // --------------------------------------------------------- 群通话邀请

  @override
  Future<void> showGroupCallRing(IncomingCallNotification invite) async =>
      groupRings.add(invite);

  @override
  Future<void> cancelGroupCallRing() async => cancelledGroupRings += 1;

  @override
  void onGroupCallOpen(ValueChanged<String> handler) => onGroupOpen = handler;

  @override
  Future<String?> takeLaunchGroupCall() async {
    final payload = launchGroup;
    launchGroup = null;
    return payload;
  }
}
