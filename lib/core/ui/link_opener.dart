import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/desktop_window/desktop_link_window.dart';
import '../router/app_router.dart';
import '../util/link_safety.dart';

/// 点一个网址，**三道岔路**（用户 2026-09-25 定的规矩，见 `core/util/link_safety.dart`）：
///
/// * 我们自己的站点（`gracelink.cc` 及其子域名）→ **直接**进应用内浏览器；
/// * 微信/腾讯那一系 → 跳到「已停止访问该网页」的拦截页，**不给访问**；
/// * 其它第三方 → 先到「第三方网址，是否继续访问」，点「继续访问」才加载。
///
/// 单独一个文件（不是一个页面里的私有函数）的理由：**聊天里点链接与扫一扫扫到
/// 链接必须是同一条路**。用户 2026-09-27 说得很清楚：「外部链接就跳转 webview，
/// 但同时也要遵守聊天里发链接点击的处理原则」——两处各写一份迟早会走偏。
///
/// 认不出主机名就什么都不做（宁可没反应，也别把用户丢到一个空页）。
void openChatLink(BuildContext context, String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return;
  final encoded = Uri.encodeComponent(url);

  switch (linkSafetyOf(url)) {
    case LinkSafety.official:
      // 桌面：直接开成**系统级独立窗口**里那页内嵌浏览器（微信 PC 那种
      // 「弹一扇自己的浏览器窗口」，用户 2026-10-04 要的）
      if (openExternalLinkWindow(context, url)) return;
      context.push(
        '${AppRoutes.webview}'
        '?title=${Uri.encodeComponent(uri.host)}'
        '&src=$encoded',
      );
    case LinkSafety.blocked:
      context.push('${AppRoutes.linkBlocked}?url=$encoded');
    case LinkSafety.thirdParty:
      context.push('${AppRoutes.linkConfirm}?url=$encoded');
  }
}
