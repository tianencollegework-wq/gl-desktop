import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../data/model/lingting/download.dart';
import '../../data/model/lingting/song.dart';
import '../../domain/lingting/lingting_downloads.dart';
import '../../domain/lingting/lingting_player.dart';
import 'widgets/lingting_cover.dart';
import 'widgets/lingting_mini_player.dart';

/// 「下载管理」（首页右上角那颗键进来）—— 本机已经下好的歌都在这儿。
///
/// 为什么要有这一页：下载是为了**离线**听，之前下过的歌只在播放页那颗绿色对勾上
/// 有个影子，想看「我到底下了哪些、占了多少」都没有入口。
///
/// 这一页**完全不联网**：歌名/歌手/封面在下载那一刻就记在本机清单里了
/// （见 `LingtingDownload`），飞行模式进来也是完整的一份列表。
///
/// * 点某一行 → 从这一首开始播（队列就是下载列表，本地文件优先）；
/// * 长按某一行 → 删掉本机那一份（跟微信删聊天记录一样先确认一下）。
///
/// 进来时会顺手 `enrichMissing()`：最早那版下载记录里只有一条路径，
/// 不补的话这一页会列出一个数字当歌名（用户 2026-09-25 就是这么看到的 `3866`）。
class LingtingDownloadsPage extends ConsumerStatefulWidget {
  const LingtingDownloadsPage({super.key});

  @override
  ConsumerState<LingtingDownloadsPage> createState() =>
      _LingtingDownloadsPageState();
}

class _LingtingDownloadsPageState extends ConsumerState<LingtingDownloadsPage> {
  @override
  void initState() {
    super.initState();
    // 老记录补全：联网时才会真发请求，断网就安静跳过（这一页本身不联网也能用）
    ref.read(lingtingDownloadsProvider.notifier).enrichMissing();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final downloads = ref.watch(lingtingDownloadsProvider);
    final items = downloads.items.entries.toList(growable: false);

    return LingtingScaffold(
      title: i18n.t('lingting.downloadsTitle'),
      body: items.isEmpty
          ? _Empty(hint: i18n.t('lingting.downloadsEmpty'))
          : ListView.separated(
              padding: EdgeInsets.only(top: context.rpx(8)),
              itemCount: items.length,
              separatorBuilder: (context, index) => Divider(
                height: 1,
                indent: context.rpx(30),
                color: AppColors.rowDivider,
              ),
              itemBuilder: (context, index) {
                final entry = items[index];
                return _DownloadRow(
                  song: entry.value.toSong(entry.key),
                  onTap: () => _play(ref, downloads.songs, index, i18n),
                  onLongPress: () => _confirmDelete(
                    context,
                    ref,
                    entry.key,
                    entry.value,
                    i18n,
                  ),
                );
              },
            ),
    );
  }

  /// 点一行：以**下载列表**为队列播这一首（这样「下一首」也是下好的一首，离线能一直听）
  void _play(
    WidgetRef ref,
    List<LingtingSong> queue,
    int index,
    AppI18n i18n,
  ) => ref
      .read(lingtingPlayerProvider.notifier)
      .playQueue(
        queue,
        startIndex: index,
        source: i18n.t('lingting.downloadsTitle'),
      );

  /// 长按一行 → 确认后删本机那一份（歌本身、账号那边的记录都不动）
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    int songId,
    LingtingDownload download,
    AppI18n i18n,
  ) async {
    final confirmed = await showWeChatConfirm(
      context,
      message: i18n.t('lingting.deleteDownloadConfirm', <String, String>{
        'name': download.name.isEmpty
            ? i18n.t('lingting.downloadsTitle')
            : download.name,
      }),
      confirmLabel: i18n.t('common.del'),
      danger: true,
    );
    if (!confirmed) return;
    await ref.read(lingtingDownloadsProvider.notifier).remove(songId);
    if (context.mounted) noticeBus.toast(i18n.t('lingting.deletedDownload'));
  }
}

/// 一行：封面 + 歌名 + 歌手（右侧一颗小播放键，让「这一点就播」看得见）
class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.song,
    required this.onTap,
    required this.onLongPress,
  });

  final LingtingSong song;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    onLongPress: onLongPress,
    // 桌面（2026-10-03）：右键同长按 → 删除确认（歌本身不动，只删本机那份）
    onSecondaryTapDown: (_) => onLongPress(),
    child: Container(
      color: AppColors.white,
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(30),
        vertical: context.rpx(20),
      ),
      child: Row(
        children: <Widget>[
          LingtingCover(url: song.cover, sizeRpx: 96, radiusRpx: 12),
          SizedBox(width: context.rpx(22)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.rpx(30),
                    color: AppColors.text000,
                  ),
                ),
                SizedBox(height: context.rpx(8)),
                Text(
                  song.singerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.rpx(24),
                    color: AppColors.text999,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.download_done,
            size: context.rpx(38),
            color: AppColors.wechatGreen,
          ),
        ],
      ),
    ),
  );
}

/// 一首都没下过：给一句「怎么才会有」的话，别只丢一个空页面
class _Empty extends StatelessWidget {
  const _Empty({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rpx(80)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.download_outlined,
            size: context.rpx(96),
            color: AppColors.chevron,
          ),
          SizedBox(height: context.rpx(22)),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.rpx(28),
              height: 1.6,
              color: AppColors.text999,
            ),
          ),
        ],
      ),
    ),
  );
}
