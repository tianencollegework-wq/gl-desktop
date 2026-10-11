# macOS 版：可行性分析与落地计划

这份文档回答一个问题：**Android 与 Windows 都在跑了，macOS 能不能搞、要多少工、卡在哪。**
它只做判断与盘点，不是操作手册；真要发版那天，这里会长成 `windows-release.md` 那样的手册
（见 `docs/release/windows-release.md`）。

写于 2026-10-11，本机是 Windows（`flutter --version` → 3.44.2 stable / Dart 3.12.2），
**没有在真 Mac 上跑过一次** —— 下文凡是「读代码/读 pubspec 得出的结论」都标了证据，
凡是「只有真机能确定」的都写进最后一节。

---

## 一、结论先行

| 问题 | 答案 |
|---|---|
| 技术上能不能做 | **能**。Flutter 桌面这条路 macOS 是一等公民：三栏框架、独立窗口、托盘、7 种语言这些都是跨平台 Dart，一行不用改 |
| 最大的技术成本 | **`windows/runner/` 那 2164 行 C++ 原生层要用 Swift/AppKit 重写一遍**（Dart 侧接口不变，`lib/` 里的调用点一个字都不用动） |
| 要不要交那 99 美元 | **可以不交**（用户 2026-10-11：「来路不明无所谓」）。Flutter 的 macOS 工程默认就是本地签名（`CODE_SIGN_IDENTITY = "-"`，本仓 `macos/Runner.xcodeproj/project.pbxproj` 里已经是这个），Apple Silicon 上能跑。代价是**每个用户第一次打开要自己去「系统设置 → 隐私与安全性」点一下「仍要打开」** —— 而 macOS 15 起，「右键 → 打开」那条捷径已被苹果取消，只剩这一条路 |
| 没 Mac 能不能做 | **能，不是死结**：打包交给 GitHub 的 Mac 机器（公开仓库免费不限量），CI 还能自己把 App 真跑一遍做自动烟测；人眼验收租一台云 Mac，**$1/小时 起**，从 Windows 远程桌面连过去即可 |
| 建议顺序 | **不等任何人**：模板整改 + Swift 原生层 + CI 流水线现在就能做（不需要账号也不需要 Mac），先出一个能装的、未对外签名的 .dmg；哪天想省掉用户那两步手动放行，再买账号接公证 |

一句话：**没 Mac、不花钱都能做出来；唯一换不来的，是用户第一次要多点两下。**

---

## 二、产品决定（按微信电脑端与主流 Mac 软件的惯例定下来的）

用户 2026-10-11：「按微信电脑端和主流软件来吧」。下面这些**就这么定了，不用再问** ——
有异议直接改这一节。

| 事情 | 决定 | 为什么 |
|---|---|---|
| **点红叉** | 关掉窗口、程序继续在后台跑（Dock 图标与菜单栏图标都在），消息照收；第一次关窗提示一句「仍在后台运行」 | 微信 Mac 版就是这样；Mac 用户真正的「退出」是 ⌘Q 或菜单里的「退出 Gracelink」。⚠️ 模板现在写的是「关掉最后一个窗口就退出」（`macos/Runner/AppDelegate.swift` 的 `applicationShouldTerminateAfterLastWindowClosed → true`），**这一句必须改** |
| **菜单栏小图标** | 保留（等同 Windows 那个托盘），菜单两项：打开 Gracelink / 退出 | 微信 Mac 版也是「Dock + 菜单栏」两处都在 |
| **Dock 未读角标** | 做（`NSApp.dockTile.badgeLabel`，几十行） | 微信 / Telegram / Slack 都有，Mac 用户靠它知道有新消息 |
| **新消息提示** | 走 macOS 通知中心（本地通知，**不需要苹果账号**） | 主流 IM 都这样；比 Windows 那边「只有缩进托盘时弹一次气泡」更接近主流 |
| **快捷键** | 不用改 | 咱们自己只定义了「回车发送 / Shift+回车换行」（`chat_input.dart` 里的 `SingleActivator`），本来就是跨平台的；复制粘贴那些由 Flutter 按平台自动换键（Mac 上自动是 ⌘） |
| **退出方式** | ⌘Q + 应用菜单 + 菜单栏图标那个「退出」 | 模板自带的 `MainMenu.xib` 已经有标准应用菜单，不用自己画 |
| **芯片** | **只出 Apple Silicon（M 系列）** | 新 Mac 全是 M 芯片；要照顾 Intel 得另编一套、包大一倍，而 Flutter 自己都在淘汰 Intel Mac。代价：**老 Intel 苹果电脑装不了** |
| **最低系统版本** | 保持模板默认 **macOS 10.15** | 兼容面最大，不用额外改设置 |
| **卸载** | 「关于」页那一栏保留，点了把 App 移到废纸篓 | Mac 的惯例是拖到废纸篓，给个一键入口只是省事 |
| **自动更新** | 保持「提示有新版本 → 打开下载页」 | 没签名就**不能**自己替换自己（系统会拦）；Windows 那边现在也是这个做法 |

