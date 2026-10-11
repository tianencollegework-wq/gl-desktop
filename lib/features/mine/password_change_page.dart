import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/repo/profile_repository.dart';
import '../../domain/mine/profile_form.dart';

/// 修改密码，对应老端 `pages/mine/secure.vue` 里那个底部弹层的「改密码」分支。
///
/// 老端和我们原来都是**一个弹层塞三栏**（验证码 / 新密码 / 重复新密码，一起填完再保存）。
/// 现在改成**三步三个页面**（微信那种一屏一项的向导）：
///
/// | 步骤 | 已认证（`is_auth`） | 未认证 |
/// |---|---|---|
/// | 1 | 验证码（可点「发送验证码」，带 60 秒倒计时） | 原密码 |
/// | 2 | 新密码（6–16 位） | 同左 |
/// | 3 | 确认新密码 | 同左 |
///
/// 每页一栏 + 一行灰提示 + 一颗绿色大按钮（微信那套：白底、圆角、`#07C160`），
/// 按钮右上角只有「下一步 / 完成」这一个主动作 —— 校验也拆到各步：
/// 第 1 步查验证码、第 2 步查长度、第 3 步查两次一致（顺序与文案都还是老端那三条，
/// 见 `domain/mine/profile_form.dart` 的 `PasswordForm`）。
///
/// **返回键在一页不是退出，而是回上一步**（`PopScope` + 顶栏那颗返回箭头同一套逻辑）：
/// 不然填到第三步一按返回整页就没了，这体验比弹层还差。
class PasswordChangePage extends ConsumerStatefulWidget {
  const PasswordChangePage({super.key});

  @override
  ConsumerState<PasswordChangePage> createState() => _PasswordChangePageState();
}

class _PasswordChangePageState extends ConsumerState<PasswordChangePage> {
  /// 一共三步（0 起）
  static const int _lastStep = 2;

  int _step = 0;
  PasswordForm _form = const PasswordForm();

  bool _sendingCode = false;
  bool _submitting = false;

  /// 「发送验证码」之后的倒计时（秒）；> 0 时那颗按钮变成 `59s` 且不可点
  int _countdown = 0;
  Timer? _timer;

