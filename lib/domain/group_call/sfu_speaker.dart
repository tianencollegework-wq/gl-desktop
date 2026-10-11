/// 群通话里「谁在说话」的判定。
///
/// 为什么要有它：音频能量是**每一轮单独采样**的（Cloudflare 不会告诉我们谁在说），
/// 而界面上那个人名/头像不能跟着采样一跳一跳 —— 说话中间换气、词与词之间的静音
/// 都会让能量掉下去。所以这里做两件事：
///
/// * **阈值**：低于 [threshold] 的一律当成"没说话"（底噪、键盘声）；
/// * **保持**：一旦认定某人开始说，他停下来的 [hold] 时间内仍然算他 ——
///   这就是微信那种"名字亮着不动"的观感。
///
/// 它不认识 mid / 流，只认 `userId → 0~1` 的能量表（归位在 `SfuRoom` 里做，
/// 那边才知道 mid 是谁的）。
class SfuSpeakerTracker {
  SfuSpeakerTracker({
    this.threshold = 0.02,
    this.hold = const Duration(milliseconds: 1200),
  });

  /// 起说门槛：低于它算没说话
  final double threshold;

  /// 说完之后还认他多久
  final Duration hold;

  String? _active;
  DateTime? _lastHeard;

  /// 当前认定的说话人（没人说话时 null）
  String? get active => _active;

  /// 喂一轮能量（`userId → 0~1`），返回这一轮之后的活跃说话人。
  ///
  /// 规则很简单，但顺序重要：**先看这一轮有没有人在说**（有就立刻换人，
  /// 不等保持期），没有才走保持期。
  String? update(Map<String, double> levels, DateTime now) {
    String? loudest;
    var best = threshold;
    for (final entry in levels.entries) {
      final level = entry.value;
      if (!level.isFinite || level < best) continue;
      best = level;
      loudest = entry.key;
    }
    if (loudest != null) {
      _active = loudest;
      _lastHeard = now;
      return _active;
    }
    final active = _active;
    final heard = _lastHeard;
    if (active != null && heard != null && now.difference(heard) >= hold) {
      _active = null;
      _lastHeard = null;
    }
    return _active;
  }

  /// 清空（离开房间 / 重建会话时用）
  void reset() {
    _active = null;
    _lastHeard = null;
  }
}
