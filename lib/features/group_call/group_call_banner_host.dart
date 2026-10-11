import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../domain/call/call_busy.dart';
import '../../domain/group_call/group_call_presence.dart';
import 'group_call_sync.dart' show groupCallPresenceProvider;

/// 「群里有人开语音了」的**应用内横幅**（S6.15）。
///
/// 管的是长连接那条路：人就在 App 里（不管停在哪个页面），别人开了语音时屏幕上
/// 飘一条「群名 / 张三 邀请你加入群语音」，点「加入」直接进群通话页。
///
/// 与 S6.14 那条**离线推送**是互补的两半，别混起来：
///
/// | | App 没在跑 | App 在跑（这个） |
/// |---|---|---|
/// | 怎么知道 | 服务端推 `groupCalling` | 长连接推 `sfuRoom`（`started` 那一次） |
/// | 怎么提示 | 系统通知 + 响铃 | 屏幕上飘一条横幅（**不响铃**：人就在手机前） |
/// | 收了之后 | 点通知进群通话页 | 点「加入」进群通话页（同一条路由） |
///
/// 几个刻意的做法：
///
/// * **我就在那间屋里时不提示**：逻辑在 [GroupCallPresenceTracker]（登记的房间、
///   以及「我点进去了」这两种情况都不弹）；
/// * **只弹「刚开」那一次**：中途有人进来不重复提示（与离线推送同一个取舍）；
/// * **过一会儿自己收掉**（[bannerDuration]）：横幅不是待办清单，会话列表那一行的
///   「语音通话中」才是留着的那个记号；
/// * 挂在 `MaterialApp.builder` 上（与 [CallHost] / `NotificationHost` 同一层）：
///   它要**在任何页面上**都活着，而且要浮在 AppBar 之上。
class GroupCallBannerHost extends ConsumerStatefulWidget {
  const GroupCallBannerHost({super.key, required this.child});

  final Widget child;

  /// 横幅自己挂多久。
  ///
  /// 20 秒是「抬头就能看见」与「别赖着不走」之间的折中：它只是把「有人在开语音」
  /// 这件事现在告诉你一次，收掉之后会话列表那一行还在（那条才是长驻的记号）。
  static const Duration bannerDuration = Duration(seconds: 20);

  @override
  ConsumerState<GroupCallBannerHost> createState() =>
      _GroupCallBannerHostState();
}

class _GroupCallBannerHostState extends ConsumerState<GroupCallBannerHost> {
  late final GroupCallPresenceTracker _presence = ref.read(
    groupCallPresenceProvider,
  );

  Timer? _timer;

  /// 当前横幅挂着的那一通（用来判断「还是不是同一条」，别把计时器一直重开）
  String _shownKey = '';

  @override
  void initState() {
    super.initState();
    _presence.addListener(_onPresenceChanged);
    _onPresenceChanged();
  }

