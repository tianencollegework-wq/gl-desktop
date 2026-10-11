import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/chat/message_media.dart';
import '../message_bubble.dart' show bubbleColorOf;

/// 音视频通话消息（老端 `components/messageType/im-webrtc.vue`）。
///
/// 服务端给的 `content` 就是文案（“通话时长 00:35” / “已取消”），
/// 老端画成一条**灰底**圆角行；微信那边它和文字消息一样是**绿/白气泡**
/// （用户 2026-09-20 的截图）：自己的绿底、对方的白底，图标在靠外的那一侧
/// （自己的文案在前、话筒在后；对方的反过来），外带一根小尾巴（见 `message_bubble.dart`）。
///
/// 点一下回拨（老端 `calling(item.extends.type)`）——**M6 才接**，
/// 那之前卡片只负责显示。
class CallBubble extends StatelessWidget {
  const CallBubble({
    super.key,
    required this.payload,
    required this.mine,
    this.onTap,
  });

  final CallPayload payload;

  /// 是不是自己发的（决定底色与图标方向）
  final bool mine;

  final VoidCallback? onTap;

  /// 气泡高度（和语音那条一样，微信里所有「一条行」的气泡都一样高）
  static const double heightRpx = 88;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      payload.isVideo ? Icons.videocam_outlined : Icons.call,
      size: context.rpx(34),
      color: AppColors.text111,
    );
    final text = Text(
      payload.text,
      style: TextStyle(fontSize: context.rpx(26), color: AppColors.text111),
    );

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: context.rpx(heightRpx),
        padding: EdgeInsets.symmetric(horizontal: context.rpx(24)),
        decoration: BoxDecoration(
          // 微信：通话记录也是一颗普通气泡（自己的绿、对方的白）
          color: bubbleColorOf(mine),
          borderRadius: BorderRadius.circular(context.rpx(20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (mine) ...<Widget>[
              Flexible(child: text),
              SizedBox(width: context.rpx(12)),
              icon,
            ] else ...<Widget>[
              icon,
              SizedBox(width: context.rpx(12)),
              Flexible(child: text),
            ],
          ],
        ),
      ),
    );
  }
}
