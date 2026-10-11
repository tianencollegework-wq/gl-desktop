import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';

/// 全局配置，对应老端 `store/login.js` 的 `globalConfig`。
///
/// 来源有三个，都要能吃：
/// 1. 本地缓存（`globalConfig` key，老端也是先读缓存再用接口覆盖）；
/// 2. `/common/pub/getSystemInfo` 的 `data`；
/// 3. WS `updateConfig` 事件推过来的整份配置。
///
/// 两个刻意的设计：
/// * **缺字段落回默认值**，不抛异常。老端读的是普通 JS 对象，字段缺失时
///   `undefined` 会静默变成 `false`；Dart 里如果强转会直接崩在启动路径上，
///   所以每个字段都带兜底（默认值就是老端 `defaultConfig` 里那份）。
/// * **保留原始 map**（[raw]）。服务端可能下发我们还不认识的字段，
///   丢掉的话以后排查只能重新抓包。
@immutable
class GlobalConfig {
  const GlobalConfig({
    required this.sysInfo,
    required this.chatInfo,
    required this.compass,
    required this.demonMode,
    this.raw = const <String, dynamic>{},
  });

  final SysInfo sysInfo;
  final ChatInfo chatInfo;
  final CompassConfig compass;

  /// 演示模式：登录页会显示演示账号提示（老端 `demon_mode`）
  final bool demonMode;

  /// 原始 JSON，便于排查服务端新增字段
  final Map<String, dynamic> raw;

  /// 老端 `store/login.js` 的 `defaultConfig` 原值
  static const GlobalConfig defaults = GlobalConfig(
    sysInfo: SysInfo(),
    chatInfo: ChatInfo(),
    compass: CompassConfig(),
    demonMode: false,
  );

  factory GlobalConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return defaults;
    return GlobalConfig(
      sysInfo: SysInfo.fromJson(asMap(json['sysInfo'])),
      chatInfo: ChatInfo.fromJson(asMap(json['chatInfo'])),
      compass: CompassConfig.fromJson(asMap(json['compass'])),
      demonMode: asBool(json['demon_mode']),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sysInfo': sysInfo.toJson(),
    'chatInfo': chatInfo.toJson(),
    'compass': compass.toJson(),
    'demon_mode': demonMode,
  };

  /// 「发现」tab 是否显示（老端 `pages/index/index.vue`：`compass.status == 1`）
  bool get compassEnabled => compass.status == 1;

  /// 是否允许多设备同时在线（决定被顶下线要不要踢自己）
  bool get multiDeviceLogin => sysInfo.multipleLogin == 1;

  /// 是否开放音视频通话入口（预留在 M6 用）
  bool get webrtcEnabled => chatInfo.webrtc == 1;

  /// 上传大小上限（MB）。老端只在这一个地方用它：
  /// `let maxSize = globalConfig.fileUpload.size ?? 10`（`chat.vue::sendMessage`）。
  ///
  /// 它不在 `defaultConfig` 里，是服务端 `getSystemInfo` 下发的，所以走 [raw] 读，
  /// 读不到就按老端的 `?? 10` 算。
  int get maxUploadMb {
    final fileUpload = raw['fileUpload'];
    if (fileUpload is Map) {
      final size = int.tryParse(fileUpload['size']?.toString() ?? '');
      if (size != null && size > 0) return size;
    }
    return 10;
  }

  /// 值相等（不含 [raw]：raw 是排查用的附件，不影响语义比较，
  /// 而且用它会让 Riverpod 的 select 每次都判定成"变了"）
  @override
  bool operator ==(Object other) =>
      other is GlobalConfig &&
      other.sysInfo == sysInfo &&
      other.chatInfo == chatInfo &&
      other.compass == compass &&
      other.demonMode == demonMode;

  @override
  int get hashCode => Object.hash(sysInfo, chatInfo, compass, demonMode);
}

