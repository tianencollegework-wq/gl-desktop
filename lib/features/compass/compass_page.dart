import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../desktop_window/desktop_window_service.dart';

/// 「发现」tab，对照老端 `pages/compass/index.vue`。
///
/// **这一页现在是纯客户端写死的**（用户 2026-09-27：
/// 「发现页面也不要听服务端的了，直接改成纯客户端写死的，适配国际化。
/// 现在就搞一栏，就是『灵听』，然后 logo 用我给你上传的这张」）。
///
/// 与老端的分歧（刻意的）：老端这一页完全由 `globalConfig.compass` 驱动 ——
/// `list` 里每项是 `{icon, name, url, type, badge}`，`mode == 1` 画成一列、
/// `mode == 2` 画成三列宫格，`type == 2` 走内嵌浏览器、其余当站内路由跳。
/// 于是「发现里有什么」捏在服务端手里，而且**名字是服务端配好的中文**
/// （切到英文界面那一行还是中文），图标还得靠网络图。
///
/// 现在有两件事放在这儿：**灵听**（音乐）和**媒体号**（S11.1）。名字走语言包
/// （`lingting.title` / `news.title`）；灵听的图标是随包的
/// `assets/images/lingting_logo.png`，资讯没有现成图标、用的是一颗
/// Material 图标 + 圆角底色（见 [_newsIcon]）—— 离线也在、切语言也跟着变。
///
/// 服务端那份配置（`CompassConfig`）**照样在解析**（接口本来就返回它），
/// 只是这一页不再看它了；`HomeShell` 里那个 `compass.status == 1` 的开关
/// 也不再决定这一格在不在。
///
/// 要加第三栏：在 build 里那个 Column 里加一块 `_card`（图标可以是随包资源也可以是
/// 纯 Widget，名字加一对语言包 key，路由用现成的或新加一条）。
///
/// **媒体号这一栏是纯客户端的内容源**（手机自己去拉公开 RSS，服务端不参与，
/// 见 `domain/news/news_feed.dart`）：所以它不受服务端 `compass` 配置影响，
/// 也不会因为服务端某个接口挂了而消失。
class CompassPage extends ConsumerWidget {
  const CompassPage({super.key});

  /// 灵听那一栏的图标（用户 2026-09-27 提供的那张：音符 + 环绕的叶子）。
  ///
  /// 为什么随包而不是问服务端要：老端那张是 `/static/image/...` 的网络图，
  /// 弱网/断网时「发现」里就会空一格；这一张本来就 30KB 不到，随包最省事。
  static const String lingtingIconAsset = 'assets/images/lingting_logo.png';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(vertical: context.rpx(_gapRpx)),
      child: Column(
        children: <Widget>[
          _card(
            context,
            child: _entry(
              context,
              icon: Image.asset(lingtingIconAsset, fit: BoxFit.contain),
              label: i18n.t('lingting.title'),
              // 桌面宽窗：灵听开在**系统级独立窗口**里（用户 2026-10-04：
              // 「像微信 PC 那样、系统级别的两个窗口」）；手机 / 窄窗照旧整页推。
              onTap: () {
                if (!desktopWideLayout(context, ref)) {
                  context.push(AppRoutes.lingtingHome);
                  return;
                }
                unawaited(
                  ref
                      .read(desktopWindowServiceProvider)
                      .openLingting(title: i18n.t('lingting.title')),
                );
              },
            ),
          ),
          // 两栏之间留出和「顶部栏 → 第一栏」一样的那道缝（用户 2026-09-30：
          // 「这一栏一栏之间稍微隔开一点点距离，就像第一栏和顶部栏一样」）。
          // 上一版是一条缩进细线：留着线又加缝会像「两块之间还连着一条线」。
          SizedBox(height: context.rpx(_gapRpx)),
          _card(
            context,
            child: _entry(
              context,
              icon: _newsIcon(context),
              label: i18n.t('news.title'),
              // 桌面宽窗：媒体号也开在**系统级独立窗口**里（2026-10-04 用户：
              // 「为啥我这看到的媒体号还是这样的不是独立窗口？」）。窗里那张
              // 列表点进去的文章在这颗窗口里往下推（子引擎里桌面功能是关的，
              // 见 `child_window_app.dart`）；手机 / 窄窗照旧整页推。
              onTap: () {
                if (!desktopWideLayout(context, ref)) {
                  context.push(AppRoutes.newsList);
                  return;
                }
                unawaited(
                  ref
                      .read(desktopWindowServiceProvider)
                      .openNews(title: i18n.t('news.title')),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 栏与栏之间（以及首个栏与顶部栏之间）的那道缝：
  /// 与页面上下留白**同一个值**，两处才会看着一样宽。
  static const double _gapRpx = 20;

  /// 一栏一块白底（微信那种通栏方块，不切圆角）。
  ///
  /// 每栏各占一块、块与块之间留缝 —— 而不是「一整块 + 分隔线」：
  /// 用户要的就是这两栏分开看。
  static Widget _card(BuildContext context, {required Widget child}) =>
      Container(color: AppColors.white, width: double.infinity, child: child);

  /// 媒体号那一栏的图标：一颗 Material 图标 + 圆角底色。
  ///
  /// 为什么不做成图片资源：这一栏没有第三方的 logo 可借（内容是各家源拼的，
  /// 放谁家的标都不对），自己画一张又要加一个二进制文件进仓库。
  /// 圆角底色 + 线性图标在两种语言下都不用换。
  static Widget _newsIcon(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.greenLight,
      borderRadius: BorderRadius.circular(context.rpx(16)),
    ),
    alignment: Alignment.center,
    child: Icon(
      Icons.article_outlined,
      size: context.rpx(40),
      color: AppColors.iconGreen,
    ),
  );

  /// 一栏：左边图标 + 名字 + 右箭头（老端那个 `cu-list menu` 的一行）
  Widget _entry(
    BuildContext context, {
    required Widget icon,
    required String label,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: context.rpx(110),
      child: Row(
        children: <Widget>[
          SizedBox(width: context.rpx(30)),
          SizedBox(
            width: context.rpx(60),
            height: context.rpx(60),
            child: icon,
          ),
          SizedBox(width: context.rpx(20)),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(30),
                color: AppColors.text333,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: context.rpx(34),
            color: AppColors.text999,
          ),
          SizedBox(width: context.rpx(20)),
        ],
      ),
    ),
  );
}
