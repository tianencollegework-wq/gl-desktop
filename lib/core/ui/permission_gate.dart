import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/app_i18n.dart';
import '../platform/app_permissions.dart';
import '../platform/app_settings.dart';
import '../platform/background_health.dart';
import '../store/credential_store.dart';
import 'wechat_dialog.dart';

/// 「用之前先确保拿到这个权限」。
///
/// 这是权限这件事**唯一**的入口：先查 → 缺了就弹一次系统框 → 还是没给（或者用户
/// 之前已经拒到底、系统不再弹框了）就用微信那只白框说清「要哪一个权限、为什么」，
/// 并给一颗「去授权」直接跳到本应用在系统设置里的页面。
///
/// 为什么非要有这一步：安卓从**第二次拒绝**起就不再弹系统授权框了，
/// `getUserMedia` / 相机只会一味失败 —— 用户看到的是「点了没反应」或者一句看不懂的
/// 原生报错。光说「请去系统设置里打开」等于没帮上忙，得把那颗钮递到他手里。
///
/// 返回值是「现在到底能不能继续」：
/// * `true` —— 已授权（或这个平台不需要它）；
/// * `false` —— 没拿到，调用方**应该就此打住**（别继续往下一步走，
///   否则用户会看到一个注定失败的相机预览 / 一通接不上的电话）。
///
/// [messageKey] 是提示正文的语言包键（比如 `perm.needCamera`），
/// [reasonKey] 是可选的补充一句「为什么需要它」。
Future<bool> ensurePermission(
  BuildContext context, {
  required PermissionGateway gateway,
  required AppPermission permission,
  required String messageKey,
  String? reasonKey,
}) async {
  if ((await gateway.check(permission)).isGranted) return true;
  if ((await gateway.request(permission)).isGranted) return true;
  if (!context.mounted) return false;
  await showPermissionGuide(
    context,
    messageKey: messageKey,
    reasonKey: reasonKey,
  );
  return false;
}

/// 只提示 + 「去授权」那一只框（不查也不申请）。
///
/// 用在「已经确定没授权」的地方：相机起不来的错误回调、录音返回 false、
/// 或者调用方自己知道跳过授权这一步（测试里）。
Future<void> showPermissionGuide(
  BuildContext context, {
  required String messageKey,
  String? reasonKey,
}) async {
  final i18n = AppI18n.instance;
  final reason = reasonKey == null ? '' : '\n${i18n.t(reasonKey)}';
  final action = await showDialog<Object>(
    context: context,
    builder: (dialogContext) => WeChatDialogBox(
      body: WeChatDialogText('${i18n.t(messageKey)}$reason'),
      actions: <WeChatDialogAction>[
        WeChatDialogAction(label: i18n.t('common.cancel'), value: 'cancel'),
        WeChatDialogAction(
          label: i18n.t('common.gotoAuth'),
          value: 'settings',
          tone: WeChatDialogTone.primary,
        ),
      ],
    ),
  );
  if (action != 'settings') return;
  // 跳到本应用在系统设置里的详情页（权限开关就在那一页）
  await openAppSettings();
}

/// **通话前**的权限检查（1:1 通话与群语音共用那两处）。
///
/// 为什么要在拨号之前查：往里进之后才发现麦克风被拒，用户看到的是一通接不上、
/// 或者响两声就没了的电话；先在门口拦一下，他能立刻去开权限再拨。
/// 视频通话再顺带查摄像头（语音那条不该因为摄像头被拒就不让人打电话）。
///
/// 用户 2026-09-27 的要求：「通话前还要再检查几个权限」。
Future<bool> ensureCallPermissions(
  BuildContext context,
  WidgetRef ref, {
  required bool video,
}) async {
  final gateway = ref.read(permissionGatewayProvider);
  final mic = await ensurePermission(
    context,
    gateway: gateway,
    permission: AppPermission.microphone,
    messageKey: 'perm.needMic',
  );
  if (!mic || !video) return mic;
  if (!context.mounted) return false;
  return ensurePermission(
    context,
    gateway: gateway,
    permission: AppPermission.camera,
    messageKey: 'perm.needCamera',
  );
}

/// 「来电全屏显示」那条提醒弹过没有（**设备级**，换账号不重弹）
const String fullScreenCallHintKey = 'fullScreenCallHintShown';

/// 拨 1:1 电话之前那句「来电全屏显示还没开」的提醒（S12.8）。
///
/// 这条以前是消息列表顶上的**红条**（`SystemHealthBanner` 的 fullScreen 分支）。
/// 用户 2026-09-30：「红色横幅删掉，通话提醒就在发起通话之前弹窗提示就好了」——
/// 于是红条撤掉，改成拨号前弹一次。
///
/// 三个刻意的约束：
/// * **只在没开启时弹**（开着的人不该被打扰）；
/// * **一台机器只弹一次**（[fullScreenCallHintKey]）：这条只是「来电不够醒目」，
///   不是病（照样响铃、照样能接），每次拨号前都拦一下就成骚扰了；
/// * 用户点「去开启」才跳系统设置，跳完自己回来重新拨 —— 与其它权限引导框
///   同一个口径（[showPermissionGuide]）。
///
/// 群语音**不提示**：群邀请那条通知本来就不是全屏的（见
/// `MessageNotificationPresenter.showGroupCallRing`），这道开关只管 1:1 来电。
Future<void> remindFullScreenBeforeCall(
  BuildContext context,
  WidgetRef ref,
) async {
  final store = CredentialStore.instance;
  if (store.getBool(fullScreenCallHintKey)) return;
  final health = ref.read(backgroundHealthProvider);
  // 只有安卓有这套开关；没实现的平台（iOS / 桌面 / 单测）一律当「已允许」
  if (!health.supported) return;
  if (await health.fullScreenIntentAllowed()) return;
  // 先记一笔再弹：无论用户接下来点哪个，都只打扰这一次
  await store.setBool(fullScreenCallHintKey, true);
  if (!context.mounted) return;
  final i18n = AppI18n.instance;
  final action = await showDialog<Object>(
    context: context,
    builder: (dialogContext) => WeChatDialogBox(
      body: WeChatDialogText(i18n.t('system.notFullScreen')),
      actions: <WeChatDialogAction>[
        WeChatDialogAction(label: i18n.t('common.cancel'), value: 'cancel'),
        WeChatDialogAction(
          label: i18n.t('common.gotoAuth'),
          value: 'settings',
          tone: WeChatDialogTone.primary,
        ),
      ],
    ),
  );
  if (action != 'settings') return;
  await health.openFullScreenIntentSettings();
}
