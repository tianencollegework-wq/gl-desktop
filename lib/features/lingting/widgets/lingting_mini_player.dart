import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../domain/lingting/lingting_player.dart';
import 'lingting_cover.dart';

/// 底部迷你播放条。
///
/// 灵听每个页面都挂着它（`Column(内容, MiniPlayer)`），没有歌时高度为 0，
/// 所以页面不用自己判断显隐。点它进播放页，右侧两颗键不触发跳转。
class LingtingMiniPlayer extends ConsumerWidget {
  const LingtingMiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(lingtingPlayerProvider);
    final song = state.current;
    if (song == null) return const SizedBox.shrink();
    final i18n = ref.watch(appI18nProvider);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        border: Border(top: BorderSide(color: AppColors.rowDivider)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 顶部一条细进度线（微信/网易云那种）
          LinearProgressIndicator(
            value: state.progress,
            minHeight: context.rpx(4),
            backgroundColor: AppColors.line,
            valueColor: const AlwaysStoppedAnimation<Color>(
              AppColors.wechatGreen,
            ),
          ),
          InkWell(
            onTap: () => context.push(AppRoutes.lingtingPlayer),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.rpx(24),
                vertical: context.rpx(16),
              ),
              child: Row(
                children: <Widget>[
                  LingtingCover(url: song.cover, sizeRpx: 80, circular: true),
                  SizedBox(width: context.rpx(20)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.rpx(28),
                            color: AppColors.text000,
                          ),
                        ),
                        Text(
                          song.singerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.rpx(22),
                            color: AppColors.text999,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: i18n.t(
                      state.playing ? 'lingting.pause' : 'lingting.play',
                    ),
                    onPressed: () =>
                        ref.read(lingtingPlayerProvider.notifier).toggle(),
                    iconSize: context.rpx(52),
                    color: AppColors.text000,
                    icon: Icon(
                      state.playing
                          ? Icons.pause_circle_outline
                          : Icons.play_circle_outline,
                    ),
                  ),
                  IconButton(
                    tooltip: i18n.t('lingting.next'),
                    onPressed: () =>
                        ref.read(lingtingPlayerProvider.notifier).next(),
                    iconSize: context.rpx(48),
                    color: AppColors.text000,
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ],
      ),
    );
  }
}

/// 灵听页面统一的外壳：白底 + 底部迷你播放条。
class LingtingScaffold extends StatelessWidget {
  const LingtingScaffold({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.backgroundColor,
    required this.body,
    this.resizeToAvoidBottomInset = true,
  });

  final String? title;
  final List<Widget>? actions;
  final Widget? leading;
  final Color? backgroundColor;
  final Widget body;
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: backgroundColor ?? AppColors.white,
    resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    appBar: title == null
        ? null
        : AppBar(
            title: Text(
              title!,
              style: TextStyle(
                fontSize: context.rpx(34),
                color: AppColors.text000,
              ),
            ),
            leading: leading,
            actions: actions,
          ),
    body: Column(
      children: <Widget>[
        Expanded(child: body),
        const LingtingMiniPlayer(),
      ],
    ),
  );
}
