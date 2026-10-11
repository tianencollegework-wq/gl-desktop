import 'package:flutter/material.dart';

import '../../../../core/theme/app_dimens.dart';
import '../../../../core/util/media_format.dart';
import '../../../../domain/chat/message_media.dart';
import 'media_image.dart';

// 占位组件搬到了 `media_image.dart`（图片与视频封面共用），
// 这里再导出一遍，免得调用方到处改 import。
export 'media_image.dart' show BrokenMediaBox;

/// 图片消息（老端 `components/messageType/im-image.vue`）。
///
/// 尺寸分三档照抄老端：
/// * `extends.fixMode == 1` → 定宽 200（老端 `mode="widthFix"`）
/// * `fixMode == 2` → 定高 240（`heightFix`）
/// * `fixMode == 3` → 按 `extends.width/height` 拉伸（`scaleToFill`）
/// * 没有 fixMode 但有原始宽高 → [mediaBoxSize]（老端 `$util.imageCoverStyle`）
/// * 什么都没有 → 宽 120 等比（老端 `else` 分支）
///
/// 老端唯一没做的防护是**宽度上限**：`fixMode == 3` 且原图很宽时，
/// 图片会顶出气泡、把整行挤歪。这里统一按可用宽度等比缩一下。
class ImageBubble extends StatelessWidget {
  const ImageBubble({super.key, required this.payload, this.onTap});

  final ImagePayload payload;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (payload.isEmpty) return const BrokenMediaBox(label: 'image');

    // 气泡内容区的可用宽度：屏宽减去两侧头像与留白（与聊天页那个上限同口径）
    final maxWidth = MediaQuery.sizeOf(context).width - 260;
    final size = _boxedSize(maxWidth);

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: MediaImage(source: payload.url, fit: size.fit),
        ),
      ),
    );
  }

  ({double? width, double? height, BoxFit fit}) _boxedSize(double maxWidth) {
    if (payload.fixMode == 3 && payload.hasSize) {
      final scale = payload.width > maxWidth ? maxWidth / payload.width : 1.0;
      return (
        width: payload.width * scale,
        height: payload.height * scale,
        fit: BoxFit.fill,
      );
    }
    if (payload.fixMode == 2) {
      return (width: null, height: 240, fit: BoxFit.fitHeight);
    }
    if (payload.fixMode == 1) {
      return (width: 200, height: null, fit: BoxFit.fitWidth);
    }
    if (payload.hasSize) {
      final box = mediaBoxSize(payload.width, payload.height);
      final scale = box.width > maxWidth ? maxWidth / box.width : 1.0;
      return (
        width: box.width * scale,
        height: box.height * scale,
        fit: BoxFit.cover,
      );
    }
    return (width: 120, height: null, fit: BoxFit.fitWidth);
  }
}

/// 动态表情（`type == 'emoji'`）：老端就是一张 300rpx 的正方形图
class StickerBubble extends StatelessWidget {
  const StickerBubble({super.key, required this.url, this.onTap});

  final String url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final size = context.rpx(300);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: MediaImage(
          source: url,
          fit: BoxFit.contain,
          errorLabel: 'emoji',
        ),
      ),
    );
  }
}
