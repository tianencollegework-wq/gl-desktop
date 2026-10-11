import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 真机复现（2026-10-08）：**共享某个窗口**，把这个窗口最小化再还原，
/// 看画面到底卡在哪一环。
///
/// 用户报的：「我电脑共享一个应用程序的时候，如果把这个应用程序最小化了再点开，
/// 别人看到的画面就会一直卡在最小化前的最后一秒，但是声音是实时正常的就画面卡住」。
///
/// 本地笔记（S12.36）已知的一半：被**完全遮住**的窗口，DWM 不再为它合成新表面，
/// `PrintWindow` 拿回来的就是最后一帧 —— 那一次「切回前台又恢复实时」。
/// 最小化这一档用户说**不恢复**，所以要量清楚它卡在哪一步：
///
/// | 量到的东西 | 含义 |
/// | --- | --- |
/// | 缩略图（原生 `DesktopCapturer::CaptureFrame`）还原后**不再变** | 采集器回到窗口上也拿不到新画面 —— 卡在**采集**（我们这侧只能重建采集） |
/// | 缩略图在变、而对方还是没有新画面 | 卡在**发送**那一段（`replaceTrack` 那条路） |
///
/// 为什么用缩略图这条：`getDesktopSourceThumbnail` 在原生里就是
/// `source->UpdateThumbnail()` → `DesktopCapturer::CaptureFrame()` —— 与活采集
/// **同一个采集实现**，但它不需要 ICE 就能拿到「这一秒的画面」，
/// 逐帧比对 JPEG 字节就能判「画面还在不在变」。
///
/// ⚠️ 量活采集的帧数不能直接问 track：插件的 `MediaStreamTrack` 上根本没有
/// `getStats()`（只有 `muted/enabled/id/kind/label`）。只能把它挂到一条 PC 的
/// 发送端上问 `RTCRtpSender.getStats()`（即下面 ②④⑥⑧⑨ 那几档）；**不要求
/// 连接连上**，断开的 PC 也能读到 `media-source` / `track` 那两档。
/// （2026-10-07 本机试过 `pc1↔pc2` 对连那条路：两端一直停在
/// `RTCPeerConnectionStateNew`、出向帧恒为 0，所以别指望 `outbound-rtp`。）
///
/// 三条硬要求：
///
/// * **不碰用户桌面上任何窗口**：被测窗口是 PowerShell 起的一个自绘动画窗
///   （独立进程，跑完就杀）。不能用自己进程的窗口 —— libwebrtc 的窗口枚举会跳过
///   自己进程（`window_capturer_win.cc` 的 `EnumWindowsProc`），而 `getDisplayMedia`
///   只认插件缓存列表里的 id（`flutter_screen_capture.cc` 的 Windows 分支没有
///   Linux 那段「找不到就重建列表重试」）；
/// * **不引 `package:ffi`**（本仓没这条依赖，analyze 要干净）：那 4 个字节从 UCRT 借；
/// * 最后一步**只验证修法本身**：停掉旧轨 → `getSources`（强制刷新）→ 同一个源 id
///   再 `getDisplayMedia` → `replaceTrack` 换上去，看它能不能恢复。
///
/// 跑法（**先关掉正在跑的 release 实例**，debug 那颗会跟它抢同一个 app 名）；
/// 屏幕上会短暂出现一个写着 `FRAME n` 的小窗（就是我们自己的被测窗，约 40 秒）：
/// ```
/// flutter test integration_test/screen_share_minimize_test.dart -d windows
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('共享窗口 → 最小化 → 还原：画面卡在采集还是发送', (tester) async {
    if (!Platform.isWindows) {
      debugPrint('[MIN] 只有 Windows 有这个问题，跳过');
      return;
    }
    final win = _Win32.tryLoad();
    if (win == null) {
      debugPrint('[MIN] 装不上 Win32 绑定，跳过');
      return;
    }

    // ① 起一个「画面一直在变」的可见窗口（独立进程，跑完就杀）
    final script = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'gracelink_test_window.ps1',
    );
    await script.writeAsString(_helperScript);
    final helper = await Process.start('powershell.exe', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
    ]);
    debugPrint('[MIN] 辅助进程 pid=${helper.pid}（自绘动画窗 GRACELINK-TEST-WINDOW）');

    Future<DesktopCapturerSource?> findWindow() async {
      final sources = await desktopCapturer.getSources(
        types: <SourceType>[SourceType.Window],
      );
      for (final source in sources) {
        final id = int.tryParse(source.id);
        if (id == null || win.ownerPidOf(id) != helper.pid) continue;
        return source;
      }
      return null;
    }

    DesktopCapturerSource? picked;
    for (var attempt = 0; attempt < 20 && picked == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      picked = await findWindow();
    }
    if (picked == null) {
      debugPrint('[MIN] 辅助窗口一直没出现在源列表里，跳过');
      helper.kill();
      return;
    }
    var hwnd = int.parse(picked.id);
    debugPrint(
      '[MIN] 被测窗口：${picked.name} hwnd=$hwnd '
      'iconic=${win.isIconic(hwnd)} visible=${win.isWindowVisible(hwnd)}',
    );

    // ② 像素级探针：连抓三张缩略图，看画面还在不在变
    Future<String> thumbProbe(String label) async {
      final hashes = <String>[];
      for (var i = 0; i < 3; i++) {
        final fresh = await findWindow();
        if (fresh == null) {
          hashes.add('(源不在列表里)');
          await Future<void>.delayed(const Duration(milliseconds: 600));
          continue;
        }
        try {
          final bytes = await _thumbnail(fresh);
          hashes.add(
            bytes == null ? '(取不到)' : '${_fnv(bytes)}/${bytes.length}B',
          );
        } on Object catch (error) {
          hashes.add('(失败:$error)');
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      final distinct = hashes.toSet().length;
      final line = '[MIN] $label：$hashes → 三张里 $distinct 种'
          '（${distinct > 1 ? '画面在变' : '画面没变'}）';
      debugPrint(line);
      return line;
    }

    await thumbProbe('① 缩略图基线（可见）');

    // ③ 活采集这条路：**趁窗口还可见先取一条流**，后面每一步都量它产帧没有 ——
    // 那才是"对方收到的那条轨"本身（缩略图走的是另一个采集实例）。
    Future<MediaStreamTrack> capture() async {
      // 刷新插件那份源列表：它认的 id 必须在缓存里
      await desktopCapturer.getSources(types: <SourceType>[SourceType.Window]);
      final stream = await navigator.mediaDevices.getDisplayMedia(
        <String, dynamic>{
          'video': <String, dynamic>{
            'deviceId': <String, dynamic>{'exact': picked!.id},
          },
          'audio': false,
        },
      );
      return stream.getVideoTracks().first;
    }

    var track = await capture();
    debugPrint('[MIN] 活采集取到：${track.id}（label=${track.label}）');

    /// 量一次「这条采集一共产了多少帧」。
    ///
    /// 插件的 `MediaStreamTrack` 上没有 `getStats()`（只有 muted/enabled/id/kind/label），
    /// 所以把它挂到一条 PC 的发送端上问 `RTCRtpSender.getStats()`（原生把那把
    /// trackId 交给同一个 `getStats`）。**不要求连接连上**：断开状态下也能读到
    /// `media-source` / `track` 那两档。
    /// ⚠️ 这一档**还没在真机验过**（写它的时候没跑过），所以只打印、不作断言。
    Future<({int? frames, String detail})> framesNow() async {
      RTCPeerConnection? pc;
      try {
        pc = await createPeerConnection(<String, dynamic>{
          'sdpSemantics': 'unified-plan',
        });
        final transceiver = await pc.addTransceiver(
          track: track,
          init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendOnly,
          ),
        );
        final report = await transceiver.sender.getStats();
        final detail = <String>[];
        int? frames;
        for (final entry in report) {
          detail.add('${entry.type}(${entry.values.keys.join(',')})');
          final value =
              entry.values['frames'] ?? entry.values['framesCaptured'];
          final parsed = int.tryParse('${value ?? ''}');
          if (parsed != null && frames == null) frames = parsed;
        }
        return (frames: frames, detail: detail.join(' / '));
      } on Object catch (error) {
        return (frames: null, detail: '失败:$error');
      } finally {
        await pc?.close();
      }
    }

    /// 隔一秒量两次：涨了就是在产帧
    Future<void> framesProbe(String label) async {
      final before = await framesNow();
      await Future<void>.delayed(const Duration(seconds: 1));
      final after = await framesNow();
      final note = before.frames == null || after.frames == null
          ? '（这一版没给帧计数）'
          : (after.frames! > before.frames! ? '（在产帧）' : '（没在产帧）');
      debugPrint(
        '[MIN] $label：帧 ${before.frames} → ${after.frames}$note\n'
        '[MIN]   统计档：${after.detail}',
      );
    }

    await framesProbe('② 活采集基线');

    debugPrint('[MIN] —— 最小化 ——');
    win.showWindow(hwnd, _Win32.swMinimize);
    await Future<void>.delayed(const Duration(seconds: 1));
    debugPrint(
      '[MIN] 最小化后 iconic=${win.isIconic(hwnd)} '
      'visible=${win.isWindowVisible(hwnd)}',
    );
    await thumbProbe('③ 缩略图（最小化中）');
    await framesProbe('④ 活采集（最小化中）');

    debugPrint('[MIN] —— 还原 ——');
    win.showWindow(hwnd, _Win32.swRestore);
    await Future<void>.delayed(const Duration(seconds: 1));
    debugPrint(
      '[MIN] 还原后 iconic=${win.isIconic(hwnd)} '
      'visible=${win.isWindowVisible(hwnd)}',
    );
    await thumbProbe('⑤ 缩略图（还原后 1 秒）');
    await framesProbe('⑥ 活采集（还原后 1 秒）—— 用户报的就是这一段卡住');
    await Future<void>.delayed(const Duration(seconds: 3));
    await thumbProbe('⑦ 缩略图（还原后 5 秒）');
    await framesProbe('⑧ 活采集（还原后 5 秒）');

    // ④ 修法本身：**重建一次采集** → 新轨（真机那边接下来就是 replaceTrack 把它
    // 挂回同一个发送端 / 同一个 mid 上，不重新协商）
    debugPrint('[MIN] —— 重建采集（修法验证）——');
    final old = track;
    try {
      track = await capture();
      debugPrint('[MIN] 重建拿到新轨：${track.id}（与旧轨不同=${track.id != old.id}）');
      await framesProbe('⑨ 重建后的新轨');
      final again = await findWindow();
      if (again != null) {
        final bytes = await _thumbnail(again);
        debugPrint(
          '[MIN] 重建后缩略图：${bytes == null ? '(取不到)' : '${_fnv(bytes)}/${bytes.length}B'}',
        );
      }
    } on Object catch (error) {
      debugPrint('[MIN] 重建采集失败：$error');
    }
    debugPrint('[MIN] 旧轨：muted=${old.muted} enabled=${old.enabled}');

    // ⑤ 收尾：track 不 stop，系统的「正在捕获」标记不会消失
    await old.stop();
    await track.stop();
    helper.kill();
    debugPrint('[MIN] 收尾完成（辅助进程已杀）');
  });
}

