import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/config/app_info.dart';
import '../../../core/i18n/app_i18n.dart';
import '../../../core/net/geo_ip.dart';
import '../../../core/platform/desktop_shell.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/ui/desktop_overlay.dart';
import '../../../core/ui/wechat_dialog.dart';
import '../password_login_policy.dart';
import '../qr_login_session.dart';
import 'auth_widgets.dart';

/// 「其他登录方式」展开的小菜单里选了哪一项（菜单把方式名交回来）
const String kPasswordLoginWay = 'password';

/// 小菜单那一行（用例靠它量「是不是一行小卡片」）
const ValueKey<String> kLoginWaysMenuKey = ValueKey<String>('loginWaysMenu');

/// 桌面（宽窗）登录页：**左边品牌、右边一张卡片**，卡片默认是「扫码登录」。
///
/// 为什么要有它：手机上那一版是「品牌在上、卡片在下、整页居中」的竖排 ——
/// 在 1200×800 的窗口里两侧全是空白，一眼就是「手机页面放在了电脑窗口里」
/// （用户 2026-10-04：「全部要改成适配电脑 UI 的，不要保留任何手机样式」）。
/// 桌面上换成电脑软件通行的两栏：左侧一块品牌/装饰区（顺便把扫码这件事说清楚），
/// 右侧是真正要操作的东西 —— **默认二维码**（微信 PC 就是扫码优先），
/// 底下一条「其他登录方式」：点开是一张**贴着它下沿展开的小菜单**（密码登陆），
/// 而密码登陆**只对美国出口 IP 开放**（2026-10-08 用户定，见
/// `password_login_policy.dart`），别的地方弹一句「您当前的位置不支持密码登陆」。
///
/// 里面那些零件（输入框、按钮、记住我、演示提示）**直接用手机那一套**
/// （[AuthTextField] / [AuthButton] / [AuthCard]…）：它们都是 `rpx` 的，
/// 而这里把子树看到的宽度钉在 500（与中栏面板同一档），于是字号行高一模一样，
/// 换的只是**摆法**。
class DesktopLoginView extends ConsumerStatefulWidget {
  const DesktopLoginView({
    super.key,
    required this.siteName,
    required this.subtitle,
    required this.form,
    this.extra,
    this.onBack,
  });

  final String siteName;

  /// 品牌区那行小字（登录页是「欢迎回来…」）
  final String subtitle;

  /// 账号密码那一半（调用方用手机那套零件拼好了给进来）
  final Widget form;

  /// 表单下面那颗「注册」（注册入口关掉的站点是 null）
  final Widget? extra;

  /// 给了就在左上角画一颗返回（「添加账号」那一份用）
  final VoidCallback? onBack;

  /// 里面那些 `rpx` 零件按哪一档排版（与中栏面板同一档）
  static const double baseWidth = 500;

  @override
  ConsumerState<DesktopLoginView> createState() => _DesktopLoginViewState();
}

class _DesktopLoginViewState extends ConsumerState<DesktopLoginView> {
  /// 现在摆的是二维码（true，默认）还是账号密码表单
  bool _qr = true;

  /// 正在查出口 IP 归属地（那期间「其他登录方式」那颗不能点，显示转圈）
  bool _checkingRegion = false;

