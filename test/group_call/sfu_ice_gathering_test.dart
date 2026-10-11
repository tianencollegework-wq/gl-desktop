import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/group_call/sfu_ice_gathering.dart';

void main() {
  group('IceGatherBarrier（发 SDP 前等候选收齐）', () {
    test('已经收齐了就直接返回，不会白等一个超时', () async {
      final barrier = IceGatherBarrier(
        timeout: const Duration(seconds: 30),
        alreadyComplete: () => true,
      );

      final stopwatch = Stopwatch()..start();
      expect(await barrier.wait(), isTrue);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 200)),
        reason: 'gathering 回调有可能比 wait() 先到',
      );
    });

    test('gathering 结束信号到了立刻放行（远早于超时）', () async {
      final barrier = IceGatherBarrier(timeout: const Duration(seconds: 30));

      final waiting = barrier.wait();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      barrier.complete();

      expect(await waiting, isTrue);
    });

    test('**超时照样放行**：一次等不到的 gathering 不能把会话队列卡死', () async {
      final barrier = IceGatherBarrier(
        timeout: const Duration(milliseconds: 40),
      );

      final stopwatch = Stopwatch()..start();
      expect(await barrier.wait(), isFalse, reason: 'false = 超时放行（少几条候选）');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('超时之后才到的信号不会再影响下一次等待', () async {
      final barrier = IceGatherBarrier(
        timeout: const Duration(milliseconds: 20),
      );
      expect(await barrier.wait(), isFalse);

      // 晚到的 complete() 是上一次的，不能把下一次直接放行
      barrier.complete();
      final stopwatch = Stopwatch()..start();
      expect(await barrier.wait(), isFalse);
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 15)),
      );
    });

    test('可以反复用（每条会话上要发很多次 SDP）', () async {
      final barrier = IceGatherBarrier(
        timeout: const Duration(milliseconds: 10),
      );

      for (var i = 0; i < 3; i++) {
        final waiting = barrier.wait();
        barrier.complete();
        expect(await waiting, isTrue, reason: '第 ${i + 1} 次');
      }
    });
  });
}
