import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/link_opener.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/util/time_format.dart';
import '../../data/model/conversation.dart';
import '../../data/repo/message_sender.dart';
import '../../domain/news/news_article.dart';
import '../../domain/news/news_card.dart';
import '../../domain/news/news_feed.dart';
import '../../domain/news/news_providers.dart';
import '../chat/widgets/forward_picker.dart';
import 'widgets/news_source_avatar.dart';

/// 一篇资讯。
///
/// **刻意不做全文渲染**，只画摘要 + 封面 + 来源 + 时间，然后一颗「阅读原文」
/// 去原站。三个理由：
///
/// 1. 版权：只给摘要和链接是最稳的做法（全文转载要来源授权）；
/// 2. 依赖：真渲染 HTML 就得引 `flutter_html` 之类，而这一期只想加功能不加依赖；
/// 3. 排版：源站的 HTML 里塞满了推广卡片、内联样式、`data-*` 属性，
///    硬渲染出来比纯文本更难看（IT之家的正文里就挂着京东商品卡）。
///
/// 版式（用户 2026-09-30：「UI 再美化一下，底部只留阅读原文，分享放右上角，
/// 复制链接去掉」）：
///
/// ```
/// ←   少数派                    [分享]
/// ┌────────────────────────────────────┐
/// │ 标题（大字，粗）                    │
/// │ (派) 少数派 · 09-24 14:20           │
/// │ ────────────────────────────────── │
/// │ [    封面（16:9，圆角）     ]       │
/// │ 摘要第一段…                        │
/// │ 摘要第二段…                        │
/// │ ────────────────────────────────── │
/// │ 以上是来源给出的摘要…               │
/// └────────────────────────────────────┘
///        [      阅读原文      ]
/// ```
///
/// * **顶栏写号名**（公众号读文章时顶上也是号）：用户随时知道自己在读谁的文章；
/// * **分享只留右上角那一颗**（复用聊天那套转发选择器发一张资讯卡片）；
/// * **底栏只有「阅读原文」**：它是这一页唯一的主操作，所以给通栏宽度。
///   原来并排的「分享 / 复制链接」两颗小方钮都撤了 —— 分享挪到顶栏，
///   复制链接**整个去掉**（用户明确不要）。
class NewsDetailPage extends ConsumerStatefulWidget {
  const NewsDetailPage({super.key, required this.id, this.shared});

  /// 文章 id（路由 `?id=`）。**不传整个对象**：详情页从列表那份数据里按 id 取，
  /// 这样热重载、深链接都不会捧着一个过期对象渲染。
  final String id;

  /// 从聊天里的**资讯卡片**点进来时带来的那一份（路由 `extra`）。
  ///
  /// 收卡片的人本机列表里没有这一篇（那是发的人机器上抓到的），所以列表里找不到时
  /// 用它合成一条 —— 至少标题/摘要/缩略图/原文地址是齐的，点「阅读原文」照样能看全文。
  /// 本机恰好也有这一篇（自己分享的，或者自己列表里那条）时**优先用列表那条**：
  /// 那份更新、也不该因为一张卡片就少掉本地状态。
  final NewsCard? shared;

  @override
  ConsumerState<NewsDetailPage> createState() => _NewsDetailPageState();
}

