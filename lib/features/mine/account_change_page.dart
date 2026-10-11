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

/// 更换账号，对应老端 `pages/mine/secure.vue` 里那个底部弹层的「改账号」分支。
///
/// 老端和我们原来都是**一个弹层塞三栏**（新账号 / 当前账号验证码 / 新账号验证码，
/// 一起填完再保存）。现在跟「修改密码」一样拆成**一屏一项的向导**：
///
/// | 步骤 | 已认证（`is_auth`） | 未认证 |
/// |---|---|---|
/// | 1 | 新邮箱 | 同左 |
/// | 2 | 新邮箱收到的验证码（可点「发送验证码」，带 60 秒倒计时） | 同左 |
/// | 3 | **当前账号**的验证码 | 没有这一步（两步入完） |
///
/// 顺序就是微信「更换手机号」那套：**先填新号 → 验新号 → 验原号**。
/// 认证这件事本身就是「把账号换成真实的邮箱，验证成功后服务端把 `is_auth` 置 1」，
/// 所以未认证的账号走的是前两步（不需要、也没有原邮箱可验 —— 老端那个弹层里
/// `code` 那一栏对未认证账号本来就是空的）。
///
/// 本系统**只支持邮箱**（后端没有手机号验证），所以这一页的三处文案都是邮箱口径。
///
/// 「我的账号」和「认证账户」两行都进这一页：前者要求先认证（在 `SecurePage` 里拦），
/// 后者本来就是来认证的，不查 `is_auth`。
class AccountChangePage extends ConsumerStatefulWidget {
  const AccountChangePage({super.key});

  @override
  ConsumerState<AccountChangePage> createState() => _AccountChangePageState();
}

class _AccountChangePageState extends ConsumerState<AccountChangePage> {
  int _step = 0;
  AccountForm _form = const AccountForm();

  bool _sendingCode = false;
  bool _submitting = false;

  /// 「发送验证码」之后的倒计时（秒）
  int _countdown = 0;
  Timer? _timer;

  // 每个输入一份 controller（由本 State 拥有并释放）：来回翻步时填过的内容还在
  final TextEditingController _account = TextEditingController();
  final TextEditingController _naCode = TextEditingController();
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _timer?.cancel();
    _account.dispose();
    _naCode.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _isAuth => (ref.read(sessionStoreProvider).user?.isAuth ?? 0) != 0;

  /// 最后一步：已认证三步（第三步验当前账号），未认证两步
  int get _lastStep => _isAuth ? 2 : 1;

  /// 当前这一栏填了没有（决定那颗按钮灰不灰）
  bool get _filled => switch (_step) {
    0 => _account.text.trim().isNotEmpty,
    1 => _naCode.text.trim().isNotEmpty,
    _ => _code.text.trim().isNotEmpty,
  };

  /// 各步自己的校验（文案还是老端那几条，见 `AccountForm.validationErrorKey`）
  String? _stepErrorKey() => switch (_step) {
    0 =>
      _account.text.trim().isEmpty
          ? 'user.inputNewAccount'
          : (emailPattern.hasMatch(_account.text.trim())
                ? null
                : 'common.correctEmail'),
    1 => _naCode.text.trim().isEmpty ? 'user.inputNaCode' : null,
    _ => _code.text.trim().isEmpty ? 'user.inputCaptcha' : null,
  };

  /// 发验证码。[toNewAccount] 决定发给新邮箱还是当前账号绑定的邮箱。
  ///
  /// 两个入口的 `type` 都是 4（改账号）—— 老端那个弹层里两颗「发送验证码」
  /// 传的也是同一个 4，见 `sendCodeType(forPassword: false)`。
  Future<void> _sendCode({required bool toNewAccount}) async {
    final i18n = ref.read(appI18nProvider);
    if (_sendingCode || _countdown > 0) return;

    final account = toNewAccount
        ? _account.text.trim()
        : (ref.read(sessionStoreProvider).user?.account ?? '');
    if (account.isEmpty) {
      noticeBus.toast(
        i18n.t(toNewAccount ? 'user.inputNewAccount' : 'user.inputAccount'),
      );
      return;
    }

    setState(() => _sendingCode = true);
    try {
      final message = await ref
          .read(profileRepositoryProvider)
          .sendCode(account: account, forPassword: false);
      if (!mounted) return;
      if (message.isNotEmpty) noticeBus.toast(message);
      _startCountdown();
    } on ApiException catch (error) {
      debugPrint('[更换账号] 发送验证码失败：${error.message}');
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
      await ref.read(profileRepositoryProvider).changeAccount(_form);
      if (!mounted) return;
      // 老端改完账号提示「修改成功，请重新登陆」
      noticeBus.toast(i18n.t('user.editOkRelogin'));
      Navigator.of(context).pop();
    } on ApiException catch (error) {
      debugPrint('[更换账号] 提交失败：${error.message}');
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
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _back();
      },
      child: Scaffold(
        backgroundColor: AppColors.page,
        appBar: AppBar(
          title: Text(i18n.t('user.changeAccount')),
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
      0 => (i18n.t('user.newAccount'), i18n.t('user.doAuthCorrect')),
      1 => (i18n.t('user.naCode'), i18n.t('user.stepNaCodeHint')),
      _ => (i18n.t('user.captcha'), i18n.t('user.stepOldAccountCodeHint')),
    };

    final (
      TextEditingController controller,
      TextInputType keyboard,
      Widget? trailing,
    ) = switch (_step) {
      0 => (_account, TextInputType.emailAddress, null),
      1 => (
        _naCode,
        TextInputType.number,
        _sendCodeButton(context, i18n, true),
      ),
      _ => (_code, TextInputType.number, _sendCodeButton(context, i18n, false)),
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
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: keyboard,
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
    0 => i18n.t('user.emailOrPhone'),
    1 => i18n.t('user.inputCaptcha'),
    _ => i18n.t('user.inputCaptcha'),
  };

  void _onChanged(String value) {
    setState(() {
      _form = switch (_step) {
        0 => _form.copyWith(account: value),
        1 => _form.copyWith(newCode: value),
        _ => _form.copyWith(code: value),
      };
    });
  }

  /// 「发送验证码」（发完变倒计时，微信也是这么做的）
  Widget _sendCodeButton(
    BuildContext context,
    AppI18n i18n,
    bool toNewAccount,
  ) => Padding(
    padding: EdgeInsets.only(left: context.rpx(16)),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: (_sendingCode || _countdown > 0)
          ? null
          : () => _sendCode(toNewAccount: toNewAccount),
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
