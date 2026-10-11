import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/media/media_picker.dart';
import '../../core/net/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../core/util/emoji_pack.dart';
import '../../data/repo/emoji_repository.dart';

/// 表情管理，对应老端 `pages/message/emoji.vue`（入口是表情面板「收藏」tab 的「＋」）。
///
/// 与老端一致：
/// * 标题带数量「表情管理（N）」；右上角「整理 / 取消」切换多选；
/// * 第一格是「＋」上传（一次最多 9 张、单张 ≤2MB），传完**整份重拉**；
/// * 多选之后底部才出现两颗按钮：「移动到最前面」「删除(N)」，删除要二次确认。
///
/// 与老端不同（刻意的）：
/// * 老端上传完只重拉列表、`uni.$emit('updateEmoji')` 让别处刷新，这里直接
///   `ref.invalidate(customEmojiProvider)` —— 表情面板与这一页共用同一份缓存；
/// * 老端多选时点空格子也要判 `index==0`，新端在上传那一格上直接不响应多选
///   （手滑点「＋」不会莫名其妙进选择集）。
class EmojiManagePage extends ConsumerStatefulWidget {
  const EmojiManagePage({super.key});

  /// 单张表情的大小上限（老端那个 `2*1024*1024`）
  static const int maxBytes = 2 * 1024 * 1024;

  @override
  ConsumerState<EmojiManagePage> createState() => _EmojiManagePageState();
}

class _EmojiManagePageState extends ConsumerState<EmojiManagePage> {
  /// 正在整理（多选）模式
  bool _managing = false;

  /// 选中的表情**记录 id**
  final Set<int> _checked = <int>{};

  bool _busy = false;

  void _toggleManage() => setState(() {
    _managing = !_managing;
    _checked.clear();
  });

  void _toggleCheck(CustomEmoji emoji) {
    if (emoji.id == 0) return;
    setState(() {
      if (!_checked.remove(emoji.id)) _checked.add(emoji.id);
    });
  }

  Future<void> _refresh() =>
      ref.refresh(customEmojiProvider.future).then((_) {});

  Future<void> _upload(AppI18n i18n) async {
    if (_busy) return;
    List<PickedMedia> picked;
    try {
      picked = await ref.read(mediaPickerProvider).pickImages(limit: 9);
    } on Object catch (error) {
      debugPrint('[表情管理] 选图失败：$error');
      noticeBus.toast(i18n.t('common.notAuth'));
      return;
    }
    if (picked.isEmpty) return;

    setState(() => _busy = true);
    noticeBus.toast(i18n.t('common.uploading'));
    try {
      for (final media in picked) {
        // 老端对超限的那张是「跳过并提示」，其余照传
        if (media.size > EmojiManagePage.maxBytes) {
          noticeBus.toast('${media.name} ${i18n.t('message.emojiTooLarge')}');
          continue;
        }
        await ref.read(emojiRepositoryProvider).upload(File(media.localPath));
      }
      await _refresh();
      if (mounted) setState(() => _checked.clear());
    } on ApiException catch (error) {
      debugPrint('[表情管理] 上传失败：${error.message}');
      noticeBus.toast(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _moveToFront() async {
    if (_checked.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(emojiRepositoryProvider)
          .moveToFront(_checked.toList(growable: false));
      await _refresh();
      if (mounted) setState(() => _checked.clear());
    } on ApiException catch (error) {
      debugPrint('[表情管理] 移动失败：${error.message}');
      noticeBus.toast(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(AppI18n i18n) async {
    if (_checked.isEmpty || _busy) return;
    final confirmed = await showWeChatConfirm(
      context,
      message: i18n.t('message.comfirmDelEmoji'),
      danger: true,
    );
    if (!confirmed) return;

    setState(() => _busy = true);
    try {
      await ref
          .read(emojiRepositoryProvider)
          .remove(_checked.toList(growable: false));
      await _refresh();
      if (mounted) setState(() => _checked.clear());
    } on ApiException catch (error) {
      debugPrint('[表情管理] 删除失败：${error.message}');
      noticeBus.toast(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final emojis = ref.watch(customEmojiProvider);
    final list = emojis.value ?? const <CustomEmoji>[];

    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(
        title: Text('${i18n.t('message.emojiManage')}（${list.length}）'),
        actions: <Widget>[
          TextButton(
            onPressed: emojis.hasValue ? _toggleManage : null,
            child: Text(
              i18n.t(_managing ? 'common.cancel' : 'common.tidyUp'),
              style: TextStyle(
                fontSize: context.rpx(28),
                color: AppColors.brand,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: emojis.isLoading && !emojis.hasValue
                ? const Center(child: CircularProgressIndicator())
                : GridView.builder(
                    padding: EdgeInsets.all(context.rpx(20)),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      mainAxisSpacing: context.rpx(24),
                      crossAxisSpacing: context.rpx(24),
                    ),
                    itemCount: list.length + 1,
                    itemBuilder: (context, index) => index == 0
                        ? _uploadTile(context, i18n)
                        : _emojiTile(context, list[index - 1]),
                  ),
          ),
          if (_managing && _checked.isNotEmpty) _bottomBar(context, i18n),
        ],
      ),
    );
  }

  /// 第一格：上传（老端那个 `cuIcon-add`）
  Widget _uploadTile(BuildContext context, AppI18n i18n) => GestureDetector(
    key: const ValueKey<String>('emoji-upload'),
    onTap: () => _upload(i18n),
    child: Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(context.rpx(10)),
      ),
      child: _busy
          ? Center(
              child: SizedBox(
                width: context.rpx(36),
                height: context.rpx(36),
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Icon(Icons.add, size: context.rpx(50), color: AppColors.text999),
    ),
  );

  Widget _emojiTile(BuildContext context, CustomEmoji emoji) => GestureDetector(
    key: ValueKey<String>('emoji-${emoji.id}'),
    onTap: _managing ? () => _toggleCheck(emoji) : null,
    child: Stack(
      children: <Widget>[
        Positioned.fill(
          child: Image.network(
            emoji.url,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => Icon(
              Icons.broken_image_outlined,
              size: context.rpx(40),
              color: AppColors.text999,
            ),
          ),
        ),
        if (_managing)
          Positioned(
            right: 0,
            bottom: 0,
            child: Icon(
              _checked.contains(emoji.id)
                  ? Icons.check_circle
                  : Icons.circle_outlined,
              size: context.rpx(34),
              color: _checked.contains(emoji.id)
                  ? AppColors.brand
                  : AppColors.text999,
            ),
          ),
      ],
    ),
  );

  /// 底部两颗：移动到最前面 / 删除(N)（老端 `btn-opt`）
  Widget _bottomBar(BuildContext context, AppI18n i18n) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(30),
      vertical: context.rpx(16),
    ),
    decoration: const BoxDecoration(
      color: AppColors.white,
      border: Border(top: BorderSide(color: AppColors.line)),
    ),
    child: Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton(
            onPressed: _busy ? null : _moveToFront,
            child: Text(i18n.t('message.moveTop')),
          ),
        ),
        SizedBox(width: context.rpx(20)),
        Expanded(
          child: FilledButton(
            onPressed: _busy ? null : () => _delete(i18n),
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            child: Text('${i18n.t('common.del')}(${_checked.length})'),
          ),
        ),
      ],
    ),
  );
}
