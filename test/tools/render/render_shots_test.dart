import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/core/platform/webview_host.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/theme/app_theme.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/api/update_api.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话 / 联系人 / 消息的数据库方法都以 extension 形式提供，必须 import 才进作用域
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/sfu_models.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/chat/group_members.dart';
import 'package:gracelinkim/domain/group_call/group_call_presence.dart';
import 'package:gracelinkim/domain/group_call/sfu_room.dart';
import 'package:gracelinkim/features/call/screen_share_picker.dart';
import 'package:gracelinkim/features/group_call/group_call_controller.dart';
import 'package:gracelinkim/features/group_call/group_call_page.dart';
import 'package:gracelinkim/features/group_call/group_call_sync.dart'
    show groupCallPresenceProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../group_call/support/fake_sfu.dart';
import '../../support/fake_call_keep_alive.dart';
import '../../support/fake_call_pip.dart';
import '../../support/fake_notification_presenter.dart';
import '../../support/test_database.dart';

/// 官网手机样机的**出图工具**（不是断言型测试）。
///
/// 为什么有这个文件：官网上那几台「手机」从前是我手画 CSS 的 —— 名字、图标、
/// 按钮、行数全是照着印象编的，跟 App 对不上（用户 2026-10-10 逐条指出）。
/// 现在改成**让 App 自己出图**：真页面、真主题、真图标资源、真语言包渲染成
/// PNG，官网只负责把图放进手机外框里。
///
/// 用法（仓库根目录）：
///
///     RENDER_SHOTS=1 flutter test test/tools/render/render_shots_test.dart
///
/// **默认不跑。** 它会在官网目录里写文件、还要本机的字体路径，
/// 所以只有设了 `RENDER_SHOTS=1` 才真动手；不设时整个文件只报一条「跳过」，
/// `flutter test` 跑全量用例不受影响。
///
/// 产物（直接写进官网的静态目录，构建期原样发布，不需要再拷一次）：
///
///     website/public/shots/{list,chat,contacts,discover,group-call}.png
///     website/public/shots/en/{同上}.png
///
/// 三个刻意的选择：
///
/// * **不做 golden 断言。** 字体或引擎版本一变 golden 就会红，而出图工具不该
///   让 `flutter test` 挂掉。这里只写文件、不比较。
/// * **字体得自己喂。** 测试环境默认字体把每个字都画成方块。中文用 Windows 的
///   等线（`Deng.ttf`），图标字形用 Flutter SDK 里的 `MaterialIcons`。两样都是
///   本机的东西、不在仓库里，所以缺了会**明确报错**，绝不悄悄出一张方块图。
/// * **名单与头像是示例数据。** 截图里必然要有会话和好友（真机上是用户自己的
///   数据）。名字按语言各一套；头像是本机生成的几张纯色图，通过一个只监听回环
///   的 HTTP 服务喂给 `Image.network` —— 走的是 App 真实的取图那条路。
void main() {
  if (Platform.environment['RENDER_SHOTS'] != '1') {
    test('出图工具（默认不跑）', () {}, skip: '设 RENDER_SHOTS=1 才出图');
    return;
  }

  late AppDatabase db;
  late StubAdapter adapter;

  setUpAll(() async {
    await _startAvatarServer();
  });

  tearDownAll(() async {
    await _avatarServer?.close(force: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await _loadFonts();
    db = memoryDatabase();
    adapter = StubAdapter();
    _db = db;
    _adapter = adapter;
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  // 两条语言各出一套：官网是中英双语，英文页上挂中文截图同样算画错
  for (final locale in <String>['zh-Hans', 'en']) {
    final en = locale == 'en';
    final dir = en ? 'website/public/shots/en' : 'website/public/shots';

    testWidgets('[${_tag(locale)}] 会话列表（消息 tab）', (tester) async {
      await _loadI18n(tester, locale);
      await _seedConversations(db, adapter, en: en);
      await _prewarm(tester);
      await _pumpApp(tester);
      await _waitImages(tester);
      await _capture(tester, _shotKey, '$dir/list.png');
      await _dispose(tester);
    });

    testWidgets('[${_tag(locale)}] 聊天页（点进一个群）', (tester) async {
      debugPrint('[出图] (1) 载语言包');
      await _loadI18n(tester, locale);
      debugPrint('[出图] (2) 播会话');
      final groupId = await _seedConversations(db, adapter, en: en);
      debugPrint('[出图] (3) 预热图');
      await _prewarm(tester);
      debugPrint('[出图] (4) 挂 App');
      await _pumpApp(tester);
      debugPrint('[出图] (5) 点进群');
      await tester.tap(find.text(_n('productGroup', en)));
      await _settle(tester);
      debugPrint('[出图] (6) 播消息');
      await _seedMessages(db, groupId, en: en);
      await _settle(tester);
      await _waitImages(tester);
      // 聊天页进来是滚到底的，再推一点时间让它滚完，别截到半路
      await tester.pump(const Duration(milliseconds: 400));
      await _capture(tester, _shotKey, '$dir/chat.png');
      await _dispose(tester);
    });

    testWidgets('[${_tag(locale)}] 通讯录 tab', (tester) async {
      await _loadI18n(tester, locale);
      await _seedContacts(db, adapter, en: en);
      await _prewarm(tester);
      await _pumpApp(tester);
      await tester.tap(find.text(AppI18n.instance.t('user.contacts')));
      await _settle(tester);
      await _waitImages(tester);
      await _capture(tester, _shotKey, '$dir/contacts.png');
      await _dispose(tester);
    });

    testWidgets('[${_tag(locale)}] 发现 tab', (tester) async {
      await _loadI18n(tester, locale);
      await _prewarm(tester);
      await _pumpApp(tester);
      await tester.tap(find.text(AppI18n.instance.t('user.compass')));
      await _settle(tester);
      await _waitImages(tester);
      await _capture(tester, _shotKey, '$dir/discover.png');
      await _dispose(tester);
    });

    testWidgets('[${_tag(locale)}] 群通话页', (tester) async {
      await _loadI18n(tester, locale);
      await _prewarm(tester);
      await _pumpGroupCall(tester, en: en);
      await _waitImages(tester);
      await _capture(tester, _groupCallKey, '$dir/group-call.png');
      await _dispose(tester);
    });
  }
}

// --------------------------------------------------------------- App 那几页

/// 载语言包。
///
/// 它是从资源里读文件（真实 IO）：在测试体的假时钟里 await 会等不到
/// （实测第二个用例就卡在这行），所以放 `runAsync` 里。
Future<void> _loadI18n(WidgetTester tester, String locale) async {
  await tester.runAsync(() => AppI18n.load(locale));
}

/// 有界的 settle。
///
/// `pumpAndSettle()` 默认要等满 10 分钟才认输；出图出问题的时候我们想它
/// **快点报错**（比如某个动画一直在跑、或者页面在等一个永远不来的东西）。
Future<void> _settle(
  WidgetTester tester, [
  Duration timeout = const Duration(seconds: 25),
]) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    timeout,
  );
}

final GlobalKey _shotKey = GlobalKey();
final GlobalKey _groupCallKey = GlobalKey();

late AppDatabase _db;
late StubAdapter _adapter;

String _tag(String locale) => locale == 'en' ? 'en' : 'zh';

/// 手机视口：与 `group_call_page_test` 同一档（1080/3 = 360 逻辑宽，
/// 正是 rpx 那套尺寸按 750 设计宽换算过来的宽度）。
const Size _phone = Size(360, 760);
const double _dpr = 2;

/// 挂起整个 App（真路由 + 真主题 + 真页面），外面套一层 [RepaintBoundary]
/// —— 出图就是从它身上 `toImage`。
Future<void> _pumpApp(WidgetTester tester) async {
  debugPrint('[出图] 挂起 App…');
  _allowRealNetwork();
  _setPhoneView(tester);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_db),
          apiClientProvider.overrideWithValue(_adapter.apiClient()),
          webViewHostProvider.overrideWithValue(_FakeWebViewHost()),
          // 启动会查一次新版本（`home_shell` 的 `appUpdate()`）：截图时不需要，
          // 换成立刻失败的一份 —— 真的去连服务器会留下一个连接超时定时器，
          // 收尾时报「A Timer is still pending」
          updateApiProvider.overrideWithValue(_OfflineUpdateApi()),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
          // 「谁在开群语音」的真身会回查房间（那是网络）：换一个不回查的替身
          groupCallPresenceProvider.overrideWith(
            (ref) => GroupCallPresenceTracker(verifyInterval: null),
          ),
        ],
        child: const GracelinkApp(),
      ),
    ),
  );
  await _settle(tester);
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  container
      .read(sessionStoreProvider.notifier)
      .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
  container.read(sessionStoreProvider.notifier).applyConfig(
    GlobalConfig.fromJson(<String, dynamic>{
      // runMode 2 = 有「新的朋友」（服务端默认值也是 2）
      'sysInfo': <String, dynamic>{'runMode': 2},
      // webrtc 开着才有通话入口；online 开着才画在线小绿点
      'chatInfo': <String, dynamic>{'webrtc': 1, 'online': 1},
    }),
  );
  await _settle(tester);
  // 会话列表同步带一个节流的 debugPrint 定时器，推掉它
  // （不推的话收尾会报「A Timer is still pending」）
  await tester.pump(const Duration(seconds: 1));
  debugPrint('[出图] App 就绪');
}

