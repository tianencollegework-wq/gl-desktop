import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/retry_view.dart';
import '../../data/model/lingting/song_sheet.dart';
import '../../domain/lingting/lingting_player.dart';
import '../../domain/lingting/lingting_providers.dart';
import 'widgets/lingting_detail_header.dart';
import 'widgets/lingting_mini_player.dart';
import 'widgets/lingting_skeleton.dart';
import 'widgets/lingting_song_tile.dart';

/// 歌单详情（`/lingting/sheet?id=<歌单 id>`）。
///
/// 分层加载（S12.1）：**本机存着的那份先出画**，网络上那份回来再换成完整版；
/// 详情里一首歌都没内嵌时，那一页歌曲是后台补的（不再卡着整页不画）。
class LingtingSheetPage extends ConsumerWidget {
  const LingtingSheetPage({super.key, required this.sheetId});

  final int sheetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final staged = ref.watch(lingtingSheetProvider(sheetId));

    return LingtingScaffold(
      leading: IconButton(
        onPressed: () => context.pop(),
        icon: const Icon(Icons.arrow_back),
        color: AppColors.text000,
      ),
      title: '',
      body: switch (staged.value) {
        // 有内容（缓存或已经回来的那份）就画内容；只有真的什么都没有时才
        // 决定画骨架还是画失败
        final LingtingSongSheet sheet => _body(context, ref, i18n, sheet),
        _ =>
          staged.failed
              ? RetryView(
                  message: i18n.t('common.loadFailed'),
                  retryLabel: i18n.t('common.retry'),
                  onRetry: () => ref
                      .read(lingtingSheetProvider(sheetId).notifier)
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
    LingtingSongSheet sheet,
  ) {
    final songs = sheet.songs;
    final source = sheet.name;
    return ListView(
      padding: EdgeInsets.only(bottom: context.rpx(30)),
      children: <Widget>[
        LingtingDetailHeader(
          cover: sheet.cover,
          title: sheet.name,
          subtitle: sheet.authorName,
          meta: <String>[
            if (sheet.songCount > 0)
              i18n.t('lingting.songCount', <String, String>{
                'count': '${sheet.songCount}',
              }),
            if (sheet.playCount > 0) '${sheet.playCount}',
          ].join(' · '),
          playAllLabel: i18n.t('lingting.playAllCount', <String, String>{
            'count': '${songs.length}',
          }),
          onPlayAll: songs.isEmpty
              ? null
              : () => ref
                    .read(lingtingPlayerProvider.notifier)
                    .playQueue(songs, source: source),
        ),
        for (final (index, song) in songs.indexed)
          LingtingSongTile(
            song: song,
            index: index + 1,
            queue: songs,
            source: source,
            // 序号已经有了，就不用再放封面（省得一行里两个图）
            showCover: false,
          ),
      ],
    );
  }
}