---

## 三、已经现成的部分（白拿）

这些都是跨平台 Dart，macOS 上直接可用：

* 桌面外壳与版式：`lib/core/platform/desktop_shell.dart`（500 封顶 + 宽窗三栏）、
  `lib/features/home/desktop_frame.dart`（左图标条 + 会话列 + 聊天区）；
* **系统级独立窗口**：`desktop_multi_window` 的 pubspec 明写 `linux macos windows`
  → 文章窗 / 灵听窗 / 媒体号窗 / 网页窗这条路 macOS 原生就支持
  （`lib/features/desktop_window/*`）；
* 托盘**行为**（关窗缩回托盘、进程与 WebSocket 留着）：与微信 macOS 版一致
  （它也是关窗后留在菜单栏），Dart 侧 `tray_native.dart` 只递文案，接口不用改；
* 7 份语言包、主题、`rpx` 版式、深色模式、右键菜单、回车发送；
* 聊天 / 通话 / 群语音的业务层：`flutter_webrtc` 的 pubspec 明写
  `android elinux ios linux macos windows`。

---

## 四、插件层体检（逐个 pubspec 读过）

判据是**每个包自己 `pubspec.yaml` 里 `flutter.plugin.platforms` 那一栏**，不是印象：

| 包 | macOS | 备注 |
|---|---|---|
| shared_preferences / path_provider / url_launcher | ✅ | 有 `*_foundation` / `*_macos` |
| just_audio | ✅ | `android ios macos web`（本仓那份 `third_party/just_audio_windows_plus` 是 Windows 专用，macOS 上不注册，不冲突） |
| image_picker / file_picker / record / video_player | ✅ | 选图 / 选文件 / 录音 / 视频播放都有 |
| flutter_image_compress / gal | ✅ | 发图前压缩、存到「照片」 |
| flutter_webrtc / mobile_scanner | ✅ | 通话、扫码 |
| **webview_flutter_wkwebview** | ✅ | `pubspec.lock` 里锁的是 **3.26.1**，它自己声明 `ios` + `macos`（`sharedDarwinSource: true`）→ 内嵌网页窗（WKWebView）在 macOS 上**比 Windows 还省事**（Windows 那份得用本仓 fork：`third_party/webview_flutter_windows`） |
| flutter_local_notifications | ✅ | 本地通知，macOS 支持（**不需要** APNs） |
| audio_service | ✅ | 注册了 darwin；灵听系统媒体卡片/媒体键能不能白拿要真机验（Windows 那份是自己写的 SMTC，必要的话 macOS 再补 ~100 行 `MPNowPlayingInfoCenter`） |
| firebase_messaging / firebase_core | ⚠️ | pubspec 里**没有 windows**，`push_token.dart` / `push_background.dart` 也都硬闸在 `Platform.isAndroid \|\| Platform.isIOS` → **桌面端（含 macOS）本来就不走远程推送**，靠常连 WebSocket。所以 macOS **不需要 APNs、不需要 Firebase 那条链**，桌面消息提醒沿用 Windows 那套（应用内横幅 / 托盘气泡） |
| **open_filex** | ❌ | 只有 `android ios`。全仓两处用它：`media_saver.dart`（打开下载的文件）、`app_installer.dart`（拉起安装包）→ 两处都**不是「少个插件」，是 macOS 上本来就得换路**（见第五节） |

**插件层结论：一个都不缺**（唯一缺的那个恰好是要换语义的）。这是 macOS 可行性里最好的一条消息。

---

## 五、要重写的原生层（真正的工作量）

Windows 那半是自己写的 C++（`windows/runner/`，共 2164 行），macOS 要有一份对等的 Swift。
Dart 侧通道名与方法名**逐个照搬**，`lib/` 不变：

