import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/store/session_store.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/ui/notice_bus.dart';
import '../../../data/model/contact.dart';
import '../../../data/repo/contact_repository.dart';
import '../../../domain/contacts/contact_index.dart';
import '../../contacts/widgets/contact_avatar.dart';
import '../../../core/ui/desktop_overlay.dart';

/// 发名片时选人（老端 `im-input.vue` 那个 `contactmodel` 弹层 +
/// `user-select :type="1" :multiple="false"`：好友列表，单选）。
///
/// 老端点「完成」时如果选的**不是**恰好一位，就提示 `chat.chooseOne`
/// （「必须选择一位联系人」）——新端一样，只是选中即回填、不用再点一次选中框。
/// 关掉弹层返回 `null`。
Future<Contact?> showContactCardPicker(BuildContext context) =>
    showAppSheet<Contact>(
      context: context,
      backgroundColor: AppColors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => const _ContactCardPickerSheet(),
    );

class _ContactCardPickerSheet extends ConsumerStatefulWidget {
  const _ContactCardPickerSheet();

  @override
  ConsumerState<_ContactCardPickerSheet> createState() =>
      _ContactCardPickerSheetState();
}

class _ContactCardPickerSheetState
    extends ConsumerState<_ContactCardPickerSheet> {
  final TextEditingController _search = TextEditingController();
  Contact? _picked;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final circleAvatar = ref.watch(
      sessionStoreProvider.select((state) => state.setting.circleAvatar),
    );
    final friends = ref.watch(friendListProvider);

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        children: <Widget>[
          _header(context, i18n),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
            child: Container(
              height: context.rpx(64),
              padding: EdgeInsets.symmetric(horizontal: context.rpx(20)),
              decoration: BoxDecoration(
                color: AppColors.page,
                borderRadius: BorderRadius.circular(context.rpx(32)),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.search,
                    size: context.rpx(32),
                    color: AppColors.text999,
                  ),
                  SizedBox(width: context.rpx(10)),
                  Expanded(
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        color: AppColors.text333,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: i18n.t('common.keywords'),
                        hintStyle: TextStyle(
                          fontSize: context.rpx(26),
                          color: AppColors.text999,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.rpx(10)),
          Expanded(
            child: friends.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _empty(context, i18n),
              data: (list) => _list(context, i18n, list, circleAvatar),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, AppI18n i18n) => Container(
    height: context.rpx(90),
    padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
    child: Row(
      children: <Widget>[
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Text(
            i18n.t('common.cancel'),
            style: TextStyle(
              fontSize: context.rpx(28),
              color: AppColors.text666,
            ),
          ),
        ),
        Expanded(
          child: Text(
            i18n.t('message.shareTo'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.rpx(30),
              color: AppColors.text333,
            ),
          ),
        ),
        GestureDetector(
          onTap: () {
            final picked = _picked;
            if (picked == null) {
              // 老端是「选的不是一位就提示」，这里容量恒为 1，所以只剩「没选」
              noticeBus.toast(i18n.t('chat.chooseOne'));
              return;
            }
            Navigator.of(context).pop(picked);
          },
          child: Text(
            i18n.t('common.complete'),
            style: TextStyle(fontSize: context.rpx(28), color: AppColors.brand),
          ),
        ),
      ],
    ),
  );

  Widget _list(
    BuildContext context,
    AppI18n i18n,
    List<Contact> friends,
    bool circleAvatar,
  ) {
    final filtered = searchContacts(friends, _search.text);
    if (filtered.isEmpty) return _empty(context, i18n);

    return ListView(
      children: <Widget>[
        for (final friend in filtered) _tile(context, friend, circleAvatar),
      ],
    );
  }

  Widget _tile(BuildContext context, Contact friend, bool circleAvatar) {
    final checked = _picked?.id == friend.id;
    return InkWell(
      onTap: () => setState(() => _picked = friend),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(16),
        ),
        child: Row(
          children: <Widget>[
            ContactAvatar(
              url: friend.avatar,
              circle: circleAvatar,
              sizeRpx: 80,
            ),
            SizedBox(width: context.rpx(20)),
            Expanded(
              child: Text(
                friend.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text333,
                ),
              ),
            ),
            Icon(
              checked ? Icons.check_circle : Icons.circle_outlined,
              size: context.rpx(40),
              color: checked ? AppColors.brand : AppColors.text999,
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context, AppI18n i18n) => Center(
    child: Text(
      i18n.t('common.noData'),
      style: TextStyle(fontSize: context.rpx(26), color: AppColors.text666),
    ),
  );
}
