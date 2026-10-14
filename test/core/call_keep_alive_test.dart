import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/call_keep_alive.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通话保活的 Dart 侧（S6.5）：把「起/停/查状态」翻译成对 Kotlin 前台服务的调用。
///
/// Kotlin 那半只有真机能跑，所以这里验的是**接口契约**：发给平台通道的参数对不对
/// （通知文案跟着语言与语音/视频走）、出错时谁能兜住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Map<String, Object?> results;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');

    calls = <MethodCall>[];
    results = <String, Object?>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('gracelinkim/call_service'),
          (call) async {
            calls.add(call);
            return results[call.method];
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('gracelinkim/call_service'),
          null,
        );
  });

  group('安卓实现', () {
    // 起服务是异步的，实现里会轮询读回状态；测试里把窗口缩短、状态直接给定
    const keepAlive = AndroidCallKeepAlive(
      startTimeout: Duration(milliseconds: 400),
      pollInterval: Duration(milliseconds: 20),
    );

    test('起服务：通知文案按语言与语音/视频拼好（名字也带上），并确认真的起来了', () async {
      expect(keepAlive.supported, isTrue);
      results['isRunning'] = true;

      await keepAlive.start(video: false, peerName: '老B');
      await keepAlive.start(video: true, peerName: '老B');

      // 每条 start 后面跟一次读回确认
      expect(calls.first.method, 'start');
      expect(
        calls.where((call) => call.method == 'start').length,
        2,
        reason: '两次 start（语音 + 视频）',
      );
      expect(calls.any((call) => call.method == 'isRunning'), isTrue);
      final voice =
          calls.firstWhere((call) => call.method == 'start').arguments
              as Map<Object?, Object?>;
      expect(voice['video'], isFalse);
      expect(voice['title'], '与 老B 语音通话中');
      expect(voice['text'], '点击回到通话');

      final video =
          calls.lastWhere((call) => call.method == 'start').arguments
              as Map<Object?, Object?>;
      expect(video['video'], isTrue);
      expect(video['title'], '与 老B 视频通话中');
    });

    test('服务没起来（读回一直是 false）→ start 抛，而不是假装成功', () async {
      // 真机上系统可能拒绝 mic 类型的前台服务（比如从后台启动），那种情况
      // 必须能区分出来：假装成功比失败更难查
      await expectLater(
        keepAlive.start(video: false, peerName: '老B'),
        throwsA(isA<CallKeepAliveException>()),
      );
    });

    test('停服务 / 查状态 / 查权限 / 申请权限都走同一条通道', () async {
      results['isRunning'] = true;
      results['notificationPermission'] = false;
      results['requestNotificationPermission'] = false;

      await keepAlive.stop();
      expect(await keepAlive.isRunning(), isTrue);
      // 「没给权限」要如实返回（诊断面板据此提示），但不能炸
      expect(await keepAlive.hasNotificationPermission(), isFalse);
      // 申请走另一条方法名：通话路径只查不申请（权限框会把 App 顶到后台）
      expect(await keepAlive.requestNotificationPermission(), isFalse);

      expect(calls.map((call) => call.method), <String>[
        'stop',
        'isRunning',
        'notificationPermission',
        'requestNotificationPermission',
      ]);
    });

    test('共享屏幕：发「开了/停了」与通知文案，并读回类型位确认升降完才返回', () async {
      await keepAlive.setScreenSharing(enabled: true);
      await keepAlive.setScreenSharing(enabled: false);

      // 每一次都要跟一次读回：`startService` 是异步的，发完就走等于没升
      expect(calls.map((call) => call.method), <String>[
        'screenSharing',
        'foregroundTypes',
        'screenSharing',
        'foregroundTypes',
      ]);
      final sharing = calls
          .where((call) => call.method == 'screenSharing')
          .toList(growable: false);
      final on = sharing.first.arguments as Map<Object?, Object?>;
      expect(on['enabled'], isTrue);
      // 共享期间通知里那句换掉（还是同一颗通知，不会多出第二条）
      expect(on['text'], '正在共享屏幕');
      final off = sharing.last.arguments as Map<Object?, Object?>;
      expect(off['enabled'], isFalse);
      expect(off['text'], '点击回到通话');
    });

    test('屏幕共享：类型位还没升上去时一直等到它升上去（“第一次点必失败”那个坑）', () async {
      var probes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('gracelinkim/call_service'),
            (call) async {
              calls.add(call);
              if (call.method != 'foregroundTypes') return null;
              probes += 1;
              // 前两次读回还没有投影位（服务还在异步 startForeground 的路上）
              return probes < 3 ? 1 : 33;
            },
          );

      await keepAlive.setScreenSharing(enabled: true);

      expect(probes, greaterThanOrEqualTo(3), reason: '必须读回确认，不能发完就走');
    });

    test('屏幕共享：类型位一直升不上去就抛（调用方据此不去取一个注定抛异常的投影）', () async {
      const impatient = AndroidCallKeepAlive(
        pollInterval: Duration(milliseconds: 20),
        typeTimeout: Duration(milliseconds: 200),
      );
      results['foregroundTypes'] = 1; // 一直只有 mic 位

      await expectLater(
        impatient.setScreenSharing(enabled: true),
        throwsA(isA<CallKeepAliveException>()),
      );
    });

    test('通道报「系统不让起服务」时收成 CallKeepAliveException（带系统原文）；查状态失败一律当没在跑', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('gracelinkim/call_service'),
            (call) async => throw PlatformException(
              code: 'ForegroundServiceStartNotAllowedException',
              message: '不允许从后台启动 mic 类型的前台服务',
            ),
          );

      // ⚠️ 2026-10-13：原生侧把这类系统拒绝翻成 PlatformException 回上来
      //（以前是未捕获的 Java 异常 = 进程当场死 = 用户看到「一打电话就闪退」）。
      // Dart 侧必须收成 [CallKeepAliveException]：系统原文进诊断面板，通话自己继续。
      await expectLater(
        keepAlive.start(video: false, peerName: '老B'),
        throwsA(
          isA<CallKeepAliveException>().having(
            (error) => error.message,
            'message',
            contains('不允许从后台启动 mic 类型的前台服务'),
          ),
        ),
      );
      expect(await keepAlive.isRunning(), isFalse);
      expect(await keepAlive.hasNotificationPermission(), isFalse);
      expect(await keepAlive.requestNotificationPermission(), isFalse);
    });
  });

  group('iOS 实现（后台音频会话）', () {
    const keepAlive = IosCallKeepAlive();
    const channel = MethodChannel('gracelinkim/call_service');

    test('起保活只发「是不是视频通话」—— iOS 没有那条常驻通知，不该编文案', () async {
      expect(keepAlive.supported, isTrue);

      await keepAlive.start(video: false, peerName: '老B');
      await keepAlive.start(video: true, peerName: '老B');

      expect(calls.map((call) => call.method), <String>['start', 'start']);
      final voice = calls.first.arguments as Map<Object?, Object?>;
      expect(voice['video'], isFalse);
      // title / text 是安卓常驻通知里那两行字，iOS 没有地方用它们
      expect(voice.containsKey('title'), isFalse);
      expect(voice.containsKey('text'), isFalse);
      expect((calls.last.arguments as Map<Object?, Object?>)['video'], isTrue);
    });

    test('与安卓不同：**不用轮询确认**（setActive 是同步的，回执就是结论）', () async {
      await keepAlive.start(video: false, peerName: '老B');
      expect(calls.where((call) => call.method == 'isRunning'), isEmpty);
    });

    test('音频会话起不来 → 带系统原文的 CallKeepAliveException（通话自己继续）', () async {
      // 真机上常见的原因是别的应用占着会话（导航、录音），或系统不允许激活
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => throw PlatformException(
              code: 'audio_session',
              message: '会话被别的应用占着，激活失败',
            ),
          );

      await expectLater(
        keepAlive.start(video: false, peerName: '老B'),
        throwsA(
          isA<CallKeepAliveException>().having(
            (error) => error.message,
            'message',
            contains('会话被别的应用占着'),
          ),
        ),
      );
      expect(await keepAlive.isRunning(), isFalse);
    });

    test('旧包里还没有这条通道（MissingPluginException）也收成同一个异常', () async {
      // 不接的话，一个 MissingPluginException 会从通话路径里冒出去，
      // 而那类异常在别的封装里是被当成「平台不支持」默默咽掉的
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      await expectLater(
        keepAlive.start(video: false, peerName: '老B'),
        throwsA(isA<CallKeepAliveException>()),
      );
    });

    test('停 / 查状态 / 查权限 / 申请权限都走同一条通道', () async {
      results['isRunning'] = true;
      results['notificationPermission'] = false;
      results['requestNotificationPermission'] = true;

      await keepAlive.stop();
      expect(await keepAlive.isRunning(), isTrue);
      expect(await keepAlive.hasNotificationPermission(), isFalse);
      expect(await keepAlive.requestNotificationPermission(), isTrue);

      expect(calls.map((call) => call.method), <String>[
        'stop',
        'isRunning',
        'notificationPermission',
        'requestNotificationPermission',
      ]);
    });

    test('投屏在 iOS 上什么都不做（没有类型位可升，更不能假装升好了）', () async {
      await keepAlive.setScreenSharing(enabled: true);
      await keepAlive.setScreenSharing(enabled: false);
      expect(calls, isEmpty);
    });
  });

  group('没有保活的平台（桌面）', () {
    test('空实现：什么都不做，也不会抛', () async {
      const keepAlive = NoopCallKeepAlive();
      expect(keepAlive.supported, isFalse);
      expect(keepAlive.start(video: true, peerName: '老B'), completes);
      expect(keepAlive.stop(), completes);
      expect(await keepAlive.isRunning(), isFalse);
      expect(await keepAlive.hasNotificationPermission(), isTrue);
      expect(await keepAlive.requestNotificationPermission(), isTrue);
      expect(keepAlive.setScreenSharing(enabled: true), completes);
      expect(calls, isEmpty);
    });
  });
}
