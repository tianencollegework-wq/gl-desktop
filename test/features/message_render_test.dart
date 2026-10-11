import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/audio/voice_player.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话/消息的数据库方法是以 extension 形式提供的，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/news/news_providers.dart';
import 'package:gracelinkim/features/chat/image_preview.dart';
import 'package:gracelinkim/features/chat/widgets/media/call_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/contact_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/file_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/image_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/location_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/music_card_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/news_card_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/unsupported_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/video_bubble.dart';
import 'package:gracelinkim/features/chat/widgets/media/voice_bubble.dart';
import 'package:gracelinkim/features/news/news_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_news.dart';
import '../support/test_database.dart';

/// 九种消息类型的渲染（S4.3）。
///
/// 跑整个 App（真路由 + 内存库 + 假网络），因为要验的正是
/// 「服务端/本地存的那条消息，在聊天页里长什么样」。
/// 图片一律加载失败（测试环境没有网络），所以顺带也验了占位逻辑。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late FakeVoicePlayer voice;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    voice = FakeVoicePlayer();
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  final baseTime = DateTime(2026, 9, 18, 10).millisecondsSinceEpoch;

  Message media(
    int index, {
    required String type,
    String content = '',
    Map<String, dynamic> ext = const <String, dynamic>{},
    Map<String, dynamic> extra = const <String, dynamic>{},
    String fromUserId = 'u2',
    int isUndo = 0,
  }) => Message(
    serverId: index,
    msgId: 'm$index',
    conversationId: 'u2',
    fromUserId: fromUserId,
    fromUserName: '小明',
    type: type,
    content: content,
    sendTime: baseTime + index * 1000,
    isGroup: 0,
    isUndo: isUndo,
    ext: ext,
    extra: extra,
  );

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> pumpApp(WidgetTester tester, {FakeNewsRepository? news}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
          // 用变量持有的那个替身，才能在测试里断言它记录了什么
          voicePlayingProvider.overrideWith(() => voice),
          // 资讯卡片点进去会读列表（真实现会去拉四个 RSS），这里换掉
          if (news != null) newsRepositoryProvider.overrideWithValue(news),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 测试中途挂掉时 `disposeApp` 不会被执行，聊天页那堆数据库订阅还活着，
    // 后面 `tearDown` 关库就会卡住（表现为这一轮测试莫名多花几分钟）。
    // 这里兜一道：无论测试怎么结束，都先把 Widget 树拆了再让 tearDown 关库。
    addTearDown(() => disposeApp(tester));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();
    container.read(appRouterProvider).push('/message/chat?id=u2');
    await tester.pumpAndSettle();
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  Future<void> seedConversation() => db.upsertConversation(
    Conversation(
      id: 'u2',
      displayName: '小明',
      lastSendTime: baseTime,
      lastContent: '你好',
    ),
  );

  /// 测试环境的视口默认只有 800×600，`ListView.builder` 只会构建可见的那几行；
  /// 要一次看到十种类型就把视口调得很高（用完恢复）。
  ///
  /// 高度要留足：反向列表是从底部往上建的，媒体气泡比文字行高得多，
  /// 3200 高在第十、十一行就停了（最旧那两条根本不会构建）。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('十种气泡各就各位：图片/表情/语音/视频/文件/位置/名片/通话/未知/diy', (tester) async {
    useTallViewport(tester);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      media(1, type: 'text', content: '你好'),
      media(
        2,
        type: 'image',
        content: 'https://a.test/a.png',
        // fixMode 1 = 定宽 200（老端 im-image.vue 的第一档）
        ext: <String, dynamic>{'fixMode': 1},
      ),
      media(3, type: 'emoji', content: 'https://a.test/sticker.png'),
      media(
        4,
        type: 'voice',
        content: 'https://a.test/v.mp3',
        ext: <String, dynamic>{'duration': 12},
      ),
      media(
        5,
        type: 'video',
        content: 'https://a.test/v.mp4',
        ext: <String, dynamic>{
          'poster': 'https://a.test/p.jpg',
          'duration': 96,
        },
      ),
      media(
        6,
        type: 'file',
        content: 'https://a.test/report.pdf',
        extra: <String, dynamic>{'fileName': '报表.pdf', 'fileSize': 2048},
      ),
      media(
        7,
        type: 'location',
        content: '人民广场',
        ext: <String, dynamic>{'address': '上海市黄浦区'},
      ),
      media(
        8,
        type: 'contact',
        ext: <String, dynamic>{'id': 'u9', 'displayName': '小红'},
      ),
      media(
        9,
        type: 'webrtc',
        content: '通话时长 00:35',
        ext: <String, dynamic>{'type': 1},
      ),
      media(10, type: 'diy'),
      media(11, type: 'something-new'),
    ]);

    await pumpApp(tester);

    expect(find.byType(ImageBubble), findsOneWidget);
    expect(find.byType(StickerBubble), findsOneWidget);
    expect(find.byType(VoiceBubble), findsOneWidget);
    expect(find.byType(VideoBubble), findsOneWidget);
    expect(find.byType(FileBubble), findsOneWidget);
    expect(find.byType(LocationBubble), findsOneWidget);
    expect(find.byType(ContactBubble), findsOneWidget);
    expect(find.byType(CallBubble), findsOneWidget);
    expect(find.byType(UnsupportedBubble), findsNWidgets(2));

    // 各类型该显示的文案
    expect(find.text('12 "'), findsOneWidget); // 语音秒数（老端就带个引号）
    expect(find.text('01:36'), findsOneWidget); // 96 秒的视频时长
    expect(find.text('报表.pdf'), findsOneWidget);
    expect(find.text('2.00 KB'), findsOneWidget);
    expect(find.text('人民广场'), findsOneWidget);
    expect(find.text('上海市黄浦区'), findsOneWidget);
    expect(find.text('小红'), findsOneWidget);
    expect(find.text('个人名片'), findsOneWidget);
    expect(find.text('通话时长 00:35'), findsOneWidget);
    // diy 与未知类型各自一条文案（老端 im-item.vue）
    expect(find.text('自定义'), findsOneWidget);
    expect(find.text('暂不支持的消息类型'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('音乐卡片（type=lingting）：显歌名/歌手/来源，不在列表里写「暂不支持」', (tester) async {
    useTallViewport(tester);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      media(
        1,
        type: 'lingting',
        content: '[音乐] 《一粒麦子》- 小羊诗歌',
        // 灵听分享发出去的那四个字段（点一下就能播）
        ext: <String, dynamic>{
          'songId': 236,
          'name': '一粒麦子',
          'singer': '小羊诗歌',
          'cover': 'https://a.test/cover.jpg',
          'audioUrl': 'https://a.test/236.mp3',
        },
      ),
    ]);

    await pumpApp(tester);

    expect(find.byType(MusicCardBubble), findsOneWidget);
    expect(find.text('一粒麦子'), findsOneWidget);
    expect(find.text('小羊诗歌'), findsOneWidget);
    // 卡片底部那行来源（微信也是这个位置写来源）
    expect(find.text('灵听'), findsOneWidget);
    // 自己的类型，不能落到「暂不支持的消息类型」去
    expect(find.byType(UnsupportedBubble), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('分享卡片不分你我：自己发的灵听/媒体号卡片也是白底（不套自己的绿）', (tester) async {
    useTallViewport(tester);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    // 两张都**是我发的**（fromUserId 是自己的 u1）
    await db.upsertMessages(<Message>[
      media(
        1,
        type: 'lingting',
        fromUserId: 'u1',
        content: '[音乐] 《一粒麦子》- 小羊诗歌',
        ext: <String, dynamic>{
          'songId': 236,
          'name': '一粒麦子',
          'singer': '小羊诗歌',
          'cover': '',
          'audioUrl': 'https://a.test/236.mp3',
        },
      ),
      media(
        2,
        type: 'news',
        fromUserId: 'u1',
        content: '[媒体号] 我转发的一篇',
        ext: <String, dynamic>{
          'id': 'https://sspai.com/post/9',
          'title': '我转发的一篇',
          'source': 'sspai',
          'link': 'https://sspai.com/post/9',
        },
      ),
    ]);

    await pumpApp(tester, news: FakeNewsRepository([]));

    expect(find.byType(MusicCardBubble), findsOneWidget);
    expect(find.byType(NewsCardBubble), findsOneWidget);
    expect(
      _cardColor(tester, find.byType(MusicCardBubble)),
      AppColors.white,
      reason: '用户 2026-09-30：分享卡片不管谁发的都用白色那种气泡框',
    );
    expect(_cardColor(tester, find.byType(NewsCardBubble)), AppColors.white);

    await disposeApp(tester);
  });

  testWidgets('媒体号卡片（type=news）：显标题/来源/「媒体号」，点一下进详情（带上卡片里那份）', (tester) async {
    useTallViewport(tester);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      media(
        1,
        type: 'news',
        content: '[资讯] 朋友分享来的新闻',
        ext: <String, dynamic>{
          'id': 'https://sspai.com/post/1',
          'title': '朋友分享来的新闻',
          'source': 'sspai',
          'summary': '卡片里带的摘要。',
          'link': 'https://sspai.com/post/1',
        },
      ),
    ]);

    await pumpApp(tester, news: FakeNewsRepository([]));

    expect(find.byType(NewsCardBubble), findsOneWidget);
    expect(find.text('朋友分享来的新闻'), findsOneWidget);
    // 来源名按当前语言解析（存的是来源 key）
    expect(find.textContaining('少数派'), findsOneWidget);
    // 卡片底部那行来源
    expect(find.text('媒体号'), findsOneWidget);
    expect(find.byType(UnsupportedBubble), findsNothing);

    // 点卡片 → 详情页：**本机列表里没有这一篇**，靠卡片里那份渲染
    await tester.tap(find.byType(NewsCardBubble));
    await tester.pumpAndSettle();
    expect(find.byType(NewsDetailPage), findsOneWidget);
    expect(find.text('朋友分享来的新闻'), findsOneWidget);
    expect(find.text('卡片里带的摘要。'), findsOneWidget);
    expect(find.text('阅读原文'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('系统消息（type=event）：居中一条小字，不是气泡、也不是「暂不支持」', (tester) async {
    useTallViewport(tester);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      // 群事件：服务端 `type='event'`，content 就是那行字（用户 2026-09-21 遇到的那条）
      media(1, type: 'event', content: '小明创建了群聊'),
      // 别人撤的（服务端给的 content 带名字，老端就是照 `content` 画的）
      media(2, type: 'event', content: '小明撤回了一条消息', isUndo: 1),
    ]);

    await pumpApp(tester);

    expect(find.text('小明创建了群聊'), findsOneWidget);
    expect(find.text('小明撤回了一条消息'), findsOneWidget);
    // 回归：以前这两种都落在未知类型那颗气泡里，显示「暂不支持的消息类型」
    expect(find.text('暂不支持的消息类型'), findsNothing);
    expect(find.byType(UnsupportedBubble), findsNothing);
    // 事件的字是**居中**的（老端 `.cu-info`），不是靠左/靠右的气泡
    final viewportWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final line = tester.getCenter(find.text('小明创建了群聊'));
    expect((line.dx - viewportWidth / 2).abs(), lessThan(8));
    // 系统消息是**点不动的**（微信里系统消息没有长按菜单）：
    // 长按不该弹出转发/删除那一排
    await tester.longPress(find.text('小明创建了群聊'));
    await tester.pumpAndSettle();
    expect(find.text('转发'), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(find.text('引用'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('语音气泡：宽度按时长长出来（老端那套单位混用永远只有最小宽）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      media(
        1,
        type: 'voice',
        content: 'https://a.test/short.m4a',
        ext: <String, dynamic>{'duration': 3},
      ),
      media(
        2,
        type: 'voice',
        content: 'https://a.test/long.m4a',
        ext: <String, dynamic>{'duration': 40},
      ),
    ]);

    await pumpApp(tester);

    Finder bubbleWith(String url) => find.byWidgetPredicate(
      (widget) => widget is VoiceBubble && widget.payload.url.endsWith(url),
    );
    final shortWidth = tester.getSize(bubbleWith('short.m4a')).width;
    final longWidth = tester.getSize(bubbleWith('long.m4a')).width;
    // 老端那套是「秒数 × 3（逻辑像素）」再用 rpx 夹上下限，两套单位混着，
    // 结果短语音永远顶在最小宽度；这里要看的就是真的宽窄有别
    expect(longWidth, greaterThan(shortWidth + 20));

    await disposeApp(tester);
  });

  testWidgets('通话气泡：自己的绿底、对方的白底（不再是那条灰卡片）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      media(
        1,
        type: 'webrtc',
        content: '通话时长 00:35',
        ext: <String, dynamic>{'type': 1, 'duration': 35},
      ),
      media(
        2,
        type: 'webrtc',
        content: '通话时长 00:13',
        fromUserId: 'u1',
        ext: <String, dynamic>{'type': 1, 'duration': 13},
      ),
    ]);

    await pumpApp(tester);

    final colors = tester
        .widgetList<CallBubble>(find.byType(CallBubble))
        .map((bubble) => bubble.mine)
        .toList();
    // 一条别人的、一条自己的（列表是倒序渲染，所以只断言这两种都在）
    expect(colors.toSet(), <bool>{true, false});
    expect(find.text('通话时长 00:35'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('语音：点一下开始播（声波动起来），再点一下停', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      media(
        1,
        type: 'voice',
        content: 'https://a.test/v.mp3',
        ext: <String, dynamic>{'duration': 9},
      ),
    ]);

    await pumpApp(tester);

    expect(containerOf(tester).read(voicePlayingProvider), isNull);

    await tester.tap(find.byType(VoiceBubble));
    // 不能 pumpAndSettle：播放时声波动画是**一直在重复**的，永远等不到「没有待处理动画」
    await tester.pump(const Duration(milliseconds: 50));
    expect(voice.started, <String>['https://a.test/v.mp3']);
    expect(
      containerOf(tester).read(voicePlayingProvider),
      'https://a.test/v.mp3',
    );
    // 微信那个「波纹会变」：播的时候图标在动（数道弧一道道亮）
    expect(
      tester.widget<VoiceWaveIcon>(find.byType(VoiceWaveIcon)).playing,
      isTrue,
    );

    await tester.tap(find.byType(VoiceBubble));
    await tester.pumpAndSettle();
    expect(
      tester.widget<VoiceWaveIcon>(find.byType(VoiceWaveIcon)).playing,
      isFalse,
    );
    expect(containerOf(tester).read(voicePlayingProvider), isNull);
    expect(voice.stopCount, greaterThan(0));

    await disposeApp(tester);
  });

  testWidgets('点图片打开预览页：把整条记录里的图片都收进去（老端 showImgs）', (tester) async {
    // 老端那个 300rpx 的动态表情很高，默认 800×600 视口下最旧那张图不会被构建
    useTallViewport(tester);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      media(1, type: 'image', content: 'https://a.test/1.png'),
      media(2, type: 'text', content: '中间插一条文字'),
      media(3, type: 'emoji', content: 'https://a.test/2.png'),
      media(4, type: 'image', content: 'https://a.test/3.png'),
    ]);

    await pumpApp(tester);

    // 点最旧那张图（反向列表的树顺序与视觉顺序相反，所以按地址找）
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is ImageBubble && widget.payload.url.endsWith('1.png'),
      ),
    );
    await tester.pumpAndSettle();

    final page = tester.widget<ImagePreviewPage>(find.byType(ImagePreviewPage));
    expect(page.urls, <String>[
      'https://a.test/1.png',
      'https://a.test/2.png',
      'https://a.test/3.png',
    ]);
    expect(page.index, 0);
    // 多图时下面有「n / 总数」
    expect(find.text('1 / 3'), findsOneWidget);

    await disposeApp(tester);
  });
}

/// 分享卡片的底色：卡片的根是 `GestureDetector > Container`，取里面那个 Conatiner
Color? _cardColor(WidgetTester tester, Finder card) {
  final container = tester.widget<Container>(
    find.descendant(of: card, matching: find.byType(Container)).first,
  );
  final decoration = container.decoration;
  return decoration is BoxDecoration ? decoration.color : null;
}

/// 语音播放器的替身：只记录被点了什么，不碰音频子系统。
class FakeVoicePlayer extends VoicePlayerNotifier {
  final List<String> started = <String>[];
  int stopCount = 0;

  @override
  Future<void> startEngine(String url) async => started.add(url);

  @override
  Future<void> stopEngine() async => stopCount += 1;
}
