import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/media/media_saver.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/image_preview.dart';
import 'package:gracelinkim/features/chat/video_preview_page.dart';
import 'package:gracelinkim/features/contacts/user_detail_page.dart';
import 'package:gracelinkim/features/chat/widgets/media/contact_bubble.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/repo/lingting_repository.dart';
import 'package:gracelinkim/domain/lingting/lingting_player.dart';
import 'package:gracelinkim/features/chat/widgets/media/image_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/music_card_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/video_bubble.dart';
import 'package:gracelinkim/features/lingting/lingting_player_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_lingting.dart';
import '../support/test_database.dart';

/// 灵听播放器：测试里只要「状态机」，引擎全是空实现
/// （真去建 `AudioPlayer` 会碰平台通道，组件测试里没意义）
class _FakeMusicPlayer extends LingtingPlayerNotifier {
  /// 摆上就代表「引擎还卡在加载上」（真机上就是等一次网络）——
  /// 用例拿它验「页面不跟着一起卡」
  static Completer<void>? startGate;

  @override
  Future<Duration?> startEngine(LingtingSong song) async {
    final gate = startGate;
    if (gate != null) await gate.future;
    return const Duration(seconds: 200);
  }

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

/// 预览（S4.6）：点图片/视频/文件/位置之后会发生什么。
///
/// 相册、系统应用打开、地图这些都换成替身（[FakeMediaSaver]）：
/// 真机才有的能力在组件测试里既点不出来也没法断言，与选图/录音同一个做法。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late FakeMediaSaver saver;

  /// 假的灵听仓库：**不打网络**。
  ///
  /// 从卡片进播放页时，页面会拿 songId 去补一次歌曲详情（卡片 payload 里没有
  /// `singerId`/`albumId`，不补的话「查看歌手 / 查看专辑」是灰的）；不换掉它，
  /// 组件测试就会真去请求 `check-api.lingtingmusic.com`。
  late FakeLingtingRepository lingting;
  late List<AppNotice> notices;
  late StreamSubscription<AppNotice> noticesSub;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    // 音乐卡片点下去会走灵听播放器（它在 `main()` 之前就要求 store 就位）
    await LingtingStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    saver = FakeMediaSaver();
    lingting = FakeLingtingRepository(FakeLingtingApi());
    notices = <AppNotice>[];
    noticesSub = noticeBus.stream.listen(notices.add);
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    await noticesSub.cancel();
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  final baseTime = DateTime(2026, 9, 18, 10).millisecondsSinceEpoch;

  Future<void> seedConversation() => db.upsertConversation(
    Conversation(
      id: 'u2',
      displayName: '小明',
      lastSendTime: baseTime,
      lastContent: '你好',
    ),
  );

