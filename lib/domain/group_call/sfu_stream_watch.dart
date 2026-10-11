/// 一条远端视频「还在不在收」的判定。
///
/// 为什么需要它（2026-10-08 用户报的）：**电脑在共享屏幕、然后直接挂断群通话，
/// 手机端看到的画面就永远停在最后一帧** —— 手机手里那张图是「最后一张」，而它自己
/// 并不知道对方已经没了：注册表要等行超时（封顶 45 秒）才把人清掉，推送也可能丢，
/// 于是画面就一直卡在那里，连「对方已离开」都没有。
///
/// 判据只有一条：**接收侧的计数不涨了**。每次 [tick] 把 `mid → 计数` 喂进来
/// （`framesDecoded` 这类，见 `SfuPeerConnection.inboundVideoCounters`），
/// 连续 [timeout] 一点没涨就判这一路已经死了。
///
/// 为什么这条判据够稳：屏幕共享是**一直有帧**的（画面不动时编码器也会周期性刷新），
/// 所以「连续八秒一个计数都没动」只可能是那一路真的没了；而统计里连读数都消失的
/// mid 也一样算（那说明连那一路的统计都没了）。真要是误判，代价也只是把一张死图
/// 提前放下来 —— 注册表那边一旦说「他还在共享」，下一轮对账会把订阅重新谈起来。
class SfuStreamWatch {
  SfuStreamWatch({required this.timeout, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 多久收不到新数据就判这一路死了
  final Duration timeout;

  final DateTime Function() _now;

  /// 上一次看到的计数值
  final Map<String, int> _lastValue = <String, int>{};

  /// 计数**上一次变化**的时刻（第一次见到的那一刻也算）
  final Map<String, DateTime> _lastSeen = <String, DateTime>{};

  /// 在盯几路
  bool get watching => _lastSeen.isNotEmpty;

  /// 只盯这些 mid（退订的那些忘掉）：有共享屏时才开着这条检查
  void keep(List<String> mids) {
    final wanted = mids.toSet();
    _lastValue.removeWhere((mid, _) => !wanted.contains(mid));
    _lastSeen.removeWhere((mid, _) => !wanted.contains(mid));
  }

  /// 这一路不用再盯了（退订了 / 已经判死过一次）
  void forget(String mid) {
    _lastValue.remove(mid);
    _lastSeen.remove(mid);
  }

  void reset() {
    _lastValue.clear();
    _lastSeen.clear();
  }

  /// 采一轮计数，返回**这一轮判死的 mid**（可以注入 [at]：用例不用等真时钟）。
  List<String> tick(Map<String, int> counters, [DateTime? at]) {
    final now = at ?? _now();
    final stalled = <String>[];
    final seen = <String>{};
    for (final entry in counters.entries) {
      seen.add(entry.key);
      final last = _lastValue[entry.key];
      if (last == null || entry.value != last) {
        // 第一次见到 / 涨了：都是「还在收」
        _lastValue[entry.key] = entry.value;
        _lastSeen[entry.key] = now;
        continue;
      }
      final since = _lastSeen[entry.key];
      if (since != null && now.difference(since) >= timeout) {
        stalled.add(entry.key);
      }
    }
    // 统计里**整个消失**的 mid：上一次还在，这一次连读数都没有了（也是死了）
    for (final mid in _lastValue.keys.toList(growable: false)) {
      if (seen.contains(mid)) continue;
      final since = _lastSeen[mid];
      if (since != null && now.difference(since) >= timeout) {
        stalled.add(mid);
      }
    }
    return stalled;
  }
}
