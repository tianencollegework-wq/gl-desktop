import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/media/media_saver.dart';
import '../../core/net/api_exception.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../data/model/user_info.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/repo/group_admin_repository.dart';
import '../contacts/widgets/contact_avatar.dart';

/// 二维码页，对应老端 `pages/index/qrcode.vue`：**一个页面两种形态**——
/// 不带 `group_id` 就是「我的二维码」（码值是 `userInfo.qrUrl`），
/// 带 `group_id` 就是「群二维码」（码值来自 `groupInfo` 的 `qrUrl`）。
///
/// 观感照**微信 `我 → 二维码`**（实采 1080×2316 截图，1rpx = 1.44px）：
///
/// | 位置 | 微信实测 | 这里 |
/// |---|---|---|
/// | 顶栏 | **纯白**、无下分割线、标题黑色 | 白底 + `shape: Border()` 去掉那条线 |
/// | 顶栏底 → 头像顶 | 458.5px（≈318rpx；**微信顶栏是 44dp、我们是 56dp**，已减去 25rpx） | `rpx(276)` |
/// | 头像 | 169px 圆角方 | `rpx(116)` |
/// | 名字 | 16dp、黑 | `rpx(34)`，距头像 `rpx(21)` |
/// | 二维码 | 726px（=504rpx） | `rpx(504)`，**不留 padding**（量的是码本身） |
/// | 头像底 → 码顶 | 52px | `rpx(36)` |
/// | 码底 → 提示 | 61px | `rpx(42)` |
/// | 提示文字 | 152,152,152 | `rpx(26)`、`#999` |
/// | 底部动作 | 绿 `#12744D`、两侧各留 24px | `rpx(30)`、`AppColors.linkGreen` |
/// | 动作 → 屏幕底 | 224px（含安全区） | `rpx(112)` + 安全区 |
///
/// 存相册那张卡按这个倍率抓（360 逻辑像素 × 3 = 1080px 宽的图）
const double _savePixelRatio = 3;

/// 老端是往一张 canvas 上摞白底 + 头像 + 名字 + 二维码 + 一行小字，再整体存相册；
/// 新端用 `RepaintBoundary` 抓成 PNG 再交给 [MediaSaver] 存相册。
///
/// **存相册那张图和屏幕上这一页长得不一样**（用户 2026-09-30：「保存下来边上一点
/// 白边没有？照微信改一下」）：屏幕上那套版式是照微信的**页面**量出来的，码贴边
/// （页面上四周本来就白，看不出问题），一存成图就是「一张巨大的码顶满四条边」。
/// 所以存的是 [ _SaveCard ] 单独排的一张卡：**居中头像 + 居中名字 + 带静区的码 +
/// 底部小字**，四周一大圈白 —— 就是微信「保存图片」那张的样子。两个形态都用它。
class QrCodePage extends ConsumerStatefulWidget {
  const QrCodePage({super.key, this.groupId = ''});

  /// 空 = 我的二维码；非空 = 这个群的二维码
  final String groupId;

  @override
  ConsumerState<QrCodePage> createState() => _QrCodePageState();
}

class _QrCodePageState extends ConsumerState<QrCodePage> {
  /// 存相册那张卡的边界（它不是屏幕上那套版式，见 [_SaveCard]）
  final GlobalKey _saveCardKey = GlobalKey();

  bool _loading = false;
  bool _saving = false;

  /// 群二维码用：群名 / 头像 / 有效期文案
  String _groupName = '';
  String _groupAvatar = '';
  String _groupExpire = '';

  /// 群二维码的码值（我的二维码直接读用户资料里的 `qrUrl`）
  String _qrUrl = '';

