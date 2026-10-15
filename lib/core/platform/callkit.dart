import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 系统（iOS 的 CallKit）那一侧发生的事 —— 原生主动告诉 Dart。
///
/// 三个来源，一个接口：用户在**系统来电界面**上按了键、PushKit 收到一通来电、
/// VoIP token 到位。它们都得回到同一条通话链路（`CallPushHost` → 控制器），
/// 所以做成一个动作流而不是三个回调。
enum CallKitActionKind {
  /// 用户在系统来电界面上按了**接听**（不打开 App 也能接起来）
  answer,

  /// 按了**拒接**（来电）/**挂断**（通话中）
  end,

  /// 原生从 PushKit 收到一通来电。`payload` 是整条 `calling` 报文
  /// （与 `CallPushHost._deliver` 收的那份同构）
  incoming,

  /// PushKit 的 VoIP token 到位 / 变了（服务端发 VoIP 推送要用它）
  token,
}

/// 原生那侧的一个动作。**所有字段都可空**：原生拿到什么就带什么。
@immutable
class CallKitAction {
  const CallKitAction({
    required this.kind,
    this.callId = '',
    this.payload = '',
    this.token = '',
  });

  final CallKitActionKind kind;

  /// 哪一通（原生侧记的那条 id）
  final String callId;

  /// [CallKitActionKind.incoming]：整条 `calling` 报文的 JSON 串
  final String payload;

  /// [CallKitActionKind.token]：PushKit 的 VoIP token（十六进制）
  final String token;

  /// 从原生那张表还原（字段名与 Swift 那边逐字对齐）
  static CallKitAction? fromArguments(Object? arguments) {
    if (arguments is! Map) return null;
    final raw = arguments['kind'];
    if (raw is! String) return null;
    for (final kind in CallKitActionKind.values) {
      if (kind.name != raw) continue;
      return CallKitAction(
        kind: kind,
        callId: '${arguments['callId'] ?? ''}',
        payload: '${arguments['payload'] ?? ''}',
        token: '${arguments['token'] ?? ''}',
      );
    }
    return null;
  }

  @override
  String toString() => 'CallKitAction(${kind.name}, callId=$callId)';
}

/// 「这通来电报给系统了吗」。
///
/// **不是**「看起来报成功了」：`accepted` 只代表系统真的接下了这条来电
/// （锁屏上会弹出来）。模拟器上必然是 `false`（CallKit 不在模拟器上跑），
/// 所以调用方必须把 [reason] 记进日志 —— 否则「锁屏来电没反应」的原因
/// 只剩「不知道」。
@immutable
class CallKitReport {
  const CallKitReport({
    required this.accepted,
    this.reason = '',
    this.callId = '',
    this.alreadyReported = false,
  });

  /// 系统接下了这条来电
  final bool accepted;

  /// 没接下时系统的原话（或我们自己的说明）
  final String reason;

  /// 系统那一侧的 id
  final String callId;

  /// 这通已经报过了（原生侧去重），没有重复弹一个
  final bool alreadyReported;

  static CallKitReport fromArguments(Object? arguments) {
    if (arguments is! Map) {
      return const CallKitReport(accepted: false, reason: '原生没给结果');
    }
    return CallKitReport(
      accepted: arguments['ok'] == true,
      reason: '${arguments['reason'] ?? ''}',
      callId: '${arguments['callId'] ?? ''}',
      alreadyReported: arguments['alreadyReported'] == true,
    );
  }

  @override
  String toString() =>
      'CallKitReport(accepted=$accepted, callId=$callId'
      '${reason.isEmpty ? '' : ', reason=$reason'})';
}

/// **系统级来电界面**（iOS 的 CallKit）—— iOS 侧的 Dart 入口。
///
/// 解决的问题与安卓那条前台服务完全不同：安卓只要进程活着，来电界面我们自己画；
/// 而 iPhone 上「锁屏来电」只有 CallKit 能给 —— 别人打你时，手机锁着、
/// App 甚至已经被系统划掉，你要能在**系统那个来电话的界面**上按接听。
/// 它需要两半，缺一不可：
///
/// 1. **被叫醒**：PushKit 的 VoIP 推送（`UIBackgroundModes: voip` + 服务端发
///    APNs VoIP 推送）。收到之后 iOS 有一条**硬规则**：必须在推送回调里**立刻**
///    把它报给 CallKit，否则这条推送会被当成滥用、系统会掐掉 App
///    （iOS 13 起，见 `docs/release/ios-plan.md`）。
/// 2. **报给系统**：`CXProvider.reportNewIncomingCall` —— 锁屏那个界面就是它画的。
///
/// 所以这个接口有两类方法，别混：
/// * **Dart → 原生**：把「有一通电话了 / 结束了」告诉系统
///   （[reportIncomingCall] / [reportEnded]）；
/// * **原生 → Dart**：系统那一侧的动作（[addActionListener]）。
///
/// 没有「已接通」那一条：来电台在系统界面上被接听时，**接这个动作本身就是**
/// 系统认定「通话开始了」的依据（`CXAnswerCallAction.fulfill`），系统自己开始计时。
/// 而拨出去的叫要么走我们自己的拨号界面（不经 CallKit），要么以后真拿
/// `CXStartCallAction` 发起 —— 到那时再加不迟，现在加只会多一个没人用、
/// 还容易撒谎的方法。
///
/// 抽成接口的理由与 [CallKeepAlive] / [CallPip] 一样：平台能力只有真机能跑，
/// 而「什么时候报、报完谁收尾、非 iOS 上是不是彻底空操作」必须能在单测里钉住。
///
/// 这条路的进度（2026-10-15，别把这里的绿灯当成整条路通了）：
/// * 服务端那一半**写完了**：APNs 直连 + VoIP topic 那条通道（补丁
///   `gracelinkim-server-patch-20261015-voip-push`，部署说明与自检在补丁里），
///   客户端把标识上报成 `apns_voip:xxx` 也接上了（见 [voipToken] 的去向）；
/// * **没验过的是真机**：CallKit 在模拟器上不跑（`reportNewIncomingCall` 必回错误），
///   所以「锁屏上到底弹不弹、接听键按了之后音频对不对」只有一台 iPhone 能答
///   （模拟器上能验的是「通道在、上报失败会带回原因而不是静默」，见
///   `integration_test/ios_callkit_smoke_test.dart`）。
abstract interface class CallKit {
  /// 这个平台有没有 CallKit（只有 iOS 有）
  bool get supported;

