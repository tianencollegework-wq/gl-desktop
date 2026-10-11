#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"

// S12.24：系统媒体控制（SMTC）—— 「正在播放」那张卡片与键盘上的媒体键。
//
// 为什么要自己出：Android/iOS 那份走 `audio_service`（通知栏/锁屏），而它在
// Windows 上**没有实现**（包里只有 android / darwin / web）。灵听在 Windows 上
// 是 `just_audio_windows_plus` 在放，底下是 WinRT 的 MediaPlayer —— 系统那边
// 确实会多出一条会话（进程里那个 `MediaPlayer SMTC window`），可它没有标题/
// 歌手/封面，媒体键也只会戳 MediaPlayer 自己（而我们的「上一首/下一首」逻辑在
// Dart 里）。所以这里拿 SMTC 自己开一条会话，把元数据与那几颗键接上。
#include <systemmediatransportcontrolsinterop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

namespace {

// S12.22：子窗口自己的小通道。`desktop_multi_window` 只给了 window_show /
// window_hide，标题、关闭、边界这些都得自己出；窗口句柄就是这颗引擎的视图。
//
// 通道对象必须活着，否则 handler 还没被调就被析构 —— 攒在一个静态容器里。
std::vector<std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
    g_child_window_channels;

// 系统媒体会话那条通道也要攒着（理由同上）
std::vector<std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
    g_media_session_channels;

// S12.36：托盘那条通道也要攒着（理由同上）
std::vector<std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
    g_tray_channels;

// 「本机版本号」那条通道也要攒着（理由同上）
std::vector<std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
    g_app_info_channels;

// ✕（或 Alt+F4）＝**真关掉**：销毁这扇窗，那颗引擎也跟着释放。
//
// 走过的弯路（S12.22 → S12.23 → S12.24）：最早发现「一销毁整个进程就没了」，
// 于是改成了「✕ 只 SW_HIDE、再点就 show()」—— 窗是看不到了，但 56MB 的引擎
// 一直赖在后台。2026-10-04 用户追了一句：「我把这种独立窗口关掉了怎么不是真的
// 销毁了吗？怎么后台还在的吗？」
//
// 回头看当年那一死，原因其实在**消息循环**那头：销毁子窗时插件会用
// `PostQuitMessage` 叫停整个进程（子窗自己的 `quit_on_close_` 是 false，但
// 插件在窗口表清空时也会叫），而当时的 `main.cpp` 照单全收。现在主循环里
// 有一条「主窗口还在、且不是它在关，WM_QUIT 就丢掉」（见 main.cpp），
// 所以这条路可以走通了 —— 实测点 ✕ 之后进程活着、内存降回去、再点能重开。
//
// ⚠️ S12.29（2026-10-05）又一个跟「真关掉」有关的坑，这次是**通话窗**：
// 那扇窗里有一颗活着的 webrtc 媒体引擎（`WebrtcCallMediaEngine`）。用户在通话中
// 按 ✕ 时，这里是**立刻 DestroyWindow**——引擎连着插件一起拆，webrtc 拆到音频
// 设备（`AudioDeviceModuleImpl::Terminate`）那一步直接 abort，**整个 app 跟着
// 一起没**（事件日志：`gracelinkim.exe` 异常代码 `0xc0000409`，两次实测都在
// `[窗口] 开始销毁子窗口` 之后、`[窗口] 子窗口销毁返回` 之前）。
//
// 所以现在的规矩是：**✕ 先问 Dart 一声**（`close_requested`）—— 谁需要收摊
// （通话窗要先 `engine.close()` 把媒体放干净）就自己收，收完再回来叫 `close`；
// Dart 那边没装这一手（文章窗 / 网页窗）就照老路直接销毁。
//
// ⚠️ 又按一下（双击 ✕）也**不能**改成「直接销毁」：那时候 Dart 的收摊可能还在
// 半路，拆下去照样是那个 abort。重复的关闭请求就这样安静地等一下。
std::optional<LRESULT> ChildWindowProcDelegate(HWND hwnd, UINT message,
                                               WPARAM wparam, LPARAM lparam);

// 子窗那条自家小通道的反查表：✕ 时要顺着 HWND 找到「这扇窗的 Dart 是谁」。
// 通道对象由 `g_child_window_channels` 一直攒着，这里只存个弱引用。
std::map<HWND, std::weak_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
    g_child_close_channels;

// 已经为哪几扇窗问过 Dart「✕ 了，你收不收摊」—— 再问一次就是用户在催
std::set<HWND> g_child_close_asked;

// **声明过「我这扇窗要自己收摊」的子窗**（Dart 侧叫的 `guardClose`，见
// `desktop_window_native.dart::onCloseRequested`）。
//
// ⚠️ 2026-10-08 用户报的「独立窗口一出来就关不掉」就是这里漏的一刀：原来
// **不管哪扇窗**，✕ 都先吞下来去问 Dart。文章窗 / 网页窗 / 媒体号窗 / 灵听窗
// 的 Dart 侧压根没装这一手（它们没有什么要收的），那一问只要没人答（或答应了
// 却没走到 `close`），窗口就**永远关不掉**了 —— 真机实测：`WM_CLOSE` 发过去
// 4 秒后窗口还在、还照样响应，帮助窗口一次都没建过（＝真正销毁那条路没跑到）。
//
// 改成白名单：**默认直接关**，只有声明过的（目前只有通话窗那颗媒体引擎）
// 才走「先问 Dart」。
std::set<HWND> g_child_close_guarded;

// 问过 Dart 之后等多久算“它不打算答”：到点照样销毁，不把窗留在那儿。
// 收摊本身（通话窗放媒体）是 3 秒封顶（见 `call_window.dart`），这里给得比它宽一点。
constexpr UINT kChildCloseGraceMs = 5000;

// 销毁不能就在 WM_CLOSE 这条栈上做：那道委托是从引擎自己的
// `HandleTopLevelWindowProc` 里调过来的，而销毁会把 `FlutterViewController`
// （连它那颗引擎）删掉 —— 等于在它自己的成员函数里删自己，后面的代码就悬空了。
//
// 所以借一扇**不走 Flutter** 的消息窗转一手：WM_CLOSE 只往它 PostMessage，
// 真正那句 DestroyWindow 在主循环下一轮、脱离引擎栈的时候执行。
constexpr UINT kChildCloseMessage = WM_APP + 71;
HWND g_child_close_helper = nullptr;

LRESULT CALLBACK ChildCloseHelperProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (message == kChildCloseMessage) {
    const HWND target = reinterpret_cast<HWND>(wparam);
    // 已经决定销毁了，把那只「等 Dart」的定时器收掉（目标句柄会被系统复用，
    // 留着的定时器可能打到下一扇窗上）
    ::KillTimer(hwnd, wparam);
    std::cerr << "[窗口] 开始销毁子窗口" << std::endl;
    ::DestroyWindow(target);
    std::cerr << "[窗口] 子窗口销毁返回（进程还活着）" << std::endl;
    return 0;
  }
  if (message == WM_TIMER) {
    // 兜底：问过 Dart 之后它一直没来叫 `close`（没答 / 答了却没走完）——
    // 照样销毁。没有这一刀，那扇窗就会一直挂在那儿点 ✕ 都没反应。
    const HWND target = reinterpret_cast<HWND>(wparam);
    ::KillTimer(hwnd, wparam);
    std::cerr << "[窗口] 等 Dart 收摊超时：直接销毁" << std::endl;
    ::DestroyWindow(target);
    return 0;
  }
  return ::DefWindowProc(hwnd, message, wparam, lparam);
}

