/// 会话内「聊天记录」（S5.4）：老端 `pages/message/record.vue`。
///
/// 三件事是纯逻辑，单独放这里：
/// * 顶部那五个分段（全部 / 文本 / 图片 / 视频 / 文件）——服务端 `type` 参数；
/// * 分页（老端用 `uni-pagination`，一页 10 条，`count` 是总条数）；
/// * 「查看上下文」弹层里前后文怎么合并（老端 `viewContext` / `loadContext`）。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../data/model/message.dart';

/// 顶部的一个分段
@immutable
class RecordTab {
  const RecordTab(this.value, this.labelKey);

  /// 提交给服务端的 `type`
  final String value;

  /// 分段文案的 key
  final String labelKey;
}

/// 老端 `tabBars`：`all` / `text` / `image` / `video` / `file`
const List<RecordTab> recordTabs = <RecordTab>[
  RecordTab('all', 'common.all'),
  RecordTab('text', 'common.text'),
  RecordTab('image', 'common.image'),
  RecordTab('video', 'common.video'),
  RecordTab('file', 'common.file'),
];

/// 一页 10 条（老端 `params.limit`）
const int recordPageLimit = 10;

/// 总页数（至少 1 页，界面上的分页条要有个「1」）
int recordPageCount(int total, {int limit = recordPageLimit}) {
  if (limit <= 0) return 1;
  if (total <= 0) return 1;
  return (total + limit - 1) ~/ limit;
}

/// 页码夹在 1..总页数（服务端删了消息之后 `count` 会缩水）
int clampRecordPage(int page, int total, {int limit = recordPageLimit}) =>
    page < 1
    ? 1
    : (page > recordPageCount(total, limit: limit)
          ? recordPageCount(total, limit: limit)
          : page);

/// 上下文弹层里的一批消息怎么并进来。
///
/// 老端 `viewContext(item)`：`direction` 0 是把列表整个换成这一批（从某条消息
/// 打开），1 是「更早」（`unshift` 到前面）、2 是「更晚」（`push` 到后面）；
/// `loadContext(val)` 拿列表一头一尾继续往下拉。
///
/// 与老端不同：**按 `msg_id` 去重**。服务端返回的前后文会带边界那条消息，
/// 老端每点一次「加载更多」就多出一条重复（`v-for` 的 key 是 index，不会报错，
/// 只会看起来像同一条消息发了两次）。
@immutable
class ContextDirection {
  const ContextDirection._(this.value);

  /// 以某条为中心（列表整个换掉）
  static const ContextDirection center = ContextDirection._(0);

  /// 往更早的方向加载
  static const ContextDirection earlier = ContextDirection._(1);

  /// 往更晚的方向加载
  static const ContextDirection later = ContextDirection._(2);

  final int value;

  bool get isEarlier => value == 1;
}

/// 合并前后文（[incoming] 升序）
List<Message> mergeContextMessages(
  List<Message> current,
  List<Message> incoming,
  ContextDirection direction,
) {
  if (direction.value == 0) return List<Message>.unmodifiable(incoming);

  final merged = <Message>[
    if (direction.isEarlier) ...incoming,
    ...current,
    if (!direction.isEarlier) ...incoming,
  ];
  final seen = <String>{};
  final deduped = <Message>[];
  for (final message in merged) {
    // 没 msg_id 的（本地乐观消息）不参与去重，照原样留着
    final key = message.msgId;
    if (key != null && key.isNotEmpty && !seen.add(key)) continue;
    deduped.add(message);
  }
  return List<Message>.unmodifiable(deduped);
}
