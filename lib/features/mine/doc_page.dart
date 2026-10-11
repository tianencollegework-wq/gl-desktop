import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../domain/mine/profile_form.dart';

/// 帮助中心，对应老端 `pages/mine/doc.vue`（S5.5）。
///
/// 老端是 `uni-collapse` 手风琴（两条，第一条默认展开）+ `rich-text` 渲染的
/// 一段 HTML；新端用 `ExpansionTile` + 纯文本段落（内容逐条照搬）。
///
/// 正文是界面的一部分（S12.9 起有 7 种语言），所以标题与段落都走语言包，
/// 这里只拿 key 去翻 —— 以前写死中文，切到日语/西语这一页还是中文。
class DocPage extends ConsumerWidget {
  const DocPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('user.help'))),
      body: ListView(
        children: <Widget>[
          for (var i = 0; i < helpTopics.length; i++)
            // 用 Material 而不是 Container 上色：ExpansionTile 是 ListTile，
            // 背景与水波纹画在最近的 Material 上，套一层 ColoredBox 会把它盖掉
            Material(
              color: AppColors.white,
              child: ExpansionTile(
                // 老端第一条默认展开（`:open="item.id==1"`）
                initiallyExpanded: i == 0,
                title: Text(
                  i18n.t(helpTopics[i].titleKey),
                  style: TextStyle(
                    fontSize: context.rpx(28),
                    color: AppColors.text333,
                  ),
                ),
                childrenPadding: EdgeInsets.fromLTRB(
                  context.rpx(30),
                  0,
                  context.rpx(30),
                  context.rpx(20),
                ),
                children: <Widget>[
                  for (final key in helpTopics[i].paragraphKeys)
                    Padding(
                      padding: EdgeInsets.only(bottom: context.rpx(12)),
                      child: Text(
                        i18n.t(key),
                        style: TextStyle(
                          fontSize: context.rpx(26),
                          height: 1.6,
                          color: AppColors.text666,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
