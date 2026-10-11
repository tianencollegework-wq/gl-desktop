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
import 'package:gracelinkim/data/model/app_setting.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';
import 'package:gracelinkim/domain/call/call_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_call_ticker.dart';
import '../support/fake_web_socket.dart';
import '../support/test_database.dart';

/// 通话控制器的**生命周期**（S8.1k）。
///
/// 这一组是 2026-09-20 真机上那个故障的回归保护：
/// 「被推送叫醒的来电：响一声就断、界面卡死、点接听没反应」。
///
/// 根因不在推送，而在 provider 的依赖图：`callMediaEngineProvider` 过去用
/// `ref.watch(sessionStoreProvider)` 盯**整份**会话状态，于是任何会话变化
/// （站点配置热更新 / 多端标记 / 改设置）都会重建引擎 —— 而
/// `callControllerProvider` watch 了引擎，**正在进行的通话被整个重建**：
/// 控制器被 dispose（`dispose()` 里会 `tones.stopRing()`、关媒体、`view.dispose()`），
/// 通话页挂在旧控制器上再也不会更新，页面上那颗「接听」也点不动
/// （回调里迟到的 `ref.read` 撞上「Ref … after it has been disposed」）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late StubAdapter adapter;
  late FakeWebSocketChannel channel;
  late WsService ws;
  late ProviderContainer container;
  late SilentCallTones tones;
  late ManualCallTicker ticker;

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
    tones = SilentCallTones();
    ticker = ManualCallTicker();

    channel = FakeWebSocketChannel();
    ws = await startTestWsService(channel);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(adapter.apiClient()),
        wsServiceProvider.overrideWithValue(ws),
        // ⚠️ **刻意不替换 `callMediaEngineProvider`**：被替掉了就测不到「它盯了
        // 整份会话状态」这个真 bug（真机故障的根就在这个 provider 上）。
        // 真引擎在构造时不碰任何平台 API（建连接是通话开始后才发生的事）。
        callTonesProvider.overrideWithValue(tones),
        callTickerProvider.overrideWithValue(ticker),
      ],
    );
    container.read(callSyncServiceProvider).start();
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await settle();
  });

  tearDown(() async {
    container.dispose();
    ws.dispose();
    await db.close();
  });

  CallController controller() => container.read(callControllerProvider);

  /// 服务端推一条 `webrtc` 事件进来
  Future<void> push(Map<String, dynamic> data) async {
    channel.emit(jsonEncode(<String, dynamic>{'type': 'webrtc', 'data': data}));
    await settle();
  }

  /// 一条来电（老端的形态：事件/码/类型都在 `extends` 里）
  Map<String, dynamic> calling({String id = 'call-1'}) => <String, dynamic>{
    'id': id,
    'msg_id': 'srv-1',
    'fromUser': <String, dynamic>{
      'id': 'u2',
      'realname': '老B',
      'avatar': 'https://a.test/u2.png',
    },
    'toContactId': 'u1',
    'toUser': 'u2',
    'type': 'webrtc',
    'content': '通话中',
    'sendTime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'is_group': 0,
    'at': <String>[],
    'extends': <String, dynamic>{
      'event': CallEvent.calling,
      'type': CallType.voice,
      'code': CallCode.dialing,
      'status': CallStatus.ringing,
      'sdp': '',
      'iceCandidate': '',
    },
  };

  /// 来一通电话并返回「当初那个控制器」
  Future<CallController> ring() async {
    final before = controller();
    await push(calling());
    expect(before.session.phase, CallPhase.incoming, reason: '来电没进来');
    return before;
  }

  group('会话状态的小变化不能把正在进行的通话打掉', () {
    test('多端在线标记变化', () async {
      final before = await ring();

      container.read(sessionStoreProvider.notifier).applyMultiport(true);
      await settle();

      expect(
        identical(controller(), before),
        isTrue,
        reason: '多端标记变化把控制器重建了 —— 真机上就是「响一声就断、界面卡死」',
      );
      expect(controller().session.phase, CallPhase.incoming);
    });

    test('本地设置变化（新消息声音 / 圆形头像这类）', () async {
      final before = await ring();

      container
          .read(sessionStoreProvider.notifier)
          .applySetting(AppSetting.defaults.copyWith(voiceStatus: false));
      await settle();

      expect(identical(controller(), before), isTrue);
      expect(controller().session.phase, CallPhase.incoming);
    });

    test('通话期间页面能正常开关小窗（这条也走 view，不该被重建）', () async {
      final before = await ring();

      await controller().minimizeToPip();
      await settle();

      expect(identical(controller(), before), isTrue);
      expect(controller().session.phase, CallPhase.incoming);
    });

    test('只有换账号（user_id 变了）才重建控制器', () async {
      final before = await ring();

      container
          .read(sessionStoreProvider.notifier)
          .applyLogin(const UserInfo(userId: 'u9', displayName: '别人'));
      await settle();

      expect(identical(controller(), before), isFalse);
      expect(controller().session.phase, CallPhase.idle, reason: '新账号不该接着旧的那通');
    });
  });

  group('已经放掉的控制器：点它也不许抛异常（真机上就是这么卡住的）', () {
    test('接听 / 挂断 / 收信令 都是空操作', () async {
      final before = await ring();
      // 换账号 → 旧控制器被 dispose
      container
          .read(sessionStoreProvider.notifier)
          .applyLogin(const UserInfo(userId: 'u9', displayName: '别人'));
      await settle();

      // 一条 Unhandled Exception 都不许有；这里只要不抛就算过
      await before.accept();
      await before.hangup();
      await before.remote(
        CallSignal.fromExtends(
          <String, dynamic>{'event': CallEvent.calling},
          messageId: 'call-2',
          toContactId: 'u9',
        ),
      );
      await settle();

      expect(controller().session.phase, CallPhase.idle);
    });

    test('放掉之后再来的信令也进不了新控制器（不能把新账号拖进旧通话）', () async {
      await ring();
      container
          .read(sessionStoreProvider.notifier)
          .applyLogin(const UserInfo(userId: 'u9', displayName: '别人'));
      await settle();

      // 旧通话的后续信令（同一个 id）
      await push(<String, dynamic>{
        ...calling(id: 'call-1'),
        'toContactId': 'u9',
        'extends': <String, dynamic>{
          'event': CallEvent.hangup,
          'type': CallType.voice,
          'code': CallCode.hangupInCall,
        },
      });

      expect(controller().session.phase, CallPhase.idle);
    });
  });
}
