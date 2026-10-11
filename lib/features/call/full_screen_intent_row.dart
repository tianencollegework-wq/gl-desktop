import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/background_health.dart';
import '../../core/theme/app_colors.dart';
import '../mine/widgets/mine_list.dart';

/// 设置里的「来电全屏显示」一行（S8.1h，安卓 14+）。
///
/// 全屏通知 = 息屏/锁屏时来电**直接亮屏弹来电界面**。安卓 14 起系统只给
/// 「通话类应用」自动授权，我们的应用类别不是通话类，所以默认是**关着**的；
/// 关着也不影响收来电 —— 系统会降级成横幅 + 响铃。
///
/// 所以这一行**只放在设置里**，不进消息列表那条红提示条（那不是病，别去烦用户）：
/// 用户觉得来电不够醒目时，自己来这一行打开就是了。
///
/// 跳的是系统的「全屏通知」设置页（`ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`），
/// 14 以下没有这个页面、系统也本来就允许，所以整行不显示。
class FullScreenIntentRow extends ConsumerStatefulWidget {
  const FullScreenIntentRow({super.key});

  @override
  ConsumerState<FullScreenIntentRow> createState() =>
      _FullScreenIntentRowState();
}

class _FullScreenIntentRowState extends ConsumerState<FullScreenIntentRow> {
  /// null = 还没查出来（这一格先空着，不要先闪一个「未开启」）
  bool? _allowed;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final allowed = await ref
        .read(backgroundHealthProvider)
        .fullScreenIntentAllowed();
    if (!mounted) return;
    setState(() => _allowed = allowed);
  }

  Future<void> _open() async {
    await ref.read(backgroundHealthProvider).openFullScreenIntentSettings();
    // 用户可能还没返回（有的 ROM 是弹框而不是跳页），先刷一次；
    // 回到前台时 `systemHealthProvider` 那条链也会再刷系统开关，
    // 这里再补一次是为了这一行自己跟上
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    // 只有安卓有这套开关（iOS 走 CallKit，另说）
    if (!ref.watch(backgroundHealthProvider).supported) {
      return const SizedBox.shrink();
    }

    final allowed = _allowed;
    // 行本身走微信那套列表样式（`MineListItem`）：绿 = 已允许，蓝 = 还关着
    return MineListItem(
      label: i18n.t('call.fullScreen'),
      trailing: allowed == null
          ? ''
          : i18n.t(allowed ? 'call.fullScreenOn' : 'call.fullScreenOff'),
      trailingColor: allowed == true ? AppColors.green : AppColors.brand,
      onTap: _open,
    );
  }
}
