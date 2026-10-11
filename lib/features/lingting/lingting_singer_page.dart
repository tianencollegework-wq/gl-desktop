import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/retry_view.dart';
import '../../data/model/lingting/singer.dart';
import '../../data/model/lingting/song.dart';
import '../../domain/lingting/lingting_player.dart';
import '../../domain/lingting/lingting_providers.dart';
import 'widgets/lingting_cover.dart';
import 'widgets/lingting_detail_header.dart';
import 'widgets/lingting_mini_player.dart';
import 'widgets/lingting_skeleton.dart';
import 'widgets/lingting_song_tile.dart';

/// 歌手页（`/lingting/singer?id=<歌手 id>`）：资料 + 热门歌曲 + 专辑。
///
/// 分层加载（S12.1）：这一页要三个接口（资料 / 歌曲 / 专辑），现在**各拉各的、
/// 回来一块长一块**，不再等最慢的那一个；本机存着的那份则一进来就先摆上。
///
/// 「关注歌手」没做：它要灵听自己的登录态与会员体系，而我们只借了它一个匿名身份；
/// 真要做的话得先确认产品上「关注」算谁的行为（见交付说明）。
class LingtingSingerPage extends ConsumerWidget {
  const LingtingSingerPage({super.key, required this.singerId});

  final int singerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final staged = ref.watch(lingtingSingerProvider(singerId));

    return LingtingScaffold(
      leading: IconButton(
        onPressed: () => context.pop(),
        icon: const Icon(Icons.arrow_back),
        color: AppColors.text000,
      ),
      title: '',
      body: switch (staged.value) {
        // 三块哪一块先回来就先长出来（资料没到时头部先按空资料画，标题是空的）
        final LingtingSingerView view => _body(
          context,
          ref,
          i18n,
          view.singer ?? LingtingSinger.none,
          view.songs,
          view.albums,
        ),
        _ =>
          staged.failed
              ? RetryView(
                  message: i18n.t('common.loadFailed'),
                  retryLabel: i18n.t('common.retry'),
                  onRetry: () => ref
                      .read(lingtingSingerProvider(singerId).notifier)
                      .refresh(),
                )
              : const LingtingDetailSkeleton(rows: 4),
      },
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AppI18n i18n,
    LingtingSinger singer,
    List<LingtingSong> songs,
    List<LingtingAlbum> albums,
  ) {
    return ListView(
      padding: EdgeInsets.only(bottom: context.rpx(30)),
      children: <Widget>[
        LingtingDetailHeader(
          cover: singer.avatar,
          title: singer.name,
          subtitle: singer.fans > 0
              ? i18n.t('lingting.fans', <String, String>{
                  'count': '${singer.fans}',
                })
              : '',
          circularCover: true,
          background: singer.background,
          playAllLabel: i18n.t('lingting.playAllCount', <String, String>{
            'count': '${songs.length}',
          }),
          onPlayAll: songs.isEmpty
              ? null
              : () => ref
                    .read(lingtingPlayerProvider.notifier)
                    .playQueue(songs, source: singer.name),
        ),
        if (albums.isNotEmpty) ...<Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rpx(30),
              context.rpx(20),
              context.rpx(30),
              context.rpx(10),
            ),
            child: Text(
              i18n.t('lingting.albumTitle'),
              style: TextStyle(
                fontSize: context.rpx(30),
                fontWeight: FontWeight.w600,
                color: AppColors.text000,
              ),
            ),
          ),
          SizedBox(
            height: context.rpx(250),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: context.rpx(22)),
              itemCount: albums.length,
              itemBuilder: (context, index) {
                final album = albums[index];
                return GestureDetector(
                  onTap: () => context.push(
                    '${AppRoutes.lingtingAlbum}?id=${album.albumId}',
                  ),
                  child: Container(
                    width: context.rpx(180),
                    margin: EdgeInsets.symmetric(horizontal: context.rpx(8)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        LingtingCover(
                          url: album.cover,
                          sizeRpx: 180,
                          radiusRpx: 14,
                        ),
                        SizedBox(height: context.rpx(10)),
                        Text(
                          album.name,
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
        if (songs.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rpx(30),
              context.rpx(20),
              context.rpx(30),
              context.rpx(6),
            ),
            child: Text(
              i18n.t('lingting.hotTitle'),
              style: TextStyle(
                fontSize: context.rpx(30),
                fontWeight: FontWeight.w600,
                color: AppColors.text000,
              ),
            ),
          ),
        for (final (index, song) in songs.indexed)
          LingtingSongTile(
            song: song,
            index: index + 1,
            queue: songs,
            source: singer.name,
          ),
      ],
    );
  }
}
