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
  late String? voipStored;
  late String? voipReported;
  late List<String> reported;
  late List<String> logs;
  late _FakeSource source;

  /// 现在能不能上报。`false` = 未登录 / 没有 client_id / 网络不通：
  /// `report` 会回 false（= 没交出去），调用方**不该记账**。
  late bool canReport;

  setUp(() {
    stored = null;
    voipStored = null;
    voipReported = null;
    reported = <String>[];
    logs = <String>[];
    canReport = true;
    source = _FakeSource();
  });

  PushRegistrar build() => PushRegistrar(
    source: source,
    readCid: () => stored,
    saveCid: (cid) async => stored = cid,
    report: (cid) async {
      if (!canReport) return false;
      reported.add(cid);
      return true;
    },
    readVoipCid: () => voipStored,
    saveVoipCid: (cid) async => voipStored = cid,
    readVoipReported: () => voipReported,
    saveVoipReported: (cid) async => voipReported = cid,
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

  // ── iOS 上那条**另外算账**的标识（S8.2）─────────────────────────────────
  // 它与上面那个 `cid` 不是同一件事：这条是 PushKit 给的，只有它能弹出锁屏来电
  // 界面、也只有它能在 App 被划掉之后把进程叫醒。服务端按前缀把它们当两台设备。
  group('VoIP 标识（apns_voip）', () {
    test('首次登记：落盘 + 上报 + 记下「服务端收过了」', () async {
      await build().applyVoip('tok-voip-1');

      expect(voipStored, 'apns_voip:tok-voip-1');
      expect(reported, <String>['apns_voip:tok-voip-1']);
      expect(voipReported, 'apns_voip:tok-voip-1');
    });

    test('服务端已经收过这条：不重复上报', () async {
      voipStored = 'apns_voip:tok-voip-1';
      voipReported = 'apns_voip:tok-voip-1';

      await build().applyVoip('tok-voip-1');

      expect(reported, isEmpty);
      expect(logs.join(), contains('服务端已经收过了'));
    });

    test('标识换了（重装 App）：再报一次', () async {
      voipStored = 'apns_voip:tok-voip-1';
      voipReported = 'apns_voip:tok-voip-1';

      await build().applyVoip('tok-voip-2');

      expect(voipStored, 'apns_voip:tok-voip-2');
      expect(reported, <String>['apns_voip:tok-voip-2']);
    });

    test('未登录时那一次没交出去：本地存下、不记账；登录后（ensure）补报', () async {
      // 真机上最常见的那条路：PushKit 的标识比登录先到（约 1 秒就到），
      // 那时还没有 user / client_id —— 以前这一下会把「本地存过」当成「报过了」，
      // 于是服务端永远没有 apns_voip 那一行（锁屏来电一直不弹，日志里却不像出错）。
      canReport = false;
      final registrar = build();
      await registrar.applyVoip('tok-voip-1');

      expect(voipStored, 'apns_voip:tok-voip-1', reason: '本地要存下，不然连重报的本钱都没有');
      expect(reported, isEmpty);
      expect(voipReported, isNull, reason: '没交出去就不能记成「服务端收过了」');

      // 用户登录 / 连接就绪 —— `ensure()` 是 `session_service` 在那两个时刻调的
      canReport = true;
      source.token = null;
      await registrar.ensure();

      expect(reported, <String>['apns_voip:tok-voip-1']);
      expect(voipReported, 'apns_voip:tok-voip-1');
    });

    test('补报过的不会再补（ensure 会被调很多次）', () async {
      voipStored = 'apns_voip:tok-voip-1';
      final registrar = build();

      await registrar.ensure();
      await registrar.ensure();

      expect(reported, <String>['apns_voip:tok-voip-1']);
    });

    test('空 token（模拟器 / 原生还没拿到）：一步都不走', () async {
      await build().applyVoip('');

      expect(voipStored, isNull);
      expect(reported, isEmpty);
    });

    test('没注入 VoIP 回调（桌面 / 安卓）：空操作', () async {
      final registrar = PushRegistrar(
        source: source,
        readCid: () => stored,
        saveCid: (cid) async => stored = cid,
        report: (cid) async {
          reported.add(cid);
          return true;
        },
        log: logs.add,
      );

      await registrar.applyVoip('tok-voip-1');
      await registrar.retryVoip();

      expect(reported, isEmpty);
    });

    test('上报抛异常也不会炸出去（登记失败不能挡通话本身）', () async {
      final registrar = PushRegistrar(
        source: source,
        readCid: () => stored,
        saveCid: (cid) async => stored = cid,
        report: (cid) async => throw StateError('网络没了'),
        readVoipCid: () => voipStored,
        saveVoipCid: (cid) async => voipStored = cid,
        log: logs.add,
      );

      await registrar.applyVoip('tok-voip-1');
      // 补报那条也一样：异常不能漏出去
      await registrar.retryVoip();

      expect(voipStored, 'apns_voip:tok-voip-1', reason: '本地已经落了盘，下次连上再报');
      expect(logs.join(), contains('登记 VoIP 标识失败'));
    });
  });

  test('短标识函数：完整 token 不出现在日志里', () {
    expect(pushTokenShort('fcm:ABCDEFGHIJKLMNOP'), 'fcm:ABCDEFGH…');
    expect(pushTokenShort('abc'), 'abc');
  });
}
