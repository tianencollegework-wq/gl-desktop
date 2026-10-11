import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../core/util/media_format.dart';

/// 聊天里的一张图。
///
/// 为什么要分两种来源：新端是**先把本地文件显示出来再上传**（乐观消息），
/// 所以 `content` 在"刚选完"到"上传成功"之间是本机路径，之后才被服务端地址替换。
/// 老端的 `Image` 组件两种都能吃，Flutter 下必须显式分流，
/// 不然自己刚发的图会是一张裂图。
class MediaImage extends StatelessWidget {
  const MediaImage({
    super.key,
    required this.source,
    this.fit = BoxFit.cover,
    this.errorLabel = 'image',
  });

  final String source;
  final BoxFit fit;

  /// 加载不出来时占位图上显示的类型
  final String errorLabel;

  /// 是不是本地文件（老端的本地路径形如 `/storage/...` 或 `file:///...`）
  static bool isLocal(String source) =>
      source.isNotEmpty && !source.startsWith('http');

  @override
  Widget build(BuildContext context) {
    if (source.isEmpty) return _broken();

    if (isLocal(source)) {
      final file = File(localFilePathOf(source));
      // 文件没了（被系统清了缓存）就直接占位，别让 Image.file 抛到控制台
      if (!file.existsSync()) return _broken();
      return Image.file(
        file,
        fit: fit,
        errorBuilder: (context, error, stack) => _broken(),
      );
    }

    return Image.network(
      source,
      fit: fit,
      errorBuilder: (context, error, stack) => _broken(),
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : const ColoredBox(color: AppColors.gray),
    );
  }

  Widget _broken() => BrokenMediaBox(label: errorLabel, expand: true);
}

/// 图片加载不出来时的占位（不是白屏，也不是一张碎图）
class BrokenMediaBox extends StatelessWidget {
  const BrokenMediaBox({super.key, required this.label, this.expand = false});

  final String label;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final width = expand ? null : math.max(80.0, context.rpx(160));
    final height = expand ? null : context.rpx(160);
    return Container(
      width: width,
      height: height,
      color: AppColors.gray,
      alignment: Alignment.center,
      // 占位可能被塞进很小的盒子（比如没给尺寸的视频封面只有 200×120），
      // 所以让它整体缩放而不是溢出
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.broken_image_outlined,
              size: context.rpx(48),
              color: AppColors.text999,
            ),
            // 老端这里什么都不写；加上类型名，排查"这条消息到底是什么类型"时一眼能看到
            Text(
              '[$label]',
              style: TextStyle(
                fontSize: context.rpx(20),
                color: AppColors.text999,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
