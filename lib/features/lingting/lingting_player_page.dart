import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/model/conversation.dart';
import '../../data/model/lingting/lyric.dart';
import '../../data/model/lingting/song.dart';
import '../../data/repo/message_sender.dart';
import '../../domain/lingting/lingting_card.dart';
import '../../domain/lingting/lingting_downloads.dart';
import '../../domain/lingting/lingting_player.dart';
import '../../domain/lingting/lingting_providers.dart';
import '../../core/store/session_store.dart';
import '../chat/widgets/forward_picker.dart';
import 'widgets/lingting_lyric_view.dart';
import 'widgets/lingting_spinning_cover.dart';
import '../../core/ui/desktop_overlay.dart';

/// 播放页（`/lingting/player`）—— 版式照着微信那个播放器来：
///
/// ```
/// ⌄            歌曲 | 歌词            ↗
///                 （封面唱盘）
/// 歌名
/// 歌手
/// 当前这一句歌词
///           ⤓        ⋮
/// ──────●────────────────────
/// 0:00                    5:52
///  ↺1   |◀   ▶   ▶|   ☰
/// ```
///
/// 「分享」走的是聊天那套转发选人（`showForwardPicker`），选完把歌名 + 链接
/// 当**文本消息**发出去；「更多」里是查看歌手 / 查看专辑 / 复制歌词。
class LingtingPlayerPage extends ConsumerStatefulWidget {
  const LingtingPlayerPage({super.key});

  @override
  ConsumerState<LingtingPlayerPage> createState() => _LingtingPlayerPageState();
}

/// 上半屏显示哪一块：唱盘还是歌词（顶栏那两个 tab）
enum _PlayerTab { song, lyric }

class _LingtingPlayerPageState extends ConsumerState<LingtingPlayerPage> {
  /// 拖动进度条时先显示手指的位置（松手才真的 seek）
  double? _dragging;

  /// 上半屏那一整块是可横滑的：封面 ⇄ 歌词（顶栏两个 tab 与它同步）
  final PageController _pages = PageController();

  _PlayerTab _tab = _PlayerTab.song;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final state = ref.watch(lingtingPlayerProvider);
    final playing = state.current;
    final lyric = ref.watch(lingtingLyricProvider);

    // 聊天里点卡片进来的那首没带歌手/专辑 id → 按 songId 补一次详情，
    // 这样歌手那行有专辑、「更多」里的查看歌手 / 查看专辑也点得动。
    // 列表/搜索点进来的本来就全，不会发这个请求。
    final detail = playing != null && needsLingtingSongDetail(playing)
        ? ref.watch(lingtingSongDetailProvider(playing.songId)).value
        : null;
    final song =
        detail != null &&
            playing != null &&
            detail.songId == playing.songId &&
            detail.name.isNotEmpty
        ? detail
        : playing;

