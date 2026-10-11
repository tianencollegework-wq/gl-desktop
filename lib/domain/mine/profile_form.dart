/// 「我的」那几个表单的纯逻辑（S5.5），对照老端 `pages/mine/{profile,secure}.vue`。
///
/// 校验规则逐条照抄（包括顺序——老端是先判验证码再判密码，先弹出的提示不一样）：
/// * 资料：昵称不能空（`user.inputNickname`）、邮箱要么不填要么得像个邮箱（`common.correctEmail`）；
/// * 密码：6–16 位（`user.passLimit`）、两次要一致（`user.samePass`）；
/// * 账号：新账号不能空（`user.inputNewAccount`）、新账号验证码不能空（`user.inputNaCode`）；
/// * 已认证（`is_auth`）的账号改密码/改账号都要先填验证码（`user.inputCaptcha`）；
/// * 没认证的账号连「改账号」都点不进去（`user.beforeAuth`）。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../core/util/json_value.dart';
import '../../data/model/global_config.dart';
import '../../data/model/user_info.dart';

/// 老端 `profile.vue` 那个邮箱正则（`/^[^\s@]+@[^\s@]+\.[^\s@]+$/`）
final RegExp emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// 性别选项：1 男 / 0 女（老端 `sexList` 的顺序也是男在前）
const List<({int value, String labelKey})> genderOptions =
    <({int value, String labelKey})>[
      (value: 1, labelKey: 'common.man'),
      (value: 0, labelKey: 'common.women'),
    ];

/// 个人信息表单
@immutable
class ProfileForm {
  const ProfileForm({
    required this.realName,
    this.email = '',
    this.sex = 0,
    this.motto = '',
  });

  final String realName;
  final String email;
  final int sex;
  final String motto;

  /// 从当前登录用户初始化（老端是 `JSON.parse(JSON.stringify(userInfo))` 拿一份副本）
  factory ProfileForm.fromUser(UserInfo? user) => user == null
      ? const ProfileForm(realName: '')
      : ProfileForm(
          realName: user.realName.isNotEmpty ? user.realName : user.displayName,
          email: user.email,
          sex: user.sex,
          motto: user.motto,
        );

  ProfileForm copyWith({
    String? realName,
    String? email,
    int? sex,
    String? motto,
  }) => ProfileForm(
    realName: realName ?? this.realName,
    email: email ?? this.email,
    sex: sex ?? this.sex,
    motto: motto ?? this.motto,
  );

  /// 提交给 `updateUserInfo` 的四个字段（老端就发这四个）
  Map<String, Object> get payload => <String, Object>{
    'realname': realName,
    'email': email,
    'sex': sex,
    'motto': motto,
  };

  /// 校验：返回要提示的文案 key，通过则 null
  String? validationErrorKey() {
    if (realName.trim().isEmpty) return 'user.inputNickname';
    final mail = email.trim();
    if (mail.isNotEmpty && !emailPattern.hasMatch(mail)) {
      return 'common.correctEmail';
    }
    return null;
  }

  @override
  String toString() => 'ProfileForm($realName, $email, sex=$sex)';
}

/// 保存成功后把新的字段合并回登录用户（老端 `loginStore.login(data)`）。
///
/// 只覆盖这四个字段，其余（token、角色、认证状态…）原样保留：
/// 老端其实是用**页面里那份副本**整个覆盖本地用户，那份副本来自登录时的用户信息，
/// 所以服务端后来推的新字段会被它覆盖回去。新端不学这个。
UserInfo mergeProfile(UserInfo current, ProfileForm form) {
  final raw = Map<String, dynamic>.from(current.raw)
    ..['realname'] = form.realName
    ..['email'] = form.email
    ..['sex'] = form.sex
    ..['motto'] = form.motto;
  return UserInfo(
    userId: current.userId,
    account: current.account,
    displayName: current.displayName,
    realName: form.realName,
    avatar: current.avatar,
    mobile: current.mobile,
    email: form.email,
    sex: form.sex,
    motto: form.motto,
    role: current.role,
    isAuth: current.isAuth,
    namePy: current.namePy,
    qrUrl: current.qrUrl,
    raw: raw,
  );
}