HWND ChildCloseHelperWindow();  // 定义在下面（那扇消息窗）

/// 真正那句「把窗拆了」：借消息窗转一手，脱离引擎自己那条栈。
///
/// 所有要销毁子窗的地方都从这里走 —— `close`（Dart 收完摊叫的那一声）与
/// ✕ 没人接（文章窗 / 网页窗）那一条。
void RequestChildWindowDestroy(HWND hwnd) {
  if (hwnd == nullptr) return;
  const HWND helper = ChildCloseHelperWindow();
  if (helper != nullptr) {
    // 销毁已经排上队了：那只等 Dart 的定时器没用了
    ::KillTimer(helper, reinterpret_cast<UINT_PTR>(hwnd));
  }
  if (helper == nullptr) {
    // 退路：消息窗没建起来就直接销毁（理论上会踩「在引擎栈上拆引擎」的风险，
    // 但总比点了 ✕ 没反应强）
    ::DestroyWindow(hwnd);
    return;
  }
  ::PostMessageW(helper, kChildCloseMessage, reinterpret_cast<WPARAM>(hwnd), 0);
}

/// ------------------------------------------------ 画中画小窗（S12.31）

/// 进小窗之前那一副样式与位置：出来时照原样还回去。
struct PipState {
  LONG_PTR style = 0;
  LONG_PTR ex_style = 0;
  RECT rect{};
};

std::map<HWND, PipState> g_child_pip_states;

/// 拖窗那一下的起点：**真光标位置**与那一刻的窗口位置。
///
/// 为什么不用 Dart 报过来的位移：窗口一跟着动，指针在窗里的局部坐标也跟着变，
/// 两边一抵消，拖到一半就不动了。`GetCursorPos` 给的是屏幕坐标，跟按下那一刻
/// 一比，位移永远是准的（拖窗这件事只有系统自己那一份才对得上）。
struct DragState {
  POINT cursor{};
  RECT rect{};
};

std::map<HWND, DragState> g_child_drag_states;

/// 这扇窗所在显示器的缩放比（逻辑像素 → 物理像素）
double WindowScale(HWND hwnd) {
  const UINT dpi = hwnd != nullptr ? ::GetDpiForWindow(hwnd) : 96;
  return dpi >= 96 ? dpi / 96.0 : 1.0;
}

/// 这扇窗所在显示器的工作区（物理像素；拿不到就整屏）
RECT WorkAreaOf(HWND hwnd) {
  MONITORINFO info{};
  info.cbSize = sizeof(MONITORINFO);
  if (hwnd == nullptr ||
      !::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                        &info)) {
    return RECT{0, 0, ::GetSystemMetrics(SM_CXSCREEN),
                ::GetSystemMetrics(SM_CYSCREEN)};
  }
  return info.rcWork;
}

/// 挪到 (x, y)（尺寸不变），并保证整扇窗还留在工作区里 —— 拖不丢。
void MoveWindowClamped(HWND hwnd, int x, int y, int width, int height) {
  if (hwnd == nullptr) return;
  const RECT work = WorkAreaOf(hwnd);
  const int min_x = static_cast<int>(work.left);
  const int min_y = static_cast<int>(work.top);
  // 窗比工作区还大时贴着左上：那一头再 clamp 会把它翻到屏幕外
  const int max_x = std::max(min_x, static_cast<int>(work.right) - width);
  const int max_y = std::max(min_y, static_cast<int>(work.bottom) - height);
  x = std::min(std::max(x, min_x), max_x);
  y = std::min(std::max(y, min_y), max_y);
  ::SetWindowPos(hwnd, nullptr, x, y, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE);
}

/// ------------------------------------------------ 系统媒体控制（SMTC）

using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;

