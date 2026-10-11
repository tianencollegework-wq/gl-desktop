import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/chat/chat_info_page.dart';
import '../../features/home/desktop_frame.dart';

import '../../features/chat/chat_record_page.dart';
import '../../features/chat/emoji_manage_page.dart';
import '../../features/chat/group_notice_page.dart';
import '../../features/chat/group_members_page.dart';
import '../../features/call/call_page.dart';
import '../../features/common/placeholder_page.dart';
import '../../features/common/qrcode_page.dart';
import '../../features/common/scan_page.dart';
import '../../core/platform/desktop_shell.dart';
import '../../features/common/link_blocked_page.dart';
import '../../features/common/link_confirm_page.dart';
import '../../features/common/not_found_page.dart';
import '../../features/common/webview_page.dart';
import '../../features/contacts/contacts_page.dart';
import '../../features/contacts/friend_data_page.dart';
import '../../features/contacts/group_join_page.dart';
import '../../features/contacts/group_list_page.dart';
import '../../features/contacts/new_friends_page.dart';
import '../../features/contacts/user_detail_page.dart';
import '../../features/contacts/user_search_page.dart';
import '../../features/group_call/group_call_page.dart';
import '../../features/home/home_shell.dart';
import '../../features/home/user_selection_page.dart';
import '../../features/lingting/lingting_album_page.dart';
import '../../features/lingting/lingting_downloads_page.dart';
import '../../features/lingting/lingting_home_page.dart';
import '../../features/lingting/lingting_player_page.dart';
import '../../features/lingting/lingting_search_page.dart';
import '../../features/lingting/lingting_sheet_page.dart';
import '../../features/lingting/lingting_singer_page.dart';
import '../../features/login/login_page.dart';
import '../../features/login/qr_login_page.dart';
import '../../features/login/register_page.dart';
import '../../features/mine/about_page.dart';
import '../../features/mine/account_cancel_page.dart';
import '../../features/mine/account_change_page.dart';
import '../../features/mine/call_setting_page.dart';
import '../../features/mine/display_setting_page.dart';
import '../../features/mine/feature_page.dart';
import '../../features/mine/doc_page.dart';
import '../../features/mine/notification_setting_page.dart';
import '../../features/news/news_detail_page.dart';
import '../../features/news/news_list_page.dart';
import '../../features/mine/password_change_page.dart';
import '../../features/mine/accounts_page.dart';
import '../../features/mine/profile_page.dart';
import '../../features/mine/secure_page.dart';
import '../../features/mine/setting_page.dart';
import '../../features/search/search_page.dart';
import '../../features/splash/splash_page.dart';
import '../../domain/chat/group_join.dart';
import '../../domain/news/news_card.dart';
import '../../domain/search/local_search.dart';
import 'desktop_register_guard.dart';
import 'session_guard.dart';

/// 路由表。
///
/// 路径与老端 `pages.json` 一一对应（去掉 `pages/` 前缀），方便两头对照。
///
/// 注意：老端 4 个 tab 页面（message/index、contacts/index、compass/index、mine/index）
/// 不在这里，它们由 [HomeShell] 内部承载——老端也是用 `v-show` 把 4 个页面叠在同一个
/// 页面里，而不是 4 个独立路由。其中 `pages/contacts/index` 在 pages.json 里额外声明过
/// （老端默认 tabBar 的残留），这里同样不单独建路由。
abstract final class AppRoutes {
  /// 本地会话恢复期间的启动页（新端才有；老端直接画主界面，等 401 才跳登录页）
  static const String splash = '/splash';

  static const String home = '/';

  // 登录相关
  static const String login = '/login';
  static const String register = '/login/register';
  static const String qrLogin = '/login/qrlogin';

  /// 未登录时允许停留的页面（**只有登录/注册**）
  ///
  /// [qrLogin] **不在这里**（它是新端刻意的偏离）：那一页要拿本机登录态去
  /// `POST /enterprise/im/tokenLogin`，必须已经登着才能用；老端把它放在
  /// `pages/login/` 目录下只是文件摆放，不是「游客可进」。
  /// 放进白名单会被第 3 条规则弹回首页 —— 扫到登录码直接跳回主界面，功能等于不通。
  static const Set<String> authRoutes = <String>{login, register};

