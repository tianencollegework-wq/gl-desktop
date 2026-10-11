import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../platform/desktop_shell.dart';

/// 选中的媒体类型（决定消息 `type`）。
///
/// `voice` 不是「选」出来的（按住说话录出来的），但走的是同一条上传链路
/// ——老端 `chat.vue::sendMessage` 的 `fileTypes` 里就有 `voice`。
enum MediaKind {
  image('image'),
  video('video'),
  file('file'),
  voice('voice');

  const MediaKind(this.wireName);

  /// 老端消息体里的 `type`
  final String wireName;
}

/// 用户选中的一份媒体。
///
/// 字段都是老端发消息时**真的用到的**：`content`（本地路径）、`fileName`、
/// `fileSize`，视频还要 `duration/width/height`（拼 `extends.fixMode`）。
@immutable
class PickedMedia {
  const PickedMedia({
    required this.path,
    required this.name,
    required this.size,
    required this.kind,
    this.durationSeconds = 0,
    this.width = 0,
    this.height = 0,
  });

  /// 本地文件路径（`file://` 开头也行，发送前会归一化）
  final String path;

  final String name;

  /// 字节
  final int size;

  final MediaKind kind;

  /// 视频/语音时长（秒）。视频：老端用 `Math.ceil(duration)`；
  /// 语音：老端那个 1 秒一次的计数器（`Recording.seconds`）
  final int durationSeconds;

  final double width;
  final double height;

  /// 老端 `im-input.vue::chooseVideo` 的 `fixMode`：横图 1、竖图 2
  int get fixMode => (width > height) ? 1 : 2;

  /// 去掉 `file://` 前缀的纯路径（Dio 上传要本地路径）
  String get localPath =>
      path.startsWith('file://') ? path.substring('file://'.length) : path;

  @override
  String toString() => 'PickedMedia(${kind.wireName}, $name, $size B)';
}

/// 选媒体的入口。
///
/// 抽成接口是为了**能在测试里注入假的**——真机会弹系统选择器，
/// 组件测试里没法点（与 [VoicePlayerNotifier] 同一个理由）。
abstract class MediaPicker {
  /// 相册（老端 `chooseImage`：最多 9 张、可拍照）
  Future<List<PickedMedia>> pickImages({int limit = 9});

  /// 视频（老端 `chooseVideo`：相册或录制）
  Future<PickedMedia?> pickVideo();

  /// 拍照（「＋」面板里的「拍摄」，对齐微信）：直接开系统相机，拍出来是一张图。
  /// 用户取消返回 null。
  Future<PickedMedia?> pickCamera();

  /// 任意文件（老端 `chooseFile` / APP 端那个原生插件，最多 5 个）
  Future<List<PickedMedia>> pickFiles({int limit = 5});
}

/// 真机实现。
///
/// 桌面（Windows / macOS / Linux）走同一套方法，但内部换成**文件对话框**：
/// 桌面根本没有相机（`image_picker_windows` 里 `ImageSource.camera` 会抛
/// `StateError`），而相册就是磁盘目录 —— `image_picker` 的桌面实现只给单选、
/// 还只认几种后缀，直接换成 `file_picker` 反而更接近手机上那个相册。
class SystemMediaPicker implements MediaPicker {
  /// [desktop] 留了口：默认跟着平台走（且测试里为假，见
  /// `desktop_shell.dart::desktopFeaturesEnabled`），用例可以显式指定。
  SystemMediaPicker([ImagePicker? picker, bool? desktop])
    : _picker = picker ?? ImagePicker(),
      _desktop = desktop ?? desktopFeaturesEnabled;

  final ImagePicker _picker;

  /// 桌面形态：选图/选视频走文件对话框，拍照直接拒绝（调用方也不会显示入口）
  final bool _desktop;

