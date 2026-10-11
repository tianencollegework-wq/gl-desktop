import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 通讯录里的头像（老端那个 `cu-avatar` + 右下角在线小绿点）。
///
/// 与消息页的头像同一个口径：圆/方角由「圆形头像」设置决定，
/// 加载失败画灰底小人，别让整行报错。
class ContactAvatar extends StatelessWidget {
  const ContactAvatar({
    super.key,
    required this.url,
    required this.circle,
    this.showOnline = false,
    this.sizeRpx = 90,
    this.sizePx,
    this.radiusRpx,
    this.fallbackIcon = Icons.person,
  });

  final String url;
  final bool circle;
  final bool showOnline;
  final double sizeRpx;

  /// 固定逻辑像素（桌面版通话界面那套：不受窗口宽度影响）。
  /// 给了它就不看 [sizeRpx]（见 `call_desktop_page.dart` 的文件头）。
  final double? sizePx;

  /// 方角头像的圆角（不传就是全局默认的 10rpx）。
  /// 通话页要微信那种「大圆角方形头像」，与其在通话页另写一个头像，
  /// 不如把圆角做成参数。
  final double? radiusRpx;

  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final size = sizePx ?? context.rpx(sizeRpx);
    final image = url.isEmpty
        ? _placeholder(context, size)
        : Image.network(
            url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) =>
                _placeholder(context, size),
          );

    return SizedBox(
      width: size + context.rpx(6),
      height: size + context.rpx(6),
      child: Stack(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(
              circle ? size : context.rpx(radiusRpx ?? 10),
            ),
            child: image,
          ),
          if (showOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: context.rpx(20),
                height: context.rpx(20),
                decoration: BoxDecoration(
                  color: AppColors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.white, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _placeholder(BuildContext context, double size) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    color: AppColors.gray,
    child: Icon(fallbackIcon, size: size * 0.6, color: AppColors.text999),
  );
}