/// 群通话页不在 App 的默认路由上，单独挂一遍：假控制面 + 假媒体 + 真主题。
///
/// 套路照抄 `test/features/group_call_page_test.dart`（那边验行为，这边只要画面）。
Future<void> _pumpGroupCall(WidgetTester tester, {required bool en}) async {
  _allowRealNetwork();
  final control = FakeSfuControl()
    ..snapshot = SfuRoomState(
      epoch: 1,
      members: <SfuRoomMember>[
        const SfuRoomMember(
          userId: 'u1',
          sessionId: 'sess-1',
          tracks: <String>['mic'],
        ),
        const SfuRoomMember(
          userId: 'u2',
          sessionId: 'sess-2',
          tracks: <String>['mic'],
        ),
        const SfuRoomMember(
          userId: 'u3',
          sessionId: 'sess-3',
          tracks: <String>['mic'],
        ),
      ],
    );
  final room = SfuRoom(
    roomId: '100',
    myUserId: 'u1',
    control: control,
    local: FakeSfuLocalMedia(),
    connectionFactory: FakeSfuConnections().call,
    audioLevelPollInterval: null,
    heartbeatInterval: null,
    stateRefreshInterval: null,
    // 共享屏健康检查、补订阅重试那几支定时器同样关掉
    screenHealthInterval: null,
    reconcileRetryInterval: null,
  );
  final groupName = _n('productGroup', en);
  final controller = GroupCallController(
    groupName: groupName,
    room: room,
    loadMembers: () async => <GroupMember>[
      GroupMember(userId: 'u1', name: _n('me', en)),
      GroupMember(userId: 'u2', name: _n('engineer', en)),
      GroupMember(userId: 'u3', name: _n('ya', en)),
    ],
    keepAlive: FakeCallKeepAlive(),
    pip: FakeCallPip(),
    notify: (_) {},
  );
  final presence = GroupCallPresenceTracker(verifyInterval: null);
  addTearDown(presence.dispose);
  final router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: SizedBox.shrink()),
      ),
      GoRoute(
        path: '/call',
        builder: (context, state) =>
            GroupCallPage(conversationId: 'group-100', name: groupName),
      ),
    ],
  );

  _setPhoneView(tester);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _groupCallKey,
      child: ProviderScope(
        overrides: [
          groupCallControllerFactoryProvider.overrideWithValue(
            ({required String conversationId, required String name}) =>
                controller,
          ),
          messageNotificationPresenterProvider.overrideWithValue(
            FakeNotificationPresenter(),
          ),
          groupCallPresenceProvider.overrideWithValue(presence),
          // 「共享哪块屏幕」那张面板真身要问插件；这张截图里不需要它
          screenSharePickerProvider.overrideWithValue((
            context,
            i18n, {
            allowAudio = true,
          }) async => null),
        ],
        // 这里不是 App 自己的根（真根在 `lib/app.dart`），别把它的两个开关忘了：
        // 少了 debugShowCheckedModeBanner 时测试环境是 debug 构建，
        // 每张群通话截图右上角都会被印上一条红色「DEBUG」斜带。
        child: MaterialApp.router(
          theme: AppTheme.light,
          debugShowCheckedModeBanner: false,
          routerConfig: router,
        ),
      ),
    ),
  );
  router.push('/call');
  // 进房间那一串是异步的（拉名单、建会话、订阅），而且页面滑进来要 300ms：
  // 半路上下手，整页还在屏幕外面
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _setPhoneView(WidgetTester tester) {
  tester.view.physicalSize = _phone * _dpr;
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.reset);
}

