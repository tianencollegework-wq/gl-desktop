import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/media/image_compressor.dart';
import 'package:gracelinkim/core/media/media_picker.dart';

/// 发图前"该不该压、压完叫什么、压不了怎么办"（S4.4c）。
///
/// 真正的编码由系统原生库做（单测里跑不了），所以这里钉的是**判定与兜底**：
/// 哪张图该压、GIF/WebP 为什么不动、后缀为什么必须跟着实际格式改，以及
/// 「压不了也要把原图发出去」这条底线。
void main() {
  group('该不该压', () {
    test('手机拍的原图（几 MB）要压', () {
      expect(
        shouldCompressImage(
          name: 'IMG_20260920_101010.jpg',
          size: 4 * 1024 * 1024,
        ),
        isTrue,
      );
    });

    test('iPhone 的 HEIC 也要压（压的过程顺手转成 JPEG）', () {
      expect(
        shouldCompressImage(name: 'IMG_0001.HEIC', size: 3 * 1024 * 1024),
        isTrue,
      );
    });

    test('本来就是小图不压（表情、裁切过的截图）', () {
      expect(
        shouldCompressImage(name: 'sticker.png', size: 30 * 1024),
        isFalse,
      );
    });

    test('GIF 一律不动：转成静态格式等于把动图变成一张静帧', () {
      expect(
        shouldCompressImage(name: 'wave.gif', size: 5 * 1024 * 1024),
        isFalse,
      );
    });

    test('WebP 也不动：已经是现代格式，转 JPEG 只会更大，还可能丢透明', () {
      expect(
        shouldCompressImage(name: 'a.webp', size: 5 * 1024 * 1024),
        isFalse,
      );
    });

    test('拿不到体积时按「该压」处理（宁可白压一遍，也别把 8MB 原图传上去）', () {
      expect(shouldCompressImage(name: 'a.jpg', size: 0), isTrue);
    });

    test('大小写不敏感（相机有时候给 .JPG）', () {
      expect(
        shouldCompressImage(name: 'A.GIF', size: 9 * 1024 * 1024),
        isFalse,
      );
    });
  });

  group('压完叫什么', () {
    test('后缀跟着**实际输出的格式**走 —— 服务端按后缀判这是不是图片', () {
      expect(compressedImageName('IMG_0001.HEIC'), 'IMG_0001.jpg');
      expect(compressedImageName('照片.png'), '照片.jpg');
    });

    test('带路径只取文件名（上传的 filename 字段不该有斜杠）', () {
      expect(compressedImageName('/tmp/a/b/photo.jpeg'), 'photo.jpg');
      expect(compressedImageName(r'C:\Users\x\photo.heic'), 'photo.jpg');
    });

    test('没有后缀、名字为空也给得出一个合法名字', () {
      expect(compressedImageName('photo'), 'photo.jpg');
      expect(compressedImageName('.jpg'), 'image.jpg');
      expect(compressedImageName(''), 'image.jpg');
    });

    test('能指定别的输出格式（将来切 WebP 只用改这一处）', () {
      expect(compressedImageName('a.png', extension: 'webp'), 'a.webp');
    });
  });

  group('原生实现：压不了就原样交回（绝不能因为压缩失败发不出图）', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('gracelink-compress');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException catch (_) {
        // Windows 上句柄可能还占着，用后即删失败不影响用例
      }
    });

    File bigFile(String name, {int bytes = 400 * 1024}) =>
        File('${tempDir.path}/$name')
          ..writeAsBytesSync(List<int>.filled(bytes, 7));

    test('单测环境里没有原生编码器 → 抛出来被接住，交回原图', () async {
      // 这条同时钉住"异常必须吞掉"：真机上插件缺失/系统解码失败也是同一条路
      final file = bigFile('IMG_0001.jpg');
      final media = PickedMedia(
        path: file.path,
        name: 'IMG_0001.jpg',
        size: 400 * 1024,
        kind: MediaKind.image,
      );

      final out = await const NativeImageCompressor().compress(media);

      expect(out.path, media.path);
      expect(out.size, media.size);
      expect(out.name, media.name);
    });

    test('文件已经不在了（用户清过缓存）→ 原样交回', () async {
      final media = PickedMedia(
        path: '${tempDir.path}/不存在的图.jpg',
        name: '不存在的图.jpg',
        size: 400 * 1024,
        kind: MediaKind.image,
      );

      final out = await const NativeImageCompressor().compress(media);

      expect(out.path, media.path);
    });

    test('小图根本不进编码器（避免无谓的画质损失）', () async {
      final file = bigFile('small.png', bytes: 1024);
      final media = PickedMedia(
        path: file.path,
        name: 'small.png',
        size: 1024,
        kind: MediaKind.image,
      );

      final out = await const NativeImageCompressor().compress(media);

      expect(out.path, media.path);
    });

    test('视频 / 文件不碰（视频压缩是另一件事，见 CLI）', () async {
      final file = bigFile('clip.mp4', bytes: 1024 * 1024);
      final video = PickedMedia(
        path: file.path,
        name: 'clip.mp4',
        size: 1024 * 1024,
        kind: MediaKind.video,
      );

      final out = await const NativeImageCompressor().compress(video);

      expect(out.path, video.path);
      expect(out.kind, MediaKind.video);
    });

    test('Noop 原样交回（桌面端 / 测试用）', () async {
      const media = PickedMedia(
        path: '/tmp/a.jpg',
        name: 'a.jpg',
        size: 9 * 1024 * 1024,
        kind: MediaKind.image,
      );

      final out = await const NoopImageCompressor().compress(media);

      expect(out.path, media.path);
      expect(out.size, media.size);
    });
  });
}
