import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/global_config.dart';

void main() {
  group('默认值（照抄老端 store/login.js 的 defaultConfig）', () {
    test('空数据落回默认配置', () {
      expect(GlobalConfig.fromJson(null), GlobalConfig.defaults);
      expect(GlobalConfig.fromJson(<String, dynamic>{}), GlobalConfig.defaults);
    });

    test('默认配置的具体值', () {
      const config = GlobalConfig.defaults;
      expect(config.sysInfo.name, 'Im');
      expect(config.sysInfo.regtype, 2);
      expect(config.sysInfo.multipleLogin, 0);
      expect(config.chatInfo.webrtc, 1);
      expect(config.chatInfo.redoTime, 86400);
      expect(config.compass.status, 0);
      expect(config.demonMode, isFalse);
    });
  });

  group('宽松解析（服务端字段类型不统一）', () {
    test('字符串数字、布尔值都能读', () {
      final config = GlobalConfig.fromJson(<String, dynamic>{
        'sysInfo': <String, dynamic>{
          'multipleLogin': '1',
          'regtype': '1',
          'name': '格雷互联',
        },
        'chatInfo': <String, dynamic>{'webrtc': true},
        'compass': <String, dynamic>{'status': 1},
        'demon_mode': 1,
      });

      expect(config.sysInfo.multipleLogin, 1);
      expect(config.multiDeviceLogin, isTrue);
      expect(config.sysInfo.registerOpen, isTrue);
      expect(config.webrtcEnabled, isTrue);
      expect(config.compassEnabled, isTrue);
      expect(config.demonMode, isTrue);
      expect(config.sysInfo.name, '格雷互联');
    });

    test('部分字段缺失时，缺的那部分用默认值补齐', () {
      final config = GlobalConfig.fromJson(<String, dynamic>{
        'sysInfo': <String, dynamic>{'name': 'X'},
        'compass': <String, dynamic>{'status': '1'},
      });

      expect(config.sysInfo.name, 'X');
      expect(config.sysInfo.regtype, 2); // 缺失 → 默认
      expect(config.chatInfo.redoTime, 86400);
      expect(config.compass.status, 1);
      expect(config.compass.mode, 2);
    });

    test('sysInfo 不是对象时也降级到默认值，不抛异常', () {
      final config = GlobalConfig.fromJson(<String, dynamic>{
        'sysInfo': 'oops',
      });
      expect(config.sysInfo, const SysInfo());
    });
  });

  group('序列化', () {
    test('toJson / fromJson 往返不丢开关', () {
      final original = GlobalConfig.fromJson(<String, dynamic>{
        'sysInfo': <String, dynamic>{
          'name': '站点',
          'logo': 'https://cdn.test/logo.png',
          'regtype': 1,
          'multipleLogin': 1,
        },
        'chatInfo': <String, dynamic>{'redoTime': 120},
        'compass': <String, dynamic>{'status': 1},
        'demon_mode': true,
      });

      final restored = GlobalConfig.fromJson(original.toJson());
      expect(restored.sysInfo.name, '站点');
      expect(restored.sysInfo.logo, 'https://cdn.test/logo.png');
      expect(restored.sysInfo.regtype, 1);
      expect(restored.sysInfo.multipleLogin, 1);
      expect(restored.chatInfo.redoTime, 120);
      expect(restored.compass.status, 1);
      expect(restored.demonMode, isTrue);
    });

    test('保留原始 map（服务端可能下发我们还不知道的字段）', () {
      final config = GlobalConfig.fromJson(<String, dynamic>{
        'sysInfo': <String, dynamic>{'name': 'X'},
        'futureField': <String, dynamic>{'a': 1},
      });
      expect(config.raw['futureField'], <String, dynamic>{'a': 1});
    });
  });

  group('发现（compass.list，S7.1）', () {
    test('默认没有入口（`status == 0` 时 tab 都不显示）', () {
      expect(GlobalConfig.defaults.compass.list, isEmpty);
      expect(GlobalConfig.defaults.compass.mode, 2);
    });

    test('解析服务端下发的入口列表', () {
      final config = GlobalConfig.fromJson(<String, dynamic>{
        'compass': <String, dynamic>{
          'status': 1,
          'mode': 1,
          'list': <Map<String, dynamic>>[
            <String, dynamic>{
              'icon': 'https://cdn.test/1.png',
              'name': '朋友圈',
              'url': '/pages/compass/moments',
              'type': 1,
            },
            <String, dynamic>{
              'icon': 'https://cdn.test/2.png',
              'name': '官网',
              'url': 'https://gracelink.cc',
              'type': 2,
              'badge': 5,
            },
          ],
        },
      });

      expect(config.compass.status, 1);
      expect(config.compass.mode, 1);
      expect(config.compass.list.length, 2);
      expect(config.compass.list.first.name, '朋友圈');
      expect(config.compass.list.first.opensWebView, isFalse);
      expect(config.compass.list.last.opensWebView, isTrue);
      expect(config.compass.list.last.hasBadge, isTrue);
      expect(config.compass.list.last.badge, 5);
    });

    test('脏数据（list 里混了字符串、字段缺失）不炸', () {
      final config = GlobalConfig.fromJson(<String, dynamic>{
        'compass': <String, dynamic>{
          'list': <dynamic>[
            'not-a-map',
            <String, dynamic>{'name': '只有名字'},
          ],
        },
      });

      expect(config.compass.list.length, 1);
      expect(config.compass.list.single.name, '只有名字');
      expect(config.compass.list.single.url, isEmpty);
      expect(config.compass.list.single.hasBadge, isFalse);
    });

    test('写回本地再读回来，入口还在（toJson → fromJson）', () {
      const item = CompassItem(
        icon: 'https://cdn.test/1.png',
        name: '朋友圈',
        url: '/pages/compass/moments',
        type: 1,
        badge: 3,
      );
      const config = GlobalConfig.defaults;
      final withCompass = GlobalConfig.fromJson(<String, dynamic>{
        ...config.toJson(),
        'compass': <String, dynamic>{
          'status': 1,
          'mode': 2,
          'list': <Map<String, dynamic>>[item.toJson()],
        },
      });

      final restored = GlobalConfig.fromJson(withCompass.toJson());
      expect(restored.compass.list, <CompassItem>[item]);
    });
  });
}
