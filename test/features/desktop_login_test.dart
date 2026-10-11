import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/net/geo_ip.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/features/login/qr_login_session.dart';
import 'package:gracelinkim/features/login/widgets/auth_widgets.dart';
import 'package:gracelinkim/features/login/widgets/desktop_login.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../support/fake_geo_ip.dart';
import '../support/fake_web_socket.dart';
import '../support/test_database.dart';

/// 桌面登录页（S12.17）：**扫码优先的两栏版式**。
///
/// 手机上那一版是「品牌在上、卡片在下」的竖排，1200 宽的窗口里两侧全是空白；
/// 用户 2026-10-04 要的是电脑软件那套：左边品牌、右边一块**定宽卡片**，
/// 卡片默认是二维码（微信 PC 就是这么登的），底下一条「密码登陆」切回账号表单。
///
/// 这一套钉三件事：版式是两栏（二维码落在右半边）、服务端给的 `qrurl` 真被画成了
/// 二维码、切到账号表单后那条后台连接就撤了。
///
/// 另外两条是 2026-10-08 用户要的（见下面对应用例）：密码那一套收进「其他登录方式」
/// 里，而且**只对美国出口 IP 开放**（`features/login/password_login_policy.dart`）；
/// 电脑端**不画注册**。
///
/// 注意**不能用 `pumpAndSettle`**：等待扫码那一屏中间是个转圈（`CircularProgressIndicator`），
/// 它永远动，`pumpAndSettle` 会一直等到超时。这里统一用「推固定几帧」。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late FakeWebSocketChannel channel;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    channel = FakeWebSocketChannel();
    // 未登录 → 路由守卫把人留在登录页
    sessionGuard.update(ready: true, hasSession: false);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  /// 推几帧（不判定「静下来」——扫码那一屏有常驻动画）
  Future<void> settle(WidgetTester tester, {int frames = 8}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  /// 起整个 App，停在登录页；[desktop] 决定走哪一版版式
  Future<void> pumpLogin(
    WidgetTester tester, {
    Size windowSize = const Size(1200, 800),
    bool desktop = true,
    GeoIpService? geo,
  }) async {
    tester.view.physicalSize = windowSize;
    // dpr = 1：下面断言的宽度就是逻辑宽度
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          desktopFeaturesProvider.overrideWithValue(desktop),
          desktopShellProvider.overrideWithValue(desktop),
          // 扫码那条连接换成假通道：测试里不能真的去连服务端
          qrLoginConnectorProvider.overrideWithValue(
            (_) => channel as WebSocketChannel,
          ),
          // 出口 IP 的归属地：默认按「美国」答（要验「别处被拦」就传别的）
          geoIpProvider.overrideWithValue(geo ?? FakeGeoIp('US')),
        ],
        child: const GracelinkApp(),
      ),
    );
    await settle(tester);
  }

  /// 让扫码那条连接把 `init` 收下（服务端分配 client_id 那一步）
  Future<void> emitInit(WidgetTester tester) async {
    channel.emit(
      jsonEncode(<String, dynamic>{'type': 'init', 'client_id': 'c-1'}),
    );
    await settle(tester);
  }

  /// 服务端推二维码
  Future<void> emitQr(WidgetTester tester, String url) async {
    channel.emit(
      jsonEncode(<String, dynamic>{'type': 'codeLoginQr', 'qrurl': url}),
    );
    await settle(tester);
  }

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  List<Map<String, dynamic>> sentFrames() => channel.sent
      .map((frame) => json.decode(frame as String))
      .cast<Map<String, dynamic>>()
      .toList();

  testWidgets('宽窗登录页：两栏（左品牌右卡片），默认是扫码', (tester) async {
    await pumpLogin(tester);
    await emitInit(tester);

    // 连线了、要二维码了（服务端只在收到这一句时才生成）
    expect(sentFrames().last, <String, dynamic>{
      'type': 'pong',
      'isQrLogin': true,
    });

    expect(find.text('扫码登录'), findsWidgets);
    expect(find.text('请使用手机扫码登录'), findsWidgets);
    expect(
      tester.getRect(find.byType(DesktopLoginView)).width,
      1200,
      reason: '登录页吃满整窗（不被壳夹到 500）',
    );
    expect(
      tester.getRect(find.text('欢迎回来，登录后继续聊天')).center.dx,
      lessThan(600),
      reason: '品牌那一栏在左半边',
    );
    expect(
      tester.getRect(find.text('其他登录方式')).center.dx,
      greaterThan(600),
      reason: '卡片在右半边（密码那一套收进「其他登录方式」里）',
    );

    await disposeApp(tester);
  });

  testWidgets('服务端给的 qrurl 直接画成二维码（200×200，落在右半边）', (tester) async {
    await pumpLogin(tester);
    await emitInit(tester);

    expect(find.byType(QrImageView), findsNothing, reason: '还没拿到码');
    expect(find.text('请使用手机扫码登录'), findsWidgets, reason: '等待时那句话在');

    await emitQr(tester, 'https://im.example.test/scan/a/d6b5ZRQ%2Bazv');

    // 那条 URL 就是服务端推来的那一句（session 层的钉子见
    // `test/features/qr_login_test.dart`）；这里钉的是它**真的被画成了二维码**
    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.widget<QrImageView>(find.byType(QrImageView)).size, 200);
    expect(
      tester.getRect(find.byType(QrImageView)).center.dx,
      greaterThan(600),
      reason: '二维码在右半边，不是手机那种居中竖排',
    );

    await disposeApp(tester);
  });

  testWidgets('点「其他登录方式 › 密码登陆」（美国 IP）：切回账号表单，二维码与那条连接一起撤掉', (tester) async {
    await pumpLogin(tester);
    await emitInit(tester);
    await emitQr(tester, 'https://im.example.test/scan/a/abc');
    expect(find.byType(QrImageView), findsOneWidget);

    // 屏幕上那条不再是「密码登陆」，而是「其他登录方式」——点开是一行小菜单
    await tester.tap(find.text('其他登录方式'));
    await settle(tester);
    expect(find.byKey(kLoginWaysMenuKey), findsOneWidget);
    expect(find.text('密码登陆'), findsOneWidget);

    // 美国出口 IP → 放行，切到账号密码那一半
    await tester.tap(find.text('密码登陆'));
    await settle(tester);
    // `autoDispose` 的回收是排在一个真异步任务上跑的（不是 fake clock 里的定时器），
    // 所以给它一点真时间
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await settle(tester);

    expect(find.byType(QrImageView), findsNothing);
    // 输入框回来了（手机那套零件：账号 / 密码两行）
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    // 那条匿名连接被关掉（切走就等于不要二维码了，`autoDispose` 收的尾）
    expect(channel.closed, isTrue);

    await disposeApp(tester);
  });

  testWidgets('「其他登录方式」展开的是一行小菜单：贴在链接下沿，字号与链接同档', (tester) async {
    await pumpLogin(tester);
    await emitInit(tester);

    await tester.tap(find.text('其他登录方式'));
    await settle(tester);

    // 形态：一行的小卡片（不是盖住大半屏的模态框），位置贴着那颗链接
    final menu = tester.getRect(find.byKey(kLoginWaysMenuKey));
    final link = tester.getRect(find.text('其他登录方式'));
    expect(menu.width, lessThan(300), reason: '一行选项不该撑出一张大框');
    expect(menu.height, lessThan(80));
    expect(
      menu.center.dy,
      greaterThan(link.center.dy),
      reason: '挂在链接下沿，不是屏幕正中的弹窗',
    );
    expect(menu.left, closeTo(link.left, 60), reason: '贴着链接展开');

    // 尺度：字要按面板那一档（500）算。第一版漏了这一步，28rpx 按整窗 1200
    // 算成 ≈45px —— 2026-10-09 用户截图里那个「巨型弹窗」
    final label = tester.widget<Text>(find.text('密码登陆'));
    expect(label.style?.fontSize, closeTo(500 / 750 * 28, 0.01));
    // 菜单里没有「取消」那颗按钮（点空白处就收）
    expect(find.text('取消'), findsNothing);

    // 点空白处收掉（菜单自己关，不走进登录）
    await tester.tapAt(const Offset(80, 80));
    await settle(tester);
    expect(find.text('密码登陆'), findsNothing);
    expect(find.text('账号'), findsNothing, reason: '只是关菜单，不该冒出账号密码表单');

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await settle(tester);
    await disposeApp(tester);
  });

  testWidgets('出口 IP 不在美国：弹「您当前的位置不支持密码登陆」，表单不给', (tester) async {
    await pumpLogin(tester, geo: FakeGeoIp('DE'));
    await emitInit(tester);
    await emitQr(tester, 'https://im.example.test/scan/a/abc');

    await tester.tap(find.text('其他登录方式'));
    await settle(tester);
    await tester.tap(find.text('密码登陆'));
    await settle(tester);

    expect(find.text('您当前的位置不支持密码登陆'), findsOneWidget);
    expect(find.text('账号'), findsNothing, reason: '没放行就不该冒出账号密码表单');
    expect(find.byType(QrImageView), findsOneWidget, reason: '还是扫码那一屏');

    // 关掉那句提示（不然卸载时动画还挂着一个弹窗）
    await tester.tap(find.text('确定'));
    await settle(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await settle(tester);
    await disposeApp(tester);
  });

  testWidgets('归属地查不到 / 查挂了：一样按「不支持」拦下来', (tester) async {
    await pumpLogin(tester, geo: FakeGeoIp(null));
    await emitInit(tester);

    await tester.tap(find.text('其他登录方式'));
    await settle(tester);
    await tester.tap(find.text('密码登陆'));
    await settle(tester);
    expect(find.text('您当前的位置不支持密码登陆'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await settle(tester);

    // 第二个假实现干脆抛异常（超时 / DNS 那种），结果一样
    await disposeApp(tester);
    await pumpLogin(tester, geo: FakeGeoIp(null, error: StateError('超时')));
    await emitInit(tester);
    await tester.tap(find.text('其他登录方式'));
    await settle(tester);
    await tester.tap(find.text('密码登陆'));
    await settle(tester);
    expect(find.text('您当前的位置不支持密码登陆'), findsOneWidget);
    expect(find.text('账号'), findsNothing);
    await tester.tap(find.text('确定'));
    await settle(tester);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await settle(tester);
    await disposeApp(tester);
  });

  testWidgets('正在查归属地的那一帧：链接变转圈，没答复前不给表单', (tester) async {
    final geo = GatedGeoIp();
    await pumpLogin(tester, geo: geo);
    await emitInit(tester);
    await emitQr(tester, 'https://im.example.test/scan/a/abc');

    await tester.tap(find.text('其他登录方式'));
    await settle(tester);
    await tester.tap(find.text('密码登陆'));
    await settle(tester);

    expect(geo.calls, 1, reason: '点一次只问一次');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('账号'), findsNothing);

    geo.answer('US');
    await settle(tester);
    expect(find.text('账号'), findsOneWidget, reason: '答复是美国 → 给表单');

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await settle(tester);
    await disposeApp(tester);
  });

  testWidgets('电脑端不画「注册」：服务端开着注册也不给入口', (tester) async {
    await pumpLogin(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyConfig(
          GlobalConfig(
            sysInfo: const SysInfo(name: '恩信', regtype: 1),
            chatInfo: const ChatInfo(),
            compass: const CompassConfig(),
            demonMode: false,
          ),
        );
    await settle(tester);

    expect(
      find.byType(AuthSecondaryButton),
      findsNothing,
      reason: '电脑端不许注册账号（2026-10-08 用户定的）',
    );
    expect(find.text('注册'), findsNothing);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await settle(tester);
    await disposeApp(tester);
  });

  testWidgets('手机（窗 390）还是原来那一版：竖排表单，不做扫码那半套', (tester) async {
    await pumpLogin(tester, windowSize: const Size(390, 844), desktop: false);

    expect(find.byType(DesktopLoginView), findsNothing);
    expect(find.byType(QrImageView), findsNothing, reason: '手机上不做扫码那半套');
    expect(find.text('扫码登录'), findsNothing);
    // 竖排那版：品牌在上、表单在下、那条「忘记密码」交换链还在
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('忘记密码'), findsOneWidget);
    expect(tester.getRect(find.text('账号')).center.dx, lessThan(300));

    await disposeApp(tester);
  });
}
