import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/media/media_saver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/util/media_format.dart';
import 'widgets/media/media_image.dart';

/// 图片/动态表情预览（老端 `mixins/chat.js::showImgs` 里的 `uni.previewImage`）。
///
/// 老端那一手很有用：点任意一张图，会把**当前列表里所有图片和表情**都收进去，
/// 然后定位到点的这张——左右滑就能看完整条聊天记录里的图。
/// 这里保持一致（[urls] 由聊天页收集，[index] 是点中的那张）。
///
/// 保存到相册是 S4.6 补的：老端靠 `uni.previewImage` 自带的菜单（APP 上长按出菜单），
/// Flutter 没有等价物，所以**显式给一个按钮**——不然“怎么存图”要靠猜。
class ImagePreviewPage extends ConsumerStatefulWidget {
  const ImagePreviewPage({super.key, required this.urls, required this.index});

  final List<String> urls;
  final int index;

  /// 聊天页收集图片用的口径（老端只收 `image` 与 `emoji` 两种）
  static bool isPreviewable(String type) => type == 'image' || type == 'emoji';

  @override
  ConsumerState<ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends ConsumerState<ImagePreviewPage> {
  late final PageController _controller = PageController(
    initialPage: widget.index,
  );
  late int _current = widget.index;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveCurrent() async {
    if (_saving || widget.urls.isEmpty) return;
    final url = widget.urls[_current.clamp(0, widget.urls.length - 1)];
    if (url.isEmpty) return;
    setState(() => _saving = true);
    final i18n = ref.read(appI18nProvider);
    try {
      await ref
          .read(mediaSaverProvider)
          .saveImageToGallery(
            url,
            fileName: fileNameFromUrl(url, fallback: 'image.jpg'),
          );
      // 桌面上存的是下载目录、没有相册，提示语跟着平台换（见 savedMediaToastKey）
      if (mounted) noticeBus.toast(i18n.t(savedMediaToastKey()));
    } on Object catch (error) {
      debugPrint('[图片] 保存失败：$error');
      if (mounted) noticeBus.toast(i18n.t('network.error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          PageView.builder(
            controller: _controller,
            itemCount: widget.urls.length,
            onPageChanged: (index) => setState(() => _current = index),
            itemBuilder: (context, index) => GestureDetector(
              // 点一下退出（老端的预览器也是这么收的）
              onTap: () => Navigator.of(context).maybePop(),
              child: Center(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  // 用 MediaImage 而不是 Image.network：自己刚发出、还在上传的那张
                  // 在本地库里的地址是本机路径，Image.network 会直接裂图
                  child: MediaImage(
                    source: widget.urls[index],
                    fit: BoxFit.contain,
                    errorLabel: 'image',
                  ),
                ),
              ),
            ),
          ),
          if (widget.urls.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: context.bottomSafeHeight + 76,
              child: Center(
                child: Text(
                  '${_current + 1} / ${widget.urls.length}',
                  style: const TextStyle(color: AppColors.white, fontSize: 14),
                ),
              ),
            ),
          Positioned(
            right: context.rpx(30),
            bottom: context.bottomSafeHeight + context.rpx(30),
            child: GestureDetector(
              onTap: _saving ? null : () => _saveCurrent(),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: context.rpx(28),
                  vertical: context.rpx(16),
                ),
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(context.rpx(40)),
                ),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.download_outlined,
                      size: 18,
                      color: AppColors.white,
                    ),
                    SizedBox(width: context.rpx(10)),
                    Text(
                      i18n.t('chat.saveLocal'),
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        color: AppColors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