  /// 一条媒体消息（扩展字段按老端的形状塞 `extends`）
  Message mediaMessage(
    int index, {
    required String type,
    required String content,
    Map<String, dynamic> ext = const <String, dynamic>{},
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) => Message(
    serverId: index,
    msgId: 'm$index',
    conversationId: 'u2',
    fromUserId: 'u2',
    fromUserName: '小明',
    type: type,
    content: content,
    sendTime: baseTime + index * 1000,
    isGroup: 0,
    ext: ext,
    extra: extra,
  );

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          mediaSaverProvider.overrideWithValue(saver),
          lingtingPlayerProvider.overrideWith(_FakeMusicPlayer.new),
          lingtingRepositoryProvider.overrideWithValue(lingting),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();

    container.read(appRouterProvider).push('/message/chat?id=u2');
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));
  }

  testWidgets('点图片：进预览页，点「保存到本地」把它交给相册', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(1, type: 'image', content: 'https://cdn.test/a.png'),
      mediaMessage(2, type: 'image', content: 'https://cdn.test/b.png'),
    ]);

    await pumpApp(tester);
    await tester.tap(find.byType(ImageBubble).first);
    await tester.pumpAndSettle();

    expect(find.byType(ImagePreviewPage), findsOneWidget);
    // 两张图都收进去了（老端 `showImgs` 的行为），且停在点中的那张
    final page = tester.widget<ImagePreviewPage>(find.byType(ImagePreviewPage));
    expect(page.urls, <String>[
      'https://cdn.test/a.png',
      'https://cdn.test/b.png',
    ]);
    expect(find.text('${page.index + 1} / 2'), findsOneWidget);

    await tester.tap(find.text('保存到本地'));
    await tester.pumpAndSettle();

    // 存的是当前正在看的那张
    expect(saver.savedImages, <String>[page.urls[page.index]]);
    expect(saver.savedImageNames.single, 'b.png');
    expect(
      notices.whereType<ToastNotice>().map((notice) => notice.message),
      contains('已保存到相册'),
    );

    await disposeApp(tester);
  });

  testWidgets('点视频：进全屏播放页（插件在测试里不可用 → 落到失败提示）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'video',
        content: 'https://cdn.test/v.mp4',
        ext: <String, dynamic>{'duration': 12},
        extra: <String, dynamic>{'fileName': '旅行.mp4'},
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.byType(VideoBubble));
    // 播放器初始化是异步的，`pumpAndSettle` 会卡在转圈上，所以逐帧推到出结果为止
    await pumpUntil(tester, find.text('网络错误'));

    expect(find.byType(VideoPreviewPage), findsOneWidget);
    // 测试环境没有平台播放器 → 显示「网络错误」占位，而不是白屏或崩
    expect(find.text('网络错误'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('点 pdf：弹层两项，选「本地预览」→ 下载后用系统应用打开', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'file',
        content: 'https://cdn.test/doc/报表.pdf',
        extra: <String, dynamic>{'fileName': '报表.pdf', 'fileSize': 2048},
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.text('报表.pdf'));
    await tester.pumpAndSettle();

    expect(find.text('本地预览'), findsOneWidget);
    expect(find.text('在线预览'), findsOneWidget);

    await tester.tap(find.text('本地预览'));
    await tester.pumpAndSettle();

    expect(saver.downloads, <String>['https://cdn.test/doc/报表.pdf']);
    expect(saver.downloadNames.single, '报表.pdf');
    expect(saver.openedFiles.single, '/tmp/报表.pdf');

    await disposeApp(tester);
  });

  testWidgets('点 pdf 选「在线预览」：交给浏览器，不下载', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'file',
        content: 'https://cdn.test/doc/报表.pdf',
        extra: <String, dynamic>{'fileName': '报表.pdf'},
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.text('报表.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在线预览'));
    await tester.pumpAndSettle();

    expect(saver.openedUrls, <String>['https://cdn.test/doc/报表.pdf']);
    expect(saver.downloads, isEmpty);

    await disposeApp(tester);
  });

  testWidgets('txt 选「本地预览」：只提示不支持，不下载也不打开', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'file',
        content: 'https://cdn.test/doc/说明.txt',
        extra: <String, dynamic>{'fileName': '说明.txt'},
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.text('说明.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地预览'));
    await tester.pumpAndSettle();

    expect(saver.downloads, isEmpty);
    expect(saver.openedFiles, isEmpty);
    expect(
      notices.whereType<ToastNotice>().map((notice) => notice.message),
      contains('该文件不支持预览'),
    );

    await disposeApp(tester);
  });

  testWidgets('音频文件只有一个「在线预览」入口（老端也把它丢给浏览器）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'file',
        content: 'https://cdn.test/doc/歌.mp3',
        extra: <String, dynamic>{'fileName': '歌.mp3'},
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.text('歌.mp3'));
    await tester.pumpAndSettle();

    expect(find.text('本地预览'), findsNothing);
    expect(find.text('在线预览'), findsOneWidget);

    await tester.tap(find.text('在线预览'));
    await tester.pumpAndSettle();
    expect(saver.openedUrls, <String>['https://cdn.test/doc/歌.mp3']);

    await disposeApp(tester);
  });

  testWidgets('文件下载失败：提示网络错误，不崩', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'file',
        content: 'https://cdn.test/doc/报表.pdf',
        extra: <String, dynamic>{'fileName': '报表.pdf'},
      ),
    ]);
    saver.failDownload = true;

    await pumpApp(tester);
    await tester.tap(find.text('报表.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地预览'));
    await tester.pumpAndSettle();

    expect(saver.openedFiles, isEmpty);
    expect(
      notices.whereType<ToastNotice>().map((notice) => notice.message),
      contains('网络错误'),
    );

    await disposeApp(tester);
  });

  testWidgets('点位置：用坐标唤起系统地图', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'location',
        content: '人民广场',
        ext: <String, dynamic>{
          'address': '上海市黄浦区',
          'latitude': 31.23,
          'longitude': 121.47,
        },
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.text('人民广场'));
    await tester.pumpAndSettle();

    expect(saver.openedUrls, hasLength(1));
    // 测试机是桌面（既不是 Android 也不是 iOS）→ 走 Google 地图那一档；
    // 坐标必须原样带上（具体链接形态由 file_preview_test.dart 逐档覆盖）
    expect(saver.openedUrls.single, contains('31.23,121.47'));

    await disposeApp(tester);
  });

  testWidgets('点名片：进对方资料页（老端 openContact）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    // 资料页自己去拉详情，这里给个空回执，能进页就够了
    adapter.ok(ChatPaths.userInfo, data: <String, dynamic>{});
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'contact',
        content: '[个人名片] 小红',
        ext: <String, dynamic>{
          'avatar': 'https://cdn.test/xh.png',
          'displayName': '小红',
          'id': 'u3',
        },
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.byType(ContactBubble));
    await tester.pumpAndSettle();

    expect(find.byType(UserDetailPage), findsOneWidget);
    expect(adapter.bodyOf(ChatPaths.userInfo)['user_id'], 'u3');

    await disposeApp(tester);
  });

  testWidgets('点音乐卡片：开播这一首 + 直接进灵听播放页', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'lingting',
        content: '[音乐] 《一粒麦子》- 小羊诗歌',
        ext: <String, dynamic>{
          'songId': 236,
          'name': '一粒麦子',
          'singer': '小羊诗歌',
          'cover': 'https://cdn.test/cover.jpg',
          'audioUrl': 'https://cdn.test/236.mp3',
        },
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.byType(MusicCardBubble));
    // 播放页的唱盘是永不停的旋转动画，`pumpAndSettle` 会超时 → 手工 pump 几帧
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final state = container.read(lingtingPlayerProvider);
    expect(state.current?.songId, 236, reason: '点的就是卡片上那一首');
    expect(state.current?.audioUrl, 'https://cdn.test/236.mp3');
    expect(state.playing, isTrue);
    expect(find.byType(LingtingPlayerPage), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('引擎还在加载（网络慢）也照样进播放页，不把它压在网络后面', (tester) async {
    // 真机上的现场（2026-09-25 用户报的）：「歌响了，页没进去，再点一次才进」——
    // 根因是起播里 `await player.play()`（just_audio 的 play() 要到暂停/播完
    // 才完成）把后面的 `context.push` 一起堵住了。这里把引擎卡在加载上验这件事。
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'lingting',
        content: '[音乐] 《一粒麦子》- 小羊诗歌',
        ext: <String, dynamic>{
          'songId': 236,
          'name': '一粒麦子',
          'singer': '小羊诗歌',
          'cover': 'https://cdn.test/cover.jpg',
          'audioUrl': 'https://cdn.test/236.mp3',
        },
      ),
    ]);

    final gate = Completer<void>();
    _FakeMusicPlayer.startGate = gate;
    addTearDown(() => _FakeMusicPlayer.startGate = null);

    await pumpApp(tester);
    await tester.tap(find.byType(MusicCardBubble));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(
      find.byType(LingtingPlayerPage),
      findsOneWidget,
      reason: '引擎还在加载，页面也该已经进来了',
    );

    gate.complete();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    expect(container.read(lingtingPlayerProvider).current?.songId, 236);

    await disposeApp(tester);
  });

  testWidgets('音乐卡片没有音频地址：只提示，不进播放页', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'lingting',
        content: '[音乐] 《裸记录》',
        ext: <String, dynamic>{'songId': 9, 'name': '裸记录'},
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.byType(MusicCardBubble));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    expect(container.read(lingtingPlayerProvider).hasSong, isFalse);
    expect(find.byType(LingtingPlayerPage), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('名片没带 id：不跳页（老端会拼出一个坏地址）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'contact',
        content: '[个人名片] 小红',
        ext: <String, dynamic>{'displayName': '小红'},
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.byType(ContactBubble));
    await tester.pumpAndSettle();

    expect(find.byType(UserDetailPage), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('位置没有坐标：只提示，不打开地图', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      mediaMessage(
        1,
        type: 'location',
        content: '某个地方',
        ext: <String, dynamic>{'address': '没写坐标'},
      ),
    ]);

    await pumpApp(tester);
    await tester.tap(find.text('某个地方'));
    await tester.pumpAndSettle();

    expect(saver.openedUrls, isEmpty);
    expect(
      notices.whereType<ToastNotice>().map((notice) => notice.message),
      contains('暂无数据'),
    );

    await disposeApp(tester);
  });
}