  bool get _isGroup => widget.groupId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_isGroup) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadGroup());
    }
  }

  Future<void> _loadGroup() async {
    setState(() => _loading = true);
    try {
      final info = await ref
          .read(groupAdminRepositoryProvider)
          .joinInfo(widget.groupId);
      if (!mounted) return;
      setState(() {
        _groupName = info.name;
        _groupAvatar = info.avatar;
        _groupExpire = info.qrExpire;
        _qrUrl = info.qrUrl;
        _loading = false;
      });
    } on ApiException catch (error) {
      debugPrint('[二维码] 群资料取不到：${error.message}');
      noticeBus.toast(error.message);
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 当前这个码该用哪个头像（我的二维码用用户资料里的，群二维码用群头像）
  String _avatarOf(UserInfo? user) =>
      _isGroup ? _groupAvatar : (user?.avatar ?? '');

  /// 存相册那张卡上的名字：群里是「群聊：名字」（微信存下来那张就是这么写的），
  /// 个人的就是自己名字
  String _saveName(AppI18n i18n, UserInfo? user) =>
      _isGroup ? '${i18n.t('user.group')}：$_groupName' : (user?.name ?? '');

  /// 把 [ _SaveCard ] 抓成 PNG 存相册（老端是把 canvas 存相册）
  Future<void> _save() async {
    final i18n = ref.read(appI18nProvider);
    if (_saving) return;
    final boundary =
        _saveCardKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;

    setState(() => _saving = true);
    try {
      // 头像得先在图片缓存里，否则抓下来是个灰块（页面上另一份头像已经把
      // 同一张图拉过一遍了，这里通常秒回）
      final avatar = _avatarOf(ref.read(sessionStoreProvider).user);
      if (avatar.isNotEmpty) {
        await precacheImage(
          NetworkImage(avatar),
          context,
          onError: (error, stack) {},
        );
      }
      final image = await boundary.toImage(pixelRatio: _savePixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();
      if (bytes == null) return;
      // 先落到临时文件，再交给统一的「存相册」那条路（它认本机路径）
      final name = _isGroup ? 'qrcode-group' : 'qrcode-me';
      final file = File('${(await getTemporaryDirectory()).path}/$name.png');
      await file.writeAsBytes(bytes, flush: true);
      await ref
          .read(mediaSaverProvider)
          .saveImageToGallery(file.path, fileName: '$name.png');
      if (mounted) noticeBus.toast(i18n.t('common.saveOk'));
    } on Object catch (error) {
      // 相册权限被拒 / 抓图失败：提示一下，不影响看码
      debugPrint('[二维码] 存相册失败：$error');
      noticeBus.toast(i18n.t('common.notAuth'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final user = ref.watch(sessionStoreProvider.select((state) => state.user));
    final qrUrl = _isGroup ? _qrUrl : (user?.qrUrl ?? '');

    return Scaffold(
      // 微信这一页是**整页白**（顶栏也是白的），所以不复用全站那档灰顶栏
      backgroundColor: AppColors.white,
      appBar: AppBar(
        backgroundColor: AppColors.white,
        // 全站顶栏底下那条灰线，这一页没有（微信实测：顶栏下面直接就是白的）
        shape: const Border(),
        title: Text(i18n.t(_isGroup ? 'user.groupQrcode' : 'user.qrcode')),
      ),
      body: Stack(
        // 存相册那张卡要放到屏幕外面去，所以这一层**不能裁**
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: KeyedSubtree(
              // 屏幕上的那套（用例靠它把「页面上」和「存下来那张」分开）
              key: const ValueKey<String>('qrcodeScreen'),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : qrUrl.isEmpty
                  // 老端这句是「请重新登陆后再生成二维码」（用户资料里没 qrUrl）
                  ? _empty(context, i18n)
                  : _body(context, i18n, qrUrl),
            ),
          ),
          // 存相册用的那张卡：**放在屏幕左边外面**。它照样会被绘制，
          // 而 `RepaintBoundary` 抓的是它自己那层，跟它在不在屏幕里无关。
          if (!_loading && qrUrl.isNotEmpty)
            Positioned(
              left: -_SaveCard.width,
              top: 0,
              child: RepaintBoundary(
                key: _saveCardKey,
                child: _SaveCard(
                  // 给用例一个抓手：屏幕上 / 存下来那张要能分得开
                  key: const ValueKey<String>('qrSaveCard'),
                  avatar: _avatarOf(user),
                  name: _saveName(i18n, user),
                  qrUrl: qrUrl,
                  hint: _hintText(context, i18n),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppI18n i18n, String qrUrl) => Column(
    children: <Widget>[
      SizedBox(height: context.rpx(276)),
      // 屏幕上这块**不再**是存相册抓的那张（那是屏幕外单独排的 [_SaveCard]）：
      // 这一套是照微信的**页面**量出来的，码贴边也没关系 —— 页面上四周本来就是白的。
      Container(
        color: AppColors.white,
        child: Column(
          children: <Widget>[
            _headerRow(context, i18n),
            // 微信量出来是 52px（36rpx）—— 但 `ContactAvatar` 的盒子比头像本身
            // 高 6rpx（右下角在线小绿点要的地方），所以这里给 30rpx，
            // 到头像**下沿**的距离才是那 36rpx。
            SizedBox(height: context.rpx(30)),
            QrImageView(
              data: qrUrl,
              size: context.rpx(504),
              backgroundColor: AppColors.white,
              // 量的是码本身（726px），所以不留白边；四周的页面本来就是白的
              padding: EdgeInsets.zero,
            ),
            SizedBox(height: context.rpx(42)),
            Text(
              _hintText(context, i18n),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.rpx(26),
                color: AppColors.text999,
              ),
            ),
          ],
        ),
      ),
      // 底下那行动作贴着屏幕底，中间这段留白自动吃掉
      const Spacer(),
      _actions(context, i18n),
      SizedBox(height: context.rpx(112)),
    ],
  );

  /// 头像 + 名字：整行跟二维码**同宽**（微信里头像比码左沿往里缩 25px）
  Widget _headerRow(BuildContext context, AppI18n i18n) {
    final user = ref.watch(sessionStoreProvider.select((state) => state.user));
    final name = _isGroup
        ? '${i18n.t('user.group')} $_groupName'
        : user?.name ?? '';
    final avatar = _isGroup ? _groupAvatar : (user?.avatar ?? '');

    return SizedBox(
      width: context.rpx(504),
      child: Padding(
        padding: EdgeInsets.only(left: context.rpx(17)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ContactAvatar(
              url: avatar,
              circle: false,
              sizeRpx: 116,
              radiusRpx: 12,
            ),
            SizedBox(width: context.rpx(21)),
            // 名字比头像顶低下 26rpx（微信实测：名字中心比头像中心高 8dp 左右）
            Padding(
              padding: EdgeInsets.only(top: context.rpx(26)),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(34),
                  color: AppColors.text000,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 码下面那行小字（页面和存相册那张卡共用一句，样式各给各的）。
  ///
  /// 群码那句是「7 天有效 + 到期日」，两种信息**整句**由语言包给
  /// （`group.qrExpire` 里带 `{date}`）—— 老端那种「括号 + 日期 + 尾巴词」
  /// 的拼法只有中文语序读得通，欧洲语言得把「有效期至」放在日期前面。
  String _hintText(BuildContext context, AppI18n i18n) => _isGroup
      ? '${i18n.t('user.sevenLimit')}${i18n.t('group.qrExpire', <String, String>{'date': _groupExpire})}'
      : i18n.t('user.scanToFriend');

  /// 底部那行绿色动作：`扫一扫 | 保存图片`
  ///
  /// ⚠️ **电脑端只剩下「保存图片」**（用户 2026-10-08：「扫一扫在电脑端没用」）：
  /// 那台机器上没有相机，这条链接点下去只会被路由原样弹回主界面
  /// （见 `app_router.dart` 里 `AppRoutes.scan` 那条 `redirect`）——
  /// 摆一个点了没反应的入口不如不摆，竖线也跟着一起去掉。
  Widget _actions(BuildContext context, AppI18n i18n) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: <Widget>[
      if (!ref.watch(desktopFeaturesProvider)) ...<Widget>[
        _action(
          context,
          i18n.t('user.scanNow'),
          () => context.push(AppRoutes.scan),
        ),
        SizedBox(width: context.rpx(16)),
        Container(
          key: const ValueKey<String>('qrcodeActionBar'),
          width: context.rpx(2),
          height: context.rpx(28),
          color: AppColors.linkGreen,
        ),
        SizedBox(width: context.rpx(16)),
      ],
      _action(context, i18n.t('user.savePicture'), _saving ? null : _save),
    ],
  );

  Widget _action(BuildContext context, String label, VoidCallback? onTap) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Text(
          label,
          style: TextStyle(
            fontSize: context.rpx(30),
            color: AppColors.linkGreen,
          ),
        ),
      );

  Widget _empty(BuildContext context, AppI18n i18n) => Center(
    child: Padding(
      padding: EdgeInsets.all(context.rpx(60)),
      child: Text(
        i18n.t(_isGroup ? 'common.noData' : 'user.qcxdlhzscewm'),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: context.rpx(28), color: AppColors.text666),
      ),
    ),
  );
}

/// 「保存图片」存下来的那张卡 —— 和屏幕上那套版式**不是一回事**。
///
/// 微信「保存图片」存下来的是一张**海报**：头像居中、名字居中、码带白边居中、
/// 底下收一句小字，四周一大圈白（见用户 2026-09-30 给的那张对比图）。
/// 我们原来存的是**页面上那一块**（头像行 + 码 + 提示），而页面上的码是贴边的
/// （页面上四周本来就是白的，看不出问题），存成图就成了「一张巨大的码，四条边
/// 一点留白都没有」。所以存相册这条路改用这张单独排的卡。
///
/// ```
/// ┌──────────────────────┐
/// │        (头像)          │  ← 居中，圆角方
/// │      群聊：嘻嘻哈哈     │  ← 居中
/// │                      │
/// │   ┌──────────────┐   │
/// │   │    二维码      │   │  ← 码自带静区（白边），四周再留一大圈
/// │   └──────────────┘   │
/// │                      │
/// │   该二维码7天内…       │  ← 底部小灰字，居中
/// └──────────────────────┘
/// ```
///
/// 几个刻意的决定：
///
/// * **宽度固定 360 逻辑像素**（× `_savePixelRatio` 3 = **1080px 宽**），和屏幕多宽
///   无关 —— 存下来的图在哪台手机上都是同一张（微信那张是 1024×1520，
///   我们这张约 1080×1650，长宽比也对得上）；
/// * 卡内的尺寸按 **750 设计稿**给（`_u`），所以页面上量出来的 rpx 值可以直接
///   拿过来用；
/// * 四周留白 `_u(120)`、码的静区 `_u(45)`：**码本身只占宽度的一半多一点**
///   （微信那张也是这个比例），再也不会顶到边；
/// * 缩放系数锁死（`TextScaler.noScaling`）：存下来的是一张海报，不该因为用户
///   把系统字体调大了就变成两行、涨出卡外。
class _SaveCard extends StatelessWidget {
  const _SaveCard({
    super.key,
    required this.avatar,
    required this.name,
    required this.qrUrl,
    required this.hint,
  });

  /// 卡宽（逻辑像素）—— 固定值，见类注释
  static const double width = 360;

  final String avatar;
  final String name;
  final String qrUrl;
  final String hint;

  /// 750 设计稿 → 卡宽（存相册这张图和屏幕宽度无关，所以要自己换算）
  static double _u(double rpx) => rpx / 750 * width;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
    child: Container(
      width: width,
      color: AppColors.white,
      padding: EdgeInsets.fromLTRB(_u(120), _u(120), _u(120), _u(120)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _avatarBox(),
          SizedBox(height: _u(36)),
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _u(36),
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: AppColors.text000,
            ),
          ),
          SizedBox(height: _u(60)),
          // 码 + 静区：白色底由这层 Container 给（二维码四周的留白不是装饰，
          // 是扫码必需的静态区）
          Container(
            color: AppColors.white,
            padding: EdgeInsets.all(_u(45)),
            child: CustomPaint(
              size: Size.square(_u(420)),
              painter: QrPainter(
                data: qrUrl,
                version: QrVersions.auto,
                // 模块之间不留缝（不然缩小后会有灰线）
                gapless: true,
              ),
            ),
          ),
          SizedBox(height: _u(60)),
          Text(
            hint,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(
              fontSize: _u(23),
              height: 1.5,
              color: AppColors.text999,
            ),
          ),
        ],
      ),
    ),
  );

  /// 头像：圆角方（微信那张也是圆角方，不是圆）
  ///
  /// 这里**不复用 `ContactAvatar`**：它是按屏幕宽度算 rpx 的，而这张卡是固定宽度，
  /// 两者对不上。一张存出去的图，自己画更直接。
  Widget _avatarBox() => Container(
    width: _u(150),
    height: _u(150),
    decoration: BoxDecoration(
      color: AppColors.gray,
      borderRadius: BorderRadius.circular(_u(24)),
      border: Border.all(color: AppColors.rowDivider),
    ),
    clipBehavior: Clip.antiAlias,
    child: avatar.isEmpty
        ? Icon(Icons.person, size: _u(90), color: AppColors.text999)
        : Image.network(
            avatar,
            fit: BoxFit.cover,
            // 失败就剩灰底（不留红叉：存相册这张图是给外人看的）
            errorBuilder: (context, error, stack) =>
                Icon(Icons.person, size: _u(90), color: AppColors.text999),
          ),
  );
}
