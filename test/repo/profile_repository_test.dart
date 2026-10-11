import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/auth_api.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/api/upload_api.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/data/repo/profile_repository.dart';
import 'package:gracelinkim/domain/mine/profile_form.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 「我的」的仓库（S5.5）：改资料、换头像、改密码、改账号、发验证码。
///
/// 走真实的 [ChatApi] / [AuthApi] / [UploadApi] + 假 adapter——头像那条尤其
/// 值得走一遍：它的 `data` 是**字符串**（不是对象），用 `dataAsMap` 解析会静默
/// 拿到空 map（S5.5 才发现，所以专门留了一条用例钉住）。
void main() {
  late StubAdapter adapter;
  late ProfileRepository repository;
  late Directory tempDir;

  const user = UserInfo(
    userId: 'u1',
    account: '13800000000',
    displayName: '我',
    realName: '张三',
    email: 'zhangsan@example.test',
    sex: 1,
    motto: '你好',
    isAuth: 1,
    raw: <String, dynamic>{'user_id': 'u1'},
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    adapter = StubAdapter();
    final api = adapter.apiClient();
    repository = ProfileRepository(ChatApi(api), AuthApi(api), UploadApi(api));
    tempDir = await Directory.systemTemp.createTemp('gracelink-avatar');
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException catch (_) {
      // Windows 上刚上传的文件可能还占着句柄，删不掉就算了
    }
  });

  test('保存资料：四个字段发出去，返回合并后的用户', () async {
    adapter.ok(ChatPaths.updateUserInfo, data: null);

    final merged = await repository.updateProfile(
      current: user,
      form: ProfileForm.fromUser(user).copyWith(realName: '李四', sex: 0),
    );

    expect(adapter.bodyOf(ChatPaths.updateUserInfo), <String, dynamic>{
      'realname': '李四',
      'email': 'zhangsan@example.test',
      'sex': 0,
      'motto': '你好',
    });
    expect(merged.realName, '李四');
    expect(merged.sex, 0);
    // 没变的字段原样保留
    expect(merged.avatar, '');
    expect(merged.account, '13800000000');
  });

  test('保存资料失败：抛出去（页面自己提示），本地不用改', () async {
    adapter.fail(ChatPaths.updateUserInfo, msg: '保存炸了');
    expect(
      () => repository.updateProfile(
        current: user,
        form: ProfileForm.fromUser(user),
      ),
      throwsA(isA<Object>()),
    );
  });

  test('头像上传：表单带 file 与 ext=png，返回的 data 就是新地址', () async {
    final file = File('${tempDir.path}/avatar.png')
      ..writeAsBytesSync(List<int>.filled(64, 0));
    adapter.ok(UploadPaths.avatar, data: 'https://cdn.test/new-avatar.png');

    final url = await repository.uploadAvatar(file);

    expect(url, 'https://cdn.test/new-avatar.png');
    final data = adapter.requestTo(UploadPaths.avatar).data;
    expect(data, isA<FormData>());
    final form = data as FormData;
    // 文本字段只有 ext，图片本体在 files 里（字段名 file）
    expect(form.fields.map((entry) => entry.key), <String>['ext']);
    expect(form.fields.firstWhere((entry) => entry.key == 'ext').value, 'png');
    expect(form.files.map((entry) => entry.key), <String>['file']);
  });

  test('头像上传：服务端给对象也给兜底（url 字段）', () async {
    final file = File('${tempDir.path}/avatar2.png')
      ..writeAsBytesSync(List<int>.filled(64, 0));
    adapter.ok(
      UploadPaths.avatar,
      data: <String, dynamic>{'url': 'https://cdn.test/from-map.png'},
    );

    expect(
      await repository.uploadAvatar(file),
      'https://cdn.test/from-map.png',
    );
  });

  test('修改密码：参数三个字段，回执的 msg 带回来', () async {
    adapter.ok(ChatPaths.editPassword, data: null);

    final message = await repository.changePassword(
      const PasswordForm(
        password: '123456',
        code: '9999',
        originalPassword: '',
      ),
    );

    expect(adapter.bodyOf(ChatPaths.editPassword), <String, dynamic>{
      'password': '123456',
      'code': '9999',
      'originalPassword': '',
    });
    expect(message, 'ok'); // StubAdapter 的信封里 msg 就是 'ok'
  });

  test('修改账号：参数三个字段，回执的 msg 带回来', () async {
    adapter.ok(ChatPaths.editAccount, data: null);

    final message = await repository.changeAccount(
      const AccountForm(account: 'a@b.co', code: '1', newCode: '2'),
    );

    expect(adapter.bodyOf(ChatPaths.editAccount), <String, dynamic>{
      'account': 'a@b.co',
      'code': '1',
      'newCode': '2',
    });
    expect(message, 'ok');
  });

  test('发验证码：改密码用 type=3、改账号用 type=4', () async {
    adapter.ok(AuthPaths.sendCode, data: null);

    await repository.sendCode(account: '13800000000', forPassword: true);
    expect(adapter.bodyOf(AuthPaths.sendCode), <String, dynamic>{
      'account': '13800000000',
      'type': 3,
    });

    await repository.sendCode(account: 'a@b.co', forPassword: false);
    expect(adapter.lastBodyOf(AuthPaths.sendCode), <String, dynamic>{
      'account': 'a@b.co',
      'type': 4,
    });
  });

  test('接口失败：抛 ApiException（页面自己弹提示）', () async {
    adapter.fail(ChatPaths.editPassword, msg: '密码不对');
    expect(
      () => repository.changePassword(
        const PasswordForm(password: '123456', repass: '123456'),
      ),
      throwsA(isA<Object>()),
    );
  });
}
