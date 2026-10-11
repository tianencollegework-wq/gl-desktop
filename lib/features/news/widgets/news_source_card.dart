import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/util/time_format.dart';
import '../../../domain/news/news_article.dart';
import '../../../domain/news/news_feed.dart';
import '../../../domain/news/news_group.dart';
import '../../../domain/news/news_providers.dart';
import 'news_source_avatar.dart';

/// 一个「媒体号」的一张卡（用户 2026-09-30 给的公众号截图就是这个版式）：
///
/// ```
/// ┌────────────────────────────────────────┐
/// │ (头像) 温州草根说            14小时前  │
/// │ ┌────────────────────────────────────┐ │
/// │ │        封面（压着标题）            │ │
/// │ └────────────────────────────────────┘ │
/// │ 温州路边摊买水果，结果全是一肚子气  [图]│
/// │ ─────────────────────────────────────── │
/// │ 18万多人涌入温州这里！好热闹        [图]│
/// │ ─────────────────────────────────────── │
/// │ 余下2篇                              ⌄ │
/// └────────────────────────────────────────┘
/// ```
///
/// 几个刻意对齐公众号的地方：卡头是**号**（头像 + 号名 + 号里最新那篇的相对时间），
/// 不是文章；第一篇**有图就压着标题**（图在上、标题浮在图上）；后面几篇是
/// 「左标题 + 右缩略图」的小行，行间一条细线；没露完的收在「余下N篇」后面。
///
/// 「余下N篇」是按号算的（`NewsListState.expanded`）：点哪张卡展开哪张，
/// 别的卡不受影响 —— 用户 2026-09-30 之前抱怨的「一次性加载太多」，
/// 现在既不是全局分页、也不会一进来就把四个号全铺开。
class NewsSourceCard extends ConsumerWidget {
  const NewsSourceCard({super.key, required this.group, required this.onOpen});

  final NewsFeedGroup group;

  /// 点某一篇 → 详情页
  final void Function(NewsArticle article) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final state = ref.watch(newsListProvider).value;
    final covers = ref.watch(newsCoversProvider);
    final visible =
        state?.visibleOf(group.sourceKey) ?? NewsListState.defaultPerSource;
    final hidden = state?.hiddenOf(group) ?? 0;
    final articles = group.articles.take(visible).toList(growable: false);
    if (articles.isEmpty) return const SizedBox.shrink();

    // 封面补图：feed 里只有爱范儿自带图，另外三个要去原文页取 `og:image`。
    // 这里**只给这张卡露出来的这几篇补**（不给整个列表补，否则一进页面就是
    // 上百个请求）；每补到一张 provider 会刷一次，卡片自己就换版了。
    // 放在 post-frame：build 里改 provider 会报错。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      ref.read(newsCoversProvider.notifier).ensure(articles);
    });

    final lead = articles.first;
    final rest = articles.skip(1).toList(growable: false);

    return Container(
      margin: EdgeInsets.fromLTRB(
        context.rpx(20),
        0,
        context.rpx(20),
        context.rpx(16),
      ),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(context.rpx(12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(
            name: i18n.t(_feedNameKey(group.sourceKey)),
            time: group.newest == null
                ? ''
                : feedTime(
                    group.newest!.millisecondsSinceEpoch,
                    translate: i18n.t,
                  ),
            sourceKey: group.sourceKey,
          ),
          _Lead(
            article: lead,
            image: newsImageOf(lead, covers),
            onTap: () => onOpen(lead),
          ),
          for (final article in rest)
            _Row(
              article: article,
              image: newsImageOf(article, covers),
              onTap: () => onOpen(article),
            ),
          if (hidden > 0)
            _MoreRow(
              label: i18n.t('news.moreCount', <String, String>{
                'count': '$hidden',
              }),
              onTap: () =>
                  ref.read(newsListProvider.notifier).expand(group.sourceKey),
            ),
        ],
      ),
    );
  }
}

