import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/data/api/lingting/lingting_api.dart';
import 'package:gracelinkim/data/api/lingting/lingting_client.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/repo/lingting_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词是**两段式**的：
///
/// * 第一段 `quickLyric` —— 列表/搜索自带的纯文本，不发请求、立刻能显示；
/// * 第二段 `timelineLyric` —— 去 `/v1/music/lyric` 要 `.lrc`（有时间轴），
///   拿到就把界面那份换掉；**同一首歌只问一次**。
///
/// 这两段的必要性来自实测（2026-09-24）：列表里那个 `lyric` 字段是把整首歌用
/// `;` 连成一段的纯文本，而且往往比正文短；真正逐行带时间戳的歌词只在 `.lrc` 上。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late List<String> requested;
  late String lrcBody;
  late _RecordingApi api;
  late _NoLoginRepository repository;

  const plainSnippet = '《敬拜的心》;;词曲：赵治德;我献上一颗敬拜的心;';

  setUp(() async {
    HttpOverrides.global = null; // 这一组要真连本机端口
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LingtingStore.init();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requested = <String>[];
    lrcBody = '[00:18.90]我献上一颗敬拜的心\r\n[00:25.24]指的就是我全所有\r\n';
    server.listen((request) async {
      requested.add(request.uri.toString());
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
        ..add(utf8.encode(lrcBody));
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    api = _RecordingApi(base);
    api.lyricUrlResult = '$base/music/voice/23455.lrc';
    repository = _NoLoginRepository(api);
  });

  tearDown(() => server.close(force: true));

  LingtingSong songWith({String rawLyric = plainSnippet, int id = 23455}) =>
      LingtingSong(
        songId: id,
        name: '敬拜的心',
        singerName: '起初音乐',
        audioUrl: 'https://x/$id.mp3',
        rawLyric: rawLyric,
      );

  test('第一段：列表自带的纯文本立刻拆成逐行歌词，且一个请求都不发', () async {
    final lyric = await repository.quickLyric(songWith());

    expect(lyric.hasTimeline, isFalse);
    expect(lyric.plain.split('\n'), <String>['《敬拜的心》', '词曲：赵治德', '我献上一颗敬拜的心']);
    expect(api.lyricUrlCalls, isEmpty, reason: '第一段不该去要 .lrc');
    expect(requested, isEmpty, reason: '第一段不该发任何请求');
  });

  test('第二段：拿到 .lrc 就解出时间轴，并缓存住（再要一次不再发请求）', () async {
    final song = songWith();
    await repository.quickLyric(song);

    final first = await repository.timelineLyric(song);
    expect(first.hasTimeline, isTrue);
    expect(first.lines.length, 2);
    expect(first.lines.first.text, '我献上一颗敬拜的心');
    expect(api.lyricUrlCalls, <int>[23455]);

    final second = await repository.timelineLyric(song);
    expect(second.hasTimeline, isTrue);
    expect(api.lyricUrlCalls, <int>[23455], reason: '缓存过的别再问');
    expect(requested, hasLength(1), reason: '.lrc 也只下一次');
  });

  test('两段一起走：最终给的是有时间轴的那份', () async {
    final lyric = await repository.lyric(songWith());
    expect(lyric.hasTimeline, isTrue);
    expect(lyric.lineAt(const Duration(seconds: 20)), '我献上一颗敬拜的心');
  });

  test('服务端没给歌词地址 → 只问一次，界面继续用第一段那份', () async {
    api.lyricUrlResult = '';
    final song = songWith();
    await repository.quickLyric(song);

    expect((await repository.timelineLyric(song)).hasTimeline, isFalse);
    expect((await repository.timelineLyric(song)).hasTimeline, isFalse);
    expect(api.lyricUrlCalls, <int>[23455], reason: '「没有」也要记住，不然每次进播放页都要问一遍');

    final lyric = await repository.lyric(song);
    expect(lyric.hasTimeline, isFalse);
    expect(lyric.plain, contains('我献上一颗敬拜的心'), reason: '退回第一段那份');
  });

  test('.lrc 里其实没有时间轴（正文）→ 不当成时间轴，也不覆盖缓存', () async {
    lrcBody = '这句歌词没有时间标签\r\n第二行也没有\r\n';
    final song = songWith();
    await repository.quickLyric(song);

    expect((await repository.timelineLyric(song)).hasTimeline, isFalse);
    final lyric = await repository.lyric(song);
    expect(lyric.hasTimeline, isFalse);
    expect(lyric.plain.split('\n').first, '《敬拜的心》');
  });

  test('下载失败不影响：当作没有时间轴（歌词是锦上添花，不能把播放页弄成错误态）', () async {
    await server.close(force: true); // 端口关掉 → 连接失败
    final song = songWith();
    await repository.quickLyric(song);

    expect((await repository.timelineLyric(song)).hasTimeline, isFalse);
    expect((await repository.lyric(song)).plain, contains('《敬拜的心》'));
  });

  test('列表已经给了时间轴（详情类接口的形态）时，不必再去问 .lrc', () async {
    final song = songWith(rawLyric: '[00:10.00]带时间轴的正文');
    final lyric = await repository.lyric(song);
    expect(lyric.hasTimeline, isTrue);
    expect(api.lyricUrlCalls, isEmpty);
  });
}

/// 只记「歌词地址被要了几次」，别的接口这一组用不到
class _RecordingApi extends LingtingApi {
  _RecordingApi(String baseUrl) : super(LingtingClient(baseUrl: baseUrl));

  final List<int> lyricUrlCalls = <int>[];

  /// 歌词接口返回的地址（用例直接摆；空串 = 服务端没有这首歌的歌词）
  String lyricUrlResult = '';

  @override
  Future<String> lyricUrl(int songId) async {
    lyricUrlCalls.add(songId);
    return lyricUrlResult;
  }
}

/// 把匿名登录与 401 重登换掉：用例里除了本机那个 HTTP 服务，不许再有真网络
class _NoLoginRepository extends LingtingRepository {
  _NoLoginRepository(LingtingApi api) : super(api, LingtingStore.instance);

  @override
  Future<void> ensureSession({bool force = false}) async {}

  @override
  Future<T> guarded<T>(Future<T> Function() action) => action();
}
