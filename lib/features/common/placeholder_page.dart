import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// 尚未实现页面的占位。
///
/// 刻意把老端路径显示在界面上：逐个改造时，一眼就能对上「这个路由对应老端哪个文件」，
/// 不用来回翻 `REFACTOR_PLAN.md`。
class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({
    super.key,
    required this.title,
    required this.legacyPath,
    this.milestone,
  });

  /// 页面标题（取自老端 pages.json 的 navigationBarTitleText）
  final String title;

  /// 对应的老端文件路径
  final String legacyPath;

  /// 计划在哪个里程碑实现
  final String? milestone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.construction_outlined,
                size: 48,
                color: AppColors.text999,
              ),
              const SizedBox(height: 16),
              const Text(
                '待实现',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text333,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '对应老端：$legacyPath',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppColors.text666),
              ),
              if (milestone != null) ...[
                const SizedBox(height: 6),
                Text(
                  '计划：$milestone',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.text999,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
