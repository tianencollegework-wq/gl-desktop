import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/model/lingting/home.dart';
import '../../data/model/lingting/lyric.dart';
import '../../data/model/lingting/singer.dart';
import '../../data/model/lingting/song.dart';
import '../../data/model/lingting/song_sheet.dart';
import '../../data/repo/lingting_repository.dart';
import 'lingting_player.dart';

/// 灵听的**分层加载**（用户 2026-09-30：「每次要转圈圈大半天很不友好」）。
///
/// 老的做法是「一页一个请求、等最慢的那个」：
/// 首页把五个接口 `Future.wait` 到一起（每日三十首拿不到时还要再串两次兜底请求）、
/// 歌手页把三个接口 `Future.wait` 到一起、歌单页有时还要补一页歌曲 ——
/// 任何一块慢（灵听的接口超时是 12 秒）整页就一直转圈。
///
/// 现在每一页都按同一条规矩来：
///
/// 1. **缓存先出画**：进页面先拿本机存着的那一份（`LingtingRepository.cachedXxx`），
///    有就直接画，不转圈；网络上那份回来了再悄悄盖上去；
/// 2. **一块一块来**：能拆的请求各走各的（首页五块、歌手页三块），回来一块画一块；
/// 3. **只有真的什么都没有**（没缓存 + 一块都没回来）才显示「加载失败 / 重试」。
///
/// 下面两个状态对象就是这套规矩在界面上的样子。

/// 取灵听仓库；起不来（本机存储没初始化、客户端构造失败）就返回 null。
///
/// 正常运行时不会走到 null（`main()` 里先 `await LingtingStore.init()`），但这一条链
/// **一旦在 `build()` 里抛，provider 就进 error 态、整棵树跟着报错**（不是我们要的
/// 「加载失败 + 重试」）。所以统一收成「当作加载失败」。
LingtingRepository? lingtingRepositoryOrNull(Ref ref) {
  try {
    return ref.read(lingtingRepositoryProvider);
  } on Object catch (error) {
    debugPrint('[灵听] 仓库起不来：$error');
    return null;
  }
}

/// 「分层」的通用状态：`value` 是**手上最好的那一份**（缓存或已经回来的网络数据），
/// `pending` 还在路上。
///
/// * `value != null` → 照画内容（**这是常态**：缓存命中，或已经回来一块了）；
/// * `skeleton` → 一块都没回来、还在等：画骨架；
/// * `failed` → 一块都没回来且已经失败：画「加载失败 + 重试」。
@immutable
class LingtingStaged<T> {
  const LingtingStaged({this.value, this.pending = 0, this.failed = false});

  final T? value;
  final int pending;
  final bool failed;

  bool get hasValue => value != null;

  /// 还在等第一块（页面上就是那几行骨架）
  bool get skeleton => pending > 0 && value == null;

  LingtingStaged<T> copyWith({T? value, int? pending, bool? failed}) =>
      LingtingStaged<T>(
        value: value ?? this.value,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
      );
}

/// 首页的五个区块：各自拉、各自出画
enum LingtingHomeSection {
  banners,
  daily,
  hot,
  sheets,
  singers;

  /// 五块全在等（刚进页面时的样子）
  static const Set<LingtingHomeSection> all = <LingtingHomeSection>{
    banners,
    daily,
    hot,
    sheets,
    singers,
  };
}

/// 首页状态：内容 + 「哪几块还在路上」
@immutable
class LingtingHomeState {
  const LingtingHomeState({
    this.home = LingtingHome.empty,
    this.pending = LingtingHomeSection.all,
    this.failed = false,
  });

  final LingtingHome home;

  /// 还在等的区块（空了就是都拉完了）
  final Set<LingtingHomeSection> pending;

  /// 五块一块都没拿到、手上也没有缓存
  final bool failed;

  bool get refreshing => pending.isNotEmpty;

