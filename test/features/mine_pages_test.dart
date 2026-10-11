import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/config/app_info.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/i18n/locale_controller.dart';
import 'package:gracelinkim/core/media/media_picker.dart';
import 'package:gracelinkim/core/platform/app_uninstaller.dart';
import 'package:gracelinkim/core/platform/app_version.dart';
import 'package:gracelinkim/core/platform/background_health.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/api/update_api.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/data/repo/profile_repository.dart';
import 'package:gracelinkim/domain/mine/profile_form.dart';
import 'package:gracelinkim/features/chat/emoji_manage_page.dart';
import 'package:gracelinkim/features/mine/about_page.dart';
import 'package:gracelinkim/features/mine/account_cancel_page.dart';
import 'package:gracelinkim/features/mine/account_change_page.dart';
import 'package:gracelinkim/features/mine/feature_page.dart';
import 'package:gracelinkim/features/mine/app_update_flow.dart';
import 'package:gracelinkim/features/mine/doc_page.dart';
import 'package:gracelinkim/features/mine/password_change_page.dart';
import 'package:gracelinkim/features/mine/profile_page.dart';
import 'package:gracelinkim/features/mine/secure_page.dart';
import 'package:gracelinkim/features/mine/setting_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 本机版本：测试里读不到安卓那条通道（`PlatformAppVersionSource` 的
/// MethodChannel 在 flutter_tester 里永远不完成，不是抛异常），所以固定一个值。
class _FixedVersionSource implements AppVersionSource {
  const _FixedVersionSource();

  @override
  Future<AppVersionInfo> read() async =>
      const AppVersionInfo(name: '1.0.0', code: 7);
}

/// 一键卸载的假实现（真实现会拉起外部程序、然后 `exit(0)`，测试里跑不得；
/// 宿主机上 App 目录里也没有卸载程序（`unins000.exe` / 老的 `uninstall.exe`），
/// 这一栏默认就不显示）。
class _FakeUninstaller implements AppUninstaller {
  _FakeUninstaller({this.available = true, this.started = true});

  final bool available;
  final bool started;
  int calls = 0;

  @override
  bool get isAvailable => available;

  @override
  Future<bool> uninstall() async {
    calls++;
    return started;
  }
}

/// 「通知权限」那一行要的假后台开关（宿主机不是安卓，真的那个查不到任何东西）。
class _FakeBackgroundHealth implements BackgroundHealth {
  _FakeBackgroundHealth({this.granted = true});

  bool granted;
  int openedSettings = 0;

  @override
  bool get supported => true;

  @override
  Future<bool> notificationGranted() async => granted;

  @override
  Future<bool> ignoringBatteryOptimizations() async => true;

  @override
  Future<bool> openNotificationSettings() async {
    openedSettings++;
    return true;
  }

  @override
  Future<bool> fullScreenIntentAllowed() async => true;

  @override
  Future<bool> openFullScreenIntentSettings() async => true;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => true;
}

class _FakePicker implements MediaPicker {
  _FakePicker({this.images = const <PickedMedia>[]});

  final List<PickedMedia> images;

  @override
  Future<List<PickedMedia>> pickImages({int limit = 9}) async => images;

  @override
  Future<PickedMedia?> pickVideo() async => null;

  @override
  Future<PickedMedia?> pickCamera() async => null;

  @override
  Future<List<PickedMedia>> pickFiles({int limit = 5}) async =>
      const <PickedMedia>[];
}

/// 只实现头像上传的仓库替身（其余方法用不到，抛异常提醒）
class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository({this.avatarUrl = '', this.avatarError});

  final String avatarUrl;
  final ApiException? avatarError;
  final List<String> uploadedPaths = <String>[];

  @override
  Future<String> uploadAvatar(File file) async {
    uploadedPaths.add(file.path);
    if (avatarError != null) throw avatarError!;
    return avatarUrl;
  }

  @override
  Future<UserInfo> updateProfile({
    required UserInfo current,
    required ProfileForm form,
  }) => throw UnimplementedError();

  @override
  Future<String> changePassword(PasswordForm form) =>
      throw UnimplementedError();

  @override
  Future<String> changeAccount(AccountForm form) => throw UnimplementedError();

  @override
  Future<String> cancelAccount({required String password}) =>
      throw UnimplementedError();

  @override
  Future<String> sendCode({
    required String account,
    required bool forPassword,
  }) => throw UnimplementedError();
}

