import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/call_keep_alive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/desktop_overlay.dart';

/// 前台服务自检（**只有 debug 构建能看到**，入口在「设置」里）。
///
/// 为什么要有它：通话保活这件事只有真机能验，而走一遍真通话（两台设备、两个账号）
/// 的重成本不该花在「服务到底起没起」这种问题上。这里点一下「起服务」，通知栏就该
/// 立刻出现一条「与 自检 语音通话中」；点「停服务」就该立刻消失。
///
/// 顺带一个合规细节：Android 14+ 要求 mic/camera 类型的前台服务**由前台 UI 触发**，
/// 点按钮正好就是这种场景（所以自检不会因为系统限制而失败）。
///
/// 命令行一起验（插着 USB）：
/// ```
/// adb shell dumpsys activity services cc.gracelink.im   # 看服务在不在
/// adb shell dumpsys notification --noredact | grep -i gracelink # 看通知在不在
/// ```
Future<void> showCallKeepAliveSelfCheck(BuildContext context) =>
    showAppSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => const _CallKeepAliveSelfCheck(),
    );

class _CallKeepAliveSelfCheck extends ConsumerStatefulWidget {
  const _CallKeepAliveSelfCheck();

  @override
  ConsumerState<_CallKeepAliveSelfCheck> createState() =>
      _CallKeepAliveSelfCheckState();
}

class _CallKeepAliveSelfCheckState
    extends ConsumerState<_CallKeepAliveSelfCheck> {
  /// 每一句都留在屏上（真机排查时一眼看到整条链路）
  final List<String> _log = <String>[];

  CallKeepAlive get _keepAlive => ref.read(callKeepAliveProvider);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '前台服务自检',
              style: TextStyle(
                fontSize: context.rpx(32),
                fontWeight: FontWeight.bold,
                color: AppColors.text333,
              ),
            ),
            SizedBox(height: context.rpx(8)),
            Text(
              '支持：${_keepAlive.supported ? '是（安卓）' : '否（这个平台没有前台服务）'}\n'
              '起服务后通知栏应出现「与 自检 语音/视频通话中」；停服务后立刻消失。',
              style: TextStyle(
                fontSize: context.rpx(24),
                height: 1.4,
                color: AppColors.text999,
              ),
            ),
            SizedBox(height: context.rpx(20)),
            Wrap(
              spacing: context.rpx(16),
              runSpacing: context.rpx(16),
              children: <Widget>[
                _button('起服务（语音）', () => _start(video: false)),
                _button('起服务（视频）', () => _start(video: true)),
                _button('停服务', _stop),
                _button('查状态', _status),
                _button('查通知权限', () => _permission(request: false)),
                _button('申请通知权限', () => _permission(request: true)),
              ],
            ),
            if (_log.isNotEmpty) ...<Widget>[
              SizedBox(height: context.rpx(20)),
              Container(
                padding: EdgeInsets.all(context.rpx(20)),
                decoration: BoxDecoration(
                  color: AppColors.page,
                  borderRadius: BorderRadius.circular(context.rpx(12)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final line in _log.reversed.take(12))
                      Text(
                        line,
                        style: TextStyle(
                          fontSize: context.rpx(24),
                          height: 1.4,
                          color: AppColors.text666,
                        ),
                      ),
                  ],
                ),
              ),
            ],
            SizedBox(height: context.rpx(20)),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                height: context.rpx(88),
                alignment: Alignment.center,
                child: Text(
                  '关闭',
                  style: TextStyle(
                    fontSize: context.rpx(30),
                    color: AppColors.text666,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _button(String label, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(24),
        vertical: context.rpx(16),
      ),
      decoration: BoxDecoration(
        color: AppColors.brand,
        borderRadius: BorderRadius.circular(context.rpx(30)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: context.rpx(26), color: AppColors.white),
      ),
    ),
  );

  Future<void> _start({required bool video}) async {
    final keepAlive = _keepAlive;
    _append('起服务（${video ? '视频' : '语音'}）…');
    try {
      await keepAlive.start(video: video, peerName: '自检');
      _append('start 调用成功');
    } catch (error) {
      // 起不来是最需要看到的信息（Android 14+ 会在这里报「不允许从后台启动」这类错）
      _append('start 抛异常：$error');
    }
    await _status();
  }

  Future<void> _stop() async {
    _append('停服务…');
    try {
      await _keepAlive.stop();
      _append('stop 调用成功');
    } catch (error) {
      _append('stop 抛异常：$error');
    }
    await _status();
  }

  Future<void> _status() async {
    final running = await _keepAlive.isRunning();
    _append('isRunning = $running');
  }

  /// 查/申请通知权限。
  ///
  /// ⚠️ 申请会弹系统框，弹框期间 App 处于后台 —— 那时候起 mic 类型的前台服务
  /// 会被系统拒掉（真机实测过），所以**先申请、后起服务**，别反过来。
  Future<void> _permission({required bool request}) async {
    final before = await _keepAlive.hasNotificationPermission();
    if (!request) {
      _append('通知权限 = $before');
      return;
    }
    final after = await _keepAlive.requestNotificationPermission();
    _append('申请通知权限：调用前 $before → 调用后 $after');
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }
}
