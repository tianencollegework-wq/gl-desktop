import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/media/media_picker.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/data/repo/message_sender.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 发媒体（S4.4b）：本地文件先乐观显示，再走 `uploadFile` 表单直传。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late MessageSender sender;
  late Directory tempDir;

  const me = UserInfo(
    userId: 'u1',
    displayName: '我',
    raw: <String, dynamic>{'user_id': 'u1', 'displayName': '我'},
  );
  const conversation = Conversation(id: 'u2', displayName: '小明');

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    db = memoryDatabase();
    adapter = StubAdapter();
    sender = MessageSender(db, ChatApi(adapter.apiClient()), Random(3));
    await db.upsertConversation(conversation);
    tempDir = await Directory.systemTemp.createTemp('gracelink-media');
  });

  tearDown(() async {
    await db.close();
    // Windows 上刚上传过的文件可能还占着句柄（Dio 的 MultipartFile 延迟读），
    // 用后即删只为不堆临时文件，删不掉就算了
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException catch (_) {
      // 忽略
    }
  });

  Future<PickedMedia> media({
    MediaKind kind = MediaKind.image,
    String name = 'photo.png',
    int size = 2048,
  }) async {
    final file = File('${tempDir.path}/$name')
      ..writeAsBytesSync(List<int>.filled(size, 0));
    return PickedMedia(path: file.path, name: name, size: size, kind: kind);
  }

  /// 上传请求里的表单（`message` 是 JSON 字符串、`file` 是文件本体）
  Future<FormData> formOf(String path) async {
    final data = adapter.requestTo(path).data;
    expect(data, isA<FormData>());
    return data as FormData;
  }

  Map<String, dynamic> messageField(FormData form) =>
      json.decode(form.fields.firstWhere((e) => e.key == 'message').value)
          as Map<String, dynamic>;

  test('图片：先落库（本地路径）→ 表单直传 → 用服务端地址覆盖', () async {
    final picked = await media();
    adapter.ok(
      UploadPaths.file,
      data: <String, dynamic>{
        'id': 66,
        'msg_id': 'm66',
        'type': 'image',
        'content': 'https://a.test/upload/1.png',
        'sendTime': 1700000000,
        'extends': <String, dynamic>{
          'fixMode': 2,
          'width': 800,
          'height': 1200,
        },
        'fromUser': <String, dynamic>{'id': 'u1', 'displayName': '我'},
      },
    );

    final pending = sender.sendMedia(
      conversation: conversation,
      me: me,
      media: picked,
    );

    // 上传还没回来：本地这条已经在库里，content 是本机路径（界面能立刻显示自己选的图）
    final before = await db.messagesFor('u2');
    expect(before, hasLength(1));
    expect(before.single.type, 'image');
    expect(before.single.content, picked.path);
    expect(before.single.status, MessageStatus.going);
    expect(before.single.extra['fileName'], 'photo.png');
    expect(before.single.extra['fileSize'], 2048);

    final result = await pending;
    expect(result.ok, isTrue);

    // 走的是上传接口，不是 sendMessage
    expect(adapter.paths, contains(UploadPaths.file));
    expect(adapter.paths, isNot(contains(ChatPaths.sendMessage)));

    final form = await formOf(UploadPaths.file);
    expect(form.files, hasLength(1));
    expect(form.files.single.key, 'file');
    expect(form.files.single.value.filename, 'photo.png');

    final message = messageField(form);
    expect(message['type'], 'image');
    expect(message['content'], picked.path);
    expect(message['toContactId'], 'u2');
    expect(message['from_user'], 'u1');
    expect(message['fileName'], 'photo.png');
    expect(message['fileSize'], 2048);

    // 回执把地址与尺寸换成了服务端的
    final after = await db.messagesFor('u2');
    expect(after, hasLength(1));
    expect(after.single.content, 'https://a.test/upload/1.png');
    expect(after.single.msgId, 'm66');
    expect(after.single.status, MessageStatus.sent);
    expect(after.single.ext['fixMode'], 2);
  });

  test('视频：请求体带 extends（时长/尺寸/fixMode/poster）', () async {
    final picked = PickedMedia(
      path: (await media(kind: MediaKind.video, name: 'v.mp4')).path,
      name: 'v.mp4',
      size: 1024,
      kind: MediaKind.video,
      durationSeconds: 12,
      width: 1080,
      height: 1920,
    );
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});

    await sender.sendMedia(conversation: conversation, me: me, media: picked);

    final message = messageField(await formOf(UploadPaths.file));
    expect(message['type'], 'video');
    expect(message['extends'], <String, dynamic>{
      'duration': 12,
      'width': 1080.0,
      'height': 1920.0,
      // 竖屏 → 老端算出来是 2
      'fixMode': 2,
      'poster': '',
    });
  });

  test('文件：type 是 file，请求体带文件名与大小', () async {
    final picked = await media(
      kind: MediaKind.file,
      name: '报表.xlsx',
      size: 4096,
    );
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});

    await sender.sendMedia(conversation: conversation, me: me, media: picked);

    final message = messageField(await formOf(UploadPaths.file));
    expect(message['type'], 'file');
    expect(message['fileName'], '报表.xlsx');
    expect(message['fileSize'], 4096);
  });

  test('上传失败：标红，重发会重新上传本地文件', () async {
    final picked = await media();
    adapter.fail(UploadPaths.file, code: 500, msg: '上传炸了');

    final failed = await sender.sendMedia(
      conversation: conversation,
      me: me,
      media: picked,
    );
    expect(failed.ok, isFalse);
    expect((await db.messagesFor('u2')).single.status, MessageStatus.failed);

    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    final retried = await sender.resend(
      message: failed.message,
      me: me,
      isGroup: 0,
    );

    expect(retried.ok, isTrue);
    expect(
      adapter.paths.where((p) => p == UploadPaths.file),
      hasLength(2),
      reason: '重发要重新上传本地文件（服务端地址还没拿到）',
    );
    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1));
    expect(stored.single.status, MessageStatus.sent);
  });

  test('发完更新会话列表的最后一条（非文本类型）', () async {
    adapter.ok(UploadPaths.file, data: <String, dynamic>{});
    await sender.sendMedia(
      conversation: conversation,
      me: me,
      media: await media(),
    );

    final updated = await db.findConversation('u2');
    expect(updated!.lastType, 'image');
    expect(updated.lastContent, contains('photo.png'));
  });
}
