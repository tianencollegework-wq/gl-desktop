import '../../core/util/json_value.dart';

/// 举报原因（S13.1，2026-10-11）。
///
/// **码表要和服务端逐字对齐**：`app/enterprise/service/ReportInput.php` 的
/// `REASONS`（顺序也一致，界面就按这个顺序列）。对不上的后果是服务端回一句
/// 「举报原因不对」，而用户根本不知道自己做错了什么 —— 补丁包里的
/// `_patch/check-report-patch.js` 就是钉这件事的。
///
/// 文案用 i18n key（七份语言包都要有，`test/core/i18n_keys_test.dart` 盯着）。
enum ReportReason {
  /// 垃圾广告 / 营销
  ad('ad', 'report.reasonAd'),

  /// 色情低俗
  porn('porn', 'report.reasonPorn'),

  /// 诈骗 / 欺诈
  fraud('fraud', 'report.reasonFraud'),

  /// 辱骂 / 骚扰
  harass('harass', 'report.reasonHarass'),

  /// 其他（这时「补充说明」就是主要信息）
  other('other', 'report.reasonOther');

  const ReportReason(this.code, this.labelKey);

  /// 发给服务端的码
  final String code;

  /// 界面上的文案 key
  final String labelKey;

  static ReportReason? fromCode(String code) {
    for (final reason in ReportReason.values) {
      if (reason.code == code) return reason;
    }
    return null;
  }
}

/// 从哪儿举报的（服务端只拿它做统计与后台那一列，码表同样要对齐 `SCENES`）。
enum ReportScene {
  /// 关于页「投诉」（不针对某个人，是平台级反馈）
  about('about'),

  /// 聊天信息页「投诉」（针对这个会话对面的人）
  chat('chat'),

  /// 群信息页「投诉」：举报**这个群本身**（不针对群里某个人、也不针对某条消息）
  ///
  /// 服务端会拿 `group_id` 认对象（并校验举报人在这个群里）：后台那一页看到的
  /// 是「谁投诉了哪个群」，要解散、要处理群里的哪条消息由人看了再定。
  /// 之所以要有这一种，是因为群里「投诉谁」常常说不清 —— 用户想投诉的就是这个群。
  group('group'),

  /// 长按某条消息「举报」
  message('message'),

  /// 用户资料页「投诉」
  profile('profile');

  const ReportScene(this.code);

  final String code;
}

/// 举报的对象：**一个人、一条消息，或者两者都有**。
///
/// 三种入口对应三种目标（这就是为什么要有这个类：
/// 三个页面各自拼请求体的话，字段名与「带不带消息」的判断会各写一份）。
///
/// 服务端要的形状见 `ReportInput::normalize`：
/// `to_user` 被举报人、`msg_id` 消息 uuid、`server_id` 消息数字主键、
/// `group_id` 群号、`reason` 原因、`detail` 说明、`scene` 场景。
class ReportTarget {
  const ReportTarget({
    this.userId = '',
    this.userName = '',
    this.msgId = '',
    this.serverId = 0,
    this.groupId = '',
    this.preview = '',
    required this.scene,
  });

  /// 用户资料页 / 聊天信息页：举报**这个人**
  factory ReportTarget.user({
    required String userId,
    String userName = '',
    ReportScene scene = ReportScene.profile,
  }) => ReportTarget(userId: userId, userName: userName, scene: scene);

  /// 长按消息：举报**这一条**（发送者一起带上，后台那一列就有名字了）
  factory ReportTarget.message({
    required String userId,
    String userName = '',
    String msgId = '',
    int serverId = 0,
    String groupId = '',
    String preview = '',
  }) => ReportTarget(
    userId: userId,
    userName: userName,
    msgId: msgId,
    serverId: serverId,
    groupId: groupId,
    preview: preview,
    scene: ReportScene.message,
  );

  /// 群信息页：举报**这个群**（`groupId` 客户端是 `group-5` 那种形状，
  /// 服务端 `ReportInput::groupId` 会归一化成群号）
  factory ReportTarget.group({
    required String groupId,
    String groupName = '',
  }) => ReportTarget(
    groupId: groupId,
    userName: groupName,
    scene: ReportScene.group,
  );

  /// 关于页：平台级反馈，不针对某个人
  factory ReportTarget.platform({ReportScene scene = ReportScene.about}) =>
      ReportTarget(scene: scene);

  /// 被举报人的 `user_id`（空串 = 不针对个人）
  final String userId;

  /// 界面上显示的名字（举报对象那一行）
  final String userName;

  /// 被举报消息的 uuid（`Message.msgId`）
  final String msgId;

  /// 被举报消息的数字主键（`Message.serverId`；uuid 缺失时的兜底）
  final int serverId;

  /// 群会话 id（客户端是 `group-5` 那种形状，服务端会归一化成群号）
  final String groupId;

  /// 消息的列表预览（弹层里写「举报的是这一条」）
  final String preview;

  final ReportScene scene;

  /// 有没有具体对象。
  ///
  /// 除了「关于页」那种平台反馈，服务端**要求必须有对象**
  /// （`ReportInput::normalize` 里那句「没有指定举报对象」）——
  /// 一个没有对象、没有消息的举报，后台拿到手也没法处理。
  bool get hasTarget =>
      userId.isNotEmpty || msgId.isNotEmpty || serverId > 0 || groupId.isNotEmpty;

  /// 这个目标能不能发出去（页面据此决定要不要给入口）
  bool get isSubmittable =>
      hasTarget || scene == ReportScene.about;

  /// 请求体（形状与 `ReportInput::normalize` 认识的键一一对应）
  Map<String, dynamic> toParams({
    required String reason,
    String detail = '',
  }) => <String, dynamic>{
    'to_user': idValue(userId),
    'msg_id': msgId,
    'server_id': serverId,
    'group_id': groupId,
    'reason': reason,
    'detail': detail,
    'scene': scene.code,
  };
}
