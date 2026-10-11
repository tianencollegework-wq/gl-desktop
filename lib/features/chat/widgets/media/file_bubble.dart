import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/util/media_format.dart';
import '../../../../domain/chat/message_media.dart';

/// 文件消息（老端 `components/messageType/im-file.vue`）。
///
/// 老端左侧那个图标是 `<image :src="item.extUrl">`，而 `extUrl` 在整个老项目里
/// **只被读、从来没被写过**（服务端也没这个字段），所以老端上文件图标一直是裂图。
/// 新端改成按后缀画一个彩色小方块（PDF/DOCX/ZIP…），不依赖任何额外字段。
class FileBubble extends StatelessWidget {
  const FileBubble({
    super.key,
    required this.payload,
    required this.translate,
    this.onTap,
  });

  final FilePayload payload;

  /// 取词（跟着 App 当前语言走；2026-09-25 排查时补的：以前这里写死「文件」，
  /// 切到 English 之后附件名还会是中文）
  final String Function(String key) translate;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final title = payload.name.isEmpty
        ? translate('common.file')
        : payload.name;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: context.rpx(420),
        padding: EdgeInsets.all(context.rpx(20)),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(context.rpx(10)),
        ),
        child: Row(
          children: <Widget>[
            _extensionBadge(context),
            SizedBox(width: context.rpx(20)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.rpx(28),
                      color: AppColors.text333,
                    ),
                  ),
                  SizedBox(height: context.rpx(8)),
                  Text(
                    payload.size > 0 ? fileSize(payload.size) : '',
                    style: TextStyle(
                      fontSize: context.rpx(24),
                      color: AppColors.text999,
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

  Widget _extensionBadge(BuildContext context) {
    final extension = payload.extension.isEmpty
        ? '?'
        : payload.extension.toUpperCase();
    final color = _colorOf(payload.extension);
    return Container(
      width: context.rpx(64),
      height: context.rpx(80),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(context.rpx(8)),
      ),
      child: Text(
        extension.length > 4 ? extension.substring(0, 4) : extension,
        style: TextStyle(
          fontSize: context.rpx(20),
          fontWeight: FontWeight.w600,
          color: AppColors.white,
        ),
      ),
    );
  }

  /// 按后缀给个颜色，扫一眼就知道是什么文件
  Color _colorOf(String extension) {
    switch (extension) {
      case 'pdf':
        return const Color(0xFFE04F4F);
      case 'doc':
      case 'docx':
        return const Color(0xFF2B6CB0);
      case 'xls':
      case 'xlsx':
        return const Color(0xFF2F855A);
      case 'ppt':
      case 'pptx':
        return const Color(0xFFDD6B20);
      case 'zip':
      case 'rar':
      case '7z':
        return const Color(0xFF805AD5);
      case 'mp3':
      case 'wav':
      case 'm4a':
        return const Color(0xFFB7791F);
      case 'mp4':
      case 'mov':
      case 'avi':
        return const Color(0xFF319795);
      default:
        return AppColors.text666;
    }
  }
}
