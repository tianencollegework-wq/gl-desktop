import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/group_call/sfu_speaker.dart';

/// 「谁在说话」的判定（阈值 + 保持）。
///
/// 它决定界面上那个名字/头像亮着的是谁，规则错了的观感问题很直接：
/// 阈值太松 → 底噪就让人名乱跳；没有保持 → 说话人换气时界面闪回头像墙。
void main() {
  final t0 = DateTime(2026, 9, 26, 12);

  test('低于阈值的能量不算说话', () {
    final tracker = SfuSpeakerTracker(threshold: 0.02);
    expect(tracker.update(<String, double>{'a': 0.01}, t0), isNull);
  });

  test('超过阈值就认他，取最响的那个', () {
    final tracker = SfuSpeakerTracker(threshold: 0.02);
    expect(
      tracker.update(<String, double>{'a': 0.03, 'b': 0.31, 'c': 0.05}, t0),
      'b',
    );
  });

  test('保持期内换气不闪：沉默一会儿仍然算他', () {
    final tracker = SfuSpeakerTracker(
      threshold: 0.02,
      hold: const Duration(seconds: 1),
    );
    tracker.update(<String, double>{'a': 0.4}, t0);
    expect(
      tracker.update(
        const <String, double>{},
        t0.add(const Duration(milliseconds: 400)),
      ),
      'a',
    );
    expect(
      tracker.update(
        const <String, double>{},
        t0.add(const Duration(milliseconds: 900)),
      ),
      'a',
    );
  });

  test('超过保持期就没人说话了', () {
    final tracker = SfuSpeakerTracker(
      threshold: 0.02,
      hold: const Duration(seconds: 1),
    );
    tracker.update(<String, double>{'a': 0.4}, t0);
    expect(
      tracker.update(
        const <String, double>{},
        t0.add(const Duration(seconds: 2)),
      ),
      isNull,
    );
    expect(tracker.active, isNull);
  });

  test('别人开口立刻换人（不等保持期）', () {
    final tracker = SfuSpeakerTracker(
      threshold: 0.02,
      hold: const Duration(seconds: 2),
    );
    tracker.update(<String, double>{'a': 0.4}, t0);
    expect(
      tracker.update(<String, double>{
        'b': 0.5,
      }, t0.add(const Duration(milliseconds: 100))),
      'b',
    );
  });

  test('NaN / 无穷不会把判定弄坏（插件偶尔给怪值）', () {
    final tracker = SfuSpeakerTracker(threshold: 0.02);
    expect(
      tracker.update(<String, double>{
        'a': double.nan,
        'b': double.infinity,
      }, t0),
      isNull,
    );
    expect(tracker.update(<String, double>{'a': 0.5}, t0), 'a');
  });

  test('reset 之后谁都不算说话（离开房间/重建会话用）', () {
    final tracker = SfuSpeakerTracker();
    tracker.update(<String, double>{'a': 0.5}, t0);
    tracker.reset();
    expect(tracker.active, isNull);
  });
}
