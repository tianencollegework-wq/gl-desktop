/// 通话窗里那一页（2026-10-04）——**这颗窗口与别的子窗口不一样**：
/// 真媒体引擎也在这里（见 `call_window_bridge.dart` 那段图）。
///
/// 它只做三件事：
///
/// * 把主窗口推过来的状态（`callStatePayload`）摆成界面
///   （`call_desktop_page.dart`，微信 PC 那套版式）；
/// * 收主窗口发来的媒体指令，交给**本地**那份真引擎（`WebrtcCallMediaEngine`），
///   原样把结果回过去（SDP、候选、统计——都是能过通道的东西）；
/// * 本地引擎有点动静（流到了 / 候选 / 连通 / 失败）就报给主窗口，并把界面上
///   点的那一下（接听/挂断/静音/摄像头/大小窗互换）也送过去 —— 那些事只有
///   主窗口那份状态机能做。
///
/// 还有一件与别的子窗不一样的事：**用户按 ✕ 在这里不等于「直接拆窗口」**。
/// 这扇窗里那颗媒体引擎还活着的时候拆引擎，webrtc 会在拆音频设备那一步 abort，
/// **整个 app 一起没**（2026-10-05 真机两次实测）。所以原生那边先把 ✕ 问过来
/// （`DesktopWindowNative.onCloseRequested`），这里按「挂断」那套顺序收摊：
/// 先请主窗口收尾 → 再放媒体 → 最后才关窗（见 [_onCloseRequested]）。
///
/// 2026-10-05 起还多了一手**画中画小窗**：控制栏那颗钮让这扇窗自己去跟原生
/// 说「把我缩成右下角那个置顶小窗」（去边框 / 不占任务栏 / 置顶 / 320×180），
/// 页面同时换成紧凑版式；小窗里按住画面能拖走，那颗「还原」钮把它变回大窗
/// （见 [_togglePip]）—— 整件事只跟这扇窗自己有关，主窗口不用知道。
///
/// 窗口参数里已经带了「对端是谁」（名字/头像/语音还是视频/谁发起），所以第一屏
/// 不用等主窗口那一份状态就是对的；状态那份跟着 `ready` 自己伸手要一次
/// （被叫那一屏没有计时器，靠主窗口主动推可能会错过）。
library;

import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../data/media/call_media_engine.dart';
import '../../domain/call/call_controller.dart';
import '../../domain/call/call_machine.dart';
import '../../domain/call/call_signal.dart';
import '../desktop_window/desktop_window_native.dart';
import '../desktop_window/window_args.dart';
import 'call_desktop_page.dart';
import 'call_window_bridge.dart';

class DesktopCallWindow extends ConsumerStatefulWidget {
  const DesktopCallWindow({super.key, required this.args, this.mediaEngine});

  final DesktopWindowArgs args;

  /// 造本机媒体引擎的方式。
  ///
  /// 真机上就是「惰性 ICE 那份真引擎」；测试里换成假的，好钉住 ✕ 那条路
  /// 「先放媒体、再关窗」的顺序（那顺序就是 S12.29 那个崩溃修复本身）。
  final CallMediaEngine Function()? mediaEngine;

  @override
  ConsumerState<DesktopCallWindow> createState() => _DesktopCallWindowState();
}

class _DesktopCallWindowState extends ConsumerState<DesktopCallWindow> {
  /// 本地那份真引擎。ICE 列表是主窗口算好的（子引擎里没有会话配置）。
  late final CallMediaEngine _engine =
      widget.mediaEngine?.call() ??
      WebrtcCallMediaEngine.withLazyIceServers(
        iceServers: () => widget.args.iceServers,
      );

  /// 主窗口 ↔ 这里那两条线
  late final WindowMethodChannel _fromMain = WindowMethodChannel(
    callWindowChannelName,
    mode: ChannelMode.unidirectional,
  );
  late final WindowMethodChannel _toMain = WindowMethodChannel(
    callWindowEventChannelName,
    mode: ChannelMode.unidirectional,
  );

  /// 界面看的那份状态：先用窗口参数拼一个（第一屏就不白），主窗口的推送随后到
  late CallViewState _state = _initialState();

  /// 现在缩在**画中画小窗**里没有（2026-10-05）。
  ///
  /// 这颗状态只属于这扇窗：进/出都是原生把这扇窗改一下（去边框 + 置顶 +
  /// 不占任务栏 + 换成右下角那个小尺寸，见 `desktop_window_native.dart::setPip`），
  /// 主窗口那边不需要知道 —— 挂断那条路（`bye` → 关窗）跟小窗毫无关系。
  bool _pip = false;

