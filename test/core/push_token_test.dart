import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/push_token.dart';

/// 推送设备标识（S8.1）：`cid` 的形态就是客户端与服务端之间那份契约
/// （`fcm:xxxx` / `getui:xxxx`，后端按前缀分流），所以它必须有单测钉着。
void main() {
  group('PushToken', () {
    test('cid 是「服务商:标识」——后端靠这个前缀分流', () {
      const token = PushToken(provider: 'fcm', token: 'abcdefghijklmn');

      expect(token.cid, 'fcm:abcdefghijklmn');
      expect(token.isValid, isTrue);
    });

    test('空标识不算有效', () {
      expect(const PushToken(provider: 'fcm', token: '').isValid, isFalse);
      expect(const PushToken(provider: '', token: 'x').isValid, isFalse);
    });

    test('日志里只出现前 8 位（完整标识等于一把推送钥匙）', () {
      const token = PushToken(provider: 'fcm', token: 'ABCDEFGHIJKLMNOP');
      const short = 'fcm:ABCDEFGH…';

      expect(token.short, short);
      expect(token.toString(), contains(short));
      expect(token.toString(), isNot(contains('ABCDEFGHIJKLMNOP')));
    });

    test('标识很短时整个显示，不越界', () {
      expect(const PushToken(provider: 'fcm', token: 'abc').short, 'fcm:abc…');
    });
  });

  group('没有推送通道的平台', () {
    test('空实现：拿不到标识，也没有轮换事件', () async {
      const source = NoopPushTokenSource();

      expect(source.supported, isFalse);
      expect(await source.current(), isNull);
      expect(await source.onRefresh.isEmpty, isTrue);
    });

    test('平台默认来源在桌面/测试环境里是空实现', () {
      // 测试跑在主机上（不是 Android/iOS），所以这里就是"没有推送通道"那条路
      expect(defaultPushTokenSource(), isA<NoopPushTokenSource>());
    });
  });
}
