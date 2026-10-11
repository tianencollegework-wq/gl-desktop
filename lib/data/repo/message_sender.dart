import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/media/media_picker.dart';
import '../../core/net/api_exception.dart';
import '../../core/util/uuid.dart';
import '../../domain/call/call_duration.dart';
import '../../domain/chat/contact_card.dart';
import '../../domain/chat/outgoing_message.dart';
import '../../domain/lingting/lingting_card.dart';
import '../../domain/news/news_card.dart';
import '../api/chat_api.dart';
import '../db/app_database.dart';
// 数据库方法都在 extension 里，必须 import 才会进作用域
import '../db/conversation_dao.dart';
import '../db/message_dao.dart';
import '../model/conversation.dart';
import '../model/message.dart';
import '../model/time_units.dart' show nowMillis;
import '../model/user_info.dart';

/// 发送结果
@immutable
class SendResult {
  const SendResult({
    required this.message,
    required this.ok,
    this.error,
    this.removed = false,
  });

  /// 落库后的那条消息（带 `localId`）
  final Message message;

  final bool ok;

  /// 失败原因（`ok == false` 时才有）
  final String? error;

  /// 服务端明确拒绝、这条已经删掉了（老端 `code == 401` 时 `messageList.pop()`）
  final bool removed;

  @override
  String toString() =>
      'SendResult(ok=$ok, ${message.msgId ?? message.clientId ?? message.localId})';
}

/// 发消息（S4.4）。
///
/// 流程照老端 `chat.vue::sendMessage`，但有一处**刻意不同**：
/// 老端先把消息塞进内存列表、接口失败就只把 `status` 改成 `failed`
/// （退出聊天页这条记录就没了）；新端**先落库再发**，所以：
/// * 发完立刻能在聊天页看到（乐观显示，转圈）；
/// * 接口回来把服务端版本合并上去（`clientId` / 同内容认领，不会出现两条）；
/// * 失败就地标红，退出页面再进来还能点重发。
class MessageSender {
  MessageSender(this._db, this._api, [this._random]);

  final AppDatabase _db;
  final ChatApi _api;

  /// 只为了测试能固定 uuid（`null` 就走真随机）
  final Random? _random;

  /// 发一条文本（`content` 是纯文本，表情以 `[!code]` token 形式内嵌）。
  ///
  /// [at] 是文本里 @ 到的群成员 id（老端 `im-input.vue` 从富文本的 link 节点里抓，
  /// 见 `domain/chat/group_members.dart::resolveAt`）。
  Future<SendResult> sendText({
    required Conversation conversation,
    required UserInfo me,
    required String content,
    Message? quoted,
    List<String> at = const <String>[],
    String Function(String key)? translate,
  }) => _send(
    conversation: conversation,
    me: me,
    type: 'text',
    content: content,
    at: at,
    ext: quoted == null
        ? null
        : buildQuote(quoted, translate: translate ?? (key) => key),
  );

  /// 走上传接口的消息类型（老端 `chat.vue::sendMessage` 里的 `fileTypes`）
  static const Set<String> uploadTypes = <String>{
    'image',
    'video',
    'file',
    'voice',
  };

  /// 发一份媒体（图片/视频/文件/语音）。
  ///
  /// 老端这四个类型**不走 `sendMessage`**，而是表单直传
  /// `{apiUrl}/common/upload/uploadFile`：`message` 字段是整条消息的 JSON、
  /// `file` 字段是文件本体。本地路径先写进 `content`（界面能立刻显示自己选的图），
  /// 上传成功后用服务端返回的地址覆盖。
  ///
  /// 大小限制由调用方按服务端配置先判（老端是在这里弹 toast 的），
  /// 因为配置在会话状态里，发送层不该去读界面状态。
  Future<SendResult> sendMedia({
    required Conversation conversation,
    required UserInfo me,
    required PickedMedia media,
  }) async {
    final message = Message(
      clientId: uuidV4(_random),
      conversationId: conversation.id,
      fromUserId: me.userId,
      fromUserName: me.name,
      fromUserAvatar: me.avatar,
      toContactId: conversation.id,
      type: media.kind.wireName,
      content: media.path,
      sendTime: nowMillis(),
      // 视频自带尺寸/时长（老端 `chooseVideo` 就是这个结构）；
      // 语音只带时长（老端 `handlerSuccess` 里 `extends: {duration}`）
      ext: switch (media.kind) {
        MediaKind.video => <String, dynamic>{
          'duration': media.durationSeconds,
          'width': media.width,
          'height': media.height,
          'fixMode': media.fixMode,
          'poster': '',
        },
        MediaKind.voice => <String, dynamic>{'duration': media.durationSeconds},
        MediaKind.image || MediaKind.file => const <String, dynamic>{},
      },
      isGroup: conversation.isGroup,
      isRead: 1,
      status: MessageStatus.going,
      extra: <String, dynamic>{
        'fileName': media.name,
        'fileSize': media.size,
        // 重发要拿得到本地文件（服务端地址还没回来）
        'localPath': media.localPath,
      },
    );

    final localId = await _db.insertOptimistic(message);
    final stored = message.copyWith(localId: localId);
    await _touchConversation(conversation, stored);
    return _post(stored, me: me, isGroup: conversation.isGroup);
  }

