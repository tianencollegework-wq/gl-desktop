import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/domain/call/call_diagnostics.dart';
import 'package:gracelinkim/features/call/call_diagnostics_sheet.dart';

/// 通话诊断（S6.5 前的排查工具）：把「打不通」分成能动手修的那几类。
///
/// 全部是纯逻辑（不碰平台通道），所以能整体跑单测：候选类型、`getStats` 解析、
/// 一句话结论、时间线与导出文本。
void main() {
  group('候选类型', () {
    test('认得 host / srflx / relay / prflx（浏览器原样发过来的格式）', () {
      expect(
        iceCandidateKind(
          'candidate:842163049 1 udp 1677729535 203.0.113.7 54321 typ srflx '
          'raddr 0.0.0.0 rport 0',
        ),
        IceCandidateKind.srflx,
      );
      expect(
        iceCandidateKind(
          'candidate:1 1 udp 2130706431 192.168.1.5 5000 typ host',
        ),
        IceCandidateKind.host,
      );
      expect(
        iceCandidateKind('candidate:2 1 tcp 1518280447 10.0.0.2 9 typ relay'),
        IceCandidateKind.relay,
      );
      expect(
        iceCandidateKind('candidate:3 1 udp 1 1.2.3.4 5 typ prflx'),
        IceCandidateKind.prflx,
      );
      expect(iceCandidateKind(''), IceCandidateKind.unknown);
      expect(iceCandidateKind('随便一段文本'), IceCandidateKind.unknown);
    });
  });

  group('getStats 解析', () {
    test('选中候选对的类型 / RTT / 码率 / 丢包都读得出来', () {
      final sample = parseCallMediaSample(<StatsReport>[
        StatsReport('CP1', 'candidate-pair', 0, <dynamic, dynamic>{
          'selected': true,
          'state': 'succeeded',
          'localCandidateId': 'LC1',
          'remoteCandidateId': 'RC1',
          'protocol': 'udp',
          // libwebrtc 的原生单位是秒
          'currentRoundTripTime': 0.032,
        }),
        StatsReport('LC1', 'local-candidate', 0, <dynamic, dynamic>{
          'candidateType': 'srflx',
        }),
        StatsReport('RC1', 'remote-candidate', 0, <dynamic, dynamic>{
          'candidateType': 'host',
        }),
        StatsReport('OT1', 'outbound-rtp', 0, <dynamic, dynamic>{
          'kind': 'audio',
          'bytesSent': 12000,
        }),
        StatsReport('IT1', 'inbound-rtp', 0, <dynamic, dynamic>{
          'kind': 'audio',
          'bytesReceived': 9000,
          'packetsLost': 3,
          'jitter': 0.015,
        }),
        StatsReport('RI1', 'remote-inbound-rtp', 0, <dynamic, dynamic>{
          'packetsLost': 1,
        }),
      ]);

      expect(sample.localCandidateType, 'srflx');
      expect(sample.remoteCandidateType, 'host');
      expect(sample.protocol, 'udp');
      expect(sample.roundTripMs, 32);
      expect(sample.bytesSent, 12000);
      expect(sample.bytesReceived, 9000);
      expect(sample.packetsLost, 4, reason: '上下行丢包都算上');
      expect(sample.jitterMs, 15);
      expect(sample.relayed, isFalse);
      expect(sample.isEmpty, isFalse);
    });

    test('已经换算成毫秒的 RTT 不会再乘 1000（各平台版本不一致）', () {
      final sample = parseCallMediaSample(<StatsReport>[
        StatsReport('CP1', 'candidate-pair', 0, <dynamic, dynamic>{
          'selected': true,
          'currentRoundTripTime': 180,
        }),
      ]);
      expect(sample.roundTripMs, 180);
    });

    test('走 TURN 中转的候选对认得出来', () {
      final sample = parseCallMediaSample(<StatsReport>[
        StatsReport('CP1', 'candidate-pair', 0, <dynamic, dynamic>{
          'selected': true,
          'localCandidateId': 'LC1',
          'remoteCandidateId': 'RC1',
        }),
        StatsReport('LC1', 'local-candidate', 0, <dynamic, dynamic>{
          'candidateType': 'relay',
        }),
        StatsReport('RC1', 'remote-candidate', 0, <dynamic, dynamic>{
          'candidateType': 'srflx',
        }),
      ]);
      expect(sample.relayed, isTrue);
    });

    test('报表缺字段 / 是垃圾也不抛（诊断工具不能把通话搞崩）', () {
      final sample = parseCallMediaSample(<StatsReport>[
        StatsReport('X', 'something-else', 0, <dynamic, dynamic>{'a': 'b'}),
      ]);
      expect(sample.isEmpty, isTrue);
      expect(sample.roundTripMs, isNull);
      expect(sample.framesPerSecond, 0);
    });
  });

  group('一句话结论（面板最值钱的那行）', () {
    CallDiagnosticsRecorder recorder() =>
        CallDiagnosticsRecorder(clock: () => DateTime(2026, 9, 19, 21, 3, 12));

    test('还没通话', () {
      expect(recorder().snapshot().hint, '还没有通话记录');
    });

    test('一条候选都没有 → ICE 配置不合法 / 权限没给', () {
      final r = recorder()..begin(video: false, caller: true, peer: '老B');
      expect(r.snapshot().hint, contains('一条本机候选都没有'));
      expect(r.snapshot().hint, contains('stun:'));
    });

    test('只有 host → STUN 没起作用（站点那栏地址要检查）', () {
      final r = recorder()
        ..begin(video: false, caller: true, peer: '老B')
        ..localCandidate(
          'candidate:1 1 udp 2130706431 192.168.1.5 5000 typ host',
        );
      expect(r.snapshot().hint, contains('STUN 没起作用'));
    });

    test('有 srflx 还是连不上 → 就是缺 TURN（对称 NAT）', () {
      final r = recorder()
        ..begin(video: false, caller: true, peer: '老B')
        ..localCandidate(
          'candidate:1 1 udp 1 203.0.113.7 5000 typ srflx raddr 0 rport 0',
        );
      expect(r.snapshot().hint, contains('必须部署 TURN'));
    });

    test('连通了：直连 / 中转各有各的说法', () {
      final direct = recorder()
        ..begin(video: false, caller: true, peer: '老B')
        ..localCandidate(
          'candidate:1 1 udp 1 203.0.113.7 5000 typ srflx raddr 0 rport 0',
        )
        ..setConnected(true);
      expect(direct.snapshot().hint, contains('P2P'));

      final relayed = recorder()
        ..begin(video: false, caller: true, peer: '老B')
        ..localCandidate('candidate:1 1 tcp 1 10.0.0.2 9 typ relay')
        ..setConnected(true)
        ..sample(
          const CallMediaSample(
            localCandidateType: 'relay',
            remoteCandidateType: 'srflx',
          ),
        );
      expect(relayed.snapshot().hint, contains('TURN 中转'));
    });

    test('快照里的 connected 字段跟着 setConnected 走（面板配色靠它）', () {
      final r = recorder()..begin(video: false, caller: true, peer: '老B');
      expect(r.snapshot().connected, isFalse);
      r.setConnected(true);
      expect(r.snapshot().connected, isTrue);
      r.setConnected(false);
      expect(r.snapshot().connected, isFalse);
    });
  });

  group('结论那行的配色', () {
    test('绿=已连通；橙=没连上且走中转；灰=其它', () {
      // 以前这里是 `hint.contains('已连通')` —— 配色依赖文案，改个措辞就静默失效。
      // 现在只看 connected 字段，所以这里故意给一句**根本不含「已连通」**的 hint。
      const connected = CallDiagnostics(hint: '随便一句话', connected: true);
      expect(hintColorOf(connected), AppColors.green);

      const relayed = CallDiagnostics(
        hint: '还没连上（假装是这种措辞）',
        latestSample: CallMediaSample(localCandidateType: 'relay'),
      );
      expect(hintColorOf(relayed), AppColors.orange);

      const idle = CallDiagnostics(hint: '还没有通话记录');
      expect(hintColorOf(idle), AppColors.text666);
    });

    test('真采集器跑完一通：连通就是绿的（端到端串一遍）', () {
      final r = CallDiagnosticsRecorder()
        ..begin(video: false, caller: true, peer: '老B')
        ..localCandidate(
          'candidate:1 1 udp 1 203.0.113.7 5000 typ srflx raddr 0 rport 0',
        )
        ..setConnected(true);
      expect(hintColorOf(r.snapshot()), AppColors.green);
    });
  });

  group('采集器与导出', () {
    test('候选按类型计数、信令收发与失败都记下来', () {
      var now = DateTime(2026, 9, 19, 21, 0, 0);
      final r = CallDiagnosticsRecorder(clock: () => now)
        ..begin(
          video: true,
          caller: false,
          peer: '老B',
          iceServers: const <String>['stun:stun.example.com:3478（无账号）'],
        );

      expect(r.isRecording, isTrue);
      r
        ..localCandidate('candidate:1 1 udp 1 192.168.1.5 5000 typ host')
        ..localCandidate(
          'candidate:2 1 udp 1 203.0.113.7 5001 typ srflx raddr 0 rport 0',
        )
        ..remoteCandidate('candidate:9 1 udp 1 198.51.100.9 6000 typ host')
        ..signalSent('calling')
        ..signalSent('calling')
        ..signalSent('offer')
        ..signalFailed('hangup', 'timeout');

      final snapshot = r.snapshot();
      expect(snapshot.localCandidates[IceCandidateKind.host], 1);
      expect(snapshot.localCandidates[IceCandidateKind.srflx], 1);
      expect(snapshot.remoteCandidates[IceCandidateKind.host], 1);
      expect(snapshot.localCandidateCount, 2);
      expect(snapshot.remoteCandidateCount, 1);
      expect(snapshot.signals['calling'], 2);
      expect(snapshot.failedSignals['hangup'], 1);
      expect(snapshot.iceServers.single, contains('stun.example.com'));

      // 时间线：收到来电 → 那条失败
      expect(snapshot.events.first.label, '收到来电');
      expect(snapshot.events.last.label, contains('hangup 发送失败'));
      expect(snapshot.summary, contains('通话诊断 · 2026-09-19 21:00:00'));
      expect(snapshot.summary, contains('对端=老B'));
      expect(snapshot.summary, contains('信令：calling 2 / offer 1'));
      expect(snapshot.summary, contains('失败 hangup 1'));

      // 结束之后再记就晚了（finish 是幂等的，重复调用不会多记一条）
      now = now.add(const Duration(seconds: 35));
      r.finish(callTimeSeconds: 35);
      expect(r.isRecording, isFalse);
      r.finish(callTimeSeconds: 40);
      final finished = r.snapshot();
      expect(
        finished.events.where((e) => e.label.startsWith('通话结束')),
        hasLength(1),
      );
      expect(finished.summary, contains('通话结束（时长 00:00:35）'));
      expect(finished.hint, isNotEmpty, reason: '结束之后快照仍然留着');
    });

    test('建连接之后补记 ICE 列表（服务端签发的 TURN 凭据那时才并进来）', () {
      final r =
          CallDiagnosticsRecorder(clock: () => DateTime(2026, 9, 26, 10, 0, 0))
            ..begin(
              video: false,
              caller: true,
              peer: '老B',
              iceServers: const <String>['stun:stun.example.com:3478（无账号）'],
            );

      // 会话一起来只记到站内那一栏（换 TURN 凭据要等建连接那一步）
      expect(r.snapshot().iceServers.single, contains('stun.example.com'));

      r.updateIceServers(const <String>[
        'stun:stun.example.com:3478（无账号）',
        'turn:turn.cloudflare.com:3478?transport=udp（带账号）',
      ]);
      final snapshot = r.snapshot();
      expect(snapshot.iceServers, hasLength(2));
      expect(snapshot.iceServers.last, contains('turn.cloudflare.com'));
      expect(
        snapshot.summary,
        contains('turn.cloudflare.com'),
        reason: '导出的报告里也要看得到 TURN 到底有没有用上',
      );

      // 空列表 = 没变化：不能把已经记下来的擦掉
      r.updateIceServers(const <String>[]);
      expect(r.snapshot().iceServers, hasLength(2));
    });

    test('两次采样之间的字节差算出码率（3 秒 30KB ≈ 80kbps）', () {
      var now = DateTime(2026, 9, 19, 21, 0, 0);
      final r = CallDiagnosticsRecorder(clock: () => now)
        ..begin(video: false, caller: true, peer: '老B')
        ..sample(
          const CallMediaSample(
            bytesSent: 1000,
            bytesReceived: 2000,
            roundTripMs: 40,
          ),
        );

      now = now.add(const Duration(seconds: 3));
      r.sample(
        const CallMediaSample(
          bytesSent: 31000,
          bytesReceived: 32000,
          roundTripMs: 120,
        ),
      );

      final snapshot = r.snapshot();
      expect(snapshot.upstreamKbps, closeTo(80, 0.5));
      expect(snapshot.downstreamKbps, closeTo(80, 0.5));
      expect(snapshot.rttMinMs, 40);
      expect(snapshot.rttMaxMs, 120);
      expect(snapshot.sampleCount, 2);
    });

    test('ICE 服务器描述：没账号要标出来（站点那栏最容易填错）', () {
      expect(
        describeIceServers(<Map<String, dynamic>>[
          <String, dynamic>{
            'urls': <String>['stun:stun.cloudflare.com:3478'],
          },
          <String, dynamic>{
            'urls': 'turn:turn.example.com:3478?transport=udp',
            'username': 'u',
            'credential': 'p',
          },
        ]),
        <String>[
          'stun:stun.cloudflare.com:3478（无账号）',
          'turn:turn.example.com:3478?transport=udp（带账号）',
        ],
      );
    });
  });
}
