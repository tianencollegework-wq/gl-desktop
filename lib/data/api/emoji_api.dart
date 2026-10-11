import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import 'endpoints.dart';

/// 自定义表情，对应老端 `api/emoji.js`。
class EmojiApi {
  const EmojiApi(this._client);

  final ApiClient _client;

  /// 收藏表情列表。
  ///
  /// `data` 是**数组**（老端 `emojiApi.emojiList({})` 直接 `res.data.forEach`），
  /// 用 `postMap` 会拿到空 map——这种坑之前踩过，这里单独走列表那条路。
  Future<List<Map<String, dynamic>>> list([
    Map<String, dynamic> params = const {},
  ]) => _client.postListMaps(EmojiPaths.list, data: params);

  Future<void> add(Map<String, dynamic> params) =>
      _client.postVoid(EmojiPaths.add, data: params);

  Future<void> del(Map<String, dynamic> params) =>
      _client.postVoid(EmojiPaths.del, data: params);

  Future<void> move(Map<String, dynamic> params) =>
      _client.postVoid(EmojiPaths.move, data: params);
}

final emojiApiProvider = Provider<EmojiApi>(
  (ref) => EmojiApi(ref.watch(apiClientProvider)),
);
