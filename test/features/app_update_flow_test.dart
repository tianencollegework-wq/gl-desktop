import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/app_installer.dart';
import 'package:gracelinkim/core/platform/app_version.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/core/ui/wechat_dialog.dart';
import 'package:gracelinkim/data/api/update_api.dart';
import 'package:gracelinkim/data/repo/update_repository.dart';
import 'package:gracelinkim/features/mine/app_update_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

class _FakeVersionSource implements AppVersionSource {
  const _FakeVersionSource();

  @override
  Future<AppVersionInfo> read() async =>
      const AppVersionInfo(name: '1.0.0', code: 261008);
}

/// 下载 / 安装都是平台能力，单测里跑不了 —— 换成这个替身，
/// 好钉住「什么时候下载、进度给谁、失败说什么、强制更新不给取消」。
class _FakeInstaller implements AppInstaller {
  _FakeInstaller({
    this.failDownload = false,
    this.installOk = true,
    this.hangUntilCancelled = false,
  });

  final bool failDownload;
  final bool installOk;

  /// 下载一直挂着，直到取消（用来验「取消下载」那颗按钮）
  final bool hangUntilCancelled;

  final List<String> downloads = <String>[];
  final List<String> installed = <String>[];
  final List<String> opened = <String>[];
  double? lastProgress;

  @override
  Future<String> download(
    String url, {
    required String fileName,
    void Function(double? progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    downloads.add(url);
    onProgress?.call(0.4);
    lastProgress = 0.4;
    if (hangUntilCancelled) {
      final gate = Completer<void>();
      unawaited(cancelToken?.whenCancel.then((_) => gate.complete()));
      await gate.future;
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.cancel,
      );
    }
    if (failDownload) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.connectionError,
      );
    }
    onProgress?.call(1);
    lastProgress = 1;
    return '/tmp/$fileName';
  }

  @override
  Future<bool> installPackage(String path) async {
    installed.add(path);
    return installOk;
  }

  @override
  Future<bool> openUrl(String url) async {
    opened.add(url);
    return true;
  }
}

