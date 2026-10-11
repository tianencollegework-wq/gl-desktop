import 'package:flutter/material.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/ui/wechat_dialog.dart';
import '../../../domain/chat/group_admin.dart';
import '../../../core/ui/desktop_overlay.dart';

/// 群成员管理那几个弹层（S5.3 / S5.2b）。
///
/// 群成员管理页（老端 `groupUser.vue`）与用户详情页的「群内管理」块
/// （老端 `contacts/detail.vue`）用的是**同一套**操作，所以弹层抽在这里，
/// 两个页面共用一份实现——否则禁言那套 UI 要写两遍。
///
/// 对应的老端写法：禁言是 `uni-popup`（4 个预设 + 自定义天数 + 取消禁言），
/// 移出 / 设管理员是 `uni.showModal`（移出那个带「加入黑名单」开关）。

/// 禁言弹层的结果。
///
/// * `null`（弹层被关掉）→ 什么都不做；
/// * [NoSpeakSheetResult.cancelMute] → 取消禁言（提交空 choice）；
/// * [NoSpeakSheetResult.apply] → 按选中的时长禁言。
@immutable
class NoSpeakSheetResult {
  const NoSpeakSheetResult.apply(NoSpeakChoice this.choice);

  const NoSpeakSheetResult.cancelMute() : choice = null;

  /// null 表示「取消禁言」
  final NoSpeakChoice? choice;

  @override
  String toString() => choice == null
      ? 'NoSpeakSheetResult.cancelMute()'
      : 'NoSpeakSheetResult.apply($choice)';
}

/// 弹层的单行按钮（老端的 `cu-item`）
Widget groupSheetItem(
  BuildContext context, {
  required String label,
  required VoidCallback onTap,
  Color color = AppColors.text333,
  IconData? trailing,
}) => InkWell(
  onTap: onTap,
  child: SizedBox(
    height: context.rpx(100),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(fontSize: context.rpx(30), color: color),
        ),
        if (trailing != null) ...<Widget>[
          SizedBox(width: context.rpx(10)),
          Icon(trailing, size: context.rpx(32), color: AppColors.green),
        ],
      ],
    ),
  ),
);

/// 禁言弹层：4 个预设 + 自定义天数（±）/ 取消禁言。
///
/// [days] 是当前禁言天数（服务端 `no_speak_day`），[muted] 表示现在正被禁言
/// （正被禁言才有「取消禁言」那一颗）。
Future<NoSpeakSheetResult?> showNoSpeakSheet(
  BuildContext context,
  AppI18n i18n, {
  required int days,
  required bool muted,
}) async {
  // 初值跟老端一样落在「自定义」上，天数沿用服务端给的 `no_speak_day`
  var choice = NoSpeakChoice.custom(days == 0 ? 1 : days);

  final picked = await showAppSheet<_NoSpeakPick>(
    context: context,
    backgroundColor: AppColors.white,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final preset in noSpeakPresets)
                groupSheetItem(
                  sheetContext,
                  label: i18n.t(preset.labelKey),
                  trailing: choice.presetId == preset.id ? Icons.check : null,
                  onTap: () => setSheetState(
                    () => choice = NoSpeakChoice.preset(preset.id),
                  ),
                ),
              groupSheetItem(
                sheetContext,
                label: i18n.t('common.diy'),
                onTap: () => setSheetState(
                  () => choice = NoSpeakChoice.custom(choice.days),
                ),
                trailing: choice.isCustom ? Icons.check : null,
              ),
              // 自定义天数（老端那个数字框：这里做成真能改的）
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  IconButton(
                    onPressed: () => setSheetState(
                      () => choice = NoSpeakChoice.custom(choice.days - 1),
                    ),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text(
                    '${choice.days}',
                    style: TextStyle(fontSize: context.rpx(30)),
                  ),
                  IconButton(
                    onPressed: () => setSheetState(
                      () => choice = NoSpeakChoice.custom(choice.days + 1),
                    ),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  Text(
                    i18n.t('common.day'),
                    style: TextStyle(
                      fontSize: context.rpx(26),
                      color: AppColors.text666,
                    ),
                  ),
                ],
              ),
              const Divider(height: 1, color: AppColors.line),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (muted)
                    TextButton(
                      onPressed: () => Navigator.of(
                        sheetContext,
                      ).pop(const _NoSpeakPick.cancelMute()),
                      child: Text(
                        i18n.t('group.cancelNoSpeak'),
                        style: const TextStyle(color: AppColors.red),
                      ),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: Text(i18n.t('common.cancel')),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(sheetContext).pop(_NoSpeakPick(choice)),
                    child: Text(i18n.t('common.ok')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (picked == null) return null;
  if (picked.choice == null) return const NoSpeakSheetResult.cancelMute();
  return NoSpeakSheetResult.apply(picked.choice!);
}

/// 移出群聊的确认弹层（带「加入黑名单」开关）。
///
/// 返回 `null` = 取消；返回布尔 = 已确认，值是那个开关。
Future<bool?> showRemoveMemberSheet(BuildContext context, AppI18n i18n) async {
  var isBlack = false;
  return showAppSheet<bool>(
    context: context,
    backgroundColor: AppColors.white,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(height: context.rpx(30)),
            Icon(
              Icons.error_outline,
              size: context.rpx(60),
              color: AppColors.orange,
            ),
            SizedBox(height: context.rpx(10)),
            Text(
              i18n.t('group.removeUserTips'),
              style: TextStyle(fontSize: context.rpx(28)),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  i18n.t('common.joinBlackList'),
                  style: TextStyle(fontSize: context.rpx(26)),
                ),
                Switch(
                  value: isBlack,
                  onChanged: (value) => setSheetState(() => isBlack = value),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: Text(i18n.t('common.cancel')),
                ),
                SizedBox(width: context.rpx(40)),
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(isBlack),
                  child: Text(
                    i18n.t('common.ok'),
                    style: const TextStyle(color: AppColors.green),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.rpx(20)),
          ],
        ),
      ),
    ),
  );
}

/// 一个确认框（老端那些 `uni.showModal`：设置/取消管理员、转让群主）
///
/// 样式走全站统一的微信白框（`core/ui/wechat_dialog.dart`）。
Future<bool?> showGroupConfirm(
  BuildContext context,
  AppI18n i18n,
  String content, {
  String? okLabel,
}) => showWeChatConfirm(
  context,
  message: content,
  confirmLabel: okLabel ?? i18n.t('common.ok'),
  cancelLabel: i18n.t('common.cancel'),
);

/// 弹层内部的返回值：区分「取消禁言」与「按选中时长禁言」
class _NoSpeakPick {
  const _NoSpeakPick(this.choice);

  const _NoSpeakPick.cancelMute() : choice = null;

  final NoSpeakChoice? choice;
}
