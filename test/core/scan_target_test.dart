import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:gracelinkim/domain/scan/scan_target.dart';
import 'package:gracelinkim/features/common/scan_page.dart';

/// 扫码内容分流（S7.1），对照老端 `common/scan.js::checkQr`。
///
/// 纯函数，不碰相机与网络：这一层只判「自家链接 / 外链 / 普通文本」，
/// 剩下的（验证接口与跳哪个页面）在 `scan_page.dart` 与仓库用例里。
void main() {
  const apiUrl = 'https://im.example.test';

  test('自家链接：路径 + 最后一段当 realToken', () {
    final target = parseScanTarget(
      data: '$apiUrl/enterprise/group/qr/abc123',
      apiUrl: apiUrl,
    );

    expect(
      target,
      const ScanInternalTarget(
        path: '/enterprise/group/qr/abc123',
        token: 'abc123',
      ),
    );
  });

  test('最后的斜杠为空时取前一段（末尾带 / 也认）', () {
    expect(
      parseScanTarget(data: '$apiUrl/index/qr/abc123/', apiUrl: apiUrl),
      const ScanInternalTarget(path: '/index/qr/abc123/', token: 'abc123'),
    );
  });

  test('普通文本（不是链接）：原样交给弹层', () {
    expect(
      parseScanTarget(data: '随便一段文字', apiUrl: apiUrl),
      const ScanTextTarget('随便一段文字'),
    );
  });

  test('带协议的网址：认成外链，交给聊天那三道闸门（2026-09-27 改）', () {
    // 老端这里当普通文本、弹一个「复制」框；用户 2026-09-27 要求：
    // 「外部链接就跳转 webview，但同时也要遵守聊天里发链接点击的处理原则」。
    // 所以这里只负责**认出来**，怎么走交给 `core/ui/link_opener.dart`
    // （自家站点直开 / 微信系拦掉 / 其它先确认）。
    expect(
      parseScanTarget(data: 'https://weixin.qq.com/r/abc', apiUrl: apiUrl),
      const ScanUrlTarget('https://weixin.qq.com/r/abc'),
    );
  });

  group('外链那条路', () {
    test('http / https、大小写都认', () {
      expect(
        parseScanTarget(data: 'http://example.com', apiUrl: apiUrl),
        const ScanUrlTarget('http://example.com'),
      );
      expect(
        parseScanTarget(data: 'HTTPS://Example.com/a?b=1', apiUrl: apiUrl),
        const ScanUrlTarget('HTTPS://Example.com/a?b=1'),
      );
    });

    test('前后空白会去掉（二维码扫出来常带换行）', () {
      expect(
        parseScanTarget(data: '  https://example.com/a\n', apiUrl: apiUrl),
        const ScanUrlTarget('https://example.com/a'),
      );
    });

    test('没有协议的裸域名**不算**外链（与聊天里把网址做成蓝字同一个口径）', () {
      expect(
        parseScanTarget(data: 'example.com/a', apiUrl: apiUrl),
        const ScanTextTarget('example.com/a'),
      );
    });

    test('内容里含自家 apiUrl 时优先走自家那条路（不会被当成外链）', () {
      final target = parseScanTarget(
        data: 'https://im.example.test/index/qr/abc',
        apiUrl: apiUrl,
      );
      expect(target, isA<ScanInternalTarget>());
    });
  });

  test('正文里恰好引了我们的域名：不当自家链接（新端多做一道校验）', () {
    // 老端会拿这段去发请求（`pathinfo` 是个乱七八糟的东西）；新端要求
    // 「以 / 开头且最后一段非空」，否则退回文本处理。
    const text = '看看这篇 $apiUrl 上的文章';
    expect(
      parseScanTarget(data: text, apiUrl: apiUrl),
      const ScanTextTarget(text),
    );
  });

  test('空内容与空白：当空文本，不发请求', () {
    expect(parseScanTarget(data: '', apiUrl: apiUrl), const ScanTextTarget(''));
    expect(
      parseScanTarget(data: '   ', apiUrl: apiUrl),
      const ScanTextTarget(''),
    );
  });

  test('apiUrl 没配（空串）时：不再有「自家码」那条路，带协议的照走外链', () {
    expect(
      parseScanTarget(data: 'https://im.example.test/x/y', apiUrl: ''),
      const ScanUrlTarget('https://im.example.test/x/y'),
    );
    // 没有协议的那种仍然是普通文本
    expect(
      parseScanTarget(data: '随便一段文字', apiUrl: ''),
      const ScanTextTarget('随便一段文字'),
    );
  });

  group('一帧识别结果里取哪一条（相机扫到与相册识别共用）', () {
    test('插件会把空项一起给出来：跳过它们，取第一条有内容的', () {
      expect(
        firstScannedValue(
          const BarcodeCapture(
            barcodes: <Barcode>[
              Barcode(rawValue: ''),
              Barcode(),
              Barcode(rawValue: 'https://example.com'),
            ],
          ),
        ),
        'https://example.com',
      );
    });

    test('一条都没有 / 全是空的：null（不当成一个结果去处理）', () {
      expect(firstScannedValue(const BarcodeCapture()), isNull);
      expect(
        firstScannedValue(
          const BarcodeCapture(barcodes: <Barcode>[Barcode(rawValue: '')]),
        ),
        isNull,
      );
    });
  });

  test('服务端的回答：三个字段都解析', () {
    expect(
      ScanVerdict.fromJson(<String, dynamic>{
        'action': 'qrLogin',
        'id': 'g1',
        'loginToken': 'tk-1',
      }),
      const ScanVerdict(action: 'qrLogin', id: 'g1', loginToken: 'tk-1'),
    );
    expect(ScanVerdict.fromJson(<String, dynamic>{}).isEmpty, isTrue);
  });

  group('扫群二维码：服务端在验证那一步顺带给的群资料', () {
    test('`groupInfo` 那条把群表那一行给回来：名字/头像/邀请人都认得出', () {
      // 服务端 `Index::group`：把群表那一行原样回，再补上 `avatar`（整条 URL）、
      // `invite_id`（生成这张码的人，也在群里）与 `id`（`group-<数字>`）。
      // **这条路不查群成员**，所以它才是「未入群的人也能看到的群资料」。
      final verdict = ScanVerdict.fromJson(<String, dynamic>{
        'action': 'groupInfo',
        'id': 'group-9',
        'name': '扫码群',
        'avatar': 'https://cdn.test/g.png',
        'setting': '{"manage":0,"invite":1,"nospeak":0}',
        'invite_id': 'u9',
      });

      expect(verdict.group, isNotNull);
      expect(verdict.group!.id, 'group-9');
      expect(verdict.group!.name, '扫码群');
      expect(verdict.group!.avatar, 'https://cdn.test/g.png');
      expect(verdict.group!.inviteUid, 'u9');
      expect(verdict.group!.inviteOpen, isTrue);
      // 群表那一行里没有人头与 isJoin：按「没这个字段」处理（界面自会省略人数）
      expect(verdict.group!.memberCount, 0);
      expect(verdict.group!.joined, isFalse);
    });

    test('群已关闭加群：`setting` 是数据库里那个 JSON 字符串也认得出来', () {
      // `groupInfo` 那条是 `json_decode` 过的对象，扫码这条是原样字符串。
      // 只认对象的话，这里会被当成「没这个字段」而按开放处理（兜底是 true）。
      final verdict = ScanVerdict.fromJson(<String, dynamic>{
        'action': 'groupInfo',
        'id': 'group-9',
        'setting': '{"invite":0}',
      });

      expect(verdict.group!.inviteOpen, isFalse);
    });

    test('其它 action 不顺带群资料（个人名片 / 扫码登录 / 空回包）', () {
      expect(
        ScanVerdict.fromJson(<String, dynamic>{
          'action': 'userInfo',
          'id': 'u2',
        }).group,
        isNull,
      );
      expect(ScanVerdict.fromJson(<String, dynamic>{}).group, isNull);
    });
  });

  group('服务端的 action 该跳哪（`scan_page.dart::scanRouteOf`）', () {
    test('三个认识的 action 各自去哪儿（参数名不能拼错）', () {
      expect(
        scanRouteOf(const ScanVerdict(action: 'groupInfo', id: 'g9')),
        '${AppRoutes.groupInfo}?group_id=g9',
      );
      expect(
        scanRouteOf(const ScanVerdict(action: 'userInfo', id: 'u2')),
        '${AppRoutes.contactsDetail}?id=u2',
      );
      expect(
        scanRouteOf(const ScanVerdict(action: 'qrLogin', loginToken: 'tk-1')),
        '${AppRoutes.qrLogin}?token=tk-1',
      );
    });

    test('id / token 里的特殊字符会被编码（不能拼出畸形 query）', () {
      expect(
        scanRouteOf(const ScanVerdict(action: 'userInfo', id: 'a&b=c')),
        '${AppRoutes.contactsDetail}?id=a%26b%3Dc',
      );
    });

    test('不认识的 action、或关键字段是空的：返回 null（页面只提示）', () {
      expect(
        scanRouteOf(const ScanVerdict(action: 'something', id: 'g1')),
        isNull,
      );
      expect(scanRouteOf(const ScanVerdict(action: 'groupInfo')), isNull);
      expect(
        scanRouteOf(const ScanVerdict(action: 'qrLogin', loginToken: '')),
        isNull,
      );
      expect(scanRouteOf(const ScanVerdict()), isNull);
    });
  });
}
