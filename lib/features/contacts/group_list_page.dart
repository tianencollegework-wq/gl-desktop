import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/model/contact.dart';
import '../../data/repo/contact_repository.dart';
import '../../data/repo/conversation_repository.dart';
import '../../domain/contacts/group_list.dart';
import 'widgets/contact_avatar.dart';

/// 群聊列表，对应老端 `pages/contacts/group.vue`。
///
/// 结构照老端：四个分段（全部 / 我创建的 / 我管理的 / 我加入的）+ 搜索入口；
/// 点一行**直接进群聊**（老端也是 `navigateTo(chat)`，不是群信息页）。
///
/// 与老端不同（刻意的）：
/// * 数据来自本地库的流，进页面就有内容，接口只对齐一次（老端每次 `getGroupList(true)`）；
/// * 搜索走通讯录同一套口径（名字 / 拼音 / 账号）；
/// * 群主那行的小图标保留（老端 `cuIcon-peoplefill`），但**只有群主自己能看到**这条
///   逻辑也照抄（`owner_id == user_id`）。
class GroupListPage extends ConsumerStatefulWidget {
  const GroupListPage({super.key});

  @override
  ConsumerState<GroupListPage> createState() => _GroupListPageState();
}

class _GroupListPageState extends ConsumerState<GroupListPage> {
  GroupTab _tab = GroupTab.all;
  bool _searching = false;
  String _keyword = '';
  final TextEditingController _search = TextEditingController();

  /// 本次进页面是否已经对齐过（老端 `mounted` 里每次都拉）
  bool _synced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    if (_synced) return;
    _synced = true;
    try {
      await ref.read(contactRepositoryProvider).syncFromServer();
    } on Object catch (error) {
      // 失败不清列表：本地缓存照常展示（与通讯录主页一致）
      debugPrint('[群聊] 同步失败：$error');
    }
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        // 老端关掉搜索框时清空关键词，而且 `watch.keywords('')` 会把分段
        // 归回「全部」（它那个 watcher 里就写了 `this.type='all'`）
        _search.clear();
        _keyword = '';
        _tab = GroupTab.all;
      }
    });
  }

  void _applySearch(String keyword) {
    setState(() {
      _keyword = keyword;
      if (keyword.trim().isEmpty) _tab = GroupTab.all;
    });
  }

  Future<void> _openChat(Contact group) async {
    // 还没聊过的群：先补一条本地会话，否则聊天页会说「联系人不存在」
    await ref.read(conversationRepositoryProvider).ensureFromContact(group);
    if (!mounted) return;
    context.push('${AppRoutes.chat}?id=${Uri.encodeComponent(group.id)}');
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final myId = ref.watch(
      sessionStoreProvider.select((state) => state.userId),
    );
    final setting = ref.watch(
      sessionStoreProvider.select((state) => state.setting),
    );
    final groups = ref.watch(groupListProvider).value ?? const <Contact>[];
    final visible = visibleGroups(
      groups,
      tab: _tab,
      myUserId: myId,
      keyword: _keyword,
    );

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        title: Text(i18n.t('group.groupList')),
        actions: <Widget>[
          IconButton(
            tooltip: i18n.t('common.search'),
            onPressed: _toggleSearch,
            icon: Icon(_searching ? Icons.close : Icons.search),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _header(context, i18n),
          const Divider(height: 1, color: AppColors.line),
          Expanded(
            child: RefreshIndicator(
              color: AppColors.brand,
              onRefresh: () async {
                _synced = false;
                await _sync();
              },
              child: visible.isEmpty
                  ? _empty(context, i18n)
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: visible.length,
                      itemBuilder: (context, index) => _groupRow(
                        context,
                        group: visible[index],
                        circle: setting.circleAvatar,
                        i18n: i18n,
                        myId: myId,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏：默认是四个分段，点放大镜之后整条换成搜索框（老端就在这一条里二选一）
  Widget _header(BuildContext context, AppI18n i18n) => Container(
    color: AppColors.white,
    height: context.rpx(80),
    child: _searching
        ? Row(
            children: <Widget>[
              SizedBox(width: context.rpx(20)),
              Icon(
                Icons.search,
                size: context.rpx(32),
                color: AppColors.text999,
              ),
              SizedBox(width: context.rpx(10)),
              Expanded(
                child: TextField(
                  controller: _search,
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
                  // 老端 `watch.keywords`：清空就恢复全部
                  onChanged: (value) {
                    if (value.isEmpty) _applySearch('');
                  },
                  onSubmitted: _applySearch,
                ),
              ),
              TextButton(
                onPressed: () => _applySearch(_search.text),
                child: Text(
                  i18n.t('common.search'),
                  style: TextStyle(fontSize: context.rpx(28)),
                ),
              ),
            ],
          )
        : Row(
            children: <Widget>[
              for (final tab in GroupTab.values)
                GestureDetector(
                  onTap: () => setState(() => _tab = tab),
                  child: Container(
                    alignment: Alignment.center,
                    padding: EdgeInsets.symmetric(horizontal: context.rpx(24)),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: context.rpx(4),
                          color: _tab == tab
                              ? AppColors.brand
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    child: Text(
                      i18n.t(tab.labelKey),
                      style: TextStyle(
                        fontSize: context.rpx(28),
                        color: _tab == tab
                            ? AppColors.brand
                            : AppColors.text666,
                      ),
                    ),
                  ),
                ),
            ],
          ),
  );

  Widget _groupRow(
    BuildContext context, {
    required Contact group,
    required bool circle,
    required AppI18n i18n,
    required String myId,
  }) => InkWell(
    onTap: () => _openChat(group),
    child: Container(
      height: context.rpx(110),
      padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
      color: AppColors.white,
      child: Row(
        children: <Widget>[
          ContactAvatar(
            url: group.avatar,
            circle: circle,
            fallbackIcon: Icons.group,
          ),
          SizedBox(width: context.rpx(20)),
          Expanded(
            child: Text(
              group.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(30),
                color: AppColors.text333,
              ),
            ),
          ),
          // 我是群主（老端那个 `cuIcon-peoplefill`）
          if (group.isOwner(myId))
            Tooltip(
              message: i18n.t('group.owner'),
              child: Icon(
                Icons.people_alt,
                size: context.rpx(34),
                color: AppColors.text999,
              ),
            ),
        ],
      ),
    ),
  );

  Widget _empty(BuildContext context, AppI18n i18n) => ListView(
    // 空态也要能下拉刷新，所以套一层可滚动
    physics: const AlwaysScrollableScrollPhysics(),
    children: <Widget>[
      SizedBox(height: context.rpx(80)),
      Center(
        child: Image.asset('assets/images/empty.png', width: context.rpx(240)),
      ),
      SizedBox(height: context.rpx(20)),
      Center(
        child: Text(
          i18n.t('common.none'),
          style: TextStyle(fontSize: context.rpx(26), color: AppColors.text999),
        ),
      ),
    ],
  );
}
