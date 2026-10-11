import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../call/call_keep_alive_notification_row.dart';
import '../call/call_keep_alive_self_check.dart';
import '../call/call_route_row.dart';
import '../call/full_screen_intent_row.dart';
import 'widgets/mine_list.dart';

/// 设置 › 音视频通话（微信 `设置 → 功能 → 音视频通话`）。
///
/// 通话相关的东西**从此都归这一页**，不再跟消息提醒的开关混在一起：
///
/// * 「通话线路」是**两端都有**的一行：这一通电话实际会用的 ICE 线路（点开是明细）。
///   它同时保证这一页**在任何平台上都不是白纸**（2026-10-10 用户：「电脑端设置的
///   音视频通话点开是啥都没有的这体验很不好，要么有东西，要么就不要有这一栏」——
///   原来那两行都是安卓专属，桌面上各自 `SizedBox.shrink()` 掉，点进来就是一片空白）；
/// * 「通话保活通知」是把**申请通知权限**挪出通话（那个系统框会把 App 顶到后台，
///   Android 14 不允许从后台起 mic 类型前台服务 —— 详见那个文件头的说明）；
/// * 「来电全屏显示」是 Android 14+ 的开关，关着时来电降级成横幅 + 响铃（照样能接）；
/// * 「前台服务自检」只有 debug 构建看得见（保活只有真机能验）。
///
/// 以前这里还有一行「通话诊断」：那是 S6.5 之前排查打不通的工具，通话本身稳定之后
/// 就没用了 —— 需要看诊断时**在通话页长按**还能打开（见 `call_page.dart`），
/// 只是不再占设置页一格。
///
/// 后三行都是安卓专属（`supported == false` 时自己不画），所以**安卓上会多几行，
/// 桌面上只有「通话线路」那一行** —— 但不再是空白页。
class CallSettingPage extends ConsumerWidget {
  const CallSettingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);

    final rows = <Widget>[
      const CallRouteRow(),
      const CallKeepAliveNotificationRow(),
      const FullScreenIntentRow(),
      if (kDebugMode)
        MineListItem(
          label: '前台服务自检（debug）',
          onTap: () => showCallKeepAliveSelfCheck(context),
        ),
    ];

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('common.webrtc'))),
      body: ListView(
        padding: EdgeInsets.only(bottom: context.rpx(40)),
        children: <Widget>[MineList(gapBefore: false, children: rows)],
      ),
    );
  }
}
