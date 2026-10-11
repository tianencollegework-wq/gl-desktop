import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/call_keep_alive.dart';
import '../../core/platform/call_pip.dart';
import '../../core/store/session_store.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/api/sfu_api.dart';
import '../../data/media/sfu_local_media.dart';
import '../../data/media/sfu_peer_connection.dart';
import '../../data/model/conversation.dart';
import '../../data/repo/group_admin_repository.dart';
import '../../data/repo/message_sender.dart';
import '../../domain/chat/group_members.dart';
import '../../domain/group_call/group_call_hub.dart';
import '../../domain/group_call/sfu_room.dart';

/// 群通话里的一个人（**名单来自群成员接口，状态来自房间快照**）。
///
/// 两者合在一起的理由：注册表里只有 user_id（它不认识名字/头像），而群成员接口
/// 里只有名单（它不认识谁在通话）—— 界面要的是"这一行是谁、他在不在、在不在说、
/// 有没有共享屏幕"。
@immutable
class GroupCallMember {
  const GroupCallMember({
    required this.userId,
    required this.name,
    required this.avatar,
    required this.isMe,
    required this.inCall,
    required this.audio,
    required this.screen,
    required this.speaking,
  });

  final String userId;
  final String name;
  final String avatar;
  final bool isMe;

  /// 在通话里（发布了麦克风或屏幕；自己进房间即算）
  final bool inCall;

  /// 发布了麦克风
  final bool audio;

  /// 在共享屏幕
  final bool screen;

  /// 此刻在说话（见 `SfuSpeakerTracker`）
  final bool speaking;
}

/// 界面要看的全部状态（房间状态机 + 名单 + 本机开关）
@immutable
class GroupCallView {
  const GroupCallView({
    this.phase = SfuRoomPhase.idle,
    this.members = const <GroupCallMember>[],
    this.activeSpeakerId,
    this.screen,
    this.micEnabled = true,
    this.micPublished = false,
    this.micPublishPending = false,
    this.screenSharer,
    this.screenSharing = false,
    this.supportsScreenShare = false,
    this.inPip = false,
    this.error = '',
  });

  final SfuRoomPhase phase;

  /// 全群成员（**含没进通话的**，界面自己决定画哪些）
  final List<GroupCallMember> members;

  /// 此刻在说话的人（可能为 null：插件不给能量、或没人说话）
  final String? activeSpeakerId;

  /// 收到的共享屏（谁的哪条流；没人共享时为 null）
  final SfuIncomingMedia? screen;

  /// 我的麦克风开着（按钮的开关态）——这是**我的意图**，点一下就会变
  final bool micEnabled;

  /// 我的麦克风**真的发布出去了**（注册表里我那一行带着 `mic`）——这是**事实**。
  ///
  /// 两者必须分开：意图管按钮，事实管那行警告（不发布成功时得说出来，
  /// 但绝不能把按钮锁死 —— 那会让用户"点多少次都开不了麦"）。
  final bool micPublished;

  /// 我的麦克风**正在发布中**（进房间那几秒里就是它）：这段时间里
  /// 「注册表还没写上我的 mic」不代表出问题了，所以那行红字要等它落定再说话。
  final bool micPublishPending;

  /// **别人**正在共享屏幕的那个人（我自己在共享时是 null）。
  ///
  /// 共享屏同一时刻只允许一个人：SFU 那边没有这个限制，两个人同时开就会互相打架
  /// （注册表里两条 `screen`，观看端只认其中一条，而且两边都要重协商），
  /// 所以由客户端这一层拦住第二个人的话。
  final GroupCallMember? screenSharer;

  /// 我在共享屏幕
  final bool screenSharing;

  /// 这台设备能不能共享屏幕（安卓的系统投屏；不能就**不画那颗按钮**）
  final bool supportsScreenShare;

  /// 这一通正缩在**系统小窗**（画中画）里：界面这时只画内容，**一个按钮都不画**
  /// （进了 PiP 之后触摸被系统接管，点一下是「展开 / 菜单」，按钮画上去也点不到）。
  final bool inPip;

