import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/media/media_saver.dart';
import '../../core/net/api_exception.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/util/media_format.dart';
import '../../data/model/message.dart';
import '../../data/repo/conversation_repository.dart';
import '../../data/repo/search_repository.dart';
import '../../domain/chat/contact_card.dart';
import '../../domain/chat/file_preview.dart';
import '../../domain/chat/message_media.dart';
import '../../domain/chat/message_record.dart';
import '../../domain/lingting/lingting_card.dart';
import '../../domain/lingting/lingting_player.dart';
import '../../domain/news/news_card.dart';
import '../chat/widgets/file_preview_sheet.dart';
import '../desktop_window/desktop_window_service.dart';
import '../chat/widgets/message_bubble.dart';
import 'image_preview.dart';
import 'video_preview_page.dart';
import '../../core/ui/desktop_overlay.dart';

/// 会话内「聊天记录」，对应老端 `pages/message/record.vue`（S5.4）。
///
/// * 顶部分段（全部 / 文本 / 图片 / 视频 / 文件）= 服务端的 `type` 参数；
/// * 右上角放大镜切出搜索框（老端 `switchSearch`），搜索时每行多一个「查看上下文」；
/// * 底部分页条（老端 `uni-pagination`，一页 10 条，总数是信封里的 `count`）；
/// * 「查看上下文」底部弹层：以某条为中心，往两头都能继续加载（老端 `loadContext`）。
///
/// 与老端不同（刻意的）：
/// * **标题用「聊天记录」**：老端这一页的标题写的是 `message.info`（「聊天信息」），
///   跟聊天信息页撞了，`pages.json` 里写的才是「聊天记录」；
/// * 每行用真正的消息气泡渲染（老端是左对齐的简化列表），图片/视频/文件点开
///   还是能预览；
/// * 前后文**按 `msg_id` 去重**（老端每次「加载更多」都会多出一条边界消息）；
/// * 会话在本地不存在时提示「联系人不存在」并回首页（与老端一致）。
class ChatRecordPage extends ConsumerStatefulWidget {
  const ChatRecordPage({
    super.key,
    required this.conversationId,
    required this.isGroup,
  });

  final String conversationId;

  /// 老端从 `record?id=&is_group=` 的查询参数拿（本地会话行里也有）
  final int isGroup;

  @override
  ConsumerState<ChatRecordPage> createState() => _ChatRecordPageState();
}

class _ChatRecordPageState extends ConsumerState<ChatRecordPage> {
  final TextEditingController _controller = TextEditingController();

  List<Message> _messages = const <Message>[];
  String _tab = recordTabs.first.value;
  String _keyword = '';
  int _page = 1;
  int _total = 0;
  int _isGroup = 0;
  bool _searching = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _isGroup = widget.isGroup;
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 会话不存在就别查了（老端 `group.noContact` + `reLaunch` 回首页）
  Future<void> _prepare() async {
    final conversation = await ref
        .read(conversationRepositoryProvider)
        .find(widget.conversationId);
    if (!mounted) return;
    if (conversation == null) {
      noticeBus.toast(ref.read(appI18nProvider).t('group.noContact'));
      context.go(AppRoutes.home);
      return;
    }
    setState(() => _isGroup = conversation.isGroup);
    await _load();
  }

  Future<void> _load({int? page}) async {
    setState(() {
      _loading = true;
      if (page != null) _page = page;
    });
    try {
      final result = await ref
          .read(searchRepositoryProvider)
          .recordPage(
            conversationId: widget.conversationId,
            isGroup: _isGroup,
            type: _tab,
            keyword: _keyword,
            page: _page,
          );
      if (!mounted) return;
      setState(() {
        _messages = result.messages;
        _total = result.total;
        // 服务端删过消息之后 count 会缩水，页码夹回范围内
        _page = clampRecordPage(_page, _total);
        _loading = false;
      });
    } on ApiException catch (error) {
      debugPrint('[聊天记录] 拉取失败：${error.message}');
      if (!mounted) return;
      setState(() {
        _messages = const <Message>[];
        _total = 0;
        _loading = false;
      });
    }
  }

  void _switchTab(String value) {
    if (_tab == value) return;
    setState(() {
      _tab = value;
      _page = 1;
    });
    unawaited(_load());
  }

