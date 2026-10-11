import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/retry_view.dart';
import '../../data/model/lingting/singer.dart';
import '../../domain/lingting/lingting_player.dart';
import '../../domain/lingting/lingting_providers.dart';
import 'widgets/lingting_detail_header.dart';
import 'widgets/lingting_mini_player.dart';
import 'widgets/lingting_skeleton.dart';
import 'widgets/lingting_song_tile.dart';

/// 专辑页（`/lingting/album?id=<专辑 id>`）。
///
/// 分层加载（S12.1）：本机存着的那份先出画，网络上那份回来再盖上去。
class LingtingAlbumPage extends ConsumerWidget {
  const LingtingAlbumPage({super.key, required this.albumId});

  final int albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final staged = ref.watch(lingtingAlbumProvider(albumId));

    return LingtingScaffold(
      leading: IconButton(
        onPressed: () => context.pop(),
        icon: const Icon(Icons.arrow_back),
        color: AppColors.text000,
      ),
      title: '',
      body: switch (staged.value) {
        final LingtingAlbum album => _body(context, ref, i18n, album),
        _ =>
          staged.failed
              ? RetryView(
                  message: i18n.t('common.loadFailed'),
                  retryLabel: i18n.t('common.retry'),
                  onRetry: () => ref
                      .read(lingtingAlbumProvider(albumId).notifier)
                      .refresh(),
                )
              : const LingtingDetailSkeleton(),
      },
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AppI18n i18n,
    LingtingAlbum album,
  ) {
    final songs = album.songs;
    return ListView(
      padding: EdgeInsets.only(bottom: context.rpx(30)),
      children: <Widget>[
        LingtingDetailHeader(
          cover: album.cover,
          title: album.name,
          subtitle: album.singerName,
          meta: i18n.t('lingting.songCount', <String, String>{
            'count': '${songs.isEmpty ? album.songCount : songs.length}',
          }),
          playAllLabel: i18n.t('lingting.playAllCount', <String, String>{
            'count': '${songs.length}',
          }),
          onPlayAll: songs.isEmpty
              ? null
              : () => ref
                    .read(lingtingPlayerProvider.notifier)
                    .playQueue(songs, source: album.name),
          trailing: album.singerId == 0
              ? null
              : OutlinedButton(
                  onPressed: () => context.push(
                    '${AppRoutes.lingtingSinger}?id=${album.singerId}',
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.rpx(22),
                      vertical: context.rpx(14),
                    ),
                    minimumSize: Size.zero,
                    textStyle: TextStyle(fontSize: context.rpx(26)),
                  ),
                  child: Text(album.singerName),
                ),
        ),
        for (final (index, song) in songs.indexed)
          LingtingSongTile(
            song: song,
            index: index + 1,
            queue: songs,
            source: album.name,
          ),
      ],
    );
  }
}
