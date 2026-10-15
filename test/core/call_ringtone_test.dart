import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';

/// iOS 来电 / 群邀请那条通知的参数（2026-10-15）。
///
/// 为什么单开一份，而不是塞进 `ios_runner_test.dart`：那一份读的是 `ios/` 里的
/// **文件**（包没打进、wav 合不合法），这份钉的是 **Dart 侧指着谁**。
///
/// 两边的错法不一样：
/// * iOS 上「来电响不响」与安卓**根本不是一件事** —— 安卓放的是用户自己手机的
///   系统铃声（我们只指对渠道与音轨），iOS 放的是**我们自己打进包里的那个文件**；
/// * iOS 找不到指定名字的文件时**不报错**，静默退回默认提示音。于是「名字写错」
///   与「文件没进包」都会表现成同一种症状：来电只有一声「叮」，朋友来不及接。
///   而那是个只有真机看得出来的错 —— 所以这两件事各有一条用例钉住。
///
/// 抽成 [LocalMessageNotificationPresenter.callNotificationIos] 还有一个绕不开的
/// 理由：真去调 `showIncomingCall` 的话，它开头就有
/// `Platform.isAndroid || Platform.isIOS`，宿主机上直接 return，这段构造根本走不到。
void main() {
  test('iOS 来电通知指着包里那个铃声，而不是默认提示音', () {
    final ios = LocalMessageNotificationPresenter.callNotificationIos();

    expect(
      ios.sound,
      LocalMessageNotificationPresenter.callRingtoneFile,
      reason: '掉了 sound：iOS 只会「叮」一声就结束，锁屏上根本来不及接',
    );
    expect(ios.presentSound, isTrue, reason: '不带声音的通知在锁屏上等于没响');
    expect(ios.presentAlert, isTrue, reason: '来电要横幅 / 弹窗，不是静默塞进通知中心');
    expect(
      ios.interruptionLevel,
      InterruptionLevel.timeSensitive,
      reason: '不是时效性通知就穿不过「专注模式」—— 开着专注模式的人一个都接不到',
    );
  });

  test('这个名字对应的文件真的在 ios/Runner/ 里（改名字不改文件 = 又回到一声叮）', () {
    final path =
        'ios/Runner/${LocalMessageNotificationPresenter.callRingtoneFile}';
    expect(
      File(path).existsSync(),
      isTrue,
      reason:
          '$path 不存在。iOS 找不到这个文件时不会报错，只会放默认提示音 —— '
          '所以名字与文件必须同源（生成脚本见 tool/audio/make-ios-ringtone.sh）',
    );
  });
}