/// 上传头像成功后更新本地用户（老端 `this.userInfo.avatar = res.data; login(data)`）
UserInfo mergeAvatar(UserInfo current, String avatar) {
  final raw = Map<String, dynamic>.from(current.raw)..['avatar'] = avatar;
  return UserInfo(
    userId: current.userId,
    account: current.account,
    displayName: current.displayName,
    realName: current.realName,
    avatar: avatar,
    mobile: current.mobile,
    email: current.email,
    sex: current.sex,
    motto: current.motto,
    role: current.role,
    isAuth: current.isAuth,
    namePy: current.namePy,
    qrUrl: current.qrUrl,
    raw: raw,
  );
}

/// 昵称那一行能不能改。
///
/// 老端：企业模式（`runMode == 1`）且不允许自定义名字（`diyName != 1`）时是只读的，
/// 其余情况给输入框。
bool nicknameEditable(SysInfo sysInfo) =>
    sysInfo.runMode != 1 || sysInfo.diyName == 1;

/// 昵称那一行的标题：企业模式叫「姓名」，否则叫「用户名/昵称」
String nicknameLabelKey(SysInfo sysInfo) =>
    sysInfo.runMode == 1 ? 'user.realname' : 'user.nickname';

/// 修改密码表单
@immutable
class PasswordForm {
  const PasswordForm({
    this.code = '',
    this.password = '',
    this.repass = '',
    this.originalPassword = '',
  });

  /// 验证码（已认证的账号必填）
  final String code;

  final String password;
  final String repass;

  /// 原密码（**没认证**的账号才要填，老端那个 `v-if="!userInfo.is_auth"`）
  final String originalPassword;

  PasswordForm copyWith({
    String? code,
    String? password,
    String? repass,
    String? originalPassword,
  }) => PasswordForm(
    code: code ?? this.code,
    password: password ?? this.password,
    repass: repass ?? this.repass,
    originalPassword: originalPassword ?? this.originalPassword,
  );

  /// 校验顺序照老端：先验证码，再长度，再两次一致
  String? validationErrorKey({required bool isAuth}) {
    if (isAuth && code.trim().isEmpty) return 'user.inputCaptcha';
    if (password.length < 6 || password.length > 16) return 'user.passLimit';
    if (password != repass) return 'user.samePass';
    return null;
  }

  Map<String, Object> get payload => <String, Object>{
    'password': password,
    'code': code,
    'originalPassword': originalPassword,
  };
}

/// 修改账号表单
@immutable
class AccountForm {
  const AccountForm({this.account = '', this.code = '', this.newCode = ''});

  /// 新账号
  final String account;

  /// 当前账号的验证码（已认证才有这一栏）
  final String code;

  /// 新账号收到的验证码
  final String newCode;

  AccountForm copyWith({String? account, String? code, String? newCode}) =>
      AccountForm(
        account: account ?? this.account,
        code: code ?? this.code,
        newCode: newCode ?? this.newCode,
      );

  String? validationErrorKey({required bool isAuth}) {
    if (isAuth && code.trim().isEmpty) return 'user.inputCaptcha';
    if (account.trim().isEmpty) return 'user.inputNewAccount';
    if (newCode.trim().isEmpty) return 'user.inputNaCode';
    return null;
  }

  Map<String, Object> get payload => <String, Object>{
    'account': account,
    'code': code,
    'newCode': newCode,
  };
}

/// 「我的账号」那一行点了之后：没认证先提示，别让他进弹层
String? accountEditErrorKey({required bool isAuth}) =>
    isAuth ? null : 'user.beforeAuth';

/// `sendCode` 的 `type`：3 改密码、4 改账号（老端 `secure.vue` 里那两个值）
int sendCodeType({required bool forPassword}) => forPassword ? 3 : 4;

/// 版本号：老端读的是 `plus.runtime.getProperty`（打包时注入的 version）。
///
/// 新端先写死常量（`pubspec.yaml` 的 version 是它，两处一起改），
/// 等 S7.2 做「检查更新」时再换成运行时读包信息。
const String appVersion = '1.0.0';

/// 「关于 → 功能介绍」那一条的适用范围。
///
/// 手机端与电脑端是**同一页**（都是「我 → 设置 → 关于 → 功能介绍」），
/// 但有些话只对其中一端成立：电脑端的「关掉窗口会缩到托盘」在手机上不存在，
/// 手机端的「退到后台保活」在电脑上也是另一套说法。
/// 用户 2026-10-10：「让功能介绍按平台显示各自特有的条目（手机端不出现托盘/独立窗口
/// 这类电脑专属描述）」。
enum FeatureScope {
  /// 两端都显示
  both,

  /// 只有电脑端显示
  desktop,

  /// 只有手机端显示
  mobile,
}