  /// 进不去时的原因（给界面看的那句话）
  final String error;

  /// 通话中的人（头像墙与成员面板画这些人）
  List<GroupCallMember> get inCallMembers =>
      members.where((member) => member.inCall).toList(growable: false);
}

/// 群通话的控制器：把房间状态机（`SfuRoom`）、群成员名单、本机开关与保活串起来。
///
/// 它与 1:1 的 `CallController` 是一个分工：**信令/媒体时序在 `SfuRoom` 里**
/// （那部分是纯逻辑、有单测），这里只管"界面要什么"：
///
/// * 名单：注册表只给 user_id，名字/头像来自群成员接口（拉不到就只显示群成员四个字，
///   绝不因此让通话失败）；
/// * 共享屏幕的三步顺序（**Android 14 的硬要求**：先拿到投屏同意 → 再把前台服务
///   类型升上 `mediaProjection` → 最后才取流）—— 与 1:1 那条路径逐字一致；
/// * 保活：进房间起前台服务（群里没有"视频通话"这回事，类型是 mic），退出即停。
///
/// 它**不碰媒体本身**：音视频是 端点 ↔ Cloudflare 直连，远端音频由 WebRTC 自己
/// 从系统输出，这里只需要拿到共享屏那一路画面给界面。
class GroupCallController {
  GroupCallController({
    required this.groupName,
    required this.room,
    required this.loadMembers,
    required this.keepAlive,
    required this.notify,
    this.notice,
    this.hub,
    this.writeRecord,
    this.pip,
  }) {
    // 进了 / 出了小窗：原生说了算（界面据此切成「只有内容」的样子）
    pip?.addModeListener(_onPipModeChanged);
  }

  /// "正在进行的群通话"登记处：WS 推来 `sfuRoom` 时靠它找到这个房间
  /// （不传就是不接那条推送，对账只靠心跳的版本号）。
  final GroupCallHub? hub;

  /// 群名（保活通知上那句「与 {name} 语音通话中」用它）
  final String groupName;

  final SfuRoom room;

  /// 群成员名单（失败返回空表即可，不能影响进房间）
  final Future<List<GroupMember>> Function() loadMembers;

  final CallKeepAlive keepAlive;

  /// 提示（真正的弹层在 `NoticeBus`；这里只报 key，与 1:1 同一个做法）
  final void Function(String key) notify;

  /// 带**名字**的提示（「张三 已离开通话」）。
  ///
  /// 为什么单独一个：[notify] 只认 key、带不了参数，而这种提示缺了名字就等于
  /// 没说（用户 2026-10-08 报的就是「看不到对方已离开」）。不传就是只更新界面、
  /// 不飘字。
  final void Function(String key, String name)? notice;

  /// 通话结束后往群里落记录的那个动作（不传就是不落，测试里方便）。
  final GroupCallRecordWriter? writeRecord;

  /// 通话小窗（画中画）。不传（iOS/桌面）就是没有小窗这回事。
  final CallPip? pip;

  final ValueNotifier<GroupCallView> view = ValueNotifier<GroupCallView>(
    const GroupCallView(),
  );

  Map<String, GroupMember> _roster = <String, GroupMember>{};
  SfuIncomingMedia? _screen;
  bool _micEnabled = true;
  bool _keepAliveStarted = false;
  bool _disposed = false;

  /// 原生说「进了小窗」
  bool _inPip = false;

  /// 已经把小窗参数交给系统了（进过房间）；没进过房间时不用收尾
  bool _pipEngaged = false;
  String _pipTitle = '';

  /// 这条记录只落一次（`hangup()` 与 `dispose()` 都会来问一遍）
  bool _recordDone = false;
  StreamSubscription<SfuIncomingMedia>? _media;
  StreamSubscription<SfuIncomingMedia>? _dropped;

  /// 上一轮「谁在通话里」（`userId → 在不在`）：用来发现「有人刚离开」并飘一条字
  Map<String, bool> _inCall = <String, bool>{};

