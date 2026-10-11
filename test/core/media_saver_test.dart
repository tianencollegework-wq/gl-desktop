import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/media/media_saver.dart';
import 'package:gracelinkim/core/util/media_format.dart';

/// 下载/存相册里「是网络地址还是本机文件」的分流（S4.6）。
///
/// 这条分流很关键：乐观消息（自己刚发出、还在上传的那条）在库里的地址是
/// 本机路径，如果拿去当网址下载，会得到一个 0 字节文件、存到相册的是空图。
void main() {
  group('本机路径识别', () {
    test('file:// 前缀会被去掉', () {
      expect(
        localFilePathOf('file:///storage/emulated/0/a.jpg'),
        '/storage/emulated/0/a.jpg',
      );
    });

    test('已经是路径的原样返回', () {
      expect(localFilePathOf('/tmp/b.png'), '/tmp/b.png');
      expect(localFilePathOf(r'C:\Users\x\c.png'), r'C:\Users\x\c.png');
    });
  });

  group('download 不走网络的情形', () {
    test('本机文件直接返回，不碰临时目录/不发起请求', () async {
      final saver = SystemMediaSaver();
      // 走到 path_provider 或 dio 就会因为平台通道缺失而失败，所以这条能过就说明分流生效
      expect(
        await saver.download('/tmp/local.mp4', fileName: 'ignored.mp4'),
        '/tmp/local.mp4',
      );
      expect(
        await saver.download('file:///tmp/local.mp4', fileName: 'ignored.mp4'),
        '/tmp/local.mp4',
      );
    });
  });
}
