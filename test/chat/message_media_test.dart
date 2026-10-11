import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/util/json_value.dart';
import 'package:gracelinkim/core/util/media_format.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/chat/message_media.dart';

void main() {
  Message message({
    required String type,
    String content = '',
    Map<String, dynamic> ext = const <String, dynamic>{},
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) => Message(
    conversationId: 'u2',
    type: type,
    content: content,
    ext: ext,
    extra: extra,
  );

  group('文件大小（老端 getFileSize 的输出格式）', () {
    test('不到 1KB：数字直接跟 B，没有空格', () {
      expect(fileSize(0), '0B');
      expect(fileSize(512), '512B');
      expect(fileSize(1023), '1023B');
    });

    test('1KB 起：两位小数 + 空格 + 单位', () {
      expect(fileSize(1024), '1.00 KB');
      expect(fileSize(1536), '1.50 KB');
      expect(fileSize(1024 * 1024), '1.00 MB');
      expect(fileSize(5 * 1024 * 1024), '5.00 MB');
      expect(fileSize(5 * 1024 * 1024 * 1024), '5.00 GB');
    });
  });

  group('时长（老端 videoFormatTime）', () {
    test('不到 1 小时：mm:ss', () {
      expect(durationText(0), '00:00');
      expect(durationText(9), '00:09');
      expect(durationText(65), '01:05');
      expect(durationText(3599), '59:59');
    });

    test('超过 1 小时：h:mm:ss', () {
      expect(durationText(3600), '1:00:00');
      expect(durationText(3725), '1:02:05');
    });

    test('负数当 0（老端会算出奇怪的值）', () {
      expect(durationText(-5), '00:00');
    });
  });

  group('封面尺寸（老端 imageCoverStyle 的实际效果）', () {
    test('宽 > 高：宽固定 200，高等比', () {
      final box = mediaBoxSize(400, 200);
      expect(box.width, 200);
      expect(box.height, 100);
    });

    test('高 >= 宽：高固定 240，宽等比', () {
      final box = mediaBoxSize(100, 400);
      expect(box.width, 60);
      expect(box.height, 240);
    });
  });

  group('图片载荷', () {
    test('读 content 与 extends 里的 fixMode/宽高', () {
      final payload = imagePayloadOf(
        message(
          type: 'image',
          content: 'https://a.test/a.png',
          ext: <String, dynamic>{'fixMode': 3, 'width': 400, 'height': 300},
        ),
      );

      expect(payload.url, 'https://a.test/a.png');
      expect(payload.fixMode, 3);
      expect(payload.width, 400);
      expect(payload.height, 300);
      expect(payload.hasSize, isTrue);
    });

    test('没有宽高时 hasSize 为假（老端退回 120 宽那档）', () {
      final payload = imagePayloadOf(
        message(type: 'image', content: 'https://a.test/a.png'),
      );
      expect(payload.hasSize, isFalse);
    });

    test('地址为空算空载荷', () {
      expect(imagePayloadOf(message(type: 'image')).isEmpty, isTrue);
    });
  });

  group('语音载荷', () {
    test('秒数来自 extends.duration', () {
      final payload = voicePayloadOf(
        message(
          type: 'voice',
          content: 'https://a.test/v.mp3',
          ext: <String, dynamic>{'duration': 12},
        ),
      );
      expect(payload.url, 'https://a.test/v.mp3');
      expect(payload.duration, 12);
    });

    test('没给秒数就是 0（老端会显示 0 "）', () {
      expect(voicePayloadOf(message(type: 'voice', content: 'x')).duration, 0);
    });
  });

  group('视频载荷', () {
    test('封面、时长、尺寸都在 extends 里', () {
      final payload = videoPayloadOf(
        message(
          type: 'video',
          content: 'https://a.test/v.mp4',
          ext: <String, dynamic>{
            'poster': 'https://a.test/p.jpg',
            'duration': 96,
            'width': 1280,
            'height': 720,
          },
        ),
      );
      expect(payload.url, 'https://a.test/v.mp4');
      expect(payload.poster, 'https://a.test/p.jpg');
      expect(payload.duration, 96);
      expect(payload.hasSize, isTrue);
    });
  });

  group('文件载荷', () {
    test('名字与大小读顶层（老端自己发出去那条的形状）', () {
      final payload = filePayloadOf(
        message(
          type: 'file',
          content: 'https://a.test/x.pdf',
          extra: <String, dynamic>{'fileName': '合同.pdf', 'fileSize': 2048},
        ),
      );
      expect(payload.name, '合同.pdf');
      expect(payload.size, 2048);
      expect(payload.extension, 'pdf');
    });

    test('顶层没有就读 extends', () {
      final payload = filePayloadOf(
        message(
          type: 'file',
          content: 'https://a.test/x.zip',
          ext: <String, dynamic>{'name': '打包.zip', 'size': 1024},
        ),
      );
      expect(payload.name, '打包.zip');
      expect(payload.size, 1024);
      expect(payload.extension, 'zip');
    });

    test('两处都没有就从下载地址猜（去掉查询串）', () {
      final payload = filePayloadOf(
        message(type: 'file', content: 'https://a.test/upload/9f2/报表.xlsx?t=1'),
      );
      expect(payload.name, '报表.xlsx');
      expect(payload.extension, 'xlsx');
      expect(payload.size, 0);
    });

    test('地址里没有后缀也不算崩', () {
      final payload = filePayloadOf(
        message(type: 'file', content: 'https://a.test/download'),
      );
      expect(payload.name, 'download');
      expect(payload.extension, '');
    });

    test('从服务端真实报文里来（顶层 file_name 那套也能吃到）', () {
      final json = <String, dynamic>{
        'id': 7,
        'msg_id': 'm7',
        'type': 'file',
        'content': 'https://a.test/doc.docx',
        'fileSize': '3072',
        'fileName': '说明.docx',
        'toContactId': 'u2',
        'fromUser': <String, dynamic>{'id': 'u2', 'realname': '小明'},
        'extends': <String, dynamic>{},
      };
      final payload = filePayloadOf(
        Message.fromServerJson(json, conversationId: 'u2'),
      );
      expect(payload.name, '说明.docx');
      expect(payload.size, 3072);
      expect(payload.extension, 'docx');
    });
  });

  group('位置载荷', () {
    test('标题取 content，地址与坐标取 extends（字符串坐标也能解析）', () {
      final payload = locationPayloadOf(
        message(
          type: 'location',
          content: '人民广场',
          ext: <String, dynamic>{
            'address': '上海市黄浦区',
            'latitude': '31.23',
            'longitude': 121.47,
          },
        ),
      );
      expect(payload.title, '人民广场');
      expect(payload.address, '上海市黄浦区');
      expect(payload.latitude, closeTo(31.23, 0.0001));
      expect(payload.longitude, closeTo(121.47, 0.0001));
      expect(payload.hasCoordinate, isTrue);
    });
  });

  group('名片载荷', () {
    test('昵称优先 displayName，退回 realname', () {
      final byDisplayName = contactPayloadOf(
        message(
          type: 'contact',
          ext: <String, dynamic>{
            'id': 'u9',
            'displayName': '小明',
            'avatar': 'https://a.test/a.png',
          },
        ),
      );
      expect(byDisplayName.displayName, '小明');

      final byRealname = contactPayloadOf(
        message(
          type: 'contact',
          ext: <String, dynamic>{'id': 'u9', 'realname': '小红'},
        ),
      );
      expect(byRealname.displayName, '小红');
      expect(byRealname.isEmpty, isFalse);
    });
  });

  group('通话卡片载荷', () {
    test('type == 1 是视频通话', () {
      expect(
        callPayloadOf(
          message(
            type: 'webrtc',
            content: '通话时长 00:35',
            ext: <String, dynamic>{'type': 1},
          ),
        ).isVideo,
        isTrue,
      );
      expect(
        callPayloadOf(
          message(
            type: 'webrtc',
            content: '已取消',
            ext: <String, dynamic>{'type': 0},
          ),
        ).isVideo,
        isFalse,
      );
    });

    test('group_call == 1 是群通话记录（先弹详情卡：时长与人数都在 extends 里）', () {
      final group = callPayloadOf(
        message(
          type: 'webrtc',
          content: '群通话 00:45',
          ext: <String, dynamic>{
            'type': 0,
            'group_call': 1,
            'callTime': 45,
            'participants': 3,
          },
        ),
      );
      expect(group.groupCall, isTrue);
      expect(group.text, '群通话 00:45');
      expect(group.isVideo, isFalse);
      // 详情卡上那两行（`callTime` 与 `content` 里的时长是同一个数，
      // 服务端出的是同一个口径）
      expect(group.durationSeconds, 45);
      expect(group.participants, 3);

      // 1:1 的通话记录（服务端写的那条）没有这个记号：仍然是回拨，
      // 那两样详情数据也没有（老记录本就不带）
      final oneOnOne = callPayloadOf(
        message(
          type: 'webrtc',
          content: '通话时长 00:35',
          ext: <String, dynamic>{'type': 0, 'code': 906},
        ),
      );
      expect(oneOnOne.durationSeconds, 0);
      expect(oneOnOne.participants, 0);
      expect(oneOnOne.groupCall, isFalse);
    });
  });

  group('未知类型文案', () {
    test('diy 单独给一条文案，其余都说暂不支持', () {
      expect(unsupportedKeyOf('diy'), 'common.diy');
      expect(unsupportedKeyOf('video-call'), 'common.nonsupportMsg');
      expect(unsupportedKeyOf(''), 'common.nonsupportMsg');
    });
  });

  group('宽松取小数', () {
    test('数字、字符串、布尔都能吃', () {
      expect(asDouble(2), 2);
      expect(asDouble('2'), 2);
      expect(asDouble('39.9'), closeTo(39.9, 0.0001));
      expect(asDouble(true), 1);
      expect(asDouble(null), 0);
      expect(asDouble('abc', -1), -1);
    });
  });
}
