import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';

/// App 本地设置，对应老端 `uni.getStorageSync('appSetting')`。
///
/// 老端在 `App.vue` 的 `onLaunch` 里写死这份默认值。**三项里有两项我们改成了微信的
/// 默认**（`vibrateStatus`：老端 false、微信「新消息通知 → 震动」默认是开）：
/// 新消息提醒的「声音 + 震动」两边都默认开着，用户嫌吵自己去设置里关。
///
/// 注意**已存的设置优先**：这份默认值只在用户从没动过那两个开关时生效
/// （老用户手机上存着的还是老端那份，不会因为升级突然开始震）。
@immutable
class AppSetting {
  const AppSetting({
    this.voiceStatus = true,
    this.vibrateStatus = true,
    this.circleAvatar = false,
  });

  /// 新消息是否播放提示音
  final bool voiceStatus;

  /// 新消息是否震动
  final bool vibrateStatus;

  /// 头像是否显示为圆形
  final bool circleAvatar;

  static const AppSetting defaults = AppSetting();

  factory AppSetting.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return defaults;
    return AppSetting(
      voiceStatus: asBool(json['voiceStatus'], fallback: true),
      vibrateStatus: asBool(json['vibrateStatus'], fallback: true),
      circleAvatar: asBool(json['circleAvatar']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'voiceStatus': voiceStatus,
    'vibrateStatus': vibrateStatus,
    'circleAvatar': circleAvatar,
  };

  @override
  bool operator ==(Object other) =>
      other is AppSetting &&
      other.voiceStatus == voiceStatus &&
      other.vibrateStatus == vibrateStatus &&
      other.circleAvatar == circleAvatar;

  @override
  int get hashCode => Object.hash(voiceStatus, vibrateStatus, circleAvatar);

  AppSetting copyWith({
    bool? voiceStatus,
    bool? vibrateStatus,
    bool? circleAvatar,
  }) => AppSetting(
    voiceStatus: voiceStatus ?? this.voiceStatus,
    vibrateStatus: vibrateStatus ?? this.vibrateStatus,
    circleAvatar: circleAvatar ?? this.circleAvatar,
  );
}
