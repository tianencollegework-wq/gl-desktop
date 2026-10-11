import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/ui/notice_bus.dart';
import '../../../data/repo/contact_repository.dart';
import '../../../domain/chat/forward_targets.dart';
import '../../../core/ui/desktop_overlay.dart';

/// 转发目标选择器（老端 `pages/index/userSelection.vue`，`type == 3`）。
///
/// 返回选中的目标；直接关掉返回 null。**限 5 个**（老端 `message.forwardLimit`）。
Future<List<ForwardTarget>?> showForwardPicker(
  BuildContext context, {
  required String excludeId,
}) => showAppSheet<List<ForwardTarget>>(
  context: context,
  backgroundColor: AppColors.white,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (context) => _ForwardPickerSheet(excludeId: excludeId),
);

class _ForwardPickerSheet extends ConsumerStatefulWidget {
  const _ForwardPickerSheet({required this.excludeId});

  final String excludeId;

  @override
  ConsumerState<_ForwardPickerSheet> createState() =>
      _ForwardPickerSheetState();
}

class _ForwardPickerSheetState extends ConsumerState<_ForwardPickerSheet> {
  final TextEditingController _search = TextEditingController();
  final Map<String, ForwardTarget> _picked = <String, ForwardTarget>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(ForwardTarget target) {
    final i18n = ref.read(appI18nProvider);
    if (_picked.containsKey(target.id)) {
      setState(() => _picked.remove(target.id));
      return;
    }
    if (_picked.length >= forwardLimit) {
      noticeBus.toast(i18n.t('message.forwardLimit'));
      return;
    }
    setState(() => _picked[target.id] = target);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final targets = ref.watch(forwardTargetsProvider(widget.excludeId));

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
            child: targets.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Text(
                  i18n.t('common.noData'),
                  style: TextStyle(
                    fontSize: context.rpx(26),
                    color: AppColors.text666,
                  ),
                ),
              ),
              data: (list) => _list(context, i18n, list),
            ),
          ),
          _footer(context, i18n),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, AppI18n i18n) => Container(
    height: context.rpx(90),
    padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
    alignment: Alignment.center,
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
            i18n.t('message.forward'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.rpx(30),
              color: AppColors.text333,
            ),
          ),
        ),
        GestureDetector(
          onTap: _picked.isEmpty
              ? () => noticeBus.toast(i18n.t('message.chooseUser'))
              : () => Navigator.of(context).pop(_picked.values.toList()),
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
    List<ForwardTarget> targets,
  ) {
    final filtered = searchForwardTargets(targets, _search.text.trim());
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          i18n.t('common.noData'),
          style: TextStyle(fontSize: context.rpx(26), color: AppColors.text666),
        ),
      );
    }
    return ListView(
      children: <Widget>[
        for (final target in filtered) _tile(context, i18n, target),
      ],
    );
  }

  Widget _tile(BuildContext context, AppI18n i18n, ForwardTarget target) {
    final checked = _picked.containsKey(target.id);
    return InkWell(
      onTap: () => _toggle(target),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(18),
        ),
        child: Row(
          children: <Widget>[
            CircleAvatar(
              radius: context.rpx(30),
              backgroundColor: AppColors.page,
              foregroundImage: target.avatar.isEmpty
                  ? null
                  : NetworkImage(target.avatar),
              child: Icon(
                target.isGroupChat
                    ? Icons.groups_outlined
                    : Icons.person_outline,
                size: context.rpx(32),
                color: AppColors.text666,
              ),
            ),
            SizedBox(width: context.rpx(20)),
            Expanded(
              child: Text(
                // 群聊名字后面带「（群聊）」（老端 `name += "（群聊）"`）
                forwardTargetLabel(target, '（${i18n.t('user.group')}）'),
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

  Widget _footer(BuildContext context, AppI18n i18n) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(16),
        ),
        child: Row(
          children: <Widget>[
            Text(
              '${i18n.t('common.checked')} ${_picked.length} / $forwardLimit',
              style: TextStyle(
                fontSize: context.rpx(26),
                color: AppColors.text666,
              ),
            ),
          ],
        ),
      ),
      SizedBox(height: context.bottomSafeHeight),
    ],
  );
}
