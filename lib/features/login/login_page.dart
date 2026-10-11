import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_info.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/store/credential_store.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/util/json_value.dart';
import '../../data/model/global_config.dart';
import '../../domain/session/session_service.dart';
import 'widgets/auth_widgets.dart';
import 'widgets/desktop_login.dart';

/// 登录页，对应老端 `pages/login/index.vue`。
///
/// **观感是 2026-09-29 改版那一套现代风**（用户：「太丑太丑了，美化一下，现代化
/// 一点」）：淡绿渐变底、白色圆角卡片表单、带图标的圆角填充输入框（聚焦时描边变
/// 绿）、通栏药丸登录按钮 + 下面一颗描边「注册」按钮、右上角语言药丸。
/// 这套观感两页共用，具体零件都在 `widgets/auth_widgets.dart` 里。
///
/// 版面的层级：品牌（logo + 站点名 + 一行说明）→ 卡片（账号 / 密码 · 记住我 +
/// 忘记密码 · 登录按钮）→ 注册按钮 → 演示提示。
///
/// 2026-09-25 那版曾经是「照抄微信登录页」的白底 + 下划线输入行，被用户否掉了，
/// 所以这里不再提「对齐微信」。
///
/// 还原了这些行为（都是老端页面上真实存在的东西）：
/// * 右上角语言选择器（`common/config.js` 的 `langList`：简体中文 / English）；
/// * 站点 logo 与站点名取自全局配置，配置未取到时用本地默认；
/// * 「忘记密码」切换后，密码框替换成验证码框 + 发送验证码按钮，
///   并且密码会**写死成 `123456`**（老端 watch 里就是这么干的，服务端按此校验）；
/// * 「记住我」把整份登录表单存到本地，下次自动回填；
/// * 演示模式（`demon_mode`）随机填一个 1380000000x 的演示账号；
/// * 底部版本号 `{站点名} for {版本}`。
///
/// 电脑端**不画「注册」**（2026-10-08 用户：「把电脑端的注册删掉，不允许电脑
/// 注册账号」）：开不开注册看服务端 `sysInfo.registerOpen`，但电脑端一律不画，
/// 路由那一层还有一道拦截（`core/router/desktop_register_guard.dart`）。
///
/// 刻意省略的一处：老端底部那个隐藏的 `safe-verify`（连点 15 次复制设备 id）
/// 是开发者调试用的，没有产品含义。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({
    super.key,
    this.addAccount = false,
    this.initialAccount = '',
  });

  /// 是不是「添加账号」那一份（从切换账号页进来的，S10.1）。
  ///
  /// 三处差别：标题下面那行小字改成「登录其他账号」、左上角有返回、
  /// 登录成功后直接回主界面（不用等路由守卫 —— 这一页不是 `/login`，守卫不会自己
  /// 把人送走）。「注册」入口也跟着指向 [AppRoutes.accountsAddRegister]。
  final bool addAccount;

  /// 预填的账号（从一个「已退出」的账号切过来的）
  final String initialAccount;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final TextEditingController _account = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();

  bool _rememberMe = false;
  bool _forget = false;
  bool _busy = false;
  bool _demoPrefilled = false;

  @override
  void initState() {
    super.initState();
    _restoreRememberedAccount();
    _prefillFromRoute();
    _maybePrefillDemoAccount(ref.read(sessionStoreProvider).config);
  }

  /// 切换账号页点一个「已退出」的账号进来时：账号预填，密码清掉
  /// （旧的密码是**记住我**存的上一个账号的，填在这儿只会误导）
  void _prefillFromRoute() {
    final account = widget.initialAccount.trim();
    if (account.isEmpty || account == _account.text) return;
    _account.text = account;
    _password.text = '';
    _code.text = '';
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  /// 老端 `mounted()`：把 `LoginAccount` 整份回填
  void _restoreRememberedAccount() {
    final saved = CredentialStore.instance.getJson(
      CredentialStore.keyLoginAccount,
    );
    if (saved == null) return;
    _account.text = asText(saved['account']);
    _password.text = asText(saved['password']);
    _code.text = asText(saved['code']);
    _rememberMe = asBool(saved['rememberMe']);
  }

  /// 老端 `mounted()`：演示模式下随机填 13800000002~13800000020 / 123456
  void _maybePrefillDemoAccount(GlobalConfig config) {
    if (!config.demonMode || _demoPrefilled) return;
    _demoPrefilled = true;
    if (_account.text.isNotEmpty) return;
    _account.text = '${13800000000 + Random().nextInt(19) + 2}';
    _password.text = '123456';
  }

  void _saveRememberedAccount() {
    final store = CredentialStore.instance;
    if (!_rememberMe) {
      store.setJson(CredentialStore.keyLoginAccount, null);
      return;
    }
    store.setJson(CredentialStore.keyLoginAccount, <String, dynamic>{
      'account': _account.text,
      'password': _password.text,
      'code': _code.text,
      'rememberMe': _rememberMe,
    });
  }

  void _toggleForget(bool value) {
    setState(() {
      _forget = value;
      // 老端 `watch.forget`：切到验证码登录时把密码置为 123456
      if (value) _password.text = '123456';
    });
  }

  Future<void> _sendCode() async {
    final t = ref.read(appI18nProvider).t;
    final account = _account.text.trim();
    if (account.isEmpty) {
      noticeBus.toast(t('user.inputAccount'));
      return;
    }
    try {
      // type 1 = 登录 / 忘记密码（老端 `sendCode()` 里就是 1）
      await ref
          .read(sessionServiceProvider)
          .sendCode(account: account, type: 1);
    } on ApiException catch (error) {
      debugPrint('[登录] 发送验证码失败：${error.message}');
    }
  }

  Future<void> _login() async {
    final t = ref.read(appI18nProvider).t;
    final account = _account.text.trim();
    if (account.isEmpty) {
      noticeBus.toast(t('user.inputAccount'));
      return;
    }
    if (_forget) {
      if (_code.text.trim().isEmpty) {
        noticeBus.toast(t('user.inputCaptcha'));
        return;
      }
    } else if (_password.text.isEmpty) {
      noticeBus.toast(t('user.inputPass'));
      return;
    }

    _saveRememberedAccount();
    setState(() => _busy = true);
    try {
      await ref
          .read(sessionServiceProvider)
          .login(
            account: account,
            // 老端忘记密码模式固定用 123456，验证码走 code 字段
            password: _forget ? '123456' : _password.text,
            code: _forget ? _code.text.trim() : '',
            rememberMe: _rememberMe,
          );
      // 普通登录成功后不需要手动跳转：会话状态一变，路由守卫就把人送回主界面
      // （见 `core/router/session_guard.dart` 第 3 条）。
      //
      // **添加账号那一份不一样**（S10.1）：登录成功就是「切到这个新账号」，得自己
      // 回主界面 —— 我们停在 `/mine/accounts/add`，它不是 `/login` 那条白名单路由，
      // 守卫不会动手。
      if (widget.addAccount && mounted) context.go(AppRoutes.home);
    } on ApiException catch (error) {
      debugPrint('[登录] 失败：${error.message}'); // 提示已由网络层统一弹出
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 返回：添加账号是从切换页推进来的，退回那一页；万一没得退（深层链接直接落到
  /// 这里），就回主界面，别把人困在登录表单里
  void _goBack() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go(AppRoutes.home);
  }

  @override
  Widget build(BuildContext context) {
    // 全局配置是异步到的（本地缓存 / 接口），演示模式要跟着它变
    ref.listen<GlobalConfig>(
      sessionStoreProvider.select((state) => state.config),
      (_, next) => _maybePrefillDemoAccount(next),
    );

    final i18n = ref.watch(appI18nProvider);
    final config = ref.watch(
      sessionStoreProvider.select((state) => state.config),
    );
    // 站点名走 [AppInfo.siteName]：服务端还是老端那几个默认名（IM / Raingad-IM…）
    // 时替它换成 Gracelink —— 否则登录页底下那行会写成「Raingad-IM for 1.0.0」
    // （用户 2026-09-27：「软件默认的『IM』、『raingad-im』等等全部改成 Gracelink」）。
    final siteName = AppInfo.siteName(config.sysInfo.name);

    final subtitle = i18n.t(
      widget.addAccount ? 'user.loginOtherAccount' : 'user.loginIntro',
    );
    final card = AuthCard(
      children: <Widget>[
        _buildForm(i18n),
        _buildOptions(i18n),
        SizedBox(height: context.rpx(36)),
        AuthButton(label: i18n.t('user.login'), busy: _busy, onPressed: _login),
      ],
    );
    // 电脑端**不许注册**（用户 2026-10-08：「把电脑端的注册删掉，不允许电脑
    // 注册账号」）：这台机器是电脑端时这颗按钮整个不画 —— 手机上照旧。
    // 为什么看 [desktopFeaturesProvider] 而不是窗口宽度：窗口拉窄了也不该冒出注册
    // （那是同一个电脑端），而测试里这个开关默认是关的（见 desktop_shell.dart）。
    final desktopClient = ref.watch(desktopFeaturesProvider);
    final register = (!desktopClient && config.sysInfo.registerOpen)
        ? Padding(
            padding: EdgeInsets.symmetric(horizontal: context.rpx(40)),
            child: AuthSecondaryButton(
              label: i18n.t('user.register'),
              // 添加账号时走那条「已登录也能进」的注册页（`/login/register`
              // 会被守卫弹回主界面，见 `AppRoutes.accountsAdd` 的注释）
              onPressed: () => widget.addAccount
                  ? context.push(AppRoutes.accountsAddRegister)
                  : context.go(AppRoutes.register),
            ),
          )
        : null;

    // 桌面（宽窗）：两栏 + **扫码优先**（S12.17）—— 手机上那套「品牌在上、
    // 卡片在下」的竖排在 1200 宽的窗口里两侧全是空白，一眼就是手机页面。
    if (desktopWideLayout(context, ref)) {
      return DesktopLoginView(
        siteName: siteName,
        subtitle: subtitle,
        form: card,
        extra: register,
        onBack: widget.addAccount ? _goBack : null,
      );
    }

    // 手机（窄窗）那一版：版面的层级是品牌 → 卡片（输入 + 记住我/忘记密码 +
    // 登录按钮）→ 注册按钮 → 演示提示。键盘弹出 / 小屏 / 横屏的滚动与
    // 「版本号钉底」都由 [AuthScaffold] 统一处理（见里面的注释）。
    return AuthScaffold(
      siteName: siteName,
      onBack: widget.addAccount ? _goBack : null,
      children: <Widget>[
        SizedBox(height: context.rpx(34)),
        AuthBrand(siteName: siteName, subtitle: subtitle),
        SizedBox(height: context.rpx(46)),
        card,
        if (register != null) ...<Widget>[
          SizedBox(height: context.rpx(30)),
          register,
        ],
        if (config.demonMode && !widget.addAccount) _buildDemoHint(i18n),
      ],
    );
  }

  /// 输入区：带图标的圆角填充输入框（标签在框上方）。
  ///
  /// 验证码模式下密码框整行换成验证码框，发送验证码那颗按钮放进框内右侧。
  Widget _buildForm(AppI18n i18n) {
    return Column(
      children: <Widget>[
        AuthFormRow(
          title: i18n.t('user.account'),
          child: AuthTextField(
            controller: _account,
            hintText: i18n.t('user.hintAccount'),
            icon: Icons.person_outline_rounded,
            maxLength: 32,
            textInputAction: TextInputAction.next,
          ),
        ),
        if (!_forget)
          AuthFormRow(
            title: i18n.t('user.password'),
            child: AuthTextField(
              controller: _password,
              hintText: i18n.t('user.inputPass'),
              icon: Icons.lock_outline_rounded,
              obscure: true,
              maxLength: 32,
              textInputAction: TextInputAction.done,
            ),
          )
        else
          AuthFormRow(
            title: i18n.t('user.captcha'),
            child: AuthTextField(
              controller: _code,
              hintText: i18n.t('user.inputCaptcha'),
              icon: Icons.shield_outlined,
              keyboardType: TextInputType.number,
              maxLength: 6,
              trailing: AuthCodeButton(
                label: i18n.t('user.sendCode'),
                onPressed: _sendCode,
              ),
            ),
          ),
      ],
    );
  }

  /// 记住我（左边低调一行）+ 忘记密码（右边绿色文字链接），夹在输入框和登录按钮
  /// 之间 —— 这是现在登录页的通行摆法：一眼看到的是「登录」。
  ///
  /// 用 `Wrap` 而不是 `Row`：同一句话各语言长度差得很远（中文「忘记密码」4 个字、
  /// 日语「パスワードをお忘れですか」12 个全角字、英语两个词），而版式是按
  /// `rpx` 缩放的字号 —— 320dp 那种窄屏上连英语都会把这一行顶爆（实测溢出 78px）。
  /// Wrap 放不下就整块换行（每一项自己一行，仍然读得全），宽屏还是左右分开。
  Widget _buildOptions(AppI18n i18n) {
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: context.rpx(16),
        children: <Widget>[
          // Wrap 给孩子的宽度是无界的，得自己拿整行宽度封顶（松约束：
          // 装得下就用自己的自然宽度、两个才能同一行左右分开）。
          // 单个标签比一整行还长时（西语「Iniciar sesión con contraseña」），
          // 它会在行内换行，而不是画到屏幕外面去。
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: AuthCheckBox(
              label: i18n.t('user.remenberMe'),
              checked: _rememberMe,
              onChanged: (value) => setState(() => _rememberMe = value),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: AuthTextLink(
              label: _forget
                  ? i18n.t('user.passlogin')
                  : i18n.t('user.forgetPass'),
              onPressed: () => _toggleForget(!_forget),
            ),
          ),
        ],
      ),
    );
  }

  /// 演示模式（`demon_mode`）那三行提示：淡绿底的圆角小面板（挂在注册按钮下面）
  Widget _buildDemoHint(AppI18n i18n) {
    return Padding(
      padding: EdgeInsets.only(
        top: context.rpx(34),
        left: context.rpx(40),
        right: context.rpx(40),
      ),
      child: Container(
        padding: EdgeInsets.all(context.rpx(26)),
        decoration: BoxDecoration(
          color: AppColors.wechatGreen.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(context.rpx(24)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.info_outline_rounded,
              size: context.rpx(32),
              color: AppColors.wechatGreen,
            ),
            SizedBox(width: context.rpx(16)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    i18n.t('user.demoHintTitle'),
                    style: TextStyle(
                      fontSize: context.rpx(26),
                      fontWeight: FontWeight.w600,
                      color: AppColors.text666,
                    ),
                  ),
                  SizedBox(height: context.rpx(8)),
                  Text(
                    i18n.t('user.demoHintAccount'),
                    style: TextStyle(
                      fontSize: context.rpx(24),
                      color: AppColors.text999,
                    ),
                  ),
                  Text(
                    i18n.t('user.demoHintPassword'),
                    style: TextStyle(
                      fontSize: context.rpx(24),
                      color: AppColors.text999,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
