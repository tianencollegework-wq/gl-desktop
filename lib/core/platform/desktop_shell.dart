import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';

/// 现在跑的是不是**桌面**（Windows / macOS / Linux）。
///
/// 判据用 `dart:io` 的 `Platform.isX`，不用 `defaultTargetPlatform`：
/// 组件测试跑在桌面宿主机上时 `defaultTargetPlatform` 就是 windows，
/// 会把桌面形态误开进测试（见 [desktopShellProvider] 的说明）。
/// `kIsWeb` 必须先短路 —— web 上一读 `Platform` 就抛。
bool get isDesktopRuntime =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// `flutter test` 一定会设的环境变量（本机实测 `FLUTTER_TEST=true`）。
final bool _isFlutterTest = Platform.environment['FLUTTER_TEST'] == 'true';

/// 桌面**行为**总开关（回车发送、右键菜单、选文件、存到下载目录……）。
///
/// 与 [isDesktopRuntime] 只差一个字，但很关键：**测试里默认是关的**。
/// 组件测试跑在桌面宿主机上时 `isDesktopRuntime` 为真，而现有那套用例钉的
/// 全是手机上的版式与交互（默认窗口 800×600、输入栏有「拍摄」、扫码页有取景框，
/// ……），桌面分支一律开起来会让它们成片变红。所以：
///
/// * 拿得到 `ref` 的地方读 [desktopFeaturesProvider]（用例可以 override）；
/// * 拿不到 `ref` 的地方（选图 / 存文件的实现类）用它做构造默认值，
///   同样可以注入 —— 见 `SystemMediaPicker` / `SystemMediaSaver`。
bool get desktopFeaturesEnabled => isDesktopRuntime && !_isFlutterTest;

final desktopFeaturesProvider = Provider<bool>((ref) => desktopFeaturesEnabled);

/// 桌面外壳开关。
///
/// **测试里默认关掉**：现有用例的默认窗口是 800×600，比
/// [DesktopShell.maxWidth] 还宽 —— 开着就会全体套进 500 列的窄窗，
/// 版式一变形，那些按宽度/坐标断言的用例全会碎。要验桌面形态的用例
/// 自己 override 成 `true`。
final desktopShellProvider = Provider<bool>((ref) => desktopFeaturesEnabled);

/// 桌面窗口的**内容壳**：窗口可以拉得很宽，内容封顶居中。
///
/// 为什么要有它：整站版式是按手机屏宽算的 —— `rpx` 就是 `屏宽 / 750`
/// （全项目 1897 处），还有十几处直接读 `MediaQuery.sizeOf(context).width`
/// （扫码取景框、图片气泡的最大宽度…）。窗口拉宽之后这些尺寸跟着一起放大，
/// 界面会变成「放大镜里的手机」。
///
/// 与其去改 106 个文件，不如在**根上把宽度换掉**：这里把内容封顶到
/// [maxWidth] 并居中，同时把子树看到的 `MediaQuery.size.width` 覆写成
/// `min(窗口宽, maxWidth)` —— 上面那些写法一个字都不用改就全部归位。
/// 窗口本来就窄时直接透传，行为与手机完全一致。
class DesktopShell extends ConsumerWidget {
  const DesktopShell({super.key, required this.child, this.contentMaxWidth});

  /// 内容区的最大宽度（逻辑像素）。取 500：比手机常见宽度（390–430）宽一点，
  /// 又明显窄于笔记本窗口，居中之后两侧留灰能看出是「窄窗」形态。
  static const double maxWidth = 500;

  /// 封顶宽度换个值（默认 [maxWidth]）。
  ///
  /// 系统级独立窗口（灵听 / 媒体号 / 文章）用它：那些窗口是按手机版式排的，
  /// 用户**最大化**之后 `rpx`（= 窗宽 / 750）会一路涨到 2 倍多 —— 字、图标、
  /// 间距跟着胀大，竖着的版式又装不下那么高，播放键都会被挤出窗沿
  /// （2026-10-04 用户报：「灵听全屏后会变形」）。封在它自己那档宽度上，
  /// 最大化就只是「两边多出背景」，内容跟默认大小一模一样。
  final double? contentMaxWidth;

