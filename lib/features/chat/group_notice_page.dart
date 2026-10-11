import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/util/json_value.dart';
import '../../data/repo/conversation_repository.dart';
import '../../data/repo/group_admin_repository.dart';

/// 群公告：**整页编辑**，右上角一颗「保存」（S6.22）。
///
/// 换掉的是原来那个和老端一样的**底部弹层**（`showTextPrompt`：标题 + 六行输入框 +
/// 一颗「保存」）—— 用户 2026-09-27 要求「不要弹窗，变成一个页面输入，右上角保存」。
///
/// 四条规矩（前三条与老端一致，第四条是新页面才有的）：：
///
/// * **非管理员只读**：连「保存」都不画（老端是把输入框 `disabled`，新端更干脆）；
/// * 保存走 `GroupAdminRepository.setNotice`，它顺手把本地那一格 `extra.notice`
///   覆盖掉 —— 所以**返回后群资料页那一行的值当场就变了**（那一页盯着同一条流），
///   这里不用自己刷；
/// * 失败把服务端那句话弹出来（与聊天信息页其它动作同一个口径）；
/// * 管理员进来自动聚焦：公告是"进来就写"的东西，少点一下。
///
/// 初始内容从**本地库**读（不通过路由传文本）：公告可能很长，塞进 URL 又丑又容易
/// 被截断；而本地库里那一格本来就是这一页要写回去的地方。
class GroupNoticePage extends ConsumerStatefulWidget {
  const GroupNoticePage({
    super.key,
    required this.conversationId,
    this.isAuth = false,
  });

  /// 群会话 id（`group-100`）
  final String conversationId;

  /// 我能不能改这一页（群主 / 管理员）。入口（群资料页）已经算过一遍，
  /// 不在这里重新拉成员 —— 多一次请求、还可能因为网络抖一下把人变成只读。
  final bool isAuth;

  @override
  ConsumerState<GroupNoticePage> createState() => _GroupNoticePageState();
}

class _GroupNoticePageState extends ConsumerState<GroupNoticePage> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 公告还没从本地库读出来（第一帧）
  bool _loading = true;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final conversation = await ref
        .read(conversationRepositoryProvider)
        .find(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _text.text = asText(conversation?.extra['notice']);
      _loading = false;
    });
    // 管理员进来自动把光标放进去（只读的人当然不给）
    if (widget.isAuth) _focus.requestFocus();
  }

  Future<void> _save() async {
    if (_saving || !widget.isAuth) return;
    setState(() => _saving = true);
    final i18n = ref.read(appI18nProvider);
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .setNotice(widget.conversationId, _text.text.trim());
      if (!mounted) return;
      noticeBus.toast(i18n.t('common.saveOk'));
      context.pop();
    } on ApiException catch (error) {
      debugPrint('[群公告] 保存失败：${error.message}');
      noticeBus.toast(error.message);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        title: Text(i18n.t('group.notice')),
        actions: <Widget>[
          if (widget.isAuth)
            TextButton(
              key: const Key('group-notice-save'),
              onPressed: _loading || _saving ? null : _save,
              child: Text(
                i18n.t('common.save'),
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.brand,
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TextField(
              key: const Key('group-notice-input'),
              controller: _text,
              focusNode: _focus,
              // 只读的人也能把全文读完、也能复制，只是改不了
              readOnly: !widget.isAuth,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(context.rpx(40)),
              ),
              style: TextStyle(
                fontSize: context.rpx(32),
                color: AppColors.text333,
                height: 1.5,
              ),
            ),
    );
  }
}