  /// 这一块还在路上吗。
  ///
  /// 页面上的规矩（三块一起看）：**有内容就画内容**（刷新时也照画，不闪骨架）
  /// → 没内容但在等就画骨架 → 没内容也不在等就不画（服务端确实没给这一块）。
  bool isPending(LingtingHomeSection section) => pending.contains(section);

  LingtingHomeState copyWith({
    LingtingHome? home,
    Set<LingtingHomeSection>? pending,
    bool? failed,
  }) => LingtingHomeState(
    home: home ?? this.home,
    pending: pending ?? this.pending,
    failed: failed ?? this.failed,
  );
}

/// 首页控制器：缓存先出画，然后五块各拉各的、回来一块并一块。
///
/// 刻意**不**用 `AsyncNotifier`：那个模型只有「一次 loading → 一份 data」，
/// 而这一页要的是「一块一块地长出来」（见文件顶上的说明）。
class LingtingHomeController extends Notifier<LingtingHomeState> {
  @override
  LingtingHomeState build() {
    final repo = lingtingRepositoryOrNull(ref);
    if (repo == null) {
      return const LingtingHomeState(
        pending: <LingtingHomeSection>{},
        failed: true,
      );
    }
    final cached = repo.cachedHome();
    // 先摆出缓存（有的话），再在后台把五块刷新出来
    unawaited(_refresh(repo));
    return LingtingHomeState(
      home: cached ?? LingtingHome.empty,
      pending: LingtingHomeSection.all,
    );
  }

  /// 下拉刷新 / 失败重试：五块重来一遍（手上那份内容先留着，不闪白屏）
  Future<void> refresh() async {
    final repo = lingtingRepositoryOrNull(ref);
    if (repo == null) {
      state = const LingtingHomeState(
        pending: <LingtingHomeSection>{},
        failed: true,
      );
      return;
    }
    state = state.copyWith(pending: LingtingHomeSection.all, failed: false);
    await _refresh(repo);
  }

  Future<void> _refresh(LingtingRepository repo) =>
      Future.wait<void>(<Future<void>>[
        _load(
          LingtingHomeSection.banners,
          repo.api.homeBanners,
          (home, value) => home.copyWith(banners: value),
          repo,
        ),
        _load(
          LingtingHomeSection.daily,
          repo.api.homeDaily,
          (home, value) =>
              home.copyWith(daily: value.songs, dailyFromTop: value.fromTop),
          repo,
        ),
        _load(
          LingtingHomeSection.hot,
          repo.api.homeHot,
          (home, value) => home.copyWith(hot: value),
          repo,
        ),
        _load(
          LingtingHomeSection.sheets,
          repo.api.homeSheets,
          (home, value) => home.copyWith(sheets: value),
          repo,
        ),
        _load(
          LingtingHomeSection.singers,
          repo.api.homeSingers,
          (home, value) => home.copyWith(singers: value),
          repo,
        ),
      ]);

  /// 拉一块：回来就并进 `home` 并落盘；挂了就只把这一块标成「不在等」。
  ///
  /// 单块失败**不影响别的块**（老行为：一块挂了那一块空着，页面照进）。
  Future<void> _load<T>(
    LingtingHomeSection section,
    Future<T> Function() fetch,
    LingtingHome Function(LingtingHome home, T value) merge,
    LingtingRepository repo,
  ) async {
    T? value;
    try {
      value = await fetch();
    } on Object catch (error) {
      debugPrint('[灵听] 首页 ${section.name} 拉取失败：$error');
    }
    if (!ref.mounted) return;

    final home = value == null ? state.home : merge(state.home, value);
    final pending = <LingtingHomeSection>{...state.pending}..remove(section);
    state = LingtingHomeState(
      home: home,
      pending: pending,
      // 五块都回来了、手上还是空的 —— 这才是真失败（有缓存时不会走到这里）
      failed: pending.isEmpty && home.isEmpty,
    );
    if (value != null) unawaited(repo.saveHome(home));
  }
}

final lingtingHomeProvider =
    NotifierProvider<LingtingHomeController, LingtingHomeState>(
      LingtingHomeController.new,
    );

