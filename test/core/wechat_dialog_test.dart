import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/core/ui/wechat_dialog.dart';

/// 全站那一套弹窗（微信白框）。
///
/// 尺寸都是从微信截图**实采**的（1080×2316，1rpx = 1.44px），这里把最容易被
/// 改坏的那几个数钉住：框宽 600rpx、圆角 17rpx、按钮行 104rpx、
/// 「取消」近黑 / 确认是微信那支链接蓝 `#576B95`、破坏性动作红字。
void main() {
  setUp(() async => AppI18n.load('zh-Hans'));

  /// 起一个空壳 App，点按钮就把 [open] 那个弹窗弹出来
  Future<void> pumpDialog(
    WidgetTester tester,
    Future<void> Function(BuildContext context) open,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
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
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  double rpx(double value) => 390 / 750 * value;

  Text labelOf(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label));

  group('微信白框', () {
    testWidgets('框宽 600rpx、居中，按钮行 104rpx、两颗等分', (tester) async {
      await pumpDialog(tester, (context) async {
        await showWeChatConfirm(context, message: '确定要退出吗');
      });

      final box = tester.getRect(
        find.byKey(const ValueKey<String>('wechatDialogBox')),
      );
      expect(box.width, closeTo(rpx(600), 1));
      expect(box.center.dx, closeTo(tester.view.physicalSize.width / 3 / 2, 1));

      // 两颗按钮各占一半，中间那条细线在正中间
      final cancel = tester.getRect(find.text('取消'));
      final ok = tester.getRect(find.text('确定'));
      expect(cancel.center.dx, lessThan(ok.center.dx));
      expect((cancel.center.dx + ok.center.dx) / 2, closeTo(box.center.dx, 1));
      // 按钮行高 104rpx：文字中心离框底大约半行
      expect(box.bottom - ok.center.dy, closeTo(rpx(52), rpx(3)));
    });

    testWidgets('正文居中、33rpx、近黑；「取消」近黑、确认是微信链接蓝', (tester) async {
      await pumpDialog(tester, (context) async {
        await showWeChatConfirm(context, message: '确定要退出吗');
      });

      final message = labelOf(tester, '确定要退出吗');
      expect(message.style?.fontSize, rpx(33));
      expect(message.style?.color, AppColors.text000);
      expect(message.textAlign, TextAlign.center);

      expect(labelOf(tester, '取消').style?.color, AppColors.text000);
      expect(labelOf(tester, '确定').style?.color, AppColors.wechatLinkBlue);
    });

    testWidgets('破坏性动作那颗变红', (tester) async {
      await pumpDialog(tester, (context) async {
        await showWeChatConfirm(context, message: '删除后不可恢复', danger: true);
      });

      expect(labelOf(tester, '确定').style?.color, AppColors.red);
    });

    testWidgets('没有动作时就不画按钮行（进度框那种）', (tester) async {
      await pumpDialog(
        tester,
        (context) => showDialog<void>(
          context: context,
          builder: (dialogContext) => const WeChatDialogBox(
            actions: <WeChatDialogAction>[],
            body: WeChatDialogText('正在下载…'),
          ),
        ),
      );

      expect(find.text('正在下载…'), findsOneWidget);
      expect(find.text('取消'), findsNothing);
      expect(find.text('确定'), findsNothing);
    });

    testWidgets('返回值：点确认 true、点取消 false', (tester) async {
      bool? result;
      await pumpDialog(tester, (context) async {
        result = await showWeChatConfirm(context, message: '走不走');
      });

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isFalse);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('onTap 的按钮不关框（取消下载那种：先干自己的事）', (tester) async {
      var tapped = 0;
      await pumpDialog(
        tester,
        (context) => showDialog<void>(
          context: context,
          builder: (dialogContext) => WeChatDialogBox(
            body: const WeChatDialogText('正在下载…'),
            actions: <WeChatDialogAction>[
              WeChatDialogAction(label: '取消下载', onTap: () => tapped++),
            ],
          ),
        ),
      );

      await tester.tap(find.text('取消下载'));
      await tester.pumpAndSettle();

      expect(tapped, 1);
      expect(find.text('正在下载…'), findsOneWidget, reason: '框还开着');
    });
  });
}
