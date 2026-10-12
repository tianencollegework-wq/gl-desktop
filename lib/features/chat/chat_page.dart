import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audio/voice_player.dart';
import '../../core/config/app_config.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/media/image_compressor.dart';
import '../../core/media/media_picker.dart';
import '../../core/media/media_saver.dart';
import '../../core/net/api_exception.dart';
import '../../core/notify/message_notification_presenter.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/store/cleared_chats.dart';
import '../../core/store/manual_unread.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/call/call_busy.dart';
import '../../domain/lingting/lingting_card.dart';
import '../../domain/lingting/lingting_player.dart';
import '../../domain/news/news_card.dart';
import '../../core/theme/app_dimens.dart';
import '../desktop_window/desktop_window_service.dart';
import '../../core/ui/desktop_overlay.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/permission_gate.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../core/util/emoji_pack.dart';
import '../../core/util/media_format.dart';
import '../../data/model/time_units.dart';
import '../../data/api/emoji_api.dart';
import '../../data/model/app_setting.dart';
import '../../data/model/contact.dart';
import '../../data/model/conversation.dart';
import '../../data/repo/chat_background_repository.dart';
import '../../data/model/global_config.dart';
import '../../data/model/message.dart';
import '../../data/repo/conversation_repository.dart';
import '../../data/repo/message_repository.dart';
import '../../data/repo/message_sender.dart';
import '../../domain/call/call_duration.dart';
import '../../domain/call/call_controller.dart';
import '../../domain/call/call_signal.dart';
import '../../domain/chat/chat_items.dart';
import '../../domain/chat/contact_card.dart';
import '../../domain/chat/conversation_rules.dart';
import '../../domain/chat/file_preview.dart';
import '../../domain/chat/group_members.dart';
import '../../domain/chat/message_actions.dart';
import '../../domain/chat/message_media.dart';
import '../../domain/chat/outgoing_message.dart';
import '../../domain/report/report_reasons.dart';
import '../common/report_sheet.dart';
import '../group_call/group_call_session.dart' show groupCallBusyProvider;
import '../group_call/group_call_sync.dart' show groupCallPresenceProvider;
import 'image_preview.dart';
import 'video_preview_page.dart';
import 'widgets/chat_info_panel.dart';
import 'widgets/chat_input.dart';
import 'widgets/file_preview_sheet.dart';
import 'widgets/forward_picker.dart';
import 'widgets/group_call_bar.dart';
import 'widgets/group_call_record_sheet.dart';
import 'widgets/mention_panel.dart';
import 'widgets/message_bubble.dart';

/// 聊天页用到的会话（顶层：标题、群标识、在线状态都靠它）
final chatConversationProvider = StreamProvider.family<Conversation?, String>(
  (ref, id) => ref.watch(conversationRepositoryProvider).watchOne(id),
);

/// 消息窗口：会话 id + 本地窗口大小。
///
/// 老端是「接口拉一页 → 塞进内存数组」，退出页面就丢；新端把窗口大小做成查询参数，
/// 「加载更多」= 把窗口调大，drift 的流自然会把更早的消息带出来，
/// 只有本地真的没有了才去请求服务端。
@immutable
class ChatQuery {
  const ChatQuery(this.conversationId, this.limit);

  final String conversationId;
  final int limit;

  @override
  bool operator ==(Object other) =>
      other is ChatQuery &&
      other.conversationId == conversationId &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(conversationId, limit);
}

final chatMessagesProvider = StreamProvider.family<List<Message>, ChatQuery>(
  (ref, query) => ref
      .watch(messageRepositoryProvider)
      .watch(query.conversationId, limit: query.limit),
);

