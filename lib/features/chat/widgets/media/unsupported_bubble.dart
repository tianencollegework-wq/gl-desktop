import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/chat/message_media.dart';

/// 未知类型（老端 `components/messageType/im-item.vue`）。
///
/// `diy` 类型显示「自定义」，其余一律「暂不支持的消息类型」。
/// 老端这里什么都点不了，新端保持一致——但**不会像老端那样把消息整条吞掉**
/// （老端这个组件在 `chat.vue` 的 `v-else` 分支里，卡片是白底不透明的，
/// 自己的消息会变成白底黑字，看不出是自己发的）。
class UnsupportedBubble extends StatelessWidget {
  const UnsupportedBubble({
    super.key,
    required this.type,
    required this.mine,
    required this.translate,
  });

  final String type;
  final bool mine;
  final String Function(String key) translate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(18),
        vertical: context.rpx(10),
      ),
      decoration: BoxDecoration(
        color: mine ? AppColors.brand : AppColors.white,
        borderRadius: BorderRadius.circular(context.rpx(8)),
      ),
      child: Text(
        translate(unsupportedKeyOf(type)),
        style: TextStyle(
          fontSize: context.rpx(26),
          color: mine ? AppColors.white : AppColors.text666,
        ),
      ),
    );
  }
}