/// 卡头：头像 + 号名 …… 右上角相对时间
class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.time,
    required this.sourceKey,
  });

  final String name;
  final String time;
  final String sourceKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.rpx(28),
        context.rpx(24),
        context.rpx(28),
        context.rpx(20),
      ),
      child: Row(
        children: <Widget>[
          // 和详情页是同一个头像组件（同一个号在哪儿都长得一样）
          NewsSourceAvatar(sourceKey: sourceKey),
          SizedBox(width: context.rpx(20)),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(31),
                fontWeight: FontWeight.w500,
                color: AppColors.text000,
              ),
            ),
          ),
          if (time.isNotEmpty) ...<Widget>[
            SizedBox(width: context.rpx(16)),
            Text(
              time,
              style: TextStyle(
                fontSize: context.rpx(26),
                color: AppColors.textTime,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 第一篇：**图在上、标题压在图上**（公众号那张图就是这个做法）。
/// 还没有封面时退成「大标题 + 灰色占位块」，补到封面后自己就换版了。
class _Lead extends StatelessWidget {
  const _Lead({
    required this.article,
    required this.image,
    required this.onTap,
  });

  final NewsArticle article;
  final String image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (image.isEmpty) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            context.rpx(28),
            context.rpx(4),
            context.rpx(28),
            context.rpx(28),
          ),
          child: Text(
            article.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.rpx(37),
              height: 1.35,
              fontWeight: FontWeight.w600,
              color: AppColors.text000,
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        // 公众号的封面是宽幅（比 16:9 再扁一点），这里取 16:9 兼顾竖图和横图
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _Cover(url: image),
            // 压一层「下深上透」的渐变：标题不管压在什么图上都读得清
            // （第一张截图里那个浅色底也是同一个用意，只是更淡）
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0x00000000), Color(0xA6000000)],
                ),
              ),
            ),
            Positioned(
              left: context.rpx(28),
              right: context.rpx(28),
              bottom: context.rpx(24),
              child: Text(
                article.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(37),
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: AppColors.white,
                  shadows: const <Shadow>[
                    Shadow(color: Color(0x59000000), blurRadius: 6),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 后面几篇：左标题 + 右缩略图，行间一条细线（细线从标题左边起、通到卡片右缘）
class _Row extends StatelessWidget {
  const _Row({required this.article, required this.image, required this.onTap});

  final NewsArticle article;
  final String image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Padding(
        padding: EdgeInsets.only(left: context.rpx(28)),
        child: Container(height: context.rpx(2), color: AppColors.rowDivider),
      ),
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            context.rpx(28),
            context.rpx(26),
            context.rpx(28),
            context.rpx(26),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    top: image.isEmpty ? 0 : context.rpx(6),
                  ),
                  child: _Title(article: article),
                ),
              ),
              if (image.isNotEmpty) ...<Widget>[
                SizedBox(width: context.rpx(24)),
                ClipRRect(
                  borderRadius: BorderRadius.circular(context.rpx(8)),
                  child: _Cover(url: image, thumb: true),
                ),
              ],
            ],
          ),
        ),
      ),
    ],
  );
}

/// 小行里的标题（读过的淡一档，没读的标题前一颗小红点）
class _Title extends StatelessWidget {
  const _Title({required this.article});

  final NewsArticle article;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      if (!article.read)
        Padding(
          padding: EdgeInsets.only(
            top: context.rpx(13),
            right: context.rpx(12),
          ),
          child: Container(
            width: context.rpx(14),
            height: context.rpx(14),
            decoration: const BoxDecoration(
              color: AppColors.unreadRed,
              shape: BoxShape.circle,
            ),
          ),
        ),
      Expanded(
        child: Text(
          article.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.rpx(33),
            height: 1.4,
            color: article.read ? AppColors.text666 : AppColors.text000,
          ),
        ),
      ),
    ],
  );
}

/// 「余下N篇」—— 点一下这个号再露 10 条
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        context.rpx(28),
        context.rpx(26),
        context.rpx(22),
        context.rpx(26),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: context.rpx(30),
                color: AppColors.text333,
              ),
            ),
          ),
          Icon(
            Icons.keyboard_arrow_down,
            size: context.rpx(40),
            color: AppColors.chevron,
          ),
        ],
      ),
    ),
  );
}

/// 封面 / 缩略图。加载失败就留一块浅灰（**不留红叉**：源站的图常防盗链，
/// 那是别人的问题，不该在列表里显得像我们坏了）。
class _Cover extends StatelessWidget {
  const _Cover({required this.url, this.thumb = false});

  final String url;

  /// 小行的方形缩略图（大封面是通栏的，由外层的 `AspectRatio` 定尺寸）
  final bool thumb;

  @override
  Widget build(BuildContext context) {
    final side = context.rpx(132);
    final width = thumb ? side : context.rpx(750);
    final image = Image.network(
      url,
      width: thumb ? side : null,
      height: thumb ? side : null,
      fit: BoxFit.cover,
      // 按显示尺寸解码：列表里滚起来轻一点，别把原图整个塞进内存
      cacheWidth: (width * 3).round(),
      errorBuilder: (context, error, stack) =>
          thumb ? _placeholder(context, side) : const SizedBox.shrink(),
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : (thumb ? _placeholder(context, side) : const SizedBox.shrink()),
    );
    if (!thumb) return SizedBox.expand(child: image);
    return SizedBox(width: side, height: side, child: image);
  }

  Widget _placeholder(BuildContext context, double side) => Container(
    width: side,
    height: side,
    color: AppColors.gray,
    alignment: Alignment.center,
    child: Icon(
      Icons.image_outlined,
      size: context.rpx(44),
      color: AppColors.text999,
    ),
  );
}

/// 号名（语言包 key，如 `news.source.ithome`；第三方品牌名，中文包「IT之家」、
/// 英文包「ITHome」）。拿不到就退回通用标题，不留一个空的卡头。
String _feedNameKey(String sourceKey) =>
    newsFeedByKey(sourceKey)?.nameKey ?? 'news.title';
