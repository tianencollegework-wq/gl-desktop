import '../../data/model/conversation.dart';
import '../../data/model/message.dart';

/// 会话相关的纯规则（S3.2）。
///
/// 全部从老端逐条抄过来，**不改语义**，因为会话列表的显示结果要和老端一致：
/// * `utils.js::sortContacts` —— 排序
/// * `utils.js::getMsgType` —— 非文本消息的预览占位
/// * `store/message.js::initContacts` —— 未读/at 汇总、置顶分组、草稿
/// * `App.vue::appendMessage` —— 推送消息如何落成一条会话
///
/// 抽成纯函数的目的是**可测**：这些规则以前散在 store 与页面里，
/// 只能在真机上点着看，现在能直接用单测固定住。
abstract final class ConversationRules {
  /// 这些类型的 `lastContent` 直接显示原文，其余换成「[图片]」这类占位
  /// （对应老端的 `['text','event','location','contact'].includes(type)`）
  static const Set<String> rawPreviewTypes = <String>{
    'text',
    'event',
    'location',
    'contact',
  };

  /// 非文本消息的预览占位，对应老端 `getMsgType`。
  ///
  /// [callVideo] 只在 `webrtc` 类型且已知通话类型时才有值：
  /// `true` 视频通话、`false` 语音通话、`null` 未知（显示「[音视频通话]」）。
  ///
  /// 注意 `contact` 类型：老端写的是 `$t('common.IDcard')`，而语言包里的 key 是
  /// `common.idcard`——所以老端在会话列表里会显示成字面量 `[common.IDcard]`。
  /// 这里用正确的 key。
  static String preview({
    required String type,
    required String Function(String key) translate,
    bool? callVideo,
  }) {
    final label = switch (type) {
      'image' => 'common.image',
      'emoji' => 'common.diyEmoji',
      'voice' => 'common.voice',
      'video' => 'common.video',
      'file' => 'common.file',
      'location' => 'common.location',
      'contact' => 'common.idcard',
      // 音乐卡片（灵听分享）：我们自己发的类型，别的端显示不出来，
      // 列表与通知里统一显示「[音乐]」
      'lingting' => 'common.music',
      // 资讯卡片（资讯频道的「分享」）：与音乐卡片同理，列表与通知里显示「[资讯]」
      'news' => 'common.news',
      'webrtc' =>
        callVideo == null
            ? 'common.webrtc'
            : (callVideo ? 'common.videoCalling' : 'common.voiceCalling'),
      _ => 'common.nonsupportMsg',
    };
    return '[${translate(label)}]';
  }

  /// 会话列表里的预览文案
  static String previewOf(
    Conversation conversation, {
    required String Function(String key) translate,
  }) {
    if (rawPreviewTypes.contains(conversation.lastType)) {
      return conversation.lastContent;
    }
    return preview(type: conversation.lastType, translate: translate);
  }

  /// 列表与标题栏上显示的那个名字。
  ///
  /// 为什么不能直接用服务端给的 `displayName`：**「我的收藏」「系统通知」这两个
  /// 名字是服务端用中文存下来的**（收藏那条会话是服务端建的，名字就叫「我的收藏」），
  /// 于是切到英文界面时，别的会话都跟着语言变了，唯独这两行还是中文
  /// （用户 2026-09-27 专门指出这一点）。
  ///
  /// 认这两条会话靠的是**它们的 id**（收藏固定 `-1`、系统通知固定 `system`，
  /// 见 `conversation_repository` 的说明），外加老端那两个 `is_group` 值兜底：
  /// * `is_group == 2` 就是系统通知 —— 服务端给的名字可能是任意文案；
  /// * `is_group == 3` **不一定是收藏**（老端它还是「应用号」），所以只认 id，
  ///   免得把某个人（或应用号）的名字硬换成「我的收藏」。
  static String displayNameOf(
    Conversation conversation, {
    required String Function(String key) translate,
  }) {
    if (conversation.id == 'system' || conversation.isGroup == 2) {
      return translate('user.systemNotice');
    }
    if (conversation.id == '-1') return translate('user.myFavorites');
    return conversation.displayName.isEmpty
        ? conversation.id
        : conversation.displayName;
  }

