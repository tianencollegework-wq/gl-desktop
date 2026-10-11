/// 通话时长文案（老端 `hybrid/html/index.html::setCallTime`）。
///
/// 老端的格式固定 `HH:MM:SS`（小时也补零），新端逐字照抄：服务端下发的通话记录
/// 文案（`im-webrtc.vue` 直接显示 `content`，形如「通话时长 00:35」）也是这个口径，
/// 两边看起来才一致。
String formatCallDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe - hours * 3600) ~/ 60;
  final rest = safe - hours * 3600 - minutes * 60;
  return '${_pad(hours)}:${_pad(minutes)}:${_pad(rest)}';
}

/// 通话记录那条文案里的时长：**分钟:秒**（`00:35`）。
///
/// 为什么不直接用 [formatCallDuration]：老端记在聊天里的那条不是客户端拼的，
/// 是服务端 `Im.php::sendToMsg` 用 `date("i:s", $callTime)` 拼出来的（`webRtc.duration`），
/// 形如「通话时长 00:35」。群通话的记录要跟它在同一个列表里长得一模一样，
/// 所以跟着那个口径走（不足一分钟也显示 `00:xx`；超过一小时分钟数继续往上涨）。
String formatCallRecordDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  return '${_pad(safe ~/ 60)}:${_pad(safe % 60)}';
}

String _pad(int value) => value.toString().padLeft(2, '0');
