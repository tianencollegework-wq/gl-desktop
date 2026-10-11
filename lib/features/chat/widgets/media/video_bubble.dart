import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/util/media_format.dart';
import '../../../../domain/chat/message_media.dart';
import 'media_image.dart';

/// 视频消息（老端 `components/messageType/im-video.vue`）。
///
/// 老端显示的是**封面图 + 半透明遮罩 + 播放图标 + 右下角时长**，
/// 点一下才进播放页（S4.6）。封面尺寸同样是 `imageCoverStyle` 那套。
class VideoBubble extends StatelessWidget {
  const VideoBubble({super.key, required this.payload, this.onTap});

  final VideoPayload payload;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (payload.isEmpty) return const BrokenMediaBox(label: 'video');

    final maxWidth = MediaQuery.sizeOf(context).width - 260;
    final size = _box();
    final scale = size.width > maxWidth ? maxWidth / size.width : 1.0;
    final width = size.width * scale;
    final height = size.height * scale;

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (payload.poster.isEmpty)
                const ColoredBox(color: AppColors.gray)
              else
                MediaImage(source: payload.poster, errorLabel: 'video'),
              // 老端的 `relative-shadow`：压暗一点，白色图标才看得清
              const ColoredBox(color: Color(0x3D838383)),
              Center(
                child: Icon(
                  Icons.play_circle_outline,
                  size: context.rpx(80),
                  color: AppColors.white,
                ),
              ),
              if (payload.duration > 0)
                Positioned(
                  right: 5,
                  bottom: 5,
                  child: Text(
                    durationText(payload.duration),
                    style: TextStyle(
                      fontSize: context.rpx(20),
                      color: AppColors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  ({double width, double height}) _box() {
    if (payload.hasSize) return mediaBoxSize(payload.width, payload.height);
    // 老端没给尺寸时用同一个函数算（会得到 200×NaN），这里给个稳妥的 16:9
    return (width: 200, height: math.max(120, 200 * 9 / 16));
  }
}
