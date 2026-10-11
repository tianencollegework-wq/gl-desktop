import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/core/ui/wechat_toast.dart';

import '../support/widget_ancestors.dart';

/// 微信式提示浮层（S7.6）。
///
/// 三件事是这一层的全部意义，逐条盯住：
/// 1. 位置与长相 —— 屏幕**正中**的深色圆角盒子 + 白字（不是 Material 那种贴底的 SnackBar）；
/// 2. 同一句还在屏幕上时不弹第二遍（重复提示就是这么吞掉的）；
/// 3. 到点自己收掉，后来的提示顶掉前一条。
void main() {
  final toastBox = find.byKey(const ValueKey<String>('wechatToast'));

  testWidgets('提示挂在正中：深色圆角盒子 + 白字', (tester) async {
    final layer = await pumpLayer(tester);
    addTearDown(layer.dispose);

    layer.show('网络不可用');
    await tester.pump();

    expect(find.text('网络不可用'), findsOneWidget);

    // 位置：屏幕正中（默认视口 800×600）
    final center = tester.getCenter(toastBox);
    expect(center.dx, moreOrLessEquals(400, epsilon: 1));
    expect(center.dy, moreOrLessEquals(300, epsilon: 1));

    // 长相：深色底 + 白字 + 圆角
    final box = tester.widget<DecoratedBox>(toastBox);
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, AppColors.toastBackground);
    expect(decoration.borderRadius, isNotNull);
    final text = tester.widget<Text>(find.text('网络不可用'));
    expect(text.style?.color, AppColors.toastText);

    // 松手让淡出让位，免得 teardown 时还有动画在跑
    layer.hide();
    await tester.pumpAndSettle();
  });

  testWidgets('同一句还在屏幕上时不再弹第二遍', (tester) async {
    final layer = await pumpLayer(tester);
    addTearDown(layer.dispose);

    layer.show('您没有操作权限！');
    await tester.pump();
    // 接口层弹的那一次 + 页面 catch 之后又弹的那一次（同一句话）
    layer.show('您没有操作权限！');
    await tester.pump();

    expect(toastBox, findsOneWidget);
    expect(find.text('您没有操作权限！'), findsOneWidget);

    layer.dispose();
    await tester.pumpAndSettle();
  });

  testWidgets('换一句直接顶掉前一条，到点自己收掉', (tester) async {
    final layer = await pumpLayer(tester);
    addTearDown(layer.dispose);

    layer.show('第一条');
    await tester.pump();
    expect(find.text('第一条'), findsOneWidget);

    // 不一样的话就顶掉（微信不排队等前面那条播完）
    layer.show('第二条');
    await tester.pump();
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);

    // 到点自己走（普通提示 1.8 秒 + 淡出）
    await tester.pump(WeChatToastLayer.defaultDuration);
    await tester.pumpAndSettle();
    expect(toastBox, findsNothing);
    expect(layer.showingMessage, isNull);
  });

  testWidgets('带按钮的提示：点按钮回调 + 立刻收起', (tester) async {
    final layer = await pumpLayer(tester);
    addTearDown(layer.dispose);

    var taps = 0;
    layer.show('需要麦克风权限', actionLabel: '去授权', onAction: () => taps += 1);
    await tester.pump();

    expect(find.text('去授权'), findsOneWidget);
    await tester.tap(find.text('去授权'));
    await tester.pump();

    expect(taps, 1);
    expect(toastBox, findsNothing);
  });

  testWidgets('提示自己包里一层 Material（不然文字会有两条黄色下划线）', (tester) async {
    final layer = await pumpLayer(tester);
    addTearDown(layer.dispose);

    layer.show('网络不可用');
    await tester.pump();

    // 浮层挂在根 Navigator 的 Overlay 上，祖先里本来**没有** Material：
    // `MaterialApp` 会给这种文字一份调试样式（红字 + 两条黄色下划线，
    // 见 `material/app.dart` 的 `_errorTextStyle`）—— 用户 2026-09-30 报的
    // 「很多提示都有两条黄色下划线」就是它。这里钉住最近的那层 Material
    // 就是提示自己包的那个。
    expect(
      nearestMaterialOf(tester.element(find.text('网络不可用')))?.type,
      MaterialType.transparency,
    );

    layer.dispose();
    await tester.pumpAndSettle();
  });

  testWidgets('提示是浮层：它铺满屏的那层不吃点击', (tester) async {
    var taps = 0;
    final layer = await pumpLayer(
      tester,
      // 按钮摆在屏幕底部 —— 提示铺满整屏，但**只有正中那个盒子**是能碰到的，
      // 别处（包括它盖住的这一片）照样点得到
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ElevatedButton(
          onPressed: () => taps += 1,
          child: const Text('按我'),
        ),
      ),
    );
    addTearDown(layer.dispose);

    layer.show('正在发送…');
    await tester.pump();
    await tester.tap(find.text('按我'));
    await tester.pump();

    expect(taps, 1);

    layer.dispose();
    await tester.pumpAndSettle();
  });
}

/// 把 App 与浮层一起立起来（拿根 Navigator 的 Overlay 给提示用）
Future<WeChatToastLayer> pumpLayer(WidgetTester tester, {Widget? body}) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: body ?? const SizedBox.expand())),
  );
  final overlay = tester.state<NavigatorState>(find.byType(Navigator)).overlay;
  return WeChatToastLayer(overlayOf: () => overlay);
}
