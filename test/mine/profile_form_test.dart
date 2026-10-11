import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/mine/profile_form.dart';

/// 「我的」那几个表单的纯逻辑（S5.5）。
void main() {
  const user = UserInfo(
    userId: 'u1',
    account: '13800000000',
    displayName: '我',
    realName: '张三',
    avatar: 'https://cdn.test/a.png',
    email: 'zhangsan@example.test',
    sex: 1,
    motto: '你好',
    isAuth: 1,
    role: 2,
    raw: <String, dynamic>{'user_id': 'u1', 'token_extra': '别丢'},
  );

  group('资料表单', () {
    test('从登录用户初始化（昵称取 realname，空则用 displayName）', () {
      expect(ProfileForm.fromUser(user).realName, '张三');
      expect(ProfileForm.fromUser(user).email, 'zhangsan@example.test');
      expect(ProfileForm.fromUser(user).sex, 1);
      expect(ProfileForm.fromUser(user).motto, '你好');

      const noRealName = UserInfo(userId: 'u2', displayName: '昵称');
      expect(ProfileForm.fromUser(noRealName).realName, '昵称');
      expect(ProfileForm.fromUser(null).realName, '');
    });

    test('提交给 updateUserInfo 的就四个字段', () {
      final form = ProfileForm.fromUser(user).copyWith(email: 'a@b.co');
      expect(form.payload, <String, Object>{
        'realname': '张三',
        'email': 'a@b.co',
        'sex': 1,
        'motto': '你好',
      });
    });

    test('昵称不能空（空、纯空格都拦）', () {
      expect(
        const ProfileForm(realName: '').validationErrorKey(),
        'user.inputNickname',
      );
      expect(
        const ProfileForm(realName: '   ').validationErrorKey(),
        'user.inputNickname',
      );
      expect(const ProfileForm(realName: '张三').validationErrorKey(), isNull);
    });

    test('邮箱可以空；填了就得像邮箱（老端那个正则）', () {
      expect(
        const ProfileForm(realName: '张三', email: '').validationErrorKey(),
        isNull,
      );
      expect(
        const ProfileForm(
          realName: '张三',
          email: 'not-an-email',
        ).validationErrorKey(),
        'common.correctEmail',
      );
      expect(
        const ProfileForm(realName: '张三', email: 'a@b').validationErrorKey(),
        'common.correctEmail',
      );
      expect(
        const ProfileForm(realName: '张三', email: 'a@b.co').validationErrorKey(),
        isNull,
      );
      expect(
        const ProfileForm(
          realName: '张三',
          email: 'a b@c.co',
        ).validationErrorKey(),
        'common.correctEmail',
      );
    });

    test('保存成功后只换那四个字段，其余（含 raw 里的未知字段）保留', () {
      final form = ProfileForm.fromUser(
        user,
      ).copyWith(realName: '李四', email: 'lisi@example.test', sex: 0);
      final merged = mergeProfile(user, form);

      expect(merged.realName, '李四');
      expect(merged.email, 'lisi@example.test');
      expect(merged.sex, 0);
      // 其余原样
      expect(merged.userId, 'u1');
      expect(merged.account, '13800000000');
      expect(merged.avatar, 'https://cdn.test/a.png');
      expect(merged.isAuth, 1);
      // 老端拿页面里那份副本整个覆盖，会把服务端后来推的字段抹掉；新端不这样
      expect(merged.raw['token_extra'], '别丢');
      expect(merged.toJson()['realname'], '李四');
    });

    test('换头像只动 avatar', () {
      final merged = mergeAvatar(user, 'https://cdn.test/new.png');
      expect(merged.avatar, 'https://cdn.test/new.png');
      expect(merged.realName, '张三');
      expect(merged.raw['avatar'], 'https://cdn.test/new.png');
    });
  });

  group('昵称那一行的可编辑条件', () {
    test('企业模式（runMode=1）且没开自定义名字 → 只读', () {
      expect(nicknameEditable(const SysInfo(runMode: 1, diyName: 0)), isFalse);
      expect(nicknameLabelKey(const SysInfo(runMode: 1)), 'user.realname');
    });

    test('免好友模式（runMode=2）→ 可编辑，标题是「用户名/昵称」', () {
      expect(nicknameEditable(const SysInfo(runMode: 2)), isTrue);
      expect(nicknameLabelKey(const SysInfo(runMode: 2)), 'user.nickname');
    });

    test('企业模式但开了自定义名字（diyName=1）→ 可编辑', () {
      expect(nicknameEditable(const SysInfo(runMode: 1, diyName: 1)), isTrue);
    });
  });

  group('修改密码', () {
    test('已认证先要验证码（老端先判验证码再判密码）', () {
      expect(
        const PasswordForm(
          password: 'abcdef',
          repass: 'abcdef',
        ).validationErrorKey(isAuth: true),
        'user.inputCaptcha',
      );
      expect(
        const PasswordForm(code: '1234').validationErrorKey(isAuth: true),
        'user.passLimit',
      );
    });

    test('6–16 位（5 位、17 位都不行）', () {
      expect(
        const PasswordForm(
          password: '12345',
          repass: '12345',
        ).validationErrorKey(isAuth: false),
        'user.passLimit',
      );
      expect(
        const PasswordForm(
          password: '123456',
          repass: '123456',
        ).validationErrorKey(isAuth: false),
        isNull,
      );
      expect(
        PasswordForm(
          password: '1' * 17,
          repass: '1' * 17,
        ).validationErrorKey(isAuth: false),
        'user.passLimit',
      );
    });

    test('两次要一致', () {
      expect(
        const PasswordForm(
          password: '123456',
          repass: '654321',
        ).validationErrorKey(isAuth: false),
        'user.samePass',
      );
    });

    test('参数就是三个字段', () {
      const form = PasswordForm(
        password: '123456',
        code: '9999',
        originalPassword: 'oldpass',
      );
      expect(form.payload, <String, Object>{
        'password': '123456',
        'code': '9999',
        'originalPassword': 'oldpass',
      });
    });
  });

  group('修改账号', () {
    test('已认证先要验证码，再要新账号与新验证码', () {
      expect(
        const AccountForm(
          account: 'a@b.co',
          newCode: '1111',
        ).validationErrorKey(isAuth: true),
        'user.inputCaptcha',
      );
      expect(
        const AccountForm(
          code: '1111',
          newCode: '2222',
        ).validationErrorKey(isAuth: true),
        'user.inputNewAccount',
      );
      expect(
        const AccountForm(
          code: '1111',
          account: 'a@b.co',
        ).validationErrorKey(isAuth: true),
        'user.inputNaCode',
      );
      expect(
        const AccountForm(
          code: '1111',
          account: 'a@b.co',
          newCode: '2222',
        ).validationErrorKey(isAuth: true),
        isNull,
      );
    });

    test('参数就是三个字段', () {
      const form = AccountForm(account: 'a@b.co', code: '1', newCode: '2');
      expect(form.payload, <String, Object>{
        'account': 'a@b.co',
        'code': '1',
        'newCode': '2',
      });
    });

    test('没认证点「我的账号」只提示，不进弹层', () {
      expect(accountEditErrorKey(isAuth: false), 'user.beforeAuth');
      expect(accountEditErrorKey(isAuth: true), isNull);
    });
  });

  group('杂项', () {
    test('验证码 type：改密码 3、改账号 4（老端那两个值）', () {
      expect(sendCodeType(forPassword: true), 3);
      expect(sendCodeType(forPassword: false), 4);
    });

    test('上传头像带的表单字段是 ext=png', () {
      expect(avatarUploadExtra, <String, String>{'ext': 'png'});
    });

    test('头像地址的解析：字符串直接用，对象取 url/avatar/path', () {
      expect(avatarUrlOf('https://cdn.test/a.png'), 'https://cdn.test/a.png');
      expect(avatarUrlOf(<String, dynamic>{'url': 'u'}), 'u');
      expect(avatarUrlOf(<String, dynamic>{'avatar': 'a'}), 'a');
      expect(avatarUrlOf(<String, dynamic>{'path': 'p'}), 'p');
      expect(avatarUrlOf(null), '');
      expect(avatarUrlOf(<String, dynamic>{}), '');
    });

    test('帮助中心两条、功能介绍十二条（都只存文案 key，并按端过滤）', () {
      expect(helpTopics, hasLength(2));
      // S12.9 起存的是文案 key（7 种语言），不是写死的中文 —— 正文本身
      // 由 `test/features/not_found_and_help_test.dart` 逐份语言包验
      expect(helpTopics[0].titleKey, 'help.notifyTitle');
      expect(helpTopics[0].paragraphKeys, isNotEmpty);
      expect(helpTopics[1].titleKey, 'help.certTitle');
      // 2026-10-10：上游那七条卖点（「纯WEB技术打造」「全部采用自建」…）换成按本软件
      // 实际功能重写的十二条，正文进语言包（`feature.item1` …）。
      expect(aboutFeatures, hasLength(12));
      expect(
        aboutFeatures.map((item) => item.key).toList(),
        <String>[
          'feature.item1',
          'feature.item2',
          'feature.item12',
          'feature.item3',
          'feature.item4',
          'feature.item5',
          'feature.item6',
          'feature.item7',
          'feature.item8',
          'feature.item9',
          'feature.item10',
          'feature.item11',
        ],
        reason: '顺序就是页面上的顺序',
      );
      // 各自只在一种端上显示的两条：item2 是电脑端（扫码登录/独立窗口/托盘），
      // item12 是手机端（后台保活）；其余十条两端共用
      expect(
        aboutFeatures
            .where((item) => item.scope == FeatureScope.desktop)
            .map((item) => item.key),
        <String>['feature.item2'],
      );
      expect(
        aboutFeatures
            .where((item) => item.scope == FeatureScope.mobile)
            .map((item) => item.key),
        <String>['feature.item12'],
      );

      final onDesktop = aboutFeatureKeysFor(desktop: true);
      final onMobile = aboutFeatureKeysFor(desktop: false);
      expect(onDesktop, hasLength(11));
      expect(onMobile, hasLength(11));
      expect(onDesktop, contains('feature.item2'));
      expect(onDesktop, isNot(contains('feature.item12')));
      expect(onMobile, contains('feature.item12'));
      expect(onMobile, isNot(contains('feature.item2')));
      expect(appVersion, isNotEmpty);
    });
  });
}

// 语言清单（老端 `langList()` 的等价物）现在只有一份：`LocaleController.options`
// ——旧的那个 `profile_form.languageOptions()` 没有任何地方在用（只有这条用例
// 在叫它），2026-09-30 删掉了；清单本身由 `test/core/locale_controller_test.dart` 守。
