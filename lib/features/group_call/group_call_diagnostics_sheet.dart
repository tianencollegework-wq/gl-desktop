import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import 'group_call_controller.dart';
import '../../core/ui/desktop_overlay.dart';

/// 群通话诊断面板：**长按通话页**随时打开。
///
/// 群通话与 1:1 不一样的地方在于：它没有"没有候选 / 只有 host / 有 srflx 还是连不上"
/// 那几类问题（媒体是端点 ↔ Cloudflare 直连，没有点对点打洞那一步）。它的问题是
/// 下面这三类，而这个面板把它们分开：
///
/// * **订阅没建上**（「订阅」那节里看不到 `u2|mic → mid-…`）→ 快照 / 权限 / 重协商的事；
/// * **订阅建了但没流**（有订阅却听不到）→ CF 侧或对方没在发；
/// * **重建计数一直涨** → 网络或凭据问题（这通电话的体验一定差）。
///
/// 数据源是 `SfuRoom.diagnostics`（纯逻辑在 `domain/group_call/sfu_trace.dart`），
/// 这里只管显示与复制：**不碰平台通道、不落文件**，所以能跟着假房间一起测。
Future<void> showGroupCallDiagnosticsSheet(
  BuildContext context,
  GroupCallController controller,
) => showAppSheet<void>(
  context: context,
  backgroundColor: AppColors.white,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (context) => _GroupCallDiagnosticsSheet(controller: controller),
);

class _GroupCallDiagnosticsSheet extends ConsumerWidget {
  const _GroupCallDiagnosticsSheet({required this.controller});

  final GroupCallController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    // 盯着时间线：它变了就重画（一条新条目不一定伴随界面状态变化）
    return ListenableBuilder(
      listenable: controller.room.trace,
      builder: (context, _) => _body(context, i18n),
    );
  }

  Widget _body(BuildContext context, AppI18n i18n) {
    final diagnostics = controller.room.diagnostics;
    final trace = diagnostics.trace;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(context, i18n),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _section(context, i18n.t('group.diagRoom'), <Widget>[
                      _line(
                        context,
                        '${i18n.t('group.diagRoomId')}：${diagnostics.roomId}'
                        '（epoch ${diagnostics.epoch}，'
                        '${diagnostics.phase.name}）',
                      ),
                      _line(
                        context,
                        '${i18n.t('group.diagSessions')}：'
                        '${diagnostics.publishSessionId ?? i18n.t('call.diagNone')}'
                        ' ｜ '
                        '${diagnostics.receiveSessionId ?? i18n.t('call.diagNone')}',
                      ),
                      _line(
                        context,
                        '${i18n.t('group.diagPublished')}：'
                        '${diagnostics.publishedTracks.isEmpty ? i18n.t('call.diagNone') : diagnostics.publishedTracks.join('、')}',
                      ),
                      _line(
                        context,
                        '${i18n.t('group.diagSpeaker')}：'
                        '${diagnostics.activeSpeaker ?? i18n.t('call.diagNone')}',
                      ),
                    ]),
                    _section(context, i18n.t('group.diagSubs'), <Widget>[
                      if (diagnostics.subscriptions.isEmpty)
                        _line(context, i18n.t('call.diagNone'))
                      else
                        for (final line in diagnostics.subscriptions)
                          _line(context, line),
                    ]),
                    _section(context, i18n.t('group.diagCounters'), <Widget>[
                      _line(context, trace.counters),
                    ]),
                    _section(context, i18n.t('call.diagTimeline'), <Widget>[
                      if (trace.entries.isEmpty)
                        _line(context, i18n.t('call.diagEmpty'))
                      else
                        for (final entry in trace.entries)
                          _line(
                            context,
                            entry.toString(),
                            failure: entry.failure,
                          ),
                    ]),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: AppColors.line),
            _footer(context, i18n),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AppI18n i18n) => Padding(
    padding: EdgeInsets.symmetric(vertical: context.rpx(28)),
    child: Text(
      i18n.t('group.diagnostics'),
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: context.rpx(32),
        fontWeight: FontWeight.w600,
        color: AppColors.text333,
      ),
    ),
  );

  Widget _section(BuildContext context, String title, List<Widget> children) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rpx(30),
              context.rpx(18),
              context.rpx(30),
              context.rpx(8),
            ),
            child: Text(
              title,
              style: TextStyle(
                fontSize: context.rpx(26),
                fontWeight: FontWeight.w600,
                color: AppColors.text333,
              ),
            ),
          ),
          ...children,
        ],
      );

  Widget _line(BuildContext context, String text, {bool failure = false}) =>
      Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(6),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: context.rpx(24),
            color: failure ? AppColors.red : AppColors.text666,
          ),
        ),
      );

  Widget _footer(BuildContext context, AppI18n i18n) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(20),
      vertical: context.rpx(14),
    ),
    child: Row(
      children: <Widget>[
        Expanded(
          child: _button(
            context,
            label: i18n.t('call.diagCopy'),
            onTap: () => _copy(i18n),
          ),
        ),
        SizedBox(width: context.rpx(16)),
        Expanded(
          child: _button(
            context,
            label: i18n.t('common.close'),
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    ),
  );

  /// 复制整份诊断（与 1:1 面板同一颗按钮：出问题时贴给对方的就是这段文本）
  Future<void> _copy(AppI18n i18n) async {
    await Clipboard.setData(
      ClipboardData(text: controller.room.diagnostics.summary),
    );
    noticeBus.toast(i18n.t('call.diagCopied'));
  }

  Widget _button(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: context.rpx(80),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.page,
        borderRadius: BorderRadius.circular(context.rpx(12)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: context.rpx(28), color: AppColors.text333),
      ),
    ),
  );
}