class _NewsDetailPageState extends ConsumerState<NewsDetailPage> {
  @override
  void initState() {
    super.initState();
    // 进来就算读过了（列表里那个红点消失）。放在 initState 里只做一次，
    // 不要在 build 里调 —— 那会在每次重建时都写一遍磁盘。
    //
    // 分享进来的那条**不标**：它不在本机列表里，标了也只是在已读表里多一个
    // 永远用不上的 id。
    if (widget.shared == null) {
      ref.read(newsListProvider.notifier).markRead(widget.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final local = ref.watch(newsArticleProvider(widget.id));
    final article = local ?? widget.shared?.toArticle();
    final feed = article == null ? null : newsFeedByKey(article.sourceKey);
    // 能不能分享出去（手上至少有一份完整信息时就能）
    final shareable =
        article != null && (local != null || widget.shared != null);

    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        // 顶栏写号名，不是「媒体号」：和公众号一样，读文章时顶上写着你正在读谁
        title: Text(
          feed == null ? i18n.t('news.title') : i18n.t(feed.nameKey),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: context.rpx(32)),
        ),
        actions: <Widget>[
          if (shareable)
            IconButton(
              tooltip: i18n.t('news.share'),
              onPressed: () => _share(i18n, article),
              icon: Icon(Icons.ios_share, size: context.rpx(40)),
            ),
        ],
      ),
      body: article == null ? _Missing(id: widget.id) : _Body(article: article),
    );
  }

  /// 分享：选人（复用聊天那套转发选择器）→ 发一张**资讯卡片**出去。
  ///
  /// 和灵听那边的「分享」是同一套（用户 2026-09-30：「能不能做成像音乐一样的
  /// 卡片可以分享到聊天里」）：卡片带标题/来源/缩略图/原文地址，对方点一下进
  /// 详情页，他本机没有这一篇也能看（摘要 + 阅读原文）。
  Future<void> _share(AppI18n i18n, NewsArticle article) async {
    final targets = await showForwardPicker(context, excludeId: '');
    if (targets == null || targets.isEmpty) return;

    final me = ref.read(sessionStoreProvider).user;
    // 没登录态就发不出去（正常情况下进不来这一页，兜一下）
    if (me == null) return;
    final sender = ref.read(messageSenderProvider);
    final card = NewsCard.fromArticle(article);
    var sent = 0;
    for (final target in targets) {
      try {
        final result = await sender.sendNewsCard(
          conversation: Conversation(
            id: target.id,
            displayName: target.name,
            avatar: target.avatar,
            isGroup: target.isGroup,
          ),
          me: me,
          card: card,
          translate: i18n.t,
        );
        if (result.ok) sent += 1;
      } on Object catch (error) {
        debugPrint('[资讯] 分享失败（${target.name}）：$error');
      }
    }
    if (!mounted) return;
    noticeBus.toast(
      sent == 0
          ? i18n.t('news.shareFailed')
          : i18n.t('news.sharedCount', <String, String>{'count': '$sent'}),
    );
  }
}

/// 文章不在了：本机缓存被新一轮抓取顶掉，或者从别处深链接进来的 id 是旧的
class _Missing extends ConsumerWidget {
  const _Missing({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rpx(60)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              i18n.t('news.gone'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.rpx(27),
                color: AppColors.text666,
              ),
            ),
            SizedBox(height: context.rpx(24)),
            // 直接给一条路：这里只是因为列表那份数据里找不到它，
            // 把列表刷一遍多半就有了
            OutlinedButton(
              onPressed: () => ref.read(newsListProvider.notifier).refresh(),
              child: Text(i18n.t('common.retry')),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.article});

