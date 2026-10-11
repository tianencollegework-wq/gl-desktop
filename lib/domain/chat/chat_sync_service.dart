import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'message_notifier.dart';
import '../../core/net/api_exception.dart';
import '../../core/store/hidden_conversations.dart';
import '../../core/store/session_store.dart';
import '../../core/util/json_value.dart';
import '../../core/ws/ws_event.dart';
import '../../core/ws/ws_client.dart';
import '../../core/ws/ws_handlers.dart';
import '../../core/ws/ws_router.dart';
import '../../core/ws/ws_service.dart';
import '../../data/api/auth_api.dart';
import '../../data/model/conversation.dart';
import '../../data/model/message.dart';
import '../../data/repo/contact_repository.dart';
import '../../data/repo/conversation_repository.dart';
import '../../data/repo/message_repository.dart';
import '../call/call_controller.dart';

/// 聊天链路（S4.0）：把服务端推来的消息与状态变化接进本地库。
///
/// 对应老端 `App.vue` 里那几个分支（`simple` / `group` / `isOnline` /
/// `setChatTop` / `setIsNotice` / `undoMessage`）＋ `appendMessage`。
/// 老端这套逻辑是"读整份 storage → 改 → 写回整份"，且未读只活在内存里；
/// 这里全部落到 SQLite，界面订阅流就能动。
class ChatSyncService {
  ChatSyncService(
    this._ref,
    this._ws,
    this._conversations,
    this._messages,
    this._contacts,
    this._auth,
    this._notifier,
  );

  final Ref _ref;
  final WsService _ws;
  final ConversationRepository _conversations;
  final MessageRepository _messages;
  final ContactRepository _contacts;
  final AuthApi _auth;
  final MessageNotifier _notifier;

  /// 系统消息未读数（老端 `msgStore.sysUnread`：只加不减，进系统会话时才清）
  final ValueNotifier<int> systemUnread = ValueNotifier<int>(0);

  bool _started = false;

  /// 上一次的连接状态：只在「从非 connected 变成 connected」时补一次消息
  WsStatus _lastStatus = WsStatus.idle;

  /// 正在补消息（避免重连抖动时并发跑好几轮）
  bool _catchingUp = false;

  /// 注册 WS 处理器（在 `main()` 里启动一次）
  void start() {
    if (_started) return;
    _started = true;
    _ws.router.registerAll(<String, WsHandler>{
      WsEvents.simple: handleIncoming,
      WsEvents.group: handleIncoming,
      WsEvents.isOnline: _onOnline,
      WsEvents.setChatTop: _onSetChatTop,
      WsEvents.setIsNotice: _onSetIsNotice,
      WsEvents.undoMessage: _onUndo,
      // S5.1：通讯录相关的增量
      WsEvents.appendContact: _onAppendContact,
      WsEvents.addGroup: _onAddGroup,
      WsEvents.editGroupName: _onEditGroupName,
      WsEvents.removeGroup: _onRemoveGroup,
      WsEvents.removeUser: _onRemoveUser,
    });
    // 断线期间服务端**不会重放**漏掉的推送（`simple` / `group` 是纯在线推送），
    // 所以每次连接恢复都要把有未读的会话各补一页最新消息，否则就会出现
    // 「会话列表有预览、点进去什么都没有」。
    //
    // 订阅不取消：它挂在根作用域的 WsService 上，生命周期与容器一致
    // （`onLoggedOut` 也不取消，重新登录还要用它补消息）。
    _ws.statusChanges.listen(_onStatusChanged);
  }

  void _onStatusChanged(WsStatus status) {
    final reconnected =
        status == WsStatus.connected && _lastStatus != WsStatus.connected;
    _lastStatus = status;
    if (!reconnected) return;
    if (!_ref.read(sessionStoreProvider).isLoggedIn) return;
    unawaited(catchUp());
  }

  /// 连接恢复后的整轮对齐：会话列表 → 通讯录 → 有未读的会话各补一页消息。
  ///
  /// 三样都是「纯在线推送」的例外：`simple` / `group` / `appendContact` /
  /// `addGroup` 在断线期间服务端不会重放，只能主动拉。
  /// 顺序不能反：先有服务端的未读数，才知道该补哪些会话。
  Future<void> catchUp() async {
    try {
      await _conversations.syncFromServer();
    } on ApiException catch (error) {
      // 拉不到就先用手里的本地数据，界面上不阻断
      debugPrint('[聊天] 会话同步失败：${error.message}');
    }
    await _contacts.syncFromServer();
    await syncMissedMessages();
  }

  /// 把「有未读」的会话各补一页最新消息（离线/断线期间漏推的那些）。
  ///
  /// 只补有未读的会话：没未读说明要么已经看过，要么本来就没新消息，
  /// 不值得为它多打一次接口。
  Future<void> syncMissedMessages() async {
    if (_catchingUp) return;
    _catchingUp = true;
    try {
      for (final conversation in await _conversations.all()) {
        if (conversation.unread <= 0) continue;
        // 系统通知（`is_group == 2`）不进消息表，也没有消息接口可拉
        if (conversation.isGroup == 2 || conversation.id == 'system') continue;
        try {
          await _messages.refreshNewest(
            conversationId: conversation.id,
            isGroup: conversation.isGroup,
          );
        } on ApiException catch (error) {
          debugPrint('[聊天] 补会话 ${conversation.id} 的最新消息失败：${error.message}');
        }
      }
    } finally {
      _catchingUp = false;
    }
  }

