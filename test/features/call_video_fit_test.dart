import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoViewObjectFit;
import 'package:gracelinkim/features/call/widgets/call_video_fit.dart';

/// 「这块区域放这一路画面该铺满还是完整放」（S12.33，`call_video_fit.dart`）。
///
/// 用户报的那件事：「电脑共享屏幕，手机端看到的好像是不完整的」。根因是放法按
/// `cover`（铺满）算 —— 3072×1920 的屏放进手机那块竖长条，只留中间三成宽。
/// 这里把真机那几个尺寸钉住：屏幕、竖屏手机、横过来拿的手机、自己那块小窗。
void main() {
  /// 这台机器真窗与屏幕的那几个尺寸（都是逻辑像素）
  const screen3072 = Size(3072, 1920); // 电脑整屏（16:10）
  const phoneBox = Size(390, 700); // 手机通话页那块大画面（9:19.5）
  const portrait1080 = Size(1080, 1920); // 竖着拿的手机摄像头
  const landscape1080 = Size(1920, 1080); // 横过来拿的手机摄像头

  group('铺满会裁掉多少', () {
    test('电脑屏幕放进手机那块竖长条：只看得见三成半（用户报的就是这个）', () {
      final visible = coverVisibleFraction(screen3072, phoneBox);
      expect(visible, closeTo(0.348, 0.01));
      expect(coverCropsTooMuch(screen3072, phoneBox), isTrue);
    });

    test('竖屏摄像头放进竖屏区域：几乎不裁（铺满是对的）', () {
      expect(
        coverVisibleFraction(portrait1080, phoneBox),
        closeTo(0.986, 0.01),
      );
      expect(coverCropsTooMuch(portrait1080, phoneBox), isFalse);
    });

    test('横过来拿的手机：只剩中间三成一，一样该完整放', () {
      expect(
        coverVisibleFraction(landscape1080, phoneBox),
        closeTo(0.317, 0.01),
      );
      expect(coverCropsTooMuch(landscape1080, phoneBox), isTrue);
    });

    test('桌面右上角那块自己小窗（192×144）放横屏摄像头：只裁两成半，仍然铺满', () {
      expect(
        coverVisibleFraction(landscape1080, const Size(192, 144)),
        closeTo(0.75, 0.01),
      );
      expect(coverCropsTooMuch(landscape1080, const Size(192, 144)), isFalse);
    });

    test('尺寸还不知道（0 或者没量出来）时算「没裁」：调用方按原来的口径走', () {
      expect(coverVisibleFraction(Size.zero, phoneBox), 1);
      expect(coverVisibleFraction(screen3072, Size.zero), 1);
      expect(coverVisibleFraction(Size.zero, Size.zero), 1);
    });
  });

  group('最终挑哪一档', () {
    test('还不知道画面多大：先按铺满（摄像头那一套默认），等第一帧再说', () {
      expect(
        fitFor(null, phoneBox),
        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );
      expect(
        fitFor(Size.zero, phoneBox),
        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );
    });

    test('电脑屏幕 → 完整放；竖屏摄像头 → 铺满', () {
      expect(
        fitFor(screen3072, phoneBox),
        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
      expect(
        fitFor(portrait1080, phoneBox),
        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );
    });

    test('用户自己挑过（长按 / 双击）就不再自动：挑什么是什么', () {
      for (final frame in <Size?>[null, screen3072, portrait1080]) {
        expect(
          fitFor(frame, phoneBox, fill: true),
          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        );
        expect(
          fitFor(frame, phoneBox, fill: false),
          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
        );
      }
    });

    test('门槛可调：宽松一点（0.5）时横屏手机又回到铺满', () {
      expect(
        fitFor(landscape1080, phoneBox, severeCrop: 0.5),
        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
        reason: '横屏手机裁掉 68%，仍然超过一半的门槛',
      );
      expect(
        fitFor(const Size(1280, 720), const Size(390, 700), severeCrop: 0.75),
        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        reason: '16:9 放进竖长条裁 66.6% < 75% → 这档门槛下算「还行」',
      );
    });
  });
}