/// 歌单详情（内嵌第一页歌曲；页面上「播放全部」直接用这份）
///
/// 缓存先出画 → 详情回来换成完整那份（标题/封面/数量/第一页歌）→
/// 详情里一首歌都没内嵌但总数不为零时再补一页（服务端分页口径，逐块补上）。
class LingtingSheetController
    extends Notifier<LingtingStaged<LingtingSongSheet>> {
  LingtingSheetController(this.sheetId);

  /// 歌单 id（family 参数）
  final int sheetId;

  @override
  LingtingStaged<LingtingSongSheet> build() {
    final repo = lingtingRepositoryOrNull(ref);
    if (repo == null) {
      return const LingtingStaged<LingtingSongSheet>(failed: true);
    }
    unawaited(_load(repo));
    return LingtingStaged<LingtingSongSheet>(
      value: repo.cachedSheet(sheetId),
      pending: 1,
    );
  }

  Future<void> refresh() async {
    final repo = lingtingRepositoryOrNull(ref);
    if (repo == null) {
      state = const LingtingStaged<LingtingSongSheet>(failed: true);
      return;
    }
    state = state.copyWith(pending: 1, failed: false);
    await _load(repo);
  }

  Future<void> _load(LingtingRepository repo) async {
    LingtingSongSheet? sheet;
    try {
      sheet = await repo.guarded(() => repo.api.sheetDetail(sheetId));
    } on Object catch (error) {
      debugPrint('[灵听] 歌单 $sheetId 拉取失败：$error');
    }
    if (!ref.mounted) return;
    _emit(sheet: sheet, pending: 0);

    if (sheet == null || sheet.songs.isNotEmpty || sheet.songCount <= 0) return;
    // 详情里一首都没内嵌：再补一页（这一块慢就慢，界面已经有标题了）
    try {
      final songs = await repo.guarded(() => repo.api.sheetSongs(sheetId));
      if (!ref.mounted) return;
      _emit(sheet: sheet.copyWith(songs: songs), pending: 0);
    } on Object catch (error) {
      debugPrint('[灵听] 歌单 $sheetId 补歌曲失败：$error');
    }
  }

  void _emit({LingtingSongSheet? sheet, required int pending}) {
    final value = sheet ?? state.value;
    state = LingtingStaged<LingtingSongSheet>(
      value: value,
      pending: pending,
      failed: value == null,
    );
    if (sheet != null) {
      unawaited(ref.read(lingtingRepositoryProvider).saveSheet(sheet));
    }
  }
}

final lingtingSheetProvider = NotifierProvider.autoDispose
    .family<LingtingSheetController, LingtingStaged<LingtingSongSheet>, int>(
      LingtingSheetController.new,
    );

/// 歌手页要的三样：资料 + 热门歌曲 + 专辑（三块各拉各的）
@immutable
class LingtingSingerView {
  const LingtingSingerView({
    this.singer,
    this.songs = const <LingtingSong>[],
    this.albums = const <LingtingAlbum>[],
  });

  static const LingtingSingerView empty = LingtingSingerView();

  final LingtingSinger? singer;
  final List<LingtingSong> songs;
  final List<LingtingAlbum> albums;

  bool get isEmpty => singer == null && songs.isEmpty && albums.isEmpty;

  LingtingSingerView copyWith({
    LingtingSinger? singer,
    List<LingtingSong>? songs,
    List<LingtingAlbum>? albums,
  }) => LingtingSingerView(
    singer: singer ?? this.singer,
    songs: songs ?? this.songs,
    albums: albums ?? this.albums,
  );
}

