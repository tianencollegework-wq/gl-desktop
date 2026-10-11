import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/media/image_compressor.dart';
import 'package:gracelinkim/core/media/media_picker.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
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
// 数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/widgets/chat_input.dart';
import 'package:gracelinkim/features/chat/widgets/emoji_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 输入区与发送（S4.4）。
///
/// 跑整个 App（真路由 + 内存库 + 假网络），因为要验的是完整一条链路：
/// 敲字 → 乐观落库 → 请求体 → 气泡状态 → 失败重发 / 草稿 / 表情。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late FakeMediaPicker picker;
  late FakeImageCompressor compressor;
  late List<AppNotice> notices;
  late StreamSubscription<AppNotice> noticeSub;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    picker = FakeMediaPicker();
    compressor = FakeImageCompressor();
    notices = <AppNotice>[];
    noticeSub = noticeBus.stream.listen(notices.add);
    sessionGuard.update(ready: true, hasSession: true);
    tempDir = await Directory.systemTemp.createTemp('gracelink-send');
  });

  tearDown(() async {
    await noticeSub.cancel();
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException catch (_) {
      // Windows 上文件可能还占着句柄，用后即删失败不影响用例
    }
  });

  final baseTime = DateTime(2026, 9, 18, 10).millisecondsSinceEpoch;

  Future<void> seedConversation({
    int isGroup = 0,
    int role = 3,
    int nospeak = 0,
    String draft = '',
  }) => db.upsertConversation(
    Conversation(
      id: 'u2',
      displayName: '小明',
      isGroup: isGroup,
      role: role,
      draft: draft,
      lastSendTime: baseTime,
      lastContent: '你好',
      extra: <String, dynamic>{
        'setting': <String, dynamic>{'nospeak': nospeak},
      },
    ),
  );

  Message localMessage(int index, {String content = '旧消息'}) => Message(
    serverId: index,
    msgId: 'm$index',
    conversationId: 'u2',
    fromUserId: 'u2',
    fromUserName: '小明',
    content: content,
    sendTime: baseTime + index * 1000,
  );

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          // 选图/选文件在测试里没法点系统选择器，换成本地替身
          mediaPickerProvider.overrideWithValue(picker),
          // 图片压缩走原生编码器，单测环境里没有 —— 换成替身（默认原样放行，
          // 需要验"发的是压完那张"时再让它返回压缩结果）
          imageCompressorProvider.overrideWithValue(compressor),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();

    final container = containerOf(tester);
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();
    container.read(appRouterProvider).push('/message/chat?id=u2');
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));
    return container;
  }

  /// 在输入框里敲字（`ChatInput` 里的那个 TextField）
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(ChatInput),
        matching: find.byType(TextField),
      ),
      text,
    );
    await tester.pumpAndSettle();
  }

  /// 点「发送」按钮（输入框里有内容时才出现）
  Future<void> tapSend(WidgetTester tester) async {
    await tester.tap(
      find.descendant(of: find.byType(ChatInput), matching: find.text('发送')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('敲字 → 出现发送按钮 → 点一下：乐观落库 + 请求体正确', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await seedConversation();
    await pumpApp(tester);

    // 没内容时没有发送按钮（老端是 v-if="inputMsg"）
    expect(
      find.descendant(of: find.byType(ChatInput), matching: find.text('发送')),
      findsNothing,
    );

    await type(tester, '你好呀');
    await tapSend(tester);

    // 语音自动滚到底，气泡立刻出现（不等接口）
    expect(find.text('你好呀'), findsOneWidget);
    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1));
    expect(stored.single.content, '你好呀');
    expect(stored.single.fromUserId, 'u1');

    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['toContactId'], 'u2');
    expect(body['from_user'], 'u1');
    expect(body['content'], '你好呀');
    expect(body['type'], 'text');
    expect(body['is_group'], 0);
    // 发完输入框清空
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byType(ChatInput),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      isEmpty,
    );

    await disposeApp(tester);
  });

  testWidgets('发送失败：气泡上出现红叹号，点一下重发', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.fail(ChatPaths.sendMessage, code: 500, msg: '服务器炸了');
    await seedConversation();
    await pumpApp(tester);

    await type(tester, '发不出去');
    await tapSend(tester);

    final stored = await db.messagesFor('u2');
    expect(stored.single.status, MessageStatus.failed);
    // 失败提示图标在气泡上（点它重发）
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    // 服务端恢复正常，点一下重发
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await tester.tap(find.byIcon(Icons.error_outline));
    await tester.pumpAndSettle();

    expect(await db.messagesFor('u2'), hasLength(1));
    final retried = (await db.messagesFor('u2')).single;
    expect(retried.status, MessageStatus.sent);
    expect(
      adapter.paths.where((p) => p == ChatPaths.sendMessage),
      hasLength(2),
    );

    await disposeApp(tester);
  });

  testWidgets('表情面板：内置表情插进输入框（不直接发）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(EmojiPaths.list, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await seedConversation();
    await pumpApp(tester);

    expect(find.byType(EmojiPanel), findsNothing);
    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPanel), findsOneWidget);
    // 底部是分类条（微信的摆法）：最近 / 收藏 + 8 个内置分类
    // （分类条上的「常用」那颗就是 😀，所以下面点格子要用 `.first`）
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);

    // 点第一个内置表情（S4.4b：面板上是**系统表情字符**，不再是网络图）
    await tester.tap(find.text('😀').first);
    await tester.pumpAndSettle();

    // 内容进了输入框，还没发出去
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(ChatInput),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, '😀');
    expect(adapter.paths, isNot(contains(ChatPaths.sendMessage)));

    // 再发出去，请求体里就是那个 emoji 字符（网页端/老端收到也是普通 emoji）
    await tapSend(tester);
    expect(adapter.bodyOf(ChatPaths.sendMessage)['content'], '😀');

    await disposeApp(tester);
  });

  testWidgets('键盘和面板互斥：点输入框就把表情面板收起来', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(EmojiPaths.list, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPanel), findsOneWidget);

    // 点输入框 = 拉起系统输入法：面板必须让位，不能两者同时占着下半屏
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPanel), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );

    // 反过来：面板开着时点表情不会把键盘也拉起来（连着点好几个表情的姿势）
    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPanel), findsOneWidget);
    await tester.tap(find.text('😀').first);
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPanel), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('点过的表情会进「最近」那一栏', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(EmojiPaths.list, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('😀').first);
    await tester.pumpAndSettle();

    // 分类条最左那颗「最近」
    await tester.tap(find.byIcon(Icons.history));
    await tester.pumpAndSettle();
    expect(find.text('😀'), findsWidgets);
    expect(find.text('还没有最近使用的表情'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('点头像：进对方的资料页（老端聊天页点了没反应）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.setMsgIsRead);
    adapter.ok(
      ChatPaths.userInfo,
      data: <String, dynamic>{
        'user_id': 'u2',
        'realname': '小明',
        'account': '13800000000',
      },
    );
    await seedConversation();
    await db.upsertMessages(<Message>[
      Message(
        serverId: 1,
        msgId: 'm1',
        conversationId: 'u2',
        fromUserId: 'u2',
        fromUserName: '小明',
        fromUserAvatar: 'https://a.test/avatar.png',
        content: '旧消息',
        sendTime: baseTime + 1000,
      ),
    ]);
    await pumpApp(tester);

    // 点对方头像（那条消息的头像就是 u2）；测试环境里网络图加载不出来，
    // 但它那张 Container/Image 还在树上，能点到
    await tester.tap(find.byType(Image).first, warnIfMissed: false);
    await tester.pumpAndSettle();

    // 资料页真的去拉了那个人的详情
    expect(adapter.paths, contains(ChatPaths.userInfo));
    expect(adapter.bodyOf(ChatPaths.userInfo)['user_id'], 'u2');

    await disposeApp(tester);
  });

  testWidgets('收藏表情：点一下直接发（老端 chooseDiyEmoji）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      EmojiPaths.list,
      data: <Map<String, dynamic>>[
        <String, dynamic>{'src': 'https://a.test/sticker.png', 'file_id': 9},
      ],
    );
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await seedConversation();
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pumpAndSettle();
    // 分类条最左那颗心 = 收藏（老端那个「自定义表情」tab）
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();

    // 收藏表情也是一张网络图，加载失败会变成占位图标，直接点那个格子
    await tester.tap(find.byIcon(Icons.broken_image_outlined));
    await tester.pumpAndSettle();

    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['type'], 'emoji');
    expect(body['content'], 'https://a.test/sticker.png');
    expect(body['file_id'], 9);

    await disposeApp(tester);
  });

  testWidgets('引用：长按气泡 → 引用 → 引用条出现 → 请求体带 pid 与 extends', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await seedConversation();
    await db.upsertMessages(<Message>[localMessage(1, content: '在吗')]);
    await pumpApp(tester);

    // 长按气泡里的正文（气泡的中心可能在留白上，点不准）
    await tester.longPress(find.text('在吗'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();

    // 引用条显示「发送人：内容」
    expect(find.text('小明：在吗'), findsOneWidget);

    await type(tester, '在的');
    await tapSend(tester);

    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['pid'], 'm1');
    expect(body['extends'], <String, dynamic>{
      'msg_id': 'm1',
      'content': '小明：在吗',
      'user_id': 'u2',
      'realname': '小明',
    });

    await disposeApp(tester);
  });

  testWidgets('草稿：敲了不发，离开再回来还在（并且会话列表也有草稿）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    final container = await pumpApp(tester);

    await type(tester, '没发出去的半句');

    // 退回会话列表（等于离开聊天页）
    container.read(appRouterProvider).pop();
    await tester.pumpAndSettle();
    // 草稿是 dispose 里异步写库的（不能阻塞在 dispose 里等），多推一帧让它落地
    await tester.pump();

    final conversation = await db.findConversation('u2');
    expect(conversation!.draft, '没发出去的半句');

    // 再进来：草稿回到输入框
    container.read(appRouterProvider).push('/message/chat?id=u2');
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(ChatInput),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, '没发出去的半句');

    await disposeApp(tester);
  });

  testWidgets('群已禁言（普通成员）：点发送只提示，不发请求', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation(isGroup: 1, role: 3, nospeak: 1);
    await pumpApp(tester);

    await type(tester, '发不出去');
    await tapSend(tester);

    expect(adapter.paths, isNot(contains(ChatPaths.sendMessage)));
    expect(await db.messagesFor('u2'), isEmpty);

    await disposeApp(tester);
  });

  testWidgets('单聊：没有禁言这件事，正常发出去', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await seedConversation();
    await pumpApp(tester);

    await type(tester, 'hi');
    await tapSend(tester);

    expect(adapter.paths, contains(ChatPaths.sendMessage));

    await disposeApp(tester);
  });

  testWidgets('系统会话（is_group == 2）：没有输入框', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation(isGroup: 2);
    await pumpApp(tester);

    expect(find.byType(ChatInput), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('「+」面板：选一张图 → 上传 → 气泡出现在聊天里', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await seedConversation();
    // 上传要真的读一个文件（`MultipartFile.fromFile`），所以得有个真文件
    final file = File('${tempDir.path}/picked.png')
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
    await pumpApp(tester);

    // 没内容时右边是「+」（老端 `v-if="!inputMsg"`），点开是工具栏
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('相册'), findsOneWidget);
    expect(find.text('拍摄'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('个人名片'), findsOneWidget);

    picker.images = <PickedMedia>[
      PickedMedia(
        path: file.path,
        name: 'picked.png',
        size: 4,
        kind: MediaKind.image,
      ),
    ];
    // 不能用 pumpAndSettle：乐观消息上有个转圈（无限动画），永远等不到静止。
    await tester.tap(find.text('相册'));
    await tester.pump();

    // 落库那条的 content 是本地路径（先乐观显示自己选的图），状态是「发送中」
    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1));
    expect(stored.single.type, 'image');
    expect(stored.single.content, file.path);
    expect(stored.single.status, MessageStatus.going);
    // 面板关掉、回到「+」
    expect(find.text('相册'), findsNothing);
    expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);

    // 发图前会先过一遍压缩（S4.4c）—— 这里它原样放行，但"被调用了"要钉住
    expect(compressor.calls, hasLength(1));
    expect(compressor.calls.single.name, 'picked.png');

    // 这里**不断言上传请求**：上传要真读一遍文件（`MultipartFile.fromFile`），
    // 而组件测试跑在假时区里，真 I/O 的续点永远不会被投递（实测 pump+runAsync
    // 来回 10 轮也不行）。表单直传的字段/地址由 test/repo/media_send_test.dart
    // 在普通异步环境里断言。
    await disposeApp(tester);
  });

  testWidgets('发图前先压小：落库的本地图换成压完那张，名字也跟着实际格式', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await seedConversation();
    final original = File('${tempDir.path}/IMG_0001.heic')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    final compressed = File('${tempDir.path}/chat_abc.jpg')
      ..writeAsBytesSync(<int>[9, 9, 9]);
    // iPhone 拍的原图：体积大、后缀是 heic，压完是 jpg
    compressor.result = (media) => PickedMedia(
      path: compressed.path,
      name: compressedImageName(media.name),
      size: 300 * 1024,
      kind: media.kind,
    );
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    picker.images = <PickedMedia>[
      PickedMedia(
        path: original.path,
        name: 'IMG_0001.heic',
        size: 6 * 1024 * 1024,
        kind: MediaKind.image,
      ),
    ];
    await tester.tap(find.text('相册'));
    await tester.pump();

    expect(compressor.calls.single.path, original.path);
    final stored = await db.messagesFor('u2');
    expect(stored.single.content, compressed.path, reason: '发出去的是压完那张');
    expect(
      stored.single.extra['localPath'],
      compressed.path,
      reason: '重发也要用压完那张',
    );
    expect(
      stored.single.extra['fileName'],
      'IMG_0001.jpg',
      reason: '后缀跟着实际格式：服务端按后缀判它是不是图片',
    );

    await disposeApp(tester);
  });

  testWidgets('大小上限按**压完之后**算：20MB 的原图压成 300KB 就该放行', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await seedConversation();
    final original = File('${tempDir.path}/IMG_big.jpg')
      ..writeAsBytesSync(<int>[1]);
    final compressed = File('${tempDir.path}/chat_big.jpg')
      ..writeAsBytesSync(<int>[2]);
    compressor.result = (media) => PickedMedia(
      path: compressed.path,
      name: compressedImageName(media.name),
      size: 300 * 1024,
      kind: media.kind,
    );
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    picker.images = <PickedMedia>[
      PickedMedia(
        path: original.path,
        name: 'IMG_big.jpg',
        size: 20 * 1024 * 1024,
        kind: MediaKind.image,
      ),
    ];
    await tester.tap(find.text('相册'));
    await tester.pump();

    expect(find.textContaining('文件大小'), findsNothing);
    expect(await db.messagesFor('u2'), hasLength(1));

    await disposeApp(tester);
  });

  testWidgets('「+」面板：发一张名片（选好友 → 请求体带 extends；没选就提示）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await seedConversation();
    // 名片只能从好友里选（老端 `user-select :type="1"`），群聊不在候选里
    await db.upsertContacts(<Contact>[
      const Contact(
        id: 'u3',
        displayName: '小红',
        avatar: 'https://a.test/xh.png',
      ),
      const Contact(id: 'u4', displayName: '阿强'),
      const Contact(id: 'g9', displayName: '开发群', isGroup: 1),
    ]);
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('个人名片'), findsOneWidget);

    // 面板固定高度、条目会换行（S6.3 加了通话两项之后 6 个），
    // 名片在小屏上可能落在可视区外，先滚到它再点。
    await tester.ensureVisible(find.text('个人名片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('个人名片'));
    await tester.pumpAndSettle();
    expect(find.text('选择要分享的人'), findsOneWidget);
    expect(find.text('小红'), findsOneWidget);
    expect(find.text('阿强'), findsOneWidget);
    expect(find.text('开发群'), findsNothing);

    // 没选就点「完成」：照老端提示，弹层不关
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(notices.whereType<ToastNotice>().last.message, '必须选择一位联系人');
    expect(find.text('选择要分享的人'), findsOneWidget);

    // 选小红 → 完成：弹层关掉，消息乐观落库
    await tester.tap(find.text('小红'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('选择要分享的人'), findsNothing);
    expect(adapter.paths, contains(ChatPaths.sendMessage));
    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['type'], 'contact');
    expect(body['content'], '[个人名片] 小红');
    expect(body['extends'], <String, dynamic>{
      'avatar': 'https://a.test/xh.png',
      'displayName': '小红',
      'id': 'u3',
    });

    // 本地库里就是一条 contact；会话列表的预览也跟着变了
    final stored = await db.messagesFor('u2');
    expect(stored.single.type, 'contact');
    expect((await db.findConversation('u2'))?.lastType, 'contact');

    await disposeApp(tester);
  });

  testWidgets('收到名片：气泡上写着名字与「个人名片」', (tester) async {
    adapter.ok(
      ChatPaths.messageList,
      data: <Map<String, dynamic>>[
        <String, dynamic>{
          'msg_id': 'm1',
          'id': 1,
          'type': 'contact',
          'content': '[个人名片] 小红',
          'sendTime': baseTime,
          'from_user': 'u2',
          'fromUser': <String, dynamic>{'user_id': 'u2', 'displayName': '小明'},
          'extends': <String, dynamic>{
            'avatar': 'https://a.test/xh.png',
            'displayName': '小红',
            'id': 'u3',
          },
        },
      ],
    );
    await seedConversation();
    await pumpApp(tester);

    expect(find.text('小红'), findsOneWidget);
    expect(find.text('个人名片'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('超过服务端大小上限：只提示，不上传', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await seedConversation();
    await pumpApp(tester);

    // 默认上限 10MB（老端 `globalConfig.fileUpload.size ?? 10`）
    picker.images = <PickedMedia>[
      const PickedMedia(
        path: '/tmp/big.png',
        name: 'big.png',
        size: 11 * 1024 * 1024,
        kind: MediaKind.image,
      ),
    ];
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('相册'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.paths, isNot(contains(UploadPaths.file)));
    expect(await db.messagesFor('u2'), isEmpty);
    expect(notices.whereType<ToastNotice>().first.message, contains('10'));

    await disposeApp(tester);
  });

  testWidgets('视频超过 60 秒：只提示，不上传', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await seedConversation();
    await pumpApp(tester);

    picker.video = const PickedMedia(
      path: '/tmp/long.mp4',
      name: 'long.mp4',
      size: 1024,
      kind: MediaKind.video,
      durationSeconds: 61,
    );
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视频'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.paths, isNot(contains(UploadPaths.file)));
    expect(notices.whereType<ToastNotice>().first.message, contains('60'));

    await disposeApp(tester);
  });

  testWidgets('「＋」面板照微信摆：一行四个（第五个换行）+ 白方块灰底 + 微信那套图标/文案', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    // 文案用微信的：相册 / 拍摄 / 视频通话 / 语音通话 / 视频 / 文件 / 个人名片
    for (final label in <String>[
      '相册',
      '拍摄',
      '视频通话',
      '语音通话',
      '视频',
      '文件',
      '个人名片',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '面板里该有「$label」');
    }

    // 图标是微信那种**实心**字形（不是老端那些描边的）
    for (final icon in <IconData>[
      Icons.photo,
      Icons.photo_camera,
      Icons.videocam,
      Icons.call,
      Icons.video_library,
      Icons.folder,
      Icons.person,
    ]) {
      expect(find.byIcon(icon), findsOneWidget);
    }

    // 一行四个：前四个格子的标签在同一水平线上，第五个（视频）掉到第二行
    final rowOne = <String>['相册', '拍摄', '视频通话', '语音通话'];
    final tops = rowOne.map((l) => tester.getTopLeft(find.text(l)).dy).toSet();
    expect(tops, hasLength(1), reason: '微信是一行四个，四个标签应该齐平');
    expect(
      tester.getTopLeft(find.text('视频')).dy,
      greaterThan(tops.single),
      reason: '第五个该换行',
    );
    // 第二行的三个也齐平
    expect(
      tester.getTopLeft(find.text('文件')).dy,
      tester.getTopLeft(find.text('视频')).dy,
    );
    expect(
      tester.getTopLeft(find.text('个人名片')).dy,
      tester.getTopLeft(find.text('视频')).dy,
    );

    // 底是浅灰、格子是白方块（不是老端的白底灰格子）
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Container && widget.color == AppColors.panelBackground,
      ),
      findsOneWidget,
    );

    await disposeApp(tester);
  });

  testWidgets('「拍摄」：拍一张 → 走与相册同一条发送链路', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await seedConversation();
    final file = File('${tempDir.path}/IMG_camera.jpg')
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
    await pumpApp(tester);

    picker.camera = PickedMedia(
      path: file.path,
      name: 'IMG_camera.jpg',
      size: 4,
      kind: MediaKind.image,
    );
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拍摄'));
    await tester.pump();

    // 和相册选图一样：先乐观落库（发出去的是本机那张），面板收起
    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1));
    expect(stored.single.type, 'image');
    expect(stored.single.content, file.path);
    expect(find.text('拍摄'), findsNothing);
    // 压缩那一步也一样过（S4.4c）
    expect(compressor.calls, hasLength(1));
    expect(compressor.calls.single.name, 'IMG_camera.jpg');

    await disposeApp(tester);
  });

  testWidgets('「拍摄」：用户在相机里取消 → 什么都不发，面板还开着（与相册选图同口径）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拍摄'));
    await tester.pump();

    expect(await db.messagesFor('u2'), isEmpty);
    expect(compressor.calls, isEmpty);
    // 取消与「相册选图」一个口径：面板不收（`_pick` 也是如此），什么也不发
    expect(find.text('拍摄'), findsOneWidget);

    await disposeApp(tester);
  });
}

/// 图片压缩的替身。
///
/// 默认**原样放行**（其它用例的路径/体积断言因此不受影响），需要验「压缩真的被调用、
/// 发出去的是压完那张」时再设 [result]。
class FakeImageCompressor implements ImageCompressor {
  final List<PickedMedia> calls = <PickedMedia>[];
  PickedMedia Function(PickedMedia media)? result;

  @override
  Future<PickedMedia> compress(PickedMedia media) async {
    calls.add(media);
    return result?.call(media) ?? media;
  }
}

/// 选媒体的替身：想返回什么就填什么，不弹系统选择器。
class FakeMediaPicker implements MediaPicker {
  List<PickedMedia> images = const <PickedMedia>[];
  PickedMedia? video;
  List<PickedMedia> files = const <PickedMedia>[];

  @override
  Future<List<PickedMedia>> pickImages({int limit = 9}) async => images;

  @override
  Future<PickedMedia?> pickVideo() async => video;

  /// 「拍摄」拍出来的那张（默认不拍）
  PickedMedia? camera;

  @override
  Future<PickedMedia?> pickCamera() async => camera;

  @override
  Future<List<PickedMedia>> pickFiles({int limit = 5}) async => files;
}