/// 站点信息，对应老端 `defaultConfig.sysInfo`
@immutable
class SysInfo {
  const SysInfo({
    this.logo = '',
    this.name = 'Im',
    this.diyName = 0,
    this.regauth = 0,
    this.regtype = 2,
    this.runMode = 2,
    this.ipregion = 1,
    this.multipleLogin = 0,
  });

  /// 站点 logo 地址（空则用本地 `assets/images/logo.png`）
  final String logo;
  final String name;

  /// 企业模式是否允许自定义名字
  final int diyName;

  /// 注册权限：0 不限制 / 1 手机号 / 2 邮箱 / 3 手机号或邮箱
  final int regauth;

  /// 注册方式：1 开放注册（登录页显示注册按钮）/ 2 仅邀请
  final int regtype;

  /// 运行模式
  final int runMode;

  /// 是否显示 IP 归属地
  final int ipregion;

  /// 是否允许多设备同时登录
  final int multipleLogin;

  factory SysInfo.fromJson(Map<String, dynamic> json) => SysInfo(
    logo: asText(json['logo']),
    name: asText(json['name'], 'Im'),
    diyName: asInt(json['diyName'], 0),
    regauth: asInt(json['regauth'], 0),
    regtype: asInt(json['regtype'], 2),
    runMode: asInt(json['runMode'], 2),
    ipregion: asInt(json['ipregion'], 1),
    multipleLogin: asInt(json['multipleLogin'], 0),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'logo': logo,
    'name': name,
    'diyName': diyName,
    'regauth': regauth,
    'regtype': regtype,
    'runMode': runMode,
    'ipregion': ipregion,
    'multipleLogin': multipleLogin,
  };

  /// 登录页是否显示「注册」按钮（老端：`regtype == 1`）
  bool get registerOpen => regtype == 1;

  @override
  bool operator ==(Object other) =>
      other is SysInfo &&
      other.logo == logo &&
      other.name == name &&
      other.diyName == diyName &&
      other.regauth == regauth &&
      other.regtype == regtype &&
      other.runMode == runMode &&
      other.ipregion == ipregion &&
      other.multipleLogin == multipleLogin;

  @override
  int get hashCode => Object.hash(
    logo,
    name,
    diyName,
    regauth,
    regtype,
    runMode,
    ipregion,
    multipleLogin,
  );
}

/// 聊天相关开关，对应老端 `defaultConfig.chatInfo`
@immutable
class ChatInfo {
  const ChatInfo({
    this.online = 1,
    this.webrtc = 1,
    this.dbDelMsg = 1,
    this.redoTime = 86400,
    this.groupChat = 1,
    this.simpleChat = 1,
    this.stun = '',
    this.stunUser = '',
    this.stunPass = '',
  });

  /// 是否展示在线状态
  final int online;

  /// 是否开启音视频通话
  final int webrtc;

  /// 是否允许删除消息
  final int dbDelMsg;

  /// 允许撤回的时间（秒）
  final int redoTime;

  /// 是否开启群聊
  final int groupChat;

  /// 是否开启单聊
  final int simpleChat;

  /// 站点自建的 STUN/TURN 地址（老端 `call.vue` 把它塞进 WebView 的 URL 参数）。
  ///
  /// 注意它是**一个字符串**，不是数组：老端就把它当单个地址用，空串表示没配，
  /// 由客户端回退到公共 STUN（见 `domain/call/call_media_config.dart`）。
  final String stun;

  /// TURN 的用户名 / 密码（只配 STUN 时通常为空）
  final String stunUser;
  final String stunPass;

