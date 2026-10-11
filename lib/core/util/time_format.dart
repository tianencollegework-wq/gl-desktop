/// 时间格式化，对应老端 `utils/utils.js` 的 `date` / `timeFormat` / `hoursTimeFormat`。
///
/// 全部照原样搬，**包括老端的一个 bug**：算"本周"时用的是 JS 的
/// `today.getDay()`（周日 = 0），于是 `weekStart = today - (getDay - 1)` 在周日会变成
/// "明天"，导致周日那天所有消息都退化成显示 `m-d`（比如 `9-21`）。
/// 新端保持同样行为（`timeFormatQuirkOnSunday` 测试固定住了），
/// 因为"显示结果与老端一致"是这一期的硬要求。
library;

/// 取词函数，与 [AppI18n.t] 同形（第二个参数是可选的占位符表）。
///
/// 这里不直接依赖 i18n 单例，纯函数模块只认这个签名，好测。
typedef Translate = String Function(String key, [Map<String, String>? params]);

const List<String> _weekdayKeys = <String>[
  'time.sun',
  'time.mon',
  'time.tue',
  'time.wed',
  'time.thu',
  'time.fri',
  'time.sat',
];

/// 会话列表右上角的时间：今天 `H:i`、昨天「昨天」、本周内显示周几、
/// 今年内 `m-d`、更早 `Y-m-d`
String timeFormat(int millis, {required Translate translate, DateTime? now}) {
  if (millis <= 0) return '';
  final dateTime = DateTime.fromMillisecondsSinceEpoch(millis);
  final nowDate = now ?? DateTime.now();
  final today = DateTime(nowDate.year, nowDate.month, nowDate.day);
  final yesterday = today.subtract(const Duration(days: 1));
  // JS: getDay() = 周日 0 … 周六 6；这里用同样的口径（Dart 的 weekday 是周一 1 … 周日 7）
  final jsWeekday = dateTime.weekday % 7;
  final todayJsWeekday = today.weekday % 7;
  final weekStart = today.subtract(Duration(days: todayJsWeekday - 1));
  final yearStart = DateTime(nowDate.year);

  if (!dateTime.isBefore(today)) {
    // 今天：微信写「上午9:33 / 下午5:47」（12 小时制），老端是 24 小时的 `H:i`
    return _wechatClock(dateTime, translate);
  }
  if (!dateTime.isBefore(yesterday) && dateTime.isBefore(today)) {
    return translate('time.yesterday');
  }
  if (!dateTime.isBefore(weekStart) && dateTime.isBefore(yesterday)) {
    return translate(_weekdayKeys[jsWeekday]);
  }
  if (!dateTime.isBefore(yearStart) && dateTime.isBefore(weekStart)) {
    return _format(dateTime, 'm-d');
  }
  return _format(dateTime, 'Y-m-d');
}

/// 今天的时刻：微信写法 `上午9:33` / `下午5:47`。
///
/// 中英文的语序不同（`上午9:33` vs `9:33 AM`），所以格式串放在语言包
/// 里的 `time.today`，这里只管拼参数。
///
/// `{H}` 是补的 24 小时制（德语/法语/西语用 `{H}:{mm}`，不把
/// `5:47` 这种 12 小时值当 24 小时显示）。
String _wechatClock(DateTime time, Translate translate) {
  final hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
  return translate('time.today', <String, String>{
    'ap': translate(time.hour < 12 ? 'time.am' : 'time.pm'),
    'h': '$hour12',
    'H': _pad(time.hour),
    'mm': _pad(time.minute),
  });
}

