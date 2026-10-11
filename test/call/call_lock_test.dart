import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/call/call_lock.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';

/// 多端锁（老端 `msgStore.webrtcLock`）的规则，逐条对着 `App.vue` 抄的。
void main() {
  test('一上来没锁', () {
    final lock = CallLock();
    expect(lock.isLocked, isFalse);
    expect(lock.peerId, isNull);
  });

  test('来电时锁成对方的 user_id（老端 `webrtcLock = data.fromUser.user_id`）', () {
    final lock = CallLock()..lockPeer('u2');

    expect(lock.isLocked, isTrue);
    expect(lock.peerId, 'u2');
  });

  test('offer / answer 时锁成「有人在通话」（老端 `webrtcLock = true`，对方 id 丢了）', () {
    final lock = CallLock()..lockAnonymous();

    expect(lock.isLocked, isTrue);
    // 这正是老端那处丢失：锁着，但不知道锁的是谁，所以「对方下线」那条规则匹配不上
    expect(lock.peerId, isNull);
  });

  test('对方下线：只有锁的就是那个人时才解锁', () {
    final lock = CallLock()..lockPeer('u2');

    lock.peerOffline('u3');
    expect(lock.isLocked, isTrue);

    lock.peerOffline('u2');
    expect(lock.isLocked, isFalse);
  });

  test('锁成匿名时对方下线不解锁（老端那个「锁会一直留着」的后果）', () {
    final lock = CallLock()..lockAnonymous();

    lock.peerOffline('u2');
    expect(lock.isLocked, isTrue);
  });

  test('自己那条信令带回 90x 挂断码就解锁（[902,903,905,906,907]）', () {
    for (final code in <int>[902, 903, 905, 906, 907]) {
      final lock = CallLock()..lockPeer('u2');
      lock.ownSignal(code);
      expect(lock.isLocked, isFalse, reason: 'code=$code 应该解锁');
    }
  });

  test('901（发起）与 904（接听）不解锁', () {
    final lock = CallLock()..lockPeer('u2');

    lock.ownSignal(CallCode.dialing);
    expect(lock.isLocked, isTrue);
    lock.ownSignal(CallCode.accept);
    expect(lock.isLocked, isTrue);
  });

  test('手动解锁', () {
    final lock = CallLock()
      ..lockAnonymous()
      ..unlock();

    expect(lock.isLocked, isFalse);
    expect(lock.peerId, isNull);
  });
}
