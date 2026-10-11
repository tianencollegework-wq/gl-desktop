import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/model/sfu_models.dart';
import 'sfu_failure.dart';
import 'sfu_session_queue.dart';
import 'sfu_speaker.dart';
import 'sfu_stream_watch.dart';
import 'sfu_trace.dart';
import 'sfu_transport.dart';

/// 房间阶段（界面据它决定显示什么）
enum SfuRoomPhase {
  idle,

  /// 采媒体 → 建发布会话 → 发布 → 订阅全屋子
  joining,

  joined,

  /// 某条会话被判定不可用，正在换新会话重建（媒体会断一下）
  rebuilding,

  leaving,

  /// 进不去（没权限 / 人满 / 网络）
  failed,
}

/// 界面要看的房间状态
@immutable
class SfuRoomView {
  const SfuRoomView({
    this.phase = SfuRoomPhase.idle,
    this.roomId = '',
    this.participants = const <SfuParticipant>[],
    this.epoch = 0,
    this.screenSharing = false,
    this.micPublished = false,
    this.micPublishPending = false,
    this.activeSpeaker,
    this.error = '',
  });

  final SfuRoomPhase phase;
  final String roomId;
  final List<SfuParticipant> participants;
  final int epoch;

  /// 我在共享屏幕
  final bool screenSharing;

  /// 我的麦克风**真的发布出去了**（注册表里我那一行带着 `mic`）。
  ///
  /// 与「麦克风按钮是开着的」不是一件事：按钮开只说明本机没有被静音，
  /// 而发布没谈成（CF 拒了 / 还没重协商完）时，别人其实一个字都听不到。
  /// 界面必须拿这个字段画那颗按钮，不能拿本机意图画 —— 否则就会同时显示
  /// 「麦克风已开」与「已静音」这种自相矛盾的状态（真机上出现过）。
  final bool micPublished;

  /// 我这一路发布**还在路上**（已经发出去了，还没等到结果）。
  ///
  /// 为什么需要单独一个信号：进房间时"**听见别人**"与"**自己的声音发出去**"走的是
  /// 两条互不相干的会话，前者一两秒就落地，后者还要走候选收集 + 与 Cloudflare 建连
  /// （真机上好几秒）。这几秒里注册表里当然还没有我的 `mic` —— 但**那不是故障**，
  /// 界面不该据此挂上「麦克风没接上」。
  final bool micPublishPending;

  /// 此刻在说话那个人（`userId`；没人说话是 null，且**不含自己**）。
  ///
  /// 判定见 [SfuSpeakerTracker]：能量表是每一轮现采的，插件不提供这个字段时它
  /// 永远是 null —— 界面这时退回头像墙。
  final String? activeSpeaker;

  /// 失败原因（给界面提示用）
  final String error;

  bool get joined => phase == SfuRoomPhase.joined;

  /// `activeSpeaker` 是可空的，`copyWith` 用 `??` 就永远清不掉它 —— 传 [_unset]
  /// 表示"没提这个字段"，传 null 表示"确实要清空"。
  static const Object _unset = Object();

  SfuRoomView copyWith({
    SfuRoomPhase? phase,
    String? roomId,
    List<SfuParticipant>? participants,
    int? epoch,
    bool? screenSharing,
    bool? micPublished,
    bool? micPublishPending,
    Object? activeSpeaker = _unset,
    String? error,
  }) => SfuRoomView(
    phase: phase ?? this.phase,
    roomId: roomId ?? this.roomId,
    participants: participants ?? this.participants,
    epoch: epoch ?? this.epoch,
    screenSharing: screenSharing ?? this.screenSharing,
    micPublished: micPublished ?? this.micPublished,
    micPublishPending: micPublishPending ?? this.micPublishPending,
    activeSpeaker: identical(activeSpeaker, _unset)
        ? this.activeSpeaker
        : activeSpeaker as String?,
    error: error ?? this.error,
  );
}

/// 收到的一路远端媒体（**已经对上「谁的哪条 track」**）。
///
/// 界面按 [userId] 把它挂到那个人的声音/画面上（共享屏就是 `trackName == 'screen'`
/// 的那路视频）。
@immutable
class SfuIncomingMedia {
  const SfuIncomingMedia({
    required this.userId,
    required this.trackName,
    required this.kind,
    required this.stream,
  });

  final String userId;

  /// `mic` / `screen`（协议里的 track 名）
  final String trackName;

  /// `audio` / `video`
  final String kind;

  /// `MediaStream`。domain 层不引插件类型，所以是个 [Object]，界面自己 cast
  final Object stream;
}

/// 房间里的一位参与者（含自己）
@immutable
class SfuParticipant {
  const SfuParticipant({
    required this.userId,
    required this.audio,
    required this.screen,
    required this.isMe,
  });

  final String userId;

  /// 发布了麦克风
  final bool audio;

  /// 在共享屏幕
  final bool screen;

  final bool isMe;
}

/// 界面上的「群通话诊断」读它：一次快照（房间 / 两条会话 / 订阅 / 计数 + 时间线）。
///
/// 与 1:1 的 `CallDiagnostics` 是同一个位置的东西，但内容不一样：那边看候选与
/// RTT（点对点直连才有的东西），这边看**订阅有没有建上**与**重建了几次**。
@immutable
class SfuRoomDiagnostics {
  const SfuRoomDiagnostics({
    required this.roomId,
    required this.phase,
    required this.epoch,
    required this.publishSessionId,
    required this.receiveSessionId,
    required this.subscriptions,
    required this.publishedTracks,
    required this.activeSpeaker,
    required this.trace,
  });

  final String roomId;
  final SfuRoomPhase phase;
  final int epoch;

  /// 两条会话的 id（`null` = 还没建）
  final String? publishSessionId;
  final String? receiveSessionId;

  /// `u2|mic → mid-x（发布者会话 sess-…）`
  final List<String> subscriptions;

  /// `mic → mid-mic`
  final List<String> publishedTracks;

  final String? activeSpeaker;
  final SfuTrace trace;

  /// 导出/复制用的纯文本（与 1:1 那份 `summary` 一样，给开发者看的）
  String get summary {
    final buffer = StringBuffer()
      ..writeln('群通话诊断')
      ..writeln('房间：$roomId（epoch $epoch，阶段 ${phase.name}）')
      ..writeln('发布会话：${publishSessionId ?? '（未建）'}')
      ..writeln('接收会话：${receiveSessionId ?? '（未建）'}')
      ..writeln(
        '我发布：${publishedTracks.isEmpty ? '（无）' : publishedTracks.join('、')}',
      )
      ..writeln('订阅：${subscriptions.isEmpty ? '（无）' : subscriptions.join('、')}')
      ..writeln('说话人：${activeSpeaker ?? '（没人说话）'}')
      ..writeln(trace.counters)
      ..writeln('时间线：');
    for (final entry in trace.entries) {
      buffer.writeln('  $entry');
    }
    return buffer.toString();
  }
}

/// 一条到 SFU 的会话（发布或接收）：会话 id + 连接 + 一条改动队列
class _SfuSide {
  _SfuSide({required this.purpose, required this.sessionId, required this.pc})
    : queue = SfuSessionQueue(sessionId: sessionId);

  final String purpose;
  final String sessionId;
  final SfuPeerConnection pc;
  final SfuSessionQueue queue;

  /// 这条会话上收到的远端 track（拆会话时要取消）
  StreamSubscription<SfuIncomingTrack>? incoming;
}

