import 'dart:async';

import 'package:flutter/foundation.dart';

/// 「这扇窗现在还在不在、可见吗、有没有被最小化」——Windows 上由 Win32 回答
/// （`IsWindow` + `IsIconic` + `IsWindowVisible`，见 `window_state_probe_io.dart`）。
///
/// 抽成回调是为了**能单测**：假探针给一串状态，就能把「最小化 → 还原 → 重建」
/// 这条时序钉住，不用真窗口、也不用真时钟。
typedef WindowVisibleProbe = bool Function(int hwnd);

/// 桌面源 id → 窗口句柄。
///
/// Windows 上 `desktopCapturer.getSources()` 给**窗口**那类的 id 就是十进制 HWND
/// （规划书 S12.38 实测：屏幕那块是 `"0"`，窗口那块是 `"459138"`）。
///
/// 返回 null 的两种情形都不需要盯：
/// * **整块屏幕**（`"0"`）—— 屏幕一直在变，没有「最小化」这回事；
/// * 不是窗口句柄（安卓上 sourceId 恒为 null；web 上也没有这条）。
int? windowHandleOf(String? sourceId) {
  final text = (sourceId ?? '').trim();
  if (text.isEmpty || text == '0') return null;
  final value = int.tryParse(text);
  if (value == null || value <= 0) return null;
  return value;
}

/// 盯着「我共享的那扇窗」，它被最小化 / 藏起来之后再回来时叫一声 [onRestored]。
///
/// 为什么需要它（2026-10-08 用户报的）：「共享一个应用程序，把这个程序最小化了再
/// 点开，对方看到的画面一直卡在最小化前最后一秒，声音却是正常的」。
///
/// 根因在**采集器**那一层，我们改不了（在插件预编译的 `libwebrtc.dll` 里，而且
/// 那颗库没开 WGC，见 S12.36）：窗口被最小化之后 DWM 不再为它合成新表面，
/// GDI 那条 `PrintWindow` 拿回来的就是最后一帧；窗口回来之后，同一个 capturer
/// 手里的表面**已经不更新了**，于是对方就永久停在那张图上。
///
/// 能改的是**我们这一侧的动作**：窗口回来之后**重建一次采集**（新的
/// `getDisplayMedia` → 新的 track → `replaceTrack` 换到同一个 mid 上，
/// 不重新协商、协议与服务端一行都不用动）—— 这是这个类唯一负责的事。
///
/// 三条边界（都有用例钉着）：
///
/// * **最小化期间什么都不做**：那时候「画面不动」是正常的（对方看最后一帧是期望行为），
///   重建只会白折腾，还可能把正在共享的声音一起断掉；
/// * **回来之后要先等一个宽限期**（[grace]）：窗口刚还原时还没画出来，
///   立刻重建会把「一片空白」采进去；
/// * **重建要防抖**（[cooldown]）：用户来回最小化时不要每次都连着重下去。
class SharedWindowWatch {
  SharedWindowWatch({
    required this.visible,
    required this.onRestored,
    this.pollInterval = const Duration(seconds: 1),
    this.grace = const Duration(milliseconds: 1500),
    this.cooldown = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 这扇窗现在可见吗（false = 最小化 / 被藏起来 / 已经不存在）
  final WindowVisibleProbe visible;

  /// 窗口从「离开」回到「可见」且过了宽限期时调一次（同步回调，别在里面 await 太久）
  final VoidCallback onRestored;

  /// 多久问一次窗口状态
  final Duration pollInterval;

  /// 回到可见之后等多久再重建（等窗口先画出来）
  final Duration grace;

  /// 两次重建之间的最小间隔
  final Duration cooldown;

  final DateTime Function() _now;

  Timer? _timer;
  int? _hwnd;
  bool _away = false;
  DateTime? _backSince;
  DateTime? _lastRecovery;

  /// 已经因为这个看门狗重建过几次（诊断与用例用）
  int recoveries = 0;

  /// 在盯着吗
  bool get watching => _timer != null;

  /// 开始盯这扇窗（重复调用会先停掉上一次）
  void start(int hwnd) {
    stop();
    _hwnd = hwnd;
    _timer = Timer.periodic(pollInterval, (_) => tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _hwnd = null;
    _away = false;
    _backSince = null;
  }

  /// 巡查一次。
  ///
  /// **单测直接调它**：不用起真 timer，也不用等真时钟（[now] 注入一个假时钟即可）。
  void tick() {
    final hwnd = _hwnd;
    if (hwnd == null) return;
    if (!visible(hwnd)) {
      // 最小化 / 隐藏：记一笔就走（这段期间画面停在最后一帧是正常的）
      _away = true;
      _backSince = null;
      return;
    }
    if (!_away) return; // 一直在可见：不打扰
    final at = _now();
    _backSince ??= at;
    if (at.difference(_backSince!) < grace) return; // 刚回来，让它先画出来
    _away = false;
    _backSince = null;
    final last = _lastRecovery;
    if (last != null && at.difference(last) < cooldown) return; // 刚重建过
    _lastRecovery = at;
    recoveries += 1;
    onRestored();
  }
}
