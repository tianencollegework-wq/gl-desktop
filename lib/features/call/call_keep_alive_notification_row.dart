import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/call_keep_alive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/notice_bus.dart';
import '../mine/widgets/mine_list.dart';

/// 设置里的「通话保活通知」一行（安卓 13+）。
///
/// 通话期间会挂一条常驻通知「与 X 语音通话中」，系统据此不冻结通话；通知要显示得
/// 先有 `POST_NOTIFICATIONS`。
///
/// ⚠️ **这个入口存在的意义就是把「申请权限」挪出通话**：那个系统权限框会把 App 顶到
/// 后台，而 Android 14 不允许从后台启动 mic 类型的前台服务 —— 通话中弹它，保活必然
/// 失败（真机上验证过，见 REFACTOR_PLAN 的 S6.5）。所以通话路径里只查不申请。
///
/// 不给权限也**不影响通话与保活**，只是通知栏看不到那条「通话中」。
class CallKeepAliveNotificationRow extends ConsumerStatefulWidget {
  const CallKeepAliveNotificationRow({super.key});

  @override
  ConsumerState<CallKeepAliveNotificationRow> createState() =>
      _CallKeepAliveNotificationRowState();
}

class _CallKeepAliveNotificationRowState
    extends ConsumerState<CallKeepAliveNotificationRow> {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final granted = await ref
        .read(callKeepAliveProvider)
        .hasNotificationPermission();
    if (!mounted) return;
    setState(() => _granted = granted);
  }

  Future<void> _request() async {
    final keepAlive = ref.read(callKeepAliveProvider);
    final i18n = AppI18n.instance;
    final before = await keepAlive.hasNotificationPermission();
    if (before) {
      noticeBus.toast(i18n.t('call.keepAliveNotifyOn'));
      return;
    }
    await keepAlive.requestNotificationPermission();
    // 用户可能还没点那个框，先刷新一次；再等半秒看结果
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _refresh();
    if (!mounted) return;
    if (_granted != true) {
      noticeBus.toast(i18n.t('call.keepAliveNotifyDenied'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final supported = ref.watch(callKeepAliveProvider).supported;
    // 这个平台没有前台服务（iOS/桌面）就不显示这一行
    if (!supported) return const SizedBox.shrink();

    final granted = _granted;
    // 行本身走微信那套列表样式（`MineListItem`），这里只管文案与状态色：
    // 绿 = 已开启，蓝 = 还没给权限（点一下就申请）
    return MineListItem(
      label: i18n.t('call.keepAliveNotify'),
      trailing: granted == null
          ? ''
          : i18n.t(
              granted ? 'call.keepAliveNotifyOn' : 'call.keepAliveNotifyOff',
            ),
      trailingColor: granted == true ? AppColors.green : AppColors.brand,
      onTap: _request,
    );
  }
}
