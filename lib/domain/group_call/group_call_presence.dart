import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';

/// **正在进行的群语音**里，屋子外面的人需要知道的那几样（S6.15）。
///
/// 与 `group_call_push.dart`（离线推送那条）的分工：
///
/// * 那条推给**App 没在跑**的人（弹系统通知、响铃、点进去加入）；
/// * 这一条是**人就在 App 里**时用的 —— 长连接那条 `sfuRoom` 事件谁在线谁收得到，
///   收到之后要的是两件轻得多的事：屏幕上飘一条「张三 邀请你加入群语音」的横幅，
///   以及会话列表那一行挂上「语音通话中」。
///
/// 所以这里**不弹系统通知、不响铃**：人就在手机前面看着，再响一声是骚扰
/// （离线推送那块已经把「不在线的人」包了）。
@immutable
class GroupCallLive {
  const GroupCallLive({
    required this.conversationId,
    required this.roomId,
    required this.callId,
    required this.groupName,
    required this.starterName,
    required this.started,
    this.members,
  });

  /// 群会话 id（`group-100`）：会话列表按它挂标记、横幅按它进群通话页
  final String conversationId;

  /// SFU 房间号（`100`）：回查房间状态时用它
  final String roomId;

  /// 这一通群语音的 id（服务端编的；用来分辨前后两通）
  final String callId;

  /// 群名（服务端只在「这一通刚开」那一次带；之后进来的事件里没有，就留住上一份）
  final String groupName;

  /// 发起人的昵称（同上，只有「刚开」那一次有）
  final String starterName;

  /// 这一通是不是**刚开**：只有它会弹横幅。
  ///
  /// 之后有人陆续进来，服务端推的 `live` 事件不带这个标记 —— 那时候横幅已经弹过了，
  /// 再弹一次就成了骚扰（与离线推送里「只有第一笔推」同一个理由）。
  final bool started;

  /// 屋里现在几个人（服务端 `members`；数不出来时是 null）。
  ///
  /// 群聊页顶上那条「N 人正在语音通话 · 加入」用它；拿不到就退化成不带人数的说法
  /// —— 人数只影响那句话好不好看，不该成为「这条提示显不显示」的判据。
  final int? members;

  /// 「这一通」的身份证：忽略过的那几通靠它记住（服务端没给 id 时退回会话 id）。
  String get inviteKey => callId.isNotEmpty ? callId : conversationId;

  /// 服务端那条事件里有没有跟这一通有关的信息（决定要不要吵醒界面）
  bool get isMeaningful => groupName.isNotEmpty || starterName.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is GroupCallLive &&
      other.conversationId == conversationId &&
      other.roomId == roomId &&
      other.callId == callId &&
      other.groupName == groupName &&
      other.starterName == starterName &&
      other.started == started &&
      other.members == members;

  @override
  int get hashCode => Object.hash(
    conversationId,
    roomId,
    callId,
    groupName,
    starterName,
    started,
    members,
  );

  @override
  String toString() =>
      'GroupCallLive($conversationId, call=$callId, live=$roomId'
      '${started ? ', 刚开' : ''}${groupName.isEmpty ? '' : ' $groupName'})';
}

/// 房间号（服务端给的是数字群号）→ 群会话 id（`group-100`）。
///
/// 两头的形状不一样是有历史原因的：SFU 那边只认数字群号（成员校验就是
/// `GroupUser.group_id`），而会话列表那边一直是 `group-<数字>`（见 `Contact`）。
/// 与 `GroupCallController` 里的 `groupCallRoomId()` 互为反函数。
String groupConversationIdOfRoom(String roomId) {
  final id = roomId.trim();
  if (id.isEmpty) return '';
  return id.startsWith('group-') ? id : 'group-$id';
}

/// 群会话 id → 房间号（`group-100` → `100`；已经是数字就原样）
String groupRoomIdOfConversation(String conversationId) {
  final id = conversationId.trim();
  const prefix = 'group-';
  return id.startsWith(prefix) ? id.substring(prefix.length) : id;
}

