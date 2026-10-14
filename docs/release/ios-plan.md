# iOS 版：落地计划与现状（2026-10-14 起）

用户 2026-10-14 的原话：「我圣诞节买开发者账号，我也没有苹果手机给你真机调试，也没有苹果电脑，
不过 iOS 代码层面你先完善一下，之前很多功能都还没适配。」
这份文档就是那件事的现场记录：**今天做完的、买号之后要做的、以及一件都没验过的。**

---

## 一、结论先行

1. **iOS 这条路现在"能编、能起、能开发"，只差身份与签名**：`ios/` 那份 Flutter 模板已经
   按这个 App 的真实需要整改过（权限文案、后台模式、包名、最低系统、entitlements、
   隐私清单），原生侧把我们自己那几条平台通道补上了（版本号 / 权限 / 系统设置 / 通话保活），
   Dart 侧跟着长出 iOS 分支（保活、后台开关）。
2. **一件事都不用等账号**：GitHub 上的 macOS runner 能编未签名的 iOS 包、能在模拟器上
   把 App 真跑一遍（`.github/workflows/ios.yml`）。所以「到底编不编得过、起不起得来」
   这两个问题，今天就有答案 —— **条件是先把仓库推上去、手点一下那个 workflow**。
3. **没有任何一行 Swift 被编译过**（开发机是 Windows，没有 Swift 工具链，也没有 Mac）。
   现在所有 iOS 原生代码的把握都来自「照着引擎头文件与插件源码写」，不是「编过」。
   这是这份文档最该被记住的一句话，第十一节照实列了全部没验过的东西。
4. **买号之后的第一件事不是写代码，是让 CI 跑绿**：先确认能编、能起，再往上加
   CallKit 来电界面那一层（那才是 iOS 上真正缺的大功能）。

---

## 二、为什么"没有 Mac"不等于"做不了 iOS"

与 macOS 那份计划书第八节同一个结论，这里只写差异：

| 事 | 需要什么 | 现在有没有 |
|---|---|---|
| 编 iOS 包（未签名） | 任意一台 macOS | ✅ GitHub runner（公开仓库免费不限量） |
| 在**模拟器**里把 App 跑起来 | 同上 | ✅ 同一个 runner 上 `simctl` + `integration_test/boot_smoke_test.dart` |
| 截图看界面（哪怕只是登录页） | 同上 | ✅ `xcrun simctl io screenshot`（产物里有，见工作流） |
| 装到**真机**上 | 开发者账号 + 一台 iPhone + 一台 Mac | ❌ 三样都没有 |
| TestFlight（自己或别人手机上装） | 开发者账号（$99/年）+ macOS + Xcode | ❌ 只差账号 |
| 上架 App Store | 同上 + 审核资料 | ❌ 见第九节 |

**关键差别**：认证/签名这件事可以完全放在 CI 上（证书塞进 secret，签名与上传都在 runner 上做），
所以「没有 Mac」从头到尾都不是死路 —— 真正缺的只有**账号**与**一台真机**。

---

## 三、买号之后的第一小时（照这个顺序做）

1. **建 App ID**：`cc.gracelink.im`（与 macOS 同一个身份，一份钱两个平台），
   Capabilities 里勾上 **Push Notifications**。
   ⚠️ 不勾的话，`ios/Runner/Runner.entitlements` 里那条 `aps-environment` 会让**签名直接失败**
   （entitlements 里有、描述文件里没有的东西一律被拒）。
2. **Xcode 打开 `ios/Runner.xcworkspace`**（不是 `.xcodeproj`）→ Signing & Capabilities →
   勾 Automatically manage signing + 选团队。Xcode 会自己建描述文件、把
   `CODE_SIGN_ENTITLEMENTS` 指向 `Runner/Runner.entitlements`（这条我们已经在工程里接好了，
   三份构建配置都接了）。