  /// 发一个收藏表情（老端 `chooseDiyEmoji`：点一下**直接发**，不走输入框）
  Future<SendResult> sendSticker({
    required Conversation conversation,
    required UserInfo me,
    required String url,
    int fileId = 0,
  }) => _send(
    conversation: conversation,
    me: me,
    type: 'emoji',
    content: url,
    fileId: fileId,
  );

  /// 发一张名片（老端 `im-input.vue::sendContactCard`）。
  ///
  /// 与收藏表情一样走普通 JSON 接口：`type` 是 `contact`，`content` 是
  /// 「[个人名片] 张三」（会话列表与通知里显示的那行字），
  /// 渲染要用的三个字段在 `extends` 里（这样老端收到也能正常画）。
  Future<SendResult> sendContactCard({
    required Conversation conversation,
    required UserInfo me,
    required ContactCard card,
    String Function(String key)? translate,
  }) => _send(
    conversation: conversation,
    me: me,
    type: 'contact',
    content: card.content(translate ?? (key) => key),
    ext: card.toExt(),
  );

  /// 发一张音乐卡片（灵听的「分享」）。
  ///
  /// 与名片同一套：`content` 是列表/通知里那行字，渲染字段在 `extends` 里。
  /// 点它直接进灵听播放页开播（见 `domain/lingting/lingting_card.dart`）。
  Future<SendResult> sendMusicCard({
    required Conversation conversation,
    required UserInfo me,
    required MusicCard card,
    String Function(String key)? translate,
  }) => _send(
    conversation: conversation,
    me: me,
    type: lingtingMessageType,
    content: card.content(translate ?? (key) => key),
    ext: card.toExt(),
  );

  /// 发一张资讯卡片（资讯详情页的「分享」）。
  ///
  /// 与音乐卡片、名片同一套：`content` 是列表/通知里那行字
  /// （`[资讯] 标题`），渲染字段在 `extends` 里。对方点一下进资讯详情页
  /// （见 `domain/news/news_card.dart`）。
  Future<SendResult> sendNewsCard({
    required Conversation conversation,
    required UserInfo me,
    required NewsCard card,
    String Function(String key)? translate,
  }) => _send(
    conversation: conversation,
    me: me,
    type: newsMessageType,
    content: card.content(translate ?? (key) => key),
    ext: card.toExt(),
  );

  /// 群通话记录（通话结束后群里那一条，微信里写的是「通话时长 12:30」）。
  ///
  /// 为什么让客户端发、而不是服务端直接写消息表：这条记录走的就是**普通发消息那条路**
  /// （`im/sendMessage`）—— 未读计数、离线推送、会话列表预览全在服务端那条链上，
  /// 通话记录没有理由另开一条。服务端只需要如实告知「房间空了、这通打了多久」
  /// （`leave` 回包里的 `announce` 只发给最后一个走的人，见 `Sfu.php::claimClosed`）。
  ///
  /// 类型沿用 `webrtc`：老端的 `im-webrtc.vue` 直接显示 `content`，新端画同一种气泡。
  /// 多一个 `group_call` 记号是给新端分辨用的：点一下该进**群通话页**
  /// （1:1 那一条的点击是回拨）。
  Future<SendResult> sendGroupCallRecord({
    required Conversation conversation,
    required UserInfo me,
    required int seconds,
    required int participants,
    String Function(String key)? translate,
  }) => _send(
    conversation: conversation,
    me: me,
    type: 'webrtc',
    content: _callRecordContent(translate, seconds),
    ext: <String, dynamic>{
      // 0 = 语音（与 1:1 记录同一个字段：老端拿它选图标）
      'type': 0,
      'group_call': 1,
      'callTime': seconds,
      'participants': participants,
    },
  );

  /// 重发（老端 `reSend`：不再插时间分隔、不再走一遍「追加」逻辑）
  Future<SendResult> resend({
    required Message message,
    required UserInfo me,
    required int isGroup,
  }) async {
    final localId = message.localId;
    if (localId == null) {
      return SendResult(message: message, ok: false, error: '这条消息不在本地库里，无法重发');
    }
    await _db.setStatus(localId, MessageStatus.going);
    final going = message.copyWith(status: MessageStatus.going);
    // 重发用的是上一次已经落库的 content / ext，不再重新拼引用
    return _post(going, me: me, isGroup: isGroup);
  }

