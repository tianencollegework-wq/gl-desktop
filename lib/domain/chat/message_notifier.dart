import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/message_alerter.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/notify/message_notification_presenter.dart';
import '../../core/platform/app_foreground.dart';
import '../../data/model/app_setting.dart';
import '../../data/model/conversation.dart';
import '../../data/model/message.dart';
import 'message_notification.dart';

/// 收到一条消息后的提醒（S4.0 的收尾）。
///
/// 老端只有一套：不管前台后台都 `playSound()`，同时在后台时额外
/// `createPushMessage` 建通知栏 —— 结果是**后台时又响又弹，响两次**。
/// 新端把它们分开：
///
/// | App 状态 | 提醒方式 |
/// |---|---|
/// | 前台 | 应用内提示音 + 震动（[MessageAlerter]，跟设置走） |
/// | 后台 | 系统通知（声音由系统通知自己出） |
///
/// 两边都遵守同样的门槛：**自己发的不提醒、会话免打扰不提醒**。
class MessageNotifier {
  MessageNotifier({
    required this.presenter,
    required this.alerter,
    required this.appInForeground,
    required this.translate,
  });

  final MessageNotificationPresenter presenter;
  final MessageAlerter alerter;
  final bool Function() appInForeground;
  final String Function(String key) translate;

  /// 有一条消息进来了（WS 推的或自己发的都走这里，自己发的会被门槛挡掉）
  Future<void> onIncoming({
    required Message message,
    required Conversation? conversation,
    required String myUserId,
    required AppSetting setting,
  }) async {
    if (message.isMine(myUserId)) return;
    if (conversation?.muted ?? false) return;

    if (appInForeground()) {
      await alerter.alert(setting);
      return;
    }

    // 后台：交给系统通知栏（同一会话的通知会互相覆盖，不会堆一屏）
    final payload = messageNotificationOf(
      message: message,
      conversation: conversation,
      myUserId: myUserId,
      appInForeground: false,
      translate: translate,
    );
    if (payload == null) return;
    await presenter.show(payload);
  }
}

final messageNotifierProvider = Provider<MessageNotifier>(
  (ref) => MessageNotifier(
    presenter: ref.watch(messageNotificationPresenterProvider),
    alerter: ref.watch(messageAlerterProvider),
    appInForeground: () => ref.read(appForegroundProvider),
    translate: (key) => ref.read(appI18nProvider).t(key),
  ),
);
