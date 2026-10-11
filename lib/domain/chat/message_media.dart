/// 各类型消息的载荷解析。
///
/// 字段来源是老端 `components/messageType/*.vue` 的**渲染代码**（服务端没有 schema）：
/// 老端把 `extends` 当对象直接读，另外 **文件消息还读顶层的
/// `fileName` / `fileSize` / `extUrl`**（老端自己发出去的那条消息就是这么拼的，
/// 见 `pages/message/chat.vue` 的发送分支），所以两个地方都读一遍，
/// 再退回从 URL 里猜名字。
///
/// 这些都是纯函数，方便用真实报文校准（见规划书 S6.0）。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../core/util/json_value.dart';
import '../../data/model/message.dart';

/// 图片消息（`type == 'image'`）
///
/// * `content` 是图片地址
/// * `extends.fixMode`：老端的显示模式，1 = 定宽 200、2 = 定高 240、3 = 按原尺寸
/// * `extends.width/height`：原图尺寸
@immutable
class ImagePayload {
  const ImagePayload({
    required this.url,
    this.fixMode = 0,
    this.width = 0,
    this.height = 0,
  });

  final String url;
  final int fixMode;
  final double width;
  final double height;

  bool get isEmpty => url.isEmpty;

  /// 老端 `im-image.vue` 的第三个分支：什么信息都没有时按 120 宽等比缩放
  bool get hasSize => width > 0 && height > 0;
}

/// 语音消息（`type == 'voice'`）
///
/// * `content` 是音频地址
/// * `extends.duration` 是秒数（老端显示成 `12 "`）
@immutable
class VoicePayload {
  const VoicePayload({required this.url, required this.duration});

  final String url;

  /// 秒
  final int duration;

  bool get isEmpty => url.isEmpty;
}

/// 视频消息（`type == 'video'`）
///
/// * `content` 是视频地址，`extends.poster` 是封面图
@immutable
class VideoPayload {
  const VideoPayload({
    required this.url,
    required this.poster,
    required this.duration,
    this.width = 0,
    this.height = 0,
  });

  final String url;
  final String poster;

  /// 秒
  final int duration;
  final double width;
  final double height;

  bool get isEmpty => url.isEmpty;
  bool get hasSize => width > 0 && height > 0;
}

/// 文件消息（`type == 'file'`）
@immutable
class FilePayload {
  const FilePayload({
    required this.url,
    required this.name,
    required this.size,
    required this.extension,
  });

  final String url;
  final String name;

  /// 字节
  final int size;

  /// 后缀（不含点，小写），没有就是空串
  final String extension;

  bool get isEmpty => url.isEmpty;
}

/// 位置消息（`type == 'location'`）
///
/// * `content` 是地点标题（老端显示在上一行）
/// * `extends.address` 是详细地址，`extends.latitude/longitude` 是坐标
@immutable
class LocationPayload {
  const LocationPayload({
    required this.title,
    required this.address,
    required this.latitude,
    required this.longitude,
  });

  final String title;
  final String address;
  final double latitude;
  final double longitude;

  bool get hasCoordinate => latitude != 0 || longitude != 0;
}

/// 名片消息（`type == 'contact'`）
@immutable
class ContactPayload {
  const ContactPayload({
    required this.id,
    required this.displayName,
    required this.avatar,
  });

  final String id;
  final String displayName;
  final String avatar;

  bool get isEmpty => id.isEmpty && displayName.isEmpty;
}

/// 音视频通话卡片（`type == 'webrtc'`）
///
/// * `content` 是卡片上的文字（老端直接显示）
/// * `extends.type`：1 = 视频通话，其它 = 语音通话（决定图标）
/// * `extends.code` / `extends.event` 是信令语义，M6 才用
@immutable
class CallPayload {
  const CallPayload({
    required this.text,
    required this.type,
    this.groupCall = false,
    this.durationSeconds = 0,
    this.participants = 0,
  });

  final String text;

  /// 1 = 视频
  final int type;

  /// 群通话记录（`extends.group_call == 1`）：通话结束后群里那条
  /// （内容形如「群通话 12:30」，与 1:1 的通话记录长得一样）。
  ///
  /// 分辨它的用处只有一个：点一下该进**群通话页**，而 1:1 那一条是回拨。
  final bool groupCall;

