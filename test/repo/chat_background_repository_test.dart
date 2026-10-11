import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/media/media_picker.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/repo/chat_background_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 聊天背景仓库：选图 → 拷进应用目录 → 写 `chat-bg-info<会话 id>`；
/// 移除时把本地那份文件一起删掉。
///
/// 纯 Dart 测试（不跑组件）：这里的文件拷贝是**真实 I/O**，所以文档目录注入成
/// 一个临时目录，不走 `path_provider` 的平台通道。
void main() {
  late CredentialStore store;
  late Directory docs;
  late _FakePicker picker;
  late ChatBackgroundRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = await CredentialStore.init();
    docs = await Directory.systemTemp.createTemp('chat-bg-test');
    picker = _FakePicker();
    repository = ChatBackgroundRepository(
      store,
      picker,
      documentsDir: () async => docs,
    );
  });

  tearDown(() async {
    if (docs.existsSync()) await docs.delete(recursive: true);
  });

  /// 造一张「相册里的图」给假的 picker 用
  Future<String> sourceImage(String name) async {
    final file = File('${docs.path}/$name');
    await file.writeAsBytes(<int>[1, 2, 3]);
    return file.path;
  }

  test('选一张图：拷进 <文档目录>/chat-bg/，路径写进 chat-bg-info<会话 id>', () async {
    picker.files = <PickedMedia>[
      PickedMedia(
        path: await sourceImage('photo.png'),
        name: 'photo.png',
        size: 3,
        kind: MediaKind.image,
      ),
    ];

    final result = await repository.pickImage('u2');

    expect(result, isNotNull);
    expect(result!.image, '${docs.path}/chat-bg/u2.png');
    expect(File(result.image).existsSync(), isTrue);
    // 老端那个 key 名照抄（值就是路径）
    expect(store.chatBackground('u2').image, result.image);
  });

  test('换背景：旧那份文件会被删掉（不留垃圾）', () async {
    picker.files = <PickedMedia>[
      PickedMedia(
        path: await sourceImage('a.jpg'),
        name: 'a.jpg',
        size: 3,
        kind: MediaKind.image,
      ),
    ];
    await repository.pickImage('u2');
    expect(File('${docs.path}/chat-bg/u2.jpg').existsSync(), isTrue);

    picker.files = <PickedMedia>[
      PickedMedia(
        path: await sourceImage('b.png'),
        name: 'b.png',
        size: 3,
        kind: MediaKind.image,
      ),
    ];
    final result = await repository.pickImage('u2');

    expect(result!.image, '${docs.path}/chat-bg/u2.png');
    expect(File('${docs.path}/chat-bg/u2.jpg').existsSync(), isFalse);
    expect(
      Directory('${docs.path}/chat-bg').listSync().whereType<File>().length,
      1,
    );
  });

  test('别人的背景不会被顺手删掉（id 前缀相同也不行）', () async {
    for (final id in <String>['u1', 'u10']) {
      picker.files = <PickedMedia>[
        PickedMedia(
          path: await sourceImage('$id.png'),
          name: '$id.png',
          size: 3,
          kind: MediaKind.image,
        ),
      ];
      await repository.pickImage(id);
    }

    expect(File('${docs.path}/chat-bg/u1.png').existsSync(), isTrue);
    expect(File('${docs.path}/chat-bg/u10.png').existsSync(), isTrue);
  });

  test('用户取消（没选到东西）：什么都不写', () async {
    picker.files = const <PickedMedia>[];

    expect(await repository.pickImage('u2'), isNull);
    expect(store.chatBackground('u2').image, isEmpty);
  });

  test('选中的文件已经不在了：不写（返回 null）', () async {
    picker.files = <PickedMedia>[
      const PickedMedia(
        path: '/definitely/not/here.png',
        name: 'here.png',
        size: 3,
        kind: MediaKind.image,
      ),
    ];

    expect(await repository.pickImage('u2'), isNull);
    expect(store.chatBackground('u2').image, isEmpty);
  });

  test('会话 id 里的非法字符会换掉（不能写到别的目录去）', () async {
    picker.files = <PickedMedia>[
      PickedMedia(
        path: await sourceImage('c.png'),
        name: 'c.png',
        size: 3,
        kind: MediaKind.image,
      ),
    ];

    final result = await repository.pickImage('a/b:c');

    expect(result!.image, '${docs.path}/chat-bg/a_b_c.png');
  });

  test('移除：清掉路径与文件', () async {
    picker.files = <PickedMedia>[
      PickedMedia(
        path: await sourceImage('d.jpg'),
        name: 'd.jpg',
        size: 3,
        kind: MediaKind.image,
      ),
    ];
    final result = await repository.pickImage('u2');

    await repository.remove('u2');

    expect(store.chatBackground('u2').image, isEmpty);
    expect(File(result!.image).existsSync(), isFalse);
  });

  test('虚化开关：只改 filter，图片路径不动', () async {
    picker.files = <PickedMedia>[
      PickedMedia(
        path: await sourceImage('e.jpg'),
        name: 'e.jpg',
        size: 3,
        kind: MediaKind.image,
      ),
    ];
    final picked = await repository.pickImage('u2');

    await repository.setFilter('u2', true);
    expect(store.chatBackground('u2').filter, isTrue);
    expect(store.chatBackground('u2').image, picked!.image);

    await repository.setFilter('u2', false);
    expect(store.chatBackground('u2').filter, isFalse);
  });

  test('每改一次都会通知（聊天页靠这个即时刷新）', () async {
    var notified = 0;
    repository.revision.addListener(() => notified++);
    picker.files = <PickedMedia>[
      PickedMedia(
        path: await sourceImage('f.jpg'),
        name: 'f.jpg',
        size: 3,
        kind: MediaKind.image,
      ),
    ];

    await repository.pickImage('u2');
    await repository.setFilter('u2', true);
    await repository.remove('u2');

    expect(notified, 3);
  });
}

class _FakePicker implements MediaPicker {
  List<PickedMedia> files = const <PickedMedia>[];

  @override
  Future<List<PickedMedia>> pickImages({int limit = 9}) async => files;

  @override
  Future<PickedMedia?> pickVideo() async => null;

  @override
  Future<PickedMedia?> pickCamera() async => null;

  @override
  Future<List<PickedMedia>> pickFiles({int limit = 5}) async =>
      const <PickedMedia>[];
}
