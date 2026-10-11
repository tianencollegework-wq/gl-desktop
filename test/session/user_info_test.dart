import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/user_info.dart';

void main() {
  test('user_id 缺失时回落到 id（老端两个写法都出现过）', () {
    expect(UserInfo.fromJson(<String, dynamic>{'user_id': 12}).userId, '12');
    expect(UserInfo.fromJson(<String, dynamic>{'id': 34}).userId, '34');
    expect(UserInfo.fromJson(<String, dynamic>{}).userId, '');
  });

  group('展示名回落链：displayName → realname → account', () {
    test('优先 displayName', () {
      final user = UserInfo.fromJson(<String, dynamic>{
        'displayName': '昵称',
        'realname': '实名',
        'account': '13800000000',
      });
      expect(user.name, '昵称');
    });

    test('displayName 为空串时用 realname，再退到 account', () {
      expect(
        UserInfo.fromJson(<String, dynamic>{
          'displayName': ' ',
          'realname': '实名',
        }).name,
        '实名',
      );
      expect(
        UserInfo.fromJson(<String, dynamic>{'account': '13800000000'}).name,
        '13800000000',
      );
    });

    test('什么都没有时给一个占位名，而不是空串', () {
      expect(UserInfo.fromJson(<String, dynamic>{}).name, '未命名');
    });
  });

  test('宽松字段：sex / is_auth 是字符串也能读', () {
    final user = UserInfo.fromJson(<String, dynamic>{
      'user_id': 1,
      'sex': '1',
      'is_auth': '2',
    });
    expect(user.sex, 1);
    expect(user.isAuth, 2);
  });

  test('toJson 原样回写服务端字段（不能把服务端多给的字段弄丢）', () {
    final raw = <String, dynamic>{
      'user_id': '9',
      'realname': '张三',
      'unknown_field': 'keep-me',
    };
    final user = UserInfo.fromJson(raw);
    expect(user.toJson(), raw);
  });
}
