import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 一段录好的音频。
///
/// 老端没有这个对象：它的录音结果就是一个临时路径 + 一个「秒数」计数器
/// （`im-input.vue` 用 `setInterval` 每秒 +1），这里把时长一起带上，
/// 免得调用方再去读文件。
@immutable
class Recording {
  const Recording({
    required this.path,
    required this.durationMs,
    required this.sizeBytes,
  });

  /// 本地文件路径（上传完之前界面就用它显示）
  final String path;

  /// 录制时长（毫秒，由录音器自己掐表，不是从音频文件里读的）
  final int durationMs;

  /// 字节数（拼 `fileSize` 用；老端的语音消息根本不给这个字段）
  final int sizeBytes;

  /// 老端发出去的 `extends.duration` 是整秒（1 秒一次的计数器），这里向上取整
  int get seconds => durationMs <= 0 ? 0 : (durationMs / 1000).ceil();

  @override
  String toString() => 'Recording($path, ${durationMs}ms, $sizeBytes B)';
}

/// 录音。抽成接口是为了能在测试里注入替身（真机会弹麦克风权限）。
///
/// 与老端 `uni.getRecorderManager()` 的对应关系：
/// * 老端 `start({duration: 60000, format: 'mp3'})` → [maxDuration] 60 秒；
/// * 老端 `onStop` 里判 `recLength < 1` → [minDuration] 1 秒；
/// * 取消（上滑）后把临时文件丢掉 → [cancel]。
///
/// **刻意不同**：老端录 mp3（H5 那边靠 lamejs，APP 端靠系统编码器）；
/// `record` 这个库没有 mp3 编码器，用的是 AAC（`.m4a`）——安卓、iOS、浏览器
/// 都能放。真正老的客户端收到的还是同一个 URL，只是文件后缀不同。
abstract class VoiceRecorder {
  /// 最长录多久（老端 `duration: 60000`）
  static const Duration maxDuration = Duration(seconds: 60);

  /// 短于这个时长就丢掉（老端 `duration < 1` → `chat.recordToLow`）
  static const Duration minDuration = Duration(seconds: 1);

  /// 麦克风权限（老端没有显式申请，靠 `onError` 的 code 201 提示）
  Future<bool> hasPermission();

  /// 开始录音（超过 [maxDuration] 由上层停下；实现里也会兜一道）
  Future<void> start();

  /// 停止。返回 null 表示这次没录到东西（拿不到文件）
  Future<Recording?> stop();

  /// 取消（丢掉文件）
  Future<void> cancel();

  /// 录音时的**音量**（0 静音 ~ 1 最大），给中间那个声波气泡用。
  ///
  /// 默认给一条空流：测试替身不必实现它，界面就画「没声音」的静音波形
  /// （不会因此卡住或报错）。
  Stream<double> get amplitude => const Stream<double>.empty();

  /// 丢掉一段已录好的音频（比如太短不合格的那段）
  Future<void> discard(Recording recording);

  Future<void> dispose();
}

/// 真机实现（`record` 包）
class SystemVoiceRecorder implements VoiceRecorder {
  SystemVoiceRecorder([AudioRecorder? recorder])
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  final Stopwatch _watch = Stopwatch();
  String? _path;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/gl_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        numChannels: 1,
        // 16kHz 单声道：人声够用（语音不需要更宽的频带，采样率再往上只是白花体积）
        sampleRate: 16000,
        // 24kbps：AAC-LC 单声道在 16kHz 下的**实用下限**。
        //   60 秒 ≈ 180KB、10 秒 ≈ 30KB（原来是 64kbps，同样一条要 3 倍大）。
        // 不建议再往下：16kbps 及以下 AAC 会明显发闷、带金属音，
        // 而语音本来就短 —— 一条 10 秒的少那 10KB，用户根本感觉不到，
        // 但音质掉得很明显。
        // 注：`record` 走的是**系统编码器**（安卓 MediaCodec / 苹果 AVAssetWriter），
        // 这个值会被真正采纳（不像 MediaRecorder 那样会被某些机型悄悄抬回去）。
        bitRate: 24000,
      ),
      path: path,
    );
    _path = path;
    _watch
      ..reset()
      ..start();
  }

  @override
  Future<Recording?> stop() async {
    _watch.stop();
    final duration = _watch.elapsedMilliseconds;
    final stopped = await _recorder.stop();
    final path = stopped ?? _path;
    _path = null;
    if (path == null) return null;

    var size = 0;
    try {
      size = await File(path).length();
    } on FileSystemException {
      // 拿不到就当 0：服务端那边还有一道限制
    }
    return Recording(path: path, durationMs: duration, sizeBytes: size);
  }

  /// dBFS → 0..1：人声一般在 -40~-10 dBFS，这里把 -50~0 摊开
  @override
  Stream<double> get amplitude => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 110))
      .map((sample) => ((sample.current + 50) / 50).clamp(0.0, 1.0));

  @override
  Future<void> cancel() async {
    _watch.stop();
    final path = _path;
    _path = null;
    try {
      await _recorder.cancel();
    } on Object {
      // 已经停了/平台不支持取消：忽略，别把取消流程卡住
    }
    if (path != null) {
      try {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } on FileSystemException {
        // 临时文件删不掉无所谓，系统会自己清临时目录
      }
    }
  }

  @override
  Future<void> discard(Recording recording) async {
    try {
      final file = File(recording.path);
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // 临时文件删不掉无所谓
    }
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

final voiceRecorderProvider = Provider<VoiceRecorder>(
  (ref) => SystemVoiceRecorder(),
);
