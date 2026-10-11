import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/app_version.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../domain/mine/profile_form.dart';
import '../../domain/session/session_service.dart';
import 'widgets/mine_list.dart';

/// 设置，对应老端 `pages/mine/setting.vue`（S5.5）。
///
/// 老端把「通用设置」和「我的」页上一堆入口**平铺**在几个圆角卡片里；
/// 这一版按**微信那套分组**重排（微信 `设置`）：
///
/// | 分组 | 行 |
/// |---|---|
/// | 账号 | 个人资料 / 账号安全 |
/// | 通用 | 通知 / 界面与显示 |
/// | 功能 | 音视频通话 |
/// | 帮助与关于 | 帮助中心 / 关于恩信（右侧带版本号） |
/// | （独立一块） | 切换账号（S10.1） / 退出登录 |
///
/// 最后一块那两行**文字居中、不带箭头**，样式故意做得一模一样（用户 2026-09-29
/// 的要求：「在退出登录上面再搞一栏 UI 跟退出登录一样的叫切换账号」）。
///
/// 微信 `设置` 顶上还有一个搜索框，我们**没做** —— 那要么是真搜索、要么是假框子，
/// 假框子比没有更糟。
///
/// **桌面（宽窗）上换成两栏**：左列是上面那几个分组的**分类**、右列是那一类的行
/// （2026-10-04 用户：「设置页还是手机UI啊，不太符合电脑操作习惯，虽然比例已经
/// 对了」）。手机那份仍是「一列竖排分组」——手指上下划很顺，鼠标上就变成一条很长
/// 的滚动页：改一项要滚过四块。形态切换见 [_SettingPageState.build]。
class SettingPage extends ConsumerStatefulWidget {
  const SettingPage({super.key});

  @override
  ConsumerState<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends ConsumerState<SettingPage> {
  /// 桌面两栏里左列选中的那一类（下标与 [_categoryLabels] 同序）。
  /// 默认第一类「账号」，与手机上从上往下看到的第一块一致。
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    // 右栏（二级页那条路）与整窗都算「宽窗」：那一档的排版基准是面板宽 500，
    // 左列 + 右列分下来正好装得下（见 [_desktopBody] 里那个 0.32）
    if (desktopWideLayout(context, ref)) return _desktopBody(context, i18n);
    return _phoneBody(context, i18n);
  }