  /// 进房间：拉名单（尽力而为）→ 起保活 → 采媒体、建会话、订阅全屋
  Future<void> start() async {
    if (_disposed) return;
    // 先登记：进房间那一串要花几秒（采媒体、建会话、订阅），这期间别人进来／走了
    // 照样会推 `sfuRoom` —— 登记之后那些推送就能推到这次对账上
    hub?.attach(room);
    room.view.addListener(_sync);
    _media = room.incomingMedia.listen(_onIncoming);
    _dropped = room.droppedMedia.listen(_onDropped);
    _sync();
    await _loadRoster();
    try {
      await room.join();
    } on Object catch (error) {
      // `join()` 已经把阶段与错误文案写进 view 了（这里只吞掉异常，
      // 让界面停在「进不去」上而不是炸掉这一页）
      debugPrint('[群通话] 进房间失败：$error');
    }
    // ⚠️ 保活要放在**采到媒体之后**（麦克风是在 `join()` 里拿的）——与 1:1 的
    // `_openMedia` 同一个口径，也是 Android 14 的硬要求：`microphone` 类型的
    // 前台服务有 while-in-use 校验，而首次通话时 RECORD_AUDIO 还没授权
    // （那一步就是 `join()` 里 getUserMedia 弹的框）。先起服务会被系统直接拒掉，
    // 后果是整通电话没有常驻通知（切后台就被冻结）、而且屏幕共享也跟着一起坏
    // （取投影必须已经有带 mediaProjection 类型的服务在跑）。
    if (!_disposed && room.view.value.phase != SfuRoomPhase.failed) {
      await _startKeepAlive();
    }
    // 媒体已经在 `join()` 里采到了：把声音切到免提（与 1:1 那条一样，
    // 在“刚拿到媒体”的时候做一次）。不切的话安卓按通话模式默认走听筒，
    // 群里别人说话会小得像在远处 —— 微信群语音默认就是免提。
    await _applySpeaker(true);
    _sync();
  }

  /// 把音频路由切到免提/听筒。失败只记日志：路由切不过去不该把整通电话弄挂
  /// （与 1:1 的 `_applySpeaker` 逐字同一个取舍）。
  Future<void> _applySpeaker(bool enabled) async {
    try {
      await room.local.setSpeakerEnabled(enabled);
    } on Object catch (error) {
      debugPrint('[群通话] 设置音频路由失败（忽略）：$error');
    }
  }

  /// 开关麦克风。**只关发出去的音**（对面听不到我），不是退出通话。
  Future<void> toggleMicrophone() async {
    if (_disposed) return;
    final next = !_micEnabled;
    try {
      await room.setMicrophoneEnabled(next);
      _micEnabled = next;
      _sync();
    } on Object catch (error) {
      debugPrint('[群通话] 开关麦克风失败：$error');
      notify('group.callMicFailed');
    }
  }

