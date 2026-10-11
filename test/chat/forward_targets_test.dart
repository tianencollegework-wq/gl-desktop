import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/chat/forward_targets.dart';

/// 转发候选（S4.5），对照老端 `pages/index/userSelection.vue` 的 type 3 分支。
void main() {
  List<Map<String, dynamic>> friends() => <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'u2',
      'displayName': '小明',
      'avatar': 'https://a.test/2.png',
      'is_group': 0,
      'name_py': 'xiaoming',
    },
    <String, dynamic>{'id': 'sys', 'displayName': '系统通知', 'is_group': 2},
  ];

  List<Map<String, dynamic>> groups() => <Map<String, dynamic>>[
    <String, dynamic>{'id': 'g1', 'displayName': '同学群', 'is_group': 1},
  ];

  test('好友 + 群聊拼起来，当前会话排除掉', () {
    final targets = parseForwardTargets(
      friends: friends(),
      groups: groups(),
      excludeId: 'u2',
    );
    expect(targets.map((t) => t.id), <String>['g1']);
  });

  test('只留好友与群聊（老端过滤 is_group ∈ [0,1,3]，系统会话转发不了）', () {
    final targets = parseForwardTargets(friends: friends(), groups: groups());
    expect(targets.map((t) => t.id), <String>['u2', 'g1']);
    expect(targets[0].isGroupChat, isFalse);
    expect(targets[1].isGroupChat, isTrue);
  });

  test('没有 id 的项跳过', () {
    final targets = parseForwardTargets(
      friends: <Map<String, dynamic>>[
        <String, dynamic>{'displayName': '没有 id'},
      ],
      groups: const <Map<String, dynamic>>[],
    );
    expect(targets, isEmpty);
  });

  test('群聊名字带「（群聊）」后缀（老端 `name += "（群聊）"`）', () {
    final targets = parseForwardTargets(friends: friends(), groups: groups());
    expect(forwardTargetLabel(targets[1], '（群聊）'), '同学群（群聊）');
    expect(forwardTargetLabel(targets[0], '（群聊）'), '小明');
  });

  test('搜索：名字与拼音', () {
    final targets = parseForwardTargets(friends: friends(), groups: groups());
    expect(searchForwardTargets(targets, '小明').single.id, 'u2');
    expect(searchForwardTargets(targets, 'xiaom').single.id, 'u2');
    expect(searchForwardTargets(targets, '  '), targets);
    expect(searchForwardTargets(targets, '不存在'), isEmpty);
  });
}
