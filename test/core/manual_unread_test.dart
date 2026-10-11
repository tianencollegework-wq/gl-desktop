import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/manual_unread.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「标为未读」的本地名单。
///
/// 这件事在老端和协议里都不存在（纯本机标记），所以它自己的存活规则
/// 只能靠这一份用例钉住：**标了要落盘、重启还在、进会话就消、换账号清空**。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
  });

  test('标为未读会落盘，重建容器（≈重启 App）后还在', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(manualUnreadProvider), isEmpty);
    await container.read(manualUnreadProvider.notifier).mark('u1');

    expect(container.read(manualUnreadProvider), <String>{'u1'});
    expect(
      CredentialStore.instance.getString(ManualUnreadNotifier.storageKey),
      '["u1"]',
    );

    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    expect(restarted.read(manualUnreadProvider), <String>{'u1'});
  });

  test('重复标记同一个会话不会写两遍', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(manualUnreadProvider.notifier);
    await notifier.mark('u1');
    await notifier.mark('u1');

    expect(container.read(manualUnreadProvider), <String>{'u1'});
  });

  test('进会话（clear）之后红点标记就没了', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(manualUnreadProvider.notifier);
    await notifier.mark('u1');
    await notifier.mark('u2');
    await notifier.clear('u1');

    expect(container.read(manualUnreadProvider), <String>{'u2'});
    // 没标过的 id 调 clear 不该出事
    await notifier.clear('没标过');
    expect(container.read(manualUnreadProvider), <String>{'u2'});
  });

  test('退出登录清空', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(manualUnreadProvider.notifier);
    await notifier.mark('u1');
    await notifier.mark('u2');
    await notifier.clearAll();

    expect(container.read(manualUnreadProvider), isEmpty);
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    expect(restarted.read(manualUnreadProvider), isEmpty);
  });

  test('存坏了（不是 JSON）当作没标过，不能因此打不开列表', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ManualUnreadNotifier.storageKey: '这不是 JSON',
    });
    await CredentialStore.init();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(manualUnreadProvider), isEmpty);
  });
}
