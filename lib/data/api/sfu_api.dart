import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import '../../core/net/api_exception.dart';
import '../../core/util/json_value.dart';
import '../../domain/group_call/sfu_failure.dart';
import '../../domain/group_call/sfu_transport.dart';
import '../model/sfu_models.dart';
import 'endpoints.dart';

/// 群通话（Cloudflare Realtime SFU）的控制面，对应 `docs/protocol/sfu-group-call.md`。
///
/// 为什么全部经我们自己的服务端、而不是客户端直连 Cloudflare：
/// 1. **App Secret 是一把账号级的长期钥匙**（CF 只认 `Authorization: Bearer <APP_SECRET>`，
///    没有给客户端用的短时令牌），放进 APK 就等于公开，且没法轮换；
/// 2. CF 官方明说 **session id / track name 都不代表权限**，"谁能请求"必须由应用自己判
///    —— 群通话要判"你是不是这个群的成员"，这个判断只能在服务端做；
/// 3. 订阅要用"发布者的 sessionId + trackName"，而 CF **不提供房间发现**，
///    这份映射本来就得我们的服务端维护。既然这层省不掉，密钥与权限就一起放在那儿。
///
/// 注意：**媒体不经过这里**。音视频是端点 ↔ Cloudflare 直连，这里只走几百字节的 SDP。
///
/// 它 `implements [SfuControlPlane]`：这样真实实现与测试里的假实现**必须签名一致**，
/// 否则两边会各写一套、契约悄悄漂移（房间状态机只对接口编程）。
class SfuApi implements SfuControlPlane {
  const SfuApi(this._client);

  final ApiClient _client;

  /// 群通话控制面的 HTTP 超时（**不跟全局那 10 秒**）。
  ///
  /// 这条链每一跳都要我们的服务端再走一趟 Cloudflare，而服务端自己那条上游
  /// 超时是 5s —— 正常几百毫秒，服务端一抖就是十几秒起。2026-10-06 真机量到的
  /// 数字：源站上连 `/common/pub/checkVersion` 都要 1.7~6.3s，`sfu/room`
  /// 2.7~30s（还有一次整整 30s 无响应）。
  ///
  /// 10 秒的全局超时会在**服务端其实会成功**的时候把这一跳判死，代价极大：
  /// 发布会话被判死 → 会话毒化 → 重建 → 再建会话 / 再发布 / 再订阅，每一步
  /// 又是几秒的往返，于是「服务端慢」直接变成「连不上」（真机上抓到的原话：
  /// `进房间失败：NetworkUnavailableException(请求超时)`，而那时发布正在谈）。
  ///
  /// 30s 也**大于服务端自己的上游超时（5s）**：正常会先拿到它的业务错误码
  /// （4005 = 结果未知，要重建），而不是本端一句含糊的「网络不可用」。
  static const Duration requestTimeout = Duration(seconds: 30);

  /// **把 HTTP 层的失败翻成 `SfuFailure`**（被拒 / 结果未知 / 会话没了 / 要重登）。
  ///
  /// 为什么必须在这一层翻（2026-10-08 查实的真机故障）：房间状态机与
  /// `SfuSessionQueue` 全部只认 `SfuFailure` —— 「结果未知」走到它们那里才会
  /// 触发"会话不可信 → 换一条会话重建"。而这里以前是**裸着往上抛**
  /// `BusinessException` / `NetworkUnavailableException`：
  /// * `on SfuFailure catch` 一条都进不去 → 不重建、不毒化；
  /// * 调用方只看到一句业务错误，重试继续打在**同一条已经不可信的会话**上。
  ///
  /// 真机上的样子：服务端调 Cloudflare 那一跳 5 秒超时（4005）之后，手机端
  /// 两分钟里每次对账都在订同一条会话、每次都超时，而用户手动"退出再重进"
  /// （等于换了一条新会话）**立刻就好**。
  Future<T> _guard<T>(String label, Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException catch (error) {
      throw SfuFailure.fromApiException(error, label: label);
    }
  }

  /// 建一条会话（发布会话 / 接收会话各一条）。
  ///
  /// 返回的只是一个 id：CF 侧"建了会话"不等于"连接建立了"，还要靠第一次
  /// `publish` / `subscribe` 里的 SDP 交换把连接谈起来。
  @override
  Future<String> createSession({
    required String roomId,
    required String purpose,
  }) => _guard<String>('session', () async {
    final data = await _client.postMap(
      SfuPaths.session,
      data: <String, dynamic>{'room_id': roomId, 'purpose': purpose},
      notify: false,
      timeout: requestTimeout,
    );
    return asText(data['session_id'] ?? data['sessionId']);
  });

  /// 发布自己的 track（`location: "local"`）。
  ///
  /// [tracks] 是 `{track_name, mid}`：mid 是本端 offer 里那条 transceiver 的 mid。
  /// 共享屏就是在同一个发布会话上再加一条 `screen`。
  @override
  Future<SfuExchangeResult> publish({
    required String sessionId,
    required String sdpOffer,
    required List<Map<String, dynamic>> tracks,
  }) => _guard<SfuExchangeResult>('publish', () async {
    final data = await _client.postMap(
      SfuPaths.publish,
      data: <String, dynamic>{
        'session_id': sessionId,
        'sdp_offer': sdpOffer,
        'tracks': tracks,
      },
      notify: false,
      timeout: requestTimeout,
    );
    return SfuExchangeResult.fromJson(data);
  });

