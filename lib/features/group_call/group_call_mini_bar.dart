import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../domain/call/call_duration.dart';
import '../../domain/group_call/sfu_room.dart';
import 'group_call_session.dart';

/// 群通话**小窗**：页面关掉之后还听得见看得着的那颗药丸（S6.17）。
///
/// 为什么需要它：S6.17 起「点返回键 = 退出页面」，通话继续在跑 —— 那总得有个地方
/// 告诉你「你还在一通话里」，以及一个点一下回到通话页的入口（微信就是那么一颗）。
/// 没有它，用户会以为电话挂了，或者找不到怎么回去。
///
/// 几条做法：
///
/// * **只在通话页不在台上时出现**（[GroupCallSessionHost.pageOpen]）：页面上已经有
///   一样的四颗钮，再飘一颗小窗是重复；
/// * **可以拖着走**：挡着东西时自己挪（微信那个也一样），松手后钳在屏幕内；
/// * 点整颗 = 回通话页（同一条路由，进去就是「看着」原来那一通，不会重开）；
/// * 右边那颗挂断是**唯一的兜底**：页面关着的时候也得有地方能把这通结束掉。
///
/// 挂在 `MaterialApp.builder` 最外层（与横幅同一层）：它要盖在**所有页面**之上。
class GroupCallMiniBarHost extends ConsumerStatefulWidget {
  const GroupCallMiniBarHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<GroupCallMiniBarHost> createState() =>
      _GroupCallMiniBarHostState();
}

class _GroupCallMiniBarHostState extends ConsumerState<GroupCallMiniBarHost> {
  /// 拖动后的位置（null = 还没拖过，用默认位置）
  Offset? _dragged;