  /// 系统这一侧建得起来吗。
  ///
  /// ⚠️ **它不代表报得成**：模拟器上 provider 建得出来，可 `reportNewIncomingCall`
  /// 会回一条错误（CallKit 不在模拟器上跑）。真正的判据是 [reportIncomingCall]
  /// 的返回值；这个值只回答「这台设备上有没有这条路」。
  Future<bool> isAvailable();

  /// 把一通来电报给系统：锁屏 / 后台都会弹出那个系统来电界面。
  ///
  /// [callId] 用来去重（原生侧同一通只报一次）；[payload] 是整条 `calling` 报文，
  /// 原生把它存下来，等 Dart 起来时交回去（App 被推醒时 Dart 还没活）。
  Future<CallKitReport> reportIncomingCall({
    required String callId,
    required String peerId,
    required String peerName,
    required bool video,
    String payload = '',
  });

  /// 这通结束了（对端挂了 / 本机取消 / 响铃超时）：**必须告诉系统**，
  /// 不然锁屏那个界面会一直挂着 —— 用户以为对方还在打。
  Future<void> reportEnded({
    required String callId,
    String reason = 'remoteEnded',
  });

  /// 取走「原生替我存着的那通来电」（App 被 PushKit 叫醒时 Dart 还没起来的那条）。
  ///
  /// 取一次就清掉：与「读冷启动那条通知」同一个道理（见 `CallPushHost`），
  /// 重复接同一通电话会把状态机搅乱。
  /// 没有就回空串。
  Future<String> takePendingCall();

  /// PushKit 的 VoIP token（服务端要拿它发 VoIP 推送）。没有就回空串。
  Future<String> voipToken();

  /// 原生那侧最近一次失败的原话（诊断用，比如模拟器上 CallKit 拒绝上报）
  Future<String> lastError();

  /// 监听系统那一侧的动作。用**监听表**而不是一个 setter：与 `CallPip` 同一个理由
  /// （后注册的把前一个顶掉，就会有一边再也收不到消息）。
  void addActionListener(void Function(CallKitAction action) handler);

  /// 摘掉监听（传进来的必须是**注册过的那个函数对象**）
  void removeActionListener(void Function(CallKitAction action) handler);
}

/// iOS 实现：一条 MethodChannel（`ios/Runner/AppDelegate.swift` 里的 `handleCallKit`）。
///
/// **进程级只有一份**（见 [IosCallKit.new]）：监听表与「谁在听」是按实例存的，
/// 而平台回调是**通道级**的 —— 两个实例同时活着的话，后注册的那个会把回调
/// 顶过去，先来的那个从此收不到系统动作（现象是「锁屏上按了接听没反应」，
/// 看不出跟监听有关）。所以这个类的构造被收成了「要么拿那唯一一份、要么
/// 显式给一条自己的通道」。
class IosCallKit implements CallKit {
  /// 没传 [channel] 时给的是**进程里那一份**（与 `callKitProvider` 同源）；
  /// 传了就是另建一份，各自用自己那条通道 —— 那是给单测 / 模拟器自检注入用的，
  /// 它们用 mock 通道，不该跟真机上那份共用一个监听表。
  factory IosCallKit({MethodChannel? channel}) =>
      channel == null ? _shared : IosCallKit._(channel);

  IosCallKit._(this._channel);

  static final IosCallKit _shared = IosCallKit._(null);

  final MethodChannel? _channel;

  static const MethodChannel _defaultChannel = MethodChannel(
    'gracelinkim/callkit',
  );

  MethodChannel get _methodChannel => _channel ?? _defaultChannel;

  /// 现在听着系统动作的人
  final Set<void Function(CallKitAction)> _listeners = {};