    return Scaffold(
      backgroundColor: Colors.black,
      body: song == null
          ? Center(
              child: Text(
                i18n.t('lingting.emptyHint'),
                style: const TextStyle(color: Colors.white70),
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _background(song),
                SafeArea(
                  child: Column(
                    children: <Widget>[
                      _topBar(context, i18n, song),
                      // 上半屏整块可横滑：手指从右往左滑 → 封面溜走、歌词进来；
                      // 反过来滑（左往右）就回到封面。顶栏那两个 tab 与它同步。
                      Expanded(
                        child: PageView(
                          controller: _pages,
                          onPageChanged: (index) =>
                              setState(() => _tab = _PlayerTab.values[index]),
                          children: <Widget>[
                            _coverView(context, song, state),
                            _lyricView(context, i18n, lyric, state),
                          ],
                        ),
                      ),
                      if (_tab == _PlayerTab.song)
                        _songLine(context, i18n, lyric.value, state, song),
                      _actionsRow(context, i18n, song),
                      _progress(context, state),
                      _controls(context, i18n, state),
                      SizedBox(height: context.rpx(12)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// 唱盘那一页（PageView 的第 0 页）—— 屏幕不高（小屏 / 横屏）时整体缩小，
  /// 而不是硬撑一块出去把下面的按钮顶飞
  Widget _coverView(
    BuildContext context,
    LingtingSong song,
    LingtingPlayerState state,
  ) => Center(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: LingtingSpinningCover(url: song.cover, playing: state.playing),
    ),
  );

  /// 歌词那一页（PageView 的第 1 页）—— 拖歌词列表时正好和横滑方向分开，
  /// 不会一碰就翻页
  Widget _lyricView(
    BuildContext context,
    AppI18n i18n,
    AsyncValue<LingtingLyric> lyric,
    LingtingPlayerState state,
  ) => Padding(
    padding: EdgeInsets.symmetric(horizontal: context.rpx(50)),
    child: lyric.when(
      // 切歌时保留上一首的歌词，不要闪一下转圈
      skipLoadingOnReload: true,
      loading: () =>
          const Center(child: CircularProgressIndicator(color: Colors.white70)),
      error: (error, stack) => Center(
        child: Text(
          i18n.t('lingting.noLyric'),
          style: const TextStyle(color: Colors.white54),
        ),
      ),
      data: (data) => LingtingLyricView(
        lyric: data,
        position: state.position,
        // 点某一行 → 从那一句开始放（有时间轴的歌词才有这回事）
        onLineTap: (line) =>
            ref.read(lingtingPlayerProvider.notifier).seek(line.at),
      ),
    ),
  );

  /// 背景：把封面放大 + 高斯模糊，再压一层黑（微信那个播放器就是这个观感）。
  /// 没有封面时退回原来的墨绿渐变。
  Widget _background(LingtingSong song) {
    if (song.cover.isEmpty) {
      return const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xFF1F4633), Color(0xFF0B120E)],
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Transform.scale(
            // 放大一点，免得模糊后边缘露出底色
            scale: 1.3,
            child: Image.network(
              song.cover,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Color(0xFF1F4633), Color(0xFF0B120E)],
                  ),
                ),
              ),
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Color(0x66000000), Color(0x99000000)],
            ),
          ),
        ),
      ],
    );
  }

  /// 顶栏：收起（左下箭头）· 歌曲/歌词 · 分享
  Widget _topBar(BuildContext context, AppI18n i18n, LingtingSong song) {
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: i18n.t('common.back'),
          onPressed: () => context.pop(),
          icon: const Icon(Icons.keyboard_arrow_down),
          iconSize: context.rpx(58),
          color: Colors.white,
        ),
        Expanded(child: _tabs(context, i18n)),
        IconButton(
          tooltip: i18n.t('lingting.share'),
          onPressed: () => _share(context, i18n, song),
          icon: const Icon(Icons.ios_share),
          iconSize: context.rpx(46),
          color: Colors.white,
        ),
      ],
    );
  }

  /// 「歌曲 / 歌词」两个 tab，选中那条下面一道白线（微信就是这两颗字）
  Widget _tabs(BuildContext context, AppI18n i18n) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: <Widget>[
      _tabItem(context, i18n.t('lingting.playerTabSong'), _PlayerTab.song),
      SizedBox(width: context.rpx(56)),
      _tabItem(context, i18n.t('lingting.playerTabLyric'), _PlayerTab.lyric),
    ],
  );

  Widget _tabItem(BuildContext context, String label, _PlayerTab tab) {
    final active = _tab == tab;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _goToTab(tab),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: context.rpx(30),
              color: active ? Colors.white : Colors.white60,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          SizedBox(height: context.rpx(8)),
          Container(
            width: context.rpx(40),
            height: context.rpx(5),
            decoration: BoxDecoration(
              color: active ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(context.rpx(3)),
            ),
          ),
        ],
      ),
    );
  }

  /// 点顶栏那两个 tab → 页面也滑过去（不然是「字变了、内容没变」）
  void _goToTab(_PlayerTab tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    if (_pages.hasClients) {
      _pages.animateToPage(
        tab.index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  /// 歌名 / 歌手 / 当前这一句歌词（左对齐，微信是这么排的）
  Widget _songLine(
    BuildContext context,
    AppI18n i18n,
    LingtingLyric? lyric,
    LingtingPlayerState state,
    LingtingSong song,
  ) {
    final current = lyric == null ? '' : lyric.lineAt(state.position);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        context.rpx(40),
        context.rpx(20),
        context.rpx(40),
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            song.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.rpx(40),
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: context.rpx(10)),
          Text(
            song.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: context.rpx(26), color: Colors.white70),
          ),
          SizedBox(height: context.rpx(12)),
          Text(
            current,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: context.rpx(28), color: Colors.white),
          ),
        ],
      ),
    );
  }

  /// 操作那一行：下载 + 更多（微信还有「喜欢」和「加入歌单」，我们没有收藏
  /// 那一套，就不摆出来占地方）
  Widget _actionsRow(BuildContext context, AppI18n i18n, LingtingSong song) {
    final downloads = ref.watch(lingtingDownloadsProvider);
    final status = downloads.statusOf(song.songId);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.rpx(30),
        context.rpx(18),
        context.rpx(30),
        0,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          _iconAction(
            context,
            tooltip: i18n.t(
              status == LingtingDownloadStatus.done
                  ? 'lingting.downloaded'
                  : 'lingting.download',
            ),
            onTap: () => _download(i18n, song),
            child: switch (status) {
              LingtingDownloadStatus.downloading => SizedBox(
                width: context.rpx(46),
                height: context.rpx(46),
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    CircularProgressIndicator(
                      value: downloads.progressOf(song.songId) == 0
                          ? null
                          : downloads.progressOf(song.songId),
                      strokeWidth: context.rpx(3),
                      color: Colors.white,
                      backgroundColor: const Color(0x33FFFFFF),
                    ),
                  ],
                ),
              ),
              LingtingDownloadStatus.done => Icon(
                Icons.download_done,
                size: context.rpx(44),
                color: AppColors.wechatGreen,
              ),
              _ => Icon(
                Icons.download_outlined,
                size: context.rpx(44),
                color: Colors.white,
              ),
            },
          ),
          _iconAction(
            context,
            tooltip: i18n.t('lingting.more'),
            onTap: () => _openMore(context, i18n, song),
            child: Icon(
              Icons.more_vert,
              size: context.rpx(44),
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconAction(
    BuildContext context, {
    required String tooltip,
    required VoidCallback onTap,
    required Widget child,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    iconSize: context.rpx(44),
    padding: EdgeInsets.all(context.rpx(12)),
    constraints: const BoxConstraints(),
    icon: child,
  );

  /// 下载（下好了再点就什么都不做；失败给一句提示，再点一次是重试）
  Future<void> _download(AppI18n i18n, LingtingSong song) async {
    final status = ref.read(lingtingDownloadsProvider).statusOf(song.songId);
    if (status == LingtingDownloadStatus.done ||
        status == LingtingDownloadStatus.downloading) {
      return;
    }
    try {
      await ref.read(lingtingDownloadsProvider.notifier).download(song);
      if (mounted) noticeBus.toast(i18n.t('lingting.downloaded'));
    } on Object catch (error) {
      // 把原因也摆出来：下载链路上「断了 / 服务端不理 / 没权限」三种情况
      // 的提示一样的话，看屏幕根本分不出是哪一种（日志里也有一份）
      if (mounted) {
        noticeBus.toast(
          '${i18n.t('lingting.downloadFailed')}：${_reasonOf(error)}',
        );
      }
    }
  }

  /// 失败原因截一小段（异常那串 toString 有时是一大段，取第一行、限长）
  static String _reasonOf(Object error) {
    final text = error.toString().split('\n').first.trim();
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }

  /// 「更多」：查看歌手 / 查看专辑 / 复制歌词（微信还有「定时关闭」，我们没有）
  void _openMore(BuildContext context, AppI18n i18n, LingtingSong song) {
    showAppSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.rpx(20)),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: context.rpx(30)),
          child: Row(
            children: <Widget>[
              _sheetItem(
                context,
                icon: Icons.person_outline,
                label: i18n.t('lingting.viewSinger'),
                enabled: song.singerId > 0,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.push(
                    '${AppRoutes.lingtingSinger}?id=${song.singerId}',
                  );
                },
              ),
              _sheetItem(
                context,
                icon: Icons.album_outlined,
                label: i18n.t('lingting.viewAlbum'),
                enabled: song.albumId > 0,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.push('${AppRoutes.lingtingAlbum}?id=${song.albumId}');
                },
              ),
              _sheetItem(
                context,
                icon: Icons.copy_all_outlined,
                label: i18n.t('lingting.copyLyric'),
                enabled: true,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _copyLyric(i18n);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) => Expanded(
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Column(
        children: <Widget>[
          Icon(
            icon,
            size: context.rpx(52),
            color: enabled ? AppColors.text000 : AppColors.chevron,
          ),
          SizedBox(height: context.rpx(16)),
          Text(
            label,
            style: TextStyle(
              fontSize: context.rpx(26),
              color: enabled ? AppColors.text000 : AppColors.chevron,
            ),
          ),
        ],
      ),
    ),
  );

  /// 复制歌词（有时间轴就按行拼，纯文本就原样）
  Future<void> _copyLyric(AppI18n i18n) async {
    final lyric = ref.read(lingtingLyricProvider).value ?? LingtingLyric.empty;
    if (lyric.isEmpty) {
      noticeBus.toast(i18n.t('lingting.noLyric'));
      return;
    }
    await Clipboard.setData(ClipboardData(text: lyric.fullText));
    if (mounted) noticeBus.toast(i18n.t('lingting.lyricCopied'));
  }

  /// 分享：选人（复用聊天那套转发选择器）→ 发一张**音乐卡片**出去。
  ///
  /// 以前发的是一行「《歌名》- 歌手 + 链接」的文本，现在发 `type: 'lingting'`
  /// 的卡片消息：对方点一下就直接进灵听播放页开播（见 `lingting_card.dart`）。
  Future<void> _share(
    BuildContext context,
    AppI18n i18n,
    LingtingSong song,
  ) async {
    final targets = await showForwardPicker(context, excludeId: '');
    if (targets == null || targets.isEmpty || !mounted) return;

    final me = ref.read(sessionStoreProvider).user;
    // 没登录态就发不出去（正常情况下进不来这一页，兜一下）
    if (me == null) return;
    final sender = ref.read(messageSenderProvider);
    final card = MusicCard.fromSong(song);
    var sent = 0;
    for (final target in targets) {
      try {
        final result = await sender.sendMusicCard(
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
        debugPrint('[灵听] 分享失败（${target.name}）：$error');
      }
    }
    if (!mounted) return;
    noticeBus.toast(
      sent == 0
          ? i18n.t('lingting.shareFailed')
          : i18n.t('lingting.sharedCount', <String, String>{'count': '$sent'}),
    );
  }

  Widget _progress(BuildContext context, LingtingPlayerState state) {
    final duration = state.duration.inMilliseconds <= 0
        ? 1.0
        : state.duration.inMilliseconds.toDouble();
    final value = (_dragging ?? state.position.inMilliseconds.toDouble()).clamp(
      0.0,
      duration,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.rpx(50),
        context.rpx(20),
        context.rpx(50),
        0,
      ),
      child: Column(
        children: <Widget>[
          SliderTheme(
            data: SliderThemeData(
              trackHeight: context.rpx(4),
              activeTrackColor: AppColors.wechatGreen,
              inactiveTrackColor: const Color(0x33FFFFFF),
              thumbColor: Colors.white,
              overlayColor: const Color(0x33FFFFFF),
              thumbShape: RoundSliderThumbShape(
                enabledThumbRadius: context.rpx(9),
              ),
              overlayShape: RoundSliderOverlayShape(
                overlayRadius: context.rpx(20),
              ),
            ),
            child: Slider(
              value: value,
              max: duration,
              onChanged: (next) => setState(() => _dragging = next),
              onChangeEnd: (next) {
                setState(() => _dragging = null);
                ref
                    .read(lingtingPlayerProvider.notifier)
                    .seek(Duration(milliseconds: next.round()));
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.rpx(12)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  _format(Duration(milliseconds: value.round())),
                  style: TextStyle(
                    fontSize: context.rpx(22),
                    color: Colors.white54,
                  ),
                ),
                Text(
                  _format(state.duration),
                  style: TextStyle(
                    fontSize: context.rpx(22),
                    color: Colors.white54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(
    BuildContext context,
    AppI18n i18n,
    LingtingPlayerState state,
  ) {
    final notifier = ref.read(lingtingPlayerProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        IconButton(
          tooltip: _modeLabel(i18n, state.mode),
          onPressed: notifier.cycleMode,
          iconSize: context.rpx(48),
          color: Colors.white70,
          icon: Icon(_modeIcon(state.mode)),
        ),
        IconButton(
          tooltip: i18n.t('lingting.previous'),
          onPressed: notifier.previous,
          iconSize: context.rpx(66),
          color: Colors.white,
          icon: const Icon(Icons.skip_previous),
        ),
        IconButton(
          tooltip: i18n.t(state.playing ? 'lingting.pause' : 'lingting.play'),
          onPressed: notifier.toggle,
          iconSize: context.rpx(76),
          color: Colors.white,
          style: IconButton.styleFrom(
            backgroundColor: AppColors.wechatGreen,
            padding: EdgeInsets.all(context.rpx(18)),
          ),
          icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
        ),
        IconButton(
          tooltip: i18n.t('lingting.next'),
          onPressed: () => notifier.next(),
          iconSize: context.rpx(66),
          color: Colors.white,
          icon: const Icon(Icons.skip_next),
        ),
        IconButton(
          tooltip: i18n.t('lingting.playlistTitle'),
          onPressed: () => _openPlaylist(context, i18n),
          iconSize: context.rpx(48),
          color: Colors.white70,
          icon: const Icon(Icons.queue_music),
        ),
      ],
    );
  }

  /// 播放列表（从底部弹出来，当前那首绿色高亮）
  void _openPlaylist(BuildContext context, AppI18n i18n) {
    showAppSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.rpx(24)),
        ),
      ),
      builder: (sheetContext) => Consumer(
        builder: (context, ref, child) {
          final state = ref.watch(lingtingPlayerProvider);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.all(context.rpx(24)),
                  child: Text(
                    i18n.t('lingting.playlistTitle'),
                    style: TextStyle(
                      fontSize: context.rpx(30),
                      color: AppColors.text000,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: state.queue.length,
                    itemBuilder: (context, index) {
                      final item = state.queue[index];
                      final playing = index == state.index;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          playing ? Icons.graphic_eq : Icons.music_note,
                          size: context.rpx(34),
                          color: playing
                              ? AppColors.wechatGreen
                              : AppColors.chevron,
                        ),
                        title: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.rpx(28),
                            color: playing
                                ? AppColors.wechatGreen
                                : AppColors.text000,
                          ),
                        ),
                        subtitle: Text(
                          item.singerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.rpx(22),
                            color: AppColors.text999,
                          ),
                        ),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          ref
                              .read(lingtingPlayerProvider.notifier)
                              .playQueue(
                                state.queue,
                                startIndex: index,
                                source: state.source,
                              );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static IconData _modeIcon(LingtingPlayMode mode) {
    switch (mode) {
      case LingtingPlayMode.order:
        return Icons.repeat;
      case LingtingPlayMode.single:
        return Icons.repeat_one;
      case LingtingPlayMode.shuffle:
        return Icons.shuffle;
    }
  }

  static String _modeLabel(AppI18n i18n, LingtingPlayMode mode) {
    switch (mode) {
      case LingtingPlayMode.order:
        return i18n.t('lingting.modeOrder');
      case LingtingPlayMode.single:
        return i18n.t('lingting.modeSingle');
      case LingtingPlayMode.shuffle:
        return i18n.t('lingting.modeShuffle');
    }
  }

  /// `mm:ss`（超过一小时也不特殊处理：歌不会那么长）
  static String _format(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
