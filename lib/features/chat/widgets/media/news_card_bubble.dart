import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/i18n/app_i18n.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/util/time_format.dart';
import '../../../../domain/news/news_card.dart';
import '../../../../domain/news/news_feed.dart';

/// 资讯卡片（`type == 'news'`）。版式与音乐卡片（[MusicCardBubble]）**一套**：
/// 左边标题（最多两行）+ 「来源 · 时间」，右边一张缩略图，底下一条细线，
/// 最后一行是小图标 + 来源文案（「资讯」）。整块都能点，**不做气泡小尾巴** ——
/// 微信里这类分享卡片也是独立的一块。
///
/// 为什么是个 `ConsumerWidget`（音乐卡片是纯 `StatelessWidget`）：
/// 卡片上的来源名要**按当前语言**解析（中文「少数派」/英文「sspai」），
/// 而存进消息里的是来源 key，渲染时才查语言包。
///
/// 底色**不分你我，永远纯白**（用户 2026-09-30：「转发到聊天里的不管是灵听还是
/// 媒体号文章，都改成对方发给我的那种 UI，白色的这种气泡框，不要绿色了」）——
/// 与音乐卡片（[MusicCardBubble]）同一条规矩。
class NewsCardBubble extends ConsumerWidget {
  const NewsCardBubble({
    super.key,
    required this.card,
    required this.sourceLabel,
    this.onTap,
  });

  final NewsCard card;

  /// 卡片底部那行来源文案（`news.title`）
  final String sourceLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final feed = newsFeedByKey(card.sourceKey);
    final meta = <String>[
      if (feed != null) i18n.t(feed.nameKey),
      if (card.publishedAt != null)
        timeFormat(card.publishedAt!.millisecondsSinceEpoch, translate: i18n.t),
    ].join(' · ');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: context.rpx(440),
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
                        card.title.isEmpty ? sourceLabel : card.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.rpx(30),
                          height: 1.25,
                          color: AppColors.text000,
                        ),
                      ),
                      if (meta.isNotEmpty) ...<Widget>[
                        SizedBox(height: context.rpx(10)),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.rpx(22),
                            color: AppColors.text999,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (card.image.isNotEmpty) ...<Widget>[
                  SizedBox(width: context.rpx(18)),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(context.rpx(10)),
                    child: _Thumb(url: card.image),
                  ),
                ],
              ],
            ),
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.rpx(14)),
              child: const Divider(height: 1, color: Color(0x1A000000)),
            ),
            Row(
              children: <Widget>[
                Icon(
                  Icons.article_outlined,
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

/// 卡片右边那张缩略图。加载不出来就画一块灰底（源站图常防盗链，
/// 那是别人的问题，不该在聊天里显得像我们坏了）
class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => Image.network(
    url,
    width: context.rpx(120),
    height: context.rpx(120),
    fit: BoxFit.cover,
    errorBuilder: (context, error, stack) => _placeholder(context),
    loadingBuilder: (context, child, progress) =>
        progress == null ? child : _placeholder(context),
  );

  Widget _placeholder(BuildContext context) => Container(
    width: context.rpx(120),
    height: context.rpx(120),
    color: AppColors.gray,
    alignment: Alignment.center,
    child: Icon(
      Icons.article_outlined,
      size: context.rpx(40),
      color: AppColors.text999,
    ),
  );
}
