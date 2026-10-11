import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 封面图（歌曲 / 专辑 / 歌单 / 歌手头像通用）。
///
/// 灵听的图都在 `resource.lingtingmusic.com` / COS 上，**一律直接 `Image.network`**：
/// 项目里没有图片缓存插件，为这一个频道引一个不值得。代价是每次进页面会重新下载，
/// 所以这里只做三件事让它别难看：
/// 1. 加载中与失败都是同一块**灰底 + 音符**（不闪白、不留红叉）；
/// 2. 可选择圆角 / 圆形；
/// 3. [shadow] 给封面加一层淡淡的投影 —— 歌单、专辑墙那种排版有这个才立得住。
class LingtingCover extends StatelessWidget {
  const LingtingCover({
    super.key,
    required this.url,
    this.sizeRpx = 0,
    this.radiusRpx = 12,
    this.circular = false,
    this.fit = BoxFit.cover,
    this.shadow = false,
  });

  final String url;

  /// 0 = 由父级决定尺寸（铺满）
  final double sizeRpx;

  final double radiusRpx;
  final bool circular;
  final BoxFit fit;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final size = sizeRpx <= 0 ? null : context.rpx(sizeRpx);
    final radius = BorderRadius.circular(
      circular ? (size == null ? 0 : size / 2) : context.rpx(radiusRpx),
    );
    final image = ClipRRect(borderRadius: radius, child: _image(context, size));
    final decorated = circular
        ? ClipOval(child: image)
        : DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: shadow
                  ? const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x1A000000),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: image,
          );
    return SizedBox(width: size, height: size, child: decorated);
  }

  Widget _image(BuildContext context, double? size) {
    if (url.isEmpty) return _placeholder(context, size);
    return Image.network(
      url,
      fit: fit,
      width: size,
      height: size,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : _placeholder(context, size),
      errorBuilder: (context, error, stack) => _placeholder(context, size),
    );
  }

  Widget _placeholder(BuildContext context, double? size) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[Color(0xFFE9E9E9), Color(0xFFD9D9D9)],
      ),
    ),
    alignment: Alignment.center,
    child: Icon(
      Icons.music_note,
      size: (size ?? context.rpx(80)) * 0.42,
      color: AppColors.chevron,
    ),
  );
}
