import 'package:flutter/material.dart';

import '../i18n/app_i18n.dart';
import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import 'wechat_dialog.dart';

/// 单行/多行输入弹窗（老端那些 `showModal({editable: true})` 与 `uni-popup-dialog mode="input"`）。
///
/// 刻意做成 `StatefulWidget`：`TextEditingController` 必须由**它自己的 State**
/// 拥有并在 `dispose` 里释放——如果在 `showDialog` 返回后立刻 dispose，
/// 弹窗的退场动画还在用它，会报
/// `A TextEditingController was used after being disposed`（S5.2 写完时踩过）。
///
/// [enabled] 为 false 时输入框只读（群公告那种「非管理员点开只是看看」）；
/// 这时一般连 [showOk] 也一起关掉 —— 老端只把输入框 `disabled`、"保存"按钮还画着，
/// 点了会发一个注定被服务端拒的请求，新端在只读时干脆不画那颗按钮。
Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  String initial = '',
  String? cancelLabel,
  String? okLabel,
  int maxLines = 1,
  bool enabled = true,
  bool showOk = true,
}) {
  final i18n = AppI18n.instance;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _TextPromptDialog(
      title: title,
      initial: initial,
      cancelLabel: cancelLabel ?? i18n.t('common.cancel'),
      okLabel: okLabel ?? i18n.t('common.ok'),
      maxLines: maxLines,
      enabled: enabled,
      showOk: showOk,
    ),
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.initial,
    required this.cancelLabel,
    required this.okLabel,
    required this.maxLines,
    required this.enabled,
    required this.showOk,
  });

  final String title;
  final String initial;
  final String cancelLabel;
  final String okLabel;
  final int maxLines;
  final bool enabled;

  /// 是否画右下角那颗确认（只读时不画）
  final bool showOk;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // 框走全站统一的微信白框（`wechat_dialog.dart`）：标题在上、输入框在下
  @override
  Widget build(BuildContext context) => WeChatDialogBox(
    actions: <WeChatDialogAction>[
      WeChatDialogAction(
        label: widget.cancelLabel,
        onTap: () => Navigator.of(context).pop(),
      ),
      if (widget.showOk)
        WeChatDialogAction(
          label: widget.okLabel,
          tone: WeChatDialogTone.primary,
          onTap: () => Navigator.of(context).pop(_controller.text.trim()),
        ),
    ],
    body: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(56),
        vertical: context.rpx(62),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            widget.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.rpx(33),
              height: 1.4,
              color: AppColors.text000,
            ),
          ),
          SizedBox(height: context.rpx(24)),
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: widget.enabled,
            maxLines: widget.maxLines,
            style: TextStyle(fontSize: context.rpx(28)),
            decoration: const InputDecoration(isDense: true),
            onSubmitted: widget.maxLines == 1
                ? (value) => Navigator.of(context).pop(value.trim())
                : null,
          ),
        ],
      ),
    ),
  );
}