  /// 「其他登录方式」那颗链接：展开小菜单时的**锚**（菜单贴它下沿长出来）
  final GlobalKey _loginWaysKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);

    // 挂上「桌面框架」那一枚标记：登录页**自己没有框架**，[DesktopShell] 于是
    // 会把内容夹回 500 居中（两侧留灰）—— 两栏版式就不存在了。挂上它之后这一页
    // 吃满整窗（与主框架同一套账，见 `desktop_shell.dart` 里的说明）。
    return DesktopFrameScope(builder: (context) => _scaffold(context, i18n));
  }

  Widget _scaffold(BuildContext context, AppI18n i18n) {
    return Scaffold(
      backgroundColor: AppColors.white,
      body: MediaQuery(
        // 里面的零件全是 `rpx` 的（750 = 屏宽那一套）。窗口 1200 宽时不钉住，
        // 输入框的行高会按 1200 算成 1.6 倍 —— 就是那面「放大镜」。
        data: MediaQuery.of(context).copyWith(
          size: Size(
            DesktopLoginView.baseWidth,
            MediaQuery.sizeOf(context).height,
          ),
        ),
        child: Stack(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: _brand(i18n)),
                Expanded(
                  child: ColoredBox(
                    color: AppColors.page,
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: SizedBox(
                          width: 420,
                          child: _qr ? _qrPanel(i18n) : _formPanel(i18n),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Positioned(top: 20, right: 28, child: const AuthLanguageChip()),
            if (widget.onBack != null)
              Positioned(
                top: 20,
                left: 20,
                child: TextButton.icon(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: Text(i18n.t('common.back')),
                  style: TextButton.styleFrom(foregroundColor: AppColors.white),
                ),
              ),
            Positioned(
              right: 28,
              bottom: 16,
              child: AuthFooter(siteName: widget.siteName),
            ),
          ],
        ),
      ),
    );
  }

  /// 左半边：品牌绿渐变 + logo + 站名 + 一行说明
  Widget _brand(AppI18n i18n) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[AppColors.wechatGreen, AppColors.iconGreen],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 56),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.asset(AppInfo.logoAsset, width: 84, height: 84),
          ),
          const SizedBox(height: 28),
          Text(
            widget.siteName,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w600,
              color: AppColors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.subtitle,
            style: const TextStyle(fontSize: 15, color: Color(0xCCFFFFFF)),
          ),
          const SizedBox(height: 36),
          Row(
            children: <Widget>[
              const Icon(
                Icons.qr_code_2_rounded,
                size: 22,
                color: Color(0xCCFFFFFF),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  i18n.t('desktop.scanLoginHint'),
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xCCFFFFFF),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  /// 右半边其一：二维码（桌面上的默认形态）
  Widget _qrPanel(AppI18n i18n) {
    final session = ref.watch(qrLoginSessionProvider);
    // 只在真的要显示二维码时才去连（切回账号密码登录后 autoDispose 会把连接关掉）
    WidgetsBinding.instance.addPostFrameCallback((_) => session.start());

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          i18n.t('desktop.scanLogin'),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: AppColors.text000,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: 232,
          height: 232,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.fieldBorder),
          ),
          child: ValueListenableBuilder<QrLoginState>(
            valueListenable: session.state,
            builder: (context, state, _) => _qrContent(i18n, session, state),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          i18n.t('desktop.scanLoginHint'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppColors.text666),
        ),
        const SizedBox(height: 22),
        // 「其他登录方式」：密码那一套收进这里（2026-10-08 用户要的层次）
        if (_checkingRegion)
          // 查归属地要联网（几百毫秒到几秒）：先把链接换成转圈，
          // 免得人以为点了没反应又连点
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: context.rpx(28),
                height: context.rpx(28),
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: context.rpx(16)),
              Text(
                i18n.t('desktop.otherLoginWays'),
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text999,
                ),
              ),
            ],
          )
        else
          AuthTextLink(
            key: _loginWaysKey,
            label: i18n.t('desktop.otherLoginWays'),
            onPressed: () => _showLoginWays(i18n),
          ),
      ],
    );
  }

  /// 「其他登录方式」：**在链接下沿弹出小菜单**列出还开放着的登录方式，
  /// 选了再往下走。现在只有「密码登陆」一种，而且**要过地域这一关**（见
  /// `password_login_policy.dart`）：美国放行进表单，别处弹一句不支持。
  ///
  /// 为什么是这种形态：2026-10-09 第一版是一张居中的模态框（一个标题 + 一行 +
  /// 「取消」），用户当场退回「太奇怪太大了吧」—— 电脑上「点一下展开几个选项」
  /// 就是**贴着触发点的小菜单**（微信 PC 的右键菜单、`popupMenuTheme` 都是这一档，
  /// 见 `app_context_menu.dart`），盖住小半屏、还要多点一次「取消」的是手指的做法。
  ///
  /// **弹层不在页面那棵「钉住 500 宽」的子树里**（连 State 的 `context` 也在它
  /// 之上）：页面里 `rpx` 按 500 算，弹层却按整窗宽（1200 就是 2.4 倍长）——
  /// 第一版那个「放大镜弹窗」正是这么来的，所以菜单内容走 [DesktopOverlayScale]
  /// 把尺度钉回去（[WeChatDialogBox] 内部同一套账），尺寸也只写那一档的值。
  Future<void> _showLoginWays(AppI18n i18n) async {
    if (_checkingRegion) return;
    final picked = await showMenu<String>(
      context: context,
      // 贴链接下沿展开（`showMenu` 的定位语义见 desktop_overlay.dart）
      position: appMenuPosition(context, anchorKey: _loginWaysKey, gap: 2),
      // 白底小卡片：样式跟着主题的 `popupMenuTheme`，与全站右键菜单同一个口径
      constraints: const BoxConstraints(minWidth: 168, maxWidth: 280),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          key: kLoginWaysMenuKey,
          value: kPasswordLoginWay,
          // 行高不传：默认那 48 就是电脑上菜单的尺度。**这里不能写
          // `context.rpx(...)`** —— State 的 context 在页面那层「钉住 500」的
          // MediaQuery **之上**，`rpx` 会按整窗算（试过：rpx(78) → 124.8，
          // 用例当场抓住）。
          child: DesktopOverlayScale(
            child: Builder(
              builder: (pinned) => Text(
                i18n.t('user.passlogin'),
                style: TextStyle(
                  fontSize: pinned.rpx(28),
                  color: AppColors.text333,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    if (!mounted || picked != kPasswordLoginWay) return;
    await _openPasswordLogin(i18n);
  }

  /// 选了密码登陆之后：先问出口 IP 在哪个国家，再决定给不给那张表单
  Future<void> _openPasswordLogin(AppI18n i18n) async {
    setState(() => _checkingRegion = true);
    String? country;
    try {
      country = await ref.read(geoIpProvider).countryCode();
    } on Object catch (error) {
      // 查不到也按「不在美国」处理（见 password_login_policy.dart）
      debugPrint('[登录] 查出口 IP 归属地失败：$error');
    }
    if (!mounted) return;
    setState(() => _checkingRegion = false);
    if (passwordLoginAllowedIn(country)) {
      setState(() => _qr = false);
      return;
    }
    debugPrint('[登录] 当前位置（${country ?? '未知'}）不支持密码登陆');
    await showWeChatAlert(
      context,
      message: i18n.t('user.passloginUnsupported'),
    );
  }

  Widget _qrContent(AppI18n i18n, QrLoginSession session, QrLoginState state) {
    switch (state.phase) {
      case QrLoginPhase.connecting:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 14),
            Text(
              i18n.t('desktop.qrConnecting'),
              style: const TextStyle(fontSize: 13, color: AppColors.text999),
            ),
          ],
        );
      case QrLoginPhase.waiting:
        if (state.qrUrl.isEmpty) return const SizedBox.shrink();
        return QrImageView(
          data: state.qrUrl,
          size: 200,
          backgroundColor: AppColors.white,
          // 二维码本身生成失败（数据太长之类）时别把整页炸掉
          errorStateBuilder: (context, error) => const Icon(
            Icons.qr_code_2_rounded,
            size: 64,
            color: AppColors.text999,
          ),
        );
      case QrLoginPhase.confirmed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.check_circle_rounded,
              size: 56,
              color: AppColors.wechatGreen,
            ),
            const SizedBox(height: 12),
            Text(
              i18n.t('user.qrLoginOk'),
              style: const TextStyle(fontSize: 14, color: AppColors.text666),
            ),
          ],
        );
      case QrLoginPhase.failed:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.wifi_off_rounded,
              size: 44,
              color: AppColors.text999,
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                state.message.isEmpty
                    ? i18n.t('desktop.qrFailed')
                    : state.message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppColors.text999),
              ),
            ),
            const SizedBox(height: 8),
            AuthTextLink(
              label: i18n.t('desktop.qrRefresh'),
              onPressed: session.restart,
            ),
          ],
        );
    }
  }

  /// 右半边其二：账号密码（与手机上同一套零件，只是摆进这张卡片里）
  Widget _formPanel(AppI18n i18n) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      widget.form,
      if (widget.extra != null) ...<Widget>[
        const SizedBox(height: 16),
        widget.extra!,
      ],
      const SizedBox(height: 14),
      AuthTextLink(
        label: i18n.t('desktop.scanLogin'),
        onPressed: () => setState(() => _qr = true),
      ),
    ],
  );
}
