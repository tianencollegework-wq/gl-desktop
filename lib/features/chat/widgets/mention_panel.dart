import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/util/emoji.dart';
import '../../../core/util/time_format.dart';
import '../../../data/model/message.dart';
import '../../../data/repo/message_repository.dart';
import '../../../core/ui/desktop_overlay.dart';

/// 「N 人提到我」面板（老端聊天页那个 `fixed-item` + `atmodel` 弹层）。
///
/// **与老端不同**：老端点开是调 `getMessageInfo` 拉一份服务端数据、再逐条
/// 「查看上下文」用 `getMessageContext` 拉前后文；新端本地就是全部历史，
/// 直接把库里 @ 到我的消息列出来（离线也能看）。
Future<void> showMentionPanel(
  BuildContext context, {
  required String conversationId,
  required String myUserId,
}) => showAppSheet<void>(
  context: context,
  backgroundColor: AppColors.white,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (context) =>
      _MentionPanel(conversationId: conversationId, myUserId: myUserId),
);

class _MentionPanel extends ConsumerStatefulWidget {
  const _MentionPanel({required this.conversationId, required this.myUserId});

  final String conversationId;
  final String myUserId;

  @override
  ConsumerState<_MentionPanel> createState() => _MentionPanelState();
}

class _MentionPanelState extends ConsumerState<_MentionPanel> {
  late Future<List<Message>> _messages;

  @override
  void initState() {
    super.initState();
    _messages = ref
        .read(messageRepositoryProvider)
        .mentioning(widget.conversationId, widget.myUserId);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        children: <Widget>[
          Container(
            height: context.rpx(90),
            padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
            alignment: Alignment.center,
            child: Row(
              children: <Widget>[
                Text(
                  i18n.t('message.detail'),
                  style: TextStyle(
                    fontSize: context.rpx(30),
                    color: AppColors.text333,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Text(
                    i18n.t('common.close'),
                    style: TextStyle(
                      fontSize: context.rpx(28),
                      color: AppColors.red,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Message>>(
              future: _messages,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final messages = snapshot.data!;
                if (messages.isEmpty) {
                  return Center(
                    child: Text(
                      i18n.t('common.noData'),
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        color: AppColors.text666,
                      ),
                    ),
                  );
                }
                return ListView(
                  children: <Widget>[
                    for (final message in messages)
                      _row(context, i18n, message),
                  ],
                );
              },
            ),
          ),
          SizedBox(height: context.bottomSafeHeight),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, AppI18n i18n, Message message) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(30),
      vertical: context.rpx(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                message.fromUserName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(26),
                  color: AppColors.text333,
                ),
              ),
            ),
            Text(
              dateFormat('Y-m-d H:i', message.sendTime),
              style: TextStyle(
                fontSize: context.rpx(22),
                color: AppColors.text999,
              ),
            ),
          ],
        ),
        SizedBox(height: context.rpx(8)),
        // 只显示文字版预览（图片/语音这些给个「[图片]」占位）
        Text(
          message.type == 'text'
              ? previewText(message.content)
              : '[${i18n.t('common.photo')}]',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: context.rpx(26), color: AppColors.text666),
        ),
      ],
    ),
  );
}
