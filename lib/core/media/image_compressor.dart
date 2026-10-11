import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/uuid.dart';
import 'media_picker.dart';

/// 发图之前先在本地把图压小（S4.4c）。
///
/// **为什么必须有这一层**：手机拍出来的原图动辄 4~10MB（还可能是 HEIC），
/// 直接传上去有三个代价 ——
/// 1. 上传慢、费流量，弱网下还会被那 10 秒的请求超时打断；
/// 2. 存到服务器上就是几十 MB 的相册，磁盘越用越紧；
/// 3. 对方（和网页端）加载一张图要等好几秒。
///
/// 压完之后一张聊天图通常在 **150~350KB**（微信那个量级），肉眼几乎看不出差别。
///
/// ### 三个刻意的选择
///
/// * **输出 JPEG**：兼容性最好的一条路（Flutter、网页、老安卓 WebView、iOS 13 全认），
///   照片的压缩率也够用。WebP 同质量还能再小 25~35%，但那要求两端都新 ——
///   而"限长边 + 限质量"这一档的收益是**十倍量级**，先把这个拿到手。
/// * **`keepExif: false` + `autoCorrectionAngle: true`**：一边把 GPS 之类的元数据丢掉，
///   一边把 EXIF 里的方向**转进像素**（否则竖向拍的照片会躺倒）。
///   两者必须成对：只丢 EXIF 不转像素 = 照片躺倒；转像素还留着方向标签 =
///   服务端再转一次，照样躺倒。
/// * **后缀跟着实际格式改**：服务端是按**上传文件的后缀**判断"这是不是图片"的，
///   压成 JPEG 却还叫 `.heic` / `.png` 的话，图片会被当成普通文件发出去（真会踩）。
///
/// 抽成接口的理由与 `MediaPicker` / `CallKeepAlive` 一样：真机能力（原生解码器）
/// 在单测里跑不了，而"哪张图该压、压完叫什么"这些判断必须能钉住。
abstract interface class ImageCompressor {
  /// 压不了（不是图片 / 本来就是小图 / 平台不支持 / 出错）就**原样返回** ——
  /// 发图绝不能因为压缩失败而失败。
  Future<PickedMedia> compress(PickedMedia media);
}

/// 聊天图的目标长边（像素）。
///
/// 插件给的是 `minWidth/minHeight`（"不比这个小"），所以竖图最终长边会按比例大一些
/// （3:4 的照片 ≈ 1280×1707）。这个量级与微信发出去的图相当：1MP 上下，
/// JPEG q80 大概 150~350KB。
const int chatImageMinEdge = 1280;

/// JPEG 质量。75~85 是肉眼几乎无损的区间，80 是各家聊天 App 的常见取值。
const int chatImageQuality = 80;

/// 小于这个大小（字节）就**不压**：本来就是小图（表情、截图裁切），
/// 再编一遍只会掉画质，还可能压完更大。
const int imageCompressMinBytes = 200 * 1024;

/// 这些后缀**不动**：GIF 一动就把动图变成一张静帧（`flutter_image_compress`
/// 只会输出静态 JPEG/PNG/WebP），而表情/动图消息正是靠它。
/// SVG 压根不是位图，交回服务端按文件走。
const Set<String> imageCompressSkipExtensions = <String>{
  'gif',
  'svg',
  'webp', // 已经是现代格式了，再转 JPEG 只会变大（而且可能丢透明）
};

/// 这张图要不要压（**纯逻辑**，好单测）。
///
/// [size] 拿不到时传 0 → 按"该压"处理（宁可白压一遍，也别把 8MB 的原图直接传上去）。
bool shouldCompressImage({required String name, required int size}) {
  if (imageCompressSkipExtensions.contains(imageExtensionOf(name))) {
    return false;
  }
  if (size > 0 && size <= imageCompressMinBytes) {
    return false;
  }
  return true;
}

/// `photo.JPG` → `jpg`；没有后缀就是空串
String imageExtensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// 去掉后缀的文件名（`a/b/photo.jpg` → `photo`）
String imageBaseNameOf(String name) {
  final slash = name.lastIndexOf('/');
  final leaf = slash >= 0 ? name.substring(slash + 1) : name;
  final backslash = leaf.lastIndexOf(r'\');
  final bare = backslash >= 0 ? leaf.substring(backslash + 1) : leaf;
  final dot = bare.lastIndexOf('.');
  // `dot == 0` 是「只有后缀没有名字」（`.jpg` 这种隐藏文件）→ 交给下面兜底成 image
  final base = dot > 0 ? bare.substring(0, dot) : (dot == 0 ? '' : bare);
  return base.isEmpty ? 'image' : base;
}

/// 压完之后叫什么：**后缀必须是实际输出的格式**（服务端按后缀判类型）。
String compressedImageName(String sourceName, {String extension = 'jpg'}) =>
    '${imageBaseNameOf(sourceName)}.$extension';

/// 真机实现：走系统原生编码器。
class NativeImageCompressor implements ImageCompressor {
  const NativeImageCompressor();

  @override
  Future<PickedMedia> compress(PickedMedia media) async {
    if (media.kind != MediaKind.image) return media;
    if (!shouldCompressImage(name: media.name, size: media.size)) return media;
    final source = media.localPath;
    if (source.isEmpty || !File(source).existsSync()) return media;

    try {
      final target = <String>[
        Directory.systemTemp.path,
        'chat_${uuidV4()}.jpg',
      ].join(Platform.pathSeparator);
      final output = await FlutterImageCompress.compressAndGetFile(
        source,
        target,
        minWidth: chatImageMinEdge,
        minHeight: chatImageMinEdge,
        quality: chatImageQuality,
        format: CompressFormat.jpeg,
        // 方向烤进像素 + 丢掉 EXIF（GPS/机身信息），理由见文件头
        keepExif: false,
        autoCorrectionAngle: true,
      );
      if (output == null) return media;

      final size = await File(output.path).length();
      // 压完反而更大（极小图、已经压过一遍的图）：宁可发原图
      if (size <= 0 || size >= media.size) return media;

      debugPrint(
        '[图片] 压缩：${media.size} → $size B（${media.name} → '
        '${compressedImageName(media.name)}）',
      );
      return PickedMedia(
        path: output.path,
        name: compressedImageName(media.name),
        size: size,
        kind: media.kind,
      );
    } on Object catch (error) {
      // 压不了就按原图发，绝不因为压缩失败而发不出图
      debugPrint('[图片] 压缩失败，按原图发送：$error');
      return media;
    }
  }
}

/// 不压（测试、桌面端、以及"我自己想看看原图效果"的时候）
class NoopImageCompressor implements ImageCompressor {
  const NoopImageCompressor();

  @override
  Future<PickedMedia> compress(PickedMedia media) async => media;
}

/// 只有安卓/iOS 才有原生编码器
final imageCompressorProvider = Provider<ImageCompressor>((ref) {
  if (Platform.isAndroid || Platform.isIOS) {
    return const NativeImageCompressor();
  }
  return const NoopImageCompressor();
});