3. **接推送**（与安卓那套 FCM 是一家的，但 iOS 这一段必须在 Firebase 里做）：
   - Firebase 控制台 → 项目设置 → 添加 iOS 应用，Bundle ID 填 `cc.gracelink.im`；
   - 把 `GoogleService-Info.plist` 放进 `ios/Runner/`（**进仓库，与安卓的
     `google-services.json` 不一样**：它不含密钥，苹果那边本来就是明文分发）；
   - 项目设置 → 云消息 → APNs 认证密钥：上传 `.p8`（在苹果后台 Keys 里建，
     勾 Apple Push Notifications service），填 Key ID 与 Team ID。
   - 服务端那边**不用改**：iOS 走 FCM 的 token（`cid` 里还是 `fcm:` 前缀），
     由 FCM 转成 APNs 投递（见第七节）。
4. **跑一次 CI**：GitHub → Actions → 「iOS 构建与自检」→ Run workflow。
   绿了再往下做 CallKit；红了就先修红 —— 在那之前写更多 iOS 代码都是赌。
5. **出 TestFlight**：见第九节（要加一个签名 + 上传的 job，代码骨架留在
   `.github/workflows/ios.yml` 末尾的注释里）。

---

## 四、iOS 与安卓的机制对照（**同名不同实现**的那些）

| 能力 | 安卓（已验） | iOS（本轮做完，未编译验证） |
|---|---|---|
| 通话期间不被冻住 | `CallForegroundService` 前台服务 + 常驻通知 | `UIBackgroundModes: audio` + **激活的 `AVAudioSession`**（`IosCallKeepAlive`）；被打断（来电 / 闹钟 / Siri）后**自己恢复**，见第五节最后一条 |
| 灵听切后台继续响 | `audio_service` 前台服务 | `audio_session` 把会话设成 `playback` 并激活（`AudioSessionConfigurator`，2026-10-14 补） |
| 来电响铃 / 接听界面 | 全屏通知 + `setShowWhenLocked` | **没有**（要 CallKit + PushKit，见第六节） |
| 后台收到消息 | FCM 数据消息 → 后台 isolate 画通知 | 同一条路（FCM 经 APNs 投递），**但进程被用户划掉以后收不到**（苹果的硬限制） |
| 通知权限 | `POST_NOTIFICATIONS`（13+ 运行时权限） | `UNUserNotificationCenter` 授权框 |
| 「去系统设置」 | 应用详情页 / 通知设置页 / 电池优化页三个入口 | 只有 `openSettingsURLString`（本应用设置页）一个入口 |
| 电池优化白名单 | 有（不申请就会掉线） | **不存在**这个概念（恒 true，不显示那条提示） |
| 画中画 | 系统 PiP（`enterPipNow`） | 没有（要 `AVPictureInPictureController` + 一层视频视图） |
| 屏幕共享 | `MediaProjection` | 没有（要 ReplayKit 的广播扩展，且审核要额外说明） |
| 通话窗口盖锁屏 | `setCallScreenMode` | 没有（那是 CallKit 的事） |
| 系统媒体卡片（灵听） | `audio_service` 的媒体通知 | `audio_service` 的 darwin 那份（Now Playing / 锁屏 / 耳机键）；**后台播放要会话分类配合，见第六节** |

---

## 五、这一轮落地了什么（逐项）

**工程配置**（`ios/`）
* `Runner/Info.plist`：五条权限文案（相机 / 麦克风 / 相册读 / 相册写 / 本地网络）、
  `UIBackgroundModes = audio + remote-notification`（**故意没有 voip**，那是 PushKit 的，
  一起做时再加）、`ITSAppUsesNonExemptEncryption = false`（免掉每次上传的出口合规问答）、
  七种语言的 `CFBundleLocalizations`（iOS 只认这里）、`NSAllowsLocalNetworking`
  （开发时连局域网用 http）、`tel` / `app-settings` 进 `LSApplicationQueriesSchemes`。
* `Runner/Runner.entitlements`（新）：`aps-environment = development`，三份构建配置都接上。
* `Runner/PrivacyInfo.xcprivacy`（新）：上传 App Store 必须有的隐私清单（声明不追踪、
  按真实情况列出收集的数据类型）。⚠️ 光放文件是**不进包**的 —— 已经在
  `project.pbxproj` 里接好了引用（PBXBuildFile + PBXFileReference + group children
  + Resources 那一相），谁拆掉一处，`test/core/ios_runner_test.dart` 会直接报红。
