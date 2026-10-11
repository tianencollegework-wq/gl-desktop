import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/util/time_format.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 会话列表右上角那行时间。
///
/// 其余分支仍按老端 `utils.js` 的口径（昨天 / 周X / m-d / Y-m-d），
/// 今天这一档 S8.x 起改成了**微信写法**：`上午9:33` / `下午5:47`。
void main() {
  // 语言包要从 asset bundle 读，先起绑定
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppI18n zh;
  late AppI18n en;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    zh = await AppI18n.load('zh-Hans');
    en = await AppI18n.load('en');
  });

  int at(DateTime time) => time.millisecondsSinceEpoch;

  group('今天：上午/下午 + 12 小时制（微信）', () {
    // 挑一个周三当“现在”，避开老端那个“周日会把本周算到明天”的怪癖
    final now = DateTime(2026, 9, 16, 18, 30);

    test('中文：上午 / 下午在时间前面', () {
      expect(
        timeFormat(at(DateTime(2026, 9, 16, 9, 33)), translate: zh.t, now: now),
        '上午9:33',
      );
      expect(
        timeFormat(
          at(DateTime(2026, 9, 16, 17, 47)),
          translate: zh.t,
          now: now,
        ),
        '下午5:47',
      );
    });

    test('12 点算下午、0 点算上午（12 小时制的惯例）', () {
      expect(
        timeFormat(
          at(DateTime(2026, 9, 16, 12, 30)),
          translate: zh.t,
          now: now,
        ),
        '下午12:30',
      );
      expect(
        timeFormat(at(DateTime(2026, 9, 16, 0, 5)), translate: zh.t, now: now),
        '上午12:05',
      );
    });

    test('英文：AM / PM 在时间后面', () {
      expect(
        timeFormat(
          at(DateTime(2026, 9, 16, 17, 47)),
          translate: en.t,
          now: now,
        ),
        '5:47 PM',
      );
      expect(
        timeFormat(at(DateTime(2026, 9, 16, 9, 3)), translate: en.t, now: now),
        '9:03 AM',
      );
    });
  });

  group('其余分支保持老端口径', () {
    final now = DateTime(2026, 9, 16, 18, 30);

    test('昨天 → 「昨天」', () {
      expect(
        timeFormat(at(DateTime(2026, 9, 15, 20, 0)), translate: zh.t, now: now),
        '昨天',
      );
    });

    test('本周内 → 周X', () {
      // 9-16 是周三，9-14 是周一
      expect(
        timeFormat(at(DateTime(2026, 9, 14, 10, 0)), translate: zh.t, now: now),
        '周一',
      );
    });

    test('更早（今年内）→ m-d（老端是补零的）', () {
      expect(
        timeFormat(at(DateTime(2026, 8, 3, 10, 0)), translate: zh.t, now: now),
        '08-03',
      );
    });

    test('时间无效 → 空字符串（不要显示 1970）', () {
      expect(timeFormat(0, translate: zh.t, now: now), '');
    });
  });
}
