import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/model/lingting/home.dart';
import '../../data/model/lingting/singer.dart';
import '../../data/model/lingting/song.dart';
import '../../data/model/lingting/song_sheet.dart';
import '../../data/repo/lingting_repository.dart';
import '../../domain/lingting/lingting_player.dart';
import '../../domain/lingting/lingting_providers.dart';
import 'widgets/lingting_cover.dart';
import 'widgets/lingting_mini_player.dart';
import 'widgets/lingting_song_tile.dart';

/// 灵听首页 —— 「发现」里填 `/pages/lingting/index` 进的就是这一页。
///
/// 这一页**不做任何假设**：banner / 每日三十首 / 热门 / 推荐歌单 / 推荐歌手
/// 五个区块各自独立，缺哪块就不画哪块（服务端某个接口挂了也照样进得来）。
class LingtingHomePage extends ConsumerWidget {
  const LingtingHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final state = ref.watch(lingtingHomeProvider);

    return LingtingScaffold(
      title: i18n.t('lingting.title'),
      backgroundColor: AppColors.white,
      // 右上角：下载管理（下过几首时挂个小角标，一眼看得出里面有东西）
      actions: <Widget>[_DownloadsAction(ref: ref)],
      // 五块**各画各的**（S12.1）：本机存着的那份、或先回来的那几块立刻出画，
      // 还在路上的先摆骨架 —— 不再等最慢的那一个（老实现要等五个接口 + 每日三十首
      // 那两次串行的兜底请求全齐了才画，用户看到的就是「转圈大半天」）。
      // 只有「没有缓存 + 五块全挂」才整页失败。
      body: state.failed
          ? _Failed(
              message: i18n.t('lingting.emptyHint'),
              retry: i18n.t('common.retry'),
              onRetry: () => ref.read(lingtingHomeProvider.notifier).refresh(),
            )
          : RefreshIndicator(
              color: AppColors.wechatGreen,
              onRefresh: () =>
                  ref.read(lingtingHomeProvider.notifier).refresh(),
              child: ListView(
                padding: EdgeInsets.only(bottom: context.rpx(24)),
                children: <Widget>[
                  _SearchPill(hint: i18n.t('lingting.searchHint')),
                  ..._section(
                    state,
                    LingtingHomeSection.banners,
                    () => <Widget>[_Banner(banners: state.home.banners)],
                  ),
                  ..._section(
                    state,
                    LingtingHomeSection.daily,
                    () => _daily(ref, state.home, i18n),
                  ),
                  ..._section(
                    state,
                    LingtingHomeSection.hot,
                    () => _hot(ref, state.home, i18n),
                  ),
                  ..._section(
                    state,
                    LingtingHomeSection.sheets,
                    () => <Widget>[
                      _SheetRow(
                        sheets: state.home.sheets,
                        title: i18n.t('lingting.sheetsTitle'),
                      ),
                      const _Gap(),
                    ],
                  ),
                  ..._section(
                    state,
                    LingtingHomeSection.singers,
                    () => <Widget>[
                      _SingerRow(
                        singers: state.home.singers,
                        title: i18n.t('lingting.singersTitle'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  /// 一块的渲染规矩（三选一）：
  /// **有内容就画内容**（下拉刷新时也照画，不闪骨架）→ 没内容但在等就画骨架 →
  /// 没内容也不在等（服务端确实没给这一块）就什么都不画。
  List<Widget> _section(
    LingtingHomeState state,
    LingtingHomeSection section,
    List<Widget> Function() content,
  ) {
    final hasData = switch (section) {
      LingtingHomeSection.banners => state.home.banners.isNotEmpty,
      LingtingHomeSection.daily => state.home.daily.isNotEmpty,
      LingtingHomeSection.hot => state.home.hot.isNotEmpty,
      LingtingHomeSection.sheets => state.home.sheets.isNotEmpty,
      LingtingHomeSection.singers => state.home.singers.isNotEmpty,
    };
    if (hasData) return content();
    if (state.isPending(section)) {
      return <Widget>[
        _HomeSkeleton(
          // 给用例一个把手：这一块还挂着骨架（等它回来就换成内容）
          key: ValueKey<String>('lingtingHomeSkeleton.${section.name}'),
          section: section,
        ),
      ];
    }
    return const <Widget>[];
  }

  /// 「每日三十首」那一块（接口拿不到时会退到置顶栏，标题跟着换，不冒充）
  List<Widget> _daily(WidgetRef ref, LingtingHome home, AppI18n i18n) {
    final title = i18n.t(
      home.dailyFromTop ? 'lingting.newSongsTitle' : 'lingting.dailyTitle',
    );
    return <Widget>[
      _SectionHeader(
        title: title,
        action: i18n.t('lingting.playAll'),
        onAction: () => _playAll(ref, home.daily, title),
      ),
      for (final (index, song) in home.daily.take(3).indexed)
        LingtingSongTile(
          song: song,
          index: index + 1,
          queue: home.daily,
          source: title,
        ),
      const _Gap(),
    ];
  }

  /// 「热门歌曲」那一块
  List<Widget> _hot(WidgetRef ref, LingtingHome home, AppI18n i18n) => <Widget>[
    _SectionHeader(
      title: i18n.t('lingting.hotTitle'),
      action: i18n.t('lingting.playAll'),
      onAction: () => _playAll(ref, home.hot, i18n.t('lingting.hotTitle')),
    ),
    for (final (index, song) in home.hot.take(5).indexed)
      LingtingSongTile(
        song: song,
        index: index + 1,
        queue: home.hot,
        source: i18n.t('lingting.hotTitle'),
      ),
    const _Gap(),
  ];

  void _playAll(WidgetRef ref, List<LingtingSong> songs, String source) => ref
      .read(lingtingPlayerProvider.notifier)
      .playQueue(songs, source: source);
}

/// 还在路上的那一块先摆几个灰块。
///
/// **刻意不做闪烁动画**：一闪一闪的骨架在组件测试里会把 `pumpAndSettle` 挂死
/// （永远有动画在跑），而且这里要的只是「这一块已经在路上了」这一个信息。
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton({super.key, required this.section});

  final LingtingHomeSection section;

  @override
  Widget build(BuildContext context) {
    // 轮播是整块一张大图，不跟列表一个形状
    if (section == LingtingHomeSection.banners) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(24),
          vertical: context.rpx(12),
        ),
        child: _Block(height: context.rpx(276), radius: context.rpx(18)),
      );
    }

    final horizontal =
        section == LingtingHomeSection.sheets ||
        section == LingtingHomeSection.singers;
    final rows = section == LingtingHomeSection.singers ? 1 : 3;
    // 横排那两块：一张方封面 / 一个圆头像，底下一条名字
    final tile = context.rpx(180);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.rpx(30),
            context.rpx(28),
            context.rpx(30),
            context.rpx(12),
          ),
          child: _Block(
            width: context.rpx(160),
            height: context.rpx(32),
            radius: context.rpx(6),
          ),
        ),
        for (var i = 0; i < rows; i++)
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rpx(30),
              context.rpx(10),
              context.rpx(30),
              context.rpx(10),
            ),
            child: horizontal
                ? Row(
                    children: <Widget>[
                      for (var j = 0; j < 2; j++) ...<Widget>[
                        if (j > 0) SizedBox(width: context.rpx(20)),
                        _Block(
                          width: tile,
                          height: tile,
                          radius: context.rpx(14),
                        ),
                      ],
                    ],
                  )
                : Row(
                    children: <Widget>[
                      _Block(
                        width: context.rpx(88),
                        height: context.rpx(88),
                        radius: context.rpx(12),
                      ),
                      SizedBox(width: context.rpx(20)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            _Block(
                              height: context.rpx(26),
                              radius: context.rpx(6),
                            ),
                            SizedBox(height: context.rpx(14)),
                            _Block(
                              width: context.rpx(220),
                              height: context.rpx(22),
                              radius: context.rpx(6),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        const _Gap(),
      ],
    );
  }
}

/// 骨架里的一个灰块
class _Block extends StatelessWidget {
  const _Block({this.width, required this.height, required this.radius});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: AppColors.gray,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

/// 首页右上角的「下载管理」入口。
///
/// 只放一颗下载图标：**不挂数字角标**（2026-09-25 用户定：右上角就一个下载符号，
/// 那个绿色数字太吵）；下过的歌在别的页面上只有一个绿色小对勾，要看全部就进这一页
/// （那页完全不联网，见 `LingtingDownloadsPage`）。
class _DownloadsAction extends StatelessWidget {
  const _DownloadsAction({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    return IconButton(
      tooltip: i18n.t('lingting.downloadsTitle'),
      onPressed: () => context.push(AppRoutes.lingtingDownloads),
      icon: Icon(Icons.download_outlined, size: context.rpx(40)),
      color: AppColors.text000,
    );
  }
}

/// 区块之间那一条浅灰带（整页白底会糊成一片，靠它分区）
class _Gap extends StatelessWidget {
  const _Gap();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: context.rpx(16),
    child: ColoredBox(color: AppColors.page),
  );
}

/// 顶部搜索胶囊（比放一颗放大镜好找，也和音乐类 App 的常规一致）
class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      context.rpx(24),
      context.rpx(16),
      context.rpx(24),
      context.rpx(8),
    ),
    child: GestureDetector(
      onTap: () => context.push(AppRoutes.lingtingSearch),
      child: Container(
        height: context.rpx(72),
        decoration: BoxDecoration(
          color: AppColors.panelBackground,
          borderRadius: BorderRadius.circular(context.rpx(36)),
        ),
        padding: EdgeInsets.symmetric(horizontal: context.rpx(26)),
        child: Row(
          children: <Widget>[
            Icon(Icons.search, size: context.rpx(36), color: AppColors.text999),
            SizedBox(width: context.rpx(14)),
            Expanded(
              child: Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(26),
                  color: AppColors.text999,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 顶部轮播。`bannerUrl` 实测是歌曲 id，所以点一下直接播那首歌。
class _Banner extends StatefulWidget {
  const _Banner({required this.banners});

  final List<LingtingBanner> banners;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        SizedBox(
          height: context.rpx(300),
          child: PageView.builder(
            itemCount: widget.banners.length,
            onPageChanged: (index) => setState(() => _index = index),
            itemBuilder: (context, index) {
              final banner = widget.banners[index];
              return GestureDetector(
                onTap: () => _open(context, banner),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rpx(24),
                    vertical: context.rpx(12),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(context.rpx(18)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        LingtingCover(url: banner.image),
                        // 底部压一层黑→透明，标题压在图上也读得清
                        if (banner.title.isNotEmpty)
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.center,
                                colors: <Color>[
                                  Color(0x99000000),
                                  Color(0x00000000),
                                ],
                              ),
                            ),
                          ),
                        if (banner.title.isNotEmpty)
                          Positioned(
                            left: context.rpx(24),
                            right: context.rpx(24),
                            bottom: context.rpx(18),
                            child: Text(
                              banner.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: context.rpx(28),
                                color: AppColors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (widget.banners.length > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              for (var i = 0; i < widget.banners.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: context.rpx(i == _index ? 26 : 12),
                  height: context.rpx(8),
                  margin: EdgeInsets.symmetric(horizontal: context.rpx(5)),
                  decoration: BoxDecoration(
                    color: i == _index
                        ? AppColors.wechatGreen
                        : AppColors.mutedDot,
                    borderRadius: BorderRadius.circular(context.rpx(6)),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  /// 点 banner：`bannerUrl` 是歌曲 id，但列表里没这首的信息，所以先取一次详情
  Future<void> _open(BuildContext context, LingtingBanner banner) async {
    final songId = banner.songId;
    if (songId <= 0) return;
    final container = ProviderScope.containerOf(context);
    try {
      final song = await container
          .read(lingtingRepositoryProvider)
          .api
          .songDetail(songId);
      if (!context.mounted || song.isEmpty) return;
      await container.read(lingtingPlayerProvider.notifier).playSong(song);
    } on Object catch (error) {
      // 这首曲子取不到详情（下架、网络抖）时什么都别做，别弹一堆错
      debugPrint('[灵听] banner 打开失败：$error');
    }
  }
}

/// 区块标题：绿色小竖条 + 标题 + 右侧动作
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    color: AppColors.white,
    padding: EdgeInsets.fromLTRB(
      context.rpx(30),
      context.rpx(28),
      context.rpx(20),
      context.rpx(4),
    ),
    child: Row(
      children: <Widget>[
        Container(
          width: context.rpx(6),
          height: context.rpx(30),
          margin: EdgeInsets.only(right: context.rpx(14)),
          decoration: BoxDecoration(
            color: AppColors.wechatGreen,
            borderRadius: BorderRadius.circular(context.rpx(3)),
          ),
        ),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: context.rpx(32),
              color: AppColors.text000,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (action != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.wechatGreen,
              minimumSize: Size.zero,
              padding: EdgeInsets.symmetric(
                horizontal: context.rpx(12),
                vertical: context.rpx(6),
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.play_circle_outline, size: context.rpx(30)),
                SizedBox(width: context.rpx(6)),
                Text(action!, style: TextStyle(fontSize: context.rpx(26))),
              ],
            ),
          ),
      ],
    ),
  );
}

/// 推荐歌单（横向滚动，一屏三张）
class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.sheets, required this.title});

  final List<LingtingSongSheet> sheets;
  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _SectionHeader(title: title),
      SizedBox(
        height: context.rpx(296),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: context.rpx(22)),
          itemCount: sheets.length,
          itemBuilder: (context, index) {
            final sheet = sheets[index];
            return GestureDetector(
              onTap: () => context.push(
                '${AppRoutes.lingtingSheet}?id=${sheet.sheetId}',
              ),
              child: Container(
                width: context.rpx(216),
                margin: EdgeInsets.symmetric(horizontal: context.rpx(8)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    LingtingCover(
                      url: sheet.cover,
                      sizeRpx: 216,
                      radiusRpx: 16,
                      shadow: true,
                    ),
                    SizedBox(height: context.rpx(14)),
                    Text(
                      sheet.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        height: 1.3,
                        color: AppColors.text000,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}

/// 推荐歌手（横向圆形头像）
class _SingerRow extends StatelessWidget {
  const _SingerRow({required this.singers, required this.title});

  final List<LingtingSinger> singers;
  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _SectionHeader(title: title),
      SizedBox(
        height: context.rpx(226),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: context.rpx(22)),
          itemCount: singers.length,
          itemBuilder: (context, index) {
            final singer = singers[index];
            return GestureDetector(
              onTap: () => context.push(
                '${AppRoutes.lingtingSinger}?id=${singer.singerId}',
              ),
              child: Container(
                width: context.rpx(176),
                margin: EdgeInsets.symmetric(horizontal: context.rpx(8)),
                child: Column(
                  children: <Widget>[
                    LingtingCover(
                      url: singer.avatar,
                      sizeRpx: 156,
                      circular: true,
                      shadow: true,
                    ),
                    SizedBox(height: context.rpx(12)),
                    Text(
                      singer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        color: AppColors.text000,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}

/// 加载失败（灵听进不去时别给白屏）
class _Failed extends StatelessWidget {
  const _Failed({
    required this.message,
    required this.retry,
    required this.onRetry,
  });

  final String message;
  final String retry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.cloud_off, size: context.rpx(88), color: AppColors.chevron),
        SizedBox(height: context.rpx(20)),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: context.rpx(28), color: AppColors.text666),
        ),
        SizedBox(height: context.rpx(24)),
        OutlinedButton(
          onPressed: onRetry,
          child: Text(retry, style: TextStyle(fontSize: context.rpx(28))),
        ),
      ],
    ),
  );
}
