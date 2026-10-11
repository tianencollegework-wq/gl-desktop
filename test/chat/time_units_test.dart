import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/time_units.dart';

void main() {
  group('toMillis：服务端给秒或毫秒都能正确归一到毫秒', () {
    test('秒级时间戳 ×1000（老端 WS 推送那份就是秒）', () {
      // 2025-09-18 附近：1758163200 秒
      expect(toMillis(1758163200), 1758163200000);
      expect(toMillis('1758163200'), 1758163200000);
    });

    test('毫秒级时间戳原样返回（本地乐观消息与 REST 列表那份）', () {
      expect(toMillis(1758163200000), 1758163200000);
    });

    test('阈值与老端 date() 完全一致：9e10 是分界线', () {
      // 刚小于阈值 → 当秒
      expect(toMillis(89999999999), 89999999999000);
      // 刚好等于阈值 → 当毫秒（老端是 `< 90000000000` 才乘）
      expect(toMillis(90000000000), 90000000000);
    });

    test('空值 / 非法值 → 0（代表"没有时间"，排序时会排到最后）', () {
      expect(toMillis(null), 0);
      expect(toMillis(''), 0);
      expect(toMillis('abc'), 0);
      expect(toMillis(0), 0);
      expect(toMillis(-1), 0);
      expect(toMillis(<String, dynamic>{}), 0);
    });

    test('double 也接受（服务端 JSON 里出现过浮点）', () {
      expect(toMillis(1758163200.0), 1758163200000);
    });
  });

  test('nowMillis 是毫秒量级（不是秒）', () {
    final now = nowMillis();
    expect(now, greaterThan(90000000000));
    expect(DateTime.fromMillisecondsSinceEpoch(now).year, greaterThan(2020));
  });
}
