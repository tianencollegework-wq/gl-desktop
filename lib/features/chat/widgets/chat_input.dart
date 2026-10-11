import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/speech_to_text.dart';
import '../../../core/audio/voice_recorder.dart';
import '../../../core/i18n/app_i18n.dart';
import '../../../core/media/media_picker.dart';
import '../../../core/platform/app_permissions.dart';
import '../../../core/platform/desktop_shell.dart';
import '../../../core/platform/app_settings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/ui/hover_highlight.dart';
import '../../../core/ui/notice_bus.dart';
import '../../../core/ui/permission_gate.dart';
import '../../../core/util/emoji_pack.dart';
import '../../../core/util/uuid.dart';
import '../../../data/model/contact.dart';
import '../../../domain/call/call_signal.dart';
import '../../../domain/chat/group_members.dart';
import 'contact_card_picker.dart';
import 'emoji_panel.dart';
import 'member_picker.dart';
import 'voice_record_overlay.dart';

/// 输入区（S4.4，对应老端 `components/message/im-input.vue`）。
///
/// 结构照老端：左边表情按钮，中间输入框，右边「发送」按钮（有内容才出现），
/// 引用条在输入框下面；表情面板贴着输入区展开（老端就是把它画在同一块里）。
///
/// 与老端不同的三点（刻意的）：
/// 1. **输入框里存的是纯文本 + `[!code]` 表情 token**，不是富文本 `<img>`。
///    聊天页渲染 token 的方式与老端一致，所以对方看到的一样；而纯文本在
///    草稿、预览、搜索里都干净得多。
/// 2. **草稿写在会话行的 `draft` 列**（老端是 `draft_<id>` 这个独立 storage key）。
///    落库之后换设备/重启都不丢，也与会话列表的草稿标记同源。
/// 3. **@ 用的是纯文本 token**（`@名字`），不是老端富文本里的 link 节点；
///    发送时按「文本里还留着这个 @」来决定带不带这个 user_id
///    （见 `domain/chat/group_members.dart::resolveAt`），与老端 `edit.getLink()` 同语义。
/// 4. **录音界面放在输入行上方**（老端是绝对定位的浮层）。避免被外层裁剪，
///    也省掉一层 `Overlay`；按住时的文案与秒数跟老端一致。
class ChatInput extends ConsumerStatefulWidget {
  const ChatInput({
    super.key,
    required this.initialDraft,
    required this.canSend,
    required this.onSendText,
    required this.onSendSticker,
    required this.onSendMedia,
    required this.onSendContactCard,
    this.onStartCall,
    this.onStartGroupCall,
    required this.conversationId,
    this.isGroup = false,
    this.meUserId,
    this.onDraftChanged,
    this.quoteText,
    this.quoteAuthor,
    this.onClearQuote,
    this.editText,
    this.onEditConsumed,
    this.enabled = true,
  });

  /// 输入框初始内容（进来时从会话行读出来的草稿）
  final String initialDraft;

  /// 当前会话能不能发言（群禁言，见 `domain/chat/outgoing_message.dart`）
  final bool canSend;

  /// 发送文本（引用块由聊天页持有，发送时自己带上）。
  ///
  /// 第二个参数是文本里 @ 到的群成员 id（老端的 `at`）。
  final Future<void> Function(String text, List<String> at) onSendText;

  /// 发送收藏表情（老端点一下直接发）
  final Future<void> Function(CustomEmoji emoji) onSendSticker;

  /// 发一份刚选好的媒体（图片/视频/文件）。
  ///
  /// 大小与时长限制由聊天页判（它手里有服务端配置与文案），这里只管选。
  final Future<void> Function(PickedMedia media) onSendMedia;

  /// 发一张名片（老端「+」面板里的「名片」：先从好友里选一位）
  final Future<void> Function(Contact contact) onSendContactCard;

  /// 发起音视频通话（老端「＋」面板里的「语音通话」「视频通话」两项）。
  ///
  /// 传 null 就不显示这两项（群聊，或服务端没开 `webrtc`）——
  /// 老端的条件是 `!contact.is_group && parseInt(globalConfig.chatInfo.webrtc)`。
  /// 三道拦截（没开 webrtc / 关了私聊 / 已在通话中）都在状态机里。
  final void Function(int type)? onStartCall;

  /// 发起群语音（「＋」面板里的「群通话」）。
  ///
  /// 与 1:1 那两项摆在同一个位置、同样是**明确的用户动作**：之前群通话只藏在
  /// 群资料页里，用户根本找不到（"群里怎么没有像私聊那样的通话按钮"）。
  /// 传 null 就不显示这一项（单聊、系统会话）。
  final VoidCallback? onStartGroupCall;

  /// 当前会话 id（打开群成员选择器要用）
  final String conversationId;

  /// 是不是群聊（决定 @ 入口显不显示，老端 `contact.is_group==1`）
  final bool isGroup;

  /// 当前登录用户 id（判断引用的作者是不是自己）
  final String? meUserId;

  /// 草稿变化（写回会话行）
  final void Function(String draft)? onDraftChanged;

  /// 引用条上的那行字（由聊天页用 `buildQuote` 拼好，长按菜单在那边）
  final String? quoteText;

  /// 引用的是谁（群里会自动 @ 他，老端 `quoteMessage()` 里做的事）
  final GroupMember? quoteAuthor;

  final VoidCallback? onClearQuote;

  /// 外面塞进来的「待编辑」文本（撤回后点「重新编辑」）。
  /// 用它填完输入框后要调 [onEditConsumed]，不然下次进来还会被填一次。
  final String? editText;

  final VoidCallback? onEditConsumed;

  final bool enabled;

  /// 输入上限（老端 `editor` 的 `maxlength="300"`）
  static const int maxLength = 300;