| 通道 | Windows 实现 | macOS 对应 | 量级 |
|---|---|---|---|
| `gracelinkim/child_window` | `flutter_window.cpp` 主体：子窗口 标题/尺寸/居中/show/close、`setPip`（无边框 + 置顶 + 挪到右下角）、`dragBegin/Update/End`、`guardClose` / `close_requested` 那套「✕ 交给 Dart 先收摊」 | `NSWindow`：`styleMask`（子窗去标题栏）、`setContentSize`/`center`、`level = .floating` + `collectionBehavior`（小窗）、`mouseDragged` 换算光标位移、`windowShouldClose` 委托 | ≈ 400–600 行 |
| `gracelinkim/tray` | `tray_icon.cpp`：`Shell_NotifyIcon` + 自画菜单 | `NSStatusItem` + `NSMenu`（菜单文字仍由 Dart 递进来，接口一样） | ≈ 120–180 行 |
| `gracelinkim/app_info` | `flutter_window.cpp` 尾部：版本名 + 内部号 | 读 `CFBundleShortVersionString` / `CFBundleVersion` | ≈ 20 行 |
| `gracelinkim/media_session` | WinRT SMTC | 先试 `audio_service`（darwin 有实现）；不行再写 `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` | ≈ 0 或 120 行 |
| 关窗 → 缩回托盘 | `WM_CLOSE` 拦下来 `ShowWindow(SW_HIDE)` + 首次气泡 | `NSWindow.orderOut` + `NSApp.setActivationPolicy`；气泡在 macOS 上不流行，改用 `UNUserNotification` 或干脆不做 | ≈ 60 行 |
| **主窗口最小尺寸** | `win32_window.cpp` 的 `WM_GETMINMAXINFO`：客户区最小 **900×600 逻辑像素**（还按 DPI 与窗口边框换算过） | `NSWindow.contentMinSize = 900×600` | ≈ 5 行，**但别漏** |
| 崩溃兜底 | `main.cpp` 里的 VEH 调用栈（`crash_stack.txt`） | macOS 有自己的崩溃报告（`~/Library/Logs/DiagnosticReports`），**不用移植** | 0 |

主窗口**不需要**自画标题栏：Windows 那份用的是标准窗口边框（`CreateWindow(..., WS_OVERLAPPEDWINDOW, ...)`），
macOS 用系统红绿灯 + 默认菜单栏即可（`macos/Runner/Base.lproj/MainMenu.xib` 模板已经有一份 App 菜单）。

⚠️ 但那条**最小窗口尺寸**要照着搬：它不是外观问题 —— Windows 那边把客户区最小宽度钉在 900，
是为了不让手机版式（窄窗）回来，因为窄窗会**绕过「密码登录只对美国出口 IP 开放」那道闸门**
（见 `lib/features/login/password_login_policy.dart` 与 `win32_window.cpp` 里那段注释，
`test/core/desktop_window_min_size_test.dart` 读那份 C++ 钉着它）。macOS 这边必须在
`NSWindow.contentMinSize` 上同样钉住，并且**补一条对应的测试**（现在那条只认 Windows 那个文件）。

另外两个 Windows-only 的 Dart 分支，macOS 上要各加一条：

* `lib/data/media/window_state_probe_io.dart`：用 `user32.dll` 的 `IsIconic` 判「通话对方窗口是不是最小化了」。
  macOS 上现在返回 null（功能静默降级：不盯最小化）。要真做，走 `NSRunningApplication` / `CGWindowListCopyWindowInfo`；
* `lib/core/platform/webview_host.dart`：~~现在 `Platform.isWindows → WindowsWebViewHost`，
  其余桌面 → 降级页~~ —— **2026-10-11 已做**：`Platform.isMacOS → SystemWebViewHost`，
  也就是 `webview_flutter` 的 WKWebView（与手机同一套 Dart API，**不必另写一份
  `MacWebViewHost`**）。降级页就只剩 Linux 了。

---

## 六、系统集成与小坑（都是「一次没做对就卡一整天」的那种）

