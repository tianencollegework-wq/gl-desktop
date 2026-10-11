import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/chat/chat_items.dart';

void main() {
  /// 2026-09-18 10:00:00 本地时间
  final base = DateTime(2026, 9, 18, 10).millisecondsSinceEpoch;
  final now = DateTime(2026, 9, 18, 12);

  Message message(String content, {required int offsetMillis}) => Message(
    serverId: 1,
    conversationId: 'u1',
    content: content,
    fromUserId: 'u2',
    sendTime: base + offsetMillis,
  );

  /// 只认语言包 key 的假翻译（时间格式串里需要 `time.am` / `time.pm` 这些）
  String translate(String key, [Map<String, String>? params]) {
    const strings = <String, String>{
      'time.am': '上午',
      'time.pm': '下午',
      'time.chatToday': '{ap}{h}:{mm}',
      'time.chatDay': '{m}月{d}日 {ap}{h}:{mm}',
      'time.chatYear': '{y}年{m}月{d}日 {ap}{h}:{mm}',
    };
    var text = strings[key] ?? key;
    params?.forEach((name, value) => text = text.replaceAll('{$name}', value));
    return text;
  }

  List<ChatItem> build(
    List<Message> ascending, {
    bool hasMoreHistory = false,
  }) => buildChatItems(
    ascending,
    hasMoreHistory: hasMoreHistory,
    translate: translate,
    now: now,
  );

  group('时间分隔（老端 chat.vue 的 180 秒规则）', () {
    test('没有消息就没有任何项', () {
      expect(build(const <Message>[]), isEmpty);
    });

    test('顺序是新 → 旧（和界面上的 reverse 列表对齐）', () {
      final items = build(<Message>[
        message('早', offsetMillis: 0),
        message('晚', offsetMillis: 60 * 1000),
      ], hasMoreHistory: true);

      expect(items.length, 2);
      expect((items[0] as ChatMessageItem).message.content, '晚');
      expect((items[1] as ChatMessageItem).message.content, '早');
    });

    test('间隔不到 3 分钟：两条消息之间不插时间', () {
      final items = build(<Message>[
        message('早', offsetMillis: 0),
        message('晚', offsetMillis: 60 * 1000),
      ], hasMoreHistory: true);

      expect(items.whereType<ChatTimeItem>(), isEmpty);
    });

    test('间隔超过 3 分钟：在较新的那条上方插一条时间', () {
      final items = build(<Message>[
        message('早', offsetMillis: 0),
        message('晚', offsetMillis: 10 * 60 * 1000),
      ], hasMoreHistory: true);

      expect(items.length, 3);
      expect((items[0] as ChatMessageItem).message.content, '晚');
      expect((items[1] as ChatTimeItem).text, '上午10:10');
      expect((items[2] as ChatMessageItem).message.content, '早');
    });

    test('刚好 180000 毫秒不算间隔（老端是严格大于）', () {
      final items = build(<Message>[
        message('早', offsetMillis: 0),
        message('晚', offsetMillis: 180000),
      ], hasMoreHistory: true);

      expect(items.whereType<ChatTimeItem>(), isEmpty);
    });

    test('历史拉到底：最旧的那条上方再补一条时间', () {
      final items = build(<Message>[
        message('早', offsetMillis: 0),
        message('晚', offsetMillis: 60 * 1000),
      ]);

      expect(items.length, 3);
      expect((items.last as ChatTimeItem).text, '上午10:00');
    });

    test('历史还有：最旧那条上方不补时间', () {
      final items = build(<Message>[
        message('早', offsetMillis: 0),
      ], hasMoreHistory: true);
      expect(items.length, 1);
    });

    test('不是今天的消息显示「月日 + 12 小时制」（微信写法）', () {
      // 昨天 20:00 与昨天 08:00，间隔 12 小时 → 分隔条取较新那条的时间
      final items = build(<Message>[
        message('上午', offsetMillis: -26 * 60 * 60 * 1000),
        message('晚上', offsetMillis: -14 * 60 * 60 * 1000),
      ], hasMoreHistory: true);

      final divider = items.whereType<ChatTimeItem>().single;
      expect(divider.text, '09月17日 下午8:00');
    });
  });
}