  @override
  void dispose() {
    _presence.removeListener(_onPresenceChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _onPresenceChanged() {
    final invite = _presence.pendingInvite;
    final key = invite?.inviteKey ?? '';
    if (key == _shownKey) return;
    _shownKey = key;
    _timer?.cancel();
    _timer = null;
    if (invite == null) return;
    // 到点自己收掉：`dismiss` 会把这一通记进「不再提示」，界面跟着收
    _timer = Timer(
      GroupCallBannerHost.bannerDuration,
      () => _presence.dismiss(invite),
    );
  }

  /// 点「加入」：进那个群的群通话页（与在群资料页点「群通话」、
  /// 与点离线通知进来，走的是**同一条**路由 —— 进去就是加入）。
  ///
  /// 正在打 1:1 电话时不给进（与群资料页那颗入口同一个判据、同一句提示）：
  /// 一条链路一只麦克风，硬进只会把两通电话都弄坏。
  void _join(GroupCallLive invite) {
    _presence.dismiss(invite);
    if (ref.read(callBusyProvider)) {
      noticeBus.toast(ref.read(appI18nProvider).t('group.callBusy'));
      return;
    }
    ref
        .read(appRouterProvider)
        .push(
          '${AppRoutes.groupCall}'
          '?id=${Uri.encodeComponent(invite.conversationId)}'
          '&name=${Uri.encodeComponent(invite.groupName)}',
        );
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: <Widget>[
      widget.child,
      // 贴在屏幕最上面、盖在导航栏之上（`SafeArea` 让它落在状态栏下面）
      Positioned(top: 0, left: 0, right: 0, child: _banner(context)),
    ],
  );

  Widget _banner(BuildContext context) {
    // 两件事都会让横幅显隐：谁在开语音（presence）与「我现在正打着 1:1 电话吗」
    // （后者期间不弹 —— 那时人已经占着麦克风了，横幅摆出来也进不去）
    final busy = ref.watch(callBusyProvider);
    return ListenableBuilder(
      listenable: _presence,
      builder: (context, _) {
        final invite = _presence.pendingInvite;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          // 收起时向上折叠（横幅在屏幕最上面，往上收才像「走了」）
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[...previous, ?current],
          ),
          transitionBuilder: (child, animation) => SizeTransition(
            sizeFactor: animation,
            // 从顶上展开 / 往顶上收起（横幅就在屏幕最上面）
            alignment: Alignment.topCenter,
            child: FadeTransition(opacity: animation, child: child),
          ),
          // 没有要提示的那一通（或被 1:1 电话挡住）时**整棵子树都不在**：
          // 半个透明横幅挂在屏幕外比不画更糟（它还会吃掉触摸）
          child: invite == null || busy
              ? const SizedBox(width: double.infinity)
              : _card(context, invite),
        );
      },
    );
  }

  Widget _card(BuildContext context, GroupCallLive invite) {
    final i18n = ref.watch(appI18nProvider);
    final starter = invite.starterName;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(24),
          vertical: context.rpx(16),
        ),
        child: Material(
          color: AppColors.white,
          elevation: 6,
          borderRadius: BorderRadius.circular(context.rpx(24)),
          child: InkWell(
            borderRadius: BorderRadius.circular(context.rpx(24)),
            onTap: () => _join(invite),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.rpx(28),
                vertical: context.rpx(24),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: context.rpx(76),
                    height: context.rpx(76),
                    decoration: const BoxDecoration(
                      color: AppColors.brand,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.phone_in_talk_rounded,
                      size: context.rpx(40),
                      color: AppColors.white,
                    ),
                  ),
                  SizedBox(width: context.rpx(22)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          invite.groupName.isEmpty
                              ? i18n.t('group.pushTitle')
                              : invite.groupName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.rpx(30),
                            fontWeight: FontWeight.w600,
                            color: AppColors.text000,
                          ),
                        ),
                        SizedBox(height: context.rpx(6)),
                        Text(
                          starter.isEmpty
                              ? i18n.t('group.callLiveGeneric')
                              : i18n.t('group.callLiveHint', <String, String>{
                                  'name': starter,
                                }),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.rpx(26),
                            color: AppColors.text666,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.rpx(10)),
                  // 「忽略」只是把这一条横幅按掉（列表标记照留）；
                  // 「加入」是主操作，做成实心绿
                  GestureDetector(
                    onTap: () => _presence.dismiss(invite),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.rpx(16),
                        vertical: context.rpx(14),
                      ),
                      child: Text(
                        i18n.t('group.callLiveIgnore'),
                        style: TextStyle(
                          fontSize: context.rpx(28),
                          color: AppColors.text999,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: context.rpx(8)),
                  GestureDetector(
                    onTap: () => _join(invite),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.rpx(28),
                        vertical: context.rpx(14),
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.brand,
                        borderRadius: BorderRadius.circular(context.rpx(30)),
                      ),
                      child: Text(
                        i18n.t('group.callLiveJoin'),
                        style: TextStyle(
                          fontSize: context.rpx(28),
                          color: AppColors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
