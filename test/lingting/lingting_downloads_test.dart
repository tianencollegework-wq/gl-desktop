import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/data/model/lingting/download.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/repo/lingting_repository.dart';
import 'package:gracelinkim/domain/lingting/lingting_downloads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_lingting.dart';

/// 「下载」这条路不依赖外网：本机起一个 HTTP 服务喂字节，落盘落到临时目录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('下载状态', () {
    const idle = LingtingDownloads.empty;

    test('没下过 → none；在下 → downloading；下好 → done；失败 → failed', () {
      expect(idle.statusOf(1), LingtingDownloadStatus.none);

      final downloading = idle.copyWith(progress: <int, double>{1: 0.4});
      expect(downloading.statusOf(1), LingtingDownloadStatus.downloading);
      expect(downloading.progressOf(1), 0.4);

      final done = idle.copyWith(
        items: <int, LingtingDownload>{
          1: const LingtingDownload(path: '/tmp/1.mp3', name: '一粒麦子'),
        },
      );
      expect(done.statusOf(1), LingtingDownloadStatus.done);
      expect(done.pathOf(1), '/tmp/1.mp3');
      // 下载列表要用到的两样：能拼成一首可播的歌、歌名就在本机（离线也列得出来）
      expect(done.songs.single.songId, 1);
      expect(done.songs.single.name, '一粒麦子');

      final failed = idle.copyWith(failed: <int>{1});
      expect(failed.statusOf(1), LingtingDownloadStatus.failed);
    });

    test('「在下」压过「已下好」——重下时状态不会提前变成已完成', () {
      final state = LingtingDownloads(
        progress: <int, double>{1: 0.1},
        items: <int, LingtingDownload>{
          1: const LingtingDownload(path: '/tmp/1.mp3'),
        },
      );
      expect(state.statusOf(1), LingtingDownloadStatus.downloading);
    });

    test('同内容的两个状态相等（provider 靠它决定要不要重建界面）', () {
      expect(
        LingtingDownloads(progress: <int, double>{1: 0.5}),
        LingtingDownloads(progress: <int, double>{1: 0.5}),
      );
      expect(
        LingtingDownloads(progress: <int, double>{1: 0.5}),
        isNot(LingtingDownloads(progress: <int, double>{1: 0.6})),
      );
    });
  });

  group('本机清单（歌曲 id → 已下载那一份）', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LingtingStore.init();
    });

    test('存进去再读回来是同一份 —— 键要转成字符串才能 json.encode', () async {
      // 这个用例钉的是一个整轮的真机 bug：`json.encode(<int, String>{...})` 会抛
      // 「Converting object to an encodable object failed: _Map len:1」，
      // 于是文件已经下好了、下载却一直显示失败。
      const saved = <int, LingtingDownload>{
        236: LingtingDownload(
          path: '/data/lingting/236.mp3',
          url: 'https://x/236.mp3',
          name: '一粒麦子',
          singer: '小羊诗歌',
          cover: 'https://x/cover.jpg',
        ),
        9: LingtingDownload(path: '/data/lingting/9.mp3'),
      };
      await LingtingStore.instance.saveDownloads(saved);
      expect(LingtingStore.instance.downloads, saved);
    });

    test('老记录（只存了一行路径）也读得回来 —— 不至于把用户下过的歌弄丢', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lingting.downloads': '{"236":"/data/lingting/236.mp3"}',
      });
      await LingtingStore.init();

      final restored = LingtingStore.instance.downloads;
      expect(restored.keys, <int>[236]);
      expect(restored[236]!.path, '/data/lingting/236.mp3');
      expect(restored[236]!.name, isEmpty, reason: '老记录里没有歌名');
    });
  });

  group('老记录补全（只有一行路径的那种）', () {
    late ProviderContainer container;
    late Directory root;
    late FakeLingtingApi api;

    /// 补一条只有路径的记录（就是用户真机上看到 `3866` 的那个样子），
    /// 文件是真存在的 —— `_pruneMissing` 会把「记录里有、盘上没了」的剔掉
    Future<void> seed(String path) async {
      File(path).writeAsStringSync('mp3');
      await LingtingStore.instance.saveDownloads(<int, LingtingDownload>{
        3866: LingtingDownload(path: path),
      });
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LingtingStore.init();
      root = await Directory.systemTemp.createTemp('lingting-enrich');
      api = FakeLingtingApi();
      api.detailResult = const LingtingSong(
        songId: 3866,
        name: '敬拜的心',
        singerName: '约书亚乐团',
        albumName: '直到世界尽头',
        cover: 'https://x/3866.jpg',
        audioUrl: 'https://x/3866.mp3',
      );
      container = ProviderContainer(
        overrides: [
          lingtingRepositoryProvider.overrideWithValue(
            FakeLingtingRepository(api),
          ),
        ],
      );
    });

    tearDown(() {
      container.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('缺歌名/封面/直链的老记录会按 songId 补全，并写回本机清单', () async {
      await seed('${root.path}/3866.mp3');
      final before = container.read(lingtingDownloadsProvider).songs.single;
      expect(before.name, '3866', reason: '补之前只能拿 id 当歌名（用户截图里就是它）');
      expect(before.audioUrl, isEmpty, reason: '没有直链 —— 所以才点一下没反应');

      await container.read(lingtingDownloadsProvider.notifier).enrichMissing();

      final song = container.read(lingtingDownloadsProvider).songs.single;
      expect(song.name, '敬拜的心');
      expect(song.singerName, '约书亚乐团');
      expect(song.cover, 'https://x/3866.jpg');
      expect(song.audioUrl, 'https://x/3866.mp3', reason: '有直链才进得了播放队列');
      // 本机清单也存下来了：下次进来不用再问一次
      expect(LingtingStore.instance.downloads[3866]!.name, '敬拜的心');
      // 本地那一份路径不动（放的时候还是放本地文件）
      expect(
        container.read(lingtingDownloadsProvider).pathOf(3866),
        endsWith('3866.mp3'),
      );
    });

    test('字段齐全的记录不会再去问接口', () async {
      File('${root.path}/3866.mp3').writeAsStringSync('mp3');
      await LingtingStore.instance.saveDownloads(<int, LingtingDownload>{
        3866: LingtingDownload(
          path: '${root.path}/3866.mp3',
          url: 'https://x/3866.mp3',
          name: '敬拜的心',
          singer: '约书亚乐团',
          cover: 'https://x/3866.jpg',
        ),
      });

      await container.read(lingtingDownloadsProvider.notifier).enrichMissing();

      expect(api.detailCalls, 0);
    });

    test('接口挂了不影响本地那几行（这一页不联网也能用）', () async {
      await seed('${root.path}/3866.mp3');
      api.detailResult = null;
      // 让详情接口直接报错：拿不到就只能维持原样
      container.dispose();
      container = ProviderContainer(
        overrides: [
          lingtingRepositoryProvider.overrideWithValue(_BrokenRepository(api)),
        ],
      );

      await container.read(lingtingDownloadsProvider.notifier).enrichMissing();

      final song = container.read(lingtingDownloadsProvider).songs.single;
      expect(song.songId, 3866);
      expect(song.name, '3866', reason: '补不到就维持原样，不把这一行弄丢');
    });
  });

  group('落盘', () {
    late HttpServer server;
    late Directory root;
    late List<int> payload;

    setUp(() async {
      HttpOverrides.global = null;
      root = await Directory.systemTemp.createTemp('lingting-dl');
      payload = List<int>.generate(240000, (index) => index % 256);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response
          ..statusCode = 200
          ..headers.contentLength = payload.length
          ..add(payload);
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('文件按「歌曲 id.mp3」落盘，内容与源一致，进度会回调', () async {
      final progress = <double>[];
      final target = LingtingSong(
        songId: 236,
        name: '一粒麦子',
        audioUrl: 'http://127.0.0.1:${server.port}/a.mp3',
      );

      final file = await downloadLingtingSong(
        target,
        rootDir: root,
        dio: Dio(),
        onProgress: progress.add,
      );

      expect(file, isNotNull);
      expect(file!.path, endsWith('/236.mp3'));
      expect(await file.readAsBytes(), payload);
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
      // 中间产物不留：`.part` 下完就改名了
      expect(await File('${file.path}.part').exists(), isFalse);
    });

    test('下载失败时不留半个残文件', () async {
      // 端口上没人听 → 连接直接被拒
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close(force: true);

      var threw = false;
      try {
        await downloadLingtingSong(
          LingtingSong(
            songId: 236,
            name: '一粒麦子',
            audioUrl: 'http://127.0.0.1:$port/a.mp3',
          ),
          rootDir: root,
          dio: Dio(BaseOptions(connectTimeout: const Duration(seconds: 3))),
        );
      } on Object {
        threw = true;
      }

      expect(threw, isTrue);
      expect(await File('${root.path}/236.mp3').exists(), isFalse);
      expect(await File('${root.path}/236.mp3.part').exists(), isFalse);
    });
  });

  /// 「卡住 → 掐掉 → 带着 Range 接着下」这条路。
  ///
  /// 真机上的现场（2026-09-25 对着灵听 CDN 实测）：一条连接经常握上手、
  /// 给几 KB 就没声了（一次 0 字节、一次只到 32768 字节），而同一时刻换一条
  /// 带 `Range: bytes=N-` 的连接接着要，一次就把剩下的 13MB 全拿回来了。
  /// 所以这里用一个「一轮只给前面一小截就挂着不动」的假服务端把这个场景钉死。
  group('卡住要掐、断了要接着下', () {
    late Directory root;
    late List<int> payload;

    setUp(() async {
      HttpOverrides.global = null;
      root = await Directory.systemTemp.createTemp('lingting-resume');
      payload = List<int>.generate(300000, (index) => index % 256);
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    LingtingSong songOn(int port) => LingtingSong(
      songId: 236,
      name: '一粒麦子',
      audioUrl: 'http://127.0.0.1:$port/a.mp3',
    );

    /// 从 `Range: bytes=123-` 里取出起点
    int rangeStartOf(String? header) =>
        int.parse(RegExp(r'bytes=(\d+)-').firstMatch(header!)!.group(1)!);

    test('第一条连接卡住 → 掐掉，带着 Range 从断点把剩下的拿完', () async {
      final ranges = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final range = request.headers.value('range');
        ranges.add(range);
        try {
          if (ranges.length == 1) {
            // 第一轮：只给前面 1000 字节就不吭声了（不 close，就这么挂着）
            request.response
              ..statusCode = 200
              ..headers.contentLength = payload.length
              ..add(payload.sublist(0, 100000));
            await request.response.flush();
            return;
          }

          final from = rangeStartOf(range);
          request.response
            ..statusCode = 206
            ..headers.contentLength = payload.length - from
            ..headers.set(
              'content-range',
              'bytes $from-${payload.length - 1}/${payload.length}',
            )
            ..add(payload.sublist(from));
          await request.response.close();
        } on Object {
          // 客户端把连接掐了（正是我们中止卡住那一轮的方式）→ 服务端这边不用管
        }
      });
      addTearDown(() => server.close(force: true));

      final progress = <double>[];
      final file = await downloadLingtingSong(
        songOn(server.port),
        rootDir: root,
        onProgress: progress.add,
        stallTimeout: const Duration(milliseconds: 400),
      );

      expect(file, isNotNull, reason: '第二轮该把剩下的拿完');
      expect(await file!.readAsBytes(), payload, reason: '接起来必须是完整的一首');
      expect(ranges.first, isNull, reason: '第一轮是整份要的');
      expect(ranges, hasLength(2));
      final resumedAt = rangeStartOf(ranges[1]);
      expect(resumedAt, greaterThan(0));
      expect(resumedAt, lessThanOrEqualTo(100000), reason: '从已经下到的地方接着下');
      expect(progress.last, 1.0);
      expect(File('${file.path}.part').existsSync(), isFalse);
    });

    test('服务端不认 Range（回整份）→ 不把旧前缀拼进去，重下一份干净的', () async {
      final requests = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add(request.headers.value('range'));
        try {
          if (requests.length == 1) {
            // 第一轮：给一小截然后挂着（逼出续传）
            request.response
              ..statusCode = 200
              ..headers.contentLength = payload.length
              ..add(payload.sublist(0, 100000));
            await request.response.flush();
            return;
          }
          // 之后一律「整份」（假装这个服务端不认 Range）
          request.response
            ..statusCode = 200
            ..headers.contentLength = payload.length
            ..add(payload);
          await request.response.close();
        } on Object {
          // 同上：客户端掐连接时的报错忽略
        }
      });
      addTearDown(() => server.close(force: true));

      final file = await downloadLingtingSong(
        songOn(server.port),
        rootDir: root,
        stallTimeout: const Duration(milliseconds: 400),
      );

      expect(file, isNotNull);
      expect(
        await file!.readAsBytes(),
        payload,
        reason: '旧前缀 + 整份拼出来的文件绝不能当成功',
      );
      expect(requests.where((item) => item != null), isNotEmpty);
    });

    test('一直断：抛异常、不留一个看着像下好了的 mp3，但留下断点', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final range = request.headers.value('range');
        try {
          if (range == null) {
            request.response
              ..statusCode = 200
              ..headers.contentLength = payload.length
              ..add(payload.sublist(0, 100000));
          } else {
            final from = rangeStartOf(range);
            final end = (from + 100000).clamp(0, payload.length);
            request.response
              ..statusCode = 206
              ..headers.contentLength = payload.length - from
              ..headers.set(
                'content-range',
                'bytes $from-${payload.length - 1}/${payload.length}',
              )
              ..add(payload.sublist(from, end));
          }
          await request.response.flush();
        } on Object {
          // 客户端掐连接时的报错忽略（下同）
        }
      });
      addTearDown(() => server.close(force: true));

      var threw = false;
      try {
        await downloadLingtingSong(
          songOn(server.port),
          rootDir: root,
          attempts: 2,
          stallTimeout: const Duration(milliseconds: 300),
        );
      } on Object {
        threw = true;
      }

      expect(threw, isTrue);
      expect(await File('${root.path}/236.mp3').exists(), isFalse);
      final part = File('${root.path}/236.mp3.part');
      expect(await part.exists(), isTrue, reason: '断点留着，下次点下载能接着下');
      expect(await part.length(), lessThan(payload.length));
    });
  });
}

/// 详情接口永远失败（断网那种）：补全要安静跳过，不能把已经下好的那几行弄丢
class _BrokenRepository extends FakeLingtingRepository {
  _BrokenRepository(super.fakeApi);

  @override
  Future<LingtingSong> songDetail(int songId) async => throw StateError('断网了');
}