/// 功能介绍里的一条：文案 key + 适用范围。
@immutable
class FeatureItem {
  const FeatureItem(this.key, [this.scope = FeatureScope.both]);

  /// 文案 key（`feature.item*`，7 种语言都在语言包里）
  final String key;

  /// 这一条在哪些端上显示
  final FeatureScope scope;

  /// 当前这一端要不要显示它（[desktop] 由 `desktopFeaturesProvider` 给）
  bool showsOn({required bool desktop}) => switch (scope) {
    FeatureScope.both => true,
    FeatureScope.desktop => desktop,
    FeatureScope.mobile => !desktop,
  };
}

/// 「关于 → 功能介绍」的全部条目，**顺序就是页面上的顺序**。
///
/// 老端 `about.vue` 里写死了七条，内容是**上游那套自建 IM 的卖点**
/// （「纯WEB技术打造，不依赖任何三方服务」「全部采用自建，数据掌握在自己手上」
/// 「可快速建立企业内部通讯系统」…）。用户 2026-10-10 要求按本软件实际重写：
/// 我们对上游做了大量改动（群组多人通话与屏幕共享、扫码登录、托盘与独立窗口、
/// 灵听/媒体号、多账号、后台保活、多语言…），技术架构也不同（Flutter 原生客户端，
/// 不是 uniapp 那套），原话在界面上已经不成立了。
///
/// 与新版九节安装协议同一套口径：这是官方服务的客户端，不是自托管。
///
/// 存 key 而不是文案：正文也是界面的一部分，7 种语言在语言包里
/// （`feature.*`），由 `features/mine/feature_page.dart` 渲染时翻。
///
/// 两端的差异只有两条，都摆在前面（各归各的端）：`feature.item2` 是电脑端的
/// （扫码登录 / 独立窗口 / 托盘 / 安装卸载），`feature.item12` 是手机端的
/// （后台保活与系统限制提示）。其余十条两端共用 —— 所以 key 的编号不等于
/// 手机端看到的位置，页面按这张表过滤后再排。
const List<FeatureItem> aboutFeatures = <FeatureItem>[
  FeatureItem('feature.item1'),
  FeatureItem('feature.item2', FeatureScope.desktop),
  FeatureItem('feature.item12', FeatureScope.mobile),
  FeatureItem('feature.item3'),
  FeatureItem('feature.item4'),
  FeatureItem('feature.item5'),
  FeatureItem('feature.item6'),
  FeatureItem('feature.item7'),
  FeatureItem('feature.item8'),
  FeatureItem('feature.item9'),
  FeatureItem('feature.item10'),
  FeatureItem('feature.item11'),
];

/// 当前这一端该显示的文案 key（电脑端少手机那条，手机端少电脑那条）。
List<String> aboutFeatureKeysFor({required bool desktop}) => <String>[
  for (final item in aboutFeatures)
    if (item.showsOn(desktop: desktop)) item.key,
];

/// 帮助中心的两条（老端 `doc.vue` 里写死的，内容是纯文本，新端不用 rich-text）
@immutable
class HelpTopic {
  const HelpTopic({required this.titleKey, required this.paragraphKeys});

  /// 标题的文案 key
  final String titleKey;

  /// 段落的文案 key（老端是一段富文本 HTML，这里拆成几段纯文本）
  ///
  /// 存 key 而不是文案：S12.9 起有 7 种语言，正文也是界面的一部分，
  /// 写死中文的话切到日语/西语这一页还是中文。正文在语言包里，
  /// 由 `features/mine/doc_page.dart` 渲染时翻（`help.*` 开头那几条）。
  final List<String> paragraphKeys;
}

const List<HelpTopic> helpTopics = <HelpTopic>[
  HelpTopic(
    titleKey: 'help.notifyTitle',
    paragraphKeys: <String>[
      'help.notifyP1',
      'help.notifyP2',
      'help.notifyP3',
      'help.notifyP4',
      'help.notifyP5',
      'help.notifyP6',
    ],
  ),
  HelpTopic(titleKey: 'help.certTitle', paragraphKeys: <String>['help.certP1']),
];

/// 头像上传时老端带的那个表单字段（`formData: {ext: 'png'}`）
const Map<String, String> avatarUploadExtra = <String, String>{'ext': 'png'};

/// 把接口返回的头像地址取出来（`data` 直接就是 URL；万一服务端换成对象也给兜底）
String avatarUrlOf(Object? data) {
  if (data is String) return data;
  final map = asMap(data);
  return asText(map['url'] ?? map['avatar'] ?? map['path']);
}
