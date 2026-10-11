import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 逐条去问一次**真缩略图**（面板里那些灰块能不能换成画面，就看这一条）。
///
/// ⚠️ 为什么走 `dynamic`：`getThumbnail` 只长在插件内部那个实现类
/// （`src/native/desktop_capturer_impl.dart::DesktopCapturerNative`）上，公开接口
/// `DesktopCapturer` 里没有它，而且插件没把那个类导出 —— 直接
/// `import 'package:flutter_webrtc/src/...'` 会被 `implementation_imports` 拦下
/// （本仓 analyze 必须干净）。运行时对象就是那个实现类，动态调用打得中。
Future<Uint8List?> thumbnailOf(DesktopCapturerSource source) async {
  try {
    final dynamic capturer = desktopCapturer;
    final Object? bytes = await capturer.getThumbnail(source);
    return bytes is Uint8List ? bytes : null;
  } on Object catch (error) {
    debugPrint('[SMOKE] 插件那条 getThumbnail 用不了（${error.runtimeType}）：$error');
  }
  // 绕过插件那个 Dart 包装，直接打原生那条通道（方法名与参数表就是原生认的那份，
  // 见 `common/cpp/src/flutter_webrtc.cc` 里 getDesktopSourceThumbnail 那一段）。
  try {
    final Object? bytes = await const MethodChannel('FlutterWebRTC.Method')
        .invokeMethod<Object?>('getDesktopSourceThumbnail', <String, dynamic>{
          'sourceId': source.id,
          'thumbnailSize': <String, int>{'width': 160, 'height': 90},
        });
    debugPrint('[SMOKE] 原生回话的类型：${bytes.runtimeType}');
    return bytes is Uint8List ? bytes : null;
  } on Object catch (error) {
    debugPrint('[SMOKE] 直打通道也不行：$error');
    return null;
  }
}

/// 从 JPEG 头里读出宽高（只看 SOF0/SOF2 那一段；读不出就返回 null）
String? jpegSize(Uint8List? bytes) {
  if (bytes == null || bytes.length < 10) return null;
  final data = ByteData.sublistView(bytes);
  if (data.getUint16(0) != 0xFFD8) return null; // SOI
  var offset = 2;
  while (offset + 9 < bytes.length) {
    if (data.getUint8(offset) != 0xFF) return null;
    final marker = data.getUint8(offset + 1);
    final length = data.getUint16(offset + 2);
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      final height = data.getUint16(offset + 5);
      final width = data.getUint16(offset + 7);
      return '${width}x$height';
    }
    offset += 2 + length;
  }
  return null;
}

