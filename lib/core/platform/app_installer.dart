import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 整包更新用的下载 / 安装（S7.2）。
///
/// 对应老端那两段平台能力：
/// * `plus.downloader.createDownload`（带进度、可中断）；
/// * `plus.runtime.install`（安卓交给系统安装器；iOS 只能 `openURL` 去 App Store）。
///
/// 抽成接口的理由与 `MediaSaver` / `CallKeepAlive` 一样：下载与安装都是平台能力，
/// 单测里跑不了，而「进度回调、可取消、失败要说清楚」这些行为必须能钉住。
abstract interface class AppInstaller {
  /// 下载更新包到临时目录，返回本地路径。
  ///
  /// [onProgress] 收到的是 0~1；服务端没给 `Content-Length` 时收到 null。
  /// [cancelToken] 用来中断（用户点「取消下载」）。
  Future<String> download(
    String url, {
    required String fileName,
    void Function(double? progress)? onProgress,
    CancelToken? cancelToken,
  });

  /// 交给系统安装器（安卓的 APK）。返回是不是真的交出去了。
  ///
  /// 注意：**系统会再要一次用户同意**（首次还要先允许「安装未知应用」），
  /// 这里返回 true 只代表安装界面被拉起来了。
  Future<bool> installPackage(String path);

  /// 用浏览器打开（`.html` 那种更新、以及 iOS 的一切地址）
  Future<bool> openUrl(String url);
}

/// 真机实现
class SystemAppInstaller implements AppInstaller {
  SystemAppInstaller([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<String> download(
    String url, {
    required String fileName,
    void Function(double? progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${_safeName(fileName)}';
    await _dio.download(
      url,
      path,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) => onProgress?.call(
        total > 0 ? (received / total).clamp(0, 1).toDouble() : null,
      ),
    );
    return path;
  }

  @override
  Future<bool> installPackage(String path) async {
    try {
      final result = await OpenFilex.open(path);
      if (result.type == ResultType.done) return true;
      debugPrint('[更新] 安装器没拉起来：${result.type} ${result.message}');
      return false;
    } on Object catch (error) {
      debugPrint('[更新] 安装失败：$error');
      return false;
    }
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
    if (cleaned.isEmpty) return 'update.apk';
    return cleaned.length > 80
        ? cleaned.substring(cleaned.length - 80)
        : cleaned;
  }
}

final appInstallerProvider = Provider<AppInstaller>(
  (ref) => SystemAppInstaller(),
);
