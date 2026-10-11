/// 群通话依赖的三样"外界东西"的抽象。
///
/// 抽成接口的理由与 `CallMediaEngine` 一样：真实 WebRTC 与真实网络只有设备能跑，
/// 而**最容易写错的那些判断**（同一会话的改动顺序、订阅对账、失败后重建）
/// 全在 [SfuRoom] 里。有了这三个接口，那些逻辑就能用假实现跑到尽头
/// （见 `test/group_call/support/fake_sfu.dart`）。
library;

import 'package:flutter/foundation.dart';

import '../../data/model/sfu_models.dart';

/// 我们的服务端控制面。`SfuApi` 直接实现它。
///
/// 注意：客户端**不直连 Cloudflare**（App Secret 是账号级长期密钥、且权限与房间发现
/// 只能服务端做，见 `docs/protocol/sfu-group-call.md`）。
abstract interface class SfuControlPlane {
  /// 建一条会话（`purpose` = `publish` / `receive`）
  Future<String> createSession({
    required String roomId,
    required String purpose,
  });

  /// 发布（端点出 offer，SFU 回 answer）
  Future<SfuExchangeResult> publish({
    required String sessionId,
    required String sdpOffer,
    required List<Map<String, dynamic>> tracks,
  });

  /// 订阅（**不带 offer**，SFU 回 offer，端点作答后走 [renegotiate]）
  Future<SfuExchangeResult> subscribe({
    required String sessionId,
    required List<Map<String, dynamic>> tracks,
  });

  /// 把端点 answer 交回 CF
  Future<void> renegotiate({
    required String sessionId,
    required String sdpAnswer,
  });

  /// 关掉某些 track（停订阅 / 停发布 / 停共享屏）
  Future<SfuExchangeResult> closeTracks({
    required String sessionId,
    required List<String> mids,
    String? sdpOffer,
    bool force = false,
  });

  /// 房间快照（谁发布了什么 + 注册表版本号）
  Future<SfuRoomState> roomState({required String roomId});

  /// 心跳：在房间里每隔一阵子叫一次。
  ///
  /// 注册表靠 `updated_at` 判"这个人还在不在"，而**发布之后一直不动的客户端**
  /// （静音坐着、没换共享屏）在自己那行上永远不会再写东西 —— 没有心跳就会被当成
  /// 掉线清掉，别人就会把他的声音退订掉。回包带回版本号，见 [SfuHeartbeat]。
  Future<SfuHeartbeat> heartbeat({required String roomId});

  /// 声明"我的麦克风是不是静音中"。
  ///
  /// ⚠️ 与 [publish] 的分工：静音**不摘 track**。摘掉 `mic` 虽然能让注册表自己
  /// 变对，但代价是对方**退订** —— 取消静音要重新发布（跨洋链路上 1~2 秒），
  /// 而那一步一旦失败，对方就再也听不到我（「说话没声」的成因）。所以这里只报
  /// 一个显示态，发布关系原封不动：取消静音是**立即恢复**。
  ///
  /// 调用方按**尽力而为**处理：本机静音已经生效，这里失败只是别人看到的标记
  /// 不对，不能因此把「静音」这个动作判失败。
  Future<void> setMuted({required String roomId, required bool muted});

  /// 离开房间（关会话 + 从注册表移除）。
  ///
  /// 回包是**这一通是不是就此结束**（房间空了、这通电话多久、期间到过几个人）：
  /// 最后一个走的人要拿它去群里落一条通话记录（见 [SfuLeaveResult]）。
  ///
  /// [closing] 说的是"这是**退出通话**，不是扔一条坏会话"：房间状态机重建时也会调
  /// `leave`（只丢那一条被毒化的会话），那一次不能算收尾 —— 否则一次重建就可能
  /// 把"房间空了"的广播权领走、真走的人反而拿不到。
  Future<SfuLeaveResult> leave({
    required String roomId,
    required List<String> sessionIds,
    bool closing = false,
  });
}

/// 端点要发布的一条本地 track。
@immutable
class SfuLocalTrack {
  const SfuLocalTrack({required this.name, required this.kind});

  /// `mic` / `screen`（进房间注册表，订阅方靠它对上）
  final String name;

  /// `audio` / `video`
  final String kind;
}

/// 一次"要发给后端的 SDP"：候选已经收齐（**非 trickle**，CF 的硬要求）。
@immutable
class SfuPreparedSdp {
  const SfuPreparedSdp({required this.sdp, required this.mids});

  /// 收齐候选之后的 `pc.localDescription.sdp`
  final String sdp;

  /// track 名 → transceiver 的 mid（发布用）；关闭时是 "要关的 mid" 列表
  final Map<String, String> mids;