  /// 外壳那一层的形状**必须恒定**（永远是这个 `Stack`）—— 与 `DesktopShell` 里
  /// 写着的是同一条规矩：某一态直接 `return widget.child`、另一态返回一层容器，
  /// 「翻面」那一帧的子树就会**按类型比对失败、被整棵重挂**。
  ///
  /// 这个宿主挂在 `MaterialApp.builder` 上，所以重挂的是 **Router 那一整棵**
  /// （页面状态只是靠 Navigator 自己那把 GlobalKey 才没丢，不该指望它）。
  /// 小窗一秒能显隐好几次，没必要每次都走一遍重挂。
  ///
  /// 下面只换「里面那颗药丸在与不在」，层次一个字不动。
  @override
  Widget build(BuildContext context) {
    final host = ref.watch(groupCallSessionProvider);
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final session = host.active;
        // 没有通话、或人正看着通话页：药丸不画（不是不画这一层）
        return Stack(
          children: <Widget>[
            widget.child,
            if (session != null && !host.pageOpen)
              Positioned.fill(child: _overlay(context, session)),
          ],
        );
      },
    );
  }

  Widget _overlay(BuildContext context, GroupCallSession session) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final width = _widthOf(context, size);
          final height = context.rpx(104);
          final fallback = Offset(
            context.rpx(16),
            context.statusBarHeight + context.rpx(12),
          );
          final place = _clamp(_dragged ?? fallback, size, width, height);
          return Stack(
            children: <Widget>[
              Positioned(
                left: place.dx,
                top: place.dy,
                width: width,
                height: height,
                child: GestureDetector(
                  // 拖着走：挡着别人的东西时自己挪开（松手后会被钳回屏幕里）
                  onPanUpdate: (details) => setState(() {
                    _dragged = place + details.delta;
                  }),
                  child: _pill(context, session),
                ),
              ),
            ],
          );
        },
      );

  /// 药丸宽度：跟着屏宽走，但最多按设计稿的 640rpx（不然在平板上拉成一条横幅）
  double _widthOf(BuildContext context, Size size) {
    final byScreen = size.width - context.rpx(30);
    final byDesign = context.rpx(640);
    return byScreen < byDesign ? byScreen : byDesign;
  }

  /// 摆回屏幕里（顶到状态栏以下、底留一点边距，别压到系统手势条）
  Offset _clamp(Offset value, Size size, double width, double height) {
    final minX = 0.0;
    final maxX = size.width - width;
    final minY = 0.0;
    final maxY = size.height - height;
    return Offset(
      value.dx.clamp(minX, maxX < minX ? minX : maxX),
      value.dy.clamp(minY, maxY < minY ? minY : maxY),
    );
  }

  Widget _pill(BuildContext context, GroupCallSession session) {
    final i18n = ref.watch(appI18nProvider);
    final view = session.view;
    final joined = view.phase == SfuRoomPhase.joined;
    final subtitle = switch (view.phase) {
      SfuRoomPhase.failed => i18n.t('group.callFailed'),
      SfuRoomPhase.rebuilding => i18n.t('group.callReconnecting'),
      SfuRoomPhase.joined => _status(i18n, session),
      _ => i18n.t('group.callJoining'),
    };
    return Material(
      color: AppColors.brand,
      elevation: 8,
      borderRadius: BorderRadius.circular(context.rpx(24)),
      child: InkWell(
        borderRadius: BorderRadius.circular(context.rpx(24)),
        // 点整颗 = 回通话页（进去就是原来这一通，不会重开）
        onTap: () => _return(session),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rpx(22)),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.phone_in_talk_rounded,
                size: context.rpx(36),
                color: AppColors.white,
              ),
              SizedBox(width: context.rpx(14)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      session.name.isEmpty
                          ? i18n.t('group.call')
                          : session.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        fontWeight: FontWeight.w600,
                        color: AppColors.white,
                      ),
                    ),
                    SizedBox(height: context.rpx(4)),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.rpx(22),
                        color: AppColors.white,
                      ),
                    ),
                  ],
                ),
              ),
              if (joined) ...<Widget>[
                SizedBox(width: context.rpx(10)),
                // 「回到通话」：这一颗是**给不看小窗的人看的说明**
                // （整颗都能点，这里只是把意思写出来）
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rpx(20),
                    vertical: context.rpx(10),
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(context.rpx(24)),
                  ),
                  child: Text(
                    i18n.t('group.callReturn'),
                    style: TextStyle(
                      fontSize: context.rpx(24),
                      color: AppColors.brand,
                    ),
                  ),
                ),
              ],
              SizedBox(width: context.rpx(6)),
              // 兜底：页面关着时总得有地方能挂断。
              // ⚠️ 不给它 `tooltip`：小窗挂在 `MaterialApp.builder` 上、在 Navigator
              // **外面**，那里没有 Overlay，带 tooltip 的按钮一构建就报
              // 「No Overlay widget found」（`group_call_mini_bar_test` 抓出来的）。
              IconButton(
                key: const Key('group-call-mini-hangup'),
                iconSize: context.rpx(40),
                color: AppColors.white,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tightFor(
                  width: context.rpx(56),
                  height: context.rpx(56),
                ),
                icon: const Icon(Icons.call_end_rounded),
                onPressed: () => unawaited(_hangup()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「3 人 · 12:03」（还没进房间时不画这颗药丸的按钮位，见 `_pill`）
  String _status(AppI18n i18n, GroupCallSession session) {
    final people = i18n.t('group.callPeople', <String, String>{
      'n': '${session.memberCount}',
    });
    final seconds = session.elapsed.inSeconds;
    if (seconds <= 0) return people;
    return '$people · ${formatCallDuration(seconds)}';
  }

  void _return(GroupCallSession session) {
    ref
        .read(appRouterProvider)
        .push(
          '${AppRoutes.groupCall}'
          '?id=${Uri.encodeComponent(session.conversationId)}'
          '&name=${Uri.encodeComponent(session.name)}',
        );
  }

  Future<void> _hangup() => ref.read(groupCallSessionProvider).end();
}