  /// 登录后对齐一次会话列表与通讯录，并把漏掉的消息补回来
  /// （老端进消息页拉 `getContacts`、进通讯录拉 `getFriendList` / `getGroupList`）
  Future<void> onLoggedIn() => catchUp();

  /// 登出：清掉登录态相关的内存计数与本地通讯录
  ///
  /// 会话与消息**不清**（与老端一致：它也只是重新登录后覆盖，没做账号隔离），
  /// 但通讯录里全是别人的资料，换账号留着会串号，所以清掉。
  Future<void> onLoggedOut() async {
    systemUnread.value = 0;
    // 不取消 WS 状态订阅：它是根作用域里的常驻监听，登出再登录还要用它
    // （`_onStatusChanged` 里会先看登录态）
    await _contacts.clear();
  }

  /// 处理一条推送消息（`simple` / `group`）。
  ///
  /// 返回是否真的落库了一条新消息（重复推送、缺字段的脏数据都返回 false）。
  ///
  /// [alert] 为 false 时不响提示音：通话信令（`webrtc` 的 `calling`）走这条路
  /// 落一条通话记录，响声与震动交给通话自己的铃声（老端也一样）。
  Future<bool> handleIncoming(WsEvent event, {bool alert = true}) async {
    final data = event.data;
    if (data.isEmpty) {
      // 业务事件理论上都带 data；如果哪天不是，这里必须留下痕迹
      debugPrint('[聊天] ${event.type} 事件没有 data 字段：${event.raw}');
      return false;
    }

    final session = _ref.read(sessionStoreProvider);
    final myUserId = session.userId;
    final conversationId = Message.conversationIdFor(data, myUserId: myUserId);
    if (conversationId.isEmpty) {
      debugPrint('[聊天] 消息没有归属会话，已跳过：$data');
      return false;
    }

    final serverId = asInt(data['id'], 0);
    final msgId = asText(data['msg_id']);
    final type = asText(data['type'], 'text');

    // 老端 `checkMsg`：按服务端 id 判重（本地乐观消息用 msg_id）
    final exists = await _messages.has(
      conversationId,
      serverId: serverId == 0 ? null : serverId,
      msgId: msgId,
    );
    if (exists) {
      debugPrint('[聊天] 重复推送，跳过：$serverId / $msgId');
      return false;
    }

    final message = Message.fromServerJson(
      data,
      conversationId: conversationId,
    );
    await _messages.saveOne(message);

    final mine = message.isMine(myUserId);

    // 系统消息：老端只把计数 +1，不建会话
    if (conversationId == 'system') {
      if (!mine) systemUnread.value += 1;
      if (alert) {
        await _notifier.onIncoming(
          message: message,
          conversation: null,
          myUserId: myUserId,
          setting: session.setting,
        );
      }
      return true;
    }

    // 陌生会话：推送里带 contactInfo 时先补一条会话（老端 getContact 里的兜底）
    final contactInfo = asMap(data['contactInfo']);
    if (contactInfo.isNotEmpty) {
      await _conversations.ensureFromContactInfo(contactInfo);
    }

    final conversation = await _conversations.applyIncomingMessage(
      message,
      myUserId: myUserId,
    );

    // 「不显示该聊天」藏起来的会话，再来一条新消息就自己冒出来（微信就是这个行为）。
    // 放在落库之后：先让消息进去，再把会话从名单里摘掉，界面下一帧就完整了。
    if (conversationId.isNotEmpty) {
      await _ref
          .read(hiddenConversationsProvider.notifier)
          .show(conversationId);
    }

    debugPrint(
      '[聊天] ${conversationId.isEmpty ? "?" : conversationId} 收到 $type 消息',
    );
    if (alert) {
      await _notifier.onIncoming(
        message: message,
        conversation: conversation,
        myUserId: myUserId,
        setting: session.setting,
      );
    }
    return true;
  }

  /// `isOnline`：更新在线状态（会话行 + 通讯录里的好友），并解锁通话锁。
  ///
  /// 锁那一步是老端 `App.vue` 里的 `if(!data.is_online && msgStore.webrtcLock == data.id)`
  /// ——「被我锁住的那个人下线了就解锁」，不然那把锁会挡住之后的去电。
  Future<void> _onOnline(WsEvent event) async {
    final id = asText(event.data['id'] ?? event.top('id'));
    if (id.isEmpty) return;
    final online = asBool(event.data['is_online']) ? 1 : 0;
    await _conversations.setOnline(id, online);
    await _contacts.setOnline(id, online);
    final call = _ref.read(callControllerProvider);
    if (online == 0) {
      await call.peerOffline(id);
    } else {
      // S8.1h：对方上线时叫一声通话层 —— 主叫在等 answer 期间可能需要
      // **补发一次 offer**（对方被离线推送叫醒后，我们那份 offer 很可能已经丢了，
      // 而服务端不会给离线的人补投信令）。见 CallMachine.peerOnline。
      await call.peerOnline(id);
    }
  }

