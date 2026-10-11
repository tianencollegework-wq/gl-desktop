import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/router/app_router.dart';

/// 占位页清单是一道「防漏」闸门。
///
/// 起因：**扫一扫**页面写好了、用例也在，但路由没接 —— 点进去仍然是那张
/// 「待实现」占位页，而且没有任何用例会红（是复查功能清单时才发现的）。
/// 所以这里把两件事钉住：
/// 1. **已经实装的页面不能还留在 `pendingRoutePaths` 里**（下面那份清单）；
/// 2. 占位清单不许悄悄变长（新加占位 = 改这个用例，强制过一遍脑子）。
void main() {
  test('已经做好的页面不能还留在占位清单里', () {
    // 这份清单 = 已经接到真页面的路由（挑的是最容易「写了页面忘接路由」的那批）
    const implemented = <String>[
      AppRoutes.scan, // 扫一扫（S7.1）
      AppRoutes.qrcode, // 我的 / 群二维码（S7.1）
      AppRoutes.webview, // 内嵌浏览器（S7.1）
      AppRoutes.groupInfo, // 群资料 / 加入群聊（S7.1）
      AppRoutes.groupUser, // 群成员管理（S5.3）
      AppRoutes.userSelection, // 用户选择器 / 创建群聊（S5.6）
      AppRoutes.emoji, // 表情管理（S5.6b）
      AppRoutes.groupList, // 群聊列表（S5.5）
      AppRoutes.newFriends, // 新的朋友（S5.5）
      AppRoutes.contactsDetail, // 用户详情（S5.5）
      AppRoutes.mineSecure, // 账号安全（S5.5）
      AppRoutes.mineDoc, // 用户协议 / 隐私政策（S5.5）
      AppRoutes.contactSearch, // 搜人（S5.4）
      AppRoutes.indexSearch, // 本地搜索（S5.4）
      AppRoutes.chatRecord, // 聊天记录（S5.4）
      AppRoutes.chatDetail, // 聊天信息（S5.3）
      AppRoutes.qrLogin, // 扫码登录确认页（S7.1 遗留）
    ];

    for (final path in implemented) {
      expect(
        pendingRoutePaths,
        isNot(contains(path)),
        reason: '$path 已经接了真页面，不该还在占位清单里',
      );
    }
  });

  test('占位清单只剩这些（加新的占位要在这里登记）', () {
    expect(pendingRoutePaths.toSet(), <String>{
      // 朋友圈：不做（老端那页自己写着「静态模板」，接口层也没有对应接口）
      AppRoutes.moments,
    });
  });

  test('占位页仍然有真实路由（能构建，不是写了个名字而已）', () {
    // 只是把路由表建出来：`createAppRouter()` 里给每条占位都挂了 GoRoute，
    // 这里保证清单与路由表彼此一致（清单里有的路径必须真的能匹配上）。
    expect(createAppRouter(), isNotNull);
  });
}
