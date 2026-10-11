import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/lingting/lingting_card.dart';
import '../../../lingting/widgets/lingting_cover.dart';

/// 音乐卡片（`type == 'lingting'`）。
///
/// 布局照微信那套分享卡片：左边歌名（最多两行）+ 歌手，右边一张封面，
/// 底下一条细线收尾，最后一行是小音符 + 来源（「灵听」）。
/// 整块都能点（点一下开播并进播放页），**不做气泡小尾巴** ——
/// 微信里这类卡片也是独立的一块。
///
/// 底色**不分你我，永远纯白**（用户 2026-09-30：「转发到聊天里的不管是灵听还是
/// 媒体号文章，都改成对方发给我的那种 UI，白色的这种气泡框，不要绿色了」）：
/// 分享卡片本来就是「一张卡片」，不是一句我说的话 —— 绿底会让人误以为
/// 卡片里的标题是我打的字。只有普通文字气泡才分颜色（自己的绿、对方的白）。
class MusicCardBubble extends StatelessWidget {
  const MusicCardBubble({
    super.key,
    required this.card,
    required this.sourceLabel,
    this.onTap,
  });

  final MusicCard card;

  /// 卡片底部那行来源文案（`lingting.title`）
  final String sourceLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: context.rpx(420),
        padding: EdgeInsets.fromLTRB(
          context.rpx(22),
          context.rpx(20),
          context.rpx(18),
          context.rpx(14),
        ),
        decoration: BoxDecoration(
          // 不分你我：自己的卡片也是白色（见类注释）
          color: AppColors.white,
          borderRadius: BorderRadius.circular(context.rpx(8)),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        card.name.isEmpty ? sourceLabel : card.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.rpx(30),
                          height: 1.25,
                          color: AppColors.text000,
                        ),
                      ),
                      if (card.singer.isNotEmpty) ...<Widget>[
                        SizedBox(height: context.rpx(10)),
                        Text(
                          card.singer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.rpx(24),
                            color: AppColors.text999,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: context.rpx(18)),
                Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    LingtingCover(url: card.cover, sizeRpx: 120, radiusRpx: 10),
                    // 这颗小播放键是「这里点得动」的提示（微信卡片也有）
                    Icon(
                      Icons.play_circle_fill,
                      size: context.rpx(46),
                      color: Colors.white.withValues(alpha: 0.88),
                      shadows: const <Shadow>[
                        Shadow(color: Color(0x66000000), blurRadius: 6),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.rpx(14)),
              child: const Divider(height: 1, color: Color(0x1A000000)),
            ),
            Row(
              children: <Widget>[
                Icon(
                  Icons.music_note,
                  size: context.rpx(22),
                  color: AppColors.text999,
                ),
                SizedBox(width: context.rpx(6)),
                Text(
                  sourceLabel,
                  style: TextStyle(
                    fontSize: context.rpx(20),
                    color: AppColors.text999,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
