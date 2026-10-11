import 'package:drift/drift.dart';

/// 会话表，对应老端 `allContacts` / `mainContacts`（存在 `uni.setStorageSync` 里的那份）。
///
/// 老端把单聊、群聊、系统消息全部塞进一个数组，字段是服务端直接给的；
/// 这里落库时只把**界面真正用到**的字段拆成列，其余服务端字段整体存进 [extra]，
/// 免得服务端加了字段我们这边对不上（与 `UserInfo.raw` 一个思路）。
class DbConversations extends Table {
  /// 会话 id：单聊是对方 `user_id`，群聊是 `group_id`，系统消息是 `system`
  TextColumn get id => text()();

  TextColumn get displayName => text().withDefault(const Constant(''))();
  TextColumn get avatar => text().withDefault(const Constant(''))();

  /// 最后一条消息的预览文案（老端还会把它换成「[图片]」这类占位）
  TextColumn get lastContent => text().withDefault(const Constant(''))();

  /// 最后一条消息时间，**毫秒**（见 `time_units.dart` 的归一化说明）
  IntColumn get lastSendTime => integer().withDefault(const Constant(0))();

  /// 最后一条消息类型（`text` / `image` / `webrtc` …）
  TextColumn get lastType => text().withDefault(const Constant('text'))();

  /// 是否群聊（老端 `is_group`：1 群、2 群且未读额外累加）
  IntColumn get isGroup => integer().withDefault(const Constant(0))();

  /// 未读数
  IntColumn get unread => integer().withDefault(const Constant(0))();

  /// 被 @ 的条数（老端 `is_at`）
  IntColumn get isAt => integer().withDefault(const Constant(0))();

  /// 置顶（1 置顶）
  IntColumn get isTop => integer().withDefault(const Constant(0))();

  /// 是否提醒（0 免打扰、1 提醒）
  IntColumn get isNotice => integer().withDefault(const Constant(1))();

  /// 群内角色（`< 3` 表示有撤回权限）
  IntColumn get role => integer().withDefault(const Constant(0))();

  /// 老端 `dep_id`（部门/组织维度）
  IntColumn get depId => integer().withDefault(const Constant(0))();

  /// 在线状态（`isOnline` 事件更新）
  IntColumn get isOnline => integer().withDefault(const Constant(0))();

  /// 草稿
  ///
  /// 老端把草稿存在 `draft_<会话 id>` 这个独立的 storage key 里；落库时直接做成
  /// 会话的一个列（语义完全一致，少一次关联查询）。同步接口不会下发 draft，
  /// 所以 [DbConversations] 的同步用 `toSyncCompanion()`（不含 draft）以免覆盖它。
  TextColumn get draft => text().withDefault(const Constant(''))();

  /// 服务端给的其它字段（JSON），不在界面上用但不丢
  TextColumn get extra => text().withDefault(const Constant(''))();

  /// 本地更新时间（毫秒），用于排查同步问题
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => <Column>{id};
}

/// 通讯录表（S5.1），对应老端存在 storage 里的 `friendList` / `groupList`。
///
/// 老端把两份列表整份塞进 `uni.setStorageSync`，任何变化（`friendUpdate++`）
/// 都要重新调接口拉一遍；这里落库，界面订阅流就能动，WS 推来的增量直接改一行。
///
/// 三类数据共用一张表，靠 [isGroup] 区分（与老端 `is_group` 同一套值）：
/// * `0` 好友（`getFriendList`）
/// * `1` 群聊（`getGroupList`）
/// * `2` 系统通知（`getFriendList` 里夹带的那条会话）
class DbContacts extends Table {
  /// 好友是 `user_id`，群聊是 `group_id`，系统通知是 `system`
  TextColumn get id => text()();

  /// 界面显示名。老端好友列表里直接用服务端的 `displayName`
  /// （设置备注后服务端会把这个字段换成备注名），所以列名保持一致。
  TextColumn get displayName => text().withDefault(const Constant(''))();

  /// 真实姓名（老端 `realname`：用户详情、搜索页都用它）
  TextColumn get realName => text().withDefault(const Constant(''))();

  TextColumn get avatar => text().withDefault(const Constant(''))();

  /// 0 好友、1 群聊、2 系统通知
  IntColumn get isGroup => integer().withDefault(const Constant(0))();

  /// 服务端给的拼音首字母（老端 `item.index`，通讯录分组直接用它）
  TextColumn get indexLetter => text().withDefault(const Constant(''))();

