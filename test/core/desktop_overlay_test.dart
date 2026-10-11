import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/core/ui/desktop_overlay.dart';
import 'package:gracelinkim/core/ui/wechat_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 桌面上那两种弹层（S12.17）：**底部弹层变居中窗口**、**确认框的 rpx 尺度归位**。
///
/// 用户 2026-10-04：「全部要改成适配电脑 UI 的，不要保留任何手机样式」——
/// 「从屏幕底部滑上来」是手指的手势语言，1200 宽的窗口里弹一张手机宽的卡片，
/// 鼠标还得一路拖到屏幕底下；确认框更糟：桌面框架在屏上时 `MediaQuery` 是整窗宽，
/// 600rpx 的框会按 1200 算成 960 —— 一个占满屏幕的「微信白框」。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppI18n.load('zh-Hans');
  });

  /// 起一个空壳 App：窗口尺寸自己给，点按钮就把弹层弹出来
  Future<void> pumpShell(
    WidgetTester tester, {
    required bool desktop,
    required Size windowSize,
    required void Function(BuildContext context) open,
  }) async {
    tester.view.physicalSize = windowSize;
    // dpr = 1：下面断言的宽度就是逻辑宽度
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopFeaturesProvider.overrideWithValue(desktop)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => open(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('宽窗桌面：底部弹层换成居中窗口（定宽 500，居中，里面的 rpx 按 500 算）', (tester) async {
    await pumpShell(
      tester,
      desktop: true,
      windowSize: const Size(1200, 800),
      open: (context) => showAppSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 180, child: Text('弹层内容')),
      ),
    );

    expect(find.byType(BottomSheet), findsNothing, reason: '桌面上不该再是底部弹层');
    final window = tester.getRect(
      find.byKey(const ValueKey<String>('desktopSheetWindow')),
    );
    expect(window.width, kDesktopOverlayWidth);
    expect(window.center.dx, 600, reason: '居中');
    // 弹层里面那些页面按面板那一档（500）排版：`rpx` 读到的就是这个宽度
    expect(
      MediaQuery.sizeOf(tester.element(find.text('弹层内容'))).width,
      kDesktopOverlayWidth,
    );
    expect(find.text('弹层内容'), findsOneWidget);
  });

  testWidgets('窄窗（900 以下）还是手机那套底部弹层', (tester) async {
    await pumpShell(
      tester,
      desktop: true,
      windowSize: const Size(800, 600),
      open: (context) => showAppSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 180, child: Text('弹层内容')),
      ),
    );

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktopSheetWindow')),
      findsNothing,
    );
  });

  testWidgets('桌面开关关着（手机）哪怕窗口 1200 宽也还是底部弹层', (tester) async {
    await pumpShell(
      tester,
      desktop: false,
      windowSize: const Size(1200, 800),
      open: (context) => showAppSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 180, child: Text('弹层内容')),
      ),
    );

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktopSheetWindow')),
      findsNothing,
    );
  });

  testWidgets('宽窗桌面：微信确认框钉回面板尺度（600rpx → 400 宽，不再是 960）', (tester) async {
    await pumpShell(
      tester,
      desktop: true,
      windowSize: const Size(1200, 800),
      open: (context) async {
        await showWeChatConfirm(context, message: '确定要退出吗');
      },
    );

    final box = tester.getRect(
      find.byKey(const ValueKey<String>('wechatDialogBox')),
    );
    // 500 / 750 * 600 = 400（与中栏面板同一档），而不是 1200 / 750 * 600 = 960
    expect(box.width, closeTo(400, 1));
    expect(box.center.dx, 600);
    expect(find.text('确定要退出吗'), findsOneWidget);
  });

  testWidgets('手机上确认框的尺度一个像素都没动（600rpx 按屏宽算）', (tester) async {
    await pumpShell(
      tester,
      desktop: false,
      windowSize: const Size(390, 844),
      open: (context) async {
        await showWeChatConfirm(context, message: '确定要退出吗');
      },
    );

    final box = tester.getRect(
      find.byKey(const ValueKey<String>('wechatDialogBox')),
    );
    expect(box.width, closeTo(390 / 750 * 600, 1));
    expect(
      tester
          .widget<Container>(
            find.byKey(const ValueKey<String>('wechatDialogBox')),
          )
          .color,
      AppColors.white,
      reason: '白底那几个数一个都没动',
    );
  });
}
