import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';
import 'package:gracelinkim/features/call/call_desktop_page.dart';
import 'package:gracelinkim/features/call/call_window.dart';
import 'package:gracelinkim/features/call/call_window_bridge.dart';
import 'package:gracelinkim/features/call/call_window_host.dart';
import 'package:gracelinkim/features/call/call_window_media_engine.dart';
import 'package:gracelinkim/features/call/widgets/call_round_button.dart';
import 'package:gracelinkim/features/desktop_window/window_args.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_call_media.dart';

/// 通话独立窗口（2026-10-04，用户：「请将通话做到新开一个独立窗口」）。
///
/// 四块各钉几条：
/// * 窗口参数（对端/语音还是视频/ICE 列表）编得出去、解得回来；
/// * 主窗口推给窗口的那份状态编解码（认不出的阶段不能把界面搞崩）；
/// * 媒体代理：指令原样转出去、窗口报的流翻译成引擎回调、窗口起不来退回本地引擎；
/// * 窗口里那张界面：第一屏来自窗口参数、主窗口推状态就跟着变、点挂断真的把
///   动作送回主窗口；
/// * ✕：先请主窗口按挂断收尾、再放媒体、最后才关窗（原生先问一声那条路，
///   S12.29 —— 顺序换一下整个 app 会跟着 webrtc 一起 abort）。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 窗口里那份界面拿的是 `appI18nProvider`，它背后要凭据（语言）；
    // 不初始化就在组件树里抛（见 `call_page_test.dart` 同一处）
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
  });

  group('窗口参数', () {
    test('通话窗的对端/语音还是视频/ICE 列表都能原样过一遍', () {
      const args = DesktopWindowArgs.call(
        peerId: 'peer-9',
        peerName: 'Gracelink Team',
        peerAvatar: 'https://cdn.example.com/a.png',
        video: true,
        isCaller: true,
        iceServers: <Map<String, dynamic>>[
          <String, dynamic>{'urls': 'stun:stun.example.com:3478'},
          <String, dynamic>{
            'urls': 'turn:turn.example.com:3478',
            'username': 'u',
            'credential': 'c',
          },
        ],
      );

      final decoded = DesktopWindowArgs.decode(args.encode())!;
      expect(decoded.kind, DesktopWindowKind.call);
      expect(decoded.id, 'peer-9');
      expect(decoded.title, 'Gracelink Team');
      expect(decoded.avatar, 'https://cdn.example.com/a.png');
      expect(decoded.video, isTrue);
      expect(decoded.isCaller, isTrue);
      expect(decoded.iceServers, hasLength(2));
      expect(decoded.iceServers.first['urls'], 'stun:stun.example.com:3478');
      expect(decoded.iceServers.last['credential'], 'c');
    });

    test('语音、被叫、没有 ICE 时也不会往参数里塞空东西', () {
      const args = DesktopWindowArgs.call(
        peerId: 'peer-1',
        peerName: '小明',
        video: false,
        isCaller: false,
      );
      final encoded = args.encode();
      expect(encoded, isNot(contains('ice=')));
      expect(encoded, isNot(contains('video=')));

      final decoded = DesktopWindowArgs.decode(encoded)!;
      expect(decoded.video, isFalse);
      expect(decoded.isCaller, isFalse);
      expect(decoded.iceServers, isEmpty);
    });
  });

  group('状态编解码', () {
    test('主窗口那份状态过一趟还能原样还原', () {
      final view = CallViewState(
        session: const CallSession(
          phase: CallPhase.connected,
          peerId: 'peer-1',
          peerName: 'Gracelink Team',
          peerAvatar: 'a.png',
          type: CallType.video,
          isCaller: true,
          callTime: 75,
        ),
        microphoneEnabled: false,
        cameraEnabled: true,
        hasLocalStream: true,
        hasRemoteStream: true,
        remoteBig: true,
        canShareScreen: true,
        screenSharing: true,
      );

      final restored = callViewStateFrom(callStatePayload(view));
      expect(restored.session.phase, CallPhase.connected);
      expect(restored.session.peerName, 'Gracelink Team');
      expect(restored.session.isVideo, isTrue);
      expect(restored.session.callTime, 75);
      expect(restored.microphoneEnabled, isFalse);
      expect(restored.hasLocalStream, isTrue);
      expect(restored.hasRemoteStream, isTrue);
      expect(restored.remoteBig, isTrue);
      // 桌面共享屏幕那两颗钮的判据就从这两个字段来（界面只看状态）
      expect(restored.canShareScreen, isTrue);
      expect(restored.screenSharing, isTrue);
    });

    test('认不出的阶段当 idle（界面不能因为一条报文没看懂就崩）', () {
      final restored = callViewStateFrom(<String, dynamic>{
        'phase': '这不是阶段',
        'peerName': '小明',
      });
      expect(restored.session.phase, CallPhase.idle);
      expect(restored.session.peerName, '小明');
    });
  });

  group('媒体代理', () {
    test('媒体指令原样转到通话窗，回话原样带回', () async {
      final transport = _FakeTransport()..answer('createOffer', 'offer-sdp-1');
      final engine = CallWindowMediaEngine(
        transport: transport,
        fallbackFactory: FakeCallMediaEngine.new,
      );

      expect(await engine.createOffer(video: true), 'offer-sdp-1');
      expect(transport.invoked, <String>['createOffer']);
      expect(transport.lastArgs['video'], isTrue);
      expect(engine.degraded, isFalse);
    });

    test('共享屏幕：选的源与「要不要电脑声音」都带过去，回话解成枚举', () async {
      final transport = _FakeTransport()
        ..answer('startScreenShare', ScreenShareAudioRoute.microphone.name);
      final engine = CallWindowMediaEngine(
        transport: transport,
        fallbackFactory: FakeCallMediaEngine.new,
      );

      // 枚举过不了通道：窗口那侧回的是字符串，这侧要解回枚举（S12.32）
      expect(
        await engine.startScreenShare(sourceId: 'window:42', withAudio: true),
        ScreenShareAudioRoute.microphone,
      );
      expect(transport.invoked, <String>['startScreenShare']);
      expect(transport.lastArgs['sourceId'], 'window:42');
      expect(transport.lastArgs['withAudio'], isTrue);
    });

    test('窗口回的话认不出来（老版本窗口 / 没回话）：当「只共享了画面」', () async {
      final transport = _FakeTransport();
      final engine = CallWindowMediaEngine(
        transport: transport,
        fallbackFactory: FakeCallMediaEngine.new,
      );

      expect(
        await engine.startScreenShare(withAudio: true),
        ScreenShareAudioRoute.off,
      );

      transport.answer('startScreenShare', '谁也没听说过的一种发法');
      expect(
        await engine.startScreenShare(withAudio: true),
        ScreenShareAudioRoute.off,
      );
      expect(engine.degraded, isFalse, reason: '一条没看懂的回话不该把通话搬回主窗');
    });

    test('窗口报「流到了」→ 引擎回调收到一个（占位）流', () {
      final transport = _FakeTransport();
      final engine = CallWindowMediaEngine(
        transport: transport,
        fallbackFactory: FakeCallMediaEngine.new,
      );
      final events = <String>[];
      engine.onLocalStream = (_) => events.add('local');
      engine.onRemoteStream = (_) => events.add('remote');
      engine.onIceCandidate = (candidate) =>
          events.add('ice:${candidate['sdpMid']}');

      engine.handleEvent(callEventLocalStream, <String, dynamic>{});
      engine.handleEvent(callEventRemoteStream, <String, dynamic>{});
      engine.handleEvent(callEventIceCandidate, <String, dynamic>{
        'candidate': <String, dynamic>{'candidate': 'cand', 'sdpMid': 'audio'},
      });

      expect(events, <String>['local', 'remote', 'ice:audio']);
      expect(engine.localStream, isNotNull);
      expect(engine.remoteStream, isNotNull);
    });

    test('窗口的家底（摄像头/ICE 列表）缓存下来给诊断面板用', () {
      final engine = CallWindowMediaEngine(
        transport: _FakeTransport(),
        fallbackFactory: FakeCallMediaEngine.new,
      );
      expect(engine.iceServersDescription, isEmpty);

      engine.handleEvent(callEventCapabilities, <String, dynamic>{
        'supportsScreenShare': true,
        'hasLocalVideo': true,
        'iceServersDescription': <String>['stun:stun.example.com:3478（无账号）'],
      });

      expect(engine.supportsScreenShare, isTrue);
      expect(engine.hasLocalVideo, isTrue);
      expect(engine.iceServersDescription, hasLength(1));
    });

    test('窗口回了话但这条指令没做成：整通电话**不**退回主窗口，错原样抛出去', () async {
      final transport = _FakeTransport()..rejected = 'setSpeakerEnabled';
      final fake = FakeCallMediaEngine();
      final engine = CallWindowMediaEngine(
        transport: transport,
        fallbackFactory: () => fake,
      );

      await expectLater(
        engine.setSpeakerEnabled(true),
        throwsA(isA<CallWindowCommandFailed>()),
      );
      // 关键（2026-10-05 真机 bug）：一条指令失败不该把整通电话搬回主窗口
      expect(engine.degraded, isFalse);
      expect(fake.calls, isEmpty);
    });

    test('窗口那条路走不通：退回主窗口里的引擎，通话照样能打（degraded）', () async {
      final transport = _FakeTransport()..failEverything = true;
      final fake = FakeCallMediaEngine();
      final engine = CallWindowMediaEngine(
        transport: transport,
        fallbackFactory: () => fake,
      );

      await engine.open(video: true);
      expect(engine.degraded, isTrue);
      expect(fake.calls, <String>['open(video=true)']);
      // 退化那一下顺手把那扇窗收掉：界面马上要在主窗口里再摆一页，两扇一起
      // 留在屏上就是用户 2026-10-05 那张截图（两份通话界面）
      expect(transport.closed, 1);

      // 退回之后事件由本地那份引擎报上来（界面那张页也在主窗口里）
      var localStreams = 0;
      engine.onLocalStream = (_) => localStreams += 1;
      await engine.createOffer(video: true);
      expect(fake.createdOffers, hasLength(1));
      expect((await engine.sampleStats()).isEmpty, isTrue);

      // 本地引擎重新报流（退回时回调已经接上）
      expect(localStreams, 0);
      expect(engine.localStream, isNotNull);
    });

    test('窗起来过又被关掉（✕）：不退回主窗口，交给宿主收尾', () async {
      final transport = _FakeTransport()..lost = true;
      final fake = FakeCallMediaEngine();
      final engine = CallWindowMediaEngine(
        transport: transport,
        fallbackFactory: () => fake,
      );
      var lost = 0;
      engine.onWindowLost = () => lost += 1;

      await expectLater(
        engine.createOffer(video: false),
        throwsA(isA<CallWindowLost>()),
      );
      // 关键：**不**另建一份本地引擎 —— 这一通的本机轨道与连接已经随那颗窗
      // 销毁了，退回主窗只能画出一张没声音没画面、也挂不断的空壳页
      expect(fake.calls, isEmpty);
      expect(lost, 1);
      // 顺手把（已经不存在的）那扇窗收干净
      expect(transport.closed, 1);
    });

    test('取统计探到窗被关掉：也交给宿主收尾（一秒一跳那条探针）', () async {
      final transport = _FakeTransport()..lost = true;
      final fake = FakeCallMediaEngine();
      final engine = CallWindowMediaEngine(
        transport: transport,
        fallbackFactory: () => fake,
      );
      var lost = 0;
      engine.onWindowLost = () => lost += 1;

      // 统计这条承诺「绝不抛」（诊断工具把通话搞崩就本末倒置了）
      expect(await engine.sampleStats(), isEmpty);
      expect(lost, 1);
    });

    test('家底（能不能共享屏 / ICE 列表）在退回本地引擎之后跟着换', () async {
      final transport = _FakeTransport()..failEverything = true;
      final fake = FakeCallMediaEngine()..screenShareSupported = false;
      fake.iceServers = const <String>['local-ice'];
      final engine = CallWindowMediaEngine(
        transport: transport,
        fallbackFactory: () => fake,
      );

      // 窗口先报一份家底（子窗那颗引擎那一份）
      engine.handleEvent(callEventCapabilities, <String, dynamic>{
        'supportsScreenShare': true,
        'hasLocalVideo': true,
        'iceServersDescription': <String>['window-ice'],
      });
      expect(engine.supportsScreenShare, isTrue);
      expect(engine.iceServersDescription, <String>['window-ice']);

      // 退回主窗口里的引擎：那份家底已经不属于这条连接了，得换成真的
      // （以前写成 `_fallback?.x ?? _x`，`??` 永远走不到右边 —— 界面与诊断
      // 面板拿到的一直是子窗那一份）
      await engine.open(video: true);
      expect(engine.degraded, isTrue);
      expect(engine.supportsScreenShare, isFalse);
      expect(engine.iceServersDescription, <String>['local-ice']);
    });
  });

  group('通话窗里那一页', () {
    /// 子窗那条线：真机上由插件提供，测试里收下调用、回个话就行
    Future<List<MethodCall>> pumpWindow(
      WidgetTester tester, {
      bool video = true,
      bool isCaller = true,
      Size size = const Size(600, 700),
      CallMediaEngine? engine,
      List<MethodCall>? nativeCalls,
      void Function(MethodCall call)? onNativeCall,
      // 「画中画这台机器上做没做成」：原生那条 `setPip` 回什么
      // （界面只认 true 才切小窗版式，见 `call_window.dart::_togglePip`）
      bool pipApplied = true,
    }) async {
      final outgoing = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('gracelinkim/child_window'),
        (call) async {
          nativeCalls?.add(call);
          onNativeCall?.call(call);
          // 别的动作（setTitle/setSize/center/show/close）不需要回话
          return call.method == 'setPip' ? pipApplied : null;
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('mixin.one/desktop_multi_window/channels'),
        (call) async {
          outgoing.add(call);
          return null;
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('gracelinkim/child_window'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('mixin.one/desktop_multi_window/channels'),
          null,
        );
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: DesktopCallWindow(
              args: DesktopWindowArgs.call(
                peerId: 'peer-1',
                peerName: 'Gracelink Team',
                video: video,
                isCaller: isCaller,
                iceServers: const <Map<String, dynamic>>[
                  <String, dynamic>{'urls': 'stun:stun.example.com:3478'},
                ],
              ),
              mediaEngine: engine == null ? null : () => engine,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      return outgoing;
    }

    /// 主窗口推一份状态进来（插件那条线长什么样见 `window_channel.dart`）
    Future<void> pushState(
      WidgetTester tester,
      Map<String, dynamic> payload,
    ) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'mixin.one/desktop_multi_window/channels',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('methodCall', <String, dynamic>{
            'channel': callWindowChannelName,
            'method': callWindowState,
            'arguments': payload,
          }),
        ),
        (_) {},
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('第一屏用窗口参数就画得出来（不用等主窗口那份状态）', (tester) async {
      await pumpWindow(tester, video: false);

      expect(find.text('Gracelink Team'), findsOneWidget);
      expect(find.text('等待对方接受邀请..'), findsOneWidget);
      expect(find.text('挂断'), findsOneWidget);
      // 桌面这档不画「扬声器」（没有听筒那回事）
      expect(find.text('扬声器已开'), findsNothing);
    });

    testWidgets('主窗口推状态：那一屏跟着变（计时/静音/接通）', (tester) async {
      await pumpWindow(tester, video: false);

      await pushState(tester, <String, dynamic>{
        'phase': CallPhase.connected.name,
        'peerId': 'peer-1',
        'peerName': 'Gracelink Team',
        'video': false,
        'isCaller': true,
        'callTime': 75,
        'microphoneEnabled': false,
        'hasLocalStream': true,
      });

      expect(find.text('00:01:15'), findsOneWidget);
      expect(find.text('麦克风已关'), findsOneWidget);
    });

    testWidgets('点挂断／接听：动作送回主窗口（那颗钮属于主窗口那份状态机）', (tester) async {
      final outgoing = await pumpWindow(tester, video: false, isCaller: false);
      outgoing.clear();

      await tester.tap(find.text('接听'));
      await tester.pump(const Duration(milliseconds: 50));

      expect(outgoing.map((call) => call.method), everyElement('invokeMethod'));
      final sent = outgoing
          .map((call) => call.arguments as Map)
          .where((args) => args['channel'] == callWindowEventChannelName)
          .toList();
      expect(sent, isNotEmpty);
      expect((sent.last['arguments'] as Map)['action'], 'accept');
      expect(sent.last['method'], callWindowAction);
    });

    testWidgets('点「共享屏幕」：这一下带着选好的源回主窗口（sourceId 跟着动作走）', (tester) async {
      // 那一下会去问原生要「可共享的屏幕/窗口列表」：
      // * `desktopCapturer` 一被碰到就会订阅 `FlutterWebRTC.Event`（事件通道照样
      //   走这个通道名），不给应答就是 `MissingPluginException` 从事件循环里冒出来；
      // * 源列表本身走 `FlutterWebRTC.Method`。测试里让它直接报「没有原生实现」——
      //   选择面板会退成「按系统默认源来」那一支（`screen_share_picker.dart` 第三条
      //   口径），而且回话在假时钟里就完成，不用 `runAsync` 等真原生。
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Event'),
        (call) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async {
          if (call.method == 'initialize') return null;
          throw MissingPluginException('测试里没有原生实现：${call.method}');
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'),
          null,
        );
      });

      final outgoing = await pumpWindow(tester, video: true);
      // 主窗口查到的家底（支不支持共享屏幕）跟着状态推过来，界面才画那颗钮
      await pushState(tester, <String, dynamic>{
        'phase': CallPhase.connected.name,
        'peerId': 'peer-1',
        'peerName': 'Gracelink Team',
        'video': true,
        'isCaller': true,
        'callTime': 3,
        'canShareScreen': true,
      });
      expect(find.text('共享屏幕'), findsOneWidget);
      outgoing.clear();

      await tester.tap(find.text('共享屏幕'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      final sent = outgoing
          .map((call) => call.arguments as Map)
          .where((args) => args['channel'] == callWindowEventChannelName)
          .toList();
      expect(sent, isNotEmpty);
      final action = Map<String, dynamic>.from(sent.last['arguments'] as Map);
      expect(action['action'], 'screenShare');
      // 测试环境里没有原生源列表：选择面板退成「按系统默认源来」那一支，
      // 但 `sourceId` 这个字段本身必须在（主窗口那份状态机按它取）
      expect(action.containsKey('sourceId'), isTrue);
      expect(action['sourceId'], isNull);
    });

    testWidgets('家底里没有共享屏幕（canShareScreen 为 false）：一颗都不画', (tester) async {
      await pumpWindow(tester, video: true);
      await pushState(tester, <String, dynamic>{
        'phase': CallPhase.connected.name,
        'peerId': 'peer-1',
        'peerName': 'Gracelink Team',
        'video': true,
        'isCaller': true,
        'callTime': 3,
        'canShareScreen': false,
      });
      expect(find.text('共享屏幕'), findsNothing);
    });

    testWidgets('点「画中画」：原生把那扇窗缩成小窗，版式跟着换紧凑那一版', (tester) async {
      final native = <MethodCall>[];
      await pumpWindow(tester, video: true, nativeCalls: native);
      native.clear();

      expect(find.text('画中画'), findsOneWidget);
      await tester.tap(find.text('画中画'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      final setPip = native
          .where((call) => call.method == 'setPip')
          .map((call) => Map<String, dynamic>.from(call.arguments as Map))
          .toList();
      expect(setPip, hasLength(1));
      expect(setPip.single['on'], isTrue);
      expect(setPip.single['w'], kCallDesktopPipSize.width);
      expect(setPip.single['h'], kCallDesktopPipSize.height);

      // 版式跟着换：大圆钮一颗不剩，只剩小窗那排图标钮
      expect(find.byType(CallRoundButton), findsNothing);
      expect(find.text('挂断'), findsNothing);
      expect(find.byIcon(Icons.picture_in_picture_alt_rounded), findsOneWidget);
      expect(find.byIcon(Icons.call_end_rounded), findsOneWidget);

      // 那颗「还原」：把窗变回大窗（on=false），版式也回大窗那一版
      await tester.tap(find.byIcon(Icons.picture_in_picture_alt_rounded));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      final back = native.lastWhere((call) => call.method == 'setPip');
      expect((Map<String, dynamic>.from(back.arguments as Map))['on'], isFalse);
      expect(find.text('画中画'), findsOneWidget);
    });

    testWidgets('原生说这台机器上没做成：版式不切（不能自己以为在小窗里）', (tester) async {
      final native = <MethodCall>[];
      await pumpWindow(
        tester,
        video: true,
        nativeCalls: native,
        pipApplied: false,
      );
      await tester.tap(find.text('画中画'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(native.map((call) => call.method), contains('setPip'));
      // 还是大窗那一版：麦克风/摄像头/画中画/挂断四颗圆钮都在
      expect(find.text('画中画'), findsOneWidget);
      expect(find.byType(CallRoundButton), findsNWidgets(4));
    });

    testWidgets('小窗里拖一下画面：begin/update/end 三下都送到原生', (tester) async {
      final native = <MethodCall>[];
      await pumpWindow(tester, video: true, nativeCalls: native);
      await tester.tap(find.text('画中画'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      native.clear();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CallDesktopPage)),
      );
      for (var step = 0; step < 3; step += 1) {
        await gesture.moveBy(const Offset(20, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));

      final methods = native.map((call) => call.method).toList();
      expect(methods, contains('dragBegin'));
      expect(methods, contains('dragUpdate'));
      expect(methods, contains('dragEnd'));
    });

    /// 真机上那条「用户按 ✕」的问话：`window_channel_plugin` 之外，runner 自己
    /// 那条 `gracelinkim/child_window` 会先 `close_requested` 问一声
    /// （见 `windows/runner/flutter_window.cpp`），答完 native 就不自己销毁了。
    Future<void> nativeAsksClose(WidgetTester tester) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'gracelinkim/child_window',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('close_requested'),
        ),
        (_) {},
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('用户按 ✕：先请主窗口按挂断收尾 → 再放媒体 → 最后才关窗（顺序不能换）', (tester) async {
      // 这条钉的是 S12.29 的崩溃修复：媒体还活着时拆引擎，webrtc 会在拆音频设备
      // 那一步 abort，**整个 app 一起没**（2026-10-05 真机两次实测）。
      final engine = FakeCallMediaEngine();
      final native = <MethodCall>[];
      List<String>? engineCallsWhenWindowClosed;
      final outgoing = await pumpWindow(
        tester,
        video: false,
        engine: engine,
        nativeCalls: native,
        onNativeCall: (call) {
          // 关窗那一瞬间媒体引擎走到哪儿了（断言顺序就靠它）
          if (call.method == 'close') {
            engineCallsWhenWindowClosed = List<String>.of(engine.calls);
          }
        },
      );
      outgoing.clear();
      native.clear();

      await nativeAsksClose(tester);

      // 1) 主窗口那份状态机得知道：这一通结束了（它会发挂断信令、记通话记录）
      final actions = outgoing
          .map((call) => call.arguments)
          .whereType<Map>()
          .where((args) => args['channel'] == callWindowEventChannelName)
          .toList();
      expect(actions, isNotEmpty);
      expect((actions.last['arguments'] as Map)['action'], 'hangup');
      // 2) 本机媒体先放干净（这一步就是那个崩溃修复本身）
      expect(engine.closed, isTrue);
      // 3) 最后才关窗，而且关窗**发生在媒体放掉之后**
      expect(native.map((call) => call.method), contains('close'));
      expect(engineCallsWhenWindowClosed, contains('close()'));
    });

    testWidgets('✕ 之后再来的那句 `bye`：不插手（收摊那条路自己会关窗）', (tester) async {
      final engine = FakeCallMediaEngine();
      final native = <MethodCall>[];
      await pumpWindow(
        tester,
        video: false,
        engine: engine,
        nativeCalls: native,
      );
      native.clear();

      await nativeAsksClose(tester);
      // 主窗口那句「再见」晚一步到（它不知道我们这边已经在收摊了）
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'mixin.one/desktop_multi_window/channels',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('methodCall', <String, dynamic>{
            'channel': callWindowChannelName,
            'method': callWindowBye,
            'arguments': <String, dynamic>{},
          }),
        ),
        (_) {},
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 窗只关一次（收摊那条路关的）：bye 那条要是也关，就是在「媒体还在拆」
      // 的时候把引擎拆了 —— 又踩回崩溃那条路
      expect(native.where((call) => call.method == 'close'), hasLength(1));
    });
  });

  group('传输层（假原生）：开窗、重试、关窗', () {
    /// 装一个假的 `desktop_multi_window` 原生层。
    ///
    /// 为什么这条一定要有：真机上**没法**用 `flutter test -d windows` 自检
    /// 窗口（子引擎跑的还是测试那个 `main`，永远注册不上通道 —— 2026-10-04
    /// 实测，连早就验过的文章窗也 ping 不应），所以「开窗参数对不对、冷启动
    /// 那几次 `CHANNEL_UNREGISTERED` 重不重试、挂断会不会说再见」只能在这里钉。
    ({List<MethodCall> calls, void Function(int) setRefusals}) install(
      WidgetTester tester, {
      required int refusals,
      // 「窗口回了话，但这条指令失败」：原生层把它包成一个普通 PlatformException
      ({String method, String message})? reject,
    }) {
      final calls = <MethodCall>[];
      var left = refusals;
      final messenger = tester.binding.defaultBinaryMessenger;
      // 插件有**两条**通道：一条管窗口（createWindow/getAllWindows），
      // 一条管通道（registerMethodHandler/invokeMethod）—— 两条都得应答
      messenger.setMockMethodCallHandler(
        const MethodChannel('mixin.one/desktop_multi_window'),
        (call) async {
          calls.add(call);
          switch (call.method) {
            case 'createWindow':
              return 'w-call-1';
            default:
              return null;
          }
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('mixin.one/desktop_multi_window'),
          null,
        ),
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('mixin.one/desktop_multi_window/channels'),
        (call) async {
          calls.add(call);
          switch (call.method) {
            case 'invokeMethod':
              final args = Map<String, dynamic>.from(call.arguments as Map);
              // 媒体指令里外两层都有 `method`：外层是通道的方法名
              // （`callWindowMedia`），里层才是「哪条指令」
              final inner = args['arguments'] is Map
                  ? Map<String, dynamic>.from(args['arguments'] as Map)
                  : const <String, dynamic>{};
              if (reject != null &&
                  args['channel'] == callWindowChannelName &&
                  inner['method'] == reject.method) {
                // 子窗 handler 抛出来的东西过通道之后就是这样（code 是 error，
                // 不是 CHANNEL_UNREGISTERED）
                throw PlatformException(code: 'error', message: reject.message);
              }
              // 子窗还没把那条线挂上时，原生层就是这么回的
              if (args['channel'] == callWindowChannelName && left > 0) {
                left -= 1;
                throw PlatformException(
                  code: 'CHANNEL_UNREGISTERED',
                  message: '子窗还没注册',
                );
              }
              return <String, dynamic>{'ok': true};
            case 'getWindowDefinition':
              return <String, dynamic>{
                'windowId': 'main',
                'windowArgument': '',
              };
            default:
              return null;
          }
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('mixin.one/desktop_multi_window/channels'),
          null,
        ),
      );
      return (calls: calls, setRefusals: (value) => left = value);
    }

    testWidgets('冷启动那几次叫不应会重试，成功之后照常回话；窗口只开一颗', (tester) async {
      final fake = install(tester, refusals: 3);
      final transport = MultiWindowCallWindowTransport();
      // ⚠️ `plan` 与 `invokeMedia` 都得在 `runAsync` 里：重试那条路上有
      // `Future.delayed`，而组件测试的时钟是假时钟 —— `plan()` 里那个「提前开窗」
      // 只要落在假时钟里，后面 `await _opening` 就永远等不到（探针验过：
      // 整条会挂死，5 分钟超时）。
      await tester.runAsync(() async {
        transport.plan(
          const CallWindowSpec(
            peerId: 'peer-1',
            peerName: '小明',
            video: true,
            isCaller: true,
          ),
        );
        await transport.invokeMedia('open', <String, dynamic>{'video': true});
        await transport.closeWindow();
      });

      final created = fake.calls.where((call) => call.method == 'createWindow');
      expect(created, hasLength(1), reason: '绝不重开第二颗引擎');
      final config = Map<String, dynamic>.from(created.single.arguments as Map);
      expect(config['hiddenAtLaunch'], isTrue, reason: '先设好标题/大小再显形');
      final args = DesktopWindowArgs.decode(config['arguments'] as String)!;
      expect(args.kind, DesktopWindowKind.call);
      expect(args.id, 'peer-1');
      expect(args.title, '小明');
      expect(args.video, isTrue);

      final last = fake.calls
          .where((call) => call.method == 'invokeMethod')
          .last;
      final sent = Map<String, dynamic>.from(last.arguments as Map);
      expect(sent['method'], callWindowBye, reason: '挂断要让窗口自己关掉');
    });

    testWidgets('窗口回了话但这条指令失败：**不重试**，立刻抛 CallWindowCommandFailed', (
      tester,
    ) async {
      final fake = install(
        tester,
        refusals: 0,
        reject: (
          method: 'setSpeakerEnabled',
          message: 'CallMediaException(切换扬声器失败: MissingPluginException)',
        ),
      );
      final transport = MultiWindowCallWindowTransport();

      final failure = await tester.runAsync(() async {
        transport.plan(
          const CallWindowSpec(
            peerId: 'peer-1',
            peerName: '小明',
            video: false,
            isCaller: true,
          ),
        );
        return transport
            .invokeMedia('setSpeakerEnabled', <String, dynamic>{
              'enabled': true,
            })
            .then<Object?>((value) => value, onError: (Object error) => error);
      });
      expect(failure, isA<CallWindowCommandFailed>());
      expect((failure! as CallWindowCommandFailed).method, 'setSpeakerEnabled');

      // 关键：**只试了一次** —— 以前这里会空转完 15 秒的预算才认输
      final attempts = fake.calls
          .where((call) => call.method == 'invokeMethod')
          .map((call) => Map<String, dynamic>.from(call.arguments as Map))
          .where(
            (sent) =>
                sent['channel'] == callWindowChannelName &&
                Map<String, dynamic>.from(sent['arguments'] as Map)['method'] ==
                    'setSpeakerEnabled',
          )
          .length;
      expect(attempts, 1);
    });

    testWidgets('答过一次话之后再叫不应：立刻认输，不再空转 15 秒（✕ 关掉那条路）', (tester) async {
      final fake = install(tester, refusals: 0);
      final transport = MultiWindowCallWindowTransport();

      await tester.runAsync(() async {
        transport.plan(
          const CallWindowSpec(
            peerId: 'peer-1',
            peerName: '小明',
            video: false,
            isCaller: true,
          ),
        );
        // 第一枪是好的：这颗窗确实起来过、答过话
        await transport.invokeMedia('open', <String, dynamic>{'video': false});
        // 用户按 ✕ 把窗关了：那条线从此一律叫不应
        fake.setRefusals(1000000);
        final failure = await transport
            .invokeMedia('createOffer', <String, dynamic>{'video': false})
            .then<Object?>((value) => value, onError: (Object error) => error);
        // 专门的类型：\u300c窗起来过又被关掉\u300d与\u300c还没起来过\u300d的处理相反
        // （见 `CallWindowLost`）
        expect(failure, isA<CallWindowLost>());
      });

      // 关键：**只试了一次**。旧代码在这里会把 15 秒预算跑满（几十次重试），
      // 用户那 15 秒里既没画面也没声音 —— 媒体全卡在这条指令上。
      final attempts = fake.calls
          .where(
            (call) => call.method == 'invokeMethod' && call.arguments is Map,
          )
          .map((call) => Map<String, dynamic>.from(call.arguments as Map))
          .where(
            (sent) =>
                sent['channel'] == callWindowChannelName &&
                sent['arguments'] is Map &&
                Map<String, dynamic>.from(sent['arguments'] as Map)['method'] ==
                    'createOffer',
          )
          .length;
      expect(attempts, 1);
    });

    testWidgets('那条线一直叫不应：抛出来（媒体代理会退回本地引擎）', (tester) async {
      final fake = install(tester, refusals: 1000000);
      // 预算调到 600ms：这条等的是「一直叫不应」，真等 15 秒没意义
      final transport = MultiWindowCallWindowTransport(
        retryBudget: const Duration(milliseconds: 600),
      );

      final failure = await tester.runAsync(() async {
        transport.plan(
          const CallWindowSpec(
            peerId: 'peer-1',
            peerName: '小明',
            video: false,
            isCaller: true,
          ),
        );
        return transport
            .invokeMedia('open', <String, dynamic>{'video': false})
            .then<Object?>((value) => value, onError: (Object error) => error);
      });
      expect(failure, isA<CallMediaException>());
      expect(
        fake.calls.where((call) => call.method == 'createWindow'),
        hasLength(1),
      );
    });
  });

  group('主窗口那句「这通电话是谁」', () {
    test('窗口参数带上对端与视频那一档', () {
      const spec = CallWindowSpec(
        peerId: 'peer-1',
        peerName: '小明',
        peerAvatar: 'a.png',
        video: true,
        isCaller: false,
      );
      final args = spec.toArgs();
      expect(args.kind, DesktopWindowKind.call);
      expect(args.id, 'peer-1');
      expect(args.title, '小明');
      expect(args.avatar, 'a.png');
      expect(args.video, isTrue);
      expect(args.isCaller, isFalse);
    });
  });
}

/// 假传输层：记下主窗口说了什么，也可以「怎么调都失败」。
class _FakeTransport implements CallWindowTransport {
  final List<String> invoked = <String>[];
  final Map<String, Object?> answers = <String, Object?>{};
  final List<Map<String, dynamic>> pushed = <Map<String, dynamic>>[];
  Map<String, dynamic> lastArgs = <String, dynamic>{};
  CallWindowSpec? planned;
  int closed = 0;

  /// 窗口那条路整个不通（模拟原生建不出引擎）
  bool failEverything = false;

  /// 哪条指令「窗口回了话但没做成」（抛 [CallWindowCommandFailed]）
  String? rejected;

  /// 那颗窗**起来过又被关掉**（✕）：抛 [CallWindowLost]
  bool lost = false;

  void answer(String method, Object? value) => answers[method] = value;

  @override
  void plan(CallWindowSpec spec) => planned = spec;

  @override
  Future<void> pushState(Map<String, dynamic> state) async {
    pushed.add(state);
  }

  @override
  Future<Object?> invokeMedia(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (failEverything) {
      throw const CallMediaException('测试里这条窗开不出来');
    }
    if (lost) throw CallWindowLost(method);
    invoked.add(method);
    lastArgs = args ?? <String, dynamic>{};
    if (rejected == method) {
      throw CallWindowCommandFailed(method, 'CallMediaException(切换扬声器失败)');
    }
    return answers[method];
  }

  @override
  Future<void> closeWindow() async => closed += 1;

  @override
  Future<bool> alive() async => !failEverything;
}
