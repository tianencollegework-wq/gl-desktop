import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/util/time_format.dart';
import '../../../core/ui/desktop_overlay.dart';

/// 点聊天里那条群通话记录先弹的**详情卡**（S6.16）。
///
/// 为什么不是点一下就直接进群通话页（S6.13 那版的行为）：那个页面**进去就是加入房间**
/// —— 手滑点一下就真的在服务端开出一间新屋子，而「这一通刚开」会让**离线群成员的手机
/// 响一声**（服务端第一笔就叫醒的规则）。微信里点这条记录是看详情，我们跟它对齐：
/// 想再打一次，在同一张卡上再点一下那颗明确的按钮。
///
/// 卡上只有两样真实数据（都在消息的 `extends` 里）：打了多久（**分钟:秒**，与气泡
/// 里 `content` 拼出来的那个数一模一样）、期间到过几个人。
/// **没有参与者名字**（服务端只记了人数），所以不假装有名单。
///
/// 那通语音还在开的话，按钮是「加入」（进页面就是加入现成的房间）；
/// 已经散了就是「再次发起」（进页面等于开一场新的）—— 两者走的是**同一条路由**，
/// 只有文案不一样。
Future<void> showGroupCallRecordSheet(
  BuildContext context, {
  required String groupName,

  /// 时长那行显示什么（由调用方用 `formatCallRecordDuration` 算好 —— 与气泡、通知
  /// 里那个「分钟:秒」是同一个口径）
  required String duration,

  /// 期间到过几个人（0 = 不知道，那一行不画）
  required int participants,

  /// 这一通现在还在不在开（拿 `GroupCallPresenceTracker` 查；决定按钮是
  /// 「加入」还是「再次发起」）
  required bool live,
  required Translate translate,
  required VoidCallback onAction,
}) {
  return showAppSheet<void>(
    context: context,
    backgroundColor: AppColors.white,
    builder: (sheetContext) {
      Widget row(String label, String value) => Padding(
        padding: EdgeInsets.symmetric(vertical: sheetContext.rpx(18)),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: sheetContext.rpx(28),
                  color: AppColors.text666,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: sheetContext.rpx(28),
                color: AppColors.text333,
              ),
            ),
          ],
        ),
      );

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: sheetContext.rpx(40),
            vertical: sheetContext.rpx(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.symmetric(vertical: sheetContext.rpx(20)),
                child: Text(
                  translate('group.call'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: sheetContext.rpx(32),
                    fontWeight: FontWeight.w600,
                    color: AppColors.text000,
                  ),
                ),
              ),
              if (groupName.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: sheetContext.rpx(20)),
                  child: Text(
                    groupName,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: sheetContext.rpx(26),
                      color: AppColors.text999,
                    ),
                  ),
                ),
              Container(height: 0.5, color: AppColors.line),
              row(translate('group.callRecordDuration'), duration),
              // 人数是服务端数出来的；老记录 / 数不出来时不画这一行，
              // 而不是显示一个「0 人」
              if (participants > 0)
                row(
                  translate('group.callRecordPeople'),
                  translate('group.callPeople', <String, String>{
                    'n': '$participants',
                  }),
                ),
              Container(height: 0.5, color: AppColors.line),
              SizedBox(height: sheetContext.rpx(30)),
              // 主操作：还在开就是「加入」，散了就是「再次发起」——走同一条路由
              GestureDetector(
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onAction();
                },
                child: Container(
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(vertical: sheetContext.rpx(24)),
                  decoration: BoxDecoration(
                    color: AppColors.brand,
                    borderRadius: BorderRadius.circular(sheetContext.rpx(16)),
                  ),
                  child: Text(
                    translate(
                      live ? 'group.callLiveJoin' : 'group.callRestart',
                    ),
                    style: TextStyle(
                      fontSize: sheetContext.rpx(30),
                      color: AppColors.white,
                    ),
                  ),
                ),
              ),
              SizedBox(height: sheetContext.rpx(14)),
              GestureDetector(
                onTap: () => Navigator.of(sheetContext).pop(),
                child: Container(
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(vertical: sheetContext.rpx(24)),
                  decoration: BoxDecoration(
                    color: AppColors.navBar,
                    borderRadius: BorderRadius.circular(sheetContext.rpx(16)),
                  ),
                  child: Text(
                    translate('common.cancel'),
                    style: TextStyle(
                      fontSize: sheetContext.rpx(30),
                      color: AppColors.text333,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
