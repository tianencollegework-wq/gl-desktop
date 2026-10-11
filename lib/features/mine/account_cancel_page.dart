import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/router/app_router.dart';
import '../../domain/session/session_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../data/repo/profile_repository.dart';

/// 注销账号（设置在 账号与安全 里那一行）。
///
/// 三件事按微信那套来：
/// * 先把**后果逐条写清楚**（注销不可逆，不能上来就一颗红按钮）；
/// * 填**登录密码**当凭据 —— 服务端 `Im::deleteAccount` 会再校验一次
///   （客户端这一层只是防误触）；
/// * 提交前再来一层确认弹窗，确认了才真发请求。
///
/// 成功后清掉本机会话并回登录页：服务端把账号软删除了（`delete_time`），
/// 手里那枚 token 也当场作废 —— 同一个账号密码再也登不进来。
class AccountCancelPage extends ConsumerStatefulWidget {
  const AccountCancelPage({super.key});

  @override
  ConsumerState<AccountCancelPage> createState() => _AccountCancelPageState();
}

class _AccountCancelPageState extends ConsumerState<AccountCancelPage> {
  final TextEditingController _password = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final i18n = ref.read(appI18nProvider);
    if (_submitting) return;
    if (_password.text.isEmpty) {
      noticeBus.toast(i18n.t('user.cancelPasswordHint'));
      return;
    }
    // 最后一层确认：红按钮 + 「确定」才真的发请求
    final confirmed = await showWeChatConfirm(
      context,
      message: i18n.t('user.cancelConfirm'),
      // 弹窗那颗键用「注销」（页面上那颗大按钮是「申请注销」，两个不一样，
      // 免得同一句话在屏幕上出现两遍）
      confirmLabel: i18n.t('user.cancel'),
      danger: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _submitting = true);
    try {
      final message = await ref
          .read(profileRepositoryProvider)
          .cancelAccount(password: _password.text);
      if (!mounted) return;
      noticeBus.toast(message.isNotEmpty ? message : i18n.t('user.cancelled'));
      // 账号已经没了：本机那份会话（含 token、未读、聊天列表）一起清掉
      await ref.read(sessionServiceProvider).logout();
      if (mounted) context.go(AppRoutes.home);
    } on ApiException catch (error) {
      debugPrint('[注销账号] 失败：${error.message}');
      noticeBus.toast(error.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final filled = _password.text.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('user.cancelAccount'))),
      body: ListView(
        padding: EdgeInsets.only(bottom: context.rpx(40)),
        children: <Widget>[
          // 为什么、会发生什么：写清楚再让人决定
          Container(
            color: AppColors.white,
            padding: EdgeInsets.symmetric(
              horizontal: context.rpx(30),
              vertical: context.rpx(30),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  i18n.t('user.cancelIntro'),
                  style: TextStyle(
                    fontSize: context.rpx(28),
                    height: 1.6,
                    color: AppColors.text000,
                  ),
                ),
                SizedBox(height: context.rpx(18)),
                _bullet(context, i18n.t('user.cancelBullet1')),
                _bullet(context, i18n.t('user.cancelBullet2')),
                _bullet(context, i18n.t('user.cancelBullet3')),
              ],
            ),
          ),
          SizedBox(height: context.rpx(16)),
          // 密码：确认是本人操作（服务端也会校验这一栏）
          Container(
            color: AppColors.white,
            padding: EdgeInsets.symmetric(
              horizontal: context.rpx(30),
              vertical: context.rpx(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  i18n.t('user.cancelPassword'),
                  style: TextStyle(
                    fontSize: context.rpx(28),
                    color: AppColors.text000,
                  ),
                ),
                SizedBox(height: context.rpx(6)),
                TextField(
                  controller: _password,
                  obscureText: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: i18n.t('user.cancelPasswordHint'),
                    hintStyle: TextStyle(
                      fontSize: context.rpx(26),
                      color: AppColors.text999,
                    ),
                    border: InputBorder.none,
                  ),
                  style: TextStyle(
                    fontSize: context.rpx(30),
                    color: AppColors.text000,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.rpx(30),
              vertical: context.rpx(40),
            ),
            child: SizedBox(
              height: context.rpx(AppDimens.listRowRpx),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  // 和弹窗里那颗「注销」用同一档红（`WeChatDialogTone.danger`）
                  backgroundColor: AppColors.red,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(context.rpx(12)),
                  ),
                ),
                onPressed: (!filled || _submitting) ? null : _submit,
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
                        i18n.t('user.cancelSubmit'),
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
    );
  }

  /// 一条后果（前面一个小圆点，微信那种纯文字清单）
  Widget _bullet(BuildContext context, String text) => Padding(
    padding: EdgeInsets.only(top: context.rpx(10)),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '· ',
          style: TextStyle(
            fontSize: context.rpx(28),
            height: 1.6,
            color: AppColors.text999,
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: context.rpx(28),
              height: 1.6,
              color: AppColors.text999,
            ),
          ),
        ),
      ],
    ),
  );
}
