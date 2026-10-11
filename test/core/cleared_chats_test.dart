import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/cleared_chats.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「清空聊天记录」的本地账本（S5.3b）。
///
/// 它要解决的麻烦：服务端**没有**「只清我这边」的接口，历史还在库里；
/// 只删本地的话，用户一进聊天页那页历史又会被拉回来，看起来就是「清空不管用」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    ClearedChatsStore.instance = ClearedChatsStore();
  });

  test('记下来的 id 会被命中（msgId 与 serverId 都算）', () async {
    final store = ClearedChatsStore.instance;
    await store.mark('u9', ids: <String>{'m1', '11'}, lastSendTime: 1758163200);

    expect(store.hides('u9', 'm1'), isTrue);
    expect(store.hides('u9', '11'), isTrue);
    // 没被清掉的消息照常显示（新消息也走这条路）
    expect(store.hides('u9', 'm2'), isFalse);
    // 别的会话不受影响
    expect(store.hides('u8', 'm1'), isFalse);
    // 空 id 一律不算命中（本地乐观消息还没 msgId）
    expect(store.hides('u9', null), isFalse);
    expect(store.hides('u9', ''), isFalse);
  });

  test('预览只在「服务端最后一条正好是被清掉的那条」时抹掉', () async {
    final store = ClearedChatsStore.instance;
    await store.mark('u9', ids: <String>{'m1'}, lastSendTime: 1000);

    expect(store.hidesPreview('u9', 1000), isTrue);
    // 之后又来了新消息：服务端最后一条的 sendTime 变了 → 预览恢复正常
    expect(store.hidesPreview('u9', 2000), isFalse);
    // 没清过的会话 / 没有时间的会话不抹
    expect(store.hidesPreview('u8', 1000), isFalse);
    expect(store.hidesPreview('u9', 0), isFalse);
  });

  test('重启之后还记得（落盘 + reload）', () async {
    await ClearedChatsStore.instance.mark(
      'u9',
      ids: <String>{'m1'},
      lastSendTime: 1000,
    );

    // 模拟重开 App：换一个实例再从本地存储读回来
    ClearedChatsStore.instance = ClearedChatsStore();
    expect(ClearedChatsStore.instance.hides('u9', 'm1'), isFalse);
    ClearedChatsStore.instance.reload();
    expect(ClearedChatsStore.instance.hides('u9', 'm1'), isTrue);
    expect(ClearedChatsStore.instance.hidesPreview('u9', 1000), isTrue);
  });

  test('存坏了不会把界面带崩（当没清空过）', () async {
    await CredentialStore.instance.setString(
      ClearedChatsStore.storageKey,
      '这不是 json',
    );
    ClearedChatsStore.instance.reload();
    expect(ClearedChatsStore.instance.hides('u9', 'm1'), isFalse);
  });

  test('同一个会话清两次是合并（不是覆盖），lastSendTime 取更大的那个', () async {
    final store = ClearedChatsStore.instance;
    await store.mark('u9', ids: <String>{'m1'}, lastSendTime: 1000);
    await store.mark('u9', ids: <String>{'m2'}, lastSendTime: 500);

    expect(store.hides('u9', 'm1'), isTrue);
    expect(store.hides('u9', 'm2'), isTrue);
    // 第二次那批更旧：不能把时间戳往回退，否则旧预览又会冒出来
    expect(store.hidesPreview('u9', 1000), isTrue);
  });

  test('id 记太多会砍掉最老的（上限 maxIdsPerChat）', () async {
    final store = ClearedChatsStore.instance;
    final total = ClearedChatsStore.maxIdsPerChat + 10;
    await store.mark(
      'u9',
      ids: <String>{for (var index = 0; index < total; index++) 'm$index'},
      lastSendTime: 1000,
    );

    // 最老的 10 个被砍了，最新的那条还在
    expect(store.hides('u9', 'm0'), isFalse);
    expect(store.hides('u9', 'm${total - 1}'), isTrue);
  });

  test('退出登录清空', () async {
    final store = ClearedChatsStore.instance;
    await store.mark('u9', ids: <String>{'m1'}, lastSendTime: 1000);
    await store.clearAll();

    expect(store.hides('u9', 'm1'), isFalse);
    // 也真的从盘上删了
    ClearedChatsStore.instance = ClearedChatsStore();
    ClearedChatsStore.instance.reload();
    expect(ClearedChatsStore.instance.hides('u9', 'm1'), isFalse);
  });

  test('每次改动都会推一次 revision（会话列表要重画那行空白预览）', () async {
    final store = ClearedChatsStore.instance;
    final before = store.revision.value;
    await store.mark('u9', ids: <String>{'m1'}, lastSendTime: 1000);
    expect(store.revision.value, greaterThan(before));
  });
}
