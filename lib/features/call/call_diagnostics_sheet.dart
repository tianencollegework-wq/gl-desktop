import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/media/media_saver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/util/dump_file.dart';
import '../../domain/call/call_diagnostics.dart';
import '../../core/ui/desktop_overlay.dart';

/// 通话诊断面板：安卓端「打不通 / 黑屏 / 没声音」的第一排查工具。
///
/// 四种「连不上」在界面上长得一模一样（都在「正在接通…」），这个面板把它们分开：
/// 没候选（配置/权限） / 只有 host（STUN 没生效） / 有 srflx 还是连不上（必须
/// TURN） / 连上了但走中转。没有它，每次打不通都只能靠猜。
///
/// 两个入口：
/// * 通话页长按浮层（通话前/通话中，看的是**这一通**的实时数据）；
/// * 「设置 → 通话诊断」（看**上一通**的存档，通话结束后不会被清掉）。
///
/// 采集在 `domain/call/call_diagnostics.dart`（纯逻辑），这里只管显示与导出。
Future<void> showCallDiagnosticsSheet(
  BuildContext context,
  ValueListenable<CallDiagnostics> source,
) => showAppSheet<void>(
  context: context,
  backgroundColor: AppColors.white,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (context) => _CallDiagnosticsSheet(source: source),
);

/// 那行结论的颜色：绿=已连通、橙=没连上但走中转、灰=还没通话。
///
/// 单独拿出来（而不是写在 `_hintCard` 里）有两个好处：用例能直接钉这段判断，
/// 而且配色只看 `diagnostics.connected` 这个**布尔字段** —— 以前是
/// `hint.contains('已连通')`，改个措辞颜色就静默失效。
Color hintColorOf(CallDiagnostics diagnostics) {
  if (diagnostics.connected) return AppColors.green;
  if (diagnostics.latestSample?.relayed ?? false) return AppColors.orange;
  return AppColors.text666;
}

class _CallDiagnosticsSheet extends ConsumerStatefulWidget {
  const _CallDiagnosticsSheet({required this.source});

  final ValueListenable<CallDiagnostics> source;

  @override
  ConsumerState<_CallDiagnosticsSheet> createState() =>
      _CallDiagnosticsSheetState();
}

