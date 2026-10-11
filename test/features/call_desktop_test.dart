import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoViewObjectFit;
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';
import 'package:gracelinkim/features/call/call_desktop_page.dart';
import 'package:gracelinkim/features/call/widgets/call_round_button.dart';
import 'package:gracelinkim/features/call/widgets/call_video_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_call_media.dart';

/// 桌面版通话界面（2026-10-04，`call_desktop_page.dart`）。
///
/// 钉的就是用户报的那件事：**通话页原来是按手机版式用 `rpx` 排的，桌面窗口一宽
/// 就整个放大变形**（麦克风/扬声器/摄像头三颗钮铺满整屏、挂断钮盖在用户名上）。
/// 所以这里的核心断言是：窗口拉到 1200 宽，圆钮**还是 56**。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppI18n.load('zh-Hans');
    // 测试环境里没有原生 WebRTC：`flutter_webrtc` 里那个全局事件通道
    // （`FlutterWebRTC.Event`，桌面端 `navigator.mediaDevices` 一被碰到就建）
    // 会把 `MissingPluginException` 抛到事件循环上，被测试框架判定为失败。
    // 这里给它一个应答让它安静下来 —— 渲染器初始化失败那条路本身有兜底，
    // 界面照样渲染（深色底），结构仍可断言。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          (call) async => null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Event'),
            null,
          ),
    );
  });

  CallViewState stateOf({
    required CallPhase phase,
    bool video = false,
    bool isCaller = true,
    bool hasLocal = false,
    bool hasRemote = false,
    bool remoteBig = false,
    int callTime = 0,
    bool microphoneEnabled = true,
    bool cameraEnabled = true,
    bool canShareScreen = false,
    bool screenSharing = false,
  }) => CallViewState(
    session: CallSession(
      phase: phase,
      peerId: 'peer-1',
      peerName: 'Gracelink Team',
      type: video ? CallType.video : CallType.voice,
      isCaller: isCaller,
      callTime: callTime,
    ),
    microphoneEnabled: microphoneEnabled,
    cameraEnabled: cameraEnabled,
    hasLocalStream: hasLocal,
    hasRemoteStream: hasRemote,
    remoteBig: remoteBig,
    canShareScreen: canShareScreen,
    screenSharing: screenSharing,
  );

  Future<List<String>> pump(
    WidgetTester tester,
    CallViewState state, {
    Size size = const Size(420, 640),
    FakeMediaStream? local,
    FakeMediaStream? remote,
    bool capture = false,
    String captureName = '',
    // 传了才画「共享屏幕」那颗（null = 平台不支持 / 语音通话）
    void Function(String? sourceId, bool withAudio)? screenShare,
    // 传了才画「画中画」那颗（null = 这一页不是通话窗，没有窗可缩）
    VoidCallback? togglePip,
    // 正缩在小窗里 → 小窗那一版版式
    bool pip = false,
  }) async {
    final calls = <String>[];
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final captureKey = ValueKey<String>('capture-$captureName');
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: CallDesktopPage(
              i18n: AppI18n.instance,
              state: state,
              localStream: local,
              remoteStream: remote,
              pip: pip,
              actions: CallDesktopActions(
                accept: () => calls.add('accept'),
                hangup: () => calls.add('hangup'),
                toggleMicrophone: () => calls.add('mic'),
                toggleCamera: () => calls.add('camera'),
                toggleLayout: () => calls.add('layout'),
                diagnostics: () => calls.add('diagnostics'),
                startScreenShare: screenShare,
                togglePip: togglePip == null
                    ? null
                    : () {
                        togglePip();
                        calls.add('pip');
                      },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (capture) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      // ⚠️ 抓图必须在 `runAsync` 里：`toImage/toByteData` 要在真事件循环上跑，
      // 放在外面会把测试挂死（探针验过：外面抓 → 后面的 tap 永远等不到）。
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/$captureName').writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    return calls;
  }

  testWidgets('语音通话：窗口拉到 1200 宽，圆钮还是 56（不再跟着 rpx 放大）', (tester) async {
    await pump(
      tester,
      stateOf(phase: CallPhase.connected, callTime: 75),
      size: const Size(1200, 800),
    );

    final buttons = tester
        .widgetList<CallRoundButton>(find.byType(CallRoundButton))
        .toList();
    expect(buttons.length, 2, reason: '语音通话只有麦克风与挂断两颗');
    for (final button in buttons) {
      expect(button.size, 56, reason: '桌面这档写死 56 逻辑像素（手机那档才是 rpx 换算）');
      expect(button.labelFontSize, 12);
    }
    // 真量一遍渲染出来的尺寸，确保没有别的地方又把它放大
    final size = tester.getSize(find.byType(CallRoundButton).first);
    expect(size.height, lessThan(100), reason: '圆钮 + 一行标签就该是 56 + 6 + 12 上下');
  });

  testWidgets('语音通话：名字、计时、状态都在，点挂断回调得上', (tester) async {
    final calls = await pump(
      tester,
      stateOf(phase: CallPhase.connected, callTime: 75),
      capture: true,
      captureName: 'call_desktop_voice.png',
    );

    expect(find.text('Gracelink Team'), findsOneWidget);
    // 计时口径沿用 `formatCallDuration`（HH:MM:SS，与服务端下发的通话记录一致）
    expect(find.text('00:01:15'), findsOneWidget);
    expect(find.text('麦克风已开'), findsOneWidget);
    expect(find.text('挂断'), findsOneWidget);
    expect(find.text('扬声器已开'), findsNothing, reason: '桌面没有听筒，不画扬声器那颗');

    await tester.tap(find.text('挂断'));
    expect(calls, <String>['hangup']);
  });

  testWidgets('拨号中：写「等待对方接受邀请..」；来电：拒绝 + 接听两颗', (tester) async {
    // 抓图按**真窗那一档**来（视频 600×700 / 语音 420×620，见 `call_window.dart`
    // `_setup()`）：来电那一屏的毛病只有在这个尺寸上才看得见
    await pump(
      tester,
      stateOf(phase: CallPhase.outgoing, video: true, isCaller: true),
      size: const Size(600, 700),
      capture: true,
      captureName: 'call_desktop_outgoing.png',
    );
    expect(find.text('等待对方接受邀请..'), findsOneWidget);

    final calls = await pump(
      tester,
      stateOf(phase: CallPhase.incoming, isCaller: false, video: true),
      size: const Size(600, 700),
      capture: true,
      captureName: 'call_desktop_incoming.png',
    );
    expect(find.text('Gracelink Team'), findsOneWidget);
    expect(find.text('Gracelink Team 正在请求与您视频通话'), findsOneWidget);
    expect(find.text('挂断'), findsOneWidget);
    expect(find.text('接听'), findsOneWidget);

    await tester.tap(find.text('接听'));
    await tester.tap(find.text('挂断'));
    expect(calls, <String>['accept', 'hangup']);

    // 语音那通（真窗 420×620，见 `call_window.dart`）也抓一张：两屏放一起比
    await pump(
      tester,
      stateOf(phase: CallPhase.incoming, isCaller: false),
      size: const Size(420, 620),
      capture: true,
      captureName: 'call_desktop_incoming_voice.png',
    );
    expect(find.text('Gracelink Team 正在请求与您语音通话'), findsOneWidget);
  });

  testWidgets('视频通话接通：对方画面铺满、自己的小窗在右上角', (tester) async {
    await pump(
      tester,
      stateOf(
        phase: CallPhase.connected,
        video: true,
        callTime: 12,
        hasLocal: true,
        hasRemote: true,
        remoteBig: true,
      ),
      local: FakeMediaStream(),
      remote: FakeMediaStream(),
      capture: true,
      captureName: 'call_desktop_video.png',
    );

    // 自己的小窗：192×144，右上角 16（与手机版那种 rpx 尺寸不是一套）
    final inset = find.byWidgetPredicate(
      (widget) => widget is Positioned && widget.width == 192,
    );
    expect(inset, findsOneWidget);

    // 名字与顶部那层压暗是一对：控制栏还在的时候名字也在（以前名字只在
    // **收起**控制栏时才画，而那一刻压暗层已经没了 —— 白字压亮画面）
    expect(find.text('Gracelink Team'), findsOneWidget);
    expect(find.text('00:00:12'), findsOneWidget);
  });

  testWidgets('视频通话还没接通：只画本地预览，头像小一号挂在上面', (tester) async {
    await pump(
      tester,
      stateOf(phase: CallPhase.outgoing, video: true, hasLocal: true),
      local: FakeMediaStream(),
      size: const Size(1200, 800),
    );
    expect(find.text('等待对方接受邀请..'), findsOneWidget);
    // 视频这一档的圆钮：麦克风 + 摄像头 + 挂断
    expect(find.byType(CallRoundButton), findsNWidgets(3));
    expect(find.text('摄像头已开'), findsOneWidget);
  });

  testWidgets('大窗画面默认「完整」（contain），双击切成「铺满」（cover）', (tester) async {
    await pump(
      tester,
      stateOf(
        phase: CallPhase.connected,
        video: true,
        callTime: 5,
        hasLocal: true,
        hasRemote: true,
        remoteBig: true,
      ),
      local: FakeMediaStream(),
      remote: FakeMediaStream(),
    );

    RTCVideoViewObjectFit bigFit() =>
        tester.widgetList<CallVideoView>(find.byType(CallVideoView)).first.fit;

    // 默认不是 cover：桌面窗口的宽高比跟镜头画面差得远，铺满只能靠裁
    // （用户 2026-10-05 反馈的「全屏后有点变形」就是它）
    expect(bigFit(), RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);

    await tester.tap(find.byType(CallVideoView).first);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byType(CallVideoView).first);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      bigFit(),
      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      reason: '双击是那个「我想要铺满」的开关',
    );
  });

  /// 「共享屏幕」那颗点下去要问原生要源列表（`desktopCapturer`）。测试里让那条
  /// 通道直接报「没有原生实现」：选择面板会退成「按系统默认源来」那一支
  /// （`screen_share_picker.dart` 第三条口径），而且回话在假时钟里就完成。
  void mockWebrtcMethodChannel(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        if (call.method == 'initialize') return null;
        throw MissingPluginException('测试里没有原生实现：${call.method}');
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        null,
      ),
    );
  }

  /// 假原生：给出源列表（`getDesktopSources`）并按 [thumbnail] 回缩略图
  /// （`getDesktopSourceThumbnail`，空手就是 `false`/null 那一支）。
  /// [asks] 按顺序记下每一次问的是哪个源，用来钉「空的会再问一轮」。
  void mockDesktopSources(
    WidgetTester tester, {
    required List<Map<String, dynamic>> sources,
    required Uint8List? Function(String sourceId, int attempt) thumbnail,
    required List<String> asks,
  }) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        switch (call.method) {
          case 'initialize':
          case 'getDesktopSources':
            if (call.method == 'initialize') return null;
            return <String, dynamic>{'sources': sources};
          case 'getDesktopSourceThumbnail':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final id = args['sourceId'] as String;
            asks.add(id);
            final asked = asks.where((each) => each == id).length;
            // 空手时回一个空数组（真机上窗口那条就是这个样子），不是 null
            return thumbnail(id, asked) ?? Uint8List(0);
        }
        throw MissingPluginException('测试里没有原生实现：${call.method}');
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        null,
      ),
    );
  }

  /// 把一串十六进制写成字节（测试里要一张真图时用）
  Uint8List hexBytes(String hex) => Uint8List.fromList(<int>[
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);

  testWidgets('桌面 + 视频通话 + 平台支持：画「共享屏幕」那颗，点了把选中的源交出去', (tester) async {
    mockWebrtcMethodChannel(tester);
    final shares = <String?>[];
    // 面板底下的开关默认关：这一条钉的是「没动开关 → 不要声音」
    var audios = <bool>[];
    await pump(
      tester,
      stateOf(
        phase: CallPhase.connected,
        video: true,
        callTime: 9,
        hasLocal: true,
        hasRemote: true,
        remoteBig: true,
        canShareScreen: true,
      ),
      local: FakeMediaStream(),
      remote: FakeMediaStream(),
      screenShare: (sourceId, withAudio) {
        shares.add(sourceId);
        audios = <bool>[withAudio];
      },
    );

    expect(find.text('共享屏幕'), findsOneWidget);
    await tester.tap(find.text('共享屏幕'));
    await tester.pumpAndSettle();

    // 测试环境里没有原生源列表：选择面板退成「按系统默认源来」那一支
    // （`screen_share_picker.dart` 第三条口径），所以这里收到的是 null
    expect(shares, <String?>[null]);
    expect(audios, <bool>[false], reason: '那座开关默认是关的（要声音是额外的事）');
  });

  testWidgets('面板：整屏排最前、窗口用标题；空手的缩略图会再问一轮（S12.32）', (tester) async {
    // 一张真的 1×1 透明 PNG（假字节进 `Image.memory` 会报解码错）
    final png = hexBytes(
      '89504e470d0a1a0a0000000d4948445200000001000000010806000000'
      '1f15c4890000000a49444154789c63000100000500010d0a2db40000'
      '000049454e44ae426082',
    );
    final asks = <String>[];
    // 源列表故意把窗口放在前面：面板要自己把「整屏」提到最上面
    mockDesktopSources(
      tester,
      sources: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'win-7',
          'name': 'Freebuff Desktop',
          'type': 'window',
          'thumbnailSize': <String, int>{'width': 0, 'height': 0},
        },
        <String, dynamic>{
          'id': '0',
          'name': 'Screen 1',
          'type': 'screen',
          'thumbnailSize': <String, int>{'width': 0, 'height': 0},
        },
      ],
      // 屏幕那条第一问空着回来、第二问才有图；窗口那条三问都空
      thumbnail: (id, attempt) => id == '0' && attempt > 1 ? png : null,
      asks: asks,
    );
    final shares = <String?>[];
    await pump(
      tester,
      stateOf(
        phase: CallPhase.connected,
        video: true,
        callTime: 9,
        hasLocal: true,
        hasRemote: true,
        remoteBig: true,
        canShareScreen: true,
      ),
      local: FakeMediaStream(),
      remote: FakeMediaStream(),
      screenShare: (sourceId, withAudio) => shares.add(sourceId),
    );

    await tester.tap(find.text('共享屏幕'));
    await tester.pumpAndSettle();
    // 第一问那几张缩略图回来之后，空着的那两条要各再问一轮（延时 250ms）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 名字：屏幕那类按界面语言自己起名（原生给的是 `Screen 1`），窗口用标题
    expect(find.text('整个屏幕'), findsOneWidget);
    expect(find.text('Freebuff Desktop'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('整个屏幕')).dy,
      lessThan(tester.getTopLeft(find.text('Freebuff Desktop')).dy),
      reason: '整屏优先：那块屏永远是第一行',
    );
    // 缩略图：屏幕那条第二问拿到图（不再画灰块），窗口那条三问都空（还画灰块）
    expect(asks.where((id) => id == '0'), hasLength(2));
    expect(asks.where((id) => id == 'win-7'), hasLength(3));
    expect(find.byIcon(Icons.desktop_windows_outlined), findsOneWidget);

    // 选中窗口那条：一路交出去的还是原生那个 id
    await tester.tap(find.text('Freebuff Desktop'));
    await tester.pumpAndSettle();
    expect(shares, <String?>['win-7']);
  });

  testWidgets('不支持共享（startScreenShare 为 null）：一颗都不画', (tester) async {
    await pump(
      tester,
      stateOf(
        phase: CallPhase.connected,
        video: true,
        callTime: 9,
        hasLocal: true,
        hasRemote: true,
        remoteBig: true,
        canShareScreen: true,
      ),
      local: FakeMediaStream(),
      remote: FakeMediaStream(),
    );
    expect(find.text('共享屏幕'), findsNothing);
    // 不支持时剩下的圆钮还是三颗（麦克风/摄像头/挂断）
    expect(find.byType(CallRoundButton), findsNWidgets(3));
  });

  testWidgets('正在共享：那颗变成「停止共享」，再点一下回调收到 null（停不停归控制器）', (tester) async {
    mockWebrtcMethodChannel(tester);
    final shares = <String?>[];
    await pump(
      tester,
      stateOf(
        phase: CallPhase.connected,
        video: true,
        callTime: 30,
        hasLocal: true,
        hasRemote: true,
        remoteBig: true,
        canShareScreen: true,
        screenSharing: true,
      ),
      local: FakeMediaStream(),
      remote: FakeMediaStream(),
      screenShare: (sourceId, withAudio) => shares.add(sourceId),
    );

    expect(find.text('停止共享'), findsOneWidget);
    expect(find.text('共享屏幕'), findsNothing);
    await tester.tap(find.text('停止共享'));
    await tester.pumpAndSettle();
    expect(shares, <String?>[null]);
  });

  testWidgets('共享屏幕那一支：本机那块画面按完整放（不裁掉屏幕边角）', (tester) async {
    final local = FakeMediaStream();
    await pump(
      tester,
      stateOf(
        phase: CallPhase.connected,
        video: true,
        callTime: 30,
        hasLocal: true,
        hasRemote: true,
        remoteBig: false, // 大窗 = 本机（共享的那块屏幕）
        canShareScreen: true,
        screenSharing: true,
      ),
      local: local,
      remote: FakeMediaStream(),
      screenShare: (_, _) {},
    );

    final views = tester
        .widgetList<CallVideoView>(find.byType(CallVideoView))
        .toList();
    expect(views, hasLength(2));
    expect(
      views.first.fit,
      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      reason: '共享出去的是屏幕：裁掉一边就是真丢信息',
    );
    // 右上角那块是对方的摄像头画面（不是我共享出去的那块）→ 照旧 cover
    expect(views.last.fit, RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
  });

  testWidgets('共享屏幕期间：摄像头那颗置灰、点了没反应（手机版一直是这么做的）', (tester) async {
    final calls = await pump(
      tester,
      stateOf(
        phase: CallPhase.connected,
        video: true,
        callTime: 30,
        hasLocal: true,
        hasRemote: true,
        remoteBig: true,
        canShareScreen: true,
        screenSharing: true,
      ),
      local: FakeMediaStream(),
      remote: FakeMediaStream(),
      screenShare: (_, _) {},
    );

    final camera = tester.widget<CallRoundButton>(
      find.ancestor(
        of: find.byIcon(Icons.videocam_rounded),
        matching: find.byType(CallRoundButton),
      ),
    );
    expect(
      camera.onTap,
      isNull,
      reason: '共享时发出去的是屏幕、摄像头已经被引擎停掉 —— 这颗不该还能点（2026-10-05 复查）',
    );
    // 点一下也真的什么都不会发生
    await tester.tap(find.byIcon(Icons.videocam_rounded));
    expect(calls, isEmpty);
    // 「停止共享」那颗还是活的
    expect(
      tester
          .widget<CallRoundButton>(
            find.ancestor(
              of: find.byIcon(Icons.stop_screen_share_rounded),
              matching: find.byType(CallRoundButton),
            ),
          )
          .onTap,
      isNotNull,
    );
  });

  testWidgets('大窗里那颗「画中画」：点了交给宿主（缩的是这扇窗自己）', (tester) async {
    var pips = 0;
    final calls = await pump(
      tester,
      stateOf(phase: CallPhase.connected, callTime: 12),
      togglePip: () => pips += 1,
    );

    expect(find.text('画中画'), findsOneWidget);
    await tester.tap(find.text('画中画'));
    expect(pips, 1);
    expect(calls, <String>['pip']);

    // 没传 togglePip（主窗口里那份兜底页）：一颗都不画 —— 没有窗可缩
    await pump(tester, stateOf(phase: CallPhase.connected, callTime: 12));
    expect(find.text('画中画'), findsNothing);
  });

  testWidgets('小窗那一版：只剩画面 + 一排 30 的图标钮（大圆钮/名字/本机小窗都不画）', (tester) async {
    await pump(
      tester,
      stateOf(
        phase: CallPhase.connected,
        video: true,
        callTime: 12,
        hasLocal: true,
        hasRemote: true,
        remoteBig: true,
      ),
      local: FakeMediaStream(),
      remote: FakeMediaStream(),
      pip: true,
      togglePip: () {},
      size: const Size(320, 180),
      capture: true,
      captureName: 'call_desktop_pip.png',
    );

    // 只剩大窗那一路：本机小窗（192×144）收起来了 —— 它比整扇窗还大
    expect(find.byType(CallVideoView), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Positioned && widget.width == 192,
      ),
      findsNothing,
    );
    // 大窗那套 84 宽的圆钮一颗都不剩（四颗 336 塞不进 320）
    expect(find.byType(CallRoundButton), findsNothing);
    // 小窗里没有写字的地方：名字、计时、标签都不画（文字只留在 tooltip 里）
    expect(find.text('Gracelink Team'), findsNothing);
    expect(find.text('00:00:12'), findsNothing);
    expect(find.text('挂断'), findsNothing);
    // 一排图标钮：麦克风 / 摄像头 / 挂断 / 还原
    const icons = <IconData>[
      Icons.mic_rounded,
      Icons.videocam_rounded,
      Icons.call_end_rounded,
      Icons.picture_in_picture_alt_rounded,
    ];
    for (final icon in icons) {
      expect(find.byIcon(icon), findsOneWidget);
      final rect = tester.getRect(find.byIcon(icon));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320), reason: '四个钮得排在一行里');
    }
  });

  testWidgets('小窗里那排钮：静音/挂断/还原都接得上（图标只有 tooltip 说得出名字）', (tester) async {
    final calls = await pump(
      tester,
      stateOf(phase: CallPhase.connected, video: true, callTime: 12),
      pip: true,
      togglePip: () {},
      size: const Size(320, 180),
    );

    expect(find.byTooltip('恢复大窗'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.tap(find.byIcon(Icons.call_end_rounded));
    await tester.tap(find.byIcon(Icons.picture_in_picture_alt_rounded));
    expect(calls, <String>['mic', 'hangup', 'pip']);
  });

  testWidgets('语音通话的小窗：摆头像 + 名字 + 计时（没有画面时才需要那块）', (tester) async {
    await pump(
      tester,
      stateOf(phase: CallPhase.connected, callTime: 75),
      pip: true,
      togglePip: () {},
      size: const Size(320, 180),
    );

    expect(find.text('Gracelink Team'), findsOneWidget);
    expect(find.text('00:01:15'), findsOneWidget);
    // 语音通话没有视频轨：不画摄像头那颗
    expect(find.byIcon(Icons.videocam_rounded), findsNothing);
    expect(find.byType(CallRoundButton), findsNothing);
  });

  testWidgets('小窗里来电那一屏：拒接 + 接听两颗（一样只有图标）', (tester) async {
    final calls = await pump(
      tester,
      stateOf(phase: CallPhase.incoming, isCaller: false, video: true),
      pip: true,
      togglePip: () {},
      size: const Size(320, 180),
    );

    expect(find.byTooltip('挂断'), findsOneWidget);
    expect(find.byTooltip('接听'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.call_rounded));
    await tester.tap(find.byIcon(Icons.call_end_rounded));
    expect(calls, <String>['accept', 'hangup']);
  });
}
