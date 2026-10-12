import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/domain/report/report_failure.dart';
import 'package:gracelinkim/domain/report/report_reasons.dart';

/// 举报这一层的**契约**测试（S13.1，2026-10-11）。
///
/// 这一层最容易出的错都不是逻辑错，而是**两边对不上**：
/// 原因码与服务端白名单差一个字母 → 用户看到「举报原因不对」；
/// 请求体的键名写错 → 服务端当没收到（举报对象成了空）；
/// 业务码认不出来 → 用户看到一句中文（而这 App 有七种语言）。
/// 所以这里逐条钉死这三件事。
///
/// 服务端那一侧是 `app/enterprise/service/ReportInput.php`（`REASONS` / `SCENES` /
/// `CODE_*`），补丁包里的 `_patch/check-report-patch.js` 会把两份源码对一遍
/// （这里只能钉住客户端自己这一份）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('原因码表（与服务端 ReportInput::REASONS 逐字对齐）', () {
    test('五个码、顺序固定', () {
      expect(
        ReportReason.values.map((reason) => reason.code).toList(),
        <String>['ad', 'porn', 'fraud', 'harass', 'other'],
      );
    });

    test('每个原因都有自己那句文案（七份语言包都得有，别退化成 key）', () async {
      await AppI18n.load('zh-Hans');
      for (final reason in ReportReason.values) {
        final text = AppI18n.instance.t(reason.labelKey);
        expect(text, isNot(startsWith('report.')), reason: reason.code);
        expect(text.trim(), isNotEmpty, reason: reason.code);
      }
    });

    test('fromCode 认得出每一个码；生面孔返回 null（老客户端遇到新码不该崩）', () {
      for (final reason in ReportReason.values) {
        expect(ReportReason.fromCode(reason.code), reason);
      }
      expect(ReportReason.fromCode('violence'), isNull);
      expect(ReportReason.fromCode(''), isNull);
    });
  });

  group('举报目标 → 请求体（键名就是服务端认的那几个）', () {
    test('资料页举报一个人', () {
      final target = ReportTarget.user(userId: '9', userName: '小明');
      expect(target.scene, ReportScene.profile);
      expect(target.hasTarget, isTrue);
      expect(target.toParams(reason: 'harass', detail: '  一直在骂人  '), <String, dynamic>{
        'to_user': 9,
        'msg_id': '',
        'server_id': 0,
        'group_id': '',
        'reason': 'harass',
        // 空白由仓库那一层 trim（`ReportRepository.submit`），这里原样
        'detail': '  一直在骂人  ',
        'scene': 'profile',
      });
    });

    test('长按消息举报：消息 id / 数字主键 / 群号 / 发送者一起带上', () {
      final target = ReportTarget.message(
        userId: '9',
        userName: '小明',
        msgId: 'uuid-1',
        serverId: 88,
        groupId: 'group-5',
        preview: '你好',
      );
      expect(target.scene, ReportScene.message);
      expect(target.toParams(reason: 'ad'), <String, dynamic>{
        'to_user': 9,
        'msg_id': 'uuid-1',
        'server_id': 88,
        'group_id': 'group-5',
        'reason': 'ad',
        'detail': '',
        'scene': 'message',
      });
    });

    test('群信息页投诉：报的是这个群（`group_id` 就是对象，没有具体的人）', () {
      // 群里「投诉谁」常常说不清，用户要投诉的就是这个群：服务端认 `group_id`
      // （并校验举报人在这个群里），后台那一页看到的是「谁投诉了哪个群」。
      final target = ReportTarget.group(groupId: 'group-5', groupName: '产品群');
      expect(target.scene, ReportScene.group);
      expect(target.userId, isEmpty);
      expect(target.userName, '产品群');
      expect(target.hasTarget, isTrue, reason: '有群号就算有对象');
      expect(target.isSubmittable, isTrue);
      expect(target.toParams(reason: 'ad'), <String, dynamic>{
        'to_user': '',
        'msg_id': '',
        'server_id': 0,
        // 原样发；`group-5` 那种写法由服务端 `ReportInput::groupId` 归一化
        'group_id': 'group-5',
        'reason': 'ad',
        'detail': '',
        'scene': 'group',
      });
    });

    test('场景码表与服务端 `ReportInput::SCENES` 逐字对齐', () {
      expect(
        ReportScene.values.map((scene) => scene.code).toList(),
        <String>['about', 'chat', 'group', 'message', 'profile'],
      );
    });

    test('关于页的平台级反馈：没有对象也能发（服务端只对这一种场景放行）', () {
      final target = ReportTarget.platform();
      expect(target.scene, ReportScene.about);
      expect(target.hasTarget, isFalse);
      expect(target.isSubmittable, isTrue);
      expect(target.toParams(reason: 'other', detail: 'App 里有人发广告'), <String, dynamic>{
        'to_user': '',
        'msg_id': '',
        'server_id': 0,
        'group_id': '',
        'reason': 'other',
        'detail': 'App 里有人发广告',
        'scene': 'about',
      });
    });

    test('没有对象、场景也不是「关于页」→ 界面就该不给入口', () {
      const target = ReportTarget(scene: ReportScene.chat);
      expect(target.hasTarget, isFalse);
      expect(target.isSubmittable, isFalse);
    });

    test('一张空的消息 id 不会把整个举报发成「举报自己」', () {
      // `idValue('')` 给回空串，服务端 `(int)''` 是 0 —— 这正是「不指定对象」的意思
      final target = ReportTarget.message(userId: '', userName: '', msgId: 'm1');
      expect(target.toParams(reason: 'ad')['to_user'], '');
      expect(target.hasTarget, isTrue, reason: '有消息 id 就算有对象');
    });
  });

  group('业务码 → 文案（认不出的退回服务端原话）', () {
    test('六个码各自对上自己那句', () {
      expect(ReportCodes.labelKeyOf(4101), 'report.errBadParam');
      expect(ReportCodes.labelKeyOf(4102), 'report.errSelf');
      expect(ReportCodes.labelKeyOf(4103), 'report.errDuplicate');
      expect(ReportCodes.labelKeyOf(4104), 'report.errTooMany');
      expect(ReportCodes.labelKeyOf(4105), 'report.errNotMine');
      expect(ReportCodes.labelKeyOf(4106), 'report.errGone');
      expect(ReportCodes.labelKeyOf(4999), isNull);
      expect(ReportCodes.labelKeyOf(null), isNull);
    });

    test('服务端明确拒绝 → 被拒（带码）', () {
      final outcome = ReportOutcome.fromApiException(
        const BusinessException(4103, '这条已经举报过了'),
      );
      expect(outcome, isA<ReportRejected>());
      expect(outcome.labelKey, 'report.errDuplicate');
      expect(outcome.needsRelogin, isFalse);
    });

    test('生面孔的码 → 原样转述服务端那句话，不当成「失败」', () {
      final outcome = ReportOutcome.fromApiException(
        const BusinessException(4999, '举报太密集了，请稍后再试'),
      );
      expect(outcome.labelKey, isNull);
      expect(outcome.message, '举报太密集了，请稍后再试');
    });

    test('网络失败 / 登录失效 → 「没提交成」，不是「被拒」', () {
      final offline = ReportOutcome.fromApiException(
        const NetworkUnavailableException(),
      );
      expect(offline, isA<ReportUnavailable>());
      expect(offline.needsRelogin, isFalse);

      final expired = ReportOutcome.fromApiException(
        const UnauthorizedException(),
      );
      expect(expired, isA<ReportUnavailable>());
      expect(expired.needsRelogin, isTrue, reason: '这种要直接送去重登');
    });

    test('服务端 5xx 也不算被拒（不知道对面收没收到）', () {
      final outcome = ReportOutcome.fromApiException(const ServerException());
      expect(outcome, isA<ReportUnavailable>());
    });
  });
}