/// 「我的」那一堆页面（S5.5）。
///
/// 跑整个 App：从底部「我的」tab 进，验的是真实链路（头部资料 → 二级页 → 接口）。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ProviderContainer container;
  late StreamSubscription<AppNotice> noticeSub;
  late List<AppNotice> notices;

  const user = UserInfo(
    userId: 'u1',
    account: '13800000000',
    displayName: '张三',
    realName: '张三',
    avatar: '',
    email: 'zhangsan@example.test',
    sex: 1,
    motto: '你好',
    isAuth: 1,
    raw: <String, dynamic>{'user_id': 'u1', 'account': '13800000000'},
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    sessionGuard.update(ready: true, hasSession: true);
    notices = <AppNotice>[];
    noticeSub = noticeBus.stream.listen(notices.add);
  });

  tearDown(() async {
    await noticeSub.cancel();
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  Iterable<String> toasts() =>
      notices.whereType<ToastNotice>().map((notice) => notice.message);

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// 用 AppBar 自带的返回按钮（`pageBack` 找的是英文 tooltip，这套界面是中文）
  Future<void> tapBack(WidgetTester tester) async {
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
  }

  /// 「我」→ 设置（微信把原来平铺在我页上的入口都收进设置里了）
  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
  }

  /// 起 App → 登录 → 切到「我的」tab
  Future<void> pumpMine(
    WidgetTester tester, {
    UserInfo login = user,
    GlobalConfig? config,
    MediaPicker? picker,
    ProfileRepository? profile,
    BackgroundHealth? health,
    AppUninstaller? uninstaller,
    // 桌面行为总开关：测试里默认**关**（`desktopFeaturesEnabled` 认 FLUTTER_TEST），
    // 「功能介绍」按它过滤条目，所以要验电脑端那一份得自己拧开
    bool? desktop,
  }) async {
    // 竖屏高一点：我的那两张卡片在小屏上会把最后一行挤出视口
    tester.view.physicalSize = const Size(1170, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          // 检查更新拉的是那份静态清单，**不走 `ApiClient`**（它自己一条 Dio），
          // 所以这里得把那条 Dio 也接到假 adapter 上，不然会去撞真网络
          updateApiProvider.overrideWithValue(
            UpdateApi(Dio()..httpClientAdapter = adapter),
          ),
          // 检查更新要按平台分流（安卓下载安装 / 其它丢浏览器），
          // 而测试里的 `defaultTargetPlatform` 是宿主机，这里钉死
          targetPlatformProvider.overrideWithValue(TargetPlatform.android),
          appVersionSourceProvider.overrideWithValue(
            const _FixedVersionSource(),
          ),
          if (picker != null) mediaPickerProvider.overrideWithValue(picker),
          if (profile != null)
            profileRepositoryProvider.overrideWithValue(profile),
          // 宿主机不是安卓 → 默认是 `NoopBackgroundHealth`（查不到任何系统开关），
          // 要验「通知权限」那一行就得自己塞一个假的
          if (health != null)
            backgroundHealthProvider.overrideWithValue(health),
          if (uninstaller != null)
            appUninstallerProvider.overrideWithValue(uninstaller),
          if (desktop != null)
            desktopFeaturesProvider.overrideWithValue(desktop),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container.read(sessionStoreProvider.notifier).applyLogin(login);
    if (config != null) {
      container.read(sessionStoreProvider.notifier).applyConfig(config);
    }
    await tester.pumpAndSettle();

    // 底部 tab 按微信写单个「我」字（顶部标题仍是「我的」）
    await tester.tap(find.text('我'));
    await tester.pumpAndSettle();
  }

  /// 企业模式（runMode=1）且不允许自定义名字：昵称只读
  GlobalConfig enterpriseConfig({int diyName = 0}) => GlobalConfig(
    sysInfo: SysInfo(runMode: 1, diyName: diyName, name: '示例IM'),
    chatInfo: const ChatInfo(),
    compass: const CompassConfig(),
    demonMode: false,
  );

  group('我的 tab', () {
    testWidgets('资料卡照微信：昵称、认证标签、恩信号，下面只有表情与设置两块', (tester) async {
      await pumpMine(tester);

      expect(find.text('张三'), findsOneWidget);
      expect(find.text('已认证'), findsOneWidget);
      expect(find.text('恩信号：13800000000'), findsOneWidget);
      // 右上角那颗二维码
      expect(find.byIcon(Icons.qr_code), findsOneWidget);

      expect(find.text('表情'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);

      // 以前平铺在这一页上的那些入口，全部搬进设置页了
      for (final label in <String>['扫 一 扫', '通用设置', '账号安全', '帮助中心', '检查更新']) {
        expect(find.text(label), findsNothing, reason: label);
      }

      await disposeApp(tester);
    });

    testWidgets('未认证时标签是「未认证」', (tester) async {
      await pumpMine(
        tester,
        login: const UserInfo(
          userId: 'u1',
          account: 'u1',
          displayName: '我',
          isAuth: 0,
        ),
      );
      expect(find.text('未认证'), findsOneWidget);
      expect(find.text('已认证'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('「我」页保留状态栏内边距（外壳去掉了，这一页不能去）', (tester) async {
      // 外壳 HomeShell 把顶部内边距从 MediaQuery 里去掉了（上面的导航栏已经吃过
      // 一次，不然列表会重复留白），但「我」页**没有导航栏**，它的资料卡自己用
      // `context.statusBarHeight` 留位 —— 这个例外断了，资料卡就会顶到状态栏上。
      tester.view.padding = const FakeViewPadding(top: 60); // 物理像素：60/3 = 20dp
      await pumpMine(tester);

      final cardContext = tester.element(
        find.byKey(const ValueKey<String>('mineProfileCard')),
      );
      expect(MediaQuery.paddingOf(cardContext).top, 20);

      await disposeApp(tester);
    });

    testWidgets('资料卡的上下留白照微信实测值（顶部 128rpx、整卡 ~420rpx）', (tester) async {
      await pumpMine(tester);

      // 测试视口 390×1000 @3x → 1rpx = 0.52dp；视口无状态栏，所以卡片从 0 开始
      double rpx(double value) => 390 / 750 * value;

      final card = tester.getRect(
        find.byKey(const ValueKey<String>('mineProfileCard')),
      );
      final name = tester.getRect(find.text('张三'));
      final idLine = tester.getRect(find.text('恩信号：13800000000'));
      final pill = tester.getRect(
        find.byKey(const ValueKey<String>('mineAuthPill')),
      );

      expect(card.top, 0, reason: '资料卡是「我」页第一个孩子，从屏幕顶开始画');
      // 微信：状态栏往下 184px（=128rpx）才是头像顶 —— 卡片内容就排在这块留白下面
      expect(
        name.top - card.top,
        closeTo(rpx(128) + rpx(8), rpx(6)),
        reason: '名字与卡片顶的距离 = 那块大留白（128rpx）+ 名字自己的下移（8rpx）',
      );
      // 名字 → 恩信号 → 药丸，三行依次往下
      expect(idLine.top, greaterThan(name.bottom));
      expect(pill.top, greaterThan(idLine.bottom));
      // 药丸高 65px（微信实测）、它下面还有 65px 到卡片底
      expect(pill.height, closeTo(rpx(46), rpx(2)));
      expect(card.bottom - pill.bottom, closeTo(rpx(46), rpx(4)));
      // 除两行字以外全是留白，加起来就是上面那张表里的那几个数（不用管字体行高）
      expect(
        card.height - name.height - idLine.height,
        closeTo(rpx(128 + 8 + 18 + 44 + 46 + 46), rpx(2)),
        reason: '资料卡的高度 / 呼吸感全在这几个间距上',
      );

      await disposeApp(tester);
    });

    testWidgets('卡片上三处都能点：设置、表情、资料卡', (tester) async {
      await pumpMine(tester);

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingPage), findsOneWidget);
      await tapBack(tester);

      await tester.tap(find.text('表情'));
      await tester.pumpAndSettle();
      expect(find.byType(EmojiManagePage), findsOneWidget);
      await tapBack(tester);

      await tester.tap(find.text('张三'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePage), findsOneWidget);

      await disposeApp(tester);
    });
  });

  group('设置页', () {
    testWidgets('按微信分四组，最后一块是单独居中的退出登录', (tester) async {
      await pumpMine(tester);
      await openSettings(tester);

      for (final header in <String>['账号', '通用', '功能', '帮助与关于']) {
        expect(find.text(header), findsOneWidget, reason: header);
      }
      for (final label in <String>[
        '个人资料',
        '账号与安全',
        '通知',
        '界面与显示',
        '音视频通话',
        '帮助中心',
        '退出登录',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // 「关于」那一行右边带版本号（测试环境读不到通道，用常量兜底）
      expect(find.text('关于恩信'), findsOneWidget);
      expect(find.text('版本 1.0.0'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('四行都进得去：个人信息 / 账号与安全 / 帮助中心 / 关于', (tester) async {
      await pumpMine(tester);
      await openSettings(tester);

      await tester.tap(find.text('个人资料'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePage), findsOneWidget);
      await tapBack(tester);

      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();
      expect(find.byType(SecurePage), findsOneWidget);
      await tapBack(tester);

      await tester.tap(find.text('帮助中心'));
      await tester.pumpAndSettle();
      expect(find.byType(DocPage), findsOneWidget);
      await tapBack(tester);

      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('退出登录：确认后清会话（弹窗正文与「退出」键照微信）', (tester) async {
      adapter.ok(AuthPaths.logout, data: null);
      await CredentialStore.instance.saveClientId('cid-1');
      await pumpMine(tester);
      await openSettings(tester);

      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      // 微信那句正文 + 两颗按钮
      expect(find.text('退出后不会删除任何历史数据，下次登录依然可以使用本账号。'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      await tester.tap(find.text('退出'));
      await tester.pumpAndSettle();

      expect(adapter.paths, contains(AuthPaths.logout));
      expect(container.read(sessionStoreProvider).user, isNull);

      await disposeApp(tester);
    });
  });

  group('个人信息页', () {
    testWidgets('字段照登录用户填好，保存发四个字段并更新本地用户', (tester) async {
      adapter.ok(ChatPaths.updateUserInfo, data: null);
      await pumpMine(tester);

      await tester.tap(find.text('张三'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePage), findsOneWidget);

      // 账号只读、昵称可编辑（默认 runMode=2）、邮箱与签名都带出来了
      expect(find.text('账号'), findsOneWidget);
      expect(find.text('13800000000'), findsWidgets);
      expect(find.text('用户名/昵称'), findsOneWidget);
      expect(find.text('e-mail'), findsOneWidget);
      expect(find.text('男'), findsOneWidget);
      expect(find.text('女'), findsOneWidget);

      // 改昵称 + 换成女性
      await tester.enterText(find.byType(TextField).first, '李四');
      await tester.tap(find.text('女'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(adapter.bodyOf(ChatPaths.updateUserInfo), <String, dynamic>{
        'realname': '李四',
        'email': 'zhangsan@example.test',
        'sex': 0,
        'motto': '你好',
      });
      // 本地登录用户跟着换新（老端 `loginStore.login(data)`）
      expect(container.read(sessionStoreProvider).user?.realName, '李四');
      expect(container.read(sessionStoreProvider).user?.sex, 0);
      expect(toasts(), contains('保存成功'));

      await disposeApp(tester);
    });

    testWidgets('昵称清空：提示一句，不打接口', (tester) async {
      adapter.ok(ChatPaths.updateUserInfo, data: null);
      await pumpMine(tester);
      await tester.tap(find.text('张三'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(toasts(), contains('请输入用户名或昵称'));
      expect(adapter.paths, isNot(contains(ChatPaths.updateUserInfo)));

      await disposeApp(tester);
    });

    testWidgets('邮箱乱填：提示「请输入正确的邮箱」', (tester) async {
      adapter.ok(ChatPaths.updateUserInfo, data: null);
      await pumpMine(tester);
      await tester.tap(find.text('张三'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(1), '不是邮箱');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(toasts(), contains('请输入正确的邮箱'));
      expect(adapter.paths, isNot(contains(ChatPaths.updateUserInfo)));

      await disposeApp(tester);
    });

    testWidgets('企业模式且不允许自定义名字：昵称只读', (tester) async {
      await pumpMine(tester, config: enterpriseConfig());
      await tester.tap(find.text('张三'));
      await tester.pumpAndSettle();

      // 标题变成「姓名」，而且没有那个输入框（只剩邮箱与签名两个）
      expect(find.text('姓名'), findsOneWidget);
      expect(find.text('用户名/昵称'), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2));

      await disposeApp(tester);
    });

    testWidgets('这一页没有退出登录（微信也是：退出去设置页）', (tester) async {
      await pumpMine(tester);
      await tester.tap(find.text('张三'));
      await tester.pumpAndSettle();

      expect(find.text('退出登录'), findsNothing);
      expect(find.text('注销登录'), findsNothing);

      await disposeApp(tester);
    });
  });

  testWidgets('换头像：选图后交给仓库上传，本地用户跟着换', (tester) async {
    // 这里换掉的是**仓库**而不是网络层：真实的 `MultipartFile.fromFile` 会去读磁盘，
    // 而 `testWidgets` 的函数体跑在假时钟里，真实文件 I/O 会卡住不返回。
    // 表单与接口参数由 `test/repo/profile_repository_test.dart` 负责验。
    final profile = _FakeProfileRepository(
      avatarUrl: 'https://cdn.test/new-avatar.png',
    );
    final picker = _FakePicker(
      images: const <PickedMedia>[
        PickedMedia(
          path: '/tmp/picked-avatar.png',
          name: 'picked-avatar.png',
          size: 64,
          kind: MediaKind.image,
        ),
      ],
    );

    await pumpMine(tester, picker: picker, profile: profile);
    await tester.tap(find.text('张三'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('头像'));
    // 「上传中」那个转圈一直在动，不能 pumpAndSettle
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if ((container.read(sessionStoreProvider).user?.avatar ?? '')
          .isNotEmpty) {
        break;
      }
    }

    expect(profile.uploadedPaths, <String>['/tmp/picked-avatar.png']);
    expect(toasts(), contains('上传中...'));
    expect(
      container.read(sessionStoreProvider).user?.avatar,
      'https://cdn.test/new-avatar.png',
    );

    await disposeApp(tester);
  });

  testWidgets('换头像：仓库挂了只提示，本地头像不动', (tester) async {
    final profile = _FakeProfileRepository(
      avatarError: const BusinessException(500, '上传失败'),
    );
    final picker = _FakePicker(
      images: const <PickedMedia>[
        PickedMedia(
          path: '/tmp/picked-avatar.png',
          name: 'picked-avatar.png',
          size: 64,
          kind: MediaKind.image,
        ),
      ],
    );

    await pumpMine(tester, picker: picker, profile: profile);
    await tester.tap(find.text('张三'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('头像'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (toasts().contains('上传失败')) break;
    }

    expect(toasts(), contains('上传失败'));
    expect(container.read(sessionStoreProvider).user?.avatar, '');

    await disposeApp(tester);
  });

  group('设置 › 通知', () {
    testWidgets('通知权限那一行在最上面：显示状态、点一下跳系统设置、回来重查', (tester) async {
      final health = _FakeBackgroundHealth(granted: false);
      await pumpMine(tester, health: health);
      await openSettings(tester);
      await tester.tap(find.text('通知'));
      await tester.pumpAndSettle();

      expect(find.text('通知权限'), findsOneWidget);
      expect(find.text('未开启'), findsOneWidget);

      await tester.tap(find.text('通知权限'));
      await tester.pumpAndSettle();
      expect(health.openedSettings, 1, reason: '点一下就是跳系统的应用通知设置');
      expect(find.text('未开启'), findsOneWidget, reason: '还没真开，不许自欺欺人');

      // 用户在那边的开关打开后回到 App
      health.granted = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('已开启'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('声音、震动两个开关默认都开（微信也是），且都会落盘', (tester) async {
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('通知'));
      await tester.pumpAndSettle();

      // 默认：声音开、震动开（微信「新消息通知」里两项都默认开）
      expect(container.read(sessionStoreProvider).setting.voiceStatus, isTrue);
      expect(
        container.read(sessionStoreProvider).setting.vibrateStatus,
        isTrue,
      );

      final switches = find.byType(Switch);
      expect(switches, findsNWidgets(2));

      await tester.tap(switches.at(0)); // 声音关掉
      await tester.pumpAndSettle();
      await tester.tap(switches.at(1)); // 震动也关掉
      await tester.pumpAndSettle();

      final setting = container.read(sessionStoreProvider).setting;
      expect(setting.voiceStatus, isFalse);
      expect(setting.vibrateStatus, isFalse);
      // 落盘了（老端写 storage，新端写 SharedPreferences）
      expect(CredentialStore.instance.appSetting?['voiceStatus'], isFalse);
      expect(CredentialStore.instance.appSetting?['vibrateStatus'], isFalse);

      await disposeApp(tester);
    });
  });

  group('设置 › 界面与显示', () {
    testWidgets('圆形头像落盘', (tester) async {
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('界面与显示'));
      await tester.pumpAndSettle();

      expect(
        container.read(sessionStoreProvider).setting.circleAvatar,
        isFalse,
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(container.read(sessionStoreProvider).setting.circleAvatar, isTrue);
      expect(CredentialStore.instance.appSetting?['circleAvatar'], isTrue);

      await disposeApp(tester);
    });

    testWidgets('切换语言：存下来并换掉界面语言', (tester) async {
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('界面与显示'));
      await tester.pumpAndSettle();

      // 没手动选过时这一行写的是「跟随系统」（2026-10-01 起选择器里最上面那条），
      // 而用例宿主不一定落在中文，所以按当前这档算一遍再断言。
      final current = container.read(localeProvider);
      expect(current.followsSystem, isTrue, reason: '用例里没存过语言');
      expect(
        find.text(AppI18n.instance.t('common.followSystem')),
        findsOneWidget,
      );
      await tester.tap(find.text('切换语言'));
      await tester.pumpAndSettle();

      // 选择器里「跟随系统」+ 7 种语言一个都不能少（少一种就会点到满屏 key）
      final items = LocaleController.pickerItems(AppI18n.instance);
      expect(items.first.code, LocaleController.systemCode);
      for (final option in items) {
        expect(
          find.text(option.label),
          findsAtLeastNWidgets(1),
          reason: '选择器里少了 ${option.code}',
        );
      }

      // 挑一个具体语言（不能挑「跟随系统」—— 那一条是回到自动，不是换语言）：
      // 当前档是宿主算出来的，未必就是简中
      final target = LocaleController.options.firstWhere(
        (option) => option.code != current.code,
      );
      await tester.tap(find.text(target.label));
      await tester.pumpAndSettle();
      // `setLocale` 里有 await：读语言包走的是真实的 asset 读取、存偏好走的是
      // SharedPreferences 那条通道，两者都在真事件循环上完成。`testWidgets`
      // 的 fake-async 推不动它们（`pumpAndSettle` 只把动画走完），得用
      // `runAsync` 放行真异步，再回来断言。
      await tester.runAsync(() async {
        for (var i = 0; i < 200; i++) {
          if (AppI18n.instance.localeCode == target.code &&
              CredentialStore.instance.language == target.code) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      final picked = container.read(localeProvider);
      expect(picked.code, target.code);
      expect(picked.followsSystem, isFalse, reason: '手动选过就不再跟随系统');
      expect(CredentialStore.instance.language, target.code);
      // 界面真的换了：这一页的标题与行名用的是新语言包的词，
      // 右下角那个当前语言也跟着变成新选中的那个。
      expect(AppI18n.instance.localeCode, target.code);
      expect(find.text(AppI18n.instance.t('user.appearance')), findsOneWidget);
      expect(find.text(AppI18n.instance.t('user.language')), findsOneWidget);
      expect(find.text(target.label), findsOneWidget);

      await disposeApp(tester);
    });
  });

  group('注销账号', () {
    testWidgets('入口在「账号与安全」里，进去先把后果写清楚；没填密码点不动', (tester) async {
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('注销账号'));
      await tester.pumpAndSettle();

      expect(find.byType(AccountCancelPage), findsOneWidget);
      expect(find.textContaining('注销后，该账号将无法登录'), findsOneWidget);
      expect(find.text('申请注销'), findsOneWidget);

      // 没填密码：那颗按钮是灰的，点下去什么也不发
      await tester.tap(find.text('申请注销'));
      await tester.pumpAndSettle();
      expect(adapter.paths, isNot(contains(ChatPaths.deleteAccount)));
      expect(find.text('确定要注销账号吗？注销后将无法登录，也无法恢复。'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('填密码 → 二次确认后注销：带上密码、清掉本机会话', (tester) async {
      adapter.ok(ChatPaths.deleteAccount, data: null);
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('注销账号'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hunter2');
      await tester.pumpAndSettle();
      await tester.tap(find.text('申请注销'));
      await tester.pumpAndSettle();

      // 最后一层确认（红按钮）；取消就什么都不发生
      expect(find.text('确定要注销账号吗？注销后将无法登录，也无法恢复。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(adapter.paths, isNot(contains(ChatPaths.deleteAccount)));

      // 再来一次，这回点「注销」
      await tester.tap(find.text('申请注销'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('注销'));
      await tester.pumpAndSettle();

      expect(adapter.paths, contains(ChatPaths.deleteAccount));
      expect(adapter.bodyOf(ChatPaths.deleteAccount), <String, dynamic>{
        'password': 'hunter2',
      });
      // 本机那份会话也要清干净（账号已经不存在了）
      expect(container.read(sessionStoreProvider).user, isNull);

      await disposeApp(tester);
    });
  });

  group('账号与安全页', () {
    testWidgets('这一页没有退出登录（微信只在「设置」最底下那一块退）', (tester) async {
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();

      expect(find.byType(SecurePage), findsOneWidget);
      expect(find.text('退出登录'), findsNothing);
      expect(find.text('注销登录'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('未认证：点「我的账号」只提示；点「认证账户」进换账号页（它不查认证）', (tester) async {
      await pumpMine(
        tester,
        login: const UserInfo(
          userId: 'u1',
          account: 'u1',
          displayName: '我',
          isAuth: 0,
        ),
      );
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();

      expect(find.text('认证账户'), findsOneWidget);
      await tester.tap(find.text('我的账号'));
      await tester.pumpAndSettle();

      expect(toasts(), contains('请先认证账户！'));
      // 没进换账号页：那一页才有的「新邮箱」不出现
      expect(find.byType(AccountChangePage), findsNothing);
      expect(find.text('新邮箱'), findsNothing);

      // 「认证账户」那一行就是来认证的 —— 它必须进得去
      // （以前这里也走同一道校验，于是永远只弹「请先认证账户！」，等于这行是死的）
      await tester.tap(find.text('认证账户'));
      await tester.pumpAndSettle();

      expect(find.byType(AccountChangePage), findsOneWidget);
      // 未认证只有两步：没有原邮箱可以验（老端那个弹层里 `code` 那一栏也是空的）
      expect(find.text('新邮箱'), findsOneWidget);
      expect(find.text('验证账户的真实性，绑定后请使用新账户来登录！'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('未认证：更换账号两步就走完，发出去的 code 是空的', (tester) async {
      adapter.ok(ChatPaths.editAccount, data: null);
      await pumpMine(
        tester,
        login: const UserInfo(
          userId: 'u1',
          account: 'u1',
          displayName: '我',
          isAuth: 0,
        ),
      );
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('认证账户'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'me@example.test');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      expect(find.text('新邮箱验证码'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget, reason: '只有两步：第二步就是最后一步');
      await tester.enterText(find.byType(TextField), '2222');
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(adapter.bodyOf(ChatPaths.editAccount), <String, dynamic>{
        'account': 'me@example.test',
        'code': '',
        'newCode': '2222',
      });

      await disposeApp(tester);
    });

    testWidgets('改密码：三步三个页面，校验拆到各步，最后发三个字段', (tester) async {
      adapter.ok(ChatPaths.editPassword, data: null);
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改密码'));
      await tester.pumpAndSettle();

      ElevatedButton steps() =>
          tester.widget<ElevatedButton>(find.byType(ElevatedButton));

      // 第 1 步：已认证 → 要验证码；没认证那边才有的「原密码」不该出现
      expect(find.byType(PasswordChangePage), findsOneWidget);
      expect(find.text('验证码'), findsOneWidget);
      expect(find.text('原密码'), findsNothing);
      // 空着的时候那颗按钮是灰的（微信也是），点它没反应
      expect(steps().onPressed, isNull);

      await tester.enterText(find.byType(TextField), '9999');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      // 第 2 步：新密码（6-16 位），长度不够就停在这一步
      expect(find.text('新密码'), findsOneWidget);
      expect(find.text('验证码'), findsNothing);
      expect(find.text('下一步'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '123');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(toasts(), contains('请输入6-16位密码'));
      expect(find.text('新密码'), findsOneWidget, reason: '校验不过就停在第 2 步');

      // 返回箭头是**回上一步**，不是退出整页；且填过的东西留着（按钮还是亮的）
      await tapBack(tester);
      expect(find.text('验证码'), findsOneWidget);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('新密码'), findsOneWidget);
      expect(steps().onPressed, isNotNull, reason: '刚才填的 123 还在');
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      // 第 3 步：确认新密码；两次不一致要拦下来
      expect(find.text('确认新密码'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123457');
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(toasts(), contains('两次密码输入不相同！'));
      expect(find.text('确认新密码'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(adapter.bodyOf(ChatPaths.editPassword), <String, dynamic>{
        'password': '123456',
        'code': '9999',
        'originalPassword': '',
      });
      // 提交成功后回「账号与安全」那一页
      expect(find.byType(SecurePage), findsOneWidget);
      expect(find.byType(PasswordChangePage), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('未认证：改密码第一步问的是「原密码」，发的是 originalPassword', (tester) async {
      adapter.ok(ChatPaths.editPassword, data: null);
      await pumpMine(
        tester,
        login: const UserInfo(
          userId: 'u1',
          account: 'u1',
          displayName: '我',
          isAuth: 0,
        ),
      );
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改密码'));
      await tester.pumpAndSettle();

      // 没认证 → 第 1 步是原密码（老端那个 `v-if="!userInfo.is_auth"`）
      expect(find.text('原密码'), findsOneWidget);
      expect(find.text('验证码'), findsNothing);
      expect(find.text('发送验证码'), findsNothing);

      await tester.enterText(find.byType(TextField), 'old-pass');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(adapter.bodyOf(ChatPaths.editPassword), <String, dynamic>{
        'password': '123456',
        'code': '',
        'originalPassword': 'old-pass',
      });

      await disposeApp(tester);
    });

    testWidgets('更换账号：三步三个页面，校验拆到各步，最后发三个字段', (tester) async {
      adapter.ok(ChatPaths.editAccount, data: null);
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的账号'));
      await tester.pumpAndSettle();

      ElevatedButton steps() =>
          tester.widget<ElevatedButton>(find.byType(ElevatedButton));

      // 第 1 步：新邮箱（空着时那颗按钮是灰的）
      expect(find.byType(AccountChangePage), findsOneWidget);
      expect(find.text('新邮箱'), findsOneWidget);
      expect(steps().onPressed, isNull);

      // 不是邮箱就停在这一步
      await tester.enterText(find.byType(TextField), 'no-at-sign');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(toasts(), contains('请输入正确的邮箱'));
      expect(find.text('新邮箱'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'new@example.test');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      // 第 2 步：新邮箱收到的验证码（右侧那颗「发送验证码」就是发给新邮箱的）
      expect(find.text('新邮箱验证码'), findsOneWidget);
      expect(find.text('发送验证码'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '2222');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      // 第 3 步：当前账号的验证码
      expect(find.text('验证码'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '1111');
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(adapter.bodyOf(ChatPaths.editAccount), <String, dynamic>{
        'account': 'new@example.test',
        'code': '1111',
        'newCode': '2222',
      });
      expect(toasts(), contains('修改成功，请重新登陆'));
      // 提交成功后回「账号与安全」那一页
      expect(find.byType(SecurePage), findsOneWidget);
      expect(find.byType(AccountChangePage), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('更换账号第 2 步能发验证码：送新邮箱、type=4，发完变倒计时', (tester) async {
      adapter.ok(AuthPaths.sendCode, data: null);
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的账号'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'new@example.test');
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('发送验证码'));
      // 只推进两帧：倒计时是每秒一跳的定时器，pumpAndSettle 会一路跑到 60 秒后
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.bodyOf(AuthPaths.sendCode), <String, dynamic>{
        'account': 'new@example.test',
        'type': 4,
      });
      expect(find.text('发送验证码'), findsNothing);
      expect(find.textContaining(RegExp(r'\d+s')), findsWidgets);

      await disposeApp(tester);
    });

    testWidgets('改密码第一步能发验证码：送当前账号、type=3，发完变倒计时', (tester) async {
      adapter.ok(AuthPaths.sendCode, data: null);
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('账号与安全'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改密码'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('发送验证码'));
      // 只推进两帧：倒计时是每秒一跳的定时器，pumpAndSettle 会一路跑到 60 秒后
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.bodyOf(AuthPaths.sendCode), <String, dynamic>{
        'account': '13800000000',
        'type': 3,
      });
      // 发完那颗按钮变成倒计时（点不动了）
      expect(find.text('发送验证码'), findsNothing);
      expect(find.textContaining(RegExp(r'\d+s')), findsWidgets);

      await disposeApp(tester);
    });
  });

  group('关于页与帮助中心', () {
    testWidgets('关于页照微信：名称 + 版本 + 三栏（功能介绍 / 投诉 / 版本更新）', (tester) async {
      await pumpMine(tester, config: enterpriseConfig());
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();

      expect(find.byType(AboutPage), findsOneWidget);
      expect(find.text('示例IM'), findsOneWidget);
      expect(find.text('Version 1.0.0'), findsOneWidget);
      // 微信这一页**没有标题**（只有左上角那颗返回箭头）
      expect(find.widgetWithText(AppBar, '关于恩信'), findsNothing);
      // 三栏照微信；老端的「检查更新」改叫微信那个名字
      expect(find.text('功能介绍'), findsOneWidget);
      expect(find.text('投诉'), findsOneWidget);
      expect(find.text('版本更新'), findsOneWidget);
      expect(find.text('检查更新'), findsNothing);
      // 老端那七条特性搬到二级页去了，页脚是新的版权
      expect(find.text('支持一对一音视频通话'), findsNothing);
      expect(find.text('2026 Gracelink Team 版权所有'), findsOneWidget);

      // 「示例IM」是管理员真起过的名字 → 原样显示，只把上游那几个**默认名**
      // （Im / Raingad-IM / gracelinkim）换成 Gracelink（见下一条用例）
      await disposeApp(tester);
    });

    testWidgets('关于页：服务端还报着老端的默认名与旧 logo 时，显示 Gracelink + 随包 logo', (
      tester,
    ) async {
      // 老端那份 `sysInfo` 的默认名就是 `Im`，logo 是它自己的那张网站图
      await pumpMine(
        tester,
        config: GlobalConfig(
          sysInfo: const SysInfo(name: 'Im', logo: '/static/image/logo.png'),
          chatInfo: const ChatInfo(),
          compass: const CompassConfig(),
          demonMode: false,
        ),
      );
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();

      expect(find.text('Gracelink'), findsOneWidget);
      expect(find.text('Im'), findsNothing);
      // logo 固定随包那张：原来会去拉服务端那张旧图（用户：不管服务端配的）
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, AppInfo.logoAsset);

      await disposeApp(tester);
    });

    testWidgets('关于页的骨架照微信实测值：logo 120rpx、列表块左右各缩 44rpx', (tester) async {
      await pumpMine(tester, config: enterpriseConfig());
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();

      // 屏幕宽 390dp → 1rpx = 0.52dp
      final logo = tester.getSize(find.byType(Image));
      expect(logo.width, closeTo(120 / 750 * 390, 0.01));
      expect(logo.height, closeTo(120 / 750 * 390, 0.01));
      // 行首文字 = 块缩进 44rpx + 行内边距 30rpx
      expect(
        tester.getTopLeft(find.text('功能介绍')).dx,
        closeTo(74 / 750 * 390, 0.01),
      );
      // 页脚压在页面底部（微信也是）
      final footer = tester.getCenter(find.text('2026 Gracelink Team 版权所有'));
      expect(footer.dy, greaterThan(tester.getCenter(find.text('版本更新')).dy));

      await disposeApp(tester);
    });

    testWidgets('功能介绍：手机端这一份十一条（按当前语言翻，且没有电脑端专属那条）',
        (tester) async {
      // 十一条纵着排比一屏长，ListView 不构建视口外的行 —— 把视口先拉高，
      // 否则 find.text 只能找到头上那几条
      tester.view.physicalSize = const Size(1170, 12000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('功能介绍'));
      await tester.pumpAndSettle();

      expect(find.byType(FeaturePage), findsOneWidget);
      // 测试里桌面总开关是关的 → 这一屏就是手机端那份
      final keys = aboutFeatureKeysFor(desktop: false);
      expect(keys, hasLength(11));
      for (final key in keys) {
        final text = AppI18n.instance.t(key);
        expect(text, isNot(startsWith('feature.')), reason: '$key 没翻出来');
        expect(find.text(text), findsOneWidget, reason: key);
      }
      // 电脑端专属那条（扫码登录/独立窗口/托盘/安装卸载）不该出现在手机上
      expect(
        find.text(AppI18n.instance.t('feature.item2')),
        findsNothing,
        reason: '托盘/独立窗口这类电脑专属描述不该给手机用户看',
      );
      // 上游那套自建 IM 的卖点也不该再出现在这一页上
      expect(find.textContaining('纯WEB'), findsNothing);
      expect(find.textContaining('自建'), findsNothing);

      // 用例体里就收掉：那个「还有定时器没清」的断言发生在 tearDown 之前
      await disposeApp(tester);
    });

    testWidgets('功能介绍：把桌面总开关拧开就是电脑端那一份（少手机那条，多托盘那条）',
        (tester) async {
      tester.view.physicalSize = const Size(1170, 12000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await pumpMine(tester, desktop: true);
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('功能介绍'));
      await tester.pumpAndSettle();

      expect(find.byType(FeaturePage), findsOneWidget);
      final keys = aboutFeatureKeysFor(desktop: true);
      expect(keys, hasLength(11));
      for (final key in keys) {
        final text = AppI18n.instance.t(key);
        expect(text, isNot(startsWith('feature.')), reason: '$key 没翻出来');
        expect(find.text(text), findsOneWidget, reason: key);
      }
      expect(
        find.text(AppI18n.instance.t('feature.item12')),
        findsNothing,
        reason: '手机端的后台保活那条不该出现在电脑上',
      );

      await disposeApp(tester);
    });

    testWidgets('投诉：只做表面功夫（「提交成功」+ 一个勾）', (tester) async {
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('投诉'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('提交成功'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);

      // 那个过场动画自己会关（1.4 秒）
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('提交成功'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('点「版本更新」：拉那份更新清单，没有新版本就提示', (tester) async {
      // 清单里写的就是本机这一份（`_FixedVersionSource` 报的是 1.0.0+7）
      adapter.responses[updateManifestUrl] = json.encode(<String, dynamic>{
        'android': <String, dynamic>{
          'version': '1.0.0',
          'code': 7,
          'url': 'https://message.gracelink.cc/gracelink-1.0.0.apk',
        },
      });
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('版本更新'));
      await tester.pumpAndSettle();

      // 拉的就是清单那个地址本身（GET，不再上报本机版本）
      expect(adapter.paths, contains(updateManifestUrl));
      expect(toasts(), contains('暂无新版本'));

      await disposeApp(tester);
    });

    testWidgets('关于页：安装版在「版本更新」下面多一栏「卸载恩信」，点了先确认再拉起卸载程序', (
      tester,
    ) async {
      final uninstaller = _FakeUninstaller();
      await pumpMine(tester, uninstaller: uninstaller);
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();

      expect(find.text('卸载恩信'), findsOneWidget);

      await tester.tap(find.text('卸载恩信'));
      await tester.pumpAndSettle();
      // 破坏性动作：先问一句，没点确定之前什么都不动
      expect(
        find.text('确定要卸载恩信吗？卸载后可以重新安装，登录状态与聊天记录会保留。'),
        findsOneWidget,
      );
      expect(uninstaller.calls, 0);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(uninstaller.calls, 1);

      await disposeApp(tester);
    });

    testWidgets('关于页：卸载确认框点「取消」就不动卸载程序', (tester) async {
      final uninstaller = _FakeUninstaller();
      await pumpMine(tester, uninstaller: uninstaller);
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('卸载恩信'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(uninstaller.calls, 0);
      await disposeApp(tester);
    });

    testWidgets('关于页：卸载程序拉不起来就明说（不当成卸完了）', (tester) async {
      final uninstaller = _FakeUninstaller(started: false);
      await pumpMine(tester, uninstaller: uninstaller);
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('卸载恩信'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(uninstaller.calls, 1);
      expect(
        find.text('没能拉起卸载程序，请到系统「设置 → 应用」里卸载，或到安装目录运行其中的卸载程序'),
        findsOneWidget,
      );

      await disposeApp(tester);
    });

    testWidgets('关于页：开发目录里跑（没有卸载程序）不显示「卸载恩信」', (tester) async {
      await pumpMine(
        tester,
        uninstaller: _FakeUninstaller(available: false),
      );
      await openSettings(tester);
      await tester.tap(find.text('关于恩信'));
      await tester.pumpAndSettle();

      expect(find.text('卸载恩信'), findsNothing);
      // 原来那三栏照旧
      expect(find.text('版本更新'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('帮助中心：两条，第一条默认展开', (tester) async {
      await pumpMine(tester);
      await openSettings(tester);
      await tester.tap(find.text('帮助中心'));
      await tester.pumpAndSettle();

      expect(find.text('如何开启手机通知'), findsOneWidget);
      expect(find.text('为什么账号显示为未认证'), findsOneWidget);
      // 第一条默认展开（老端 `:open="item.id==1"`）
      expect(find.textContaining('允许通知'), findsWidgets);
      expect(find.textContaining('未认证状态是无法更改的'), findsNothing);

      await disposeApp(tester);
    });
  });
}
