import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/config/app_config.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/sfu_api.dart';
import 'package:gracelinkim/domain/group_call/sfu_failure.dart';
import 'package:shared_preferences/shared_preferences.dart';

const AppConfig _config = AppConfig(
  env: AppEnv.dev,
  scheme: 'https',
  host: 'example.test',
  hostToken: 'sha-hidden-bi',
);

/// 按路径返回预设报文，并记下每个请求的完整参数（与 session_service_test 同一套）
class _StubAdapter implements HttpClientAdapter {
  final Map<String, String> responses = <String, String>{};

  /// 给某些路径换一个 HTTP 状态码（默认 200）：验 5xx 也要翻成 SfuFailure
  final Map<String, int> statuses = <String, int>{};
  final List<RequestOptions> requests = <RequestOptions>[];

  Map<String, dynamic> bodyOf(String path) {
    final request = requests.firstWhere((item) => item.path == path);
    final data = request.data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String) return json.decode(data) as Map<String, dynamic>;
    return <String, dynamic>{};
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body =
        responses[options.path] ??
        json.encode(<String, dynamic>{'code': 0, 'msg': 'ok', 'data': null});
    return ResponseBody.fromString(
      body,
      statuses[options.path] ?? 200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _envelope(Object? data) =>
    json.encode(<String, dynamic>{'code': 0, 'msg': 'ok', 'data': data});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _StubAdapter adapter;
  late SfuApi api;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();

    adapter = _StubAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    api = SfuApi(
      ApiClient(
        config: _config,
        credentials: CredentialStore.instance,
        dio: dio,
      ),
    );
  });

  test('建会话：`{room_id, purpose}` → 读回 session_id', () async {
    adapter.responses['/enterprise/sfu/session'] = _envelope(<String, dynamic>{
      'session_id': 'sess-abc',
    });

    final sessionId = await api.createSession(
      roomId: 'g-100',
      purpose: 'publish',
    );

    expect(sessionId, 'sess-abc');
    expect(adapter.bodyOf('/enterprise/sfu/session'), <String, dynamic>{
      'room_id': 'g-100',
      'purpose': 'publish',
    });
  });

  test('发布：带上 track_name 与 mid，能读回 answer 与逐条结果', () async {
    adapter.responses['/enterprise/sfu/publish'] = _envelope(<String, dynamic>{
      'sdp': <String, dynamic>{'type': 'answer', 'answer': 'v=0 mic'},
      'requires_renegotiation': false,
      'tracks': <dynamic>[
        <String, dynamic>{'track_name': 'mic', 'mid': '0', 'status': 'active'},
        <String, dynamic>{
          'track_name': 'screen',
          'error_code': 'track_error',
          'error_description': 'unsupported',
        },
      ],
    });

    final result = await api.publish(
      sessionId: 'sess-abc',
      sdpOffer: 'v=0 offer',
      tracks: <Map<String, dynamic>>[
        <String, dynamic>{'track_name': 'mic', 'mid': '0'},
        <String, dynamic>{'track_name': 'screen', 'mid': '1'},
      ],
    );

    expect(adapter.bodyOf('/enterprise/sfu/publish'), <String, dynamic>{
      'session_id': 'sess-abc',
      'sdp_offer': 'v=0 offer',
      'tracks': <dynamic>[
        <String, dynamic>{'track_name': 'mic', 'mid': '0'},
        <String, dynamic>{'track_name': 'screen', 'mid': '1'},
      ],
    });
    expect(result.sdpAnswer, 'v=0 mic');
    expect(result.requiresRenegotiation, isFalse);
    expect(result.allTracksOk, isFalse, reason: '整包 200 但有一条 track 失败');
    expect(result.failedTracks.single.trackName, 'screen');
  });

  test('订阅：**不带本地 offer**，每条指向"发布者的会话 + track 名"，可一次多条', () async {
    adapter.responses['/enterprise/sfu/subscribe'] = _envelope(
      <String, dynamic>{
        'sdp': <String, dynamic>{'type': 'offer', 'offer': 'v=0 sfu-offer'},
        'requires_renegotiation': true,
        'tracks': <dynamic>[
          <String, dynamic>{
            'track_name': 'mic',
            'mid': 'recv-mid-0',
            'status': 'active',
          },
        ],
      },
    );

    final result = await api.subscribe(
      sessionId: 'sess-recv',
      tracks: <Map<String, dynamic>>[
        <String, dynamic>{'session_id': 'sess-pub-b', 'track_name': 'mic'},
      ],
    );

    expect(
      adapter.bodyOf('/enterprise/sfu/subscribe'),
      <String, dynamic>{
        'session_id': 'sess-recv',
        'tracks': <dynamic>[
          <String, dynamic>{'session_id': 'sess-pub-b', 'track_name': 'mic'},
        ],
      },
      reason: '订阅不带 sdp_offer：offer 是 SFU 反回来给我们的',
    );
    expect(result.sdpOffer, 'v=0 sfu-offer', reason: '要交给端点作答');
    expect(result.sdpAnswer, isNull, reason: '这条路径上没有我们的 answer 要交回');
    expect(result.requiresRenegotiation, isTrue);
    expect(
      result.tracks.single.mid,
      'recv-mid-0',
      reason: '接收侧的 mid 用来把 onTrack 收到的流认回谁的哪条 track',
    );
  });

  test('renegotiate：把端点 answer 交回去', () async {
    await api.renegotiate(sessionId: 'sess-recv', sdpAnswer: 'v=0 answer');

    expect(adapter.bodyOf('/enterprise/sfu/renegotiate'), <String, dynamic>{
      'session_id': 'sess-recv',
      'sdp_answer': 'v=0 answer',
    });
  });

  test('房间快照：成员 + 发布会话 + track 名 + epoch', () async {
    adapter.responses['/enterprise/sfu/room'] = _envelope(<String, dynamic>{
      'epoch': 7,
      'members': <dynamic>[
        <String, dynamic>{
          'user_id': 'u2',
          'session_id': 'sess-pub-b',
          'tracks': <dynamic>['mic', 'screen'],
        },
        <String, dynamic>{
          'user_id': 'u3',
          'session_id': '',
          'tracks': <dynamic>[],
        },
      ],
    });

    final state = await api.roomState(roomId: 'g-100');

    expect(adapter.bodyOf('/enterprise/sfu/room'), <String, dynamic>{
      'room_id': 'g-100',
    });
    expect(state.epoch, 7);
    expect(state.publishers.length, 1, reason: '没发布的人不算发布者');
    expect(state.publishers.single.userId, 'u2');
    expect(state.publishers.single.tracks, <String>['mic', 'screen']);
  });

  test('关 track（带协商）：offer + mids + force=false 原样交给服务端', () async {
    adapter.responses['/enterprise/sfu/close'] = _envelope(<String, dynamic>{
      'sdp': <String, dynamic>{'type': 'answer', 'answer': 'v=0 close-answer'},
      'tracks': <dynamic>[],
    });

    final result = await api.closeTracks(
      sessionId: 'sess-recv',
      mids: <String>['0'],
      sdpOffer: 'v=0 close-offer',
    );

    expect(adapter.bodyOf('/enterprise/sfu/close'), <String, dynamic>{
      'session_id': 'sess-recv',
      'mids': <dynamic>['0'],
      'sdp_offer': 'v=0 close-offer',
      'force': false,
    });
    expect(result.sdpAnswer, 'v=0 close-answer');
  });

  test('关 track（不做 SDP 交换）：force=true 时**不**带 sdp_offer', () async {
    adapter.responses['/enterprise/sfu/close'] = _envelope(<String, dynamic>{
      'tracks': <dynamic>[],
    });

    await api.closeTracks(
      sessionId: 'sess-recv',
      mids: <String>['1'],
      force: true,
    );

    expect(
      adapter.bodyOf('/enterprise/sfu/close'),
      <String, dynamic>{
        'session_id': 'sess-recv',
        'mids': <dynamic>['1'],
        'force': true,
      },
      reason: '拿不到可用 offer 时才走这条路，报文里不该出现空的 sdp_offer',
    );
  });

  test('心跳：带上房间号，读回版本号与人数', () async {
    adapter.responses['/enterprise/sfu/heartbeat'] = _envelope(
      <String, dynamic>{'epoch': 12, 'member_count': 4},
    );

    final beat = await api.heartbeat(roomId: 'g-100');

    expect(adapter.bodyOf('/enterprise/sfu/heartbeat'), <String, dynamic>{
      'room_id': 'g-100',
    });
    expect(beat.epoch, 12);
    expect(beat.memberCount, 4);
  });

  test('离开房间：带上自己的会话 id（默认不是收尾）', () async {
    await api.leave(
      roomId: 'g-100',
      sessionIds: <String>['sess-pub', 'sess-recv'],
    );

    expect(adapter.bodyOf('/enterprise/sfu/leave'), <String, dynamic>{
      'room_id': 'g-100',
      'session_ids': <dynamic>['sess-pub', 'sess-recv'],
      'closing': false,
    });
  });

  test('退出通话（closing）：服务端只会让一个人拿到 announce', () async {
    adapter.responses['/enterprise/sfu/leave'] = _envelope(<String, dynamic>{
      'closed': true,
      'announce': true,
      'duration': 765,
      'participants': 4,
    });

    final result = await api.leave(
      roomId: 'g-100',
      sessionIds: <String>['sess-pub', 'sess-recv'],
      closing: true,
    );

    expect(adapter.bodyOf('/enterprise/sfu/leave')['closing'], isTrue);
    expect(result.closed, isTrue);
    expect(result.announce, isTrue);
    expect(result.durationSeconds, 765);
    expect(result.participants, 4);
  });

  test('每一条控制面请求都带 30 秒的超时（不跟全局那 10 秒）', () async {
    // 为什么这条要单独钉：这条链每一跳都要服务端再走一趟 Cloudflare，
    // 2026-10-06 真机量到它拖到 2.7~30s。10 秒的超时会在**它其实会成功**的
    // 时候把发布会话判死 → 毒化 → 重建 → 更慢（真机原话：进房间失败：请求超时，
    // 而那时发布正在谈）。
    adapter.responses['/enterprise/sfu/room'] = _envelope(<String, dynamic>{
      'epoch': 1,
      'members': <dynamic>[],
    });
    adapter.responses['/enterprise/sfu/session'] = _envelope(<String, dynamic>{
      'session_id': 'sess-abc',
    });
    adapter.responses['/enterprise/sfu/heartbeat'] = _envelope(
      <String, dynamic>{'epoch': 1},
    );

    await api.createSession(roomId: 'g-100', purpose: 'publish');
    await api.roomState(roomId: 'g-100');
    await api.heartbeat(roomId: 'g-100');
    await api.leave(roomId: 'g-100', sessionIds: <String>[]);

    expect(adapter.requests, isNotEmpty);
    for (final request in adapter.requests) {
      expect(
        request.receiveTimeout,
        SfuApi.requestTimeout,
        reason: '${request.path} 的收超时',
      );
      expect(
        request.sendTimeout,
        SfuApi.requestTimeout,
        reason: '${request.path} 的发超时',
      );
    }
    expect(SfuApi.requestTimeout, greaterThan(const Duration(seconds: 5)));
  });

  test('服务端没交代（还没升级补丁 / 字段缺）：一律当成「还没结束」', () async {
    adapter.responses['/enterprise/sfu/leave'] = _envelope(<String, dynamic>{});

    final result = await api.leave(roomId: 'g-100', sessionIds: <String>[]);

    expect(result.closed, isFalse);
    expect(result.announce, isFalse);
    expect(result.durationSeconds, 0);
    expect(result.participants, 0);
  });

  group('失败必须翻成 SfuFailure（2026-10-08：不翻就永远不会重建会话）', () {
    // 这一组钉的是一个真机故障的**根因**：`SfuFailure.fromApiException` 写好了
    // 却一个调用点都没有，于是控制面抛出来的全是裸的 `BusinessException` /
    // `NetworkUnavailableException` —— 而房间状态机与会话队列**只认 SfuFailure**，
    // 「结果未知 → 换一条会话重建」这条路一步都走不到。
    test('订阅撞上服务端 4005（调 Cloudflare 超时）= 结果未知 → 要重建会话', () async {
      adapter.responses['/enterprise/sfu/subscribe'] = json.encode(<
        String,
        dynamic
      >{
        'code': 4005,
        'msg':
            '上游不可达（Operation timed out after 5000 milliseconds with 0 bytes received）',
        'data': null,
      });

      await expectLater(
        api.subscribe(
          sessionId: 'sess-recv',
          tracks: <Map<String, dynamic>>[
            <String, dynamic>{
              'session_id': 'sess-pub-u2',
              'track_name': 'screen',
            },
          ],
        ),
        throwsA(
          isA<SfuFailure>()
              .having((f) => f.kind, 'kind', SfuFailureKind.unknownOutcome)
              .having((f) => f.requiresRebuild, 'requiresRebuild', isTrue)
              .having((f) => f.code, 'code', 4005)
              .having((f) => f.label, 'label', 'subscribe'),
        ),
      );
    });

    test('被明确拒（4001）= 什么都没发生 → 会话还能用，不重建', () async {
      adapter.responses['/enterprise/sfu/publish'] = json.encode(
        <String, dynamic>{'code': 4001, 'msg': '上游说请求不合法', 'data': null},
      );

      await expectLater(
        api.publish(
          sessionId: 'sess-pub',
          sdpOffer: 'v=0',
          tracks: <Map<String, dynamic>>[
            <String, dynamic>{'track_name': 'mic', 'mid': 'mid-mic-1'},
          ],
        ),
        throwsA(
          isA<SfuFailure>()
              .having((f) => f.kind, 'kind', SfuFailureKind.rejected)
              .having((f) => f.requiresRebuild, 'requiresRebuild', isFalse)
              .having((f) => f.label, 'label', 'publish'),
        ),
      );
    });

    test('HTTP 5xx 也是「结果未知」（服务端可能已经生效了）', () async {
      adapter.responses['/enterprise/sfu/room'] = '{}';
      adapter.statuses['/enterprise/sfu/room'] = 500;

      await expectLater(
        api.roomState(roomId: 'g-100'),
        throwsA(
          isA<SfuFailure>()
              .having((f) => f.kind, 'kind', SfuFailureKind.unknownOutcome)
              .having((f) => f.label, 'label', 'room'),
        ),
      );
    });
  });
}
