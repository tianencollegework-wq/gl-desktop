/// 网页窗里的「标签页」（2026-10-04）。
///
/// 用户原话：「还有你说的多标签做上呗」—— 这扇窗以前只有一页：主窗口再点一条
/// 外链，就把这一页换过去（`open_url` 里 `router.go`），看上一条时点下一条就把它
/// 顶掉了。现在每点一条外链**多开一个标签**、切着看，和微信 PC 那扇浏览器窗口
/// 一个样子。
///
/// 为什么单独一条文件而不是塞进界面里：标签的规矩（同址去重、关掉当前这个之后
/// 竖谁上来、关完一个不剩怎么办）都是能用单测钉住的东西，界面只管画。
library;

import 'package:flutter/foundation.dart';

import 'window_args.dart';

/// 一个标签：一条地址 + 顶上那行字。
@immutable
class WebTab {
  const WebTab({
    required this.id,
    required this.url,
    required this.title,
    this.pageTitle = '',
  });

  /// 标签自己那个编号（每个窗口里从 1 开始发），切/关都按它找
  final int id;

  /// 这条标签要打开的地址
  final String url;

  /// 主窗口给的名字（域名，见 [webWindowTitleOf]）
  final String title;

  /// 网页自己报的标题（`WebviewController.title` 那条流）；还没有就是空串
  final String pageTitle;

  /// 标签条上显示什么：网页报了标题就听它的，没报先用域名
  String get label => pageTitle.isEmpty ? title : pageTitle;

  WebTab withPageTitle(String value) =>
      WebTab(id: id, url: url, title: title, pageTitle: value);
}

/// 一扇网页窗里那一排标签。
///
/// 只被一颗引擎里的界面用（每扇网页窗一份），所以不挂 provider：直接由
/// `child_window_app.dart` 建出来递给界面 —— 窗口之间的标签不该互相串。
class WebTabsController extends ChangeNotifier {
  WebTabsController({required String url, String title = ''}) {
    // 开窗时那一条（主窗口点的那条外链）—— 它也就是当前这一条
    if (url.isNotEmpty) {
      final tab = _make(url: url, title: title);
      _tabs.add(tab);
      _activeId = tab.id;
    }
  }

  final List<WebTab> _tabs = <WebTab>[];
  int _activeId = 0;
  int _nextId = 1;

  List<WebTab> get tabs => List<WebTab>.unmodifiable(_tabs);

  bool get isEmpty => _tabs.isEmpty;

  int get activeId => _activeId;

  /// 当前这个标签在列表里的位置（`IndexedStack` 用它决定画谁）
  int get activeIndex => _indexOf(_activeId);

  WebTab? get active => _tabs.isEmpty ? null : _tabs[activeIndex];

  /// 主窗口又点了一条外链：**新开一个标签**。
  ///
  /// 同一条地址已经在里面（用户把一条链接点了两遍）→ 不叠第二个，直接切过去；
  /// 不然点几下就多出几条一模一样、还各自占一份 WebView2 的标签。
  void open({required String url, String title = ''}) {
    if (url.isEmpty) return;
    final existing = _tabs.indexWhere((tab) => tab.url == url);
    if (existing >= 0) {
      _activeId = _tabs[existing].id;
      notifyListeners();
      return;
    }
    final tab = _make(url: url, title: title);
    _tabs.add(tab);
    _activeId = tab.id;
    notifyListeners();
  }

  /// 切到某一个标签
  void activate(int id) {
    if (id == _activeId || _indexOf(id) < 0) return;
    _activeId = id;
    notifyListeners();
  }

  /// 关掉某一个标签。
  ///
  /// 关的是当前这个 → 右邻顶上来（右边没有了就退回左邻）—— 与浏览器同一个手感。
  /// 关完一个不剩：这里只把状态清干净，「窗要不要跟着关」由界面那边定
  /// （见 `DesktopWebWindow`：关掉最后一个标签 = 关掉这扇窗）。
  void close(int id) {
    final index = _indexOf(id);
    if (index < 0) return;
    final wasActive = _tabs[index].id == _activeId;
    _tabs.removeAt(index);
    if (wasActive && _tabs.isNotEmpty) {
      _activeId = _tabs[index > _tabs.length - 1 ? _tabs.length - 1 : index].id;
    }
    notifyListeners();
  }

  /// 网页自己报了标题（可能来好几次，同一个标题就不再通知）
  void setPageTitle(int id, String title) {
    final index = _indexOf(id);
    if (index < 0) return;
    final clean = title.trim();
    if (clean.isEmpty || _tabs[index].pageTitle == clean) return;
    _tabs[index] = _tabs[index].withPageTitle(clean);
    notifyListeners();
  }

  int _indexOf(int id) => _tabs.indexWhere((tab) => tab.id == id);

  WebTab _make({required String url, required String title}) => WebTab(
    id: _nextId++,
    url: url,
    title: title.isEmpty ? webWindowTitleOf(url) : title,
  );
}
