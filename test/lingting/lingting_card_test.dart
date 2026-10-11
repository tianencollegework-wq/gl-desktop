import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/lingting/lingting_card.dart';
import 'package:gracelinkim/domain/lingting/lingting_providers.dart';

/// 音乐卡片（`type == 'lingting'`）：发送时怎么装进 `extends`、收到后怎么读回来。
///
/// 这一层是纯逻辑，钉住三件事：
/// 1. 卡片带全了播放要用的四个字段（**不依赖联网**就能起播）；
/// 2. 读回来时字段少一个也别崩（别的端将来发的方式可能不一样）；
/// 3. 会话列表/通知里那行字是「[音乐] 《歌名》- 歌手」。
void main() {
  const song = LingtingSong(
    songId: 236,
    name: '一粒麦子',
    singerName: '小羊诗歌',
    singerId: 88,
    albumName: '一粒麦子',
    albumId: 4229,
    cover: 'https://x/cover.jpg',
    audioUrl: 'https://x/236.mp3',
  );

  String notFound(String key) => key;

  group('从歌到卡片', () {
    test('播放要用的字段都带上，content 是「[音乐] 《歌名》- 歌手」', () {
      final card = MusicCard.fromSong(song);
      expect(card.toExt(), <String, dynamic>{
        'songId': 236,
        'name': '一粒麦子',
        'singer': '小羊诗歌',
        // 歌手/专辑的 id 也带上：播放页「更多」里的查看歌手 / 查看专辑指着它们
        // （2026-09-25 之前发的老卡片没有这两项，播放页会按 songId 补一次详情）
        'singerId': 88,
        'album': '一粒麦子',
        'albumId': 4229,
        'cover': 'https://x/cover.jpg',
        'audioUrl': 'https://x/236.mp3',
      });
      expect(
        card.content((key) => key == 'common.music' ? '音乐' : key),
        '[音乐] 《一粒麦子》- 小羊诗歌',
      );
      expect(card.playable, isTrue);
    });

    test('没有歌手就只给书名号里的歌名', () {
      const noSinger = LingtingSong(songId: 1, name: '云上太阳');
      expect(MusicCard.fromSong(noSinger).displayTitle, '《云上太阳》');
    });

    test('没有音频地址 → playable 为 false（点卡片时只提示，不跳空播放页）', () {
      const broken = LingtingSong(songId: 9, name: '裸记录');
      expect(MusicCard.fromSong(broken).playable, isFalse);
    });
  });

  group('从消息读回卡片', () {
    Message message({
      Map<String, dynamic> ext = const <String, dynamic>{},
      Map<String, dynamic> extra = const <String, dynamic>{},
      String content = '',
    }) => Message(
      serverId: 1,
      msgId: 'm1',
      conversationId: 'u2',
      fromUserId: 'u2',
      type: lingtingMessageType,
      content: content,
      sendTime: 1000,
      ext: ext,
      extra: extra,
    );

    test('extends 里的字段能还原成一首可播的歌（含歌手/专辑 id）', () {
      final card = musicCardOf(message(ext: MusicCard.fromSong(song).toExt()));
      expect(card.songId, 236);
      expect(card.name, '一粒麦子');
      expect(card.singer, '小羊诗歌');
      expect(card.singerId, 88);
      expect(card.album, '一粒麦子');
      expect(card.albumId, 4229);
      expect(card.playable, isTrue);

      final back = card.toSong();
      expect(back.songId, 236);
      expect(back.singerName, '小羊诗歌');
      expect(back.singerId, 88);
      expect(back.albumName, '一粒麦子');
      expect(back.albumId, 4229);
      expect(back.subtitle, '小羊诗歌 - 一粒麦子');
      expect(back.audioUrl, 'https://x/236.mp3');
      expect(back.playable, isTrue);
    });

    test('老卡片（没有歌手/专辑 id）读回来是 0 —— 播放页据此去补详情', () {
      final card = musicCardOf(
        message(
          ext: const <String, dynamic>{
            'songId': 236,
            'name': '一粒麦子',
            'singer': '小羊诗歌',
            'cover': 'https://x/cover.jpg',
            'audioUrl': 'https://x/236.mp3',
          },
        ),
      );
      expect(card.singerId, 0);
      expect(card.albumId, 0);
      expect(card.playable, isTrue, reason: '照样能播，只是没有歌手/专辑页可去');
    });

    test('字段跑到消息顶层（extra）也认', () {
      final card = musicCardOf(
        message(
          extra: const <String, dynamic>{
            'songId': 7,
            'name': '通往祢的路',
            'audioUrl': 'https://x/7.mp3',
          },
        ),
      );
      expect(card.songId, 7);
      expect(card.name, '通往祢的路');
      expect(card.playable, isTrue);
    });

    test('什么都没有 → 空卡片，不会抛异常', () {
      final card = musicCardOf(message());
      expect(card.isEmpty, isTrue);
      expect(card.playable, isFalse);
      expect(card.displayTitle, '《》');
    });
  });

  group('资料不全的才去补详情', () {
    test('老卡片进来的（没歌手/专辑 id）要补；列表进来的（带 id）不补', () {
      const fromCard = LingtingSong(
        songId: 236,
        name: '一粒麦子',
        singerName: '小羊诗歌',
        audioUrl: 'https://x/236.mp3',
      );
      expect(needsLingtingSongDetail(fromCard), isTrue);
      expect(needsLingtingSongDetail(song), isFalse);
      // 没歌（空状态）也不该白跑一趟接口
      expect(needsLingtingSongDetail(LingtingSong.none), isFalse);
    });
  });

  test('类型常量就是服务端要存的那个字符串', () {
    // 服务端不校验 type 白名单、原样入库，所以这个字符串**不能随便改**：
    // 改了以后老消息（历史上发出去的那些）就认不出来了。
    expect(lingtingMessageType, 'lingting');
    expect(notFound('common.music'), 'common.music');
  });
}