/// 一颗引擎一条会话（键是它那扇窗）。
///
/// 用 shared_ptr：按钮回调是异步的，得保证它回来时对象还在；
/// 窗口销毁时（[ReleaseMediaSession]）把通道摘掉，回调再进来只会看到空通道 ——
/// 引擎都没了还往它里面投就是悬空。
struct MediaSession {
  HWND hwnd = nullptr;
  SystemMediaTransportControls controls{nullptr};
  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
};

std::vector<std::shared_ptr<MediaSession>>& MediaSessions() {
  static std::vector<std::shared_ptr<MediaSession>> sessions;
  return sessions;
}

std::shared_ptr<MediaSession> FindMediaSession(HWND hwnd) {
  for (const auto& session : MediaSessions()) {
    if (session->hwnd == hwnd) return session;
  }
  return nullptr;
}

/// 拿某扇窗的 SMTC。桌面应用得走 interop 那个工厂（这个类没有普通激活工厂）。
SystemMediaTransportControls MediaControlsFor(HWND hwnd) {
  try {
    auto interop =
        winrt::get_activation_factory<SystemMediaTransportControls,
                                      ISystemMediaTransportControlsInterop>();
    SystemMediaTransportControls controls{nullptr};
    winrt::check_hresult(interop->GetForWindow(
        hwnd, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(controls)));
    return controls;
  } catch (...) {
    return nullptr;  // 拿不到就当作没有系统那份（不影响播放）
  }
}

/// 窗口没了：把会话收掉、把通道摘掉（详见 [MediaSession] 的注释）
void ReleaseMediaSession(HWND hwnd) {
  auto session = FindMediaSession(hwnd);
  if (session == nullptr) return;
  std::cerr << "[窗口] 释放媒体会话：找到" << std::endl;
  try {
    if (session->controls != nullptr) {
      std::cerr << "[窗口] 释放媒体会话：IsEnabled(false) 前" << std::endl;
      session->controls.IsEnabled(false);
      std::cerr << "[窗口] 释放媒体会话：IsEnabled(false) 后" << std::endl;
      session->controls.PlaybackStatus(MediaPlaybackStatus::Closed);
      std::cerr << "[窗口] 释放媒体会话：PlaybackStatus 后" << std::endl;
    }
  } catch (...) {
    std::cerr << "[窗口] 释放媒体会话：抛了异常（吞掉）" << std::endl;
  }
  // 会话本身也放掉：它绑在那扇窗上，窗都要没了，再握着它等系统回调就是悬空
  std::cerr << "[窗口] 释放媒体会话：controls 置空 前" << std::endl;
  session->controls = nullptr;
  std::cerr << "[窗口] 释放媒体会话：channel 置空 前" << std::endl;
  session->channel = nullptr;
  std::cerr << "[窗口] 系统媒体会话已释放" << std::endl;
}

/// 系统那颗键 → Dart 那边认的名字（"stop" 当暂停：队列留着，回来还能接着听）
std::string ButtonName(SystemMediaTransportControlsButton button) {
  switch (button) {
    case SystemMediaTransportControlsButton::Play:
      return "play";
    case SystemMediaTransportControlsButton::Pause:
      return "pause";
    case SystemMediaTransportControlsButton::Next:
      return "next";
    case SystemMediaTransportControlsButton::Previous:
      return "previous";
    case SystemMediaTransportControlsButton::Stop:
      return "pause";
    default:
      return "";
  }
}

std::string StringOf(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return std::string();
  if (const auto* text = std::get_if<std::string>(&it->second)) return *text;
  return std::string();
}

bool BoolOf(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return false;
  if (const auto* flag = std::get_if<bool>(&it->second)) return *flag;
  return false;
}

double DoubleOf(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return 0.0;
  if (const auto* number = std::get_if<double>(&it->second)) return *number;
  if (const auto* integer = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*integer);
  }
  return 0.0;
}

/// 秒 → WinRT 的 100 纳秒单位（TimeSpan）
int64_t TicksOf(double seconds) {
  if (seconds <= 0) return 0;
  return static_cast<int64_t>(seconds * 10000000.0);
}

/// 会话（没有就建一条，顺便把系统那几颗键接回 Dart）
std::shared_ptr<MediaSession> EnsureMediaSession(HWND hwnd) {
  if (hwnd == nullptr) return nullptr;
  if (auto existing = FindMediaSession(hwnd); existing != nullptr) {
    return existing;
  }
  auto controls = MediaControlsFor(hwnd);
  if (controls == nullptr) return nullptr;

  auto session = std::make_shared<MediaSession>();
  session->hwnd = hwnd;
  session->controls = controls;
  controls.IsEnabled(true);
  controls.IsPlayEnabled(true);
  controls.IsPauseEnabled(true);
  controls.IsNextEnabled(true);
  controls.IsPreviousEnabled(true);
  controls.ButtonPressed([session](auto&&, auto&& args) {
    const std::string button = ButtonName(args.Button());
    // 窗口销毁之后通道会被摘掉（见 [ReleaseMediaSession]）：引擎都不在了，
    // 还往它里面投就是悬空
    if (button.empty() || session->channel == nullptr) return;
    try {
      flutter::EncodableMap payload;
      payload[flutter::EncodableValue("button")] =
          flutter::EncodableValue(button);
      session->channel->InvokeMethod(
          "media_button",
          std::make_unique<flutter::EncodableValue>(payload));
    } catch (...) {
    }
  });
  MediaSessions().push_back(session);
  return session;
}