* `Runner.xcodeproj/project.pbxproj`：包名 `com.example.gracelinkim` → **`cc.gracelink.im`**
  （与 macOS 同一个 App ID）、最低系统 **13.0 → 15.0**（`firebase_core` /
  `firebase_messaging` 那条要 15.0，见 `tool/audit/ios_support.js` 的输出）。
* **应用图标与启动图**（`tool/icons/make_ios_icons.js`，新）：模板里那 15 张图标是
  **Flutter 自己的青色标**（装上去桌面上就不是我们的东西），启动图更是三张 **1×1 的空图**
  （于是启动那一下是一片白，而应用内启动页画的是「白底 + logo」）。
  现在：图标从与安卓 / macOS **同一个源图**生成 —— 满幅、**不带 alpha 通道**
  （苹果在 App Store 那一步会拒透明图标，源图四角本来带透明，用同色底座铺平）；
  启动图从应用内那张 logo 生成（168 / 336 / 504，与启动页那 180 的方块接得上）。
  脚本自带验收：尺寸、有没有 alpha、四角颜色，当场对一遍。

**原生侧**（`ios/Runner/AppDelegate.swift`，一个文件里，**没有动工程文件**）
* `gracelinkim/app_info`：`version` → `{name, code}`（读 `Bundle`）。
* `gracelinkim/permissions`：`check` / `request`，摄像头 / 麦克风 / 通知，
  与安卓同一套语义（`granted` / `denied` / `permanentlyDenied` / `unsupported`）。
* `gracelinkim/app_settings`：通知权限查询、跳本应用设置页；电池那两条如实回
  「iOS 没有这个东西」（`true` / `false`），不伪造状态。
* `gracelinkim/call_service`：`start`（按语音/视频设 `playAndRecord` + `voiceChat`/`videoChat`
  并激活）/ `stop`（关会话，`notifyOthersOnDeactivation` 把音乐还回去）/ `isRunning` /
  `lastError` / 通知权限两条。
* **通话音频会话能从系统中断里爬回来（2026-10-14 补）**：`CallAudioSession` 现在把
  「通话还在不在」（`wanted`）与「会话此刻真不真活着」（`active`）**分开记** ——
  系统把会话顶掉时（来电、闹钟、Siri、别的应用抢喇叭）会话确实死了，可通话并没结束；
  合成一个值只能二选一：要么中断期间 `isRunning` 撒谎说「在跑」，要么中断结束后永远
  不恢复。现在挂上 `interruptionNotification`（`.ended` 且给了 `shouldResume`、且通话
  还在 → 按原分类重设并重新激活）与 `mediaServicesWereResetNotification`（媒体服务被
  系统重启后重设一遍），两者都复用同一个 `apply()`（少设一样东西就是「被电话打断一次
  之后视频通话不再外放」那种只有真机能发现的错）；挂断时摘掉观察者。
  修好之前的表现是：**被来电打断一次，这通电话就静默变哑，而诊断面板还说保活正常**。
  投屏与类型位那两条**故意回 notImplemented**（iOS 上没有这种东西，不假装成功）。
* 通道挂在 `engineBridge.applicationRegistrar` 上（引擎给「应用级通道」留的那条路，
  不是借插件的注册表）。

**Dart 侧**
* `lib/core/platform/call_keep_alive.dart`：新增 `IosCallKeepAlive`（同一条通道，
  另一个机制：激活音频会话而不是起服务；不用轮询确认、不编通知文案、投屏是空操作），
  provider 三端分流。
* `lib/core/platform/audio_session_configurator.dart`（新，2026-10-14）：**灵听在 iOS 上的
  后台播放**。以前 iPhone 上切后台 / 锁屏音乐会被系统停，根因是没人把 `AVAudioSession`
  设成 `playback` —— `just_audio` 的 darwin 源码里**一行都没碰这个类**（实测 grep 过）。
  现在起播前、继续播前各设一次（幂等），停止 / 播放器释放时把会话交还系统。
  `audio_session` 由传递依赖提成直接依赖（版本不变，仍是锁定的 0.2.4）；**只在 iOS 上
  有实际动作** —— 安卓那套（`audio_service` + `just_audio` 自己申请焦点）是真机验过的，
  不去多拧一颗螺丝。通话那条会话**不归它管**（分类不同：`playAndRecord` vs `playback`），
  两边各管各的。
