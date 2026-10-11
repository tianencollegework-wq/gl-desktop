/// 「共享哪一块屏幕」那个选择面板（桌面，2026-10-05）。
///
/// 微信 PC 点「共享屏幕」先弹一个小面板：整个屏幕 / 某个窗口。
/// 桌面原生的 `getDisplayMedia` 正好认这件事 —— `video -> deviceId -> exact`
/// 就是要共享的那个源的 id（见插件 `flutter_screen_capture.cc::GetDisplayMedia`），
/// 不给就是默认源（主屏）。源列表来自 `desktopCapturer.getSources()`
/// （同样是原生那条 `GetDesktopSources`）。
///
/// 缩略图（S12.32）：插件取源列表时在 Windows 上**不填** `thumbnail` 字段
/// （源码里挂着 TODO），所以 `source.thumbnail` 永远是空 —— 但它另有一条
/// `getDesktopSourceThumbnail`（原生里是 `source->UpdateThumbnail()`，libwebrtc
/// 真去抓一帧）。2026-10-05 本机实测（`integration_test/screen_share_smoke_test.dart`）：
///
/// * 屏幕与窗口**都能拿到真图**（屏幕 3072×1920/354KB，窗口 2880×1800~3088×1844，
///   每条 10~40ms）；
/// * 但原生那边不是每次都当场给 —— 实测同一条窗口第一次 0 字节、隔 250ms 再问
///   就有 308744 字节。所以空的回话不会就这么算了：`_sourceThumbnail` 最多
///   再问两轮，灰块只是「还没拿到」时的样子。
///
/// ⚠️ 插件自己那个 Dart 包装（`DesktopCapturerNative.getThumbnail`）用不了：
/// 真机实测它在类型检查那一步抛 `type '_UnmodifiableUint8ArrayView' is not a
/// subtype of type 'bool'`（它内部那个泛型包装把回话按错类型解了）。所以这里
/// **直打原生那条通道**（`FlutterWebRTC.Method` + `getDesktopSourceThumbnail`），
/// 方法名与参数表就是原生认的那一份。
///
/// 一张 300KB 上下的整屏图不大适合直接 `Image.memory`：解码按 `cacheWidth` 收小
/// （列表里只要 96 宽），不然每张都按 3072 宽解码一遍。
///
/// 三条口径：
///
/// * **面板只在通话窗那颗引擎里弹**：源列表与取屏幕流是同一颗引擎的事，主窗口
///   那边看不到源列表（所以选择结果要一路带下去，见 `call_host.dart`）；
/// * **取消 = 什么都不做**（不是「共享主屏」）：`null` 与 `sourceId == null` 是
///   两件事，前者是用户反悔，后者是「没选，用系统默认源」；
/// * **读不到列表不算错**：`desktopCapturer` 在某些环境（老系统 / 权限 / 测试）
///   拿不到东西，那就退成「共享整个屏幕」，别把共享这条路堵死。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/desktop_overlay.dart';

/// 用户选定的共享源：[sourceId] 为 null = 系统默认源（主屏）。
class ScreenShareChoice {
  const ScreenShareChoice(this.sourceId, {this.withAudio = false});

  final String? sourceId;

  /// 连**电脑的声音**一起发（面板底下那座开关，默认关）
  final bool withAudio;
}