  /// 名字全拼（老端 `name_py`，搜索与索引兜底用）
  TextColumn get namePy => text().withDefault(const Constant(''))();

  /// 账号（群聊列表页的搜索条件里有它）
  TextColumn get account => text().withDefault(const Constant(''))();

  /// 在线状态（WS `isOnline`）
  IntColumn get isOnline => integer().withDefault(const Constant(0))();

  /// 群内角色（群主 1 / 管理员 2 / 成员 3，群聊列表页据此筛选）
  IntColumn get role => integer().withDefault(const Constant(0))();

  /// 群主 id（老端群聊列表里给群主画个小人图标）
  TextColumn get ownerId => text().withDefault(const Constant(''))();

  /// 服务端给的其它字段（JSON）
  TextColumn get extra => text().withDefault(const Constant(''))();

  /// 本地更新时间（毫秒）
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => <Column>{id};
}

/// 消息表，对应老端各页面拿到的 `msgList` 与服务端 `getMessageList` 的返回。
@TableIndex(
  name: 'idx_messages_conversation',
  columns: <Symbol>{#conversationId, #sendTime},
)
@TableIndex(
  name: 'idx_messages_msg_id',
  columns: <Symbol>{#msgId},
  unique: true,
)
class DbMessages extends Table {
  IntColumn get localId => integer().autoIncrement()();

  /// 服务端消息主键（老端到处用的 `item.id`，通话信令里作为 `main_id`）
  IntColumn get serverId => integer().nullable()();

  /// 业务消息 id（客户端生成的 uuid；老端用它做去重）
  TextColumn get msgId => text().nullable()();

  /// 本机生成的消息 id（老端 `$util.getUuid()`，发出去时放在 `id` 字段里）。
  ///
  /// 与 [msgId] 分开存的原因：服务端到底把哪个字段回传给我们还没实测过
  /// （老端把 uuid 写在 `id` 上，又用 `id` 匹配接口返回）。发出去的乐观消息
  /// 用这个字段认领"服务端回显的同一条消息"，避免出现两条一样的。
  TextColumn get clientId => text().nullable()();

  /// 发送状态：`sent`（默认）/ `going`（发出去等回执）/ `failed`（失败可重发）
  ///
  /// 老端把状态放在内存里的 `message.status`，退出聊天页就没了；落库之后
  /// 重进聊天页仍然能看到"发送失败"并点重发。
  TextColumn get status => text().withDefault(const Constant('sent'))();

  /// 归属会话（与 [DbConversations.id] 一致）
  TextColumn get conversationId => text()();

  TextColumn get fromUserId => text().withDefault(const Constant(''))();
  TextColumn get fromUserName => text().withDefault(const Constant(''))();
  TextColumn get fromUserAvatar => text().withDefault(const Constant(''))();

  /// 消息体里的 `toContactId`（自己发的时候是对方 id）
  TextColumn get toContactId => text().withDefault(const Constant(''))();

  /// 消息体里的 `toUser`
  TextColumn get toUser => text().withDefault(const Constant(''))();

  TextColumn get type => text().withDefault(const Constant('text'))();
  TextColumn get content => text().withDefault(const Constant(''))();

  /// 消息时间，**毫秒**（服务端可能给秒，入库前统一归一化）
  IntColumn get sendTime => integer().withDefault(const Constant(0))();

  /// 被 @ 的 user_id 列表（JSON 数组）
  TextColumn get atUsers => text().withDefault(const Constant('[]'))();

  /// 老端 `extends`（JSON）：图片尺寸、语音时长、通话 event/code 都在这里
  TextColumn get ext => text().withDefault(const Constant('{}'))();

  IntColumn get isGroup => integer().withDefault(const Constant(0))();

  /// 本地是否已读（用于进聊天页时判断要不要上报已读）
  IntColumn get isRead => integer().withDefault(const Constant(0))();

  /// 是否已撤回（老端 `is_undo`）
  IntColumn get isUndo => integer().withDefault(const Constant(0))();

  /// 是否本机发出（老端 `extends.isMobile == 1`）：多端同步时用来避免重复处理
  IntColumn get isMobile => integer().withDefault(const Constant(0))();

  /// 服务端给的其它字段（JSON）
  TextColumn get extra => text().withDefault(const Constant(''))();

  // 主键就是自增的 localId（drift 不允许 autoIncrement 列再声明 primaryKey）
}
