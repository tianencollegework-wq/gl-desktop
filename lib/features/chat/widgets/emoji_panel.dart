import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/router/app_router.dart';
import '../../../core/store/recent_emoji.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/util/emoji.dart';
import '../../../core/util/emoji_pack.dart';
// 收藏表情的列表与「改了之后怎么刷新」都在仓库里：面板与表情管理页共用
import '../../../data/repo/emoji_repository.dart';

/// 表情面板（老端 `im-input.vue` 里那个 `appBox == 1` 的窗口）。
///
/// 与老端的两点不同：
/// * 「表情」那一栏是**系统表情**（S4.4b：原来是把服务端那份 twitter 表情包当图片加载，
///   现在直接用系统字体渲染 —— 点一下把**字符**插进输入框，不直接发）；
/// * 底部是**分类条**（微信的摆法）：最近 / 收藏 + 8 个内置分类，
///   第一栏「常用」原样照抄老端那 66 个，位置不变（见 `emoji_pack.dart`）。
///
/// 「收藏」是服务端返回的自定义表情（用户自己上传的图），点一下**直接发出去**。
class EmojiPanel extends ConsumerStatefulWidget {
  const EmojiPanel({
    super.key,
    required this.onPickBuiltin,
    required this.onPickCustom,
  });

  /// 选了内置表情（参数是要插进输入框的**字符**，如 `😀`）
  final void Function(String char) onPickBuiltin;

  /// 选了收藏表情（直接发送）
  final void Function(CustomEmoji emoji) onPickCustom;

  /// 面板高度（老端是固定 300px）
  static const double heightRpx = 560;

  /// 面板最多占屏幕高度的比例。
  ///
  /// 老端面板是按 px 写死的，横屏/小屏上会把输入区挤出去；
  /// 这里按 rpx 算再扣一道上限，保证不会溢出。
  static const double maxHeightRatio = 0.4;

  /// 分类条高度
  static const double stripRpx = 84;

  /// 内置那一屏一行放几个（微信 8 个）
  static const int columns = 8;

  /// 收藏那一屏一行放几个（老端 5 个，格子大一点好看）
  static const int favoritesColumns = 5;