| 项 | 现状（`macos/` 是 `flutter create` 原样模板） | 要做的 |
|---|---|---|
| Bundle ID | `com.example.gracelinkim`（占位） | 改成 `cc.gracelink.im`（与 Android `applicationId`、Windows `CompanyName=Gracelink` 对齐）。**注册 App ID 需要账号**，所以这一条与公证一起排 |
| 图标 | Flutter 默认那片青色（`macos/Runner/Assets.xcassets/AppIcon.appiconset`） | 换成软件自己的 logo（源图 `assets/images/logo.png`，与官网 `make-logo.mjs` 那条同源）。**别重演官网那次「默认图标被当成自家 logo」的错** |
| **沙箱网络** | `Release.entitlements` 里**只有** `app-sandbox` | 必须补 `com.apple.security.network.client` —— 沙箱下**没有它连不出网**（Flutter 官方 macOS 构建文档也只把 `network.server` 给了 debug/profile）。漏了它的症状是「release 包能起、登录一直转圈」 |
| 权限文案 | `Info.plist` 没有 `NS*UsageDescription` 那几条 | 补 `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`（通话、扫码、录音）。缺了系统会**直接崩**而不是拒绝 |
| 摄像头 / 麦克风 | entitlements 里没有 | 补 `com.apple.security.device.camera` / `.audio-input` |
| 屏幕共享 | `screen_share_picker.dart` 走 `FlutterWebRTC.Method`（插件在 Android/macOS 实现） | macOS 上要拿「屏幕录制」权限（TCC）+ `com.apple.security.device.screen-capture`；macOS 15 起系统会定期重新征求同意 —— 第一次用时被弹框挡一下是正常的，要在界面上说明 |
| 文件访问 | 存图/存文件走 `media_saver.dart`：先 `getDownloadsDirectory()`（path_provider）再复制，用户主动选的路径走自写文件选择 | 沙箱下这是**两个不同的权限**：用户选的靠 `com.apple.security.files.user-selected.read-write`；而直接往「下载」目录写要 `com.apple.security.files.downloads.read-write`（少了它 `getDownloadsDirectory()` 拿得到路径但写不进去——Windows 上没有这层，所以这是移植时才会暴露的坑） |
| 卸载（关于页那一栏） | `app_uninstaller.dart` 找 `unins000.exe`，`if (!Platform.isWindows) return null` | macOS 没有卸载程序：改成「把 .app 移到废纸篓」（`NSFileManager.trashItem`）+ 可选清理 `~/Library/Application Support/...`。注意 macOS 习惯是**拖到废纸篓**，这一栏要不要保留值得商量 |
| 检查更新 | `app_update_flow.dart`：非 Android 一律 `openUrl(info.url)` → 交给系统浏览器 | macOS 上就是「打开 .dmg 地址」，**现有逻辑不用改**，只等 `update.json` 的 `macos.url` 填真地址（服务端现在还是 `example.com` 占位，官网下载页因此显示「即将上线」） |
| 单实例 | Windows runner 里有一套（`tlhelp32.h` 那段） | macOS：`NSRunningApplication` / 一把 named lock + 把已有窗口 `activate` 到前面 |

### 已经落地的（2026-10-11，本机改完、已推上 GitHub）

| 项 | 落成什么样 | 谁守着 |
|---|---|---|
| 沙箱联网 | 两份 entitlements 都补了 `network.client`，且两份**逐项对齐**（Debug 只多 `allow-jit` 与 `network.server` 两条调试专用的） | `test/core/macos_runner_test.dart` |
| 权限文案 | `Info.plist` 补相机 / 麦克风 / 照片（两条）/ 本地网络，另加 `LSApplicationCategoryType` | 同上 |
| 身份 | bundle id 换成 `cc.gracelink.im`（`AppInfo.xcconfig` 与 `project.pbxproj` 里 RunnerTests 那三处），Copyright 换成 Gracelink | 用例与安卓 `applicationId` 交叉断言 |
| 图标 | 七张换成本家的标，生成脚本 `tool/icons/make_macos_icons.js`（可重跑） | 用例按像素判据守着（圆角 / 品牌蓝 / 白形 / 四角透明） |
| 最小窗口 | `MainFlutterWindow.swift` 里 `contentMinSize` = 900×600 | `desktop_window_min_size_test.dart` 新增一条 |
| 网页窗 | macOS 走**系统那一支**（`webview_flutter` 的 WKWebView，与手机同一套 API）：原来那段注释写「只到安卓/iOS」是错的 | `desktop_windows_test.dart` 里的平台分流断言（⚠️ macOS 那一支要到真机上才跑得到） |

改到一半才发现的两件事（都记在图标脚本头部）：

* 源图 `tool/audit/icon-fg.png` 是**不透明的蓝底座 #008CFF + 白鸽**，不是「透明底 + 图形」——
  所以脚本不再另画底座（第一版白画了一层，被图标用例的像素判据当场敲出来）；