/// 聊天消息上方那条时间分隔（微信写法）：
///
/// * 今天：`上午6:17`
/// * 今年更早：`8月16日 上午6:17`
/// * 跨年：`2025年8月16日 上午6:17`
///
/// 老端这里是 24 小时的 `09-19 10:59`；换成微信的 12 小时制 + 中文日期后
/// 和消息里那行时间同一套语感。语序中英不同，格式串仍放在语言包里。
String hoursTimeFormat(
  int millis, {
  required Translate translate,
  DateTime? now,
}) {
  if (millis <= 0) return '';
  final dateTime = DateTime.fromMillisecondsSinceEpoch(millis);
  final nowDate = now ?? DateTime.now();
  final hour12 = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
  final params = <String, String>{
    'ap': translate(dateTime.hour < 12 ? 'time.am' : 'time.pm'),
    'h': '$hour12',
    'H': _pad(dateTime.hour),
    'mm': _pad(dateTime.minute),
    'y': '${dateTime.year}',
    'm': _pad(dateTime.month),
    'd': _pad(dateTime.day),
  };
  if (dateTime.year != nowDate.year) {
    return translate('time.chatYear', params);
  }
  if (dateTime.month == nowDate.month && dateTime.day == nowDate.day) {
    return translate('time.chatToday', params);
  }
  return translate('time.chatDay', params);
}

/// 老端 `utils.js::date(format, timestamp)` 的等价物。
///
/// 支持的格式串：`Y-m-d H:i:s` / `Y-m-d H:i` / `Y-m-d` / `m-d H:i` / `m-d` / `H:i`。
/// 传入的 [millis] 已是毫秒（老端调用处传的是秒，靠它自身那段
/// "小于 9e10 就 ×1000" 的魔法兜住；新端统一在入口归一化，见 `time_units.dart`）。
String dateFormat(String format, int millis) {
  if (millis <= 0) return '';
  return _format(DateTime.fromMillisecondsSinceEpoch(millis), format);
}

String _format(DateTime time, String format) {
  final year = time.year.toString();
  final month = _pad(time.month);
  final day = _pad(time.day);
  final hour = _pad(time.hour);
  final minute = _pad(time.minute);
  final second = _pad(time.second);

  return format
      .replaceAll('Y', year)
      .replaceAll('m', month)
      .replaceAll('d', day)
      .replaceAll('H', hour)
      .replaceAll('i', minute)
      .replaceAll('s', second);
}

/// 公众号式信息流里那种相对时间：`刚刚` / `3分钟前` / `14小时前` / `昨天` /
/// `2天前` / `9-21` / `2025-8-16`。
///
/// 与 [timeFormat] 的分工：那个是**会话列表**用的（今天显示时刻、本周内显示周几），
/// 这个是媒体号卡片右上角用的（用户 2026-09-30 给的图里就是「14小时前」「昨天」）。
///
/// 两处细节：
/// * 超过 24 小时但**没跨到昨天**（比如现在凌晨 1 点、文章是前天晚上 23 点）按天数走，
///   不会出现「26小时前」这种读着费劲的说法；
/// * 未来时间（设备时钟不准）一律当「刚刚」，不显示负数。
String feedTime(int millis, {required Translate translate, DateTime? now}) {
  if (millis <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final nowDate = now ?? DateTime.now();
  final diff = nowDate.difference(time);
  if (diff.inMinutes < 1) return translate('time.justNow');
  if (diff.inMinutes < 60) {
    return translate('time.minAgo', <String, String>{
      'min': '${diff.inMinutes}',
    });
  }
  if (diff.inHours < 24) {
    return translate('time.hourAgo', <String, String>{
      'hour': '${diff.inHours}',
    });
  }
  final today = DateTime(nowDate.year, nowDate.month, nowDate.day);
  final day = DateTime(time.year, time.month, time.day);
  final days = today.difference(day).inDays;
  if (days <= 1) return translate('time.yesterday');
  if (days < 7) {
    return translate('time.dayAgo', <String, String>{'day': '$days'});
  }
  return time.year == nowDate.year
      ? _format(time, 'm-d')
      : _format(time, 'Y-m-d');
}

String _pad(int value) => value < 10 ? '0$value' : '$value';