/// 那扇消息窗（只建一次；创建失败就返回 nullptr，调用方走退路）
HWND ChildCloseHelperWindow() {
  if (g_child_close_helper != nullptr) {
    return g_child_close_helper;
  }
  const wchar_t kClassName[] = L"GracelinkChildCloseHelper";
  WNDCLASS klass{};
  klass.lpfnWndProc = ChildCloseHelperProc;
  klass.hInstance = ::GetModuleHandle(nullptr);
  klass.lpszClassName = kClassName;
  ::RegisterClass(&klass);  // 已注册过会失败，无所谓：只有这一个地方用这个名字
  g_child_close_helper =
      ::CreateWindowEx(0, kClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                       nullptr, klass.hInstance, nullptr);
  return g_child_close_helper;
}

std::optional<LRESULT> ChildWindowProcDelegate(HWND hwnd, UINT message,
                                               WPARAM wparam, LPARAM lparam) {
  if (message == WM_DESTROY) {
    // 窗要没了：先把系统媒体会话收掉（不然它会在这扇窗消失后继续发键位，
    // 而那颗引擎已经拆了）。返回 nullopt = 交给下面照常销毁。
    std::cerr << "[窗口] 子窗口收到 WM_DESTROY" << std::endl;
    ReleaseMediaSession(hwnd);
    // 这扇窗的 HWND 从此不作数：反查表也收掉（句柄会被系统复用）
    g_child_close_channels.erase(hwnd);
    g_child_close_asked.erase(hwnd);
    // 画中画与拖拽那两份状态也跟着这扇窗收掉（HWND 会被系统复用）
    g_child_pip_states.erase(hwnd);
    g_child_drag_states.erase(hwnd);
    // 「这扇窗要自己收摊」的记号同理（句柄会被复用，留着会落到别人头上）
    g_child_close_guarded.erase(hwnd);
    return std::nullopt;
  }
  if (message != WM_CLOSE) {
    return std::nullopt;
  }

  // ✕ 的路（2026-10-05 起）：先问这扇窗的 Dart 要不要收摊（见文件头那段
  // 「S12.29」）。通话窗里那颗媒体引擎必须在引擎被拆之前放干净，不然 webrtc
  // 拆音频设备时会 abort 整个进程。
  // 没声明过要自己收摊的窗（文章 / 网页 / 媒体号 / 灵听）：**✕ 就是关掉**，
  // 不经过 Dart（见 `g_child_close_guarded` 的注释）。
  if (g_child_close_guarded.count(hwnd) == 0) {
    RequestChildWindowDestroy(hwnd);
    return 0;
  }

  const auto it = g_child_close_channels.find(hwnd);
  const auto channel =
      it != g_child_close_channels.end() ? it->second.lock() : nullptr;
  if (channel != nullptr && g_child_close_asked.count(hwnd) == 0) {
    g_child_close_asked.insert(hwnd);
    // ⚠️ 日志里别写 U+2715（✕）那个字符：/W4 把它当错（C4566，936 代码页
    // 表示不出来），构建直接失败。
    std::cerr << "[窗口] 关闭请求：先问 Dart 收不收摊，收完它自己来叫 close"
              << std::endl;
    channel->InvokeMethod(
        "close_requested", std::make_unique<flutter::EncodableValue>(),
        std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
            // Dart 答应了：它收完摊会自己调 `close`（那条走
            // RequestChildWindowDestroy），这里什么都不用做
            [](const flutter::EncodableValue* result) {},
            // Dart 那边慌了 / 没接这一手：照老路直接销毁
            [hwnd](const std::string& code, const std::string& message,
                   const flutter::EncodableValue* details) {
              std::cerr << "[窗口] Dart 不收这个摊（" << code
                        << "）：照老路直接销毁" << std::endl;
              RequestChildWindowDestroy(hwnd);
            },
            // 通道没人接（文章窗 / 网页窗没装这一手）：同上
            [hwnd]() {
              std::cerr << "[窗口] 这扇窗没接关闭请求：照老路直接销毁" << std::endl;
              RequestChildWindowDestroy(hwnd);
            }));
    // 兜底定时器：Dart 收了但没收完（或者压根没人答）也不能把窗留在那儿。
    // 定时器挂在帮助窗上（不走 Flutter），id 就用目标句柄，到点见 `ChildCloseHelperProc`。
    if (const HWND helper = ChildCloseHelperWindow(); helper != nullptr) {
      ::SetTimer(helper, reinterpret_cast<UINT_PTR>(hwnd), kChildCloseGraceMs,
                 nullptr);
    }
    return 0;
  }

  if (channel != nullptr) {
    // 又按了一下（用户不耐烦双击了）：**还是不能拆**。Dart 那边收摊可能还在
    // 半路（`engine.close()` 正在放媒体），这时候拆引擎就是那个 abort。
    // 安静地忽略掉 —— 收摊本身有 3 秒封顶，之后它一定会自己关。
    std::cerr << "[窗口] 关闭请求重复：Dart 还在收摊，等一下" << std::endl;
    return 0;
  }
  // 这扇窗根本没有那条通道（理论上到不了：通道是建窗时就挂的）
  RequestChildWindowDestroy(hwnd);
  return 0;
}

std::wstring Utf8ToUtf16(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                         static_cast<int>(utf8.size()), nullptr,
                                         0);
  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                        static_cast<int>(utf8.size()), wide.data(), size);
  return wide;
}

