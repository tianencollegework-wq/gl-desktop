import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/callkit.dart';

/// 系统来电界面（CallKit）的 **Dart 侧契约**（2026-10-15）。
///
/// Swift 那半只有真机能跑（模拟器上 CallKit 根本不工作），所以这里钉的是
/// **接口那一层** —— 也就是「谁也不能在别处把这几件事写错」的那一层：
///
/// * 发给平台通道的参数对不对（哪几个字段、名字有没有差一个字）；
/// * 系统没接住（模拟器 / 旧包 `MissingPluginException`）时**不抛**、
///   但把原因如实带上去 —— 那种失败不让通话黄掉，可它也不能变成一句「不知道」；
/// * 系统那一侧的动作怎么回来（接听 / 挂断 / 推送叫醒 / token），
///   以及「摘掉监听之后还会不会收到」与「只有一个实例能装平台回调」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('gracelinkim/callkit');

  late List<MethodCall> calls;
  late Map<String, Object?> results;
  late IosCallKit callKit;

  /// 假装原生那边叫了 Dart 一次（系统界面上的动作就是这么回来的）
  Future<void> fromNative(String method, Object? arguments) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (data) {},
        );
  }

  setUp(() {
    calls = <MethodCall>[];
    results = <String, Object?>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return results[call.method];
        });
    callKit = IosCallKit();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('上报来电', () {
    test('参数原样发过去，系统的结论如实翻回来', () async {
      results['reportIncomingCall'] = <String, Object?>{
        'ok': true,
        'reason': '',
        'callId': 'UUID-1',
        'alreadyReported': false,
      };

      final report = await callKit.reportIncomingCall(
        callId: 'call-9',
        peerId: '22',
        peerName: '老B',
        video: true,
        payload: '{"id":"call-9"}',
      );

      final sent = calls.single.arguments as Map<Object?, Object?>;
      expect(sent['callId'], 'call-9');
      expect(sent['peerId'], '22');
      expect(sent['peerName'], '老B');
      expect(sent['video'], isTrue);
      expect(sent['payload'], '{"id":"call-9"}');

      expect(report.accepted, isTrue);
      expect(report.callId, 'UUID-1');
      expect(report.alreadyReported, isFalse);
    });

    test('系统没接住时**不抛**，但把系统原话带上去（模拟器上必然走这条）', () async {
      results['reportIncomingCall'] = <String, Object?>{
        'ok': false,
        'reason': 'CallKit is not available in the simulator',
      };

      final report = await callKit.reportIncomingCall(
        callId: 'call-9',
        peerId: '22',
        peerName: '老B',
        video: false,
      );

      expect(report.accepted, isFalse);
      // 「为什么没弹出来」必须能一路查到系统原话 —— 否则只剩「不知道」
      expect(report.reason, contains('simulator'));
    });

    test('同一通报两次：原生说已经报过了，就不再弹一个', () async {
      results['reportIncomingCall'] = <String, Object?>{
        'ok': true,
        'callId': 'UUID-1',
        'alreadyReported': true,
      };

      final report = await callKit.reportIncomingCall(
        callId: 'call-9',
        peerId: '22',
        peerName: '老B',
        video: false,
      );

      expect(report.accepted, isTrue);
      expect(report.alreadyReported, isTrue);
    });

    test('旧安装包（没有这条通道）当成「没接住」，不抛', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      final report = await callKit.reportIncomingCall(
        callId: 'call-9',
        peerId: '22',
        peerName: '老B',
        video: false,
      );

      expect(report.accepted, isFalse);
      expect(report.reason, contains('旧版本'));
    });
  });

  group('收尾与查询', () {
    test('结束原因发给原生；原生出错也**不抛**（通话已经结束了，收尾失败不该搅黄它）', () async {
      results['reportEnded'] = null;
      await callKit.reportEnded(callId: 'call-9', reason: 'declined');

      final sent = calls.single.arguments as Map<Object?, Object?>;
      expect(sent['callId'], 'call-9');
      expect(sent['reason'], 'declined');

      // 原生侧抛错：Dart 这边必须安静收下（只留一行日志）
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'boom', message: '关不掉');
          });
      await expectLater(callKit.reportEnded(callId: 'call-9'), completes);
    });

    test('取暂存的来电与 VoIP token：拿不到时回空串，不抛', () async {
      results['takePendingCall'] = '{"id":"call-9"}';
      results['voipToken'] = 'abcd';

      expect(await callKit.takePendingCall(), '{"id":"call-9"}');
      expect(await callKit.voipToken(), 'abcd');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await callKit.takePendingCall(), '');
      expect(await callKit.voipToken(), '');
    });

    test('失败原话能读到（诊断面板那一行靠它）', () async {
      results['lastError'] = 'CallKit 不在模拟器上跑';
      expect(await callKit.lastError(), 'CallKit 不在模拟器上跑');
    });
  });

  group('系统那一侧的动作', () {
    test('接听 / 挂断 / 推送叫醒 / token 四种都能回来', () async {
      final seen = <CallKitAction>[];
      callKit.addActionListener(seen.add);
      // 收尾：这个实例是**进程级共享**的那一份（见 IosCallKit 的注释），
      // 留着的监听会漏给同一个文件里后面的用例
      addTearDown(() => callKit.removeActionListener(seen.add));

      await fromNative('action', <String, Object?>{
        'kind': 'answer',
        'callId': 'call-9',
      });
      await fromNative('action', <String, Object?>{
        'kind': 'end',
        'callId': 'call-9',
      });
      await fromNative('action', <String, Object?>{
        'kind': 'incoming',
        'callId': 'call-9',
        'payload': '{"id":"call-9"}',
      });
      await fromNative('action', <String, Object?>{
        'kind': 'token',
        'token': 'ff00',
      });

      expect(seen.map((a) => a.kind), <CallKitActionKind>[
        CallKitActionKind.answer,
        CallKitActionKind.end,
        CallKitActionKind.incoming,
        CallKitActionKind.token,
      ]);
      expect(seen[2].payload, '{"id":"call-9"}');
      expect(seen[3].token, 'ff00');
    });

    test('不认识的动作 / 旧包里没有的动作直接忽略，不崩', () async {
      final seen = <CallKitAction>[];
      callKit.addActionListener(seen.add);
      addTearDown(() => callKit.removeActionListener(seen.add));

      await fromNative('action', <String, Object?>{'kind': 'wakeup'});
      await fromNative('action', 'not-a-map');
      await fromNative('somethingElse', <String, Object?>{'kind': 'answer'});

      expect(seen, isEmpty);
    });

    test('摘掉监听之后不再收到（回调留着，但没人听就不分发）', () async {
      final seen = <CallKitAction>[];
      void listener(CallKitAction action) => seen.add(action);

      callKit.addActionListener(listener);
      await fromNative('action', <String, Object?>{'kind': 'answer'});
      callKit.removeActionListener(listener);
      await fromNative('action', <String, Object?>{'kind': 'end'});

      expect(seen.single.kind, CallKitActionKind.answer);
    });

    test('不传通道时拿到的是同一份实例（两个实例会互相顶掉平台回调）', () async {
      expect(identical(IosCallKit(), IosCallKit()), isTrue);
      // 显式给通道才另建：那是单测 / 自检注入用的那条路
      expect(
        identical(
          IosCallKit(channel: const MethodChannel('gracelinkim/callkit')),
          IosCallKit(),
        ),
        isFalse,
      );
    });
  });

  group('没有 CallKit 的平台', () {
    const noop = NoopCallKit();

    test('支持的标成 false，调用一律安全（界面靠它决定画不画说明）', () async {
      expect(noop.supported, isFalse);
      final report = await noop.reportIncomingCall(
        callId: 'x',
        peerId: '1',
        peerName: '老B',
        video: false,
      );
      expect(report.accepted, isFalse);
      expect(report.reason, isNotEmpty);
      await noop.reportEnded(callId: 'x');
      expect(await noop.takePendingCall(), '');
      expect(await noop.voipToken(), '');
      expect(await noop.lastError(), '');
    });
  });
}