  /// 这一通打了多久（秒；`extends.callTime`）。
  ///
  /// 1:1 的那种记录里没有这个字段（老端记在聊天里的那条本就不带），所以默认 0；
  /// 群通话记录是我们自己发出去的（`MessageSender.sendGroupCallRecord`），一定有。
  final int durationSeconds;

  /// 期间到过几个人（`extends.participants`；老记录里没有就是 0）。
  ///
  /// 只有人数、**没有名单** —— 服务端数得清人头，不记名字。所以详情卡里
  /// 也不能假装有参与者列表。
  final int participants;

  bool get isVideo => type == 1;
}

ImagePayload imagePayloadOf(Message message) {
  final ext = message.ext;
  return ImagePayload(
    url: message.content,
    fixMode: asInt(ext['fixMode'], 0),
    width: asDouble(ext['width']),
    height: asDouble(ext['height']),
  );
}

VoicePayload voicePayloadOf(Message message) => VoicePayload(
  url: message.content,
  duration: asInt(message.ext['duration'], 0),
);

VideoPayload videoPayloadOf(Message message) {
  final ext = message.ext;
  return VideoPayload(
    url: message.content,
    poster: asText(ext['poster']),
    duration: asInt(ext['duration'], 0),
    width: asDouble(ext['width']),
    height: asDouble(ext['height']),
  );
}

/// 消息里的原始文件名（下载/保存时用名字后缀）。
///
/// 老端发文件、视频时会把 `fileName` 放在消息**顶层**（`chat.vue` 拼报文那段），
/// 收别人的消息时可能是 `extends.fileName`，两处都读一遍，最后从地址里猜。
String messageFileNameOf(Message message) {
  final extra = asText(message.extra['fileName']);
  if (extra.isNotEmpty) return extra;
  final fromExt = asText(message.ext['fileName']);
  if (fromExt.isNotEmpty) return fromExt;
  return _nameFromUrl(message.content);
}

/// 文件消息：名字与大小三处都试一遍（顶层 → `extends` → 从 URL 猜）
FilePayload filePayloadOf(Message message) {
  final ext = message.ext;
  final extra = message.extra;
  final url = message.content;
  final name = asText(extra['fileName']) == ''
      ? asText(ext['name']) == ''
            ? _nameFromUrl(url)
            : asText(ext['name'])
      : asText(extra['fileName']);
  final size = _firstPositive(<int>[
    asInt(extra['fileSize'], 0),
    asInt(ext['size'], 0),
  ]);
  return FilePayload(
    url: url,
    name: name,
    size: size,
    extension: _extensionOf(name.isEmpty ? url : name),
  );
}

LocationPayload locationPayloadOf(Message message) {
  final ext = message.ext;
  return LocationPayload(
    title: message.content,
    address: asText(ext['address']),
    latitude: asDouble(ext['latitude']),
    longitude: asDouble(ext['longitude']),
  );
}

ContactPayload contactPayloadOf(Message message) {
  final ext = message.ext;
  return ContactPayload(
    id: asText(ext['id']),
    displayName: asText(ext['displayName'] ?? ext['realname']),
    avatar: asText(ext['avatar']),
  );
}

CallPayload callPayloadOf(Message message) => CallPayload(
  text: message.content,
  type: asInt(message.ext['type'], 0),
  groupCall: asInt(message.ext['group_call'], 0) == 1,
  durationSeconds: asInt(message.ext['callTime'], 0),
  participants: asInt(message.ext['participants'], 0),
);

/// 老端 `im-item.vue`：`diy` 类型单独给文案，其余未知类型都说“暂不支持”
String unsupportedKeyOf(String type) =>
    type == 'diy' ? 'common.diy' : 'common.nonsupportMsg';

/// 从下载地址里猜文件名（`.../upload/9f2/报表.xlsx?t=1` → `报表.xlsx`）。
///
/// 服务端存的是不透明文件名时也会原样显示（比如 `9f2a1c`），
/// 总比空白强——老端这里直接显示 `undefined`。
String _nameFromUrl(String url) {
  if (url.isEmpty) return '';
  final withoutQuery = url.split('?').first;
  final segments = withoutQuery.split('/');
  return segments.isEmpty ? '' : segments.last;
}

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

int _firstPositive(List<int> values) {
  for (final value in values) {
    if (value > 0) return value;
  }
  return 0;
}
