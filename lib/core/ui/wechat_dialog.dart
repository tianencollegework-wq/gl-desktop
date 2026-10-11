import 'package:flutter/material.dart';

import '../i18n/app_i18n.dart';
import 'desktop_overlay.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

/// **全站唯一一种弹窗**：微信那个白框。
///
/// 以前各页各写一个 `AlertDialog`（Material 那套：左对齐正文、文字按钮、圆角很小），
/// 摆在一起一眼就看得出是「拼的」。现在统一走这里。
///
/// 尺寸/配色全部**从微信截图实采**（1080×2316，1rpx = 1.44px）：
///
/// | 元素 | 微信实测 | 这里 |
/// |---|---|---|
/// | 框宽 | 864px = **600rpx**（左右各留 75rpx） | `rpx(600)` + 左右 `rpx(75)` |
/// | 圆角 | ≈24px | `rpx(17)` |
/// | 正文 | 居中、17dp 近黑、两行总高 113px | `rpx(33)`、`height: 1.4` |
/// | 正文上下留白 | 各 ≈70rpx | `rpx(62)` + 行高自带的 leading |
/// | 分割线 | `#E5E5E5`，0.5px | `AppColors.rowDivider` |
/// | 按钮行高 | 150px = **104rpx**（= 50dp） | `rpx(104)` |
/// | 「取消」 | `#191919` | `AppColors.text000` |
/// | 右边那颗 | **`#576B95`**（微信那支链接蓝，截图里「退出」就是这个值） | `AppColors.wechatLinkBlue` |
/// | 遮罩 | 白底被罩成 118 = 黑 54% | 不传 `barrierColor`（Flutter 默认就是 `black54`） |
///
/// 用法上就是三件套：[showWeChatConfirm]（确认框）、[showWeChatAlert]（只有一个「确定」）、
/// 以及要自定义内容时直接用 [WeChatDialogBox] 拼。
/// 按钮的语气：取消那种就是普通的近黑，确认是微信蓝，破坏性动作是红。
enum WeChatDialogTone { plain, primary, danger }

class WeChatDialogAction {
  const WeChatDialogAction({
    required this.label,
    this.value,
    this.tone = WeChatDialogTone.plain,
    this.onTap,
  });

  /// 按钮文字
  final String label;

  /// 点了之后 `showDialog` 的返回值
  final Object? value;

  final WeChatDialogTone tone;

  /// 有它就**只调它、不关框**（比如「取消下载」：先中断下载，
  /// 等下载那边真的停了再由它自己带着结果关框）
  final VoidCallback? onTap;
}

/// 只有框：白底 + 圆角 + 上半块内容 +（细线）+ 按钮行。
///
/// [body] 自己带内边距（文字用 [WeChatDialogText] 那个现成的）。
class WeChatDialogBox extends StatelessWidget {
  const WeChatDialogBox({super.key, required this.body, required this.actions});

  final Widget body;

  /// 1 个 → 通栏；2 个 → 等分；多了不拦（等分排）。
  /// **空列表 = 没有按钮行**（纯进度框那种，微信也是不给按钮）。
  final List<WeChatDialogAction> actions;

  /// 桌面上先把 `rpx` 的尺度钉回面板那一档（500）：桌面框架在屏上时 `MediaQuery`
  /// 就是真实窗口宽，不钉的话 600rpx 的框会按 1200 算成 960 —— 一个占满屏幕的
  /// 「微信确认框」。窄窗 / 手机 [DesktopOverlayScale] 原样返回。
  ///
  /// **必须是里面的 `Builder` 拿到钉过的 context**：下面那些 `context.rpx(...)`
  /// 全在 `build` 里当场算，外面那个 context 上的 MediaQuery 还没换（写错过一次：
  /// 框宽依旧是 960）。
  @override
  Widget build(BuildContext context) =>
      DesktopOverlayScale(child: Builder(builder: _box));

  Widget _box(BuildContext context) {
    final radius = BorderRadius.circular(context.rpx(17));
    return Dialog(
      // 框自己画，所以把 Material 那层底和阴影都关掉
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: context.rpx(75),
        vertical: context.rpx(80),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Container(
          key: const ValueKey<String>('wechatDialogBox'),
          width: context.rpx(600),
          color: AppColors.white,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              body,
              if (actions.isNotEmpty) ...<Widget>[
                Container(height: 0.5, color: AppColors.rowDivider),
                SizedBox(
                  height: context.rpx(104),
                  child: Row(
                    children: <Widget>[
                      for (var i = 0; i < actions.length; i++) ...<Widget>[
                        if (i != 0)
                          Container(width: 0.5, color: AppColors.rowDivider),
                        Expanded(child: _action(context, actions[i])),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(BuildContext context, WeChatDialogAction action) => InkWell(
    onTap: () {
      final onTap = action.onTap;
      if (onTap != null) {
        onTap();
        return;
      }
      Navigator.of(context).pop(action.value);
    },
    child: Center(
      child: Text(
        action.label,
        style: TextStyle(
          fontSize: context.rpx(32),
          color: switch (action.tone) {
            WeChatDialogTone.plain => AppColors.text000,
            WeChatDialogTone.primary => AppColors.wechatLinkBlue,
            WeChatDialogTone.danger => AppColors.red,
          },
        ),
      ),
    ),
  );
}

/// 一块居中的正文（弹窗那种 17dp、行高 1.4、近黑）
class WeChatDialogText extends StatelessWidget {
  const WeChatDialogText(this.message, {super.key, this.maxHeight});

  final String message;

  /// 长内容（更新日志、扫描结果）限个高，超出滚
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      message,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: context.rpx(33),
        height: 1.4,
        color: AppColors.text000,
      ),
    );
    final padding = EdgeInsets.symmetric(
      horizontal: context.rpx(56),
      vertical: context.rpx(62),
    );
    if (maxHeight == null) return Padding(padding: padding, child: text);
    return Padding(
      padding: padding,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight!),
        child: SingleChildScrollView(child: text),
      ),
    );
  }
}

/// 确认框：左边「取消」右边「确定」，返回 true 表示点了确定。
///
/// [danger] 用于破坏性动作（删除、清空这类），右边那颗会变红。
Future<bool> showWeChatConfirm(
  BuildContext context, {
  required String message,
  String? cancelLabel,
  String? confirmLabel,
  bool danger = false,
}) async {
  final i18n = AppI18n.instance;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => WeChatDialogBox(
      body: WeChatDialogText(message),
      actions: <WeChatDialogAction>[
        WeChatDialogAction(
          label: cancelLabel ?? i18n.t('common.cancel'),
          value: false,
        ),
        WeChatDialogAction(
          label: confirmLabel ?? i18n.t('common.ok'),
          value: true,
          tone: danger ? WeChatDialogTone.danger : WeChatDialogTone.primary,
        ),
      ],
    ),
  );
  return result == true;
}

/// 只有一个「确定」的提示框（扫描到不认识的内容、干完了说一声这种）
Future<void> showWeChatAlert(
  BuildContext context, {
  required String message,
  String? confirmLabel,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => WeChatDialogBox(
    body: WeChatDialogText(message),
    actions: <WeChatDialogAction>[
      WeChatDialogAction(
        label: confirmLabel ?? AppI18n.instance.t('common.ok'),
        value: 'ok',
        tone: WeChatDialogTone.primary,
      ),
    ],
  ),
);
