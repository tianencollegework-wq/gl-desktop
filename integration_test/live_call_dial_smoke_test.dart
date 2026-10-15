// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';
import 'package:gracelinkim/domain/call/call_sync_service.dart';
import 'package:gracelinkim/domain/session/session_service.dart';
import 'package:integration_test/integration_test.dart';

/// **真拨一通电话**（不是单测，也不是「建连自检」）。
///
/// 与 `docs/release/ios-plan.md` 第十一节那条「真机行为一件都没验」对着干的就是它：
/// 别的自检只能证明「建得起来、取得到麦克风」，**接通这件事必须有第二个人在电话那头**。
/// 所以这条用例把对端当黑盒：它只负责拨号，然后等状态机自己走到 `connected`。
///
/// 判据分两层，缺一不可：
///
/// 1. **信令接通**：状态机进入 `CallPhase.connected`（对方真的按了接听、SDP 交换完）；
/// 2. **媒体在动**：`sampleStats()` 里的收/发字节数 **> 0**。
///    光看第 1 层会被「接通了但一个字节都没传」骗过去 —— 那正是「能打通但听不到声音」。
///
/// 凭据**只从 `--dart-define` 读，绝不落盘**（这个仓库是公开的，写进文件等于公开泄密）：
///
/// ```
/// flutter test integration_test/live_call_dial_smoke_test.dart -d windows \
///   --dart-define=LIVE_ACCOUNT=你的测试号 \
///   --dart-define=LIVE_PASSWORD=... \
///   --dart-define=LIVE_PEER_ID=22 \
///   --dart-define=LIVE_PEER_NAME='好友昵称' \
///   --dart-define=LIVE_READY_SECONDS=25
/// ```
///
/// 没给凭据（比如 CI 上没配 Secrets）就**明确跳过**：既不假装通过，也不把
/// 「这台机器没有账号」记成一片红。
///
/// ⚠️ 对端必须是**人**（App 开着、能按接听）。所以它天生不能无人值守地跑 ——
/// 想全自动，得有两个号，各登一台设备（那时把这条用例复制一份、把拨号/接听
/// 分到两条进程里）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const account = String.fromEnvironment('LIVE_ACCOUNT');
  const password = String.fromEnvironment('LIVE_PASSWORD');
  const peerId = String.fromEnvironment('LIVE_PEER_ID');
  const peerName = String.fromEnvironment('LIVE_PEER_NAME', defaultValue: '对端');
  const video = bool.fromEnvironment('LIVE_VIDEO');
  const readySeconds = int.fromEnvironment(
    'LIVE_READY_SECONDS',
    defaultValue: 20,
  );
  const talkSeconds = int.fromEnvironment('LIVE_TALK_SECONDS', defaultValue: 8);
  const dialSeconds = int.fromEnvironment(
    'LIVE_DIAL_SECONDS',
    defaultValue: 75,
  );

  void report(String line) => print('[LIVE] $line');

  /// 有上限地轮询一个条件（不用 `pumpAndSettle`：长连接与定时器常驻，settle 永远不返回）
  Future<bool> waitFor(
    bool Function() check,
    Duration limit, {
    String label = '',
  }) async {
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      if (check()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final ok = check();
    if (!ok && label.isNotEmpty) report('$label：等超时了（${limit.inSeconds}s）');
    return ok;
  }

  testWidgets(
    '真拨一通：登录 → 拨号 → 等对方接听 → 媒体有没有在动',
    timeout: const Timeout(Duration(minutes: 10)),
    (tester) async {
      if (account.isEmpty || password.isEmpty || peerId.isEmpty) {
        report(
          'SKIP：没给 LIVE_ACCOUNT / LIVE_PASSWORD / LIVE_PEER_ID（都是 --dart-define），'
          '这条用例没跑 —— 不是通过，是没跑',
        );
        return;
      }

      // 生产路径：本机存储 + 语言包（提示音、toast 都要它）
      await CredentialStore.init();
      await AppI18n.load('zh-Hans');

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final ws = container.read(wsServiceProvider);
      final session = container.read(sessionServiceProvider);
      await session.bootstrap();
      // 通话信令的入站处理器（calling / acceptRtc / offer / answer / ICE 都走它）
      container.read(callSyncServiceProvider).start();

      // bindUid 与随后的 calling 都要走这条长连接，所以先等它起来
      final connected = await waitFor(
        () => ws.isConnected,
        const Duration(seconds: 40),
        label: '长连接',
      );
      report('长连接 = ${connected ? '就绪' : '没连上'}');

      final user = await session.login(account: account, password: password);
      report('登录成功：${user.displayName}（id=${user.userId}）');

      // bindUid 是登录成功后立刻发出去的（服务端靠它才知道这条连接是谁）
      await Future<void>.delayed(const Duration(seconds: 2));

      final controller = container.read(callControllerProvider);
      var lastPhase = controller.session.phase;
      controller.view.addListener(() {
        final phase = controller.session.phase;
        if (phase == lastPhase) return;
        report('阶段：${lastPhase.name} → ${phase.name}');
        lastPhase = phase;
      });

      // 给对端一点准备时间：这条用例拨的是**真人**
      report('$readySeconds 秒后开始拨号 —— 请让「$peerName」打开 App 等着接听');
      for (var left = readySeconds; left > 0; left -= 5) {
        report('倒计时 ${left}s');
        await Future<void>.delayed(const Duration(seconds: 5));
      }

      try {
        await controller
            .start(
              peerId: peerId,
              peerName: peerName,
              type: video ? CallType.video : CallType.voice,
              // 站点开关：这台是生产路径，两项都开着（关掉的话状态机会直接拒绝拨号）
              webrtcEnabled: true,
              simpleChatEnabled: true,
            )
            // 硬时限（与 `ios_call_media_smoke_test.dart` 里那套同一个理由）：
            // 无头模拟器上系统权限框没人点，取麦克风会**一直等**。上一回那条用例
            // 就是因此白等 28 分钟被杀、注解都来不及发。卡住要**当场说清卡在哪一步**。
            .timeout(
              const Duration(seconds: 90),
              onTimeout: () => throw TimeoutException(
                '「发起拨号」超过 90 秒没返回 —— 最可能是取麦克风那一步在等一个'
                '没人点的系统权限框，或者信令通道没发出去',
              ),
            );
        report('已发出 calling（本机阶段=${controller.session.phase.name}）');
      } on TimeoutException catch (error) {
        // 不在这里直接抛：还得把状态机收干净（挂断），并在下面把「阶段」行打完 ——
        // 那几行才是判断卡在哪一步的唯一线索
        report('拨号没起来：$error');
      }

      // 等接通：结束（被拒/挂断/超时）也立刻收场，别干等到超时
      var outcome = '超时';
      final deadline = DateTime.now().add(Duration(seconds: dialSeconds));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final phase = controller.session.phase;
        if (phase == CallPhase.connected) {
          outcome = '接通';
          break;
        }
        if (phase == CallPhase.ended || phase == CallPhase.idle) {
          outcome = '结束（${phase.name}）';
          break;
        }
      }
      report('结果 = $outcome（最后阶段=${controller.session.phase.name}）');

      // 接通了就量一次媒体：有字节在流动才算「真的有声音在传」
      var sent = 0;
      var received = 0;
      if (outcome == '接通') {
        report('接通后听 $talkSeconds 秒再量一次');
        await Future<void>.delayed(Duration(seconds: talkSeconds));
        final stats = await container
            .read(callMediaEngineProvider)
            .sampleStats();
        sent = stats.bytesSent;
        received = stats.bytesReceived;
        report(
          '媒体统计：发出=$sent 字节 收到=$received 字节 '
          'RTT=${stats.roundTripMs}ms 丢包=${stats.packetsLost} '
          '候选=${stats.localCandidateType}→${stats.remoteCandidateType}',
        );
        report('现在可以挂了');
        await Future<void>.delayed(const Duration(seconds: 2));
      }

      await controller.hangup();
      report('已挂断（阶段=${controller.session.phase.name}）');

      expect(
        outcome,
        '接通',
        reason:
            '$dialSeconds 秒内没接通 —— 看上面每一行「阶段：」，'
            '它说明卡在哪一步（拨不出去 / 对方没接 / 信令来了本机没动）',
      );
      expect(
        sent + received,
        greaterThan(0),
        reason:
            '接通了但一个字节都没传 —— 这是「能打通但听不到声音」，'
            '比没接通更隐蔽，必须当成失败',
      );
    },
  );
}
