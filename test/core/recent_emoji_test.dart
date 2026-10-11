import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/recent_emoji.dart';
import 'package:gracelinkim/core/util/emoji_pack.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 表情面板最左边那一栏（微信也有）。纯本机行为，所以存活规则要自己钉住。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
  });

  test('用过的表情会落盘，重建容器（≈重启 App）后还在', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(recentEmojiProvider), isEmpty);
    await container.read(recentEmojiProvider.notifier).use('😀');

    expect(container.read(recentEmojiProvider), <String>['😀']);
    expect(
      CredentialStore.instance.getString(RecentEmojiNotifier.storageKey),
      '["😀"]',
    );

    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    expect(restarted.read(recentEmojiProvider), <String>['😀']);
  });

  test('重复用一个只提前，不重复插一份', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(recentEmojiProvider.notifier);
    await notifier.use('😀');
    await notifier.use('👍');
    await notifier.use('😀');

    expect(container.read(recentEmojiProvider), <String>['😀', '👍']);
  });

  test('超过上限时把最老的挤出去', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(recentEmojiProvider.notifier);
    for (var index = 0; index < recentEmojiLimit + 5; index++) {
      await notifier.use('表情$index');
    }

    final recent = container.read(recentEmojiProvider);
    expect(recent, hasLength(recentEmojiLimit));
    expect(recent.first, '表情${recentEmojiLimit + 4}');
    expect(recent.contains('表情0'), isFalse);
  });

  test('退出登录清空', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(recentEmojiProvider.notifier);
    await notifier.use('😀');
    await notifier.clearAll();

    expect(container.read(recentEmojiProvider), isEmpty);
  });

  test('存坏了（不是 JSON）当作没有最近使用，不能因此打不开面板', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      RecentEmojiNotifier.storageKey: '这不是 JSON',
    });
    await CredentialStore.init();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(recentEmojiProvider), isEmpty);
  });
}