* `lib/domain/lingting/lingting_player.dart`：四个接线点（起播前 / 继续播前 / `stop()` /
  播放器释放），每个点都再包一层 try ——音频会话那一步失败绝不能让音乐停下。
* `lib/core/platform/background_health.dart`：新增 `IosBackgroundHealth`（只有通知权限
  那一道是真的 → 红提示条与「设置 › 通知」那一行在 iPhone 上同样成立）。
* `call_keep_alive_notification_row.dart` 改成按平台判（那条「通话中」的常驻通知是安卓独有的）、
  `call_keep_alive_self_check.dart` 的自检说明按平台分开写。

**检查与文档**
* `test/core/ios_runner_test.dart`（新，20 条）：把上面每一条配置都钉住 —— 权限文案不能少、
  后台模式不能多也不能少、包名不能留 `com.example`、最低系统 ≥ 15.0、
  **每个通道的每个方法名都要与 Dart 侧对得上**（少了就是「功能静默消失」），
  以及「Dart 侧新加的通道必须说清 iOS 上谁来实现」。
* `test/core/call_keep_alive_test.dart` / `background_health_test.dart`：各加一组 iOS 契约用例。
* `test/core/audio_session_configurator_test.dart`（新，3 条，2026-10-14）：这一层的三条契约 ——
  非 iOS 上是空操作、iOS 那份「通道不在也只记一行、绝不抛」、按平台挑实现。
* `test/lingting/lingting_player_test.dart`（+5 条，2026-10-14）：钉住接线本身，尤其是
  **顺序**（`['music', 'startEngine']` —— 分类必须在出声**之前**生效）与「会话设不上
  也不影响播放」。
* `tool/audit/ios_support.js`（新）：读 pub 缓存列出每个依赖的 iOS 支持与**最低 iOS 版本**
  （`IPHONEOS_DEPLOYMENT_TARGET` 就是照着它的输出定的）。
* `.github/workflows/ios.yml`（新）：macOS runner 上编译（不签名）+ 模拟器真启动 + 截图。

---

## 六、还没做的（按优先级）

| # | 事 | 价值 | 依赖 | 估时 |
|---|---|---|---|---|
| 1 | **让 CI 跑绿一次**（编得过 + 模拟器起得来） | 把「应该能跑」变成「确实能跑」 | 仓库推上去 + 手点一下 | 1–2 小时（含修错） |
| 2 | **CallKit + PushKit 来电界面** | iPhone 上锁屏来电只有它是"系统级"的；现在只能靠一条普通通知 | 账号（VoIP 推送证书）+ 真机 | 4–7 天 |
| 3 | 服务端 VoIP 推送那条链 | 上面那条的一半（APNs VoIP topic、payload 形状） | 同上 + 服务端改 | 2–3 天 |
| 4 | ~~灵听在 iOS 的后台播放（`audio_session` 会话分类）~~ **2026-10-14 已写**（`AudioSessionConfigurator`；但 iPhone 上还没试过） | 修好前切后台音乐会被系统停（安卓有前台服务撑着） | 无 | 做完了 |
| 5 | 画中画（AVPictureInPictureController） | 通话切出去还能看着对方 | 真机 | 3–5 天 |
| 6 | 屏幕共享（ReplayKit 广播扩展） | 群里那个功能补齐 | 账号（App Extension）+ 真机 | 3–5 天 |
| 7 | 上架资料（隐私政策页、审核说明、账号删除入口） | 不写就上不了架 | 账号 | 2–3 天 |

**为什么把「CI 跑绿」排在第一位**：第六节那几项都要动 Swift，而现在这份 Swift 一行都没编译过；
在没验证的地基上继续加代码，只会把「一次修十个错」变成「一次修三十个」。

---

## 七、推送那条链（iOS 上是真的不一样，值得单独记一笔）

