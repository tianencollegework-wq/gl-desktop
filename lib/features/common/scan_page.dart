import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/config/app_config.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/media/media_picker.dart';
import '../../core/net/api_exception.dart';
import '../../core/platform/app_settings.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/link_opener.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../data/api/scan_api.dart';
import '../../domain/scan/scan_target.dart';

/// 扫一扫，对应老端 `pages/index/scan.vue`（里面是 `components/get-qrcode.vue`
/// 那套相机取景框 + 手电筒 + 权限被拒提示）+ `common/scan.js::checkQr`。
///
/// 扫到的东西怎么处理**全在 [parseScanTarget]**（纯函数，用例钉着）：
/// * 自家链接 → 问服务端要 `action` 再分流（群资料 / 个人名片 / 扫码登录）；
/// * **外链** → 走 [openChatLink]，也就是**聊天里点链接那三道闸门**
///   （自家站点直开、微信系拦掉、其它先确认）—— 用户 2026-09-27 的要求；
/// * 其余当普通文本，弹「已识别内容 + 复制」。
///
/// 与老端不同（刻意的）：
/// * 老端用 `uni.scanCode`（系统扫码界面），只有相机；新端自己做界面，
///   于是能加**相册导入**（`analyzeImage`，微信扫一扫右下角也是这个）、
///   能画提示文案、能手电筒、失败时能直接跳系统设置；
/// * 相机权限被拒时给的是「需要摄像头权限 + 去授权」，不是一句笼统的失败
///   —— 安卓从第二次拒绝起就不再弹系统框，光提示等于没帮上忙。
class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

/// 服务端的 `action` → 该跳哪个路由（`null` = 不认识，页面只能提示一下）。
///
/// 单独拿出来（而不是写在 widget 里）是为了能在用例里直接钉这段分流，
/// 同 `compass_page.dart::openCompassItem`。
///
/// 与老端不同（刻意的）：老端不管 `id` 空不空都往下跳，结果是一个什么都加载
/// 不出来的空页；新端关键字段缺了就当「没识别出来」，提示一声更好懂。
String? scanRouteOf(ScanVerdict verdict) {
  switch (verdict.action) {
    case 'groupInfo':
      // 扫到群二维码：先看群资料，再决定加不加
      return verdict.id.isEmpty
          ? null
          : '${AppRoutes.groupInfo}'
                '?group_id=${Uri.encodeComponent(verdict.id)}';
    case 'userInfo':
      return verdict.id.isEmpty
          ? null
          : '${AppRoutes.contactsDetail}'
                '?id=${Uri.encodeComponent(verdict.id)}';
    case 'qrLogin':
      // 扫码登录（PC 端）的确认页还是占位（见 REFACTOR_PLAN 的 S7.1 遗留）
      return verdict.loginToken.isEmpty
          ? null
          : '${AppRoutes.qrLogin}'
                '?token=${Uri.encodeComponent(verdict.loginToken)}';
  }
  return null;
}

/// 一帧识别结果里第一条有效内容（插件的 `barcodes` 可能有空项）
String? firstScannedValue(BarcodeCapture capture) => capture.barcodes
    .map((barcode) => barcode.rawValue)
    .firstWhere(
      (value) => value != null && value.isNotEmpty,
      orElse: () => null,
    );

class _ScanPageState extends ConsumerState<ScanPage> {
  /// 桌面上没有 `mobile_scanner` 的实现（见 build 里那段注释）：控制器与它的
  /// 事件流都**不建** —— 建出来就是去碰插件，而插件在那台机器上不存在
  /// （`MobileScannerPlatform.instance` 没被设过，构造即抛）。
  ///
  bool get _isDesktop => ref.read(desktopFeaturesProvider);

  MobileScannerController? _controller;
  StreamSubscription<BarcodeCapture>? _subscription;

  /// 正在处理一个结果（或者已经跳走了）：这期间不接第二个
  bool _busy = false;

