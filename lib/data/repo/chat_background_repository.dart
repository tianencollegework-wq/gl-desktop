import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/media/media_picker.dart';
import '../../core/store/credential_store.dart';

/// 聊天背景（老端 `pages/message/detail.vue` 的 `setBg` 弹层 + `chat.vue` 的 `bgInfo`）。
///
/// 老端的做法：`uni.chooseImage` 选一张 → `uni.saveFile` 存进应用目录 →
/// 把路径写进 `chat-bg-info<会话 id>`（**设备本地偏好，不跟随账号**，换手机就没了）。
/// 新端同一套，只多一步「拷进应用文档目录」：`image_picker` 给的是临时路径，
/// 系统随时会清理，而相册里那张原图用户也可能删掉。
///
/// 与老端不同（刻意的）两处：
/// * 老端那次选图能选相册也能拍照，新端这一版只开相册
///   （`MediaPicker.pickImages` 的多选接口不带 `source`；要拍照得另开一条路）；
/// * 老端改完要**重进聊天**才生效（它自己在界面上写着那句提示），
///   新端用 [revision] 通知聊天页，改完当场就变。
class ChatBackgroundRepository {
  ChatBackgroundRepository(
    this._store,
    this._picker, {
    Future<Directory> Function()? documentsDir,
  }) : _documentsDir = documentsDir ?? getApplicationDocumentsDirectory;

  final CredentialStore _store;
  final MediaPicker _picker;
  final Future<Directory> Function() _documentsDir;

  /// 背景变更通知（聊天页监听它做即时刷新）
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 图片支持的扩展名（老端没挑，`saveFile` 给了什么就是什么；这里也宽松点）
  static const Set<String> _suffixes = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
  };

  /// 当前背景：`(图片, 是否虚化)`。没设置过就是空，[image] 是本机文件路径。
  ({String image, bool filter}) load(String conversationId) =>
      _store.chatBackground(conversationId);

  /// 选一张图当背景；用户取消（或文件拿不到）返回 null。
  Future<({String image, bool filter})?> pickImage(
    String conversationId,
  ) async {
    final picked = await _picker.pickImages(limit: 1);
    if (picked.isEmpty) return null;
    final source = File(picked.first.localPath);
    if (!await source.exists()) {
      debugPrint('[聊天背景] 选中的文件已经不在了：${picked.first.localPath}');
      return null;
    }

    final dir = await _dir();
    final target = File(
      '${dir.path}/${_fileName(conversationId, picked.first)}',
    );
    await _deleteFilesOf(conversationId, keep: target.path);
    await source.copy(target.path);
    await _store.saveChatBackground(
      conversationId,
      image: target.path,
      filter: false,
    );
    revision.value++;
    return _store.chatBackground(conversationId);
  }

  /// 移除背景（老端那颗红色按钮），顺手把本地那份文件删掉
  Future<void> remove(String conversationId) async {
    await _deleteFilesOf(conversationId);
    await _store.saveChatBackground(conversationId, image: '', filter: false);
    revision.value++;
  }

  /// 背景虚化开关。
  ///
  /// 老端这个开关只画在微信小程序端（`#ifdef MP-WEIXIN`），安卓/iOS 端没有；
  /// 新端的渲染层是支持的，所以字段与接口都留着（界面这一版没放出来，与老端一致）。
  Future<void> setFilter(String conversationId, bool filter) async {
    final current = _store.chatBackground(conversationId);
    await _store.saveChatBackground(
      conversationId,
      image: current.image,
      filter: filter,
    );
    revision.value++;
  }

  /// 换账号登录时把所有背景清掉（含本机那些图片文件）。
  ///
  /// 为什么需要：背景是「按会话 id 存的本机偏好」，换账号后同一条会话
  /// （比如都和同一个人聊）会沿用上个账号设的图。聊天记录本身由
  /// `ConversationRepository.wipeLocal` 清，这里只管背景。
  Future<void> clearAll() async {
    await _store.clearChatBackgrounds();
    try {
      // 直接拼路径（不走 `_dir()`）：清理时不该顺手把空目录建出来
      final dir = Directory('${(await _documentsDir()).path}/chat-bg');
      if (await dir.exists()) await dir.delete(recursive: true);
    } on Object catch (error) {
      // 拿不到文档目录（比如没有 path_provider 的环境）或文件被占都不影响登录
      debugPrint('[聊天背景] 清背景目录失败（已忽略）：$error');
    }
    revision.value++;
  }

  /// 背景目录：`<应用文档目录>/chat-bg/`
  Future<Directory> _dir() async {
    final base = await _documentsDir();
    final dir = Directory('${base.path}/chat-bg');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// 删掉这个会话在背景目录里的旧文件（换背景时不留垃圾）
  Future<void> _deleteFilesOf(String conversationId, {String keep = ''}) async {
    final dir = await _dir();
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (entity.path == keep) continue;
      if (_stem(entity.path) != _safeId(conversationId)) continue;
      try {
        await entity.delete();
      } on FileSystemException catch (error) {
        // 删不掉不影响换背景（最多留一个孤儿文件）
        debugPrint('[聊天背景] 旧背景删不掉：$error');
      }
    }
  }

  /// 会话 id 可能带 `/`、`:` 这类不适合当文件名的字符，统一换掉
  static String _safeId(String conversationId) =>
      conversationId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static String _fileName(String conversationId, PickedMedia picked) =>
      '${_safeId(conversationId)}${_suffixOf(picked)}';

  /// 扩展名取原名（拿不到就看路径），都不是认识的图片格式就按 `.jpg`
  static String _suffixOf(PickedMedia picked) {
    for (final candidate in <String>[picked.name, picked.localPath]) {
      final dot = candidate.lastIndexOf('.');
      if (dot < 0) continue;
      final suffix = candidate.substring(dot).toLowerCase();
      if (_suffixes.contains(suffix)) return suffix;
    }
    return '.jpg';
  }

  /// 去掉目录与扩展名（`…/chat-bg/u1.png` → `u1`）
  static String _stem(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}

final chatBackgroundRepositoryProvider = Provider<ChatBackgroundRepository>(
  (ref) => ChatBackgroundRepository(
    CredentialStore.instance,
    ref.watch(mediaPickerProvider),
  ),
);