  Future<SendResult> _send({
    required Conversation conversation,
    required UserInfo me,
    required String type,
    required String content,
    Map<String, dynamic>? ext,
    List<String> at = const <String>[],
    String fileName = '',
    int fileSize = 0,
    int fileId = 0,
  }) async {
    final message = Message(
      clientId: uuidV4(_random),
      conversationId: conversation.id,
      fromUserId: me.userId,
      fromUserName: me.name,
      fromUserAvatar: me.avatar,
      toContactId: conversation.id,
      type: type,
      content: content,
      sendTime: nowMillis(),
      ext: ext ?? const <String, dynamic>{},
      at: at,
      isGroup: conversation.isGroup,
      isRead: 1,
      status: MessageStatus.going,
      // 老端把文件名/大小放在消息**顶层**（图片、文件消息），发的时候要带上
      extra: <String, dynamic>{
        if (fileName.isNotEmpty) 'fileName': fileName,
        if (fileSize > 0) 'fileSize': fileSize,
        if (fileId > 0) 'file_id': fileId,
      },
    );

    final localId = await _db.insertOptimistic(message);
    final stored = message.copyWith(localId: localId);

    // 会话列表立刻动起来（老端是等 WS 回显才更新）
    await _touchConversation(conversation, stored);

    return _post(stored, me: me, isGroup: conversation.isGroup);
  }

  /// 真正打接口，并把结果落到那条本地消息上
  Future<SendResult> _post(
    Message message, {
    required UserInfo me,
    required int isGroup,
  }) async {
    // `extends` 里带 `msg_id` 就说明这条是引用消息（与老端的存放方式一致）
    final quoted = message.ext['msg_id'] == null ? null : message.ext;
    final payload = buildOutgoingPayload(
      clientId: message.clientId ?? '',
      type: message.type,
      content: message.content,
      me: me,
      toContactId: message.conversationId,
      isGroup: isGroup,
      sendTimeMs: message.sendTime,
      ext: message.ext.isEmpty ? null : message.ext,
      quote: quoted,
      pid: quoted?['msg_id']?.toString(),
      at: message.at,
      fileName: _text(message.extra['fileName']),
      fileSize: _int(message.extra['fileSize']),
      fileId: _int(message.extra['file_id']),
    );

    try {
      // 图片/视频/文件/语音走表单直传，其余走普通 JSON 接口
      final localPath = _text(message.extra['localPath']);
      final data = uploadTypes.contains(message.type) && localPath.isNotEmpty
          ? await _api.uploadFile(
              FormData.fromMap(<String, dynamic>{
                'message': jsonEncode(payload),
                'file': await MultipartFile.fromFile(
                  localPath,
                  filename: _text(message.extra['fileName']),
                ),
              }),
            )
          : await _api.sendMessage(payload);
      // 叠加服务端的回执（回执可能只有 id，也可能什么都没有）
      final merged = message.overlayWith(
        Message.fromServerJson(
          data,
          conversationId: message.conversationId,
        ).copyWith(status: MessageStatus.sent),
      );
      await _db.upsertMessages(<Message>[merged]);
      debugPrint('[发送] 成功：${message.type} → ${message.conversationId}');
      return SendResult(message: merged, ok: true);
    } on ApiException catch (error) {
      // 服务端明确拒绝（禁言、被拉黑之类）：老端会把这条从列表里弹掉
      final removed = error is BusinessException && error.code == 401;
      final localId = message.localId;
      if (localId != null) {
        if (removed) {
          await _db.deleteMessage(localId);
        } else {
          await _db.setStatus(localId, MessageStatus.failed);
        }
      }
      debugPrint('[发送] 失败：${error.message}');
      return SendResult(
        message: message.copyWith(status: MessageStatus.failed),
        ok: false,
        error: error.message,
        removed: removed,
      );
    }
  }

  /// 会话行的「最后一条」跟着走（老端也要等 WS 回显才更新，这里提前一步）
  Future<void> _touchConversation(
    Conversation conversation,
    Message message,
  ) async {
    final existing = await _db.findConversation(conversation.id);
    if (existing == null) return;
    await _db.upsertConversation(
      existing.copyWith(
        // 老端会话列表里非文本消息显示成「[图片]」这类占位，由渲染层统一处理
        lastContent: message.content,
        lastSendTime: message.sendTime,
        lastType: message.type,
      ),
    );
  }
}

/// 群通话记录那条文案：把 `group.callRecord` 里的 `{time}` 换成时长。
///
/// 兜底也要有时长：语言包里没这条 key 时 `t` 会把 key 原样返回（便于定位漏项），
/// 那时群里会多出一条光秃秃的 `group.callRecord` —— 后面补上 `00:35` 至少能看懂。
String _callRecordContent(String Function(String key)? translate, int seconds) {
  final time = formatCallRecordDuration(seconds);
  final template = (translate ?? (key) => key)('group.callRecord');
  return template.contains('{time}')
      ? template.replaceFirst('{time}', time)
      : '$template $time';
}

String _text(Object? value) => value?.toString() ?? '';

int _int(Object? value) => int.tryParse(value?.toString() ?? '') ?? 0;

final messageSenderProvider = Provider<MessageSender>(
  (ref) =>
      MessageSender(ref.watch(appDatabaseProvider), ref.watch(chatApiProvider)),
);