void RegisterChildWindowChannel(flutter::FlutterViewController* controller) {
  // 注意：`view()` 给的是窗内那颗**视图**窗口（Flutter 画布的那个子窗口），
  // 标题栏、任务栏项都挂在它上面那层**顶层**窗口上 —— 所以要先爬到 GA_ROOT。
  // （第一次没爬，SetWindowTextW 返回 true 但标题栏还是空的。）
  HWND hwnd =
      ::GetAncestor(controller->view()->GetNativeWindow(), GA_ROOT);
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            controller->engine()->GetRegistrarForPlugin(
                                "GracelinkChildWindow"));
  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "gracelinkim/child_window",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [hwnd](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "setTitle") {
          const auto* title = std::get_if<std::string>(call.arguments());
          if (title == nullptr || hwnd == nullptr) {
            result->Error("bad_args", "setTitle 需要一个字符串");
            return;
          }
          ::SetWindowTextW(hwnd, Utf8ToUtf16(*title).c_str());
          result->Success(flutter::EncodableValue(true));
        } else if (method == "guardClose") {
          // 「这扇窗的 ✕ 先交给我收摊」（通话窗那颗 webrtc 媒体引擎必须先放
          // 干净，否则拆引擎会 abort 整个进程，见文件头那段「S12.29」）。
          // **没声明的窗一律「✕ 就是关掉」**，见 `g_child_close_guarded`。
          if (hwnd != nullptr) {
            g_child_close_guarded.insert(hwnd);
          }
          result->Success(flutter::EncodableValue(true));
        } else if (method == "close") {
          // 「我收完摊了，拆吧」——不能回头去 PostMessage(WM_CLOSE)：那条路
          // 现在会先问 Dart（✕ 那条），于是 Dart 又收到一次 close_requested，
          // 两边你问我我问你就转不完了。这里直接走销毁那一手。
          RequestChildWindowDestroy(hwnd);
          result->Success(flutter::EncodableValue(true));
        } else if (method == "setSize") {
          // 逻辑像素（和窗口自己那套 DPI 缩放对齐），只改尺寸不动位置。
          const auto* size = std::get_if<flutter::EncodableMap>(call.arguments());
          if (size == nullptr || hwnd == nullptr) {
            result->Error("bad_args", "setSize 需要一个 {w,h}");
            return;
          }
          const double scale = ::GetDpiForWindow(hwnd) / 96.0;
          // Dart 那边可能是 int 也可能是 double，两种都收
          auto number_of = [&size](const char* key) -> double {
            const auto& value = size->at(flutter::EncodableValue(key));
            if (const auto* d = std::get_if<double>(&value)) return *d;
            if (const auto* i = std::get_if<int64_t>(&value)) {
              return static_cast<double>(*i);
            }
            return 0.0;
          };
          int width = static_cast<int>(number_of("w") * scale);
          int height = static_cast<int>(number_of("h") * scale);
          RECT rect{};
          ::GetWindowRect(hwnd, &rect);
          ::SetWindowPos(hwnd, nullptr, rect.left, rect.top, width, height,
                         SWP_NOZORDER | SWP_NOACTIVATE);
          result->Success(flutter::EncodableValue(true));
        } else if (method == "center") {
          // 居中到它所在那个显示器的**工作区**（不算任务栏）
          if (hwnd == nullptr) {
            result->Error("no_hwnd", "拿不到子窗口句柄");
            return;
          }
          RECT rect{};
          ::GetWindowRect(hwnd, &rect);
          MONITORINFO info{};
          info.cbSize = sizeof(MONITORINFO);
          ::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                           &info);
          const int width = rect.right - rect.left;
          const int height = rect.bottom - rect.top;
          const int x = info.rcWork.left +
                        ((info.rcWork.right - info.rcWork.left) - width) / 2;
          const int y = info.rcWork.top +
                        ((info.rcWork.bottom - info.rcWork.top) - height) / 2;
          // rcWork 那几项是 LONG，x/y 是 int —— 显式转成 int 再比，
          // 不然 std::max 推不出同一个类型（编译期直接报错）。
          ::SetWindowPos(hwnd, nullptr,
                         std::max(x, static_cast<int>(info.rcWork.left)),
                         std::max(y, static_cast<int>(info.rcWork.top)), 0, 0,
                         SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSIZE);
          result->Success(flutter::EncodableValue(true));
        } else if (method == "show") {
          // 窗口是 hiddenAtLaunch 建的（免得先看到一个 800×600 的闪一下）：
          // 标题、尺寸、位置都就绪了再由子窗口自己叫它出来。
          if (hwnd != nullptr) {
            ::ShowWindow(hwnd, SW_SHOW);
            ::SetForegroundWindow(hwnd);
          }
          result->Success(flutter::EncodableValue(true));
        } else if (method == "bounds") {
          RECT rect{};
          if (hwnd != nullptr && ::GetWindowRect(hwnd, &rect)) {
            flutter::EncodableMap out;
            out[flutter::EncodableValue("x")] =
                flutter::EncodableValue(rect.left);
            out[flutter::EncodableValue("y")] =
                flutter::EncodableValue(rect.top);
            out[flutter::EncodableValue("w")] =
                flutter::EncodableValue(rect.right - rect.left);
            out[flutter::EncodableValue("h")] =
                flutter::EncodableValue(rect.bottom - rect.top);
            result->Success(flutter::EncodableValue(out));
          } else {
            result->Error("no_hwnd", "拿不到子窗口句柄");
          }
        } else if (method == "setPip") {
          // 画中画小窗（S12.31）：进 = 去边框 + 不占任务栏（WS_EX_TOOLWINDOW）
          // + 置顶（HWND_TOPMOST）+ 挪到工作区右下角；出 = **原样还回去**
          // （样式与位置都是进之前存下的那一份，不重新居中、不改大小）。
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr || hwnd == nullptr) {
            result->Error("bad_args", "setPip 需要一个 {on, w, h}");
            return;
          }
          const bool on = BoolOf(*args, "on");
          const double scale = WindowScale(hwnd);
          const int width =
              std::max(1, static_cast<int>(DoubleOf(*args, "w") * scale));
          const int height =
              std::max(1, static_cast<int>(DoubleOf(*args, "h") * scale));
          if (on) {
            // 只在第一次进的时候存：连着进两次不该把「小窗那一份」当成原样
            if (g_child_pip_states.find(hwnd) == g_child_pip_states.end()) {
              PipState state;
              state.style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
              state.ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
              ::GetWindowRect(hwnd, &state.rect);
              g_child_pip_states[hwnd] = state;
            }
            std::cerr << "[窗口] 进画中画小窗" << std::endl;
            const LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
            const LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
            // 标题栏/边框/最大化那一套全去掉（系统菜单也跟着去掉）
            ::SetWindowLongPtr(hwnd, GWL_STYLE,
                               (style & ~(WS_CAPTION | WS_THICKFRAME |
                                          WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
                                          WS_SYSMENU)) |
                                   WS_POPUP);
            // 不进任务栏、不进 alt-tab
            ::SetWindowLongPtr(
                hwnd, GWL_EXSTYLE,
                (ex_style & ~WS_EX_APPWINDOW) | WS_EX_TOOLWINDOW);
            // WS_EX_TOOLWINDOW 这一点要一次隐藏/显示才会反映到任务栏上
            // （不这么做，小窗在任务栏上还挂着一颗按钮）
            ::ShowWindow(hwnd, SW_HIDE);
            ::ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            const RECT work = WorkAreaOf(hwnd);
            const int margin = static_cast<int>(24 * scale);
            const int x = std::max(static_cast<int>(work.left),
                                   static_cast<int>(work.right) - width -
                                       margin);
            const int y = std::max(static_cast<int>(work.top),
                                   static_cast<int>(work.bottom) - height -
                                       margin);
            ::SetWindowPos(hwnd, HWND_TOPMOST, x, y, width, height,
                           SWP_FRAMECHANGED);
            ::SetForegroundWindow(hwnd);
          } else {
            const auto it = g_child_pip_states.find(hwnd);
            if (it != g_child_pip_states.end()) {
              const PipState state = it->second;
              g_child_pip_states.erase(it);
              std::cerr << "[窗口] 退出画中画小窗" << std::endl;
              ::SetWindowLongPtr(hwnd, GWL_STYLE, state.style);
              ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, state.ex_style);
              ::ShowWindow(hwnd, SW_HIDE);
              ::SetWindowPos(hwnd, HWND_NOTOPMOST, state.rect.left,
                             state.rect.top, state.rect.right - state.rect.left,
                             state.rect.bottom - state.rect.top,
                             SWP_FRAMECHANGED);
              ::ShowWindow(hwnd, SW_SHOWNOACTIVATE);
              ::SetForegroundWindow(hwnd);
            }
          }
          result->Success(flutter::EncodableValue(true));
        } else if (method == "dragBegin" || method == "dragUpdate" ||
                   method == "dragEnd") {
          // 拖窗（小窗里按住画面拖那一下）：begin 记住「按下时的光标与窗口位置」，
          // update 按**当前光标**算位移，end 收摊。位置永远是系统给的屏幕坐标，
          // 不看 Dart 那边报的 delta（理由见 [DragState]）。
          if (hwnd == nullptr) {
            result->Error("no_hwnd", "拿不到子窗口句柄");
            return;
          }
          if (method == "dragBegin") {
            DragState state;
            if (!::GetCursorPos(&state.cursor)) {
              result->Success(flutter::EncodableValue(false));
              return;
            }
            ::GetWindowRect(hwnd, &state.rect);
            g_child_drag_states[hwnd] = state;
            result->Success(flutter::EncodableValue(true));
          } else if (method == "dragUpdate") {
            const auto it = g_child_drag_states.find(hwnd);
            if (it == g_child_drag_states.end()) {
              result->Success(flutter::EncodableValue(false));
              return;
            }
            POINT cursor{};
            if (!::GetCursorPos(&cursor)) {
              result->Success(flutter::EncodableValue(false));
              return;
            }
            const int width = it->second.rect.right - it->second.rect.left;
            const int height = it->second.rect.bottom - it->second.rect.top;
            MoveWindowClamped(hwnd,
                              it->second.rect.left +
                                  (cursor.x - it->second.cursor.x),
                              it->second.rect.top +
                                  (cursor.y - it->second.cursor.y),
                              width, height);
            result->Success(flutter::EncodableValue(true));
          } else {
            g_child_drag_states.erase(hwnd);
            result->Success(flutter::EncodableValue(true));
          }
        } else {
          result->NotImplemented();
        }
      });
  g_child_window_channels.push_back(channel);
  // ✕ 时要顺着 HWND 找回来问一声（见文件头「S12.29」那段）
  if (hwnd != nullptr) {
    g_child_close_channels[hwnd] = channel;
  }

  // 顶层窗口的消息先给这道委托过一眼（插件自己那颗窗口会调
  // HandleTopLevelWindowProc，所以这里的 ✕ 拦得住）。
  registrar->RegisterTopLevelWindowProcDelegate(ChildWindowProcDelegate);
}