  // 四个输入各自一个 controller（由本 State 拥有并释放）：来回翻步时填过的内容还在
  final TextEditingController _code = TextEditingController();
  final TextEditingController _old = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _repass = TextEditingController();

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _old.dispose();
    _password.dispose();
    _repass.dispose();
    super.dispose();
  }

  bool get _isAuth => (ref.read(sessionStoreProvider).user?.isAuth ?? 0) != 0;

  /// 当前这一栏填了没有（决定那颗按钮灰不灰）
  bool get _filled => switch (_step) {
    0 => _isAuth ? _code.text.trim().isNotEmpty : _old.text.isNotEmpty,
    1 => _password.text.isNotEmpty,
    _ => _repass.text.isNotEmpty,
  };

  Future<void> _sendCode() async {
    final i18n = ref.read(appI18nProvider);
    final user = ref.read(sessionStoreProvider).user;
    if (_sendingCode || _countdown > 0) return;
    final account = user?.account ?? '';
    if (account.trim().isEmpty) {
      noticeBus.toast(i18n.t('user.inputNewAccount'));
      return;
    }

    setState(() => _sendingCode = true);
    try {
      final message = await ref
          .read(profileRepositoryProvider)
          .sendCode(account: account, forPassword: true);
      if (!mounted) return;
      if (message.isNotEmpty) noticeBus.toast(message);
      _startCountdown();
    } on ApiException catch (error) {
      debugPrint('[修改密码] 发送验证码失败：${error.message}');
      noticeBus.toast(error.message);
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _countdown = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _countdown--);
      if (_countdown <= 0) timer.cancel();
    });
  }

  /// 各步自己的校验（顺序与文案照老端，见 `PasswordForm.validationErrorKey`）
  String? _stepErrorKey() => switch (_step) {
    0 => _isAuth && _code.text.trim().isEmpty ? 'user.inputCaptcha' : null,
    1 =>
      (_password.text.length < 6 || _password.text.length > 16)
          ? 'user.passLimit'
          : null,
    _ => _repass.text != _password.text ? 'user.samePass' : null,
  };

  /// 下一步 / 完成
  Future<void> _next() async {
    final i18n = ref.read(appI18nProvider);
    final errorKey = _stepErrorKey();
    if (errorKey != null) {
      noticeBus.toast(i18n.t(errorKey));
      return;
    }
    if (_step < _lastStep) {
      setState(() => _step++);
      return;
    }
    await _submit();
  }

  Future<void> _submit() async {
    final i18n = ref.read(appI18nProvider);
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final message = await ref
          .read(profileRepositoryProvider)
          .changePassword(_form);
      if (!mounted) return;
      noticeBus.toast(message.isNotEmpty ? message : i18n.t('common.saveOk'));
      Navigator.of(context).pop();
    } on ApiException catch (error) {
      debugPrint('[修改密码] 提交失败：${error.message}');
      noticeBus.toast(error.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 顶栏那颗返回箭头：不在第一步就回上一步（与系统返回键同一套）
  void _back() {
    if (_step > 0) {
      setState(() => _step--);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final isAuth = ref.watch(
      sessionStoreProvider.select((state) => (state.user?.isAuth ?? 0) != 0),
    );

    return PopScope(
      // 第一步才允许真的退出这一页
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _back();
      },
      child: Scaffold(
        backgroundColor: AppColors.page,
        appBar: AppBar(
          title: Text(i18n.t('user.editPass')),
          // 用 `BackButton` 而不是自己拼一个 IconButton：全站返回箭头一个样子，
          // 测试里也统一用 `find.byType(BackButton)` 找它
          leading: BackButton(onPressed: _back),
        ),
        body: ListView(
          padding: EdgeInsets.only(bottom: context.rpx(40)),
          children: <Widget>[
            _fieldBlock(context, i18n, isAuth),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.rpx(30),
                vertical: context.rpx(30),
              ),
              child: SizedBox(
                height: context.rpx(88),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.wechatGreen,
                    disabledBackgroundColor: AppColors.greenLight,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(context.rpx(12)),
                    ),
                  ),
                  onPressed: (!_filled || _submitting) ? null : _next,
                  child: _submitting
                      ? SizedBox(
                          width: context.rpx(40),
                          height: context.rpx(40),
                          child: const CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.white,
                          ),
                        )
                      : Text(
                          i18n.t(
                            _step == _lastStep ? 'common.done' : 'common.next',
                          ),
                          style: TextStyle(
                            fontSize: context.rpx(32),
                            color: AppColors.white,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一屏一栏：白底一行 + 它下面那行灰提示
  Widget _fieldBlock(BuildContext context, AppI18n i18n, bool isAuth) {
    final (String label, String hint) = switch (_step) {
      0 =>
        isAuth
            ? (i18n.t('user.captcha'), i18n.t('user.stepCodeHint'))
            : (i18n.t('user.originalPass'), i18n.t('user.stepOldPassHint')),
      1 => (i18n.t('user.newPass'), i18n.t('user.stepNewPassHint')),
      _ => (i18n.t('user.reNewPass'), i18n.t('user.stepReNewPassHint')),
    };

    final (
      TextEditingController controller,
      bool obscure,
      Widget? trailing,
    ) = switch (_step) {
      0 =>
        isAuth
            ? (_code, false, _sendCodeButton(context, i18n))
            : (_old, true, null),
      1 => (_password, true, null),
      _ => (_repass, true, null),
    };

    return Container(
      color: AppColors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: context.rpx(AppDimens.listRowRpx),
            padding: EdgeInsets.symmetric(
              horizontal: context.rpx(AppDimens.listPadRpx),
            ),
            child: Row(
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: context.rpx(32),
                    color: AppColors.text000,
                  ),
                ),
                SizedBox(width: context.rpx(24)),
                Expanded(
                  child: TextField(
                    controller: controller,
                    obscureText: obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: _step == 0 && isAuth
                        ? TextInputType.number
                        : TextInputType.text,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: context.rpx(32),
                      color: AppColors.text000,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: _placeholder(i18n),
                      hintStyle: TextStyle(
                        fontSize: context.rpx(32),
                        color: AppColors.text999,
                      ),
                    ),
                    onChanged: _onChanged,
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              left: context.rpx(AppDimens.listPadRpx),
              right: context.rpx(AppDimens.listPadRpx),
              bottom: context.rpx(24),
            ),
            child: Text(
              hint,
              style: TextStyle(
                fontSize: context.rpx(24),
                color: AppColors.text999,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _placeholder(AppI18n i18n) => switch (_step) {
    0 =>
      _isAuth ? i18n.t('user.inputCaptcha') : i18n.t('user.inputOriginalPass'),
    1 => i18n.t('user.passLimit'),
    _ => i18n.t('user.inputReNewPass'),
  };

  void _onChanged(String value) {
    setState(() {
      _form = switch (_step) {
        0 =>
          _isAuth
              ? _form.copyWith(code: value)
              : _form.copyWith(originalPassword: value),
        1 => _form.copyWith(password: value),
        _ => _form.copyWith(repass: value),
      };
    });
  }

  /// 第 1 步右侧那颗「发送验证码」（发完变倒计时，微信也是这么做的）
  Widget _sendCodeButton(BuildContext context, AppI18n i18n) => Padding(
    padding: EdgeInsets.only(left: context.rpx(16)),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: (_sendingCode || _countdown > 0) ? null : _sendCode,
      child: Text(
        _countdown > 0 ? '${_countdown}s' : i18n.t('user.sendCode'),
        style: TextStyle(
          fontSize: context.rpx(28),
          color: _countdown > 0 ? AppColors.text999 : AppColors.linkGreen,
        ),
      ),
    ),
  );
}
