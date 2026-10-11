import 'package:flutter/material.dart';

/// ColorUI 调色板。
///
/// 数值全部取自老端 `static/css/main.css`，用于逐像素还原现有观感。
abstract final class AppColors {
  /// `.bg-green` —— 主按钮、聊天背景色系
  static const Color green = Color(0xFF39B54A);

  /// `.bg-green.light`
  static const Color greenLight = Color(0xFFD7F0DB);

  /// `.bg-mine` / `.text-blue` —— 老端的品牌蓝，tab 选中态、我的页顶栏
  static const Color brand = Color(0xFF0389FB);

  /// `.bg-blue` —— ColorUI 默认蓝，用于主按钮
  static const Color blue = Color(0xFF0081FF);

  /// `.bg-red` —— 未读徽标
  static const Color red = Color(0xFFE54D42);

  /// `.bg-orange`
  static const Color orange = Color(0xFFF37B1D);

  /// `.bg-gray`
  static const Color gray = Color(0xFFF0F0F0);

  /// `.bg-white`
  static const Color white = Color(0xFFFFFFFF);

  /// 页面底色（卡片之间的缝也是它）。
  ///
  /// 老端是 `page { background-color: #f5f5f5 }`，但**微信全站只有一档灰**：
  /// 顶部栏、页面底、聊天背景、分组标题条都是 `#EDEDED`（实测），
  /// 所以这里跟着微信走（`navBar` / `chatBackground` 与它同值不是巧合）。
  static const Color page = Color(0xFFEDEDED);

  /// 微信的品牌绿（底部栏选中态）
  static const Color wechatGreen = Color(0xFF07C160);

  /// 底部栏未选中态（图标与文字同一档灰）
  static const Color tabInactive = Color(0xFF575B66);

  /// 会话昵称那种「近黑」（放在微信旁边，`#333` 会显得发灰）
  static const Color text000 = Color(0xFF1A1A1A);

  /// 微信右上角时间那种更浅的灰
  static const Color textTime = Color(0xFFB2B2B2);

  /// 未读红角标（微信是 #FA5151，比 `.bg-red` 亮、更正）
  static const Color unreadRed = Color(0xFFFA5151);

  /// 免打扰会话有未读时那个小灰点
  static const Color mutedDot = Color(0xFFD2D2D2);

  /// 微信消息页顶部栏的浅灰底（**不是纯白**）+ 它下面那条分割线。
  /// 置顶会话那一行也用同一个灰（微信里置顶区就是灰底）。
  static const Color navBar = Color(0xFFEDEDED);
  static const Color navDivider = Color(0xFFDCDCDC);

  /// 底部 tab 栏底色。微信比顶部栏**浅一档**（`#F7F7F7` vs `#EDEDED`），
  /// 一条细线把它和内容分开。
  static const Color tabBar = Color(0xFFF7F7F7);

  /// 列表行与行之间那条细线。微信是 `#E5E5E5`，而且**从文字左边才开始**
  /// （入口那几行的线从图标后面起，好友行的从名字后面起）。
  static const Color rowDivider = Color(0xFFE5E5E5);

  /// 分组字母条下面那条更淡的线（比 `rowDivider` 深一点点）
  static const Color sectionDivider = Color(0xFFD5D5D5);

  /// 通讯录那几个入口的彩色方块底色。四档全部**从微信截图实采**，
  /// 不是照着「差不多」挑的：新的朋友（橙）、群聊（绿，就是品牌绿）、
  /// 标签 / 企业联系人（蓝）、公众号 / 服务号（更亮的蓝）。
  static const Color entryOrange = Color(0xFFFA9E3B);
  static const Color entryBlue = Color(0xFF2781D7);

  /// 微信「＋」菜单那个**深色卡片**的底色（半透明黑灰）
  static const Color menuDark = Color(0xF24C4C4C);

  /// 聊天页底色（微信那层浅灰，比 `page` 深一档）
  static const Color chatBackground = Color(0xFFEDEDED);

  /// 输入区那两块面板（表情 / 「＋」）的底色。
  /// 微信的面板是「**浅灰底 + 白方块**」（与 `page` 同一档灰），
  /// 不是老端那种白底灰方块。
  static const Color panelBackground = Color(0xFFF5F5F5);

  /// 自己发的消息气泡（微信绿）+ 里面的**黑字**（微信不用白字）
  static const Color bubbleMine = Color(0xFF95EC69);
  static const Color bubbleMineText = Color(0xFF191919);