/// `gracelinkim/media_session`：灵听在放什么 → 系统那张「正在播放」卡片。
///
/// 每颗引擎都挂一条：桌面流程里放歌的是灵听窗口那颗引擎，但窗口拉窄到 900 以下时
/// 灵听是整页开在主窗口里的，那时放歌的就是主窗口这颗。
void RegisterMediaSessionChannel(flutter::FlutterViewController* controller) {
  HWND hwnd = ::GetAncestor(controller->view()->GetNativeWindow(), GA_ROOT);
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            controller->engine()->GetRegistrarForPlugin(
                                "GracelinkMediaSession"));
  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "gracelinkim/media_session",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [hwnd, channel](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        const auto* raw = std::get_if<flutter::EncodableMap>(call.arguments());
        const flutter::EncodableMap empty;
        const flutter::EncodableMap& map = raw != nullptr ? *raw : empty;

        if (call.method_name() == "update") {
          auto session = EnsureMediaSession(hwnd);
          if (session == nullptr) {
            // 系统那边不给会话（旧系统 / 被策略挡了）：不是错，静默降级
            result->Success(flutter::EncodableValue(false));
            return;
          }
          session->channel = channel;  // 系统那几颗键要回得来
          try {
            auto controls = session->controls;
            controls.PlaybackStatus(BoolOf(map, "playing")
                                        ? MediaPlaybackStatus::Playing
                                        : MediaPlaybackStatus::Paused);
            auto updater = controls.DisplayUpdater();
            updater.Type(MediaPlaybackType::Music);
            auto music = updater.MusicProperties();
            music.Title(winrt::to_hstring(StringOf(map, "title")));
            music.Artist(winrt::to_hstring(StringOf(map, "artist")));
            music.AlbumTitle(winrt::to_hstring(StringOf(map, "album")));
            const std::string cover = StringOf(map, "cover");
            if (!cover.empty()) {
              try {
                // 封面直接甩 URL 给系统（它自己去拿，也会自己缓存）
                updater.Thumbnail(winrt::Windows::Storage::Streams::
                                      RandomAccessStreamReference::CreateFromUri(
                                          winrt::Windows::Foundation::Uri(
                                              winrt::to_hstring(cover))));
              } catch (...) {
                // 封面没拿到（URL 不对 / 断网）不影响歌名歌手
              }
            }
            updater.Update();

            const double duration = DoubleOf(map, "duration");
            if (duration > 0) {
              winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties
                  timeline;
              timeline.StartTime(winrt::Windows::Foundation::TimeSpan{0});
              timeline.MinSeekTime(winrt::Windows::Foundation::TimeSpan{0});
              timeline.MaxSeekTime(
                  winrt::Windows::Foundation::TimeSpan{TicksOf(duration)});
              timeline.EndTime(
                  winrt::Windows::Foundation::TimeSpan{TicksOf(duration)});
              timeline.Position(winrt::Windows::Foundation::TimeSpan{
                  TicksOf(DoubleOf(map, "position"))});
              controls.UpdateTimelineProperties(timeline);
            }
          } catch (...) {
            // 系统那张卡片是锦上添花：出错也不能影响放歌
          }
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "clear") {
          auto session = FindMediaSession(hwnd);
          if (session != nullptr) {
            try {
              session->controls.PlaybackStatus(MediaPlaybackStatus::Closed);
              auto updater = session->controls.DisplayUpdater();
              updater.ClearAll();
              updater.Update();
            } catch (...) {
            }
          }
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
  g_media_session_channels.push_back(channel);
}

}  // namespace

