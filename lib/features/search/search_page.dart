import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/model/contact.dart';
import '../../data/repo/contact_repository.dart';
import '../../data/repo/conversation_repository.dart';
import '../../domain/search/local_search.dart';
import '../contacts/widgets/contact_avatar.dart';
import '../contacts/widgets/contacts_empty.dart';

/// 本地搜索，对应老端 `pages/index/search.vue`（S5.4）。
///
/// 三个入口共用这一页：消息页（`type=1`）、通讯录（`type=2`）、群聊列表
/// （`type=3`，只搜群）。数据源是**本地通讯录**（老端每次都现拉两份整份列表，
/// 新端订阅本地库的流，进页面就有结果、离线也能搜）。
///
/// 与老端不同（刻意的）：
/// * 老端的 `type==2` 想「点好友进详情页」，但它把 `is_group` 写成了 `is_gourp`
///   （恒为 undefined），所以那个分支从来没生效过——新端按它的**意图**做了：
///   `type==2` 点好友进用户详情页（与通讯录列表点一行一致），其余情况补会话进聊天。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, required this.type});

  final LocalSearchType type;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  String _keyword = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    setState(() => _keyword = '');
  }

  /// 补一条本地会话再进聊天（老端 `openDetails`：`appendContacts` 之后才跳）
  Future<void> _openChat(Contact contact) async {
    await ref.read(conversationRepositoryProvider).ensureFromContact(contact);
    if (!mounted) return;
    context.push('${AppRoutes.chat}?id=${Uri.encodeComponent(contact.id)}');
  }

  void _openContact(Contact contact) {
    // 通讯录进来的（type=2）点好友看资料，与通讯录列表点一行一致
    if (widget.type == LocalSearchType.contacts && contact.isFriend) {
      context.push(
        '${AppRoutes.contactsDetail}?id=${Uri.encodeComponent(contact.id)}',
      );
      return;
    }
    _openChat(contact);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    // 好友 + 群聊两份流都在本地库里，合并起来当数据源（老端是现拉两份整份列表）
    final contacts = <Contact>[
      ...ref.watch(friendListProvider).value ?? const <Contact>[],
      ...ref.watch(groupListProvider).value ?? const <Contact>[],
    ];
    final results = localSearch(contacts, _keyword, type: widget.type);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t(widget.type.titleKey))),
      body: Column(
        children: <Widget>[
          _searchBar(context, i18n),
          Expanded(
            child: results.isEmpty
                // 老端这时显示的也是「暂无数据」（没输入关键词时同样）
                ? Center(child: ContactsEmpty(text: i18n.t('common.none')))
                : ListView(
                    children: <Widget>[
                      if (results.friends.isNotEmpty) ...<Widget>[
                        _sectionHeader(context, i18n.t('user.friend')),
                        for (final friend in results.friends)
                          _row(context, friend),
                      ],
                      if (results.groups.isNotEmpty) ...<Widget>[
                        _sectionHeader(context, i18n.t('user.group')),
                        for (final group in results.groups)
                          _row(context, group),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

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
            // 老端是 `watch: keywords` —— 输入即搜，没有搜索按钮
            onChanged: (value) => setState(() => _keyword = value),
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
          ),
        ),
        if (_keyword.isNotEmpty)
          GestureDetector(
            onTap: _clear,
            child: Icon(
              Icons.close,
              size: context.rpx(34),
              color: AppColors.text999,
            ),
          ),
      ],
    ),
  );

  Widget _sectionHeader(BuildContext context, String title) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(30),
      vertical: context.rpx(16),
    ),
    child: Text(
      title,
      style: TextStyle(fontSize: context.rpx(24), color: AppColors.text999),
    ),
  );

  Widget _row(BuildContext context, Contact contact) => InkWell(
    onTap: () => _openContact(contact),
    child: Container(
      color: AppColors.white,
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(30),
        vertical: context.rpx(20),
      ),
      child: Row(
        children: <Widget>[
          ContactAvatar(url: contact.avatar, circle: true, sizeRpx: 80),
          SizedBox(width: context.rpx(20)),
          Expanded(
            child: Text(
              contact.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(30),
                color: AppColors.text333,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