/// 收尾：把整棵树拆掉，让 drift 关查询流时那个零延迟定时器跑完。
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

// ------------------------------------------------------------------ 示例数据

/// 会话列表那几行（含置顶、群聊、未读、免打扰、系统通知）。
///
/// 返回产品群的 id，聊天页那张图接着用它。
Future<String> _seedConversations(
  AppDatabase db,
  StubAdapter adapter, {
  required bool en,
}) async {
  // 页面进来会同步一次会话接口；空响应按 App 的规则**保留本地数据**
  adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.upsertConversations(<Conversation>[
    Conversation(
      id: 'group-100',
      displayName: _n('productGroup', en),
      avatar: _avatar(1),
      lastContent: '${_n('engineer', en)}：${_t('lastProduct', en)}',
      lastSendTime: now - 1000 * 60 * 12,
      isGroup: 1,
      unread: 3,
    ),
    Conversation(
      id: 'group-101',
      displayName: _n('designGroup', en),
      avatar: _avatar(2),
      lastContent: '',
      lastType: 'image',
      lastSendTime: now - 1000 * 60 * 55,
      isGroup: 1,
      isNotice: 0,
      unread: 12,
    ),
    Conversation(
      id: 'u2',
      displayName: _n('engineer', en),
      avatar: _avatar(3),
      lastContent: _t('lastEngineer', en),
      lastSendTime: now - 1000 * 60 * 60 * 4,
    ),
    Conversation(
      id: 'u3',
      displayName: _n('ya', en),
      avatar: _avatar(4),
      lastContent: '',
      lastType: 'voice',
      lastSendTime: now - 1000 * 60 * 60 * 26,
    ),
    Conversation(
      id: 'system',
      displayName: AppI18n.instance.t('user.systemNotice'),
      avatar: _avatar(5),
      lastContent: _t('lastSystem', en),
      lastSendTime: now - 1000 * 60 * 60 * 30,
      isGroup: 2,
      isNotice: 0,
    ),
    Conversation(
      id: 'group-102',
      displayName: _n('family', en),
      avatar: _avatar(6),
      lastContent: _t('lastFamily', en),
      lastSendTime: now - 1000 * 60 * 60 * 50,
      isGroup: 1,
      isTop: 1,
    ),
  ]);
  return 'group-100';
}

