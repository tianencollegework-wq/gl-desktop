import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/audio/speech_to_text.dart';
import 'package:gracelinkim/core/audio/voice_recorder.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/widgets/chat_input.dart';
import 'package:gracelinkim/features/chat/widgets/voice_record_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';
import '../support/widget_ancestors.dart';

/// 按住说话（S4.4c）：录音、上滑取消、太短丢掉、权限被拒。
///
/// 真机会弹麦克风权限、录真音频，所以录音器在测试里换成替身
/// （与选图/选文件、语音播放同一个做法）。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late FakeVoiceRecorder recorder;
  late FakeSpeechToText speech;
  late List<AppNotice> notices;
  late StreamSubscription<AppNotice> noticeSub;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    recorder = FakeVoiceRecorder();
    speech = FakeSpeechToText();
    notices = <AppNotice>[];
    noticeSub = noticeBus.stream.listen(notices.add);
    sessionGuard.update(ready: true, hasSession: true);
    tempDir = await Directory.systemTemp.createTemp('gracelink-voice-ui');
  });

  tearDown(() async {
    await noticeSub.cancel();
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException catch (_) {
      // 忽略
    }
  });

  const baseTime = 1700000000000;

  Future<void> seedConversation({int isGroup = 0}) => db.upsertConversation(
    Conversation(
      id: 'u2',
      displayName: '小明',
      isGroup: isGroup,
      role: 3,
      lastSendTime: baseTime,
      lastContent: '你好',
    ),
  );

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> pumpApp(WidgetTester tester, {bool desktop = false}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          voiceRecorderProvider.overrideWithValue(recorder),
          speechToTextProvider.overrideWithValue(speech),
          // 桌面档（S12.38）：录音浮层换成固定像素的卡片那一套
          if (desktop) desktopFeaturesProvider.overrideWithValue(true),
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

  /// 切到录音模式（老端那个麦克风/键盘切换按钮）
  Future<void> enterVoiceMode(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.mic_none_outlined));
    await tester.pumpAndSettle();
  }

  /// 按住「按住说话」，返回手势对象（让用例自己决定松手还是上滑）
  Future<TestGesture> hold(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('按住说话')),
    );
    await tester.pump();
    return gesture;
  }

  testWidgets('按住 → 松开：发出去一条语音（本地路径 + 时长）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await seedConversation();
    // 录音器「录」出一份真文件，后面上传要用
    final file = File('${tempDir.path}/gl_voice.m4a')
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
    recorder.result = Recording(
      path: file.path,
      durationMs: 4000,
      sizeBytes: 4,
    );
    await pumpApp(tester);

    // 默认是输入框，没有「按住说话」
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('按住说话'), findsNothing);

    await enterVoiceMode(tester);
    expect(find.text('按住说话'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: '录音模式下没有输入框');

    final gesture = await hold(tester);
    // 按住后：输入框那行变成「松开发送」，整屏浮层也上来了
    // 两处：输入框那行（带秒数）与浮层底部托盘
    expect(find.textContaining('松开发送'), findsWidgets);
    expect(recorder.startCalls, 1);
    expect(find.byType(VoiceRecordOverlay), findsOneWidget);

    // 浮层挂在根 Overlay 上（祖先里没有 Material）：少包一层的话，里面所有文字
    // 都会掉进 `MaterialApp` 的调试样式（红字 + 两条黄色下划线，2026-09-30 报过），
    // 这里钉住离浮层文字最近的那层 Material 就是它自己包的。
    expect(
      nearestMaterialOf(tester.element(find.text('滑到这里 转文字')))?.type,
      MaterialType.transparency,
    );

    // 走 3 秒（老端那 1 秒一跳的计数器）
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('松开发送 3″'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // 落库：type 是 voice、content 是本地文件、时长在 extends 里、状态发送中
    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1));
    expect(stored.single.type, 'voice');
    expect(stored.single.content, file.path);
    expect(stored.single.ext['duration'], 4);
    expect(stored.single.status, MessageStatus.going);
    expect(stored.single.extra['localPath'], file.path);
    expect(stored.single.extra['fileName'], endsWith('.m4a'));
    // 松手后按钮回到「按住说话」
    expect(find.text('按住说话'), findsOneWidget);

    // 上传请求不在组件测试里断言（真文件 I/O 在假时区推不动，见规划书的踩坑清单），
    // 表单直传的字段由 test/repo/voice_send_test.dart 覆盖。
    await disposeApp(tester);
  });

  testWidgets('录满 60 秒：自动停下并发送', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await seedConversation();
    recorder.result = Recording(
      path: '${tempDir.path}/gl_voice.m4a',
      durationMs: 60000,
      sizeBytes: 480000,
    );
    await pumpApp(tester);
    await enterVoiceMode(tester);

    final gesture = await hold(tester);
    await tester.pump(const Duration(seconds: 60));

    // 到点自己停了（不用抬手）
    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1));
    expect(stored.single.ext['duration'], 60);
    expect(find.textContaining('松开发送'), findsNothing);

    await gesture.up();
    await tester.pump();
    await disposeApp(tester);
  });

  testWidgets('按住时出现微信那套全屏浮层（声波气泡 + 取消/转文字两区）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await pumpApp(tester);
    await enterVoiceMode(tester);

    expect(find.byType(VoiceRecordOverlay), findsNothing);
    final gesture = await hold(tester);
    await tester.pump();

    expect(find.byType(VoiceRecordOverlay), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('滑到这里 转文字'), findsOneWidget);
    expect(find.text('松开发送'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await disposeApp(tester);
  });

  testWidgets('桌面档：底部那张紧凑卡片（固定像素）+ 短武装线', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    // 桌面窗口 1280x900 逻辑（dpr=1：断言里的宽度就是逻辑宽度），
    // 于是 `realWindowWidth` ≥ 900 → 走桌面那一档
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester, desktop: true);
    await enterVoiceMode(tester);

    final gesture = await hold(tester);
    await tester.pump();

    // 桌面是底部居中一张卡片；手机那套（整屏压暗 + 中间大泡泡）一个都不画
    expect(find.byKey(const Key('voice-record-desktop')), findsOneWidget);
    expect(find.byKey(const Key('voice-record-phone')), findsNothing);
    expect(find.byKey(const Key('voice-record-scrim')), findsNothing);
    expect(find.byKey(const Key('voice-record-card')), findsOneWidget);
    // 卡片是**固定逻辑像素**（不吃 rpx）：真机上窗口一宽就撑成一张巨画，
    // 就是手机那套 rpx 尺寸照搬到桌面来的后果
    expect(
      tester.getSize(find.byKey(const Key('voice-record-card'))).width,
      VoiceRecordOverlay.desktopCardWidth,
    );

    // 武装线比手机那 220rpx 短得多：从按钮往上挪 100 逻辑像素就已经在「取消」区
    // （手机那条线在 1280 宽的窗口里是 rpx(220)=375，同一位置还停在「松开发送」）
    final height = tester.getSize(find.byType(MaterialApp)).height;
    await gesture.moveTo(Offset(100, height - 100));
    await tester.pump();
    // 卡片那行是「秒数 · 提示」（见 `_desktopBody`），所以按子串找
    expect(find.textContaining('松开取消'), findsOneWidget);
    expect(recorder.cancelCalls, 0, reason: '还没松手，什么都不该发生');

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(recorder.cancelCalls, 1);
    expect(await db.messagesFor('u2'), isEmpty);
    await disposeApp(tester);
  });

  testWidgets('滑到左下角「取消」：什么都不发', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await pumpApp(tester);
    await enterVoiceMode(tester);

    final gesture = await hold(tester);
    // 新规矩（照微信）：往**左上**滑过武装线 → 取消区
    await gesture.moveTo(const Offset(100, 300));
    await tester.pump();
    expect(find.text('松开取消'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(recorder.cancelCalls, 1);
    expect(await db.messagesFor('u2'), isEmpty);
    expect(find.text('按住说话'), findsOneWidget);
    expect(find.byType(VoiceRecordOverlay), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('滑到右下角「转文字」：识别结果直接填进输入框，不发语音', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await seedConversation();
    recorder.result = Recording(
      path: '${tempDir.path}/voice.m4a',
      durationMs: 2400,
      sizeBytes: 900,
    );
    speech.text = '明天下午三点开会';
    await pumpApp(tester);
    await enterVoiceMode(tester);

    final gesture = await hold(tester);
    // 往**右上**滑：滑到这里 转文字
    await gesture.moveTo(const Offset(700, 300));
    await tester.pump();
    expect(find.text('松开转文字'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();

    // 文本进了输入框，语音没有发出去（用户要的是「识别到什么就显示什么」）
    expect(speech.calls, hasLength(1));
    expect(speech.calls.single, endsWith('voice.m4a'));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '明天下午三点开会',
    );
    expect(await db.messagesFor('u2'), isEmpty);
    expect(recorder.discarded, hasLength(1));
    expect(find.byType(VoiceRecordOverlay), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('转文字失败：提示，输入框保持空的', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    recorder.result = Recording(
      path: '${tempDir.path}/voice.m4a',
      durationMs: 2400,
      sizeBytes: 900,
    );
    speech.error = const SpeechToTextException('HTTP 401', statusCode: 401);
    await pumpApp(tester);
    await enterVoiceMode(tester);

    final gesture = await hold(tester);
    await gesture.moveTo(const Offset(700, 300));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();

    expect(notices.whereType<ToastNotice>().last.message, '转文字失败，请重试');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );

    await disposeApp(tester);
  });

  testWidgets('太短（不到 1 秒）：提示并丢掉', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    recorder.result = Recording(
      path: '${tempDir.path}/short.m4a',
      durationMs: 400,
      sizeBytes: 10,
    );
    await pumpApp(tester);
    await enterVoiceMode(tester);

    final gesture = await hold(tester);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(await db.messagesFor('u2'), isEmpty);
    expect(recorder.discarded, hasLength(1));
    expect(notices.whereType<ToastNotice>().first.message, '录音时间太短');

    await disposeApp(tester);
  });

  testWidgets('麦克风权限被拒：只提示，不启动录音', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    recorder.permission = false;
    await pumpApp(tester);
    await enterVoiceMode(tester);

    final gesture = await hold(tester);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(recorder.startCalls, 0);
    expect(await db.messagesFor('u2'), isEmpty);
    expect(notices.whereType<ToastNotice>().first.message, contains('麦克风权限'));

    await disposeApp(tester);
  });

  testWidgets('群已禁言：按住了也不录', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      const Conversation(
        id: 'u2',
        displayName: '同学群',
        isGroup: 1,
        role: 3,
        extra: <String, dynamic>{
          'setting': <String, dynamic>{'nospeak': 1},
        },
      ),
    );
    await pumpApp(tester);

    // 禁言时输入区还在（老端也在），只是不能发
    expect(find.byType(ChatInput), findsOneWidget);
    await enterVoiceMode(tester);
    final gesture = await hold(tester);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(recorder.startCalls, 0);
    expect(await db.messagesFor('u2'), isEmpty);
    expect(notices.whereType<ToastNotice>().first.message, contains('禁言'));

    await disposeApp(tester);
  });
}

/// 录音器替身：不碰麦克风，直接给一份「录好的文件」
class FakeVoiceRecorder implements VoiceRecorder {
  FakeVoiceRecorder();

  bool permission = true;
  int startCalls = 0;
  int cancelCalls = 0;
  final List<Recording> discarded = <Recording>[];

  /// [stop] 返回什么
  Recording? result;

  /// 假音量流（浮层画声波用）
  final StreamController<double> amplitudeController =
      StreamController<double>.broadcast();

  @override
  Stream<double> get amplitude => amplitudeController.stream;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start() async {
    startCalls += 1;
  }

  @override
  Future<Recording?> stop() async => result;

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
  }

  @override
  Future<void> discard(Recording recording) async {
    discarded.add(recording);
  }

  @override
  Future<void> dispose() async {
    await amplitudeController.close();
  }
}

/// 转文字替身：不联网，直接回一段文本（或抛一个错）
class FakeSpeechToText implements SpeechToTextService {
  /// 每次调用传进来的音频路径
  final List<String> calls = <String>[];

  String text = '';
  Object? error;

  @override
  Future<String> transcribe(String filePath) async {
    calls.add(filePath);
    final failure = error;
    if (failure != null) throw failure;
    return text;
  }
}
