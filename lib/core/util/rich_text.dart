/// 富文本（HTML）→ 纯文本。
///
/// 网页端（官方原生客户端）发消息时 `content` 是一段 HTML，真机实测它发来的是
/// `<p><span class="chat-grid-input">Hi</span></p>`；老端把它交给 `mp-html` 渲染，
/// 新端不引 HTML 渲染库（见 `REFACTOR_PLAN.md` 的选型说明），所以在**显示前**把标签剥掉。
///
/// 规则照老端 `utils/utils.js::htmlToLines`（非 H5 分支）：
/// * `<br>` → 换行；`</p>` / `</div>` / `</li>` 这类块级结束 → 换行（一段一行）；
/// * 其它标签整个剥掉；
/// * 表情图片（`<img emoji-name="1f600" ...>`，是老端 `emojiToHtml` 的产物）
///   还原成 `[!1f600]` token，交给我们自己的表情渲染；其它图片直接丢掉；
/// * 常见 HTML 实体解码（`&nbsp;` `&amp;` `&lt;` …）；
/// * 连续空行压成一个、首尾去空白。
///
/// **我们发出去的消息不受影响**：自己发的本来就是纯文本 + `[!code]` token
/// （见 `domain/chat/outgoing_message.dart` 的说明），走这里的「快路径」原样返回。
library;

/// 表情图片：老端 `emojiToHtml` 生成的 `<img emoji-name="1f600" src="...">`
final RegExp _imagePattern = RegExp(r'<img\b[^>]*>', caseSensitive: false);

/// 表情图片里的 `emoji-name`（有则还原成 `[!code]`，没有就是普通图片 → 丢掉）
final RegExp _emojiNamePattern = RegExp(
  'emoji-name\\s*=\\s*["\']([^"\']+)["\']',
  caseSensitive: false,
);

final RegExp _lineBreakPattern = RegExp(r'<br\s*/?>', caseSensitive: false);
final RegExp _blockEndPattern = RegExp(
  r'</\s*(p|div|li|h[1-6]|tr)\s*>',
  caseSensitive: false,
);
final RegExp _blockStartPattern = RegExp(
  r'<\s*(p|div|li|h[1-6]|tr)\b[^>]*>',
  caseSensitive: false,
);

/// 剩下的标签（含注释 `<!-- -->`）一并剥掉
final RegExp _anyTagPattern = RegExp(r'</?[^>]+(>|$)');
final RegExp _entityPattern = RegExp(
  r'&(#[xX]?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);',
);
final RegExp _blankLinesPattern = RegExp(r'\n{3,}');
final RegExp _whitespacePattern = RegExp(r'\s+');

const Map<String, String> _namedEntities = <String, String>{
  'nbsp': ' ',
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'ldquo': '“',
  'rdquo': '”',
  'lsquo': '‘',
  'rsquo': '’',
  'hellip': '…',
  'middot': '·',
  'mdash': '—',
  'ndash': '–',
  'times': '×',
  'divide': '÷',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'deg': '°',
};

/// HTML 实体解码（`&nbsp;` `&amp;` `&#39;` `&#x1f600;`）。
///
/// 认不出来的原样留着 —— 老端也是「认不出就不动」，宁可显示 `&foo;` 也不丢字。
String decodeHtmlEntities(String source) {
  if (!source.contains('&')) return source;
  return source.replaceAllMapped(_entityPattern, (match) {
    final body = match.group(1)!;
    if (body.startsWith('#')) {
      final isHex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
      final digits = body.substring(isHex ? 2 : 1);
      final code = int.tryParse(digits, radix: isHex ? 16 : 10);
      if (code == null || code <= 0 || code > 0x10FFFF) return match.group(0)!;
      return String.fromCharCode(code);
    }
    return _namedEntities[body.toLowerCase()] ?? match.group(0)!;
  });
}

/// 富文本 → 纯文本（气泡显示用，保留换行）。
String richToPlainText(String source) {
  if (source.isEmpty) return '';
  // 快路径：自己发的消息是纯文本 + `[!code]`，连标签和实体都没有
  if (!source.contains('<') && !source.contains('&')) return source;

  final text = source
      .replaceAllMapped(_imagePattern, (match) {
        final name = _emojiNamePattern.firstMatch(match.group(0)!)?.group(1);
        return name == null ? '' : '[!$name]';
      })
      .replaceAll(_lineBreakPattern, '\n')
      .replaceAll(_blockEndPattern, '\n')
      .replaceAll(_blockStartPattern, '')
      .replaceAll(_anyTagPattern, '');

  return decodeHtmlEntities(text)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(_blankLinesPattern, '\n\n')
      .trim();
}

/// 富文本 → 单行（会话列表预览 / 引用块 / 通知 / 复制用）。
String richToSingleLine(String source) =>
    richToPlainText(source).replaceAll(_whitespacePattern, ' ').trim();