* 鸽形在底座里**偏左上**（占位 0.446 / 0.433），安卓那份也是 —— 三平台保持同一位移，别顺手居中。

**这批没做的**：

* **屏幕共享那条沙箱 entitlement 没敢写**：`com.apple.security.device.screen-capture` 这个键名
  找不到权威出处（确定的是它属于 TCC 那套「屏幕录制」授权），等真机试屏幕共享时再定；
* **托盘与关窗缩回后台没动**：`applicationShouldTerminateAfterLastWindowClosed` 现在还是 `true`
  （关掉最后一个窗口就退出）。那要连着 `NSStatusItem`、`windowShouldClose` 一起做，
  一次做完才敢推 —— 半成品会造出「关掉窗口后程序还在跑、却叫不回来」的状态。

---

## 七、签名与分发：不交那 99 美元是什么样

用户 2026-10-11：「来路不明无所谓」。那就不交，但**代价要说清楚**，别到时候被用户问倒：

| 状态 | 用户拿到手 |
|---|---|
| **咱们这条路**（Flutter 默认的本地签名，没有开发者身份） | 从浏览器下 .dmg → 拖进「应用程序」→ 第一次双击被拦（「Apple 无法验证…」）→ 去**系统设置 → 隐私与安全性**，在「安全性」那一块点**「仍要打开」**，输一次开机密码 → 之后就正常，系统会记住这个例外 |
| 出了名的「**已损坏，无法打开**」 | 这是**另一回事**：包在打包/下载时坏了或签名对不上（单纯没公证不会给这条）。常见解法是 `xattr -dr com.apple.quarantine /Applications/Gracelink.app`，但那只是**去掉下载标记、不修签名**，真遇到要先查包本身 |
| Developer ID 签名 + 公证（将来买了账号再说） | 双击就开，什么都不用点。**这才是对外分发的理想形态** |

⚠️ 一条硬事实：**macOS 15（Sequoia）起，「右键 → 打开」那条老捷径被苹果取消了**，
只认「系统设置 → 隐私与安全性 → 仍要打开」（那个按钮只在拦下的**一小时内**有效）。
（依据：Apple 支持文档「安全地打开 Mac 上的 App」<https://support.apple.com/en-us/102445>；
Sequoia 取消右键绕过的那条 <https://mjtsai.com/blog/2024/07/05/sequoia-removes-gatekeeper-contextual-menu-override/>。）
所以这事**不能只在页面上写一句「右键打开」** —— 下载页要给一块「第一次怎么打开」的说明，
中英双语，**并且把同一段话放进软件里的更新提示**。

给下载页的原文就照这三步写：

1. 把 Gracelink 从 .dmg 拖进「应用程序」；
2. 双击它 —— 会弹一句「Apple 无法验证」之类，点「完成 / 好」；
3. 打开**系统设置 → 隐私与安全性**，往下找到**安全性**，点**「仍要打开」**，输开机密码。

**那 99 美元买到的就是把这三步省掉**（外加公司身份可查，以及 iOS 那边反正也要它）：
Apple Developer Program → Developer ID 证书 → `notarytool` 公证 → `stapler staple` 订票。
证书一年一换，过期后已发的旧包照跑、发新包要重签；密钥走 CI 里的 base64 .p12 +
App Store Connect API key，**不进仓库**。真买就 iOS 与 macOS 一起买。

### 与 Windows 的对照

Windows 那边已经有一整条流水线（Inno Setup + 签名 + 向导自检，见 `windows-release.md`）。
macOS 这边**没有 Inno 的对等物**，也不需要：

```
flutter build macos --release          → build/macos/Build/Products/Release/Gracelink.app（Flutter 默认已带本地签名）
hdiutil create -volname Gracelink ...   → 出 Gracelink-1.0.0.dmg（系统自带，不用装额外工具）
# 买了账号之后才多这两步：
codesign 签 .app 与 .dmg → notarytool 提交公证 → stapler staple
```

版本号继续以 `pubspec.yaml: version: 1.0.0+261008` 为唯一真源：
`CFBundleShortVersionString` 取版本名、`CFBundleVersion` 取内部号，模板里已经这么接了
（`$(FLUTTER_BUILD_NAME)` / `$(FLUTTER_BUILD_NUMBER)`），所以 `tool/release/bump_version.dart` 那条链不用改。

