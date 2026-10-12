import '../../core/util/emoji.dart';
import '../../data/model/message.dart';
import 'conversation_rules.dart';

/// 长按气泡能做的事（S4.5），对照老端 `pages/message/chat.vue` 里那段
/// `add-modal` 的 `v-if` 条件。
enum MessageAction {
  /// 撤回（`message.undo`）
  undo,

  /// 复制（`message.copy`）
  copy,

  /// 存到自定义表情（`message.saveEmoji`）
  saveEmoji,

  /// 转发（`message.forward`）
  forward,

  /// 引用（`message.quote`）
  quote,

  /// 举报（S13.1，2026-10-11 新增；老端没有这一项）
  report,

  /// 删除（`common.del`）
  delete,
}

/// 发出去就撤不回来的类型（老端： `curMsg.type!=='webrtc'`）
const Set<String> undoBlockedTypes = <String>{'webrtc'};

/// 能复制的类型（老端：`['text','image','video','file'].includes(type)`）
const Set<String> copyableTypes = <String>{'text', 'image', 'video', 'file'};

/// 不能转发的类型（老端：`type!=='voice' && type!=='webrtc' && type!=='money'`）
const Set<String> forwardBlockedTypes = <String>{'voice', 'webrtc', 'money'};

/// 不能引用的类型（老端：`type!=='webrtc' && type!=='money'`）
const Set<String> quoteBlockedTypes = <String>{'webrtc', 'money'};

/// 不能举报的类型（2026-10-11）：
/// * `webrtc` 是通话信令、`money` 是转账 —— 都不是「对方说的一句话」；
/// * `event` / `admin_notice` 是系统自己发的那几条（入群提示、公告）。
const Set<String> reportBlockedTypes = <String>{
  'webrtc',
  'money',
  'event',
  'admin_notice',
};

/// 这条消息能不能撤回。
///
/// 老端条件（`im-input`/`chat.vue` 两处一样）：
/// ```
/// (now - sendTime < redoTime*1000 && fromUser.id == me) || contact.role < 3
/// ```
/// 后半段是**群主/管理员能撤任何人的消息**（单聊里 `role` 是 0，所以任何消息都能撤
/// —— 老端在单聊里也给了这个入口，见规划书 S4.5 的说明）。
bool canUndo({
  required Message message,
  required String? myUserId,
  required int role,
  required int redoTimeSeconds,
  required int nowMs,
  required bool isGroup,
}) {
  if (undoBlockedTypes.contains(message.type)) return false;
  if (message.isUndo == 1) return false;
  final mine = myUserId != null && message.fromUserId == myUserId;
  final inWindow = nowMs - message.sendTime < redoTimeSeconds * 1000 && mine;
  if (inWindow) return true;
  // 老端的 `contact.role<3`：单聊里 role 恒为 0，所以它等于「单聊随便撤」。
  // 新端只在群聊里让管理员撤别人的（单聊没有别人的消息可撤，语义一样）。
  if (isGroup && role > 0 && role < 3) return true;
  return false;
}

/// 撤回那条提示能不能点「重新编辑」。
///
/// 老端只看时间窗（没看是谁撤的，所以别人的撤回提示也能点出别人的原文，
/// 这是老端的一个小毛病）；新端加上「必须是自己发的」。
bool canReedit({
  required Message message,
  required String? myUserId,
  required int redoTimeSeconds,
  required int nowMs,
}) {
  if (message.isUndo != 1) return false;
  if (myUserId == null || message.fromUserId != myUserId) return false;
  // 只有文字消息能「重新编辑」（老端把图片/文件的 content 也填回富文本里，
  // 结果是一段看不懂的地址）
  if (message.type != 'text') return false;
  if (message.content.isEmpty) return false;
  return nowMs - message.sendTime < redoTimeSeconds * 1000;
}

/// 长按菜单里要显示哪几项（顺序与老端一致：撤回 / 复制 / 存表情 / 转发 / 引用 / 删除）
List<MessageAction> availableActions({
  required Message message,
  required String? myUserId,
  required int role,
  required int redoTimeSeconds,
  required int nowMs,
  required bool isGroup,

  /// 服务端开关：`globalConfig.chatInfo.dbDelMsg`（1 才给「删除」）
  required bool dbDelMsg,
}) {
  final actions = <MessageAction>[];
  if (canUndo(
    message: message,
    myUserId: myUserId,
    role: role,
    redoTimeSeconds: redoTimeSeconds,
    nowMs: nowMs,
    isGroup: isGroup,
  )) {
    actions.add(MessageAction.undo);
  }
  if (copyableTypes.contains(message.type)) actions.add(MessageAction.copy);
  if (message.type == 'emoji') actions.add(MessageAction.saveEmoji);
  if (!forwardBlockedTypes.contains(message.type)) {
    actions.add(MessageAction.forward);
  }
  if (!quoteBlockedTypes.contains(message.type)) {
    actions.add(MessageAction.quote);
  }
  // 举报（新增）：**别人的**、还在的消息才给这一项。
  // 自己那条不用举报；已撤回的那条没有内容可看（`isUndo`），也没什么可处理的。
  if (canReport(message: message, myUserId: myUserId)) {
    actions.add(MessageAction.report);
  }
  // 老端：`globalConfig.chatInfo.dbDelMsg && fromUser.id == user.user_id`
  if (dbDelMsg && myUserId != null && message.fromUserId == myUserId) {
    actions.add(MessageAction.delete);
  }
  return actions;
}

/// 这条消息能不能举报（长按菜单那一项的门槛）。
///
/// 三道：**不是我发的**、**还没撤回**、**不是系统类消息**（[reportBlockedTypes]）。
/// 服务端还有一道更硬的（只能举报和我有关的会话里的消息，见
/// `Report::mayReportMessage`）—— 这里只是别让用户点开一个注定会被拒的弹层。
bool canReport({required Message message, required String? myUserId}) {
  if (myUserId == null || myUserId.isEmpty) return false;
  if (message.fromUserId == myUserId) return false;
  if (message.isUndo == 1) return false;
  if (reportBlockedTypes.contains(message.type)) return false;
  return true;
}

/// 复制到剪贴板的内容。
///
/// 老端是 `htmlToLines(content)`：把富文本拆成纯文本、**把表情图片整个丢掉**
/// （`htmlString.replace(/<img...>/gi, '')`）。新端 content 本来就是纯文本 + `[!code]`
/// token，所以这里用列表预览那套 `previewText()` 去掉 token，行为一致。
String copyText(Message message) {
  if (message.type == 'text') return previewText(message.content);
  // 图片/视频/文件的老端行为就是复制 content（一个地址）
  return message.content;
}

/// 举报弹层里那行「举报的是哪一条」的预览。
///
/// 文本走 [previewText]（顺带剥掉表情 token，与复制/列表预览同一套）；
/// 其余类型换成「[图片]」「[语音]」这类占位 —— 直接把一个文件地址摆进举报框
/// 对举报人没有任何意义（与 `ConversationRules.previewOf` 同一口径）。
String reportPreview(Message message, String Function(String key) translate) {
  if (message.type == 'text') return previewText(message.content);
  return ConversationRules.preview(
    type: message.type,
    translate: translate,
  );
}
