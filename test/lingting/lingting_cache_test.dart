import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/data/model/lingting/home.dart';
import 'package:gracelinkim/data/model/lingting/singer.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/model/lingting/song_sheet.dart';
import 'package:gracelinkim/data/repo/lingting_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_lingting.dart';

/// 灵听的本机内容缓存（S12.1）。
///
/// 「分层加载」的前半段就靠它：进页面先拿本机存着的那份立刻出画。存的是 JSON，
/// 所以要钉两件事 —— ①模型能原样转一圈回来（不然第二次进来画面就缺胳膊少腿）；
/// ②坏数据不能把页面弄崩（当作没缓存）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LingtingStore store;
  late FakeLingtingApi api;
  late FakeLingtingRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = await LingtingStore.init();
    api = FakeLingtingApi();
    repository = FakeLingtingRepository(api);
  });

  group('模型转一圈', () {
    test('一首歌：id / 名字 / 歌手 / 专辑 / 封面 / 直链 / 歌词都不丢', () {
      const song = LingtingSong(
        songId: 27,
        name: '一粒麦子',
        singerName: '小羊诗歌',
        singerId: 3,
        albumName: '我愿意',
        albumId: 9,
        cover: 'https://x/c.jpg',
        audioUrl: 'https://x/27.mp3',
        videoId: 5,
        rawLyric: 'https://x/27.lrc',
      );
      expect(LingtingSong.fromJson(song.toJson()), song);
    });

    test('歌单 / 歌手 / 专辑：连同内嵌的歌曲一起原样回来', () {
      final song = fakeSong(1);
      final sheet = LingtingSongSheet(
        sheetId: 122244,
        name: '流淌着生命河流',
        cover: 'https://x/s.jpg',
        description: '说明',
        authorId: 7,
        authorName: '某某',
        authorAvatar: 'https://x/a.jpg',
        songCount: 20,
        playCount: 300,
        songs: <LingtingSong>[song],
      );
      final singer = LingtingSinger(
        singerId: 3,
        name: '小羊诗歌',
        avatar: 'https://x/av.jpg',
        background: 'https://x/bg.jpg',
        followed: true,
        fans: 1200,
        songCount: 88,
      );
      final album = LingtingAlbum(
        albumId: 9,
        name: '我愿意',
        cover: 'https://x/ac.jpg',
        singerId: 3,
        singerName: '小羊诗歌',
        singerAvatar: 'https://x/av.jpg',
        songCount: 12,
        playCount: 900,
        songs: <LingtingSong>[song],
      );

      expect(LingtingSongSheet.fromJson(sheet.toJson()).songs, <LingtingSong>[
        song,
      ]);
      expect(LingtingSongSheet.fromJson(sheet.toJson()).songCount, 20);
      expect(LingtingSinger.fromJson(singer.toJson()).fans, 1200);
      expect(LingtingSinger.fromJson(singer.toJson()).followed, isTrue);
      expect(LingtingAlbum.fromJson(album.toJson()).songs, <LingtingSong>[
        song,
      ]);
      expect(LingtingAlbum.fromJson(album.toJson()).singerName, '小羊诗歌');
    });

    test('首页一整份：五块 + 「每日三十首是兜底来的」那个标记都在', () {
      final home = homeFromResponses(
        banners: <Object>[
          <String, dynamic>{
            'bannerImg': 'https://x/b.jpg',
            'bannerTitle': '新歌',
            'bannerUrl': '27',
            'type': 1,
          },
        ],
        daily: <Object>[fakeSong(1).toJson()],
        dailyFromTop: true,
        hot: <Object>[fakeSong(2).toJson()],
        sheets: <Object>[
          <String, dynamic>{'songSheetId': 5, 'songSheetName': '歌单'},
        ],
        singers: <Object>[
          <String, dynamic>{'singerId': 3, 'singerName': '小羊诗歌'},
        ],
      );

      final back = LingtingHome.fromJson(home.toJson());
      expect(back, home);
      expect(back.dailyFromTop, isTrue);
      expect(back.banners.single.songId, 27);
      expect(back.singers.single.name, '小羊诗歌');
    });

    test('解析不出来的一律当作「没有缓存」', () {
      expect(LingtingHome.fromJson(<String, dynamic>{}).isEmpty, isTrue);
      expect(LingtingSinger.fromJson(<String, dynamic>{}).isEmpty, isTrue);
      expect(LingtingAlbum.fromJson(<String, dynamic>{}).isEmpty, isTrue);
      expect(LingtingSongSheet.fromJson(<String, dynamic>{}).isEmpty, isTrue);
    });
  });

  group('本机缓存', () {
    test('写进去能读回来，也记得是什么时候写的', () async {
      expect(store.cacheRead('x'), isNull);
      expect(store.cacheTime('x'), isNull);

      await store.cacheWrite('x', <String, dynamic>{'a': 1});
      expect(store.cacheRead('x'), <String, dynamic>{'a': 1});
      expect(store.cacheTime('x'), isNotNull);

      // 再写一次是覆盖，不是追加
      await store.cacheWrite('x', <String, dynamic>{'a': 2});
      expect(store.cacheRead('x'), <String, dynamic>{'a': 2});

      await store.cacheRemove('x');
      expect(store.cacheRead('x'), isNull);
    });

    test('清空之后一个都不剩', () async {
      await store.cacheWrite('x', 1);
      await store.cacheWrite('y', 2);
      await store.cacheClear();
      expect(store.cacheRead('x'), isNull);
      expect(store.cacheRead('y'), isNull);
    });

    test('缓存内容是一团坏 JSON 时当作没有（不抛给页面）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        LingtingStore.keyCache: '这不是 JSON',
      });
      store = await LingtingStore.init();
      expect(store.cacheRead('x'), isNull);
    });
  });

  group('仓库层', () {
    test('首页：存一份 → 冷启动读得回来（五块一起）', () async {
      expect(repository.cachedHome(), isNull);

      final home = LingtingHome(daily: <LingtingSong>[fakeSong(1)]);
      await repository.saveHome(home);
      expect(repository.cachedHome(), home);
    });

    test('歌单 / 歌手 / 专辑各存各的（歌手那三块分三条键）', () async {
      await repository.saveSheet(
        LingtingSongSheet(
          sheetId: 5,
          name: '歌单',
          songs: <LingtingSong>[fakeSong(1)],
        ),
      );
      await repository.saveSinger(3, LingtingSinger(singerId: 3, name: '小羊诗歌'));
      await repository.saveSingerSongs(3, <LingtingSong>[fakeSong(2)]);
      await repository.saveSingerAlbums(3, <LingtingAlbum>[
        LingtingAlbum(albumId: 9, name: '我愿意'),
      ]);
      await repository.saveAlbum(LingtingAlbum(albumId: 9, name: '我愿意'));

      expect(repository.cachedSheet(5)?.name, '歌单');
      expect(repository.cachedSheet(6), isNull);
      expect(repository.cachedSinger(3)?.name, '小羊诗歌');
      expect(repository.cachedSingerSongs(3).single.songId, 2);
      expect(repository.cachedSingerAlbums(3).single.name, '我愿意');
      expect(repository.cachedAlbum(9)?.name, '我愿意');
    });

    test('空的那一份不往缓存里存（省得下次进来拿一个空壳）', () async {
      await repository.saveSheet(LingtingSongSheet.none);
      await repository.saveSinger(3, LingtingSinger.none);
      await repository.saveAlbum(LingtingAlbum.none);
      await repository.saveSingerSongs(3, const <LingtingSong>[]);
      await repository.saveSingerAlbums(3, const <LingtingAlbum>[]);
      await repository.saveHome(LingtingHome.empty);

      expect(repository.cachedSheet(0), isNull);
      expect(repository.cachedSinger(3), isNull);
      expect(repository.cachedAlbum(0), isNull);
      expect(repository.cachedSingerSongs(3), isEmpty);
      expect(repository.cachedSingerAlbums(3), isEmpty);
      expect(repository.cachedHome(), isNull);
    });

    test('缓存坏了也不崩：拿不出可用的一份就当没有', () async {
      // 值根本不是一个对象（这里塞了一个数组）→ 直接当没有
      await store.cacheWrite(LingtingRepository.albumCacheKey(9), <Object>[
        1,
        2,
      ]);
      expect(repository.cachedAlbum(9), isNull);
      // 对象里字段是乱的：不抛给页面（解析出来是个空壳 → 也算没有）
      await store.cacheWrite(
        LingtingRepository.sheetCacheKey(5),
        <String, dynamic>{'songSheetId': '不是数字', 'songSheetName': ''},
      );
      expect(repository.cachedSheet(5), isNull);
    });
  });
}