  @override
  bool get supported => true;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (error) {
      debugPrint('[通话] 查询 CallKit 可用性失败：$error');
      return false;
    }
  }

  @override
  Future<CallKitReport> reportIncomingCall({
    required String callId,
    required String peerId,
    required String peerName,
    required bool video,
    String payload = '',
  }) async {
    try {
      final raw = await _methodChannel
          .invokeMethod<Object?>('reportIncomingCall', <String, dynamic>{
            'callId': callId,
            'peerId': peerId,
            'peerName': peerName,
            'video': video,
            'payload': payload,
          });
      return CallKitReport.fromArguments(raw);
    } on MissingPluginException {
      // 旧安装包（这条通道是 2026-10-15 加的）：当成「系统没接下」，
      // 别抛 —— 通话本身照走，只是没有系统来电界面
      return const CallKitReport(
        accepted: false,
        reason: '这个 iOS 包里还没有 CallKit 通道（旧版本）',
      );
    } on PlatformException catch (error) {
      return CallKitReport(
        accepted: false,
        reason: error.message?.isNotEmpty == true ? error.message! : error.code,
      );
    } catch (error) {
      return CallKitReport(accepted: false, reason: '$error');
    }
  }

  @override
  Future<void> reportEnded({
    required String callId,
    String reason = 'remoteEnded',
  }) async {
    await _ignoreFailure('reportEnded', <String, dynamic>{
      'callId': callId,
      'reason': reason,
    });
  }

  /// 这两条**失败也不抛**：通话已经结束了/已经在走了，画面上那个系统界面
  /// 收不收得掉只影响观感 —— 绝不能因为收尾失败把一通电话搅黄。
  Future<void> _ignoreFailure(String method, Map<String, dynamic> args) async {
    try {
      await _methodChannel.invokeMethod<void>(method, args);
    } catch (error) {
      debugPrint('[通话] CallKit $method 失败：$error');
    }
  }

  @override
  Future<String> takePendingCall() async {
    try {
      return await _methodChannel.invokeMethod<String>('takePendingCall') ?? '';
    } catch (error) {
      debugPrint('[通话] 取 PushKit 存下的来电报文失败：$error');
      return '';
    }
  }

  @override
  Future<String> voipToken() async {
    try {
      return await _methodChannel.invokeMethod<String>('voipToken') ?? '';
    } catch (error) {
      debugPrint('[通话] 取 VoIP token 失败：$error');
      return '';
    }
  }

  @override
  Future<String> lastError() async {
    try {
      return await _methodChannel.invokeMethod<String>('lastError') ?? '';
    } catch (error) {
      return '$error';
    }
  }

  @override
  void addActionListener(void Function(CallKitAction action) handler) {
    // **每次注册都重挂一遍**平台回调（幂等的同一只闭包）：这样「后来注册的
    // 那一个」永远不会被「先走掉的那一个」顺手摘掉，谁也不用假设自己是不是唯一那个。
    //
    // ⚠️ 刻意**不在没人听的时候把回调摘成 null**（2026-10-15 排查时改的）：
    // 摘掉的前提是「我这个实例就是唯一那个」，而那只是个假设 —— 万一同时活着
    // 两个（历史上的隐患：provider 随容器重建），后一个 remove 掉自己的监听时
    // 会把**前一个**装上去的回调一起清掉，两边从此都收不到系统动作，
    // 而现象是「锁屏上按了接听没反应」，看不出跟监听有关。
    // 代价只是空转一次投递：回调里 `_listeners` 为空就什么都不做。
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method != 'action') return null;
      final action = CallKitAction.fromArguments(call.arguments);
      if (action == null) return null;
      for (final listener in List<void Function(CallKitAction)>.of(
        _listeners,
      )) {
        listener(action);
      }
      return null;
    });
    _listeners.add(handler);
  }

  @override
  void removeActionListener(void Function(CallKitAction) handler) {
    _listeners.remove(handler);
  }
}

/// 没有 CallKit 的平台（安卓 / 桌面）：什么都不做，`supported` 是 false。
///
/// 界面据此决定「要不要画那个『锁屏来电』的说明」；调用方一律先看 [supported]。
class NoopCallKit implements CallKit {
  const NoopCallKit();

  @override
  bool get supported => false;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<CallKitReport> reportIncomingCall({
    required String callId,
    required String peerId,
    required String peerName,
    required bool video,
    String payload = '',
  }) async => const CallKitReport(accepted: false, reason: '这个平台没有 CallKit');

  @override
  Future<void> reportEnded({
    required String callId,
    String reason = 'remoteEnded',
  }) async {}

  @override
  Future<String> takePendingCall() async => '';

  @override
  Future<String> voipToken() async => '';

  @override
  Future<String> lastError() async => '';

  @override
  void addActionListener(void Function(CallKitAction action) handler) {}

  @override
  void removeActionListener(void Function(CallKitAction action) handler) {}
}

final callKitProvider = Provider<CallKit>(
  (ref) => Platform.isIOS ? IosCallKit() : const NoopCallKit(),
);
