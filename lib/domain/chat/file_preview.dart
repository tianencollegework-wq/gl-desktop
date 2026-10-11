/// 文件/位置消息「点一下之后干什么」的判断，全部是纯函数。
///
/// 口径照抄老端 `mixins/chat.js`：
/// * `preview()` —— 后缀在 [localPreviewExtensions] 里才下载后用系统应用打开，
///   否则弹「该文件不支持预览」；后缀在 [audioExtensions] 里则当音频、丢给内置浏览器打开；
/// * `openLocation()` —— `uni.openLocation` 用坐标唤起系统地图。
library;

import 'package:flutter/foundation.dart' show immutable;

/// 能用系统应用打开的文档后缀（老端那段只在 APP 分支里生效）
const Set<String> localPreviewExtensions = <String>{
  'doc',
  'xls',
  'ppt',
  'pdf',
  'docx',
  'xlsx',
  'pptx',
};

/// 老端把它当中文音频、交给 webview 的后缀（注意它写的是 `acc`，不是 `aac`）
const Set<String> audioExtensions = <String>{'mp3', 'wav', 'acc'};

/// 后缀是否支持「本地预览」（下载 + 系统应用打开）
bool supportsLocalPreview(String extension) =>
    localPreviewExtensions.contains(extension.toLowerCase());

/// 后缀是不是音频（老端拿去开 webview，新端直接用系统浏览器打开真实地址）
bool isAudioFile(String extension) =>
    audioExtensions.contains(extension.toLowerCase());

/// 唤起系统地图要用的目标平台。
///
/// 单独抽出来是为了能在测试里把三种都跑一遍——真机上只能跑到自己那一档。
enum MapTarget { android, ios, others }

/// 位置消息点开后要打开的地址。
///
/// 老端是 `uni.openLocation`（调用方给经纬度，剩下的交给系统），
/// Flutter 没这个 API，只能拼一个各家都认的链接：
/// * Android：`geo:` 意图（缺地图 App 时会落到浏览器，也能用）
/// * iOS：`maps.apple.com`
/// * 其它（桌面/Web）：Google 地图，至少能看
///
/// 标题里可能带 `(` `)` 等符号，所以坐标部分用逗号不套括号，标题单独 URL 编码。
String mapUrlOf({
  required double latitude,
  required double longitude,
  required String title,
  MapTarget target = MapTarget.android,
}) {
  final point = '$latitude,$longitude';
  final label = Uri.encodeComponent(title);
  switch (target) {
    case MapTarget.android:
      return 'geo:$point?q=$point($label)';
    case MapTarget.ios:
      return 'https://maps.apple.com/?ll=$point&q=$label';
    case MapTarget.others:
      return 'https://www.google.com/maps/search/?api=1&query=$point';
  }
}

/// 当前平台对应哪一档（组件里用，测试直接传枚举）
MapTarget currentMapTarget({required bool isAndroid, required bool isIOS}) =>
    isAndroid
    ? MapTarget.android
    : isIOS
    ? MapTarget.ios
    : MapTarget.others;

/// 预览要用的两个选项（对应老端那个底部弹层的两项）
@immutable
class FilePreviewOption {
  const FilePreviewOption({required this.key, required this.hintKey});

  /// 标题的 i18n key
  final String key;

  /// 副标题的 i18n key
  final String hintKey;
}

/// 「本地预览 / 需下载」
const FilePreviewOption localPreviewOption = FilePreviewOption(
  key: 'message.localPreview',
  hintKey: 'message.download',
);

/// 「在线预览 / 支持常用的文件和文档」
const FilePreviewOption onlinePreviewOption = FilePreviewOption(
  key: 'message.onlinePreview',
  hintKey: 'message.normalFile',
);
