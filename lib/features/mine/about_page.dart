import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_info.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/platform/app_uninstaller.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/link_opener.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../domain/mine/profile_form.dart';
import '../../domain/report/report_reasons.dart';
import '../common/report_sheet.dart';
import 'app_update_flow.dart';
import 'widgets/mine_list.dart';

/// 关于，对应老端 `pages/mine/about.vue`（S5.5），观感照微信「关于微信」那一页。
///
/// 骨架是**从那张微信截图逐像素量出来**的（1080×2316，3x → 1rpx = 1.44px）：
///
/// | 元素 | 微信实测 | 这里 |
/// |---|---|---|
/// | 顶栏 | **纯白、没有标题**（只有左上角返回箭头）、没有底下那条灰线 | 同 |
/// | logo | 173×173px（圆角 ≈16px）、水平居中 | `rpx(120)` + 圆角 `rpx(12)` |
/// | 顶栏底 → logo 顶 | 131px | `rpx(91)` |
/// | logo 底 → 名字顶 | 107px | `rpx(68)`（名字那行的行高自己再吃掉一点） |
/// | 名字 | 57px 粗体（「微信」两字实测宽 109px） | `rpx(40)` 粗体 |
/// | 版本号 | 44px（「Version 8.0.72」实测宽 289px） | `rpx(30)` |
/// | 版本底 → 首条细线 | 124px | `rpx(78)` |
/// | 列表块 | 左右各缩 64px（细线 64..1015），行高 152px | `paddingRpx: 44` + 共用行高 |
/// | 三栏 | 功能介绍 / 投诉 / 版本更新（**右侧不写版本号**） | 同 |
/// | 版权 | 居中、`#999999`，压在页面底部 | `text999`、`rpx(22)`、贴底 |
///
/// 站点 logo 与名字都从全局配置来（拿不到就用本地那套）。
///
/// 「版本更新」就是原来的「检查更新」（老端 `checkVersion`），
/// 「功能介绍」进二级页（老端那七条文案）。
///
/// 两处与从前不同（2026-10-11，S13）：
/// * **「投诉」不再是「只做表面功夫」** —— 现在是**真的提交**（平台级反馈，
///   不针对某个人，落到 `yu_report` 的 `scene=about` 那一类）；
/// * 多了**「联系我们」**一组：客服邮箱（点一下复制）与官网（点一下进应用内
///   浏览器）—— 上架审核要看的就是这两样，地址在 `AppInfo` 里改一处就行。
class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final sysInfo = ref.watch(
      sessionStoreProvider.select((state) => state.config.sysInfo),
    );
    // 名字走 [AppInfo.siteName]：服务端还报着老端那几个默认名（IM / Raingad-IM…）
    // 时换成 Gracelink；logo **固定用随包那张** —— 与启动页、登录页同一张
    // （用户 2026-09-27：「logo 也改成现在软件用的 logo」）。
    final siteName = AppInfo.siteName(sysInfo.name);

    return Scaffold(
      // 微信这一页是**整页白**（顶栏也是白的）
      backgroundColor: AppColors.white,
      appBar: AppBar(
        backgroundColor: AppColors.white,
        // 全站顶栏底下那条灰线，这一页没有（微信实测：顶栏下面直接就是白的）
        shape: const Border(),
        // 微信这一页**没有标题**，只有左上角那颗返回箭头
        title: const SizedBox.shrink(),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                SizedBox(height: context.rpx(91)),
                Center(child: _logo(context)),
                SizedBox(height: context.rpx(68)),
                Center(
                  child: Text(
                    siteName,
                    style: TextStyle(
                      fontSize: context.rpx(40),
                      fontWeight: FontWeight.w600,
                      color: AppColors.text000,
                    ),
                  ),
                ),
                SizedBox(height: context.rpx(8)),
                Center(
                  child: Text(
                    'Version $appVersion',
                    style: TextStyle(
                      fontSize: context.rpx(30),
                      color: AppColors.text000,
                    ),
                  ),
                ),
                SizedBox(height: context.rpx(78)),
                MineList(
                  paddingRpx: 44,
                  gapBefore: false,
                  dividerIndentRpx: 0,
                  children: <Widget>[
                    MineListItem(
                      label: i18n.t('user.featureIntro'),
                      onTap: () => context.push(AppRoutes.mineFeature),
                    ),
                    MineListItem(
                      label: i18n.t('chat.complaint'),
                      // 平台级反馈：没有具体对象，所以服务端那边收的是
                      // `scene=about` 的那一类（见 `ReportInput::normalize`）
                      onTap: () => showReportSheet(
                        context,
                        target: ReportTarget.platform(),
                        titleKey: 'chat.complaint',
                      ),
                    ),
                    MineListItem(
                      label: i18n.t('user.versionUpdate'),
                      // 老端「检查更新」：报本机版本，有新版本就提示 + 交给安装器
                      onTap: () => runAppUpdate(context, ref, isPrompt: true),
                    ),
                    // 「卸载恩信」只给安装版看（安装目录里有卸载程序才有这一栏：
                    // Inno 版是 `unins000.exe`，老自研安装器那份是 `uninstall.exe`）：
                    // 用户 2026-10-08：「在电脑端版本更新下面再加一栏卸载恩信，
                    // 点击一键卸载」—— 不想为了卸载去翻安装目录
                    if (ref.watch(appUninstallerProvider).isAvailable)
                      MineListItem(
                        label: i18n.t('user.uninstallApp'),
                        onTap: () => _uninstall(context, ref),
                      ),
                  ],
                ),
                // 「联系我们」：客服邮箱 + 官网（S13.3，上架审核要看的就是这两样）。
                // 地址在 `AppInfo.supportEmail` / `AppInfo.siteUrl`，改一处即可。
                MineList(
                  paddingRpx: 44,
                  dividerIndentRpx: 0,
                  header: i18n.t('user.contactUs'),
                  children: <Widget>[
                    MineListItem(
                      label: i18n.t('user.contactEmail'),
                      trailing: AppInfo.supportEmail,
                      onTap: () => _copyEmail(context, i18n),
                    ),
                    MineListItem(
                      label: i18n.t('user.contactWebsite'),
                      trailing: AppInfo.siteHost,
                      onTap: () => openChatLink(context, AppInfo.siteUrl),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _footer(context, i18n),
        ],
      ),
    );
  }

  /// 客服邮箱那一行：**点一下复制**（手机上没有邮件客户端也照样能用）
  Future<void> _copyEmail(BuildContext context, AppI18n i18n) async {
    await Clipboard.setData(const ClipboardData(text: AppInfo.supportEmail));
    // 复用通用的「复制成功」（老端 `copyOk`），不为一句提示再开一个 key
    noticeBus.toast(i18n.t('common.copyOk'));
  }

  /// 一键卸载：先问一句，再把卸载程序拉起来（它会把 App 关掉、删掉安装目录）
  Future<void> _uninstall(BuildContext context, WidgetRef ref) async {
    final i18n = ref.read(appI18nProvider);
    final confirmed = await showWeChatConfirm(
      context,
      message: i18n.t('user.uninstallConfirm'),
      danger: true,
    );
    if (!confirmed || !context.mounted) return;

    // 成功的话进程马上就没了（不会走到下一行）；拉不起来才需要说话
    final started = await ref.read(appUninstallerProvider).uninstall();
    if (started || !context.mounted) return;
    await showWeChatAlert(context, message: i18n.t('user.uninstallFail'));
  }

  /// 应用自己的 logo（随包那张），微信那个圆角比例是 ≈9%
  Widget _logo(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(context.rpx(12)),
    child: Image.asset(
      AppInfo.logoAsset,
      width: context.rpx(120),
      height: context.rpx(120),
      fit: BoxFit.cover,
    ),
  );

  /// 页脚版权（微信压在页面底部，居中、`#999`）
  Widget _footer(BuildContext context, AppI18n i18n) => SafeArea(
    top: false,
    minimum: EdgeInsets.only(bottom: context.rpx(60)),
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
      child: Text(
        i18n.t('user.copyright'),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: context.rpx(22), color: AppColors.text999),
      ),
    ),
  );
}
