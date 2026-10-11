/// 网页窗那张界面（2026-10-04）：**顶上一条标签栏 + 下面当前标签那一页**。
///
/// 标签是「真」标签：每页自己的 webview 一直挂在树上（`IndexedStack`，没轮到的
/// 那几页只不画出来），所以来回切不会重新加载，滚动位置、页面里的状态都还在 ——
/// 这正是「多标签」与「同一个浏览器换地址」的区别（用户 2026-10-04：
/// 「还有你说的多标签做上呗」）。
///
/// 界面上只做三件事：画标签栏、画当前那一页、把「当前标签是谁」同步到原生标题栏
/// （任务栏那一项跟着变）。标签本身的规矩（去重 / 关掉之后竖谁 / 关完怎么办）
/// 在 [WebTabsController] 里，那部分有单测钉着。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/webview_host.dart';
import '../../core/theme/app_colors.dart';
import 'desktop_window_native.dart';
import 'web_tabs.dart';

/// 网页窗那一整张界面。
class DesktopWebWindow extends ConsumerStatefulWidget {
  const DesktopWebWindow({super.key, required this.controller});

  final WebTabsController controller;

  @override
  ConsumerState<DesktopWebWindow> createState() => _DesktopWebWindowState();
}

class _DesktopWebWindowState extends ConsumerState<DesktopWebWindow> {
  /// 「已经叫过一眼关窗」：native 关窗是异步的，而监听器可能连着响几下
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTabsChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTabsChanged);
    super.dispose();
  }

  /// 标签有变化：
  /// * 当前那个换了人（切标签 / 关掉当前这个）→ 原生标题栏跟着换 —— 任务栏上
  ///   那一项也就跟着变，和浏览器一样；
  /// * **关掉最后一个标签 = 关掉这扇窗**（和用户点 ✕ 同一条路：native 那边真销毁，
  ///   引擎一起释放，见 `desktop_window_native.dart` 的 `close()`）。
  void _onTabsChanged() {
    if (widget.controller.isEmpty) {
      if (_closing) return;
      _closing = true;
      debugPrint('[网页窗] 标签关光了，这扇窗跟着关');
      unawaited(DesktopWindowNative.close());
      return;
    }
    final active = widget.controller.active;
    if (active != null) {
      // 留一行日志：现场排查「点了几条外链、现在在哪个标签上」看这里
      debugPrint(
        '[网页窗] ${widget.controller.tabs.length} 个标签，当前=${active.label}',
      );
      unawaited(DesktopWindowNative.setTitle(active.label));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final tabs = widget.controller.tabs;
          if (tabs.isEmpty) return const SizedBox.shrink();
          final activeIndex = widget.controller.activeIndex;
          return Column(
            children: <Widget>[
              _WebTabBar(
                tabs: tabs,
                activeId: widget.controller.activeId,
                onActivate: widget.controller.activate,
                onClose: widget.controller.close,
              ),
              Expanded(
                // 只画当前那一页；别的页面留在树上（进度、滚动位置、登录态都在），
                // 切回来不用重新加载
                child: IndexedStack(
                  index: activeIndex,
                  sizing: StackFit.expand,
                  children: <Widget>[
                    for (final tab in tabs)
                      _WebTabView(
                        // key 用标签编号：标签换位子（关掉中间一个）也不会把
                        // 上一页的 webview 塞给下一个标签
                        key: ValueKey<int>(tab.id),
                        url: tab.url,
                        onTitle: (title) =>
                            widget.controller.setPageTitle(tab.id, title),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 顶上那条标签栏（能滚：标签多了往右排，不压缩每个标签的宽度）。
class _WebTabBar extends ConsumerWidget {
  const _WebTabBar({
    required this.tabs,
    required this.activeId,
    required this.onActivate,
    required this.onClose,
  });

  final List<WebTab> tabs;
  final int activeId;
  final ValueChanged<int> onActivate;
  final ValueChanged<int> onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final closeTip = ref.watch(appI18nProvider).t('webview.closeTab');
    return Container(
      height: 38,
      decoration: const BoxDecoration(
        color: AppColors.page,
        border: Border(bottom: BorderSide(color: AppColors.navDivider)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        itemBuilder: (context, index) {
          final tab = tabs[index];
          return _WebTabChip(
            tab: tab,
            active: tab.id == activeId,
            closeTip: closeTip,
            onActivate: () => onActivate(tab.id),
            onClose: () => onClose(tab.id),
          );
        },
      ),
    );
  }
}

/// 一个标签：名字一行（长了省略号）+ 右上角那颗 ✕。
class _WebTabChip extends StatelessWidget {
  const _WebTabChip({
    required this.tab,
    required this.active,
    required this.closeTip,
    required this.onActivate,
    required this.onClose,
  });

  final WebTab tab;
  final bool active;
  final String closeTip;
  final VoidCallback onActivate;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      child: Material(
        // 当前那个是白的（下面的内容也是白的，看着就是「连着」的）
        color: active ? AppColors.white : Colors.transparent,
        child: InkWell(
          onTap: onActivate,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    tab.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: active ? AppColors.text333 : AppColors.text666,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                Tooltip(
                  message: closeTip,
                  child: InkWell(
                    onTap: onClose,
                    customBorder: const CircleBorder(),
                    child: const Padding(
                      padding: EdgeInsets.all(5),
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: AppColors.text666,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一个标签里的网页（标题 / 进度 / 出错重试都在这一层，和 `/mine/webview`
/// 那一页同一套观感）。
class _WebTabView extends ConsumerStatefulWidget {
  const _WebTabView({super.key, required this.url, required this.onTitle});

  final String url;
  final ValueChanged<String> onTitle;

  @override
  ConsumerState<_WebTabView> createState() => _WebTabViewState();
}

class _WebTabViewState extends ConsumerState<_WebTabView> {
  int _progress = 0;
  String _error = '';

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    return Column(
      children: <Widget>[
        // 只在**拿到进度之后**才画（与 WebViewPage 同一条规矩：一开始就画个
        // 不知道什么时候完的动画，既没信息量，组件测试里也等不到 settle）
        if (_progress > 0 && _progress < 100)
          LinearProgressIndicator(value: _progress / 100, minHeight: 3),
        Expanded(
          child: _error.isEmpty
              ? ref
                    .watch(webViewHostProvider)
                    .build(
                      url: widget.url,
                      onProgress: (progress) {
                        if (progress == _progress) return;
                        setState(() => _progress = progress);
                      },
                      onError: (description) =>
                          setState(() => _error = description),
                      onTitle: widget.onTitle,
                    )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        i18n.t('common.loadFailed'),
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.text666,
                        ),
                      ),
                      const SizedBox(height: 10),
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
    );
  }
}
