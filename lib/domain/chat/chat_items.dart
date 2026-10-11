import '../../core/util/time_format.dart';
import '../../data/model/message.dart';

/// 聊天页要渲染的一行：要么是一条消息，要么是一条时间分隔。
///
/// 老端把这两者混在同一个数组里（时间分隔是 `type: 'event'` 的假消息，插在
/// `z-paging` 的聊天记录数组里）。新端也用同一招：一个纯函数算出列表，
/// 界面照着画，不用在两处各写一遍插入规则。
sealed class ChatItem {
  const ChatItem();
}

class ChatMessageItem extends ChatItem {
  const ChatMessageItem(this.message);

  final Message message;
}

/// 时间分隔条
class ChatTimeItem extends ChatItem {
  const ChatTimeItem({required this.sendTime, required this.text});

  final int sendTime;
  final String text;
}

/// 两条消息间隔超过这个值就插一条时间分隔（老端在 `chat.vue` 里写死的 180000 毫秒）
const int chatTimeGapMillis = 180000;

/// 把升序的消息列表算成「带时间分隔的显示列表」。
///
/// 规则来自老端两处代码（`queryList` 的加载分支与 `appendTime` 的新消息分支），
/// 新端把它**合并成同一条规则**——它们本来表达的是同一件事
/// （「首条消息上面、以及间隔超过 3 分钟的那条消息上面，都补一条时间」）：
///
/// 1. 每两条相邻消息间隔超过 [chatTimeGapMillis] 时，在**较新的那条**上方插一条时间；
/// 2. 历史已经拉到底时，最旧的那条上方也补一条（老端的分页末页逻辑）。
///
/// 返回的列表顺序是**新 → 旧**（和界面上的 `reverse: true` 列表对齐，下标 0 在最下面），
/// 所以「某条消息上方的分隔」在数组里就是紧跟在它**后面**。
List<ChatItem> buildChatItems(
  List<Message> ascending, {
  required bool hasMoreHistory,
  required Translate translate,
  DateTime? now,
}) {
  if (ascending.isEmpty) return const <ChatItem>[];

  final newestFirst = ascending.reversed.toList();
  final items = <ChatItem>[];

  for (var i = 0; i < newestFirst.length; i++) {
    final current = newestFirst[i];
    items.add(ChatMessageItem(current));

    final older = i + 1 < newestFirst.length ? newestFirst[i + 1] : null;
    if (older != null &&
        current.sendTime - older.sendTime > chatTimeGapMillis) {
      items.add(_timeItem(current.sendTime, now, translate));
    }
  }

  if (!hasMoreHistory) {
    items.add(_timeItem(newestFirst.last.sendTime, now, translate));
  }
  return items;
}

ChatTimeItem _timeItem(int sendTime, DateTime? now, Translate translate) =>
    ChatTimeItem(
      sendTime: sendTime,
      text: hoursTimeFormat(sendTime, now: now, translate: translate),
    );