  /// 排序，对应老端 `sortContacts`：
  /// 按 `lastSendTime` 倒序，时间无效的排到最后。
  ///
  /// 老端用的是 `Array.prototype.sort`（现代引擎稳定排序），
  /// 这里显式说明：相等时保持原顺序（`List.sort` 不保证稳定，所以自己稳住）。
  static List<Conversation> sorted(List<Conversation> input) {
    final indexed = input.indexed.toList();
    indexed.sort((a, b) {
      final timeA = a.$2.lastSendTime;
      final timeB = b.$2.lastSendTime;
      final validA = timeA > 0;
      final validB = timeB > 0;
      if (validA != validB) return validA ? -1 : 1;
      if (validA && validB && timeA != timeB) return timeB.compareTo(timeA);
      return a.$1.compareTo(b.$1);
    });
    return indexed.map((entry) => entry.$2).toList();
  }

  /// 置顶的排前面，其余按时间倒序。
  ///
  /// 老端是 `topContacts.concat(otherContacts)`：先把置顶的挑出来（组内保持
  /// `sortContacts` 的结果），再把非置顶接上去。这里保持一致。
  static List<Conversation> topFirst(List<Conversation> input) {
    final sortedList = sorted(input);
    return <Conversation>[
      ...sortedList.where((item) => item.isTop == 1),
      ...sortedList.where((item) => item.isTop != 1),
    ];
  }

  /// 汇总未读，对应老端 `initContacts` 的统计口径（**含它那两处不对称**）：
  ///
  /// * 未读只在 `is_notice == 1` 且**有 lastContent** 时累加；
  /// * `@我的数量`在任何情况下都累加（老端没判免打扰）；
  /// * `unreadIds` 只收集「有未读或有 @」**且** `is_notice == 1` 的会话。
  static Totals totals(Iterable<Conversation> conversations) {
    var unread = 0;
    var at = 0;
    final unreadIds = <String>[];
    for (final item in conversations) {
      if (item.lastContent.isNotEmpty && item.isNotice == 1) {
        unread += item.unread;
      }
      if (item.isAt > 0) at += item.isAt;
      if (item.hasUnread && item.isNotice == 1) unreadIds.add(item.id);
    }
    return Totals(unread: unread, at: at, unreadIds: unreadIds);
  }

  /// 推送消息落到会话上，对应老端 `App.vue::appendMessage`。
  ///
  /// 返回更新后的会话（[existing] 为空则按老端新建一条），以及未读增量：
  /// * 自己发的消息不增加未读（老端 `addUnread = 0`）；
  /// * `at` 里包含自己时 `is_at += 1`；
  /// * **不回退未读**：老端是 `contact.unread += addUnread`，这里同样只加不减。
  static ConversationApplyResult applyIncoming({
    required Conversation? existing,
    required Message message,
    required String myUserId,
  }) {
    final mine = message.isMine(myUserId);
    final atMe = message.at.contains(myUserId) ? 1 : 0;
    final unreadDelta = mine ? 0 : 1;

    final base =
        existing ??
        Conversation(
          id: message.conversationId,
          displayName: message.fromUserName,
          avatar: message.fromUserAvatar,
          isGroup: message.isGroup,
          isTop: 0,
          // 老端新建会话时没带 is_notice，而默认值是 undefined；
          // 这里按服务端配置语义给「提醒」，与列表里 most 会话一致
          isNotice: 1,
        );

    final updated = base.copyWith(
      lastContent: message.content,
      lastSendTime: message.sendTime,
      lastType: message.type,
      unread: base.unread + unreadDelta,
      isAt: base.isAt + atMe,
    );

    return ConversationApplyResult(
      conversation: updated,
      unreadDelta: unreadDelta,
    );
  }
}

/// 未读汇总结果
class Totals {
  const Totals({
    required this.unread,
    required this.at,
    required this.unreadIds,
  });

  /// 总未读（不含免打扰会话）
  final int unread;

  /// 总 @ 数
  final int at;

  /// 列表上要打红点的会话 id
  final List<String> unreadIds;

  @override
  String toString() =>
      'Totals(unread: $unread, at: $at, ids: ${unreadIds.length})';
}

class ConversationApplyResult {
  const ConversationApplyResult({
    required this.conversation,
    required this.unreadDelta,
  });

  final Conversation conversation;
  final int unreadDelta;
}