/// 一帧真缩略图：插件自己那层 `getThumbnail` 在真机上会抛类型错（见 smoke 测试），
/// 所以直接打原生那条通道。
Future<Uint8List?> _thumbnail(DesktopCapturerSource source) async {
  try {
    final Object? bytes = await const MethodChannel('FlutterWebRTC.Method')
        .invokeMethod<Object?>('getDesktopSourceThumbnail', <String, dynamic>{
          'sourceId': source.id,
          'thumbnailSize': <String, int>{'width': 160, 'height': 90},
        });
    return bytes is Uint8List ? bytes : null;
  } on Object catch (error) {
    debugPrint('[MIN] 缩略图失败：$error');
    return null;
  }
}

/// FNV-1a：够用的内容指纹（同内容同值、内容一变值就变）
String _fnv(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = (hash ^ byte) * 0x01000193 & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 被测窗口：一个大号字块每 100ms 挪一次 —— 画面一直在变，指纹才有意义。
const String _helperScript = r'''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object System.Windows.Forms.Form
$f.Text = 'GRACELINK-TEST-WINDOW'
$f.Width = 560
$f.Height = 380
$l = New-Object System.Windows.Forms.Label
$l.Font = New-Object System.Drawing.Font('Consolas', 40)
$l.AutoSize = $true
$f.Controls.Add($l)
$t = New-Object System.Windows.Forms.Timer
$t.Interval = 100
$script:i = 0
$t.Add_Tick({
  $script:i++
  $l.Text = 'FRAME ' + $script:i
  $l.Left = 20 + ($script:i % 5) * 70
  $l.Top = 40 + ($script:i % 4) * 60
})
$t.Start()
[System.Windows.Forms.Application]::Run($f)
''';

/// Win32 的最小绑定：只用到「这扇窗是谁的 / 是不是最小化 / 最小化与还原」。
class _Win32 {
  _Win32._(
    this._isIconic,
    this._isWindowVisible,
    this._showWindow,
    this._ownerPid,
    this._malloc,
    this._free,
  );

  static const int swMinimize = 6;
  static const int swRestore = 9;

  final int Function(int hwnd) _isIconic;
  final int Function(int hwnd) _isWindowVisible;
  final int Function(int hwnd, int cmd) _showWindow;
  final int Function(int hwnd, Pointer<Uint32> out) _ownerPid;
  final Pointer<Uint8> Function(int bytes) _malloc;
  final void Function(Pointer<Uint8> p) _free;

  static _Win32? tryLoad() {
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final ucrt = DynamicLibrary.open('ucrtbase.dll');
      return _Win32._(
        user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'IsIconic',
        ),
        user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'IsWindowVisible',
        ),
        user32.lookupFunction<Int32 Function(IntPtr, Int32),
            int Function(int, int)>('ShowWindow'),
        user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>),
            int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId'),
        ucrt.lookupFunction<Pointer<Uint8> Function(IntPtr),
            Pointer<Uint8> Function(int)>('malloc'),
        ucrt.lookupFunction<Void Function(Pointer<Uint8>),
            void Function(Pointer<Uint8>)>('free'),
      );
    } on Object catch (error) {
      debugPrint('[MIN] Win32 绑定失败：$error');
      return null;
    }
  }

  bool isIconic(int hwnd) => _isIconic(hwnd) != 0;

  bool isWindowVisible(int hwnd) => _isWindowVisible(hwnd) != 0;

  void showWindow(int hwnd, int cmd) => _showWindow(hwnd, cmd);

  /// 这扇窗属于哪个进程（认领辅助进程那扇窗用）。
  ///
  /// 只借 4 个字节装那个 DWORD：为这一处把 `package:ffi` 引进来不值得。
  int ownerPidOf(int hwnd) {
    final buffer = _malloc(4).cast<Uint32>();
    try {
      _ownerPid(hwnd, buffer);
      return buffer.value;
    } finally {
      _free(buffer.cast<Uint8>());
    }
  }
}