  /// 对方的气泡（白）
  static const Color bubbleOther = Color(0xFFFFFFFF);

  /// 录音浮层中心的那个声波气泡 / 它里面的声波条
  static const Color voiceOverlayBubble = Color(0xFF7BE05A);
  static const Color voiceOverlayWave = Color(0xFF1A1A1A);
  // 录音遮罩：能看清背后的聊天（微信不是全黑）
  static const Color voiceOverlayScrim = Color(0xB3000000);

  /// 录音遮罩底部那条文案（「松开 发送」）用的近黑色
  static const Color voiceOverlayText = text111;

  /// `.c-333`
  /// 气泡里的字（微信自己的绿气泡里也是**黑字**，不用白字）
  static const Color text111 = Color(0xFF111111);

  static const Color text333 = Color(0xFF333333);

  /// `.text-gray` / `.bg-white` 的前景色
  static const Color text666 = Color(0xFF666666);

  /// `.c-999`
  static const Color text999 = Color(0xFF999999);

  /// 分割线
  static const Color line = Color(0xFFEEEEEE);

  /// 列表行右端那个 `>`。微信实测 `#B0B0B0`，比 `text999` 浅一点、更「淡」。
  static const Color chevron = Color(0xFFB2B2B2);

  // ------------------------------------------------ 「我」页那几个彩色图标
  //
  // 微信那几行是**彩色线稿图标**（不是我们之前那种白字 + 渐变圆底），
  // 颜色是逐个从截图里取主色测出来的。

  /// 服务（绿）
  static const Color iconGreen = Color(0xFF10B060);

  /// 表情（黄）
  static const Color iconAmber = Color(0xFFF0B010);

  /// 设置（蓝）
  static const Color iconBlue = Color(0xFF2080D0);

  /// 「我」页资料卡上那排小药丸的边（微信实测 `#B2B2B2`，与 [chevron] 同值）
  static const Color pillBorder = Color(0xFFB2B2B2);

  /// 微信弹窗里那颗确认键的颜色（实测 `#576B95` —— 截图里的「退出」就是这个值）。
  ///
  /// 微信这套灰蓝是它弹窗/链接的固定色，跟品牌绿是两个体系：绿用于按钮和气泡，
  /// 这个灰蓝用于**白底上的可点文字**。
  static const Color wechatLinkBlue = Color(0xFF576B95);

  // ------------------------------------------------ 登录 / 注册页（2026-09-29 改版）
  //
  // 老端那套「白底 + 下划线输入行」是照着微信登录页抄的，用户 2026-09-29 说
  // 「太丑了，现代化一点」，所以这两页换成：极淡的品牌绿渐变底 + 白色卡片表单 +
  // 圆角填充输入框 + 通栏药丸按钮。下面这几个是那套观感专用的值。

  /// 登录 / 注册页顶部那层极淡的品牌绿（往下很快过渡成白）
  static const Color authWash = Color(0xFFEFFAF2);

  /// 输入框的填充底色（白卡片上的一档浅灰，比 [page] 浅很多）
  static const Color fieldFill = Color(0xFFF5F6F8);

  /// 输入框未聚焦时的那圈描边（几乎看不见，只为让边缘不发糊）
  static const Color fieldBorder = Color(0xFFECEEF1);

  /// 卡片 / logo 底下那种柔和的投影（不透明度很低，不能用纯黑的 `shadow`）
  static const Color authShadow = Color(0x140F2E1A);

  // ------------------------------------------------ 提示（toast）
  //
  // 微信全站只有一个提示位置：**屏幕正中一块深色圆角方盒 + 白字**，没有 Material
  // 那种贴着屏幕底边的 SnackBar。这两档给 [WeChatToastLayer] 与「提交成功」
  // 那个勾用 —— 两边共用一套颜色，观感才是同一个 App（S7.6）。

  /// 提示盒子的底色（半透明深灰：能看清背后的聊天，又不像纯黑那么重）
  static const Color toastBackground = Color(0xE6333333);

  /// 提示里的文字与图标
  static const Color toastText = Color(0xFFFFFFFF);

  /// 白底页面上那些**绿色文字链接**（二维码页底部的「扫一扫 | 保存图片」）。
  ///
  /// 微信实测 `#12744D`：明显比品牌绿 [wechatGreen] 深（那不是 JPEG 偏色，
  /// 实测像素的亮度就落在这个值上），当成微信「白底绿链接」那一档用。
  static const Color linkGreen = Color(0xFF12744D);
}
