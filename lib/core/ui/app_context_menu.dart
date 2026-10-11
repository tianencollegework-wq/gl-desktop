import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

/// 桌面上「在鼠标那儿弹出的小菜单」的一项。
///
/// 手机那条路是**深色大卡片 + 图标**（长按气泡那个，见 `message_bubble.dart`）；
/// 鼠标那条路是微信 PC 那套**白底列表**（右键，一行一项、无图标）。
class AppMenuItem<T> {
  const AppMenuItem({required this.value, required this.label});

  final T value;
  final String label;
}

/// 在鼠标位置弹一个**列表式**菜单 —— 微信 PC 的右键菜单（2026-10-04）。
///
/// 为什么要它：手机上「长按 → 弹一张深色大卡片（图标 + 字）」是手指的语言，
/// 鼠标上既难按中、也挡内容；微信 PC 的规矩是**在指针那儿弹一张白底小卡片，
/// 一行一项**。两张菜单背后是同一批动作，只是形态不同，所以这里只做「形态」
/// 这一件事，动作由调用方给。
///
/// 位置用的是**指针那一点**（1×1 的矩形，与 `showMenu` 的语义对齐：菜单顶 = 矩形
/// 顶、横向朝着空间大的那一侧长），所以贴着窗口边右键也翻得回来。
///
/// 样式跟着 `popupMenuTheme`（白底、圆角 10、投影 6），行高与字号与
/// 会话行那个右键菜单同一个口径 —— 全站只有一种「右键菜单」。
Future<T?> showAppContextMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<AppMenuItem<T>> items,
}) {
  final overlay = Overlay.of(context).context.findRenderObject();
  final size = overlay is RenderBox ? overlay.size : MediaQuery.sizeOf(context);
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
      Offset.zero & size,
    ),
    items: <PopupMenuEntry<T>>[
      for (final item in items)
        PopupMenuItem<T>(
          value: item.value,
          child: Text(
            item.label,
            style: TextStyle(
              fontSize: context.rpx(31),
              color: AppColors.text333,
            ),
          ),
        ),
    ],
  );
}
