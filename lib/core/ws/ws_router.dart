import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ws_event.dart';

typedef WsHandler = FutureOr<void> Function(WsEvent event);

/// WS 事件分发。
///
/// 老端把 20 多个事件全塞在 `App.vue` 的一个巨型 `switch` 里（300+ 行），
/// 这里拆成注册表：协议层（ping/pong/init）在 M1 注册，
/// 业务层（simple/group/webrtc/…）在 M2、M4、M5、M6 逐个注册。
///
/// 额外做一件老端没有的事：**记录收到过但没人处理的事件**（`unknownTypes`），
/// 这样万一服务端推了我们不知道的事件，能立刻发现而不是静默丢掉。
class WsRouter {
  final Map<String, WsHandler> _handlers = <String, WsHandler>{};
  final List<String> _unknownTypes = <String>[];

  void register(String type, WsHandler handler) {
    _handlers[type] = handler;
  }

  void registerAll(Map<String, WsHandler> handlers) {
    _handlers.addAll(handlers);
  }

  bool handles(String type) => _handlers.containsKey(type);

  Set<String> get registeredTypes => _handlers.keys.toSet();

  /// 收到过、但当前没有处理器的事件名（用于排查协议盲区）
  List<String> get unknownTypes => List<String>.unmodifiable(_unknownTypes);

  Future<void> dispatch(WsEvent event) async {
    final handler = _handlers[event.type];
    if (handler == null) {
      if (!_unknownTypes.contains(event.type)) {
        _unknownTypes.add(event.type);
        debugPrint('[WS] 收到未处理的事件：${event.type}（已记入 unknownTypes）');
      }
      return;
    }

    try {
      await handler(event);
    } catch (error, stack) {
      // 单个事件处理失败不能影响后续事件
      debugPrint('[WS] 处理事件 ${event.type} 失败：$error');
      debugPrint('$stack');
    }
  }
}
