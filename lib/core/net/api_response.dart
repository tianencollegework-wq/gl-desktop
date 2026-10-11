import 'dart:convert';

import 'api_exception.dart';

/// 统一响应信封：`{ "code": 0, "msg": "", "data": {} }`
///
/// 服务端返回的 `code` 可能是数字或字符串（老端既有 `parseInt` 比较也有 `==` 松散比较），
/// 这里统一收敛成 int。
class ApiResponse {
  const ApiResponse({required this.code, this.msg, this.data, this.count = 0});

  final int code;
  final String? msg;
  final dynamic data;

  /// 分页总数。老端的列表接口会多给一个 `count`（`uni-pagination` 用它），
  /// 以前这一项被丢掉了，需要分页的页面只能自己再发一次请求。
  final int count;

  bool get isSuccess => code == 0;

  /// 把响应解析成异常；成功返回 null。
  ApiException? toException() => mapBusinessCode(code, msg);

  factory ApiResponse.fromJson(Map<String, dynamic> json) {
    return ApiResponse(
      code: _asInt(json['code']) ?? -999,
      msg: json['msg']?.toString(),
      data: json['data'],
      count: _asInt(json['count']) ?? 0,
    );
  }

  /// `data` 是对象时用它，否则抛异常——避免把错误结构一路带到业务层。
  Map<String, dynamic> get dataAsMap {
    final value = data;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    return const <String, dynamic>{};
  }

  List<dynamic> get dataAsList {
    final value = data;
    if (value is List) return value;
    return const <dynamic>[];
  }

  @override
  String toString() => 'ApiResponse(code: $code, msg: $msg)';
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// 把响应体安全地转成 map。
///
/// 客户端把 Dio 设成了 `ResponseType.plain`（见 ApiClient 注释），所以这里
/// 拿到的是**字符串**，需要自己解码；解码失败（比如网关返回的 HTML 错误页）
/// 返回空 map，由调用方按状态码处理。
Map<String, dynamic> asStringKeyedMap(dynamic body) {
  if (body is Map<String, dynamic>) return body;
  if (body is Map) return body.cast<String, dynamic>();
  if (body is String) {
    final text = body.trim();
    if (text.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = json.decode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on FormatException {
      return const <String, dynamic>{};
    }
  }
  return const <String, dynamic>{};
}
