import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/desktop_overlay.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/success_check.dart';
import '../../data/repo/report_repository.dart';
import '../../domain/report/report_failure.dart';
import '../../domain/report/report_reasons.dart';

/// 举报弹层（S13.1，2026-10-11）。
///
/// 四个入口共用这一个弹层（单聊信息页的「投诉」、群信息页的「投诉」、
/// 长按消息的「举报」、关于页的「投诉」）：选原因 → 可写一句补充说明 → 提交。
///
/// 返回值：**提交成功是 true**（关掉 / 没提交是 false 或 null）——
/// 调用方需要的话可以据此刷新界面（目前三个入口都不需要）。
///
/// 与老端那个「只做表面功夫」的投诉相比，这一版是**真的提交**
/// （`/enterprise/report/submit` → `yu_report` → 后台那个举报页）：
/// 用户点一下要真的有人能看到，不然「投诉」只是个安慰剂。
///
/// 文案与结果：
///  * 成功：走 [showSuccessCheck]（那个「提交成功 + 一个勾」的过场），
///    再关掉弹层 —— 与用户要的观感一致；
///  * 被拒（业务码 4101…4106）：按**码**出各自语言的文案，弹层不关，
///    用户改一下还能再提交；
///  * 网络失败 / 登录态过期：讲明是哪一种（后者直接把用户送去重登）。
Future<bool> showReportSheet(
  BuildContext context, {
  required ReportTarget target,
  String titleKey = 'report.title',
}) async {
  final submitted = await showAppSheet<bool>(
    context: context,
    // 有输入框：得让键盘把内容顶上去（桌面那份会变成居中小窗，不受影响）
    isScrollControlled: true,
    backgroundColor: AppColors.white,
    builder: (sheetContext) =>
        _ReportSheet(target: target, titleKey: titleKey),
  );
  return submitted == true;
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.target, required this.titleKey});

  final ReportTarget target;

  /// 标题的文案 key。关于页那条入口传的是「投诉」（`chat.complaint`）——
  /// 那一页本来就叫投诉，写成「举报」对用户是另一件事。
  final String titleKey;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  final TextEditingController _detail = TextEditingController();
  ReportReason? _reason;
  bool _sending = false;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  /// 补充说明的字数上限与服务端一致（`ReportInput::DETAIL_MAX`）
  static const int _detailMax = 500;

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _sending) return;
    final i18n = ref.read(appI18nProvider);
    setState(() => _sending = true);

    final outcome = await ref
        .read(reportRepositoryProvider)
        .submit(widget.target, reason: reason, detail: _detail.text);
    if (!mounted) return;
    setState(() => _sending = false);

    switch (outcome) {
      case ReportAccepted():
        // 微信那种「提交成功 + 一个勾」的过场：它自己会关掉（约 1.4 秒），
        // 然后我们再关弹层 —— 用户看到的是「点了提交 → 勾 → 回到原页面」
        await showSuccessCheck(context, message: i18n.t('report.done'));
        if (mounted) Navigator.of(context).pop(true);
      case ReportRejected(:final labelKey, :final message):
        // 认得出的码用自己的话（七种语言），认不出的原样转述服务端那句话
        noticeBus.toast(labelKey == null ? message : i18n.t(labelKey));
      case ReportUnavailable(:final message, :final needsRelogin):
        if (needsRelogin) {
          noticeBus.requireRelogin(message);
          if (mounted) Navigator.of(context).pop(false);
        } else {
          noticeBus.toast(message);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final target = widget.target;
    // 名字缺了就拿群号顶上 —— 报一条群消息时对方名字可能没缓存，
    // 显示成「恩信平台」会让人以为自己在投诉平台
    final name = target.userName.isNotEmpty
        ? target.userName
        : (target.groupId.isNotEmpty
              ? target.groupId
              : i18n.t('report.targetUnknown'));
    // 「举报对象」这一行在群投诉里说的是**群**，写成「举报对象：产品群」
    // 会让人以为是某个叫「产品群」的人
    final targetKey = target.scene == ReportScene.group
        ? 'report.targetGroup'
        : 'report.target';

    return SafeArea(
      top: false,
      child: Padding(
        // 键盘顶上来（手机上）时把内容一起顶上去
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        // 内容比屏幕高时必须**能滚**：五个原因 + 说明 + 两栏按钮在小屏手机、
        // 或「宽而矮」的桌面窗口上排不下 —— 不滚的话「提交」会被顶出屏幕，
        // 用户看得见弹层却点不着那颗钮（测试里就是这么发现的：溢出 510px）。
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _title(context, i18n, name),
              // 举报对象那一行：关于页那种平台级反馈没有对象，就不画
              if (target.hasTarget) _targetRow(context, i18n, targetKey, name),
              if (target.preview.isNotEmpty) _preview(context, target.preview),
              _reasonList(context, i18n),
              _detailField(context, i18n),
              _hint(context, i18n),
              _buttons(context, i18n),
              SizedBox(height: context.rpx(20)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title(BuildContext context, AppI18n i18n, String name) => Padding(
    padding: EdgeInsets.fromLTRB(
      context.rpx(30),
      context.rpx(34),
      context.rpx(30),
      context.rpx(10),
    ),
    child: Row(
      children: <Widget>[
        Text(
          i18n.t(widget.titleKey),
          style: TextStyle(
            fontSize: context.rpx(34),
            fontWeight: FontWeight.w600,
            color: AppColors.text000,
          ),
        ),
      ],
    ),
  );

  /// 「举报对象：xxx」（群投诉是「举报的群：xxx」）
  Widget _targetRow(
    BuildContext context,
    AppI18n i18n,
    String labelKey,
    String name,
  ) => Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
        child: Row(
          children: <Widget>[
            Text(
              '${i18n.t(labelKey)}：',
              style: TextStyle(
                fontSize: context.rpx(26),
                color: AppColors.text666,
              ),
            ),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(26),
                  color: AppColors.text000,
                ),
              ),
            ),
          ],
        ),
      );

  /// 消息预览：让用户在提交之前看一眼「举报的是哪一条」
  Widget _preview(BuildContext context, String preview) => Container(
    margin: EdgeInsets.fromLTRB(
      context.rpx(30),
      context.rpx(16),
      context.rpx(30),
      0,
    ),
    padding: EdgeInsets.all(context.rpx(18)),
    decoration: BoxDecoration(
      color: AppColors.page,
      borderRadius: BorderRadius.circular(context.rpx(10)),
    ),
    width: double.infinity,
    child: Text(
      preview,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: context.rpx(26), color: AppColors.text666),
    ),
  );

  Widget _reasonList(BuildContext context, AppI18n i18n) => Padding(
    padding: EdgeInsets.only(top: context.rpx(14)),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final reason in ReportReason.values)
          InkWell(
            onTap: () => setState(() => _reason = reason),
            child: Container(
              height: context.rpx(96),
              padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      i18n.t(reason.labelKey),
                      style: TextStyle(
                        fontSize: context.rpx(30),
                        color: AppColors.text000,
                      ),
                    ),
                  ),
                  if (_reason == reason)
                    Icon(
                      Icons.check,
                      size: context.rpx(38),
                      color: AppColors.wechatGreen,
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  Widget _detailField(BuildContext context, AppI18n i18n) => Container(
    margin: EdgeInsets.fromLTRB(
      context.rpx(30),
      context.rpx(6),
      context.rpx(30),
      0,
    ),
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(20),
      vertical: context.rpx(10),
    ),
    decoration: BoxDecoration(
      color: AppColors.page,
      borderRadius: BorderRadius.circular(context.rpx(10)),
    ),
    child: TextField(
      controller: _detail,
      maxLines: 3,
      maxLength: _detailMax,
      style: TextStyle(fontSize: context.rpx(28)),
      decoration: InputDecoration(
        border: InputBorder.none,
        isDense: true,
        // 计数器去掉：这一格里再冒一行「0/500」就太挤了
        counterText: '',
        hintText: i18n.t('report.detailHint'),
        hintStyle: TextStyle(
          fontSize: context.rpx(28),
          color: AppColors.text999,
        ),
      ),
    ),
  );

  Widget _hint(BuildContext context, AppI18n i18n) => Padding(
    padding: EdgeInsets.fromLTRB(
      context.rpx(30),
      context.rpx(16),
      context.rpx(30),
      0,
    ),
    child: Text(
      i18n.t('report.hint'),
      style: TextStyle(
        fontSize: context.rpx(22),
        height: 1.5,
        color: AppColors.text999,
      ),
    ),
  );

  Widget _buttons(BuildContext context, AppI18n i18n) => Padding(
    padding: EdgeInsets.only(top: context.rpx(20)),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(false),
          child: Text(i18n.t('common.cancel')),
        ),
        SizedBox(width: context.rpx(40)),
        TextButton(
          // 没选原因就不给提交（省得服务端拿 4101 打回来）
          onPressed: (_reason == null || _sending) ? null : _submit,
          child: _sending
              ? SizedBox(
                  width: context.rpx(30),
                  height: context.rpx(30),
                  child: const CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  i18n.t('report.submit'),
                  style: const TextStyle(color: AppColors.red),
                ),
        ),
      ],
    ),
  );
}
