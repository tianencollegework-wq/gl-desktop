/// 登录 / 注册两页共用的那套观感。
///
/// 2026-09-29 用户说这两页「太丑太丑了，美化一下，现代化一点」，于是把 2026-09-25
/// 那版「照抄微信登录页」的白底 + 下划线输入行整体换掉，改成现在这套：
///
/// * 页面底色：顶部一层**极淡的品牌绿渐变**（往下过渡成白）压两团柔和光晕；
/// * 表单：一张**白色圆角卡片**（大圆角 + 低不透明度投影）把输入区框起来；
/// * 输入框：**圆角填充**（浅灰底）+ 行首图标，聚焦时描边变品牌绿、底色转白；
/// * 按钮：**通栏药丸**（主按钮品牌绿 + 同色柔光投影，次按钮绿色描边）；
/// * 语言切换：右上角一颗白色药丸（地球图标 + 当前语言），点开底部弹层。
///
/// 行为一点没动：还是那几个 controller、那套校验、那套 i18n key、那几个跳转。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_info.dart';
import '../../../core/i18n/app_i18n.dart';
import '../../../core/i18n/locale_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/ui/hover_highlight.dart';
import '../../../core/ui/desktop_overlay.dart';

/// 登录 / 注册页的外壳：渐变背景 + 可滚动内容 + 钉在底部的版本号。
///
/// 两页的差别只有中间那几块（登录：账号 / 密码 / 记住我 / 忘记密码；注册：
/// 五行资料 + 已有账号入口），所以外壳（顶栏、品牌、版本号、键盘处理）放在这里
/// 共用 —— 以前这些在每个页面里各写了一遍，改一处就得记得改另一处。
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.siteName,
    required this.children,
    this.onBack,
    this.showLanguage = true,
  });

  /// 站点名，只有底部版本号用它
  final String siteName;

  /// 顶栏下面的内容（品牌、卡片……）
  final List<Widget> children;

  /// 给了就在左上角画一颗返回按钮（注册页用）；登录页没有上一级，不传
  final VoidCallback? onBack;

  final bool showLanguage;

  @override
  Widget build(BuildContext context) {
    // 与老端同一条口径：内容可滚动、版本号钉在屏幕底部
    // （`position: fixed; bottom: 40rpx`），小屏 / 键盘弹出都不会溢出。
    //
    // `resizeToAvoidBottomInset: false`：键盘弹出时页面**不整体上推**，否则钉在
    // 底部的版本号会被顶到按钮中间（老端没有那个怪现象）。键盘高度改加到滚动内容
    // 的底部内边距里，输入框仍然能滚到键盘上方。
    return Scaffold(
      backgroundColor: AppColors.white,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: <Widget>[
          const Positioned.fill(child: AuthBackdrop()),
          SafeArea(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.only(
                      bottom:
                          context.rpx(110) +
                          MediaQuery.viewInsetsOf(context).bottom,
                    ),
                    child: Column(
                      children: <Widget>[
                        Padding(
                          padding: EdgeInsets.only(
                            top: context.rpx(18),
                            left: context.rpx(30),
                            right: context.rpx(30),
                          ),
                          child: Row(
                            children: <Widget>[
                              if (onBack != null)
                                _RoundIconButton(
                                  icon: Icons.arrow_back_ios_new_rounded,
                                  onTap: onBack!,
                                ),
                              const Spacer(),
                              if (showLanguage) const AuthLanguageChip(),
                            ],
                          ),
                        ),
                        ...children,
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: context.rpx(40),
                  child: AuthFooter(siteName: siteName),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 页面底色：顶部淡淡的品牌绿往下化开，另加两团柔光（不用 `BackdropFilter`，
/// 那玩意儿每一帧都要重新采样背景，登录页这种纯装饰不值得）。
class AuthBackdrop extends StatelessWidget {
  const AuthBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[AppColors.authWash, AppColors.white, AppColors.white],
          stops: <double>[0, 0.5, 1],
        ),
      ),
      child: ClipRect(
        child: Stack(
          children: <Widget>[
            Positioned(
              top: -context.rpx(130),
              right: -context.rpx(80),
              child: _Glow(
                size: context.rpx(380),
                color: AppColors.wechatGreen,
                opacity: 0.18,
              ),
            ),
            Positioned(
              top: context.rpx(150),
              left: -context.rpx(150),
              child: _Glow(
                size: context.rpx(330),
                color: AppColors.green,
                opacity: 0.12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一团从中心向外淡出的颜色（装饰用）
class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color, required this.opacity});

  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: <Color>[
          color.withValues(alpha: opacity),
          color.withValues(alpha: 0),
        ],
      ),
    ),
  );
}

/// 白底圆形小按钮（顶栏那颗返回箭头）
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: context.rpx(72),
    height: context.rpx(72),
    child: Material(
      color: AppColors.white,
      shape: const CircleBorder(side: BorderSide(color: AppColors.fieldBorder)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Icon(icon, size: context.rpx(32), color: AppColors.text333),
      ),
    ),
  );
}

/// 右上角的语言切换：白色药丸（地球 + 当前语言 + 箭头），点开底部弹层。
///
/// 老端就是一个右上角的灰字 `picker`；2026-09-29 改版换成药丸，顺便让**注册页
/// 也有了**（以前只有登录页能切语言，注册页的人被卡在当前语言里）。
class AuthLanguageChip extends ConsumerWidget {
  const AuthLanguageChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = LocaleController.labelOf(
      ref.watch(localeProvider),
      ref.watch(appI18nProvider),
    );
    // 桌面（2026-10-03）：药丸是手画的，吃不到主题的 `hoverColor`，
    // 悬停反馈与手型光标由 [HoverHighlight] 补（圆角与药丸一致）。
    return HoverHighlight(
      borderRadius: BorderRadius.circular(context.rpx(32)),
      child: GestureDetector(
        onTap: () => _pick(context, ref),
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: context.rpx(64),
          padding: EdgeInsets.symmetric(horizontal: context.rpx(22)),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(context.rpx(32)),
            border: Border.all(color: AppColors.fieldBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.translate_rounded,
                size: context.rpx(30),
                color: AppColors.text666,
              ),
              SizedBox(width: context.rpx(12)),
              Text(
                current,
                style: TextStyle(
                  fontSize: context.rpx(24),
                  color: AppColors.text666,
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: context.rpx(30),
                color: AppColors.chevron,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 老端 `langList` 那张表，最上面多一条「跟随系统」
  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final current = ref.read(localeProvider);
    final i18n = ref.read(appI18nProvider);
    final t = i18n.t;
    final items = LocaleController.pickerItems(i18n);
    final selected = await showAppSheet<String>(
      context: context,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.rpx(36)),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(height: sheetContext.rpx(30)),
            Text(
              t('user.language'),
              style: TextStyle(
                fontSize: sheetContext.rpx(30),
                fontWeight: FontWeight.w600,
                color: AppColors.text000,
              ),
            ),
            SizedBox(height: sheetContext.rpx(16)),
            for (final option in items)
              ListTile(
                title: Text(
                  option.label,
                  style: TextStyle(
                    fontSize: sheetContext.rpx(30),
                    color: AppColors.text000,
                  ),
                ),
                trailing: option.code == current.selectedCode
                    ? Icon(
                        Icons.check_rounded,
                        size: sheetContext.rpx(36),
                        color: AppColors.wechatGreen,
                      )
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(option.code),
              ),
            SizedBox(height: sheetContext.rpx(20)),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await ref.read(localeProvider.notifier).setLocale(selected);
  }
}

/// 顶部品牌区：白底圆角 logo（带柔光投影）+ 站点名 + 一行说明。
///
/// logo **固定用随包那一张**（`AppInfo.logoAsset`），不再优先取服务端
/// `sysInfo.logo` —— 用户 2026-09-27：「logo 也改成现在软件用的 logo」。
/// 站点**名字**照旧听服务端的（那是管理员可改的配置）。
class AuthBrand extends StatelessWidget {
  const AuthBrand({super.key, required this.siteName, this.subtitle});

  final String siteName;

  /// 站点名下面那行小字（登录页是「欢迎回来…」、注册页是「创建一个新账号…」）
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Container(
          padding: EdgeInsets.all(context.rpx(10)),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(context.rpx(46)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: AppColors.authShadow,
                blurRadius: context.rpx(44),
                offset: Offset(0, context.rpx(14)),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(context.rpx(36)),
            child: Image.asset(
              AppInfo.logoAsset,
              width: context.rpx(152),
              height: context.rpx(152),
              fit: BoxFit.cover,
            ),
          ),
        ),
        SizedBox(height: context.rpx(26)),
        Text(
          siteName,
          style: TextStyle(
            fontSize: context.rpx(46),
            fontWeight: FontWeight.w600,
            letterSpacing: context.rpx(1),
            color: AppColors.text000,
          ),
        ),
        if (subtitle != null) ...<Widget>[
          SizedBox(height: context.rpx(14)),
          Text(
            subtitle!,
            style: TextStyle(
              fontSize: context.rpx(26),
              color: AppColors.text999,
            ),
          ),
        ],
      ],
    );
  }
}

/// 表单白卡片：大圆角 + 很淡的一层投影，把输入区从背景上「抬」起来
class AuthCard extends StatelessWidget {
  const AuthCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: EdgeInsets.symmetric(horizontal: context.rpx(40)),
    padding: EdgeInsets.fromLTRB(
      context.rpx(36),
      context.rpx(42),
      context.rpx(36),
      context.rpx(38),
    ),
    decoration: BoxDecoration(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(context.rpx(36)),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: AppColors.authShadow,
          blurRadius: context.rpx(50),
          offset: Offset(0, context.rpx(18)),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// 一行输入：**上面标题、下面填充输入框**。
///
/// 老端（和 2026-09-25 那版）是「左标签 + 右输入 + 底下一根细线」；改版后标签
/// 移到框上方，行与行之间靠间距分开，不再画分割线。
class AuthFormRow extends StatelessWidget {
  const AuthFormRow({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: context.rpx(30)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(
            left: context.rpx(6),
            bottom: context.rpx(14),
          ),
          child: Text(
            title,
            style: TextStyle(
              fontSize: context.rpx(26),
              fontWeight: FontWeight.w500,
              color: AppColors.text666,
            ),
          ),
        ),
        child,
      ],
    ),
  );
}

/// 填充式圆角输入框：浅灰底 + 行首图标，聚焦时描边变品牌绿、底色转白。
///
/// 密码框右侧自带一颗眼睛（点一下明文／密文切换）—— 老端没有这个，是改版顺手
/// 加的：手机上一个字一个字戳密码，看不见很容易输错。
///
/// [trailing] 是给「发送验证码」那种按钮留的位置（放在框内右侧，比原来挂在
/// 行尾好看，也更符合现在这套观感）。
class AuthTextField extends StatefulWidget {
  const AuthTextField({
    super.key,
    required this.controller,
    required this.hintText,
    this.icon,
    this.obscure = false,
    this.keyboardType,
    this.maxLength,
    this.onChanged,
    this.trailing,
    this.textInputAction,
  });

  final TextEditingController controller;
  final String hintText;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final Widget? trailing;
  final TextInputAction? textInputAction;

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  final FocusNode _focus = FocusNode();

  /// 是否把内容遮起来（初始跟着 [AuthTextField.obscure]）
  late bool _hidden = widget.obscure;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: context.rpx(100),
      padding: EdgeInsets.symmetric(horizontal: context.rpx(26)),
      decoration: BoxDecoration(
        color: focused ? AppColors.white : AppColors.fieldFill,
        borderRadius: BorderRadius.circular(context.rpx(26)),
        border: Border.all(
          color: focused ? AppColors.wechatGreen : AppColors.fieldBorder,
          width: context.rpx(2),
        ),
      ),
      child: Row(
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            Icon(
              widget.icon,
              size: context.rpx(38),
              color: focused ? AppColors.wechatGreen : AppColors.text999,
            ),
            SizedBox(width: context.rpx(18)),
          ],
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              obscureText: _hidden,
              keyboardType: widget.keyboardType,
              maxLength: widget.maxLength,
              onChanged: widget.onChanged,
              textInputAction: widget.textInputAction,
              style: TextStyle(
                fontSize: context.rpx(30),
                color: AppColors.text000,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                counterText: '',
                hintText: widget.hintText,
                hintStyle: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text999,
                ),
              ),
            ),
          ),
          if (widget.trailing != null) ...<Widget>[
            SizedBox(width: context.rpx(14)),
            widget.trailing!,
          ],
          if (widget.obscure) ...<Widget>[
            SizedBox(width: context.rpx(10)),
            GestureDetector(
              onTap: () => setState(() => _hidden = !_hidden),
              behavior: HitTestBehavior.opaque,
              // 眼睛图标本身很小，垫一圈内边距把可点范围撑到 48rpx 见方
              child: Padding(
                padding: EdgeInsets.all(context.rpx(8)),
                child: Icon(
                  _hidden
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: context.rpx(34),
                  color: AppColors.text999,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 主按钮：**通栏药丸**，品牌绿 + 同色柔光投影。
///
/// [background] / [foreground] 留着是因为注册页以前传过描边按钮，现在两页都用
/// 默认的绿色（描边那颗换成了 [AuthSecondaryButton]）。
class AuthButton extends StatelessWidget {
  const AuthButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.background = AppColors.wechatGreen,
    this.foreground = AppColors.white,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color background;
  final Color foreground;

  /// 请求进行中：显示转圈并禁用点击
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: context.rpx(104),
      child: ElevatedButton(
        onPressed: busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: AppColors.greenLight,
          disabledForegroundColor: AppColors.white,
          elevation: 8,
          shadowColor: background.withValues(alpha: 0.45),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(context.rpx(52)),
          ),
        ),
        child: busy
            ? SizedBox(
                width: context.rpx(36),
                height: context.rpx(36),
                child: const CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.white,
                ),
              )
            : Text(
                label,
                style: TextStyle(
                  fontSize: context.rpx(32),
                  fontWeight: FontWeight.w600,
                  letterSpacing: context.rpx(2),
                  color: foreground,
                ),
              ),
      ),
    );
  }
}

