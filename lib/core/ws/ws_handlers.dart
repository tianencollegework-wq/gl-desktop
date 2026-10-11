import '../store/credential_store.dart';
import 'ws_client.dart';
import 'ws_router.dart';

/// 协议层处理器（M1）。
///
/// 只做三件事：回心跳、接心跳、存 `client_id`。
/// 业务事件（消息、群、通话）在后续里程碑按 [pendingBusinessEvents] 的清单逐个补齐。
Map<String, WsHandler> protocolWsHandlers({
  required WsClient client,
  required CredentialStore store,
  void Function(String clientId)? onClientId,
  void Function(bool multiport)? onMultiport,
}) {
  return <String, WsHandler>{
    /// 服务端 ping → 必须回 pong，否则会被断开
    WsEvents.ping: (event) {
      client.send(const <String, dynamic>{'type': 'pong'});
    },

    /// 服务端 pong，顶层字段带 `multiport`（是否多端在线）
    WsEvents.pong: (event) {
      final raw = event.top('multiport');
      final multiport = raw == true || raw == 1 || raw.toString() == '1';
      onMultiport?.call(multiport);
    },

    /// 连接就绪，带回 `client_id`（后续要拿它调 bindUid，见 M2）
    WsEvents.init: (event) async {
      final clientId = event.top('client_id')?.toString();
      if (clientId == null || clientId.isEmpty) {
        // 待确认：老端无条件读 res.client_id，若服务端确实返回空值要在这里暴露出来
        return;
      }
      await store.saveClientId(clientId);
      onClientId?.call(clientId);
    },
  };
}

/// 客户端 → 服务端的事件名（老端 `App.vue` / `socket.js` 里发出去的那几个）
abstract final class WsEvents {
  static const String ping = 'ping';
  static const String pong = 'pong';
  static const String init = 'init';
  static const String bindUid = 'bindUid';
  static const String close = 'close';

  // 服务端 → 客户端的业务事件（M2 起逐个注册）
  static const String isOnline = 'isOnline';
  static const String offline = 'offline';
  static const String updateConfig = 'updateConfig';
  static const String simple = 'simple';
  static const String group = 'group';
  static const String setChatTop = 'setChatTop';
  static const String setIsNotice = 'setIsNotice';
  static const String addGroup = 'addGroup';
  static const String setManager = 'setManager';
  static const String addGroupUser = 'addGroupUser';
  static const String removeUser = 'removeUser';
  static const String undoMessage = 'undoMessage';
  static const String editGroupName = 'editGroupName';
  static const String removeGroup = 'removeGroup';
  static const String setNotice = 'setNotice';
  static const String groupSetting = 'groupSetting';
  static const String appendContact = 'appendContact';
  static const String webrtc = 'webrtc';

  /// 群通话：注册表变了（有人进来/走了/换了会话）→ 房间里的人重新对账订阅。
  /// 服务端在 `Sfu.php::bumpEpoch` 里推（群频道：`{room_id, epoch}` + S6.15 加上的
  /// `live` / `call_id`，以及「这一通刚开」那一次才有的 `started` / `name` / `starter`
  /// —— 后几个是给**没在通话里**的人的横幅与会话列表标记用的）。
  static const String sfuRoom = 'sfuRoom';

  /// 已经有处理器的事件（对照 `docs/protocol/ws-events.md` 的进度列）：
  /// M1 协议层 `ping/pong/init`，M2 会话层 `offline/updateConfig`，
  /// M4 聊天层 `simple/group/isOnline/setChatTop/setIsNotice/undoMessage`，
  /// M5 通讯录层 `appendContact/addGroup/editGroupName/removeGroup/removeUser`，
  /// M6 通话层 `webrtc`，S9 群通话层 `sfuRoom`。
  static const List<String> handledEvents = <String>[
    ping,
    pong,
    init,
    bindUid,
    offline,
    updateConfig,
    simple,
    group,
    isOnline,
    setChatTop,
    setIsNotice,
    undoMessage,
    appendContact,
    addGroup,
    editGroupName,
    removeGroup,
    removeUser,
    webrtc,
    sfuRoom,
  ];

  /// 老端 `App.vue` 处理过、但目前还没有处理器的事件。
  ///
  /// 对照 `docs/protocol/ws-events.md` 使用：剩这几个都是**群成员/群设置**（S5.3 接）。
  static const List<String> pendingBusinessEvents = <String>[
    setManager,
    addGroupUser,
    setNotice,
    groupSetting,
  ];
}
