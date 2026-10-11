import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 协议日志（对应 REFACTOR_PLAN 的 S1.6）。
///
/// 这是采集真实报文的工具：把 WS 收发与 HTTP 请求/响应的**原始报文**落成 JSONL 文件。
/// 采集方式（不需要 Charles / mitmproxy）：
///
/// 1. App 里打开开关（debug 包默认开）；
/// 2. **用老端给新端发消息、打电话**；
/// 3. 新端记录下来的就是服务端原样返回的报文；
/// 4. 导出文件 → 存进 `docs/protocol/` 校正模型。
///
/// 只在 debug 构建里收集，release 不产生任何开销。
class ProtocolLog {
  ProtocolLog._();

  static const int _maxEntries = 800;
  static const int _maxPayloadChars = 20000;

  static final List<ProtocolLogEntry> _entries = <ProtocolLogEntry>[];

  /// 是否记录。debug 默认开，release 默认关（可用本地开关覆盖）。
  static bool enabled = kDebugMode;

  static List<ProtocolLogEntry> get entries => List.unmodifiable(_entries);

  static void clear() => _entries.clear();

  static void httpRequest(String method, String path, Object? payload) {
    _add('http', 'out', '$method $path ${_stringify(payload)}');
  }

  static void httpResponse(String path, int statusCode, Object? payload) {
    _add('http', 'in', '$statusCode $path ${_stringify(payload)}');
  }

  static void wsIn(Object? payload) => _add('ws', 'in', _stringify(payload));

  static void wsOut(Object? payload) => _add('ws', 'out', _stringify(payload));

  static void _add(String channel, String direction, String payload) {
    if (!enabled) return;
    final text = payload.length > _maxPayloadChars
        ? '${payload.substring(0, _maxPayloadChars)}…(截断)'
        : payload;
    _entries.add(
      ProtocolLogEntry(
        at: DateTime.now(),
        channel: channel,
        direction: direction,
        payload: text,
      ),
    );
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
  }

  static String _stringify(Object? payload) {
    if (payload == null) return '';
    if (payload is String) return payload;
    try {
      return json.encode(payload);
    } catch (_) {
      return payload.toString();
    }
  }

  /// 导出为 JSONL，返回文件路径。
  static Future<String> dumpToFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    final file = File('${dir.path}/protocol_$stamp.jsonl');
    final buffer = StringBuffer();
    for (final entry in _entries) {
      buffer.writeln(entry.toJsonLine());
    }
    await file.writeAsString(buffer.toString());
    return file.path;
  }
}

@immutable
class ProtocolLogEntry {
  const ProtocolLogEntry({
    required this.at,
    required this.channel,
    required this.direction,
    required this.payload,
  });

  final DateTime at;

  /// 'http' 或 'ws'
  final String channel;

  /// 'in' 或 'out'
  final String direction;
  final String payload;

  String toJsonLine() => json.encode(<String, dynamic>{
    'at': at.toIso8601String(),
    'channel': channel,
    'direction': direction,
    'payload': payload,
  });

  @override
  String toString() => '[$channel/$direction] $payload';
}