  static bool isAuthRoute(String path) => authRoutes.contains(path);

  // 消息
  static const String chat = '/message/chat';
  static const String emoji = '/message/emoji';
  static const String chatDetail = '/message/detail';
  static const String chatRecord = '/message/record';

  /// 群公告（S6.22）：`/message/group/notice?id=<会话 id>&auth=<0|1>`。
  /// 入口是群资料页那一行（管理员 `auth=1`）。
  static const String groupNotice = '/message/group/notice';
  static const String call = '/message/call';
  static const String videoPlay = '/message/video';
  static const String groupUser = '/message/group/groupUser';
  static const String groupInfo = '/message/group/info';

  /// 群通话（S9.1）：`/message/group/call?id=<群会话 id>&name=<群名>`
  static const String groupCall = '/message/group/call';

  // 首页 / 发现
  static const String userSelection = '/index/userSelection';
  static const String qrcode = '/index/qrcode';
  static const String indexSearch = '/index/search';
  static const String scan = '/index/scan';
  static const String moments = '/compass/moments';

  /// 资讯频道（S11.1）：列表 + 一篇。
  ///
  /// 内容不是服务端给的，也不是我们写的 —— 手机自己去拉几个公开 RSS
  /// （源写死在 `domain/news/news_feed.dart`）。入口在「发现」里那一栏。
  static const String newsList = '/news/index';
  static const String newsDetail = '/news/detail';

  // 灵听（音乐频道）——服务端的「发现」里填 `/pages/lingting/index` 就进得来。
  // 段路径与老端 `pages.json` 的风格一致（去掉 `pages/` 前缀），
  // 从前「发现」那条服务端配置里的 `/pages` 前缀会被剥掉才对得上；
  // 2026-09-27 起「发现」那一页是**客户端写死**的（只有灵听一条），直接指路由常量。
  static const String lingtingHome = '/lingting/index';
  static const String lingtingSearch = '/lingting/search';
  static const String lingtingSheet = '/lingting/sheet';
  static const String lingtingSinger = '/lingting/singer';
  static const String lingtingAlbum = '/lingting/album';
  static const String lingtingPlayer = '/lingting/player';
  static const String lingtingDownloads = '/lingting/downloads';

  // 通讯录
  static const String contactsDetail = '/contacts/detail';
  static const String contactsFriendData = '/contacts/detail/friend';
  static const String newFriends = '/contacts/friend';
  static const String contactSearch = '/contacts/search';
  static const String groupList = '/contacts/group';

  // 我的
  static const String webview = '/mine/webview';

  /// 外链的两道闸门（`?url=` 传原地址）：微信/腾讯系 → 拦截页；
  /// 其余第三方 → 「是否继续访问」确认页。见 `core/util/link_safety.dart`。
  static const String linkBlocked = '/mine/linkBlocked';
  static const String linkConfirm = '/mine/linkConfirm';
  static const String mineProfile = '/mine/profile';
  static const String mineSecure = '/mine/secure';

  /// 设置 › 账号与安全 › 修改密码（三步向导页）
  static const String minePassword = '/mine/secure/password';
  static const String mineAccount = '/mine/secure/account';

  /// 设置 › 账号与安全 › 注销账号（不可逆）
  static const String mineCancelAccount = '/mine/secure/cancel';
  static const String mineAbout = '/mine/about';
  static const String mineFeature = '/mine/about/feature';
  static const String mineSetting = '/mine/setting';
  static const String mineDoc = '/mine/doc';

  /// 设置 › 切换账号（S10.1）
  static const String accounts = '/mine/accounts';