  @override
  ConsumerState<ChatInput> createState() => _ChatInputState();
}

/// 输入区下方展开的那块面板（老端 `appBox`：0 无、1 表情、2 工具栏）
enum InputPanel { none, emoji, more }

class _ChatInputState extends ConsumerState<ChatInput> {
  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode();
  InputPanel _panel = InputPanel.none;
  bool _hasText = false;

  /// 老端的 `recShow`：输入框换成「按住说话」
  bool _voiceMode = false;

  /// 正在录（老端 `isUseRecorder`）
  bool _recording = false;

  /// 手指当前所在的区（老端只有一个 `isCancel`，微信是「取消 / 转文字」两个）
  VoiceRecordZone _zone = VoiceRecordZone.send;

  /// 全屏录音浮层的状态（浮层自己订阅它，输入区只负责改）
  final ValueNotifier<VoiceRecordState> _voiceState =
      ValueNotifier<VoiceRecordState>(const VoiceRecordState());

  /// 插在根 Overlay 上的录音浮层（不接收触摸，手势还在这个控件手里）
  OverlayEntry? _overlayEntry;

  /// 已录秒数（老端 `recLength`，1 秒一跳）
  int _seconds = 0;

  /// 防止「抬手」与「录满 60 秒自动停」同时收尾
  bool _finishing = false;

  Timer? _timer;

  /// 已 @ 的人（老端 `edit` 里的 link 列表）。
  /// 只增不减：文本里删掉的 @ 由 `resolveAt` 负责排除。
  final Map<String, GroupMember> _mentions = <String, GroupMember>{};

  bool get _emojiOpen => _panel == InputPanel.emoji;