**要不要上 Mac App Store？** 建议**先不上**：商店版必须走审核，而 IM 类应用的独立窗口、
菜单栏常驻、屏幕共享在商店规则下都要额外解释；而且上商店**必须**有那 99 美元的账号。
先做现在这条直发（.dmg）就行。

---

## 八、GitHub 这条路的可行性（用户提的，也是本项目的唯一出路）

先说一个现状：这台机器原本**根本不是 git 仓库**（`git remote -v` → `fatal: not a git repository`），
所以「用 GitHub 出包」的第一步是 `git init` + 建仓库，而不是配流水线。
**2026-10-11 已经做完了**：仓库在 <https://github.com/tianencollegework-wq/gl-desktop>
（公开、小号），本地 `git init -b main` + 两次提交（初始化 / macOS runner 整改），
提交作者一律用 GitHub 的匿名邮箱（`<id>+<login>@users.noreply.github.com`），**不暴露真邮箱**。

两个当时踩到、以后还会再踩的坑：

* **推送「推不动」、命令却一直在跑** —— 那是 Windows 的 Git Credential Manager 弹了个登录框
  在等你（终端里看不到）。`gh auth setup-git --hostname github.com` 把 git 的凭据交给 gh 之后，
  推送 4.7 秒就完成。以后 `git push` 卡住先想这一条。
* **`workflow` 是另一张票**：`gh auth login` 默认给的 scope 是 `gist read:org repo`，
  而 GitHub **拒绝**任何「创建 / 更新 `.github/workflows/…`」的推送，报
  `refusing to allow an OAuth App to create or update workflow … without 'workflow' scope`。
  要 `gh auth refresh -h github.com -s workflow` 再授一次权。拿到它之前，
  `.github/workflows/macos.yml` 先放在工作区里、用 `.git/info/exclude` 挡住 `git add -A`
  （**不是**写进 `.gitignore`，免得以后忘掉它还没进仓库）。

### 仓库：**公开**，放在小号上（用户 2026-10-11 定的）

理由很直白：**公开仓库的标准 runner（含 macOS）免费且不限量**，私有仓库才按分钟计费。
用户的想法是「小号 + 不宣传，基本没人会注意到」。这句话的实际情况说白一点：
公开就是公开，任何人搜得到、能 clone 全文，搜索引擎也可能收 —— 只是**不特意去找的话确实很难被看见**。
所以关键不在「藏」，而在**别把不该公开的东西放进去**。

公开之前先盘了一遍（2026-10-11）：

| 东西 | 现状 | 结论 |
|---|---|---|
| `android/key.properties`（签名口令） | 原本就在 `.gitignore` 里 | ✅ 不会进仓库 |
| `android/app/gracelink-release.keystore`（正式签名证书） | `*.keystore` 已忽略 | ✅ |
| `android/app/google-services.json`（Firebase 配置 + 安卓 API key） | **原本没忽略** | ⚠️ 已补进 `.gitignore`；将来安卓要上 CI，用 secret 注入 |
| 服务端地址与 `hostToken`（`lib/core/config/app_config.dart` 里硬编码） | 在代码里 | ⚠️ 这**不是新泄漏**：每个装出去的 APK 里都有这两样，装了就能翻出来；公开它不会更糟，但要知道它本来就在外面 |
| `dist/Gracelink-Setup-1.0.0.exe`（21 MB 成品） | 没忽略 | ⚠️ 已补 `/dist/`：成品不进代码仓库 |
| `website/node_modules`、`website/dist`、`crash_stack.txt`、各种 `.log` | 部分没忽略 | ⚠️ 已补齐 |

第一次构建的流水线已经写好：`.github/workflows/macos.yml`（手动点一下就能跑，也可以靠 `v*` tag 触发；
钉了 `macos-15` 与 `timeout-minutes: 40`，产物是带「应用程序」快捷方式的 .dmg，
并且会把**架构 / 签名 / 版本号**打出来 —— 正好回答第十一节里那几个「没验过」）。

### GitHub Actions 的 macOS runner（2026 年的实情）

* 标签：`macos-latest` / `macos-15` / `macos-26`（都是 **arm64**），Intel 要显式用 `macos-15-intel`；
  `macos-13` 已退役，`macos-14` 公告 2026-11-02 起不再支持 → **钉 `macos-15` 或 `macos-26`**，别用 `latest`；
