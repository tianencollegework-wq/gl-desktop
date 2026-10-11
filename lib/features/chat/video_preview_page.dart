import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/media/media_saver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/util/media_format.dart';

/// 视频播放页（老端 `pages/message/video.vue`）。
///
/// 老端那页：全屏黑底 + `<video controls autoplay>` + 两个按钮
/// （「保存到本地」`chat.saveLocal`、「关闭」`common.close`），返回键文案是「关闭视频」。
/// 新端一样，只是控件得自己画（`video_player` 不带控件）：点画面暂停/继续 + 一条可拖动进度条。
///
/// **只能在真机上验**：`video_player` 是平台插件，组件测试里 `initialize()` 会失败，
/// 页面会落到「播放失败」那一档（有单测固定这个分支，至少保证不白屏、不崩）。
class VideoPreviewPage extends ConsumerStatefulWidget {
  const VideoPreviewPage({super.key, required this.url, this.fileName = ''});

  final String url;

  /// 保存到相册时用的文件名（消息里的 `fileName`，没有就从地址里猜）
  final String fileName;

  @override
  ConsumerState<VideoPreviewPage> createState() => _VideoPreviewPageState();
}

class _VideoPreviewPageState extends ConsumerState<VideoPreviewPage> {
  VideoPlayerController? _controller;
  Object? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (widget.url.isEmpty) {
      setState(() => _error = '空的视频地址');
      return;
    }
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await controller.initialize();
      await controller.play();
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      setState(() {
        _controller = controller;
        _error = null;
      });
    } on Object catch (error) {
      debugPrint('[视频] 打开失败：$error');
      // 先把错误画出来，再去收拾播放器
      if (mounted) setState(() => _error = error);
      // **千万别 await 这个 dispose**：播放器初始化失败时 `create()` 没跑完，
      // `dispose()` 会等一个永远不完成的 Completer——曾经整页卡在转圈上
      // （组件测试当场抓到：只找到「关闭」按钮，错误文案永远不出现）。
      if (controller != null) unawaited(controller.dispose());
    }
  }

  void _retry() {
    setState(() => _error = null);
    unawaited(_open());
  }

  bool get _playing => _controller?.value.isPlaying ?? false;

  void _toggle() {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      if (controller.value.isPlaying) {
        unawaited(controller.pause());
      } else {
        unawaited(controller.play());
      }
    });
  }

  /// 保存到本地（老端 `download()`：先 `uni.downloadFile` 再 `saveVideoToPhotosAlbum`）
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final i18n = ref.read(appI18nProvider);
    try {
      await ref
          .read(mediaSaverProvider)
          .saveVideoToGallery(
            widget.url,
            fileName: widget.fileName.isEmpty
                ? fileNameFromUrl(widget.url)
                : widget.fileName,
          );
      // 桌面上存的是下载目录、没有相册，提示语跟着平台换（见 savedMediaToastKey）
      if (mounted) noticeBus.toast(i18n.t(savedMediaToastKey()));
    } on Object catch (error) {
      // 老端这条链路失败时什么都不说（`saveVideoToPhotosAlbum` 没写 fail 回调），
      // 用户点了保存却不知道成没成——新端照旧端的成功提示，失败也说一句。
      debugPrint('[视频] 保存失败：$error');
      if (mounted) noticeBus.toast(i18n.t('network.error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                onTap: _error == null ? _toggle : _retry,
                child: Center(
                  child: _error != null
                      ? _errorBox(context, i18n)
                      : controller == null
                      ? const CircularProgressIndicator()
                      : AspectRatio(
                          aspectRatio: controller.value.aspectRatio <= 0
                              ? 16 / 9
                              : controller.value.aspectRatio,
                          child: Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              VideoPlayer(controller),
                              if (!_playing)
                                Icon(
                                  Icons.play_circle_outline,
                                  size: context.rpx(120),
                                  color: AppColors.white,
                                ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
            // 老端导航栏上的「关闭视频」
            Positioned(
              left: 0,
              top: 0,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(
                  Icons.arrow_back_ios_new,
                  size: 16,
                  color: AppColors.white,
                ),
                label: Text(
                  i18n.t('chat.closeVideo'),
                  style: const TextStyle(color: AppColors.white),
                ),
              ),
            ),
            if (controller != null)
              Positioned(
                left: context.rpx(30),
                right: context.rpx(30),
                bottom: context.rpx(140),
                child: VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: AppColors.brand,
                    bufferedColor: Color(0x66FFFFFF),
                    backgroundColor: Color(0x33FFFFFF),
                  ),
                ),
              ),
            Positioned(
              right: context.rpx(30),
              bottom: context.rpx(30),
              child: Row(
                children: <Widget>[
                  _button(
                    context,
                    label: i18n.t('chat.saveLocal'),
                    onTap: _saving ? null : () => unawaited(_save()),
                  ),
                  SizedBox(width: context.rpx(20)),
                  _button(
                    context,
                    label: i18n.t('common.close'),
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _button(
    BuildContext context, {
    required String label,
    required VoidCallback? onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(28),
        vertical: context.rpx(16),
      ),
      margin: EdgeInsets.only(bottom: context.bottomSafeHeight),
      decoration: BoxDecoration(
        color: const Color(0x33FFFFFF),
        borderRadius: BorderRadius.circular(context.rpx(40)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: context.rpx(26), color: AppColors.white),
      ),
    ),
  );

  /// 老端对资源加载失败没有任何界面（就是一片黑）；新端给一句提示 + 点一下重试
  Widget _errorBox(BuildContext context, AppI18n i18n) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(
        Icons.videocam_off_outlined,
        size: context.rpx(90),
        color: AppColors.text999,
      ),
      SizedBox(height: context.rpx(20)),
      Text(
        i18n.t('network.error'),
        style: TextStyle(fontSize: context.rpx(28), color: AppColors.white),
      ),
    ],
  );
}
