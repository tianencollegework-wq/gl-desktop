import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/audio/call_tones.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
// 消息表的读写都是 extension，必须 import
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';
import 'package:gracelinkim/domain/call/call_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_call_media.dart';
import '../support/fake_call_ticker.dart';
import '../support/fake_web_socket.dart';
import '../support/test_database.dart';

/// 通话链路（S6.3）：WS 的 `webrtc` 事件 → 通话状态机 + 落一条通话记录。
///
/// 不跑界面：这里是「信令怎么进到状态机里」的那一层，
/// 用真 `WsService`（假通道）+ 假媒体层 + 真状态机/控制器。
void main() {
  // 语言包与 SharedPreferences 都要平台绑定（与 session_service_test 同）
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late StubAdapter adapter;
  late FakeWebSocketChannel channel;
  late WsService ws;
  late ProviderContainer container;
  late FakeCallMediaEngine media;
  late SilentCallTones tones;
  late ManualCallTicker ticker;

  /// 让 async 链路（事件分发、落库、发信令）跑完
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    adapter.ok('/enterprise/im/sendToMsg', data: <String, dynamic>{});
    media = FakeCallMediaEngine();
    tones = SilentCallTones();
    ticker = ManualCallTicker();

    channel = FakeWebSocketChannel();
    ws = await startTestWsService(channel);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(adapter.apiClient()),
        wsServiceProvider.overrideWithValue(ws),
        callMediaEngineProvider.overrideWithValue(media),
        callTonesProvider.overrideWithValue(tones),
        callTickerProvider.overrideWithValue(ticker),
      ],
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    // 服务端推 `webrtc` 时要有人接
    container.read(callSyncServiceProvider).start();
    await settle();
  });

  tearDown(() async {
    container.dispose();
    ws.dispose();
    await db.close();
  });

  /// 服务端推一条 `webrtc` 事件
  Future<void> push(Map<String, dynamic> data) async {
    channel.emit(jsonEncode(<String, dynamic>{'type': 'webrtc', 'data': data}));
    await settle();
  }

  /// 一条通话消息（老端的形态：事件/码/类型都在 `extends` 里）
  Map<String, dynamic> frame({
    required String event,
    String fromUserId = 'u2',
    String fromName = '老B',
    String toContactId = 'u1',
    String toUser = 'u2',
    String id = 'call-1',
    String msgId = 's1',
    int type = CallType.voice,
    int code = 0,
    int status = CallStatus.ringing,
    String sdp = '',
    Map<String, dynamic>? ice,
    bool isbtn = false,
    String content = '通话中',
  }) => <String, dynamic>{
    // 外层 `id` 就是**通话 id**（主叫那条自己造的 uuid），`msg_id` 是服务端业务 id；
    // 被叫之后的每一条信令都带同一个 `id`，状态机的「不是这通电话」判定靠它。
    'id': id,
    'msg_id': msgId,
    'fromUser': <String, dynamic>{
      'id': fromUserId,
      'realname': fromName,
      'avatar': 'https://a.test/$fromUserId.png',
    },
    'toContactId': toContactId,
    'toUser': toUser,
    'type': 'webrtc',
    'content': content,
    'sendTime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'is_group': 0,
    'at': <String>[],
    'extends': <String, dynamic>{
      'event': event,
      'type': type,
      'code': code,
      'status': status,
      'isbtn': isbtn,
      'sdp': sdp,
      'iceCandidate': ice == null ? '' : jsonEncode(ice),
    },
  };

  CallController controller() => container.read(callControllerProvider);

  List<Map<String, dynamic>> sentFrames() => adapter.requests
      .where((request) => request.path == '/enterprise/im/sendToMsg')
      .map((request) => request.data as Map<String, dynamic>)
      .toList();

  group('来电', () {
    test('收到 calling：进来电状态 + 响铃 + 落一条通话记录 + 补一条会话', () async {
      await push(frame(event: CallEvent.calling));

      final session = controller().session;
      expect(session.phase, CallPhase.incoming);
      expect(session.peerId, 'u2');
      expect(session.peerName, '老B');
      expect(session.peerAvatar, 'https://a.test/u2.png');
      expect(session.isCaller, isFalse);
      expect(session.messageId, 'call-1');
      // 电话没接之前不该去取麦克风
      expect(media.calls, isEmpty);
      expect(tones.ringStarts, 1);

      // 聊天里那条通话记录（老端 `appendMessage(res)`）
      final stored = await db.messagesFor('u2');
      expect(stored, hasLength(1));
      expect(stored.single.type, 'webrtc');
      expect(stored.single.msgId, 's1');
      expect(stored.single.content, '通话中');
      expect((await db.findConversation('u2'))?.lastType, 'webrtc');
    });

    test('接听后：回 acceptRtc（904），并开始计时', () async {
      await push(frame(event: CallEvent.calling));
      await controller().accept();
      await settle();

      expect(controller().session.phase, CallPhase.connecting);
      expect(tones.ringStops, greaterThanOrEqualTo(1));
      expect(media.calls, contains('open(video=false)'));
      expect(ticker.running, isTrue);

      final body = sentFrames().last;
      expect(body['event'], CallEvent.acceptRtc);
      expect(body['code'], CallCode.accept);
      expect(body['id'], 'call-1');
      expect(body['toContactId'], 'u2');
      expect(body['msg_id'], 's1');
    });

    test('对方挂断（906）：会话结束，本端不回枪', () async {
      await push(frame(event: CallEvent.calling));
      await controller().accept();
      await settle();
      final before = sentFrames().length;

      await push(
        frame(
          event: CallEvent.hangup,
          fromUserId: 'u2',
          toContactId: 'u1',
          code: CallCode.hangupInCall,
        ),
      );

      expect(controller().session.phase, CallPhase.ended);
      // 收到挂断不再回一条（老端 `isbtn` 那套：对端发来的挂断都没有 isbtn）
      expect(sentFrames(), hasLength(before));
      expect(controller().session.code, CallCode.hangupInCall);
    });
  });

  group('去电', () {
    test('自己那条 calling 的回显：落一条记录，但不当来电', () async {
      await push(
        frame(
          event: CallEvent.calling,
          fromUserId: 'u1',
          fromName: '我',
          toContactId: 'u2',
          toUser: 'u2',
        ),
      );

      final session = controller().session;
      expect(session.phase, CallPhase.idle);
      expect(tones.ringStarts, 0);
      expect(await db.messagesFor('u2'), hasLength(1));
    });

    test('对端忙线（907 的 hangup）：提示「对方忙~~」并结束', () async {
      // 先造出一通本端拨号中的电话
      await controller().start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await settle();
      expect(controller().session.isActive, isTrue);

      await push(
        frame(
          event: CallEvent.hangup,
          fromUserId: 'u2',
          toContactId: 'u1',
          id: controller().session.messageId,
          code: CallCode.busy,
        ),
      );

      expect(controller().session.phase, CallPhase.ended);
      expect(controller().session.code, CallCode.busy);
    });
  });

  group('各类信令与落库', () {
    test('只有 calling 落库：ICE 候选 / offer / answer 不落（否则聊天里会灌几十条）', () async {
      await push(frame(event: CallEvent.calling));
      expect(await db.messagesFor('u2'), hasLength(1));

      await push(frame(event: CallEvent.acceptRtc, code: CallCode.accept));
      await push(frame(event: CallEvent.offer, sdp: 'v=0-offer'));
      await push(frame(event: CallEvent.answer, sdp: 'v=0-answer'));
      await push(
        frame(
          event: CallEvent.iceCandidate,
          ice: <String, dynamic>{
            'candidate': 'candidate:1 1 udp 1 10.0.0.1 1 typ host',
            'sdpMLineIndex': 0,
            'sdpMid': '0',
          },
        ),
      );

      expect(await db.messagesFor('u2'), hasLength(1));
    });

    test('ICE 候选能解出来（服务端那边是 JSON 字符串）', () async {
      await push(frame(event: CallEvent.calling, toUser: 'u2'));
      // 候选只在「已接听」之后才有意义（状态机也只在 connecting/connected 时收）
      await controller().accept();
      await settle();
      await push(
        frame(
          event: CallEvent.iceCandidate,
          id: 'call-1',
          ice: <String, dynamic>{
            'candidate': 'candidate:1 1 udp 1 10.0.0.1 1 typ host',
            'sdpMLineIndex': 0,
            'sdpMid': '0',
          },
        ),
      );

      expect(media.addedCandidates, hasLength(1));
      expect(
        media.addedCandidates.single['candidate'],
        'candidate:1 1 udp 1 10.0.0.1 1 typ host',
      );
    });

    test('脏报文（没有 event / 没有 data）直接忽略，不抛异常', () async {
      await push(frame(event: ''));
      expect(controller().session.phase, CallPhase.idle);

      channel.emit('{"type":"webrtc"}');
      await settle();
      expect(controller().session.phase, CallPhase.idle);
    });
  });

  group('报文字段', () {
    test('fromUser 里 id / realname / displayName 三种写法都认', () async {
      final withDisplayName = parseCallSignal(<String, dynamic>{
        'id': 'call-9',
        'msg_id': 's9',
        'fromUser': <String, dynamic>{
          'user_id': 'u3',
          'displayName': '群里的阿强',
          'avatar': 'a.png',
        },
        'toContactId': 'u1',
        'extends': <String, dynamic>{'event': 'calling', 'type': 1},
      });
      expect(withDisplayName.fromUserId, 'u3');
      expect(withDisplayName.fromUserName, '群里的阿强');
      expect(withDisplayName.isVideo, isTrue);
      expect(withDisplayName.messageId, 'call-9');
      expect(withDisplayName.serverId, 's9');
    });

    test('没有 extends 时不会崩（event 空 → 上层忽略）', () {
      final signal = parseCallSignal(<String, dynamic>{'id': 'x'});
      expect(signal.event, isEmpty);
      expect(signal.code, 0);
      expect(signal.iceCandidate, isEmpty);
    });
  });
}
