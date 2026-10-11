import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/app_installer.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../data/model/app_update.dart';
import '../../data/repo/update_repository.dart';

/// 当前运行平台。
///
/// 抽成 provider 的理由与 `MediaSaver` / `CallKeepAlive` 一样：这条链按平台分流
/// （安卓下载安装、iOS 丢浏览器），而 widget 测试里的 `defaultTargetPlatform` 是
/// **宿主机**（Windows/Linux 上跑就是 windows/linux），不好钉住；测试里直接
/// override 这一个 provider 就能把两条路都验到。
final targetPlatformProvider = Provider<TargetPlatform>(
  (ref) => defaultTargetPlatform,
);

/// 检查更新（S7.2；2026-10-08 换成读静态清单）。
///
/// 两个入口：
/// * **启动时**（老端在 `App.vue` 里调 `appUpdate()`）：`isPrompt: false`
///   ——没有新版本时一声不吭，有新版本才弹窗；
/// * **「我的 → 检查更新」**：`isPrompt: true`——没有新版本要提示「暂无新版本」。
///
/// 声明：
/// * **安卓**：弹窗确认（强制更新那颗不给「暂不升级」）→ 下载 APK → 交给系统安装器；
/// * **iOS / Windows / macOS**：地址直接交给系统浏览器（App Store 与桌面安装包
///   都不该由应用自己装，老端 iOS 那条也是丢浏览器），所以那三端不弹窗、不下载；
/// * **下载过程可以取消**（强制更新一律不给取消，与老端一致）。
Future<void> runAppUpdate(
  BuildContext context,
  WidgetRef ref, {
  required bool isPrompt,
}) async {
  final i18n = ref.read(appI18nProvider);
  final isAndroid = ref.read(targetPlatformProvider) == TargetPlatform.android;

  AppUpdateInfo? info;
  try {
    info = await ref
        .read(updateRepositoryProvider)
        .check(platform: ref.read(targetPlatformProvider));
  } on Object catch (error) {
    // 检查失败是静默的（网络抖一下不该弹东西）；手动点才提示一句
    debugPrint('[更新] 检查失败：$error');
    if (isPrompt) noticeBus.toast(i18n.t('app.checkFail'));
    return;
  }

  if (info == null) {
    if (isPrompt) noticeBus.toast(i18n.t('app.noNv'));
    return;
  }
  if (!context.mounted) return;

  if (!isAndroid) {
    // iOS / Windows / macOS：地址交给系统浏览器（这三端装不了自己的更新包）
    await ref.read(appInstallerProvider).openUrl(info.url);
    return;
  }

  final confirmed = await showUpdateConfirmDialog(context, i18n, info);
  if (confirmed != true || !context.mounted) return;

  final result = await showUpdateDownloadDialog(context, ref, i18n, info);
  switch (result) {
    case UpdateRunResult.installed:
      // 注：老端这里弹的是「应用资源更新完成！」—— 那是 `.wgt` 资源包（换完就生效）
      // 才成立的说法；APK 只是交给了系统安装器，用户可能直接在安装界面按了取消。
      if (!info.force) noticeBus.toast(i18n.t('app.installHanded'));
    case UpdateRunResult.cancelled:
      noticeBus.toast(i18n.t('app.cancelDown'));
    case UpdateRunResult.downloadFailed:
      noticeBus.toast(i18n.t('app.downloadFail'));
    case UpdateRunResult.installFailed:
      noticeBus.toast(i18n.t('app.installFail'));
  }
}

