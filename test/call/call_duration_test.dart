import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/call/call_duration.dart';

/// 通话时长文案（老端 `index.html::setCallTime` 逐字照抄）。
void main() {
  test('不足一分钟也带小时位（老端就是 HH:MM:SS）', () {
    expect(formatCallDuration(0), '00:00:00');
    expect(formatCallDuration(7), '00:00:07');
    expect(formatCallDuration(35), '00:00:35');
    expect(formatCallDuration(60), '00:01:00');
    expect(formatCallDuration(600), '00:10:00');
  });

  test('分、秒都补零', () {
    expect(formatCallDuration(61), '00:01:01');
    expect(formatCallDuration(3599), '00:59:59');
  });

  test('超过一小时照样算（老端也是取整算小时）', () {
    expect(formatCallDuration(3600), '01:00:00');
    expect(formatCallDuration(3725), '01:02:05');
    expect(formatCallDuration(36000), '10:00:00');
  });

  test('负数当成 0（计时器理论上不会给，但别输出 -1:-1:-1）', () {
    expect(formatCallDuration(-5), '00:00:00');
  });

  group('聊天里那条记录的时长（与服务端 `date("i:s")` 同一个口径）', () {
    test('分钟:秒，不足一分钟也带分钟位', () {
      expect(formatCallRecordDuration(0), '00:00');
      expect(formatCallRecordDuration(7), '00:07');
      expect(formatCallRecordDuration(35), '00:35');
      expect(formatCallRecordDuration(45), '00:45');
      expect(formatCallRecordDuration(61), '01:01');
      expect(formatCallRecordDuration(765), '12:45');
    });

    test('超过一小时分钟数继续涨（不绕回 0，也不凭空多一个秒字段）', () {
      expect(formatCallRecordDuration(3600), '60:00');
      expect(formatCallRecordDuration(3725), '62:05');
    });

    test('负数当成 0', () {
      expect(formatCallRecordDuration(-5), '00:00');
    });
  });
}
