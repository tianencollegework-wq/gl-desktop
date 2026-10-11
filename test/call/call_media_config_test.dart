import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/domain/call/call_media_config.dart';

/// 通话媒体配置（S6.2）：ICE 列表与 `getUserMedia` / SDP 参数。
/// 这份东西错了，真机上表现为「打不通」或「没有回声消除」，所以逐项钉死。
void main() {
  group('ICE 服务器', () {
    test('站点没配 STUN 时：公共 STUN + 老端那个兜底地址', () {
      final servers = CallMediaConfig.iceServers(const ChatInfo());

      expect(servers, hasLength(2));
      expect(servers[0]['urls'], CallMediaConfig.publicStunUrls);
      // 老端：`opt.stun ? opt.stun : ['stun:stun.callwithus.com']`
      expect(servers[1]['urls'], <String>[CallMediaConfig.fallbackStunUrl]);
      // 没账号密码就不发这两个键（发空串在真机上被当成「带鉴权的 STUN」）
      expect(servers[1].containsKey('username'), isFalse);
      expect(servers[1].containsKey('credential'), isFalse);
    });

    test('站点地址没写协议头 → 自动补 stun:（真机上就是因为这个才闪退）', () {
      // 站点后台实际填的是这个（从真机缓存的配置里读出来的）
      final servers = CallMediaConfig.iceServers(
        const ChatInfo(stun: 'stun.cloudflare.com:3478'),
      );

      expect(servers[1]['urls'], <String>['stun:stun.cloudflare.com:3478']);
    });

    test('补全规则：有协议头的原样（大小写也认），没有的就当 STUN', () {
      expect(
        CallMediaConfig.normalizeIceUrl('stun:stun.a.com:3478'),
        'stun:stun.a.com:3478',
      );
      expect(CallMediaConfig.normalizeIceUrl('STUN:a.com'), 'STUN:a.com');
      expect(
        CallMediaConfig.normalizeIceUrl('turn:a.com:3478'),
        'turn:a.com:3478',
      );
      expect(
        CallMediaConfig.normalizeIceUrl('turns:a.com:5349'),
        'turns:a.com:5349',
      );
      expect(CallMediaConfig.normalizeIceUrl('a.com:3478'), 'stun:a.com:3478');
      expect(CallMediaConfig.normalizeIceUrl('stun.a.com'), 'stun:stun.a.com');
      // 少数面板把协议写在 @ 前面
      expect(
        CallMediaConfig.normalizeIceUrl('turn@a.com:3478'),
        'turn:a.com:3478',
      );
      expect(
        CallMediaConfig.normalizeIceUrl('turns@a.com:5349'),
        'turns:a.com:5349',
      );
      expect(CallMediaConfig.normalizeIceUrl('  '), isEmpty);
    });

    test('一栏里塞了多个地址（逗号/空格/换行）就拆成数组', () {
      final servers = CallMediaConfig.iceServers(
        const ChatInfo(
          stun: 'stun.cloudflare.com:3478,stun:a.com\nstun:b.com:3479',
        ),
      );

      expect(servers[1]['urls'], <String>[
        'stun:stun.cloudflare.com:3478',
        'stun:a.com',
        'stun:b.com:3479',
      ]);
    });

    test('公共 STUN 那六个地址一个都不能少（没有 TURN 时全靠它们）', () {
      expect(CallMediaConfig.publicStunUrls, <String>[
        'stun:stun.xten.com',
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
        'stun:stun2.l.google.com:19302',
        'stun:stun3.l.google.com:19302',
        'stun:stun4.l.google.com:19302',
      ]);
    });

    test('站点配了 TURN：地址 + 账号密码原样带上（顺序仍是公共 STUN 在前）', () {
      final servers = CallMediaConfig.iceServers(
        const ChatInfo(
          stun: 'turn:turn.example.com:3478',
          stunUser: 'user1',
          stunPass: 'pass1',
        ),
      );

      expect(servers, hasLength(2));
      expect(servers[1]['urls'], <String>['turn:turn.example.com:3478']);
      expect(servers[1]['username'], 'user1');
      expect(servers[1]['credential'], 'pass1');
    });

    test('配了一串空格也当没配（老端是 JS，`'
        '.trim()` 那种脏配置要挡住）', () {
      final servers = CallMediaConfig.iceServers(const ChatInfo(stun: '   '));

      expect(servers[1]['urls'], <String>[CallMediaConfig.fallbackStunUrl]);
    });

    test('自己的 TURN 位现在还是空的——这是最大的一块空缺（风险登记 #1）', () {
      // 这条是「有意为之的断言」：等自建 coturn 之后把地址填进
      // `CallMediaConfig.ownTurnServers` 时，这条会失败，提醒一起改文档。
      expect(CallMediaConfig.ownTurnServers, isEmpty);
    });

    test('填了自己的 TURN 之后会追加在最后（顺序不影响协商，但便于排查）', () {
      final servers = CallMediaConfig.iceServers(
        const ChatInfo(stun: 'stun:site.example.com'),
      );

      expect(servers.map((server) => server['urls']).toList(), <dynamic>[
        CallMediaConfig.publicStunUrls,
        <String>['stun:site.example.com'],
      ]);
    });
  });

  group('getUserMedia 参数', () {
    test('语音通话：只要音频，而且给的是布尔 true', () {
      final constraints = CallMediaConfig.localMediaConstraints(video: false);

      expect(constraints, <String, dynamic>{'audio': true});
      expect(constraints.containsKey('video'), isFalse);
    });

    test('视频通话：加一路前置摄像头', () {
      final constraints = CallMediaConfig.localMediaConstraints(video: true);

      expect(constraints['audio'], isTrue);
      expect(constraints['video'], <String, dynamic>{
        'facingMode': CameraFacing.front,
      });
    });

    test('刻意不带 width / height（老端那组是屏幕横竖写反的，而且原生会忽略）', () {
      final constraints = CallMediaConfig.localMediaConstraints(video: true);
      final video = constraints['video'] as Map<String, dynamic>;

      expect(video.containsKey('width'), isFalse);
      expect(video.containsKey('height'), isFalse);
      expect(video.keys.toSet(), <String>{'facingMode'});
    });

    test('切前后置', () {
      expect(CameraFacing.toggle(CameraFacing.front), CameraFacing.back);
      expect(CameraFacing.toggle(CameraFacing.back), CameraFacing.front);
      expect(CameraFacing.front, 'user');
      expect(CameraFacing.back, 'environment');
    });
  });

  group('SDP 参数', () {
    test('语音通话不收视频（老端 offerToRecieveVideo: 0）', () {
      final constraints = CallMediaConfig.sdpConstraints(video: false);

      expect(constraints['mandatory'], <String, dynamic>{
        'OfferToReceiveAudio': true,
        'OfferToReceiveVideo': false,
      });
      expect(constraints['optional'], isEmpty);
    });

    test('视频通话两路都收', () {
      final constraints = CallMediaConfig.sdpConstraints(video: true);

      expect(
        (constraints['mandatory']
            as Map<String, dynamic>)['OfferToReceiveVideo'],
        isTrue,
      );
    });

    test('SFU 发布那条会话：**只发不收**（多一条 recvonly 音轨就会让 CF 要重协商）', () {
      expect(
        CallMediaConfig.publishSdpConstraints()['mandatory'],
        <String, dynamic>{
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': false,
        },
      );
      expect(CallMediaConfig.publishSdpConstraints()['optional'], isEmpty);
    });
  });

  group('ICE 候选字段', () {
    test('只留三个键，多余的（address / usernameFragment）全部丢掉', () {
      final picked = pickIceCandidateFields(<String, dynamic>{
        'candidate': 'cand-1',
        'sdpMLineIndex': 0,
        'sdpMid': 'audio',
        'address': '192.168.1.5',
        'usernameFragment': 'abcd',
      });

      expect(picked, <String, dynamic>{
        'candidate': 'cand-1',
        'sdpMLineIndex': 0,
        'sdpMid': 'audio',
      });
      expect(picked.keys.toSet(), CallMediaConfig.iceCandidateKeys.toSet());
    });

    test('缺字段也算正常（候选可能就是不全）', () {
      expect(pickIceCandidateFields(const <String, dynamic>{}), isEmpty);
      expect(
        pickIceCandidateFields(<String, dynamic>{'candidate': 'cand-1'}),
        <String, dynamic>{'candidate': 'cand-1'},
      );
    });
  });

  group('ChatInfo 的三个 STUN 字段（服务端下发）', () {
    test('从服务端报文里读出来', () {
      final chatInfo = ChatInfo.fromJson(<String, dynamic>{
        'webrtc': 1,
        'stun': 'turn:turn.example.com:3478',
        'stunUser': 'u',
        'stunPass': 'p',
      });

      expect(chatInfo.stun, 'turn:turn.example.com:3478');
      expect(chatInfo.stunUser, 'u');
      expect(chatInfo.stunPass, 'p');
    });

    test('没给就是空串（老端 `?? '
        '`），并且能整份存回本地', () {
      final chatInfo = ChatInfo.fromJson(const <String, dynamic>{'webrtc': 1});

      expect(chatInfo.stun, '');
      expect(chatInfo.stunUser, '');
      expect(chatInfo.stunPass, '');
      expect(chatInfo.toJson()['stun'], '');
    });

    test('相等判断把这三个字段算进去（配置热更新要能触发重建）', () {
      expect(const ChatInfo(stun: 'a') == const ChatInfo(stun: 'a'), isTrue);
      expect(const ChatInfo(stun: 'a') == const ChatInfo(stun: 'b'), isFalse);
      expect(
        const ChatInfo(stunUser: 'a').hashCode ==
            const ChatInfo(stunUser: 'a').hashCode,
        isTrue,
      );
    });

    test('整份 GlobalConfig 的往返（本地缓存里要留着）', () {
      final config = GlobalConfig.fromJson(<String, dynamic>{
        'chatInfo': <String, dynamic>{
          'stun': 'stun:site.example.com:3478',
          'stunUser': 'u',
          'stunPass': 'p',
        },
      });

      final restored = GlobalConfig.fromJson(config.toJson());

      expect(restored.chatInfo.stun, 'stun:site.example.com:3478');
      expect(restored.chatInfo.stunUser, 'u');
      expect(restored.chatInfo.stunPass, 'p');
      expect(restored, config);
    });
  });
}