  @override
  ConsumerState<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends ConsumerState<EmojiPanel> {
  /// 分类条选中项：`-1` 最近、`-2` 收藏、`>= 0` 是内置分类下标
  /// （默认落在第一个内置分类「常用」，和老端打开面板看到的是同一屏）
  int _selected = 0;

  bool get _isRecent => _selected == -1;

  bool get _isFavorites => _selected == -2;

  EmojiCategory? get _category =>
      _isRecent || _isFavorites ? null : builtinEmojiCategories[_selected];

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final height = math.min(
      context.rpx(EmojiPanel.heightRpx),
      screenHeight * EmojiPanel.maxHeightRatio,
    );

    return Container(
      height: height,
      // 与「＋」面板同一块灰底（微信两块面板是一模一样的底）
      color: AppColors.panelBackground,
      child: Column(
        children: <Widget>[
          Expanded(child: _body(context, i18n)),
          const Divider(height: 1, color: AppColors.navDivider),
          _strip(context, i18n),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppI18n i18n) {
    if (_isRecent) return _recentGrid(context, i18n);
    if (_isFavorites) return _favoritesGrid(context, i18n);
    return _categoryGrid(context);
  }

  /// 底部那排分类（微信在底部，可横向滑动）
  Widget _strip(BuildContext context, AppI18n i18n) => SizedBox(
    height: context.rpx(EmojiPanel.stripRpx),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: context.rpx(16)),
      child: Row(
        children: <Widget>[
          _stripItem(
            context,
            value: -1,
            label: i18n.t('chat.emojiRecent'),
            selected: _isRecent,
            child: Icon(
              Icons.history,
              size: context.rpx(40),
              color: _isRecent ? AppColors.text333 : AppColors.text999,
            ),
          ),
          _stripItem(
            context,
            value: -2,
            label: i18n.t('common.diyEmoji'),
            selected: _isFavorites,
            child: Icon(
              Icons.favorite_border,
              size: context.rpx(40),
              color: _isFavorites ? AppColors.text333 : AppColors.text999,
            ),
          ),
          for (var index = 0; index < builtinEmojiCategories.length; index++)
            _stripItem(
              context,
              value: index,
              label: i18n.t(builtinEmojiCategories[index].labelKey),
              selected: _selected == index,
              child: Text(
                builtinEmojiCategories[index].icon,
                style: TextStyle(fontSize: context.rpx(38)),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _stripItem(
    BuildContext context, {
    required int value,
    required String label,
    required bool selected,
    required Widget child,
  }) => Semantics(
    label: label,
    selected: selected,
    child: GestureDetector(
      onTap: () => setState(() => _selected = value),
      child: Container(
        width: context.rpx(72),
        height: context.rpx(EmojiPanel.stripRpx),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // 选中的那一格是**白底**（灰底上白块才看得出来）
          color: selected ? AppColors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(context.rpx(10)),
        ),
        child: child,
      ),
    ),
  );

  /// 内置分类那一屏：**系统表情**（一行 8 个，和微信一样密）。
  ///
  /// 不再去服务端拉 png：码值就是 Unicode 码点，直接给系统字体渲染。
  /// 万一某个码点这台机器不认识（旧系统缺字），系统会画成豆腐块，
  /// 但那也比整块面板「一张图都加载不出来」强，所以不再做兜底。
  Widget _categoryGrid(BuildContext context) {
    final codes = _category?.codes ?? const <String>[];
    return GridView.builder(
      padding: EdgeInsets.all(context.rpx(20)),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: EmojiPanel.columns,
        mainAxisSpacing: context.rpx(16),
        crossAxisSpacing: context.rpx(16),
      ),
      itemCount: codes.length,
      itemBuilder: (context, index) {
        final char = emojiCharOf(codes[index]);
        if (char == null) return const SizedBox.shrink();
        return _charTile(context, char);
      },
    );
  }

  /// 「最近使用」：空的时候给一句话，别让用户对着白板发愣
  Widget _recentGrid(BuildContext context, AppI18n i18n) {
    final recent = ref.watch(recentEmojiProvider);
    if (recent.isEmpty) {
      return Center(
        child: Text(
          i18n.t('chat.emojiRecentEmpty'),
          style: TextStyle(fontSize: context.rpx(24), color: AppColors.text999),
        ),
      );
    }
    return GridView.builder(
      padding: EdgeInsets.all(context.rpx(20)),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: EmojiPanel.columns,
        mainAxisSpacing: context.rpx(16),
        crossAxisSpacing: context.rpx(16),
      ),
      itemCount: recent.length,
      itemBuilder: (context, index) => _charTile(context, recent[index]),
    );
  }

  /// 一格系统表情：点一下插进输入框，并记进「最近使用」
  Widget _charTile(BuildContext context, String char) => GestureDetector(
    onTap: () {
      widget.onPickBuiltin(char);
      // 记一次「最近使用」：不 await，点一下不该等落盘
      unawaited(ref.read(recentEmojiProvider.notifier).use(char));
    },
    child: Center(
      child: Text(char, style: TextStyle(fontSize: context.rpx(52))),
    ),
  );

  Widget _favoritesGrid(BuildContext context, AppI18n i18n) {
    final emojis = ref.watch(customEmojiProvider);
    return emojis.when(
      loading: () => Center(
        child: SizedBox(
          width: context.rpx(40),
          height: context.rpx(40),
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      // 拉不到就当作「没有收藏」——老端这里也是静默的
      error: (error, stack) => _empty(context, i18n),
      // 第一格固定是那颗「＋」（老端 `im-input.vue` 的 `upload-emoji`）：
      // 一个收藏都没有时它也得在，不然没地方进表情管理页。
      data: (list) => GridView.builder(
        padding: EdgeInsets.all(context.rpx(20)),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: EmojiPanel.favoritesColumns,
          mainAxisSpacing: context.rpx(20),
          crossAxisSpacing: context.rpx(20),
        ),
        itemCount: list.length + 1,
        itemBuilder: (context, index) => index == 0
            ? _manageTile(context)
            : _customTile(context, list[index - 1]),
      ),
    );
  }

  /// 收藏 tab 第一格：进表情管理页
  Widget _manageTile(BuildContext context) => GestureDetector(
    onTap: () => context.push(AppRoutes.emoji),
    child: Container(
      decoration: BoxDecoration(
        // 灰底上要看得见，所以用深一档的线（原来白底时用的 `line` 会糊掉）
        border: Border.all(color: AppColors.navDivider),
        borderRadius: BorderRadius.circular(context.rpx(10)),
      ),
      child: Icon(Icons.add, size: context.rpx(44), color: AppColors.text999),
    ),
  );

  Widget _customTile(BuildContext context, CustomEmoji emoji) =>
      GestureDetector(
        onTap: () => widget.onPickCustom(emoji),
        child: Image.network(
          emoji.url,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) => Icon(
            Icons.broken_image_outlined,
            size: context.rpx(40),
            color: AppColors.text999,
          ),
        ),
      );

  Widget _empty(BuildContext context, AppI18n i18n) => Center(
    child: Text(
      i18n.t('common.diyEmoji'),
      style: TextStyle(fontSize: context.rpx(24), color: AppColors.text999),
    ),
  );
}
