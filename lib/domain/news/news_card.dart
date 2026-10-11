/// 资讯卡片消息（`type == 'news'`）：发送、渲染、点击的纯逻辑。
///
/// 和音乐卡片（`domain/lingting/lingting_card.dart`）、名片（`contact`）**同一套做法**：
/// `content` 放「会话列表 / 通知里显示的那行字」，真正渲染要用的字段全放 `extends`。
/// 用户 2026-09-30：「能不能做成像音乐一样的卡片可以分享到聊天里」——照搬的就是那一套。
///
/// 服务端不校验 `type` 白名单（`type` 原样入库、能转发、能通过 WS 推给客户端），
/// 所以新类型直接能用；代价与音乐卡片一样：**官方网页端和旧 uniapp 收到会显示
/// 「暂不支持的消息类型」**。
///
/// 两处刻意的截断，都是因为 `extends` 要跟着消息一起存/推：
/// * 标题 120 字、摘要 200 字 —— 卡片上本来就只显示两行标题，摘要更是只给个引子，
///   没必要把整篇 1000 字摘要塞进消息体（别的端还会把它当正文渲染）；
/// * `content` 里那行字只留 60 字标题，理由同上。
library;

import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';
import '../../data/model/message.dart';
import 'news_article.dart';
import 'news_feed.dart';

/// 资讯卡片的消息类型（服务端原样存，不需要它认识）
const String newsMessageType = 'news';

/// 卡片里标题/摘要的截断长度
const int newsCardTitleLimit = 120;
const int newsCardSummaryLimit = 200;

@immutable
class NewsCard {
  const NewsCard({
    required this.id,
    required this.title,
    this.sourceKey = '',
    this.summary = '',
    this.image = '',
    this.link = '',
    this.publishedAt,
  });

  /// 从列表里那一篇来
  factory NewsCard.fromArticle(NewsArticle article) => NewsCard(
    id: article.id,
    title: _clip(article.title, newsCardTitleLimit),
    sourceKey: article.sourceKey,
    summary: _clip(article.summary, newsCardSummaryLimit),
    image: article.imageUrl,
    link: article.link,
    publishedAt: article.publishedAt,
  );

  /// 从 `extends` / 顶层 `extra` 里读回一张卡片。
  ///
  /// 两处都读一遍的理由见 [newsCardOf]；桌面「文章独立窗口」也用它 ——
  /// 卡片本体要跟着窗口参数递到子引擎那边去（那边本机可能没这一篇）。
  factory NewsCard.fromExt(
    Map<String, dynamic> ext, [
    Map<String, dynamic>? extra,
  ]) {
    String pick(String key) {
      final fromExt = asText(ext[key]);
      if (fromExt.isNotEmpty) return fromExt;
      return asText(extra == null ? null : extra[key]);
    }

    return NewsCard(
      id: pick('id'),
      title: pick('title'),
      sourceKey: pick('source'),
      summary: pick('summary'),
      image: pick('image'),
      link: pick('link'),
      publishedAt: DateTime.tryParse(pick('published')),
    );
  }

  /// 原文那条的稳定标识（我们自己的缓存里用它找）
  final String id;
  final String title;

  /// 来源 key（`ithome` 这些）——**存 key 不存名字**：对方切到英文界面时，
  /// 卡片上的来源名跟着他自己的语言走（和 App 里其它文案一套规矩）
  final String sourceKey;
  final String summary;
  final String image;
  final String link;
  final DateTime? publishedAt;

  bool get isEmpty => title.isEmpty && link.isEmpty;

  /// `content`：会话列表、通知里显示的那行字（与名片/音乐卡片同一套写法）
  String content(String Function(String key) translate) =>
      '[${translate('common.news')}] ${_clip(title, 60)}';

  /// 发出去时放进 `extends` 的字段
  Map<String, dynamic> toExt() => <String, dynamic>{
    'id': id,
    'title': title,
    'source': sourceKey,
    'summary': summary,
    'image': image,
    'link': link,
    if (publishedAt != null) 'published': publishedAt!.toIso8601String(),
  };

  /// 详情页渲染用：拼回一条「文章」。
  ///
  /// 收卡片的人本机列表里没有这一篇（那是**发的人**机器上抓到的），所以详情页
  /// 拿不到本地那条时用这份合成——**只能看摘要和原图**，代表我们手上就这么多
  /// （对方点「阅读原文」去原站看全文，和列表里那一篇一致）。
  NewsArticle toArticle() => NewsArticle(
    id: id,
    title: title,
    link: link,
    sourceKey: sourceKey,
    summary: summary,
    imageUrl: image,
    publishedAt: publishedAt,
    // 分享进来的那条不算「未读」（它不在列表里，也标不了）
    read: true,
  );

  /// 卡片上那行来源名（认不出来的源返回空串，UI 就不画）
  String sourceLabelKey() => newsFeedByKey(sourceKey)?.nameKey ?? '';

  @override
  String toString() => 'NewsCard($id, $title)';
}

/// 从一条消息里读回卡片。
///
/// 与音乐卡片一致：字段在 `extends` 和消息顶层 `extra` 两处都读一遍
/// （别人（将来别的端）发的时候可能放在不同位置）。
NewsCard newsCardOf(Message message) =>
    NewsCard.fromExt(message.ext, message.extra);

String _clip(String text, int limit) =>
    text.length <= limit ? text : '${text.substring(0, limit).trimRight()}…';