/// 桌面屏幕共享的真机自检（2026-10-05，**不是单测**）。
///
/// 「电脑端能不能共享屏幕」这件事只有这台机器说了算：源列表与屏幕流都是
/// `flutter_webrtc` 的 Windows 原生（`common/cpp/src/flutter_screen_capture.cc`）
/// 给的，组件测试里那条通道永远是假的原生（`MissingPluginException`），
/// 只能证明「拿不到列表时不崩」，证明不了「拿得到」。
///
/// 这份自检把产品真正的两步原样跑一遍：
///
/// 1. `desktopCapturer.getSources()` —— 界面上那个选择面板（「整个屏幕 /
///    某个窗口」）的数据源；顺带把每条的 id / 名字 / 有没有缩略图打出来
///    （Windows 上原生还没填 `thumbnail` 字段，看日志就一目了然）；
/// 2. `navigator.mediaDevices.getDisplayMedia(...)` —— 界面选了哪一块，
///    `video -> deviceId -> exact` 就带哪一块的 id（不给就是系统默认源）。
///
/// 跑法（**先关掉正在跑的 release 实例**，debug 那颗会跟它抢同一个 app 名）：
/// ```
/// flutter test integration_test/screen_share_smoke_test.dart -d windows
/// ```
///
/// 注意它**不会**发起通话：这里只验「取屏幕流」这条原生路。通话里那一套
/// （换轨、停止共享、对方看到什么）由组件测试 + 真机对拨验。
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 停干净：track 不 stop，系统的「正在捕获」标记不会消失，下一次自检就取不到了
  Future<void> dispose(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  testWidgets('源列表：这台机器上有屏幕（以及有没有窗口 / 缩略图）', (tester) async {
    final sources = await desktopCapturer.getSources(
      types: <SourceType>[SourceType.Screen, SourceType.Window],
      thumbnailSize: ThumbnailSize(160, 90),
    );
    debugPrint('[SMOKE] 源列表：${sources.length} 个');
    for (final source in sources.take(12)) {
      debugPrint(
        '[SMOKE]  - ${source.type} id=${source.id} '
        'name=${source.name} thumb=${source.thumbnail?.length ?? 0}',
      );
    }
    expect(sources, isNotEmpty, reason: '这台机器上至少该有一块屏');
    expect(
      sources.where((source) => source.type == SourceType.Screen),
      isNotEmpty,
      reason: '至少要有一块屏可共享（窗口那类没有也不该失败）',
    );
  });

  testWidgets('按源 id 取屏幕流：真的能出画面（界面选了什么就共享什么）', (tester) async {
    final sources = await desktopCapturer.getSources(
      types: <SourceType>[SourceType.Screen, SourceType.Window],
    );
    expect(sources, isNotEmpty);

    // 选集合里的最后一块屏：单屏机器上就是那块，多屏机器上能证明「按 id 选得中」
    final screens = sources
        .where((source) => source.type == SourceType.Screen)
        .toList();
    final picked = screens.isEmpty ? sources.last : screens.last;
    debugPrint('[SMOKE] 选中的源：${picked.type} ${picked.id} ${picked.name}');

    final stream = await navigator.mediaDevices.getDisplayMedia(
      <String, dynamic>{
        'video': <String, dynamic>{
          'deviceId': <String, dynamic>{'exact': picked.id},
        },
        'audio': false,
      },
    );
    final tracks = stream.getVideoTracks();
    expect(tracks, isNotEmpty, reason: '按源 id 该拿到一路画面');
    debugPrint('[SMOKE] 取到画面：${tracks.first.id} ${tracks.first.getSettings()}');

    // 采集几秒：建了流但一帧都没有（黑屏 / 权限被挡）要在这里现形
    await Future<void>.delayed(const Duration(seconds: 3));
    debugPrint('[SMOKE] 采集 3 秒后仍在采：${tracks.first.enabled}');
    await dispose(stream);
  });

  testWidgets('按窗口的源 id 取流：某一个窗口也能共享（面板里那半列选项）', (tester) async {
    final sources = await desktopCapturer.getSources(
      types: <SourceType>[SourceType.Screen, SourceType.Window],
    );
    final windows = sources
        .where((source) => source.type == SourceType.Window)
        .toList();
    // 桌面上一般总有几个窗口（本机测的时候有 2 个）；一个都没有就不硬凑
    if (windows.isEmpty) {
      debugPrint('[SMOKE] 这台机器上一个窗口都没有，跳过这条');
      return;
    }
    final picked = windows.first;
    debugPrint('[SMOKE] 选中的窗口：${picked.id} ${picked.name}');

    final stream = await navigator.mediaDevices.getDisplayMedia(
      <String, dynamic>{
        'video': <String, dynamic>{
          'deviceId': <String, dynamic>{'exact': picked.id},
        },
        'audio': false,
      },
    );
    final tracks = stream.getVideoTracks();
    expect(tracks, isNotEmpty, reason: '按窗口 id 也该拿到一路画面');
    debugPrint('[SMOKE] 窗口画面：${tracks.first.id}');
    await Future<void>.delayed(const Duration(seconds: 2));
    await dispose(stream);
  });

  testWidgets('不给源（系统默认源）：照样能取到（选择面板读不到列表时走的那条路）', (tester) async {
    final stream = await navigator.mediaDevices.getDisplayMedia(
      <String, dynamic>{'video': true, 'audio': false},
    );
    final tracks = stream.getVideoTracks();
    expect(tracks, isNotEmpty, reason: '默认源（主屏）该能取到画面');
    debugPrint(
      '[SMOKE] 默认源画面：${tracks.first.id} ${tracks.first.getSettings()}',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await dispose(stream);
  });

  testWidgets('逐条要一张真缩略图：面板里那些灰块能不能换成画面（2026-10-05 新增）', (tester) async {
    // 插件取源列表时**不填 thumbnail**（Windows 上那条 TODO），所以面板里一直是灰块；
    // 但它另有一条 `getDesktopSourceThumbnail`（原生里是 `source->UpdateThumbnail()`，
    // libwebrtc 的桌面采集真去抓一帧）—— 这一条就是量它到底给不给图、多贵。
    final sources = await desktopCapturer.getSources(
      types: <SourceType>[SourceType.Screen, SourceType.Window],
      thumbnailSize: ThumbnailSize(160, 90),
    );
    expect(sources, isNotEmpty);
    final watched = sources.take(8).toList();
    var withBytes = 0;
    final started = DateTime.now();
    for (final source in watched) {
      final at = DateTime.now();
      var bytes = await thumbnailOf(source);
      var ms = DateTime.now().difference(at).inMilliseconds;
      debugPrint(
        '[SMOKE] 缩略图 ${source.type} id=${source.id} '
        '${bytes?.length ?? 0} 字节 / ${jpegSize(bytes) ?? '?'} / ${ms}ms',
      );
      // 空图要不要重问一次？（2026-10-05 实测：这条用例**单跑**时空手起家
      // 一次就有真图；跟在前面那几条「真取过屏幕流」的用例后面跑，同一个
      // 进程里就老给 0 字节 —— 猜是原生那侧的采集刚收完尾。这里隔一会儿
      // 再问两轮，把「等一等能不能拿到」量出来，别靠猜。）
      for (var attempt = 2; bytes == null || bytes.isEmpty; attempt++) {
        if (attempt > 3) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final retryAt = DateTime.now();
        bytes = await thumbnailOf(source);
        ms = DateTime.now().difference(retryAt).inMilliseconds;
        debugPrint(
          '[SMOKE] 缩略图（第 $attempt 轮）${source.type} id=${source.id} '
          '${bytes?.length ?? 0} 字节 / ${jpegSize(bytes) ?? '?'} / ${ms}ms',
        );
      }
      if (bytes != null && bytes.isNotEmpty) withBytes += 1;
    }
    debugPrint(
      '[SMOKE] ${watched.length} 条一共 ${DateTime.now().difference(started).inMilliseconds}ms'
      '（有图的 $withBytes 条）',
    );
    expect(withBytes, greaterThan(0), reason: '至少屏幕那几条该给得出一张真图');
  });

  testWidgets('共享时的系统声音（Windows loopback）：整屏那条能拿到音频轨（2026-10-05 新增）', (
    tester,
  ) async {
    // 插件的 Windows 原生是 `ApplicationLoopbackCapturer`（WASAPI）：
    // 「整个屏幕」（源 id 0）抓**全部系统声音**；窗口那条按 PID 只抓那个程序的声音。
    // 这一条只回答「拿不拿得到那条音频轨」（听得到声音与否要两台设备对拨才知道）。
    final at = DateTime.now();
    final stream = await navigator.mediaDevices.getDisplayMedia(
      <String, dynamic>{
        // ⚠️ 插件那边 `video` 不给/不是 map 时会默认抓「整个屏幕」（源 id 0），
        // 所以这一条也顺手把默认源那道开了 —— 反正下面只看音频
        'video': <String, dynamic>{
          'deviceId': <String, dynamic>{'exact': '0'},
        },
        'audio': true,
      },
    );
    final audio = stream.getAudioTracks();
    debugPrint(
      '[SMOKE] 拿流用了 ${DateTime.now().difference(at).inMilliseconds}ms；'
      '音频轨 ${audio.length} 条'
      '${audio.isEmpty ? '' : '：${audio.first.id} ${audio.first.getSettings()}'}',
    );
    if (audio.isEmpty) {
      // 拿不到轨（系统挡了 / 这台机器上没有默认输出设备）也不把自检判死：
      // 日志里把事实写清楚，界面那边会退成「只共享画面」
      debugPrint('[SMOKE] 这台机器上给不出 loopback 音频轨（共享会退成只发画面）');
      await dispose(stream);
      return;
    }
    // 采几秒：建了轨但没有真正的采样在走（设备被独占等）要在这里现形
    await Future<void>.delayed(const Duration(seconds: 3));
    debugPrint('[SMOKE] 采集 3 秒后仍在采：${audio.first.enabled}');
    await dispose(stream);
  });
}
