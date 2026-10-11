// WS 协议探测脚本（对应 REFACTOR_PLAN 的 S6.0 采集思路，提前到 M2 前做一次）。
//
// 用途：连一次线上 WebSocket，把**服务端真实返回的报文**抓下来存档，
// 用来校正 docs/protocol/ 里那批"只能靠真实报文确定"的字段。
//
// 用法：
//   dart run tool/ws_probe.dart [wss地址] [观测秒数]
//   dart run tool/ws_probe.dart wss://message.gracelink.cc/wss 20
//
// 行为与正式客户端一致：连上后立即发 `{"type":"ping"}`，收到服务端 ping 回 pong，
// 每 5 秒补一次心跳。不发任何业务消息、不绑定账号、不登录。
//
// 产出：docs/protocol/samples/ws-probe-<时间戳>.jsonl + 终端摘要。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

const String defaultUrl = 'wss://message.gracelink.cc/wss';
const Duration heartbeat = Duration(seconds: 5);

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : defaultUrl;
  final observeSeconds = args.length > 1 ? int.tryParse(args[1]) ?? 20 : 20;

  final frames = <_Frame>[];
  final out = stdout;

  out.writeln('=== WS 探测 ===');
  out.writeln('地址   : $url');
  out.writeln('观测时长: ${observeSeconds}s');
  out.writeln('');

  final channel = WebSocketChannel.connect(Uri.parse(url));
  final started = DateTime.now();

  try {
    await channel.ready.timeout(const Duration(seconds: 15));
  } on TimeoutException {
    out.writeln('❌ 握手超时（15s）：地址或网络不通');
    await channel.sink.close();
    return;
  } catch (error) {
    out.writeln('❌ 握手失败：$error');
    return;
  }

  final handshakeMs = DateTime.now().difference(started).inMilliseconds;
  out.writeln('✅ 握手成功，耗时 ${handshakeMs}ms');
  out.writeln('');

  void send(Map<String, dynamic> payload) {
    final text = json.encode(payload);
    channel.sink.add(text);
    frames.add(_Frame(DateTime.now(), 'out', text));
    out.writeln('[${_stamp(DateTime.now())}] --> $text');
  }

  final subscription = channel.stream.listen(
    (dynamic message) {
      final text = message is String ? message : message.toString();
      frames.add(_Frame(DateTime.now(), 'in', text));
      out.writeln('[${_stamp(DateTime.now())}] <-- $text');

      // 服务端 ping 必须回 pong，否则会被断开
      final event = _tryDecode(text);
      if (event?['type'] == 'ping') send(<String, dynamic>{'type': 'pong'});
    },
    onError: (Object error) => out.writeln('!! 连接出错：$error'),
    onDone: () => out.writeln(
      '!! 连接被关闭，closeCode=${channel.closeCode} '
      'reason=${channel.closeReason}',
    ),
    cancelOnError: false,
  );

  // 与正式客户端一致：连上就发心跳
  send(<String, dynamic>{'type': 'ping'});
  final ticker = Timer.periodic(
    heartbeat,
    (_) => send(<String, dynamic>{'type': 'ping'}),
  );

  await Future<void>.delayed(Duration(seconds: observeSeconds));

  ticker.cancel();
  await subscription.cancel();
  await channel.sink.close();

  out.writeln('');
  out.writeln(_summarize(frames));

  final path = await _writeSample(frames);
  out.writeln('样本已写入：$path');
}

String _stamp(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}:'
    '${time.second.toString().padLeft(2, '0')}.'
    '${time.millisecond.toString().padLeft(3, '0')}';

Map<String, dynamic>? _tryDecode(String text) {
  try {
    final decoded = json.decode(text);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } on FormatException {
    return null;
  }
}

/// 直接回答 docs/protocol/README.md 里那批"待确认"问题
String _summarize(List<_Frame> frames) {
  final inbound = frames.where((frame) => frame.direction == 'in').toList();
  if (inbound.isEmpty) {
    return '摘要：${frames.length} 帧，其中入站 0 帧——服务端没有主动推送任何内容。';
  }

  final topLevelKeys = <String>{};
  final types = <String, int>{};
  final dataKeys = <String, Set<String>>{};
  final examples = <String, String>{};

  for (final frame in inbound) {
    final json = _tryDecode(frame.payload);
    if (json == null) continue;
    topLevelKeys.addAll(json.keys);
    final type = json['type']?.toString() ?? '(无 type)';
    types[type] = (types[type] ?? 0) + 1;
    examples.putIfAbsent(type, () => frame.payload);
    final data = json['data'];
    if (data is Map) {
      dataKeys
          .putIfAbsent(type, () => <String>{})
          .addAll(data.keys.map((k) => k.toString()));
    }
  }

  final buffer = StringBuffer()
    ..writeln('=== 摘要 ===')
    ..writeln('总帧数     : ${frames.length}（入站 ${inbound.length}）')
    ..writeln('顶层字段   : ${topLevelKeys.join(', ')}')
    ..writeln(
      '事件分布   : ${types.entries.map((e) => '${e.key}×${e.value}').join(', ')}',
    );

  for (final entry in dataKeys.entries) {
    buffer.writeln('data.${entry.key} : ${entry.value.join(', ')}');
  }
  buffer.writeln('');
  buffer.writeln('--- 各事件首帧原文 ---');
  for (final entry in examples.entries) {
    buffer.writeln('${entry.key}: ${entry.value}');
  }
  return buffer.toString();
}

Future<String> _writeSample(List<_Frame> frames) async {
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '')
      .replaceAll('-', '')
      .split('.')
      .first;
  final dir = Directory('docs/protocol/samples');
  if (!await dir.exists()) await dir.create(recursive: true);
  final file = File('${dir.path}/ws-probe-$stamp.jsonl');
  final buffer = StringBuffer();
  for (final frame in frames) {
    buffer.writeln(
      json.encode(<String, dynamic>{
        'at': frame.at.toIso8601String(),
        'direction': frame.direction,
        'payload': frame.payload,
      }),
    );
  }
  await file.writeAsString(buffer.toString());
  return file.path;
}

class _Frame {
  const _Frame(this.at, this.direction, this.payload);

  final DateTime at;

  /// 'in' 为服务端下发，'out' 为客户端发出
  final String direction;
  final String payload;
}
