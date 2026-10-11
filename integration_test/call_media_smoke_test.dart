import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/domain/call/call_media_config.dart';
import 'package:integration_test/integration_test.dart';

/// 真机媒体自检（**不是单测**）。
///
/// 单测里媒体层永远是假的（`test/support/fake_call_media.dart`），真实 WebRTC
/// 只有设备能跑。这个文件用来定位「点接听就闪退」这类只在真机上出现的问题。
///
/// 跑法：
/// ```
/// flutter test integration_test/call_media_smoke_test.dart -d <设备号> --plain-name 'mode=xx'
/// ```
///
/// ## 2026-09-19 真机实测结论（三星 S23 Ultra / Android 14 / flutter_webrtc 1.6.2+hotfix.3）
///
/// 现象：点接听或点发起通话 → 应用直接闪退。系统日志：
/// ```
/// java.lang.NullPointerException:
///   Attempt to invoke virtual method 'java.util.List org.webrtc.PeerConnection.getTransceivers()'
///   on a null object reference
///   at PeerConnectionObserver.getTransceiversTrack(PeerConnectionObserver.java:1252)
///   at MethodCallHandlerImpl.getTrackForId(MethodCallHandlerImpl.java:1751)
///   at MethodCallHandlerImpl.getNextTrackUUID(MethodCallHandlerImpl.java:1675)
///   at GetUserMediaImpl.getUserAudio(GetUserMediaImpl.java:395)
///   at GetUserMediaImpl$2.invoke(GetUserMediaImpl.java:494)   ← 权限回调里
/// ```
///
/// 拆开验证后确认：**`createPeerConnection` 底层建连失败（返回 null）**，但插件照样
/// 回了一个 id；随后 `getUserMedia` 会遍历所有 PeerConnectionObserver，撞上这个
/// 「空连接」→ 不可捕获的 Java NPE → 闪退。
/// （`mode=z-cases` 里能看到 `DEAD: ... peerConnection is null`，那条路是 Dart 侧
/// 判断过的，所以不会崩；`getUserMedia` 那条路没判断，所以崩。）
///
/// 所以这个文件的价值：**以后任何一次媒体层改动，先跑一遍 `mode=minimal` +
/// `mode=site`，能在装包之前把「真机上根本建不起连接」这类问题挡住。**
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 站点真实配置（从真机里读出来的）：只有 stun 地址，没有账号密码
  const siteChatInfo = ChatInfo(stun: 'stun.cloudflare.com:3478');

  /// 建连接 + 取流（真实通话走的就是这两步）
  Future<void> openEngine(
    String label, {
    required List<Map<String, dynamic>> iceServers,
    bool video = false,
  }) async {
    final engine = WebrtcCallMediaEngine(iceServers: iceServers);
    try {
      await engine.open(video: video);
      final tracks = engine.localStream?.getTracks().length ?? 0;
      // ignore: avoid_print
      print('[SMOKE] $label OK tracks=$tracks');
      await engine.close();
      // ignore: avoid_print
      print('[SMOKE] $label closed');
    } catch (error) {
      // ignore: avoid_print
      print('[SMOKE] $label FAILED: $error');
      rethrow;
    }
  }

  /// 只建连接、不取流：建不起来时这里会**报错而不是崩溃**，能看清原因
  Future<void> probe(
    String label,
    List<Map<String, dynamic>> iceServers,
  ) async {
    // ignore: avoid_print
    print('[SMOKE] $label config=${jsonEncode(iceServers)}');
    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': iceServers,
    });
    try {
      final transceivers = await pc.getTransceivers();
      final offer = await pc.createOffer();
      // ignore: avoid_print
      print(
        '[SMOKE] $label ALIVE transceivers=${transceivers.length} '
        'offer=${offer.sdp?.length ?? 0}',
      );
    } catch (error) {
      // ignore: avoid_print
      print('[SMOKE] $label DEAD: $error');
    }
    await pc.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  /// 建连的对照组：找出「哪一套 ICE 清单会让底层建不起连接」
  final cases = <String, List<Map<String, dynamic>>>{
    // —— 单条目，都能过 ——
    'one-google': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>['stun:stun.l.google.com:19302'],
      },
    ],
    'one-xten-no-port': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>['stun:stun.xten.com'],
      },
    ],
    'one-cloudflare': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>['stun:stun.cloudflare.com:3478'],
      },
    ],
    'one-entry-publics': <Map<String, dynamic>>[
      <String, dynamic>{'urls': CallMediaConfig.publicStunUrls},
    ],
    // —— 两条目 ——
    'two-simple': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>['stun:stun.l.google.com:19302'],
      },
      <String, dynamic>{
        'urls': <String>['stun:stun.cloudflare.com:3478'],
      },
    ],
    'site-order': CallMediaConfig.iceServers(siteChatInfo),
    'site-order-reversed': CallMediaConfig.iceServers(
      siteChatInfo,
    ).reversed.toList(),
    'publics-then-cloudflare': <Map<String, dynamic>>[
      <String, dynamic>{'urls': CallMediaConfig.publicStunUrls},
      <String, dynamic>{
        'urls': <String>['stun:stun.cloudflare.com:3478'],
      },
    ],
    'publics-without-xten-then-cloudflare': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': CallMediaConfig.publicStunUrls
            .where((url) => !url.contains('xten'))
            .toList(),
      },
      <String, dynamic>{
        'urls': <String>['stun:stun.cloudflare.com:3478'],
      },
    ],
    'xten-then-cloudflare': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>['stun:stun.xten.com'],
      },
      <String, dynamic>{
        'urls': <String>['stun:stun.cloudflare.com:3478'],
      },
    ],
    'cloudflare-then-xten': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>['stun:stun.cloudflare.com:3478'],
      },
      <String, dynamic>{
        'urls': <String>['stun:stun.xten.com'],
      },
    ],
    // —— 一条条目里放全部（备选修法）——
    'one-entry-all': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>[
          ...CallMediaConfig.publicStunUrls,
          'stun:stun.cloudflare.com:3478',
        ],
      },
    ],
  };

  testWidgets('mode=z-cases：逐个配置建连接，看谁 DEAD', (tester) async {
    for (final entry in cases.entries) {
      await probe(entry.key, entry.value);
    }
  });

  testWidgets('mode=raw：只取麦克风，不建连接', (tester) async {
    final stream = await navigator.mediaDevices.getUserMedia(
      CallMediaConfig.localMediaConstraints(video: false),
    );
    // ignore: avoid_print
    print('[SMOKE] raw OK tracks=${stream.getTracks().length}');
    for (final track in stream.getTracks()) {
      await track.stop();
    }
  });

  testWidgets('mode=minimal：一个公共 STUN 走完整流程', (tester) async {
    await openEngine(
      'minimal',
      iceServers: <Map<String, dynamic>>[
        <String, dynamic>{
          'urls': <String>['stun:stun.l.google.com:19302'],
        },
      ],
    );
  });

  testWidgets('mode=site：站点配置走完整流程（修好后应当 OK）', (tester) async {
    await openEngine(
      'site',
      iceServers: CallMediaConfig.iceServers(siteChatInfo),
    );
  });

  testWidgets('mode=video：一个公共 STUN + 摄像头', (tester) async {
    await openEngine(
      'video',
      iceServers: <Map<String, dynamic>>[
        <String, dynamic>{
          'urls': <String>['stun:stun.l.google.com:19302'],
        },
      ],
      video: true,
    );
  });
}
