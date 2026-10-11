import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/news/news_article.dart';
import 'package:gracelinkim/domain/news/news_card.dart';

/// 资讯卡片（`type == 'news'`）：发送时怎么装进 `extends`、收到后怎么读回来。
///
/// 与音乐卡片（`test/lingting/lingting_card_test.dart`）同一组断言，钉住三件事：
/// 1. 卡片带全了详情页要用的字段（标题/来源/摘要/缩略图/原文地址）；
/// 2. 读回来时字段少一个也别崩（别的端将来发的方式可能不一样）；
/// 3. 会话列表/通知里那行字是「[资讯] 标题」。
void main() {
  final article = NewsArticle(
    id: 'https://sspai.com/post/115153',
    title: '社区速递 160 | 水月雨首款游戏耳机',
    link: 'https://sspai.com/post/115153',
    sourceKey: 'sspai',
    summary: '除了首页时间流和侧栏的精选展位，还有很多内容。',
    imageUrl: 'https://cdn.test/a.jpg',
    publishedAt: DateTime(2026, 9, 29, 17, 3),
  );

  group('从文章到卡片', () {
    test('详情页要用的字段都带上，content 是「[资讯] 标题」', () {
      final card = NewsCard.fromArticle(article);

      expect(card.toExt(), <String, dynamic>{
        'id': 'https://sspai.com/post/115153',
        'title': '社区速递 160 | 水月雨首款游戏耳机',
        'source': 'sspai',
        'summary': '除了首页时间流和侧栏的精选展位，还有很多内容。',
        'image': 'https://cdn.test/a.jpg',
        'link': 'https://sspai.com/post/115153',
        'published': '2026-09-29T17:03:00.000',
      });
      expect(
        card.content((key) => key == 'common.news' ? '资讯' : key),
        '[资讯] 社区速递 160 | 水月雨首款游戏耳机',
      );
      // 存的是**来源 key**：对方切到英文界面时，卡片上的来源名也跟着变
      expect(card.sourceLabelKey(), 'news.source.sspai');
      expect(card.isEmpty, isFalse);
    });

    test('标题与摘要都截断（消息体要跟着存/推，不能把整篇摘要塞进去）', () {
      final long = NewsArticle(
        id: 'x',
        title: '长' * 300,
        link: 'https://a.test/1',
        sourceKey: 'ithome',
        summary: '摘要' * 300,
      );
      final card = NewsCard.fromArticle(long);

      expect(card.title.length, lessThanOrEqualTo(newsCardTitleLimit + 1));
      expect(card.title, endsWith('…'));
      expect(card.summary.length, lessThanOrEqualTo(newsCardSummaryLimit + 1));
      // content 里那行字更短（「[资讯] 」+ 60 字标题），免得把会话列表的预览撑爆
      expect(
        card.content((key) => key == 'common.news' ? '资讯' : key).length,
        lessThan(70),
      );
    });

    test('合成回一篇文章：详情页拿它渲染（没有来源 key 时来源行不画）', () {
      final card = NewsCard.fromArticle(article);
      final rebuilt = card.toArticle();

      expect(rebuilt.title, article.title);
      expect(rebuilt.link, article.link);
      expect(rebuilt.summary, article.summary);
      expect(rebuilt.imageUrl, article.imageUrl);
      expect(rebuilt.read, isTrue, reason: '分享进来的不算未读');

      expect(
        const NewsCard(id: 'y', title: 'x', sourceKey: 'nope').sourceLabelKey(),
        '',
      );
    });
  });

  group('从消息读回卡片', () {
    Message message({Map<String, dynamic> ext = const <String, dynamic>{}}) =>
        Message(
          msgId: 'm1',
          conversationId: 'u2',
          fromUserId: 'u2',
          type: newsMessageType,
          content: '[资讯] 一条新闻',
          sendTime: 1,
          ext: ext,
        );

    test('extends 里的字段都读回来', () {
      final card = newsCardOf(
        message(ext: NewsCard.fromArticle(article).toExt()),
      );

      expect(card.id, article.id);
      expect(card.title, article.title);
      expect(card.sourceKey, 'sspai');
      expect(card.summary, article.summary);
      expect(card.image, article.imageUrl);
      expect(card.link, article.link);
      expect(card.publishedAt, article.publishedAt);
    });

    test('字段放在消息顶层 extra 里也认（别的端可能放那儿）', () {
      final card = newsCardOf(
        message(ext: const <String, dynamic>{}).copyWith(
          extra: <String, dynamic>{
            'title': '从 extra 来',
            'link': 'https://a.test/2',
          },
        ),
      );

      expect(card.title, '从 extra 来');
      expect(card.link, 'https://a.test/2');
    });

    test('裸记录（什么都没带）读出来是空的 —— 点它不该跳空白页', () {
      expect(newsCardOf(message()).isEmpty, isTrue);
    });
  });
}
