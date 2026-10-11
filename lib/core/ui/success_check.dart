import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 「提交成功 + 一个勾」的过场动画（微信投诉/反馈提交后那种）。
///
/// 一个居中的深色圆角盒子：绿圈里那个勾**从中心弹出来**，停一下再淡出，
/// 全程不需要用户点确认（[showSuccessCheck] 自己关自己）。
///
/// 底色与文字色跟全站那种居中提示共用一套（[AppColors.toastBackground] /
/// [AppColors.toastText]，见 `WeChatToastLayer`）：两种提示在同一个位置、
/// 同一套颜色，才像同一个 App（S7.6）。
///
/// 用法：`await showSuccessCheck(context, message: '提交成功')`
Future<void> showSuccessCheck(BuildContext context, {required String message}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    builder: (dialogContext) => _SuccessCheckDialog(message: message),
  );
}

class _SuccessCheckDialog extends StatefulWidget {
  const _SuccessCheckDialog({required this.message});

  final String message;

  @override
  State<_SuccessCheckDialog> createState() => _SuccessCheckDialogState();
}

class _SuccessCheckDialogState extends State<_SuccessCheckDialog>
    with SingleTickerProviderStateMixin {
  /// 勾弹出来（0→1）、停一会、整体淡出，一共约 1.4 秒
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// 勾的缩放：前 30% 弹出来（`easeOutBack` 带一点回弹）
  late final Animation<double> _check = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.3, curve: Curves.easeOutBack),
  );

  /// 整块卡片：前 15% 淡入、后 25% 淡出
  late final Animation<double> _fade =
      TweenSequence<double>(<TweenSequenceItem<double>>[
        TweenSequenceItem<double>(
          tween: Tween<double>(
            begin: 0,
            end: 1,
          ).chain(CurveTween(curve: Curves.easeOut)),
          weight: 15,
        ),
        TweenSequenceItem<double>(tween: ConstantTween<double>(1), weight: 60),
        TweenSequenceItem<double>(
          tween: Tween<double>(
            begin: 1,
            end: 0,
          ).chain(CurveTween(curve: Curves.easeIn)),
          weight: 25,
        ),
      ]).animate(_controller);

  @override
  void initState() {
    super.initState();
    unawaited(
      _controller.forward().then((_) {
        // 用 `pop` 而**不是** `maybePop`：下面那个 `PopScope(canPop: false)`
        // 会把 `maybePop` 拦下来（它是给系统返回键用的），弹层就自己关不掉了
        if (mounted) Navigator.of(context).pop();
      }),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: Center(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Opacity(
          opacity: _fade.value.clamp(0, 1),
          child: Container(
            width: 150,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            decoration: BoxDecoration(
              color: AppColors.toastBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 44,
                  height: 44,
                  child: Transform.scale(
                    scale: _check.value,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.wechatGreen,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check,
                        size: 28,
                        color: AppColors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.toastText,
                    fontSize: 14,
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