  @override
  String toString() =>
      'SfuPreparedSdp(${mids.length} tracks, ${sdp.length} bytes)';
}

/// 收到的一条远端 track。
@immutable
class SfuIncomingTrack {
  const SfuIncomingTrack({
    required this.mid,
    required this.kind,
    required this.stream,
  });

  /// 接收侧的 mid（[SfuExchangeResult.tracks] 里那条 result 的 `mid`）
  final String mid;

  /// `audio` / `video`
  final String kind;

  final Object stream;
}

/// 一条到 SFU 的 PeerConnection。
///
/// 每个方法都对应 CF connection patterns 里的一个动作；**候选收齐**这件事被吃进
/// 方法内部（调用方拿到的 [SfuPreparedSdp] 一定是可以直接发的）。
abstract interface class SfuPeerConnection {
  /// 收到 SFU 推来的远端 track
  Stream<SfuIncomingTrack> get incomingTracks;

  /// 这一刻各条**远端音频**的能量：`mid → 0~1`。
  ///
  /// 界面靠它画「正在说话」的那个人（见 `SfuSpeakerTracker`）。它是**尽力而为**的
  /// 一条路：插件/平台不提供这个字段时就返回空表 —— 界面会认为"没人说话"，
  /// 退回头像墙，而不是瞎猜一个说话人。
  ///
  /// 只问**接收会话**（我自己的声音不在里面）。
  Future<Map<String, double>> audioLevels();

  /// **接收侧**每一条视频流的「还在不在收」的计数（`mid → 计数`）。
  ///
  /// 用在别的共享屏**本机健康检查**上（见 `SfuRoom.screenStallTimeout`）：
  /// 远端共享者突然没了（App 被杀 / 网断 / 注册表还没更新）时，接收侧只看得到
  /// 「最后一帧停在那里」—— 靠这个计数**不涨**就能自己判出来，把画面放下来，
  /// 不用等注册表（那条链可能是 45 秒的行超时，也可能一直没对上）。
  ///
  /// 计数取的是能反映「真的有新数据进来」的那几档之一（优先 `framesDecoded`，
  /// 退到 `framesReceived` / `bytesReceived` / `packetsReceived`）：平台/版本给
  /// 的字段名不一样，所以这里只保证「**涨了 = 还在收**」这一个语义。
  Future<Map<String, int>> inboundVideoCounters();

  /// 连接是否已经建立。
  ///
  /// 这是 CF 的硬要求：应用完 answer 之后**要等到 ICE 连上**再宣布这一步成功
  /// （没连上就继续发请求等于把改动盖在一条死连接上）。超时返回 false，
  /// 调用方按「结果未知」处理 → 换新会话重建。
  Future<bool> waitConnected(Duration timeout);

  /// 发布（或追加发布）：把本地 track 挂上去、出 offer、收齐候选
  Future<SfuPreparedSdp> preparePublish(List<SfuLocalTrack> tracks);

  /// 应用 SFU 的 answer（发布路径用；**不需要 renegotiate**）
  Future<void> applyAnswer(String answerSdp);

  /// 处理 SFU 的 offer：应用它、造 answer、收齐候选，返回要交给 `renegotiate` 的 answer
  Future<String> answerSfuOffer(String offerSdp);

  /// 关闭前重新出 offer：`stop()` 掉这些 mid 的 transceiver、收齐候选
  ///
  /// 拿不到可用 offer（例如那些 transceiver 早就没了）时返回 null，
  /// 调用方改用 `force: true` 的关法。
  Future<SfuPreparedSdp?> prepareClose(List<String> mids);

  /// 把某个已发布的 track 名换成「此刻本机的那一条」。
  ///
  /// 用在**采集被重建**之后（桌面：被共享的那扇窗最小化又回来 —— 见
  /// `WebrtcSfuLocalMedia` 里那条 `SharedWindowWatch`）：旧的采集器手里的画面
  /// 已经死了，本机重新采了一条新轨，但它在 SFU 那边**身份没变** —— 所以要做的是
  /// 把新轨挂回**同一个 transceiver**（`sender.replaceTrack`），
  /// **不重新协商、不碰服务端**（注册表里那条发布还是它，mid 也不变）。
  ///
  /// 返回是否真的换上了（false = 本机没有这条轨 / 这条轨没在这个会话上发布过）。
  Future<bool> replaceTrackByName(String trackName);

  /// 应用关 track 流程返回的 answer
  Future<void> applyCloseAnswer(String answerSdp);

  Future<void> close();
}

/// 造一条新的 PeerConnection。
///
/// 为什么是工厂而不是单例：**会话被判定不可用时要换一条新连接重建**
/// （CF 的恢复指引：不确定结果的请求不能重放，得换连接），
/// 所以每个会话都要能重新造一条。
typedef SfuConnectionFactory = SfuPeerConnection Function();

