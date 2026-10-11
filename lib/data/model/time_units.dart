/// 时间戳单位归一化（S3.4 的核心结论）。
///
/// 老端从头到尾没有统一过单位，但它有一处"魔法"让显示看起来正常——
/// `utils/utils.js::date()`：
///
/// ```js
/// const date = (format, timestamp) => {
///   if (timestamp < 90000000000) { timestamp *= 1000; }
///   ...
/// }
/// ```
///
/// 也就是小于 9e10 的值当成"秒"，乘 1000 再用。所以渲染层对两种单位都能忍。
/// 但同一份代码里的**逻辑判断**不能忍，这就是老端的隐患：
///
/// | 位置 | 代码 | 隐含单位 |
/// | --- | --- | --- |
/// | `im-input.vue:267` | 本地乐观消息 `sendTime: new Date().getTime()` | 毫秒 |
/// | `chat.vue:684` | `prev.sendTime - item.sendTime > 180000`（3 分钟插时间分隔） | 毫秒 |
/// | `chat.vue:720` | `getTime() - curMsg.sendTime < redoTime * 1000`（能否撤回） | 毫秒 |
/// | `chat.vue:373` | `getTime() - message.sendTime < redoTime * 1000`（已读上报） | 毫秒 |
/// | `App.vue:473` | WS 推送时 `contact.lastSendTime = data.sendTime * 1000` | 秒 |
///
/// 前四条说明**消息列表里的 `sendTime` 必须是毫秒**（本地乐观消息就是毫秒，
/// 两者混在同一个数组里比较）；最后一条说明 WS 推送那份很可能是秒。
/// 老端这个 `* 1000` 会让会话列表的时间显示成荒谬值（毫秒再乘 1000）。
///
/// 新端的做法：**入库前一律归一化成毫秒**，用与老端 `date()` 完全相同的阈值判断。
/// 好处是服务端给秒还是毫秒、REST 与 WS 是否一致，都不需要先拿到真实报文就能正确显示。
library;

/// 小于这个值就当"秒"处理（与老端 `date()` 的阈值完全一致）
const int _secondsThreshold = 90000000000;

/// 把服务端给的时间戳统一成**毫秒**。
///
/// * `null` / 无法解析 → 返回 0（代表"没有时间"）
/// * 秒级时间戳（如 `1758163200`）→ 乘以 1000
/// * 毫秒级时间戳（如 `1758163200000`）→ 原样
int toMillis(Object? value) {
  final raw = switch (value) {
    null => null,
    int v => v,
    num v => v.toInt(),
    String v => int.tryParse(v.trim()),
    _ => null,
  };
  if (raw == null || raw <= 0) return 0;
  return raw < _secondsThreshold ? raw * 1000 : raw;
}

/// 当前时间（毫秒）。老端本地乐观消息用的也是这个口径。
int nowMillis() => DateTime.now().millisecondsSinceEpoch;