/// 聊天页（S4.2）。对应老端 `pages/message/chat.vue`。
///
/// 这一步只做骨架：反向列表（新的在最下面）、时间分隔、上拉加载历史、
/// 滚动到底、聊天背景图、进入清未读、正在看时收到新消息就上报已读。
/// 输入区在 S4.4，图片/语音等类型的渲染在 S4.3。
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    super.key,
    required this.conversationId,
    this.embedded = false,
  });

  final String conversationId;

  /// 嵌在桌面三栏的右栏里（见 `features/home/desktop_frame.dart`）。
  ///
  /// 只改顶栏的摆法（也算「按钮位置」那一类）：
  /// **没有返回箭头**（左边那一列列表一直在，没有「返回」这个动作），
  /// 标题靠左而不是居中 —— 微信 PC 的聊天标题就是这么摆的。
  /// 手机上这个值永远是 false，版式一点不变。
  final bool embedded;

  /// 老端 z-paging 的 `default-page-size`
  static const int pageSize = 20;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  /// 离「最旧」多近就开始加载更早的消息
  static const double _loadMoreThreshold = 400;

  final ScrollController _scroll = ScrollController();

  /// 本地窗口大小，每次加载历史先放大它
  int _limit = ChatPage.pageSize;

  bool _historyEnded = false;
  int _serverPage = 1;
  bool _loading = false;
  bool _entered = false;

  /// 进页那一步（读会话 + 清未读 + 读缓存）是否已经做完。
  ///
  /// 没做完之前不处理「新消息来了」：那时候 [_reportedServerId] 还是 0，
  /// 缓存里最后一条老消息会被误当成刚推来的新消息上报已读
  /// （组件测试里那条「进页面不该发已读」的断言抓出来的）。
  bool _entryReady = false;

  /// 进页面时这个会话的未读数（老端把它画在返回按钮上）
  int _unreadAtEntry = 0;

  /// 已经上报过已读的最大服务端消息 id，避免每来一条都打接口
  int _reportedServerId = 0;

  /// 我在上面翻历史时又来了几条新消息（老端 `newMsgCount`）
  int _newCount = 0;

  /// 正在引用的消息（老端 `im-input.vue` 里的 `quote`）
  Message? _quote;

  /// 这个会话的草稿（进页时从会话行读出来，交给输入框当初始值）
  String _draft = '';

  /// 语音播放器：离开页面要停掉（老端 `onUnload` 里的 `innerAudioContext.stop()`）。
  ///
  /// 必须在 `initState` 里就取出来：`dispose` 里再用 `ref` 会直接抛
  /// “Using ref when a widget is about to or has been unmounted is unsafe”，
  /// 而且抛在 `dispose` 里会把整个测试隔离区（后续所有用例）一起挂住。
  late final VoicePlayerNotifier _voicePlayer;

  /// 会话仓库。
  ///
  /// 在 `initState` 里就取出来，因为输入框会在 `dispose` 里回写草稿，
  /// 那时候再 `ref.read` 会抛“查一个已经失活的 widget 的祖先”
  /// （这个错会把整个测试隔离区一起挂住）。
  late final ConversationRepository _conversations;

  /// 消息仓库（撤回/删除/转发/@ 面板要用），理由同上
  late final MessageRepository _messages;

  /// 「标为未读」那本本地账（进页面要清它），理由同上
  late final ManualUnreadNotifier _manualUnread;

  /// 撤回后点「重新编辑」要填回输入框的文本
  String? _editText;

  /// 顶栏那颗通话钮的**锚**：弹出的「语音 / 视频」小菜单要挂在它下面
  /// （见 [appMenuPosition]）。
  ///
  /// 存成 State 字段而不是在 `build` 里现造 —— 现造等于每次重建都换一个锚，
  /// 菜单正在开着时上一层重建一下就会找不到它。
  final GlobalKey _callAnchor = GlobalKey(debugLabel: 'chatNavCallAnchor');

  /// 上一帧真拿到过的消息列表。
  ///
  /// 「加载更多」是把 `_limit` 放大一页，而 `_limit` 是 provider 的 key ——
  /// 于是**换了一个全新的 provider**，它头一帧只有 `loading`、没有值。
  /// 那一帧列表是空的，反向列表的 maxScrollExtent 跟着变 0、滚动位移被夹到 0，
  /// 界面就猛地跳回最底下（用户 2026-09-21 反馈：转圈后自动跳到最底）。
  /// 所以新 provider 还没吐值的那几帧，拿这份旧列表先顶着。
  List<Message>? _lastMessages;

  @override
  void initState() {
    super.initState();
    _voicePlayer = ref.read(voicePlayingProvider.notifier);
    _conversations = ref.read(conversationRepositoryProvider);
    _messages = ref.read(messageRepositoryProvider);
    _manualUnread = ref.read(manualUnreadProvider.notifier);
    _scroll.addListener(_onScroll);
    // 进了这个会话，它那条系统通知就没用了（老端是点通知进来后自己消失，
    // 新端补上「从会话列表进来」也能清）
    unawaited(
      ref
          .read(messageNotificationPresenterProvider)
          .cancel(widget.conversationId),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_onEnter()));
  }

  @override
  void dispose() {
    unawaited(_voicePlayer.stop());
    _scroll.dispose();
    super.dispose();
  }

  ChatQuery get _query => ChatQuery(widget.conversationId, _limit);

  /// 直接问数据库要当前窗口的消息。
  ///
  /// 刻意**不读 provider 的当前值**：进页那一瞬间流还没吐第一帧，
  /// provider 的值是 null，会被当成“本地没有缓存”而去打接口
  /// （这个错是组件测试里那条“有缓存不打接口”的断言抓出来的）。
  ///
  /// 也刻意**不碰 `ref`**：这个方法是在 [\_onEnter] 的 await 之后调的，
  /// 而点通知进来又马上离开（路由被重定向 / 被别处 pop）时页面已经被弹掉了 ——
  /// 那时 `ref.read` 会直接抛
  /// “Using "ref" when a widget is about to or has been unmounted is unsafe”
  /// （真机 2026-10-08 抓到的就是这条：`_cached` ← `_onEnter`）。
  /// 仓库在 `initState` 里就存成字段了，用字段就没有这个问题。
  Future<List<Message>> _cached() =>
      _messages.cached(widget.conversationId, limit: _limit);

  /// 进会话 / 新消息到达时清掉「标为未读」的本地标记。
  ///
  /// 长按列表选「标为未读」那一行会顶一个红点（不带数字），一进去就该没。
  /// 单独一个方法是因为有两处清未读（进页面、以及正在看时来了新消息都要清）。
  Future<void> _clearManualUnreadMark() =>
      _manualUnread.clear(widget.conversationId);

  /// 进页面：补最新一页 → 清本地未读 → 按发送人上报已读。
  ///
  /// 顺序是刻意的：
  /// 1. 先补一次最新一页（本地有缓存也要补，见 [_refreshNewest]），
  /// 否则离线期间漏掉的消息永远不出现；
  /// 2. 未读的发送人要在 `markReadLocally` **之前**取——它会把整个会话标成已读，
  ///    之后就看不出那些消息原本是谁发的了；
  /// 3. 最后才把已读上报给服务端，不然下拉刷新时服务端的旧未读会把角标带回来。
  Future<void> _onEnter() async {
    if (_entered || !mounted) return;
    _entered = true;

    // 「我是谁」先取出来：下面每一句都要 await，等回来时页面可能已经不在了
    // （那时再 `ref.read` 就抛了，见 [_cached] 的注释）
    final myUserId = ref.read(sessionStoreProvider).userId;

    final conversations = _conversations;
    final conversation = await conversations.find(widget.conversationId);
    if (conversation == null) {
      // 会话已不存在（在别处被删了）：界面显示空，不再做任何事
      return;
    }
    _unreadAtEntry = conversation.unread;
    _draft = conversation.draft;

    final cached = await _cached();
    if (cached.isEmpty) {
      // 本地什么都没有：先拉一页把界面撑起来
      await _loadHistory();
    } else {
      // 本地有缓存也要补最新一页：服务端不会重放离线期间的推送
      await _refreshNewest(conversation);
    }

    final senders = await _messages.unreadSenders(
      widget.conversationId,
      myUserId: myUserId,
    );

    if (conversation.unread > 0 || senders.isNotEmpty) {
      // 老端进页面只清本地未读（不调接口）；新端多一步：把未读在服务端也标掉。
      // 服务端的未读是同步（`getContacts`）时的真相，不标掉的话「已读 → 刷新又未读」。
      // 只看 `unread`：@ 角标要等用户点开 @ 面板才清（和会话行清未读是两件事）。
      await conversations.markReadLocally(widget.conversationId);
      await _clearManualUnreadMark();
      for (final sender in senders) {
        await _messages.reportRead(
          conversationId: widget.conversationId,
          isGroup: conversation.isGroup,
          fromUserId: sender,
        );
      }
    }

    // 已经在看的这批不当作「新消息」重复上报
    final latest = await _cached();
    if (latest.isNotEmpty) _reportedServerId = latest.last.serverId ?? 0;

    _entryReady = true;
    if (mounted) setState(() {});
  }

  /// 补一次「最新一页」（老端每次进聊天页都拿空 `last_id` 拉第一页）。
  ///
  /// 只补最新那一页，不动 `_limit` / `_historyEnded`：往上的翻历史仍然是
  /// 「本地够用就不碰网络」。
  Future<void> _refreshNewest(Conversation conversation) async {
    try {
      await _messages.refreshNewest(
        conversationId: widget.conversationId,
        isGroup: conversation.isGroup,
        limit: ChatPage.pageSize,
      );
    } on ApiException catch (error) {
      // 拉不到就继续用本地缓存（重连补偿、下拉刷新还会再补）
      debugPrint('[聊天] 补最新消息失败：${error.message}');
    }
  }

  /// 「加载更多」：先把本地窗口放大，本地真的没有了才去服务端翻页。
  ///
  /// 老端是一页一页请求、没有本地缓存，所以每次进聊天都要等接口；
  /// 新端本地够用就不打接口（离线也能翻历史）。
  Future<void> _loadHistory() async {
    if (_loading || _historyEnded) return;

    // 整个流程都算「加载中」：不然用户连续上滑会并发跑进来好几份，
    // 把窗口一次放大好几页（本地缓存本来够用，却被白白放大）
    _loading = true;
    if (mounted) setState(() {});
    try {
      final cached = await _cached();
      if (cached.length >= _limit) {
        // 本地还够：只把窗口放大一页，完全不碰网络
        if (mounted) setState(() => _limit += ChatPage.pageSize);
        return;
      }

      final conversation = await _conversations.find(widget.conversationId);
      if (conversation == null) return;

      final page = await _messages.loadPage(
        conversationId: widget.conversationId,
        isGroup: conversation.isGroup,
        // 游标就是「当前手里最旧那条」的 msg_id（老端取列表第一个）
        lastId: cached.isEmpty ? null : cached.first.msgId,
        page: _serverPage,
        limit: ChatPage.pageSize,
      );
      _serverPage += 1;
      if (!page.hasMore) _historyEnded = true;
      if (mounted) setState(() => _limit += ChatPage.pageSize);
    } on ApiException catch (error) {
      debugPrint('[聊天] 加载历史失败：${error.message}');
    } finally {
      // 失败、或者中途 return（会话没了）也要把「加载中」收尾，
      // 不然列表顶上那个转圈会一直挂着
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  /// 点了带内容的气泡（老端 `chat.vue` 里那串 `@tap`）。
  ///
  /// * 图片/动态表情 → 预览页（老端 `showImgs` 会把整条记录里的图片都收进去）
  /// * 视频 → 全屏播放页（老端 `handlePlay`）
  /// * 文件 → 底部两项弹层（老端 `previewFile`）
  /// * 位置 → 唤起系统地图（老端 `openLocation`）
  /// * 名片 → M5、通话卡片 → M6（语音由气泡自己播放，不走这里）
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
      case 'webrtc':
        final call = callPayloadOf(message);
        // 群通话记录（打完留在群里那一条）：点一下弹一张详情卡（时长 / 人数 /
        // 「加入」或「再次发起」），**不再一点就直接进群通话页**。
        //
        // 为什么 S6.16 改了这条行为：群通话页进去就是加入房间，而服务端「第一笔就叫醒」
        // 那条规则会让**离线群成员的手机响一声**——手滑点一下就会真的叫醒一群人。
        // 微信里点这条记录也是看详情。1:1 的记录没变，仍是老端的回拨。
        if (call.groupCall) {
          await _showGroupCallRecord(message, call);
        } else {
          await _startCall(type: call.type);
        }
      default:
        break;
    }
  }

  /// 点一张音乐卡片 → **直接开播 + 进灵听播放页**。
  ///
  /// 微信里点分享来的歌也是「点一下就开始放」，不再多一次确认。
  /// 卡片自己带着歌名/歌手/封面/音频地址，所以**不需要联网**就能起播；
  /// 播放页会再按 songId 去补歌词与时长。
  ///
  /// 注意两张单的顺序：**先把播放点着，再进页面，但不等它**。
  /// 起播要等一次网络（播放器 `setUrl`），以前这里是 `await playSong(...)`
  /// 之后才 `push`，网络一慢/一抽，看到的就是「点了没反应，或者歌响了
  /// 但页面没动、再点一次才进」。播放状态里「现在这首」是起播头一件事就写好的
  /// （在等网络之前），所以页面一开就有歌。
  Future<void> _playMusicCard(Message message) async {
    final card = musicCardOf(message);
    final i18n = ref.read(appI18nProvider);
    if (!card.playable) {
      // 服务端偶尔有裸记录（没有音频地址）——播不了就只提示，别跳一个空播放页
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

  /// 点一张资讯卡片 → 资讯详情页。
  ///
  /// 卡片自己带着标题/摘要/缩略图/原文地址，所以**收卡片的人本机没有这一篇也能看**
  /// （详情页在列表里找不到时会用卡片里那份合成，见 `NewsDetailPage.shared`）；
  /// 本机恰好也有（自己分享的、或自己列表里那条），就直接用本机那条，带已读状态。
  void _openNewsCard(Message message) {
    final card = newsCardOf(message);
    if (card.isEmpty) return;
    // 桌面宽窗：文章开在**系统级独立窗口**里（微信 PC 点公众号文章就是这种
    // 手感），聊天 / 列表都留在原地；手机 / 窄窗照旧推整页。
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

  /// 点一张名片 → 对方资料页（老端 `mixins/chat.js::openContact`）。
  ///
  /// 老端是 `navigateTo('/pages/contacts/detail?id=' + item.id)`，
  /// 其中 `id` 就是名片 `extends.id`（对方的 `user_id`）。
  void _openContactCard(Message message) {
    final userId = contactCardTargetId(message);
    if (userId.isEmpty) {
      debugPrint('[聊天] 这张名片没带 id，跳不了资料页');
      return;
    }
    context.push(
      '${AppRoutes.contactsDetail}?id=${Uri.encodeComponent(userId)}',
    );
  }

  /// 点头像：自己的进「我」的资料页，别人的进他的资料页。
  ///
  /// 老端聊天页的眼睛是「好看但不能点」的（只有聊天信息页那一圈头像能点），
  /// 用户 2026-09-20 要求补上；群聊里点别人的头像还会把 `group_id` 一起带过去，
  /// 这样资料页里那块「群内管理」才有数据（老端群成员列表就是这么跳的）。
  void _onAvatarTap(Message message, Conversation conversation) {
    final userId = message.fromUserId;
    if (userId.isEmpty) return;
    final myId = ref.read(sessionStoreProvider).userId;
    if (userId == myId) {
      context.push(AppRoutes.mineProfile);
      return;
    }
    // 群聊里带 `group_id`（服务端的群会话 id 就是 `group-5` 这种，自带那道横线）
    final groupId = conversation.isGroup == 1
        ? '&group_id=${Uri.encodeComponent(conversation.id)}'
        : '';
    context.push(
      '${AppRoutes.contactsDetail}?id=${Uri.encodeComponent(userId)}$groupId',
    );
  }

  /// 视频：全屏播放页（老端 `/pages/message/video?name=&src=`）
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

  /// 文件：先弹「本地预览 / 在线预览」，再按后缀决定下载后系统打开、还是交给浏览器。
  ///
  /// 后缀判断照抄老端：只有 pdf/office 那几种能本地打开，音频直接开浏览器，
  /// 其余弹「该文件不支持预览」。
  Future<void> _openFile(Message message) async {
    final payload = filePayloadOf(message);
    if (payload.isEmpty) return;
    final choice = await showFilePreviewSheet(context, message);
    if (choice == null || !mounted) return;

    final saver = ref.read(mediaSaverProvider);
    final i18n = ref.read(appI18nProvider);
    // 音频走「在线预览」那条（老端也是把它丢给内嵌浏览器）
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

    // 老端这里弹的是 `uni.showLoading('文件加载中')`，新端用全局提示代替
    noticeBus.toast(i18n.t('message.fileLoading'));
    try {
      final path = await saver.download(
        payload.url,
        fileName: payload.name.isEmpty
            ? fileNameFromUrl(payload.url)
            : payload.name,
      );
      // 系统里没有能打开它的应用时，`openDocument` 也是这个表现——给一句话，别静默
      if (!await saver.openLocalFile(path) && mounted) {
        noticeBus.toast(i18n.t('message.fileNotSupport'));
      }
    } on Object catch (error) {
      debugPrint('[聊天] 文件下载失败：$error');
      if (mounted) noticeBus.toast(i18n.t('network.error'));
    }
  }

  /// 位置：唤起系统地图（老端 `uni.openLocation`；Flutter 只能拼链接）
  Future<void> _openLocation(Message message) async {
    final payload = locationPayloadOf(message);
    final i18n = ref.read(appI18nProvider);
    // 老端没有坐标时会把 `undefined` 递给系统（大概率什么都没发生），这里明说一句
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

  Future<void> _openPreview(Message tapped) async {
    if (tapped.content.isEmpty) return;
    final messages =
        ref.read(chatMessagesProvider(_query)).value ?? const <Message>[];
    // 老端是「遍历一遍列表，把 image/emoji 都收进去」；顺序上它用 unshift 变成
    // 倒序，新端按时间正序收（左右滑的方向不一样，不影响使用）
    final urls = <String>[
      for (final message in messages)
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

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // reverse 列表里 extentAfter 是「离最旧那条还有多远」
    if (_scroll.position.extentAfter < _loadMoreThreshold) {
      unawaited(_loadHistory());
    }
  }

  void _scrollToBottom() {
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
    setState(() => _newCount = 0);
  }

  /// 正在看的会话来了新消息：清本地未读 + 上报已读。
  ///
  /// 老端只上报了接口，本地未读会一直挂着（返回列表时能看到一个红点）；
  /// 新端顺便把本地未读清掉。
  Future<void> _onIncoming(List<Message> messages) async {
    if (messages.isEmpty || !_entryReady) return;
    final newest = messages.last;
    final myUserId = ref.read(sessionStoreProvider).userId;
    if (newest.isMine(myUserId)) return;

    final serverId = newest.serverId ?? 0;
    if (serverId <= _reportedServerId) return;
    // 上报前先数一下这一波来了几条，回到底部的按钮上要显示条数（老端 newMsgCount）
    final fresh = messages
        .where((message) => (message.serverId ?? 0) > _reportedServerId)
        .length;
    _reportedServerId = serverId;

    await _conversations.markReadLocally(widget.conversationId);
    await _clearManualUnreadMark();
    await _messages.reportRead(
      conversationId: widget.conversationId,
      isGroup: newest.isGroup,
      fromUserId: newest.fromUserId,
    );

    // 用户正在上面看历史：不打断他，用按钮提示（老端 newMsgCount）
    if (mounted && _scroll.hasClients && _scroll.position.pixels > 60) {
      setState(() => _newCount += fresh);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final conversation = ref
        .watch(chatConversationProvider(widget.conversationId))
        .value;
    final asyncMessages = ref.watch(chatMessagesProvider(_query));
    final messages = asyncMessages.value ?? _lastMessages ?? const <Message>[];
    final setting = ref.watch(
      sessionStoreProvider.select((state) => state.setting),
    );
    final config = ref.watch(
      sessionStoreProvider.select((state) => state.config),
    );
    final apiUrl = ref.watch(appConfigProvider).apiUrl;
    // 背景是设备本地偏好（`chat-bg-info<会话 id>`）。老端要重进聊天才生效，
    // 这里监听仓库的变更通知，在聊天信息页改完当场就变。
    final backgroundRepo = ref.watch(chatBackgroundRepositoryProvider);

    ref.listen<AsyncValue<List<Message>>>(chatMessagesProvider(_query), (
      previous,
      next,
    ) {
      final list = next.value;
      if (list == null) return;
      _lastMessages = list;
      unawaited(_onIncoming(list));
    });

    if (conversation == null) {
      return _buildScaffold(
        context,
        i18n,
        title: widget.conversationId,
        embedded: widget.embedded,
        child: Center(
          child: Text(
            i18n.t('group.noContact'),
            style: TextStyle(
              fontSize: context.rpx(28),
              color: AppColors.text999,
            ),
          ),
        ),
      );
    }

    final items = buildChatItems(
      messages,
      // 本地窗口还有余量、或服务端还有更早的消息 → 上面还能继续加载
      hasMoreHistory: messages.length >= _limit || !_historyEnded,
      translate: i18n.t,
    );

    return _buildScaffold(
      context,
      i18n,
      // 「我的收藏」「系统通知」的名字要跟语言走（服务端存的是中文），
      // 见 `ConversationRules.displayNameOf`
      title: ConversationRules.displayNameOf(conversation, translate: i18n.t),
      conversation: conversation,
      embedded: widget.embedded,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ValueListenableBuilder<int>(
              valueListenable: backgroundRepo.revision,
              builder: (context, _, _) => _background(
                context,
                background: backgroundRepo.load(widget.conversationId),
                child: ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: EdgeInsets.symmetric(vertical: context.rpx(20)),
                  itemCount: items.length + (_loading ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= items.length) {
                      return Padding(
                        padding: EdgeInsets.all(context.rpx(20)),
                        child: const Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.text999,
                            ),
                          ),
                        ),
                      );
                    }
                    final item = items[index];
                    return switch (item) {
                      ChatTimeItem() => ChatTimeDivider(text: item.text),
                      ChatMessageItem() => _bubble(
                        context,
                        item.message,
                        conversation: conversation,
                        setting: setting,
                        config: config,
                        i18n: i18n,
                        apiUrl: apiUrl,
                      ),
                    };
                  },
                ),
              ),
            ),
          ),
          // 「N 人提到我」（老端那个 `fixed-item`）
          if (conversation.isAt > 0)
            Positioned(
              left: context.rpx(30),
              bottom: context.rpx(140),
              child: GestureDetector(
                onTap: () => unawaited(_openMentions()),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rpx(16),
                    vertical: context.rpx(8),
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.orange,
                    borderRadius: BorderRadius.circular(context.rpx(30)),
                  ),
                  child: Text(
                    '${conversation.isAt}${i18n.t('message.remindMe')}',
                    style: TextStyle(
                      fontSize: context.rpx(24),
                      color: AppColors.white,
                    ),
                  ),
                ),
              ),
            ),
          if (_newCount > 0)
            Positioned(
              right: context.rpx(30),
              bottom: context.rpx(140),
              child: GestureDetector(
                onTap: _scrollToBottom,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rpx(16),
                    vertical: context.rpx(8),
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.brand,
                    borderRadius: BorderRadius.circular(context.rpx(30)),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    '$_newCount',
                    style: TextStyle(
                      fontSize: context.rpx(24),
                      color: AppColors.white,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 一条消息气泡。
  ///
  /// 长按菜单显哪几项由 `domain/chat/message_actions.dart` 算（纯函数，单测覆盖），
  /// 这里只负责给出当前上下文（我是谁、群角色、服务端那两个开关、当前时间）。
  Widget _bubble(
    BuildContext context,
    Message message, {
    required Conversation conversation,
    required AppSetting setting,
    required GlobalConfig config,
    required AppI18n i18n,
    required String apiUrl,
  }) {
    final session = ref.read(sessionStoreProvider);
    final meId = session.userId;
    final now = nowMillis();
    final redoTime = config.chatInfo.redoTime;
    return MessageBubble(
      message: message,
      mine: message.isMine(meId),
      circleAvatar: setting.circleAvatar,
      showOnline:
          conversation.isOnline == 1 &&
          conversation.isGroup == 0 &&
          config.chatInfo.online == 1,
      translate: i18n.t,
      onAvatarTap: (target) => _onAvatarTap(target, conversation),
      onContentTap: _onContentTap,
      onRetry: _resend,
      onQuote: (target) => setState(() => _quote = target),
      actions: availableActions(
        message: message,
        myUserId: meId,
        role: conversation.role,
        isGroup: conversation.isGroup == 1,
        redoTimeSeconds: redoTime,
        dbDelMsg: config.chatInfo.dbDelMsg == 1,
        nowMs: now,
      ),
      onAction: (target, action) => unawaited(_onMessageAction(target, action)),
      canReedit: canReedit(
        message: message,
        myUserId: meId,
        redoTimeSeconds: redoTime,
        nowMs: now,
      ),
      onReedit: (target) => setState(() => _editText = target.content),
    );
  }

  /// 长按菜单里的每一项
  Future<void> _onMessageAction(Message message, MessageAction action) async {
    final i18n = ref.read(appI18nProvider);
    switch (action) {
      case MessageAction.undo:
        await _messages.undo(
          conversationId: widget.conversationId,
          serverId: message.serverId,
          msgId: message.msgId,
        );
      case MessageAction.copy:
        // 老端 `uni.setClipboardData` 会自己弹一句「已复制」
        await Clipboard.setData(ClipboardData(text: copyText(message)));
        noticeBus.toast(i18n.t('message.copy'));
      case MessageAction.saveEmoji:
        final fileId = int.tryParse(message.extra['file_id'].toString()) ?? 0;
        try {
          await ref.read(emojiApiProvider).add(<String, dynamic>{
            'file_id': fileId,
          });
          if (mounted) noticeBus.toast(i18n.t('message.saveEmoji'));
        } on ApiException catch (error) {
          debugPrint('[表情] 存表情失败：${error.message}');
        }
      case MessageAction.forward:
        await _forward(message);
      case MessageAction.quote:
        setState(() => _quote = message);
      case MessageAction.report:
        await _report(message);
      case MessageAction.delete:
        await _delete(message, i18n);
    }
  }

  /// 转发（老端 `userSelection.vue` 的 type 3：选人 → `forwardMessage`）
  Future<void> _forward(Message message) async {
    final msgId = message.msgId ?? '';
    if (msgId.isEmpty) return;
    final targets = await showForwardPicker(
      context,
      excludeId: widget.conversationId,
    );
    if (targets == null || targets.isEmpty || !mounted) return;
    final i18n = ref.read(appI18nProvider);
    try {
      await _messages.forward(
        userIds: targets.map((target) => target.id).toList(),
        msgId: msgId,
      );
    } on ApiException catch (error) {
      debugPrint('[消息] 转发失败：${error.message}');
      if (mounted) noticeBus.toast(i18n.t('common.noData'));
    }
  }

  /// 举报这一条消息（S13.1，2026-10-11 新增）。
  ///
  /// 带上发送者（后台那一列要有名字）、消息的 uuid 与数字主键、以及群会话 id
  /// （单聊不带）。内容预览用 [reportPreview]：让用户在提交前看一眼举报的是哪一条。
  ///
  /// 真正的护栏在服务端（只能举报「和我有关的会话」里的消息）；
  /// 客户端这道只是 [canReport] 那三条（不是我发的 / 没撤回 / 不是系统消息）。
  Future<void> _report(Message message) async {
    final i18n = ref.read(appI18nProvider);
    await showReportSheet(
      context,
      target: ReportTarget.message(
        userId: message.fromUserId,
        userName: message.fromUserName,
        msgId: message.msgId ?? '',
        serverId: message.serverId ?? 0,
        groupId: message.isGroup == 1 ? widget.conversationId : '',
        preview: reportPreview(message, i18n.t),
      ),
    );
  }

  /// 删除（老端先弹一句「删除消息会从所有人的聊天记录中抹掉」）
  Future<void> _delete(Message message, AppI18n i18n) async {
    // `danger`：删消息是不可逆的，右键红字（微信删东西也是红）
    final confirmed = await showWeChatConfirm(
      context,
      message: i18n.t('message.delMsgConfirm'),
      danger: true,
    );
    if (!confirmed) return;
    try {
      await _messages.delete(
        conversationId: widget.conversationId,
        serverId: message.serverId,
        msgId: message.msgId,
      );
    } on ApiException catch (error) {
      debugPrint('[消息] 删除失败：${error.message}');
    }
  }

  /// 「N 人提到我」：点开就是清 @ 提醒（老端 `openAtModel` → `readAtMsg`）
  Future<void> _openMentions() async {
    final meId = ref.read(sessionStoreProvider).userId;
    await _conversations.clearAt(widget.conversationId);
    if (!mounted) return;
    await showMentionPanel(
      context,
      conversationId: widget.conversationId,
      myUserId: meId,
    );
  }

  /// 背景：老端 `chat-bg-info<id>` 里的图片 + 可选的模糊层。
  ///
  /// 老端存的是**本机文件路径**（`uni.saveFile` 的产物），所以这里本地文件走
  /// [Image.file]；`http` 开头的当网络图（老端在某些端上也可能存过 URL）。
  Widget _background(
    BuildContext context, {
    required ({String image, bool filter}) background,
    required Widget child,
  }) {
    if (background.image.isEmpty) return child;
    final path = background.image;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: path.startsWith('http')
              ? Image.network(
                  path,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) =>
                      const ColoredBox(color: AppColors.page),
                )
              : Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  // 文件被删了 / 换设备之后路径失效：当没有背景，不要报错
                  errorBuilder: (context, error, stack) =>
                      const ColoredBox(color: AppColors.page),
                ),
        ),
        if (background.filter)
          const Positioned.fill(child: ColoredBox(color: Color(0x66FFFFFF))),
        Positioned.fill(child: child),
      ],
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    AppI18n i18n, {
    required String title,
    required Widget child,
    Conversation? conversation,
    bool embedded = false,
  }) {
    // 桌面内嵌（三栏右栏）：右边那块信息面板由这里挂 —— 摆成 Row 的第二个孩子，
    // 而不是 Overlay/Drawer：微信 PC 那一栏是**挤占**聊天区宽度（消息流跟着变窄），
    // 不是盖在上面。面板只在「⋯」开着时才在树上。
    final panelOpen =
        embedded && ref.watch(chatInfoPanelProvider) && conversation != null;

    final chatArea = Column(
      children: <Widget>[
        _buildNavBar(
          context,
          title: title,
          conversation: conversation,
          embedded: embedded,
        ),
        // 群里正在开语音时，标题栏下面常挂一条「N 人正在语音通话 · 加入」（S6.16）。
        // 只有群会话才有这回事（系统会话、单聊整条不画，高度为 0、也不吃触摸）。
        if (conversation != null && conversation.isGroup == 1)
          GroupCallBar(
            conversationId: conversation.id,
            onJoin: () => unawaited(_openGroupCall()),
          ),
        Expanded(child: child),
        _buildInput(context, i18n, conversation: conversation),
      ],
    );

    if (!panelOpen) {
      return Scaffold(
        // 聊天页底色是微信那层浅灰（比列表页的 `page` 深一档）
        backgroundColor: AppColors.chatBackground,
        body: chatArea,
      );
    }

    return Scaffold(
      backgroundColor: AppColors.chatBackground,
      body: Row(
        children: <Widget>[
          Expanded(child: chatArea),
          // 面板里就是「聊天信息」那份内容（成员 / 群名称 / 公告 / 群管理/
          // 查找记录 / 开关…全在栏里滚），不再从面板里推一整页手机版详情
          ChatInfoPanel(
            conversation: conversation,
            onClearHistory: () =>
                unawaited(_clearHistoryFromPanel(conversation)),
          ),
        ],
      ),
    );
  }

  /// 侧栏面板里的「清空聊天记录」。
  ///
  /// 聊天信息**整页**里那份逻辑（[ChatInfoPage._clearHistory]）比这里复杂：
  /// 群里我是群主时还要连服务端一起清。侧栏这一版只做「本机清」——
  /// 微信 PC 那一栏里的「清空聊天记录」也是本机口径，删全体的入口在群资料里。
  Future<void> _clearHistoryFromPanel(Conversation conversation) async {
    final i18n = ref.read(appI18nProvider);
    final confirmed = await showWeChatConfirm(
      context,
      message: i18n.t('chat.clearRecordTips'),
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    final messages = await ref
        .read(messageRepositoryProvider)
        .cached(conversation.id, limit: ClearedChatsStore.maxIdsPerChat);
    await ClearedChatsStore.instance.mark(
      conversation.id,
      ids: <String>{
        for (final message in messages) ...<String>[
          if ((message.msgId ?? '').isNotEmpty) message.msgId!,
          if (message.serverId != null) '${message.serverId}',
        ],
      },
      lastSendTime: messages.isEmpty
          ? 0
          : messages
                .map((Message item) => item.sendTime)
                .reduce((a, b) => a > b ? a : b),
    );
    await ref.read(messageRepositoryProvider).deleteFor(conversation.id);
    await ref
        .read(conversationRepositoryProvider)
        .clearPreview(conversation.id);
    if (!mounted) return;
    noticeBus.toast(i18n.t('common.clearOk'));
  }

  /// 导航栏：返回（带未读数角标，老端就这么画的）、标题、更多（进聊天设置）
  Widget _buildNavBar(
    BuildContext context, {
    required String title,
    Conversation? conversation,
    bool embedded = false,
  }) {
    // `is_group == 2` 是老端的「系统会话」（系统通知那种），
    // 它俩在 `chat.vue` 里都是 `v-if="is_group!=2"`：不给「更多」按钮
    final isSystem = conversation?.isGroup == 2;
    final showOnline =
        conversation != null &&
        conversation.isGroup == 0 &&
        conversation.isOnline == 1;

    return Container(
      // 微信安卓：聊天页的顶栏和聊天背景是同一档浅灰，靠下面那条细线分界
      decoration: const BoxDecoration(
        color: AppColors.navBar,
        border: Border(
          bottom: BorderSide(color: AppColors.navDivider, width: 0.5),
        ),
      ),
      height: context.statusBarHeight + context.customBarHeight,
      padding: EdgeInsets.only(top: context.statusBarHeight),
      child: Row(
        children: <Widget>[
          // 桌面上嵌在右栏里时不画返回箭头：左边那一列列表一直在，
          // 没有「返回上一页」这个动作（微信 PC 的聊天顶栏也没箭头）
          if (!embedded)
            SizedBox(
              width: 56,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new,
                      size: 18,
                      color: AppColors.text333,
                    ),
                    onPressed: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(AppRoutes.home);
                      }
                    },
                  ),
                  if (_unreadAtEntry > 0)
                    Positioned(
                      right: 4,
                      top: 6,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 16),
                        height: 16,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: AppColors.red,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _unreadAtEntry > 99 ? '99+' : '$_unreadAtEntry',
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.white,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: Row(
              // 内嵌（桌面右栏）：标题靠左，像微信 PC 那样；
              // 手机上仍是屏幕正中（右边挂两个图标也不会把它挤偏）
              mainAxisAlignment: embedded
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: <Widget>[
                // 内嵌时标题贴左（微信 PC 那儿顶栏只有名字，没有头像）
                if (embedded) SizedBox(width: context.rpx(28)),
                if (showOnline)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppColors.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text333,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 桌面内嵌（三栏右栏）：微信 PC 在右上角摆「查找聊天记录 / 通话 / ⋯」
          // （用户 2026-10-03 给的两张截图）。手机上仍是原来那一颗「更多」。
          if (embedded && !isSystem)
            _desktopActions(context, conversation, isSystem: isSystem)
          else
            SizedBox(
              width: 56,
              child: isSystem
                  ? null
                  : IconButton(
                      icon: const Icon(
                        Icons.more_horiz,
                        size: 22,
                        color: AppColors.text333,
                      ),
                      onPressed: () => context.push(
                        '${AppRoutes.chatDetail}'
                        '?id=${Uri.encodeComponent(widget.conversationId)}'
                        '&is_group=${conversation?.isGroup ?? 0}',
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  /// 桌面右栏顶栏右边那三颗（微信 PC）：查找聊天记录 / 通话 / 更多。
  ///
  /// 通话那颗在**单聊且服务端开了 webrtc** 时才画（与输入区那个入口同一套
  /// 条件，见 [_buildInput] 里的 `canCall`）；群里那颗是群通话，与输入区
  /// 「＋」面板里那项同一个动作。点了弹一个小菜单选「语音通话 / 视频通话」
  /// （微信 PC 也是先弹菜单，不是直接拨）。
  Widget _desktopActions(
    BuildContext context,
    Conversation? conversation, {
    required bool isSystem,
  }) {
    final i18n = ref.watch(appI18nProvider);
    final me = ref.watch(sessionStoreProvider.select((state) => state.user));
    final webrtcEnabled = ref.watch(
      sessionStoreProvider.select((state) => state.config.webrtcEnabled),
    );
    final isGroup = conversation?.isGroup == 1;
    final canCall =
        conversation != null &&
        conversation.isGroup == 0 &&
        conversation.id != (me?.userId ?? '') &&
        webrtcEnabled;
    final canGroupCall = isGroup;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _navIcon(
          context,
          key: const ValueKey<String>('chatNavRecord'),
          icon: Icons.search,
          tooltip: i18n.t('chat.searchMsg'),
          onTap: () => context.push(
            '${AppRoutes.chatRecord}'
            '?id=${Uri.encodeComponent(widget.conversationId)}'
            '&is_group=${conversation?.isGroup ?? 0}',
          ),
        ),
        if (canCall || canGroupCall)
          _navIcon(
            context,
            key: const ValueKey<String>('chatNavCall'),
            // 菜单靠它定位（见 [_showCallMenu]）
            anchorKey: _callAnchor,
            icon: Icons.videocam_outlined,
            tooltip: i18n.t('common.webrtc'),
            // 正在通话中就不开这颗菜单：直接一句「你正在通话中，请先挂断」
            // —— 用户 2026-10-04 的要求（一通电话里不能再发起第二通）。
            // 状态机里本来也就拦（老端那三道检查），但那句提示是
            // 「其他终端正在通话中」，本地自己拨第二通时看着丈二和尚；
            // 这里提前拦下，提示与实际情形对得上。
            onTap: () {
              if (ref.read(callBusyProvider)) {
                noticeBus.toast(i18n.t('group.callBusy'));
                return;
              }
              _showCallMenu(
                context,
                i18n,
                canCall: canCall,
                canGroupCall: canGroupCall,
              );
            },
          ),
        _navIcon(
          context,
          key: const ValueKey<String>('chatNavMore'),
          icon: Icons.more_horiz,
          tooltip: i18n.t('message.info'),
          // ⋯ 在桌面是**右侧信息面板**（微信 PC 那栏），不再整页跳转。
          // 群成员 / 群公告 / 群管理仍在面板里那个「聊天信息」入口后面。
          onTap: () => ref.read(chatInfoPanelProvider.notifier).toggle(),
        ),
        SizedBox(width: context.rpx(16)),
      ],
    );
  }

  /// 顶栏上的一颗图标（桌面版）：比手机那颗小一档，带 Tooltip。
  ///
  /// [anchorKey] 给「要弹菜单」的那颗用：外面再套一层 [KeyedSubtree] 当把手，
  /// 菜单定位时用它拿这颗钮的 `RenderBox`（见 [appMenuPosition]）。
  Widget _navIcon(
    BuildContext context, {
    required Key key,
    GlobalKey? anchorKey,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final button = Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: IconButton(
        key: key,
        icon: Icon(icon, size: context.rpx(40), color: AppColors.text333),
        onPressed: onTap,
      ),
    );
    return anchorKey == null
        ? button
        : KeyedSubtree(key: anchorKey, child: button);
  }

  /// 顶栏那颗通话：弹一个小菜单选语音 / 视频（微信 PC 就是这么两步）。
  ///
  /// 位置**锚在 [_callAnchor] 那颗钮的下面**（右对齐着往左长，微信 PC 那种下拉）。
  /// 2026-10-04 之前这里把 `context.findRenderObject()` 当锚用 —— 那是**整页**
  /// 那块 RenderBox，菜单于是飘到窗口右下角，离钮十万八千里（用户截图）。
  Future<void> _showCallMenu(
    BuildContext context,
    AppI18n i18n, {
    required bool canCall,
    required bool canGroupCall,
  }) async {
    final selected = await showMenu<String>(
      position: appMenuPosition(context, anchorKey: _callAnchor),
      context: context,
      items: <PopupMenuEntry<String>>[
        if (canCall) ...<PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'voice',
            child: Text(i18n.t('message.voiceCall')),
          ),
          PopupMenuItem<String>(
            value: 'video',
            child: Text(i18n.t('message.videoCall')),
          ),
        ],
        if (canGroupCall)
          PopupMenuItem<String>(
            value: 'group',
            child: Text(i18n.t('group.call')),
          ),
      ],
    );
    if (selected == null || !mounted) return;
    switch (selected) {
      case 'voice':
        await _startCall(type: CallType.voice);
      case 'video':
        await _startCall(type: CallType.video);
      case 'group':
        await _openGroupCall();
    }
  }

  /// 输入区（S4.4）。
  ///
  /// 系统会话（`is_group == 2`，老端的「系统通知」）不给输入框——老端 `chat.vue`
  /// 里就是 `v-if="is_group!=2"`。
  Widget _buildInput(
    BuildContext context,
    AppI18n i18n, {
    Conversation? conversation,
  }) {
    if (conversation == null || conversation.isGroup == 2) {
      return SizedBox(height: context.bottomSafeHeight);
    }
    final me = ref.watch(sessionStoreProvider.select((state) => state.user));
    final webrtcEnabled = ref.watch(
      sessionStoreProvider.select((state) => state.config.webrtcEnabled),
    );
    // 通话入口的条件（老端 `im-input.vue` 那两处 `v-if`）：
    // `!contact.is_group && webrtc`，即**只有 is_group == 0 的单聊**才给按钮：
    // 群聊（1）、系统通知（2）、「我的收藏 / 应用号」这类（3）都不给——
    // 老端一个 `!is_group` 就把它们全排掉了，新端之前只排了群聊，所以在
    // 「我的收藏」「自己的聊天」里也冒出了语音/视频按钮。
    // 另外会话 id 就是自己的（跟自己聊）也发不起通话，一并排掉。
    final canCall =
        conversation.isGroup == 0 &&
        conversation.id != (me?.userId ?? '') &&
        webrtcEnabled;
    // 群通话的入口：群里（`is_group == 1`）就给 —— 与私聊那两项摆在「＋」面板的
    // 同一行，用户不用再钻到群资料页里找。
    final canGroupCall = conversation.isGroup == 1;
    return ChatInput(
      // 换会话时重建输入框（草稿、引用条、面板状态都是它自己的）
      key: ValueKey<String>(widget.conversationId),
      conversationId: widget.conversationId,
      isGroup: conversation.isGroup == 1,
      meUserId: me?.userId,
      initialDraft: _draft,
      canSend: canSpeak(conversation) && me != null,
      quoteText: _quoteText(i18n),
      quoteAuthor: _quoteAuthor(),
      onClearQuote: () => setState(() => _quote = null),
      editText: _editText,
      onEditConsumed: () => setState(() => _editText = null),
      onDraftChanged: (draft) {
        _draft = draft;
        unawaited(_conversations.saveDraft(widget.conversationId, draft));
      },
      onSendText: _sendText,
      onSendSticker: _sendSticker,
      onSendMedia: _sendMedia,
      onSendContactCard: _sendContactCard,
      // 单聊 + 服务端开了 webrtc 才给通话入口（老端那两处 `v-if` 的条件）
      onStartCall: canCall ? (type) => unawaited(_startCall(type: type)) : null,
      // 群通话（「＋」面板里的「群通话」）
      onStartGroupCall: canGroupCall ? () => unawaited(_openGroupCall()) : null,
    );
  }

  /// 点群通话记录 → 先弹一张**详情卡**（S6.16），不再是进去就开一场新的。
  ///
  /// 卡上那两样真实数据取自消息的 `extends`（`callTime` / `participants`，见
  /// `MessageSender.sendGroupCallRecord`）；「现在还在不在开」取自在线状态那本账
  /// （`GroupCallPresenceTracker` —— 与会话列表那行标记、聊天页顶上那条是同一个
  /// 来源，所以三处不会互相矛盾）。
  ///
  /// 卡上那颗按钮走的是 [_openGroupCall]：还在开就是加入，散了就是**重新开一间**。
  Future<void> _showGroupCallRecord(Message message, CallPayload call) async {
    final conversation = await _conversations.find(widget.conversationId);
    if (conversation == null) return;
    final i18n = ref.read(appI18nProvider);
    final live =
        ref.read(groupCallPresenceProvider).liveIn(conversation.id) != null;
    if (!mounted) return;
    await showGroupCallRecordSheet(
      context,
      groupName: conversation.displayName,
      // 时长口径与那条记录本身一致（**分钟:秒**，见 `formatCallRecordDuration`）：
      // 卡上写「00:45」、气泡里也是「群通话 00:45」，同一个数字
      duration: formatCallRecordDuration(call.durationSeconds),
      participants: call.participants,
      live: live,
      translate: i18n.t,
      onAction: () => unawaited(_openGroupCall()),
    );
  }

  /// 进这个群的群通话页（与群资料页那个入口同一个路由）。
  ///
  /// 1:1 通话中不给进，理由与群资料页那个入口一样（两套通话都要麦克风）：
  /// 那种时候只提示一声，不把人推进去。
  Future<void> _openGroupCall() async {
    final conversation = await _conversations.find(widget.conversationId);
    if (conversation == null) return;
    final i18n = ref.read(appI18nProvider);
    if (ref.read(callControllerProvider).view.value.isActive) {
      noticeBus.toast(i18n.t('group.callBusy'));
      return;
    }
    if (!mounted) return;
    context.push(
      '${AppRoutes.groupCall}?id=${Uri.encodeComponent(conversation.id)}'
      '&name=${Uri.encodeComponent(conversation.displayName)}',
    );
  }

  /// 发起一通电话（S6.3）：聊天输入区那个「语音通话/视频通话」，
  /// 以及通话卡片上的回拨都走这里。
  ///
  /// 老端 `im-input.vue::calling(is_video)` 的三道检查（没开 webrtc、关了私聊、
  /// 已在通话中）都在状态机里，所以这里无脑把参数递进去，该提示的自己会提示。
  Future<void> _startCall({required int type}) async {
    final conversation = await _conversations.find(widget.conversationId);
    if (conversation == null) {
      debugPrint('[聊天] 会话不在了，发不起通话：${widget.conversationId}');
      return;
    }
    // 与输入区那个按钮同一套条件（通话卡片回拨也走这里）：
    // 只有单聊能通话，群聊 / 系统通知 / 我的收藏 / 跟自己聊都拦掉。
    final meId = ref.read(sessionStoreProvider).userId;
    if (conversation.isGroup != 0 || conversation.id == meId) {
      debugPrint(
        '[聊天] 这个会话不支持通话：${conversation.id}（is_group=${conversation.isGroup}）',
      );
      return;
    }
    // 群语音在跑也不给拨（S6.20）：两套通话都要麦克风，而**前台服务只有一份**
    // ——同时开着的话，一方挂断时会把另一方的常驻通知一起停掉。
    // 与「1:1 通话中不给进群通话」那两处入口同一个口径。
    if (ref.read(groupCallBusyProvider)) {
      noticeBus.toast(ref.read(appI18nProvider).t('group.callBusy'));
      return;
    }
    // 已经在 1:1 通话里也不再起第二通（用户 2026-10-04 的要求）。
    // 与上面那颗菜单同一道闸：状态机里虽然也拦，但它的文案是
    // 「其他终端正在通话中」，对本地这个场景对不上号。
    if (ref.read(callBusyProvider)) {
      noticeBus.toast(ref.read(appI18nProvider).t('group.callBusy'));
      return;
    }
    if (!mounted) return;
    // 拨号前先确保麦克风（视频再确保摄像头）：没授权就**不发这一通**
    // （弹系统框 + 一句「去授权」），用户 2026-09-27 的要求。
    if (!await ensureCallPermissions(
      context,
      ref,
      video: type == CallType.video,
    )) {
      return;
    }
    if (!mounted) return;
    // 「来电全屏显示」没开时提醒一句（S12.8）：以前这条是消息页顶上的红条，
    // 用户要求改成拨号前弹一次（见 `remindFullScreenBeforeCall`）
    await remindFullScreenBeforeCall(context, ref);
    if (!mounted) return;
    final config = ref.read(sessionStoreProvider).config;
    await ref
        .read(callControllerProvider)
        .start(
          peerId: widget.conversationId,
          peerName: conversation.displayName,
          peerAvatar: conversation.avatar,
          type: type,
          webrtcEnabled: config.webrtcEnabled,
          simpleChatEnabled: config.chatInfo.simpleChat == 1,
        );
  }

  /// 引用的作者（群里会自动 @ 他；老端 `im-input.vue::quoteMessage`）
  GroupMember? _quoteAuthor() {
    final quote = _quote;
    if (quote == null) return null;
    return GroupMember(
      userId: quote.fromUserId,
      name: quote.fromUserName,
      avatar: quote.fromUserAvatar,
    );
  }

  /// 引用条上的那行字（与发送时写进 `extends.content` 的一模一样）
  String? _quoteText(AppI18n i18n) {
    final quote = _quote;
    if (quote == null) return null;
    return buildQuote(quote, translate: i18n.t)['content']?.toString();
  }

  /// 发文本（引用/@ 由发送层组装，见 `domain/chat/outgoing_message.dart`）
  Future<void> _sendText(String text, List<String> at) async {
    final conversation = await _currentConversation();
    final me = ref.read(sessionStoreProvider).user;
    if (conversation == null || me == null) return;

    final quoted = _quote;
    setState(() => _quote = null);
    final result = await ref
        .read(messageSenderProvider)
        .sendText(
          conversation: conversation,
          me: me,
          content: text,
          quoted: quoted,
          at: at,
          translate: ref.read(appI18nProvider).t,
        );
    if (!mounted) return;
    // 失败就在气泡上标红（点一下重发），提示由 `ApiClient` 统一弹
    if (result.ok) _scrollToBottom();
  }

  /// 发收藏表情（老端点一下直接发，不进输入框）
  Future<void> _sendSticker(CustomEmoji emoji) async {
    final conversation = await _currentConversation();
    final me = ref.read(sessionStoreProvider).user;
    if (conversation == null || me == null) return;
    await ref
        .read(messageSenderProvider)
        .sendSticker(
          conversation: conversation,
          me: me,
          url: emoji.url,
          fileId: emoji.fileId,
        );
    if (mounted) _scrollToBottom();
  }

  /// 发一张名片（老端「+」面板 → 名片 → 选一位好友 → 完成）
  Future<void> _sendContactCard(Contact contact) async {
    final conversation = await _currentConversation();
    final me = ref.read(sessionStoreProvider).user;
    if (conversation == null || me == null) return;
    final i18n = ref.read(appI18nProvider);
    final result = await ref
        .read(messageSenderProvider)
        .sendContactCard(
          conversation: conversation,
          me: me,
          card: ContactCard.fromContact(contact),
          translate: i18n.t,
        );
    if (mounted) _scrollToBottom();
    // 发送失败与其它消息一样只在气泡上标红（老端也是），这里不额外弹提示
    if (!result.ok) debugPrint('[聊天] 名片发送失败：${result.error}');
  }

  /// 发一份图片/视频/文件（老端 `chat.vue::sendMessage` 的 fileTypes 分支）。
  ///
  /// 两道限制都在这里判，因为文案与服务端配置都在这一层：
  /// * 大小：`globalConfig.fileUpload.size`（MB，默认 10）；
  /// * 视频时长：60 秒（老端 `chat.videoLimit`）。
  Future<void> _sendMedia(PickedMedia media) async {
    final i18n = ref.read(appI18nProvider);
    // 图片先压小（S4.4c）：原图动辄 4~10MB（手机拍的），压完通常只有一两百 KB。
    // 顺序很重要 —— 大小限制要比**压完之后**的体积，否则一张 20MB 的照片会被
    // 直接顶回来，而它压完其实只有 300KB（微信也是这个顺序）。
    final prepared = await ref.read(imageCompressorProvider).compress(media);
    final limit = ref.read(sessionStoreProvider).config.maxUploadMb;
    if (prepared.size > limit * 1024 * 1024) {
      noticeBus.toast('${i18n.t('message.fileLimit')}$limit M');
      return;
    }
    if (media.kind == MediaKind.video && media.durationSeconds > 60) {
      noticeBus.toast(i18n.t('chat.videoLimit'));
      return;
    }

    final conversation = await _currentConversation();
    final me = ref.read(sessionStoreProvider).user;
    if (conversation == null || me == null) return;

    final result = await ref
        .read(messageSenderProvider)
        .sendMedia(conversation: conversation, me: me, media: prepared);
    if (!mounted) return;
    if (result.ok) _scrollToBottom();
  }

  /// 重发一条失败的消息
  Future<void> _resend(Message message) async {
    final conversation = await _currentConversation();
    final me = ref.read(sessionStoreProvider).user;
    if (conversation == null || me == null) return;
    if (!canSpeak(conversation)) {
      noticeBus.toast(ref.read(appI18nProvider).t('group.noSpeakNoSend'));
      return;
    }
    await ref
        .read(messageSenderProvider)
        .resend(message: message, me: me, isGroup: conversation.isGroup);
  }

  Future<Conversation?> _currentConversation() =>
      _conversations.find(widget.conversationId);
}

/// 时间分隔条（老端 `.cu-info`）
class ChatTimeDivider extends StatelessWidget {
  const ChatTimeDivider({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    // 微信那条时间分隔**没有底色**：就是一行浅灰字浮在聊天背景上
    // （老端和我们之前都是一个半透明黑底胶囊，摆在微信旁边很显眼）
    return Container(
      margin: EdgeInsets.symmetric(vertical: context.rpx(20)),
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(horizontal: context.rpx(16)),
      child: Text(
        text,
        style: TextStyle(fontSize: context.rpx(24), color: AppColors.textTime),
      ),
    );
  }
}
