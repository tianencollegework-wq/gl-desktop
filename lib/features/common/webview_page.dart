import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/webview_host.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../desktop_window/desktop_link_window.dart';

/// 内嵌浏览器，对应老端 `pages/mine/webview.vue`
/// （`/mine/webview?title=&src=<encodeURIComponent 的地址>`）。
///
/// 三处会进来：用户协议 / 隐私政策（「我的」页里那些外链）、
/// 「发现」页里 `type == 2` 的条目、以及扫到普通网址之后的兜底。
class WebViewPage extends ConsumerStatefulWidget {
  const WebViewPage({super.key, this.title = '', this.src = ''});

  /// 导航栏标题（老端也是从 query 里读）
  final String title;

  /// 要打开的地址（老端 `decodeURIComponent(options.src)`）
  final String src;

  @override
  ConsumerState<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends ConsumerState<WebViewPage> {
  int _progress = 0;
  String _error = '';

  @override
  void initState() {
    super.initState();
    // 桌面：网页一律进**独立的网页窗**（用户 2026-10-04：「把 webview 网页的窗口也
    // 独立窗口打开」）。别的入口（「我的」里的用户协议 / 隐私政策、「发现」里
    // type == 2 的外链、扫到网址的兜底）推进来时，把它们交给网页窗、这一页自己收掉。
    //
    // 为什么统一从这一页收口，而不是去改那几个入口：
    // * 一条规矩只写一遍，以后再加入口也不会漏；
    // * **Windows 上一条线程只装得下一个 webview**（WebView2 那套的
    //   DispatcherQueue 是线程级的，见规划书 S12.25）：主窗口自己占掉那个名额，
    //   网页窗就再也起不来了 —— 都推给网页窗，那一个名额就只给它在用。
    //
    // 网页窗里那一页不动（`webWindowHostProvider`，不然自己套自己）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _handOverToWindow());
  }

  void _handOverToWindow() {
    if (!mounted || widget.src.isEmpty) return;
    if (ref.read(webWindowHostProvider)) return;
    if (!openExternalLinkWindow(context, widget.src)) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);

    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(title: Text(widget.title)),
      body: widget.src.isEmpty
          ? _message(context, i18n.t('common.noData'))
          : Column(
              children: <Widget>[
                // 只在**拿到进度之后**才画：一开始就画一个「不知道什么时候完」的
                // 无限动画，既没信息量，也会让组件测试里的 `pumpAndSettle` 永远等下去
                if (_progress > 0 && _progress < 100)
                  LinearProgressIndicator(
                    value: _progress / 100,
                    minHeight: context.rpx(4),
                  ),
                Expanded(
                  child: _error.isEmpty
                      ? ref
                            .watch(webViewHostProvider)
                            .build(
                              url: widget.src,
                              onProgress: (progress) {
                                if (progress == _progress) return;
                                setState(() => _progress = progress);
                              },
                              onError: (description) =>
                                  setState(() => _error = description),
                            )
                      : Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Text(
                                i18n.t('common.loadFailed'),
                                style: TextStyle(
                                  fontSize: context.rpx(28),
                                  color: AppColors.text666,
                                ),
                              ),
                              SizedBox(height: context.rpx(20)),
                              OutlinedButton(
                                onPressed: () => setState(() {
                                  _error = '';
                                  _progress = 0;
                                }),
                                child: Text(i18n.t('common.retry')),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _message(BuildContext context, String text) => Center(
    child: Text(
      text,
      style: TextStyle(fontSize: context.rpx(28), color: AppColors.text666),
    ),
  );
}
