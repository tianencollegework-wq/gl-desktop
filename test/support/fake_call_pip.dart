import 'package:gracelinkim/core/platform/call_pip.dart';

/// 假的小窗（画中画）：记录「参数（比例/标题）什么时候交给系统、什么时候进/出小窗」。
///
/// 真画中画只有安卓真机能跑，但「参数跟着通话状态走、只有点按钮才进、
/// 每条结束路径都要把小窗收掉」这条策略必须能在单测里钉住（跟保活那条一样的理由）。
class FakeCallPip implements CallPip {
  FakeCallPip({this.supported = true, this.available = true});

  @override
  final bool supported;

  /// 系统接不接受（部分 ROM 关掉了画中画）
  bool available;

  /// 每次 `setParams` 的参数（`video=false title=老B`），按顺序
  final List<String> settings = <String>[];

  /// 现在是不是在小窗里
  bool inPip = false;

  /// `isInPip` 被问了几次
  int queries = 0;

  /// 「缩成小窗」按钮被点了几次
  int enters = 0;

  /// 通话结束时收小窗收了几次
  int exits = 0;

  /// 点「缩成小窗」时系统接不接受
  bool acceptEnter = true;

  /// 让 `setEnabled` 抛（模拟通道/ROM 出问题）
  Object? error;

  final Set<void Function(bool inPip)> _modeListeners = {};

  @override
  void addModeListener(void Function(bool inPip) handler) =>
      _modeListeners.add(handler);

  @override
  void removeModeListener(void Function(bool inPip) handler) =>
      _modeListeners.remove(handler);

  @override
  Future<bool> isInPip() async {
    queries += 1;
    return inPip;
  }

  @override
  Future<bool> enter() async {
    enters += 1;
    if (acceptEnter) inPip = true;
    return acceptEnter;
  }

  @override
  Future<bool> setParams({required bool video, String title = ''}) async {
    final failure = error;
    if (failure != null) throw failure;
    settings.add('video=$video title=$title');
    return available;
  }

  @override
  Future<bool> exit() async {
    exits += 1;
    inPip = false;
    return available;
  }

  /// 原生上报「进了 / 出了小窗」（1:1 与群通话可能同时听着，逐个通知）
  void emitMode(bool value) {
    inPip = value;
    for (final listener in _modeListeners.toList(growable: false)) {
      listener(value);
    }
  }

  /// 最后一次设置（没设置过就是 null）
  String? get last => settings.isEmpty ? null : settings.last;
}