/// 次按钮：**绿色描边药丸**（登录页那颗「注册」）。
///
/// 以前注册入口是一行绿色小字，挂在按钮下面容易被当成免责声明；
/// 换成一颗和主按钮同宽的白底描边按钮，层级一眼就清楚。
class AuthSecondaryButton extends StatelessWidget {
  const AuthSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: context.rpx(96),
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: AppColors.white,
        side: BorderSide(
          color: AppColors.wechatGreen.withValues(alpha: 0.55),
          width: context.rpx(2),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(context.rpx(48)),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: context.rpx(30),
          fontWeight: FontWeight.w500,
          color: AppColors.wechatGreen,
        ),
      ),
    ),
  );
}

/// 白底上的**绿色文字链接**（「忘记密码」「已有账号？登录」那个「登录」）。
class AuthTextLink extends StatelessWidget {
  const AuthTextLink({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => HoverHighlight(
    borderRadius: BorderRadius.circular(context.rpx(8)),
    child: GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(6),
          vertical: context.rpx(12),
        ),
        // 与左边「记住我」同一行，宽度由登录页封顶（见 `_buildOptions`）——
        // 长文案（日语「パスワードをお忘れですか」）在这里按宽度换行，不会顶出去。
        child: Text(
          label,
          style: TextStyle(
            fontSize: context.rpx(28),
            fontWeight: FontWeight.w500,
            color: AppColors.wechatGreen,
          ),
        ),
      ),
    ),
  );
}

