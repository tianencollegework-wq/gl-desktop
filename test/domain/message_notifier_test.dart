import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/audio/message_alerter.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/data/model/app_setting.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/chat/message_notification.dart';
import 'package:gracelinkim/domain/chat/message_notifier.dart';

class _FakePresenter implements MessageNotificationPresenter {
  final List<MessageNotification> shown = <MessageNotification>[];
  final List<String> cancelled = <String>[];
  bool permissionGranted = true;
  int permissionRequests = 0;
  ValueChanged<String>? onOpen;
  String? pending;

  @override
  Future<String?> initialize({required ValueChanged<String> onOpen}) async {
    this.onOpen = onOpen;
    return pending;
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
  Future<void> cancelAll() async {}

  // 来电那几条本文件用不到（来电不走消息通知这条链），给个空实现就行
  @override
  Future<void> showIncomingCall(IncomingCallNotification call) async {}

  @override
  Future<void> cancelIncomingCall() async {}

  @override
  void onIncomingCallOpen(ValueChanged<String> handler) {}

  @override
  Future<String?> takeLaunchIncomingCall() async => null;

  // 群通话邀请那几条本文件也用不到（它们不走消息通知这条链）
  @override
  Future<void> showGroupCallRing(IncomingCallNotification invite) async {}

  @override
  Future<void> cancelGroupCallRing() async {}

  @override
  void onGroupCallOpen(ValueChanged<String> handler) {}

  @override
  Future<String?> takeLaunchGroupCall() async => null;
}

/// 「提示音有没有响」——老端那套 `playSound()` 的替身
class _RecordingAlerter implements MessageAlerter {
  int count = 0;

  @override
  Future<void> alert(AppSetting setting) async => count += 1;

  @override
  Future<void> dispose() async {}
}

void main() {
  late _FakePresenter presenter;
  late _RecordingAlerter alerter;
  var foreground = true;

  const myId = 'u1';

  Message message({
    String conversationId = 'u2',
    String fromUserId = 'u2',
    String type = 'text',
    String content = '你好',
    int isGroup = 0,
  }) => Message(
    conversationId: conversationId,
    msgId: 'm1',
    fromUserId: fromUserId,
    fromUserName: '李四',
    type: type,
    content: content,
    isGroup: isGroup,
  );

  MessageNotifier notifier() => MessageNotifier(
    presenter: presenter,
    alerter: alerter,
    appInForeground: () => foreground,
    translate: (key) => key,
  );

  setUp(() {
    presenter = _FakePresenter();
    alerter = _RecordingAlerter();
    foreground = true;
  });

  test('前台：响一声（提示音+震动），不弹系统通知', () async {
    await notifier().onIncoming(
      message: message(),
      conversation: const Conversation(id: 'u2', displayName: '李四'),
      myUserId: myId,
      setting: const AppSetting(),
    );

    expect(alerter.count, 1);
    expect(presenter.shown, isEmpty);
  });

  test('后台：弹系统通知，自己不再响（免得响两次）', () async {
    foreground = false;

    await notifier().onIncoming(
      message: message(),
      conversation: const Conversation(id: 'u2', displayName: '李四'),
      myUserId: myId,
      setting: const AppSetting(),
    );

    expect(alerter.count, 0);
    expect(presenter.shown.single.title, '李四');
    expect(presenter.shown.single.body, '你好');
  });

  test('自己发的：前台不响、后台也不弹', () async {
    await notifier().onIncoming(
      message: message(fromUserId: myId),
      conversation: const Conversation(id: 'u2', displayName: '李四'),
      myUserId: myId,
      setting: const AppSetting(),
    );
    foreground = false;
    await notifier().onIncoming(
      message: message(fromUserId: myId),
      conversation: const Conversation(id: 'u2', displayName: '李四'),
      myUserId: myId,
      setting: const AppSetting(),
    );

    expect(alerter.count, 0);
    expect(presenter.shown, isEmpty);
  });

  test('会话免打扰：前台不响、后台也不弹', () async {
    const muted = Conversation(id: 'u2', displayName: '李四', isNotice: 0);

    await notifier().onIncoming(
      message: message(),
      conversation: muted,
      myUserId: myId,
      setting: const AppSetting(),
    );
    foreground = false;
    await notifier().onIncoming(
      message: message(),
      conversation: muted,
      myUserId: myId,
      setting: const AppSetting(),
    );

    expect(alerter.count, 0);
    expect(presenter.shown, isEmpty);
  });

  test('群消息也走同一套（后台弹「群名 / 发送者: 内容」）', () async {
    foreground = false;

    await notifier().onIncoming(
      message: message(isGroup: 1, content: '在吗'),
      conversation: const Conversation(
        id: 'g9',
        displayName: '项目群',
        isGroup: 1,
      ),
      myUserId: myId,
      setting: const AppSetting(),
    );

    expect(presenter.shown.single.title, '项目群');
    expect(presenter.shown.single.body, '李四: 在吗');
  });
}