/// `gracelinkim/tray`：托盘菜单与气泡的文字（**由 Dart 递进来**，见
/// `lib/features/desktop_window/tray_native.dart`）。
///
/// 文案的唯一事实来源是 `assets/i18n` 那 7 份语言包，只有 Dart 读得到 ——
/// 所以这里一个字都不翻译，收下来就是。
void RegisterTrayChannel(flutter::FlutterViewController* controller,
                         TrayIcon* tray) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            controller->engine()->GetRegistrarForPlugin(
                                "GracelinkTray"));
  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "gracelinkim/tray",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [tray](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "configure") {
          result->NotImplemented();
          return;
        }
        const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
        if (map == nullptr || tray == nullptr) {
          result->Error("bad_args", "configure 需要一个 {open,exit,balloon}");
          return;
        }
        auto text_of = [map](const char* key) -> std::wstring {
          const auto entry = map->find(flutter::EncodableValue(key));
          if (entry == map->end()) {
            return std::wstring();
          }
          const auto* value = std::get_if<std::string>(&entry->second);
          if (value == nullptr) {
            return std::wstring();
          }
          return Utf8ToUtf16(*value);
        };
        tray->SetLabels(text_of("open"), text_of("exit"), text_of("balloon"));
        result->Success(flutter::EncodableValue(true));
      });
  g_tray_channels.push_back(channel);
}

/// `gracelinkim/app_info`：本机**版本名 + 内部号**（Dart 那边
/// `lib/core/platform/app_version.dart` 读它，「检查更新」拿这两样跟服务端清单比）。
///
/// 为什么要这条（2026-10-09）：在这之前只有安卓那边有实现
/// （`MainActivity.kt` 走 PackageManager），PC 上调用会抛 MissingPluginException，
/// Dart 侧退回「常量兜底」—— 于是 PC 报给「检查更新」的内部号**永远是 0**，
/// 只能靠版本名去凑（那段兜底说明见 `lib/data/model/app_update.dart`）。
///
/// 数据来源是**编译期的宏**，不是去读资源里的版本字段：CMake 把 `pubspec.yaml`
/// 的 `version:` 原样递进来（见 `windows/runner/CMakeLists.txt` 那几行
/// `FLUTTER_VERSION` 定义），所以这里拿到的就是发版时 pubspec 里那一个值，
/// 工程里没有第二份需要人肉对齐的副本。
void RegisterAppInfoChannel(flutter::FlutterViewController* controller) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            controller->engine()->GetRegistrarForPlugin(
                                "GracelinkAppInfo"));
  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "gracelinkim/app_info",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "version") {
          result->NotImplemented();
          return;
        }
        // 版本名 = `FLUTTER_VERSION` 加号前那一半（`1.0.0+261008` → `1.0.0`）；
        // 内部号直接取 CMake 递进来的那个整数（同 pubspec 加号后那一半）。
        std::string name = FLUTTER_VERSION;
        const auto plus = name.find('+');
        if (plus != std::string::npos) {
          name = name.substr(0, plus);
        }
        flutter::EncodableMap payload;
        payload[flutter::EncodableValue("name")] = flutter::EncodableValue(name);
        payload[flutter::EncodableValue("code")] =
            flutter::EncodableValue(static_cast<int32_t>(FLUTTER_VERSION_BUILD));
        result->Success(flutter::EncodableValue(payload));
      });
  g_app_info_channels.push_back(channel);
}