  /// 手机 / 窄窗：一列竖排分组（S5.5 那套，一个像素都不动）
  Widget _phoneBody(BuildContext context, AppI18n i18n) {
    final version = ref.watch(appVersionInfoProvider).value?.name ?? appVersion;

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('user.setting'))),
      body: ListView(
        padding: EdgeInsets.only(bottom: context.rpx(60)),
        children: <Widget>[
          MineList(
            header: i18n.t('user.account'),
            gapBefore: false,
            children: <Widget>[
              MineListItem(
                // 微信这一行叫「个人资料」，点进去那页才叫「个人信息」
                label: i18n.t('user.personalData'),
                onTap: () => context.push(AppRoutes.mineProfile),
              ),
              MineListItem(
                label: i18n.t('user.secure'),
                onTap: () => context.push(AppRoutes.mineSecure),
              ),
            ],
          ),
          MineList(
            header: i18n.t('user.general'),
            children: <Widget>[
              MineListItem(
                label: i18n.t('user.notification'),
                onTap: () => context.push(AppRoutes.settingNotification),
              ),
              MineListItem(
                label: i18n.t('user.appearance'),
                onTap: () => context.push(AppRoutes.settingDisplay),
              ),
            ],
          ),
          MineList(
            header: i18n.t('user.features'),
            children: <Widget>[
              MineListItem(
                label: i18n.t('common.webrtc'),
                onTap: () => context.push(AppRoutes.settingCall),
              ),
            ],
          ),
          MineList(
            header: i18n.t('user.helpAndAbout'),
            children: <Widget>[
              MineListItem(
                label: i18n.t('user.help'),
                onTap: () => context.push(AppRoutes.mineDoc),
              ),
              MineListItem(
                label: i18n.t('common.aboutUs'),
                trailing: i18n.t('common.version', <String, String>{
                  'version': version,
                }),
                onTap: () => context.push(AppRoutes.mineAbout),
              ),
            ],
          ),
          // 切换账号 / 退出登录：单独一块、文字居中、不带箭头。
          // 「切换账号」在上（用户 2026-09-29 定的位置），样式与退出登录一致
          MineList(
            children: <Widget>[
              _centeredRow(
                context,
                i18n.t('user.switchAccount'),
                () => context.push(AppRoutes.accounts),
              ),
              _logoutRow(context, i18n),
            ],
          ),
        ],
      ),
    );
  }

  /// 桌面：**左分类 + 右内容**。
  ///
  /// 左列就是手机那几块分组标题（账号 / 通用 / 功能 / 帮助与关于），点一下右列换成
  /// 那一类；手机版最底下那「切换账号 / 退出登录」两块并进「账号」这一类（它们本来
  /// 就是账号的事，桌面上不至于为它们单开一类）。
  ///
  /// 头一条是这一栏自己的标题（「设置」+ 返回）：桌面上的二级页都该有这么一条，
  /// 手机那条 `AppBar` 是「居中 + 状态栏留白」的手指语言，摆进右栏就不像栏了。
  Widget _desktopBody(BuildContext context, AppI18n i18n) {
    final labels = _categoryLabels(i18n);

    return Scaffold(
      backgroundColor: AppColors.white,
      body: Column(
        children: <Widget>[
          _paneHeader(context, i18n),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                children: <Widget>[
                  // 左列宽度跟着这块分到的宽度走：不到 900 的窗口里右栏只有
                  // 三百多，固定 176 会把内容挤成一条；反过来宽窗里 176 太窄也
                  // 不像分类栏。0.32 + 上下限在两种宽度下都合适
                  SizedBox(
                    width: (constraints.maxWidth * 0.32).clamp(96.0, 176.0),
                    child: Container(
                      color: AppColors.navBar,
                      child: Column(
                        children: <Widget>[
                          for (var i = 0; i < labels.length; i++)
                            _categoryRow(context, labels[i], i),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(
                    width: 0.5,
                    thickness: 0.5,
                    color: AppColors.navDivider,
                  ),
                  Expanded(
                    child: ListView(
                      key: const ValueKey<String>('settingPaneContent'),
                      padding: EdgeInsets.only(bottom: context.rpx(60)),
                      children: _sectionChildren(context, i18n),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 左列那几个分类（与手机版的分组标题同一批 key）
  List<String> _categoryLabels(AppI18n i18n) => <String>[
    i18n.t('user.account'),
    i18n.t('user.general'),
    i18n.t('user.features'),
    i18n.t('user.helpAndAbout'),
  ];

  /// 右列的内容：左列选中哪一类就给哪一块。行本身与手机版共用 [MineListItem]，
  /// 所以行高、字号、箭头、细线全站仍是同一套。
  List<Widget> _sectionChildren(BuildContext context, AppI18n i18n) {
    switch (_section) {
      case 0:
        return <Widget>[
          MineList(
            gapBefore: false,
            children: <Widget>[
              // 微信这一行叫「个人资料」，点进去那页才叫「个人信息」
              MineListItem(
                label: i18n.t('user.personalData'),
                onTap: () => context.push(AppRoutes.mineProfile),
              ),
              MineListItem(
                label: i18n.t('user.secure'),
                onTap: () => context.push(AppRoutes.mineSecure),
              ),
            ],
          ),
          // 手机版把这两项摆在页面最底下那一块（单独一块、文字居中）；
          // 桌面上它们属于「账号」这一类，就接在这一类的下半块里
          MineList(
            children: <Widget>[
              MineListItem(
                label: i18n.t('user.switchAccount'),
                onTap: () => context.push(AppRoutes.accounts),
              ),
              MineListItem(
                label: i18n.t('user.exitLogin'),
                showChevron: false,
                onTap: () => _confirmLogout(context, i18n),
              ),
            ],
          ),
        ];
      case 1:
        return <Widget>[
          MineList(
            gapBefore: false,
            children: <Widget>[
              MineListItem(
                label: i18n.t('user.notification'),
                onTap: () => context.push(AppRoutes.settingNotification),
              ),
              MineListItem(
                label: i18n.t('user.appearance'),
                onTap: () => context.push(AppRoutes.settingDisplay),
              ),
            ],
          ),
        ];
      case 2:
        return <Widget>[
          MineList(
            gapBefore: false,
            children: <Widget>[
              MineListItem(
                label: i18n.t('common.webrtc'),
                onTap: () => context.push(AppRoutes.settingCall),
              ),
            ],
          ),
        ];
      default:
        final version =
            ref.watch(appVersionInfoProvider).value?.name ?? appVersion;
        return <Widget>[
          MineList(
            gapBefore: false,
            children: <Widget>[
              MineListItem(
                label: i18n.t('user.help'),
                onTap: () => context.push(AppRoutes.mineDoc),
              ),
              MineListItem(
                label: i18n.t('common.aboutUs'),
                trailing: i18n.t('common.version', <String, String>{
                  'version': version,
                }),
                onTap: () => context.push(AppRoutes.mineAbout),
              ),
            ],
          ),
        ];
    }
  }

  /// 这一栏顶上那条：返回 + 「设置」。灰底 + 下面一条细线，与聊天页那条顶栏同一档
  Widget _paneHeader(BuildContext context, AppI18n i18n) => Container(
    key: const ValueKey<String>('settingPaneHeader'),
    height: context.rpx(84),
    padding: EdgeInsets.only(left: context.rpx(6), right: context.rpx(26)),
    decoration: const BoxDecoration(
      color: AppColors.navBar,
      border: Border(
        bottom: BorderSide(color: AppColors.navDivider, width: 0.5),
      ),
    ),
    child: Row(
      children: <Widget>[
        IconButton(
          tooltip: i18n.t('common.back'),
          icon: Icon(
            Icons.arrow_back_ios_new,
            size: context.rpx(32),
            color: AppColors.text333,
          ),
          // 桌面右栏里没有「返回上一页」那套手势，但设置是叠在主界面上的
          // 一条路由：给一颗能退回主界面的钮，栈空时直接回主界面
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(AppRoutes.home);
            }
          },
        ),
        Text(
          i18n.t('user.setting'),
          style: TextStyle(
            fontSize: context.rpx(32),
            fontWeight: FontWeight.w600,
            color: AppColors.text333,
          ),
        ),
      ],
    ),
  );

  /// 左列的一类。选中那行：白底 + 左边一条品牌绿的细条（「现在看的是这一类」）
  Widget _categoryRow(BuildContext context, String label, int index) {
    final selected = index == _section;
    return InkWell(
      key: ValueKey<String>('settingCategory$index'),
      onTap: () {
        if (selected) return;
        setState(() => _section = index);
      },
      child: Container(
        height: context.rpx(84),
        padding: EdgeInsets.symmetric(horizontal: context.rpx(24)),
        decoration: BoxDecoration(
          color: selected ? AppColors.white : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? AppColors.wechatGreen : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.rpx(28),
            color: selected ? AppColors.text000 : AppColors.text333,
            fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 通栏白底、文字居中、没有箭头的一行（手机版「切换账号」「退出登录」共用）
  Widget _centeredRow(BuildContext context, String label, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        child: Container(
          height: context.rpx(AppDimens.listRowRpx),
          color: AppColors.white,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: context.rpx(32),
              color: AppColors.text000,
            ),
          ),
        ),
      );

  Widget _logoutRow(BuildContext context, AppI18n i18n) => _centeredRow(
    context,
    i18n.t('user.exitLogin'),
    () => _confirmLogout(context, i18n),
  );

  /// 退出登录的确认框：正文、两颗按钮都跟微信那个「退出登录」弹窗一样
  /// （正文是「退出后不会删除任何历史数据…」、右键是「退出」）。
  Future<void> _confirmLogout(BuildContext context, AppI18n i18n) async {
    final confirmed = await showWeChatConfirm(
      context,
      message: i18n.t('user.exitLoginTip'),
      confirmLabel: i18n.t('user.exit'),
    );
    if (!confirmed) return;
    await ref.read(sessionServiceProvider).logout();
    if (context.mounted) context.go(AppRoutes.home);
  }
}
