import 'package:flutter/foundation.dart';

/// 时间线上的一条
@immutable
class SfuTraceEntry {
  const SfuTraceEntry({
    required this.at,
    required this.text,
    required this.failure,
  });

  /// 相对进房间那一刻的偏移
  final Duration at;

  final String text;

  /// 这一条是失败（面板上标红，也计入失败数）
  final bool failure;

  /// `+12.3s`
  String get label => '+${(at.inMilliseconds / 1000).toStringAsFixed(1)}s';

  @override
  String toString() => failure ? '$label $text  ← 失败' : '$label $text';
}

/// 群通话发生了什么：一条时间线 + 几个计数。
///
/// 为什么群通话尤其需要它：这个功能**没有本地能跑的完整验证**（真 WebRTC + CF 的
/// SFU 都在真机上），出问题时界面上长得都一样（"没人说话" / "听不到他"）。
/// 有了这份记录，三类问题一眼能分开：
///
/// * **订阅没建上**（面板里看不到那条 `u2|mic`）→ 快照/权限/重协商的问题；
/// * **订阅建了但没流**（有 `u2|mic → mid-x` 却听不到）→ CF 侧或对方没发布；
/// * **重建风暴**（`重建` 计数一直涨）→ 网络或凭据问题，那通电话的通话质量一定差。
///
/// 纯逻辑（不碰平台通道、不碰文件），所以能整体跑单测：时间用注入的 `now`，
/// 面板与导出在 `features/group_call/group_call_diagnostics_sheet.dart`。
/// 它是 [ChangeNotifier]：诊断面板开着的时候要跟着新条目刷（面板盯着它，
/// 而不是整个房间状态 —— 时间线上的变化不一定伴随界面状态变化）。
class SfuTrace extends ChangeNotifier {
  SfuTrace({this.limit = 80, DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _start = _now();
  }

  /// 时间线最多留多少条（老的最先扔掉：出问题时最近那几十条才有用）
  final int limit;

  final DateTime Function() _now;
  late DateTime _start;

  final List<SfuTraceEntry> entries = <SfuTraceEntry>[];

  /// 发布了几次（含共享屏那次）
  int publishes = 0;

  /// 订阅批次数（一批可以带多条 track）
  int subscribes = 0;

  /// 把 answer 交回 CF 的次数（订阅一步就有一次）
  int renegotiates = 0;

  /// 关 track 的次数（停订阅 / 停共享屏）
  int closes = 0;

  /// 换新会话重建的次数（**这个数一直涨就说明网络或凭据有问题**）
  int rebuilds = 0;

  /// 失败条目数
  int failures = 0;

  int heartbeats = 0;
  int heartbeatFailures = 0;

  /// 记一条。**同时写进手机日志**（`adb logcat` 里搜 `[群通话]`）：
  /// 真机上的群通话问题以前只能靠用户长按复制诊断面板，一来慢、二来用户漏一步
  /// 就什么都看不到。日志是插上手机就能读的，排查不用再等人配合。
  void record(String text, {bool failure = false}) {
    debugPrint('[群通话]${failure ? ' ✗' : ''} $text');
    entries.add(
      SfuTraceEntry(
        at: _now().difference(_start),
        text: text,
        failure: failure,
      ),
    );
    if (entries.length > limit) entries.removeAt(0);
    if (failure) failures += 1;
    notifyListeners();
  }

  /// 重新开始（重建房间、第二次进房间时用）
  void reset() {
    entries.clear();
    publishes = 0;
    subscribes = 0;
    renegotiates = 0;
    closes = 0;
    rebuilds = 0;
    failures = 0;
    heartbeats = 0;
    heartbeatFailures = 0;
    _start = _now();
    notifyListeners();
  }

  /// 面板与导出里那行计数（中文与 `summary` 一致：给开发者看的诊断文本）
  String get counters =>
      '发布 $publishes · 订阅 $subscribes · 重协商 $renegotiates · '
      '关闭 $closes · 重建 $rebuilds · 失败 $failures · '
      '心跳 $heartbeats（失败 $heartbeatFailures）';
}