/// 输入框里那颗「发送验证码」：淡绿底的小药丸（比行尾一行小字更好点）
class AuthCodeButton extends StatelessWidget {
  const AuthCodeButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => HoverHighlight(
    borderRadius: BorderRadius.circular(context.rpx(20)),
    child: GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(20),
          vertical: context.rpx(12),
        ),
        decoration: BoxDecoration(
          color: AppColors.wechatGreen.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(context.rpx(20)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: context.rpx(24),
            fontWeight: FontWeight.w600,
            color: AppColors.wechatGreen,
          ),
        ),
      ),
    ),
  );
}

/// 「记住我」那颗方框：圆角小方块，选中时填品牌绿 + 白勾，旁边一档灰字。
class AuthCheckBox extends StatelessWidget {
  const AuthCheckBox({
    super.key,
    required this.label,
    required this.checked,
    required this.onChanged,
  });

  final String label;
  final bool checked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => HoverHighlight(
    borderRadius: BorderRadius.circular(context.rpx(10)),
    child: GestureDetector(
      onTap: () => onChanged(!checked),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.rpx(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: context.rpx(34),
              height: context.rpx(34),
              decoration: BoxDecoration(
                color: checked ? AppColors.wechatGreen : AppColors.white,
                borderRadius: BorderRadius.circular(context.rpx(10)),
                border: Border.all(
                  color: checked ? AppColors.wechatGreen : AppColors.chevron,
                  width: context.rpx(2),
                ),
              ),
              child: checked
                  ? Icon(
                      Icons.check_rounded,
                      size: context.rpx(24),
                      color: AppColors.white,
                    )
                  : null,
            ),
            SizedBox(width: context.rpx(14)),
            // `Flexible`：外面（登录页那一行）拿整行宽度封了顶，这里再让文字
            // 自己按剩余宽度换行 —— 否则 Row 里的非弹性孩子拿到的是无界宽度，
            // 日语「ログイン状態を保持」这种长文案会直接画到父级外面去。
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: context.rpx(26),
                  color: AppColors.text666,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 钉在屏幕底部那行版本号：`{站点名} for {版本}`
class AuthFooter extends StatelessWidget {
  const AuthFooter({super.key, required this.siteName});

  final String siteName;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      AppInfo.footer(siteName),
      style: TextStyle(
        fontSize: context.rpx(24),
        letterSpacing: context.rpx(0.5),
        color: AppColors.text999,
      ),
    ),
  );
}
