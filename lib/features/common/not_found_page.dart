import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';

/// 路由没匹配上时给的那一页（`createAppRouter()` 的 `errorBuilder`）。
///
/// S12.9 起有 7 种语言：这页会被人看到（外部链接点进来、路由写错了），
/// 以前写死中文，切到日语/西语还是中文 —— 现在标题与正文都走语言包。
///
/// 单独拎成一个页面（而不是塞在 `app_router.dart` 里的闭包）：这样能用
/// 普通 widget 用例钉住「真的翻了」，不用为了验一句话去把整个路由树拉起来。
class RouteNotFoundPage extends ConsumerWidget {
  const RouteNotFoundPage({super.key, required this.path});

  /// 没匹配上的那个路径（原样显示出来，好让人知道错在哪）
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);

    return Scaffold(
      appBar: AppBar(title: Text(i18n.t('common.pageNotFound'))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            i18n.t('common.routeUnmatched', <String, String>{'path': path}),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Colors.black54),
          ),
        ),
      ),
    );
  }
}