class LingtingSingerController
    extends Notifier<LingtingStaged<LingtingSingerView>> {
  LingtingSingerController(this.singerId);

  final int singerId;

  /// 三块都要等
  static const int _sections = 3;

  @override
  LingtingStaged<LingtingSingerView> build() {
    final repo = lingtingRepositoryOrNull(ref);
    if (repo == null) {
      return const LingtingStaged<LingtingSingerView>(failed: true);
    }
    unawaited(_load(repo));
    final cached = _cachedOf(repo);
    return LingtingStaged<LingtingSingerView>(
      value: cached.isEmpty ? null : cached,
      pending: _sections,
    );
  }

  Future<void> refresh() async {
    final repo = lingtingRepositoryOrNull(ref);
    if (repo == null) {
      state = const LingtingStaged<LingtingSingerView>(failed: true);
      return;
    }
    state = state.copyWith(pending: _sections, failed: false);
    await _load(repo);
  }

  LingtingSingerView _cachedOf(LingtingRepository repo) => LingtingSingerView(
    singer: repo.cachedSinger(singerId),
    songs: repo.cachedSingerSongs(singerId),
    albums: repo.cachedSingerAlbums(singerId),
  );

  Future<void> _load(LingtingRepository repo) =>
      Future.wait<void>(<Future<void>>[
        _piece(
          () => repo.guarded(() => repo.api.singerDetail(singerId)),
          (view, singer) => view.copyWith(singer: singer),
          (singer) => repo.saveSinger(singerId, singer),
          '资料',
        ),
        _piece(
          () => repo.guarded(() => repo.api.singerSongs(singerId)),
          (view, songs) => view.copyWith(songs: songs),
          (songs) => repo.saveSingerSongs(singerId, songs),
          '歌曲',
        ),
        _piece(
          () => repo.guarded(() => repo.api.singerAlbums(singerId)),
          (view, albums) => view.copyWith(albums: albums),
          (albums) => repo.saveSingerAlbums(singerId, albums),
          '专辑',
        ),
      ]);

  /// 拉一块：回来就并进视图并落盘（**当场出画**），挂了算这一块没有
  Future<void> _piece<T>(
    Future<T> Function() fetch,
    LingtingSingerView Function(LingtingSingerView view, T value) merge,
    Future<void> Function(T value) save,
    String label,
  ) async {
    T? value;
    try {
      value = await fetch();
    } on Object catch (error) {
      debugPrint('[灵听] 歌手 $singerId $label 拉取失败：$error');
    }
    if (!ref.mounted) return;

    final current = state.value ?? LingtingSingerView.empty;
    final next = value == null ? current : merge(current, value);
    final pending = state.pending > 0 ? state.pending - 1 : 0;
    state = LingtingStaged<LingtingSingerView>(
      value: next.isEmpty ? null : next,
      pending: pending,
      failed: pending == 0 && next.isEmpty,
    );
    if (value != null) unawaited(save(value));
  }
}

final lingtingSingerProvider = NotifierProvider.autoDispose
    .family<LingtingSingerController, LingtingStaged<LingtingSingerView>, int>(
      LingtingSingerController.new,
    );

/// 专辑详情
class LingtingAlbumController extends Notifier<LingtingStaged<LingtingAlbum>> {
  LingtingAlbumController(this.albumId);

  final int albumId;

  @override
  LingtingStaged<LingtingAlbum> build() {
    final repo = lingtingRepositoryOrNull(ref);
    if (repo == null) return const LingtingStaged<LingtingAlbum>(failed: true);
    unawaited(_load(repo));
    return LingtingStaged<LingtingAlbum>(
      value: repo.cachedAlbum(albumId),
      pending: 1,
    );
  }

  Future<void> refresh() async {
    final repo = lingtingRepositoryOrNull(ref);
    if (repo == null) {
      state = const LingtingStaged<LingtingAlbum>(failed: true);
      return;
    }
    state = state.copyWith(pending: 1, failed: false);
    await _load(repo);
  }

  Future<void> _load(LingtingRepository repo) async {
    LingtingAlbum? album;
    try {
      album = await repo.guarded(() => repo.api.albumDetail(albumId));
    } on Object catch (error) {
      debugPrint('[灵听] 专辑 $albumId 拉取失败：$error');
    }
    if (!ref.mounted) return;
    final value = album ?? state.value;
    state = LingtingStaged<LingtingAlbum>(
      value: value,
      pending: 0,
      failed: value == null,
    );
    if (album != null) unawaited(repo.saveAlbum(album));
  }
}

