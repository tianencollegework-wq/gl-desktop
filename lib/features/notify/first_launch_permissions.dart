import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notify/message_notification_presenter.dart';
import '../../core/platform/app_permissions.dart';
import '../../core/store/credential_store.dart';

/// 问过一次没有。存在本地（**设备级**的权限，换账号也不该再问一遍）
const String firstLaunchPermissionsKey = 'firstLaunchPermissionsAsked';

/// **第一次打开 App 时**把「基本权限」要一遍（用户 2026-09-27 的要求：
/// 「确保一下，是不是软件下载完第一次打开会自动申请系统的这几个基本权限？」）。
///
/// 现在只有**通知**这一条 —— 它是唯一一条「不问就等于功能残废」的权限
/// （没有它，新消息、通话邀请在锁屏上一声不响，用户根本不知道有人找他）。
///
/// **摄像头与麦克风刻意不在启动时问**：一上来就要相机权限，用户只会拒绝，
/// 而且系统权限框会把 App 顶上后台（安卓 14 那套 while-in-use 校验很不欢迎这件事）。
/// 它们各自在**用到的那一刻**问：拨电话、开群语音、按住说话、扫码、拍照
/// （`core/ui/permission_gate.dart`）。
///
/// 这里与从前那版（`HomeShell` 里一个顶级 bool「本次启动已经问过」）的区别：
/// **问一次就存下来**。以前是每个进程问一次 —— 冷启动十次就问十次，
/// 被拒之后系统早就不弹框了，那十次都是白跑。
///
/// 放在主界面（`HomeShell`）而不是登录页：没登录时也不会有消息要提醒，
/// 而且推送登记、全局配置都是登录之后才齐的。
Future<void> runFirstLaunchPermissionPrompt(WidgetRef ref) async {
  final store = CredentialStore.instance;
  if (store.getBool(firstLaunchPermissionsKey)) return;

  final gateway = ref.read(permissionGatewayProvider);
  final status = await gateway.check(AppPermission.notifications);
  if (status == PermissionStatus.unsupported) {
    // 这条通道不认通知（iOS / 桌面 / 还没实现它的旧包）：交给通知那一层
    // 自己去问 —— 它在 iOS 上会弹系统框（安卓 13+ 也会，与上面那条等效）
    final presenter = ref.read(messageNotificationPresenterProvider);
    if (!await presenter.enabled()) await presenter.requestPermission();
  } else if (!status.isGranted) {
    await gateway.request(AppPermission.notifications);
  }
  // 答完就记一笔（无论同不同意）：每次启动都问一遍是骚扰。
  // 想反悔的人有两条路：设置 › 通知 › 通知权限，或者系统设置页。
  await store.setBool(firstLaunchPermissionsKey, true);
}
