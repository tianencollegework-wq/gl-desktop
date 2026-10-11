import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/desktop_shell.dart';
import '../util/media_format.dart';

/// 保存成功后该提示哪一句。
///
/// 手机上是「已保存到相册」，**桌面上没有相册** —— 那边存的是下载目录里的一个
/// 文件（见 [SystemMediaSaver.saveImageToGallery]），所以提示得换成「已保存到
/// 下载目录」，否则用户会一直去手机里找。
///
/// [desktop] 不传就跟平台走（且测试里为假，见 `desktopFeaturesEnabled`）。
String savedMediaToastKey({bool? desktop}) =>
    (desktop ?? desktopFeaturesEnabled)
    ? 'common.savedToDownloads'
    : 'common.savedToGallery';

/// 下载 / 存相册 / 打开文件（S4.6 的预览要用）。
///
/// 对应老端这几处：
/// * 图片、视频的「保存到本地」→ `uni.downloadFile` + `saveVideoToPhotosAlbum`
///   （`pages/message/video.vue::download`）；
/// * 文件的「本地预览」→ `uni.downloadFile` + `uni.openDocument`
///   （`mixins/chat.js::preview`），只支持 pdf/office 那几种后缀；
/// * 文件的「在线预览」→ 老端是跳 webview，**但那个地址在客户端从来没被赋过值**
///   （`item.preview` 全项目没人写），所以线上它打开的是 `undefined`。
///   新端改成用系统浏览器打开消息里的真实地址——功能先能用。
///
/// 抽成接口是为了能在测试里注入替身：这些全是平台能力（相册、系统应用），
/// 组件测试里跑不了（与选图/录音同一个做法）。
abstract class MediaSaver {
  /// 下载到临时目录，返回本地路径。
  ///
  /// 传进来的如果是本机路径（比如自己刚发出去、还在上传的那条消息），则原样返回。
  Future<String> download(String url, {required String fileName});

  /// 保存网络图片到相册
  Future<void> saveImageToGallery(String url, {required String fileName});

  /// 保存网络视频到相册
  Future<void> saveVideoToGallery(String url, {required String fileName});

  /// 用系统应用打开本地文件（pdf / office 文档）
  Future<bool> openLocalFile(String path);

  /// 用浏览器（或系统地图）打开一个链接
  Future<bool> openUrl(String url);
}

/// 真机实现
class SystemMediaSaver implements MediaSaver {
  /// [desktop] 留了口：默认跟着平台走（且测试里为假，见
  /// `desktop_shell.dart::desktopFeaturesEnabled`），用例可以显式指定。
  SystemMediaSaver([Dio? dio, bool? desktop])
    : _dio = dio ?? Dio(),
      _desktop = desktop ?? desktopFeaturesEnabled;

  final Dio _dio;

  /// 桌面形态：没有相册、没有 `open_filex`，存档与开文件都换路（见下面各处）
  final bool _desktop;

  @override
  Future<String> download(String url, {required String fileName}) async {
    // 本机文件：不用下载（乐观消息在“上传成功”之前就是本机路径）
    if (!url.startsWith('http')) return localFilePathOf(url);
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${_safeName(fileName)}';
    final file = File(path);
    // 已经下过就直接用（老端每次都重下，浪费流量）
    if (await file.exists() && await file.length() > 0) return path;
    await _dio.download(url, path);
    return path;
  }

  @override
  Future<void> saveImageToGallery(
    String url, {
    required String fileName,
  }) async {
    final path = await download(url, fileName: fileName);
    if (_desktop) {
      // 桌面没有系统相册（`gal` 也没做 Windows/macOS/Linux 实现）：
      // 存到「下载」目录 —— 用户能自己找到，与手机上的「存到相册」一个意思。
      await _copyToDownloads(path, fileName);
      return;
    }
    if (!await Gal.hasAccess()) await Gal.requestAccess();
    await Gal.putImage(path);
  }

  @override
  Future<void> saveVideoToGallery(
    String url, {
    required String fileName,
  }) async {
    final path = await download(url, fileName: fileName);
    if (_desktop) {
      await _copyToDownloads(path, fileName);
      return;
    }
    if (!await Gal.hasAccess()) await Gal.requestAccess();
    await Gal.putVideo(path);
  }

  /// 把已经下好的文件复制到系统「下载」目录（同名就覆盖）。
  ///
  /// 拿不到下载目录时（部分 Linux 环境）退回文档目录 —— 两个都拿不到才抛。
  Future<void> _copyToDownloads(String sourcePath, String fileName) async {
    final dir =
        (await getDownloadsDirectory()) ??
        await getApplicationDocumentsDirectory();
    await File(sourcePath).copy('${dir.path}/${_safeName(fileName)}');
  }

  @override
  Future<bool> openLocalFile(String path) async {
    // 桌面（2026-10-03）：`open_filex` 只做了安卓/iOS，桌面上调它会抛
    // 「MissingPluginException」。系统里「用默认应用打开一个文件」这件事
    // `url_launcher` 就能做（Windows 上走 ShellExecute），所以直接转过去。
    if (_desktop) return openUrl(Uri.file(path).toString());
    final result = await OpenFilex.open(path);
    return result.type == ResultType.done;
  }

  @override
  Future<bool> openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 文件名只用来拼本地路径，防一手路径穿越与 Windows 非法字符
  String _safeName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll('..', '_')
        .trim();
    if (cleaned.isEmpty) return 'download';
    return cleaned.length > 80
        ? cleaned.substring(cleaned.length - 80)
        : cleaned;
  }
}

final mediaSaverProvider = Provider<MediaSaver>(
  (ref) => SystemMediaSaver(null, ref.watch(desktopFeaturesProvider)),
);
