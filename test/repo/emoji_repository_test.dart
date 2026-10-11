import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/emoji_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/api/upload_api.dart';
import 'package:gracelinkim/data/repo/emoji_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 收藏表情的仓库（S5.6b）：列表、上传、删除、移到最前。
///
/// 走真实的 [EmojiApi] / [UploadApi] + 假 adapter：这几条接口的参数名
/// （`ids`、上传的字段名 `file`）就是最容易写错的地方。
void main() {
  late StubAdapter adapter;
  late EmojiRepository repository;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    adapter = StubAdapter();
    final api = adapter.apiClient();
    repository = EmojiRepository(EmojiApi(api), UploadApi(api));
    tempDir = await Directory.systemTemp.createTemp('gracelink-emoji');
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException catch (_) {
      // Windows 上刚上传的文件可能还占着句柄，删不掉就算了
    }
  });

  test('列表：data 是数组，id / file_id / src 都取到', () async {
    adapter.ok(
      EmojiPaths.list,
      data: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 11,
          'file_id': 7,
          'src': 'https://cdn.test/e1.png',
        },
        // 没有地址的那条要丢掉（面板画不出来，老端会画出个空框）
        <String, dynamic>{'id': 12, 'file_id': 8, 'src': ''},
        <String, dynamic>{
          'id': 13,
          'file_id': 9,
          'src': 'https://cdn.test/e3.png',
        },
      ],
    );

    final list = await repository.list();

    expect(adapter.bodyOf(EmojiPaths.list), isEmpty);
    expect(list.length, 2);
    expect(list.first.id, 11);
    expect(list.first.fileId, 7);
    expect(list.first.url, 'https://cdn.test/e1.png');
    expect(list.last.url, 'https://cdn.test/e3.png');
  });

  test('删除：参数是 ids（表情记录 id，不是 file_id）', () async {
    adapter.ok(EmojiPaths.del, data: null);

    await repository.remove(<int>[11, 13]);

    expect(adapter.bodyOf(EmojiPaths.del), <String, dynamic>{
      'ids': <int>[11, 13],
    });
  });

  test('移到最前：参数是 ids', () async {
    adapter.ok(EmojiPaths.move, data: null);

    await repository.moveToFront(<int>[12]);

    expect(adapter.bodyOf(EmojiPaths.move), <String, dynamic>{
      'ids': <int>[12],
    });
  });

  test('上传：表单字段名是 file（老端 uni.uploadFile 的 name）', () async {
    final file = File('${tempDir.path}/e1.png')
      ..writeAsBytesSync(List<int>.filled(64, 0));
    adapter.ok(UploadPaths.emoji, data: null);

    await repository.upload(file);

    final data = adapter.requestTo(UploadPaths.emoji).data;
    expect(data, isA<FormData>());
    expect((data as FormData).files.map((entry) => entry.key), <String>[
      'file',
    ]);
  });

  test('接口失败直接把异常抛出去（页面负责提示与不刷新）', () async {
    adapter.fail(EmojiPaths.del, code: 400, msg: '删除失败');

    await expectLater(() => repository.remove(<int>[11]), throwsA(anything));
  });
}
