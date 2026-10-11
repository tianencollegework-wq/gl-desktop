import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 通讯录那几个列表页的空态（老端 `<Empty>` 组件：一张图 + 一行字）。
///
/// 调用方负责套一层可滚动的容器（空态也要能下拉刷新），这里只管画。
class ContactsEmpty extends StatelessWidget {
  const ContactsEmpty({super.key, this.text = ''});

  /// 图下面那行字；空字符串就只画图
  final String text;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Image.asset('assets/images/empty.png', width: context.rpx(240)),
      if (text.isNotEmpty) ...<Widget>[
        SizedBox(height: context.rpx(20)),
        Text(
          text,
          style: TextStyle(fontSize: context.rpx(26), color: AppColors.text999),
        ),
      ],
    ],
  );
}
