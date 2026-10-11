import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/store/lingting_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/model/lingting/search.dart';
import '../../data/model/lingting/singer.dart';
import '../../data/model/lingting/song_sheet.dart';
import '../../data/repo/lingting_repository.dart';
import 'widgets/lingting_cover.dart';
import 'widgets/lingting_mini_player.dart';
import 'widgets/lingting_song_tile.dart';

/// 灵听搜索。
///
/// 交互按音乐类 App 的常规来：**边打字边出联想**（`search/associate`），
/// 回车/点联想才真搜（单曲/歌手/歌单三个接口并行）。没搜过时显示本机搜索历史。
class LingtingSearchPage extends ConsumerStatefulWidget {
  const LingtingSearchPage({super.key});

  @override
  ConsumerState<LingtingSearchPage> createState() => _LingtingSearchPageState();
}

class _LingtingSearchPageState extends ConsumerState<LingtingSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;
  List<String> _suggestions = const <String>[];
  LingtingSearchResult? _result;
  String? _error;
  bool _searching = false;
  String _keyword = '';
  LingtingSearchTab _tab = LingtingSearchTab.song;

  /// 用户自己点过 tab 没有（分层加载时，没点过就让「第一个有结果的 tab」说话）
  bool _tabPicked = false;

  /// 联想请求的序号：慢的那个回来时如果已经不是最后一次输入，就丢掉
  int _suggestSeq = 0;

  @override
  void initState() {
    super.initState();
    _history = LingtingStore.instance.searchHistory;
    // 进来就把焦点给输入框（不然用户还要点一下）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  late List<String> _history;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    return LingtingScaffold(
      leading: IconButton(
        onPressed: () => context.pop(),
        icon: const Icon(Icons.arrow_back),
        color: AppColors.text000,
      ),
      title: '',
      body: Column(
        children: <Widget>[
          _searchBar(context, i18n),
          Expanded(child: _body(context, i18n)),
        ],
      ),
    );
  }

  Widget _searchBar(BuildContext context, AppI18n i18n) => Container(
    color: AppColors.white,
    padding: EdgeInsets.fromLTRB(
      context.rpx(0),
      context.rpx(0),
      context.rpx(24),
      context.rpx(16),
    ),
    child: TextField(
      controller: _controller,
      focusNode: _focus,
      textInputAction: TextInputAction.search,
      onChanged: _onChanged,
      onSubmitted: search,
      style: TextStyle(fontSize: context.rpx(30), color: AppColors.text000),
      decoration: InputDecoration(
        isDense: true,
        hintText: i18n.t('lingting.searchHint'),
        hintStyle: TextStyle(
          fontSize: context.rpx(28),
          color: AppColors.text999,
        ),
        prefixIcon: Icon(
          Icons.search,
          size: context.rpx(40),
          color: AppColors.text999,
        ),
        suffixIcon: _controller.text.isEmpty
            ? null
            : IconButton(
                onPressed: () {
                  _controller.clear();
                  _onChanged('');
                },
                icon: Icon(Icons.close, size: context.rpx(36)),
                color: AppColors.text999,
              ),
        filled: true,
        fillColor: AppColors.panelBackground,
        contentPadding: EdgeInsets.symmetric(
          horizontal: context.rpx(20),
          vertical: context.rpx(18),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(context.rpx(16)),
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );

  Widget _body(BuildContext context, AppI18n i18n) {
    if (_searching) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.wechatGreen),
      );
    }
    if (_error != null) {
      return _empty(context, _error!);
    }
    final result = _result;
    if (result != null) {
      final tabs = searchTabsOf(result);
      if (tabs.isEmpty) return _empty(context, i18n.t('lingting.searchEmpty'));
      return Column(
        children: <Widget>[
          _tabBar(context, tabs),
          Expanded(child: _resultList(context, i18n, result)),
        ],
      );
    }
    if (_suggestions.isNotEmpty) return _suggestionList(context, i18n);
    return _historyView(context, i18n);
  }

  Widget _tabBar(BuildContext context, List<LingtingSearchTab> tabs) =>
      Container(
        color: AppColors.white,
        padding: EdgeInsets.symmetric(horizontal: context.rpx(20)),
        child: Row(
          children: <Widget>[
            for (final tab in tabs)
              Expanded(
                child: InkWell(
                  onTap: () => setState(() {
                    _tab = tab;
                    _tabPicked = true;
                  }),
                  child: Column(
                    children: <Widget>[
                      Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: context.rpx(18),
                        ),
                        child: Text(
                          _tabLabel(tabs, tab),
                          style: TextStyle(
                            fontSize: context.rpx(28),
                            color: _tab == tab
                                ? AppColors.wechatGreen
                                : AppColors.text666,
                            fontWeight: _tab == tab
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      Container(
                        height: context.rpx(4),
                        width: context.rpx(60),
                        color: _tab == tab
                            ? AppColors.wechatGreen
                            : Colors.transparent,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

  /// tab 文案带上条数（`单曲 128`），这也是音乐 App 的常规
  String _tabLabel(List<LingtingSearchTab> tabs, LingtingSearchTab tab) {
    final i18n = ref.watch(appI18nProvider);
    final result = _result;
    switch (tab) {
      case LingtingSearchTab.song:
        return '${i18n.t('lingting.songTab')} ${result?.songCount ?? 0}';
      case LingtingSearchTab.singer:
        return '${i18n.t('lingting.singerTab')} ${result?.singerCount ?? 0}';
      case LingtingSearchTab.sheet:
        return '${i18n.t('lingting.sheetTab')} ${result?.sheetCount ?? 0}';
    }
  }

  Widget _resultList(
    BuildContext context,
    AppI18n i18n,
    LingtingSearchResult result,
  ) {
    final source = i18n.t('lingting.searchFor', <String, String>{
      'keyword': _keyword,
    });
    switch (_tab) {
      case LingtingSearchTab.song:
        return ListView.builder(
          itemCount: result.songs.length,
          itemBuilder: (context, index) => LingtingSongTile(
            song: result.songs[index],
            queue: result.songs,
            source: source,
            showCover: true,
          ),
        );
      case LingtingSearchTab.singer:
        return ListView.builder(
          itemCount: result.singers.length,
          itemBuilder: (context, index) =>
              _singerRow(context, result.singers[index]),
        );
      case LingtingSearchTab.sheet:
        return ListView.builder(
          itemCount: result.sheets.length,
          itemBuilder: (context, index) =>
              _sheetRow(context, i18n, result.sheets[index]),
        );
    }
  }

  Widget _singerRow(BuildContext context, LingtingSinger singer) => InkWell(
    onTap: () =>
        context.push('${AppRoutes.lingtingSinger}?id=${singer.singerId}'),
    child: Container(
      color: AppColors.white,
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(30),
        vertical: context.rpx(18),
      ),
      child: Row(
        children: <Widget>[
          LingtingCover(url: singer.avatar, sizeRpx: 88, circular: true),
          SizedBox(width: context.rpx(20)),
          Expanded(
            child: Text(
              singer.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(30),
                color: AppColors.text000,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: context.rpx(40),
            color: AppColors.chevron,
          ),
        ],
      ),
    ),
  );

  Widget _sheetRow(
    BuildContext context,
    AppI18n i18n,
    LingtingSongSheet sheet,
  ) => InkWell(
    onTap: () => context.push('${AppRoutes.lingtingSheet}?id=${sheet.sheetId}'),
    child: Container(
      color: AppColors.white,
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(30),
        vertical: context.rpx(18),
      ),
      child: Row(
        children: <Widget>[
          LingtingCover(url: sheet.cover, sizeRpx: 88, radiusRpx: 10),
          SizedBox(width: context.rpx(20)),
          Expanded(
            child: Text(
              sheet.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(28),
                height: 1.3,
                color: AppColors.text000,
              ),
            ),
          ),
          if (sheet.songCount > 0)
            Text(
              i18n.t('lingting.songCount', <String, String>{
                'count': '${sheet.songCount}',
              }),
              style: TextStyle(
                fontSize: context.rpx(24),
                color: AppColors.text999,
              ),
            ),
        ],
      ),
    ),
  );

  Widget _suggestionList(BuildContext context, AppI18n i18n) =>
      ListView.builder(
        itemCount: _suggestions.length,
        itemBuilder: (context, index) => InkWell(
          onTap: () => search(_suggestions[index]),
          child: Container(
            color: AppColors.white,
            padding: EdgeInsets.symmetric(
              horizontal: context.rpx(30),
              vertical: context.rpx(22),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.search,
                  size: context.rpx(34),
                  color: AppColors.text999,
                ),
                SizedBox(width: context.rpx(18)),
                Expanded(
                  child: Text(
                    _suggestions[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.rpx(28),
                      color: AppColors.text000,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _historyView(BuildContext context, AppI18n i18n) {
    if (_history.isEmpty) return _empty(context, i18n.t('lingting.searchHint'));
    return ListView(
      padding: EdgeInsets.all(context.rpx(26)),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                i18n.t('lingting.searchHistory'),
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text666,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: _clearHistory,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.text999,
                minimumSize: Size.zero,
                padding: EdgeInsets.zero,
              ),
              child: Text(
                i18n.t('lingting.clear'),
                style: TextStyle(fontSize: context.rpx(26)),
              ),
            ),
          ],
        ),
        SizedBox(height: context.rpx(10)),
        Wrap(
          spacing: context.rpx(18),
          runSpacing: context.rpx(18),
          children: <Widget>[
            for (final keyword in _history)
              GestureDetector(
                onTap: () => search(keyword),
                onLongPress: () => _removeHistory(keyword),
                // 桌面（2026-10-03）：右键同长按 → 删这条历史
                onSecondaryTapDown: (_) => _removeHistory(keyword),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rpx(24),
                    vertical: context.rpx(12),
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.panelBackground,
                    borderRadius: BorderRadius.circular(context.rpx(28)),
                  ),
                  child: Text(
                    keyword,
                    style: TextStyle(
                      fontSize: context.rpx(26),
                      color: AppColors.text333,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _empty(BuildContext context, String text) => Center(
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: context.rpx(28), color: AppColors.text999),
    ),
  );

  // ------------------------------------------------------------ 行为

  void _onChanged(String text) {
    setState(() {
      _result = null;
      _error = null;
      if (text.trim().isEmpty) _suggestions = const <String>[];
    });
    _debounce?.cancel();
    if (text.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 300), () => _suggest(text));
  }

  Future<void> _suggest(String text) async {
    final seq = ++_suggestSeq;
    try {
      final list = await ref.read(lingtingRepositoryProvider).api.suggest(text);
      // 慢请求回来时用户可能已经改了输入：不是最后一次就丢掉
      if (!mounted || seq != _suggestSeq) return;
      setState(() => _suggestions = list);
    } on Object catch (error) {
      // 联想失败不打扰用户（主搜索还能用）
      debugPrint('[灵听] 联想失败：$error');
    }
  }

  /// 真搜：记历史 + 三个接口并行
  /// 搜一次：**三块各拉各的，哪块先回来先显示哪块**（S12.1）。
  ///
  /// 老实现是等 `Future.wait` 三个接口都回来才出结果，灵听的接口超时是 12 秒，
  /// 一块慢就是整页转圈。现在单曲那一块回来了就能开始点/播，歌手与歌单
  /// 随后几秒内自己长出来（tab 上那个条数也会跟着变）。
  Future<void> search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    _controller.text = trimmed;
    _focus.unfocus();
    setState(() {
      _searching = true;
      _result = null;
      _error = null;
      _suggestions = const <String>[];
      _keyword = trimmed;
      // 新一次搜索：tab 选择权交回给「谁先有结果」
      _tabPicked = false;
    });
    await LingtingStore.instance.addSearchHistory(trimmed);
    if (!mounted) return;
    _history = LingtingStore.instance.searchHistory;

    final api = ref.read(lingtingRepositoryProvider).api;
    var failures = 0;
    Future<void> piece(Future<LingtingSearchResult> Function() fetch) async {
      LingtingSearchResult part;
      try {
        part = await fetch();
      } on Object catch (error) {
        debugPrint('[灵听] 搜索失败（其中一块）：$error');
        failures += 1;
        return;
      }
      // 这一轮已经换了关键词 → 丢掉（慢的那块回来时别把新结果搅了）
      if (!mounted || _keyword != trimmed) return;
      setState(() {
        _result = (_result ?? LingtingSearchResult.empty).mergeWith(part);
        // 第一块回来就不转圈了（剩下的继续在后台长）
        _searching = false;
        if (!_tabPicked) {
          final tabs = searchTabsOf(_result!);
          if (tabs.isNotEmpty) _tab = tabs.first;
        }
      });
    }

    await Future.wait<void>(<Future<void>>[
      piece(() => api.searchSongs(trimmed)),
      piece(() => api.searchSingers(trimmed)),
      piece(() => api.searchSheets(trimmed)),
    ]);
    if (!mounted || _keyword != trimmed) return;
    setState(() {
      _searching = false;
      // 三块全军覆没才说「加载失败」；只挂一块就显示拿到的那些
      if (failures == 3) {
        _error = ref.read(appI18nProvider).t('common.loadFailed');
      }
    });
  }

  Future<void> _clearHistory() async {
    await LingtingStore.instance.clearSearchHistory();
    if (!mounted) return;
    setState(() => _history = const <String>[]);
  }

  Future<void> _removeHistory(String keyword) async {
    await LingtingStore.instance.removeSearchHistory(keyword);
    if (!mounted) return;
    setState(() => _history = LingtingStore.instance.searchHistory);
  }
}
