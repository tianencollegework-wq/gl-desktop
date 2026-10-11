import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/i18n/locale_controller.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/wechat_dialog.dart';
import 'widgets/mine_list.dart';

/// 设置 › 界面与显示（微信 `设置 → 通用 → 界面与显示`）。
///
/// 装的是「改了之后界面会变样」的两项：圆形头像、语言。
/// （老端这两项跟消息提醒的开关混在一页里。）
class DisplaySettingPage extends ConsumerWidget {
  const DisplaySettingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final setting = ref.watch(
      sessionStoreProvider.select((state) => state.setting),
    );
    final locale = ref.watch(localeProvider);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('user.appearance'))),
      body: ListView(
        padding: EdgeInsets.only(bottom: context.rpx(40)),
        children: <Widget>[
          MineList(
            gapBefore: false,
            children: <Widget>[
              MineSwitchItem(
                label: i18n.t('user.circleAvatar'),
                value: setting.circleAvatar,
                onChanged: (value) => ref
                    .read(sessionStoreProvider.notifier)
                    .applySetting(setting.copyWith(circleAvatar: value)),
              ),
              MineListItem(
                label: i18n.t('user.language'),
                trailing: LocaleController.labelOf(locale, i18n),
                onTap: () => _pickLocale(context, ref, i18n, locale),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 语言选择。老端是个 picker，微信是「多语言」二级页；
  /// 我们这里选项不多，弹个小选择框就够。
  ///
  /// 弹窗用全站那套微信白框（`core/ui/wechat_dialog.dart`）；
  /// 微信里选语言是个整页，这里只是几个选项，所以拿「一行一项」当框的内容、
  /// 底下留一颗「取消」。
  ///
  /// 列表用 [LocaleController.pickerItems]：它比 `options` 多最上面那条
  /// 「跟随系统」（哨兵码 `system`，选它就是回到自动）。
  Future<void> _pickLocale(
    BuildContext context,
    WidgetRef ref,
    AppI18n i18n,
    LocaleChoice current,
  ) async {
    final items = LocaleController.pickerItems(i18n);
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => WeChatDialogBox(
        actions: <WeChatDialogAction>[
          WeChatDialogAction(label: i18n.t('common.cancel'), value: 'cancel'),
        ],
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < items.length; i++) ...<Widget>[
              if (i != 0) Container(height: 0.5, color: AppColors.rowDivider),
              InkWell(
                onTap: () => Navigator.of(dialogContext).pop(items[i].code),
                child: SizedBox(
                  height: context.rpx(104),
                  child: Row(
                    children: <Widget>[
                      SizedBox(width: context.rpx(56)),
                      Expanded(
                        child: Text(
                          items[i].label,
                          style: TextStyle(
                            fontSize: context.rpx(32),
                            color: AppColors.text000,
                          ),
                        ),
                      ),
                      if (items[i].code == current.selectedCode)
                        Padding(
                          padding: EdgeInsets.only(right: context.rpx(30)),
                          child: const Icon(
                            Icons.check,
                            color: AppColors.wechatGreen,
                          ),
                        )
                      else
                        SizedBox(width: context.rpx(30)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (picked == null || picked == 'cancel') return;
    await ref.read(localeProvider.notifier).setLocale(picked);
  }
}
