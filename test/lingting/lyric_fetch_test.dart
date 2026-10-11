import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/data/api/lingting/lingting_client.dart';
import 'package:gracelinkim/data/model/lingting/lyric.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词这条路在真机上踩过两个坑，所以单独立一组用例钉住：
///
/// 1. 灵听返回的 `.lrc` 地址是 **COS 上的原文件名**，服务端**不做 URL 转义**，
///    里面带空格、中文、方括号。`Uri.parse`（Dio 内部就是它）会自己转好，
///    **再手工转一遍就完蛋**（`%20` → `%2520`，COS 回 `NoSuchKey`）；
/// 2. `.lrc` 文件是**带 BOM 的 UTF-8**，一行还挂多个时间标签。
///
/// 第一条用**本机 HTTP 服务**端到端验：服务端收到什么路径、客户端能不能把正文
/// 拿回来，都不依赖外网。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 实测回来那条地址（2026-09-23，songId=236 一粒麦子）
  const cosPath = '/music/voice/一粒麥子 (feat. 林婉容) [-yvFQ74Nwjs].lrc';

  const lrcBody =
      '\uFEFF[00:25.000][00:52.000][02:11.000]一粒麥子\r\n'
      '[00:27.000]它若不落在地裡死了\r\n'
      '[00:31.000]不論過了多少時候\r\n';

  group('下载 .lrc（地址没转义 + 带 BOM）', () {
    late HttpServer server;
    late List<String> requested;

    setUp(() async {
      // flutter_test 默认把 HttpClient 换成「一律 400」的假实现，
      // 这一组要真连本机端口，所以显式放行
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LingtingStore.init();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      requested = <String>[];
      server.listen((request) async {
        requested.add(request.uri.toString());
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
          ..add(utf8.encode(lrcBody));
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('原样（未转义）的地址能取回歌词，且只转义一次', () async {
      final client = LingtingClient(baseUrl: 'http://127.0.0.1:${server.port}');
      final text = await client.getPlainText(
        'http://127.0.0.1:${server.port}$cosPath',
      );

      expect(text, contains('一粒麥子'));
      expect(requested, hasLength(1));
      final seen = requested.single;
      expect(seen, contains('%20'), reason: '空格要转义');
      expect(seen, contains('%E4%B8%80%E7%B2%92'), reason: '中文按 UTF-8 转义');
      expect(seen, contains('%5B-yvFQ74Nwjs%5D'), reason: '方括号也要转义');
      // 这条最关键：手工再 encodeComponent 一次就会变成 %2520 / %25E4，COS 直接 NoSuchKey
      expect(seen, isNot(contains('%25%')), reason: '不能二次转义');
      expect(seen, isNot(contains('%2520')), reason: '不能二次转义');
    });
  });

  group('解析回来的歌词', () {
    test('带 BOM、一行多个时间标签的真实歌词能解出时间轴', () {
      final lines = parseLrc(lrcBody);

      // 第一行挂了三个时间标签 → 展开成三行，再按时间排序
      expect(lines.length, 5);
      expect(lines.first.at, const Duration(seconds: 25));
      expect(lines.first.text, '一粒麥子', reason: 'BOM 不该混进正文');
      expect(lines.map((line) => line.text).toSet(), <String>{
        '一粒麥子',
        '它若不落在地裡死了',
        '不論過了多少時候',
      });
      // 时间轴必须单调（界面靠它二分出该高亮哪一行）
      for (var i = 1; i < lines.length; i++) {
        expect(lines[i].at >= lines[i - 1].at, isTrue);
      }
    });

    test('纯文本歌词也会去掉 BOM', () {
      expect(plainLyricLines('\uFEFF第一行\n第二行'), <String>['第一行', '第二行']);
    });

    test('取回来就能算高亮：25 秒落在第一行，24 秒还没开始', () {
      final lyric = LingtingLyric(lines: parseLrc(lrcBody));
      expect(lyric.hasTimeline, isTrue);
      expect(lyric.activeIndex(const Duration(seconds: 25)), 0);
      expect(lyric.activeIndex(const Duration(seconds: 24)), -1);
      // 30 秒时还没到 31 秒那一行 → 停在 27 秒那行（索引 1）
      expect(lyric.activeIndex(const Duration(seconds: 30)), 1);
    });
  });
}