/// 检查更新（2026-10-08 起读静态清单）的整条链：
/// 抓 `update.json` → 比自己这一份 → 分享：安卓弹窗下载安装、其余丢浏览器。
///
/// 界面按平台分流，所以这里把 `targetPlatformProvider` 钉死（默认钉安卓）。
void main() {
  late StubAdapter adapter;
  late StreamSubscription<AppNotice> noticeSub;
  late List<AppNotice> notices;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    adapter = StubAdapter();
    notices = <AppNotice>[];
    noticeSub = noticeBus.stream.listen(notices.add);
  });

  tearDown(() async {
    await noticeSub.cancel();
  });

  Iterable<String> toasts() =>
      notices.whereType<ToastNotice>().map((notice) => notice.message);

  /// 服务器上那份清单里，当前平台（默认安卓）那一格
  void manifestSays({
    String url = 'https://message.gracelink.cc/gracelink-1.0.1.apk',
    int code = 261009,
    String version = '1.0.1',
    String note = '',
    bool? force,
    String key = 'android',
  }) => adapter.responses[updateManifestUrl] = json.encode(<String, dynamic>{
    key: <String, dynamic>{
      'version': version,
      'code': code,
      'url': url,
      if (note.isNotEmpty) 'note': note,
      'force': ?force,
    },
  });

  Future<void> pumpFlow(
    WidgetTester tester, {
    required AppInstaller installer,
    required bool isPrompt,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          targetPlatformProvider.overrideWithValue(platform),
          // 挂着假 adapter 的那条 Dio：不用 `ApiClient` 那份（它把 validateStatus
          // 设成「永不抛」，清单拉不到时要走的是**错误**那条路）
          updateRepositoryProvider.overrideWithValue(
            UpdateRepository(
              UpdateApi(Dio()..httpClientAdapter = adapter),
              const _FakeVersionSource(),
            ),
          ),
          appInstallerProvider.overrideWithValue(installer),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () =>
                      runAppUpdate(context, ref, isPrompt: isPrompt),
                  child: const Text('run'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
  }

  group('清单里没有新版本', () {
    testWidgets('同一个号：手动点时提示「暂无新版本」', (tester) async {
      manifestSays(code: 261008, version: '1.0.0');

      await pumpFlow(tester, installer: _FakeInstaller(), isPrompt: true);

      expect(toasts(), <String>['暂无新版本']);
      expect(find.byType(WeChatDialogBox), findsNothing);
    });

    testWidgets('启动时那次检查一声不吭', (tester) async {
      manifestSays(code: 261008, version: '1.0.0');

      await pumpFlow(tester, installer: _FakeInstaller(), isPrompt: false);

      expect(toasts(), isEmpty);
      expect(find.byType(WeChatDialogBox), findsNothing);
    });

    testWidgets('启动时那次检查发现新版本：照样弹窗', (tester) async {
      manifestSays();

      await pumpFlow(tester, installer: _FakeInstaller(), isPrompt: false);

      expect(find.text('发现新版本：1.0.1'), findsOneWidget);
    });
  });

  group('安卓：有新版本就弹窗 → 下载 → 交给安装器', () {
    testWidgets('弹窗显示版本名（清单里没写更新说明就不显示那一段）', (tester) async {
      manifestSays();

      await pumpFlow(tester, installer: _FakeInstaller(), isPrompt: true);

      expect(find.text('发现新版本：1.0.1'), findsOneWidget);
      expect(find.text('暂不升级'), findsOneWidget);
      expect(find.text('立即升级'), findsOneWidget);
    });

    testWidgets('清单里写了 note：按行显示在弹窗里', (tester) async {
      manifestSays(note: '修复了几个问题\n新增群二维码');

      await pumpFlow(tester, installer: _FakeInstaller(), isPrompt: true);

      expect(find.text('修复了几个问题'), findsOneWidget);
      expect(find.text('新增群二维码'), findsOneWidget);
    });

    testWidgets('点「暂不升级」：不下不上，也不提示', (tester) async {
      manifestSays();
      final installer = _FakeInstaller();

      await pumpFlow(tester, installer: installer, isPrompt: true);
      await tester.tap(find.text('暂不升级'));
      await tester.pumpAndSettle();

      expect(installer.downloads, isEmpty);
      expect(installer.installed, isEmpty);
      expect(toasts(), isEmpty);
    });

    testWidgets('点「立即升级」：下载清单里那个地址 → 交给系统安装器 → 提示完成', (tester) async {
      manifestSays();
      final installer = _FakeInstaller();

      await pumpFlow(tester, installer: installer, isPrompt: true);
      await tester.tap(find.text('立即升级'));
      await tester.pumpAndSettle();

      expect(installer.downloads, <String>[
        'https://message.gracelink.cc/gracelink-1.0.1.apk',
      ]);
      expect(installer.installed, <String>['/tmp/gracelink-1.0.1.apk']);
      expect(toasts().single, contains('系统安装器'));
    });

    testWidgets('下载中显示进度，进度不确定时显示「准备下载」', (tester) async {
      manifestSays();
      final installer = _FakeInstaller(hangUntilCancelled: true);

      await pumpFlow(tester, installer: installer, isPrompt: true);
      await tester.tap(find.text('立即升级'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('升级APP'), findsOneWidget);
      expect(find.text('正在为您更新，请耐心等待'), findsOneWidget);
      expect(find.text('已下载40%'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('点「取消」：中断并提示已取消', (tester) async {
      manifestSays();
      final installer = _FakeInstaller(hangUntilCancelled: true);

      await pumpFlow(tester, installer: installer, isPrompt: true);
      await tester.tap(find.text('立即升级'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(installer.installed, isEmpty);
      expect(toasts(), <String>['已取消下载']);
      expect(find.byType(WeChatDialogBox), findsNothing);
    });

    testWidgets('下载失败：弹窗里说清楚，点「确定」后提示失败', (tester) async {
      manifestSays();
      final installer = _FakeInstaller(failDownload: true);

      await pumpFlow(tester, installer: installer, isPrompt: true);
      await tester.tap(find.text('立即升级'));
      await tester.pumpAndSettle();

      expect(find.text('文件下载失败...'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(toasts(), <String>['文件下载失败...']);
    });

    testWidgets('安装器没拉起来：提示安装失败（包已经下完了）', (tester) async {
      manifestSays();
      final installer = _FakeInstaller(installOk: false);

      await pumpFlow(tester, installer: installer, isPrompt: true);
      await tester.tap(find.text('立即升级'));
      await tester.pumpAndSettle();

      expect(installer.installed, hasLength(1));
      expect(find.text('安装文件失败'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(toasts(), <String>['安装文件失败']);
    });
  });

  group('强制更新（清单里 force: true）', () {
    testWidgets('没有「暂不升级」，也提示这是强制更新', (tester) async {
      manifestSays(force: true);

      await pumpFlow(tester, installer: _FakeInstaller(), isPrompt: true);

      expect(find.text('立即升级'), findsOneWidget);
      expect(find.text('暂不升级'), findsNothing);
      expect(find.textContaining('强制更新'), findsOneWidget);
    });

    testWidgets('下载中不给「取消」（老端也是）', (tester) async {
      manifestSays(force: true);
      final installer = _FakeInstaller(hangUntilCancelled: true);

      await pumpFlow(tester, installer: installer, isPrompt: true);
      await tester.tap(find.text('立即升级'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('取消'), findsNothing);
    });
  });

  group('iOS / Windows / macOS：地址交给浏览器，不弹窗也不下载', () {
    for (final platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      testWidgets('$platform：直接丢系统浏览器', (tester) async {
        final key = switch (platform) {
          TargetPlatform.iOS => 'ios',
          TargetPlatform.macOS => 'macos',
          _ => 'windows',
        };
        manifestSays(
          key: key,
          url: 'https://message.gracelink.cc/Gracelink-1.0.1.dmg',
        );
        final installer = _FakeInstaller();

        await pumpFlow(
          tester,
          installer: installer,
          isPrompt: false,
          platform: platform,
        );

        expect(installer.opened, <String>[
          'https://message.gracelink.cc/Gracelink-1.0.1.dmg',
        ]);
        expect(installer.downloads, isEmpty);
        expect(installer.installed, isEmpty);
        expect(find.byType(WeChatDialogBox), findsNothing);
      });
    }
  });

  group('检查失败', () {
    testWidgets('清单拉不到：手动点提示，启动时静默', (tester) async {
      adapter.statusCodes[updateManifestUrl] = 500;

      await pumpFlow(tester, installer: _FakeInstaller(), isPrompt: true);
      expect(toasts(), <String>['检查更新失败，请稍后再试']);

      notices.clear();
      await pumpFlow(tester, installer: _FakeInstaller(), isPrompt: false);
      expect(toasts(), isEmpty);
    });
  });
}
