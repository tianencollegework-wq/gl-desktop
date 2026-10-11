import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';

/// 建连接时那份 ICE 列表怎么拼（S6.9）。
///
/// 只测纯逻辑那一段（[WebrtcCallMediaEngine.resolveIceServers]）：`_open()` 里
/// 其余几行都要平台通道，真机上才跑得起来；而「站内那份 + TURN 凭据」
/// 有没有一起交给插件，是这条链路里最该钉住的一件事。
void main() {
  const base = <Map<String, dynamic>>[
    <String, dynamic>{
      'urls': <String>['stun:stun.example.com:3478'],
    },
  ];
  const turn = <Map<String, dynamic>>[
    <String, dynamic>{
      'urls': <String>['turn:turn.cloudflare.com:3478?transport=udp'],
      'username': 'u',
      'credential': 'c',
    },
  ];

  test('站内那份在前、服务端签发的 TURN 凭据在后，一起交给插件', () async {
    final engine = WebrtcCallMediaEngine.withLazyIceServers(
      iceServers: () => base,
      turnIceServers: () async => turn,
    );

    final servers = await engine.resolveIceServers();
    expect(servers, hasLength(2));
    expect(servers.first['urls'], base.first['urls'], reason: '站内那份不能被动过');
    expect(servers.last['username'], 'u');
  });

  test('没配 / 空列表 → 只剩站内那份（ICE 列表与过去完全一致）', () async {
    var asked = 0;
    final engine = WebrtcCallMediaEngine.withLazyIceServers(
      iceServers: () => base,
      turnIceServers: () async {
        asked++;
        return const <Map<String, dynamic>>[];
      },
    );

    expect(await engine.resolveIceServers(), base);
    expect(asked, 1);
  });

  test('取凭据抛异常 → 只剩站内那份，异常不外泄（拨号不能被它打断）', () async {
    final engine = WebrtcCallMediaEngine.withLazyIceServers(
      iceServers: () => base,
      turnIceServers: () async => throw StateError('boom'),
    );

    expect(await engine.resolveIceServers(), base);
  });

  test('没给 TURN 来源（老用法）→ 原样返回，一次都不问', () async {
    final engine = WebrtcCallMediaEngine.withLazyIceServers(
      iceServers: () => base,
    );

    expect(await engine.resolveIceServers(), base);
    expect(engine.iceServers, base);
  });

  test('诊断用的描述里读得到站内那份（建连接之前）', () {
    final engine = WebrtcCallMediaEngine.withLazyIceServers(
      iceServers: () => base,
      turnIceServers: () async => turn,
    );

    expect(engine.iceServersDescription.single, contains('stun.example.com'));
    expect(engine.iceServersDescription.single, contains('无账号'));
  });
}