  /// 共享屏幕 / 停止共享。
  ///
  /// ⚠️ 顺序是硬要求（Android 14），与 1:1 那条路径完全一致：
  /// ① 系统投屏授权 → ② 前台服务类型升上 `mediaProjection` → ③ 取流发布。
  /// 写反了 `getMediaProjection()` 会直接抛 SecurityException。
  ///
  /// [sourceId] 是**桌面**上用户选的那个源（整个屏幕 / 某个窗口，S12.38）：
  /// 由界面先弹 `showScreenSharePicker` 拿到，再一路带到 `getDisplayMedia`
  /// （安卓上不用，走系统那个投屏框）。不传 = 系统默认源（主屏）。
  /// [withAudio] = 连**电脑的声音**一起发（桌面，S12.39）。只有在传了新
  /// [sourceId] 的那一次才有意义（也就是电脑上刚选完源）：停共享、安卓那条路
  /// 都不看它。
  Future<void> toggleScreenShare({
    String? sourceId,
    bool withAudio = false,
  }) async {
    if (_disposed) return;
    if (view.value.screenSharing) {
      await _stopScreenShare();
      return;
    }
    if (!view.value.supportsScreenShare) return;
    // 已经有人在共享：**不许抢**。拦住并说清原因（那颗钮这时是灰的，
    // 灰只说明"现在不该点"，点一下才知道为什么）。
    if (view.value.screenSharer != null) {
      notify('group.callShareTaken');
      return;
    }

    // ① 投屏授权（会弹系统框，App 被顶到后台；取投影不做 while-in-use 校验，
    //    所以这里没有"后台起服务"的翻车风险）
    final bool granted;
    try {
      granted = await room.local.requestScreenSharePermission();
    } on Object catch (error) {
      debugPrint('[群通话] 请求投屏授权失败：$error');
      notify('call.shareFailed');
      return;
    }
    if (!granted) {
      notify('call.shareRefused');
      return;
    }
    // 弹框那几秒里可能已经退出了/断了
    if (_disposed || view.value.phase != SfuRoomPhase.joined) return;

    // ② 前台服务带上 mediaProjection 类型
    if (!await _setServiceScreenSharing(true)) {
      notify('call.shareFailed');
      return;
    }

    // ③ 取屏幕流并作为第二路 track 发布（开了「连电脑的声音」就是两路）
    try {
      await room.startScreenShare(sourceId: sourceId, withAudio: withAudio);
    } on Object catch (error) {
      debugPrint('[群通话] 共享屏幕失败：$error');
      await _setServiceScreenSharing(false); // 回滚类型位
      notify('call.shareFailed');
      return;
    }
    _sync();
  }

  Future<void> _stopScreenShare() async {
    try {
      await room.stopScreenShare();
    } on Object catch (error) {
      debugPrint('[群通话] 停止共享失败：$error');
      notify('call.shareFailed');
    }
    await _setServiceScreenSharing(false);
    _sync();
  }

  /// 通话页左上角那颗「缩成小窗」：**立刻**进画中画（不用按 Home）。
  ///
  /// 与 1:1 那颗（`CallController.minimizeToPip`）是同一件事：进不进得去由系统
  /// 决定（部分 ROM 关掉了画中画），所以失败只记一行日志、**绝不影响这一通**。
  /// 进去之后界面会收到 `onModeChanged`，自己切成「只有内容」。
  Future<void> minimizeToPip() async {
    final pip = this.pip;
    if (_disposed || pip == null || !pip.supported) return;
    try {
      await pip.enter();
    } on Object catch (error) {
      debugPrint('[群通话] 缩成小窗失败：$error');
    }
  }

  /// 挂断（离开房间）：关两条会话、停保活、必要时往群里落一条通话记录。
  /// **幂等**，退出流程里随便调。
  Future<void> hangup() async {
    if (_disposed) return;
    hub?.detach(room);
    _releasePip();
    try {
      await room.leave();
    } on Object catch (error) {
      debugPrint('[群通话] 退出时关会话失败（忽略）：$error');
    }
    await _writeCallRecord();
    await _stopKeepAlive();
    if (!_disposed) _sync();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    room.view.removeListener(_sync);
    hub?.detach(room);
    await _media?.cancel();
    await _dropped?.cancel();
    await _stopKeepAlive();
    _releasePip();
    // 直接退出（没点挂断）时，`room.dispose()` 自己会补一次 leave ——
    // 那一次的回包里同样可能带着"这一通由我收尾"
    await room.dispose();
    await _writeCallRecord();
    view.dispose();
  }

  /// 房间空了 → 最后一个走的人往群里落一条通话记录（微信里那条「通话时长 12:30」）。
  ///
  /// 三件事保证群里只有一条：
  /// * 服务端 `leave` 回包只让一个人拿到 `announce`（两个人同时挂断也一样，
  ///   仲裁见 `Sfu.php::claimClosed`）；
  /// * `participants < 2` 不落 —— 一个人点进去又出来，不该在群里留一条；
  /// * 控制器自己只写一次（`hangup()` 与 `dispose()` 都会来问一遍）。
  ///
  /// 发失败不重试：它是一条普通消息，失败会就地标红，用户可以自己点重发。
  Future<void> _writeCallRecord() async {
    final writer = writeRecord;
    if (writer == null || _recordDone) return;
    final result = room.leaveResult;
    if (result == null || !result.announce) return;
    _recordDone = true;
    if (result.participants < 2) {
      debugPrint('[群通话] 只有我一个人进过房间，不留通话记录');
      return;
    }
    try {
      await writer(
        seconds: result.durationSeconds,
        participants: result.participants,
      );
    } on Object catch (error) {
      debugPrint('[群通话] 落通话记录失败（忽略）：$error');
    }
  }