/// 聊天页里那几条（自己发的和收到的都有，含一条图片）
Future<void> _seedMessages(
  AppDatabase db,
  String conversationId, {
  required bool en,
}) async {
  final base = DateTime.now().millisecondsSinceEpoch - 1000 * 60 * 40;
  await db.upsertMessages(<Message>[
    Message(
      conversationId: conversationId,
      msgId: 'm1',
      fromUserId: 'u2',
      fromUserName: _n('engineer', en),
      fromUserAvatar: _avatar(3),
      content: _t('msg1', en),
      sendTime: base,
      isGroup: 1,
    ),
    Message(
      conversationId: conversationId,
      msgId: 'm2',
      fromUserId: 'u1',
      fromUserName: _n('me', en),
      content: _t('msg2', en),
      sendTime: base + 1000 * 60 * 3,
      isGroup: 1,
    ),
    Message(
      conversationId: conversationId,
      msgId: 'm3',
      fromUserId: 'u3',
      fromUserName: _n('ya', en),
      fromUserAvatar: _avatar(4),
      content: _t('msg3', en),
      sendTime: base + 1000 * 60 * 6,
      isGroup: 1,
    ),
    Message(
      conversationId: conversationId,
      msgId: 'm4',
      fromUserId: 'u3',
      fromUserName: _n('ya', en),
      fromUserAvatar: _avatar(4),
      type: 'image',
      content: 'design-v2.png',
      sendTime: base + 1000 * 60 * 7,
      isGroup: 1,
    ),
    Message(
      conversationId: conversationId,
      msgId: 'm5',
      fromUserId: 'u2',
      fromUserName: _n('engineer', en),
      fromUserAvatar: _avatar(3),
      content: _t('msg4', en),
      sendTime: base + 1000 * 60 * 9,
      isGroup: 1,
    ),
  ]);
}