final lingtingAlbumProvider = NotifierProvider.autoDispose
    .family<LingtingAlbumController, LingtingStaged<LingtingAlbum>, int>(
      LingtingAlbumController.new,
    );

/// 这首歌的资料「不全」吗（缺歌手 id / 专辑 id）—— 播放页靠它决定要不要补详情。
///
/// 聊天里点卡片进来的那首就是这种情况：卡片的 payload 只带
/// 歌名/歌手/封面/音频地址（见 `lingting_card.dart`），`singerId`/`albumId`
/// 都是 0，「更多」里的查看歌手 / 查看专辑就成了灰的。
/// 列表/搜索点进来的歌本来就带着这两个 id，**不会**白跑一趟详情接口。
bool needsLingtingSongDetail(LingtingSong song) =>
    song.songId > 0 && song.singerId <= 0 && song.albumId <= 0;

/// 播放页要的「完整的那首歌」：按 songId 去详情接口补一次。
///
/// 详情接口给的东西比卡片多（`singerId`/`albumId`/专辑名/时长……），补完之后
/// 播放页的歌手行、专辑行与「更多」里的查看歌手 / 查看专辑就都活过来了。
/// 拿不到（断网、记录不全）就用卡片那份，页面不会因此报错。
final lingtingSongDetailProvider = FutureProvider.autoDispose
    .family<LingtingSong, int>((ref, songId) async {
      final repo = ref.watch(lingtingRepositoryProvider);
      // 走 guarded：会话丢了先重新匿名登录一次，与其它灵听请求同一套处理
      return repo.guarded(() => repo.api.songDetail(songId));
    });

/// 当前这首的歌词。**两段式**：
///
/// 1. 先给**手上现成的**那一份（列表/搜索接口自带的 `lyric` 纯文本，按 `;` 拆好行）
///    —— 进播放页立刻有字，不为了等一次网络请求而转圈；
/// 2. 再在后台去要 `.lrc`（**有时间轴**、且往往是完整歌词），拿到就换成它，
///    于是当前行高亮、自动滚到中间那一套才生效。
///
/// **只 `select` 歌曲 id**，不看整个播放状态 —— 这一条是踩过坑的：播放器的
/// `position` 每来一帧就会变一次（`just_audio` 的 `positionStream`），
/// 如果直接 `ref.watch(lingtingPlayerProvider)`，歌词 provider 会被每秒重建好几次，
/// 界面就在「歌词」和「转圈」之间闪，观感上就是**歌词根本不显示**。
///
/// 切歌照样会重算（id 变了），歌词仓库里还有一层按歌曲 id 的缓存
/// （含「只问一次 .lrc」的记忆），来回切不会重复下载。
class LingtingLyricController extends AsyncNotifier<LingtingLyric> {
  @override
  Future<LingtingLyric> build() async {
    final song = ref.watch(
      lingtingPlayerProvider.select((state) => state.current),
    );
    if (song == null) return LingtingLyric.empty;
    final repo = ref.read(lingtingRepositoryProvider);
    final quick = await repo.quickLyric(song);
    // 手上这份没有时间轴 → 后台要 `.lrc`（不阻塞上面那份的显示）
    if (!quick.hasTimeline) unawaited(_upgrade(song, repo));
    return quick;
  }

  /// 后台升级：拿到时间轴就替换状态；期间界面一直显示着第一段那份
  Future<void> _upgrade(LingtingSong song, LingtingRepository repo) async {
    final full = await repo.timelineLyric(song);
    if (!ref.mounted || !full.hasTimeline) return;
    // 这一轮已经切歌了 → 丢掉（否则会把上一首的歌词贴到新歌上）
    final current = ref.read(lingtingPlayerProvider).current;
    if (current == null || current.songId != song.songId) return;
    state = AsyncValue<LingtingLyric>.data(full);
  }
}

final lingtingLyricProvider =
    AsyncNotifierProvider.autoDispose<LingtingLyricController, LingtingLyric>(
      LingtingLyricController.new,
    );