  /// 两侧留白那块的底色（浅灰，与聊天区那一档同色）
  static const Color backdrop = AppColors.page;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(desktopShellProvider)) return child;

    final media = MediaQuery.of(context);
    final width = media.size.width;
    final cap = contentMaxWidth ?? maxWidth;
    if (width <= cap) {
      // 窗口本来就窄（用户把窗口拉到 500 以下）：什么都不用套，
      // 行为与手机完全一致
      return child;
    }

    // 正在跑桌面**框架**（三栏主框架 / 二级页那条「图标条 + 面板」）时内容
    // **吃满整窗**：那一层自己会摆列（见 `features/home/desktop_frame.dart`），
    // 夹到 500 就没地方摆了。用 ValueListenable 而不是 provider 状态：
    // 框架在挂载那一帧改它，走 Riverpod 会在「构建期间改 provider」上踩断言。
    return ValueListenableBuilder<int>(
      valueListenable: ref.watch(desktopFrameActiveProvider),
      builder: (context, framesOnScreen, _) {
        // 只换「夹多宽」，**不换 widget 的层次**：两态都还是
        // ColoredBox > Center > SizedBox > MediaQuery 这一串。
        // 换层次（不夹的那一态直接给 `child`）会让翻面那一帧整棵子树按类型
        // 比对失败、被整棵重挂：登录后进主界面时看得见闪一下，页面里那些
        // drift 流也会被关掉重开。
        final contentWidth = framesOnScreen > 0 ? width : cap;
        return ColoredBox(
          color: backdrop,
          child: Center(
            child: SizedBox(
              width: contentWidth,
              // 只夹宽度、不动高度：整站的竖版布局依赖「宽度 = 屏宽」这一个前提，
              // 把宽度换成 500 之后，下面那些 `rpx` 与直接读宽度的写法就自动归位了
              child: MediaQuery(
                data: media.copyWith(
                  size: Size(contentWidth, media.size.height),
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 横屏桌面形态的宽度门槛。
///
/// 够宽 → 走微信 PC 那套「左图标条 + 会话列 + 聊天区」；不够宽 → 还是手机那套
/// （<= [DesktopShell.maxWidth] 的时候连壳都不套）。
///
/// 900 这个数是排出来的：图标条 60 + 会话列 300 + 聊天区至少 540 —— 聊天区低于
/// 这数，气泡、输入框、标题栏就会挤成一团，不如退回单栏。
const double kDesktopFrameMinWidth = 900;

/// 这一帧树上挂着几个桌面框架（[DesktopFrame] / [DesktopPageFrame]）。
///
/// **不是给业务代码读的开关**（业务读 [desktopFeaturesProvider]），它只服务
/// [DesktopShell]：框架要吃满整窗，就不能再被那条 500 的封顶夹住。
/// 用 `ValueNotifier` 而不是 `StateProvider`：框架在挂载那一帧改它，
/// 写 provider 会在「构建期间改 provider」上踩断言。
///
/// **是计数不是布尔**：二级页可以叠着推（设置 → 通知 → …），顶层那个 pop 掉之后
/// 下面那个还在树上 —— 布尔会被顶层那个 `dispose` 误置回 false，[DesktopShell]
/// 于是重新把内容夹回 500，界面在返回时错位一帧。
final desktopFrameActiveProvider = Provider<ValueNotifier<int>>(
  (ref) => ValueNotifier<int>(0),
);

/// 桌面框架的挂载标记：有它在树上，[DesktopShell] 就不夹那 500 宽。
///
/// 三栏主框架与二级页面板都用它 —— 「谁在管版式」这件事只在这里记一次，
/// 免得两处各写一份挂载/卸载的账（叠着推的时候那份账最容易漏）。
class DesktopFrameScope extends ConsumerStatefulWidget {
  const DesktopFrameScope({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  ConsumerState<DesktopFrameScope> createState() => _DesktopFrameScopeState();
}

class _DesktopFrameScopeState extends ConsumerState<DesktopFrameScope> {
  late final ValueNotifier<int> _active = ref.read(desktopFrameActiveProvider);
  bool _counted = false;

  @override
  void initState() {
    super.initState();
    // 不能在 initState 里同步加：那会让上层（[DesktopShell]）在构建期间被标脏。
    // 晚一帧的代价是最外面那一帧仍按 500 排 —— 那时屏幕上还是登录页 / 启动页。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _counted) return;
      _counted = true;
      _active.value += 1;
    });
  }

  @override
  void dispose() {
    if (!_counted) {
      super.dispose();
      return;
    }
    // 不能在 dispose 里同步减：卸载发生在 finalizeTree（框架**锁着**）期间，
    // 通知会让 [DesktopShell] 的 ValueListenableBuilder 在锁定期标脏 ——
    // 报「setState() or markNeedsBuild() called when widget tree was locked」
    // （2026-10-03 从二级页点图标条回主界面时踩到的）。晚一帧减，视觉上没有区别：
    // 下面那个框架还在树上，计数本来就不该掉到 0。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _active.value -= 1;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// **真实的窗口宽度**（逻辑像素）。
///
/// 千万不要用 `MediaQuery.sizeOf(context).width` 来问「窗口有多宽」：[DesktopShell]
/// 在宽窗下会把子树看到的宽度**覆写成 500**（就是那条封顶），于是这个判断永远拿到
/// 500 —— 三栏判据永远不成立（2026-10-03 晚上就是这么踩的：功能都写好了，用户登录后
/// 看到的还是手机版式）。`View` 上那份是引擎给的真实窗口尺寸，不受 MediaQuery 覆写
/// 影响。
///
/// 拿不到 `View`（极少数没有 view 的场景）时退回 MediaQuery 的值。
double realWindowWidth(BuildContext context) {
  final view = View.maybeOf(context);
  if (view == null || view.devicePixelRatio == 0) {
    return MediaQuery.sizeOf(context).width;
  }
  return view.physicalSize.width / view.devicePixelRatio;
}

/// 现在该走桌面横屏布局吗：桌面 + 功能开着 + **窗口**够宽。
///
/// 只能在 `build` 里调（内部 `ref.watch`）。
/// 宽度要用 [realWindowWidth]，不能用 `MediaQuery` 那份（理由见它）。
bool desktopWideLayout(BuildContext context, WidgetRef ref) =>
    ref.watch(desktopFeaturesProvider) &&
    realWindowWidth(context) >= kDesktopFrameMinWidth;
