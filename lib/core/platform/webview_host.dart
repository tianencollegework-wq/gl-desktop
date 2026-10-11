import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../i18n/app_i18n.dart';
import 'desktop_shell.dart';

/// 内嵌浏览器（老端是 uniapp 的 `<web-view>`，装在我们自己的页面里）。
///
/// 抽成接口是为了**能在测试里注入假的**——真机上 webview 是平台视图，
/// 组件测试里建 `WebViewController` 会直接抛
/// 「WebViewPlatform.instance is not set」（与 [MediaPicker] 同一个理由）。
abstract class WebViewHost {
  /// 建一个能直接摆进界面的 webview；[onProgress] 报告加载进度（0–100），
  /// [onError] 在加载失败时给一句人话，[onTitle] 在网页报了标题时给一行字
  /// （只有网页窗的多标签用它：标签条和原生标题栏都跟着换；其余实现忽略即可）。
  Widget build({
    required String url,
    ValueChanged<int>? onProgress,
    ValueChanged<String>? onError,
    ValueChanged<String>? onTitle,
  });
}

/// 真机实现：官方 `webview_flutter`（安卓上是系统 WebView）
class SystemWebViewHost implements WebViewHost {
  const SystemWebViewHost();

  @override
  Widget build({
    required String url,
    ValueChanged<int>? onProgress,
    ValueChanged<String>? onError,
    ValueChanged<String>? onTitle,
  }) => _SystemWebView(url: url, onProgress: onProgress, onError: onError);
}

class _SystemWebView extends StatefulWidget {
  const _SystemWebView({required this.url, this.onProgress, this.onError});

  final String url;
  final ValueChanged<int>? onProgress;
  final ValueChanged<String>? onError;

  @override
  State<_SystemWebView> createState() => _SystemWebViewState();
}

class _SystemWebViewState extends State<_SystemWebView> {
  late final WebViewController _controller = _create();

  WebViewController _create() {
    final controller = WebViewController()
      // 老端 `<web-view>` 默认就允许脚本（协议、隐私政策那类页面依赖它）
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) => widget.onProgress?.call(progress),
          onWebResourceError: (error) {
            // 只有主框架失败才算页面挂了（子资源失败不影响阅读）
            if (error.isForMainFrame == false) return;
            widget.onError?.call(error.description);
          },
        ),
      );
    controller.loadRequest(Uri.parse(widget.url));
    return controller;
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}

/// Windows 实现：**真 webview**（微软 Edge WebView2，2026-10-04）。
///
/// 用 `webview_flutter_windows`（jnschulze 那套的维护分支）：它把 WebView2
/// 离屏渲染成一张纹理再贴进 widget 树，所以在窗口里摆的就是一个普通 widget ——
/// 没有「原生层浮在 Flutter 之上」那类空气墙问题，多窗口（每扇窗一颗引擎）
/// 也各自有各自的纹理。
///
/// 用户 2026-10-04 的原话：「为什么好像都要将链接从浏览器打开，不能像微信电脑端
/// 一样做一个 webview 吗」—— 这一份就是那个 webview。
///
/// 起不来时（这台机器没装 WebView2 运行时、或插件那层出错）**不报错、不白屏**：
/// 退回 [DesktopWebViewHost] 那一页（地址 + 「在浏览器中打开」），用户照样能看。
class WindowsWebViewHost implements WebViewHost {
  const WindowsWebViewHost();

  @override
  Widget build({
    required String url,
    ValueChanged<int>? onProgress,
    ValueChanged<String>? onError,
    ValueChanged<String>? onTitle,
  }) => _WindowsWebView(
    url: url,
    onProgress: onProgress,
    onError: onError,
    onTitle: onTitle,
  );
}

class _WindowsWebView extends StatefulWidget {
  const _WindowsWebView({
    required this.url,
    this.onProgress,
    this.onError,
    this.onTitle,
  });

  final String url;
  final ValueChanged<int>? onProgress;
  final ValueChanged<String>? onError;
  final ValueChanged<String>? onTitle;

  @override
  State<_WindowsWebView> createState() => _WindowsWebViewState();
}

class _WindowsWebViewState extends State<_WindowsWebView> {
  final WebviewController _controller = WebviewController();

  StreamSubscription<LoadingState>? _loading;
  StreamSubscription<WebErrorStatus>? _loadError;
  StreamSubscription<String>? _title;

  /// WebView2 起不来 → 退回「系统浏览器」那一页（见 [WindowsWebViewHost] 注释）
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _controller.initialize();
    } on Object catch (error) {
      debugPrint('[webview] WebView2 没起来，退回系统浏览器那一页：$error');
      // 窗口已经在关了就别再 setState（关窗那一帧真会撞上）
      if (!mounted) {
        await _controller.dispose();
        return;
      }
      widget.onProgress?.call(100);
      setState(() => _unavailable = true);
      return;
    }
    if (!mounted) {
      await _controller.dispose();
      return;
    }

    // WebView2 不给「加载到百分之几」这个数（它只在几个节点上报状态），
    // 所以那根进度线干脆不画（页面那边只认 0<p<100），加载完直接报 100。
    _loading = _controller.loadingState.listen((state) {
      if (state == LoadingState.navigationCompleted) {
        widget.onProgress?.call(100);
      }
    });
    _loadError = _controller.onLoadError.listen(
      (status) => widget.onError?.call(status.name),
    );
    // 网页自己报的标题（`<title>`）：网页窗的标签条靠它把域名换成页面名
    _title = _controller.title.listen((value) => widget.onTitle?.call(value));

    await _load(widget.url);
    if (mounted) setState(() {});
  }

  /// 换地址 / 首次加载。起不来那些错都走 [onError] 那条线（页面会画重试）。
  Future<void> _load(String url) async {
    if (_unavailable || url.isEmpty) return;
    try {
      await _controller.loadUrl(url);
    } on Object catch (error) {
      widget.onError?.call('$error');
    }
  }

  @override
  void didUpdateWidget(covariant _WindowsWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一颗窗口里换地址（主窗口连着点了两条外链）：不重建控件，让它自己过去
    if (oldWidget.url != widget.url) unawaited(_load(widget.url));
  }

  @override
  void dispose() {
    _loading?.cancel();
    _loadError?.cancel();
    _title?.cancel();
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) {
      // 退回那一页：地址亮出来、一颗按钮跳系统浏览器
      return const DesktopWebViewHost().build(
        url: widget.url,
        onProgress: widget.onProgress,
        onError: widget.onError,
        onTitle: widget.onTitle,
      );
    }
    if (!_controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Webview(_controller);
  }
}