class _CallDiagnosticsSheetState extends ConsumerState<_CallDiagnosticsSheet> {
  /// 正在导出 / 已经导出（导出按钮上转一下，避免连点写出一堆文件）
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    return SafeArea(
      child: ValueListenableBuilder<CallDiagnostics>(
        valueListenable: widget.source,
        builder: (context, diagnostics, _) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _header(context, i18n, diagnostics),
                if (diagnostics.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(context.rpx(30)),
                    child: Text(
                      i18n.t('call.diagEmpty'),
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        color: AppColors.text999,
                      ),
                    ),
                  )
                else ...<Widget>[
                  _hintCard(context, diagnostics),
                  _section(context, i18n.t('call.diagCandidates'), <Widget>[
                    _line(context, _candidates(i18n, diagnostics)),
                  ]),
                  _section(context, i18n.t('call.diagConnection'), <Widget>[
                    _connection(context, i18n, diagnostics),
                  ]),
                  if (diagnostics.iceServers.isNotEmpty)
                    _section(context, i18n.t('call.diagIceServers'), <Widget>[
                      for (final server in diagnostics.iceServers)
                        _line(context, server),
                    ]),
                  _section(context, i18n.t('call.diagSignals'), <Widget>[
                    _line(context, _signalsText(i18n, diagnostics)),
                  ]),
                  _section(context, i18n.t('call.diagTimeline'), <Widget>[
                    for (final event in diagnostics.events)
                      _line(context, _eventText(diagnostics, event)),
                  ]),
                ],
                Divider(height: 1, color: AppColors.line),
                _footer(context, i18n, diagnostics),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 头部

  Widget _header(
    BuildContext context,
    AppI18n i18n,
    CallDiagnostics diagnostics,
  ) {
    final kind = diagnostics.video ? 'call.videoCall' : 'call.voiceCall';
    final role = diagnostics.caller ? 'call.diagCaller' : 'call.diagCallee';
    final subtitle = diagnostics.isEmpty
        ? ''
        : <String>[
            i18n.t(kind),
            i18n.t(role),
            if (diagnostics.peer.isNotEmpty) diagnostics.peer,
          ].join(' · ');

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.rpx(30),
        context.rpx(24),
        context.rpx(30),
        context.rpx(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            i18n.t('call.diagnostics'),
            style: TextStyle(
              fontSize: context.rpx(32),
              fontWeight: FontWeight.bold,
              color: AppColors.text333,
            ),
          ),
          if (subtitle.isNotEmpty) ...<Widget>[
            SizedBox(height: context.rpx(8)),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: context.rpx(24),
                color: AppColors.text999,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 一句结论（面板最值钱的一行）：绿=连上、橙=没连上、灰=还没通话
  Widget _hintCard(BuildContext context, CallDiagnostics diagnostics) {
    final color = hintColorOf(diagnostics);
    return Container(
      margin: EdgeInsets.symmetric(horizontal: context.rpx(30)),
      padding: EdgeInsets.all(context.rpx(22)),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.rpx(14)),
      ),
      child: Text(
        diagnostics.hint,
        style: TextStyle(fontSize: context.rpx(26), height: 1.4, color: color),
      ),
    );
  }

  // ------------------------------------------------------------------ 明细

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
                fontSize: context.rpx(26),
                fontWeight: FontWeight.bold,
                color: AppColors.text333,
              ),
            ),
            SizedBox(height: context.rpx(8)),
            ...lines,
          ],
        ),
      );

  Widget _line(BuildContext context, String text) => Padding(
    padding: EdgeInsets.only(bottom: context.rpx(6)),
    child: Text(
      text,
      style: TextStyle(
        fontSize: context.rpx(24),
        height: 1.35,
        color: AppColors.text666,
      ),
    ),
  );

  String _candidates(AppI18n i18n, CallDiagnostics diagnostics) =>
      '${i18n.t('call.diagLocal')} ${diagnostics.localCandidateCount}'
      '（${_kindText(i18n, diagnostics.localCandidates)}） / '
      '${i18n.t('call.diagRemote')} ${diagnostics.remoteCandidateCount}'
      '（${_kindText(i18n, diagnostics.remoteCandidates)}）';

  String _kindText(AppI18n i18n, Map<IceCandidateKind, int> counts) {
    final parts = <String>[
      for (final kind in IceCandidateKind.values)
        if ((counts[kind] ?? 0) > 0) '${kind.label} ${counts[kind]}',
    ];
    return parts.isEmpty ? i18n.t('call.diagNone') : parts.join(' / ');
  }

  /// 连接这一段：走没走中转、RTT、码率、丢包
  Widget _connection(
    BuildContext context,
    AppI18n i18n,
    CallDiagnostics diagnostics,
  ) {
    final sample = diagnostics.latestSample;
    if (sample == null || sample.isEmpty) {
      return _line(context, i18n.t('call.diagNoSample'));
    }
    final pair =
        sample.localCandidateType.isEmpty && sample.remoteCandidateType.isEmpty
        ? ''
        : '${sample.localCandidateType.isEmpty ? '?' : sample.localCandidateType}'
              ' → '
              '${sample.remoteCandidateType.isEmpty ? '?' : sample.remoteCandidateType}'
              '${sample.protocol.isEmpty ? '' : '（${sample.protocol}）'}';
    final rtt = sample.roundTripMs == null
        ? ''
        : 'RTT ${sample.roundTripMs}ms'
              '${diagnostics.rttMinMs == null ? '' : '（${diagnostics.rttMinMs}~${diagnostics.rttMaxMs}）'}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (pair.isNotEmpty) _line(context, pair),
        if (rtt.isNotEmpty) _line(context, rtt),
        _line(
          context,
          '${_kbps(diagnostics.upstreamKbps)} ↑ / '
          '${_kbps(diagnostics.downstreamKbps)} ↓ · '
          '${i18n.t('call.diagSamples')} ${diagnostics.sampleCount}',
        ),
        _line(
          context,
          '${i18n.t('call.diagLoss')} ${sample.packetsLost} · '
          '${i18n.t('call.diagJitter')} ${sample.jitterMs}ms'
          '${sample.framesPerSecond > 0 ? ' · ${sample.framesPerSecond}fps' : ''}',
        ),
      ],
    );
  }

  String _signalsText(AppI18n i18n, CallDiagnostics diagnostics) {
    final sent = <String>[
      for (final entry in diagnostics.signals.entries)
        '${entry.key} ${entry.value}',
    ];
    final failed = <String>[
      for (final entry in diagnostics.failedSignals.entries)
        '${entry.key} ${entry.value}',
    ];
    final text = sent.isEmpty ? i18n.t('call.diagNone') : sent.join(' / ');
    if (failed.isEmpty) return text;
    return '$text ｜ ${i18n.t('call.diagFailed')} ${failed.join(' / ')}';
  }

  /// 时间线：`+0.32s 取本机媒体`
  String _eventText(CallDiagnostics diagnostics, CallDiagnosticsEvent event) {
    final start = diagnostics.startedAt;
    if (start == null) return event.label;
    final seconds = event.at.difference(start).inMilliseconds / 1000;
    return '+${seconds.toStringAsFixed(2)}s  ${event.label}';
  }

  String _kbps(double? value) => value == null
      ? '—'
      : (value >= 1000
            ? '${(value / 1000).toStringAsFixed(1)}Mbps'
            : '${value.round()}kbps');

  // ------------------------------------------------------------------ 底部

  Widget _footer(
    BuildContext context,
    AppI18n i18n,
    CallDiagnostics diagnostics,
  ) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(20),
      vertical: context.rpx(14),
    ),
    child: Row(
      children: <Widget>[
        if (!diagnostics.isEmpty)
          Expanded(
            child: _footerButton(
              context,
              label: i18n.t('call.diagCopy'),
              onTap: () => _copy(i18n, diagnostics),
            ),
          ),
        if (!diagnostics.isEmpty) SizedBox(width: context.rpx(16)),
        if (!diagnostics.isEmpty)
          Expanded(
            child: _footerButton(
              context,
              label: _exporting
                  ? i18n.t('call.diagExporting')
                  : i18n.t('call.diagExport'),
              onTap: _exporting ? null : () => _export(i18n, diagnostics),
            ),
          ),
        if (diagnostics.isEmpty)
          Expanded(
            child: _footerButton(
              context,
              label: i18n.t('common.close'),
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
      ],
    ),
  );

  Widget _footerButton(
    BuildContext context, {
    required String label,
    required VoidCallback? onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: context.rpx(88),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: onTap == null ? AppColors.line : AppColors.brand,
        borderRadius: BorderRadius.circular(context.rpx(44)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: context.rpx(28), color: AppColors.white),
      ),
    ),
  );

  /// 复制整份诊断文本（贴给谁都行）
  Future<void> _copy(AppI18n i18n, CallDiagnostics diagnostics) async {
    await Clipboard.setData(ClipboardData(text: diagnostics.summary));
    noticeBus.toast(i18n.t('call.diagCopied'));
  }

  /// 导出成 txt（文件落在应用文档目录，导出后可以直接用系统应用打开）
  Future<void> _export(AppI18n i18n, CallDiagnostics diagnostics) async {
    final saver = ref.read(mediaSaverProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _exporting = true);
    try {
      final path = await writeTextDump(
        prefix: 'call_diag',
        content: diagnostics.summary,
      );
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            i18n.t('call.diagExported', <String, String>{'path': path}),
          ),
          action: SnackBarAction(
            label: i18n.t('call.diagOpen'),
            onPressed: () => saver.openLocalFile(path),
          ),
        ),
      );
    } catch (error) {
      // 导出失败不能把面板弄崩：说一句就完了
      noticeBus.toast(
        i18n.t('call.diagExportFailed', <String, String>{'error': '$error'}),
      );
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      } else {
        _exporting = false;
      }
    }
  }
}
