import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/model/conversation.dart';
import '../chat_info_page.dart';

/// 桌面右栏那块聊天信息面板**开着没有**（「⋯」那颗钮切的；手机用不到）。
///
/// 放在全局是为了「在会话之间来回点时那一栏一直挂着」（微信 PC 就是这个
/// 手感：换会话只换栏里的内容）。
class ChatInfoPanelNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void close() => state = false;
}

final chatInfoPanelProvider = NotifierProvider<ChatInfoPanelNotifier, bool>(
  ChatInfoPanelNotifier.new,
);

/// 桌面右栏里那块**聊天信息**（微信 PC 点右上角「⋯」滑出来的那一栏）。
///
/// 2026-10-04 改成「面板里嵌 [ChatInfoPage] 的正文」：以前这一栏自己排了一套
/// 行（头像 / 查找聊天记录 / 免打扰 / 置顶 / 清空，外加一个「聊天信息」入口），
/// 点那个入口会推一整页**手机版**的聊天信息 —— 宽窗下那就是第四层：
/// 会话列 + 聊天 + 面板 + 详情页（聊天区被挤到 120 宽，用户截图报
/// 「一层套一层干什么啊」）。
///
/// 现在面板**就是**那一页：内容按面板宽度（300）排版，成员网格、群名称、
/// 群二维码、群公告、群管理、查找聊天记录、免打扰 / 置顶、清空、退出群聊
/// 全在这一栏里滚，不再有「从面板再推一页」这条路。手机那边整页的
/// [ChatInfoPage] 一个字节没改。
class ChatInfoPanel extends StatelessWidget {
  const ChatInfoPanel({
    super.key,
    required this.conversation,
    required this.onClearHistory,
  });

  /// 侧栏面板宽（微信 PC 约 300；与 `DesktopFrame.listWidth` 同一档）
  static const double panelWidth = 300;

  final Conversation conversation;

  /// 「清空聊天记录」：桌面这一栏是**本机口径**（微信 PC 那一栏也是，
  /// 删全体的入口在群资料里）—— 见 `ChatPage._clearHistoryFromPanel`。
  final VoidCallback onClearHistory;

  @override
  Widget build(BuildContext context) => Container(
    width: panelWidth,
    decoration: const BoxDecoration(
      color: AppColors.page,
      border: Border(left: BorderSide(color: AppColors.navDivider, width: 0.5)),
    ),
    // 面板里的字号 / 行高按**面板宽度**这一档算（`rpx` = 宽 / 750）：
    // 桌面框架把整个三栏钉在 420，直接嵌进来会按 420 排、横向溢出。
    child: MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(size: Size(panelWidth, MediaQuery.sizeOf(context).height)),
      child: ChatInfoPage(
        conversationId: conversation.id,
        isGroup: conversation.isGroup,
        embedded: true,
        onClearRecord: onClearHistory,
      ),
    ),
  );
}
