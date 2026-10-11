import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/chat/message_media.dart';

/// 名片消息（老端 `components/messageType/im-contact.vue`）。
///
/// 固定宽 360rpx：上一行是头像 + 昵称，一条分隔线，下面写「个人名片」。
/// 点一下进对方资料页（老端 `openContact`，属于 M5）。
class ContactBubble extends StatelessWidget {
  const ContactBubble({
    super.key,
    required this.payload,
    required this.translate,
    this.onTap,
  });

  final ContactPayload payload;
  final String Function(String key) translate;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final avatarSize = context.rpx(80);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: context.rpx(360),
        padding: EdgeInsets.fromLTRB(
          context.rpx(20),
          context.rpx(20),
          context.rpx(20),
          context.rpx(10),
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFE7F0F3),
          borderRadius: BorderRadius.circular(context.rpx(8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(context.rpx(10)),
                  child: SizedBox(
                    width: avatarSize,
                    height: avatarSize,
                    child: payload.avatar.isEmpty
                        ? const ColoredBox(color: AppColors.gray)
                        : Image.network(
                            payload.avatar,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) =>
                                const ColoredBox(color: AppColors.gray),
                          ),
                  ),
                ),
                SizedBox(width: context.rpx(20)),
                Flexible(
                  child: Text(
                    payload.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.rpx(28),
                      color: AppColors.text333,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.rpx(16)),
              child: const Divider(height: 1, color: Color(0xFFD6D6D6)),
            ),
            Text(
              translate('chat.userIDcard'),
              style: TextStyle(
                fontSize: context.rpx(20),
                color: AppColors.text666,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