/// 桌面兜底实现：**系统浏览器打开**。
///
/// Windows 上现在有真 webview 了（[WindowsWebViewHost]），这一份退到两个位置：
/// * macOS / Linux —— 那两个平台没有可用的 webview（`webview_flutter` 只支持
///   安卓/iOS/macOS 的 WKWebView，Windows 与 Linux 都没有官方实现）；
/// * Windows 上 WebView2 起不来的兜底（用户机器没装那套运行时）。
///
/// 原来 `SystemWebViewHost` 在桌面上只要构造 `WebViewController()` 就抛
/// 「WebViewPlatform.instance is not set」—— 协议、隐私政策、「发现」里
/// `type == 2` 的外链、扫到网址的兜底，四个入口全部点到就崩。所以这里给的是
/// 一个**能用的降级页**：把地址亮出来、给一颗按钮，点开即跳系统浏览器。
class DesktopWebViewHost implements WebViewHost {
  const DesktopWebViewHost();

  @override
  Widget build({
    required String url,
    ValueChanged<int>? onProgress,
    ValueChanged<String>? onError,
    ValueChanged<String>? onTitle,
  }) => _DesktopWebView(url: url, onProgress: onProgress, onError: onError);
}

class _DesktopWebView extends ConsumerStatefulWidget {
  const _DesktopWebView({required this.url, this.onProgress, this.onError});

  final String url;
  final ValueChanged<int>? onProgress;
  final ValueChanged<String>? onError;

  @override
  ConsumerState<_DesktopWebView> createState() => _DesktopWebViewState();
}

class _DesktopWebViewState extends ConsumerState<_DesktopWebView> {
  @override
  void initState() {
    super.initState();
    // 进度条那套在桌面没有意义（页面根本不在我们这里加载）：
    // 直接把进度报成 100，让外面那条进度线收掉
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onProgress?.call(100);
    });
  }

  Future<void> _open() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      widget.onError?.call('launch failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.open_in_new, size: 48, color: Color(0xFF999999)),
            const SizedBox(height: 16),
            Text(
              i18n.t('webview.desktopTip'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: Color(0xFF333333)),
            ),
            const SizedBox(height: 8),
            // 地址亮出来：既让用户知道要开的是哪儿，也方便复制
            SelectableText(
              widget.url,
              textAlign: TextAlign.center,
              maxLines: 3,
              style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _open,
              child: Text(i18n.t('webview.openInBrowser')),
            ),
          ],
        ),
      ),
    );
  }
}

/// 这台机器上能用哪一个 webview。
///
/// 判据是**平台**，不是 [desktopFeaturesProvider]：独立窗口那几颗引擎里那个开关
/// 是关的（窗口里按手机版式排，见 `child_window_app.dart`），但网页窗照样得用
/// Windows 那一支 —— 手机那支的 `WebViewController` 在 Windows 上只要一建就抛
/// 「WebViewPlatform.instance is not set」（2026-10-04 加网页窗时踩过：窗口里
/// 不换这一份，网页窗自己先把自已弄崩）。
///
/// 四种归宿：
/// * **Windows**：WebView2（本仓那份 `webview_flutter_windows` 分支，见上）；
/// * **macOS**：系统那一支 —— `webview_flutter` 的 WKWebView（那个包自己声明了
///   `macos`，与手机同一套 Dart API，所以这边不用另写实现）。2026-10-11 加；
///   原先这段注释写的是「只到安卓/iOS」，那是错的；
/// * **Linux**：平台那支没有实现 → [DesktopWebViewHost] 那张回退页
///   （地址 + 「在浏览器中打开」）；
/// * **手机**：系统那一支。
///
/// ⚠️ 这里的 macOS 分支**在 Windows 开发机上跑不到**（用例只跑宿主平台那一支），
/// 真机验收时顺手点一次网页窗。
///
/// 用例里那个 webview 是替身，不该被宿主平台换掉 —— 那些用例都显式
/// override 了 [webViewHostProvider]（见 `test/features/chat_link_test.dart`）。
WebViewHost webViewHostForPlatform() {
  if (Platform.isWindows) return const WindowsWebViewHost();
  // macOS：WKWebView（系统那一支现成的，与手机同一套实现）
  if (Platform.isMacOS) return const SystemWebViewHost();
  // Linux：平台那支没有 Linux 实现 → 回退页
  if (isDesktopRuntime) return const DesktopWebViewHost();
  return const SystemWebViewHost();
}

final webViewHostProvider = Provider<WebViewHost>(
  (ref) => webViewHostForPlatform(),
);