* 镜像自带 Xcode（macOS 15 镜像上默认 16.4，另有 26.x）与 **CocoaPods 1.17**；
  Flutter 3.44 起默认走 Swift Package Manager，没有 SPM 支持的插件才回落 CocoaPods；
* 计费：**公开仓库的标准 runner（含 macOS）免费且不限量**；私有仓库按分钟计费，
  macOS 标准 runner 挂牌 **$0.062/分钟**（Linux 是 $0.006/分钟，约 10 倍）。
  GitHub Free 私有仓库每月含 **2000 分钟**额度 → 按费率折算大约 **200 分钟 macOS 构建**；
  一次 macOS 构建（pub get + build + 签名 + dmg）现实里 5–12 分钟 → **每月约 20–40 次**，够用，超了也就几块钱一次。
  （注：GitHub 现在的文档已经不写「10 倍倍率」这句话，只写费率，上面是按费率折算的，不是官方口径。）

### 一次构建长什么样

```yaml
# 伪代码，真写的时候再落地；tag 触发
- checkout
- 装 Flutter（钉 3.44.2，与 pubspec 的 SDK 约束一致）
- flutter pub get
- flutter build macos --release        # ← 必须在 macOS runner 上
- 导入签名证书（来自 secrets）→ codesign → dmg → notarytool → staple
- 上传产物到 GitHub Release            # 免费，不用对象存储
```

**产物托管**：GitHub Releases 直接当下载源（免费、有直链、无需 CDN），
把 `update.json` 的 `macos.url` 指向它即可 —— 官网下载页那张「macOS 即将上线」的卡片
（`website/src/data/downloads.ts` 读 `update.json`）会自动变成可点。

另一条路（若不想把代码托管与 CI 绑在一起）：Codemagic / Bitrise 这类 Flutter 专用 CI 也有
macOS 构建与免费额度。**我没核过它们 2026 年的额度与价格**，真要走这条我再查一遍。

### 「没有 Mac」怎么破（用户的实际处境：只有 Windows）

三件事分开看：

* **能不能出包 —— 能。** 全交给 GitHub 的 Mac 机器，本机 Windows 一行 Mac 命令都不用敲；
* **能不能自动验一部分 —— 能。** CI 不只是编译，它**能真把 App 跑起来**跑集成测试
  （`flutter test integration_test -d macos`）。⚠️ 已知坑：有人在 `macos-15` 上遇到「App 起来了、
  前台化失败（`open returned 1`）然后挂住」，钉 `macos-14` 能绕开 —— 所以这条链**必须加超时**，
  别让它静静挂一小时还扣钱；
* **人眼那一眼（看排版、点几下、听声音）—— 自动化替代不了**，所以租一台云 Mac：

| 服务 | 大致价（2026 年公开价） | 备注 |
|---|---|---|
| **MacinCloud 按需付费** | **$1/小时、$4/天** 起 | 最省钱的「试半小时」；有 macOS 26 机器 |
| MacinCloud 包月 | $25/月起 | 长期用 |
| MacStadium | $109/月起（M2 Mac mini） | 按月租，适合以后常态化 |
| Scaleway Apple Silicon | 未核到现价 | **最短租 24 小时** |
| AWS EC2 Mac | 按机型，**最短 24 小时** | 短测不划算 |

它们都能从 Windows 用远程桌面（VNC / Apple Remote Desktop）连上去。
所以「没 Mac」的解法是：**平时靠 CI，关键节点花几美元租一小时，人眼过一遍**。
（价格来源：<https://www.macincloud.com/pages/payg.html>、<https://macstadium.com/pricing>、
<https://www.scaleway.com/en/docs/apple-silicon/quickstart/>；CI 能跑 App 那条
见 Flutter 集成测试文档 <https://docs.flutter.dev/testing/integration-tests> 与
GitHub 上实际这么干的例子 <https://github.com/isar/isar/blob/main/.github/workflows/test.yaml>。）

---

## 九、工作量与顺序

按一个人、有 Windows 那份做参照来估（**不含**真机调试的往返时间）。注意「前置」这一栏
现在基本没有门槛了：**编译全在 CI 上（不需要 Mac），验收花几美元租一小时云 Mac**。

