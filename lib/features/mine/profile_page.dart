import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/media/media_picker.dart';
import '../../core/net/api_exception.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/repo/profile_repository.dart';
import '../../domain/mine/profile_form.dart';
import '../contacts/widgets/contact_avatar.dart';
import 'widgets/mine_list.dart';

/// 个人信息，对应老端 `pages/mine/profile.vue`（S5.5）。
///
/// 字段与行为逐条照老端：
/// * 头像：点一下选图 → `uploadAvatar`（表单带 `ext=png`）→ 成功后换本地头像；
/// * 账号：只读；
/// * 姓名/昵称：企业模式（`runMode==1`）且没开自定义名字时只读，否则可编辑；
/// * 邮箱：可空，填了就得像个邮箱；
/// * 性别：男（1）/ 女（0）单选；
/// * 个性签名：多行；
/// * 保存成功后更新本地登录用户（老端 `loginStore.login(data)`）。
///
/// 观感按**微信 `我 → 个人信息`**：**通栏白底、行高 50dp、行间细线从文字左边起**，
/// 行首文字近黑、右侧值那档灰、箭头 `#B0B0B0` —— 与设置页、「我」页完全同一套
/// 尺寸（都取 `AppDimens` 里那组常量），不是这一页自己另定一套。
///
/// 刻意不画的：微信那页还有「我的二维码」「更多」「我的地址」，我们没有对应数据；
/// 微信也**没有保存按钮**（它改完即时上传），我们仍然是表单 + 保存（接口是一次性
/// 提交四个字段），所以照旧的绿按钮，只是换成微信那支品牌绿。
///
/// 与老端不同（刻意的）：
/// * **不做裁剪**：老端那个 `yq-avatar` 组件会弹出裁剪框（固定输出 240px 的 png），
///   新端直接上传选中的图（要裁剪得引一个原生裁剪插件，先不做）；
/// * 保存没有 8 秒冷却（老端那是防连点的土办法，新端用按钮禁用代替）。
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  late ProfileForm _form = ProfileForm.fromUser(
    ref.read(sessionStoreProvider).user,
  );
  bool _saving = false;
  bool _uploading = false;

  Future<void> _save() async {
    final i18n = ref.read(appI18nProvider);
    final errorKey = _form.validationErrorKey();
    if (errorKey != null) {
      noticeBus.toast(i18n.t(errorKey));
      return;
    }
    final user = ref.read(sessionStoreProvider).user;
    if (user == null) return;

    setState(() => _saving = true);
    try {
      final updated = await ref
          .read(profileRepositoryProvider)
          .updateProfile(current: user, form: _form);
      if (!mounted) return;
      // 老端保存成功后 `loginStore.login(data)`：本地用户信息跟着换新
      ref.read(sessionStoreProvider.notifier).applyLogin(updated);
      noticeBus.toast(i18n.t('common.saveOk'));
    } on ApiException catch (error) {
      debugPrint('[个人信息] 保存失败：${error.message}');
      noticeBus.toast(error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAvatar() async {
    final i18n = ref.read(appI18nProvider);
    final user = ref.read(sessionStoreProvider).user;
    if (user == null || _uploading) return;

    final picked = await ref.read(mediaPickerProvider).pickImages(limit: 1);
    if (picked.isEmpty || !mounted) return;

    setState(() => _uploading = true);
    noticeBus.toast(i18n.t('common.uploading'));
    try {
      final url = await ref
          .read(profileRepositoryProvider)
          .uploadAvatar(File(picked.first.path));
      if (!mounted) return;
      if (url.isEmpty) {
        // 服务端没给地址（老端这时是 `avatar = undefined`，头像一个空框）
        debugPrint('[个人信息] 头像上传成功但没拿到地址');
        noticeBus.toast(i18n.t('network.error'));
        return;
      }
      ref
          .read(sessionStoreProvider.notifier)
          .applyLogin(mergeAvatar(user, url));
    } on ApiException catch (error) {
      debugPrint('[个人信息] 头像上传失败：${error.message}');
      noticeBus.toast(error.message);
    } on Object catch (error) {
      // 选图本身也可能失败（权限拒绝等），别让它冒到框架
      debugPrint('[个人信息] 选图失败：$error');
      noticeBus.toast(i18n.t('common.notAuth'));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final user = ref.watch(sessionStoreProvider.select((state) => state.user));
    final sysInfo = ref.watch(
      sessionStoreProvider.select((state) => state.config.sysInfo),
    );
    final editable = nicknameEditable(sysInfo);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('user.profile'))),
      body: ListView(
        padding: EdgeInsets.only(bottom: context.rpx(60)),
        children: <Widget>[
          MineList(
            gapBefore: false,
            children: <Widget>[
              _avatarRow(context, i18n, user?.avatar ?? ''),
              // 账号：老端只读，微信里那个「微信号」也改不了
              MineListItem(
                label: i18n.t('user.account'),
                trailing: user?.account ?? '',
                showChevron: false,
              ),
              if (editable)
                _EditableRow(
                  label: i18n.t(nicknameLabelKey(sysInfo)),
                  initialValue: _form.realName,
                  placeholder: i18n.t('user.inputNickname'),
                  onChanged: (value) =>
                      setState(() => _form = _form.copyWith(realName: value)),
                )
              else
                MineListItem(
                  label: i18n.t('user.realname'),
                  trailing: user?.realName ?? '',
                  showChevron: false,
                ),
              _genderRow(context, i18n),
              _EditableRow(
                label: 'e-mail',
                initialValue: _form.email,
                placeholder: i18n.t('user.inputEmail'),
                onChanged: (value) =>
                    setState(() => _form = _form.copyWith(email: value)),
              ),
            ],
          ),
          // 个性签名单独一块（微信把它和资料信息分开）
          MineList(
            children: <Widget>[
              _EditableRow(
                label: i18n.t('user.motto'),
                initialValue: _form.motto,
                placeholder: i18n.t('user.inputMotto'),
                stacked: true,
                maxLines: 3,
                onChanged: (value) =>
                    setState(() => _form = _form.copyWith(motto: value)),
              ),
            ],
          ),
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
                  disabledBackgroundColor: AppColors.text999,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(context.rpx(12)),
                  ),
                ),
                onPressed: _saving ? null : _save,
                child: Text(
                  i18n.t('common.save'),
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

  /// 头像那一行（右侧是头像本身，点一行都能换）
  Widget _avatarRow(BuildContext context, AppI18n i18n, String avatar) =>
      MineListItem(
        label: i18n.t('user.avatar'),
        onTap: _pickAvatar,
        trailingWidget: _uploading
            ? SizedBox(
                width: context.rpx(48),
                height: context.rpx(48),
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : ContactAvatar(url: avatar, circle: true, sizeRpx: 90),
      );

  /// 性别：两个单选（老端是 radio，微信是进二级页，我们保持就地选）
  Widget _genderRow(BuildContext context, AppI18n i18n) => MineListItem(
    label: i18n.t('user.gender'),
    showChevron: false,
    trailingWidget: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final option in genderOptions)
          RadioGroup<int>(
            groupValue: _form.sex,
            onChanged: (value) =>
                setState(() => _form = _form.copyWith(sex: value ?? 0)),
            // 文案也点得到（老端那个 label 整块可点，只留一个小圆点太难按）
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  setState(() => _form = _form.copyWith(sex: option.value)),
              child: Row(
                children: <Widget>[
                  Text(
                    i18n.t(option.labelKey),
                    style: TextStyle(
                      fontSize: context.rpx(32),
                      color: AppColors.text000,
                    ),
                  ),
                  Radio<int>(
                    value: option.value,
                    activeColor: AppColors.wechatGreen,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

/// 可编辑的一行（昵称 / 邮箱 / 个性签名共用）。
///
/// 行尺寸跟 [MineListItem] 走同一组常量：横排的就是标准一行（50dp、右对齐输入），
/// 竖排的（个性签名）标题在上、正文在下 —— 微信那种多行资料也是这么摆的。
///
/// `TextEditingController` 必须由自己的 `State` 拥有并释放：每次 `build` 新建一个
/// 会丢光标位置，而且旧的永远不释放（S5.2 那个「弹窗退场还在用 controller」
/// 的坑之后，这一条已经是项目里的固定写法）。
class _EditableRow extends StatefulWidget {
  const _EditableRow({
    required this.label,
    required this.initialValue,
    required this.placeholder,
    required this.onChanged,
    this.stacked = false,
    this.maxLines = 1,
  });

  final String label;
  final String initialValue;
  final String placeholder;
  final ValueChanged<String> onChanged;

  /// 标题放在上面（个性签名那种），默认是左右一行
  final bool stacked;

  final int maxLines;

  @override
  State<_EditableRow> createState() => _EditableRowState();
}

class _EditableRowState extends State<_EditableRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  TextField get _field => TextField(
    controller: _controller,
    maxLines: widget.maxLines,
    textAlign: widget.stacked ? TextAlign.start : TextAlign.right,
    style: TextStyle(fontSize: context.rpx(32), color: AppColors.text000),
    decoration: InputDecoration(
      isDense: true,
      border: InputBorder.none,
      hintText: widget.placeholder,
      hintStyle: TextStyle(fontSize: context.rpx(32), color: AppColors.text999),
    ),
    onChanged: widget.onChanged,
  );

  @override
  Widget build(BuildContext context) {
    final title = Text(
      widget.label,
      style: TextStyle(fontSize: context.rpx(32), color: AppColors.text000),
    );

    if (widget.stacked) {
      return Container(
        color: AppColors.white,
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(AppDimens.listPadRpx),
          vertical: context.rpx(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            title,
            SizedBox(height: context.rpx(12)),
            _field,
          ],
        ),
      );
    }

    return MineListItem(
      label: widget.label,
      showChevron: false,
      trailingWidget: SizedBox(width: context.rpx(360), child: _field),
    );
  }
}