/// 本机媒体（麦克风 / 屏幕），**只采一次**，所有会话共用。
abstract interface class SfuLocalMedia {
  /// 采麦克风
  Future<void> startMicrophone();

  /// 屏幕共享在这台设备上能不能用（安卓的系统投屏；桌面走原生的
  /// `getDisplayMedia`；iOS 要 ReplayKit 的广播扩展，暂时没有）。
  bool get supportsScreenShare;

  /// 请求投屏授权（系统那个「开始投屏 / 录制」框）。用户点了拒绝返回 false。
  ///
  /// ⚠️ 顺序是硬要求（Android 14）：**先拿到这份同意 → 把前台服务类型升上
  /// `mediaProjection` → 最后才 [startScreen]**（理由见 S6.7：`getMediaProjection()`
  /// 要求「取投影之前已经有一个 mediaProjection 类型的前台服务在跑」）。
  /// 中间那步在控制器里（它管前台服务），所以这里只负责「同意」与「取流」两件事。
  ///
  /// 桌面（Windows / Linux）**不需要任何授权**：原生那条捕获直接就能取，
  /// 这里返回 true（与 1:1 的 `CallMediaEngine.requestScreenSharePermission` 同一个口径）。
  Future<bool> requestScreenSharePermission();

  /// 取屏幕流。**前置条件**：已拿到投屏同意（[requestScreenSharePermission]）
  /// 且前台服务已升到 `mediaProjection`。
  ///
  /// [sourceId] 是桌面上「共享哪一块屏幕 / 哪个窗口」的选择结果
  /// （`desktopCapturer.getSources()` 给的那个 id）：原生的 `getDisplayMedia` 认
  /// `video -> deviceId -> exact`。不传就是系统默认源（主屏）；安卓上这条不用。
  /// [withAudio] = 连**电脑的声音**一起发（桌面，S12.39）。Windows 上原生那套是
  /// WASAPI 环路（共享整个屏幕 = 全部系统声音，共享某个窗口 = 按 PID 只抓那个
  /// 程序），与 1:1 的 `CallMediaEngine.startScreenShare(withAudio:)` 同一个口径。
  ///
  /// ⚠️ 与 1:1 的结构差别：那边是单条连接 `replaceTrack`，多一条音频轨直接挂上去；
  /// 这边是 SFU，**每条轨都要有自己的名字**才能被别人订阅，所以开了这个之后还要
  /// 多发布一条 `screen-audio`（见 [publishableTracks]）。
  Future<void> startScreen({String? sourceId, bool withAudio = false});

  Future<void> stopScreen();

  /// 屏幕采集**变过了**：本机要么换上了新轨（重建成功），要么已经没有采集了
  /// （重建失败）。监听方拿 [screenSharing] 分辨这两种情形。
  ///
  /// 什么时候会响（桌面）：用户共享的是**某一个窗口**，把它最小化（或藏进托盘）
  /// 再还原 —— 底层那套 GDI 采集器回来之后就不再出画面了，所以本机在窗口回来时
  /// **重新采了一次**（见 `desktop_screen_capture.dart`）。
  ///
  /// * 成功：对方要看到画面恢复，就得把新轨挂回原位
  ///   （[SfuPeerConnection.replaceTrackByName]）—— 不重新协商、也不动服务端；
  /// * 失败：本机**已经没有屏幕采集了**（旧的在重建前就放掉了），监听方要把
  ///   那几路发布关掉、把界面从「正在共享」放下来 —— 不然别人一直订阅着一路
  ///   永远没数据的流，看着像"他还在共享"。
  void addScreenTrackReplacedListener(VoidCallback listener);

  /// 摘掉 [addScreenTrackReplacedListener] 加上的那个监听
  void removeScreenTrackReplacedListener(VoidCallback listener);

  /// 当前该发布的 track（麦克风一直在；共享屏开着时多一条 `screen`）
  List<SfuLocalTrack> get publishableTracks;

  bool get screenSharing;

  Future<void> setMicrophoneEnabled(bool enabled);

  /// 声音走免提（扬声器）还是听筒 —— 与 1:1 那条同一个口径
  /// （`CallMediaEngine.setSpeakerEnabled`，老端 `ROUTE_SPEAKER`）。
  ///
  /// ⚠️ 不设的话安卓会按「通话模式」默认走**听筒**：群里别人说话会小得像在远处，
  /// 而微信群语音默认就是免提。这个调用要在**拿到媒体之后**做（与 1:1 一致）。
  Future<void> setSpeakerEnabled(bool enabled);

  Future<void> dispose();
}