  /// 订阅别人的 track（`location: "remote"`）。
  ///
  /// [tracks] 每条是 `{session_id, track_name}` —— 来自房间快照
  /// （**发布者的发布会话 id + 他发布的 track 名**）。
  ///
  /// **这里不带本地 offer**：订阅是 SFU 反过来发 offer，端点作答后再走
  /// [renegotiate] 把 answer 交回去（与发布不对称，见
  /// `docs/protocol/sfu-group-call.md` 的 connection patterns）。
  ///
  /// 一次请求可以带多条、也可以跨发布者（CF 上限 64）：9 人房间一次就订阅完全屋。
  /// 响应里**每条 track 的 `mid` 是接收侧分配的** —— 客户端靠它把收到的流
  /// 对上「谁的哪条 track」（`onTrack` 里的 `event.transceiver.mid`）。
  @override
  Future<SfuExchangeResult> subscribe({
    required String sessionId,
    required List<Map<String, dynamic>> tracks,
  }) => _guard<SfuExchangeResult>('subscribe', () async {
    final data = await _client.postMap(
      SfuPaths.subscribe,
      data: <String, dynamic>{'session_id': sessionId, 'tracks': tracks},
      notify: false,
      timeout: requestTimeout,
    );
    return SfuExchangeResult.fromJson(data);
  });

  /// 关掉某条会话上的 track（停止订阅 / 停止发布 / 停共享屏）。
  ///
  /// 带 [mids] 与一个**重新出的本地 offer**（先 `stop()` 掉那些 transceiver）；
  /// 拿不到可用 offer 时才用 `force: true` 直接关（不做 SDP 交换）。
  @override
  Future<SfuExchangeResult> closeTracks({
    required String sessionId,
    required List<String> mids,
    String? sdpOffer,
    bool force = false,
  }) => _guard<SfuExchangeResult>('close', () async {
    final data = await _client.postMap(
      SfuPaths.closeTracks,
      data: <String, dynamic>{
        'session_id': sessionId,
        'mids': mids,
        'sdp_offer': ?sdpOffer,
        'force': force,
      },
      notify: false,
      timeout: requestTimeout,
    );
    return SfuExchangeResult.fromJson(data);
  });

  /// 把端点的 answer 交回给 CF（CF 主动发 offer 时走这条）。
  @override
  Future<void> renegotiate({
    required String sessionId,
    required String sdpAnswer,
  }) => _guard<void>(
    'renegotiate',
    () => _client.postVoid(
      SfuPaths.renegotiate,
      data: <String, dynamic>{'session_id': sessionId, 'sdp_answer': sdpAnswer},
      notify: false,
      timeout: requestTimeout,
    ),
  );

  /// 房间快照：谁在、他的发布会话 id 与 track 名、注册表版本号。
  @override
  Future<SfuRoomState> roomState({required String roomId}) =>
      _guard<SfuRoomState>('room', () async {
        final data = await _client.postMap(
          SfuPaths.roomState,
          data: <String, dynamic>{'room_id': roomId},
          notify: false,
          timeout: requestTimeout,
        );
        return SfuRoomState.fromJson(data);
      });

  /// 心跳：客户端在房间里每 20 秒一次（注册表靠它续命，服务端顺手清掉超时的人）。
  ///
  /// 回包带回注册表版本号：与手里那份快照的不一致，就说明"有变化而那条 WS 推送
  /// 没收到"，房间层会立刻重新拉快照对账（少一处只能靠推送的脆弱点）。
  @override
  Future<SfuHeartbeat> heartbeat({required String roomId}) =>
      _guard<SfuHeartbeat>('heartbeat', () async {
        final data = await _client.postMap(
          SfuPaths.heartbeat,
          data: <String, dynamic>{'room_id': roomId},
          notify: false,
          timeout: requestTimeout,
        );
        return SfuHeartbeat.fromJson(data);
      });

  /// 声明"我的麦克风是不是静音中"（见 [SfuControlPlane.setMuted]）。
  ///
  /// 只有几百字节，但它**不能走 `publish` 那条路**：静音不该动发布关系。
  @override
  Future<void> setMuted({required String roomId, required bool muted}) =>
      _guard<void>(
        'mute',
        () => _client.postVoid(
          SfuPaths.mute,
          data: <String, dynamic>{'room_id': roomId, 'muted': muted},
          notify: false,
          timeout: requestTimeout,
        ),
      );

  /// 离开房间：关掉自己的会话并从注册表移除（对方要重新对账）。
  ///
  /// 回包不只是"关成功没成功"：房间空了的时候，最后一个走的人会拿到
  /// `announce = true` 与这通话的时长/人数，由他往群里落一条通话记录
  /// （见 `SfuLeaveResult` 与 `GroupCallController`）。
  @override
  Future<SfuLeaveResult> leave({
    required String roomId,
    required List<String> sessionIds,
    bool closing = false,
  }) => _guard<SfuLeaveResult>('leave', () async {
    final data = await _client.postMap(
      SfuPaths.leave,
      data: <String, dynamic>{
        'room_id': roomId,
        'session_ids': sessionIds,
        // 退出通话（而不是重建时扔一条坏会话）：服务端只在这时候算
        // "房间空了没有、这通打了多久"
        'closing': closing,
      },
      notify: false,
      timeout: requestTimeout,
    );
    return SfuLeaveResult.fromJson(data);
  });
}

final sfuApiProvider = Provider<SfuApi>(
  (ref) => SfuApi(ref.watch(apiClientProvider)),
);
