import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../group_call/group_call_session.dart' show groupCallSessionProvider;
import '../../group_call/group_call_sync.dart' show groupCallPresenceProvider;

/// 群聊页顶部那条「N 人正在语音通话 · 加入」（S6.16）。
///
/// 与 S6.15 那条**横幅**（屏幕最上面飘 20 秒那种）是两回事，两条都要有：
///
/// | | 横幅（`GroupCallBannerHost`） | 这条（群聊页里的） |
/// |---|---|---|
/// | 什么时候在 | 有人刚开语音那一下，飘 20 秒 | **只要语音还在开就一直挂着** |
/// | 在哪儿 | 屏幕最上面，盖在任何页面之上 | 这个群的聊天页里，标题栏下面 |
/// | 为什么需要 | 你人可能在别的会话/别的 tab，得先知道你被叫了 | 你明明点进这个群了，顶上得有个「加入」的入口 |
///
/// 微信里点进一个正在语音的群，顶上就是这一条 —— 没有它，用户进了群也看不见「怎么加入」。
///
/// 两种状态（S6.17）：
///
/// | 谁 | 右边那颗 | 为什么 |
/// | --- | --- | --- |
/// | 别人在开，我还没进去 | 「加入」 | 点一下真的加入（与群资料页那个入口同一条路） |
/// | **我自己就在这一通里** | 「回到通话」 | 我退出过通话页（通话还在），点一下回去 |
///
/// 判据是两本账、两个来源：在不在通话里看**会话登记处**（`GroupCallSessionHost`，
/// 那是「我」的状态）；别人在不在看**在线状态那本账**（`GroupCallPresenceTracker`，
/// 那是「群里」的状态）。两处都拿不到就整条不画。
class GroupCallBar extends ConsumerWidget {
  const GroupCallBar({
    super.key,
    required this.conversationId,
    required this.onJoin,
  });

  /// 群会话 id（`group-5`）：在线状态那本账按它查
  final String conversationId;

  /// 点「加入」/ 点整条（进群通话页 = 加入）
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presence = ref.watch(groupCallPresenceProvider);
    final sessions = ref.watch(groupCallSessionProvider);
    final i18n = ref.watch(appI18nProvider);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[presence, sessions]),
      builder: (context, _) {
        // ① 我自己就在这一通里：整条变成「回到通话」（人数看这一通的真名单）
        final mine = sessions.sessionFor(conversationId);
        if (mine != null) {
          final count = mine.memberCount;
          return _bar(
            context,
            i18n,
            count <= 0
                ? i18n.t('group.callInProgress')
                : i18n.t('group.callPeople', <String, String>{'n': '$count'}),
            action: i18n.t('group.callReturn'),
          );
        }
        // ② 别人在开，我还没进去
        final call = presence.liveIn(conversationId);
        if (call == null) return const SizedBox.shrink();
        final members = call.members;
        return _bar(
          context,
          i18n,
          // 人数拿不到（老服务端 / 数不出来）就退化成不带人数的说法 ——
          // 人数只影响这句话好不好看，不该成为「这条提不提示」的判据
          members == null || members <= 0
              ? i18n.t('group.callInProgress')
              : i18n.t('group.callPeople', <String, String>{'n': '$members'}),
        );
      },
    );
  }

  Widget _bar(
    BuildContext context,
    AppI18n i18n,
    String label, {

    /// 右边那颗写什么（默认「加入」；我已经在里面时是「回到通话」）
    String? action,
  }) => Material(
    // 给用例一个抓手：整棵树里可能同时还有一颗小窗（S6.17），两者文案相近
    key: const Key('group-call-bar'),
    color: AppColors.white,
    child: InkWell(
      // 点整条 = 点右边那颗（「加入」/「回到通话」都走这个回调：
      // 同一个路由 —— 会话已经在的话，进去就是看着原来那一通）
      onTap: onJoin,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(20),
        ),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.line, width: 0.5)),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.phone_in_talk_rounded,
              size: context.rpx(36),
              color: AppColors.brand,
            ),
            SizedBox(width: context.rpx(16)),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text333,
                ),
              ),
            ),
            SizedBox(width: context.rpx(12)),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.rpx(24),
                vertical: context.rpx(10),
              ),
              decoration: BoxDecoration(
                color: AppColors.brand,
                borderRadius: BorderRadius.circular(context.rpx(26)),
              ),
              child: Text(
                action ?? i18n.t('group.callLiveJoin'),
                style: TextStyle(
                  fontSize: context.rpx(26),
                  color: AppColors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