  /// `appendContact`：有人加了我，服务端推来一条联系人
  Future<void> _onAppendContact(WsEvent event) async {
    if (event.data.isEmpty) return;
    await _contacts.upsertFromServer(event.data);
    // 老端同时会把这条写进会话列表（`mainContacts`），新端也一样：
    // 通讯录里点进去就能直接聊，不用等第一条消息
    await _conversations.ensureFromContactInfo(event.data);
  }

  /// `addGroup`：被拉进新群（老端还会补一次 `bindGroup`，否则收不到群消息）
  Future<void> _onAddGroup(WsEvent event) async {
    final id = asText(event.data['id']);
    if (id.isEmpty) return;
    await _contacts.upsertFromServer(<String, dynamic>{
      ...event.data,
      'is_group': asInt(event.data['is_group'], 1),
    });
    await _conversations.upsert(Conversation.fromServerJson(event.data));
    await bindGroupClient(id);
  }

  /// 把本端这个 client 绑到群里（老端 `bindGroup({client_id, group_id})`）。
  ///
  /// 两个地方要用：收到 `addGroup` 推送时、以及**自己创建群聊之后**
  /// （老端创建走 `appendContacts` + 等推送，新端不赌推送，创建完直接绑）。
  /// 失败只记日志：绑定可以重来，但不能因此让创建/收消息这条路炸掉。
  Future<void> bindGroupClient(String groupId) async {
    if (groupId.isEmpty) return;
    final clientId = _ws.clientId ?? '';
    if (clientId.isEmpty) {
      debugPrint('[通讯录] 还没有 client_id，跳过 bindGroup（下次连上时会重新对齐）');
      return;
    }
    try {
      await _auth.bindGroup(<String, dynamic>{
        'client_id': clientId,
        'group_id': groupId,
      });
    } on ApiException catch (error) {
      debugPrint('[通讯录] bindGroup 失败：${error.message}');
    }
  }

  /// `editGroupName`：群改名（会话行与通讯录两处都要改）
  Future<void> _onEditGroupName(WsEvent event) async {
    final id = asText(event.data['id']);
    final name = asText(event.data['displayName']);
    if (id.isEmpty || name.isEmpty) return;
    await _contacts.rename(id, name);
    await _conversations.applyServerPatch(id, displayName: name);
  }

  /// `removeGroup`：群被解散 / 我被移出（会话与通讯录都删）
  Future<void> _onRemoveGroup(WsEvent event) async {
    final id = asText(event.data['group_id'] ?? event.data['id']);
    if (id.isEmpty) return;
    await _contacts.remove(id);
    await _conversations.removeLocal(id);
  }

  /// `removeUser`：被踢的人是我才删群，否则什么都没变（成员信息属 M5 的群信息页）
  Future<void> _onRemoveUser(WsEvent event) async {
    final myUserId = _ref.read(sessionStoreProvider).userId;
    final removed = asText(event.data['user_id']);
    final groupId = asText(event.data['group_id']);
    if (groupId.isEmpty || removed.isEmpty || removed != myUserId) return;
    await _contacts.remove(groupId);
    await _conversations.removeLocal(groupId);
    debugPrint('[通讯录] 已被移出群聊：$groupId');
  }

  Future<void> _onSetChatTop(WsEvent event) async {
    final id = asText(event.data['id']);
    if (id.isEmpty) return;
    await _conversations.applyServerPatch(
      id,
      isTop: asInt(event.data['is_top'], 0),
    );
  }

  Future<void> _onSetIsNotice(WsEvent event) async {
    final id = asText(event.data['id']);
    if (id.isEmpty) return;
    await _conversations.applyServerPatch(
      id,
      isNotice: asInt(event.data['is_notice'], 1),
    );
  }

  /// `undoMessage`：服务端只推 `{is_last, toContactId, content, id/msg_id}`
  Future<void> _onUndo(WsEvent event) async {
    final data = event.data;
    final conversationId = Message.conversationIdFor(
      data,
      myUserId: _ref.read(sessionStoreProvider).userId,
    );
    if (conversationId.isEmpty) return;

    await _messages.applyUndo(
      conversationId: conversationId,
      serverId: asInt(data['id'], 0) == 0 ? null : asInt(data['id'], 0),
      msgId: asText(data['msg_id']).isEmpty ? null : asText(data['msg_id']),
      content: asText(data['content']).isEmpty ? null : asText(data['content']),
    );
    debugPrint('[聊天] 收到撤回通知：$conversationId');
  }
}

final chatSyncServiceProvider = Provider<ChatSyncService>((ref) {
  return ChatSyncService(
    ref,
    ref.watch(wsServiceProvider),
    ref.watch(conversationRepositoryProvider),
    ref.watch(messageRepositoryProvider),
    ref.watch(contactRepositoryProvider),
    ref.watch(authApiProvider),
    ref.watch(messageNotifierProvider),
  );
});
