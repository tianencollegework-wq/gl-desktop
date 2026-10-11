import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/group_call/sfu_trace.dart';

/// 群通话的时间线与计数（诊断面板的数据源）。
///
/// 这里钉住的是**面板上看到的东西准不准**：偏移时间、失败标红、只留最近若干条、
/// 计数口径。它错了的后果很直接 —— 排查时会盯着一份假数据找原因。
void main() {
  test('每条带相对进房间那一刻的偏移', () {
    final ticker = _FakeClock();
    final trace = SfuTrace(now: ticker.now);

    trace.record('进房间');
    ticker.advance(const Duration(milliseconds: 1500));
    trace.record('发布 1 条');

    expect(trace.entries.map((entry) => entry.label), <String>[
      '+0.0s',
      '+1.5s',
    ]);
    expect(trace.entries.first.text, '进房间');
  });

  test('失败条目计数 + 导出时带标记', () {
    final trace = SfuTrace();

    trace.record('订阅 u2/mic → mid-mic');
    trace.record('订阅 u3/mic 没成：4002', failure: true);

    expect(trace.failures, 1);
    expect(trace.entries.last.failure, isTrue);
    expect(trace.entries.last.toString(), contains('失败'));
    expect(trace.entries.first.toString(), isNot(contains('失败')));
  });

  test('只留最近若干条（老的最先扔：出问题时最近那几十条才有用）', () {
    final trace = SfuTrace(limit: 3);
    for (var i = 1; i <= 5; i++) {
      trace.record('第 $i 条');
    }

    expect(trace.entries.map((entry) => entry.text), <String>[
      '第 3 条',
      '第 4 条',
      '第 5 条',
    ]);
  });

  test('计数那一行的口径（面板与导出都用它）', () {
    final trace = SfuTrace()
      ..publishes = 2
      ..subscribes = 3
      ..renegotiates = 3
      ..closes = 1
      ..rebuilds = 1
      ..heartbeats = 4
      ..heartbeatFailures = 1;
    trace.record('订阅失败', failure: true);

    expect(
      trace.counters,
      '发布 2 · 订阅 3 · 重协商 3 · 关闭 1 · 重建 1 · 失败 1 · '
      '心跳 4（失败 1）',
    );
  });

  test('reset 把时间线与计数一起清掉（第二次进房间从头记）', () {
    final trace = SfuTrace()
      ..publishes = 1
      ..failures = 0;
    trace.record('进房间');
    trace.record('失败一条', failure: true);

    trace.reset();

    expect(trace.entries, isEmpty);
    expect(trace.publishes, 0);
    expect(trace.failures, 0);
  });

  test('面板盯着它：record 会通知一次（不然开着面板看不到新条目）', () {
    final trace = SfuTrace();
    var notified = 0;
    trace.addListener(() => notified += 1);

    trace.record('进房间');
    trace.reset();

    expect(notified, 2);
  });
}

/// 手动推的时钟（时间线要看偏移，不能靠真时间）
class _FakeClock {
  DateTime _value = DateTime(2026, 9, 26, 20);

  DateTime now() => _value;

  void advance(Duration duration) => _value = _value.add(duration);
}