  // ------------------------------------------------------------- 名单

  Future<void> _loadRoster() async {
    try {
      final list = await loadMembers();
      if (_disposed) return;
      _roster = <String, GroupMember>{
        for (final member in list) member.userId: member,
      };
    } on Object catch (error) {
      // 名单拉不到不影响通话：界面上那些人会显示成「群成员」
      debugPrint('[群通话] 群成员名单取不到（只影响显示名字）：$error');
    }
  }

  /// 把"房间里的人"与"群成员名单"合成一份（在通话的排前面，我在最前）
  List<GroupCallMember> _membersOf() {
    final roomView = room.view.value;
    final inCall = <String, SfuParticipant>{
      for (final participant in roomView.participants)
        participant.userId: participant,
    };
    final members = <GroupCallMember>[];
    for (final entry in inCall.entries) {
      final participant = entry.value;
      final member = _roster[entry.key];
      members.add(
        GroupCallMember(
          userId: entry.key,
          name: member?.name ?? '',
          avatar: member?.avatar ?? '',
          isMe: participant.isMe,
          inCall: true,
          // 我自己那一行的"有没有声音"要看**我的意图**：注册表里我只说了"我发布过
          // 一条 mic"，它不知道我中途按了静音（静音只是本端不再发包，`mic` 这一条
          // 一直挂在注册表上）。不用意图的话，按钮写「麦克风已关」而成员行写
          // 「麦克风已开」（用户报过的"状态对不上"就是这一类）。
          audio: participant.isMe
              ? _micEnabled && participant.audio
              : participant.audio,
          screen: participant.screen,
          speaking: roomView.activeSpeaker == entry.key,
        ),
      );
    }
    for (final member in _roster.values) {
      if (inCall.containsKey(member.userId)) continue;
      members.add(
        GroupCallMember(
          userId: member.userId,
          name: member.name,
          avatar: member.avatar,
          isMe: member.userId == room.myUserId,
          inCall: false,
          audio: false,
          screen: false,
          speaking: false,
        ),
      );
    }
    members.sort((a, b) {
      if (a.isMe != b.isMe) return a.isMe ? -1 : 1;
      if (a.inCall != b.inCall) return a.inCall ? -1 : 1;
      return 0;
    });
    return members;
  }

  // ------------------------------------------------------------- 内部

  void _sync() {
    if (_disposed) return;
    final roomView = room.view.value;
    _noteDepartures();
    // 共享屏只留"当前正在共享那个人"的那一路：注册表说没人共享了（或换人了），
    // 手里这份流就已经过期（对方会把 track 关掉，画面会冻在最后一帧）
    final sharing = roomView.participants
        .where((participant) => participant.screen)
        .toList(growable: false);
    if (sharing.isEmpty || _screen?.userId != sharing.first.userId) {
      _screen = null;
    }
    final members = _membersOf();
    view.value = GroupCallView(
      phase: roomView.phase,
      members: members,
      screenSharer: _sharerAmong(members),
      activeSpeakerId: roomView.activeSpeaker,
      screen: _screen,
      // 按钮的开关态 = **我自己的意图**（能点、点了就变），
      // 「到底发出去没有」由通话页顶上那行警告单独说。
      //
      // ⚠️ 这里曾经写成 `_micEnabled && micPublished` —— 结果是发布没落地时
      // 按钮永远是关的、点多少次都不动（用户报的「开不了麦」）。
      // 意图与事实必须分成两个信号：按钮管意图，警告管事实。
      micEnabled: _micEnabled,
      micPublished: roomView.micPublished,
      micPublishPending: roomView.micPublishPending,
      screenSharing: roomView.screenSharing,
      supportsScreenShare: room.local.supportsScreenShare,
      inPip: _inPip,
      error: roomView.error,
    );
    _syncPip();
  }

