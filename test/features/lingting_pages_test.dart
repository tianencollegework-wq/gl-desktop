import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/data/model/lingting/home.dart';
import 'package:gracelinkim/data/model/lingting/lyric.dart';
import 'package:gracelinkim/data/model/lingting/search.dart';
import 'package:gracelinkim/data/model/lingting/singer.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/model/lingting/song_sheet.dart';
import 'package:gracelinkim/data/repo/lingting_repository.dart';
import 'package:gracelinkim/domain/lingting/lingting_player.dart';
import 'package:gracelinkim/domain/lingting/lingting_providers.dart';
import 'package:gracelinkim/features/lingting/lingting_home_page.dart';
import 'package:gracelinkim/features/lingting/lingting_player_page.dart';
import 'package:gracelinkim/features/lingting/lingting_search_page.dart';
import 'package:gracelinkim/features/lingting/lingting_sheet_page.dart';
import 'package:gracelinkim/features/lingting/lingting_singer_page.dart';
import 'package:gracelinkim/features/lingting/widgets/lingting_skeleton.dart';
import 'package:gracelinkim/features/lingting/widgets/lingting_spinning_cover.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_lingting.dart';

/// 播放器在这里只要「状态机」就够了，引擎全是空实现
class _FakePlayer extends LingtingPlayerNotifier {
  /// 模拟 `just_audio` 的 `positionStream`：播放中它每秒会来好几帧
  void tick(Duration position) => state = state.copyWith(position: position);

  @override
  Future<Duration?> startEngine(LingtingSong song) async =>
      const Duration(seconds: 180);

  @override
  Future<void> playEngine() async {}

  @override
  Future<void> pauseEngine() async {}

  @override
  Future<void> seekEngine(Duration position) async {}

  @override
  Future<void> stopEngine() async {}

