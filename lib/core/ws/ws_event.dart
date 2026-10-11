import 'dart:convert';

import 'package:flutter/foundation.dart';

/// WS 消息模型。
///
/// 服务端信封只有两层是确定的：`type` 与 `data`；另有若干**顶层字段**散落在各分支里
/// （`init` 的 `client_id`、`pong` 的 `multiport`），所以原始 map 一并保留。
@immutable
class WsEvent {
  const WsEvent({required this.type, required this.data, required this.raw});

  /// 事件名（对应老端 `res['type']` 的那套：ping / pong / init / simple / webrtc ...）
  final String type;

  /// 业务载荷（老端 `res.data`）
  final Map<String, dynamic> data;

  /// 原始报文，便于取顶层字段与排查
  final Map<String, dynamic> raw;

  /// 解析失败返回 null（老端直接 `JSON.parse` 会抛异常，这里静默丢弃并记日志）
  static WsEvent? tryParse(Object? message) {
    if (message is! String || message.isEmpty) return null;
    try {
      final decoded = json.decode(message);
      if (decoded is! Map) return null;
      final map = decoded.cast<String, dynamic>();
      final type = map['type']?.toString() ?? '';
      if (type.isEmpty) return null;
      final data = map['data'];
      return WsEvent(
        type: type,
        data: data is Map
            ? data.cast<String, dynamic>()
            : const <String, dynamic>{},
        raw: map,
      );
    } on FormatException {
      return null;
    }
  }

  /// `data` 里的字段
  String? str(String key) => data[key]?.toString();

  int? intValue(String key) {
    final value = data[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  bool? boolValue(String key) {
    final value = data[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value == '1' || value.toLowerCase() == 'true';
    return null;
  }

  /// 顶层字段（如 `init` 的 `client_id`、`pong` 的 `multiport`）
  Object? top(String key) => raw[key];

  @override
  String toString() => 'WsEvent($type)';
}