  /// 切换账号 › 添加账号：`login` 用 [accountsAdd]、`register` 用
  /// [accountsAddRegister]。
  ///
  /// **刻意不借道 `/login` 那一对**：守卫第 3 条是「已登录的人去登录页就弹回主界面
  /// （[authRoutes]）」，而「添加账号」恰恰是**已经登录时再登一个**——
  /// 借道那两条会被弹回来，功能等于不通。做成普通路由（已登录可进）就不必动守卫。
  ///
  /// `accountsAdd` 支持 `?account=<账号>`，用来从一个「已退出」的账号切到登录表单
  /// （账号预填，只要输密码）。
  static const String accountsAdd = '/mine/accounts/add';
  static const String accountsAddRegister = '/mine/accounts/add/register';

  // 设置里的三组二级页（微信：设置 → 通知 / 界面与显示 / 音视频通话）
  static const String settingNotification = '/mine/setting/notification';
  static const String settingDisplay = '/mine/setting/display';
  static const String settingCall = '/mine/setting/call';
}

/// 待实现的路由：路径 / 标题（取自 pages.json 的 navigationBarTitleText）/ 老端文件 / 里程碑
class _PendingRoute {
  const _PendingRoute(this.path, this.title, this.legacyPath, this.milestone);

  final String path;
  final String title;
  final String legacyPath;
  final String milestone;
}

const List<_PendingRoute> _pendingRoutes = <_PendingRoute>[
  // 朋友圈：**不做**。老端那一页自己写着「此页面是静态模板」，全是写死的假数据，
  // 接口层也没有任何对应的接口，所以留着占位就够了（用户 2026-09-19 决定）。
  _PendingRoute(
    AppRoutes.moments,
    '朋友圈',
    'pages/compass/moments',
    '暂不做（老端那份也只是静态模板）',
  ),
];

/// 还挂着占位页的路径。
///
/// 给用例用的（`test/core/route_placeholders_test.dart`）：**已经实装的页面不能
/// 还留在这张表里**——扫一扫就漏过一次（页面写好了、路由还指着占位页，
/// 点进去是个「待实现」）。有了这个 getter，那种漏法会在用例里直接红。
List<String> get pendingRoutePaths =>
    _pendingRoutes.map((route) => route.path).toList();

/// 二级页在宽屏桌面上的外壳：**同一个桌面框架，内容摆进右栏**（窄窗 / 手机
/// 原样返回，见 [DesktopPageFrame]）。
///
/// 三个参数都是桌面版式的提示，不影响手机：
/// * [section]——从哪个分区点进来的（图标条点亮那一格、中栏摆成那一栏）；
/// * [paneId]——中栏里该点亮哪一行（会话 id / 好友 id / [ContactEntries] 那两个入口名）；
/// * [conversationId]——这一页属于哪个会话。给了它，消息分区会把聊天留在中栏、
///   这一页当右侧栏（会话信息 / 聊天记录 / 群公告 / 群成员就是这个形状）。
///
/// **刻意不包的**：登录 / 注册（整屏表单）、扫一扫（相机）、通话 / 群通话
/// （沉浸式全屏）—— 那几页在桌面上也该吃满整窗。
Widget _desktopPage(
  Widget child, {
  String? section,
  String? paneId,
  String? conversationId,
}) => DesktopPageFrame(
  section: section,
  paneId: paneId,
  conversationId: conversationId,
  child: child,
);

/// 路由实例。
///
/// **刻意做成工厂 + provider，而不是一个全局单例**：GoRouter 会把当前导航栈
/// 记在自己身上，做成全局单例后，测试之间会互相串位置（前一个用例 push 了聊天页，
/// 下一个用例启动时还停在聊天页）。放在 provider 里，每个 `ProviderScope`
/// （生产环境是根作用域，测试里是每个用例）各拿一份干净的实例。
final appRouterProvider = Provider<GoRouter>((ref) {
  final router = createAppRouter();
  ref.onDispose(router.dispose);
  // 真机排查用（2026-10-08「点通知后整个屏幕纯白」）：路由每变一次留一行。
  //
  // 为什么盯这个：go_router 在 `RouteMatchList` **一页都没有**时画的是
  // `const SizedBox.shrink()`（builder.dart 里那句「等异步 redirect 完成前先画个空盒子」）
  // —— 底下就是窗口自己的白底，看上去就是「整屏纯白啥也看不到」。
  // 有了这一行，复现时能直接分清「推上去了没有」与「是不是被谁 pop 空了」。
  router.routerDelegate.addListener(() {
    final config = router.routerDelegate.currentConfiguration;
    debugPrint('[路由] ${config.uri}（${config.matches.length} 页）');
  });
  return router;
});