/// 弹出选择面板。返回 null = 用户取消了（调用方什么都别做）。
///
/// [allowAudio] = false 时不画底下那座「连电脑的声音一起发」的开关。
///
/// 群通话在 S12.38 曾经传 `false`（理由：群里那一路声音统一走本机 mic，把电脑的
/// 声音也推进去等于把别人的话又再说一遍）；S12.39 起**两处都传 `true`** ——
/// 那个担心是**用户自己能判断**的（他要放一段视频给别人听），一刀切禁掉反而让
/// 他做不成这件事。那座开关**两处都默认关着**，要的人自己打开。
Future<ScreenShareChoice?> showScreenSharePicker(
  BuildContext context,
  AppI18n i18n, {
  bool allowAudio = true,
}) async {
  final sources = await _sources();
  if (!context.mounted) return null;
  // 一个都没拿到：不弹空面板（那是纯干扰），直接按「整个屏幕」走
  if (sources.isEmpty) return const ScreenShareChoice(null);

  final entries = _labelEntries(sources, i18n);
  // 缩略图：同一个源只问原生要一次（开关一切也会重建整个面板）
  final thumbnails = <String, Future<Uint8List?>>{};
  Future<Uint8List?> thumbnailOf(DesktopCapturerSource source) =>
      thumbnails.putIfAbsent(source.id, () => _sourceThumbnail(source.id));
  // 「连电脑的声音一起发」：默认关（共享屏幕本来就不出声，声音是额外要的）
  var withAudio = false;

  final picked = await showAppSheet<String>(
    context: context,
    backgroundColor: AppColors.white,
    constraints: const BoxConstraints(maxWidth: 420),
    // 底下那座开关要把面板重建一次（`showAppSheet` 的 builder 不会自己刷）
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              dense: true,
              title: Text(
                i18n.t('call.screenShare'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return ListTile(
                    leading: SizedBox(
                      width: 96,
                      height: 54,
                      child: FutureBuilder<Uint8List?>(
                        future: thumbnailOf(entry.source),
                        builder: (context, snapshot) =>
                            _thumbnailBox(snapshot.data),
                      ),
                    ),
                    title: Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    onTap: () =>
                        Navigator.of(sheetContext).pop(entry.source.id),
                  );
                },
              ),
            ),
            // 声音那座开关放在最下面（先选哪一块，再决定要不要出声）
            if (allowAudio)
              SwitchListTile(
                dense: true,
                value: withAudio,
                onChanged: (value) => setSheetState(() => withAudio = value),
                title: Text(
                  i18n.t('call.shareAudio'),
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  i18n.t('call.shareAudioHint'),
                  style: const TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    ),
  );
  if (picked == null) return null; // 点外面关掉 / 没点 = 取消
  return ScreenShareChoice(picked, withAudio: withAudio);
}

/// 那张「共享哪一块屏幕 / 哪个窗口」面板的签名（可替换，方便用例）。
///
/// 面板本身要问 `desktopCapturer`（插件）拿源列表，组件测试里拿不到 ——
/// 把它做成 provider（见 [screenSharePickerProvider]），用例就能把
/// 「用户选了什么」直接摆好，从而钉住「选中的源一路带到引擎」这条链。
typedef ScreenShareSourcePicker =
    Future<ScreenShareChoice?> Function(
      BuildContext context,
      AppI18n i18n, {
      bool allowAudio,
    });

/// 默认就是真的那个面板（[showScreenSharePicker]）
final screenSharePickerProvider = Provider<ScreenShareSourcePicker>(
  (ref) => showScreenSharePicker,
);

/// 一条选项：源 + 显示名
class _ScreenShareEntry {
  const _ScreenShareEntry(this.source, this.label);

  final DesktopCapturerSource source;
  final String label;
}

/// 原生给的屏幕名是英文的（`Entire Screen` / `Screen 1`），中文界面下按类型自己
/// 起名（多块屏带序号）；窗口那类用窗口标题本身（原生的名字就是它）。
///
/// 顺序按「整屏优先」：屏幕那几条总在前面（原生本来就是按 `[Screen, Window]`
/// 那个顺序拼的，这里再明确排一次 —— 面板第一行永远是那块屏，而不是某个窗口）。
List<_ScreenShareEntry> _labelEntries(
  List<DesktopCapturerSource> sources,
  AppI18n i18n,
) {
  var screenIndex = 0;
  final entries = <_ScreenShareEntry>[];
  final ordered = <DesktopCapturerSource>[
    ...sources.where((source) => source.type == SourceType.Screen),
    ...sources.where((source) => source.type != SourceType.Screen),
  ];
  for (final source in ordered) {
    if (source.type == SourceType.Screen) {
      screenIndex += 1;
      final base = i18n.t('call.sharePickScreen');
      entries.add(
        _ScreenShareEntry(
          source,
          screenIndex <= 1 ? base : '$base $screenIndex',
        ),
      );
    } else {
      entries.add(_ScreenShareEntry(source, source.name));
    }
  }
  return entries;
}