  /// 老端 `switchSearch`：关掉搜索框时清关键词并**重新拉一遍列表**
  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _keyword = '';
        _controller.clear();
        _page = 1;
      }
    });
    if (!_searching) unawaited(_load());
  }

  void _search() {
    setState(() {
      _keyword = _controller.text;
      _page = 1;
    });
    unawaited(_load());
  }

  void _gotoPage(int page) {
    if (page == _page) return;
    unawaited(_load(page: page));
  }

  // ------------------------------------------------------------ 内容点击

  Future<void> _onContentTap(Message message) async {
    switch (message.type) {
      case 'image':
      case 'emoji':
        await _openPreview(message);
      case 'video':
        _openVideo(message);
      case 'file':
        await _openFile(message);
      case 'location':
        await _openLocation(message);
      case 'contact':
        _openContactCard(message);
      case lingtingMessageType:
        await _playMusicCard(message);
      case newsMessageType:
        _openNewsCard(message);
      default:
        break;
    }
  }

  /// 点一张资讯卡片 → 资讯详情页（与聊天页同一个做法）
  void _openNewsCard(Message message) {
    final card = newsCardOf(message);
    if (card.isEmpty) return;
    // 桌面宽窗：文章开在系统级独立窗口里（与聊天页同一个做法）
    if (desktopWideLayout(context, ref)) {
      unawaited(
        ref
            .read(desktopWindowServiceProvider)
            .openArticle(id: card.id, title: card.title, shared: card),
      );
      return;
    }
    context.push(
      '${AppRoutes.newsDetail}?id=${Uri.encodeComponent(card.id)}',
      extra: card,
    );
  }

  /// 点一张音乐卡片 → 开播 + 进灵听播放页（与聊天页同一个做法：
  /// **先点火、不等网络，直接把页面推出来**）
  Future<void> _playMusicCard(Message message) async {
    final card = musicCardOf(message);
    final i18n = ref.read(appI18nProvider);
    if (!card.playable) {
      noticeBus.toast(i18n.t('lingting.cardUnplayable'));
      return;
    }
    unawaited(
      ref
          .read(lingtingPlayerProvider.notifier)
          .playSong(card.toSong(), source: i18n.t('lingting.title')),
    );
    if (!mounted) return;
    context.push(AppRoutes.lingtingPlayer);
  }

  /// 点名片 → 对方资料页（老端 `record.vue` 也是同一个 `openContact`）
  void _openContactCard(Message message) {
    final userId = contactCardTargetId(message);
    if (userId.isEmpty) return;
    context.push(
      '${AppRoutes.contactsDetail}?id=${Uri.encodeComponent(userId)}',
    );
  }

  Future<void> _openPreview(Message tapped) async {
    if (tapped.content.isEmpty) return;
    final urls = <String>[
      for (final message in _messages)
        if (ImagePreviewPage.isPreviewable(message.type) &&
            message.content.isNotEmpty)
          message.content,
    ];
    final index = urls.indexOf(tapped.content);
    if (index < 0 || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ImagePreviewPage(urls: urls, index: index),
      ),
    );
  }

  void _openVideo(Message message) {
    final payload = videoPayloadOf(message);
    if (payload.isEmpty) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => VideoPreviewPage(
            url: payload.url,
            fileName: messageFileNameOf(message),
          ),
        ),
      ),
    );
  }

  Future<void> _openFile(Message message) async {
    final payload = filePayloadOf(message);
    if (payload.isEmpty) return;
    final choice = await showFilePreviewSheet(context, message);
    if (choice == null || !mounted) return;
    final i18n = ref.read(appI18nProvider);
    final saver = ref.read(mediaSaverProvider);
    if (choice == FilePreviewChoice.online || isAudioFile(payload.extension)) {
      if (!await saver.openUrl(payload.url) && mounted) {
        noticeBus.toast(i18n.t('network.error'));
      }
      return;
    }
    if (!supportsLocalPreview(payload.extension)) {
      noticeBus.toast(i18n.t('message.fileNotSupport'));
      return;
    }
    noticeBus.toast(i18n.t('message.fileLoading'));
    try {
      final path = await saver.download(
        payload.url,
        fileName: payload.name.isEmpty
            ? fileNameFromUrl(payload.url)
            : payload.name,
      );
      if (!await saver.openLocalFile(path) && mounted) {
        noticeBus.toast(i18n.t('message.fileNotSupport'));
      }
    } on Object catch (error) {
      debugPrint('[聊天记录] 文件下载失败：$error');
      if (mounted) noticeBus.toast(i18n.t('network.error'));
    }
  }

  Future<void> _openLocation(Message message) async {
    final payload = locationPayloadOf(message);
    final i18n = ref.read(appI18nProvider);
    if (!payload.hasCoordinate) {
      noticeBus.toast(i18n.t('common.noData'));
      return;
    }
    final url = mapUrlOf(
      latitude: payload.latitude,
      longitude: payload.longitude,
      title: payload.title.isEmpty ? payload.address : payload.title,
      target: currentMapTarget(
        isAndroid: Platform.isAndroid,
        isIOS: Platform.isIOS,
      ),
    );
    if (!await ref.read(mediaSaverProvider).openUrl(url) && mounted) {
      noticeBus.toast(i18n.t('network.error'));
    }
  }

  // ------------------------------------------------------------ 前后文

  Future<void> _openContext(Message message) async {
    final msgId = message.msgId;
    if (msgId == null || msgId.isEmpty) return;
    final i18n = ref.read(appI18nProvider);
    try {
      final center = await ref
          .read(searchRepositoryProvider)
          .contextMessages(
            msgId: msgId,
            isGroup: _isGroup,
            direction: ContextDirection.center,
          );
      if (!mounted) return;
      if (center.isEmpty) {
        // 老端「拿不到前后文」时的提示
        noticeBus.toast(i18n.t('common.noData'));
        return;
      }
      await showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.page,
        builder: (sheetContext) => _ContextSheet(
          isGroup: _isGroup,
          initial: center,
          highlighted: msgId,
        ),
      );
    } on ApiException catch (error) {
      debugPrint('[聊天记录] 取前后文失败：${error.message}');
      if (mounted) noticeBus.toast(error.message);
    }
  }

  // -------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        title: Text(i18n.t('chat.messageRecord')),
        actions: <Widget>[
          IconButton(
            tooltip: i18n.t('common.search'),
            icon: Icon(_searching ? Icons.close : Icons.search, size: 20),
            onPressed: _toggleSearch,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _searching ? _searchBar(context, i18n) : _tabBar(context, i18n),
          const Divider(height: 1, color: AppColors.line),
          Expanded(child: _body(context, i18n)),
          _pager(context, i18n),
        ],
      ),
    );
  }

  Widget _tabBar(BuildContext context, AppI18n i18n) => Container(
    color: AppColors.white,
    height: context.rpx(88),
    child: Row(
      children: <Widget>[
        for (final tab in recordTabs)
          Expanded(
            child: InkWell(
              onTap: () => _switchTab(tab.value),
              child: Center(
                child: Text(
                  i18n.t(tab.labelKey),
                  style: TextStyle(
                    fontSize: context.rpx(28),
                    color: _tab == tab.value
                        ? AppColors.brand
                        : AppColors.text666,
                    fontWeight: _tab == tab.value
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _searchBar(BuildContext context, AppI18n i18n) => Container(
    color: AppColors.white,
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(30),
      vertical: context.rpx(16),
    ),
    child: Row(
      children: <Widget>[
        Icon(Icons.search, size: context.rpx(34), color: AppColors.text999),
        SizedBox(width: context.rpx(12)),
        Expanded(
          child: TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            style: TextStyle(fontSize: context.rpx(28)),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: i18n.t('common.keywords'),
              hintStyle: TextStyle(
                fontSize: context.rpx(28),
                color: AppColors.text999,
              ),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        SizedBox(width: context.rpx(12)),
        SizedBox(
          height: context.rpx(60),
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brand,
              padding: EdgeInsets.symmetric(horizontal: context.rpx(28)),
            ),
            onPressed: _search,
            child: Text(
              i18n.t('common.search'),
              style: TextStyle(fontSize: context.rpx(26)),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _body(BuildContext context, AppI18n i18n) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_messages.isEmpty) {
      return Center(child: Text(i18n.t('common.none')));
    }
    return ListView.builder(
      itemCount: _messages.length,
      itemBuilder: (context, index) => _row(context, i18n, _messages[index]),
    );
  }

  Widget _row(BuildContext context, AppI18n i18n, Message message) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      // 老端只在「搜过关键词」时才给这一行（`v-if="isContext"`）
      if (_searching)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => unawaited(_openContext(message)),
            child: Text(
              i18n.t('message.viewContext'),
              style: TextStyle(
                fontSize: context.rpx(24),
                color: AppColors.brand,
              ),
            ),
          ),
        ),
      MessageBubble(
        message: message,
        mine: message.isMine(ref.read(sessionStoreProvider).userId),
        circleAvatar: ref.read(
          sessionStoreProvider.select((state) => state.setting.circleAvatar),
        ),
        translate: i18n.t,
        onContentTap: (target) => unawaited(_onContentTap(target)),
      ),
      const Divider(height: 1, color: AppColors.line),
    ],
  );

  Widget _pager(BuildContext context, AppI18n i18n) {
    final pages = recordPageCount(_total);
    return Container(
      color: AppColors.white,
      padding: EdgeInsets.symmetric(vertical: context.rpx(10)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          TextButton(
            onPressed: _page > 1 && !_loading
                ? () => _gotoPage(_page - 1)
                : null,
            child: const Text('‹'),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.rpx(20)),
            child: Text(
              '$_page / $pages',
              style: TextStyle(
                fontSize: context.rpx(26),
                color: AppColors.text666,
              ),
            ),
          ),
          TextButton(
            onPressed: _page < pages && !_loading
                ? () => _gotoPage(_page + 1)
                : null,
            child: const Text('›'),
          ),
        ],
      ),
    );
  }
}

/// 「查看上下文」底部弹层。
///
/// 自己是一个 `StatefulWidget`：列表会随着「加载更多」增长，而弹层里的
/// `setState` 不能借用外层的（外层早就在重建了）。
class _ContextSheet extends ConsumerStatefulWidget {
  const _ContextSheet({
    required this.isGroup,
    required this.initial,
    required this.highlighted,
  });

  final int isGroup;
  final List<Message> initial;

  /// 被点的那条（列表里高亮它，老端 `.message-active`）
  final String highlighted;

  @override
  ConsumerState<_ContextSheet> createState() => _ContextSheetState();
}

class _ContextSheetState extends ConsumerState<_ContextSheet> {
  late List<Message> _messages = List<Message>.from(widget.initial);
  bool _loading = false;

  Future<void> _loadMore(ContextDirection direction) async {
    if (_loading || _messages.isEmpty) return;
    final anchor = direction.isEarlier ? _messages.first : _messages.last;
    final msgId = anchor.msgId;
    if (msgId == null || msgId.isEmpty) return;
    setState(() => _loading = true);
    try {
      final incoming = await ref
          .read(searchRepositoryProvider)
          .contextMessages(
            msgId: msgId,
            isGroup: widget.isGroup,
            direction: direction,
          );
      if (!mounted) return;
      if (incoming.isEmpty) {
        // 老端 `if(data.length<=0)` 就这一句提示
        noticeBus.toast(ref.read(appI18nProvider).t('common.noData'));
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _messages = List<Message>.from(
          mergeContextMessages(_messages, incoming, direction),
        );
        _loading = false;
      });
    } on ApiException catch (error) {
      debugPrint('[聊天记录] 加载前后文失败：${error.message}');
      if (!mounted) return;
      setState(() => _loading = false);
      noticeBus.toast(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final maxHeight = MediaQuery.of(context).size.height * 0.8;

    return SizedBox(
      height: maxHeight,
      child: Column(
        children: <Widget>[
          Container(
            color: AppColors.white,
            padding: EdgeInsets.symmetric(horizontal: context.rpx(20)),
            child: Row(
              children: <Widget>[
                Text(
                  i18n.t('message.detail'),
                  style: TextStyle(
                    fontSize: context.rpx(28),
                    color: AppColors.text333,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    i18n.t('common.close'),
                    style: const TextStyle(color: AppColors.red),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.line),
          Expanded(
            child: ListView(
              children: <Widget>[
                _loadMoreButton(context, i18n, ContextDirection.earlier),
                for (final message in _messages)
                  Container(
                    color: message.msgId == widget.highlighted
                        ? AppColors.line
                        : null,
                    child: MessageBubble(
                      message: message,
                      mine: message.isMine(
                        ref.read(sessionStoreProvider).userId,
                      ),
                      circleAvatar: false,
                      translate: i18n.t,
                    ),
                  ),
                _loadMoreButton(context, i18n, ContextDirection.later),
                if (_loading)
                  Padding(
                    padding: EdgeInsets.all(context.rpx(20)),
                    child: const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _loadMoreButton(
    BuildContext context,
    AppI18n i18n,
    ContextDirection direction,
  ) => Align(
    alignment: Alignment.center,
    child: TextButton(
      onPressed: _loading ? null : () => unawaited(_loadMore(direction)),
      child: Text(
        i18n.t('message.viewMore'),
        style: TextStyle(fontSize: context.rpx(26), color: AppColors.brand),
      ),
    ),
  );
}
