import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../data/model/lingting/song.dart';
import '../../../domain/lingting/lingting_player.dart';
import 'lingting_cover.dart';

/// 歌曲行。
///
/// 三种用途共用一个：
/// * 首页 / 歌单里带**序号**（[index] 给值，从 1 开始）——正在播那首序号变绿色小喇叭；
/// * 搜索结果里带**封面**（[showCover] = true）。
///
/// 没有「喜欢」那颗心形：灵听那套收藏要真账号，我们只借了匿名身份，
/// 收藏进去也没有意义（见 `LingtingApi` 顶部注释）。
class LingtingSongTile extends ConsumerWidget {
  const LingtingSongTile({
    super.key,
    required this.song,
    this.index = 0,
    this.queue = const <LingtingSong>[],
    this.source = '',
    this.showCover = false,
    this.onTap,
  });

  final LingtingSong song;

  /// 0 = 不显示序号
  final int index;

  /// 点它时把哪一批歌塞进播放队列（默认就这一首）
  final List<LingtingSong> queue;
  final String source;

  final bool showCover;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(lingtingPlayerProvider);
    final playing = player.current?.songId == song.songId;

    // 外面这层 Material 是必须的：`Container` 铺了不透明白底之后，
    // InkWell 的水波纹会被压在它下面看不见（点一下毫无反馈）
    return Material(
      color: AppColors.white,
      child: InkWell(
        onTap: onTap ?? () => _play(ref),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.rpx(30),
            vertical: context.rpx(22),
          ),
          child: Row(
            children: <Widget>[
              if (index > 0) _index(context, playing),
              if (showCover) ...<Widget>[
                LingtingCover(
                  url: song.cover,
                  sizeRpx: 92,
                  radiusRpx: 12,
                  shadow: true,
                ),
                SizedBox(width: context.rpx(22)),
              ],
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
                        height: 1.2,
                        color: playing
                            ? AppColors.wechatGreen
                            : AppColors.text000,
                        fontWeight: playing ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    SizedBox(height: context.rpx(8)),
                    Text(
                      song.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.rpx(24),
                        height: 1.2,
                        color: playing
                            ? AppColors.wechatGreen.withValues(alpha: 0.7)
                            : AppColors.text999,
                      ),
                    ),
                  ],
                ),
              ),
              // 正在播的那一首，右边给一个「正在播」的视觉落点，
              // 免得整行只有名字变绿不够明显
              if (playing)
                Padding(
                  padding: EdgeInsets.only(left: context.rpx(12)),
                  child: Icon(
                    Icons.volume_up,
                    size: context.rpx(34),
                    color: AppColors.wechatGreen,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 序号那一列：正在播的那首换成绿色小喇叭，别的显示灰色数字
  Widget _index(BuildContext context, bool playing) => SizedBox(
    width: context.rpx(58),
    child: playing
        ? Icon(
            Icons.graphic_eq,
            size: context.rpx(32),
            color: AppColors.wechatGreen,
          )
        : Text(
            '$index',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.rpx(26),
              color: AppColors.text999,
            ),
          ),
  );

  void _play(WidgetRef ref) {
    final list = queue.isEmpty ? <LingtingSong>[song] : queue;
    ref
        .read(lingtingPlayerProvider.notifier)
        .playSong(song, queue: list, source: source);
  }
}
