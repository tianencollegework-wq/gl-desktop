import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/repo/search_repository.dart';
import '../../domain/search/user_search.dart';
import 'widgets/contact_avatar.dart';
import 'widgets/contacts_empty.dart';

/// 搜人，对应老端 `pages/contacts/search.vue`（S5.4）。
///
/// 与通讯录那个本地搜索不同：这一页**查服务端**（`searchUser({keywords})`），
/// 所以能搜到还不是好友的人。每行右侧按 `friend` 给「发消息」或「查看」，
/// 点行进用户详情页（老端两处都跳 `/pages/contacts/detail?id=<user_id>`）。
///
/// 与老端不同（刻意的）：
/// * 空关键词点「搜索」时老端弹一句提示就完事，新端一样弹提示，但**输入框里
///   敲回车也能搜**；
/// * 搜索中有一个转圈（老端没有，慢网络下像卡住）；
/// * 失败给空态（`ApiClient` 已经弹了提示）。
class UserSearchPage extends ConsumerStatefulWidget {
  const UserSearchPage({super.key});

  @override
  ConsumerState<UserSearchPage> createState() => _UserSearchPageState();
}

class _UserSearchPageState extends ConsumerState<UserSearchPage> {
  final TextEditingController _controller = TextEditingController();
  List<UserSearchResult> _results = const <UserSearchResult>[];

  /// 搜过一次之后空态文案才换成「未搜索到用户数据」（老端 `friend.searchNoData`）
  bool _searched = false;
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final i18n = ref.read(appI18nProvider);
    final keyword = _controller.text;
    if (isBlankKeyword(keyword)) {
      noticeBus.toast(i18n.t('user.seachUser'));
      return;
    }
    setState(() => _loading = true);
    final results = await ref
        .read(searchRepositoryProvider)
        .searchUsers(keyword);
    if (!mounted) return;
    setState(() {
      // 老端是 `if (res.code == 0) this.contacts = res.data`：失败时保留上一次结果。
      // 新端失败给空列表（仓库已经吞掉异常），空态比「旧结果 + 无提示」清楚。
      _results = results;
      _searched = true;
      _loading = false;
    });
  }

  Future<void> _openDetail(UserSearchResult result) => context.push(
    '${AppRoutes.contactsDetail}?id=${Uri.encodeComponent(result.userId)}',
  );

  /// 老端 `sendMsg(id)`：本地没有这条会话时先 `getUserInfo` 拿 `contactInfo` 补上
  Future<void> _sendMessage(UserSearchResult result) async {
    final i18n = ref.read(appI18nProvider);
    final ready = await ref
        .read(searchRepositoryProvider)
        .ensureChatWith(result.userId);
    if (!mounted) return;
    if (!ready) {
      noticeBus.toast(i18n.t('group.noContact'));
      return;
    }
    context.push('${AppRoutes.chat}?id=${Uri.encodeComponent(result.userId)}');
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('friend.seachFriend'))),
      body: Column(
        children: <Widget>[
          _searchBar(context, i18n),
          Expanded(child: _body(context, i18n)),
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
            textInputAction: TextInputAction.search,
            style: TextStyle(fontSize: context.rpx(28)),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: i18n.t('user.seachUser'),
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
            onPressed: _loading ? null : _search,
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
    if (_results.isEmpty) {
      return Center(
        child: ContactsEmpty(
          text: _searched
              ? i18n.t('friend.searchNoData')
              : i18n.t('common.none'),
        ),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) => _row(context, i18n, _results[index]),
    );
  }

  Widget _row(BuildContext context, AppI18n i18n, UserSearchResult result) =>
      InkWell(
        onTap: () => _openDetail(result),
        child: Container(
          color: AppColors.white,
          padding: EdgeInsets.symmetric(
            horizontal: context.rpx(30),
            vertical: context.rpx(20),
          ),
          child: Row(
            children: <Widget>[
              ContactAvatar(url: result.avatar, circle: true, sizeRpx: 80),
              SizedBox(width: context.rpx(20)),
              Expanded(
                child: Text(
                  result.realName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.rpx(30),
                    color: AppColors.text333,
                  ),
                ),
              ),
              // 老端：是好友给「发消息」（点了直接进聊天），否则给「查看」（进详情页）
              GestureDetector(
                onTap: result.isFriend
                    ? () => _sendMessage(result)
                    : () => _openDetail(result),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rpx(16),
                    vertical: context.rpx(8),
                  ),
                  child: Text(
                    i18n.t(result.actionKey),
                    style: TextStyle(
                      fontSize: context.rpx(26),
                      color: AppColors.brand,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
