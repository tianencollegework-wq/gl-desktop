import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_info.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/model/global_config.dart';
import '../../domain/session/session_service.dart';
import 'widgets/auth_widgets.dart';

/// 注册页，对应老端 `pages/login/register.vue`。
///
/// **观感与登录页同一套现代风**（2026-09-29 一起改的；用户当时嫌这两页「太丑」）：
/// 淡绿渐变底、白色圆角卡片表单、带图标的圆角填充输入框、通栏药丸注册按钮，
/// 左上角一颗圆形返回、右上角语言药丸。零件全在 `widgets/auth_widgets.dart`。
///
/// 老端这一页是**蓝底导航栏** + 白底表单，与登录页不是一套；2026-09-25 那版先统一
/// 成微信风的白底，2026-09-29 又整体换成现在这套。
///
/// 还原点：
/// * 账号输入框**过滤中文**（老端 `handleInput` 里 replace 掉 `\u4e00-\u9fa5`）；
/// * 账号提示语随 `sysInfo.regauth` 变化：1 手机号 / 2 邮箱 / 3 手机号或邮箱；
/// * 验证码接口 `type = 2`（注册），与登录页的 1 区分；
/// * 密码校验 6–16 位、两次一致（老端那串条件写错了，见下方注释）。
class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key, this.addAccount = false});

  /// 是不是「添加账号 › 注册新账号」那一份（S10.1）。
  ///
  /// 从切换账号页进来的：注册成功后**不做**「2 秒后回 `/login`」（那会被守卫弹回
  /// 主界面），而是原地换成「登录其他账号」的表单、账号已预填 —— 刚注册的人接着
  /// 输个密码就能进去。返回也从那儿退回切换页。
  final bool addAccount;

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final TextEditingController _account = TextEditingController();
  final TextEditingController _realName = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _repass = TextEditingController();
  final TextEditingController _code = TextEditingController();

  bool _busy = false;

  @override
  void dispose() {
    _account.dispose();
    _realName.dispose();
    _password.dispose();
    _repass.dispose();
    _code.dispose();
    super.dispose();
  }

  /// 返回：从登录页点「注册」过来时退回去；万一这一页是**根**（深层链接直接落到
  /// 注册页），就回登录页，别把用户困在这儿
  void _goBack() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go(widget.addAccount ? AppRoutes.accountsAdd : AppRoutes.login);
  }

  /// 老端：`value.replace(/[\u4e00-\u9fa5]/g, '')`
  void _onAccountChanged(String value) {
    final filtered = value.replaceAll(RegExp(r'[\u4e00-\u9fa5]'), '');
    if (filtered == value) return;
    _account.value = TextEditingValue(
      text: filtered,
      selection: TextSelection.collapsed(offset: filtered.length),
    );
  }

  String _accountHint(AppI18n i18n, SysInfo sysInfo) {
    switch (sysInfo.regauth) {
      case 1:
        return i18n.t('user.inputPhone');
      case 2:
        return i18n.t('user.inputEmail');
      case 3:
        return i18n.t('user.inputEmailOrPhone');
      default:
        return i18n.t('user.inputAccountLimit');
    }
  }

  Future<void> _sendCode() async {
    final t = ref.read(appI18nProvider).t;
    final account = _account.text.trim();
    if (account.isEmpty) {
      noticeBus.toast(t('user.inputAccount'));
      return;
    }
    try {
      // type 2 = 注册
      await ref
          .read(sessionServiceProvider)
          .sendCode(account: account, type: 2);
    } on ApiException catch (error) {
      debugPrint('[注册] 发送验证码失败：${error.message}');
    }
  }

  Future<void> _register() async {
    final t = ref.read(appI18nProvider).t;
    final account = _account.text.trim();
    final realName = _realName.text.trim();

    if (account.isEmpty) {
      noticeBus.toast(t('user.inputAccount'));
      return;
    }
    if (realName.isEmpty) {
      noticeBus.toast(t('user.inputNickname'));
      return;
    }
    if (_password.text.isEmpty) {
      noticeBus.toast(t('user.inputPass'));
      return;
    }
    // 老端写的是 `password == '' && length < 6 && > 16`（三个条件同时成立才拦），
    // 等于几乎不校验。这里按文案本意实现成正常校验。
    if (_password.text.length < 6 || _password.text.length > 16) {
      noticeBus.toast(t('user.passLimit'));
      return;
    }
    if (_password.text != _repass.text) {
      noticeBus.toast(t('user.samePass'));
      return;
    }

    setState(() => _busy = true);
    try {
      await ref
          .read(sessionServiceProvider)
          .register(
            account: account,
            realName: realName,
            password: _password.text,
            repass: _repass.text,
            code: _code.text.trim(),
          );
      if (!mounted) return;
      noticeBus.toast(t('user.registerOk'));
      // 老端是等 2 秒再 reLaunch 回登录页
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      if (widget.addAccount) {
        // 添加账号：把这一页换成「登录其他账号」的表单（账号预填），
        // 而不是回 /login —— 回那儿会被守卫直接弹回主界面，人就不知道该干嘛了
        context.pushReplacement(
          '${AppRoutes.accountsAdd}'
          '?account=${Uri.encodeComponent(account)}',
        );
      } else {
        context.go(AppRoutes.login);
      }
    } on ApiException catch (error) {
      debugPrint('[注册] 失败：${error.message}'); // 提示已由网络层弹出
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final sysInfo = ref.watch(
      sessionStoreProvider.select((state) => state.config.sysInfo),
    );

    // 与登录页同一条口径（见 `AppInfo.siteName`）：老端那几个默认名换成 Gracelink
    final siteName = AppInfo.siteName(sysInfo.name);
    // 老端：验证码行只在 `parseInt(regauth)` 为真时显示
    final needCode = sysInfo.regauth != 0;

    return AuthScaffold(
      siteName: siteName,
      onBack: _goBack,
      children: <Widget>[
        SizedBox(height: context.rpx(20)),
        AuthBrand(siteName: siteName, subtitle: i18n.t('user.registerIntro')),
        SizedBox(height: context.rpx(46)),
        AuthCard(
          children: <Widget>[
            AuthFormRow(
              title: i18n.t('user.account'),
              child: AuthTextField(
                controller: _account,
                hintText: _accountHint(i18n, sysInfo),
                icon: Icons.person_outline_rounded,
                maxLength: 32,
                onChanged: _onAccountChanged,
                textInputAction: TextInputAction.next,
              ),
            ),
            AuthFormRow(
              title: i18n.t('user.nickname'),
              child: AuthTextField(
                controller: _realName,
                hintText: i18n.t('user.inputNickname'),
                icon: Icons.badge_outlined,
                maxLength: 32,
                textInputAction: TextInputAction.next,
              ),
            ),
            if (needCode)
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
            AuthFormRow(
              title: i18n.t('user.password'),
              child: AuthTextField(
                controller: _password,
                hintText: i18n.t('user.inputPass'),
                icon: Icons.lock_outline_rounded,
                obscure: true,
                maxLength: 32,
                textInputAction: TextInputAction.next,
              ),
            ),
            AuthFormRow(
              title: i18n.t('user.repass'),
              child: AuthTextField(
                controller: _repass,
                hintText: i18n.t('user.inputRepass'),
                icon: Icons.lock_outline_rounded,
                obscure: true,
                maxLength: 32,
                textInputAction: TextInputAction.done,
              ),
            ),
            SizedBox(height: context.rpx(10)),
            AuthButton(
              label: i18n.t('user.register'),
              busy: _busy,
              onPressed: _register,
            ),
          ],
        ),
        Padding(
          padding: EdgeInsets.only(top: context.rpx(26)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                i18n.t('user.hasAccount'),
                style: TextStyle(
                  fontSize: context.rpx(26),
                  color: AppColors.text999,
                ),
              ),
              AuthTextLink(label: i18n.t('user.login'), onPressed: _goBack),
            ],
          ),
        ),
      ],
    );
  }
}