  factory ChatInfo.fromJson(Map<String, dynamic> json) => ChatInfo(
    online: asInt(json['online'], 1),
    webrtc: asInt(json['webrtc'], 1),
    dbDelMsg: asInt(json['dbDelMsg'], 1),
    redoTime: asInt(json['redoTime'], 86400),
    groupChat: asInt(json['groupChat'], 1),
    simpleChat: asInt(json['simpleChat'], 1),
    stun: asText(json['stun']),
    stunUser: asText(json['stunUser']),
    stunPass: asText(json['stunPass']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'online': online,
    'webrtc': webrtc,
    'dbDelMsg': dbDelMsg,
    'redoTime': redoTime,
    'groupChat': groupChat,
    'simpleChat': simpleChat,
    'stun': stun,
    'stunUser': stunUser,
    'stunPass': stunPass,
  };

  @override
  bool operator ==(Object other) =>
      other is ChatInfo &&
      other.online == online &&
      other.webrtc == webrtc &&
      other.dbDelMsg == dbDelMsg &&
      other.redoTime == redoTime &&
      other.groupChat == groupChat &&
      other.simpleChat == simpleChat &&
      other.stun == stun &&
      other.stunUser == stunUser &&
      other.stunPass == stunPass;

  @override
  int get hashCode => Object.hash(
    online,
    webrtc,
    dbDelMsg,
    redoTime,
    groupChat,
    simpleChat,
    stun,
    stunUser,
    stunPass,
  );
}

/// 「发现 / 探索」开关与入口列表，对应老端 `defaultConfig.compass`
/// （`pages/compass/index.vue` 就是照着 `list` 画的）。
@immutable
class CompassConfig {
  const CompassConfig({
    this.mode = 2,
    this.status = 0,
    this.list = const <CompassItem>[],
  });

  final int mode;

  /// 0 关闭 / 1 开启
  final int status;

  /// 「发现」页上那一列（或一宫格）入口，由服务端下发
  final List<CompassItem> list;

  factory CompassConfig.fromJson(Map<String, dynamic> json) => CompassConfig(
    mode: asInt(json['mode'], 2),
    status: asInt(json['status'], 0),
    list: asList(json['list'])
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => CompassItem.fromJson(item.cast<String, dynamic>()))
        .toList(),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'mode': mode,
    'status': status,
    'list': <Map<String, dynamic>>[for (final item in list) item.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is CompassConfig &&
      other.mode == mode &&
      other.status == status &&
      listEquals(other.list, list);

  @override
  int get hashCode => Object.hash(mode, status, Object.hashAll(list));
}

/// 「发现」里的一个入口（老端 `compass.list` 里的一项）
@immutable
class CompassItem {
  const CompassItem({
    this.icon = '',
    this.name = '',
    this.url = '',
    this.type = 0,
    this.badge = 0,
  });

  final String icon;
  final String name;
  final String url;

  /// 2 = 站外链接（老端 `openApp` 只会把 `type == 2` 的塞进内嵌浏览器），
  /// 其余当站内页面跳
  final int type;

  /// 角标数字：0 不显示、1 显示小圆点、其余显示数字（超 99 显示 99+）
  final int badge;

  bool get opensWebView => type == 2;

  /// 有角标要画吗。
  ///
  /// **只认正数**：服务端把「没有角标」也下发成 `badge: 0`（灵听那一项就是），
  /// 以前列表模式照画不误，于是「发现」里挂了一个红圈写着 0（2026-09-25 用户看到的就是它）。
  bool get hasBadge => badge > 0;

  factory CompassItem.fromJson(Map<String, dynamic> json) => CompassItem(
    icon: asText(json['icon']),
    name: asText(json['name']),
    url: asText(json['url']),
    type: asInt(json['type'], 0),
    badge: asInt(json['badge'], 0),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'icon': icon,
    'name': name,
    'url': url,
    'type': type,
    'badge': badge,
  };

  @override
  bool operator ==(Object other) =>
      other is CompassItem &&
      other.icon == icon &&
      other.name == name &&
      other.url == url &&
      other.type == type &&
      other.badge == badge;

  @override
  int get hashCode => Object.hash(icon, name, url, type, badge);
}
