import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/net/api_exception.dart';

void main() {
  group('业务码 → 异常（对照老端 utils/request.js）', () {
    test('code 0 是成功', () {
      expect(mapBusinessCode(0, 'ok'), isNull);
      expect(mapBusinessCode(0, null), isNull);
    });

    test('code -1 需要重新登录', () {
      final error = mapBusinessCode(-1, '请先登录');
      expect(error, isA<SessionExpiredException>());
      expect(error!.message, '请先登录');
      expect(error.needsRelogin, isTrue);
    });

    test('老端会弹提示的那批错误码', () {
      for (final code in <int>[400, 401, 402, 403, 404, 405, 500, 502]) {
        final error = mapBusinessCode(code, '出错了');
        expect(error, isA<BusinessException>(), reason: 'code=$code');
        expect((error! as BusinessException).code, code);
        expect(error.shouldToast, isTrue);
      }
    });

    test('其它非 0 码也当成业务失败，并带上码值', () {
      final error = mapBusinessCode(907, null);
      expect(error, isA<BusinessException>());
      expect(error!.message, contains('907'));
      // 907 是通话忙线，属于业务正常范围，不应该触发重登
      expect(error.needsRelogin, isFalse);
    });

    test('没有 msg 时给兜底文案，不出现 null', () {
      expect(mapBusinessCode(-1, '')!.message, isNotEmpty);
      expect(mapBusinessCode(500, null)!.message, isNotEmpty);
    });
  });

  group('异常自身的语义', () {
    test('只有鉴权类异常要求重登', () {
      expect(const UnauthorizedException().needsRelogin, isTrue);
      expect(const SessionExpiredException().needsRelogin, isTrue);
      expect(const BusinessException(500, 'x').needsRelogin, isFalse);
      expect(const ServerException().needsRelogin, isFalse);
      expect(const NetworkUnavailableException().needsRelogin, isFalse);
      expect(const UnknownApiException().needsRelogin, isFalse);
    });
  });
}
