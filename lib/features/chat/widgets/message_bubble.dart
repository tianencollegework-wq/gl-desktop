import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/ui/app_context_menu.dart';
import '../../../core/ui/desktop_overlay.dart';
import '../../../core/ui/link_opener.dart';
import '../../../core/util/emoji.dart';
import '../../../core/util/link_text.dart';

/// 聊天里点链接那三道闸门也提供给别的入口（扫一扫）：老 import 路径照旧能用。
export '../../../core/ui/link_opener.dart' show openChatLink;
import '../../../core/util/rich_text.dart';
import '../../../core/util/time_format.dart';
import '../../../data/model/message.dart';
import '../../../domain/chat/message_actions.dart';
import '../../../domain/chat/message_media.dart';
import '../../../domain/lingting/lingting_card.dart';
import '../../../domain/news/news_card.dart';
import 'media/call_bubble.dart';
import 'media/contact_bubble.dart';
import 'media/file_bubble.dart';
import 'media/image_bubble.dart';
import 'media/location_bubble.dart';
import 'media/music_card_bubble.dart';
import 'media/news_card_bubble.dart';
import 'media/unsupported_bubble.dart';
import 'media/video_bubble.dart';
import 'media/voice_bubble.dart';

/// 一条消息的气泡：头像 + （别人的消息才有）名字/时间/群角色 + 内容。
///
/// 结构照 `pages/message/chat.vue` 里那段 `cu-item`：头像两边都有，
/// 自己的消息靠右；**只有文字消息带那个蓝/白气泡**（老端也是：
/// 气泡底色写在 `im-text.vue` 里，语音/位置/名片各自有自己的底）。
///
/// 各类型的渲染见 `widgets/media/`，载荷解析见 `domain/chat/message_media.dart`。
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.circleAvatar,
    required this.translate,
    this.showOnline = false,
    this.onAvatarTap,
    this.onContentTap,
    this.onRetry,
    this.onQuote,
    this.onAction,
    this.actions = const <MessageAction>[],
    this.canReedit = false,
    this.onReedit,
  });

  final Message message;
  final bool mine;
  final bool circleAvatar;

  /// 对方是否在线（单聊才显示那个绿点）
  final bool showOnline;

  final Translate translate;

  /// 点了头像：进这个人的详情页（自己的头像是「我」的资料页）。
  ///
  /// 老端在聊天页点头像**没反应**（只有聊天信息页那圈头像能点），
  /// 用户 2026-09-20 要求补上 —— 微信里聊天页和资料页都能点头像。
  final void Function(Message message)? onAvatarTap;

  /// 点了图片/表情/视频/文件/位置/名片等「有内容」的气泡。
  /// 图片与表情走预览页（[ImagePreviewPage]）；其余类型在 S4.6 / M5 / M6 接。
  final void Function(Message message)? onContentTap;

  /// 重发一条失败的消息（气泡上那个红叹号）
  final Future<void> Function(Message message)? onRetry;

  /// 长按菜单里选了「引用」
  final void Function(Message message)? onQuote;

  /// 长按菜单里选了某一项（要显示哪几项由 `domain/chat/message_actions.dart` 算）
  final void Function(Message message, MessageAction action)? onAction;

  /// 长按菜单里显示哪些项（顺序已排好）
  final List<MessageAction> actions;

  /// 撤回提示上那个「重新编辑」能不能点（老端 `common.reedit`）
  final bool canReedit;

  final void Function(Message message)? onReedit;

  @override
  Widget build(BuildContext context) {
    // 撤回提示和「创建了群聊 / 小明加入了群聊」这类**系统消息**，老端都是
    // `type == 'event'`，画成居中的一条半透明小黑条（`.cu-info`），不是一个气泡。
    // 用户 2026-09-21 反馈：新建群聊后我们这边显示的是「暂不支持的消息类型」。
    if (message.isUndo == 1 || message.type == 'event') {
      return _SystemLine(
        text: _systemText,
        translate: translate,
        // 「重新编辑」只给**自己撤的**那条（见 `domain/chat/message_actions.dart`）
        canReedit: message.isUndo == 1 && canReedit,
        onReedit: onReedit == null ? null : () => onReedit!(message),
      );
    }

    final avatar = _avatar(context);
    final body = _body(context);

    // 刻意**不做老端那个「双击气泡弹消息详情」**：Flutter 里注册 onDoubleTap 会让
    // 同级的单击（图片预览、语音播放、文件打开）多出～300ms 延迟，而这几个单击
    // 比「看详情」重要。要看全文可以长按 → 复制。
    return GestureDetector(
      onLongPressStart: _hasMenu
          ? (details) => _showMenu(context, details.globalPosition)
          : null,
      // 桌面（2026-10-03）：右键等于长按 —— 鼠标上没有「长按」这个动作，
      // 微信 PC 端的消息菜单就是右键弹的。菜单本身共用一份（_showMenu）。
      onSecondaryTapDown: _hasMenu
          ? (details) => _showMenu(context, details.globalPosition)
          : null,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(20),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: mine
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: mine
              ? <Widget>[
                  _statusMark(context),
                  body,
                  SizedBox(width: context.rpx(20)),
                  avatar,
                ]
              : <Widget>[
                  avatar,
                  SizedBox(width: context.rpx(20)),
                  body,
                  // 气泡尾巴之外留白，避免贴到屏幕右边缘
                  SizedBox(width: context.rpx(60)),
                ],
        ),
      ),
    );
  }

  bool get _hasMenu => actions.isNotEmpty;

  /// 居中那条系统消息显示什么字。
  ///
  /// * 撤回：老端渲染的是服务端给的 `content`。**本机撤的那条不能照抄** ——
  ///   `patchMessage` 只把 `is_undo` 置 1，`content` 还是原文（照抄就把原话
  ///   又显示出来了），所以自己撤的固定用语言包里那句「你撤回了一条消息」；
  ///   别人撤的用服务端给的「小明撤回了一条消息」。
  /// * 群系统消息（`type == 'event'` 且不是撤回）：服务端给什么显示什么
  ///   （「创建了群聊」「小明加入了群聊」…）。
  String get _systemText {
    final content = richToPlainText(message.content);
    if (message.isUndo == 1) {
      return (mine || content.isEmpty)
          ? translate('message.undoMsged')
          : content;
    }
    return content;
  }

  /// 消息菜单：**同一个动作集、两种形态** —— 手机那套是手指的，鼠标那套是微信 PC 的。
  ///
  /// * **手机**：微信那个**深色浮动小卡片**（带一个指着气泡的小尖角）。
  ///   用户 2026-09-21 发来微信截图要求照抄 —— 之前这里是个白色底部弹层
  ///   （自己的设计），跟微信差得远。微信的规则：半透明深灰圆角卡片
  ///   （`menuDark`）、白图标 + 白字、**一行 5 个**、行之间一条淡分隔线；卡片压在
  ///   长按位置上方，尖角朝下指着气泡；上方放不开就翻到下面；左右也夹在屏幕里；
  ///   点别处关掉（屏障透明，微信不压暗背景）。位置与尺寸见 [_MessageMenuCard]。
  /// * **桌面（鼠标）**：微信 PC 那套**白底列表** —— 在指针那儿弹、一行一项、
  ///   没有图标（2026-10-04 用户：「撤回引用这些还是不符合电脑端 UI 设计，
  ///   这是手机的习惯，你学一下微信」）。形态由 [showAppContextMenu] 提供，
  ///   与会话行那个右键菜单共用一份，全站只有一种「右键菜单」。
  ///
  /// 右键（`onSecondaryTapDown`）走的是同一个入口：鼠标上没有「长按」这个动作。
  Future<void> _showMenu(BuildContext context, Offset anchor) async {
    if (desktopFeaturesFor(context)) {
      final action = await showAppContextMenu<MessageAction>(
        context: context,
        globalPosition: anchor,
        items: <AppMenuItem<MessageAction>>[
          for (final action in actions)
            AppMenuItem(
              value: action,
              label: translate(actionLabelKey(action)),
            ),
        ],
      );
      if (action != null) onAction?.call(message, action);
      return;
    }
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: translate('common.close'),
      // 微信不压暗背景
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          _MessageMenuCard(
            anchor: anchor,
            actions: actions,
            translate: translate,
            onPick: (action) {
              Navigator.of(dialogContext).pop();
              onAction?.call(message, action);
            },
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              // 从尖角那一侧长出来（微信那个小小的弹出感）
              scale: Tween<double>(begin: 0.86, end: 1).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOut),
              ),
              child: child,
            ),
          ),
    );
  }

  /// 自己发出去的消息的发送状态：发送中转圈、失败红叹号（点一下重发）。
  /// 老端画在气泡里面，这里放在气泡左边，不挡内容。
  Widget _statusMark(BuildContext context) {
    if (!mine || message.status == MessageStatus.sent) {
      return const SizedBox.shrink();
    }
    if (message.isFailed) {
      return GestureDetector(
        onTap: () => onRetry?.call(message),
        child: Padding(
          padding: EdgeInsets.only(right: context.rpx(12)),
          child: Icon(
            Icons.error_outline,
            size: context.rpx(36),
            color: AppColors.red,
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(right: context.rpx(12)),
      child: SizedBox(
        width: context.rpx(28),
        height: context.rpx(28),
        child: const CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  /// 头像（微信里可点：进这个人的详情页）
  Widget _avatar(BuildContext context) {
    final avatar = _avatarImage(context);
    final tap = onAvatarTap;
    if (tap == null) return avatar;
    return GestureDetector(
      onTap: () => tap(message),
      // 头像旁边有留白，整个格子都要能点中
      behavior: HitTestBehavior.opaque,
      child: avatar,
    );
  }

  Widget _avatarImage(BuildContext context) {
    final size = context.rpx(80);
    final image = message.fromUserAvatar.isEmpty
        ? Container(
            width: size,
            height: size,
            color: AppColors.gray,
            child: Icon(
              Icons.person,
              size: size * 0.6,
              color: AppColors.text999,
            ),
          )
        : Image.network(
            message.fromUserAvatar,
            width: size,
            height: size,
            fit: BoxFit.cover,
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
      width: size + context.rpx(8),
      height: size + context.rpx(8),
      child: Stack(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(
              circleAvatar ? size : context.rpx(10),
            ),
            child: image,
          ),
          if (showOnline && !mine)
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

  Widget _body(BuildContext context) {
    final role = _role(message);

    return Flexible(
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: <Widget>[
          // 只有别人的消息才显示名字与时间（老端就是这样的）
          if (!mine)
            Padding(
              padding: EdgeInsets.only(bottom: context.rpx(6)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (role < 3) _roleTag(context, role),
                  Text(
                    '${message.fromUserName}  ',
                    style: TextStyle(
                      fontSize: context.rpx(24),
                      color: AppColors.text666,
                    ),
                  ),
                  Text(
                    timeFormat(message.sendTime, translate: translate),
                    style: TextStyle(
                      fontSize: context.rpx(22),
                      color: AppColors.text999,
                    ),
                  ),
                ],
              ),
            ),
          _bubbleWithTail(context),
          // 引用块（`extends.content`）：老端只画在文字消息下面（`im-text.vue`）
          if (message.type == 'text' && _quoted.isNotEmpty)
            Container(
              margin: EdgeInsets.only(top: context.rpx(16)),
              padding: EdgeInsets.all(context.rpx(8)),
              constraints: BoxConstraints(maxWidth: context.rpx(380)),
              decoration: BoxDecoration(
                color: const Color(0xFFE3E3E3),
                borderRadius: BorderRadius.circular(context.rpx(8)),
              ),
              child: Text(
                _quoted,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(24),
                  color: AppColors.text333,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 气泡 + 微信那个小尖角。
  ///
  /// 只有「自带底色」的那几类（文字、语音）加尖角：图片/文件/名片这些老端本来
  /// 就没有气泡底，硬加一个三角会很怪。尖角在气泡外侧、贴上边缘（微信也是这个位置）。
  Widget _bubbleWithTail(BuildContext context) {
    final content = _content(context);
    if (!_hasTail) return content;
    final tail = CustomPaint(
      size: Size(context.rpx(14), context.rpx(26)),
      painter: _BubbleTailPainter(color: bubbleColorOf(mine), mine: mine),
    );
    // 尾巴的竖直位置：文字消息贴第一行（微信那样），语音/通话这种矮气泡贴中间
    final centered = message.type == 'voice' || message.type == 'webrtc';
    final tailBox = Padding(
      padding: EdgeInsets.only(top: centered ? 0 : context.rpx(12)),
      child: tail,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: mine ? <Widget>[content, tailBox] : <Widget>[tailBox, content],
    );
  }

  /// 这几类才有气泡底，才配得上一根小尾巴
  /// （微信里语音与通话记录也是气泡，同样带尾巴）
  bool get _hasTail =>
      message.type == 'text' ||
      message.type == 'voice' ||
      message.type == 'webrtc';

  /// 按类型分发（老端 `chat.vue` 里那一长串 `v-if/v-else-if`）
  Widget _content(BuildContext context) {
    void onTap() => onContentTap?.call(message);

    return switch (message.type) {
      'text' => _textBubble(context),
      'image' => ImageBubble(payload: imagePayloadOf(message), onTap: onTap),
      // 动态表情：老端就是一张 300rpx 的图
      'emoji' => StickerBubble(url: message.content, onTap: onTap),
      'voice' => VoiceBubble(payload: voicePayloadOf(message), mine: mine),
      'video' => VideoBubble(payload: videoPayloadOf(message), onTap: onTap),
      'file' => FileBubble(
        payload: filePayloadOf(message),
        translate: translate,
        onTap: onTap,
      ),
      'location' => LocationBubble(
        payload: locationPayloadOf(message),
        onTap: onTap,
      ),
      'contact' => ContactBubble(
        payload: contactPayloadOf(message),
        translate: translate,
        onTap: onTap,
      ),
      'webrtc' => CallBubble(
        payload: callPayloadOf(message),
        mine: mine,
        onTap: onTap,
      ),
      // 卡片不分你我、统一白底（颜色在卡片自己那边定，这里不传 `mine`）
      lingtingMessageType => MusicCardBubble(
        card: musicCardOf(message),
        sourceLabel: translate('lingting.title'),
        onTap: onTap,
      ),
      newsMessageType => NewsCardBubble(
        card: newsCardOf(message),
        sourceLabel: translate('news.title'),
        onTap: onTap,
      ),
      _ => UnsupportedBubble(
        type: message.type,
        mine: mine,
        translate: translate,
      ),
    };
  }

  /// 文字消息的气泡（旧版 `_bubble`）
  ///
  /// 颜色按微信：自己发的是绿 `#95EC69`（字是**黑的**，微信不用白字），
  /// 对方是纯白。
  Widget _textBubble(BuildContext context) {
    const radius = 8.0;

    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - context.rpx(260),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(18),
        vertical: context.rpx(10),
      ),
      decoration: BoxDecoration(
        color: bubbleColorOf(mine),
        borderRadius: BorderRadius.circular(context.rpx(radius)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      // 网页端发来的 `content` 是 HTML（`<p><span class="chat-grid-input">Hi</span></p>`），
      // 不剥就会把标签原样显示出来（真机上就是这么冒出来的）
      child: _richText(context, richToPlainText(message.content)),
    );
  }

  /// 文本 + 表情混排：`[!1f600]` 换成**系统表情字符**，其余按文字走。
  ///
  /// 老端这里是把 token 换成 `{apiUrl}/static/img/emoji/twitter/*.png` 的图片；
  /// 新端直接用系统字体渲染那个字符（码值就是 Unicode 码点），
  /// 于是不依赖服务端静态资源、离线也能显示，历史消息里的 token 一样能看。
  ///
  /// 网址（`https://…`、`www.…`、`gracelinkim.com`）额外做成**可点的蓝字**，
  /// 点了走应用内浏览器 —— 详见 [_MessageRichText] 与 [openChatLink]。
  Widget _richText(BuildContext context, String source) {
    if (source.isEmpty) return const SizedBox.shrink();

    // 字体族**继承环境**，只覆盖字号 / 行高 / 颜色。
    //
    // 这里原先是另起一个裸 `TextStyle`。`DefaultTextStyle` 是**替换**而不是
    // 合并，裸样式会把环境里的字体族一起丢掉，文字于是落到「引擎默认字体」上
    // —— 真机上那个默认恰好就是系统字体（Material 的 Typography 各平台用的
    // 也是系统字体族，Windows 是 Segoe UI、Android 是 Roboto），所以观感不变；
    // 但只要有人给主题配了别的字体，气泡就不跟了。
    //
    // 2026-10-10：出官网截图时发现的 —— 测试环境没有「引擎默认字体」，
    // 无字体族的文本会渲染成方块，气泡内容整段看不见。
    final ambient = DefaultTextStyle.of(context).style;
    return DefaultTextStyle(
      style: TextStyle(
        fontSize: context.rpx(30),
        height: 1.3,
        // 绿气泡里是黑字（微信），白气泡里是深灰黑
        color: mine ? AppColors.bubbleMineText : AppColors.text333,
        fontFamily: ambient.fontFamily,
        fontFamilyFallback: ambient.fontFamilyFallback,
      ),
      child: _MessageRichText(source: source),
    );
  }

  Widget _roleTag(BuildContext context, int role) => Container(
    margin: EdgeInsets.only(right: context.rpx(6)),
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(8),
      vertical: context.rpx(2),
    ),
    decoration: BoxDecoration(
      color: role == 1 ? AppColors.orange : AppColors.blue,
      borderRadius: BorderRadius.circular(context.rpx(6)),
    ),
    child: Text(
      role == 1 ? translate('group.owner') : translate('group.manage'),
      style: TextStyle(fontSize: context.rpx(20), color: AppColors.white),
    ),
  );

  String get _quoted {
    final value = message.ext['content'];
    // 引用块也可能来自网页端（那边一并是 HTML），同样只取一行纯文本
    return value == null ? '' : richToSingleLine(value.toString());
  }

  /// 老端用 `item.role` 表示群角色，值在服务端返回里
  int _role(Message message) {
    final value = message.extra['role'] ?? message.ext['role'];
    return int.tryParse(value?.toString() ?? '') ?? 3;
  }
}

/// 居中那条系统小字：撤回提示 + 「创建了群聊」这类事件消息（老端 `.cu-info` / `common.reedit` 那段）。
///
/// 样式照老端：半透明黑底、白字、24upx、左右 12upx 内边距、最大宽 400upx。
/// 「重新编辑」那里，老端对**任何人的**撤回提示都给且只看时间窗，
/// 新端加了一道「必须是自己撤的」（见 `canReedit`）。
class _SystemLine extends StatelessWidget {
  const _SystemLine({
    required this.text,
    required this.translate,
    this.canReedit = false,
    this.onReedit,
  });

  /// 显示的那行字
  final String text;

  final Translate translate;

  final bool canReedit;

  /// 点了「重新编辑」（把原文填回输入框）
  final VoidCallback? onReedit;

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    padding: EdgeInsets.symmetric(vertical: context.rpx(16)),
    child: Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(16),
        vertical: context.rpx(6),
      ),
      decoration: BoxDecoration(
        color: const Color(0x22000000),
        borderRadius: BorderRadius.circular(context.rpx(8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            text,
            style: TextStyle(fontSize: context.rpx(22), color: AppColors.white),
          ),
          if (canReedit)
            GestureDetector(
              onTap: onReedit,
              child: Padding(
                padding: EdgeInsets.only(left: context.rpx(12)),
                child: Text(
                  translate('common.reedit'),
                  style: TextStyle(
                    fontSize: context.rpx(22),
                    color: AppColors.brand,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// 菜单项图标。
///
/// 微信那张卡片里用的是**实心白字形**（老端那套描边 iconfont 在这块深色底上
/// 会显得很碎），所以除了「转发」用一面镜像的弯箭头（微信就是个右弯箭头），
/// 其余都换成 Material 的实心字形。
IconData actionIcon(MessageAction action) => switch (action) {
  MessageAction.undo => Icons.replay,
  MessageAction.copy => Icons.copy,
  // 我们的「存表情」= 微信的「收藏」那一格，用心形更好认
  MessageAction.saveEmoji => Icons.favorite,
  MessageAction.forward => Icons.reply,
  MessageAction.quote => Icons.format_quote,
  MessageAction.delete => Icons.delete,
};

/// 长按菜单那张**深色浮动小卡片**（微信的长按菜单）。
///
/// 全屏一层透明屏障（点一下关掉）+ 一张按长按位置摆好的卡片：
/// 压在手指上方、尖角朝下指着气泡；上方放不开就翻到下面、尖角朝上。
/// 尺寸用 rpx 算，一格 112rpx、一行 150rpx，一行 5 个（微信那副牌）。
class _MessageMenuCard extends StatelessWidget {
  const _MessageMenuCard({
    required this.anchor,
    required this.actions,
    required this.translate,
    required this.onPick,
  });

  /// 长按的位置（全局坐标）
  final Offset anchor;

  final List<MessageAction> actions;
  final Translate translate;
  final void Function(MessageAction action) onPick;

  /// 一行放几个（微信 5 个）
  static const int columns = 5;

  /// 每格宽 / 行高 / 卡片内边距 / 尖角高（rpx）
  static const double columnRpx = 112;
  static const double rowRpx = 150;
  static const double padRpx = 12;
  static const double tailRpx = 16;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;

    final pad = context.rpx(padRpx);
    final divider = context.rpx(2);
    final cols = math.min(actions.length, columns);
    final rows = (actions.length / columns).ceil();
    final cardWidth = cols * context.rpx(columnRpx) + pad * 2;
    final cardHeight =
        rows * context.rpx(rowRpx) + (rows - 1) * divider + pad * 2;
    final tail = context.rpx(tailRpx);
    final gap = context.rpx(10);
    final edge = context.rpx(16);

    // 上方放得下就朝下指，放不下就翻到下面朝上指
    final above =
        anchor.dy - cardHeight - tail - gap >= media.padding.top + edge;
    final top = above ? anchor.dy - cardHeight - tail - gap : anchor.dy + gap;
    final left = (anchor.dx - cardWidth / 2)
        .clamp(edge, math.max(edge, screen.width - cardWidth - edge))
        .toDouble();
    // 尖角中心跟着手指走，但不贴到卡片两角
    final tailX = (anchor.dx - left)
        .clamp(
          context.rpx(28),
          math.max(context.rpx(28), cardWidth - context.rpx(28)),
        )
        .toDouble();

    final card = Container(
      width: cardWidth,
      height: cardHeight,
      decoration: BoxDecoration(
        color: AppColors.menuDark,
        borderRadius: BorderRadius.circular(context.rpx(16)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: <Widget>[
          for (var index = 0; index < rows; index++) ...<Widget>[
            if (index > 0)
              Divider(
                height: divider,
                thickness: 1,
                indent: pad,
                endIndent: pad,
                color: const Color(0x33FFFFFF),
              ),
            SizedBox(
              height: context.rpx(rowRpx),
              child: Row(
                children: <Widget>[
                  // 最后一行可能不满，微信是**左对齐**（不居中）
                  for (final action
                      in actions.skip(index * columns).take(columns))
                    SizedBox(
                      width: context.rpx(columnRpx),
                      child: _item(context, action),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    final tailPaint = SizedBox(
      width: cardWidth,
      height: tail,
      child: CustomPaint(
        painter: _MenuTailPainter(
          color: AppColors.menuDark,
          centerX: tailX,
          halfWidth: context.rpx(11),
          pointsDown: above,
        ),
      ),
    );

    return Stack(
      children: <Widget>[
        Positioned(
          left: left,
          top: top,
          // 卡片自己也要吸住点击（微信里点卡片空白处不会关菜单，
          // 不吸的话就落到后面那层屏障上、把菜单关了）
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Column(
              children: above
                  ? <Widget>[card, tailPaint]
                  : <Widget>[tailPaint, card],
            ),
          ),
        ),
      ],
    );
  }

  Widget _item(BuildContext context, MessageAction action) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => onPick(action),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        // 「转发」那面箭头老端也是镜像的（微信是个向右的弯箭头）
        Transform.flip(
          flipX: action == MessageAction.forward,
          child: Icon(
            actionIcon(action),
            size: context.rpx(46),
            color: AppColors.white,
          ),
        ),
        SizedBox(height: context.rpx(12)),
        Text(
          translate(actionLabelKey(action)),
          style: TextStyle(fontSize: context.rpx(24), color: AppColors.white),
        ),
      ],
    ),
  );
}

/// 卡片下面（或上面）那个指着气泡的小三角
class _MenuTailPainter extends CustomPainter {
  const _MenuTailPainter({
    required this.color,
    required this.centerX,
    required this.halfWidth,
    required this.pointsDown,
  });

  final Color color;
  final double centerX;
  final double halfWidth;

  /// `true` 尖朝下（卡片在气泡上方）、`false` 尖朝上
  final bool pointsDown;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (pointsDown) {
      path
        ..moveTo(centerX - halfWidth, 0)
        ..lineTo(centerX + halfWidth, 0)
        ..lineTo(centerX, size.height);
    } else {
      path
        ..moveTo(centerX, 0)
        ..lineTo(centerX - halfWidth, size.height)
        ..lineTo(centerX + halfWidth, size.height);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MenuTailPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.centerX != centerX ||
      oldDelegate.halfWidth != halfWidth ||
      oldDelegate.pointsDown != pointsDown;
}

/// 菜单项文案的 i18n key（与老端逐字对应）
String actionLabelKey(MessageAction action) => switch (action) {
  MessageAction.undo => 'message.undo',
  MessageAction.copy => 'message.copy',
  MessageAction.saveEmoji => 'message.saveEmoji',
  MessageAction.forward => 'message.forward',
  MessageAction.quote => 'message.quote',
  MessageAction.delete => 'common.del',
};

/// 气泡底色（微信：自己发的绿 `#95EC69`、对方的白）
Color bubbleColorOf(bool mine) =>
    mine ? AppColors.bubbleMine : AppColors.bubbleOther;

/// 点聊天里的一串网址，三道岔路 → 实现在 [openChatLink]（`core/ui/link_opener.dart`）。
///
/// 语义没变，只是把它搬到一个共享文件里：**扫一扫扫到链接也要走同一条路**
/// （用户 2026-09-27 明确要求两者一致）。本文件在顶部照旧把它导出，
/// 老的 import 路径不作废。
///
/// 文本 + 表情 + 网址混排：表情 token 换成系统表情字符，网址做成可点击的蓝字。
///
/// 做成有状态的是因为 [TapGestureRecognizer] 必须**自己回收**：
/// 它不是在 build 里随便 new 一下就能丢的东西（不 dispose 会漏手势资源，
/// 反复重建还会把上一条消息的 recognizer 留在树上）。
class _MessageRichText extends StatefulWidget {
  const _MessageRichText({required this.source});

  /// 已经剥过 HTML 的纯文本（`richToPlainText` 之后）
  final String source;

  @override
  State<_MessageRichText> createState() => _MessageRichTextState();
}

class _MessageRichTextState extends State<_MessageRichText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];
  List<TextSpan> _spans = const <TextSpan>[];

  @override
  void initState() {
    super.initState();
    _rebuildSpans();
  }

  @override
  void didUpdateWidget(covariant _MessageRichText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _rebuildSpans();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  /// 把文案拆成 span：表情一段一段，纯文字那几段再按网址切一刀。
  void _rebuildSpans() {
    _disposeRecognizers();
    final spans = <TextSpan>[];

    for (final segment in parseEmojiSegments(widget.source)) {
      switch (segment) {
        // 系统表情：跟着正文的字号走（微信里表情和字一样高）
        case EmojiCharSegment():
          spans.add(TextSpan(text: segment.char));
        case TextEmojiSegment():
          for (final link in parseLinkSegments(segment.text)) {
            switch (link) {
              case PlainLinkSegment():
                spans.add(TextSpan(text: link.text));
              case UrlLinkSegment():
                final recognizer = TapGestureRecognizer()
                  ..onTap = () => openChatLink(context, link.url);
                _recognizers.add(recognizer);
                spans.add(
                  TextSpan(
                    text: link.text,
                    recognizer: recognizer,
                    // 微信：链接是蓝字、不加下划线（绿气泡里同样是这个蓝）
                    style: const TextStyle(
                      color: AppColors.wechatLinkBlue,
                      decoration: TextDecoration.none,
                    ),
                  ),
                );
            }
          }
      }
    }

    _spans = spans;
  }

  @override
  Widget build(BuildContext context) => Text.rich(TextSpan(children: _spans));
}

/// 气泡那根小尾巴：一个朝内的直角三角形（自己发在右、对方在左）
class _BubbleTailPainter extends CustomPainter {
  const _BubbleTailPainter({required this.color, required this.mine});

  final Color color;
  final bool mine;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (mine) {
      // 贴在气泡右边的那个尖角朝左
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, size.height / 2)
        ..lineTo(0, size.height);
    } else {
      path
        ..moveTo(size.width, 0)
        ..lineTo(0, size.height / 2)
        ..lineTo(size.width, size.height);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BubbleTailPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.mine != mine;
}