/// 群通话的房间状态机（Cloudflare Realtime SFU）。
///
/// 它负责三件容易写错的事，依据都在 `docs/protocol/sfu-group-call.md`：
///
/// 1. **两条会话各自的改动都串行**（CF 的一条会话只有一个 offer/answer 状态机，
///    并发提交会被拒 406）；
/// 2. **按房间快照对账订阅**：只补差集、只关多余，已经订好的绝不重订
///    （重订 = 重复分配）。CF 不提供房间发现，"谁发布了什么"由我们的服务端维护，
///    客户端每次刷新都重算一次差集，所以偶尔失败的那条 track 下次刷新会自愈；
/// 3. **会话被判定不可用（结果未知 / 过期）时换新会话重建**，不是重试
///    （`tracks/new` 不幂等）。重建会**去重**：同一时刻只允许一次重建在飞。
///
/// 媒体本身不经过这里：音视频是端点 ↔ Cloudflare 直连，这里只管 SDP 与状态。
class SfuRoom {
  SfuRoom({
    required this.roomId,
    required this.myUserId,
    required this.control,
    required this.local,
    required this.connectionFactory,
    this.connectTimeout = const Duration(seconds: 10),
    this.heartbeatInterval = const Duration(seconds: 20),
    this.stateRefreshInterval = const Duration(seconds: 5),
    this.slowPollThreshold = const Duration(seconds: 2),
    this.audioLevelPollInterval = const Duration(milliseconds: 700),
    this.screenHealthInterval = const Duration(seconds: 2),
    this.screenStallTimeout = const Duration(seconds: 8),
    this.reconcileRetryInterval = const Duration(seconds: 1),
    this.reconcileRetryMaxInterval = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String roomId;
  final String myUserId;
  final Duration connectTimeout;

  /// 「谁在说话」的采样间隔（`null` = 不自动采，测试里自己调 [pollAudioLevels]）。
  ///
  /// 它只影响观感：拿不到就是没人说话（头像墙），不影响通话本身。
  final Duration? audioLevelPollInterval;

  /// 心跳间隔（`null` = 不发心跳）。服务端把“超过行超时没动静”的人当掉线清掉，
  /// 这里留出两拍余量（行超时 45 秒 vs 20 秒一拍）；测试里给短间隔或 null。
  final Duration? heartbeatInterval;

  /// **状态回查间隔**（`null` = 不回查）。
  ///
  /// 这是界面“不迟钝”的**唯一硬保证**：不管推送有没有丢、服务端有没有 bump
  /// 版本号，最多这么久界面就会自己拉一次快照纠回来。
  ///
  /// 为什么不能只靠推送（真机上“对方停了共享我还卡在画面上 / 人都走了三分钟
  /// 还挂在那儿”就是这么来的）—— 有两个会**静默断掉**的地方：
  ///
  /// * 服务端只在**自己发起的那次请求**里更新注册表；CF 那边媒体没了、
  ///   会话死了这类变化没有端点可挂，只能靠**行超时**清，而清场（`prune`）
  ///   只在拉快照时跑。客户端版本号没变就不拉快照 → **两边互相等**：
  ///   清场永远不来，掉线的人（连着他在共享的屏）就永远挂在界面上；
  /// * 推送丢了一条没有任何代价就能发生（换网、系统把 App 挂起、帧错位）。
  ///
  /// 代价是每 5 秒一条很小的读请求（服务端只查自己的注册表，不碰 CF），
  /// 比“界面落后半分钟”值 —— 群通话是几个人同时在说话的实时界面。
  ///
  /// ⚠️ 但「每 5 秒」只在服务端健康时成立：一次回查超过 [slowPollThreshold]
  /// 就说明它现在忙，间隔会自己拉长（见 [_pollTick]）—— 那种时候继续每 5 秒
  /// 往里压，受害的正是「界面准不准」这件事本身。
  final Duration? stateRefreshInterval;

  /// 定期回查超过这个耗时就算「服务端现在慢」，那之后间隔开始退避
  /// （可注入：用例不想真等两秒）
  final Duration slowPollThreshold;

  /// 共享屏的**本机健康检查**间隔（`null` = 不做这条检查；用例自己调
  /// [pollScreenHealth]）。
  ///
  /// 它盯的是「**对方那一路还在不在收**」—— 与注册表无关（那条链可能要 45 秒的
  /// 行超时，也可能一直对不上）。2026-10-08 用户报的就是这种：电脑在共享屏、
  /// 然后直接挂断群通话，手机端永远停在最后一帧。
  final Duration? screenHealthInterval;

  /// 多久收不到共享屏的新帧就判它已经断了（见 [SfuStreamWatch]）
  final Duration screenStallTimeout;

  /// **订阅没订上时的快速重试间隔**（`null` = 关掉，用例自己驱动）。
  ///
  /// 为什么不能只靠 [stateRefreshInterval]：那条是「兜底」，5 秒一拍、服务端一慢
  /// 还会自己退避到 30 秒（见 [_notePollPeriod]）。2026-10-08 真机上量到的正是这个
  /// 组合：服务端调 Cloudflare 那一跳 5 秒超时（4005）之后，**两分钟里每次对账
  /// 都打在订不上的那条会话上**，用户看到的就是「他在共享、我这边什么都没有」。
  ///
  /// 这里只在「该订的没订齐」时开火：先 1 秒、再翻倍（封顶
  /// [reconcileRetryMaxInterval]），订齐了就回到最初间隔。
  final Duration? reconcileRetryInterval;

  /// [reconcileRetryInterval] 的上限
  final Duration reconcileRetryMaxInterval;

  final DateTime Function() _now;

  /// 控制面：我们的服务端（**客户端不直连 Cloudflare**，App Secret 只在服务端）
  final SfuControlPlane control;

  /// 本机媒体（麦克风 / 屏幕）：**只采一次**，两条会话共用
  final SfuLocalMedia local;

  /// 造一条新连接：会话被判死时要换新的重建，所以是工厂
  final SfuConnectionFactory connectionFactory;

  final ValueNotifier<SfuRoomView> view = ValueNotifier<SfuRoomView>(
    const SfuRoomView(),
  );

  /// 收到的远端媒体（已对上的人）
  final StreamController<SfuIncomingMedia> _incoming =
      StreamController<SfuIncomingMedia>.broadcast();

  Stream<SfuIncomingMedia> get incomingMedia => _incoming.stream;

  _SfuSide? _publish;
  _SfuSide? _receive;

  /// 当前订阅：`userId|trackName` → 接收侧 mid
  final Map<String, _Subscription> _subscriptions = <String, _Subscription>{};

  /// 已发布的 track 名 → mid（重建时要整体重发，所以要留着）
  final Map<String, String> _publishedMids = <String, String>{};

  SfuRoomState _snapshot = SfuRoomState.empty;

  /// 我的麦克风有没有真的进注册表（界面那颗按钮看它，见 [SfuRoomView.micPublished]）
  bool _micPublished = false;

  /// 我**声明出去**的静音态（`true` = 我按了静音）。
  ///
  /// 它与 [_micPublished] 是两件事：那个说的是"注册表里有我这条发布"，这里说的是
  /// "我按了静音"（发布还在，只是不再发包）。别人看到的麦克风状态要两者一起看
  /// （见 `SfuRoomMember.muted`），少看一半就会把静音的人画成"麦克风已开"。
  bool _micMuted = false;

  /// 上一次静音态**没能报到服务端**（网络抖一下 / 老服务端还没有这个接口）。
  ///
  /// 留着它是因为：报不上去就等于别人一直看到错的标记（那正是要修的那个 bug）。
  /// 下一次心跳顺手再报一次 —— 心跳本来就是"我还在、我的状态是这样"那一趟。
  bool _mutePending = false;

  /// 发布这一趟还在飞（见 [SfuRoomView.micPublishPending]）
  bool _publishPending = false;
  bool _disposed = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  Future<void>? _publishRebuild;
  Future<void>? _receiveRebuild;

  /// 建接收会话那次调用（同一时刻只允许一次在飞，见 `_ensureReceive`）
  Future<_SfuSide>? _receiveCreating;

  /// 心跳定时器（进房间后起，离开/释放时停）
  Timer? _heartbeat;

  /// 上一次心跳还在飞（服务端慢的时候 20 秒不一定回得来：不叠飞，
  /// 否则慢一次就变成每个间隔多压一条进去）
  bool _heartbeatPending = false;

  /// 定期回查（见 [stateRefreshInterval]）
  Timer? _stateRefresh;

  /// 回查当前用的间隔（服务端慢时会拉长，见 [_pollTick]）：健康时就是
  /// [stateRefreshInterval] 那个值
  Duration? _pollInterval;

  /// 上一份快照的指纹（版本号 + 谁发了什么）：定期回查时**没变就不记时间线**，
  /// 否则 5 秒一条快照会把诊断面板上有用的那几条冲掉。
  String _snapshotDigest = '';

  /// 共享屏健康检查（见 [screenHealthInterval]）
  late final SfuStreamWatch _streamWatch = SfuStreamWatch(
    timeout: screenStallTimeout,
  );
  Timer? _screenHealth;

  /// 现在有没有共享屏要盯（见 [_syncScreenHealth]）
  bool _watchScreen = false;

  /// 补订阅的快速重试定时器（见 [reconcileRetryInterval]）
  Timer? _reconcileRetry;

  /// 下一次快速重试等多久（null = 还没退过，用 [reconcileRetryInterval]）
  Duration? _reconcileRetryDelay;

  /// 判死那一刻的计数（`mid → 当时的值`）：之后再看到**值变了**就是又活了
  /// （静态画面被误判 / 对方重开了共享），那时要把画面接回来。
  final Map<String, int> _stalledAt = <String, int>{};

  /// **本机判定某一远端媒体已经断了**（收不到新帧了）：界面据此把画面放下来。
  ///
  /// 与 `incomingMedia` 是一对：那个说「多了一路」，这个说「这一路没了」。
  final StreamController<SfuIncomingMedia> _dropped =
      StreamController<SfuIncomingMedia>.broadcast();

  Stream<SfuIncomingMedia> get droppedMedia => _dropped.stream;

  /// 收到过的远端媒体（`mid → 那一份`）：判死时要把**同一份**（连着那条流）
  /// 交回界面，界面才能确认「死的正是我正在画的那一份」。
  final Map<String, SfuIncomingMedia> _mediaByMid =
      <String, SfuIncomingMedia>{};

  /// 说话人判定（阈值/保持的规则在它里面，这里只负责把 mid 归位到人）
  final SfuSpeakerTracker _speaker = SfuSpeakerTracker();
  Timer? _levelPoller;

  /// 时间线与计数（面板读它，见 [diagnostics]）
  final SfuTrace trace = SfuTrace();

  // ------------------------------------------------------------ 给测试看的

  @visibleForTesting
  String? get publishSessionId => _publish?.sessionId;

  @visibleForTesting
  String? get receiveSessionId => _receive?.sessionId;

  @visibleForTesting
  Set<String> get subscriptionKeys => _subscriptions.keys.toSet();

  @visibleForTesting
  int get epoch => _snapshot.epoch;

  /// 界面上的「群通话诊断」快照（长按通话页随时看）
  SfuRoomDiagnostics get diagnostics => SfuRoomDiagnostics(
    roomId: roomId,
    phase: view.value.phase,
    epoch: _snapshot.epoch,
    publishSessionId: _publish?.sessionId,
    receiveSessionId: _receive?.sessionId,
    subscriptions: <String>[
      for (final entry in _subscriptions.entries)
        '${entry.key} → ${entry.value.mid ?? '（还没收到 mid）'}'
            '（发布者会话 ${entry.value.sessionId}）',
    ],
    publishedTracks: <String>[
      for (final entry in _publishedMids.entries)
        '${entry.key} → ${entry.value}',
    ],
    activeSpeaker: view.value.activeSpeaker,
    trace: trace,
  );

  // ------------------------------------------------------------ 公开动作

  /// 进房间：采麦克风 → 建发布会话并发布 → 拉快照并对账订阅
  Future<void> join() async {
    trace.record('进房间（房间 $roomId）');
    _publishView(
      view.value.copyWith(
        phase: SfuRoomPhase.joining,
        roomId: roomId,
        error: '',
      ),
    );
    try {
      await local.startMicrophone();
      trace.record('麦克风采到了');
      // 发布侧的会话**先建出来**（一条请求）：这一条之后，接收侧就不必再等"发布这条路"
      // —— 两条会话本来就互不相干。
      await _ensurePublish();
      trace.record('发布会话建好了');
      // 接收侧的会话也**同时着手**（不 await）：两边完全无关，等它建好之后
      // 下面那次对账就少一趟建会话的往返。
      unawaited(_prewarmReceive());
      // ⚠️ 发布**不 await**：真机上"进房间要等好几秒"主要就等在这里（候选收集 +
      // 与 Cloudflare 建连）。先让接收侧跑起来 —— **听见别人不需要我的发布谈成**。
      _publishPending = true;
      _publishView(view.value);
      final publishing =
          _publishMutation('publish', (side) async {
            final prepared = await side.pc.preparePublish(
              local.publishableTracks,
            );
            await _publishTracks(side, prepared);
          }).whenComplete(() {
            _publishPending = false;
          });
      // 先把这一趟的异常接住：不接的话，下面等接收侧那几秒里它会变成
      // "没人接的异步异常"（那种东西在真机上只会看到一句红字，什么也定位不到）。
      final publishError = publishing.then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      await _refreshBestEffort();
      // "重建也失败"时阶段已经是 failed（错误文案也在那一步写好了）：
      // 不能在这里把它盖成 joined —— 那样界面会显示"已进房间"，而我的麦克风
      // 其实一条都没发布出去。
      if (view.value.phase != SfuRoomPhase.failed) {
        _publishView(view.value.copyWith(phase: SfuRoomPhase.joined));
        _startHeartbeat();
        _startStateRefresh();
        _startLevelPolling();
      }
      // 自己的发布没落地（被上游拒了 / 连不上）：回到"进不去"，并把原因写出去。
      // 不能默默留在房间里 —— 那正是"界面一切正常、别人一个字都听不到"的样子。
      final failure = await publishError;
      if (failure != null) {
        _publishView(
          view.value.copyWith(
            phase: SfuRoomPhase.failed,
            error: failure is SfuFailure ? failure.message : '$failure',
          ),
        );
        throw failure;
      }
      trace.record('发布落地');
      // 发布落地后**再读一次注册表**：`micPublished` 的唯一来源是注册表，
      // 而上面那一趟快照可能跑在这次发布之前（两条会话是并行的）。
      //
      // ⚠️ 这里曾经是靠发布回包自己写 `micPublished = true` —— 那正是老问题的根源：
      // 回包说"上游接受了 mic"，而服务端因为自己的解析 bug 根本没把它写进注册表，
      // 界面于是信心十足地显示一切正常、别人一个字都听不到。
      // **"我说我发出去了"和"别人查得到我"不是一回事。**
      await _refreshBestEffort();
    } on SfuFailure catch (failure) {
      _publishView(
        view.value.copyWith(phase: SfuRoomPhase.failed, error: failure.message),
      );
      rethrow;
    } catch (error) {
      // 媒体层/原生层的异常（麦克风被拒、没设备、建连接失败…）：也要落到"进不去"
      // 这个阶段——否则界面会永远停在"正在加入"，用户只能杀进程。
      _publishView(
        view.value.copyWith(phase: SfuRoomPhase.failed, error: '$error'),
      );
      rethrow;
    }
  }

  /// 进房间时那两趟「读快照」：**失败只记日志**。
  ///
  /// 这两趟是读：读不到只是界面停在上一次的样子，推送与定期回查马上会补上。
  /// 而它们以前是硬 await —— 服务端一抖（实测一次快照 2.7~30s），一次读超时
  /// 就把整通电话顶成「进不去」，可那时**发布正在谈，别人其实听得到我**。
  /// 真正决定进不进得去的是发布（它那一条的错误照样往外抛，一路抛到
  /// 控制器的 `进不去`）。
  Future<void> _refreshBestEffort() async {
    try {
      await refreshRoomState();
    } on Object catch (error) {
      debugPrint('[群通话] 进房间拉快照失败（忽略，推送/回查会补）：$error');
      trace.record('拉快照失败（忽略）：$error', failure: true);
    }
  }

  /// 拉房间快照并对账订阅。
  ///
  /// 由四处触发：进房间与发布落地各一次；WS 推来"有人加入/离开/换了会话"时；
  /// 长连接恢复时；以及 [stateRefreshInterval] 那条**定期回查**（兜底）。
  /// 多次触发**合并成一次**：一瞬间来几条推送不会排一堆请求出去。
  ///
  /// [epoch] 是推送里带回的注册表版本号：**与手里这份相同就不跑这一趟**
  /// （一次进出会 bump 一次，房间里 9 个人就是 9 条推送）。
  /// ⚠️ 判断是“**相同**就跳过”，不是“不比手里新就跳过”：
  /// 版本号是服务端缓存里的一个计数器，缓存清过 / 服务重启过就会**倒退**，
  /// 而“比手里小就永远不刷”会让这台手机**永久不再收任何人进出的更新**。
  /// 回退时多刷一次没有任何代价（差集为空就是空转）。
  /// 不传就是"不管版本号，拉一次"（进房间、心跳、定期回查、重连走这条路）。
  ///
  /// [quiet] = 定期回查：状态没变就**不记时间线**（5 秒一条快照会把诊断面板
  /// 上有用的那几条冲掉），但该更新的状态一个不少。
  Future<void> refreshRoomState({int? epoch, bool quiet = false}) async {
    // 已经离开房间（`leave()` 把两条会话都放掉了）之后不该再被推送/重连拉回来：
    // 那会让界面已经关掉的一页重新建出接收会话来。
    if (_disposed || _publish == null) return;
    if (epoch != null && epoch == _snapshot.epoch) return;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      final snapshot = await control.roomState(roomId: roomId);
      _snapshot = snapshot;
      // 快照里必须带上**注册表原文**（谁、发了什么）与**我自己的 id**：
      // 真机上「我看不到我的 mic」只有两种可能 —— 服务端没记上，或者记上了但
      // id 对不上（客户端认不出哪一行是自己）。这两者在界面上长得一模一样，
      // 而这一行就能把它们劈开：`(我)` 没出现 = id 问题；出现了但没有 mic = 服务端没记上。
      final digest = '${snapshot.epoch}｜${_describeMembers(snapshot)}';
      if (!quiet || digest != _snapshotDigest) {
        _snapshotDigest = digest;
        trace.record(
          '快照：${_participantsOf(snapshot).length} 人 / epoch ${snapshot.epoch}'
          ' ｜ 我=${myUserId.isEmpty ? '（空）' : myUserId}'
          ' ｜ ${_describeMembers(snapshot)}',
        );
      }
      // 麦克风发没发出去**以注册表为准**：这是别人能不能听到我的唯一凭据
      _micPublished = _myPublishedTracks(snapshot).contains('mic');
      _publishView(
        view.value.copyWith(
          epoch: snapshot.epoch,
          participants: _participantsOf(snapshot),
        ),
      );
      final desired = _desiredOf(snapshot);
      // 快路径：没有差集就不入队（省掉一次请求，也避免无意义的 406 风险）
      final diff = _diffOf(desired);
      if (diff.add.isEmpty && diff.remove.isEmpty) {
        _resetReconcileRetry();
        return;
      }
      try {
        await _receiveMutation(
          'reconcile',
          (side) => _applyDiff(side, desired),
        );
      } catch (_) {
        // 这一趟没成：**不要**只等下一次回查（5 秒起、慢时退避到 30 秒），
        // 先排一次 1 秒级的重试；失败照旧往外抛（调用方该记的日志照记）
        _scheduleReconcileRetry();
        rethrow;
      }
      // 「订上一部分」也算没齐（逐条失败时 [_recordSubscriptions] 会跳过那几条）：
      // 差集还在就继续快速重试，差集空了才回到 [stateRefreshInterval] 那条慢兜底。
      final left = _diffOf(desired);
      if (left.add.isEmpty && left.remove.isEmpty) {
        _resetReconcileRetry();
      } else {
        _scheduleReconcileRetry();
      }
    } finally {
      _refreshing = false;
      final again = _refreshAgain;
      _refreshAgain = false;
      if (again && !_disposed) {
        unawaited(refreshRoomState());
      }
    }
  }

  /// 共享屏该发布哪几路：`screen`（画面），开着「连电脑的声音」时再加一条
  /// `screen-audio`（S12.39）。麦克风不算 —— 它是进房间时就发布好的，共享屏是**追加**。
  ///
  /// ⚠️ **必须在 `local.stopScreen()` 之前读**：放掉采集之后 `publishableTracks`
  /// 里就没有它们了，那时候再问"我刚发的是哪几路"已经晚了。
  List<SfuLocalTrack> get _shareTracks => <SfuLocalTrack>[
    for (final track in local.publishableTracks)
      if (track.name.startsWith('screen')) track,
  ];

  /// 开始共享屏幕：把屏幕（开着「连电脑的声音」时再加上声音）追加发布。
  ///
  /// [sourceId] 是桌面上用户选的那个源（整个屏幕 / 某个窗口）；安卓上不用。
  /// [withAudio] = 连电脑的声音一起发（桌面，S12.39）。
  ///
  /// ⚠️ 到底发布哪几路**由 `local.publishableTracks` 说了算**，不在这里写死：
  /// 用户勾了那座开关、但选中的源根本没有声音（比如一个静音的窗口）时，我们
  /// **不该**凭空造一条空的 `screen-audio` 出来 —— 那会让别人订阅到一条永远没数据
  /// 的轨，界面上看着像"他共享着声音"，其实一点声都没有。
  Future<void> startScreenShare({
    String? sourceId,
    bool withAudio = false,
  }) async {
    if (_disposed || local.screenSharing) return;
    await local.startScreen(sourceId: sourceId, withAudio: withAudio);
    _publishView(view.value.copyWith(screenSharing: true));
    // 采集被**重建**时（共享的那扇窗最小化又回来，见 `desktop_screen_capture.dart`）
    // 把新轨挂回同一个 mid 上：不重新协商、服务端一行不改。
    local.addScreenTrackReplacedListener(_onScreenTrackReplaced);
    try {
      await _publishMutation('publish-screen', (side) async {
        final prepared = await side.pc.preparePublish(_shareTracks.toList());
        await _publishTracks(side, prepared);
      });
    } catch (_) {
      // 发布失败不能把界面留在"正在共享"上
      local.removeScreenTrackReplacedListener(_onScreenTrackReplaced);
      _publishView(view.value.copyWith(screenSharing: false));
      await local.stopScreen();
      rethrow;
    }
  }

  /// 停止共享屏幕：关掉那几路 track（带协商），再放掉采集。
  ///
  /// ⚠️ 「那几路」要在 `local.stopScreen()` **之前**记下来（见 [_shareTracks]）。
  /// 共享声音时是两路（`screen` + `screen-audio`），**少关一路就会在注册表里留下
  /// 一条没人管的轨** —— 别人一直订阅着一路永远没数据的流，而且他那边看起来
  /// "你还在共享"。
  Future<void> stopScreenShare() async {
    final side = _publish;
    // 停共享之后本机就不会再有"重建"这件事了（采集已经放掉）
    local.removeScreenTrackReplacedListener(_onScreenTrackReplaced);
    if (_disposed || side == null || !local.screenSharing) return;
    final names = _shareTracks
        .map((track) => track.name)
        .toList(growable: false);
    // 先放掉采集：这样万一这期间发生重建，"该发布的 track" 里已经没有它们了
    await local.stopScreen();
    _publishView(view.value.copyWith(screenSharing: false));
    await _closeScreenTracks(names);
  }

  /// 本机把共享采集**重建**了（被共享的那扇窗最小化又回来，见
  /// `desktop_screen_capture.dart`）：把新轨挂回原来的那个 mid 上。
  ///
  /// 重建后「该发布的哪几路」可能变了（原来带电脑声音、这次取不到声音了）：
  /// 发布过、而现在本机没有的那几路要顺手关掉 —— 否则别人一直订阅着一路永远
  /// 没数据的流，看着他那儿像是"你还在共享声音"。
  void _onScreenTrackReplaced() {
    unawaited(_swapScreenTracks());
  }

  Future<void> _swapScreenTracks() async {
    if (_disposed) return;
    if (!local.screenSharing) {
      // 本机重建不回来了（采集已经没了）：这一趟共享就此收尾 —— 界面回到
      // 「没在共享」，那几路发布也关掉（否则别人一直订阅着一路永远没数据的流）。
      local.removeScreenTrackReplacedListener(_onScreenTrackReplaced);
      _publishView(view.value.copyWith(screenSharing: false));
      final gone = <String>[
        for (final name in _publishedMids.keys)
          if (name.startsWith('screen')) name,
      ];
      trace.record(
        '共享采集重建失败：这一趟共享结束（关掉 ${gone.isEmpty ? '无' : gone.join('、')}）',
        failure: true,
      );
      if (gone.isNotEmpty) await _closeScreenTracks(gone);
      return;
    }
    final shared = <String>{for (final track in _shareTracks) track.name};
    final gone = <String>[
      for (final name in _publishedMids.keys)
        if (name.startsWith('screen') && !shared.contains(name)) name,
    ];
    if (gone.isNotEmpty) {
      trace.record('共享采集重建后少了几路：${gone.join('、')} → 关掉');
      await _closeScreenTracks(gone);
    }
    for (final name in shared) {
      if (_publishedMids[name] == null) continue;
      try {
        await _publishMutation('swap-screen', (side) async {
          final swapped = await side.pc.replaceTrackByName(name);
          if (swapped) {
            trace.record('共享采集重建：$name 已换到新轨（mid 不变）');
          } else {
            trace.record('共享采集重建：$name 没挂回去（这条发布可能已经不在）', failure: true);
          }
        });
      } on Object catch (error) {
        trace.record('共享采集重建：$name 换轨失败（$error）', failure: true);
      }
    }
  }

  /// 关掉几路共享轨（带协商，走发布会话那条队列）：停共享、以及采集重建后
  /// 少了几路，都从这走。
  ///
  /// 调用方负责在 [local] 那边先停掉采集（见 `_shareTracks` 的说明）。
  Future<void> _closeScreenTracks(List<String> names) async {
    final mids = <String>[
      for (final name in names)
        if (_publishedMids[name] != null) _publishedMids[name]!,
    ];
    if (mids.isEmpty) {
      for (final name in names) {
        _publishedMids.remove(name);
      }
      return;
    }
    try {
      await _publishMutation('close-screen', (current) async {
        final prepared = await current.pc.prepareClose(mids);
        final result = await control.closeTracks(
          sessionId: current.sessionId,
          mids: mids,
          sdpOffer: prepared?.sdp,
          force: prepared == null,
        );
        await _finishExchange(current, result, 'close-screen');
      });
    } finally {
      for (final name in names) {
        _publishedMids.remove(name);
      }
    }
  }

  /// 开关麦克风。**只关发出去的音**（对面听不到我），不是退出通话。
  ///
  /// 两步，顺序是硬的：
  /// ① 本机先静音 —— 用户按下去必须立刻生效，不能等服务端；
  /// ② 再把这件事**告诉服务端**（[SfuControlPlane.setMuted]）。
  ///
  /// 没有 ② 就是 2026-10-07 真机那个 bug：手机端 B 关掉麦克风，电脑端 A 那行
  /// 一直写"麦克风已开"—— A 读到的注册表还是 `tracks:["mic"]`（静音从来不写
  /// 注册表），而 A 没有别的信息可看。
  ///
  /// ② 失败**不算静音失败**：本机已经静了，只是别人看到的标记不对；留个
  /// [_mutePending] 让下一次心跳补报。反过来把 ① 回滚掉才是真的错 ——
  /// 用户按了静音，却发现自己的声音还在往外发。
  ///
  /// 待真机确认的一件事：CF 有"媒体 30 秒没有包就回收 track"的规则，而
  /// `enabled = false` 会让本端停止发包 —— 静音超过 30 秒再取消静音时，
  /// 这条 publication 可能已经被回收。已列为真机验收项（见契约文档）。
  Future<void> setMicrophoneEnabled(bool enabled) async {
    await local.setMicrophoneEnabled(enabled);
    await _announceMute(!enabled);
  }

  /// 把"我静音了 / 我开麦了"报到服务端（见 [SfuControlPlane.setMuted]）。
  ///
  /// 本机状态先落定，再尽力上报：报成功清掉 [_mutePending]，报失败留着它等心跳
  /// 重试。**不抛异常** —— 这一趟只是为了别人看得对，不该影响我自己的静音动作，
  /// 更不该把「静音」这个动作判成失败让用户重按。
  Future<void> _announceMute(bool muted) async {
    _micMuted = muted;
    _mutePending = true;
    try {
      await control.setMuted(roomId: roomId, muted: muted);
      _mutePending = false;
      trace.record('静音态已上报：${muted ? '静音中' : '开麦'}');
    } on Object catch (error) {
      trace.record('静音态上报失败（下次心跳再试）：$error', failure: true);
    }
  }

  /// 上一次退出房间时服务端对"这一通结束没结束"的交代。
  ///
  /// 只有真发过 `leave` 请求、且服务端认了这个房间才有值。用途只有一个：
  /// 最后一个走的人要往群里落一条通话记录（`announce == true`）。
  /// 一通话只认第一次拿到的"结束"：`dispose()` 兜底时会把 `leave()` 再走一遍，
  /// 不能把已经拿到的结论冲掉。
  SfuLeaveResult? get leaveResult => _leaveResult;
  SfuLeaveResult? _leaveResult;

  /// 离开房间：关两条会话、放掉采集。
  ///
  /// 回包里带着"这一通结束没结束"（房间空了的时候，服务端只让**一个人**拿到
  /// `announce`），控制器拿它去决定要不要往群里落那条通话记录。
  Future<void> leave() async {
    if (_disposed) return;
    _stopHeartbeat();
    _stopStateRefresh();
    _stopLevelPolling();
    trace.record('离开房间');
    _publishView(view.value.copyWith(phase: SfuRoomPhase.leaving));
    final ids = <String>[
      if (_publish != null) _publish!.sessionId,
      if (_receive != null) _receive!.sessionId,
    ];
    if (ids.isNotEmpty) {
      try {
        // closing：这一次是**退出通话**（不是重建时扔一条坏会话），
        // 所以服务端要顺便算"房间空了没有"
        final result = await control.leave(
          roomId: roomId,
          sessionIds: ids,
          closing: true,
        );
        // 已经拿到过"这一通由我收尾"就不再改口（第二次 leave 只是个空转）
        if (result.announce || _leaveResult == null) _leaveResult = result;
        if (result.announce) {
          trace.record(
            '房间空了：${result.participants} 人 / ${result.durationSeconds} 秒，记录由我落',
          );
        }
      } catch (error) {
        // 已经登不上的会话关不掉是正常的，不能因此卡住退出
        debugPrint('[群通话] 离开房间时关会话失败（忽略）：$error');
      }
    }
    await _publish?.pc.close();
    await _receive?.pc.close();
    _publish = null;
    _receive = null;
    _subscriptions.clear();
    _publishedMids.clear();
    _micPublished = false;
    // 静音态也要一起清：下一次进房间是全新的一通，不能带着上一通的静音标记
    _micMuted = false;
    _mutePending = false;
    _speaker.reset();
    // 采集要放掉了：那之后本机的"屏幕轨"不会再有重建这件事
    local.removeScreenTrackReplacedListener(_onScreenTrackReplaced);
    // 共享屏健康检查也停掉（房间都没了，那些 mid 已经作废）
    _stopScreenHealth();
    // 补订阅的快速重试也停：房间都没了，没有"订不上"这回事了
    _resetReconcileRetry();
    _mediaByMid.clear();
    await local.dispose();
    _micPublished = false;
    _publishView(const SfuRoomView());
  }

  /// 幂等：兜底路径（页面被直接销毁、控制器与测试都可能再调一次）不能把
  /// 已经放掉的 `view` 再放一遍。
  Future<void> dispose() async {
    if (_disposed) return;
    // 页面被直接销毁（没走挂断那条路）时的兜底：**先当作离房**，把两条会话关掉、
    // 采集放掉，再放掉这个对象自己。正常路径上 `leave()` 已经跑过，这里是空转。
    // （注册表那边还有行超时兜底（封顶 45 秒），但主动关干净更省心）
    await leave();
    _disposed = true;
    _stopHeartbeat();
    _stopStateRefresh();
    _stopLevelPolling();
    _stopScreenHealth();
    _resetReconcileRetry();
    await _publish?.incoming?.cancel();
    await _receive?.incoming?.cancel();
    await _incoming.close();
    await _dropped.close();
    view.dispose();
  }

  // ------------------------------------------------------------ 谁在说话

  void _startLevelPolling() {
    final interval = audioLevelPollInterval;
    if (interval == null || _levelPoller != null || _disposed) return;
    _levelPoller = Timer.periodic(
      interval,
      (_) => unawaited(pollAudioLevels()),
    );
  }

  void _stopLevelPolling() {
    _levelPoller?.cancel();
    _levelPoller = null;
  }

  /// 采一轮远端音频能量，算出"谁在说话"并发布给界面。
  ///
  /// 两条容易踩空的地方：
  /// * **只读接收会话**，而且**读不到就当作没人说话**（插件在有些平台不给
  ///   `audioLevel`，这不是错误，界面退回头像墙即可）；
  /// * mid 要**先归位到人**（接收侧的 mid 是我们订阅时服务端分配的，见
  ///   [_subscriptions]）；归不了位的直接丢掉。
  Future<void> pollAudioLevels() async {
    final side = _receive;
    if (_disposed || side == null) return;
    final Map<String, double> levels;
    try {
      levels = await side.pc.audioLevels();
    } catch (error) {
      debugPrint('[群通话] 读音频能量失败（忽略）：$error');
      return;
    }
    if (_disposed) return;
    final byMid = <String, String>{};
    for (final subscription in _subscriptions.values) {
      final mid = subscription.mid;
      if (mid != null && mid.isNotEmpty) byMid[mid] = subscription.userId;
    }
    final byUser = <String, double>{};
    for (final entry in levels.entries) {
      final userId = byMid[entry.key];
      if (userId != null) byUser[userId] = entry.value;
    }
    final speaker = _speaker.update(byUser, DateTime.now());
    if (speaker == view.value.activeSpeaker) return;
    _publishView(view.value.copyWith(activeSpeaker: speaker));
  }

  // ------------------------------------------------------------ 定期回查

  /// 还差订阅 → 排一次快速重试（不阻塞当前这次对账）。
  ///
  /// 退避只在**连续不成**时长：订齐了就 [ _resetReconcileRetry ] 回到 1 秒。
  void _scheduleReconcileRetry() {
    final base = reconcileRetryInterval;
    if (base == null || _disposed || !view.value.joined) return;
    final delay = _reconcileRetryDelay ?? base;
    final doubled = delay * 2;
    _reconcileRetryDelay = doubled > reconcileRetryMaxInterval
        ? reconcileRetryMaxInterval
        : doubled;
    _reconcileRetry?.cancel();
    _reconcileRetry = Timer(delay, () {
      _reconcileRetry = null;
      unawaited(_reconcileRetryTick());
    });
  }

  void _resetReconcileRetry() {
    _reconcileRetry?.cancel();
    _reconcileRetry = null;
    _reconcileRetryDelay = null;
  }

  /// 快速重试那一拍：拉一次快照、把差集再补一遍。
  ///
  /// `quiet`：状态没变就不记时间线（重试本来就不该刷屏）。
  Future<void> _reconcileRetryTick() async {
    if (_disposed || !view.value.joined) return;
    try {
      await refreshRoomState(quiet: true);
    } on Object catch (error) {
      debugPrint('[群通话] 补订阅重试没成（退一步再来）：$error');
    }
  }

  void _startStateRefresh() {
    final interval = stateRefreshInterval;
    if (interval == null || _stateRefresh != null || _disposed) return;
    _pollInterval = interval;
    _restartPollTimer(interval);
  }

  void _stopStateRefresh() {
    _stateRefresh?.cancel();
    _stateRefresh = null;
    _pollInterval = null;
  }

  void _restartPollTimer(Duration interval) {
    _stateRefresh?.cancel();
    _stateRefresh = Timer.periodic(
      interval,
      // `quiet`：状态没变就不记时间线（见 [refreshRoomState]）
      (_) => unawaited(_pollTick()),
    );
  }

  /// 一次定期回查：**服务端慢就退避**。
  ///
  /// 回查是兜底（WS 推送丢了也能对上账），频率本来是固定的 [stateRefreshInterval]
  /// （5 秒）。但服务端一抖（每次请求要几秒）时，固定频率就从「兜底」变成
  /// 「加压」：每个客户端每 5 秒再压一条进去，房间里人越多越糟，而界面反而
  /// 更不准（那些请求自己也在排队）。2026-10-06 在源站上量到的就是这种状态：
  /// 连 `checkVersion` 都要 1.7~6.3s，`sfu/room` 2.7~30s。
  ///
  /// 规则很简单：**这一趟慢（≥ [_slowPoll]）或失败 → 间隔 ×1.5（封顶
  /// [_maxPollInterval]）；一趟又快又好 → 回到配置的间隔**。健康时不损失兜底，
  /// 抖的时候不再往火上浇油。
  Future<void> _pollTick() async {
    if (_disposed || !view.value.joined) return;
    final startedAt = DateTime.now();
    try {
      await refreshRoomState(quiet: true);
      _notePollPeriod(
        DateTime.now().difference(startedAt) >= slowPollThreshold,
      );
    } on Object catch (error) {
      debugPrint('[群通话] 定期回查失败（退一步再试）：$error');
      _notePollPeriod(true);
    }
  }

  /// 退避的上限
  static const Duration _maxPollInterval = Duration(seconds: 30);

  void _notePollPeriod(bool slow) {
    final configured = stateRefreshInterval;
    final current = _pollInterval;
    if (configured == null || current == null || _stateRefresh == null) return;
    final scaled = current * 1.5;
    final next = slow
        ? (scaled > _maxPollInterval ? _maxPollInterval : scaled)
        : configured;
    if (next == current) return;
    _pollInterval = next;
    _restartPollTimer(next);
  }

  // ------------------------------------------------------------ 心跳

  void _startHeartbeat() {
    final interval = heartbeatInterval;
    if (interval == null || _heartbeat != null || _disposed) return;
    _heartbeat = Timer.periodic(interval, (_) => unawaited(_heartbeatTick()));
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  /// 叫一次心跳。
  ///
  /// 回包里的版本号和手里这份快照对不上，就说明"注册表变过、而那条 WS 推送没收到"
  /// —— 立刻重新拉快照对账（订阅差集在那边现算，所以顺带把漏掉的订阅也补上）。
  ///
  /// **心跳失败不做任何事**：会话真死了的话，下一次 publish / 订阅会自己发现并重建；
  /// 在这里重试只会变成"失败风暴"。
  Future<void> _heartbeatTick() async {
    if (_disposed || !view.value.joined || _heartbeatPending) return;
    _heartbeatPending = true;
    try {
      final beat = await control.heartbeat(roomId: roomId);
      trace.heartbeats += 1;
      // 顺手补报上次没送出去的静音态（见 [_announceMute]）：没报上去就等于别人
      // 一直看到错的麦克风标记，而这一趟本来就是"我还在、我的状态是这样"。
      if (_mutePending && !_disposed) await _announceMute(_micMuted);
      if (_disposed || beat.epoch == _snapshot.epoch) return;
      await refreshRoomState();
    } on SfuFailure catch (failure) {
      trace.heartbeatFailures += 1;
      debugPrint('[群通话] 心跳失败（忽略）：${failure.message}');
    } catch (error) {
      trace.heartbeatFailures += 1;
      debugPrint('[群通话] 心跳异常（忽略）：$error');
    } finally {
      _heartbeatPending = false;
    }
  }

  // ------------------------------------------------------------ 订阅对账

  /// 差集：`key -> 想要的订阅`
  Map<String, _Desired> _desiredOf(SfuRoomState snapshot) => <String, _Desired>{
    for (final member in snapshot.publishers)
      if (member.userId != myUserId && member.sessionId.isNotEmpty)
        for (final track in member.tracks)
          '${member.userId}|$track': _Desired(
            userId: member.userId,
            trackName: track,
            sessionId: member.sessionId,
          ),
  };

  /// 现在缺什么、多什么。
  ///
  /// 三种情况都要看出来：
  /// * 新出现的 track → 订上；
  /// * 消失的 track → 退订；
  /// * **同一条 track 但发布者换了发布会话 id**（他掉线重建了）→ 旧的订阅已经指向一条
  ///   死会话，必须**退订再重订**（只重订会重复分配，只退订会丢流）。
  ({List<String> add, List<String> remove}) _diffOf(
    Map<String, _Desired> desired,
  ) {
    final add = <String>[];
    final remove = <String>[];
    for (final entry in desired.entries) {
      final current = _subscriptions[entry.key];
      if (current == null) {
        add.add(entry.key);
      } else if (current.sessionId != entry.value.sessionId) {
        remove.add(entry.key);
        add.add(entry.key);
      }
    }
    for (final key in _subscriptions.keys) {
      if (!desired.containsKey(key)) remove.add(key);
    }
    return (add: add, remove: remove);
  }

  /// **差集在操作内部现算**（不是外面算好传进来）：
  /// 这样会话被重建、订阅表被清空之后，重试会老老实实把该订的全部订回来。
  Future<void> _applyDiff(_SfuSide side, Map<String, _Desired> desired) async {
    final diff = _diffOf(desired);
    if (diff.remove.isEmpty && diff.add.isEmpty) return;
    trace.record('对账：新增 ${diff.add.length} / 退订 ${diff.remove.length}');
    if (diff.remove.isNotEmpty) {
      await _closeSubscriptions(side, diff.remove);
    }
    if (diff.add.isNotEmpty) {
      await _addSubscriptions(side, diff.add, desired);
    }
  }

  Future<void> _closeSubscriptions(_SfuSide side, List<String> keys) async {
    final mids = <String>[
      for (final key in keys)
        if (_subscriptions[key]?.mid != null) _subscriptions[key]!.mid!,
    ];
    if (mids.isEmpty) {
      // 本来就没有 mid（还没订上），直接抹掉记录
      for (final key in keys) {
        _subscriptions.remove(key);
      }
      _syncScreenHealth();
      return;
    }
    trace.closes += 1;
    final prepared = await side.pc.prepareClose(mids);
    final result = await control.closeTracks(
      sessionId: side.sessionId,
      mids: mids,
      sdpOffer: prepared?.sdp,
      force: prepared == null,
    );
    await _finishExchange(side, result, 'close-subscription');
    for (final key in keys) {
      _subscriptions.remove(key);
    }
    // 退订之后别再盯着那几路（它们已经不在了）
    for (final mid in mids) {
      _streamWatch.forget(mid);
      _stalledAt.remove(mid);
      _mediaByMid.remove(mid);
    }
    _syncScreenHealth();
  }

  Future<void> _addSubscriptions(
    _SfuSide side,
    List<String> keys,
    Map<String, _Desired> desired,
  ) async {
    trace.subscribes += 1;
    // 订阅**不带本地 offer**：SFU 会回一个 offer，我们作答后交给 renegotiate
    final result = await control.subscribe(
      sessionId: side.sessionId,
      tracks: <Map<String, dynamic>>[
        for (final key in keys)
          <String, dynamic>{
            'session_id': desired[key]!.sessionId,
            'track_name': desired[key]!.trackName,
          },
      ],
    );
    final offer = result.sdpOffer;
    if (offer == null) {
      // 没有 offer 就是这一批都没订上：不记名，下次刷新重算时会再试
      debugPrint('[群通话] 订阅没有返回 SFU offer，这一批先不记');
      trace.record('订阅失败：SFU 没返回 offer（${keys.length} 条）', failure: true);
      return;
    }
    // 响应里逐条给出**接收侧**的 mid：靠它把 onTrack 收到的流对回"谁的哪条 track"。
    // **先记账再作答**：远端描述一设上就开始收流（onTrack 可能比 renegotiate 早），
    // 那时若还没记账，这路流会被当成"不认识的 mid"丢掉。
    final added = _recordSubscriptions(keys, desired, result.tracks);
    try {
      final answer = await side.pc.answerSfuOffer(offer);
      trace.renegotiates += 1;
      await control.renegotiate(sessionId: side.sessionId, sdpAnswer: answer);
      if (!await side.pc.waitConnected(connectTimeout)) {
        throw SfuFailure.fromCode(
          SfuCodes.upstreamUnreachable,
          '订阅后 ICE 没能连通（可能要走 TURN）',
          label: 'subscribe',
        );
      }
    } catch (error) {
      // 没谈成：把刚记的账撤掉（否则差集以为"已经订上了"，再也不会重订）
      for (final key in added) {
        _subscriptions.remove(key);
      }
      rethrow;
    }
  }

  /// 把这一批订阅记上账，返回**真的记上的那些 key**
  List<String> _recordSubscriptions(
    List<String> keys,
    Map<String, _Desired> desired,
    List<SfuTrackResult> tracks,
  ) {
    final byTrackName = <String, SfuTrackResult>{
      for (final track in tracks) track.trackName: track,
    };
    final added = <String>[];
    for (final key in keys) {
      final wanted = desired[key]!;
      final track = byTrackName[wanted.trackName];
      if (track == null || !track.succeeded || (track.mid ?? '').isEmpty) {
        // 逐条失败（HTTP 200 里的 per-track error）：不记名，下次刷新会对上
        debugPrint(
          '[群通话] 订阅 ${wanted.userId}/${wanted.trackName} 没成：'
          '${track?.errorCode ?? 'no result'} ${track?.errorDescription ?? ''}',
        );
        trace.record(
          '订阅 ${wanted.userId}/${wanted.trackName} 没成：'
          '${track?.errorCode ?? 'no result'}',
          failure: true,
        );
        continue;
      }
      _subscriptions[key] = _Subscription(
        userId: wanted.userId,
        trackName: wanted.trackName,
        sessionId: wanted.sessionId,
        mid: track.mid,
      );
      added.add(key);
      trace.record('订阅 ${wanted.userId}/${wanted.trackName} → ${track.mid}');
    }
    // 有共享屏可盯了就开检查（没有人共享时它是不跑的，见 [_syncScreenHealth]）
    _syncScreenHealth();
    return added;
  }

  // ------------------------------------------------------------ 发布

  Future<void> _publishTracks(_SfuSide side, SfuPreparedSdp prepared) async {
    trace.publishes += 1;
    final result = await control.publish(
      sessionId: side.sessionId,
      sdpOffer: prepared.sdp,
      tracks: <Map<String, dynamic>>[
        for (final entry in prepared.mids.entries)
          <String, dynamic>{'track_name': entry.key, 'mid': entry.value},
      ],
    );
    await _finishExchange(side, result, 'publish');
    trace.record('发布已交回上游（接着等建连）');
    // CF 的硬要求：应用完 answer / 交回 answer 之后要**等到 ICE 连上**
    // 才在这一条会话上继续改（没连上还接着发请求，等于把改动盖在一条死连接上）。
    // 等不到就按「结果未知」处理：会话毒化 → 换新会话重建。
    if (!await side.pc.waitConnected(connectTimeout)) {
      throw SfuFailure.fromCode(
        SfuCodes.upstreamUnreachable,
        '发布后 ICE 没能连通（可能要走 TURN）',
        label: 'publish',
      );
    }
    _publishedMids.addAll(prepared.mids);
    trace.record('与上游建连完成');
    final accepted = <String>{
      for (final track in result.tracks)
        if (track.succeeded) track.trackName,
    };
    trace.record(
      '发布 ${prepared.mids.length} 条：'
      '${prepared.mids.entries.map((entry) => '${entry.key}→${entry.value}').join('、')}'
      '（上游接受了 ${accepted.isEmpty ? '0' : accepted.join('、')} 条）',
    );
    for (final track in result.failedTracks) {
      debugPrint(
        '[群通话] track ${track.trackName} 发布失败：'
        '${track.errorCode} ${track.errorDescription}',
      );
      trace.record(
        'track ${track.trackName} 发布失败：'
        '${track.errorCode} ${track.errorDescription}',
        failure: true,
      );
    }
    // **一条都没被接受** = 这次发布是白做的。不报出来的话，界面会一直显示
    // 「已进房间、麦克风已开」，而别人其实一个字都听不到 —— 真机上最难查的
    // 就是这种“看起来全好、就是没人听得见”。
    final missing = prepared.mids.keys
        .where((name) => !accepted.contains(name))
        .toList(growable: false);
    // 只在**有逐条结果**时才据此判失败：上游整段没给 `tracks` 时我们判不了，
    // 那时以注册表（`micPublished`）为准，不把一个不确定的回包当成硬失败。
    if (missing.isNotEmpty && accepted.isEmpty && result.tracks.isNotEmpty) {
      throw SfuFailure(
        kind: SfuFailureKind.rejected,
        message:
            '上游没有接受任何一个 track（${missing.join('、')}），'
            '别人听不到/看不到我',
        code: SfuCodes.badRequest,
        label: 'publish',
      );
    }
  }

  /// 收下一次 SDP 交换。
  ///
  /// 对称性很重要：**发布/关轨这两条路径过去只看 `sdpAnswer`**，把 CF 回过来的
  /// offer（`requires_renegotiation`）直接丢掉了 —— 本地既没有可应用的 answer，
  /// CF 那边也还在等我们的回答，而那一步已经被记成成功了。
  /// 真机上就是这么长出来的：进房间、能看见别人、按钮说「麦克风已开」，
  /// 但别人听不到、共享屏也没人看到。
  ///
  /// 订阅那条路径本来就处理了 offer（它天生是 CF 出 offer），这里把它抽出来，
  /// 三条路径用同一个口子。
  Future<void> _finishExchange(
    _SfuSide side,
    SfuExchangeResult result,
    String label,
  ) async {
    final answer = result.sdpAnswer;
    if (answer != null && answer.isNotEmpty) {
      await side.pc.applyAnswer(answer);
      return;
    }
    final offer = result.sdpOffer;
    if (offer == null || offer.isEmpty) return;
    final mine = await side.pc.answerSfuOffer(offer);
    trace.renegotiates += 1;
    await control.renegotiate(sessionId: side.sessionId, sdpAnswer: mine);
    trace.record('$label：SFU 回的是 offer，已作答并交回');
  }

  // ------------------------------------------------------------ 队列与重建

  /// 发布侧的改动。
  ///
  /// 会话被判死时不重放操作：**重建本身就会把"该发布的 track"整体重发一遍**
  /// （`local.publishableTracks`），那已经覆盖了任何一次待发布的意图。
  Future<void> _publishMutation(
    String label,
    Future<void> Function(_SfuSide side) operation,
  ) async {
    final side = await _ensurePublish();
    try {
      await side.queue.run(label, () => operation(side));
    } on SfuFailure catch (failure) {
      if (!failure.requiresRebuild) rethrow;
      trace.record(
        '$label 失败：${failure.label}（${failure.message}）→ 重建发布会话',
        failure: true,
      );
      await _startPublishRebuild();
      final fresh = _publish;
      if (fresh == null || fresh.queue.isPoisoned) rethrow;
    }
  }

  /// 接收侧的改动：会话判死后重建再重试一次（差集在操作内部现算，
  /// 所以重试会把被清空的订阅表该订的全部订回来）。
  ///
  /// 重试**只重试一次**：再失败就往外抛，等下一次房间快照刷新时自愈
  /// （刷新由 WS 推送驱动，不会因此把房间卡死）。
  Future<void> _receiveMutation(
    String label,
    Future<void> Function(_SfuSide side) operation,
  ) async {
    final side = await _ensureReceive();
    try {
      await side.queue.run(label, () => operation(side));
    } on SfuFailure catch (failure) {
      if (!failure.requiresRebuild) rethrow;
      trace.record(
        '$label 失败：${failure.label}（${failure.message}）→ 重建接收会话',
        failure: true,
      );
      await _startReceiveRebuild();
      // 重建只把旧会话丢掉，新会话是**用的时候才建**，所以这里要走
      // `_ensureReceive()` 现建一条出来再重试（直接读 `_receive` 会是 null）。
      final fresh = await _ensureReceive();
      await fresh.queue.run('$label-retry', () => operation(fresh));
    }
  }

  Future<_SfuSide> _ensurePublish() async {
    await _publishRebuild;
    final current = _publish;
    if (current != null && !current.queue.isPoisoned) return current;
    final side = await _createSide('publish');
    _publish = side;
    _watchPoison(side, _startPublishRebuild);
    return side;
  }

  Future<_SfuSide> _ensureReceive() {
    // 同一个 purpose 同一时刻**只允许一次建会话在飞**：预建（`join()` 里与发布侧
    // 同时着手）与首次对账会同时来问，两个调用方都看到 `_receive == null`
    // 各建一条 —— 会凭空多出一条没人管的会话（真机上就是房间里多一个幽灵成员）。
    final inFlight = _receiveCreating;
    if (inFlight != null) return inFlight;
    final future = _openReceive();
    _receiveCreating = future;
    unawaited(
      // 失败由调用方处理（这里只是把账清掉）
      future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_receiveCreating, future)) _receiveCreating = null;
      }),
    );
    return future;
  }

  Future<_SfuSide> _openReceive() async {
    await _receiveRebuild;
    final current = _receive;
    if (current != null && !current.queue.isPoisoned) return current;
    final side = await _createSide('receive');
    _receive = side;
    _watchPoison(side, _startReceiveRebuild);
    return side;
  }

  /// 预建接收会话（不 await，失败只记日志）：`join()` 里与发布侧同时着手。
  ///
  /// 它只是省一趟往返（建会话那条请求）；真失败了也没关系 —— 紧接着的
  /// `refreshRoomState()` 会自己再建一次（那条路带重建重试）。
  Future<void> _prewarmReceive() async {
    try {
      await _ensureReceive();
    } on Object catch (error) {
      debugPrint('[群通话] 预建接收会话失败（忽略，马上会再试）：$error');
    }
  }

  Future<_SfuSide> _createSide(String purpose) async {
    final sessionId = await control.createSession(
      roomId: roomId,
      purpose: purpose,
    );
    if (sessionId.isEmpty) {
      throw const SfuFailure(
        kind: SfuFailureKind.rejected,
        message: '服务端没有返回会话 id',
        code: SfuCodes.badRequest,
        label: 'session',
      );
    }
    final side = _SfuSide(
      purpose: purpose,
      sessionId: sessionId,
      pc: connectionFactory(),
    );
    _watchIncoming(side);
    return side;
  }

  /// 收远端媒体：按 mid 认回"谁的哪条 track"，认不出来的丢（不猜）。
  ///
  /// 只有**接收会话**上的 track 才是订阅来的；发布会话上收到的（如果有）不认。
  void _watchIncoming(_SfuSide side) {
    side.incoming = side.pc.incomingTracks.listen((track) {
      if (_disposed || side.purpose != 'receive') return;
      final owner = _ownerOfMid(track.mid);
      if (owner == null) {
        // 重建期间旧 mid 作废、或这一路还没记上账：丢掉比乱挂到别人身上好
        debugPrint('[群通话] 收到不认识的 mid(${track.mid})，先丢');
        return;
      }
      final media = SfuIncomingMedia(
        userId: owner.userId,
        trackName: owner.trackName,
        kind: track.kind,
        stream: track.stream,
      );
      // 留一份：判「这一路已经死了」时要把**同一份**交回界面
      _mediaByMid[track.mid] = media;
      if (_incoming.isClosed) return;
      _incoming.add(media);
      // 视频那一路（共享屏）要盯健康：收不到新帧就自己把画面放下来
      if (track.kind == 'video') _syncScreenHealth();
    });
  }

  // ------------------------------------------------------------ 共享屏健康

  /// 有共享屏可盯就开检查、没有就关掉（没人在共享时连 `getStats` 都不发）。
  void _syncScreenHealth() {
    final wanted = <String>[
      for (final subscription in _subscriptions.values)
        if (subscription.trackName == 'screen' &&
            (subscription.mid ?? '').isNotEmpty)
          subscription.mid!,
    ];
    if (wanted.isEmpty || _disposed) {
      _stopScreenHealth();
      return;
    }
    // 有共享屏可盯了。定时器可能没开（[screenHealthInterval] 为 null 时就是
    // 用例自己调 [pollScreenHealth]），那时检查依旧要做。
    _watchScreen = true;
    _streamWatch.keep(wanted);
    final interval = screenHealthInterval;
    if (interval == null || _screenHealth != null) return;
    _screenHealth = Timer.periodic(
      interval,
      (_) => unawaited(pollScreenHealth()),
    );
  }

  void _stopScreenHealth() {
    _watchScreen = false;
    _screenHealth?.cancel();
    _screenHealth = null;
    _stalledAt.clear();
    _streamWatch.reset();
  }

  /// 采一轮「共享屏还在不在收」（见 [SfuStreamWatch]）：不涨够了就把这一路放下来。
  ///
  /// ⚠️ **不碰注册表、也不退订**：订阅关系归快照对账管（对方真走了的话，最多
  /// 45 秒那条行超时会把他清掉，那时按差集关门）。这里只解决用户盯着最后一张
  /// 死图这件事。
  @visibleForTesting
  Future<void> pollScreenHealth() async {
    final side = _receive;
    // 没人在共享时连统计都不问（那一条 getStats 没必要发）
    if (_disposed || side == null || !_watchScreen) return;
    final Map<String, int> counters;
    try {
      counters = await side.pc.inboundVideoCounters();
    } on Object catch (error) {
      debugPrint('[群通话] 读视频收流计数失败（忽略）：$error');
      return;
    }
    if (_disposed) return;
    // 先看「之前判死的有没有又活了」：判死之后那一路只要再涨一次，就把画面接回来
    for (final mid in _stalledAt.keys.toList(growable: false)) {
      final value = counters[mid];
      if (value == null || value == _stalledAt[mid]) continue;
      _stalledAt.remove(mid);
      _reviveStalledScreen(mid);
    }
    for (final mid in _streamWatch.tick(counters, _now())) {
      _stalledAt[mid] = counters[mid] ?? -1;
      _dropStalledScreen(mid);
    }
  }

  /// 判死过的那一路**又开始出帧**了（静态画面被误判，或对方重开了共享）：接回来。
  ///
  /// 订阅一直还在（判死时**不退订**），所以这里只是把同一份交回界面 —— 不需要
  /// 重新发布/订阅，也就不会在两个客户端之间来回重谈。
  void _reviveStalledScreen(String mid) {
    final media = _mediaByMid[mid];
    if (media == null) return;
    trace.record('共享屏又出帧了：${media.userId}/${media.trackName} → 画面接回来');
    if (_incoming.isClosed) return;
    _incoming.add(media);
  }

  /// 这一路共享已经**本机判定断了**（画面停在最后一帧）：告诉界面把画面放下来。
  void _dropStalledScreen(String mid) {
    final owner = _ownerOfMid(mid);
    if (owner == null || owner.trackName != 'screen') return;
    _streamWatch.forget(mid);
    final media = _mediaByMid[mid];
    trace.record(
      '共享屏卡死：${owner.userId} 的 ${owner.trackName} 连续 '
      '${screenStallTimeout.inSeconds} 秒没有新帧 → 把画面放下来',
      failure: true,
    );
    if (media == null || _dropped.isClosed) return;
    _dropped.add(media);
  }

  ({String userId, String trackName})? _ownerOfMid(String mid) {
    if (mid.isEmpty) return null;
    for (final subscription in _subscriptions.values) {
      if (subscription.mid == mid) {
        return (userId: subscription.userId, trackName: subscription.trackName);
      }
    }
    return null;
  }

  /// 换一条新会话：丢掉旧的（尽力关掉）、建新的、把该做的重做一遍
  Future<void> _rebuildPublish() async {
    final old = _publish;
    trace.rebuilds += 1;
    trace.record('重建发布会话（旧 ${old?.sessionId ?? '无'}）');
    _publish = null;
    await _discardSide(old);
    _publishView(view.value.copyWith(phase: SfuRoomPhase.rebuilding));
    try {
      // 这里**不能**走 `_ensurePublish`：它会 await 在飞的重建，而那个在飞的
      // 就是本方法自己 —— 会死锁。重建过程自己造一条侧。
      final side = await _createSide('publish');
      _publish = side;
      _watchPoison(side, _startPublishRebuild);
      await side.queue.run('republish', () async {
        final prepared = await side.pc.preparePublish(local.publishableTracks);
        await _publishTracks(side, prepared);
      });
      _publishView(view.value.copyWith(phase: SfuRoomPhase.joined));
    } on SfuFailure catch (failure) {
      _publishView(
        view.value.copyWith(phase: SfuRoomPhase.failed, error: failure.message),
      );
    }
  }

  Future<void> _rebuildReceive() async {
    final old = _receive;
    trace.rebuilds += 1;
    trace.record('重建接收会话（旧 ${old?.sessionId ?? '无'}）');
    _receive = null;
    // 订阅表清空：新会话上的 mid 全是新的，旧记录全部作废
    _subscriptions.clear();
    await _discardSide(old);
    // 接收侧没有需要主动重做的事（订阅由差集驱动、建会话是懒的），
    // 所以这里把界面从"重建中"放回"已加入"：真正的重订紧接着就会跑。
    if (!_disposed && view.value.phase == SfuRoomPhase.rebuilding) {
      _publishView(view.value.copyWith(phase: SfuRoomPhase.joined));
    }
  }

  Future<void> _discardSide(_SfuSide? side) async {
    if (side == null) return;
    await side.incoming?.cancel();
    side.incoming = null;
    try {
      await control.leave(roomId: roomId, sessionIds: <String>[side.sessionId]);
    } catch (error) {
      // 死会话关不掉很正常
      debugPrint('[群通话] 丢弃旧会话失败（忽略）：$error');
    }
    await side.pc.close();
  }

  /// 去重：同一时刻只允许一次重建在飞（毒化回调与调用方可能同时触发）
  Future<void> _startPublishRebuild() {
    final inFlight = _publishRebuild;
    if (inFlight != null) return inFlight;
    final future = _rebuildPublish();
    _publishRebuild = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_publishRebuild, future)) _publishRebuild = null;
      }),
    );
    return future;
  }

  Future<void> _startReceiveRebuild() {
    final inFlight = _receiveRebuild;
    if (inFlight != null) return inFlight;
    final future = _rebuildReceive();
    _receiveRebuild = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_receiveRebuild, future)) _receiveRebuild = null;
      }),
    );
    return future;
  }

  void _watchPoison(_SfuSide side, Future<void> Function() rebuild) {
    side.queue.onPoisoned = (_) {
      if (_disposed) return;
      _publishView(view.value.copyWith(phase: SfuRoomPhase.rebuilding));
      unawaited(rebuild());
    };
  }

  // ------------------------------------------------------------ 视图

  /// 注册表原文一行（诊断用）：`3:mic+screen(我) ｜ 7:（空）`
  String _describeMembers(SfuRoomState snapshot) {
    if (snapshot.members.isEmpty) return '（注册表空）';
    return snapshot.members
        .map(
          (member) =>
              '${member.userId}'
              '${member.userId == myUserId ? '(我)' : ''}:'
              '${member.tracks.isEmpty ? '（空）' : member.tracks.join('+')}',
        )
        .join(' ｜ ');
  }

  /// 注册表里**我自己**那一行发布了哪些 track（没有那一行时是空表）
  Set<String> _myPublishedTracks(SfuRoomState snapshot) {
    for (final member in snapshot.members) {
      if (member.userId == myUserId) return member.tracks.toSet();
    }
    return const <String>{};
  }

  List<SfuParticipant> _participantsOf(SfuRoomState snapshot) =>
      <SfuParticipant>[
        for (final member in snapshot.members)
          SfuParticipant(
            userId: member.userId,
            // 有声音 = "**发布了**麦克风" **且** "**没在静音**"。两个都要看：
            // * 只看 tracks：静音的人被画成"麦克风已开"（2026-10-07 真机的 bug）；
            // * 只看 muted：没进房间的人也会算进来。
            // `tracks` 里那条 `mic` 一直不拆是刻意的（拆了对方就退订，取消静音时
            // 重发布一旦失败，对方就再也听不到我）—— 所以静音只能靠服务端那个
            // 单独字段带过来，见 `SfuControlPlane.setMuted`。
            audio: member.tracks.contains('mic') && !member.muted,
            screen: member.tracks.contains('screen'),
            isMe: member.userId == myUserId,
          ),
      ];

  /// 发布视图。**`micPublished` 一律由这里注入**：它是"注册表里我有没有 mic"
  /// 这一个事实，散在各调用点写就会漂（出现过按钮说开着、成员行说已静音）。
  void _publishView(SfuRoomView next) {
    if (_disposed) return;
    view.value = next.copyWith(
      micPublished: _micPublished,
      micPublishPending: _publishPending,
    );
  }
}

/// 一条想要的订阅
class _Desired {
  const _Desired({
    required this.userId,
    required this.trackName,
    required this.sessionId,
  });

  final String userId;
  final String trackName;
  final String sessionId;
}

/// 一条已建立的订阅
class _Subscription {
  _Subscription({
    required this.userId,
    required this.trackName,
    required this.sessionId,
    required this.mid,
  });

  final String userId;
  final String trackName;

  /// 订阅时用的**发布者发布会话 id**：他重建换了 id 就要重订（[SfuRoom._diffOf]）
  final String sessionId;

  final String? mid;
}