  /// 正在走「用户按了 ✕」那条收摊的路（媒体已经/正在放、窗马上关）。
  ///
  /// 给 [callWindowBye] 看的：收摊的过程中主窗口那句「再见」会到得比我们这边
  /// 放媒体还早，那时候**不能**让它直接关窗 —— 窗一关引擎就拆了，而我们的
  /// `engine.close()` 可能还在半路，那就又踩回它会 abort 的那条路。
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _engine.onLocalStream = (_) => _reportEvent(callEventLocalStream);
    _engine.onRemoteStream = (_) => _reportEvent(callEventRemoteStream);
    _engine.onIceCandidate = (candidate) => _reportEvent(
      callEventIceCandidate,
      <String, dynamic>{'candidate': candidate},
    );
    _engine.onConnected = () => _reportEvent(callEventConnected);
    _engine.onConnectionFailed = (error) =>
        _reportEvent(callEventFailed, <String, dynamic>{'error': '$error'});
    unawaited(_setup());
  }

  @override
  void dispose() {
    unawaited(_engine.close());
    super.dispose();
  }

  CallViewState _initialState() {
    final args = widget.args;
    return CallViewState(
      session: CallSession(
        phase: args.isCaller ? CallPhase.outgoing : CallPhase.incoming,
        peerId: args.id,
        peerName: args.title,
        peerAvatar: args.avatar,
        type: args.video ? CallType.video : CallType.voice,
        isCaller: args.isCaller,
      ),
    );
  }

  /// 窗口出来、两条线挂上，再自报家底 + 要一次状态。
  Future<void> _setup() async {
    // 先装「用户按了 ✕」这一手（越早越好：窗口一显形就可能被人点）
    DesktopWindowNative.onCloseRequested(_onCloseRequested);
    final args = widget.args; // 标题就是对端的名字（微信 PC 那个通话窗也是这么写的）；真拿不到就摆应用名
    await DesktopWindowNative.setTitle(
      args.title.isEmpty ? 'Gracelink' : args.title,
    );
    final geometry = args.video ? const Size(600, 700) : const Size(420, 620);
    await DesktopWindowNative.setSize(geometry.width, geometry.height);
    await DesktopWindowNative.center();
    await DesktopWindowNative.show();

    try {
      await _fromMain.setMethodCallHandler(_onMainCall);
    } on Object catch (error) {
      debugPrint('[通话窗口] 主窗口那条线没挂上：$error');
    }
    // 家底：屏幕共享支不支持 / 有没有摄像头 / 这份 ICE 列表长什么样
    // （主窗口那份代理靠它回答诊断面板与界面）。拿到媒体之后还会再报一次 ——
    // 那一刻「有没有摄像头」才是真的，见 [_reportCapabilities]。
    _reportCapabilities();
    // 「现在该画哪一屏」自己伸手要一次（见文件头）
    _reportEvent(callEventReady);
  }

  /// 自报家底（屏幕共享支不支持 / 有没有摄像头 / 实际用的 ICE 列表）。
  ///
  /// ⚠️ 要报两次。`_setup()` 那一次是「窗口刚起来」：摄像头还没取（`hasLocalVideo`
  /// 必然是 false）、连接也还没建（ICE 列表还是「打算用的那一份」）。
  /// 拿到媒体之后再报一次才是真的（`_onMedia` 的 `open` 那条路）。
  void _reportCapabilities() {
    _reportEvent(callEventCapabilities, <String, dynamic>{
      'supportsScreenShare': _engine.supportsScreenShare,
      'hasLocalVideo': _engine.hasLocalVideo,
      'iceServersDescription': _engine.iceServersDescription,
    });
  }

  /// 主窗口叫我们做的事：状态 / 媒体指令 / 打招呼 / 再见
  Future<dynamic> _onMainCall(MethodCall call) async {
    switch (call.method) {
      case callWindowState:
        final data = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : <String, dynamic>{};
        if (mounted) setState(() => _state = callViewStateFrom(data));
        return <String, dynamic>{'ok': true};
      case callWindowMedia:
        final data = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : <String, dynamic>{};
        final args = data['args'] is Map
            ? Map<String, dynamic>.from(data['args'] as Map)
            : <String, dynamic>{};
        return _onMedia((data['method'] as String?) ?? '', args);
      case callWindowPing:
        return <String, dynamic>{
          'kind': DesktopWindowKind.call.name,
          'title': widget.args.title,
        };
      case callWindowBye:
        // 挂断之后：窗口自己关（关窗只有窗口自己做得干净）。
        //
        // ⚠️ 但若正在走 ✕ 那条收摊的路，就**别插手**：那边会先放媒体再关，
        // 这里要是把窗先关了，就是「媒体还在拆、引擎已经被拆」—— abort。
        if (_closing) return <String, dynamic>{'ok': true};
        // 先放媒体（本机流/连接），再关窗：反过来的话 webrtc 会在拆音频设备时
        // abort（见 [_onCloseRequested]）。
        await _engine.close();
        await DesktopWindowNative.close();
        return <String, dynamic>{'ok': true};
      default:
        throw MissingPluginException('通话窗不认识这个调用：${call.method}');
    }
  }

  /// 一条媒体指令 → 本地引擎。**返回的东西必须是能过通道的**（字符串/map/数字）。
  Future<Object?> _onMedia(String method, Map<String, dynamic> args) async {
    final engine = _engine;
    final video = args['video'] == true;
    switch (method) {
      case 'open':
        await engine.open(video: video);
        // 拿到媒体了：家底里「有没有摄像头 / 真正用上的 ICE 列表」这一刻才是真的
        _reportCapabilities();
        return null;
      case 'createOffer':
        return engine.createOffer(video: video);
      case 'acceptOffer':
        return engine.acceptOffer('${args['sdp'] ?? ''}', video: video);
      case 'applyAnswer':
        await engine.applyAnswer('${args['sdp'] ?? ''}');
        return null;
      case 'addIceCandidate':
        final raw = args['candidate'];
        if (raw is Map) {
          await engine.addIceCandidate(Map<String, dynamic>.from(raw));
        }
        return null;
      case 'setMicrophoneEnabled':
        engine.setMicrophoneEnabled(args['enabled'] == true);
        return null;
      case 'setCameraEnabled':
        engine.setCameraEnabled(args['enabled'] == true);
        return null;
      case 'toggleCamera':
        await engine.toggleCamera();
        return null;
      case 'setSpeakerEnabled':
        await engine.setSpeakerEnabled(args['enabled'] == true);
        return null;
      case 'requestScreenSharePermission':
        return engine.requestScreenSharePermission();
      case 'startScreenShare':
        // 共享哪一块（整个屏幕 / 某个窗口）与要不要连**电脑声音**一起发
        // （S12.32）都由通话窗自己选好后带下来（见 `call_desktop_page.dart`
        // 里那个选择面板）：桌面原生读 `deviceId.exact`，不传就是默认源（主屏）。
        //
        // 回话是个**字符串**（枚举过不了通道）：`ScreenShareAudioRoute.name`，
        // 主窗口那份代理自己解回来（见 `call_window_media_engine.dart`）。
        final route = await engine.startScreenShare(
          sourceId: args['sourceId'] as String?,
          withAudio: args['withAudio'] == true,
        );
        return route.name;
      case 'stopScreenShare':
        await engine.stopScreenShare();
        return null;
      case 'sampleStats':
        return callSamplePayload(await engine.sampleStats());
      case 'close':
        await engine.close();
        return null;
      default:
        throw MissingPluginException('通话窗不认识这条媒体指令：$method');
    }
  }

  /// 用户按了 ✕（原生先来问这一声）：**这不是「随便把窗口销毁」**。
  ///
  /// 这扇窗里有一颗活着的 webrtc 媒体引擎。直接拆引擎，webrtc 会在
  /// `AudioDeviceModuleImpl::Terminate` 那一步 abort —— **整个 app 一起没**
  /// （2026-10-05 真机两次实测：事件日志 `gracelinkim.exe / 0xc0000409`）。
  /// 对照：窗里那颗「挂断」（先放媒体、再关窗）一切正常。
  ///
  /// 所以 ✕ 的规矩是三步，顺序不能换：
  ///
  /// 1. 先告诉主窗口「这一通按挂断收尾」（它手里才有信令与通话记录）；
  /// 2. 再把这边的媒体放干净（3 秒封顶：真放不掉也得往下走，不能把窗留在那儿）；
  /// 3. 最后才让原生销毁窗口。
  Future<void> _onCloseRequested() async {
    if (_closing) return;
    _closing = true;
    // 1) 主窗口那份状态机要知道：用户把窗关了 = 这通结束了（它会发挂断信令、
    //    记通话记录，然后按老规矩说一句 `bye`）
    _action('hangup');
    // 2) 媒体先放掉 —— 这一步就是这整段存在的理由
    try {
      await _engine.close().timeout(const Duration(seconds: 3));
    } on Object catch (error) {
      debugPrint('[通话窗口] ✕ 收摊时放媒体没放干净（照样关窗）：$error');
    }
    // 3) 收完了，拆吧
    await DesktopWindowNative.close();
  }

  /// 进 / 出画中画小窗（界面上那颗钮）。
  ///
  /// 原生回 false（这台机器上没做成）就**不切版式** —— 界面绝不能自己以为
  /// 在小窗里：那样画面会挤成一小块、而窗还是大的，比不做还难用。
  Future<void> _togglePip() async {
    final next = !_pip;
    final applied = await DesktopWindowNative.setPip(
      on: next,
      width: kCallDesktopPipSize.width,
      height: kCallDesktopPipSize.height,
    );
    if (!applied) {
      debugPrint('[通话窗口] 画中画这台机器上没做成（保持原样）');
      return;
    }
    if (!mounted) return;
    setState(() => _pip = next);
  }

  /// 「共享屏幕」这一下：选好的源 + 要不要连**电脑的声音**一起发（S12.32）
  /// 原样交给主窗口那份状态机（停不停、发不发都是它说了算）。
  void _shareScreen(String? sourceId, bool withAudio) => _action(
    'screenShare',
    <String, dynamic>{'sourceId': sourceId, 'withAudio': withAudio},
  );

  /// 小窗里按住画面就能拖着走（小窗摆哪儿由用户定）。
  ///
  /// 位移**不在 Dart 这边算**：窗口一跟着动，指针在窗里的局部坐标也跟着变，
  /// 两边一抵消就拖不动了 —— 这三下（begin/update/end）是让原生按**真光标
  /// 位置**去算的（见 `desktop_window_native.dart::dragBegin`）。
  ///
  /// 用 `translucent`：底下那些钮照样点得到（点击走 tap、这里只接 pan）。
  Widget _draggable(Widget child) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => unawaited(DesktopWindowNative.dragBegin()),
    onPanUpdate: (_) => unawaited(DesktopWindowNative.dragUpdate()),
    onPanEnd: (_) => unawaited(DesktopWindowNative.dragEnd()),
    onPanCancel: () => unawaited(DesktopWindowNative.dragEnd()),
    child: child,
  );

  /// 报一件事给主窗口（那条线还没挂上就记一笔 —— 主窗口会靠 `ready` 对账）
  void _reportEvent(String event, [Map<String, dynamic> extra = const {}]) {
    unawaited(
      _toMain
          .invokeMethod<Object?>(callWindowEvent, <String, dynamic>{
            'event': event,
            ...extra,
          })
          .catchError((Object error) {
            debugPrint('[通话窗口] 报 $event 没送到：$error');
            return null;
          }),
    );
  }

  /// 界面上点的那一下 → 主窗口（接听/挂断/静音/摄像头/大小窗互换都只有那份
  /// 状态机能做）。
  ///
  /// [extra] 是这一下顺带的参数（目前只有共享屏幕的 `sourceId`：选的是哪一块源）。
  /// 主窗口那份状态机在 [_onWindowAction] 里按 action 取。
  void _action(String action, [Map<String, dynamic> extra = const {}]) {
    unawaited(
      _toMain
          .invokeMethod<Object?>(callWindowAction, <String, dynamic>{
            'action': action,
            ...extra,
          })
          .catchError((Object error) {
            debugPrint('[通话窗口] 动作 $action 没送到：$error');
            return null;
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = CallDesktopPage(
      i18n: ref.watch(appI18nProvider),
      state: _state,
      localStream: _engine.localStream,
      remoteStream: _engine.remoteStream,
      // 小窗那一版版式（只有 320×180，见 `call_desktop_page.dart::_pipLayout`）
      pip: _pip,
      actions: CallDesktopActions(
        accept: () => _action('accept'),
        hangup: () => _action('hangup'),
        toggleMicrophone: () => _action('mic'),
        toggleCamera: () => _action('camera'),
        toggleLayout: () => _action('layout'),
        diagnostics: () =>
            _action('diagnostics'), // 共享屏幕（桌面）：这颗窗里的媒体引擎就是真引擎，但「谁在共享」是
        // 主窗口那份状态机的事 —— 这里只把选择好的源递上去
        startScreenShare: _state.canShareScreen ? _shareScreen : null,

        // 画中画：这扇窗自己的事（缩的是它自己）
        togglePip: _togglePip,
      ),
    );
    return ColoredBox(
      color: Colors.black,
      child: _pip ? _draggable(page) : page,
    );
  }
}