bool FlutterWindow::main_window_closing_ = false;

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // S12.24：系统媒体控制（SMTC）。主窗口这颗引擎也挂上：窗口拉窄到 900 以下时
  // 灵听是整页开在主窗口里的，那时放歌的是它。
  RegisterMediaSessionChannel(flutter_controller_.get());
  // 本机版本号（「我的」页那行、检查更新都要它）
  RegisterAppInfoChannel(flutter_controller_.get());

  // S12.36：系统托盘。加不上（外壳没起 / 通知区被策略挡）只记一行日志，
  // 别的功能都不受影响 —— 那时关窗就退回原来那套「关掉就是退出」。
  tray_.Add(GetHandle(), L"Gracelink");
  RegisterTrayChannel(flutter_controller_.get(), &tray_);

  // S12.22：desktop_multi_window 开的每个窗口都是**另一颗 Flutter engine**，
  // 插件不会自动跟过去（方法通道不跨引擎）。这里挂一道回调，新窗口一建出来
  // 就把同一批插件注册进它那颗引擎 —— 不挂的话子窗口里 shared_preferences、
  // url_launcher 这些插件直接 MissingPluginException。
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    RegisterPlugins(flutter_view_controller->engine());
    RegisterChildWindowChannel(flutter_view_controller);
    RegisterMediaSessionChannel(flutter_view_controller);
  });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

/// 缩回托盘：窗口藏起来，进程一切照旧。
///
/// 为什么是 `SW_HIDE` 而不是最小化：最小化还会在任务栏留一个按钮，而用户要的
/// 是「底部栏上找不到它、右边小箭头里才看得到」—— 那就是隐藏。
void FlutterWindow::HideToTray() {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }
  ::ShowWindow(handle, SW_HIDE);
  tray_hidden_ = true;
  std::cerr << "[托盘] 主窗口已缩进托盘 (tray-hidden)" << std::endl;
  if (!tray_balloon_shown_) {
    // 只说一次（跟微信一样）：第二次关说明用户已经知道它去哪儿了
    tray_balloon_shown_ = true;
    tray_.ShowBalloon(L"Gracelink", tray_.balloon());
  }
}

/// 从托盘里放回来（左键 / 双击 / 菜单第一项）。
void FlutterWindow::RestoreFromTray() {
  HWND handle = GetHandle();
  if (handle == nullptr) {
    return;
  }
  ::ShowWindow(handle, ::IsIconic(handle) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(handle);
  tray_hidden_ = false;
  std::cerr << "[托盘] 主窗口已恢复 (tray-shown)" << std::endl;
}

/// 托盘菜单里点「退出」：这一条才是真的退出。
///
/// 走 `PostMessage(WM_CLOSE)` 而不是 `DestroyWindow`：托盘菜单是在我们的窗口过程
/// 里弹的（`TrackPopupMenu` 是同步的），在那一刻销毁窗口＝在自己这条栈上把窗口
/// 拆掉，后面 `WM_NULL` 那条收尾消息还会打到已经没了的窗口上。
/// 消息转到下一次循环时，[quitting_from_tray_] 已经是 true，`WM_CLOSE` 就落到
/// 原来那条「真的关」的路径上。
void FlutterWindow::QuitFromTray() {
  HWND handle = GetHandle();
  quitting_from_tray_ = true;
  if (handle == nullptr) {
    return;
  }
  ::ShowWindow(handle, SW_HIDE);  // 别让它在销毁的半路上闪一下
  ::PostMessageW(handle, WM_CLOSE, 0, 0);
}

/// 托盘图标发回来的鼠标事件（`NOTIFYICON_VERSION_4`：低 16 位是鼠标消息）。
void FlutterWindow::OnTrayMessage(LPARAM lparam) {
  switch (LOWORD(lparam)) {
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      RestoreFromTray();
      return;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU: {
      const int command = tray_.ShowMenu(GetHandle());
      if (command == TrayIcon::kMenuOpen) {
        RestoreFromTray();
      } else if (command == TrayIcon::kMenuExit) {
        QuitFromTray();
      }
      return;
    }
    default:
      return;
  }
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // S12.22：主窗口只要收到关闭/销毁，就标记「这次退出是用户真的关了主窗口」。
  // 标记要在交给 Flutter 之前打：HandleTopLevelWindowProc 可能把消息吃掉。
  // S12.36：**关窗 ≠ 退出** —— 缩回托盘，进程、WebSocket、铃声全都留着
  // （用户 2026-10-06 要的就是微信那套：从底部栏右边那个小箭头点开还能看到、
  // 来电消息照样收得到）。真退出只有托盘菜单里那一项，见 [QuitFromTray]。
  if (message == WM_CLOSE && tray_.added() && !quitting_from_tray_) {
    HideToTray();
    return 0;
  }

  if (message == TrayIcon::kCallbackMessage) {
    OnTrayMessage(lparam);
    return 0;
  }

  if (message == WM_DESTROY) {
    // 图标要在窗口还没消失前摘掉，不然通知区会留一颗点不动的残影
    tray_.Remove();
  }

  if (message == WM_CLOSE || message == WM_DESTROY) {
    main_window_closing_ = true;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
