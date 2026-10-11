import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/lingting/home.dart';
import 'package:gracelinkim/data/model/lingting/search.dart';
import 'package:gracelinkim/data/model/lingting/singer.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/model/lingting/song_sheet.dart';

/// 这些 JSON 都是**实测回来的原样**（2026-09-23 打真接口抄的），
/// 字段名一个都不许改 —— 改了就等于把「服务端改字段」这种问题放到真机上才炸。
void main() {
  group('歌曲', () {
    final json = <String, dynamic>{
      'songId': 236,
      'songName': '一粒麦子',
      'singerName': '小羊诗歌',
      'singerId': 41,
      'categoryId': null,
      'albumName': '一粒麦子',
      'albumId': 126,
      'songCoverImage': 'https://resource.lingtingmusic.com/album/一粒麦子.jpg',
      'like': false,
      'audioLink': 'https://resource.lingtingmusic.com/music/voice/x.mp3',
      'videoId': null,
      'lyric': null,
      'isDownload': null,
    };

    test('解析常用字段', () {
      final song = LingtingSong.fromJson(json);
      expect(song.songId, 236);
      expect(song.name, '一粒麦子');
      expect(song.singerName, '小羊诗歌');
      expect(song.albumName, '一粒麦子');
      expect(song.playable, isTrue);
      expect(song.subtitle, '小羊诗歌 - 一粒麦子');
    });

    test('没有专辑时副标题只剩歌手', () {
      final song = LingtingSong.fromJson(<String, dynamic>{
        ...json,
        'albumName': null,
      });
      expect(song.subtitle, '小羊诗歌');
    });

    // 搜索结果里 `<title>` 被服务端标成 `[一粒][麦子]`（命中哪几个词就包哪几个），
    // 繁体那首还按字拆成 `[一粒][麥][子]`；详情与首页列表都是干净的。
    // 这层标记不能在界面上出现（真机上搜什么歌名都带一堆方括号）。
    test('搜索命中标记 [] 不进模型（歌名/歌手/专辑都去）', () {
      final song = LingtingSong.fromJson(<String, dynamic>{
        ...json,
        'songName': '[一粒][麦子]',
        'singerName': '[小羊][诗歌]',
        'albumName': '[一粒][麦子]（伴奏）',
      });
      expect(song.name, '一粒麦子');
      expect(song.singerName, '小羊诗歌');
      expect(song.albumName, '一粒麦子（伴奏）');
      expect(song.subtitle, '小羊诗歌 - 一粒麦子（伴奏）');
    });

    test('缺 audioLink → 不能播（不进队列）', () {
      final song = LingtingSong.fromJson(<String, dynamic>{
        ...json,
        'audioLink': null,
      });
      expect(song.playable, isFalse);
    });

    test('列表解析会丢掉没有音频地址的裸记录', () {
      final songs = songsFromList(<Object>[
        json,
        <String, dynamic>{'songId': 1, 'songName': '裸记录'},
      ], playableOnly: true);
      expect(songs.length, 1);
      expect(songs.single.songId, 236);
    });

    test('sameSongAs 只认「同一个 id + 同一份音频地址」', () {
      final song = LingtingSong.fromJson(json);
      expect(song.sameSongAs(LingtingSong.fromJson(json)), isTrue);
      expect(
        song.sameSongAs(
          const LingtingSong(
            songId: 236,
            name: '一粒麦子',
            audioUrl: 'https://x/别的.mp3',
          ),
        ),
        isFalse,
        reason: 'id 相同但音频地址不同 → 不是同一份资源，不该当成正在播的那首',
      );
      expect(
        song.sameSongAs(
          const LingtingSong(
            songId: 237,
            name: '另一首',
            audioUrl: 'https://x/1.mp3',
          ),
        ),
        isFalse,
      );
    });
  });

  group('首页聚合', () {
    test('没有任何数据时是 empty（页面据此显示「失败/重试」而不是白屏）', () {
      expect(homeFromResponses().isEmpty, isTrue);
    });

    test('兜底来的那一块会带上 dailyFromTop 标记（标题不能冒充「每日三十首」）', () {
      final song = <String, dynamic>{
        'songId': 274021,
        'songName': '句句祷告',
        'singerName': 'x',
        'audioLink': 'https://x/274021.mp3',
      };
      final fallback = homeFromResponses(
        daily: <Object>[song],
        dailyFromTop: true,
      );
      expect(fallback.daily.single.songId, 274021);
      expect(fallback.dailyFromTop, isTrue);

      final normal = homeFromResponses(daily: <Object>[song]);
      expect(normal.dailyFromTop, isFalse);
      expect(fallback == normal, isFalse, reason: '标记不同就不是同一份首页数据');
    });
  });

  group('歌单', () {
    test('列表项（推荐歌单）：数量是 null 时不显示「0 首」', () {
      final sheet = LingtingSongSheet.fromJson(<String, dynamic>{
        'songSheetId': 122244,
        'songSheetName': '流淌着生命河流',
        'songSheetCoverImage':
            'https://resource.lingtingmusic.com/song-sheet/x.jpg',
        'songCount': null,
      });
      expect(sheet.sheetId, 122244);
      expect(sheet.songCount, 0);
      expect(sheet.countLabel, '');
    });

    test('详情：作者与内嵌歌曲列表', () {
      final sheet = LingtingSongSheet.fromJson(<String, dynamic>{
        'songSheetId': 122244,
        'songSheetName': '流淌着生命河流',
        'singerName': 'shirley',
        'singerId': 1181560,
        'playCount': 572,
        'songCount': 20,
        'songList': <Object>[
          <String, dynamic>{
            'songId': 274040,
            'songName': '来',
            'singerName': '小羊诗歌',
            'audioLink': 'https://x/1.mp3',
          },
        ],
      });
      expect(sheet.authorName, 'shirley');
      expect(sheet.authorId, 1181560);
      expect(sheet.playCount, 572);
      expect(sheet.songCount, 20);
      expect(sheet.countLabel, '20');
      expect(sheet.songs.single.name, '来');
    });
  });

  group('歌手 / 专辑', () {
    test('歌手列表项', () {
      final singer = LingtingSinger.fromJson(<String, dynamic>{
        'singerId': 31,
        'singerName': '赞美之泉',
        'avatar': 'https://x/a.jpg',
        'follow': null,
        'nameSort': 'Z',
      });
      expect(singer.name, '赞美之泉');
      expect(singer.followed, isFalse);
    });

    test('歌手详情（背景图 + 粉丝数）', () {
      final singer = LingtingSinger.fromJson(<String, dynamic>{
        'singerId': 31,
        'singerName': '赞美之泉',
        'bgImg': 'https://x/bg.jpg',
        'fans': 25722,
      });
      expect(singer.background, 'https://x/bg.jpg');
      expect(singer.fans, 25722);
    });

    test('专辑详情（封面 + 歌曲列表）', () {
      final album = LingtingAlbum.fromJson(<String, dynamic>{
        'albumId': 3,
        'albumName': '坚定-e麦合唱团',
        'albumCoverImage': 'https://x/c.jpg',
        'singerId': 70,
        'singerName': 'e麦合唱团',
        'songCount': 10,
        'playCount': 45,
        'songList': <Object>[
          <String, dynamic>{
            'songId': 25,
            'songName': '祢的出現',
            'audioLink': 'https://x/25.mp3',
          },
        ],
      });
      expect(album.name, '坚定-e麦合唱团');
      expect(album.singerName, 'e麦合唱团');
      expect(album.songs.single.songId, 25);
    });
  });

  group('首页', () {
    test('banner 的 bannerUrl 是歌曲 id（数字串）', () {
      final banner = LingtingBanner.fromJson(<String, dynamic>{
        'bannerImg': 'https://x/banner.jpg',
        'bannerUrl': '240',
        'bannerTitle': '通往祢的路',
        'type': 1,
      });
      expect(banner.songId, 240);
      expect(banner.title, '通往祢的路');
    });

    test('target 不是数字（外链）时不认成歌曲 id', () {
      final banner = LingtingBanner.fromJson(<String, dynamic>{
        'bannerImg': 'https://x/banner.jpg',
        'bannerUrl': 'https://x/page',
        'type': 1,
      });
      expect(banner.songId, 0);
    });

    test('少一个接口（null）只让那一块空着，别的照常', () {
      final home = homeFromResponses(
        banners: null,
        daily: <Object>[
          <String, dynamic>{
            'songId': 1,
            'songName': 'a',
            'audioLink': 'https://x/1.mp3',
          },
        ],
        hot: null,
        sheets: null,
        singers: null,
      );
      expect(home.banners, isEmpty);
      expect(home.daily.length, 1);
      expect(home.hot, isEmpty);
      expect(home.isEmpty, isFalse);
    });

    test('全空 → isEmpty（首页据此显示「加载失败 + 重试」而不是白屏）', () {
      expect(homeFromResponses().isEmpty, isTrue);
    });

    test('没有图片地址的 banner 丢掉', () {
      final home = homeFromResponses(
        banners: <Object>[
          <String, dynamic>{'bannerImg': '', 'bannerUrl': '1'},
        ],
      );
      expect(home.banners, isEmpty);
    });
  });

  group('搜索', () {
    test('单曲接口：列表 + counts + 回显关键词', () {
      final result = LingtingSearchResult.fromMusic(<String, dynamic>{
        'songList': <Object>[
          <String, dynamic>{
            'songId': 23379,
            'songName': '[恩典]',
            'singerName': '起初音乐',
            'audioLink': 'https://x/23379.mp3',
          },
        ],
        'counts': 128,
        'keyword': '恩典',
        'tkeyword': '恩典',
      });
      expect(result.songs.length, 1);
      expect(result.songCount, 128);
      expect(result.keyword, '恩典');
    });

    test('合并三个接口的结果', () {
      final music = LingtingSearchResult.fromMusic(<String, dynamic>{
        'songList': <Object>[
          <String, dynamic>{
            'songId': 1,
            'songName': 'a',
            'audioLink': 'https://x/1.mp3',
          },
        ],
        'counts': 1,
      });
      final singer = LingtingSearchResult.fromSinger(<String, dynamic>{
        'singerList': <Object>[
          <String, dynamic>{'singerId': 31, 'singerName': '赞美之泉'},
        ],
        'counts': 1,
      });
      final sheet = LingtingSearchResult.fromSheet(<String, dynamic>{
        'songSheetList': <Object>[
          <String, dynamic>{'songSheetId': 122244, 'songSheetName': '流淌着生命河流'},
        ],
        'counts': 1,
      });
      final merged = LingtingSearchResult.merge(music, singer, sheet);
      expect(merged.songs.length, 1);
      expect(merged.singers.single.name, '赞美之泉');
      expect(merged.sheets.single.name, '流淌着生命河流');
      expect(searchTabsOf(merged), <LingtingSearchTab>[
        LingtingSearchTab.song,
        LingtingSearchTab.singer,
        LingtingSearchTab.sheet,
      ]);
    });

    test('没结果的 tab 不出现（比如只搜到歌手）', () {
      final result = LingtingSearchResult.merge(
        LingtingSearchResult.empty,
        LingtingSearchResult.fromSinger(<String, dynamic>{
          'singerList': <Object>[
            <String, dynamic>{'singerId': 31, 'singerName': '赞美之泉'},
          ],
        }),
        LingtingSearchResult.empty,
      );
      expect(searchTabsOf(result), <LingtingSearchTab>[
        LingtingSearchTab.singer,
      ]);
    });

    test('三个接口都空 → 一个 tab 都没有（页面显示「没有找到相关内容」）', () {
      expect(searchTabsOf(LingtingSearchResult.empty), isEmpty);
    });
  });
}
