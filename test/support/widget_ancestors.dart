import 'package:flutter/material.dart';

/// 从某个 element 往上找**最近**的一层 [Material]。
///
/// 为什么需要它（两个用例在钉同一件事）：
///
/// `MaterialApp` 给「不在任何 Material 里的 Text」准备的是一份**调试样式**
/// （红字 + 两条黄色下划线，见 `material/app.dart` 的 `_errorTextStyle`）——
/// 挂在根 Overlay 上的浮层（提示、录音浮层）祖先里本来就没有 Material，
/// 少包一层用户就会看到「很多提示都有两条黄色下划线」（2026-09-30 报的）。
///
/// 注意这里必须找**最近**的那层：再往上还有 `Scaffold` 自己那层 Material，
/// 用 `find.ancestor` 拿到的集合不保证顺序，所以手动 `visitAncestorElements`。
Material? nearestMaterialOf(Element element) {
  Material? found;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Material) {
      found = widget;
      return false;
    }
    return true;
  });
  return found;
}