  /// 别人正在共享屏幕的那个人（我自己在共享时不算），没有就是 null
  GroupCallMember? _sharerAmong(List<GroupCallMember> members) {
    for (final member in members) {
      if (member.inCall && member.screen && !member.isMe) return member;
    }
    return null;
  }

  void _onIncoming(SfuIncomingMedia media) {
    if (_disposed) return;
    // 远端音频不用界面管：WebRTC 自己从系统输出放（屏幕那路视频要画出来才要它）
    if (media.trackName != 'screen') return;
    _screen = media;
    _sync();
  }

  /// 本机判定**那一路共享已经断了**（收不到新帧，见 `SfuStreamWatch`）：
  /// 把画面放下来 + 说一声。
  ///
  /// 为什么不能等注册表：那条链要等心跳/行超时（封顶 45 秒），推送也可能丢 ——
  /// 而用户就盯着一张死图（2026-10-08 报的就是这个）。
  void _onDropped(SfuIncomingMedia media) {
    if (_disposed || media.trackName != 'screen') return;
    final current = _screen;
    // 只认「我正挂着的那一份」：别人已经换了新画面时不误伤
    if (current == null || !identical(current.stream, media.stream)) return;
    _screen = null;
    _sync();
    // 名字拿不到也给空串（接线那边会用「群成员」顶上）——画面已经放下来了，
    // 这一句只是告诉用户「刚才那一路是怎么没的」
    notice?.call('group.callShareLost', _nameOfUser(media.userId));
  }

  /// 有人刚退出通话（或掉线被行超时清掉）：飘一条字。
  ///
  /// 光靠头像消失太轻了 —— 用户看到的是一张卡住的图，根本不会注意到名单少了一人。
  void _noteDepartures() {
    // 只在「还在房间里」时算：退出 / 进不去那一刻名单会被清空（`SfuRoomView()`），
    // 那不是「他们走了」，而是「这一页散了」
    if (_disposed || room.view.value.phase != SfuRoomPhase.joined) return;
    // 顺序有讲究：字典里**后面的键覆盖前面的**，所以先铺全名单的 false，
    // 再用房间里的参与者盖成 true（写反了会把所有人都算成"不在通话"）
    final now = <String, bool>{
      for (final member in _roster.keys) member: false,
      for (final participant in room.view.value.participants)
        participant.userId: true,
    };
    for (final entry in _inCall.entries) {
      final wasInCall = entry.value;
      final stillInCall = now[entry.key] ?? false;
      // 只报「刚走的」：从前就不在房间里的人不算，还在的更不算
      if (!wasInCall || stillInCall) continue;
      if (entry.key == room.myUserId) continue; // 我自己走了不飘字
      notice?.call('group.callMemberLeft', _nameOfUser(entry.key));
    }
    _inCall = now;
  }

  /// `userId` → 能显示的名字（名单里没有就给空串：宁可不说，也不要飘一句 `u12`）
  String _nameOfUser(String userId) => _roster[userId]?.name ?? '';

  /// 原生说「进了 / 出了小窗」。
  ///
  /// 界面据此切成「只有内容」（进去）与恢复（出来）；同一状态重复报就什么都不做，
  /// 免得白重画一次——通话里状态变化很频繁。
  void _onPipModeChanged(bool inPip) {
    if (_disposed || _inPip == inPip) return;
    _inPip = inPip;
    _sync();
  }