  final NewsArticle article;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final feed = newsFeedByKey(article.sourceKey);
    // 列表里那张封面可能是从原文页补回来的（feed 里没图），详情页跟着用同一张
    final image = newsImageOf(article, ref.watch(newsCoversProvider));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      ref.read(newsCoversProvider.notifier).ensure(<NewsArticle>[article]);
    });
    final time = article.publishedAt == null
        ? ''
        : timeFormat(
            article.publishedAt!.millisecondsSinceEpoch,
            translate: i18n.t,
          );
    final paragraphs = article.summary
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);

    return Column(
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              context.rpx(40),
              context.rpx(40),
              context.rpx(40),
              context.rpx(48),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  article.title,
                  style: TextStyle(
                    fontSize: context.rpx(44),
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text000,
                  ),
                ),
                SizedBox(height: context.rpx(26)),
                _SourceLine(
                  sourceKey: article.sourceKey,
                  name: feed == null ? '' : i18n.t(feed.nameKey),
                  time: time,
                ),
                SizedBox(height: context.rpx(26)),
                Container(height: 1, color: AppColors.line),
                if (image.isNotEmpty) ...<Widget>[
                  SizedBox(height: context.rpx(28)),
                  _Cover(url: image),
                ],
                if (paragraphs.isEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: context.rpx(28)),
                    child: Text(
                      i18n.t('news.onlyLink'),
                      style: TextStyle(
                        fontSize: context.rpx(31),
                        height: 1.75,
                        color: AppColors.text666,
                      ),
                    ),
                  )
                else
                  for (final paragraph in paragraphs)
                    Padding(
                      padding: EdgeInsets.only(top: context.rpx(28)),
                      child: Text(
                        paragraph,
                        style: TextStyle(
                          fontSize: context.rpx(31),
                          height: 1.75,
                          color: AppColors.text333,
                        ),
                      ),
                    ),
                SizedBox(height: context.rpx(40)),
                Container(height: 1, color: AppColors.line),
                SizedBox(height: context.rpx(20)),
                // 说清楚这是摘要：免得用户以为文章就这么短，或者以为我们把内容吞了
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.notes_outlined,
                      size: context.rpx(26),
                      color: AppColors.text999,
                    ),
                    SizedBox(width: context.rpx(10)),
                    Expanded(
                      child: Text(
                        i18n.t('news.snippetNote'),
                        style: TextStyle(
                          fontSize: context.rpx(23),
                          height: 1.6,
                          color: AppColors.text999,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        _OriginalBar(
          label: i18n.t('news.readOriginal'),
          onTap: article.link.isEmpty
              ? null
              : () => openChatLink(context, article.link),
        ),
      ],
    );
  }
}

/// 标题下面那一行：头像 + 号名 + 时间（和列表卡头同一套观感）
class _SourceLine extends StatelessWidget {
  const _SourceLine({
    required this.sourceKey,
    required this.name,
    required this.time,
  });

  final String sourceKey;
  final String name;
  final String time;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      NewsSourceAvatar(sourceKey: sourceKey, diameter: 48),
      if (name.isNotEmpty) ...<Widget>[
        SizedBox(width: context.rpx(14)),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.rpx(28),
              fontWeight: FontWeight.w500,
              color: AppColors.text000,
            ),
          ),
        ),
      ],
      if (time.isNotEmpty) ...<Widget>[
        SizedBox(width: context.rpx(12)),
        Text(
          time,
          style: TextStyle(
            fontSize: context.rpx(25),
            color: AppColors.textTime,
          ),
        ),
      ],
    ],
  );
}

/// 封面：16:9 圆角通栏（和列表里那张保持一致），没加载出来时留一块浅灰
/// —— **不留红叉**：源站的图常防盗链，那是别人的问题，不该看着像我们坏了。
class _Cover extends StatelessWidget {
  const _Cover({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final width = context.rpx(750);
    final placeholder = Container(
      color: AppColors.gray,
      alignment: Alignment.center,
      child: Icon(
        Icons.image_outlined,
        size: context.rpx(48),
        color: AppColors.text999,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(context.rpx(16)),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          // 按显示尺寸解码（微信那种大图直接塞进内存会拖慢整页）
          cacheWidth: (width * 3).round(),
          errorBuilder: (context, error, stack) => placeholder,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : placeholder,
        ),
      ),
    );
  }
}

/// 底栏：**只有一颗通栏的「阅读原文」**。
///
/// 它是这一页唯一的主操作，所以给满宽（原来并排的小方钮都撤了：分享挪到顶栏、
/// 复制链接整个去掉 —— 用户 2026-09-30 定的）。
class _OriginalBar extends StatelessWidget {
  const _OriginalBar({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: AppColors.white,
      border: Border(top: BorderSide(color: AppColors.line)),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          context.rpx(40),
          context.rpx(20),
          context.rpx(40),
          context.rpx(20),
        ),
        child: SizedBox(
          height: context.rpx(92),
          child: ElevatedButton.icon(
            onPressed: onTap,
            icon: Icon(Icons.open_in_new, size: context.rpx(32)),
            label: Text(
              label,
              style: TextStyle(
                fontSize: context.rpx(32),
                fontWeight: FontWeight.w500,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.wechatGreen,
              foregroundColor: AppColors.white,
              disabledBackgroundColor: AppColors.gray,
              disabledForegroundColor: AppColors.text999,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(context.rpx(46)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