/// 回查一间屋子「现在还有没有人」。
///
/// 返回 `true` 还有人 / `false` 空了 / `null` **拿不准**（网络失败 —— 这时候什么都别改，
/// 免得把一场正在进行的语音从界面上抹掉）。
typedef GroupCallRoomProbe = Future<bool?> Function(String roomId);

/// 谁在开群语音（S6.15）。一个进程一份，喂给两类界面：应用内横幅与会话列表标记。
///
/// 数据来源只有一条：服务端 `Sfu.php::bumpEpoch` 推的 `sfuRoom` 事件
/// （有人进来 / 走了 / 换了会话都会 bump 一次，载荷里带 `live` / `call_id` /
/// 第一次那一次的 `started` / `name` / `starter`）。
///
/// 三条容易写错的地方，各自都有用例钉住：
///
/// * **我就在那间屋里时不提示**：我自己开的、或我正开着群通话页的那个房间，
///   推来的事件要忽略（否则会给自己弹一条「邀请你加入」）；
/// * **老服务端要当没看见**：载荷里没有 `live` 的事件一律丢掉 —— 那说明服务端的
///   `Sfu.php` 还没换成新版，不能凭一条 `epoch` 变化猜「有人在开语音」；
/// * **房间空了要收掉**：`live = false` 就把这一条从名单里去掉（会话列表那行标记
///   跟着消失），并且**不能**因此把它当成「新的一通」再弹一次横幅。
///
/// 还不止于此的一条兜底：屋里最后一个人的 App 被杀时，服务端要等下一次有人碰这间屋
/// 才会发现它空了（没有定时任务可用），所以手里有标记时**每 45 秒回查一次**
/// （见 [verify]）—— 那一次回查同时会把服务端的残骸清掉（`Sfu::room` 里带 prune）。
class GroupCallPresenceTracker extends ChangeNotifier {
  GroupCallPresenceTracker({
    this._probe,
    this._verifyInterval = const Duration(seconds: 45),
  });

  /// 会话 id → 那一通（Dart 的 Map 保持插入顺序，所以「最新的一通」就是最后一个）
  final Map<String, GroupCallLive> _live = <String, GroupCallLive>{};

  /// 已经「忽略」或「我人已经进去了」的那几通（按 [GroupCallLive.inviteKey] 记）：
  /// 不再弹横幅，但**列表标记照留**（它只是「这个群在开语音」这个事实）
  final Set<String> _muted = <String>{};

  final GroupCallRoomProbe? _probe;
  final Duration? _verifyInterval;

  Timer? _timer;

  /// 正在进行的群语音（会话列表挂标记用；顺序是「先开始的在前」）
  List<GroupCallLive> get liveCalls =>
      List<GroupCallLive>.unmodifiable(_live.values);

  /// 这个会话现在有没有语音在开（没有就是 null）
  GroupCallLive? liveIn(String conversationId) => _live[conversationId];

  /// 该弹一条横幅的那一通：**最新**的一通「刚开」的语音，且我没忽略过它。
  ///
  /// 只认「刚开」那一次（`started`）：中途进来的人不该让已经在用 App 的人又被提示一次。
  GroupCallLive? get pendingInvite {
    for (final call in _live.values.toList(growable: false).reversed) {
      if (call.started && !_muted.contains(call.inviteKey)) return call;
    }
    return null;
  }

