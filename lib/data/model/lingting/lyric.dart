import 'package:flutter/foundation.dart';

import 'markup.dart';

/// 一行歌词。
@immutable
class LyricLine {
  const LyricLine({required this.at, required this.text});

  /// 这一行该在什么时刻显示
  final Duration at;

  final String text;

  @override
  bool operator ==(Object other) =>
      other is LyricLine && other.at == at && other.text == text;

  @override
  int get hashCode => Object.hash(at, text);

  @override
  String toString() => 'LyricLine(${at.inMilliseconds}ms, $text)';
}

/// 歌词取回来之后的形态。
///
/// `[lines]` 非空 = 有时间轴（LRC 解出来了），界面可以跟着唱到哪高亮到哪；
/// `[lines]` 为空但 [plain] 非空 = 只有正文（搜索接口给的就是这种），
/// 界面就平铺显示、不做滚动。
@immutable
class LingtingLyric {
  const LingtingLyric({this.lines = const <LyricLine>[], this.plain = ''});

  static const LingtingLyric empty = LingtingLyric();

  final List<LyricLine> lines;
  final String plain;

  bool get hasTimeline => lines.isNotEmpty;
  bool get isEmpty => lines.isEmpty && plain.isEmpty;

  /// 完整正文（「复制歌词」用）：有时间轴就按行拼，否则原样。
  ///
  /// 重复出现的副歌会跟着时间轴重复 —— 这就是「按播放顺序抄一份歌词」的意思。
  String get fullText =>
      hasTimeline ? lines.map((line) => line.text).join('\n') : plain;

  /// [position] 时刻该显示的那一句（没有时间轴或还没开始唱时给空串）
  String lineAt(Duration position) {
    final index = activeIndex(position);
    return index < 0 ? '' : lines[index].text;
  }

  /// [position] 时刻该高亮第几行；还没有任何一行到点（前奏）时返回 -1。
  ///
  /// 用**最后一个不晚于 position 的行**，前奏期间界面就不会乱跳。
  int activeIndex(Duration position) {
    if (lines.isEmpty) return -1;
    final target = position.inMilliseconds;
    // 行是按时间排好的（[parseLrc] 保证），所以可以二分
    var low = 0;
    var high = lines.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      if (lines[mid].at.inMilliseconds <= target) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }
}

/// 一行 LRC 的三种标签形态：
/// * `[mm:ss.xx]` / `[mm:ss]` / `[mm:ss:xx]`（老 MP3 里三种都见过）—— 时间轴
/// * `[offset:+300]` —— 整体偏移（毫秒）
/// * `[ti:]` `[ar:]` `[al:]` `[by:]` —— 元信息，不算歌词
final RegExp _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final RegExp _offsetTag = RegExp(
  r'\[offset:\s*([+-]?\d+)\s*\]',
  caseSensitive: false,
);

/// 解析 LRC 正文。
///
/// 会比老端多做三件小事（都是真歌词里一定撞得到的）：
/// 1. **一行多个时间标签**（`[00:12.00][01:20.00]歌词`）全部展开；
/// 2. **`offset` 标签**按毫秒整体平移；
/// 3. **元信息行**（`[ti:]` 等）与解析不出时间的行丢掉，不塞进时间轴。
///
/// 解析不出任何时间标签时返回**空列表**：调用方据此走「纯文本歌词」那条路
/// （搜索接口给的歌词正文就是这样，它没有时间轴）。
/// 去掉开头的 BOM（`\uFEFF`）。
///
/// 灵听给的 `.lrc` 文件是**带 BOM 的 UTF-8**（实测 `\uFEFF[00:25.000]一粒麥子`），
/// 不清掉的话第一行正文里会混进一个看不见的字符。
String stripBom(String raw) =>
    raw.startsWith('\uFEFF') ? raw.substring(1) : raw;

List<LyricLine> parseLrc(String raw) {
  raw = stripBom(raw);
  if (raw.trim().isEmpty) return const <LyricLine>[];

  var offset = Duration.zero;
  final offsetMatch = _offsetTag.firstMatch(raw);
  if (offsetMatch != null) {
    offset = Duration(
      milliseconds: int.tryParse(offsetMatch.group(1) ?? '') ?? 0,
    );
  }

  final lines = <LyricLine>[];
  for (final rawLine in raw.split(RegExp(r'\r\n|\r|\n'))) {
    final matches = _timeTag.allMatches(rawLine).toList();
    if (matches.isEmpty) continue;
    // 时间标签之后的才是歌词正文；一行挂多个标签时正文只有一份
    final text = rawLine.substring(matches.last.end).trim();
    if (text.isEmpty) continue;
    for (final match in matches) {
      final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
      // 毫秒位可能是 2 位（`.50` = 500ms）也可能是 3 位（`.500`）
      final fractionRaw = match.group(3) ?? '';
      final fraction = fractionRaw.isEmpty
          ? 0
          : (fractionRaw.length == 1
                ? int.parse(fractionRaw) * 100
                : (fractionRaw.length == 2
                      ? int.parse(fractionRaw) * 10
                      : int.parse(fractionRaw.substring(0, 3))));
      final at =
          Duration(minutes: minutes, seconds: seconds, milliseconds: fraction) +
          offset;
      lines.add(
        LyricLine(at: at < Duration.zero ? Duration.zero : at, text: text),
      );
    }
  }

  lines.sort((a, b) => a.at.compareTo(b.at));
  return lines;
}

/// 把歌词正文按行拆开（没有时间轴的那种）。
///
/// 两种换行都要认：
/// * **真换行**（`\n` / `\r\n`）—— 老 .lrc 正文、别的来源；
/// * **分号**（`;` 与全角 `；`）—— 灵听列表接口给的就是这种：`lyric` 字段
///   是把整首歌**用 `;` 连成一行**的纯文本，`;;` 表示空行。
///
/// 这一条是看着真机截图补的：不拆分号，整首歌词会铺成**一坨连着的文字**
/// （实测那天抽了 180 首，180 首的 `lyric` 都是纯文本、其中**一首都没有真换行**）。
/// 顺带把搜索命中标记 `[]` 也去掉（同一份数据里歌词片段也带这个标记）。
List<String> plainLyricLines(String raw) {
  final lines = <String>[];
  for (final chunk in stripBom(raw).split(RegExp(r'\r\n|\r|\n'))) {
    for (final piece in chunk.split(RegExp(r'[;；]'))) {
      final text = stripLingtingMarkup(piece).trim();
      if (text.isNotEmpty) lines.add(text);
    }
  }
  return List<String>.unmodifiable(lines);
}

/// 把「歌词字段」判成两种来源。
///
/// 灵听同一个字段（`lyric`）在详情接口里是 **LRC 地址**、在搜索接口里是
/// **正文**，所以要先判：看起来像地址 → 去下载再解析；否则直接当正文用。
/// 判据是「http(s) 开头且没有换行」——正文里不会出现这种形态。
class LingtingLyricSource {
  const LingtingLyricSource._(this.isUrl, this.value);

  /// 字段是 URL（要再发一次请求去取 .lrc）
  final bool isUrl;

  /// URL 本身，或歌词正文
  final String value;

  static const LingtingLyricSource empty = LingtingLyricSource._(false, '');

  static LingtingLyricSource parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return empty;
    final looksLikeUrl =
        (text.startsWith('http://') || text.startsWith('https://')) &&
        !text.contains('\n');
    return LingtingLyricSource._(looksLikeUrl, text);
  }
}
