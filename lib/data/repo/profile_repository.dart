import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mine/profile_form.dart';
import '../api/auth_api.dart';
import '../api/chat_api.dart';
import '../api/upload_api.dart';
import '../model/user_info.dart';

/// 「我的」（S5.5），对应老端 `pages/mine/{profile,secure}.vue` 那几个接口：
/// `updateUserInfo` / `uploadAvatar` / `editPassword` / `editAccount` / `sendCode`。
///
/// **这一层不动会话状态**：改完资料要更新「当前登录用户」，那是 UI 的事
/// （页面把返回的 [UserInfo] 交给 `sessionStore.applyLogin`），
/// 仓库只负责接口与数据形态——与 `ConversationRepository` 只管库一致。
class ProfileRepository {
  ProfileRepository(this._chat, this._auth, this._upload);

  final ChatApi _chat;
  final AuthApi _auth;
  final UploadApi _upload;

  /// 保存资料（老端 `saveInfo`：`{realname, email, sex, motto}`）。
  ///
  /// 返回合并后的用户信息（四个字段换新，其余保留）。
  Future<UserInfo> updateProfile({
    required UserInfo current,
    required ProfileForm form,
  }) async {
    await _chat.updateUserInfo(form.payload);
    return mergeProfile(current, form);
  }

  /// 上传头像，返回新的头像地址。
  ///
  /// 老端的表单字段：`file` 是图片本体、`ext` 写死 `'png'`（裁剪组件固定输出 png）。
  Future<String> uploadAvatar(File file) async {
    final data = await _upload.uploadAvatar(file, extra: avatarUploadExtra);
    return avatarUrlOf(data);
  }

  /// 修改密码（`{password, code, originalPassword}`），返回服务端的 `msg`
  Future<String> changePassword(PasswordForm form) =>
      _chat.editPasswordMessage(form.payload);

  /// 修改账号（`{account, code, newCode}`），返回服务端的 `msg`
  Future<String> changeAccount(AccountForm form) =>
      _chat.editAccountMessage(form.payload);

  /// 注销账号（不可逆），返回服务端的 `msg`。
  ///
  /// 服务端要拿密码当凭据（客户端那层弹窗只是防误触），成功后账号是软删除的：
  /// 同一套账号密码再也登不进来，手里那枚 token 也会被服务端作废。
  Future<String> cancelAccount({required String password}) =>
      _chat.deleteAccountMessage(<String, dynamic>{'password': password});

  /// 发送验证码（`type`：3 改密码、4 改账号），返回服务端的 `msg`
  Future<String> sendCode({
    required String account,
    required bool forPassword,
  }) => _auth.sendCodeMessage(<String, dynamic>{
    'account': account,
    'type': sendCodeType(forPassword: forPassword),
  });
}

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(
    ref.watch(chatApiProvider),
    ref.watch(authApiProvider),
    ref.watch(uploadApiProvider),
  ),
);
