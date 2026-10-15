import 'package:gracelinkim/core/platform/callkit.dart';

/// 假的**系统来电界面**（CallKit）：记录报了几通、收了几通，并让用例假装
/// 「用户在系统界面上按了接听 / 挂断」或「原生替我们存下了一条来电报文」。
///
/// 真 CallKit 只有 iPhone 上有（模拟器上都不工作），而**什么时候报、什么时候收尾、
/// 报几遍**这套判断必须能在单测里钉住 —— 与 `FakeCallPip` / 保活那条同一个理由。
class FakeCallKit implements CallKit {
  FakeCallKit({
    this.supported = true,
    this.accept = true,
    this.reasonWhenRefused = 'CallKit 不在模拟器上跑',
  });

  @override
  final bool supported;

  /// 系统接不接受这条来电（真机 true；模拟器上必然 false）
  bool accept;

  /// 不接受时给的原因
  String reasonWhenRefused;

  /// 每次上报记一行：`callId|peerId|peerName|video`
  final List<String> reported = <String>[];

  /// 每次收尾记一行：`callId|reason`
  final List<String> ended = <String>[];

  /// 原生替我们存下的来电报文（`takePendingCall` 依次给出去，取完就没了）
  final List<String> pending = <String>[];

  /// PushKit 那条 token
  String token = '';

  /// 原生那侧最近一次失败的原话
  String lastErrorText = '';

  final Set<void Function(CallKitAction)> _listeners = {};

  /// 假装系统那一侧发生了点事（用户按了接听 / 推送叫醒 / token 到了）
  void emit(CallKitAction action) {
    for (final listener in _listeners.toList(growable: false)) {
      listener(action);
    }
  }

  /// 最后一次上报的字段（没报过就是 null）
  String? get lastReported => reported.isEmpty ? null : reported.last;

  @override
  Future<bool> isAvailable() async => supported;

  @override
  Future<CallKitReport> reportIncomingCall({
    required String callId,
    required String peerId,
    required String peerName,
    required bool video,
    String payload = '',
  }) async {
    reported.add('$callId|$peerId|$peerName|$video');
    if (!accept) {
      return CallKitReport(accepted: false, reason: reasonWhenRefused);
    }
    return CallKitReport(accepted: true, callId: 'uuid-${reported.length}');
  }

  @override
  Future<void> reportEnded({
    required String callId,
    String reason = 'remoteEnded',
  }) async {
    ended.add('$callId|$reason');
  }

  @override
  Future<String> takePendingCall() async =>
      pending.isEmpty ? '' : pending.removeAt(0);

  @override
  Future<String> voipToken() async => token;

  @override
  Future<String> lastError() async => lastErrorText;

  @override
  void addActionListener(void Function(CallKitAction action) handler) =>
      _listeners.add(handler);

  @override
  void removeActionListener(void Function(CallKitAction action) handler) =>
      _listeners.remove(handler);
}
