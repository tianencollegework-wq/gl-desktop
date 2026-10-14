import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/background_health.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/model/app_setting.dart';
import 'notification_permission_row.dart';
import 'widgets/mine_list.dart';

/// 设置 › 通知（微信 `设置 → 通知`）。
///
/// 老端把这两个开关跟「圆形头像」「语言」混在一页的「新消息 / 其他设置」里；
/// 这里按微信拆出来：**消息提醒相关的放这儿**。
///
/// 顺序照微信：最上面是**系统的通知权限**（只读状态行，点一下跳系统设置），
/// 下面才是我们自己的「声音 / 震动」两个开关 —— 权限管的是**能不能弹出来**，
/// 开关管的是**弹出来时响不响**，所以权限在上面。
///
/// 改一个存一次（老端也是「改内存那份 appSetting，再整份写回 storage」）。
class NotificationSettingPage extends ConsumerWidget {
  const NotificationSettingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final setting = ref.watch(
      sessionStoreProvider.select((state) => state.setting),
    );
    // 通知权限那一行只在手机上有（安卓 / iOS；桌面没有通知权限这回事）
    final hasPermissionRow = ref.watch(backgroundHealthProvider).supported;

    void update(AppSetting next) =>
        ref.read(sessionStoreProvider.notifier).applySetting(next);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('user.notification'))),
      body: ListView(
        padding: EdgeInsets.only(bottom: context.rpx(40)),
        children: <Widget>[
          if (hasPermissionRow)
            MineList(
              gapBefore: false,
              children: <Widget>[const NotificationPermissionRow()],
            ),
          MineList(
            header: i18n.t('user.newMessage'),
            children: <Widget>[
              MineSwitchItem(
                label: i18n.t('user.voice'),
                value: setting.voiceStatus,
                onChanged: (value) =>
                    update(setting.copyWith(voiceStatus: value)),
              ),
              MineSwitchItem(
                label: i18n.t('user.vibration'),
                value: setting.vibrateStatus,
                onChanged: (value) =>
                    update(setting.copyWith(vibrateStatus: value)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
