import 'package:flutter/foundation.dart';

import '../../../core/util/json_value.dart';
import 'singer.dart';
import 'song.dart';
import 'song_sheet.dart';

/// 首页轮播的一张图。
///
/// `bannerUrl` 实测是**一串数字**（歌曲 id），`type` 表示它指向什么
/// （实测给的都是 `1`）。这里按「有 songId 就点进那首歌」处理，
/// 认不出来的就当纯图片（点了没反应），不要瞎跳。
@immutable
class LingtingBanner {
  const LingtingBanner({
    required this.image,
    this.title = '',
    this.target = '',
    this.type = 1,
  });

  final String image;
  final String title;

  /// 原始指向（歌曲 id / 链接），按 [type] 解释
  final String target;
  final int type;

  /// 指向的歌曲 id（`type == 1` 且 target 是数字时才有值，否则 0）
  int get songId => type == 1 ? (int.tryParse(target) ?? 0) : 0;

  factory LingtingBanner.fromJson(Map<String, dynamic> json) => LingtingBanner(
    image: asText(json['bannerImg'] ?? json['image']),
    title: asText(json['bannerTitle'] ?? json['title']),
    target: asText(json['bannerUrl'] ?? json['url']),
    type: asInt(json['type'], 1),
  );

  @override
  bool operator ==(Object other) =>
      other is LingtingBanner &&
      other.image == image &&
      other.title == title &&
      other.target == target &&
      other.type == type;

  @override
  int get hashCode => Object.hash(image, title, target, type);
}

/// 首页一次要显示的全部内容。
///
/// 灵听的首页是**六个独立接口**（banner / 每日三十首 / 热门 / 推荐歌单 /
/// 推荐歌手 / 推荐视频），这里把它们收成一个不可变对象，页面只 watch 一次。
/// 每个区块都可以是空的：某个接口挂了不该让整页白屏，所以**并行拉、各自兜底**。
@immutable
class LingtingHome {
  const LingtingHome({
    this.banners = const <LingtingBanner>[],
    this.daily = const <LingtingSong>[],
    this.dailyFromTop = false,
    this.hot = const <LingtingSong>[],
    this.sheets = const <LingtingSongSheet>[],
    this.singers = const <LingtingSinger>[],
  });

  static const LingtingHome empty = LingtingHome();

  final List<LingtingBanner> banners;

  /// 每日三十首（拿不到时会退到置顶栏，见 [dailyFromTop]）
  final List<LingtingSong> daily;

  /// [daily] 是不是**置顶栏那条兜底**来的（新歌首发 / 纯音乐）
  ///
  /// 「每日三十首」那个接口对新注册的匿名账号会回 401，既然拿不到就不能
  /// 挂着「每日三十首」的标题去显示别的列表 —— 界面据这个标记换成对应标题。
  final bool dailyFromTop;

  /// 热门歌曲
  final List<LingtingSong> hot;

  final List<LingtingSongSheet> sheets;
  final List<LingtingSinger> singers;

  bool get isEmpty =>
      banners.isEmpty &&
      daily.isEmpty &&
      hot.isEmpty &&
      sheets.isEmpty &&
      singers.isEmpty;

  /// 写进本机缓存用（字段名与 [fromJson] 对齐）
  Map<String, dynamic> toJson() => <String, dynamic>{
    'banners': <Map<String, dynamic>>[
      for (final banner in banners)
        <String, dynamic>{
          'bannerImg': banner.image,
          'bannerTitle': banner.title,
          'bannerUrl': banner.target,
          'type': banner.type,
        },
    ],
    'daily': songsToJson(daily),
    'dailyFromTop': dailyFromTop,
    'hot': songsToJson(hot),
    'sheets': songSheetsToJson(sheets),
    'singers': singersToJson(singers),
  };

  /// 从本机缓存读回来（字段名与 [toJson] 一致）。
  ///
  /// 一份都用不上（key 对不上、JSON 坏了）时给 [empty]，调用方据此「当作没缓存」。
  factory LingtingHome.fromJson(Map<String, dynamic> json) => LingtingHome(
    banners: bannersFromList(json['banners']),
    daily: songsFromList(json['daily']),
    dailyFromTop: json['dailyFromTop'] == true,
    hot: songsFromList(json['hot']),
    sheets: songSheetsFromList(json['sheets']),
    singers: singersFromList(json['singers']),
  );

  /// 只换掉指定的一两块（首页分层加载时逐块并进来用）。
  ///
  /// 传 `null` 表示「这一块不动」—— 所以**不能**用它把某一块清空；
  /// 要与「空」区分开的只有 `dailyFromTop` 那个 bool，它在首页刷新时会跟着重算，
  /// 所以单独给了一个显式参数。
  LingtingHome copyWith({
    List<LingtingBanner>? banners,
    List<LingtingSong>? daily,
    bool? dailyFromTop,
    List<LingtingSong>? hot,
    List<LingtingSongSheet>? sheets,
    List<LingtingSinger>? singers,
  }) => LingtingHome(
    banners: banners ?? this.banners,
    daily: daily ?? this.daily,
    dailyFromTop: dailyFromTop ?? this.dailyFromTop,
    hot: hot ?? this.hot,
    sheets: sheets ?? this.sheets,
    singers: singers ?? this.singers,
  );

  static List<LingtingBanner> _banners(Object? value) => asList(value)
      .whereType<Map<dynamic, dynamic>>()
      .map((item) => LingtingBanner.fromJson(item.cast<String, dynamic>()))
      .where((banner) => banner.image.isNotEmpty)
      .toList(growable: false);

  @override
  bool operator ==(Object other) =>
      other is LingtingHome &&
      listEquals(other.banners, banners) &&
      listEquals(other.daily, daily) &&
      other.dailyFromTop == dailyFromTop &&
      listEquals(other.hot, hot) &&
      listEquals(other.sheets, sheets) &&
      listEquals(other.singers, singers);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(banners),
    Object.hashAll(daily),
    dailyFromTop,
    Object.hashAll(hot),
    Object.hashAll(sheets),
    Object.hashAll(singers),
  );
}

/// 一串 banner（缓存反序列化与首页解析共用）
List<LingtingBanner> bannersFromList(Object? value) =>
    LingtingHome._banners(value);

/// 首页各区块的解析入口（单独抽出来，用例可以直接喂假 JSON）
LingtingHome homeFromResponses({
  Object? banners,
  Object? daily,
  bool dailyFromTop = false,
  Object? hot,
  Object? sheets,
  Object? singers,
}) => LingtingHome(
  banners: LingtingHome._banners(banners),
  daily: songsFromList(daily),
  dailyFromTop: dailyFromTop,
  hot: songsFromList(hot),
  sheets: songSheetsFromList(sheets),
  singers: singersFromList(singers),
);
