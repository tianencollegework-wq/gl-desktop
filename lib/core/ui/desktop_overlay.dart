import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/desktop_shell.dart';
import '../theme/app_colors.dart';

/// 弹层（对话框 / 底部弹层）在宽窗桌面上的宽度基准。
///
/// 与 [DesktopShell.maxWidth] 同值：那一档本来就是「按手机屏宽排」的那一档，
/// 桌面上弹层与中栏面板同宽同字号。
const double kDesktopOverlayWidth = DesktopShell.maxWidth;

/// 这一帧该走**桌面弹层**形态吗：桌面 + 功能开着 + **窗口**够宽。
///
/// 只能 `build` 里调（内部要读 provider 的容器）。用 [realWindowWidth] 问窗口宽度，
/// 不能用 `MediaQuery`（桌面框架在屏上时它被覆写成整窗宽，只有主界面那条路是 500）。
bool desktopOverlayLayout(BuildContext context) =>
    desktopFeaturesFor(context) &&
    realWindowWidth(context) >= kDesktopFrameMinWidth;

/// 读桌面开关，**没挂 ProviderScope 时退回编译期的那个开关**。
///
/// 为什么要有这个 try：全站那些弹窗测试起的是个空壳 `MaterialApp`
/// （`test/core/wechat_dialog_test.dart` 那一套），树上没有 ProviderScope ——
/// 直接 `ref.watch` 会抛「No ProviderScope found」，把一批与桌面无关的用例
/// 全打红。那种场景本来也拿不到 override，用 `desktopFeaturesEnabled`
/// （测试里恒为 false）就是正确答案。
bool desktopFeaturesFor(BuildContext context) {
  try {
    return ProviderScope.containerOf(
      context,
      listen: false,
    ).read(desktopFeaturesProvider);
  } on StateError {
    return desktopFeaturesEnabled;
  }
}

/// 弹层里的 **rpx 尺度归位**：把子树看到的宽度钉回 [kDesktopOverlayWidth]。
///
/// 为什么需要它：桌面框架在屏上时 [DesktopShell] 不再把内容夹到 500（框架自己
/// 摆列），于是 `MediaQuery` 的宽度就是**真实窗口宽** —— 弹层里那些按手机屏宽
/// 写的 `rpx(600)`（微信确认框的框宽）会按 1200 算成 960，弹出来像个放大镜里的
/// 手机。钉回 500 之后，桌面上的确认框就是 400 宽的一张小窗，与中栏面板同一档。
///
/// 手机 / 窄窗直接返回 [child]（`desktopFeaturesProvider` 关着也是），
/// 所以那两条路上的像素一个都不动。
class DesktopOverlayScale extends StatelessWidget {
  const DesktopOverlayScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!desktopFeaturesFor(context)) return child;
    final media = MediaQuery.of(context);
    if (media.size.width <= kDesktopOverlayWidth) return child;
    return MediaQuery(
      data: media.copyWith(size: Size(kDesktopOverlayWidth, media.size.height)),
      child: child,
    );
  }
}

/// 桌面上「从一颗钮下面展开的小菜单」该摆哪儿 —— `showMenu` 的 `position`。
///
/// `showMenu` 的语义（`_PopupMenuRouteLayout.getPositionForChild`）：不给
/// `initialValue` 时 **菜单的顶边 = 这个矩形的顶边**；水平方向朝着**空间大的
/// 那一侧**长（贴右边缘的钮，菜单就右对齐着往左长）。所以「挂在钮下面」要给的
/// 正是**钮底边那一条零高矩形** —— `PopupMenuButton(position: under)` 内部就是
/// 这么算的（`features/home/shell_menu.dart` 那颗「＋」因此一直是对的）。
///
/// 为什么要 [anchorKey] 而不能直接用页面的 `context`：`context.findRenderObject()`
/// 给的是**整页**那块 RenderBox。2026-10-04 用户截图里那个 bug 就是这个 —— 聊天页
/// 顶栏的通话菜单飘在窗口右下角，离那颗摄像头图标十万八千里。锚必须是**那颗钮**
/// 自己（在 State 里存一个 [GlobalKey]，见 `features/chat/chat_page.dart`）。
///
/// [gap] 是钮与菜单之间留的那点缝（微信 PC 那种「下拉」观感）。
RelativeRect appMenuPosition(
  BuildContext context, {
  required GlobalKey anchorKey,
  double gap = 6,
}) {
  final overlayBox =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  final anchorBox = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  // 锚刚好被卸载（理论上点不到）时退回页面自己那一块：位置难看，
  // 但比「点了什么都不出来」强
  final box = (anchorBox != null && anchorBox.attached)
      ? anchorBox
      : context.findRenderObject()! as RenderBox;
  final topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
  final bottomRight = box.localToGlobal(
    box.size.bottomRight(Offset.zero),
    ancestor: overlayBox,
  );
  final top = bottomRight.dy + gap;
  return RelativeRect.fromRect(
    Rect.fromLTRB(topLeft.dx, top, bottomRight.dx, top),
    Offset.zero & overlayBox.size,
  );
}

/// 底部弹层（手机）／居中窗口（宽窗桌面）二选一。
///
/// 手机上就是原来的 `showModalBottomSheet`（参数原样透传，一个像素都不动）；
/// 桌面上换成一张**居中的白色窗口**：从屏幕底部滑上来那套是手指的手势语言，
/// 在鼠标键盘上既够不着也不体面（用户 2026-10-04：「全部要改成适配电脑 UI 的，
/// 不要保留任何手机样式」）。
///
/// 返回值的语义两边一致（`Navigator.pop(value)`），调用点不用改别的。
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  Color? backgroundColor,
  ShapeBorder? shape,
  BoxConstraints? constraints,
  bool enableDrag = true,
  bool isDismissible = true,
  bool useRootNavigator = false,
  RouteSettings? routeSettings,
  double maxWidth = kDesktopOverlayWidth,
  bool Function(Route<dynamic>)? willPop,
}) {
  if (!desktopOverlayLayout(context)) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      backgroundColor: backgroundColor,
      shape: shape,
      constraints: constraints,
      enableDrag: enableDrag,
      isDismissible: isDismissible,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: isDismissible,
    barrierColor: const Color(0x38000000),
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    builder: (dialogContext) => Center(
      child: _DesktopSheetWindow(
        maxWidth: maxWidth,
        child: Builder(builder: builder),
      ),
    ),
  );
}

/// 桌面上那张「弹层窗口」：定宽 + 白底 + 圆角 + 投影 + 上下留白封顶。
///
/// 高度不写死：内容多高就多高（那些弹层里的 `mainAxisSize: min` 与定高行都照旧），
/// 只封一个 90% 的天花板。里面的 `MediaQuery` 宽高都换成这块窗口的尺寸，
/// `rpx` 于是回到面板那一档（见 [DesktopOverlayScale] 那份说明）。
class _DesktopSheetWindow extends StatelessWidget {
  const _DesktopSheetWindow({required this.maxWidth, required this.child});

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final height = media.size.height * 0.9;
    return MediaQuery(
      data: media.copyWith(size: Size(maxWidth, height)),
      child: Material(
        // 用例靠这个 key 量那张窗口的矩形（`test/core/desktop_overlay_test.dart`）
        key: const ValueKey<String>('desktopSheetWindow'),
        color: AppColors.white,
        elevation: 18,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: maxWidth,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: child,
          ),
        ),
      ),
    );
  }
}