* **服务端不用改**：它给 iOS 设备发的还是 FCM（`cid` 前缀 `fcm:`），由 FCM 转成 APNs。
  这也是我们没走 APNs 直连的原因：安卓那边已经是一条链，多一条就多一套设备表。
* **要配的只有 Firebase 那三样**（第三节第 3 步：iOS 应用、`GoogleService-Info.plist`、APNs 密钥）。
* **苹果的硬限制（必须知道）**：
  1. 用户在后台**上滑划掉 App** 之后，普通推送（包括 `content-available` 的静默推送）
     **不会**再唤醒它 —— 通知仍会显示，但点击之前 App 不跑代码。
     安卓那边能靠前台服务熬过去，iOS 不行；**唯一例外是 VoIP 推送（PushKit）**，
     而它要求接 CallKit，所以这两件事必须一起做（第六节第 2 项）。
  2. 静默推送有节流（系统可能合并、延迟甚至丢弃），所以「靠推送做实时同步」在 iOS 上不成立，
     它只能用来弹通知。
  3. 通知权限被关掉之后，`requestAuthorization` 再调也是立刻返回 false（我们按
     `permanentlyDenied` 处理，与安卓第二次拒绝之后同一个口径）。

---

## 八、CI（`.github/workflows/ios.yml`）

* `build-ios`：`flutter analyze` + `flutter test` + `flutter build ios --release --no-codesign`
  + 打印产物里的版本号 / 后台模式 / 权限文案（**配错了那里就是空的**）。
* `simulator-smoke`：动态挑一台 iPhone 模拟器 → `flutter test integration_test/boot_smoke_test.dart -d <UDID>`
  → 截图 + 日志当产物。用例与 macOS 那条是同一个文件（判据用类型，不看文案）。
* 触发：手动（workflow_dispatch）、`v*` tag、以及**动到 `ios/**` 的 push**。
  平时改 Dart 不会触发它（macOS 构建十分钟起，没必要每次提交都等）。
* 模拟器这条路**不需要账号**，所以今天就能用 —— 唯一的门槛是把仓库推上去。

---

## 九、上传 App Store / TestFlight 要准备的东西

1. **签名**：证书导出成 `.p12`、描述文件、以及 App Store Connect 的 API Key
   （六个 secret 的名字写在 `.github/workflows/ios.yml` 末尾）。
2. **隐私清单**：`ios/Runner/PrivacyInfo.xcprivacy` 已经放好（插件各自的清单它们自己带，
   上传时会被合并）。上架前按当时的真实情况复核一遍收集项。
3. **审核备注**：这是个 IM + 音视频通话应用，审核大概率会要**测试账号**（用户名/密码各一份）
   以及「怎么发起一通电话」的说明；麦克风/摄像头用途说明已经在 Info.plist 里。
4. **账号删除入口**：苹果对「有账号体系的 App」要求应用内能注销账号 ——
   这一条现在**没有**，上架前必须补（也是第六节第 7 项的一部分）。
5. **出口合规**：`ITSAppUsesNonExemptEncryption = false` 已经答了，上传时不会再问。
6. **TestFlight**：内部测试（自己 + 100 人）不需要审核，外部测试要过一次轻量审核；
   所以「12 月买号 → 当天就能让 iPhone 用户装上」，走的是内部测试这条路。

---

## 十、验收清单（第一次拿到 Mac / 真机时照这个过）

模拟器上（CI 就能跑）：编得过 → 起得来（登录页）→ 七种语言里至少中英各切一次 →
设置 › 通知 里那一行在 → 会话列表那条红条在权限被拒时出现、开了之后消失。

真机上（要账号 + iPhone）：
装得上 → 登录（扫码 / 密码）→ 收消息（前台 + 后台 + 划掉 App 三种状态各看一次）→
通知权限框只弹一次 → **打电话**：麦克风权限 → 接通 → 切到后台 5 分钟**不断线**（这是
本轮保活那条路要证明的事）→ 锁屏 5 分钟不断线 → 挂断后音频会话确实关了（别人的音乐能恢复）→
语音消息、发图（HEIC 压缩）、存到相册、文件预览 → 灵听播放 + 锁屏控制 → 关于页版本号对得上。

