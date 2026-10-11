import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/domain/call/call_media_config.dart';
import 'package:gracelinkim/domain/call/call_route_info.dart';

/// 「设置 › 音视频通话 › 通话线路」的数据口径（2026-10-10）。
///
/// 那一页本身的存在就是为了「别让用户点开是一片白」，而这一行要显示的东西必须与
/// **真正建连接时用的那份**（[CallMediaConfig.iceServers]）逐条一致 —— 显示的和
/// 实际用的不一样的话，这个页面就只剩误导。所以下面最后一条直接拿两边对账。
void main() {
  test('站点没配：用兜底地址、没 TURN、公共 STUN 那六条一条不少', () {
    final route = CallRouteInfo.of(const ChatInfo());

    expect(route.siteUsesFallback, isTrue);
    expect(route.siteLines, <String>[CallMediaConfig.fallbackStunUrl]);
    expect(route.siteHasCredentials, isFalse);
    expect(route.builtInTurnLines, isEmpty);
    expect(route.hasTurn, isFalse);
    // 六个一个都不能省（站点没配 TURN 时能不能打通基本全靠这几个）
    expect(CallRouteInfo.publicStun.length, 6);
  });

  test('站点那栏没写协议头也补上（真机上踩过），写了 turn: 就亮「已配置 TURN」', () {
    final route = CallRouteInfo.of(
      const ChatInfo(
        stun: 'stun.cloudflare.com:3478, turn:turn.example.com:3478',
        stunUser: 'u',
        stunPass: 'p',
      ),
    );

    expect(route.siteUsesFallback, isFalse);
    expect(route.siteLines, <String>[
      'stun:stun.cloudflare.com:3478',
      'turn:turn.example.com:3478',
    ]);
    expect(route.siteHasCredentials, isTrue);
    expect(route.hasTurn, isTrue);
    expect(route.suspiciousTurnLines, isEmpty);
  });

  test('漏写 turn: 前缀的那一台会静默变成 STUN —— 页面要把它单独标出来', () {
    // 站点后台填 `turn.example.com:3478`（没有协议头）是很容易发生的事，
    // 而 [CallMediaConfig.normalizeIceUrl] 会把它当 STUN 发出去：看着像配了 TURN，
    // 其实没配。这一行存在的意义就是把这种写法指出来。
    final route = CallRouteInfo.of(
      const ChatInfo(stun: 'stun.cloudflare.com:3478\nturn.example.com:3478'),
    );

    expect(route.siteLines, <String>[
      'stun:stun.cloudflare.com:3478',
      'stun:turn.example.com:3478',
    ]);
    expect(route.hasTurn, isFalse);
    expect(route.suspiciousTurnLines, <String>['turn.example.com:3478']);
  });

  test('turn@主机:端口 这种写法也认，不算漏前缀', () {
    final route = CallRouteInfo.of(
      const ChatInfo(stun: 'turn@turn.example.com:3478'),
    );

    expect(route.siteLines, <String>['turn:turn.example.com:3478']);
    expect(route.hasTurn, isTrue);
    expect(route.suspiciousTurnLines, isEmpty);
  });

  test('站点只配了 STUN：不算配了 TURN，也没账号', () {
    final route = CallRouteInfo.of(
      const ChatInfo(stun: 'stun.cloudflare.com:3478'),
    );

    expect(route.hasTurn, isFalse);
    expect(route.siteHasCredentials, isFalse);
    expect(route.siteUsesFallback, isFalse);
    // 只配 STUN 的站点不该被怀疑成「把 TURN 写错了」
    expect(route.suspiciousTurnLines, isEmpty);
  });

  test('显示的就是实际会用的：与 CallMediaConfig.iceServers 的地址逐条对得上', () {
    const chatInfo = ChatInfo(
      stun: 'turn.example.com:3478',
      stunUser: 'u',
      stunPass: 'p',
    );
    final route = CallRouteInfo.of(chatInfo);
    final actual = <String>[
      for (final server in CallMediaConfig.iceServers(chatInfo))
        for (final url in server['urls'] as List<dynamic>) url.toString(),
    ];

    expect(route.copyLines, actual);
    expect(route.copyText, actual.join('\n'));
  });
}
