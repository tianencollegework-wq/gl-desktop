import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 通讯录右侧的字母索引条（老端 `pages/contacts/index.vue` 的 `indexBar`）。
///
/// 长相按微信来：**没有白底方块、没有阴影** —— 就是一行字母浮在列表上面
/// （老端那个 `indexBar` 是白底圆角 + 阴影，微信不是）。
///
/// 最上面那一格微信是「↑（回到顶部）」和「☆（星标朋友）」。星标朋友我们没有，
/// 所以只做 ↑。
///
/// 老端是 `touchstart/touchmove/touchend` 三个事件 + `parseInt((y - top) / 20)`
/// 算落在哪个字母上（固定 20px）。这里按实际可用高度算每格高度，
/// 横竖屏/不同字号下都不会错位。
///
/// [onSelect] 在每次手指落到某个字母时调用（点按与滑动都会触发）。
class ContactIndexBar extends StatefulWidget {
  const ContactIndexBar({
    super.key,
    required this.letters,
    required this.onSelect,
    required this.onActiveChanged,
    this.onTop,
  });

  final List<String> letters;

  /// 手指落在第几个字母上
  final void Function(String letter) onSelect;

  /// 拖动开始/结束（用来显隐中间那个大字母提示）
  final void Function(bool active) onActiveChanged;

  /// 最上面那格「↑」（回到顶部）。不传就不画。
  final VoidCallback? onTop;

  /// 「↑」这一格在提示里显示的字（微信弹的是 ↑ 本身）
  static const String topGlyph = '↑';

  @override
  State<ContactIndexBar> createState() => _ContactIndexBarState();
}

class _ContactIndexBarState extends State<ContactIndexBar> {
  String? _last;

  /// 渲染出来的格子 =「↑」+ 字母（有 onTop 时）
  List<String> get _slots => <String>[
    if (widget.onTop != null) ContactIndexBar.topGlyph,
    ...widget.letters,
  ];

  void _handle(double localY, double boxHeight) {
    final slots = _slots;
    if (slots.isEmpty || boxHeight <= 0) return;
    final slot = boxHeight / slots.length;
    var index = (localY / slot).floor();
    if (index < 0) index = 0;
    if (index >= slots.length) index = slots.length - 1;
    final item = slots[index];
    if (item == _last) return;
    _last = item;
    if (item == ContactIndexBar.topGlyph) {
      widget.onTop?.call();
      return;
    }
    widget.onSelect(item);
  }

  @override
  Widget build(BuildContext context) {
    final slots = _slots;
    if (slots.isEmpty) return const SizedBox.shrink();

    return Container(
      width: context.rpx(44),
      padding: EdgeInsets.symmetric(vertical: context.rpx(10)),
      child: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            widget.onActiveChanged(true);
            _handle(details.localPosition.dy, constraints.maxHeight);
          },
          onTapUp: (_) => widget.onActiveChanged(false),
          onTapCancel: () => widget.onActiveChanged(false),
          onVerticalDragStart: (details) {
            widget.onActiveChanged(true);
            _handle(details.localPosition.dy, constraints.maxHeight);
          },
          onVerticalDragUpdate: (details) =>
              _handle(details.localPosition.dy, constraints.maxHeight),
          onVerticalDragEnd: (_) => widget.onActiveChanged(false),
          onVerticalDragCancel: () => widget.onActiveChanged(false),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final letter in slots)
                Expanded(
                  child: Center(
                    child: Text(
                      letter,
                      style: TextStyle(
                        fontSize: context.rpx(22),
                        height: 1,
                        color: AppColors.text333,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
