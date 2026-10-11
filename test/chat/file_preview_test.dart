import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/chat/file_preview.dart';

/// 文件/位置「点一下之后干什么」的判断（S4.6）。
///
/// 这几种后缀是老端写死的列表，写错了要么「该文件不支持预览」误伤、要么
/// 下载完打不开，所以逐条钉死。
void main() {
  group('本地预览支持的后缀', () {
    test('pdf 与 office 四种都支持（含大写后缀）', () {
      for (final extension in <String>[
        'pdf',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
      ]) {
        expect(supportsLocalPreview(extension), isTrue, reason: extension);
        expect(supportsLocalPreview(extension.toUpperCase()), isTrue);
      }
    });

    test('图片、压缩包、音视频都不走「本地预览」', () {
      for (final extension in <String>[
        'jpg',
        'png',
        'zip',
        'rar',
        'mp4',
        'txt',
        'apk',
        '',
      ]) {
        expect(supportsLocalPreview(extension), isFalse, reason: extension);
      }
    });

    test('音频判定用的是老端那份（mp3/wav/acc，没有 aac）', () {
      expect(isAudioFile('mp3'), isTrue);
      expect(isAudioFile('wav'), isTrue);
      expect(isAudioFile('acc'), isTrue);
      expect(isAudioFile('MP3'), isTrue);
      // 老端漏了 aac（它写的是 acc），新端照抄，不擅自扩
      expect(isAudioFile('aac'), isFalse);
      expect(isAudioFile('m4a'), isFalse);
    });
  });

  group('地图链接', () {
    test('Android 用 geo: 意图，坐标与标题都在', () {
      final url = mapUrlOf(
        latitude: 31.23,
        longitude: 121.47,
        title: '人民广场',
        target: MapTarget.android,
      );
      expect(url, startsWith('geo:31.23,121.47?q=31.23,121.47('));
      expect(url, contains(Uri.encodeComponent('人民广场')));
    });

    test('iOS 用 maps.apple.com', () {
      expect(
        mapUrlOf(
          latitude: 1.5,
          longitude: 2.5,
          title: 'A',
          target: MapTarget.ios,
        ),
        'https://maps.apple.com/?ll=1.5,2.5&q=A',
      );
    });

    test('其它平台兜到 Google 地图（桌面调试时至少能看）', () {
      expect(
        mapUrlOf(
          latitude: 1.5,
          longitude: 2.5,
          title: 'A',
          target: MapTarget.others,
        ),
        'https://www.google.com/maps/search/?api=1&query=1.5,2.5',
      );
    });

    test('标题里的特殊字符会被编码，不会破坏链接', () {
      final url = mapUrlOf(
        latitude: 0,
        longitude: 0,
        title: '花园 (A&B) #3',
        target: MapTarget.ios,
      );
      // 空格与 `&` 必须转义：`&` 不转义会被当成参数分隔符（`q` 只剩「花园 (A」）
      expect(url, contains('%20'));
      expect(url, contains('%26'));
      expect(Uri.parse(url).queryParameters['q'], '花园 (A&B) #3');
    });

    test('平台→目标枚举的映射', () {
      expect(
        currentMapTarget(isAndroid: true, isIOS: false),
        MapTarget.android,
      );
      expect(currentMapTarget(isAndroid: false, isIOS: true), MapTarget.ios);
      expect(
        currentMapTarget(isAndroid: false, isIOS: false),
        MapTarget.others,
      );
    });
  });

  group('弹层两项的文案 key', () {
    test('与老端 locales 里的 key 对得上', () {
      expect(localPreviewOption.key, 'message.localPreview');
      expect(localPreviewOption.hintKey, 'message.download');
      expect(onlinePreviewOption.key, 'message.onlinePreview');
      expect(onlinePreviewOption.hintKey, 'message.normalFile');
    });
  });
}