/// 通讯录：群聊、系统通知，加上几个按首字母分组的好友
Future<void> _seedContacts(
  AppDatabase db,
  StubAdapter adapter, {
  required bool en,
}) async {
  adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
  adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
  await db.upsertContacts(<Contact>[
    Contact(
      id: 'group-100',
      displayName: _n('productGroup', en),
      avatar: _avatar(1),
      isGroup: 1,
    ),
    Contact(
      id: 'system',
      displayName: AppI18n.instance.t('user.systemNotice'),
      avatar: _avatar(5),
      isGroup: 2,
    ),
    // 英文页上名字是 Alex / Sam / Amber / Mia / Zoe，分组字母跟着名字走
    Contact(
      id: 'u4',
      displayName: _n('chen', en),
      avatar: _avatar(6),
      indexLetter: _letter(english: en, zh: 'C', latin: 'A'),
    ),
    Contact(
      id: 'u2',
      displayName: _n('engineer', en),
      avatar: _avatar(3),
      indexLetter: _letter(english: en, zh: 'L', latin: 'S'),
    ),
    Contact(
      id: 'u5',
      displayName: _n('su', en),
      avatar: _avatar(7),
      indexLetter: _letter(english: en, zh: 'S', latin: 'A'),
    ),
    Contact(
      id: 'u3',
      displayName: _n('ya', en),
      avatar: _avatar(4),
      indexLetter: _letter(english: en, zh: 'X', latin: 'M'),
    ),
    Contact(
      id: 'u6',
      displayName: _n('zhou', en),
      avatar: _avatar(2),
      indexLetter: _letter(english: en, zh: 'Z', latin: 'Z'),
    ),
  ]);
}

/// 分组字母：中文按拼音首字母，英文按名字首字母
String _letter({required bool english, required String zh, required String latin}) =>
    english ? latin : zh;

// ---------------------------------------------------------------- 文案与头像

String _n(String key, bool en) => _names[key]![en ? 'en' : 'zh']!;

String _t(String key, bool en) => _texts[key]![en ? 'en' : 'zh']!;

const Map<String, Map<String, String>> _names = <String, Map<String, String>>{
  'me': <String, String>{'zh': '我', 'en': 'Me'},
  'productGroup': <String, String>{'zh': '产品群', 'en': 'Product team'},
  'designGroup': <String, String>{'zh': '设计评审', 'en': 'Design review'},
  'family': <String, String>{'zh': '家人', 'en': 'Family'},
  'engineer': <String, String>{'zh': '林工', 'en': 'Sam'},
  'ya': <String, String>{'zh': '小雅', 'en': 'Mia'},
  'chen': <String, String>{'zh': '陈晨', 'en': 'Alex'},
  'su': <String, String>{'zh': '苏晴', 'en': 'Amber'},
  'zhou': <String, String>{'zh': '周舟', 'en': 'Zoe'},
};

const Map<String, Map<String, String>> _texts = <String, Map<String, String>>{
  'lastProduct': <String, String>{
    'zh': '接口我这边对齐好了，明天发版',
    'en': 'API side is aligned, shipping tomorrow',
  },
  'lastEngineer': <String, String>{
    'zh': '好，我上午先跑一轮',
    'en': 'Sure, I will run a pass in the morning',
  },
  'lastSystem': <String, String>{
    'zh': '你的账号在新设备上登录',
    'en': 'Your account signed in on a new device',
  },
  'lastFamily': <String, String>{
    'zh': '周末回来吃饭吗',
    'en': 'Coming home for dinner this weekend?',
  },
  'msg1': <String, String>{
    'zh': '这版改完了，你们看一下',
    'en': 'This pass is done — take a look',
  },
  'msg2': <String, String>{
    'zh': '收到，我这边也把接口对齐一下',
    'en': 'Got it, I will align the API side too',
  },
  'msg3': <String, String>{
    'zh': '设计稿按上次说的调了间距',
    'en': 'Spacing adjusted as we discussed',
  },
  'msg4': <String, String>{
    'zh': '那就今晚发个包，明天一起过一遍',
    'en': 'Then let us ship a build tonight and review tomorrow',
  },
};

/// 头像：本机生成的纯色图（不是仓库资产），由下面的回环服务喂给 `Image.network`
final Map<String, Uint8List> _avatars = <String, Uint8List>{};
HttpServer? _avatarServer;
String _avatarOrigin = '';