/// 等到某个东西出现为止（给异步初始化用：一直推进直到有结果，最多 40 帧）
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int frames = 40,
}) async {
  for (var i = 0; i < frames; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 相册 / 系统应用 / 浏览器全部记下来，不碰真机能力
class FakeMediaSaver implements MediaSaver {
  final List<String> savedImages = <String>[];
  final List<String> savedImageNames = <String>[];
  final List<String> savedVideos = <String>[];
  final List<String> downloads = <String>[];
  final List<String> downloadNames = <String>[];
  final List<String> openedFiles = <String>[];
  final List<String> openedUrls = <String>[];

  bool failDownload = false;

  @override
  Future<String> download(String url, {required String fileName}) async {
    downloads.add(url);
    downloadNames.add(fileName);
    if (failDownload) throw StateError('下载失败');
    return '/tmp/$fileName';
  }

  @override
  Future<void> saveImageToGallery(
    String url, {
    required String fileName,
  }) async {
    savedImages.add(url);
    savedImageNames.add(fileName);
  }

  @override
  Future<void> saveVideoToGallery(
    String url, {
    required String fileName,
  }) async {
    savedVideos.add(url);
  }

  @override
  Future<bool> openLocalFile(String path) async {
    openedFiles.add(path);
    return true;
  }

  @override
  Future<bool> openUrl(String url) async {
    openedUrls.add(url);
    return true;
  }
}
