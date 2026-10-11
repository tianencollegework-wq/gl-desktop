import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';
import '../chat/group_join.dart';

/// 扫到的内容该干什么，对应老端 `common/scan.js::checkQr`。
///
/// 老端只有两个分支：
/// 1. 内容里**含我们自己的 apiUrl** → 把最后一段当 `realToken` 发回去问服务端
///    「这是什么」（[ScanInternalTarget]）；
/// 2. 其余一律当普通文本，弹一个「已识别内容 + 复制」（[ScanTextTarget]）。
sealed class ScanTarget {
  const ScanTarget();
}

/// 自家链接：`path` 是去掉 apiUrl 之后的站内路径，`token` 是它最后一段
@immutable
class ScanInternalTarget extends ScanTarget {
  const ScanInternalTarget({required this.path, required this.token});

  final String path;
  final String token;

  @override
  bool operator ==(Object other) =>
      other is ScanInternalTarget && other.path == path && other.token == token;

  @override
  int get hashCode => Object.hash(path, token);

  @override
  String toString() => 'ScanInternalTarget($path, token=$token)';
}

/// 一个网址（`http://` / `https://` 开头的）：按**聊天里点链接那三道闸门**处理
/// （自家站点直开 / 腾讯系拦掉 / 其它先确认）—— 见 `core/ui/link_opener.dart`。
///
/// 2026-09-27 用户要求：「外部链接就跳转 webview，但同时也要遵守聊天里发链接
/// 点击的处理原则，三个处理方式」。所以这里只负责认出来，怎么走交给同一个入口。
@immutable
class ScanUrlTarget extends ScanTarget {
  const ScanUrlTarget(this.url);

  final String url;

  @override
  bool operator ==(Object other) => other is ScanUrlTarget && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'ScanUrlTarget($url)';
}

/// 普通文本：弹层展示 + 复制
@immutable
class ScanTextTarget extends ScanTarget {
  const ScanTextTarget(this.data);

  final String data;

  @override
  bool operator ==(Object other) =>
      other is ScanTextTarget && other.data == data;

  @override
  int get hashCode => data.hashCode;

  @override
  String toString() => 'ScanTextTarget($data)';
}

/// 扫码内容分流（纯函数，好单测）。
///
/// 与老端不同（刻意的）：老端不管 `pathinfo` 长什么样都直接发请求，只要内容里
/// **出现过** apiUrl 就会走这条路（比如某篇文章正文里引了我们的域名）；新端多做
/// 一道校验——必须是以 `/` 开头的站内路径、且最后一段非空，否则当普通文本处理，
/// 免得发一条注定没意义的请求。
ScanTarget parseScanTarget({required String data, required String apiUrl}) {
  final raw = data.trim();
  if (raw.isEmpty) return const ScanTextTarget('');
  if (apiUrl.isNotEmpty && raw.contains(apiUrl)) {
    final path = raw.replaceFirst(apiUrl, '');
    final parts = path.split('/').where((part) => part.isNotEmpty).toList();
    final token = parts.isEmpty ? '' : parts.last;
    if (path.startsWith('/') && token.isNotEmpty) {
      return ScanInternalTarget(path: path, token: token);
    }
  }
  // 带协议的网址：认成外链（没有协议的裸域名**不算** —— 与聊天里把网址做成
  // 可点蓝字那条规则同一个口径，免得把 `abc.com` 这种普通文本也当成链接跳走）
  if (_looksLikeUrl(raw)) return ScanUrlTarget(raw);
  return ScanTextTarget(raw);
}

/// 是不是一个"可以打开"的网址（只认 `http://` / `https://` 两种协议，大小写不敏感）
bool _looksLikeUrl(String raw) {
  final lower = raw.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

/// 服务端对自家链接的回答（老端 `res.data`：`{action, id, loginToken}`）
///
/// 群二维码那条（`[action] == 'groupInfo'`）服务端会把**整行群资料**一起给回来
/// （`name` / `avatar` / `setting` / `invite_id` …），所以额外解析出一份 [group]。
/// 为什么要留着它：「群资料」接口（`/enterprise/group/groupInfo`）是**群成员专属**的
/// —— 服务端 `Group::groupInfo` 先 `checkGroupMember`，不过就回一句「您没有操作权限！」。
/// 而群二维码本来就是给**还没进群的人**扫的，扫码这一步（`/scan/g/<token>`）
/// 恰好谁都能问。所以这份回包是「没入群的人也能看到的群资料」，群资料页拿它兜底
/// （见 `features/contacts/group_join_page.dart` 的 `scanned`）。
@immutable
class ScanVerdict {
  const ScanVerdict({
    this.action = '',
    this.id = '',
    this.loginToken = '',
    this.group,
  });

  /// `groupInfo`（群二维码）/ `userInfo`（个人名片）/ `qrLogin`（扫码登录）
  final String action;

  final String id;
  final String loginToken;

  /// `groupInfo` 那条顺带回来的群资料（其余 action 为 null）
  final GroupJoinInfo? group;

  bool get isEmpty => action.isEmpty;

  factory ScanVerdict.fromJson(Map<String, dynamic> json) {
    final action = asText(json['action']);
    return ScanVerdict(
      action: action,
      id: asText(json['id']),
      loginToken: asText(json['loginToken']),
      group: action == 'groupInfo' ? GroupJoinInfo.fromJson(json) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScanVerdict &&
      other.action == action &&
      other.id == id &&
      other.loginToken == loginToken &&
      other.group == group;

  @override
  int get hashCode => Object.hash(action, id, loginToken, group);

  @override
  String toString() => 'ScanVerdict($action, id=$id)';
}
