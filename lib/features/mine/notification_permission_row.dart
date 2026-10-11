import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/background_health.dart';
import '../../core/theme/app_colors.dart';
import 'widgets/mine_list.dart';

/// 设置 › 通知 里的第一行「通知权限」（安卓 13+）。
///
/// 微信的「新消息通知」页第一行是「接收新消息通知」，点一下跳系统的应用通知设置；
/// 我们这里做成**只读的状态行**：右边直说开没开，点一下跳过去开。
///
/// 为什么不做成开关：这一项是**系统权限**，App 自己关不掉（关掉等于卸载式禁用），
/// 做开关只会做成假的。微信、老端都是跳系统页。
///
/// 与 `CallKeepAliveNotificationRow` 的分工：那一行是**通话保活**那个开关，
/// 只在通话期间起作用；这一行说的是「系统到底允不允许我们弹通知」。
/// 两者查的是同一件事（`POST_NOTIFICATIONS`），但**入口不同、用户目的不同**，
/// 所以各留一行（微信在「设置 → 通知」和「设置 → 音视频通话」里也是两个地方说）。
class NotificationPermissionRow extends ConsumerStatefulWidget {
  const NotificationPermissionRow({super.key});

  @override
  ConsumerState<NotificationPermissionRow> createState() =>
      _NotificationPermissionRowState();
}

class _NotificationPermissionRowState
    extends ConsumerState<NotificationPermissionRow>
    with WidgetsBindingObserver {
  /// null = 还没查出来（右边先空着，不要先闪一个「未开启」）
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页回来时**必须重查**：用户在那边开了，这句话得跟着变
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final granted = await ref
        .read(backgroundHealthProvider)
        .notificationGranted();
    if (!mounted) return;
    setState(() => _granted = granted);
  }

  Future<void> _openSettings() async {
    await ref.read(backgroundHealthProvider).openNotificationSettings();
    // 有的 ROM 是弹框而不是跳页（返回时不触发 resumed），这里补一次
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    // 只有安卓有这道开关（iOS 的通知权限走系统设置，另说）
    if (!ref.watch(backgroundHealthProvider).supported) {
      return const SizedBox.shrink();
    }

    final granted = _granted;
    // 绿 = 已开启，蓝 = 还没开（点一下就跳过去）
    return MineListItem(
      label: i18n.t('user.notificationPermission'),
      trailing: granted == null
          ? ''
          : i18n.t(
              granted
                  ? 'user.notificationPermissionOn'
                  : 'user.notificationPermissionOff',
            ),
      trailingColor: granted == true ? AppColors.green : AppColors.brand,
      onTap: _openSettings,
    );
  }
}
