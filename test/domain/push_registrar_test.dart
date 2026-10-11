import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/push_token.dart';
import 'package:gracelinkim/domain/notify/push_registrar.dart';

/// 假的设备标识来源：想给什么给什么，还能手动播一个「标识轮换」事件
class _FakeSource implements PushTokenSource {
  PushToken? token;

  @override
  bool supported = true;

  int reads = 0;
  final StreamController<PushToken> _controller =
      StreamController<PushToken>.broadcast();

  @override
  Future<PushToken?> current() async {
    reads += 1;
    return token;
  }

  @override
  Stream<PushToken> get onRefresh => _controller.stream;

  void rotate(PushToken next) {
    token = next;
    _controller.add(next);
  }

  Future<void> close() => _controller.close();
}

/// 设备标识的登记（S8.1）：拿标识 → 落盘成 cid → 上报。
/// 这里钉的是三件最容易悄悄坏掉的事：
///  * 标识没变时**不要**反复上报（每次启动都上报一遍很浪费，日志也会刷屏）；
///  * 标识变了要**先落盘再上报**（上报请求本身要带 `cid` 头）；
///  * 拿不到标识 / 上报失败都要**安静收场**，不能影响登录与收发消息。
void main() {
  late String? stored;
  late List<String> reported;
  late List<String> logs;
  late _FakeSource source;

  setUp(() {
    stored = null;
    reported = <String>[];
    logs = <String>[];
    source = _FakeSource();
  });

  PushRegistrar build() => PushRegistrar(
    source: source,
    readCid: () => stored,
    saveCid: (cid) async => stored = cid,
    report: (cid) async => reported.add(cid),
    log: logs.add,
  );

  test('第一次登记：落盘 + 上报', () async {
    source.token = const PushToken(provider: 'fcm', token: 'tok-1');

    await build().ensure();

    expect(stored, 'fcm:tok-1');
    expect(reported, <String>['fcm:tok-1']);
  });

  test('标识没变：不重复上报', () async {
    stored = 'fcm:tok-1';
    source.token = const PushToken(provider: 'fcm', token: 'tok-1');

    await build().ensure();

    expect(reported, isEmpty);
    expect(logs.join(), contains('没变'));
  });

  test('标识轮换了：落盘 + 上报', () async {
    stored = 'fcm:tok-1';
    source.token = const PushToken(provider: 'fcm', token: 'tok-2');

    await build().ensure();

    expect(stored, 'fcm:tok-2');
    expect(reported, <String>['fcm:tok-2']);
  });

  test('拿不到标识（Firebase 没配好 / 没网）：什么都不做', () async {
    await build().ensure();

    expect(stored, isNull);
    expect(reported, isEmpty);
    expect(logs.join(), contains('没拿到设备标识'));
  });

  test('没有推送通道的平台：start() 直接跳过，不监听', () async {
    source
      ..supported = false
      ..token = const PushToken(provider: 'fcm', token: 'tok-1');
    final registrar = build()..start();

    source.rotate(const PushToken(provider: 'fcm', token: 'tok-2'));
    await Future<void>.delayed(Duration.zero);

    expect(reported, isEmpty);
    expect(logs.join(), contains('没有推送通道'));
    await registrar.stop();
    await source.close();
  });

  test('轮换事件会自己走一遍登记（不用等 App 重启）', () async {
    stored = 'fcm:tok-1';
    final registrar = build()..start();

    source.rotate(const PushToken(provider: 'fcm', token: 'tok-2'));
    await Future<void>.delayed(Duration.zero);

    expect(stored, 'fcm:tok-2');
    expect(reported, <String>['fcm:tok-2']);
    await registrar.stop();
    await source.close();
  });

  test('同时调两次 ensure：只跑一次（启动、登录、连接就绪都会调）', () async {
    source.token = const PushToken(provider: 'fcm', token: 'tok-1');
    final registrar = build();

    await Future.wait<void>(<Future<void>>[
      registrar.ensure(),
      registrar.ensure(),
    ]);

    expect(source.reads, 1);
    expect(reported, <String>['fcm:tok-1']);
  });

  test('上报抛异常也不会炸出去（推送登记失败不能挡住登录）', () async {
    source.token = const PushToken(provider: 'fcm', token: 'tok-1');
    final registrar = PushRegistrar(
      source: source,
      readCid: () => stored,
      saveCid: (cid) async => stored = cid,
      report: (cid) async => throw StateError('网络没了'),
      log: logs.add,
    );

    await registrar.ensure();

    expect(stored, 'fcm:tok-1', reason: '本地已经落了盘，下次连上再报');
    expect(logs.join(), contains('登记设备标识失败'));
  });

  test('短标识函数：完整 token 不出现在日志里', () {
    expect(pushTokenShort('fcm:ABCDEFGHIJKLMNOP'), 'fcm:ABCDEFGH…');
    expect(pushTokenShort('abc'), 'abc');
  });
}
