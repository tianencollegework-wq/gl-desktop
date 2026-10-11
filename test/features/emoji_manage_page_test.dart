import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/media/media_picker.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/core/util/emoji_pack.dart';
import 'package:gracelinkim/data/repo/emoji_repository.dart';
import 'package:gracelinkim/features/chat/emoji_manage_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 表情管理页（S5.6b，老端 `pages/message/emoji.vue`）。
///
/// 仓库换掉、网络层不进这一层：`MultipartFile.fromFile` 要读磁盘，而 `testWidgets`
/// 跑在假时钟里，真实文件 I/O 会卡住（换头像那批用例踩过）。表单与接口参数由
/// `test/repo/emoji_repository_test.dart` 钉。
void main() {
  late _FakeEmojiRepository repository;
  late _FakePicker picker;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    repository = _FakeEmojiRepository();
    picker = _FakePicker();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emojiRepositoryProvider.overrideWithValue(repository),
          mediaPickerProvider.overrideWithValue(picker),
        ],
        child: const MaterialApp(home: EmojiManagePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder tile(int id) => find.byKey(ValueKey<String>('emoji-$id'));
  final Finder uploadTile = find.byKey(const ValueKey<String>('emoji-upload'));

  testWidgets('标题带数量；点「整理」切多选、再点回「取消」', (tester) async {
    repository.emojis = <CustomEmoji>[
      const CustomEmoji(url: 'https://cdn.test/a.png', id: 11),
      const CustomEmoji(url: 'https://cdn.test/b.png', id: 12),
    ];

    await pumpPage(tester);

    expect(find.text('表情管理（2）'), findsOneWidget);
    expect(tile(11), findsOneWidget);
    expect(tile(12), findsOneWidget);

    await tester.tap(find.text('整理'));
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsOneWidget);
    // 还没选人，底部那两颗不出现
    expect(find.text('移动到最前面'), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('整理'), findsOneWidget);
  });

  testWidgets('多选两个 → 移动到最前：带上两个 id，选完清空', (tester) async {
    repository.emojis = <CustomEmoji>[
      const CustomEmoji(url: 'https://cdn.test/a.png', id: 11),
      const CustomEmoji(url: 'https://cdn.test/b.png', id: 12),
    ];

    await pumpPage(tester);
    await tester.tap(find.text('整理'));
    await tester.pumpAndSettle();

    await tester.tap(tile(11));
    await tester.pumpAndSettle();
    await tester.tap(tile(12));
    await tester.pumpAndSettle();
    expect(find.text('删除(2)'), findsOneWidget);

    await tester.tap(find.text('移动到最前面'));
    await tester.pumpAndSettle();

    expect(repository.moved, <int>[11, 12]);
    // 改完整份重拉一次（老端 `updateEmoji()`）
    expect(repository.listCalls, greaterThan(1));
    expect(find.text('移动到最前面'), findsNothing);
  });

  testWidgets('删除要二次确认；确认后把选中的 id 交出去', (tester) async {
    repository.emojis = <CustomEmoji>[
      const CustomEmoji(url: 'https://cdn.test/a.png', id: 11),
    ];

    await pumpPage(tester);
    await tester.tap(find.text('整理'));
    await tester.pumpAndSettle();
    await tester.tap(tile(11));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除(1)'));
    await tester.pumpAndSettle();
    expect(find.text('确定要删除选中的表情吗'), findsOneWidget);

    // 先点「取消」：什么都不该发生
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(repository.removed, isEmpty);

    await tester.tap(find.text('删除(1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(repository.removed, <int>[11]);
  });

  testWidgets('上传：只传不超 2MB 的，超限那张提示并跳过', (tester) async {
    repository.emojis = <CustomEmoji>[
      const CustomEmoji(url: 'https://cdn.test/a.png', id: 11),
    ];
    picker.images = const <PickedMedia>[
      PickedMedia(
        path: '/tmp/ok.png',
        name: 'ok.png',
        size: 64,
        kind: MediaKind.image,
      ),
      PickedMedia(
        path: '/tmp/huge.png',
        name: 'huge.png',
        size: EmojiManagePage.maxBytes + 1,
        kind: MediaKind.image,
      ),
    ];

    final notices = <AppNotice>[];
    final subscription = noticeBus.stream.listen(notices.add);
    addTearDown(subscription.cancel);

    await pumpPage(tester);
    await tester.tap(uploadTile);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(repository.uploaded, <String>['/tmp/ok.png']);
    expect(
      notices.whereType<ToastNotice>().map((notice) => notice.message),
      containsAll(<String>['上传中...', 'huge.png 不能超过 2MB']),
    );
    // 传完也重拉一次
    expect(repository.listCalls, greaterThan(1));
  });
}

class _FakeEmojiRepository implements EmojiRepository {
  List<CustomEmoji> emojis = <CustomEmoji>[];
  final List<String> uploaded = <String>[];
  final List<int> removed = <int>[];
  final List<int> moved = <int>[];
  int listCalls = 0;

  @override
  Future<List<CustomEmoji>> list() async {
    listCalls++;
    return emojis;
  }

  @override
  Future<void> upload(File file) async => uploaded.add(file.path);

  @override
  Future<void> remove(List<int> ids) async => removed.addAll(ids);

  @override
  Future<void> moveToFront(List<int> ids) async => moved.addAll(ids);
}

class _FakePicker implements MediaPicker {
  List<PickedMedia> images = <PickedMedia>[];

  @override
  Future<List<PickedMedia>> pickImages({int limit = 9}) async => images;

  @override
  Future<PickedMedia?> pickVideo() async => null;

  @override
  Future<PickedMedia?> pickCamera() async => null;

  @override
  Future<List<PickedMedia>> pickFiles({int limit = 5}) async => <PickedMedia>[];
}
