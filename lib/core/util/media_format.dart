/// 媒体相关的格式化，对应老端 `utils/utils.js` 里的
/// `getFileSize` / `videoFormatTime` / `imageCoverStyle` 三个函数。
///
/// 前两个**照抄输出**（差异只有一处，见 [durationText]），
/// 第三个老端有一段死代码，这里实现的是它的实际效果。
library;

/// 本机路径归一化：`file:///a/b.jpg` → `/a/b.jpg`，普通路径原样返回。
///
/// 显式传 `windows: false`：默认值会跟随**运行所在的机器**——在 Windows 上跑单测时
/// `toFilePath()` 会给出 `\storage\...`，手机上却是 `/storage/...`，一条用例两边结论不同。
/// 这个路径最终交给 Android/iOS 的相册与系统应用，所以一律按 POSIX 写法。
String localFilePathOf(String source) => source.startsWith('file://')
    ? Uri.parse(source).toFilePath(windows: false)
    : source;

/// 从地址里抠出文件名（下载/保存到相册时要给个名字）。
///
/// 老端的文件名来自消息的 `fileName` 字段；语音、视频这类消息有时没有，
/// 所以再兜一道：取地址最后一段、去掉查询串；拿不到就用 [fallback]。
String fileNameFromUrl(String url, {String fallback = 'download'}) {
  if (url.isEmpty) return fallback;
  final path = Uri.tryParse(url)?.path ?? url;
  final segments = path.split('/').where((item) => item.isNotEmpty).toList();
  if (segments.isEmpty) return fallback;
  final name = segments.last;
  // 地址里没有后缀时（比如 `/upload/file/12345`）就补一个通用名
  if (!name.contains('.')) return fallback;
  return name;
}

/// 文件大小：老端 `getFileSize`
///
/// 老端的写法是先把 `size + "B"` 当作默认值，再在 `>= 1024` 时逐级除：
/// * `0` → `0B`、`1023` → `1023B`（**没有空格**）
/// * `1024` → `1.00 KB`、`1048576` → `1.00 MB`（单位前**有一个空格**，两位小数）
///
/// 单位表还有 GB / TB（老端最多除 4 次）。
String fileSize(int bytes) {
  const units = <String>[' B', ' KB', ' MB', ' GB', ' TB'];
  var value = bytes.toDouble();
  var text = '${bytes}B';
  for (var i = 0; value >= 1024 && i < 4; i++) {
    value /= 1024;
    text = '${value.toStringAsFixed(2)}${units[i + 1]}';
  }
  return text;
}

/// 语音/视频时长：老端 `videoFormatTime`
///
/// * 不到 1 小时 → `mm:ss`（如 `02:05`）
/// * 超过 1 小时 → `h:mm:ss`（如 `1:02:05`）
///
/// **刻意修正过的地方**：老端是 `date('H:i:s', 秒数)`，而 `date()` 会先把
/// “小于 9e10 的时间戳”“修正”成毫秒，于是把一个**时长**当成 1970 年的时间戳、
/// 再按本地时区输出——在 UTC+8 下，1 小时 2 分的视频会显示成 `09:02:05`，
/// 在半小时时区（如 UTC+5:30）连分钟都是错的。新端直接算时长。
String durationText(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  final secs = safe % 60;
  if (hours > 0) return '$hours:${_pad(minutes)}:${_pad(secs)}';
  return '${_pad(minutes)}:${_pad(secs)}';
}

/// 图片 / 视频封面的显示尺寸：老端 `imageCoverStyle`
///
/// 老端那段代码有两个 `if`，第一个（`width<200 && height<240` 就用原尺寸）
/// **必然被第二个覆盖**，所以实际规则只有一条：
/// * 宽 > 高 → 宽固定 200，高按比例算；
/// * 否则 → 高固定 240，宽按比例算。
///
/// 传入非正数会得到 0 或 NaN（老端会算出 `Infinity`），调用方应先判断。
({double width, double height}) mediaBoxSize(double width, double height) {
  if (width > height) return (width: 200, height: 200 / width * height);
  return (width: 240 / height * width, height: 240);
}

String _pad(int value) => value < 10 ? '0$value' : '$value';
