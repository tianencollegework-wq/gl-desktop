import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/group_call/sfu_stream_watch.dart';

/// 「我订阅的那一路视频还在不在收」的判定用例（2026-10-08 用户报的那个 bug：
/// 电脑在共享屏幕、然后直接挂断群通话，手机端永远停在最后一帧）。
///
/// 时钟是注入的：这几条时序是确定的，不会因为机器慢而闪。
void main() {
  group('SfuStreamWatch：计数不涨 = 那一路已经没了', () {
    late DateTime clock;
    late SfuStreamWatch watch;

    setUp(() {
      clock = DateTime(2026, 10, 8, 20);
      watch = SfuStreamWatch(
        timeout: const Duration(seconds: 8),
        now: () => clock,
      );
    });

    void advance(Duration by) => clock = clock.add(by);

    test('计数一直在涨：一路都不判死（画面在动就是活着）', () {
      for (var i = 0; i < 20; i++) {
        expect(watch.tick(<String, int>{'m1': i}, clock), isEmpty);
        advance(const Duration(seconds: 2));
      }
    });

    test('第一次见到就记下来：不能当场判死', () {
      expect(watch.tick(<String, int>{'m1': 100}, clock), isEmpty);
      advance(const Duration(seconds: 5)); // 还不到 8 秒
      expect(watch.tick(<String, int>{'m1': 100}, clock), isEmpty);
    });

    test('连续超过 timeout 一个计数都没动：只把那一路判死', () {
      watch.tick(<String, int>{'m1': 10, 'm2': 10}, clock);
      advance(const Duration(seconds: 9));

      expect(
        watch.tick(<String, int>{'m1': 20, 'm2': 10}, clock),
        <String>['m2'],
        reason: 'm1 还在涨（画面在动），m2 一动不动才是死了',
      );
    });

    test('统计里整个消失的 mid：超过 timeout 也算死了', () {
      watch.tick(<String, int>{'m1': 10}, clock);
      advance(const Duration(seconds: 9));

      expect(
        watch.tick(const <String, int>{}, clock),
        <String>['m1'],
        reason: '连那一路的读数都没了，比「不涨」还确定',
      );
    });

    test('keep / forget：退订的那一路不再算', () {
      watch.tick(<String, int>{'m1': 10, 'm2': 10}, clock);
      watch.keep(<String>['m1']); // m2 退订了
      advance(const Duration(seconds: 9));
      expect(watch.tick(<String, int>{'m1': 20}, clock), isEmpty);

      expect(watch.watching, isTrue);
      watch.forget('m1');
      expect(watch.watching, isFalse, reason: '盯空了就该把这条检查关掉');
    });
  });
}