  /// 小窗（画中画）的策略 —— 与 1:1 那条（`CallController._syncPip`）同一套口径。
  ///
  /// **只有点通话页左上角那颗才进小窗**（按 Home / 切到别的应用都不进，那几种情况
  /// 靠前台服务 + 常驻通知）。所以这里只做两件事：
  ///
  /// 1. 这一通在跑的时候把**比例与标题**交给系统（点按钮那一刻原生要用）；
  /// 2. 这一通结束（含被挂断、进不去）时把已经打开的小窗**收掉** —— 不收的话
  ///    会留一个「小窗里是聊天列表」的怪状态。
  ///
  /// ⚠️ 比例固定用语音那一档（1:1 方块）：群通话的主内容是头像墙/说话人那块卡片，
  /// 方块最贴（共享屏那一路在小窗里用 `contain` 完整放下，四周留黑边）。
  void _syncPip() {
    final pip = this.pip;
    if (pip == null || !pip.supported || _disposed) return;

    if (!_pipActive) {
      if (!_pipEngaged) return; // 幂等：还没进过房间时每次 `_sync` 都会走到这里
      _pipEngaged = false;
      _pipTitle = '';
      unawaited(_exitPip());
      return;
    }

    if (_pipEngaged && groupName == _pipTitle) return; // 参数没变：不打通道
    _pipEngaged = true;
    _pipTitle = groupName;
    unawaited(_applyPipParams(groupName));
  }

  /// 这一通算不算"在进行中"（小窗只在这几段里有意义）
  bool get _pipActive {
    final phase = room.view.value.phase;
    return phase == SfuRoomPhase.joining ||
        phase == SfuRoomPhase.joined ||
        phase == SfuRoomPhase.rebuilding;
  }

  /// 把「比例 + 标题」交给系统（不开自动缩窗）。失败只记日志：小窗是体验，
  /// 绝不能让这一通因为它挂掉（与 1:1 同一条）。
  Future<void> _applyPipParams(String title) async {
    final pip = this.pip;
    if (pip == null) return;
    try {
      await pip.setParams(video: false, title: title);
    } on Object catch (error) {
      debugPrint('[群通话] 设置画中画参数失败：$error');
    }
  }

  /// 通话结束时把小窗收掉（不在小窗里就什么都不发生）
  Future<void> _exitPip() async {
    final pip = this.pip;
    if (pip == null) return;
    try {
      if (await pip.isInPip()) await pip.exit();
    } on Object catch (error) {
      debugPrint('[群通话] 退出画中画失败：$error');
    }
  }

  /// 收尾（挂断 / `dispose` / 换账号）：摘掉监听并把小窗收掉。
  ///
  /// 摘监听这件事**必须**做：小窗通道是全进程一条，群通话这一通结束了
  /// 还挂着它的监听，会把 1:1 那边的窗口状态接走（写成 setter 更糟：谁后注册
  /// 谁说了算）。
  void _releasePip() {
    final pip = this.pip;
    if (pip == null) return;
    pip.removeModeListener(_onPipModeChanged);
    _inPip = false;
    _pipEngaged = false;
    _pipTitle = '';
    unawaited(_exitPip());
  }

  Future<void> _startKeepAlive() async {
    if (!keepAlive.supported) return;
    try {
      await keepAlive.start(video: false, peerName: groupName);
      _keepAliveStarted = true;
    } on Object catch (error) {
      // 保活失败绝不影响这通话（与 1:1 同一条原则）
      debugPrint('[群通话] 前台服务没起来（忽略）：$error');
    }
  }

  Future<void> _stopKeepAlive() async {
    if (!_keepAliveStarted) return;
    _keepAliveStarted = false;
    try {
      await keepAlive.stop();
    } on Object catch (error) {
      debugPrint('[群通话] 停前台服务失败（忽略）：$error');
    }
  }

  /// 共享期间把前台服务的类型加上/去掉 `mediaProjection`（返回是否成功）。
  ///
  /// 服务没起来时**现起一个**：共享屏幕是用户刚点的，这一刻我们确实在前台、也确实
  /// 在用麦克风 —— 正是 Android 14 允许起 mic 类型前台服务的那一刻。
  /// 从前这里是直接跳过，而 Android 14 取投影**必须**已经有带 `mediaProjection`
  /// 类型的服务在跑：跳过 == 把共享屏判死（`getDisplayMedia` 必抛 SecurityException）。
  Future<bool> _setServiceScreenSharing(bool enabled) async {
    if (!keepAlive.supported) return true;
    if (!_keepAliveStarted) {
      // 停共享：服务本来就没在跑，什么都不用做
      if (!enabled) return true;
      await _startKeepAlive();
      // 还是起不来：如实判失败，不去取一个注定抛异常的投影
      if (!_keepAliveStarted) return false;
    }
    try {
      await keepAlive.setScreenSharing(enabled: enabled);
      return true;
    } on Object catch (error) {
      debugPrint('[群通话] 设置前台服务共享类型失败：$error');
      return false;
    }
  }
}