  /// 相机为什么起不来。**只在它变化时打一次日志**（`errorBuilder` 在 build 里，
  /// 每次重建都打会把日志刷满，真出事时反而找不到）。
  String? _loggedError;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) return;
    final controller = MobileScannerController(
      formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    );
    _controller = controller;
    _subscription = controller.barcodes.listen(_onCapture);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _onCapture(BarcodeCapture capture) async {
    final raw = firstScannedValue(capture);
    if (raw == null) return;
    await _process(raw);
  }

  /// 处理一条扫码内容（相机扫到的、或从相册图片里识别出来的）。
  ///
  /// 处理期间先把相机停掉：跳页面 / 弹层那几秒里继续扫会连着识别好几次
  /// （真机上会连跳三个页面），处理完再起回来。
  Future<void> _process(String data) async {
    if (_busy) return;
    final i18n = ref.read(appI18nProvider);
    final apiUrl = ref.read(appConfigProvider).apiUrl;

    setState(() => _busy = true);
    await _controller?.stop();

    try {
      switch (parseScanTarget(data: data, apiUrl: apiUrl)) {
        // 外链：与聊天里点链接**同一条路**（三道闸门）
        case ScanUrlTarget(:final url):
          if (mounted) openChatLink(context, url);
        case ScanTextTarget(:final data):
          await _showText(data, i18n);
        case ScanInternalTarget(:final path, :final token):
          await _verify(path: path, token: token, i18n: i18n);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _resumeCameraQuietly();
      }
    }
  }

  /// 把相机起回来。
  ///
  /// 起不回来（权限被拒、没设备、被别的应用占着）时**只记日志**：界面那边会
  /// 自己显示「需要摄像头权限 / 去授权」，而这里如果让它抛出去，
  /// 就会变成一个没人接的异步异常（真机上只见一句红字，什么也定位不到）。
  Future<void> _resumeCameraQuietly() async {
    try {
      await _controller?.start();
    } on Object catch (error) {
      debugPrint('[扫一扫] 相机没能起回来：$error');
    }
  }

  /// 相册导入：选一张图 → 在那张图里找二维码。
  ///
  /// 为什么要有它：相机可能被拒（用户不给权限、ROM 不给用），
  /// 而二维码在相册里其实到处都是（别人发来的群码、截图）。微信扫一扫
  /// 右下角那颗「相册」就是干这个的。
  Future<void> _pickFromAlbum() async {
    if (_busy) return;
    // 桌面上这颗钮也不在了（见 build 里那段注释）：这里再挡一道，别去碰相机插件。
    if (_isDesktop) {
      return;
    }
    final i18n = ref.read(appI18nProvider);

    setState(() => _busy = true);
    await _controller?.stop();
    String? data;
    var failed = false;
    try {
      final picked = await ref.read(mediaPickerProvider).pickImages(limit: 1);
      if (picked.isNotEmpty) {
        final capture = await _controller!.analyzeImage(picked.first.localPath);
        data = capture == null ? null : firstScannedValue(capture);
      }
    } on Object catch (error) {
      // 选图/读图失败（权限、坏文件、插件不支持）：说清是这一步失败，
      // 与「图里没有二维码」分开，不然用户不知道该换图还是该去开权限
      failed = true;
      debugPrint('[扫一扫] 相册识别失败：$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _resumeCameraQuietly();
      }
    }

    if (!mounted) return;
    // 用户自己取消了相册：什么都不说
    if (data == null) {
      if (failed) noticeBus.toast(i18n.t('scan.albumError'));
      return;
    }
    if (data.isEmpty) {
      noticeBus.toast(i18n.t('scan.noQr'));
      return;
    }
    await _process(data);
  }

  /// 不是我们自己的码：弹出来 + 一键复制（老端那个 `uni.showModal`）。
  ///
  /// 微信的弹窗**没有标题栏**，所以这里把「扫描结果」和内容合成一块居中正文。
  Future<void> _showText(String data, AppI18n i18n) async {
    final action = await showDialog<Object>(
      context: context,
      builder: (dialogContext) => WeChatDialogBox(
        body: WeChatDialogText(
          '${i18n.t('message.scanContent')}\n$data',
          maxHeight: context.rpx(500),
        ),
        actions: <WeChatDialogAction>[
          WeChatDialogAction(label: i18n.t('common.cancel'), value: 'cancel'),
          WeChatDialogAction(
            label: i18n.t('message.copyContent'),
            value: 'copy',
            tone: WeChatDialogTone.primary,
          ),
        ],
      ),
    );
    if (action != 'copy') return;
    await Clipboard.setData(ClipboardData(text: data));
    noticeBus.toast(i18n.t('common.copyOk'));
  }

  /// 自家的码：问服务端这是什么，再按 `action` 分流
  Future<void> _verify({
    required String path,
    required String token,
    required AppI18n i18n,
  }) async {
    final ScanVerdict verdict;
    try {
      verdict = await ref
          .read(scanApiProvider)
          .verify(path: path, token: token);
    } on ApiException catch (error) {
      // 服务端说什么就说什么（「没有操作权限」这类判断是它下的），
      // 同时把原文写进日志 —— 界面上那句话不足以定位问题
      debugPrint('[扫一扫] 验证失败：${error.message}');
      noticeBus.toast(error.message);
      return;
    }
    if (!mounted) return;

    final route = scanRouteOf(verdict);
    if (route != null) {
      // 扫到群二维码时把**服务端在验证这一步就给了的群资料**一并带过去
      // （`verdict.group`）：群资料接口只认群成员，未入群的人问不到，
      // 页面就用这一份兜底 —— 群二维码本来就是给没进群的人扫的。
      await context.push(route, extra: verdict.group);
      return;
    }
    debugPrint('[扫一扫] 服务端没给可识别的 action：${verdict.action}');
    noticeBus.toast(i18n.t('common.noData'));
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    // 电脑端（用户 2026-10-08：「扫一扫在电脑端没用，直接把这功能删了」）：
    // 那条路由在桌面上会重定向回主界面（见 `app_router.dart`），菜单里也不摆
    // 这一项。这一支只是**兜底** —— 万一这页在桌面上被建出来，也别去碰相机插件
    // （`mobile_scanner` 没有 Windows/macOS/Linux 实现，构造即抛
    // 「MobileScannerPlatform.instance is not set」）。
    if (ref.watch(desktopFeaturesProvider)) {
      return _desktopNotice(context, i18n);
    }

    final controller = _controller!;
    final value = controller.value;
    final error = value.error;
    // 相机权限被拒：这条要单独说（并给「去授权」），不能与「没相机 / 起不来」混在一起
    final denied = error?.errorCode == MobileScannerErrorCode.permissionDenied;
    if (error != null && error.toString() != _loggedError) {
      _loggedError = error.toString();
      debugPrint('[扫一扫] 相机起不来：$error');
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: AppColors.white,
        title: Text(i18n.t('user.scan')),
        actions: <Widget>[
          if (value.torchState != TorchState.unavailable)
            IconButton(
              onPressed: () => unawaited(controller.toggleTorch()),
              icon: Icon(
                value.torchState == TorchState.on
                    ? Icons.flash_on
                    : Icons.flash_off,
              ),
            ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          if (!denied)
            MobileScanner(
              controller: controller,
              // 相机起不来（权限被拒、设备没相机）走这里
              errorBuilder: (context, error) => _errorView(
                context,
                i18n,
                permission:
                    error.errorCode == MobileScannerErrorCode.permissionDenied,
              ),
              onDetectError: (error, stack) {
                debugPrint('[扫一扫] 识别出错：$error');
              },
            )
          else
            // 权限被拒时不再挂相机：挂上去只会一次次失败（而且真机上会反复弹框）
            _errorView(context, i18n, permission: true),
          if (!denied) _frame(context, i18n),
          // 相册导入（微信扫一扫右下角那颗）。相机用不了时它照样能用 ——
          // 于是「权限被拒」不再等于「扫一扫整个废掉」。
          Positioned(
            left: 0,
            right: 0,
            bottom: context.rpx(90),
            child: Center(child: _albumButton(context, i18n)),
          ),
        ],
      ),
    );
  }

  /// 桌面上万一落到这一页（正常走不到：那条路由在桌面上重定向回主界面）。
  ///
  /// 只留一句「手机上才能扫」，**不再摆「选一张图」那颗钮** —— 原来那条路
  /// （`desktop_qr_scanner.dart` 用 zxing2 读文件）随扫一扫一起去掉了。
  Widget _desktopNotice(BuildContext context, AppI18n i18n) => Center(
    child: Padding(
      padding: EdgeInsets.all(context.rpx(60)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.qr_code_scanner,
            size: context.rpx(90),
            color: AppColors.white,
          ),
          SizedBox(height: context.rpx(24)),
          Text(
            i18n.t('scan.desktopTip'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: context.rpx(26), color: AppColors.white),
          ),
        ],
      ),
    ),
  );

  /// 「相册」那颗钮：ICON + 文案，压在取景框下面
  Widget _albumButton(BuildContext context, AppI18n i18n) => Material(
    color: const Color(0x66000000),
    borderRadius: BorderRadius.circular(context.rpx(40)),
    child: InkWell(
      borderRadius: BorderRadius.circular(context.rpx(40)),
      onTap: () => unawaited(_pickFromAlbum()),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(34),
          vertical: context.rpx(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.photo_library_outlined,
              size: context.rpx(36),
              color: AppColors.white,
            ),
            SizedBox(width: context.rpx(12)),
            Text(
              i18n.t('common.album'),
              style: TextStyle(
                fontSize: context.rpx(28),
                color: AppColors.white,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 取景框 + 提示文案（老端那四层 `mask` + 中间那个方框）
  Widget _frame(BuildContext context, AppI18n i18n) {
    final side = MediaQuery.sizeOf(context).width * 0.6;
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: side,
              height: side,
              child: Stack(
                children: <Widget>[
                  for (final alignment in <Alignment>[
                    Alignment.topLeft,
                    Alignment.topRight,
                    Alignment.bottomLeft,
                    Alignment.bottomRight,
                  ])
                    Align(
                      alignment: alignment,
                      child: Container(
                        width: context.rpx(60),
                        height: context.rpx(60),
                        decoration: BoxDecoration(
                          border: Border(
                            top: alignment.y < 0
                                ? BorderSide(
                                    color: AppColors.green,
                                    width: context.rpx(6),
                                  )
                                : BorderSide.none,
                            bottom: alignment.y > 0
                                ? BorderSide(
                                    color: AppColors.green,
                                    width: context.rpx(6),
                                  )
                                : BorderSide.none,
                            left: alignment.x < 0
                                ? BorderSide(
                                    color: AppColors.green,
                                    width: context.rpx(6),
                                  )
                                : BorderSide.none,
                            right: alignment.x > 0
                                ? BorderSide(
                                    color: AppColors.green,
                                    width: context.rpx(6),
                                  )
                                : BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: context.rpx(40)),
            Text(
              i18n.t('message.scanTip'),
              style: TextStyle(
                fontSize: context.rpx(26),
                color: AppColors.white,
              ),
            ),
            SizedBox(height: context.rpx(16)),
            Text(
              i18n.t('scan.albumHint'),
              style: TextStyle(
                fontSize: context.rpx(22),
                color: AppColors.text999,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 相机起不来。
  ///
  /// 两种情况要分开说：**权限被拒**（给「去授权」）与**其它原因**
  /// （没相机、被别的应用占着 —— 给「重试」的意思都不大，说清就行）。
  Widget _errorView(
    BuildContext context,
    AppI18n i18n, {
    required bool permission,
  }) => Center(
    child: Padding(
      padding: EdgeInsets.all(context.rpx(60)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            permission
                ? Icons.no_photography_outlined
                : Icons.videocam_off_outlined,
            size: context.rpx(80),
            color: AppColors.white,
          ),
          SizedBox(height: context.rpx(20)),
          Text(
            permission
                ? i18n.t('perm.needCamera')
                : i18n.t('message.cameraError'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: context.rpx(28), color: AppColors.white),
          ),
          SizedBox(height: context.rpx(30)),
          OutlinedButton(
            onPressed: () => unawaited(openAppSettings()),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.white,
              side: const BorderSide(color: AppColors.white),
            ),
            child: Text(i18n.t('common.gotoAuth')),
          ),
        ],
      ),
    ),
  );
}
