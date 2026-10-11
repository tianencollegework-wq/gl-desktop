import 'call_signal.dart';

/// 多端通话锁（老端 `store/message.js` 里的 `webrtcLock`）。
///
/// **它纯粹是客户端的启发式**：服务端没有「通话会话」这个概念，所以同一账号
/// 两台设备同时振铃是拦不住的——老端也拦不住（见 `docs/protocol/call-signaling.md`
/// 的那条警告）。新端把同样的规则收口到这里，行为与老端一致，但别指望它可靠。
///
/// 值的三种形态照抄老端（它是 JS，`false` / `true` / 对方 user_id 混着用）：
/// * `false` / `null` → 没锁；
/// * 对方 user_id → 来电时锁上（能被「对方下线」那条规则匹配到）；
/// * `true` → 收到 `offer` / `answer` 时锁上（老端在这里丢了对方 id，
///   所以之后「对方下线」匹配不上，锁会一直留着）。
class CallLock {
  Object? _value;

  /// 有没有锁（老端那个 `if (msgStore.webrtcLock)`）
  bool get isLocked => _value != null && _value != false;

  /// 锁的是谁（只在来电时锁的那种形态下才有值）
  String? get peerId => _value is String ? _value as String : null;

  /// 老端 `App.vue`：来电时 `webrtcLock = data.fromUser.user_id`
  void lockPeer(String peerId) => _value = peerId;

  /// 老端 `App.vue`：`offer` / `answer` 时 `webrtcLock = true`
  void lockAnonymous() => _value = true;

  void unlock() => _value = false;

  /// 老端 `App.vue`：`if (!data.is_online && webrtcLock == data.id) webrtcLock = false`
  void peerOffline(String peerId) {
    if (_value == peerId) unlock();
  }

  /// 老端 `App.vue`：自己那条信令带回 902/903/905/906/907 就解锁
  void ownSignal(int code) {
    if (CallCode.unlockCodes.contains(code)) unlock();
  }

  @override
  String toString() => 'CallLock($_value)';
}
