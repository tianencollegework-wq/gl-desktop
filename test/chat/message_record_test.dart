import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/chat/message_record.dart';

/// 聊天记录页（S5.4）的纯逻辑：分段、分页、前后文合并。
void main() {
  Message message(int id, {String? msgId}) => Message(
    serverId: id,
    msgId: msgId ?? 'm$id',
    conversationId: 'g1',
    fromUserId: 'u2',
    fromUserName: '小明',
    type: 'text',
    content: '第 $id 条',
    sendTime: DateTime(2026, 9, 18, 10).millisecondsSinceEpoch + id * 1000,
  );

  group('顶部分段', () {
    test('五个分段与老端一致（顺序也是）', () {
      expect(recordTabs.map((tab) => tab.value), <String>[
        'all',
        'text',
        'image',
        'video',
        'file',
      ]);
      expect(recordTabs.map((tab) => tab.labelKey), <String>[
        'common.all',
        'common.text',
        'common.image',
        'common.video',
        'common.file',
      ]);
    });
  });

  group('分页', () {
    test('总页数：一页 10 条，向上取整，至少 1 页', () {
      expect(recordPageCount(0), 1);
      expect(recordPageCount(1), 1);
      expect(recordPageCount(10), 1);
      expect(recordPageCount(11), 2);
      expect(recordPageCount(25), 3);
      // limit 可配（老端写死 10，接口上它是参数）
      expect(recordPageCount(25, limit: 20), 2);
      expect(recordPageCount(5, limit: 0), 1);
    });

    test('页码夹在范围内（服务端删过消息后 count 会缩水）', () {
      expect(clampRecordPage(3, 25), 3);
      expect(clampRecordPage(9, 25), 3);
      expect(clampRecordPage(0, 25), 1);
      expect(clampRecordPage(4, 0), 1);
    });
  });

  group('前后文合并', () {
    test('direction=0：整个换掉（以某条为中心打开）', () {
      final merged = mergeContextMessages(
        <Message>[message(99)],
        <Message>[message(1), message(2)],
        ContextDirection.center,
      );
      expect(merged.map((item) => item.serverId), <int>[1, 2]);
    });

    test('direction=1：更早的插在前面', () {
      final merged = mergeContextMessages(
        <Message>[message(5), message(6)],
        <Message>[message(3), message(4)],
        ContextDirection.earlier,
      );
      expect(merged.map((item) => item.serverId), <int>[3, 4, 5, 6]);
    });

    test('direction=2：更晚的接在后面', () {
      final merged = mergeContextMessages(
        <Message>[message(5), message(6)],
        <Message>[message(7), message(8)],
        ContextDirection.later,
      );
      expect(merged.map((item) => item.serverId), <int>[5, 6, 7, 8]);
    });

    test('按 msg_id 去重：边界那条不会出现两次', () {
      // 服务端返回的前后文会带上边界那条（老端每次「加载更多」都会多一条）
      final merged = mergeContextMessages(
        <Message>[message(5), message(6)],
        <Message>[message(4), message(5)],
        ContextDirection.earlier,
      );
      expect(merged.map((item) => item.serverId), <int>[4, 5, 6]);
    });

    test('没有 msg_id 的（本地乐观消息）不去重，原样留着', () {
      final local1 = Message(
        conversationId: 'g1',
        fromUserId: 'u1',
        type: 'text',
        content: '本地那条',
        sendTime: 1,
      );
      final merged = mergeContextMessages(
        <Message>[local1],
        <Message>[local1],
        ContextDirection.later,
      );
      expect(merged, hasLength(2));
    });

    test('direction 的取值与老端一致：0 中心 / 1 更早 / 2 更晚', () {
      expect(ContextDirection.center.value, 0);
      expect(ContextDirection.earlier.value, 1);
      expect(ContextDirection.later.value, 2);
      expect(ContextDirection.earlier.isEarlier, isTrue);
      expect(ContextDirection.later.isEarlier, isFalse);
    });
  });
}