/// 源列表：拿不到就空列表（见文件头第三条口径）。
Future<List<DesktopCapturerSource>> _sources() async {
  try {
    return await desktopCapturer.getSources(
      types: <SourceType>[SourceType.Screen, SourceType.Window],
      thumbnailSize: ThumbnailSize(160, 90),
    );
  } catch (error) {
    debugPrint('[通话] 取可共享的屏幕/窗口列表失败（当没有）：$error');
    return <DesktopCapturerSource>[];
  }
}

/// 一块缩略图（96×54）：有图就画，没有（或还没拿到）就画灰底 —— 尺寸固定，
/// 列表才不会跳。原来那句「没缩略图就画灰块」的口径没变，只是现在能拿到图了。
Widget _thumbnailBox(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    return Container(
      color: AppColors.gray,
      alignment: Alignment.center,
      child: const Icon(Icons.desktop_windows_outlined, size: 20),
    );
  }
  return ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: Image.memory(
      bytes,
      width: 96,
      height: 54,
      fit: BoxFit.cover,
      // 原生的图是**整屏那么大**（实测 3072×1920、354KB）：解码按 96 逻辑宽
      // 收小，不然每张都要按 3072 宽解一遍
      cacheWidth: 192,
    ),
  );
}

/// 逐条去问原生要一张缩略图（见文件头那段实测与「为什么直打通道」）。
///
/// 一层壳，里面最多问三轮：原生那边刚收完尾时第一问可能空着回来（实测同一条
/// 窗口第一问 0 字节、250ms 后 308744 字节），空了就等一会儿再问，拿到就停。
/// 三问都空 / 直接报错，一律返回 null（画面那块退回灰块，不抛）。
Future<Uint8List?> _sourceThumbnail(String sourceId) async {
  for (var attempt = 1; attempt <= _thumbnailAttempts; attempt += 1) {
    final bytes = await _askThumbnail(sourceId);
    if (bytes != null && bytes.isNotEmpty) return bytes;
    // 报错（源已经不在了之类）不必再问：只有「回了个空的」才值得等一等
    if (bytes == null || attempt == _thumbnailAttempts) return null;
    await Future<void>.delayed(_thumbnailRetryDelay);
  }
  return null;
}

/// 原生那条缩略图路由一问一答：拿不到返回 null（失败不抛）。
Future<Uint8List?> _askThumbnail(String sourceId) async {
  try {
    final bytes = await _methodChannel.invokeMethod<Object?>(
      'getDesktopSourceThumbnail',
      <String, dynamic>{
        'sourceId': sourceId,
        // 原生那两个宽高**没用**（`GetDesktopSourceThumbnail` 里 `(void)width;`），
        // 但参数里少了这个 map 会直接报 Bad Arguments，所以要给。
        'thumbnailSize': <String, int>{'width': 96, 'height': 54},
      },
    );
    return bytes is Uint8List ? bytes : null;
  } on Object catch (error) {
    debugPrint('[通话] 取缩略图失败（当没有）：$error');
    return null;
  }
}

/// 一条缩略图最多问几轮（第一问 + 两轮重问）
const int _thumbnailAttempts = 3;

/// 空手时等多久再问一轮（实测 250ms 就够原生把那一帧备好）
const Duration _thumbnailRetryDelay = Duration(milliseconds: 250);

/// 插件那条主通道（`FlutterWebRTC.Method`）：缩略图这条原生路由只有它认。
const MethodChannel _methodChannel = MethodChannel('FlutterWebRTC.Method');