Future<void> _startAvatarServer() async {
  _avatarServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _avatarOrigin = 'http://127.0.0.1:${_avatarServer!.port}';
  unawaited(
    _avatarServer!.forEach((request) async {
      final segments = request.uri.pathSegments;
      final bytes = segments.isEmpty ? null : _avatars[segments.last];
      if (bytes == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('image', 'png')
        ..headers.contentLength = bytes.length
        // 短连接：留着 keep-alive 的闲置连接会在用例之间留下定时器
        ..headers.set(HttpHeaders.connectionHeader, 'close')
        ..add(bytes);
      await request.response.close();
    }),
  );
}

/// 第 [index] 张头像的地址（0 = 不用头像，交给 App 自己画灰底小人）
String _avatar(int index) => index == 0 ? '' : '$_avatarOrigin/a$index.png';

const List<int> _avatarColors = <int>[
  0xFF4C8DFF,
  0xFF39B54A,
  0xFFF37B1D,
  0xFF8E6BD9,
  0xFF00A0A0,
  0xFFE0695B,
  0xFF5B6B7C,
];

/// 画一张「纯色底 + 白色人形」的示例头像（128×128）。
///
/// 为什么不直接用 App 那个灰底小人占位：一屏全是灰方块，官网看着像坏了。
/// 也不去网上抓图：仓库里不该混进别人的照片。
Future<Uint8List> _avatarPng(int index) async {
  const size = 128;
  final color = _avatarColors[index % _avatarColors.length];
  final baseR = (color >> 16) & 0xFF;
  final baseG = (color >> 8) & 0xFF;
  final baseB = color & 0xFF;
  final pixels = Uint8List(size * size * 4);

  const centreX = size / 2;
  const headR = size * 0.17;
  const headCy = size * 0.37;
  const bodyRx = size * 0.32;
  const bodyRy = size * 0.30;
  const bodyCy = size * 0.99;

  for (var y = 0; y < size; y++) {
    final shade = 1 - 0.08 * (y / size);
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      var r = baseR * shade;
      var g = baseG * shade;
      var b = baseB * shade;

      final dx = x + 0.5 - centreX;
      final dyHead = y + 0.5 - headCy;
      final dyBody = y + 0.5 - bodyCy;
      final inHead = dx * dx + dyHead * dyHead <= headR * headR;
      final inBody =
          (dx * dx) / (bodyRx * bodyRx) +
                  (dyBody * dyBody) / (bodyRy * bodyRy) <=
              1;
      if (inHead || inBody) {
        r = r * 0.34 + 255 * 0.66;
        g = g * 0.34 + 255 * 0.66;
        b = b * 0.34 + 255 * 0.66;
      }
      pixels[i] = r.clamp(0, 255).round();
      pixels[i + 1] = g.clamp(0, 255).round();
      pixels[i + 2] = b.clamp(0, 255).round();
      pixels[i + 3] = 255;
    }
  }

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    size,
    size,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

// ------------------------------------------------------------------ 字与图

bool _fontsLoaded = false;

Future<void> _loadFonts() async {
  if (_fontsLoaded) return;
  await _loadFont('Roboto', _cjkFontPath);
  await _loadFont('MaterialIcons', _iconFontPath);
  // 聊天气泡那类文本用的是**不带字体族的**裸 `DefaultTextStyle`（真机上回落
  // 到系统字体，在测试环境里就回落成「方块字体」Ahem）。把中文字体也注册成
  // Ahem / FlutterTest，这些字才有字形可用。
  await _loadFont('Ahem', _cjkFontPath);
  await _loadFont('FlutterTest', _cjkFontPath);
  _fontsLoaded = true;
}

/// 中文字体：Windows 自带等线（真机上用的是系统字体，这里取一套观感接近的
/// 黑体）。缺了就直接抛，别悄悄出一张方块图。
String get _cjkFontPath {
  const candidates = <String>[
    'C:/Windows/Fonts/Deng.ttf',
    'C:/Windows/Fonts/msyh.ttc',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  throw StateError('找不到中文测试字体（试过：${candidates.join('、')}）');
}

/// 图标字形：Flutter SDK 自带的 MaterialIcons（从 FLUTTER_ROOT 推）
String get _iconFontPath {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) {
    throw StateError('FLUTTER_ROOT 没设，找不到 MaterialIcons 字形文件');
  }
  final path =
      '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf';
  if (!File(path).existsSync()) {
    throw StateError('找不到 MaterialIcons 字形文件：$path');
  }
  return path;
}

Future<void> _loadFont(String family, String path) async {
  final bytes = await File(path).readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// 放开本机回环的 HTTP。
///
/// 必须在**测试体内**设：`TestWidgetsFlutterBinding` 会在初始化时把
/// `HttpOverrides.global` 装回它那个「一律 400」的 mock（`_binding_io.dart`），
/// 在 `setUpAll` 里设会被它盖掉。不放开的话，`Image.network` 一张都拿不到。
void _allowRealNetwork() {
  // 这版 SDK 里 `global` 只有 setter（`current` 才是 getter），所以只赋值、不读它
  HttpOverrides.global = null;
}

/// 先把图拉进图片缓存，**再**挂页面。
///
/// 顺序很关键：`Image.network` 的请求如果是在 `pumpAndSettle` 那种假时钟里发出去
/// 的，回调永远等不到（假时钟不跑真实 IO），那一项就会以「待定」状态卡在缓存里，
/// 后面再怎么等也等不出来。所以先在 `runAsync`（真实事件循环）里把头像和随包
/// 资源图解好，页面渲染时直接命中缓存。
Future<void> _prewarm(WidgetTester tester) async {
  // 预热必须发生在放开网络之后（否则拿到的是 mock 的 400），
  // 也要发生在挂页面之前 —— 见这个函数的说明
  _allowRealNetwork();
  await tester.runAsync(() async {
    for (var index = 1; index <= _avatarColors.length; index++) {
      if (!_avatars.containsKey('a$index.png')) {
        _avatars['a$index.png'] = await _avatarPng(index);
      }
    }
  });
  final providers = <ImageProvider>[
    for (var index = 1; index <= _avatarColors.length; index++)
      NetworkImage(_avatar(index)),
    // 「发现」里那栏的图标是随包资源，同样要预热
    const AssetImage('assets/images/lingting_logo.png'),
  ];
  await tester.runAsync(() async {
    for (final provider in providers) {
      debugPrint('[出图]   预热 $provider');
      try {
        await _resolve(provider).timeout(const Duration(seconds: 8));
      } on TimeoutException {
        debugPrint('[出图]   ✗ 预热超时（跳过）：$provider');
      } catch (error) {
        debugPrint('[出图]   ✗ 预热失败（跳过）：$provider / $error');
      }
    }
  });
}

/// 把一个 provider 解到「可用」为止（等价于 prewarm 的最小实现，
/// 但不需要 BuildContext，可以放在挂页面之前用）
Future<void> _resolve(ImageProvider provider) {
  final completer = Completer<void>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (image, synchronousCall) {
      if (!completer.isCompleted) completer.complete();
    },
    onError: (error, stack) {
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  stream.addListener(listener);
  return completer.future.whenComplete(() => stream.removeListener(listener));
}

/// 挂页面之后的兜底：还有没解出来的资源图（比如空态那张 `empty.png`）就在这儿补。
Future<void> _waitImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate().toList()) {
      final provider = (element.widget as Image).image;
      try {
        await precacheImage(provider, element).timeout(
          const Duration(seconds: 5),
        );
      } on TimeoutException {
        debugPrint('[出图]   ✗ 等图超时（跳过）：$provider');
      } catch (error) {
        debugPrint('[出图]   ✗ 图出错（跳过）：$provider / $error');
      }
    }
  });
  await _settle(tester);
}

/// 出图：从外面那层 [RepaintBoundary] 上 `toImage`，写进官网的静态目录。
Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  debugPrint('[出图] 开始截图 $path');
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: _dpr));
  final width = image!.width;
  final height = image.height;
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  image.dispose();
  final bytes = data!.buffer.asUint8List();
  // 落盘也必须放在 runAsync 里：测试体的假时钟不跑真实 IO，
  // 在它外面 await 文件写入会永远等不到
  await tester.runAsync(() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  });
  debugPrint(
    '已写出 $path  $width×$height  ${(bytes.length / 1024).round()}KB',
  );
}

/// 不查更新的替身（见 `_pumpApp` 里的说明）
class _OfflineUpdateApi extends UpdateApi {
  @override
  Future<Map<String, dynamic>> fetchManifest() async =>
      throw StateError('截图工具：不查更新');
}

/// 假的 webview：真机上是平台视图，测试里建控制器会直接抛
class _FakeWebViewHost implements WebViewHost {
  @override
  Widget build({
    required String url,
    ValueChanged<int>? onProgress,
    ValueChanged<String>? onError,
    ValueChanged<String>? onTitle,
  }) => const SizedBox.shrink();
}
