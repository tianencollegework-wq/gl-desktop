import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/media/media_saver.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/features/contacts/widgets/contact_avatar.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 二维码页（S7.1，老端 `pages/index/qrcode.vue`）：一个页面两种形态。
///
/// 跑整个 App + 真实路由：不带 `group_id` 是「我的二维码」（码值读用户资料里的
/// `qrUrl`），带了就是「群二维码」（码值来自 `groupInfo` 的 `qrUrl`）。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ProviderContainer container;
  late _FakeMediaSaver saver;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    saver = _FakeMediaSaver();
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// [desktop] 为真时把 [desktopFeaturesProvider] 显式掰成「这就是电脑端
  /// （`flutter test` 里它默认是假，见 `desktop_shell.dart`）」——
  /// 电脑端少了半行动作，那半行就得有地方钉着。
  Future<void> pumpPage(
    WidgetTester tester, {
    required UserInfo user,
    String groupId = '',
    bool desktop = false,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          mediaSaverProvider.overrideWithValue(saver),
          if (desktop) desktopFeaturesProvider.overrideWithValue(true),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container.read(sessionStoreProvider.notifier).applyLogin(user);
    await tester.pumpAndSettle();

    container
        .read(appRouterProvider)
        .push(
          groupId.isEmpty
              ? AppRoutes.qrcode
              : '${AppRoutes.qrcode}?group_id=$groupId',
        );
    await tester.pumpAndSettle();

    addTearDown(() => disposeApp(tester));
  }

  /// `qr_flutter` 不对外暴露码值（`_data` 是私有的），所以这里只能钉「画没画码」；
  /// **码值取对了没有**由 `test/repo/group_admin_repository_test.dart`（`qrUrl`）
  /// 与用户资料模型那两条钉着。
  ///
  /// 注意：屏幕上用的是 `QrImageView`，存相册那张卡用的是 `QrPainter`（`CustomPaint`），
  /// 所以这个「一个码」的断言两边不会打架。
  void expectQr(WidgetTester tester) =>
      expect(find.byType(QrImageView), findsOneWidget);

  /// 「页面上」那半棵树。
  ///
  /// 存相册那张卡（屏幕外那张海报）故意和页面上写同一句提示语，所以凡是查页面
  /// 文案/位置的断言都要限定在 `qrcodeScreen` 里。
  Finder onScreen(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey<String>('qrcodeScreen')),
    matching: matching,
  );

  /// 存相册那张卡（`_SaveCard`）
  Finder saveCard() => find.byKey(const ValueKey<String>('qrSaveCard'));

  testWidgets('我的二维码：码值取用户资料里的 qrUrl，标题与说明照老端', (tester) async {
    await pumpPage(
      tester,
      user: const UserInfo(
        userId: 'u1',
        displayName: '我',
        account: 'u1',
        qrUrl: 'https://gracelink.cc/q/me',
      ),
    );

    // 标题就是微信那个「二维码」（以前叫「我的二维码」）
    expect(find.text('二维码'), findsOneWidget);
    expectQr(tester);
    expect(onScreen(find.text('扫一扫上面的二维码图案，加我为好友')), findsOneWidget);
    // 底部那行绿色动作（微信：扫一扫 | 保存图片）
    expect(find.text('扫一扫'), findsOneWidget);
    expect(find.text('保存图片'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('照微信摆位（实采值）：白底白顶栏、码 504rpx 居中、头像行与码同宽、动作行贴底', (tester) async {
    await pumpPage(
      tester,
      user: const UserInfo(
        userId: 'u1',
        displayName: '我',
        qrUrl: 'https://gracelink.cc/q/me',
      ),
    );

    double rpx(double value) => 390 / 750 * value;
    final screen = Size(
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
      tester.view.physicalSize.height / tester.view.devicePixelRatio,
    );

    // 整页白：微信这页连顶栏都是白的，且没有底下那条灰线
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      AppColors.white,
    );
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.backgroundColor, AppColors.white);
    expect((appBar.shape! as Border).bottom.width, 0);

    // 码：726px @1080 → 504rpx，水平居中
    final qr = tester.getRect(find.byType(QrImageView));
    expect(qr.width, closeTo(rpx(504), 1));
    expect(qr.center.dx, closeTo(screen.width / 2, 1));

    // 头像：169px → 116rpx；左沿比码左沿往里 25px（25/1.44 ≈ 17rpx）
    final avatar = tester.getRect(
      find.descendant(
        of: find.byType(ContactAvatar),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(avatar.width, closeTo(rpx(116), 1));
    expect(avatar.left - qr.left, closeTo(rpx(17), 1));

    // 竖排三段的间距：顶栏底→头像顶 276rpx、头像底→码顶 36rpx、码底→提示 42rpx
    final appBarRect = tester.getRect(find.byType(AppBar));
    expect(avatar.top - appBarRect.bottom, closeTo(rpx(276), rpx(2)));
    expect(qr.top - avatar.bottom, closeTo(rpx(36), 1));
    final hint = tester.getRect(onScreen(find.text('扫一扫上面的二维码图案，加我为好友')));
    expect(hint.top - qr.bottom, closeTo(rpx(42), 1));

    // 底部那行：绿色（实测 #12744D）、距屏幕底 112rpx、中间一根同色竖线
    final save = tester.widget<Text>(find.text('保存图片'));
    expect(save.style?.color, AppColors.linkGreen);
    expect(save.style?.fontSize, rpx(30));
    expect(
      screen.height - tester.getRect(find.text('保存图片')).bottom,
      closeTo(rpx(112), rpx(4)),
    );
    final bar = tester.widget<Container>(
      find.byKey(const ValueKey<String>('qrcodeActionBar')),
    );
    expect((bar.color), AppColors.linkGreen);

    await disposeApp(tester);
  });

  testWidgets('电脑端不摆「扫一扫」：那台机器上没有相机，只留下「保存图片」', (tester) async {
    await pumpPage(
      tester,
      user: const UserInfo(
        userId: 'u1',
        displayName: '我',
        qrUrl: 'https://gracelink.cc/q/me',
      ),
      desktop: true,
    );

    // 码本身照旧（与平台无关），少的是底下那半行动作
    expectQr(tester);
    expect(find.text('保存图片'), findsOneWidget);
    expect(find.text('扫一扫'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('qrcodeActionBar')),
      findsNothing,
      reason: '分隔竖线跟着「扫一扫」一起去掉，别留一根孤零零的线',
    );

    await disposeApp(tester);
  });

  testWidgets('群二维码：拉群资料，名字/有效期都带出来，码值是群的 qrUrl', (tester) async {
    adapter.ok(
      GroupPaths.info,
      data: <String, dynamic>{
        'name': '扫码群',
        'avatar': '',
        'qrUrl': 'https://gracelink.cc/q/g9',
        'qrExpire': '2026-09-26',
      },
    );

    await pumpPage(
      tester,
      user: const UserInfo(userId: 'u1', displayName: '我'),
      groupId: 'g9',
    );

    expect(adapter.bodyOf(GroupPaths.info), <String, dynamic>{
      'group_id': 'g9',
    });
    expect(find.text('群二维码'), findsOneWidget);
    expect(onScreen(find.text('群聊 扫码群')), findsOneWidget);
    expectQr(tester);
    // 老端那句是「该二维码7天内有效（<qrExpire>前到期）」
    expect(onScreen(find.text('该二维码7天内有效（2026-09-26前到期）')), findsOneWidget);
    // 存相册那张海报上写的是微信那种「群聊：名字」
    expect(
      find.descendant(of: saveCard(), matching: find.text('群聊：扫码群')),
      findsOneWidget,
    );

    await disposeApp(tester);
  });

  testWidgets('存下来的那张是微信那种海报：1080 宽、四周一圈白、码带静区居中', (tester) async {
    await pumpPage(
      tester,
      user: const UserInfo(
        userId: 'u1',
        displayName: '我',
        qrUrl: 'https://gracelink.cc/q/me',
      ),
    );

    // 存相册那张卡（不是页面上那块）
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      // 最近的上一层 RepaintBoundary 就是包着这张卡那个（`.first` = 最近）
      find
          .ancestor(of: saveCard(), matching: find.byType(RepaintBoundary))
          .first,
    );
    // 卡宽固定 360 逻辑像素（×3 = 1080px 宽的图），跟屏幕多宽无关
    expect(boundary.size.width, closeTo(360, 0.5));
    expect(
      boundary.size.height,
      greaterThan(boundary.size.width),
      reason: '微信那张是竖的（约 1080×1650）',
    );

    // 卡里怎么摆的：码居中、只占宽度一半多一点（微信那张也是这个比例）、名字也居中
    final card = tester.getRect(saveCard());
    final qr = tester.getRect(
      find.descendant(of: saveCard(), matching: find.byType(CustomPaint)).first,
    );
    expect(qr.center.dx, closeTo(card.center.dx, 1));
    expect(qr.width, closeTo(360 / 750 * 420, 0.5), reason: 'u(420)');
    expect(qr.width / card.width, lessThan(0.6), reason: '码不再顶满整个宽度');
    expect(
      tester
          .getRect(find.descendant(of: saveCard(), matching: find.text('我')))
          .center
          .dx,
      closeTo(card.center.dx, 1),
    );
    expect(card.height / card.width, inInclusiveRange(1.4, 1.8));

    // 真去遍历像素：这组断言就是用户那句「边上一点白边没有」
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final out = data!.buffer.asUint8List();
      final size = (image.width, image.height);
      return (out, size.$1, size.$2);
    });
    final pixels = bytes!.$1;
    final width = bytes.$2;
    final height = bytes.$3;
    bool isWhite(int x, int y) {
      final offset = (y * width + x) * 4;
      return pixels[offset] > 245 &&
          pixels[offset + 1] > 245 &&
          pixels[offset + 2] > 245;
    }

    /// 图被画到的那部分（卡高常常是小数，最外一行会拿到半个像素 :
    /// 那就是一层半透明白，不算「边上没白边」，跳过它）
    bool isPainted(int x, int y) => pixels[(y * width + x) * 4 + 3] == 255;

    bool isInk(int x, int y) {
      final offset = (y * width + x) * 4;
      return pixels[offset] < 60 &&
          pixels[offset + 1] < 60 &&
          pixels[offset + 2] < 60;
    }

    expect(width, 1080, reason: '360 逻辑像素 × pixelRatio 3');
    expect(
      height / width,
      inInclusiveRange(1.3, 1.8),
      reason: '微信那张（1024×1520）长宽比是 1.48，我们这张要差不多（现在 $height/$width）',
    );

    // 一圈白边：最外面 2% 不准出现黑点（用户那句「边上一点白边没有」）
    final frame = (width * 0.02).round();
    final offenders = <String>[];
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final onFrame =
            x < frame || x >= width - frame || y < frame || y >= height - frame;
        if (onFrame && isPainted(x, y) && !isWhite(x, y)) {
          final offset = (y * width + x) * 4;
          offenders.add(
            '($x,$y)=${pixels[offset]},${pixels[offset + 1]},${pixels[offset + 2]},${pixels[offset + 3]}',
          );
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '图 ${width}x$height 的四边不干净（共 ${offenders.length} 个点，前几个：'
          '${offenders.take(6).join(' ')}）—— 这正是用户截图里那个问题',
    );

    // 码在中间那段：左右各自离边 ≥ 15%，而且水平居中（黑点只在“码”那一带找，
    // 免得把名字/提示的字也算进来）
    var minX = width;
    var maxX = -1;
    var ink = 0;
    for (var y = (height * 0.45).round(); y < height * 0.75; y++) {
      for (var x = 0; x < width; x++) {
        if (!isInk(x, y)) continue;
        ink++;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
    }
    expect(ink, greaterThan(1000), reason: '那一带得真画着一个码');
    expect(minX, greaterThanOrEqualTo((width * 0.15).round()));
    expect(maxX, lessThanOrEqualTo((width * 0.85).round()));
    expect((minX + maxX) / 2, closeTo(width / 2, width * 0.02), reason: '码要居中');

    await disposeApp(tester);
  });

  testWidgets('资料里没有 qrUrl：给「请重新登陆后再生成二维码」，不画码', (tester) async {
    await pumpPage(
      tester,
      user: const UserInfo(userId: 'u1', displayName: '我'),
    );

    expect(find.text('请重新登陆后再生成二维码'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('保存到相册：把卡片抓成 PNG 交给统一的存相册那条路', (tester) async {
    // `getTemporaryDirectory()` 平时是平台通道（测试里没实现）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getTemporaryDirectory'
              ? Directory.systemTemp.path
              : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          ),
    );

    await pumpPage(
      tester,
      user: const UserInfo(
        userId: 'u1',
        displayName: '我',
        qrUrl: 'https://gracelink.cc/q/me',
      ),
    );

    // 抓图 + 写临时文件都是真实异步（假时钟里跑不动），所以这一段要 runAsync
    await tester.runAsync(() async {
      await tester.tap(find.text('保存图片'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();

    expect(saver.saved, hasLength(1));
    expect(saver.saved.single, contains('qrcode-me'));

    await disposeApp(tester);
  });
}

/// 假的「存相册」：真实现要相册权限 + 平台通道，测试里只关心叫它存了什么
class _FakeMediaSaver implements MediaSaver {
  final List<String> saved = <String>[];

  @override
  Future<void> saveImageToGallery(
    String url, {
    required String fileName,
  }) async {
    saved.add(url);
  }

  @override
  Future<String> download(String url, {required String fileName}) async => url;

  @override
  Future<void> saveVideoToGallery(
    String url, {
    required String fileName,
  }) async {}

  @override
  Future<bool> openLocalFile(String path) async => true;

  @override
  Future<bool> openUrl(String url) async => true;
}
