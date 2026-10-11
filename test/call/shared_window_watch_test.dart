import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/media/shared_window_watch.dart';
import 'package:gracelinkim/data/media/window_state_probe.dart';

/// 「共享的窗口最小化又回来」那个看门狗的时序用例（2026-10-08 用户报的 bug）。
///
/// 真机那一档的症状是：**共享某个窗口 → 最小化 → 再点开，对方画面永远停在
/// 最小化前最后一秒（声音一直正常）**。采集器本体改不了（插件预编译
/// libwebrtc 里的 `WindowCapturerWin`，没开 WGC），能做的是窗口回来之后
/// **重建一次采集** —— 这个类决定「什么时候重建」。
///
/// 不用真 timer、也不用真时钟：`tick()` 是公开的（单测直接调），`now` 注入假时钟，
/// 所以这几条时序是**确定**的，不会因为机器慢而闪。
void main() {
  group('桌面探针（本机真装一次 Win32）', () {
    test('Windows 上装得上；无效句柄说 false；非 Windows 不装', () {
      final probe = desktopWindowProbe();
      if (!Platform.isWindows) {
        expect(probe, isNull, reason: '安卓/iOS/macOS/Linux/web 都没有这条探针');
        return;
      }
      expect(probe, isNotNull, reason: '装不上就该 gracefully 退成 null（不盯）');
      // 0 与一个不可能存在的句柄：`IsWindow` 为假 → 不盯
      expect(probe!(0), isFalse);
      expect(probe(0x7FFFFFFF), isFalse);
    });
  });

  group('windowHandleOf：哪些共享源才需要盯', () {
    test('窗口源（十进制 HWND）→ 那个句柄', () {
      expect(windowHandleOf('459138'), 459138);
    });

    test('整块屏幕 / 空 / 非数字 → 不盯', () {
      expect(windowHandleOf('0'), isNull, reason: '整块屏幕没有「最小化」这回事');
      expect(windowHandleOf(null), isNull, reason: '安卓上 sourceId 就是 null');
      expect(windowHandleOf(''), isNull);
      expect(windowHandleOf('screen:0:0'), isNull);
      expect(windowHandleOf('-1'), isNull);
      expect(windowHandleOf(' 12345 '), 12345, reason: '两头的空白不该把 id 弄丢');
    });
  });

  group('SharedWindowWatch：最小化 → 还原的时序', () {
    late bool windowVisible;
    late int restored;
    late DateTime clock;
    late SharedWindowWatch watch;

    setUp(() {
      windowVisible = true;
      restored = 0;
      clock = DateTime(2026, 10, 8, 12);
      watch = SharedWindowWatch(
        visible: (_) => windowVisible,
        onRestored: () => restored += 1,
        // 用例自己调 tick()：周期给得很大，免得定时器自己跳进来
        pollInterval: const Duration(minutes: 5),
        grace: const Duration(milliseconds: 1500),
        cooldown: const Duration(seconds: 3),
        now: () => clock,
      );
      watch.start(0x1234);
      addTearDown(watch.stop);
    });

    void advance(Duration by) => clock = clock.add(by);

    void minimize() {
      windowVisible = false;
      watch.tick();
    }

    void restore() => windowVisible = true;

    test('一直可见：一次都不动', () {
      for (var i = 0; i < 5; i++) {
        watch.tick();
        advance(const Duration(seconds: 1));
      }
      expect(restored, 0);
      expect(watch.recoveries, 0);
    });

    test('最小化期间不动它：那会儿停在最后一帧是正常的，重建只会白折腾', () {
      windowVisible = false;
      for (var i = 0; i < 10; i++) {
        watch.tick();
        advance(const Duration(seconds: 1));
      }
      expect(restored, 0);
      expect(watch.recoveries, 0);
    });

    test('还原后要等宽限期：窗口先画出来，再重建', () {
      minimize();
      advance(const Duration(seconds: 2));
      windowVisible = true;
      watch.tick(); // 回来后的第一眼
      advance(const Duration(milliseconds: 800));
      watch.tick();
      expect(restored, 0, reason: '还没到 1.5 秒宽限：这时候重建会采到一片空白');
      advance(const Duration(milliseconds: 800)); // 累计 1.6 秒
      watch.tick();
      expect(restored, 1);
      expect(watch.recoveries, 1);
    });

    test('刚重建过又来回最小化：冷却期内不重建（防抖）', () {
      minimize();
      advance(const Duration(seconds: 1));
      restore();
      watch.tick();
      advance(const Duration(milliseconds: 1600));
      watch.tick();
      expect(restored, 1);

      // 紧接着又最小化再还原：离上一次重建还不到 3 秒
      minimize();
      advance(const Duration(seconds: 1));
      restore();
      watch.tick();
      advance(const Duration(milliseconds: 1600));
      watch.tick();
      expect(restored, 1, reason: '冷却期内不重复重建');
    });

    test('冷却期过了，下一次最小化还原照常重建', () {
      minimize();
      advance(const Duration(seconds: 1));
      restore();
      watch.tick();
      advance(const Duration(milliseconds: 1600));
      watch.tick();
      expect(restored, 1);

      advance(const Duration(seconds: 5)); // 离上一次重建超过 3 秒了
      minimize();
      advance(const Duration(seconds: 1));
      restore();
      watch.tick();
      advance(const Duration(milliseconds: 1600));
      watch.tick();
      expect(restored, 2);
      expect(watch.recoveries, 2);
    });

    test('窗口藏进托盘（IsWindowVisible 假）也算「离开」：一样会重建', () {
      // 有些程序「最小化」走的是 ShowWindow(SW_HIDE)：这时 IsIconic 是假，
      // 判据是可见性那一条（见 window_state_probe_io.dart）。
      minimize();
      advance(const Duration(seconds: 4));
      restore();
      watch.tick();
      advance(const Duration(milliseconds: 1600));
      watch.tick();
      expect(restored, 1);
    });

    test('stop() 之后什么都不做（停共享 / 挂断以后不该再重建）', () {
      watch.stop();
      expect(watch.watching, isFalse);
      minimize();
      watch.tick();
      advance(const Duration(seconds: 2));
      restore();
      watch.tick();
      advance(const Duration(seconds: 2));
      watch.tick();
      expect(restored, 0);
    });
  });
}
