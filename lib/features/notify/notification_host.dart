import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notify/message_notification_presenter.dart';
import '../../core/platform/app_foreground.dart';
import '../../core/router/app_router.dart';

/// 通知的「宿主」（S4.0 收尾）。挂在 `MaterialApp.builder` 上（在 Navigator 之上，
/// 与 [CallHost] 同一层），负责三件事：
///
/// 1. **跟踪前后台**：把生命周期写进 [appForegroundProvider]，决定收到消息是
///    「应用内响一声」还是「弹系统通知」；
/// 2. **注册通知点击**：点通知 → 进对应的聊天页；
/// 3. **处理冷启动**：App 是被通知拉起来的（进程当时已经没了）时，
///    初始化会把目标会话 id 交回来，这里补一次跳转。
class NotificationHost extends ConsumerStatefulWidget {
  const NotificationHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NotificationHost> createState() => _NotificationHostState();
}

class _NotificationHostState extends ConsumerState<NotificationHost>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 初始值由 [appForegroundProvider].build() 自己问引擎（不在这里写 provider ——
    // 在 initState 里改 provider 会被 Riverpod 拒掉）
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final presenter = ref.read(messageNotificationPresenterProvider);
    final pending = await presenter.initialize(onOpen: _openConversation);
    if (!mounted) return;
    if (pending != null && pending.isNotEmpty) {
      // 冷启动那条路（App 是被点通知拉起来的）：留着这一行，真机上「点了没跳」
      // 才分得清是「通知没带会话 id」还是「跳了但没落在会话上」
      debugPrint('[通知] 冷启动带回来的会话：$pending');
      _openConversation(pending);
    }
  }

  /// 点通知 → 进那个会话。用 `GoRouter` 实例直接 push（与 [CallHost] 同一套路），
  /// 不需要自己的 context 在栈顶；未登录时路由守卫会把人拦到登录页。
  void _openConversation(String conversationId) {
    if (conversationId.isEmpty) {
      debugPrint('[通知] 那条通知没带会话 id，跳不了');
      return;
    }
    // 真机排查用（2026-10-08「点通知白屏」）：这一行与下面那一行的先后顺序，
    // 就是「跳转真的发出去了」与「页面自己没找到那个会话」的分界
    debugPrint('[通知] 点通知进会话：$conversationId');
    unawaited(
      ref.read(messageNotificationPresenterProvider).cancel(conversationId),
    );
    ref
        .read(appRouterProvider)
        .push('${AppRoutes.chat}?id=${Uri.encodeComponent(conversationId)}');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref
        .read(appForegroundProvider.notifier)
        .update(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
