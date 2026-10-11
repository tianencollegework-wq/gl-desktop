import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/data/model/app_setting.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  SessionStore store() => container.read(sessionStoreProvider.notifier);

  test('没有本地会话时：未登录、未就绪、配置是默认值', () {
    final state = container.read(sessionStoreProvider);
    expect(state.isLoggedIn, isFalse);
    expect(state.ready, isFalse);
    expect(state.config, GlobalConfig.defaults);
    expect(state.setting, AppSetting.defaults);
  });

  test('本地有 token + userInfo 时算已登录（老端启动即自动登录）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      CredentialStore.keyAuthToken: 'token-1',
      CredentialStore.keyUserInfo: '{"user_id":"7","realname":"阿明"}',
    });
    await CredentialStore.init();
    container.dispose();
    container = ProviderContainer();

    final state = container.read(sessionStoreProvider);
    expect(state.isLoggedIn, isTrue);
    expect(state.userId, '7');
    expect(state.user!.name, '阿明');
  });

  test('applyLogin 落盘 token 与用户信息', () async {
    store().applyLogin(
      UserInfo.fromJson(<String, dynamic>{'user_id': '5', 'realname': '小林'}),
      authToken: 'tok-5',
    );
    await Future<void>.delayed(Duration.zero);

    final credentials = CredentialStore.instance;
    expect(credentials.authToken, 'tok-5');
    expect(credentials.userInfo!['user_id'], '5');
    expect(container.read(sessionStoreProvider).isLoggedIn, isTrue);
  });

  test('applyConfig 会写到本地缓存（下次启动先用缓存渲染）', () async {
    store().applyConfig(
      GlobalConfig.fromJson(<String, dynamic>{
        'sysInfo': <String, dynamic>{'name': '站点'},
        'compass': <String, dynamic>{'status': 1},
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(CredentialStore.instance.globalConfig!['sysInfo']['name'], '站点');
    expect(container.read(sessionStoreProvider).config.compassEnabled, isTrue);
  });

  test('markReady 之后守卫才放行', () {
    expect(container.read(sessionStoreProvider).ready, isFalse);
    store().markReady();
    expect(container.read(sessionStoreProvider).ready, isTrue);
  });

  test('clearSession 清会话但保留语言与本地设置', () async {
    store().applyLogin(
      UserInfo.fromJson(<String, dynamic>{'user_id': '5'}),
      authToken: 'tok',
    );
    store().applySetting(const AppSetting(vibrateStatus: true));
    await CredentialStore.instance.saveLanguage('en');
    await Future<void>.delayed(Duration.zero);

    store().clearSession();
    await Future<void>.delayed(Duration.zero);

    final state = container.read(sessionStoreProvider);
    expect(state.isLoggedIn, isFalse);
    expect(CredentialStore.instance.authToken, isNull);
    expect(CredentialStore.instance.userInfo, isNull);
    expect(CredentialStore.instance.language, 'en');
    expect(CredentialStore.instance.appSetting!['vibrateStatus'], isTrue);
  });
}