  @override
  Future<List<PickedMedia>> pickImages({int limit = 9}) async {
    if (_desktop) {
      return _pickFromDisk(
        type: FileType.image,
        limit: limit,
        kind: MediaKind.image,
      );
    }
    final files = await _picker.pickMultiImage(limit: limit);
    final result = <PickedMedia>[];
    for (final file in files) {
      result.add(
        PickedMedia(
          path: file.path,
          name: file.name,
          size: await _sizeOf(file.path),
          kind: MediaKind.image,
        ),
      );
    }
    return result;
  }

  @override
  Future<PickedMedia?> pickVideo() async {
    if (_desktop) {
      final picked = await _pickFromDisk(
        type: FileType.video,
        limit: 1,
        kind: MediaKind.video,
      );
      return picked.isEmpty ? null : picked.first;
    }
    final file = await _picker.pickVideo(source: ImageSource.gallery);
    if (file == null) return null;
    // 时长/宽高要读元数据。这里先用 0，等服务端回执把真实值修正过来
    // （老端是自己算出 fixMode 再发，我们让它随上传结果走，见规划书 S4.4b）
    return PickedMedia(
      path: file.path,
      name: file.name,
      size: await _sizeOf(file.path),
      kind: MediaKind.video,
    );
  }

  @override
  Future<PickedMedia?> pickCamera() async {
    // 桌面上没有相机这条路（`image_picker_windows` 对 camera 直接抛）：
    // 与其让原生插件抛一个用户看不懂的错，不如在这里就返回 null。
    // 界面上「拍摄」那一格在桌面本来就不显示（见聊天输入区）。
    if (_desktop) return null;
    final file = await _picker.pickImage(source: ImageSource.camera);
    if (file == null) return null;
    return PickedMedia(
      path: file.path,
      name: file.name,
      size: await _sizeOf(file.path),
      kind: MediaKind.image,
    );
  }

  @override
  Future<List<PickedMedia>> pickFiles({int limit = 5}) async {
    final files = await FilePicker.pickFiles();
    final picked = <PickedMedia>[];
    for (final file in files.take(limit)) {
      // `path` 在云盘/相册这类虚拟文件上会是 null（file_picker 13 的 URI 模型）
      final path = file.path;
      if (path == null) continue;
      picked.add(
        PickedMedia(
          path: path,
          name: file.name,
          size: await file.length() ?? 0,
          kind: _kindOf(file.extension ?? ''),
        ),
      );
    }
    return picked;
  }

  /// 桌面选图/选视频：系统文件对话框（可多选，最多 [limit] 个）。
  ///
  /// `FilePicker.pickFiles` 在 13.x 里就是**多选**语义（`pickFile` 才是单选，
  /// 旧的 `allowMultiple` 参数已删掉）。
  Future<List<PickedMedia>> _pickFromDisk({
    required FileType type,
    required int limit,
    required MediaKind kind,
  }) async {
    final files = await FilePicker.pickFiles(type: type);
    final picked = <PickedMedia>[];
    for (final file in files.take(limit)) {
      final path = file.path;
      if (path == null) continue;
      picked.add(
        PickedMedia(
          path: path,
          name: file.name,
          size: await file.length() ?? 0,
          kind: kind,
        ),
      );
    }
    return picked;
  }

  Future<int> _sizeOf(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException {
      // 拿不到大小就当 0：服务端那边还有一道限制
      return 0;
    }
  }

  /// 老端按后缀把文件分成图片/视频/文件三类（`im-input.vue::chooseFile`）
  MediaKind _kindOf(String extension) {
    const imageExts = <String>['jpg', 'jpeg', 'png', 'bmp', 'gif'];
    const videoExts = <String>['mp4', '3gp', 'avi', 'm2v', 'mkv', 'mov'];
    final ext = extension.toLowerCase();
    if (imageExts.contains(ext)) return MediaKind.image;
    if (videoExts.contains(ext)) return MediaKind.video;
    return MediaKind.file;
  }
}

final mediaPickerProvider = Provider<MediaPicker>(
  (ref) => SystemMediaPicker(null, ref.watch(desktopFeaturesProvider)),
);