| 块 | 内容 | 估时 | 前置 |
|---|---|---|---|
| A. 原生层 | 上面第五节那张表（child_window / tray / app_info / 关窗行为 + Dock 角标 + 系统通知），拿 Windows 那份对照着译 | 4–7 天 | 本机写代码 + CI 编译 |
| B. 系统集成 | bundle id、图标、entitlements、Info.plist、权限文案、`AppDelegate` 那句「关窗即退出」 | 2–3 天 | 同上 |
| C. 功能补齐 | 网页窗走 WKWebView、卸载改「移到废纸篓」、`open_filex` 两处换路、新消息提示、媒体卡片 | 3–5 天 | 同上 |
| D. 打包分发 | 出 .dmg、CI 流水线、CI 自动烟测、`update.json` 与官网联动、下载页那三步说明 | 2–4 天 | **不需要账号**（不签名路线） |
| E. 验收 | 第十节那张清单，逐条在 Mac 上过 | 2–4 天 | 一台 Mac（**可租**，$1/小时起） |
| | **合计** | **约 3–5 周** | |

### 建议顺序

1. **现在**（不需要账号也不需要 Mac）：`macos/` 整改（B 全部）+ 原生层（A）+ 网页窗那条（C 的一部分），
   在 CI 上跑通**未签名**的 `flutter build macos --release` 并出 .dmg
   （`.github/workflows/macos.yml` 已经写好，仓库推上去之后手动点一下就跑）；
2. **第一次验收**：花几美元租一台云 Mac，把第十节那张清单过一遍
   —— 在此之前，一切都只是「应该能跑」；
3. **哪天想省掉用户那两步手动放行**：买账号（iOS 与 macOS 同一张票）—— 注册 App ID `cc.gracelink.im`、
   出 Developer ID 证书、接公证、`stapler staple`，把 .dmg 换成签好的（只动 D 那一块）；
4. 之后 macOS 与 Windows 共用一条 `bump_version.dart` 发版链，只是多一个「出 dmg」的步骤。

---

## 十、验收清单（照 `windows-release.md` 第四节的写法）

**第一次打开按下载页那三步能装上（见第七节）** → 装（拖进「应用程序」）→ 登录页版本号对得上 → 扫码登录出二维码 →
单聊 / 群聊收发、发图（压缩）、语音消息、文件 →
1:1 通话（摄像头/麦克风权限框出现一次）→ 群语音 → 屏幕共享（要「屏幕录制」权限）→
灵听播放 + 系统媒体卡片/媒体键 + 封面 → 独立窗口（文章 / 灵听 / 媒体号 / **网页窗**）、
关掉还能再点开、只能有一扇 → 菜单栏图标 + 菜单两项（文案跟语言走）→
关窗留进程（来电/消息还收得到）→ 从菜单栏退出 → 关于页版本号 / 卸载（移到废纸篓）→
「检查更新」跳 .dmg → 7 种语言切换 + 语言持久化 → 深色模式 → 窗口拉宽/拉窄（三栏 ↔ 单栏）→
**窗口缩到最小：客户区不能小于 900×600，窄窗下不该出现密码登录表单**（那条闸门见第五节）。

---

## 十一、没验过的东西（照实记）

1. **一份都没在真 Mac 上跑过** —— 本机是 Windows。第四节的「插件齐全」是**读每个包 pubspec 声明**得的，
   不是跑通；补救办法就是第八节那两条：CI 自动跑一遍 + 租一小时云 Mac 人眼过一遍。
   第一节的估时里，A 那块的不确定性最大；
2. 沙箱 + 屏幕共享 / 摄像头在 macOS 上的具体坑（TCC 提示时序、macOS 15 的定期重授权）；
3. `desktop_multi_window` 在 macOS 上的子窗口行为 —— Windows 那份自己改过一版无边框/尺寸逻辑，
   插件在 macOS 上默认给什么样式要实测，`setPip` 那几条（无边框 + 置顶 + 右下角）也得对着 AppKit 重做一遍；
4. WebRTC 在 macOS 沙箱下的网络行为（本地网络权限 `NSLocalNetworkUsageDescription`、
   对称 NAT 下的打洞），这与 Windows 的表现不会完全一致；
5. 公证在 CI 里的具体报错（买了账号那天才会遇到：`notarytool` 对 entitlements 很挑，例如多余的 entitlement 会被拒）；
6. ~~要不要出 universal（arm64 + x86_64）~~ —— **已定：只出 Apple Silicon**（见第二节），
   要照顾 Intel 老机器的话得另编一套，先不做；
7. ~~关窗行为要用户拍板~~ —— **已按微信惯例定在第二节**（关窗留后台、⌘Q 真退出），
   至于好不好用，还得真 Mac 上试过才知道。
