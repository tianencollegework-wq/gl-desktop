import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/domain/call/call_media_config.dart';
import 'package:integration_test/integration_test.dart';

/// iOS 的媒体自检（**不是单测**，要在设备/模拟器上跑）。
///
/// 为什么与安卓那份（`call_media_smoke_test.dart`）分开：那份的判据是
/// 「`engine.open()` 成功」，而 `open()` 里含**取麦克风**。CI 的 macOS runner 是
/// 虚拟机，很可能**没有音频输入设备** —— 在那种机器上，「取不到流」是环境事实，
/// 不是我们的 bug；把环境事实钉成永久红，比没有这条检查更坏。
///
/// 所以这份分成两段，判据完全不同：
///
/// 1. **建连（必须成功）**：`createPeerConnection` + `createOffer`。这条路不需要
///    任何音频设备，而它**正是安卓上真崩过的那条**（2026-09-19：底层建连返回
///    null、插件照样回一个 id，随后 `getUserMedia` 遍历 observer 撞上它 →
///    不可捕获的原生 NPE → 用户看到「点接听就闪退」，细节见安卓那份文件头）。
/// 2. **取流（有设备才跑）**：先 `enumerateDevices()` 看有没有 `audioinput`；
///    有 → 取一次、打印轨道数、释放（必须成功）；没有 → 打印一行说明就跳过。
///
/// 跑法：
/// ```
/// flutter test integration_test/ios_call_media_smoke_test.dart -d <设备号>
/// ```
///
/// ⚠️ 它**不**证明通话能打通：那还要信令与对端。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 与安卓那份同一份站点配置（真机里读出来的：只有 stun，没有账号密码）
  const siteChatInfo = ChatInfo(stun: 'stun.cloudflare.com:3478');

  void report(String line) {
    // ignore: avoid_print
    print('[IOS-MEDIA] $line');
  }

  testWidgets('建连：站点 ICE 清单能建出连接并生成 offer（安卓上崩过的就是这条）', (tester) async {
    final iceServers = CallMediaConfig.iceServers(siteChatInfo);
    report('ICE 清单=${iceServers.length} 条');

    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': iceServers,
    });
    try {
      final transceivers = await pc.getTransceivers();
      final offer = await pc.createOffer();
      report(
        'ALIVE transceivers=${transceivers.length} '
        'offer=${offer.sdp?.length ?? 0} 字节',
      );
      expect(offer.sdp, isNotNull, reason: '建得出连接就该给得出 offer');
      expect(offer.sdp!.length, greaterThan(0));
    } finally {
      // 收尾：不 dispose 会留下一条原生连接（下一个用例可能撞上它）
      await pc.dispose();
    }
  });

  testWidgets('取麦克风：有输入设备就取一次，没有就明确跳过（不是失败）', (tester) async {
    final devices = await navigator.mediaDevices.enumerateDevices();
    final inputs = devices.where((d) => d.kind == 'audioinput').toList();
    report('音频输入设备：${inputs.length} 个'
        '${inputs.isEmpty ? '（这台机器没有 → 跳过取流）' : ''}');

    if (inputs.isEmpty) {
      // CI 的 macOS runner 大概率落这里。**明确跳过**：既不假装通过，
      // 也不把「虚拟机没麦克风」记成我们的 bug。
      report('SKIP：这台机器没有音频输入设备，取流这一段不适用');
      return;
    }

    final stream = await navigator.mediaDevices.getUserMedia(
      CallMediaConfig.localMediaConstraints(video: false),
    );
    try {
      final tracks = stream.getTracks();
      report('取流 OK tracks=${tracks.length}');
      expect(tracks, isNotEmpty, reason: '说有设备就该真取得到轨道');
    } finally {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      report('麦克风已释放');
    }
  });
}
