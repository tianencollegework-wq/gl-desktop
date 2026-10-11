import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/features/login/qr_login_session.dart';

import '../support/fake_web_socket.dart';

/// 电脑端扫码登录的那一半（S12.17）。
///
/// 协议是**从服务端代码里逐条读出来的**（`app/worker/Events.php` 的
/// `case 'pong'`、`app/enterprise/controller/Im.php::tokenLogin`，以及网页端
/// `public/assets/js/app.*.js` 里那个 `Socket` 组件），这几条钉子就是那份协议：
///
/// 1. 连上（`init`）就要一张二维码 —— 发 `{type:pong, isQrLogin:true}`；
/// 2. 服务端回 `{type:codeLoginQr, qrurl}` —— 屏幕上画的就是它；
/// 3. 服务端每 60 秒一次的 `ping` 也要回同样一句（那就是换一张新码）；
/// 4. 手机确认之后服务端推 `{type:tokenLogin, data}` —— 那里面才是登录态。
void main() {
  /// 让 async 链路（连接就绪、事件分发）跑完
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<Map<String, dynamic>> sentFrames(FakeWebSocketChannel channel) => channel
      .sent
      .map((frame) => json.decode(frame as String))
      .cast<Map<String, dynamic>>()
      .toList();

  Future<void> emit(FakeWebSocketChannel channel, Map<String, dynamic> frame) {
    channel.emit(jsonEncode(frame));
    return settle();
  }

  test('连上就报「我要扫码登录」，服务端回的 qrurl 直接当二维码用', () async {
    final channel = FakeWebSocketChannel();
    final session = QrLoginSession(
      url: 'ws://test.local/wss',
      connector: (_) => channel,
      onLogin: (_) async {},
    );
    addTearDown(session.dispose);

    expect(session.state.value.phase, QrLoginPhase.connecting);
    session.start();
    await settle();

    // 服务端 `init`（带回 client_id）—— 收到就问二维码
    await emit(channel, <String, dynamic>{'type': 'init', 'client_id': 'c-1'});
    expect(
      sentFrames(channel).last,
      <String, dynamic>{'type': 'pong', 'isQrLogin': true},
      reason: '服务端只在收到这一句时才生成二维码（Events.php 的 case pong）',
    );

    // 二维码来了：**原样用服务端那句**（地址、加密 token 都在里面）
    await emit(channel, <String, dynamic>{
      'type': 'codeLoginQr',
      'qrurl': 'https://im.example.test/scan/a/d6b5ZRQ%2Bazv',
    });
    expect(session.state.value.phase, QrLoginPhase.waiting);
    expect(
      session.state.value.qrUrl,
      'https://im.example.test/scan/a/d6b5ZRQ%2Bazv',
    );
  });

  test('服务端的 ping（每 60 秒）也回同一句 —— 那就是换一张新码', () async {
    final channel = FakeWebSocketChannel();
    final session = QrLoginSession(
      url: 'ws://test.local/wss',
      connector: (_) => channel,
      onLogin: (_) async {},
    );
    addTearDown(session.dispose);

    session.start();
    await settle();
    await emit(channel, <String, dynamic>{'type': 'init', 'client_id': 'c-1'});
    await emit(channel, <String, dynamic>{
      'type': 'codeLoginQr',
      'qrurl': 'https://im.example.test/scan/a/first',
    });
    final before = sentFrames(channel).length;

    await emit(channel, <String, dynamic>{'type': 'ping'});
    expect(sentFrames(channel).length, before + 1);
    expect(sentFrames(channel).last['isQrLogin'], isTrue);

    // 新的一张码覆盖屏幕上的那张
    await emit(channel, <String, dynamic>{
      'type': 'codeLoginQr',
      'qrurl': 'https://im.example.test/scan/a/second',
    });
    expect(session.state.value.qrUrl, 'https://im.example.test/scan/a/second');
  });

  test('手机确认：tokenLogin 推来就把登录态交出去，状态变 confirmed', () async {
    final channel = FakeWebSocketChannel();
    Map<String, dynamic>? loginData;
    final session = QrLoginSession(
      url: 'ws://test.local/wss',
      connector: (_) => channel,
      onLogin: (data) async => loginData = data,
    );
    addTearDown(session.dispose);

    session.start();
    await settle();
    await emit(channel, <String, dynamic>{'type': 'init', 'client_id': 'c-1'});
    await emit(channel, <String, dynamic>{
      'type': 'codeLoginQr',
      'qrurl': 'https://im.example.test/scan/a/abc',
    });
    expect(session.state.value.phase, QrLoginPhase.waiting);

    await emit(channel, <String, dynamic>{
      'type': 'tokenLogin',
      'data': <String, dynamic>{
        'sessionId': 'sid-1',
        'authToken': 'tok-qr',
        'userInfo': <String, dynamic>{'user_id': '7'},
      },
    });

    expect(loginData, isNotNull);
    expect(loginData!['authToken'], 'tok-qr');
    expect(session.state.value.phase, QrLoginPhase.confirmed);
  });

  test('连接断开：状态变 failed（可以让用户点「刷新二维码」重来）', () async {
    final channel = FakeWebSocketChannel();
    final session = QrLoginSession(
      url: 'ws://test.local/wss',
      connector: (_) => channel,
      onLogin: (_) async {},
    );
    addTearDown(session.dispose);

    session.start();
    await settle();
    await emit(channel, <String, dynamic>{'type': 'init', 'client_id': 'c-1'});
    await emit(channel, <String, dynamic>{
      'type': 'codeLoginQr',
      'qrurl': 'https://im.example.test/scan/a/abc',
    });

    await channel.closeIncoming();
    await settle();
    expect(session.state.value.phase, QrLoginPhase.failed);
    expect(session.state.value.message, isNotEmpty);
  });
}
