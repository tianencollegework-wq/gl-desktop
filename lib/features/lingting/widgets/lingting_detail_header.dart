import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import 'lingting_cover.dart';

/// 歌单 / 歌手 / 专辑详情页顶部那块（封面 + 标题 + 说明 + 「播放全部」）。
///
/// 三页长得几乎一样，所以抽出来共用；差异用 [circularCover]（歌手是圆头像）
/// 和 [background]（歌手有背景图）两个开关表达。
class LingtingDetailHeader extends StatelessWidget {
  const LingtingDetailHeader({
    super.key,
    required this.cover,
    required this.title,
    this.subtitle = '',
    this.meta = '',
    this.circularCover = false,
    this.background = '',
    this.playAllLabel,
    this.onPlayAll,
    this.trailing,
  });

  final String cover;
  final String title;
  final String subtitle;

  /// 第三行小字（「20 首 · 播放 572 次」这种）
  final String meta;

  final bool circularCover;

  /// 歌手页的背景图（空则用品牌绿渐变兜底）
  final String background;

  final String? playAllLabel;
  final VoidCallback? onPlayAll;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        if (background.isNotEmpty)
          Positioned.fill(child: LingtingCover(url: background)),
        if (background.isNotEmpty)
          Positioned.fill(child: Container(color: const Color(0x99000000))),
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.rpx(30),
            context.rpx(30),
            context.rpx(30),
            context.rpx(20),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              LingtingCover(
                url: cover,
                sizeRpx: 220,
                radiusRpx: 16,
                circular: circularCover,
                // 衬在照片背景上时不要投影（会脏），白底上给一点立体感
                shadow: background.isEmpty,
              ),
              SizedBox(width: context.rpx(24)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.rpx(34),
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: background.isEmpty
                            ? AppColors.text000
                            : AppColors.white,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...<Widget>[
                      SizedBox(height: context.rpx(10)),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.rpx(26),
                          color: background.isEmpty
                              ? AppColors.text666
                              : const Color(0xCCFFFFFF),
                        ),
                      ),
                    ],
                    if (meta.isNotEmpty) ...<Widget>[
                      SizedBox(height: context.rpx(8)),
                      Text(
                        meta,
                        style: TextStyle(
                          fontSize: context.rpx(24),
                          color: background.isEmpty
                              ? AppColors.text999
                              : const Color(0xB3FFFFFF),
                        ),
                      ),
                    ],
                    if (onPlayAll != null) ...<Widget>[
                      SizedBox(height: context.rpx(18)),
                      Row(
                        children: <Widget>[
                          FilledButton.icon(
                            onPressed: onPlayAll,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.wechatGreen,
                              foregroundColor: AppColors.white,
                              padding: EdgeInsets.symmetric(
                                horizontal: context.rpx(26),
                                vertical: context.rpx(14),
                              ),
                              minimumSize: Size.zero,
                              textStyle: TextStyle(fontSize: context.rpx(26)),
                            ),
                            icon: Icon(Icons.play_arrow, size: context.rpx(32)),
                            label: Text(playAllLabel ?? ''),
                          ),
                          if (trailing != null) ...<Widget>[
                            SizedBox(width: context.rpx(14)),
                            trailing!,
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