---

## 十一、没验过的东西（照实记）

1. **一行 Swift 都没编译过**。本机是 Windows、没有 Swift 工具链、没有 Mac；
   原生代码的把握来自「照 Flutter 引擎头文件（`FlutterImplicitEngineBridge` /
   `FlutterBaseRegistrar`）与插件源码写」，不是「编过」。
2. **`ios/` 的这些改动没在 Xcode 里打开过**。`project.pbxproj` 是脚本改的
   （改前先数出现次数、改后校验括号配平），可它是不是"能打开"只有 Xcode 说了算。
   同理 `Info.plist` / `entitlements` / `PrivacyInfo.xcprivacy` 也没被 Xcode 校验过
   （本机连 `plutil` 都没有）—— 好在那三个是纯文本 plist，`test/core/ios_runner_test.dart`
   已经把要读的键全读了一遍。
3. **没在任何 iOS 设备或模拟器上跑过**（连"模拟器能不能起 App"都没试）。所有真机行为
   —— 音频会话能不能真的把进程撑住、权限框的时序、FCM 经 APNs 的到达率 —— **全都没验**。
4. **最低 iOS 版本 15.0 是按插件 podspec 读出来的**（`node tool/audit/ios_support.js`），
   没在 Xcode 里确认过；Flutter 3.44 自身要求的最低版本可能更高（那会在 CI 上第一次编
   的时候就告诉我们）。15.0 意味着**放弃 iPhone 6s / 7 那几代**（它们停在 15.8，其实还在支持）；
   要不要降到 13/14 得看 `firebase` 那两条是不是非用不可（现在是）。
5. **没有 `GoogleService-Info.plist`**，所以 iOS 上 `Firebase.initializeApp()` 现在必然失败
   （代码里已经把它收成「推送通道不可用」，不影响登录与收发消息）。买号之后按第三节第 3 步补。
6. **`audio_session` 的背景播放策略写了，但没在 iPhone 上试过**（第六节第 4 项，
   2026-10-14）：会话分类（`playback`）、激活与交还的四处接线都在了，Dart 那侧有用例
   钉着；可「切后台 / 锁屏之后音乐到底停不停」只有真机能答。同理，通话那条会话新加的
   **中断恢复**（来电 / Siri 之后自己爬回来）也一行都没编译过 —— 用的是
   `NotificationCenter` + `AVAudioSession` 的标准写法，但「标准写法」不等于「编得过」。
7. **CI 那条工作流本身也没跑过**（本地推不了），里面的命令（`simctl` 挑设备、
   `flutter build ios --no-codesign`、SPM/CocoaPods 那条依赖链）都是照着文档与插件结构写的。
8. **图标与启动图没在真机 / 模拟器上看过**：只做了像素级验收（尺寸对、没有 alpha 通道、
   四角是底座蓝、不是模板那几张），看上去顺不顺眼、桌面上大小合不合适，没人看过。
   等 CI 里能截图了（第八节那个 job）才有第一双眼睛。

---

## 十二、顺序建议

0. **2026-10-14 又往 Swift 里加了东西**（通话会话的中断恢复），Dart 那侧加了音频会话
   那一层 —— 第六节第 1 项（先把 CI 跑绿）因此比之前更要紧了：这些代码全是没编译过的。
1. **今天**：把仓库推上去 → 手点一次 `iOS 构建与自检` → 修它报出来的错
   （这一步不需要账号，也不需要你做什么 iOS 相关的决定）；
2. **12 月买号之后**：第三节那五步 → 内部 TestFlight 装到 iPhone 上 → 走一遍第十节；
3. **然后**：CallKit + PushKit（第六节第 2、3 项）—— 那是 iOS 上唯一还"缺一大块"的地方，
   也是「锁屏来电只能看到一条通知」这件事的解药；
4. 之后 iOS 与安卓共用同一条 `bump_version.dart` 发版链，多出来的只有
   「出 .ipa → 上传 TestFlight → 填 App Store Connect 的更新说明」三步。