/// 群会话 id（`group-5`）→ SFU 房间号。
///
/// 服务端注册表的 `room_id` 存的是**数字群号**（成员校验就是
/// `GroupUser.group_id`），所以这里剥掉会话前缀；服务端两种形状都认
/// （`5` / `group-5` / 加密串），发数字那份是为了排查时一眼能对上。
String groupCallRoomId(String conversationId) {
  const prefix = 'group-';
  return conversationId.startsWith(prefix)
      ? conversationId.substring(prefix.length)
      : conversationId;
}

/// 造一个群通话控制器（参数是**群会话 id** 与群名）。
///
/// 做成工厂而不是单例：群通话是**用户点进去**才有的（没有来电那套被推送叫醒），
/// 一次会话一个控制器，退出就整个放掉 —— 与 1:1 那个常驻控制器不同。
typedef GroupCallControllerFactory =
    GroupCallController Function({
      required String conversationId,
      required String name,
    });

/// 往群里落一条通话记录（最后一个走的人做这件事，见 [GroupCallController.writeRecord]）。
typedef GroupCallRecordWriter =
    Future<void> Function({required int seconds, required int participants});

final groupCallControllerFactoryProvider = Provider<GroupCallControllerFactory>(
  (ref) {
    final control = ref.watch(sfuApiProvider);
    // ⚠️ 媒体与连接工厂都从 provider 里取**同一份**（连接工厂靠 `trackOf` 认识
    // 本机轨道；两份实例的话发布出去的 track 名找不到轨道，mid 就是空的）
    final local = ref.watch(sfuLocalMediaProvider);
    final connections = ref.watch(sfuConnectionFactoryProvider);
    return ({required String conversationId, required String name}) {
      final room = SfuRoom(
        roomId: groupCallRoomId(conversationId),
        myUserId: ref.read(sessionStoreProvider).userId,
        control: control,
        local: local,
        connectionFactory: connections,
      );
      final members = ref.read(groupAdminRepositoryProvider);
      return GroupCallController(
        groupName: name,
        room: room,
        hub: ref.read(groupCallHubProvider),
        loadMembers: () async =>
            (await members.members(conversationId)).members,
        keepAlive: ref.read(callKeepAliveProvider),
        // 小窗（画中画）：与 1:1 共用同一条原生通道（`gracelinkim/pip`）——
        // 监听表是按回调分的，两边互不顶掉（见 `CallPip.addModeListener`）
        pip: ref.read(callPipProvider),
        notify: (key) => noticeBus.toast(AppI18n.instance.t(key)),
        // 「谁走了 / 谁的共享断了」这两条要带名字（`notify` 只认 key）。
        // 名字拿不到（群名单还没拉回来）时用界面那套兜底词 `group.user`。
        notice: (key, name) => noticeBus.toast(
          AppI18n.instance.t(key, <String, String>{
            'name': name.isEmpty ? AppI18n.instance.t('group.user') : name,
          }),
        ),
        // 群里的通话记录（微信里那条「通话时长 12:30」）：走**发消息那条老路**
        // （未读、离线推送、会话预览都由服务端在 `im/sendMessage` 上顺手做掉）
        writeRecord: ({required int seconds, required int participants}) async {
          final me = ref.read(sessionStoreProvider).user;
          if (me == null) return;
          await ref
              .read(messageSenderProvider)
              .sendGroupCallRecord(
                conversation: Conversation(
                  id: conversationId,
                  displayName: name,
                  isGroup: 1,
                ),
                me: me,
                seconds: seconds,
                participants: participants,
                translate: AppI18n.instance.t,
              );
        },
      );
    };
  },
);
