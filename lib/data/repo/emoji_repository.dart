import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/emoji_pack.dart';
import '../api/emoji_api.dart';
import '../api/upload_api.dart';

/// 收藏表情（老端 `api/emoji.js` + 表情管理页 `pages/message/emoji.vue`）。
///
/// 老端这一页的数据流是「拉一份列表 → 上传/删除/移动之后**整份重拉** → `uni.$emit`
/// 让聊天页的表情面板也刷新」。新端一样重拉，只是把 `uni.$emit` 换成
/// `ref.invalidate(customEmojiProvider)`（面板与这一页共用同一份缓存）。
class EmojiRepository {
  EmojiRepository(this._api, this._upload);

  final EmojiApi _api;
  final UploadApi _upload;

  /// 收藏表情列表（`/enterprise/emoji/index`，`data` 是数组）
  Future<List<CustomEmoji>> list() async {
    final rows = await _api.list();
    return rows
        .map(CustomEmoji.fromJson)
        .where((emoji) => emoji.url.isNotEmpty)
        .toList();
  }

  /// 上传一个表情（老端 `uni.uploadFile(uploadEmoji, name: 'file')`）。
  ///
  /// 大小限制由调用方先查（老端是 2MB），这里只管传。
  Future<void> upload(File file) => _upload.uploadEmoji(file);

  /// 删除（老端 `delEmoji({ids})`，数组里是**表情记录 id**）
  Future<void> remove(List<int> ids) => _api.del(<String, dynamic>{'ids': ids});

  /// 移到最前（老端 `moveEmoji({ids})`，同样是记录 id）
  Future<void> moveToFront(List<int> ids) =>
      _api.move(<String, dynamic>{'ids': ids});
}

/// 收藏表情列表缓存。表情面板与表情管理页共用（管理页改完 `invalidate` 它，
/// 面板下次展开就是新的）。
final customEmojiProvider = FutureProvider<List<CustomEmoji>>(
  (ref) => ref.watch(emojiRepositoryProvider).list(),
);

final emojiRepositoryProvider = Provider<EmojiRepository>(
  (ref) => EmojiRepository(
    ref.watch(emojiApiProvider),
    ref.watch(uploadApiProvider),
  ),
);
