import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 微信式提示（toast）：**屏幕正中一块深色圆角方盒 + 白字**，自己淡入淡出，
/// 挂在浮层上 —— 不拦点击、不进导航栈、换页也不跟着消失。
///
/// 为什么不用 `SnackBar`（S7.6）：Material 那个提示条贴在屏幕**底部**（还是
/// Material 自己的圆角），而微信全站只有一个提示位置 —— 正中间。本站原本一边用
/// `SnackBar` 弹错误、一边用 `showSuccessCheck` 在正中间弹「提交成功」，
/// 同一个 App 两种提示位置，看起来就是没做完。这一层把它统一成微信那样。
///
/// 三个微信才有的行为：
/// 1. **同一句还在屏幕上时不弹第二遍** —— 这顺手治好了「接口层弹一次、页面又弹/// 一次」那种重复提示（见 `NoticeHandler` 与 S7.6）；
/// 2. 后来的提示**直接顶掉**前一条（微信不排队等前面那条播完）；
/// 3. 提示是**浮层**：不挡点击、不动导航栈，所以换页之后它还稳稳停在原处。
///
/// [overlayOf] 由调用方给（生产环境是根 Navigator 的那个 Overlay）：这一层不
/// 自己去摸 `BuildContext`，也就没有「网络层要拿 UI 的 context」那种倒挂。
class WeChatToastLayer {
  WeChatToastLayer({required this.overlayOf});

  final OverlayState? Function() overlayOf;

  /// 普通提示显示多久（微信差不多两秒）
  static const Duration defaultDuration = Duration(milliseconds: 1800);

  /// 带按钮的提示留久一点（两秒来不及点「去授权」）
  static const Duration actionDuration = Duration(seconds: 6);

  /// 淡入 / 淡出各占多久
  static const Duration fadeDuration = Duration(milliseconds: 140);

  OverlayEntry? _entry;
  Timer? _timer;

  /// 当前那条提示的 key（淡出时要找它的 state）
  GlobalKey<_ToastViewState>? _viewKey;

  /// 屏幕上那一句（没有就是 null）—— 用来吞掉同一句的重复提示
  String? _showing;

  /// 屏幕上那一句（测试与调用方可读）
  String? get showingMessage => _showing;

  /// 弹一句提示。
  ///
  /// [actionLabel] 给的是提示底下那颗小按钮（比如「需要麦克风权限…」旁边那颗
  /// 「去授权」）—— 微信的提示没有按钮，这一条是本客户端自己要的。
  void show(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    // 同一句还在屏幕上：别再弹一遍（重复提示就是这么被吞掉的）
    if (_showing == message) return;

    final overlay = overlayOf();
    if (overlay == null) return; // 界面还没起来（启动极早期），丢了就丢了

    // 后来的顶掉前一条（微信不排队）
    _removeEntry();

    _showing = message;
    final key = GlobalKey<_ToastViewState>();
    _viewKey = key;
    final entry = OverlayEntry(
      builder: (_) => _ToastView(
        key: key,
        message: message,
        actionLabel: actionLabel,
        onAction: onAction == null
            ? null
            : () {
                // 点了按钮这条提示就算交代完了（微信那种提示没有按钮，规矩由我们定）
                _removeEntry();
                onAction();
              },
      ),
    );
    _entry = entry;
    overlay.insert(entry);

    final visible =
        duration ??
        (actionLabel == null && onAction == null
            ? defaultDuration
            : actionDuration);
    _timer = Timer(visible, _fadeOut);
  }

  /// 马上收掉当前这条（不淡出）
  void hide() => _removeEntry();

  void dispose() => _removeEntry();

  void _fadeOut() {
    _timer?.cancel();
    _timer = null;
    final state = _viewKey?.currentState;
    if (state == null) {
      _removeEntry();
      return;
    }
    // 淡出最多等 `fadeDuration + 200ms`：控制器要是被提前拆了（整棵树被换掉），
    // `reverse()` 那个 future 不会自己结束，兜底把浮层收掉，免得留一块残影在那儿
    unawaited(
      state
          .fadeOut()
          .timeout(
            fadeDuration + const Duration(milliseconds: 200),
            onTimeout: () {},
          )
          .whenComplete(_removeEntry),
    );
  }

  void _removeEntry() {
    _timer?.cancel();
    _timer = null;
    final entry = _entry;
    _entry = null;
    _viewKey = null;
    _showing = null;
    // 插过就一定能 remove（插都没插进去的话 `_entry` 本来就是 null）
    entry?.remove();
  }
}

/// 提示本体：深色圆角盒子 + 白字（带按钮时下面再挂一颗白的文字按钮）
class _ToastView extends StatefulWidget {
  const _ToastView({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: WeChatToastLayer.fadeDuration,
  )..forward();

  late final Animation<double> _scale = Tween<double>(
    begin: 0.92,
    end: 1,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  /// 淡出（由 [WeChatToastLayer] 到点了叫一下，淡完那一层才会把浮层拆掉）
  Future<void> fadeOut() async {
    if (!mounted) return;
    _controller.stop();
    await _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasAction = widget.actionLabel != null && widget.onAction != null;
    return Positioned.fill(
      // ⚠️ 这一层 `Material` 不是装饰，是**必须**的：浮层挂在 Navigator 的 Overlay 上，
      // 祖先里没有任何 `Material`，而 `MaterialApp` 给这种「不入 Material 的 Text」
      // 准备的是一份调试样式（红字 + 两条黄色下划线，见 `material/app.dart` 的
      // `_errorTextStyle`）—— 用户 2026-09-30 看到的「很多提示都有两条黄色下划线」
      // 就是它。包一层透明 Material 之后，里面所有 Text 才会拿到正常字号/颜色。
      child: Material(
        type: MaterialType.transparency,
        // 空白处不吃点击：外面那一圈是透明的，用户该点的按钮照样点得到
        child: Center(
          child: FadeTransition(
            opacity: _controller,
            child: ScaleTransition(
              scale: _scale,
              child: ConstrainedBox(
                // 微信的提示盒子宽度跟着文字走，长文案换行、最多占屏宽六成
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.6,
                ),
                child: DecoratedBox(
                  key: const ValueKey<String>('wechatToast'),
                  decoration: BoxDecoration(
                    color: AppColors.toastBackground,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: hasAction ? 22 : 18,
                      vertical: 16,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          widget.message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.toastText,
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            height: 1.35,
                          ),
                        ),
                        if (hasAction) ...<Widget>[
                          const SizedBox(height: 4),
                          TextButton(
                            onPressed: widget.onAction,
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.toastText,
                              minimumSize: const Size(0, 32),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              widget.actionLabel!,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
