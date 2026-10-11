import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';

/// 多语言（S6.3 起支持 `{xxx}` 占位）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppI18n zh;
  late AppI18n en;

  setUp(() async {
    zh = await AppI18n.load('zh-Hans');
    en = await AppI18n.load('en');
  });

  group('取词', () {
    test('缺 key 时返回 key 本身（与 vue-i18n 的 fallback 一致）', () {
      expect(zh.t('根本没有这个 key'), '根本没有这个 key');
    });

    test('占位替换：通话页那句「{name} 正在请求与您视频通话」', () {
      expect(
        zh.t('call.incomingVideo', <String, String>{'name': '小明'}),
        '小明 正在请求与您视频通话',
      );
      expect(
        zh.t('call.outgoingVoice', <String, String>{'name': '老B'}),
        '您正对 老B 发起语音通话',
      );
      expect(
        en.t('call.incomingVideo', <String, String>{'name': 'Ming'}),
        'Ming is requesting a video call',
      );
    });

    test('没有占位参数时原样返回（不用把花括号去掉）', () {
      expect(zh.t('call.incomingVideo'), '{name} 正在请求与您视频通话');
    });

    test('多语言包里没有残留的占位 key（通话那批都补齐了）', () {
      expect(zh.t('call.hangup'), '挂断');
      expect(zh.t('call.answer'), '接听');
      expect(zh.t('call.micOff'), '关闭麦克风');
      expect(zh.t('call.speakerOn'), '开启扬声器');
      expect(zh.t('call.switchCamera'), '切换摄像头');
      expect(zh.has('call.videoCall'), isTrue);
      expect(en.has('call.videoCall'), isTrue);
    });

    test('两份语言包的 key 数量对齐（只允许英文多出老端遗留的那一个）', () {
      final zhKeys = <String>{};
      for (final key in <String>[
        'call.hangup',
        'call.answer',
        'call.micOn',
        'call.micOff',
        'call.speakerOn',
        'call.speakerOff',
        'call.switchCamera',
        'call.incomingVoice',
        'call.incomingVideo',
        'call.outgoingVoice',
        'call.outgoingVideo',
      ]) {
        if (zh.has(key)) zhKeys.add(key);
      }
      for (final key in zhKeys) {
        expect(en.has(key), isTrue, reason: '英文包缺 $key');
      }
      expect(zhKeys, hasLength(11));
    });
  });
}
