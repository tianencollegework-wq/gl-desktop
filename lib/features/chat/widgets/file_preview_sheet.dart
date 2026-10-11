import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../data/model/message.dart';
import '../../../domain/chat/file_preview.dart';
import '../../../domain/chat/message_media.dart';
import '../../../core/ui/desktop_overlay.dart';

/// 文件气泡点开后的选择（老端 `chat.vue` 里那个 `ref="preview"` 的底部弹层）。
///
/// 老端两项：
/// * 「本地预览 / 需下载」→ 下载后用系统应用打开（只认 pdf/office 那几种后缀）
/// * 「在线预览 / 支持常用的文件和文档」→ 打开 `item.preview`
///
/// **第二项在老端是坏的**：`item.preview` 全项目只被读、没人赋值，所以它打开的
/// 是 `undefined`（webview 一片空白）。新端用消息里的真实地址，功能先能用。
enum FilePreviewChoice { local, online }

Future<FilePreviewChoice?> showFilePreviewSheet(
  BuildContext context,
  Message message,
) {
  final payload = filePayloadOf(message);
  return showAppSheet<FilePreviewChoice>(
    context: context,
    backgroundColor: AppColors.white,
    // 默认弹层只能用屏幕的 9/16，这个高度在小屏/横屏下装不下三行内容
    // （组件测试里当场就溢出报错了），所以改成按内容高度来、太长则滚动
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (context) => _FilePreviewSheet(payload: payload),
  );
}

class _FilePreviewSheet extends ConsumerWidget {
  const _FilePreviewSheet({required this.payload});

  final FilePayload payload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    // 音频：老端是直接丢给 webview（`val==1` 也走那条），没有「本地预览」这一步
    final options = isAudioFile(payload.extension)
        ? const <FilePreviewChoice>[FilePreviewChoice.online]
        : const <FilePreviewChoice>[
            FilePreviewChoice.local,
            FilePreviewChoice.online,
          ];

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.rpx(30),
                vertical: context.rpx(24),
              ),
              child: Text(
                payload.name.isEmpty
                    ? i18n.t('message.filePreview')
                    : payload.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text333,
                ),
              ),
            ),
            if (options.contains(FilePreviewChoice.local))
              _item(context, i18n, localPreviewOption, FilePreviewChoice.local),
            if (options.contains(FilePreviewChoice.online))
              _item(
                context,
                i18n,
                onlinePreviewOption,
                FilePreviewChoice.online,
              ),
            Divider(height: 1, color: AppColors.line),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                height: context.rpx(100),
                alignment: Alignment.center,
                child: Text(
                  i18n.t('common.close'),
                  style: TextStyle(
                    fontSize: context.rpx(30),
                    color: AppColors.text666,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(
    BuildContext context,
    AppI18n i18n,
    FilePreviewOption option,
    FilePreviewChoice choice,
  ) => GestureDetector(
    onTap: () => Navigator.of(context).pop(choice),
    child: Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(30),
        vertical: context.rpx(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            i18n.t(option.key),
            style: TextStyle(
              fontSize: context.rpx(30),
              color: AppColors.text333,
            ),
          ),
          SizedBox(height: context.rpx(6)),
          Text(
            i18n.t(option.hintKey),
            style: TextStyle(
              fontSize: context.rpx(24),
              color: AppColors.text999,
            ),
          ),
        ],
      ),
    ),
  );
}
