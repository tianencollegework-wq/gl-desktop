import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/api/chat_api.dart';

/// 扫码登录确认页，对应老端 `pages/login/qrlogin.vue`
/// （`/pages/login/qrlogin?token=<loginToken>`）。
///
/// 来路只有一个：用「扫一扫」扫到**网页/PC 端的登录二维码**（服务端回答
/// `action == qrLogin`，并给一个 `loginToken`）。这一页负责让用户确认
/// 「这次登录是我本人」，确认后才 `POST /enterprise/im/tokenLogin`
/// 把那个网页会话放进自己的账号。
///
/// 与老端一致的三处：**没带 token 直接退回**；确认后把服务端那句 `msg`
/// 原样提示出来；提示完 1.5 秒自动退回。第 4 处也与老端一致：**只提示，
/// 不管对端到底登没登上**（服务端回什么就说什么，不再多问一次）。
///
/// 与老端不同（刻意的）：服务端没给 `msg` 时补一句「登录成功」——
/// 老端这种情况下什么都不弹，用户不知道成没成。
class QrLoginPage extends ConsumerStatefulWidget {
  const QrLoginPage({super.key, this.token = ''});

  /// 网页端那次登录的令牌（扫一扫从服务端拿到的 `loginToken`）
  final String token;

  @override
  ConsumerState<QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends ConsumerState<QrLoginPage> {
  /// 请求中（按钮转圈）／已确认（等那 1.5 秒里再点也没用）
  bool _busy = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // 老端 `onLoad`：没有 token 直接 `navigateBack()`
    if (widget.token.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pop();
      });
    }
  }

  Future<void> _login() async {
    if (_busy || _done) return;
    final i18n = ref.read(appI18nProvider);
    setState(() => _busy = true);
    try {
      final message = await ref.read(chatApiProvider).tokenLoginMessage(
        <String, dynamic>{'token': widget.token},
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
      noticeBus.toast(message.isEmpty ? i18n.t('user.qrLoginOk') : message);
      // 老端也是这样：提示挂 1.5 秒再自己退回
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (mounted) context.pop();
    } on ApiException catch (error) {
      // 失败留在这一页（老端靠拦截器弹提示、同样不退回）
      debugPrint('[扫码登录] 确认失败：${error.message}');
      if (!mounted) return;
      setState(() => _busy = false);
      noticeBus.toast(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);

    return Scaffold(
      backgroundColor: AppColors.white,
      // 老端这一页没有导航栏：只有图标 + 一句确认 + 两颗按钮
      body: SafeArea(
        child: Column(
          children: <Widget>[
            SizedBox(height: context.rpx(300)),
            Icon(
              Icons.desktop_windows_outlined,
              size: context.rpx(150),
              color: AppColors.text999,
            ),
            SizedBox(height: context.rpx(40)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rpx(40)),
              child: Text(
                i18n.t('user.confirmQrlogin'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text999,
                ),
              ),
            ),
            SizedBox(height: context.rpx(60)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rpx(60)),
              child: SizedBox(
                width: double.infinity,
                height: context.rpx(90),
                child: FilledButton(
                  onPressed: _busy ? null : _login,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.green,
                  ),
                  child: _busy
                      ? SizedBox(
                          width: context.rpx(34),
                          height: context.rpx(34),
                          child: const CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.white,
                          ),
                        )
                      : Text(
                          i18n.t('user.login'),
                          style: TextStyle(fontSize: context.rpx(30)),
                        ),
                ),
              ),
            ),
            SizedBox(height: context.rpx(30)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rpx(60)),
              child: SizedBox(
                width: double.infinity,
                height: context.rpx(90),
                child: OutlinedButton(
                  onPressed: () => context.pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.text666,
                  ),
                  child: Text(
                    i18n.t('common.cancel'),
                    style: TextStyle(fontSize: context.rpx(30)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