GoRouter createAppRouter() => GoRouter(
  initialLocation: AppRoutes.home,
  // 会话状态变化（登录 / 登出 / 被顶下线）时重新计算跳转
  refreshListenable: sessionGuard,
  // 两道：电脑端不许走的注册路由，再是会话语义那套（先注册后会话 ——
  // 「电脑端不许注册」优先，免得注册路由被会话规则放过去）
  redirect: (context, state) {
    final location = state.matchedLocation;
    return desktopRegisterBlocked(location) ?? guardRedirect(location);
  },
  routes: <RouteBase>[
    GoRoute(
      path: AppRoutes.splash,
      builder: (context, state) => const SplashPage(),
    ),
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const HomeShell(),
    ),
    GoRoute(
      path: AppRoutes.login,
      builder: (context, state) => const LoginPage(),
    ),
    GoRoute(
      path: AppRoutes.register,
      builder: (context, state) => const RegisterPage(),
    ),
    // 聊天页：`/message/chat?id=<会话 id>`（与老端 `chat?id=` 一致）
    //
    // 走 [ChatScreen] 而不是直接 `ChatPage`：宽屏桌面上它是「三栏框架 + 右栏
    // 就是这个会话」（左边图标条与会话列照旧在），窄窗 / 手机就是聊天页本身。
    // 从搜索、通讯录、通知进聊天也走这一条，所以桌面上的观感是一致的。
    GoRoute(
      path: AppRoutes.chat,
      builder: (context, state) =>
          ChatScreen(conversationId: state.uri.queryParameters['id'] ?? ''),
    ),
    // 聊天信息（S5.3）：`/message/detail?id=<会话 id>&is_group=<n>`
    GoRoute(
      path: AppRoutes.chatDetail,
      builder: (context, state) {
        final id = state.uri.queryParameters['id'] ?? '';
        return _desktopPage(
          ChatInfoPage(
            conversationId: id,
            isGroup:
                int.tryParse(state.uri.queryParameters['is_group'] ?? '') ?? 0,
          ),
          section: 'message',
          paneId: id,
          conversationId: id,
        );
      },
    ),
    // 群公告整页编辑（S6.22）：`/message/group/notice?id=<会话 id>&auth=<0|1>`
    GoRoute(
      path: AppRoutes.groupNotice,
      builder: (context, state) {
        final id = state.uri.queryParameters['id'] ?? '';
        return _desktopPage(
          GroupNoticePage(
            conversationId: id,
            isAuth: state.uri.queryParameters['auth'] == '1',
          ),
          section: 'message',
          paneId: id,
          conversationId: id,
        );
      },
    ),
    // 会话内聊天记录（S5.4）：`/message/record?id=<会话 id>&is_group=<n>`
    GoRoute(
      path: AppRoutes.chatRecord,
      builder: (context, state) {
        final id = state.uri.queryParameters['id'] ?? '';
        return _desktopPage(
          ChatRecordPage(
            conversationId: id,
            isGroup:
                int.tryParse(state.uri.queryParameters['is_group'] ?? '') ?? 0,
          ),
          section: 'message',
          paneId: id,
          conversationId: id,
        );
      },
    ),
    // 通话页（S6.3）：老端是 `pages/message/call?msg_id=&type=&status=&id=&name=&avatar=`，
    // 新端不用查询参数——对端信息全在通话会话（信令）里，页面只 watch 控制器。
    GoRoute(
      path: AppRoutes.call,
      builder: (context, state) => const CallPage(),
    ),
    // 群资料 / 加入群聊（S7.1）：`/message/group/info?group_id=<群 id>`
    // 来路只有一个——扫到群二维码（老端 `pages/message/group/info.vue`）。
    // `extra` 是**扫码那一步服务端给的群资料**（`ScanVerdict.group`，未入群也能拿到）：
    // 这一页的 `groupInfo` 接口只认群成员，没有它的话未入群的人只会看到
    // 「您没有操作权限！」而加不了群（S7.4 修的 bug）。
    GoRoute(
      path: AppRoutes.groupInfo,
      builder: (context, state) {
        final extra = state.extra;
        return _desktopPage(
          GroupJoinPage(
            groupId: state.uri.queryParameters['group_id'] ?? '',
            scanned: extra is GroupJoinInfo ? extra : null,
          ),
          section: 'message',
        );
      },
    ),
    // 群通话（S9.1）：`/message/group/call?id=<群会话 id>&name=<群名>`。
    // 入口**只在群资料页**（不放消息流：在群消息里点一下就进会，误触代价太大），
    // 退出由页面自己 pop（没有来电那种推送叫醒，不用 CallHost 那套开关）。
    GoRoute(
      path: AppRoutes.groupCall,
      builder: (context, state) => GroupCallPage(
        conversationId: state.uri.queryParameters['id'] ?? '',
        name: state.uri.queryParameters['name'] ?? '',
      ),
    ),
    // 群成员管理（S5.3）：`/message/group/groupUser?group_id=<群 id>`
    //
    // 群会话的 id 就是 `group_id`（群里点一行进的就是 `/message/chat?id=<group.id>`，
    // 见 `group_list_page.dart`），所以这一页也能把聊天留在中栏、自己当右侧栏。
    GoRoute(
      path: AppRoutes.groupUser,
      builder: (context, state) {
        final id = state.uri.queryParameters['group_id'] ?? '';
        return _desktopPage(
          GroupMembersPage(groupId: id),
          section: 'message',
          paneId: id,
          conversationId: id,
        );
      },
    ),
    // 用户选择（S5.6，老端 `pages/index/userSelection`）：
    // `/index/userSelection?type=1&contact_id=<预选的人>`（1 = 创建群聊，
    // 新端只实现这一种，见页面注释）。单聊的「发起群聊」用它预选对方。
    GoRoute(
      path: AppRoutes.userSelection,
      builder: (context, state) => _desktopPage(
        UserSelectionPage(
          type: int.tryParse(state.uri.queryParameters['type'] ?? '') ?? 1,
          presetIds: parsePresetIds(state.uri.queryParameters['contact_id']),
        ),
        section: 'message',
      ),
    ),
    // 表情管理（S5.6b，老端 `pages/message/emoji`）：入口是表情面板收藏 tab 的「＋」
    GoRoute(
      path: AppRoutes.emoji,
      builder: (context, state) =>
          _desktopPage(const EmojiManagePage(), section: 'message'),
    ),
    // 通讯录里的两个二级页（S5.1）：群聊列表、新朋友。
    //
    // `paneId` 是给中栏那一行点底色的（见 [ContactEntries]）——桌面上点开后
    // 通讯录列一直在左边，右栏才是这一页。
    GoRoute(
      path: AppRoutes.groupList,
      builder: (context, state) => _desktopPage(
        const GroupListPage(),
        section: 'contacts',
        paneId: ContactEntries.groups,
      ),
    ),
    // 朋友资料（好友资料 → 朋友资料）：`/contacts/detail/friend?id=<用户 id>`
    GoRoute(
      path: AppRoutes.contactsFriendData,
      builder: (context, state) {
        final id = state.uri.queryParameters['id'] ?? '';
        return _desktopPage(
          FriendDataPage(userId: id),
          section: 'contacts',
          paneId: id,
        );
      },
    ),
    GoRoute(
      path: AppRoutes.newFriends,
      builder: (context, state) => _desktopPage(
        const NewFriendsPage(),
        section: 'contacts',
        paneId: ContactEntries.newFriends,
      ),
    ),
    // 用户详情：`/contacts/detail?id=<user_id>&group_id=<群 id>`（与老端一致）
    //
    // 从通讯录列表或「新的朋友」点进来都走这一条；给了 `paneId`，中栏那一行
    // 会在右栏开着的时候带底色。
    GoRoute(
      path: AppRoutes.contactsDetail,
      builder: (context, state) {
        final id = state.uri.queryParameters['id'] ?? '';
        return _desktopPage(
          UserDetailPage(
            userId: id,
            groupId: state.uri.queryParameters['group_id'] ?? '',
          ),
          section: 'contacts',
          paneId: id,
        );
      },
    ),
    // 「我的」那几个二级页（S5.5）
    GoRoute(
      path: AppRoutes.mineProfile,
      builder: (context, state) =>
          _desktopPage(const ProfilePage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.mineSetting,
      builder: (context, state) =>
          _desktopPage(const SettingPage(), section: 'mine'),
    ),
    // 切换账号（S10.1）：设置里那一行进去
    GoRoute(
      path: AppRoutes.accounts,
      builder: (context, state) =>
          _desktopPage(const AccountsPage(), section: 'mine'),
    ),
    // 添加账号：「登录其他账号」的表单（`?account=` 可预填账号）
    GoRoute(
      path: AppRoutes.accountsAdd,
      builder: (context, state) => LoginPage(
        addAccount: true,
        initialAccount: state.uri.queryParameters['account'] ?? '',
      ),
    ),
    // 添加账号：「注册新账号」
    GoRoute(
      path: AppRoutes.accountsAddRegister,
      builder: (context, state) => const RegisterPage(addAccount: true),
    ),
    GoRoute(
      path: AppRoutes.settingNotification,
      builder: (context, state) =>
          _desktopPage(const NotificationSettingPage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.settingDisplay,
      builder: (context, state) =>
          _desktopPage(const DisplaySettingPage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.settingCall,
      builder: (context, state) =>
          _desktopPage(const CallSettingPage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.mineSecure,
      builder: (context, state) =>
          _desktopPage(const SecurePage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.minePassword,
      builder: (context, state) =>
          _desktopPage(const PasswordChangePage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.mineAccount,
      builder: (context, state) =>
          _desktopPage(const AccountChangePage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.mineCancelAccount,
      builder: (context, state) =>
          _desktopPage(const AccountCancelPage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.mineAbout,
      builder: (context, state) =>
          _desktopPage(const AboutPage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.mineFeature,
      builder: (context, state) =>
          _desktopPage(const FeaturePage(), section: 'mine'),
    ),
    GoRoute(
      path: AppRoutes.mineDoc,
      builder: (context, state) =>
          _desktopPage(const DocPage(), section: 'mine'),
    ),
    // 搜人（S5.4，查服务端）：`/contacts/search`
    GoRoute(
      path: AppRoutes.contactSearch,
      builder: (context, state) =>
          _desktopPage(const UserSearchPage(), section: 'contacts'),
    ),
    // 二维码（S7.1，老端 `pages/index/qrcode.vue`）：
    // `/index/qrcode`（我的二维码）/ `/index/qrcode?group_id=<群 id>`（群二维码）
    GoRoute(
      path: AppRoutes.qrcode,
      builder: (context, state) => _desktopPage(
        QrCodePage(groupId: state.uri.queryParameters['group_id'] ?? ''),
        section: 'mine',
      ),
    ),
    // 扫码登录确认（S7.1 遗留）：`/login/qrlogin?token=<loginToken>`
    // （扫到网页端登录码之后进来，老端 `pages/login/qrlogin.vue`）
    GoRoute(
      path: AppRoutes.qrLogin,
      builder: (context, state) =>
          QrLoginPage(token: state.uri.queryParameters['token'] ?? ''),
    ),
    // 扫一扫（S7.1）：`/index/scan`（老端 `pages/index/scan.vue` +
    // `components/get-qrcode.vue`，相机界面自己做，见 `scan_page.dart`）。
    //
    // ⚠️ **电脑端没有扫一扫**（用户 2026-10-08：「扫一扫在电脑端没用，直接把这功能
    // 删了」）：那台机器上没有相机可取景，只剩「选一张图找二维码」——多此一举。
    // 所以桌面上这条路由直接回主界面，菜单里那一项也不摆（见 `shell_menu.dart`）。
    // 手机上照旧（`desktopFeaturesEnabled` 在 `flutter test` 里是假，用例不受影响）。
    GoRoute(
      path: AppRoutes.scan,
      redirect: (context, state) =>
          desktopFeaturesEnabled ? AppRoutes.home : null,
      builder: (context, state) => const ScanPage(),
    ),
    // 灵听（音乐频道）。六个路径：
    //   `/lingting/index`   首页（服务器「发现」里填 `/pages/lingting/index`）
    //   `/lingting/search`  搜索（历史 + 联想 + 单曲/歌手/歌单三 tab）
    //   `/lingting/sheet?id=<歌单 id>`
    //   `/lingting/singer?id=<歌手 id>`
    //   `/lingting/album?id=<专辑 id>`
    //   `/lingting/player`  播放页（迷你条点进去）
    //   `/lingting/downloads` 下载管理（首页右上角）
    // 资讯（S11.1）：`/news/index`（「发现」里那一栏）、
    // `/news/detail?id=<文章 id>`（按 id 从列表那份数据里取，见 `NewsDetailPage`）
    ...newsRoutes(),
    ...lingtingRoutes(),
    // 外链那三页（内嵌浏览器 + 两道闸门）：主 App 与独立窗口共用一张表
    ...externalLinkRoutes(),
    // 本地搜索（S5.4）：`/index/search?type=1|2|3`
    GoRoute(
      path: AppRoutes.indexSearch,
      builder: (context, state) => _desktopPage(
        SearchPage(
          type: LocalSearchType.fromValue(state.uri.queryParameters['type']),
        ),
      ),
    ),
    for (final route in _pendingRoutes)
      GoRoute(
        path: route.path,
        builder: (context, state) => _desktopPage(
          PlaceholderPage(
            title: route.title,
            legacyPath: route.legacyPath,
            milestone: route.milestone,
          ),
          section: 'compass',
        ),
      ),
  ],
  // 404 页本身也是界面的一部分，走语言包（S12.9 起 7 种语言）
  errorBuilder: (context, state) =>
      RouteNotFoundPage(path: state.uri.toString()),
);

/// 资讯（文章）那一栏的路由。
///
/// 主 App 与桌面上那颗**独立窗口引擎**（`features/desktop_window/`，窗口里那份小
/// App）共用这一张表 —— 一份表两处用，才不会出现「窗口里的文章点进去是 404」。
///
/// 页面外面那层 [_desktopPage] 在窗口里会自动失效：独立窗口把
/// `desktopFeaturesProvider` 关掉了（窗口里按手机版式排），
/// [DesktopPageFrame] 于是原样返回 child。
List<RouteBase> newsRoutes() => <RouteBase>[
  GoRoute(
    path: AppRoutes.newsList,
    builder: (context, state) =>
        _desktopPage(const NewsListPage(), section: 'compass'),
  ),
  GoRoute(
    path: AppRoutes.newsDetail,
    builder: (context, state) => _desktopPage(
      NewsDetailPage(
        id: state.uri.queryParameters['id'] ?? '',
        // 从聊天里的资讯卡片点进来时会带上卡片本体：收卡片的人本机列表里
        // 没有这一篇，详情页用它合成（见 [NewsDetailPage.shared]）
        shared: state.extra is NewsCard ? state.extra! as NewsCard : null,
      ),
      section: 'compass',
    ),
  ),
];

/// 灵听（音乐频道）那一栏的路由（同样：主 App 与独立窗口共用）。
List<RouteBase> lingtingRoutes() => <RouteBase>[
  GoRoute(
    path: AppRoutes.lingtingHome,
    builder: (context, state) =>
        _desktopPage(const LingtingHomePage(), section: 'compass'),
  ),
  GoRoute(
    path: AppRoutes.lingtingSearch,
    builder: (context, state) =>
        _desktopPage(const LingtingSearchPage(), section: 'compass'),
  ),
  GoRoute(
    path: AppRoutes.lingtingSheet,
    builder: (context, state) => _desktopPage(
      LingtingSheetPage(
        sheetId: int.tryParse(state.uri.queryParameters['id'] ?? '') ?? 0,
      ),
      section: 'compass',
    ),
  ),
  GoRoute(
    path: AppRoutes.lingtingSinger,
    builder: (context, state) => _desktopPage(
      LingtingSingerPage(
        singerId: int.tryParse(state.uri.queryParameters['id'] ?? '') ?? 0,
      ),
      section: 'compass',
    ),
  ),
  GoRoute(
    path: AppRoutes.lingtingAlbum,
    builder: (context, state) => _desktopPage(
      LingtingAlbumPage(
        albumId: int.tryParse(state.uri.queryParameters['id'] ?? '') ?? 0,
      ),
      section: 'compass',
    ),
  ),
  GoRoute(
    path: AppRoutes.lingtingPlayer,
    builder: (context, state) =>
        _desktopPage(const LingtingPlayerPage(), section: 'compass'),
  ),
  GoRoute(
    path: AppRoutes.lingtingDownloads,
    builder: (context, state) =>
        _desktopPage(const LingtingDownloadsPage(), section: 'compass'),
  ),
];

/// 外链那三页的路由：内嵌浏览器（`/mine/webview`）+ 两道闸门（禁止访问 / 第三方确认）。
///
/// **主 App 与每扇独立窗口共用这一张表**，与 [newsRoutes] / [lingtingRoutes] 同一条
/// 规矩。2026-10-04 那条「媒体号窗里点『阅读原文』→ Page Not Found」就是漏了它：
/// 子窗口当时只挂了 `newsRoutes()`，而「阅读原文」走的 `openChatLink` 会推到
/// `/mine/linkConfirm`（第三方链接先确认）—— 子引擎里没这条路径，直接 404。
/// 一份表两处用，才不会出现「窗口里点链接是 404」。
List<RouteBase> externalLinkRoutes() => <RouteBase>[
  // 内嵌浏览器（S7.1）：`/mine/webview?title=&src=`（老端 `pages/mine/webview.vue`）
  GoRoute(
    path: AppRoutes.webview,
    builder: (context, state) => _desktopPage(
      WebViewPage(
        title: state.uri.queryParameters['title'] ?? '',
        src: state.uri.queryParameters['src'] ?? '',
      ),
    ),
  ),
  // 外链的两道闸门（2026-09-25）：禁止访问页 / 第三方确认页
  GoRoute(
    path: AppRoutes.linkBlocked,
    builder: (context, state) => _desktopPage(
      LinkBlockedPage(url: state.uri.queryParameters['url'] ?? ''),
    ),
  ),
  GoRoute(
    path: AppRoutes.linkConfirm,
    builder: (context, state) => _desktopPage(
      LinkConfirmPage(url: state.uri.queryParameters['url'] ?? ''),
    ),
  ),
];

/// 用户选择页的预选参数（老端 `contact_id`）。
///
/// 老端传的是**一个** id（单聊信息页那个「发起群聊」）；新端容得下逗号分隔的多个，
/// 解析逻辑单独拿出来，好单测。
List<String> parsePresetIds(String? raw) => (raw ?? '')
    .split(',')
    .map((id) => id.trim())
    .where((id) => id.isNotEmpty)
    .toList(growable: false);

/// 登录态守卫。
///
/// 三条规则，都是新端刻意的行为（写在这里免得以后被当成 bug 改掉）：
/// 1. 本地会话没恢复完 → 停在启动页；
/// 2. 没登录 → 只允许停在登录 / 注册页，其它一律回登录页；
/// 3. 已登录还想去登录页 → 回主界面（登录成功后的跳转就靠这条，不用手动 `go`）。
///
/// 参数是纯字符串（而不是 `GoRouterState`），这样单测可以直接喂路径进来。
String? guardRedirect(String path) {
  if (!sessionGuard.ready) {
    return path == AppRoutes.splash ? null : AppRoutes.splash;
  }
  // 启动页只在未就绪时有意义，就绪后让它自己走开
  if (path == AppRoutes.splash) {
    return sessionGuard.hasSession ? AppRoutes.home : AppRoutes.login;
  }
  if (!sessionGuard.hasSession) {
    return AppRoutes.isAuthRoute(path) ? null : AppRoutes.login;
  }
  if (AppRoutes.isAuthRoute(path)) return AppRoutes.home;
  return null;
}