  /// 服务端推来一条 `sfuRoom`（[data] 就是事件里的 `data` 层）。
  ///
  /// [inRoomId] 是**我此刻所在的那个房间号**（没在通话里就是空串）：那间屋子的
  /// 变化不提示（我自己就在里面）。
  void onRoomEvent(Map<String, dynamic> data, {String inRoomId = ''}) {
    final roomId = asText(data['room_id']).trim();
    final live = _boolOrNull(data['live']);
    // 没有 `live` 的事件 = 老服务端（或别的路径推的）：只当没看见，
    // 不能凭一条 epoch 变化猜「有人在开语音」
    if (roomId.isEmpty || live == null) return;
    if (inRoomId.isNotEmpty && groupRoomIdOfConversation(inRoomId) == roomId) {
      return;
    }

    final conversationId = groupConversationIdOfRoom(roomId);
    if (!live) {
      _forget(conversationId);
      return;
    }

    final previous = _live[conversationId];
    final callId = asText(data['call_id']).trim();
    final sameCall = previous != null && previous.callId == callId;
    final started = _boolOrNull(data['started']) ?? false;
    final name = asText(data['name']).trim();
    final starter = asText(data['starter']).trim();
    final members = asInt(data['members'], -1);

    _live[conversationId] = GroupCallLive(
      conversationId: conversationId,
      roomId: roomId,
      callId: callId,
      // 群名与发起人只有「刚开」那一次带；其余的合并进来，别把已经知道的信息抹掉
      groupName: name.isNotEmpty ? name : (previous?.groupName ?? ''),
      starterName: starter.isNotEmpty ? starter : (previous?.starterName ?? ''),
      // 同一通的后续事件不能把「刚开」这个标记擦掉（横幅可能正挂在屏幕上）
      started: started || (sameCall && previous.started),
      // 人数同理（老服务端根本不推 `members`）：同一通里留住上一份，
      // 换了一通才按事件里的值重算
      members: members >= 0 ? members : (sameCall ? previous.members : null),
    );
    _syncTimer();
    notifyListeners();
  }

  /// 我进了那间屋（本机或别人点进来的都算）：把它的提示收掉。
  ///
  /// 进去之后这一通就不再是「别人开的语音」了 —— 横幅、标记都该让位给通话页本身。
  /// 忽略是按 `call_id` 记的，所以这一通后续的事件也不会再把它弹回来。
  void onJoinedRoom(String conversationId) {
    final call = _live.remove(conversationId);
    if (call != null) _muted.add(call.inviteKey);
    _syncTimer();
    notifyListeners();
  }

  /// 用户把这条横幅按掉了（或者它自己过时了）：这一通不再提示。
  /// **列表标记不受影响** —— 语音还在开，那个事实不变。
  void dismiss(GroupCallLive call) {
    if (!_muted.add(call.inviteKey)) return;
    notifyListeners();
  }

  /// 回查一遍：手里这些记号还成立吗。
  ///
  /// 为什么需要它：屋里最后一个人的 App 被杀时，服务端没人去碰那间屋子，就发现不了
  /// 它空了（没有定时任务可用，这也在预算之外），那条 `live = false` 于是永远推不出来。
  /// 手里有标记时每 [GroupCallPresenceTracker] 的 `verifyInterval` 跑一次，
  /// 靠 `Sfu::room` 快照问一次真相（那一次同时会把服务端的残骸清掉）。
  ///
  /// 拿不准（网络失败）时**什么都不改**：宁可多显示一会儿，也不要把正在进行的语音
  /// 从界面上抹掉（一次抖动就收掉横幅，比多挂 45 秒糟得多）。
  Future<void> verify() async {
    final probe = _probe;
    if (probe == null) return;
    for (final call in _live.values.toList(growable: false)) {
      final bool? alive;
      try {
        alive = await probe(call.roomId);
      } on Object catch (error) {
        debugPrint('[群通话] 回查房间失败（保持原状）：$error');
        continue;
      }
      if (alive == false) _forget(call.conversationId);
    }
  }

  /// 退出登录之类的整段清空
  void reset() {
    _timer?.cancel();
    _timer = null;
    if (_live.isEmpty && _muted.isEmpty) return;
    _live.clear();
    _muted.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  // ------------------------------------------------------------------ 内部

  void _forget(String conversationId) {
    if (_live.remove(conversationId) == null) return;
    _syncTimer();
    notifyListeners();
  }

  /// 有标记才起定时器，记号全没了就停掉（平时一个定时器都不占）
  void _syncTimer() {
    final interval = _verifyInterval;
    if (interval == null || _probe == null) return;
    if (_live.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(interval, (_) => unawaited(verify()));
  }

  /// 取「有/没有」的三态：字段不在（老服务端）与 `false`（房间空了）是两回事
  static bool? _boolOrNull(Object? value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final text = value.trim().toLowerCase();
      if (text == '1' || text == 'true') return true;
      if (text == '0' || text == 'false') return false;
    }
    return null;
  }
}