/// 有新版本时那个弹窗（老端自己画的那个 `popupView`）。
///
/// 强制更新：只有一颗「立即升级」，遮罩点不掉、返回键也关不掉；
/// 其余：两颗按钮（暂不升级 / 立即升级）。
Future<bool?> showUpdateConfirmDialog(
  BuildContext context,
  AppI18n i18n,
  AppUpdateInfo info,
) => showDialog<bool>(
  context: context,
  barrierDismissible: !info.force,
  builder: (dialogContext) => PopScope(
    canPop: !info.force,
    // 全站统一的微信白框：正文居中，更新日志跟在后头
    child: WeChatDialogBox(
      actions: <WeChatDialogAction>[
        if (!info.force)
          WeChatDialogAction(label: i18n.t('app.waitInstall'), value: false),
        WeChatDialogAction(
          label: i18n.t('app.nowInstall'),
          value: true,
          tone: WeChatDialogTone.primary,
        ),
      ],
      body: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(56),
          vertical: context.rpx(62),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: context.rpx(600)),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '${i18n.t('app.newVersion')}：${info.version}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: context.rpx(33),
                    height: 1.4,
                    color: AppColors.text000,
                  ),
                ),
                SizedBox(height: context.rpx(24)),
                for (final line in appUpdateLines(info.note))
                  Padding(
                    padding: EdgeInsets.only(bottom: context.rpx(8)),
                    child: Text(
                      line,
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        color: AppColors.text666,
                      ),
                    ),
                  ),
                if (info.force)
                  Text(
                    i18n.t('app.forceTip'),
                    style: TextStyle(
                      fontSize: context.rpx(26),
                      color: AppColors.red,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

/// 下载 + 交给系统安装器（带进度、可取消），返回最后是什么结果。
Future<UpdateRunResult> showUpdateDownloadDialog(
  BuildContext context,
  WidgetRef ref,
  AppI18n i18n,
  AppUpdateInfo info,
) async =>
    await showDialog<UpdateRunResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _UpdateDownloadDialog(
        info: info,
        i18n: i18n,
        installer: ref.read(appInstallerProvider),
      ),
    ) ??
    UpdateRunResult.cancelled;

/// 下载弹窗的结局
enum UpdateRunResult { installed, downloadFailed, installFailed, cancelled }

/// 下载 + 安装那一步（老端那个「升级APP」进度弹窗）
class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({
    required this.info,
    required this.i18n,
    required this.installer,
  });

  final AppUpdateInfo info;
  final AppI18n i18n;
  final AppInstaller installer;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  final CancelToken _cancelToken = CancelToken();

  double? _progress;
  _DownloadPhase _phase = _DownloadPhase.downloading;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    // 弹窗被关掉（用户取消 / 页面被销毁）就中断下载，别在后台偷偷下完
    if (!_phase.isFinished) _cancelToken.cancel('弹窗关闭');
    super.dispose();
  }

  Future<void> _run() async {
    String path;
    try {
      path = await widget.installer.download(
        widget.info.url,
        fileName: fileNameOf(widget.info.url),
        onProgress: (value) {
          if (!mounted) return;
          setState(() => _progress = value);
        },
        // 强制更新不给取消（老端也是一颗取消按钮都不给）
        cancelToken: widget.info.force ? null : _cancelToken,
      );
    } on DioException catch (error) {
      if (!mounted) return;
      if (CancelToken.isCancel(error)) {
        _finish(UpdateRunResult.cancelled);
        return;
      }
      debugPrint('[更新] 下载失败：$error');
      setState(() => _phase = _DownloadPhase.downloadFailed);
      return;
    } on Object catch (error) {
      if (!mounted) return;
      debugPrint('[更新] 下载失败：$error');
      setState(() => _phase = _DownloadPhase.downloadFailed);
      return;
    }

    if (!mounted) return;
    setState(() {
      _progress = 1;
      _phase = _DownloadPhase.installing;
    });

    final installed = await widget.installer.installPackage(path);
    if (!mounted) return;
    if (!installed) {
      setState(() => _phase = _DownloadPhase.installFailed);
      return;
    }
    _finish(UpdateRunResult.installed);
  }

  void _finish(UpdateRunResult result) {
    _phase = _DownloadPhase.finished;
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  /// 失败态那个「确定」要带着**失败的原因**关掉弹窗
  UpdateRunResult get _failureResult => _phase == _DownloadPhase.installFailed
      ? UpdateRunResult.installFailed
      : UpdateRunResult.downloadFailed;

  @override
  Widget build(BuildContext context) {
    final i18n = widget.i18n;
    final failed = _phase.isFailed;
    return PopScope(
      // 下载中不许用返回键溜掉（要中断请点「取消下载」）
      canPop: failed,
      // 同样走全站那套白框（框里是进度条，所以正文不居中）
      child: WeChatDialogBox(
        actions: <WeChatDialogAction>[
          // 老端这里是「取消 / 后台下载」两颗按钮；本客户端只做「取消」——
          // 下载继续在后台跑要能撑过弹窗被关、App 被切走，那是另一条链（见 S7.2 备注）。
          if (!widget.info.force && _phase == _DownloadPhase.downloading)
            WeChatDialogAction(
              label: i18n.t('common.cancel'),
              // 只中断下载、**不关框**：等下载那边真的停了，
              // 由 `_finish` 带着 `cancelled` 关
              onTap: () => _cancelToken.cancel('用户取消下载'),
            ),
          if (failed)
            WeChatDialogAction(
              label: i18n.t('common.ok'),
              value: _failureResult,
              tone: WeChatDialogTone.primary,
            ),
        ],
        body: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.rpx(56),
            vertical: context.rpx(62),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                i18n.t('app.updateApp'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.rpx(33),
                  height: 1.4,
                  color: AppColors.text000,
                ),
              ),
              SizedBox(height: context.rpx(20)),
              // 老端那个弹窗的正文（`contentText` 默认就是这句）
              Text(
                failed ? _label(i18n) : i18n.t('app.waitInstallNow'),
                style: TextStyle(
                  fontSize: context.rpx(26),
                  color: failed ? AppColors.red : AppColors.text333,
                ),
              ),
              if (!failed) ...<Widget>[
                SizedBox(height: context.rpx(8)),
                Text(
                  _label(i18n),
                  style: TextStyle(
                    fontSize: context.rpx(24),
                    color: AppColors.text666,
                  ),
                ),
              ],
              SizedBox(height: context.rpx(20)),
              LinearProgressIndicator(value: _progress, color: AppColors.green),
              SizedBox(height: context.rpx(16)),
              Text(
                i18n.t('app.installHint'),
                style: TextStyle(
                  fontSize: context.rpx(22),
                  color: AppColors.text999,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _label(AppI18n i18n) {
    switch (_phase) {
      case _DownloadPhase.downloading:
        final value = _progress;
        if (value == null) return i18n.t('app.readyDown');
        return '${i18n.t('app.downloading')}${(value * 100).round()}%';
      case _DownloadPhase.installing:
        return i18n.t('app.installing');
      case _DownloadPhase.downloadFailed:
        return i18n.t('app.downloadFail');
      case _DownloadPhase.installFailed:
        return i18n.t('app.installFail');
      case _DownloadPhase.finished:
        return i18n.t('app.updated');
    }
  }
}

/// 下载弹窗的状态（用枚举而不是几个 bool，免得出现「又失败又安装中」这种组合）
enum _DownloadPhase {
  downloading,
  installing,
  downloadFailed,
  installFailed,
  finished;

  bool get isFailed =>
      this == _DownloadPhase.downloadFailed ||
      this == _DownloadPhase.installFailed;

  bool get isFinished => isFailed || this == _DownloadPhase.finished;
}

/// 下载地址里的文件名（拼本地路径用；拿不到就给个默认名）
String fileNameOf(String url) {
  final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
  final last = segments.isEmpty ? '' : segments.last;
  return last.isEmpty ? 'update.apk' : last;
}

/// 启动时自动检查更新只跑一次（老端每次 `onShow` 都调，太吵；
/// 这里一个进程只查一次，切前后台不会反复弹窗）。
bool _startupCheckDone = false;

/// 启动时的那次检查（进主界面时调一次，没新版本一声不吭）
Future<void> runStartupUpdateCheck(BuildContext context, WidgetRef ref) async {
  if (_startupCheckDone) return;
  _startupCheckDone = true;
  await runAppUpdate(context, ref, isPrompt: false);
}