  /// 桌面形态（回车发送、Shift+回车换行、不摆「拍摄」那一格）。
  ///
  /// 读 provider 而不是裸的 `isDesktopRuntime`：`flutter test` 也跑在 Windows
  /// 上，裸判据会把桌面分支开进那套钉着手机行为的用例里
  /// （见 `desktop_shell.dart::desktopFeaturesProvider`）。
  bool get _desktop => ref.read(desktopFeaturesProvider);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialDraft);
    _hasText = _controller.text.trim().isNotEmpty;
    _controller.addListener(_onTextChanged);
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    // 键盘和面板**互斥**：系统输入法一冒出来就把表情/「＋」面板收起来。
    // 不改的话两者会同时占着下半屏（面板还在、键盘又顶上来），输入框被挤到看不见。
    // 老端是 `@focus` 的时候 `showAppBox(0)`，一个道理。
    if (_focus.hasFocus && _panel != InputPanel.none) {
      setState(() => _panel = InputPanel.none);
      return;
    }
    // @ 按钮只在群聊且聚焦时出现（老端 `v-show="isFocus && contact.is_group==1"`）
    if (widget.isGroup) setState(() {});
  }

  /// 草稿是异步读出来的（先建界面再读到会话行），所以它到得晚一步：
  /// 用户还没敲字时把值补进输入框（老端是 `editorCtx.setContents` 的时候填的）。
  @override
  void didUpdateWidget(ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    final draft = widget.initialDraft;
    if (draft.isNotEmpty &&
        draft != oldWidget.initialDraft &&
        _controller.text.isEmpty) {
      _controller.text = draft;
      _hasText = true;
    }

    // 「重新编辑」：把撤回掉的那条原文填回输入框。
    //
    // `onEditConsumed` 会改聊天页的 state，而这里正处在父级 build 流程里——
    // 直接调就是 “setState() called during build”。所以推到本帧之后。
    final edit = widget.editText;
    if (edit != null && edit != oldWidget.editText) {
      _controller.text = edit;
      _hasText = edit.trim().isNotEmpty;
      final consumed = widget.onEditConsumed;
      if (consumed != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) consumed();
        });
      }
      _focus.requestFocus();
    }

    // 群里引用别人的消息时自动 @ 对方（老端 `quoteMessage()` → `setAtList`）
    final author = widget.quoteAuthor;
    if (widget.isGroup &&
        author != null &&
        author.userId != widget.meUserId &&
        author != oldWidget.quoteAuthor) {
      _mentions[author.userId] = author;
      _insertText('@${author.name} ');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // 浮层是插在根 Overlay 上的，页面走了必须收掉，否则会留在别的页面上
    _removeOverlay();
    _voiceState.dispose();
    // 录着就走人（返回键/被移出会话）必须把麦克风放掉
    if (_recording) {
      _recording = false;
      unawaited(ref.read(voiceRecorderProvider).cancel());
    }
    // 离开页面存草稿（老端 `beforeUnmount` 里做的事）
    _saveDraft();
    _controller.removeListener(_onTextChanged);
    _focus.removeListener(_onFocusChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _saveDraft() => widget.onDraftChanged?.call(_controller.text.trim());

  /// 内置表情：插到光标处（老端 `insertImage`）。
  ///
  /// 老端插的是 `[!code]` token（靠服务端图片渲染）；新端插的是**系统表情字符**，
  /// 所以自己发的消息里没有 token，网页端/老端收到的也是普通 emoji。
  void _insertEmoji(String char) => _insertText(char);

  /// 往光标处插一段文本，插完光标跟在后面（超出上限就不插）
  void _insertText(String token) {
    final value = _controller.value;
    final text = value.text;
    final selection = value.selection;
    // 光标不可用时（刚打开面板）插到末尾
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    if (text.length - (end - start) + token.length > ChatInput.maxLength) {
      return;
    }
    final next = text.replaceRange(start, end, token);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
    // 面板开着的时候**不要**抢焦点：那样键盘会同时冒出来（键盘与面板互斥），
    // 而用户想的是连着点好几个表情。等关面板时 `_togglePanel` 自己会把焦点要回来。
    if (_panel == InputPanel.none) _focus.requestFocus();
  }

  // ── @ 提及 ───────────────────────────────────────────────

  /// 打开群成员选择器（老端「@」按钮 → `usermodel` 弹层）
  Future<void> _pickMentions() async {
    final picked = await showMemberPicker(
      context,
      groupId: widget.conversationId,
      preselected: _mentions.values.toList(),
    );
    if (picked == null || !mounted) return;
    // 只把「新选中的人」插进文本（老端 `addLink` 也只插新选的）
    final added = picked
        .where((member) => !_mentions.containsKey(member.userId))
        .toList();
    setState(() {
      for (final member in picked) {
        _mentions[member.userId] = member;
      }
    });
    for (final member in added) {
      _insertText('@${member.name} ');
    }
  }

  /// 文本里仍然存在的 @（老端的 `edit.getLink()`）
  List<String> get _atIds =>
      resolveAt(_controller.text, _mentions.values.toList());

  // ── 录音（老端「按住说话」）─────────────────────────────

  void _toggleVoiceMode() {
    setState(() {
      _voiceMode = !_voiceMode;
      _panel = InputPanel.none;
    });
    if (_voiceMode) {
      _focus.unfocus();
    } else {
      _focus.requestFocus();
    }
  }

  Future<void> _startRecording() async {
    if (_recording) return;
    if (!widget.canSend) {
      _toastMuted();
      return;
    }
    final i18n = ref.read(appI18nProvider);
    final recorder = ref.read(voiceRecorderProvider);
    // 老端没有显式申请权限，靠 onError 的 code 201 提示；这里先问一次。
    //
    // 被拒时**带一颗「去授权」**：安卓从第二次拒绝起就不再弹系统框，
    // 光说「权限被拒绝」用户只能干瞪眼（与通话那几处同一个口径）。
    if (!await recorder.hasPermission()) {
      noticeBus.toastWithAction(
        i18n.t('chat.revordNotAuth'),
        actionLabel: i18n.t('common.gotoAuth'),
        onAction: () => unawaited(openAppSettings()),
      );
      return;
    }
    try {
      await recorder.start();
    } on Object {
      noticeBus.toast(i18n.t('chat.recordFailed'));
      return;
    }
    if (!mounted) {
      unawaited(recorder.cancel());
      return;
    }
    setState(() {
      _recording = true;
      _zone = VoiceRecordZone.send;
      _seconds = 0;
    });
    _voiceState.value = const VoiceRecordState();
    _insertOverlay();
    // 老端用 1 秒一跳的 setInterval 数秒；到 60 秒自动结束并发送
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds += 1);
      _voiceState.value = _voiceState.value.copyWith(seconds: _seconds);
      if (_seconds >= VoiceRecorder.maxDuration.inSeconds) {
        unawaited(_finishRecording());
      }
    });
  }

  // ── 录音浮层（微信那套全屏浮层）──────────────────────────

  /// 把浮层插到**根** Overlay 上。
  ///
  /// 为什么不画在输入区里：浮层要盖住整个屏幕（连状态栏下面的聊天都压暗），
  /// 而输入区在 `Scaffold` 的 body 里、外面还夹着安全区与裁剪。
  /// 浮层自己 `IgnorePointer`，所以插上去不会把手势抢走。
  void _insertOverlay() {
    _removeOverlay();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final i18n = ref.read(appI18nProvider);
    final recorder = ref.read(voiceRecorderProvider);
    _overlayEntry = OverlayEntry(
      builder: (overlayContext) => VoiceRecordOverlay(
        state: _voiceState,
        amplitude: recorder.amplitude,
        cancelLabel: i18n.t('common.cancel'),
        cancelSendLabel: i18n.t('chat.touchCancel'),
        transcribeLabel: i18n.t('chat.slideToTranscribe'),
        sendLabel: i18n.t('chat.touchEnd'),
        transcribeSendLabel: i18n.t('chat.releaseToTranscribe'),
        transcribingLabel: i18n.t('chat.transcribing'),
        desktop: _desktopRecording,
      ),
    );
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    final entry = _overlayEntry;
    _overlayEntry = null;
    if (entry == null) return;
    if (entry.mounted) entry.remove();
  }

  /// 现在是不是桌面那一档（固定像素 + 短武装线的录音浮层）。
  ///
  /// 不能用 `desktopWideLayout`（它内部 `ref.watch`，只能在 build 里调），
  /// 这里用的是同一套判据的读法：桌面功能开着 + 真实窗口够宽。
  bool get _desktopRecording =>
      ref.read(desktopFeaturesProvider) &&
      realWindowWidth(context) >= kDesktopFrameMinWidth;

  /// 手指移动：从麦克风往上滑过「武装线」就进入「取消 / 转文字」两区，
  /// 左边一半是取消、右边一半是转文字（微信那两个区就在这个位置）；
  /// 没滑过线就是「松开发送」。
  ///
  /// 桌面上的武装线短得多（[VoiceRecordOverlay.desktopArmPx]）：手机上那 220rpx
  /// 是按屏高算的，鼠标往上拖那么远很别扭。
  void _updateZone(Offset position) {
    if (!_recording) return;
    final size = MediaQuery.sizeOf(context);
    final arm = _desktopRecording
        ? VoiceRecordOverlay.desktopArmPx
        : context.rpx(VoiceRecordOverlay.armRpx);
    final armLine = size.height - arm;
    final zone = position.dy > armLine
        ? VoiceRecordZone.send
        : (position.dx < size.width / 2
              ? VoiceRecordZone.cancel
              : VoiceRecordZone.transcribe);
    if (zone == _zone) return;
    _zone = zone;
    _voiceState.value = _voiceState.value.copyWith(zone: zone);
  }

  Future<void> _finishRecording() async {
    if (!_recording || _finishing) return;
    _finishing = true;
    _timer?.cancel();
    _timer = null;
    final i18n = ref.read(appI18nProvider);
    final recorder = ref.read(voiceRecorderProvider);
    final zone = _zone;
    setState(() {
      _recording = false;
      _zone = VoiceRecordZone.send;
    });

    try {
      if (zone == VoiceRecordZone.cancel) {
        // 老端：上滑取消就默默丢掉（只打一条日志），不发也不提示
        _removeOverlay();
        await recorder.cancel();
        return;
      }
      final recording = await recorder.stop();
      if (recording == null) {
        _removeOverlay();
        noticeBus.toast(i18n.t('chat.recordFailed'));
        return;
      }
      if (recording.durationMs < VoiceRecorder.minDuration.inMilliseconds) {
        // 老端 `chat.recordToLow`：太短的录音丢掉
        _removeOverlay();
        await recorder.discard(recording);
        noticeBus.toast(i18n.t('chat.recordToLow'));
        return;
      }
      if (zone == VoiceRecordZone.transcribe) {
        // 滑到右侧「转文字」：**不发语音**，识别出来的文字直接填进输入框
        await _transcribe(recording);
        return;
      }
      _removeOverlay();
      await widget.onSendMedia(
        PickedMedia(
          path: recording.path,
          // 老端是 `uuid + '.mp3'`（实际编码器给的是 m4a，如实命名）
          name: '${uuidV4()}.m4a',
          size: recording.sizeBytes,
          kind: MediaKind.voice,
          durationSeconds: recording.seconds,
        ),
      );
    } finally {
      _finishing = false;
    }
  }

  /// 「滑到这里 转文字」松手后：把刚录的那段交给自建 Whisper Worker 转写，
  /// **识别到什么就把什么填进输入框**（用户 2026-09-20 的要求：
  /// 不做本地语义解析，也不自动发出去，用户自己确认后再点发送）。
  ///
  /// 这条路**不发语音消息**，所以录下来的文件用完就丢。
  Future<void> _transcribe(Recording recording) async {
    final i18n = ref.read(appI18nProvider);
    final recorder = ref.read(voiceRecorderProvider);
    // 回到文字模式：识别结果是要给用户**看和改**的，得先把输入框摆回来
    if (_voiceMode) setState(() => _voiceMode = false);
    _voiceState.value = _voiceState.value.copyWith(transcribing: true);
    try {
      final text = await ref
          .read(speechToTextProvider)
          .transcribe(recording.path);
      if (!mounted) return;
      if (text.isEmpty) {
        // 服务端没听清（静音/太小）：给一句话，别默默把空串填进输入框
        noticeBus.toast(i18n.t('chat.transcribeEmpty'));
        return;
      }
      // 填到光标处（`_insertText` 会把光标跟到后面并拉起键盘）
      _insertText(text);
    } on SpeechToTextException catch (error) {
      debugPrint('[语音] 转文字失败：$error');
      if (mounted) noticeBus.toast(i18n.t('chat.transcribeFailed'));
    } finally {
      await recorder.discard(recording);
      _removeOverlay();
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (!widget.canSend) {
      _toastMuted();
      return;
    }
    // @ 要在清空之前算（文本里还留着的才算，老端同）
    final at = _atIds;
    // 先清空再发：老端也是先把输入框清掉（发送中看到内容还在会以为没发出去）
    _controller.clear();
    setState(() {
      _panel = InputPanel.none;
      _mentions.clear();
    });
    _saveDraft();
    await widget.onSendText(text, at);
  }

  /// 打开/收起面板（老端 `showAppBox`：点同一块就收起来）
  void _togglePanel(InputPanel panel) {
    setState(() => _panel = _panel == panel ? InputPanel.none : panel);
    if (_panel == InputPanel.none) {
      _focus.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  /// 点「语音通话」/「视频通话」：先收起面板，再把请求交给聊天页
  /// （老端是直接 `navigateTo` 通话页，新端由 CallHost 统一开关通话页）
  void _startCall(int type) {
    setState(() => _panel = InputPanel.none);
    widget.onStartCall?.call(type);
  }

  /// 点「群通话」：先收起面板，再交给聊天页进群通话页
  void _startGroupCall() {
    setState(() => _panel = InputPanel.none);
    widget.onStartGroupCall?.call();
  }

  /// 选媒体（老端 `chooseImg` / `chooseVideo` / `chooseFile`）
  /// 选一张名片发出去（老端「+」面板 → 名片 → 选一个好友 → 完成）
  Future<void> _pickContactCard() async {
    if (!widget.canSend) {
      _toastMuted();
      return;
    }
    final contact = await showContactCardPicker(context);
    if (contact == null || !mounted) return;
    await widget.onSendContactCard(contact);
  }

  /// 「拍摄」（「＋」面板第一行第二格）：开系统相机拍一张，
  /// 后续与相册选图走同一条发送链路（压缩、大小限制都在聊天页那边）。
  ///
  /// **拍之前先确认摄像头权限**（用户 2026-09-27 要求：「发送文件和图片视频之前
  /// 的权限检查」）：没有权限时不进系统相机 —— 进去也拍不了，回来后只剩一句
  /// 看不懂的原生报错。
  Future<void> _capturePhoto() async {
    if (!widget.canSend) {
      _toastMuted();
      return;
    }
    final granted = await ensurePermission(
      context,
      gateway: ref.read(permissionGatewayProvider),
      permission: AppPermission.camera,
      messageKey: 'perm.needCamera',
    );
    if (!granted || !mounted) return;
    final photo = await ref.read(mediaPickerProvider).pickCamera();
    if (photo == null) return;
    setState(() => _panel = InputPanel.none);
    await widget.onSendMedia(photo);
  }

  /// 相册 / 视频 / 文件：走系统选择器（图片与视频走相册选择器，不需要额外权限），
  /// 但**选这一步自己可能失败**（相册被拒、文件的 URI 读不到、ROM 抽风）。
  /// 失败一律当「需要权限」处理，给一句能看懂的话 + 那颗「去授权」。
  Future<void> _pick(
    Future<List<PickedMedia>> Function(MediaPicker) pick,
  ) async {
    if (!widget.canSend) {
      _toastMuted();
      return;
    }
    final i18n = ref.read(appI18nProvider);
    final List<PickedMedia> media;
    try {
      media = await pick(ref.read(mediaPickerProvider));
    } on Object catch (error) {
      debugPrint('[聊天] 选文件失败：$error');
      noticeBus.toastWithAction(
        i18n.t('common.allowFileAuthfangemn'),
        actionLabel: i18n.t('common.gotoAuth'),
        onAction: () => unawaited(openAppSettings()),
      );
      return;
    }
    if (media.isEmpty || !mounted) return;
    setState(() => _panel = InputPanel.none);
    for (final item in media) {
      if (!mounted) return;
      await widget.onSendMedia(item);
    }
  }

  void _toastMuted() {
    noticeBus.toast(ref.read(appI18nProvider).t('group.noSpeakNoSend'));
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final quoteText = widget.quoteText;

    return Container(
      // 给用例一个抓手：这块底色的取值本身就是这一轮的交付物（见下面那段注释）
      key: const ValueKey<String>('chatInputBar'),
      // 输入区**不是**聊天区那一档灰（用户 2026-09-29：「现在完全是融合在一起的」，
      // 并给了微信截图）：微信聊天区是 `#EDEDED`，输入区比它**浅一档**（`#F7F7F7`，
      // 与底部 tab 栏同一个灰），顶上一条细线把两块切开。
      // 输入框本身还是白的（浅灰底托白框，微信就是这么摆的）。
      decoration: const BoxDecoration(
        color: AppColors.tabBar,
        border: Border(
          top: BorderSide(color: AppColors.navDivider, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rpx(20),
              context.rpx(14),
              context.rpx(20),
              context.rpx(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (quoteText != null && quoteText.isNotEmpty)
                  _quoteBar(context, quoteText),
                // 桌面（微信 PC，2026-10-03）：一个白框装下「输入 + 工具排」，
                //「发送」常驻右下角（见 [_desktopInputRow]）。
                if (_desktop)
                  _desktopInputRow(context, i18n)
                // 手机：语音/键盘切换 → 输入框 → 表情 → ＋（或发送）
                // （老端是表情在最左、语音切换在其右）
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      _iconButton(
                        context,
                        icon: _voiceMode
                            ? Icons.keyboard_outlined
                            : Icons.mic_none_outlined,
                        onTap: _toggleVoiceMode,
                      ),
                      SizedBox(width: context.rpx(10)),
                      Expanded(
                        child: _voiceMode
                            ? _holdToTalk(context, i18n)
                            : _field(context),
                      ),
                      // 老端：群聊聚焦时多一个「@」（微信在输入框的浮动菜单里，保留老端这个入口）
                      if (widget.isGroup &&
                          _focus.hasFocus &&
                          !_voiceMode) ...<Widget>[
                        SizedBox(width: context.rpx(8)),
                        _iconButton(
                          context,
                          icon: Icons.alternate_email,
                          onTap: () => unawaited(_pickMentions()),
                        ),
                      ],
                      SizedBox(width: context.rpx(8)),
                      _iconButton(
                        context,
                        icon: _emojiOpen
                            ? Icons.keyboard_alt_outlined
                            : Icons.emoji_emotions_outlined,
                        onTap: () {
                          // 表情要插到输入框里，所以先退出录音模式  老端不管
                          if (_voiceMode) _toggleVoiceMode();
                          _togglePanel(InputPanel.emoji);
                        },
                      ),
                      SizedBox(width: context.rpx(8)),
                      // 老端：有内容时是「发送」，没内容时是「+」（`v-if="inputMsg"`）
                      if (_hasText && !_voiceMode)
                        _sendButton(context, i18n)
                      else
                        _iconButton(
                          context,
                          icon: _panel == InputPanel.more
                              ? Icons.keyboard_alt_outlined
                              : Icons.add_circle_outline,
                          onTap: () {
                            if (_voiceMode) _toggleVoiceMode();
                            _togglePanel(InputPanel.more);
                          },
                        ),
                    ],
                  ),
              ],
            ),
          ),
          if (_panel == InputPanel.emoji)
            EmojiPanel(
              onPickBuiltin: _insertEmoji,
              onPickCustom: (emoji) async {
                if (!widget.canSend) {
                  _toastMuted();
                  return;
                }
                await widget.onSendSticker(emoji);
              },
            ),
          if (_panel == InputPanel.more) _morePanel(context, i18n),
          SizedBox(height: context.bottomSafeHeight),
        ],
      ),
    );
  }

  /// 「＋」面板：照微信摆 —— **一行四个**、白方块浮在浅灰底上、深色实心图标、
  /// 下面一行灰字（照微信那张「＋」面板截图）。
  ///
  /// 摆的是**我们真有的**那几样：相册 / 拍摄 / 视频通话 / 语音通话 / 视频 /
  /// 文件 / 个人名片。微信面板里的位置、红包、礼物、转账、收藏、音乐这些
  /// 我们没有对应功能，就不画格子（照「没有的就先不用做」）。
  ///
  /// 通话那两项的**显示条件**照老端 `im-input.vue`：单聊且服务端开了 `webrtc`
  /// 才出现（群聊 / 我的收藏 / 自己的聊天里都不给，理由见聊天页那边）。
  Widget _morePanel(BuildContext context, AppI18n i18n) {
    final height = math.min(
      context.rpx(EmojiPanel.heightRpx),
      MediaQuery.sizeOf(context).height * EmojiPanel.maxHeightRatio,
    );
    final entries = <_MoreEntry>[
      _MoreEntry(
        icon: Icons.photo,
        label: i18n.t('common.album'),
        onTap: () => unawaited(_pick((picker) => picker.pickImages())),
      ),
      // 「拍摄」要相机：桌面上没有相机（`image_picker_windows` 对 camera 直接抛），
      // 所以这一格只在移动端摆（微信 PC 端也没有「拍摄」）。
      if (!_desktop)
        _MoreEntry(
          icon: Icons.photo_camera,
          label: i18n.t('common.capture'),
          onTap: () => unawaited(_capturePhoto()),
        ),
      if (!widget.isGroup && widget.onStartCall != null) ...<_MoreEntry>[
        _MoreEntry(
          icon: Icons.videocam,
          label: i18n.t('message.videoCall'),
          onTap: () => _startCall(CallType.video),
        ),
        _MoreEntry(
          icon: Icons.call,
          label: i18n.t('message.voiceCall'),
          onTap: () => _startCall(CallType.voice),
        ),
      ],
      // 群：与私聊那两项**同一个位置**（一行四个的第三格），也是明确的用户动作。
      // 群通话只有语音（产品口径：语音 + 一人共享屏，没有全员视频）。
      if (widget.isGroup && widget.onStartGroupCall != null)
        _MoreEntry(
          icon: Icons.call,
          label: i18n.t('group.call'),
          onTap: _startGroupCall,
        ),
      _MoreEntry(
        icon: Icons.video_library,
        label: i18n.t('common.video'),
        onTap: () => unawaited(
          _pick((picker) async {
            final video = await picker.pickVideo();
            return video == null ? const <PickedMedia>[] : <PickedMedia>[video];
          }),
        ),
      ),
      _MoreEntry(
        icon: Icons.folder,
        label: i18n.t('common.file'),
        onTap: () => unawaited(_pick((picker) => picker.pickFiles())),
      ),
      _MoreEntry(
        icon: Icons.person,
        label: i18n.t('chat.userIDcard'),
        onTap: () => unawaited(_pickContactCard()),
      ),
    ];

    // 一行四个：格子宽度按可用宽度平分，列间距自己撑开（微信就是这么摆的）。
    // 格子比白方块宽一点，「个人名片」这种四个字才不会挤成两行。
    const columns = 4;
    final gap = context.rpx(60);
    final usable =
        MediaQuery.sizeOf(context).width - context.rpx(60); // 左右各 30rpx
    final cellWidth = math.min(
      (usable - gap * (columns - 1)) / columns,
      context.rpx(160),
    );

    // 面板高度是定死的（与表情面板同一档）。横屏 / 小窗上高度会比两行内容还矮，
    // 那样第二行会被裁掉 —— 所以整体按比例缩一档。
    // 竖屏手机（照片那种宽度）算出来就是 1，什么都看不出差别。
    final rows = (entries.length + columns - 1) ~/ columns;
    const rowRpx = 110.0 + 10 + 37; // 白方块 + 标签上间距 + 一行字
    final needRpx = 50 * 2 + rowRpx * rows + 56 * (rows - 1);
    final scale = math.min(1.0, height / context.rpx(needRpx));
    final square = context.rpx(110 * scale);
    final labelSize = context.rpx(26 * scale);
    final runSpacing = context.rpx(56 * scale);
    final verticalPadding = context.rpx(50 * scale);

    return Container(
      height: height,
      // 微信面板是**浅灰底 + 白方块**（不是白底灰方块，老端那种我们已经换掉了）
      color: AppColors.panelBackground,
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(30),
        vertical: verticalPadding,
      ),
      // 再兜一层滚动：缩过之后理论上塞得下，但字号异常/超小窗上也不会有点不到的项。
      child: SingleChildScrollView(
        child: Wrap(
          spacing: gap,
          runSpacing: runSpacing,
          children: <Widget>[
            for (final entry in entries)
              _moreTile(
                context,
                entry,
                width: cellWidth,
                square: square,
                labelSize: labelSize,
              ),
          ],
        ),
      ),
    );
  }

  /// 「＋」面板里的一格：白方块 + 深色实心图标 + 下面一行灰字
  Widget _moreTile(
    BuildContext context,
    _MoreEntry entry, {
    required double width,
    required double square,
    required double labelSize,
  }) => HoverHighlight(
    // 桌面：悬停给一层 8% 黑（白底上约等于微信那档 #EDEDED）
    borderRadius: BorderRadius.circular(square * 18 / 110),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: entry.onTap,
      child: SizedBox(
        width: width,
        child: Column(
          children: <Widget>[
            Container(
              width: square,
              height: square,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(square * 18 / 110),
              ),
              child: Icon(
                entry.icon,
                size: square * 56 / 110,
                color: AppColors.text000,
              ),
            ),
            Padding(
              padding: EdgeInsets.only(top: square * 10 / 110),
              child: Text(
                entry.label,
                maxLines: 1,
                style: TextStyle(fontSize: labelSize, color: AppColors.text666),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _quoteBar(BuildContext context, String text) {
    return Container(
      margin: EdgeInsets.only(bottom: context.rpx(12)),
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(16),
        vertical: context.rpx(10),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFE3E3E3),
        borderRadius: BorderRadius.circular(context.rpx(6)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(24),
                color: AppColors.text333,
              ),
            ),
          ),
          GestureDetector(
            onTap: widget.onClearQuote,
            child: Icon(
              Icons.close,
              size: context.rpx(30),
              color: AppColors.text666,
            ),
          ),
        ],
      ),
    );
  }

  /// 「按住说话」按钮（老端 `.recorder`）。
  ///
  /// 老端用 touchstart/touchend/touchmove；Flutter 里用 [Listener] 拿原始指针事件，
  /// 而不是 `GestureDetector` 的长按——长按要等 500ms，说话按钮不能等。
  /// 「按住说话」那条：按下开录、移动换区、松手按区收尾。
  ///
  /// 整屏的录音浮层是**另一层**（插在根 Overlay 上、`IgnorePointer`），
  /// 这里的 `Listener` 始终拿着手势 —— 手指滑到屏幕哪一边都不会丢事件。
  Widget _holdToTalk(BuildContext context, AppI18n i18n) => Listener(
    onPointerDown: (_) => unawaited(_startRecording()),
    onPointerMove: (event) => _updateZone(event.position),
    onPointerUp: (_) => unawaited(_finishRecording()),
    onPointerCancel: (_) {
      // 被系统抢走了手势（来电/通知栏）：当成「取消」，别把这段录成一条语音
      if (_recording) _updateZone(Offset.zero);
      unawaited(_finishRecording());
    },
    child: Container(
      height: context.rpx(70),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _recording
            ? (_zone == VoiceRecordZone.cancel
                  ? AppColors.red
                  : AppColors.wechatGreen)
            : AppColors.white,
        borderRadius: BorderRadius.circular(context.rpx(10)),
      ),
      child: Text(
        _recording
            ? '${_zoneLabel(i18n)} $_seconds″'
            : i18n.t('chat.touchSpeak'),
        style: TextStyle(
          fontSize: context.rpx(26),
          color: _recording ? AppColors.white : AppColors.text333,
        ),
      ),
    ),
  );

  /// 输入框里那行字（浮层盖住了，只在浮层还没来得及画时看得见）
  String _zoneLabel(AppI18n i18n) => switch (_zone) {
    VoiceRecordZone.cancel => i18n.t('chat.touchCancel'),
    VoiceRecordZone.transcribe => i18n.t('chat.releaseToTranscribe'),
    VoiceRecordZone.send => i18n.t('chat.touchEnd'),
  };

  /// 桌面那一套：**左边一个大白框，右下角一颗「发送」**。
  ///
  /// 与手机的差别只有「东西摆哪儿」（用户 2026-10-03 给的微信 PC 截图）：
  /// 表情 / 文件（＋面板）/ @ / 语音 这四颗从输入框**外面**挪到框**里面**的下一排，
  /// 而「发送」从框里挪到框外右下角、且**一直在**（没内容时是灰的）。
  /// 手机上仍然是老摆法（
  /// 见 `build` 里那个 `else` 分支）。
  Widget _desktopInputRow(BuildContext context, AppI18n i18n) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: <Widget>[
      Expanded(
        child: _voiceMode
            ? _holdToTalk(context, i18n)
            : _desktopField(context, i18n),
      ),
      SizedBox(width: context.rpx(16)),
      _sendButton(context, i18n, enabled: _hasText && !_voiceMode),
    ],
  );

  /// 桌面那个白框：上半是输入区，下半是工具排（微信 PC 就长这样）
  Widget _desktopField(BuildContext context, AppI18n i18n) => Container(
    constraints: BoxConstraints(minHeight: context.rpx(150)),
    decoration: BoxDecoration(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(context.rpx(10)),
      border: Border.all(color: AppColors.fieldBorder),
    ),
    // `mainAxisSize: min`：输入区在聊天页里是「按内容长高」的（不是撑满），
    // 这里不能用 `Spacer` / `Expanded` —— 高度无界时它们会直接抛布局异常
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.rpx(18),
            context.rpx(14),
            context.rpx(18),
            0,
          ),
          // 回车发送 / Shift+回车换行那一套两边共用（见 [_enterShortcuts]）
          child: _enterShortcuts(_textField(context)),
        ),
        Padding(
          padding: EdgeInsets.only(
            left: context.rpx(8),
            bottom: context.rpx(6),
          ),
          child: Row(
            children: <Widget>[
              _iconButton(
                context,
                icon: _emojiOpen
                    ? Icons.keyboard_alt_outlined
                    : Icons.emoji_emotions_outlined,
                onTap: () {
                  if (_voiceMode) _toggleVoiceMode();
                  _togglePanel(InputPanel.emoji);
                },
              ),
              _iconButton(
                context,
                icon: _panel == InputPanel.more
                    ? Icons.keyboard_alt_outlined
                    : Icons.add_circle_outline,
                onTap: () {
                  if (_voiceMode) _toggleVoiceMode();
                  _togglePanel(InputPanel.more);
                },
              ),
              if (widget.isGroup)
                _iconButton(
                  context,
                  icon: Icons.alternate_email,
                  onTap: () => unawaited(_pickMentions()),
                ),
              _iconButton(
                context,
                icon: _voiceMode
                    ? Icons.keyboard_outlined
                    : Icons.mic_none_outlined,
                onTap: _toggleVoiceMode,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _field(BuildContext context) => Container(
    constraints: BoxConstraints(minHeight: context.rpx(70)),
    padding: EdgeInsets.symmetric(horizontal: context.rpx(20)),
    decoration: BoxDecoration(
      // 白底输入框（微信）：底下的输入区是灰的，靠这层白把输入框托出来
      color: AppColors.white,
      borderRadius: BorderRadius.circular(context.rpx(10)),
    ),
    // 桌面（2026-10-03）：**回车发送、Shift+回车换行**，照微信 PC 端。
    //
    // 手机上不能这么干：软键盘的换行键就是「发送」（`TextInputAction.send`），
    // 换成 newline 之后那个键会变成换行，发送反而没键可用了。
    //
    // 两个细节（Windows 引擎里查过，见 `text_input_plugin.cc::EnterPressed`）：
    // 1. `textInputAction` 得是 `newline`：引擎只在 multiline + newline 时
    //    自己插 `\n`，否则按回车会直接发一条 `performAction`（等于替用户发送，
    //    而我们这里又拦不住）；
    // 2. 因此换行要**我们自己插**（`Shortcuts` 里那条 `InsertNewlineIntent`）——
    //    引擎插的和快捷键插的如果同时发生，会多出一个空行。
    child: _enterShortcuts(_textField(context)),
  );

  /// 桌面上把回车接过来（手机上是直通）。
  ///
  /// 聊天页的输入框有两种外形（手机那个矮框、桌面那个带工具排的白框），
  /// 但「回车发送 / Shift+回车换行」这份快捷键只能有一份 —— 两处各写一遍
  /// 迟早会漂（而且漂了很难发现，得真的敲两下才看得出来）。
  Widget _enterShortcuts(Widget child) => _desktop
      ? Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            // 回车发送（主键盘与数字小键盘都算）
            SingleActivator(LogicalKeyboardKey.enter): SendMessageIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter):
                SendMessageIntent(),
            // Shift+回车换行
            SingleActivator(LogicalKeyboardKey.enter, shift: true):
                InsertNewlineIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true):
                InsertNewlineIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              SendMessageIntent: CallbackAction<SendMessageIntent>(
                onInvoke: (_) {
                  unawaited(_send());
                  return null;
                },
              ),
              InsertNewlineIntent: CallbackAction<InsertNewlineIntent>(
                onInvoke: (_) {
                  _insertText('\n');
                  return null;
                },
              ),
            },
            child: child,
          ),
        )
      : child;

  Widget _textField(BuildContext context) => TextField(
    controller: _controller,
    focusNode: _focus,
    enabled: widget.enabled,
    maxLength: ChatInput.maxLength,
    // 老端 `editor` 是多行自适应；这里跟着长，最多 4 行
    maxLines: 4,
    minLines: 1,
    // 手机：软键盘那个键直接发送；桌面：换行交给上面的快捷键（见 _field）
    textInputAction: _desktop ? TextInputAction.newline : TextInputAction.send,
    onSubmitted: _desktop ? null : (_) => _send(),
    inputFormatters: <TextInputFormatter>[
      LengthLimitingTextInputFormatter(ChatInput.maxLength),
    ],
    style: TextStyle(fontSize: context.rpx(28), color: AppColors.text333),
    decoration: const InputDecoration(
      isDense: true,
      counterText: '',
      border: InputBorder.none,
      // 老端的编辑器没有占位文案，这里也不放——
      // 顺手避免「发送」这个词在界面上出现两次（测试里很难点）
    ),
  );

  /// 「发送」：微信那颗绿按钮
  ///
  /// 桌面（2026-10-03）：包一层 [HoverHighlight] —— 绿钮上的悬停蒙版是
  /// 「再暗一点」，一眼能看出鼠标停在这颗钮上（深浅与圆角跟着按钮走）。
  /// [enabled] 只给桌面用：那边这颗钮**一直在**，没内容时是灰的（微信 PC 就是这样）。
  /// 手机上不给这个参数（钮本身只在有内容时出现），行为不变。
  Widget _sendButton(
    BuildContext context,
    AppI18n i18n, {
    bool enabled = true,
  }) => HoverHighlight(
    borderRadius: BorderRadius.circular(context.rpx(10)),
    enabled: enabled,
    child: GestureDetector(
      onTap: enabled ? _send : null,
      child: Container(
        height: context.rpx(70),
        padding: EdgeInsets.symmetric(horizontal: context.rpx(24)),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? AppColors.wechatGreen : AppColors.gray,
          borderRadius: BorderRadius.circular(context.rpx(10)),
        ),
        child: Text(
          i18n.t('chat.send'),
          style: TextStyle(
            fontSize: context.rpx(26),
            color: enabled ? AppColors.white : AppColors.text999,
          ),
        ),
      ),
    ),
  );

  Widget _iconButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback onTap,
  }) => HoverHighlight(
    enabled: widget.enabled,
    child: GestureDetector(
      onTap: widget.enabled ? onTap : null,
      child: Container(
        height: context.rpx(70),
        width: context.rpx(60),
        alignment: Alignment.center,
        // 微信那排图标接近纯黑
        child: Icon(icon, size: context.rpx(46), color: AppColors.text333),
      ),
    ),
  );
}

/// 「＋」面板里的一格：一颗图标 + 一行字（微信那套白方块）
class _MoreEntry {
  const _MoreEntry({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// 深色**实心**图标（微信面板里的字形都是实心块，所以不用 `_outlined`）
  final IconData icon;

  final String label;

  final VoidCallback onTap;
}

/// 桌面上「回车 = 发送」这个意图（只有桌面会绑，见 [_ChatInputState._field]）。
///
/// 为什么要自己发一个意图：框架把 `enter` 绑成了
/// `DoNothingAndStopPropagationTextIntent`，有意留给输入法去处理；
/// 而在桌面上我们要的正是「回车发送」——直接在 `Shortcuts` 里盖掉它。
class SendMessageIntent extends Intent {
  const SendMessageIntent();
}

/// 桌面上「Shift+回车 = 换行」这个意图。
///
/// 动作是**我们自己插 `\n`**（见 [_ChatInputState._insertText]），
/// 不是交给 `TextInputAction.newline`：Windows 引擎只在 multiline + newline 时
/// 自己插换行，而那条路同时还会吞掉回车（连发送一起没了）。
class InsertNewlineIntent extends Intent {
  const InsertNewlineIntent();
}
