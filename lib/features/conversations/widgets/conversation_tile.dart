import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/util/emoji.dart';
import '../../../core/util/time_format.dart';
import '../../../data/model/app_setting.dart';
import '../../../data/model/conversation.dart';
import '../../../data/model/global_config.dart';
import '../../../domain/chat/conversation_rules.dart';

/// 会话列表的一行。
///
/// 逐项对应老端 `pages/message/index.vue` 里那个 `cu-item`：
/// 头像（可圆形、可方角）+ 单聊在线点、名字、`[草稿]` / `[N 人提到我]` 前缀、
/// 预览文案、右上角时间、未读红角标或静音图标、置顶行底色。
///
/// 尺寸按微信那一套对齐（手机上是 40 的头像、16 的昵称、14 的预览、12 的时间，
/// 一行约 62dp；分隔线从昵称那一列开始、不通到屏幕左边）。
class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.setting,
    required this.config,
    required this.translate,
    required this.onTap,
    this.onLongPress,
    this.unreadIsDot = false,
    this.callLabel,
  });

  /// 头像边长（微信约 40dp）+ 右侧给在线状态点留的余量
  static const double _avatarRpx = 80;
  static const double _avatarExtraRpx = 6;

  /// 行内左右内边距（微信 16dp）
  static const double _padRpx = 30;

  /// 头像与文字之间那道缝（微信 13dp）
  static const double _gapRpx = 26;

  /// 上下内边距：一行总高 ≈ 62dp（微信一屏放得下 8~9 行就是这个数）
  static const double _verticalPadRpx = 20;

  final Conversation conversation;
  final AppSetting setting;
  final GlobalConfig config;
  final Translate translate;
  final VoidCallback onTap;

  /// 长按（微信是长按弹菜单，不是左滑）：带出按下的屏幕坐标，菜单弹在那儿
  final void Function(Offset globalPosition)? onLongPress;

  /// 这一条是「标为未读」标出来的：微信此时只顶一个**小红点**、不报数字
  final bool unreadIsDot;

  /// 「语音通话中」（S6.15）：这个群里有人在开语音时，预览那一位换成它。
  ///
  /// 只换上那一位，不动名字、时间、未读角标 —— 微信里也是这个位置、这个口径：
  /// 语音开着比最后一条消息更值得先说。
  final String? callLabel;

  @override
  Widget build(BuildContext context) {
    final hasDraft = conversation.draft.isNotEmpty;
    // 语音/图片/视频/文件这一类的 `lastContent` 是**文件路径**，直接显示会露路径
    // （老端就是这样）。用统一规则换成「[语音]」「[图片]」这类占位 —— 微信也是这么显示。
    final previewSource = hasDraft
        ? conversation.draft
        : ConversationRules.previewOf(conversation, translate: translate);
    final showOnline =
        conversation.isOnline == 1 &&
        conversation.isGroup == 0 &&
        config.chatInfo.online == 1;

    // 长按要拿到「按在哪儿」（菜单弹在那个位置），而 `InkWell` 不给带坐标的回调，
    // 所以外面套一层 `GestureDetector`。`InkWell` 自己不接管长按，不会抢手势。
    // 桌面（2026-10-03）：右键同长按（微信 PC 端的会话菜单就是右键弹的）。
    return GestureDetector(
      onLongPressStart: onLongPress == null
          ? null
          : (details) => onLongPress!(details.globalPosition),
      onSecondaryTapDown: onLongPress == null
          ? null
          : (details) => onLongPress!(details.globalPosition),
      child: Material(
        // 置顶的会话用浅灰底（老端 `.top-contacts`；微信里置顶区也是这个灰）
        color: conversation.isTop == 1 ? AppColors.navBar : AppColors.white,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.rpx(_padRpx),
                  vertical: context.rpx(_verticalPadRpx),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    _avatar(context, showOnline),
                    SizedBox(width: context.rpx(_gapRpx)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            // 「我的收藏」「系统通知」要跟语言走（服务端存的是中文），
                            // 见 `ConversationRules.displayNameOf`
                            ConversationRules.displayNameOf(
                              conversation,
                              translate: translate,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              // 微信昵称 16dp、接近纯黑（`#333` 摆在微信旁边会发灰）
                              fontSize: context.rpx(31),
                              color: AppColors.text000,
                            ),
                          ),
                          SizedBox(height: context.rpx(6)),
                          Row(
                            children: <Widget>[
                              if (hasDraft)
                                _prefix(
                                  context,
                                  '[${translate('message.draft')}]',
                                ),
                              if (!hasDraft && conversation.isAt > 0)
                                _prefix(
                                  context,
                                  '[${conversation.isAt}${translate('message.remindMe')}]',
                                ),
                              Expanded(
                                child: callLabel == null
                                    ? Text(
                                        previewText(previewSource),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: context.rpx(27),
                                          color: AppColors.text999,
                                        ),
                                      )
                                    : _liveCallLabel(context, callLabel!),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: context.rpx(16)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          timeFormat(
                            conversation.lastSendTime,
                            translate: translate,
                          ),
                          style: TextStyle(
                            // 微信的时间比预览还浅一档
                            fontSize: context.rpx(24),
                            color: AppColors.textTime,
                          ),
                        ),
                        SizedBox(height: context.rpx(6)),
                        _badge(context),
                      ],
                    ),
                  ],
                ),
              ),
              // 分隔线不通到底：从昵称那一列（头像右边）开始画，微信就是这样
              Padding(
                padding: EdgeInsets.only(
                  left: context.rpx(
                    _padRpx + _avatarRpx + _avatarExtraRpx + _gapRpx,
                  ),
                ),
                child: Container(height: 0.5, color: AppColors.line),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 头像：`circleAvatar` 配置决定圆/方角
  Widget _avatar(BuildContext context, bool showOnline) {
    final size = context.rpx(_avatarRpx);
    final image = conversation.avatar.isEmpty
        ? Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            color: AppColors.gray,
            child: Icon(
              Icons.person,
              size: size * 0.6,
              color: AppColors.text999,
            ),
          )
        : Image.network(
            conversation.avatar,
            width: size,
            height: size,
            fit: BoxFit.cover,
            // 头像挂了显示占位，不要整行报错
            errorBuilder: (context, error, stack) => Container(
              width: size,
              height: size,
              color: AppColors.gray,
              child: Icon(
                Icons.person,
                size: size * 0.6,
                color: AppColors.text999,
              ),
            ),
          );

    return SizedBox(
      width: size + context.rpx(_avatarExtraRpx),
      height: size + context.rpx(_avatarExtraRpx),
      child: Stack(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(
              setting.circleAvatar ? size : context.rpx(10),
            ),
            child: image,
          ),
          if (showOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: context.rpx(20),
                height: context.rpx(20),
                decoration: BoxDecoration(
                  color: AppColors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.white, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 圆点（红点 / 静音灰点）。
  ///
  /// 高度**故意和数字角标、空角标一样**（34rpx）：让每一行的高度不因角标形态而变，
  /// 微信一屏的行高是齐的。右边留 4rpx，视觉上跟数字角标那一列对齐。
  Widget _dot(BuildContext context, Color color, {required double sizeRpx}) {
    final size = context.rpx(sizeRpx);
    return Padding(
      padding: EdgeInsets.only(right: context.rpx(4)),
      child: SizedBox(
        height: context.rpx(34),
        child: Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }

  /// 「语音通话中」那一行：一颗小喇叭 + 绿字（与横幅同一个绿，一眼认出是同一件事）
  Widget _liveCallLabel(BuildContext context, String label) => Row(
    children: <Widget>[
      Icon(
        Icons.phone_in_talk_rounded,
        size: context.rpx(26),
        color: AppColors.brand,
      ),
      SizedBox(width: context.rpx(8)),
      Flexible(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: context.rpx(27), color: AppColors.brand),
        ),
      ),
    ],
  );

  Widget _prefix(BuildContext context, String text) => Padding(
    padding: EdgeInsets.only(right: context.rpx(8)),
    child: Text(
      text,
      style: TextStyle(fontSize: context.rpx(25), color: AppColors.red),
    ),
  );

  /// 未读角标 / 静音图标（老端：有未读显示红角标，免打扰且无未读显示静音图标）。
  ///
  /// 与微信对齐的三条：红角标换成 `#FA5151`、单个数字时是**正圆**；
  /// 免打扰的会话有未读时**只点一个小灰点、不报数字**（微信就是这么干的）；
  /// 手动「标为未读」的那一条也是红点、不报数字。
  Widget _badge(BuildContext context) {
    if (conversation.unread > 0) {
      if (unreadIsDot) {
        return _dot(context, AppColors.unreadRed, sizeRpx: 20);
      }
      if (conversation.muted) {
        return _dot(context, AppColors.mutedDot, sizeRpx: 16);
      }
      return Container(
        constraints: BoxConstraints(minWidth: context.rpx(36)),
        height: context.rpx(36),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: context.rpx(8)),
        decoration: BoxDecoration(
          color: AppColors.unreadRed,
          borderRadius: BorderRadius.circular(context.rpx(18)),
        ),
        child: Text(
          conversation.unread > 99 ? '99+' : '${conversation.unread}',
          style: TextStyle(fontSize: context.rpx(24), color: AppColors.white),
        ),
      );
    }
    if (conversation.muted) {
      return Icon(
        Icons.notifications_off_outlined,
        size: context.rpx(30),
        color: AppColors.text999,
      );
    }
    return SizedBox(height: context.rpx(34));
  }
}
