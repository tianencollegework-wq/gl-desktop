import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../domain/mine/profile_form.dart';
import 'widgets/mine_list.dart';

/// 功能介绍，对应「关于」页里那一栏（微信 `关于微信 → 功能介绍`）。
///
/// 正文是 `aboutFeatureKeys`（`feature.item1` …）：2026-10-10 按**本软件实际有的功能**
/// 重写过一遍 —— 老端那七条是上游自建 IM 的卖点（「纯WEB技术打造」「全部采用自建」
/// 「可快速建立企业内部通讯系统」），我们加的功能（群组多人通话与屏幕共享、扫码登录、
/// 独立窗口与托盘、灵听/媒体号、多账号、多语言…）和技术路线（Flutter 原生客户端）
/// 都对不上，用户要求一起改掉。口径与安装包里的许可协议一致。
///
/// 翻文案走语言包（与「帮助中心」同一套规矩，S12.9）：手机端与电脑端是同一页，
/// 切到日语/西语时这里跟着变，不再固定中文。
///
/// **条目按端过滤**（2026-10-10 用户要的）：电脑端专属的那条（扫码登录 / 独立窗口 /
/// 托盘 / 安装卸载）在手机上不显示，手机端专属的那条（后台保活）在电脑上也不显示
/// —— 判据读 [desktopFeaturesProvider]（`dart:io` 的 `Platform.isX` 那一套，
/// 测试里默认关，用例可以 override）。
///
/// 观感沿用「关于」页那一块列表的规矩：白底、左右各缩 44rpx、细线通块宽。
/// 每条是一句完整的话（不是「标题 + 说明」那种两条），所以行高交给内容自己撑。
class FeaturePage extends ConsumerWidget {
  const FeaturePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    // 这一帧该按哪一端排：桌面行为总开关（窗口 / 平台）已经在里面了
    final desktop = ref.watch(desktopFeaturesProvider);
    final keys = aboutFeatureKeysFor(desktop: desktop);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('user.featureIntro'))),
      body: ListView(
        padding: EdgeInsets.only(bottom: context.rpx(60)),
        children: <Widget>[
          MineList(
            paddingRpx: 44,
            dividerIndentRpx: 0,
            children: <Widget>[
              for (final key in keys) _item(context, i18n.t(key)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, String text) => Container(
    color: AppColors.white,
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(AppDimens.listPadRpx),
      vertical: context.rpx(30),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: context.rpx(28),
        height: 1.5,
        color: AppColors.text000,
      ),
    ),
  );
}
