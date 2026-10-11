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

/// 发语音与 @（S4.4c）。
///
/// 语音走的是和图片一样的表单直传（老端 `sendMessage` 里 `voice` 就在
/// `fileTypes` 里），@ 走普通 `sendMessage`。
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
  const group = Conversation(id: 'g1', displayName: '同学群', isGroup: 1);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    db = memoryDatabase();
    adapter = StubAdapter();
    sender = MessageSender(db, ChatApi(adapter.apiClient()), Random(5));
    await db.upsertConversation(group);
    tempDir = await Directory.systemTemp.createTemp('gracelink-voice');
  });

  tearDown(() async {
    await db.close();
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException catch (_) {
      // 忽略：Windows 上文件可能还被占着
    }
  });

  Future<PickedMedia> voice({int seconds = 3, int size = 1024}) async {
    final file = File('${tempDir.path}/gl_voice.m4a')
      ..writeAsBytesSync(List<int>.filled(size, 0));
    return PickedMedia(
      path: file.path,
      name: 'abcd-1234.m4a',
      size: size,
      kind: MediaKind.voice,
      durationSeconds: seconds,
    );
  }

  Map<String, dynamic> messageField(String path) {
    final data = adapter.requestTo(path).data;
    expect(data, isA<FormData>());
    final form = data as FormData;
    return json.decode(form.fields.firstWhere((e) => e.key == 'message').value)
        as Map<String, dynamic>;
  }

  test('语音：先乐观落库（本地路径 + 时长）→ 表单直传 → 服务端地址覆盖', () async {
    final picked = await voice(seconds: 7);
    adapter.ok(
      UploadPaths.file,
      data: <String, dynamic>{
        'id': 88,
        'msg_id': 'm88',
        'type': 'voice',
        'content': 'https://a.test/upload/v.m4a',
        'sendTime': 1700000000000,
        'extends': <String, dynamic>{'duration': 7},
        'fromUser': <String, dynamic>{'id': 'u1', 'displayName': '我'},
      },
    );

    final pending = sender.sendMedia(
      conversation: group,
      me: me,
      media: picked,
    );

    // 上传还没回来：本地这条已经在了，content 是本机路径（能立刻显示自己刚录的）
    final before = await db.messagesFor('g1');
    expect(before, hasLength(1));
    expect(before.single.type, 'voice');
    expect(before.single.content, picked.path);
    expect(before.single.status, MessageStatus.going);
    expect(before.single.ext['duration'], 7);
    expect(before.single.extra['localPath'], picked.path);
    expect(before.single.extra['fileName'], 'abcd-1234.m4a');

    final result = await pending;
    expect(result.ok, isTrue);
    final after = (await db.messagesFor('g1')).single;
    expect(after.content, 'https://a.test/upload/v.m4a', reason: '用服务端地址覆盖');
    expect(after.type, 'voice');
    expect(after.ext['duration'], 7);

    // 请求体：type 是 voice、extends 只有 duration、is_group 是 1
    final body = messageField(UploadPaths.file);
    expect(body['type'], 'voice');
    expect(body['extends'], <String, dynamic>{'duration': 7});
    expect(body['is_group'], 1);
    expect(body['toContactId'], 'g1');
    expect(body['from_user'], 'u1');
    expect(body['fileName'], 'abcd-1234.m4a');
    expect(body['fileSize'], 1024);
  });

  test('语音上传失败：标红，重发会重新上传同一份文件', () async {
    final picked = await voice();
    adapter.fail(UploadPaths.file, code: 500, msg: '炸了');

    final failed = await sender.sendMedia(
      conversation: group,
      me: me,
      media: picked,
    );
    expect(failed.ok, isFalse);
    final stored = (await db.messagesFor('g1')).single;
    expect(stored.status, MessageStatus.failed);
    expect(stored.localId, isNotNull);

    // 服务端恢复后重发：还是同一个上传接口，本地这条被更新（不是插新的）
    adapter.ok(
      UploadPaths.file,
      data: <String, dynamic>{'id': 9, 'msg_id': 'm9'},
    );
    final again = await sender.resend(message: stored, me: me, isGroup: 1);
    expect(again.ok, isTrue);
    final rows = await db.messagesFor('g1');
    expect(rows, hasLength(1));
    expect(rows.single.status, MessageStatus.sent);
  });

  test('文本 @：请求体带 at（老端从富文本 link 节点抓的 user_id 数组）', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});

    await sender.sendText(
      conversation: group,
      me: me,
      content: '@小明 你看这个',
      at: <String>['u3', '0'],
    );

    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['at'], <String>['u3', '0']);
    expect(body['type'], 'text');
    expect(body['is_group'], 1);
    // 本地这条也存了 at（会话列表的「有人提到我」标记要用）
    final stored = (await db.messagesFor('g1')).single;
    expect(stored.at, <String>['u3', '0']);
  });

  test('单聊/没 @ 时不发 at 字段（老端 `if(this.isAt)`）', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await sender.sendText(conversation: group, me: me, content: '普通消息');
    expect(adapter.bodyOf(ChatPaths.sendMessage).containsKey('at'), isFalse);
  });
}
