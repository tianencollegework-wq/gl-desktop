/// 表情解析（**系统表情**，S4.4b）。
///
/// 老端的表情是「文本 token + 服务端图片」两段式：消息里存的文本形如
/// `[!1f600]`（见 `mixins/chat.js::emojiToHtml`），渲染时替换成
/// `<img src="{apiUrl}/static/img/emoji/twitter/1f600.png">`。
///
/// 新端**改用系统表情**（用户 2026-09-20 的要求）：
/// * 那份 token 里的码值**本身就是 Unicode 码点**（老端 twitter 表情包的文件名
///   就是码值），所以直接解成字符交给系统字体渲染（安卓是 Noto Color Emoji）；
/// * 面板里点一下插进输入框的是**真正的 emoji 字符**（不是 token），
///   于是我们自己发的消息里没有 token，网页端/老端收到的也是普通 emoji；
/// * 但**历史消息和网页端发来的仍然可能是 `[!code]`**（网页端用它自己的表情包），
///   所以显示时照旧解析 token —— 只是渲染从「加载图片」变成「显示字符」：
///   一样的表情、不依赖服务端静态资源、还省一堆网络请求。
/// * 解析不出码点的 token **保留原文**（对齐老端行为）。
library;

import 'rich_text.dart';

/// 表情 token 的形状：`[!代码]`。
///
/// 代码里允许 `-`：国旗这类表情是**两个码点拼起来**的
/// （`[!1f1e8-1f1f3]` = 🇨🇳），老端那 66 个都是单码点，多段是为了新加的旗子那一栏。
final RegExp emojiTokenPattern = RegExp(r'\[!([\w-]+)\]');

/// 单个码值 → 字符（十六进制 Unicode 码点，`1f600` → 😀）。
///
/// 认不出来（不是十六进制 / 超出范围 / 落在代理区）时返回 null。
String? _singleEmojiChar(String code) {
  final value = int.tryParse(code, radix: 16);
  if (value == null || value <= 0 || value > 0x10FFFF) return null;
  // 代理区（D800–DFFF）不能单独成为字符
  if (value >= 0xD800 && value <= 0xDFFF) return null;
  return String.fromCharCode(value);
}

/// 码值 → 系统表情字符。
///
/// 单码点直接用（`1f600` → 😀）；**用 `-` 接起来的多段**按顺序拼成一个字符，
/// 用来表示国旗这种多码点序列（`1f1e8-1f1f3` → 🇨🇳）。
///
/// 认不出来（不是十六进制 / 超出范围 / 落在代理区）时返回 null，
/// 调用方据此保留原文 —— 不能把 `[!xyz]` 变成空白。
String? emojiCharOf(String code) {
  final buffer = StringBuffer();
  for (final part in code.split('-')) {
    final char = _singleEmojiChar(part);
    if (char == null) return null; // 只要有一段不合法，整串就不认
    buffer.write(char);
  }
  return buffer.isEmpty ? null : buffer.toString();
}

/// 一段文本或一个表情
sealed class EmojiSegment {
  const EmojiSegment();
}

class TextEmojiSegment extends EmojiSegment {
  const TextEmojiSegment(this.text);

  final String text;
}

/// 一个系统表情：`char` 是要渲染的字符（如 `😀`），`code` 是原始码值
class EmojiCharSegment extends EmojiSegment {
  const EmojiCharSegment(this.code, this.char);

  /// 表情代码（`1f600`）
  final String code;

  /// 实际字符（`😀`）
  final String char;
}

/// 把消息文本拆成「文字 / 表情」交替的分段。
///
/// [isKnown] 用来判断某个代码是不是有效表情：**无效的保留原文**（对齐老端行为），
/// 传 null 表示「不再额外过滤，只看码点是否合法」。
List<EmojiSegment> parseEmojiSegments(
  String source, {
  bool Function(String code)? isKnown,
}) {
  final segments = <EmojiSegment>[];
  var cursor = 0;
  for (final match in emojiTokenPattern.allMatches(source)) {
    final code = match.group(1)!;
    if (!(isKnown?.call(code) ?? true)) continue;
    final char = emojiCharOf(code);
    if (char == null) continue;
    if (match.start > cursor) {
      segments.add(TextEmojiSegment(source.substring(cursor, match.start)));
    }
    segments.add(EmojiCharSegment(code, char));
    cursor = match.end;
  }
  if (cursor < source.length) {
    segments.add(TextEmojiSegment(source.substring(cursor)));
  }
  return segments;
}

/// 消息正文 → 纯文本（表情 token 换成系统表情字符）。
///
/// 两件事，顺序不能反：
/// 1. **先把富文本剥成纯文本** —— 网页端发来的 `content` 是 HTML
///    （`<p><span class="chat-grid-input">Hi</span></p>`），不剥就会把标签显示出来；
/// 2. 再把表情 token（`[!code]`）换成字符 —— 列表预览、复制、通知都用它，
///    微信这几处也都是显示表情本身。
String previewText(String source) {
  if (source.isEmpty) return '';
  final output = StringBuffer();
  for (final segment in parseEmojiSegments(richToSingleLine(source))) {
    switch (segment) {
      case TextEmojiSegment():
        output.write(segment.text);
      case EmojiCharSegment():
        output.write(segment.char);
    }
  }
  return output.toString().trim();
}
