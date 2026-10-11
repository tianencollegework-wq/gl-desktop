import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../domain/notify/system_health.dart';

/// 老端 `uni-notice-bar` 那两个颜色参数（`pages/message/index.vue` 第 26/27 行）
/// —— 红字 + 粉底。不放进 [AppColors]：那是 colorui 那套类名的对照表，
/// 这两个是一次性用的参数。
const Color _noticeText = Color(0xFFF56C6C);
const Color _noticeBackground = Color(0xFFFDE2E2);

/// 会话列表顶部的「系统可能让你收不到消息」提示条 —— 老端 6.2.0
/// `pages/message/index.vue` 那两条 `uni-notice-bar` 里**剩下的最后一条**：
///
/// * **通知权限关着** → 消息落库了、提示音响了，但通知栏里什么都没有，
///   锁屏状态下用户**根本不知道**有人找他。
///
/// 另两条都先后去掉了（都只留设置里的入口，不再常驻红条）：
/// * 「系统开启了省电优化」2026-09-27（消息到达已经靠厂商推送唤醒，那条链子断了
///   照样收得到）；
/// * 「来电全屏显示未开启」2026-09-30（用户：「首页顶部那条红色横幅删掉，通话提醒
///   就在发起通话之前弹窗提示就好了啊」→ 改成拨号前的一次性弹窗，见
///   `core/ui/permission_gate.dart::remindFullScreenBeforeCall`）。
///
/// 点一下跳到系统设置页；从设置页回来时 `SystemHealthNotifier`
/// 会重查，改好了它就自己消失。
class SystemHealthBanner extends ConsumerWidget {
  const SystemHealthBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    // 还没查出来（或者没有这套开关的平台）时**不占位**：不能先闪一条错提示
    final hint =
        ref.watch(systemHealthProvider).value?.hint ?? SystemHealthHint.none;
    if (hint == SystemHealthHint.none) return const SizedBox.shrink();

    final (IconData icon, String text) = switch (hint) {
      SystemHealthHint.notification => (
        Icons.notifications_off_outlined,
        i18n.t('system.notNotify'),
      ),
      SystemHealthHint.none => (Icons.info_outline, ''),
    };

    return GestureDetector(
      onTap: () =>
          unawaited(ref.read(systemHealthProvider.notifier).fixHint(hint)),
      child: Container(
        width: double.infinity,
        color: _noticeBackground,
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(20),
          vertical: context.rpx(14),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: context.rpx(30), color: _noticeText),
            SizedBox(width: context.rpx(10)),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(24),
                  color: _noticeText,
                  height: 1.3,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: context.rpx(30),
              color: AppColors.text999,
            ),
          ],
        ),
      ),
    );
  }
}
