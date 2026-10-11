import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/util/emoji.dart';
import 'package:gracelinkim/core/util/rich_text.dart';

/// 富文本 → 纯文本（真机上手打过的问题：网页端发来的 HTML 被原样显示）。
///
/// 网页端（官方原生客户端）发消息时 `content` 是一段 HTML，实测它发来的是
/// `<p><span class="chat-grid-input">Hi</span></p>`。
void main() {
  group('richToPlainText', () {
    test('网页端那句真实的 HTML → 干净的文字', () {
      const sent = '<p><span class="chat-grid-input">Hi</span></p>';
      expect(richToPlainText(sent), 'Hi');
    });

    test('自己发的纯文本原样（快路径：带表情 token 的也不动）', () {
      expect(richToPlainText('Hi'), 'Hi');
      expect(richToPlainText('晚上一起吃饭 [!1f600]'), '晚上一起吃饭 [!1f600]');
      expect(richToPlainText(''), '');
    });

    test('段落/换行：br 与块级结束都算换行，连续空行压成一个', () {
      expect(richToPlainText('<p>一</p><p>二</p>'), '一\n二');
      expect(richToPlainText('一<br>二'), '一\n二');
      expect(richToPlainText('一<br/>二<br />三'), '一\n二\n三');
      expect(richToPlainText('<div>一</div><div>二</div>'), '一\n二');
      expect(richToPlainText('<p>一</p><p></p><p></p><p>二</p>'), '一\n\n二');
    });

    test('其它标签整个剥掉（含带属性的、注释）', () {
      expect(richToPlainText('<b>粗</b><i>斜</i>'), '粗斜');
      expect(richToPlainText('<p style="color:red" class="x">文字</p>'), '文字');
      expect(richToPlainText('<!-- 注释 -->正文'), '正文');
      expect(richToPlainText('<p>没闭合'), '没闭合');
    });

    test('实体解码：常用命名实体与数字实体', () {
      expect(richToPlainText('a&nbsp;b'), 'a b');
      expect(richToPlainText('&lt;标签&gt;'), '<标签>');
      expect(richToPlainText('A&amp;B'), 'A&B');
      expect(richToPlainText('&#39;引号&#39;'), "'引号'");
      expect(richToPlainText('&#x41;&#x42;'), 'AB');
      // 认不出来的原样留着，不丢字
      expect(richToPlainText('&foo;文字'), '&foo;文字');
    });

    test('表情图片还原成 [!code]（老端 emojiToHtml 的产物），普通图片丢掉', () {
      expect(
        richToPlainText(
          '早<img class="mr-5" emoji-name="1f600" '
          'src="https://a.test/static/img/emoji/twitter/1f600.png">',
        ),
        '早[!1f600]',
      );
      expect(richToPlainText('<img src="https://a.test/photo.png">看图'), '看图');
    });

    test('我们自己的引用文案不会被吃掉（那是纯文本加方括号）', () {
      expect(richToPlainText('[图片]'), '[图片]');
      expect(richToPlainText('[个人名片] 小红'), '[个人名片] 小红');
    });
  });

  group('richToSingleLine', () {
    test('多行压成一行（会话列表预览、引用块用）', () {
      expect(richToSingleLine('<p>第一行</p><p>第二行</p>'), '第一行 第二行');
      expect(richToSingleLine('一\n\n\n二'), '一 二');
      expect(richToSingleLine('  <b>两边有空白</b>  '), '两边有空白');
    });
  });

  group('previewText（列表预览 = 剥 HTML + 表情 token 变系统表情）', () {
    test('网页端发来的 HTML 也能正确预览', () {
      expect(
        previewText('<p><span class="chat-grid-input">Hi</span></p>'),
        'Hi',
      );
      // 表情图片还原出来的 token 会变成**系统表情字符**（S4.4b：不再丢成空白）
      expect(previewText('<p>看这个<img emoji-name="1f600"></p>'), '看这个😀');
    });

    test('纯文本里的表情 token 变成字符', () {
      expect(previewText('晚上一起吃饭 [!1f600]'), '晚上一起吃饭 😀');
      expect(previewText(''), '');
    });
  });
}
