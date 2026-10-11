import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/chat/message_media.dart';

/// 位置消息（老端 `components/messageType/im-location.vue`）。
///
/// 上一行是地点标题（`content`），下一行是详细地址（`extends.address`），
/// 底色统一是 `#E7F0F3`。点一下开地图（老端 `uni.openLocation`，S4.6 接）。
class LocationBubble extends StatelessWidget {
  const LocationBubble({super.key, required this.payload, this.onTap});

  final LocationPayload payload;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(context.rpx(20)),
        decoration: BoxDecoration(
          color: const Color(0xFFE7F0F3),
          borderRadius: BorderRadius.circular(context.rpx(8)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.only(right: context.rpx(10)),
              child: Icon(
                Icons.location_on_outlined,
                size: context.rpx(48),
                color: AppColors.text333,
              ),
            ),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    payload.title,
                    style: TextStyle(
                      fontSize: context.rpx(28),
                      color: AppColors.text333,
                    ),
                  ),
                  if (payload.address.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: context.rpx(10)),
                      child: Text(
                        payload.address,
                        style: TextStyle(
                          fontSize: context.rpx(24),
                          color: AppColors.text999,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
