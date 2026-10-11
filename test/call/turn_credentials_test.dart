import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/call/turn_credentials.dart';

/// Cloudflare Realtime TURN 的短时凭据（S6.9）。
///
/// 全是纯逻辑（一个 `fetch` 回调 + 一个注入的时钟），所以能把**三条纪律**逐条钉住：
/// 绝不抛、不每次都问、并发只发一次请求。
void main() {
  /// Cloudflare `generate-ice-servers` 的原样返回（服务端透传的那份）
  Map<String, dynamic> cloudflarePayload({int expiresIn = 3600}) =>
      <String, dynamic>{
        'iceServers': <dynamic>[
          <String, dynamic>{
            'urls': <dynamic>['stun:stun.cloudflare.com:3478'],
          },
          <String, dynamic>{
            'urls': <dynamic>[
              'turn:turn.cloudflare.com:3478?transport=udp',
              'turn:turn.cloudflare.com:443?transport=udp',
              'turn:turn.cloudflare.com:3478?transport=tcp',
              'turn:turn.cloudflare.com:80?transport=tcp',
              'turns:turn.cloudflare.com:5349?transport=tcp',
              'turns:turn.cloudflare.com:443?transport=tcp',
            ],
            'username': 'bc91b63e',
            'credential': 'ebd71f1d',
          },
        ],
        'expiresIn': expiresIn,
      };

  group('解析报文', () {
    test('Cloudflare 那份原样报文 → 两条 ICE 服务器，账号跟着走', () {
      final servers = parseTurnIceServers(cloudflarePayload());
      expect(servers, hasLength(2));

      expect(servers.first['urls'], <String>['stun:stun.cloudflare.com:3478']);
      expect(
        servers.first.containsKey('username'),
        isFalse,
        reason: 'STUN 那条没有账号',
      );

      // TURN 那条的地址原样保留（六条 URL 一条不少），账号密码带上
      expect(
        (servers.last['urls'] as List).first,
        'turn:turn.cloudflare.com:3478?transport=udp',
      );
      expect((servers.last['urls'] as List), hasLength(6));
      expect(servers.last['username'], 'bc91b63e');
      expect(servers.last['credential'], 'ebd71f1d');
    });

    test('少写协议头的地址补成 stun:（真机上踩过的坑），重复地址只留一份', () {
      final servers = parseTurnIceServers(<String, dynamic>{
        'iceServers': <dynamic>[
          <String, dynamic>{
            'urls': <dynamic>[
              'stun.cloudflare.com:3478',
              'stun:stun.cloudflare.com:3478',
              '   ',
            ],
          },
        ],
      });
      expect(servers, hasLength(1));
      expect(servers.single['urls'], <String>['stun:stun.cloudflare.com:3478']);
    });

    test('53 端口的备用地址丢掉（系统普遍拦它，留着只会白等超时）', () {
      final servers = parseTurnIceServers(<String, dynamic>{
        'iceServers': <dynamic>[
          <String, dynamic>{
            'urls': <dynamic>[
              'turn:turn.cloudflare.com:443?transport=udp',
              'turn:turn.cloudflare.com:53?transport=udp',
            ],
            'username': 'u',
            'credential': 'c',
          },
        ],
      });
      expect(servers.single['urls'], <String>[
        'turn:turn.cloudflare.com:443?transport=udp',
      ]);
    });

    test('一个地址都不剩的条目整条丢掉', () {
      final servers = parseTurnIceServers(<String, dynamic>{
        'iceServers': <dynamic>[
          <String, dynamic>{'urls': <dynamic>[]},
          <String, dynamic>{'urls': ':53'},
          <String, dynamic>{'noUrls': true},
          'x',
          <String, dynamic>{
            'urls': <dynamic>['turn:turn.cloudflare.com:3478?transport=udp'],
            'username': 'u',
            'credential': 'c',
          },
        ],
      });
      expect(servers, hasLength(1));
      expect(servers.single['username'], 'u');
    });

    test('也认直接一个数组；其它乱七八糟的输入一律空列表（不抛）', () {
      expect(
        parseTurnIceServers(<dynamic>[
          <String, dynamic>{
            'urls': <dynamic>['stun:stun.cloudflare.com:3478'],
          },
        ]),
        hasLength(1),
      );

      for (final junk in <Object?>[
        null,
        '',
        'iceServers',
        42,
        <String, dynamic>{},
        <String, dynamic>{'iceServers': 'nope'},
        <dynamic>[1, 2, 3],
      ]) {
        expect(parseTurnIceServers(junk), isEmpty, reason: '输入 = $junk');
      }
    });
  });

  group('凭据服务（取 + 缓存）', () {
    test('缓存期内只去取一次（三通电话一次请求）', () async {
      var now = DateTime(2026, 9, 26, 10, 0, 0);
      var fetches = 0;
      final service = TurnCredentialService(
        now: () => now,
        fetch: () async {
          fetches++;
          return cloudflarePayload(expiresIn: 3600);
        },
      );

      for (var i = 0; i < 3; i++) {
        expect(await service.iceServers(), hasLength(2));
      }
      expect(fetches, 1);

      // 到期（expiresIn 打八折 → 48 分钟）之后才再问一次
      now = now.add(const Duration(minutes: 47));
      await service.iceServers();
      expect(fetches, 1, reason: '还没到 48 分钟，仍走缓存');

      now = now.add(const Duration(minutes: 2));
      await service.iceServers();
      expect(fetches, 2, reason: '过八折后的期限要重新取');
    });

    test('没给 expiresIn 时用默认缓存时长（30 分钟）', () async {
      var now = DateTime(2026, 9, 26, 10, 0, 0);
      var fetches = 0;
      final service = TurnCredentialService(
        now: () => now,
        fetch: () async {
          fetches++;
          return <String, dynamic>{
            'iceServers': <dynamic>[
              <String, dynamic>{
                'urls': <dynamic>['stun:stun.cloudflare.com:3478'],
              },
            ],
          };
        },
      );

      await service.iceServers();
      now = now.add(const Duration(minutes: 29));
      await service.iceServers();
      expect(fetches, 1);

      now = now.add(const Duration(minutes: 2));
      await service.iceServers();
      expect(fetches, 2);
    });

    test('并发调用只发一次请求（拨号与被叫同时点）', () async {
      final gate = <String, dynamic>{};
      var fetches = 0;
      final service = TurnCredentialService(
        fetch: () async {
          fetches++;
          final completer = Completer<void>();
          gate['release'] = completer.complete;
          await completer.future;
          return cloudflarePayload();
        },
      );

      final first = service.iceServers();
      final second = service.iceServers();
      final third = service.iceServers();
      (gate['release'] as void Function())();

      expect(await first, hasLength(2));
      expect(await second, hasLength(2));
      expect(await third, hasLength(2));
      expect(fetches, 1);
    });

    test('取失败（抛异常 / 超时）→ 空列表，绝不把异常扔给拨号', () async {
      final boom = TurnCredentialService(
        fetch: () async => throw StateError('网络断了'),
      );
      expect(await boom.iceServers(), isEmpty);

      final slow = TurnCredentialService(
        timeout: const Duration(milliseconds: 20),
        fetch: () => Completer<Object?>().future, // 永不返回
      );
      expect(await slow.iceServers(), isEmpty);

      // 失败之后还能恢复：过了退避窗口就重新取（失败不写缓存）
      var now = DateTime(2026, 9, 26, 10, 0, 0);
      var ok = false;
      final mixed = TurnCredentialService(
        now: () => now,
        fetch: () async {
          if (!ok) throw StateError('第一次失败');
          return cloudflarePayload();
        },
      );
      expect(await mixed.iceServers(), isEmpty);
      ok = true;
      now = now.add(const Duration(minutes: 6));
      expect(await mixed.iceServers(), hasLength(2));
    });

    test('失败之后 5 分钟内不再去取（别让每通电话都白等一次超时）', () async {
      var now = DateTime(2026, 9, 26, 10, 0, 0);
      var fetches = 0;
      final service = TurnCredentialService(
        now: () => now,
        fetch: () async {
          fetches++;
          throw StateError('Cloudflare 连不上');
        },
      );

      expect(await service.iceServers(), isEmpty);
      expect(fetches, 1);

      // 退避窗口里的三通电话：一次请求都不发（拨号也不等那 4 秒）
      for (var i = 0; i < 3; i++) {
        expect(await service.iceServers(), isEmpty);
      }
      expect(fetches, 1);

      now = now.add(const Duration(minutes: 6));
      expect(await service.iceServers(), isEmpty);
      expect(fetches, 2, reason: '过了退避窗口要再试一次');
    });

    test('服务端返回空列表（站点没配密钥）→ 空，且不缓存（下次通话还会问）', () async {
      var fetches = 0;
      final service = TurnCredentialService(
        fetch: () async {
          fetches++;
          return <String, dynamic>{'iceServers': <dynamic>[], 'expiresIn': 0};
        },
      );

      expect(await service.iceServers(), isEmpty);
      expect(await service.iceServers(), isEmpty);
      expect(fetches, 2, reason: '空列表不算「拿到了」，不该缓存 30 分钟');
    });

    test('invalidate 之后会重新取（登出 / 换账号）', () async {
      var fetches = 0;
      final service = TurnCredentialService(
        fetch: () async {
          fetches++;
          return cloudflarePayload();
        },
      );

      await service.iceServers();
      await service.iceServers();
      expect(fetches, 1);

      service.invalidate();
      await service.iceServers();
      expect(fetches, 2);
    });
  });
}
