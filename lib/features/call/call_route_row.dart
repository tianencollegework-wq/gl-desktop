import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/desktop_overlay.dart';
import '../../core/ui/notice_bus.dart';
import '../../domain/call/call_route_info.dart';
import '../mine/widgets/mine_list.dart';

/// 设置里的「通话线路」一行（2026-10-10）。
///
/// **这一行的意义是让「音视频通话」这一页在任何平台上都有东西**：那一页原本只有
/// 两行安卓专属开关，桌面上各自 `SizedBox.shrink()` 掉 —— 用户点进来看到一张
/// 白纸（「要么有东西，要么就不要有这一栏」）。
///
/// 它显示的是**这一通电话实际会用的 ICE 线路**（与 `CallMediaConfig.iceServers`
/// 同一份口径，见 [CallRouteInfo]），也就是「打不通 / 没声音」时最该先看的东西：
/// 站点只配了 STUN、没配 TURN 时，双方都在严格 NAT 后面就是连不上。
///
/// 顺带能把一个很隐蔽的配错指出来：站点那栏填 `turn.example.com:3478`（漏了
/// `turn:` 前缀）时，客户端会把它当 STUN 发出去 —— 看上去“配了 TURN”其实没配
/// （见 [CallRouteInfo.suspiciousTurnLines]）。
///
/// 只读：地址来自站点后台，客户端要改得去站点后台或重新发版，所以点开是**查看**。
class CallRouteRow extends ConsumerWidget {
  const CallRouteRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final route = ref.watch(
      sessionStoreProvider.select(
        (state) => CallRouteInfo.of(state.config.chatInfo),
      ),
    );
    // 绿 = 有 TURN（严格 NAT 后面也能通），橙 = 只有公共 STUN（可能打不通）
    return MineListItem(
      label: i18n.t('call.route'),
      trailing: i18n.t(route.hasTurn ? 'call.routeTurn' : 'call.routeStunOnly'),
      trailingColor: route.hasTurn ? AppColors.green : AppColors.orange,
      onTap: () => showCallRouteSheet(context, route),
    );
  }
}

/// 打开「通话线路」详情（手机底部弹层 / 桌面居中窗口，见 [showAppSheet]）。
Future<void> showCallRouteSheet(BuildContext context, CallRouteInfo route) =>
    showAppSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => CallRouteSheet(route: route),
    );

/// 线路明细：一句人话结论 + 三段清单 + 复制。
class CallRouteSheet extends ConsumerWidget {
  const CallRouteSheet({super.key, required this.route});

  final CallRouteInfo route;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.fromLTRB(
                  context.rpx(30),
                  context.rpx(24),
                  context.rpx(30),
                  context.rpx(8),
                ),
                child: Text(
                  i18n.t('call.route'),
                  style: TextStyle(
                    fontSize: context.rpx(32),
                    fontWeight: FontWeight.bold,
                    color: AppColors.text333,
                  ),
                ),
              ),
              _hintCard(context, i18n),
              _section(context, i18n.t('call.routePublic'), <Widget>[
                for (final url in CallRouteInfo.publicStun) _line(context, url),
              ]),
              _section(context, i18n.t('call.routeSite'), <Widget>[
                if (route.siteUsesFallback)
                  _note(context, i18n.t('call.routeFallback')),
                for (final url in route.siteLines) _line(context, url),
                _note(
                  context,
                  i18n.t(
                    route.siteHasCredentials
                        ? 'call.routeAuth'
                        : 'call.routeNoAuth',
                  ),
                ),
                for (final raw in route.suspiciousTurnLines)
                  _note(
                    context,
                    i18n.t('call.routeTurnNoScheme', <String, String>{
                      'url': raw,
                    }),
                    warn: true,
                  ),
              ]),
              if (route.builtInTurnLines.isNotEmpty)
                _section(context, i18n.t('call.routeBuiltIn'), <Widget>[
                  for (final url in route.builtInTurnLines) _line(context, url),
                ]),
              Divider(height: 1, color: AppColors.line),
              _footer(context, i18n),
            ],
          ),
        ),
      ),
    );
  }

  /// 一句结论（这一页最值钱的一行）：绿 = 有 TURN，橙 = 没有可用的 TURN
  Widget _hintCard(BuildContext context, AppI18n i18n) {
    final color = route.hasTurn ? AppColors.green : AppColors.orange;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: context.rpx(30)),
      padding: EdgeInsets.all(context.rpx(22)),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.rpx(14)),
      ),
      child: Text(
        i18n.t(route.hasTurn ? 'call.routeHintTurn' : 'call.routeHintStunOnly'),
        style: TextStyle(fontSize: context.rpx(26), height: 1.4, color: color),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> lines) =>
      Padding(
        padding: EdgeInsets.fromLTRB(
          context.rpx(30),
          context.rpx(22),
          context.rpx(30),
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                fontSize: context.rpx(24),
                color: AppColors.text999,
              ),
            ),
            SizedBox(height: context.rpx(6)),
            ...lines,
          ],
        ),
      );

  Widget _line(BuildContext context, String text) => Padding(
    padding: EdgeInsets.only(top: context.rpx(6)),
    child: Text(
      text,
      style: TextStyle(
        fontSize: context.rpx(26),
        height: 1.3,
        color: AppColors.text333,
      ),
    ),
  );

  /// 灰色小注（「站点没有配置」这类补一句的话）；[warn] 时是橙色的那句警告
  Widget _note(BuildContext context, String text, {bool warn = false}) =>
      Padding(
        padding: EdgeInsets.only(top: context.rpx(6)),
        child: Text(
          text,
          style: TextStyle(
            fontSize: context.rpx(24),
            height: 1.3,
            color: warn ? AppColors.orange : AppColors.text999,
          ),
        ),
      );

  Widget _footer(BuildContext context, AppI18n i18n) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(20),
      vertical: context.rpx(10),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: route.copyText));
            noticeBus.toast(i18n.t('call.routeCopied'));
          },
          child: Text(i18n.t('call.routeCopy')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(i18n.t('common.close')),
        ),
      ],
    ),
  );
}