  @override
  Future<void> shutVoiceUp() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late FakeLingtingRepository repository;
  late FakeLingtingApi api;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 语言包的 provider 会读 CredentialStore（`localeProvider`），两份都要初始化
    await CredentialStore.init();
    await LingtingStore.init();
    await AppI18n.load('zh-Hans');
    api = FakeLingtingApi();
    api.homeResult = homeFromResponses(
      daily: <Object>[
        <String, dynamic>{
          'songId': 1,
          'songName': '一粒麦子',
          'singerName': '小羊诗歌',
          'albumName': '一粒麦子',
          'audioLink': 'https://x/1.mp3',
        },
        <String, dynamic>{
          'songId': 2,
          'songName': '通往祢的路',
          'singerName': '赞美之泉',
          'audioLink': 'https://x/2.mp3',
        },
      ],
      hot: <Object>[
        <String, dynamic>{
          'songId': 3,
          'songName': '圣洁主',
          'singerName': 'e麦合唱团',
          'audioLink': 'https://x/3.mp3',
        },
      ],
      sheets: <Object>[
        <String, dynamic>{
          'songSheetId': 122244,
          'songSheetName': '流淌着生命河流',
          'songSheetCoverImage': 'https://x/s.jpg',
        },
      ],
    );
    api.searchResult = LingtingSearchResult.fromMusic(<String, dynamic>{
      'songList': <Object>[
        <String, dynamic>{
          'songId': 23379,
          'songName': '[恩典]',
          'singerName': '起初音乐',
          'audioLink': 'https://x/23379.mp3',
        },
      ],
      'counts': 1,
      'tkeyword': '恩典',
    });
    repository = FakeLingtingRepository(api);
    container = ProviderContainer(
      overrides: [
        lingtingRepositoryProvider.overrideWithValue(repository),
        lingtingPlayerProvider.overrideWith(_FakePlayer.new),
      ],
    );
  });

  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 窄屏（960/3 = 320dp 宽，老手机的宽度，最容易溢出）下跑同一页
  Future<void> pumpNarrow(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(960, 1707);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pump(tester, page);
  }

  /// 滚到某个文案出现（首页是长列表，断言前必须先滚过去）
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
    await tester.pumpAndSettle();
  }

  group('首页', () {
    testWidgets('按服务端数据渲染各区块', (tester) async {
      await pump(tester, const LingtingHomePage());

      // 首屏可见的那几块
      expect(find.text('灵听'), findsOneWidget);
      expect(find.text('每日三十首'), findsOneWidget);
      expect(find.text('一粒麦子'), findsOneWidget);

      // 下面的区块要滚下去才建（ListView 懒建，这本身也是断言的一部分）
      await scrollTo(tester, find.text('热门歌曲'));
      expect(find.text('圣洁主'), findsOneWidget);

      await scrollTo(tester, find.text('推荐歌单'));
      expect(find.text('流淌着生命河流'), findsOneWidget);
    });

    testWidgets('「播放全部」把整块歌塞进队列', (tester) async {
      await pump(tester, const LingtingHomePage());

      // 第一颗「播放全部」= 每日三十首那一块
      await tester.tap(find.text('播放全部').first);
      await tester.pumpAndSettle();

      final state = container.read(lingtingPlayerProvider);
      expect(state.queue.length, 2);
      expect(state.current?.songId, 1);
      expect(state.playing, isTrue);
      expect(state.source, '每日三十首');
    });

    testWidgets('点一首歌直接播那一首（队列是它所在的那一块）', (tester) async {
      await pump(tester, const LingtingHomePage());

      await tester.tap(find.text('通往祢的路'));
      await tester.pumpAndSettle();

      final state = container.read(lingtingPlayerProvider);
      expect(state.current?.songId, 2);
      expect(state.queue.length, 2);
    });

    testWidgets('每日三十首拿不到时（兜底到置顶栏）标题跟着换，不冒充', (tester) async {
      api.homeResult = LingtingHome(
        daily: const <LingtingSong>[
          LingtingSong(
            songId: 274021,
            name: '句句祷告',
            singerName: 'x',
            audioUrl: 'https://x/274021.mp3',
          ),
        ],
        dailyFromTop: true,
      );

      await pump(tester, const LingtingHomePage());

      expect(find.text('新歌首发'), findsOneWidget);
      expect(find.text('每日三十首'), findsNothing);
    });

    testWidgets('接口全挂时不白屏：显示失败与重试', (tester) async {
      api.homeResult = LingtingHome.empty;
      await pump(tester, const LingtingHomePage());

      expect(find.text('重试'), findsOneWidget);
      expect(find.text('灵听暂时没有内容'), findsOneWidget);
    });
  });

  /// 分层加载（S12.1）：用户报的是「每次要转圈圈大半天」。这两条钉的就是那个观感。
  group('首页分层加载', () {
    final dailySkeleton = find.byKey(
      const ValueKey<String>('lingtingHomeSkeleton.daily'),
    );

    testWidgets('慢的那一块不挡别的：回来一块画一块，还在路上的先摆骨架', (tester) async {
      // 「每日三十首」那一块挂住（实测它拿不到时还要串两次兜底请求，是最慢的一块）
      api.gates['daily'] = Completer<void>();
      await pump(tester, const LingtingHomePage());

      // 它还在路上 → 这一块摆骨架，标题一个字都没画（还不确定是「每日三十首」
      // 还是兜底来的「新歌首发」）
      expect(dailySkeleton, findsOneWidget);
      expect(find.text('每日三十首'), findsNothing);
      // 但排在它后面的热门歌曲照画 —— 老实现是整页一起等，这里一张都看不到
      await scrollTo(tester, find.text('热门歌曲'));
      expect(find.text('圣洁主'), findsOneWidget);

      api.open('daily');
      await tester.pumpAndSettle();

      // 放行之后骨架换成内容（从状态上钉更硬：这一刻它已经不在 pending 里了）
      final state = container.read(lingtingHomeProvider);
      expect(state.isPending(LingtingHomeSection.daily), isFalse);
      expect(state.home.daily.first.name, '一粒麦子');
      expect(dailySkeleton, findsNothing);
    });

    testWidgets('第二次进来：本机存着的那份先出画，一块都没回来也不转圈', (tester) async {
      // 「上一次」拉下来存住的那一份
      await repository.saveHome(
        homeFromResponses(
          daily: <Object>[
            <String, dynamic>{
              'songId': 7,
              'songName': '上一次的每日歌',
              'audioLink': 'https://x/7.mp3',
            },
          ],
        ),
      );
      // 这次五块全挂住：屏幕上还能看到的，只可能是本机存着的那份
      for (final key in const <String>[
        'banners',
        'daily',
        'hot',
        'sheets',
        'singers',
      ]) {
        api.gates[key] = Completer<void>();
      }

      await pump(tester, const LingtingHomePage());

      expect(find.text('上一次的每日歌'), findsOneWidget);
      expect(find.text('每日三十首'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      for (final key in const <String>[
        'banners',
        'daily',
        'hot',
        'sheets',
        'singers',
      ]) {
        api.open(key);
      }
      await tester.pumpAndSettle();
    });
  });

  /// 详情页也是同一套：本机存着的那份先出画，歌手页那三块各拉各的
  group('详情页分层加载', () {
    testWidgets('歌单：缓存那份先出画，接口回来再换成完整那份', (tester) async {
      await repository.saveSheet(
        LingtingSongSheet(
          sheetId: 5,
          name: '上一次的歌单',
          songCount: 3,
          songs: <LingtingSong>[fakeSong(1, name: '缓存里的歌')],
        ),
      );
      api.gates['sheetDetail'] = Completer<void>();

      await pump(tester, const LingtingSheetPage(sheetId: 5));

      expect(find.text('上一次的歌单'), findsOneWidget);
      expect(find.text('缓存里的歌'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      api.open('sheetDetail');
      await tester.pumpAndSettle();
    });

    testWidgets('歌手：三块各拉各的，先回来的先长出来', (tester) async {
      api.singerResult = LingtingSinger(singerId: 3, name: '小羊诗歌', fans: 1200);
      api.singerSongsResult = <LingtingSong>[fakeSong(1, name: '一粒麦子')];
      // 歌曲那一块挂住，资料那一块照回
      api.gates['singerSongs'] = Completer<void>();

      await pump(tester, const LingtingSingerPage(singerId: 3));

      // 资料回来了 → 名字与粉丝数已经画出来了；歌还一首都没有
      expect(find.text('小羊诗歌'), findsWidgets);
      expect(find.text('1200 粉丝'), findsOneWidget);
      expect(find.text('一粒麦子'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      api.open('singerSongs');
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('一粒麦子'));
      expect(find.text('一粒麦子'), findsOneWidget);
    });

    testWidgets('窄屏（320dp）下详情骨架不溢出：灰块照旧摆得下', (tester) async {
      // 本机没缓存 + 网络卡住：这一页就停在骨架上
      api.gates['sheetDetail'] = Completer<void>();

      await pumpNarrow(tester, const LingtingSheetPage(sheetId: 5));

      // 溢出在用例里会直接报错，所以「跑完了」本身就是结果
      expect(find.byType(LingtingDetailSkeleton), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      api.open('sheetDetail');
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('播放页歌词', () {
    const song = LingtingSong(
      songId: 1,
      name: '一粒麦子',
      singerName: '小羊诗歌',
      audioUrl: 'https://x/1.mp3',
    );

    /// 播放页的唱盘是**永不停息的旋转动画**，`pumpAndSettle` 会直接超时，
    /// 所以这一组只能手工 pump 几帧（把歌词那个 Future 走完就够了）
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// 按**真机比例**跑（1080×2340 / dpr 3 → 360×780 逻辑像素）：
    /// 默认的 800×600 是横屏尺寸，那种高度下播放页本来就不宽裕
    Future<void> showPlayer(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LingtingPlayerPage()),
        ),
      );
      await settle(tester);
    }

    testWidgets('顶栏两个 tab：切到「歌词」看歌词、切回「歌曲」看唱盘', (tester) async {
      repository.lyricResult = const LingtingLyric(
        lines: <LyricLine>[LyricLine(at: Duration.zero, text: '它就是那一粒麦子')],
      );
      final player =
          container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
      await player.playQueue(<LingtingSong>[song]);

      await showPlayer(tester);

      expect(find.text('歌曲'), findsOneWidget);
      expect(find.text('歌词'), findsOneWidget);
      expect(find.byType(LingtingSpinningCover), findsOneWidget);

      await tester.tap(find.text('歌词'));
      // 点 tab 是「滑过去」（200ms 上下），多给几帧让上面那一整块滑到位
      await settle(tester);
      await settle(tester);
      expect(find.text('它就是那一粒麦子'), findsOneWidget);
      expect(find.byType(LingtingSpinningCover), findsNothing);

      await tester.tap(find.text('歌曲'));
      await settle(tester);
      await settle(tester);
      expect(find.byType(LingtingSpinningCover), findsOneWidget);
    });

    testWidgets('上半屏能横滑：封面 ←→ 歌词（与顶栏 tab 同步）', (tester) async {
      repository.lyricResult = const LingtingLyric(
        lines: <LyricLine>[LyricLine(at: Duration.zero, text: '它就是那一粒麦子')],
      );
      final player =
          container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
      await player.playQueue(<LingtingSong>[song]);

      await showPlayer(tester);
      expect(find.byType(LingtingSpinningCover), findsOneWidget);

      // 手指从右往左滑（在唱盘那块上拖）→ 歌词进来
      await tester.drag(find.byType(PageView), const Offset(-300, 0));
      await settle(tester);
      await settle(tester);
      expect(find.text('它就是那一粒麦子'), findsOneWidget);

      // 再从左往右滑 → 回到唱盘
      await tester.drag(find.byType(PageView), const Offset(300, 0));
      await settle(tester);
      await settle(tester);
      expect(find.byType(LingtingSpinningCover), findsOneWidget);
    });

    testWidgets('点某一行歌词 → 从那一句开始放（进度跳到那儿）', (tester) async {
      repository.lyricResult = const LingtingLyric(
        lines: <LyricLine>[
          LyricLine(at: Duration.zero, text: '它就是那一粒麦子'),
          LyricLine(at: Duration(seconds: 30), text: '落在地里死了'),
        ],
      );
      final player =
          container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
      await player.playQueue(<LingtingSong>[song]);

      await showPlayer(tester);
      await tester.tap(find.text('歌词'));
      await settle(tester);

      // 页面上有点的那一行才行（后面那句在滚动区里，先滚过去）
      await tester.ensureVisible(find.text('落在地里死了'));
      await settle(tester);
      await tester.tap(find.text('落在地里死了'));
      await settle(tester);

      expect(player.state.position, const Duration(seconds: 30));
    });

    testWidgets('播放进度跳动不会把歌词变成转圈', (tester) async {
      repository.lyricResult = const LingtingLyric(
        lines: <LyricLine>[LyricLine(at: Duration.zero, text: '它就是那一粒麦子')],
      );
      final player =
          container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
      await player.playQueue(<LingtingSong>[song]);

      await showPlayer(tester);
      await tester.tap(find.text('歌词'));
      await settle(tester);
      expect(find.text('它就是那一粒麦子'), findsOneWidget);

      // 真机上 `positionStream` 每秒来好几帧：歌词必须还在，
      // 也不能重算（重算就会闪成转圈 —— 这正是「没有歌词」那个 bug）
      for (var i = 1; i <= 4; i++) {
        player.tick(Duration(seconds: i));
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('它就是那一粒麦子'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(repository.lyricCalls, 1, reason: '进度跳动不该让歌词重取');
    });

    testWidgets('手上有纯文本就先显示（不转圈），.lrc 到了再升级成有时间轴的那份', (tester) async {
      // 列表接口给的纯文本（没时间轴）—— 进页血立刻就该看到
      repository.lyricResult = const LingtingLyric(
        plain: '我献上一颗敬拜的心\n指的就是我全所有',
      );
      // `.lrc` 那一份（有时间轴）
      repository.timelineResult = const LingtingLyric(
        lines: <LyricLine>[LyricLine(at: Duration.zero, text: '它就是那一粒麦子')],
      );
      final player =
          container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
      await player.playQueue(<LingtingSong>[song]);

      await showPlayer(tester);
      await tester.tap(find.text('歌词'));
      await settle(tester);

      expect(find.text('它就是那一粒麦子'), findsOneWidget, reason: '.lrc 到了要换成它');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(repository.timelineCalls, 1, reason: '.lrc 只问一次');
    });

    testWidgets('切歌会重新取歌词（缓存之外的那一路也要通）', (tester) async {
      repository.lyricResult = const LingtingLyric(
        lines: <LyricLine>[LyricLine(at: Duration.zero, text: '它就是那一粒麦子')],
      );
      final player =
          container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
      await player.playQueue(<LingtingSong>[
        song,
        const LingtingSong(
          songId: 2,
          name: '通往祢的路',
          audioUrl: 'https://x/2.mp3',
        ),
      ]);

      await showPlayer(tester);
      await player.next();
      await settle(tester);

      expect(repository.lyricSongIds, <int>[1, 2]);
    });

    testWidgets('「更多」里是查看歌手 / 查看专辑 / 复制歌词三栏', (tester) async {
      repository.lyricResult = const LingtingLyric(
        lines: <LyricLine>[LyricLine(at: Duration.zero, text: '它就是那一粒麦子')],
      );
      final player =
          container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
      await player.playQueue(<LingtingSong>[song]);

      await showPlayer(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);

      expect(find.text('查看歌手'), findsOneWidget);
      expect(find.text('查看专辑'), findsOneWidget);
      expect(find.text('复制歌词'), findsOneWidget);
      // 我们没有收藏那一套，也不做定时关闭
      expect(find.text('定时关闭'), findsNothing);
    });

    testWidgets('复制歌词把整首歌词写进剪贴板', (tester) async {
      repository.lyricResult = const LingtingLyric(
        lines: <LyricLine>[
          LyricLine(at: Duration.zero, text: '它就是那一粒麦子'),
          LyricLine(at: Duration(seconds: 10), text: '落在地里死了'),
        ],
      );
      final clipboard = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            clipboard.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final player =
          container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
      await player.playQueue(<LingtingSong>[song]);
      await showPlayer(tester);

      await tester.tap(find.byIcon(Icons.more_vert));
      await settle(tester);
      await tester.tap(find.text('复制歌词'));
      await settle(tester);

      final setData = clipboard.firstWhere(
        (call) => call.method == 'Clipboard.setData',
      );
      expect((setData.arguments as Map)['text'], '它就是那一粒麦子\n落在地里死了');
    });

    testWidgets('没下过时显示下载键（点它才真去下）', (tester) async {
      final player =
          container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
      await player.playQueue(<LingtingSong>[song]);

      await showPlayer(tester);

      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    });
  });

  group('搜索', () {
    testWidgets('没搜过时显示的是搜索历史（本机存的）', (tester) async {
      await LingtingStore.instance.addSearchHistory('恩典');
      await pump(tester, const LingtingSearchPage());

      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.text('恩典'), findsOneWidget);
    });

    testWidgets('提交搜索 → 显示 tab 与结果（单曲 1）', (tester) async {
      await pump(tester, const LingtingSearchPage());

      await tester.enterText(find.byType(TextField), '恩典');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(api.searched, <String>['恩典']);
      expect(find.text('单曲 1'), findsOneWidget);
      // 接口给的是带命中标记的 `[恩典]`（见上面那条 fixture），
      // 界面上必须显示成干净的「恩典」—— 真机上搜什么都带一堆方括号
      expect(find.text('恩典'), findsWidgets);
      expect(find.text('[恩典]'), findsNothing);
      // 搜过之后历史里就有它了
      expect(LingtingStore.instance.searchHistory, contains('恩典'));
    });

    testWidgets('三块各拉各的：单曲先回来就先能看能点（不等歌手与歌单）', (tester) async {
      api.searchResult = LingtingSearchResult(
        songs: <LingtingSong>[fakeSong(1, name: '一粒麦子')],
        songCount: 1,
        singers: <LingtingSinger>[LingtingSinger(singerId: 3, name: '小羊诗歌')],
        singerCount: 1,
        sheets: <LingtingSongSheet>[
          LingtingSongSheet(sheetId: 5, name: '流淌着生命河流'),
        ],
        sheetCount: 1,
      );
      // 歌手与歌单两块挂住（实测灵的接口超时是 12 秒，一块慢就整页转圈）
      api.gates['searchSingers'] = Completer<void>();
      api.gates['searchSheets'] = Completer<void>();
      await pump(tester, const LingtingSearchPage());

      await tester.enterText(find.byType(TextField), '麦子');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      // 单曲已经在屏幕上了，也不转圈
      expect(find.text('单曲 1'), findsOneWidget);
      expect(find.text('一粒麦子'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 还没回来的那两块，连 tab 都还没出现
      expect(find.text('歌手 1'), findsNothing);

      api.open('searchSingers');
      api.open('searchSheets');
      await tester.pumpAndSettle();

      expect(find.text('歌手 1'), findsOneWidget);
      expect(find.text('歌单 1'), findsOneWidget);
    });

    testWidgets('搜不到东西时给「没有找到相关内容」', (tester) async {
      api.searchResult = LingtingSearchResult.empty;
      await pump(tester, const LingtingSearchPage());

      await tester.enterText(find.byType(TextField), '不存在');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('没有找到相关内容'), findsOneWidget);
    });
  });
}
