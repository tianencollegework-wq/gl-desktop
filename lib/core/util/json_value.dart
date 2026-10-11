/// 服务端 JSON 的宽松取值工具。
///
/// 老端是 JS，`parseInt` / 松散 `==` / `if (x)` 全都能忍：字段有时是 `1`，
/// 有时是 `"1"`，有时是 `true`，缺失时是 `undefined`。
/// Dart 里强转会直接抛异常，而这些字段大多在**启动路径**上（登录、全局配置），
/// 所以统一走这里的宽松口径，缺字段落回默认值而不是崩掉。
library;

/// 宽松取整：`1` / `"1"` / `true` → 1；无法解析时用 [fallback]
int asInt(Object? value, int fallback) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is bool) return value ? 1 : 0;
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

/// 宽松取布尔：`true` / `1` / `"1"` / `"true"` → true
bool asBool(Object? value, {bool fallback = false}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == '1' || normalized == 'true') return true;
    if (normalized == '0' || normalized == 'false' || normalized.isEmpty) {
      return false;
    }
  }
  return fallback;
}

/// 宽松取小数：`2` / `"2"` / `"39.9"` → double；解析不了用 [fallback]
double asDouble(Object? value, [double fallback = 0]) {
  if (value == null) return fallback;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  if (value is String) return double.tryParse(value.trim()) ?? fallback;
  return fallback;
}

/// 宽松取字符串：`null` → [fallback]，其它类型转成字符串
String asText(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  final text = value.toString();
  return text.isEmpty ? fallback : text;
}

/// 服务端 id 这类字段的原样回传：是整数就发整数，其余（`u3` 这种）发字符串。
///
/// 老端发的是 JS 的 number；如果服务端用 `===` 比 id，把 `friend_id` 当字符串发就
/// 永远对不上，所以这里保留原始类型（S5.1 的同意/拒绝、S5.2 的改备注都用它）。
Object idValue(String raw) => int.tryParse(raw) ?? raw;

/// 把可能是 `null` / 非对象的字段安全地变成 `Map<String, dynamic>`
Map<String, dynamic> asMap(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

/// 把可能是 `null` / 非列表的字段安全地变成列表
List<dynamic> asList(Object? value) =>
    value is List ? value : const <dynamic>[];
