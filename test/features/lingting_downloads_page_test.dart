import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/data/model/lingting/download.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/repo/lingting_repository.dart';
import 'package:gracelinkim/domain/lingting/lingting_player.dart';
import 'package:gracelinkim/features/lingting/lingting_downloads_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_lingting.dart';

/// 播放器在这里只要「状态机」就够了，引擎全是空实现
class _FakePlayer extends LingtingPlayerNotifier {
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
  late Directory dir;
  late FakeLingtingApi api;

  /// 造一首「本机真下好了」的歌（清单里那条记录指向一个真存在的小文件 ——
  /// 页面开起来会顺手把「记录里有、盘上没有了」的剔掉，文件不在就断言不了）
  Future<void> seedDownloads(List<(int, String, String)> songs) async {
    final items = <int, LingtingDownload>{};
    for (final (id, name, singer) in songs) {
      final path = '${dir.path}/$id.mp3';
      File(path).writeAsStringSync('mp3' * 8);
      items[id] = LingtingDownload(
        path: path,
        url: 'https://x/$id.mp3',
        name: name,
        singer: singer,
      );
    }
    await LingtingStore.instance.saveDownloads(items);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 语言包的 provider 会读 CredentialStore（`localeProvider`），两份都要初始化
    await CredentialStore.init();
    await LingtingStore.init();
    await AppI18n.load('zh-Hans');
    dir = await Directory.systemTemp.createTemp('lingting-downloads-test');
    api = FakeLingtingApi();
    container = ProviderContainer(
      overrides: [
        lingtingRepositoryProvider.overrideWithValue(
          FakeLingtingRepository(api),
        ),
        lingtingPlayerProvider.overrideWith(_FakePlayer.new),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LingtingDownloadsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('一首都没下过：给一句「怎么才会有」，不是白屏', (tester) async {
    await show(tester);

    expect(find.text('下载管理'), findsOneWidget);
    expect(find.textContaining('还没有下载的歌'), findsOneWidget);
  });

  testWidgets('下过的歌都列出来（歌名 + 歌手），且完全不联网也列得出来', (tester) async {
    await seedDownloads(<(int, String, String)>[
      (1, '一粒麦子', '小羊诗歌'),
      (2, '通往祢的路', '赞美之泉'),
    ]);
    await show(tester);

    expect(find.text('一粒麦子'), findsOneWidget);
    expect(find.text('小羊诗歌'), findsOneWidget);
    expect(find.text('通往祢的路'), findsOneWidget);
    expect(find.byIcon(Icons.download_done), findsNWidgets(2));
  });

  testWidgets('老记录（只有一行路径）进来会被补全：歌名/封面/直链都回来，点一下就能播', (tester) async {
    // 用户 2026-09-25 的现场：列表里只有一行「3866」（歌曲 id）、封面空白，
    // 点一下没反应。那条记录是**最早那版下载**留下的，只有一条磁盘路径。
    final path = '${dir.path}/3866.mp3';
    File(path).writeAsStringSync('mp3');
    await LingtingStore.instance.saveDownloads(<int, LingtingDownload>{
      3866: LingtingDownload(path: path),
    });
    api.detailResult = const LingtingSong(
      songId: 3866,
      name: '敬拜的心',
      singerName: '约书亚乐团',
      cover: 'https://x/3866.jpg',
      audioUrl: 'https://x/3866.mp3',
    );

    await show(tester);

    expect(api.detailSongIds, <int>[3866], reason: '进来时按 id 补一次详情');
    expect(find.text('敬拜的心'), findsOneWidget);
    expect(find.text('约书亚乐团'), findsOneWidget);
    expect(find.text('3866'), findsNothing, reason: '不该再拿 id 当歌名');

    await tester.tap(find.text('敬拜的心'));
    await tester.pumpAndSettle();

    final state = container.read(lingtingPlayerProvider);
    expect(state.playing, isTrue, reason: '补上直链后点一下就能播（以前没反应）');
    expect(state.current?.songId, 3866);
  });

  testWidgets('点一行 → 以整份下载列表为队列，从这一首开始播', (tester) async {
    await seedDownloads(<(int, String, String)>[
      (1, '一粒麦子', '小羊诗歌'),
      (2, '通往祢的路', '赞美之泉'),
    ]);
    await show(tester);

    await tester.tap(find.text('通往祢的路'));
    await tester.pumpAndSettle();

    final state = container.read(lingtingPlayerProvider);
    expect(state.queue.length, 2, reason: '「下一首」也该是下好的一首');
    expect(state.current?.songId, 2);
    expect(state.playing, isTrue);
    expect(state.source, '下载管理');
  });

  testWidgets('长按一行 → 确认后删掉本机那一份（列表与清单一起少一条）', (tester) async {
    await seedDownloads(<(int, String, String)>[
      (1, '一粒麦子', '小羊诗歌'),
      (2, '通往祢的路', '赞美之泉'),
    ]);
    await show(tester);

    await tester.longPress(find.text('一粒麦子'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除「一粒麦子」的本机文件吗'), findsOneWidget);

    await tester.tap(find.text('删除'));
    // 弹窗的返回值要等关闭动画走完才回来（那时才开始真删）
    await tester.pumpAndSettle();
    // 删本机那一份走的是**真 I/O**（`File.exists` → `File.delete` → 写清单）：
    // 假时钟里这些 await 不会自己前进，每一步都得借 runAsync 让真事件循环转一下
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.text('一粒麦子'), findsNothing);
    expect(find.text('通往祢的路'), findsOneWidget);
    expect(LingtingStore.instance.downloads.keys.toList(), <int>[2]);
    expect(File('${dir.path}/1.mp3').existsSync(), isFalse, reason: '文件也要真删掉');
  });
}
