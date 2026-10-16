# iOS 版：落地计划与现状（2026-10-14 起）

用户 2026-10-14 的原话：「我圣诞节买开发者账号，我也没有苹果手机给你真机调试，也没有苹果电脑，
不过 iOS 代码层面你先完善一下，之前很多功能都还没适配。」
这份文档就是那件事的现场记录：**今天做完的、买号之后要做的、以及哪些验过、哪些没验。**

> **2026-10-15 首绿**：第 12 跑（`05e294e`）两个 job 全绿 —— 未签名 Release 包编出来了，
> 模拟器上三条自检（原生保活 / 建连取流 / 启动到登录页）都真跑到了断言。
> 现场在 Actions 的 `ios-smoke-log` 产物里（本机留了一份在 `.ci-evidence/`）。
> 第十一节（没验过的东西）已按这次结果重写。

---

## 一、结论先行

1. **iOS 这条路现在"能编、能起、能开发"，只差身份与签名**：`ios/` 那份 Flutter 模板已经
   按这个 App 的真实需要整改过（权限文案、后台模式、包名、最低系统、entitlements、
   隐私清单），原生侧把我们自己那几条平台通道补上了（版本号 / 权限 / 系统设置 / 通话保活），
   Dart 侧跟着长出 iOS 分支（保活、后台开关）。
2. **一件事都不用等账号**：GitHub 上的 macOS runner 能编未签名的 iOS 包、能在模拟器上
   把 App 真跑一遍（`.github/workflows/ios.yml`）。所以「到底编不编得过、起不起得来」
   这两个问题，**2026-10-15 已经有答案了**（第 12 跑全绿，见第八节）。
3. **Swift 已经编过、也在模拟器上跑过了（2026-10-15 首绿）**：`flutter build ios --release
   --no-codesign` 出包成功；模拟器上我们自己那条 `call_service`（`start` → `isRunning`
   → `stop`）返回全对，`getUserMedia` 真的取到了 1 路麦克风流。**但没在任何真机上跑过** ——
   剩下没验的是「真机行为」那一类（音频会话能不能真把进程撑住、锁屏、FCM 经 APNs），
   第十一节照实列着。
4. **买号之后的第一件事是「签名 + 上传」，不是写代码**：CI 已经把「能编、能起、通话链
   活着」验完了，剩下的只有证书与描述文件那一道。
5. **CallKit 来电界面那一层 2026-10-15 写完了**（第六节第 2 项）：Dart 侧「什么时候
   把它交给系统、什么时候收回来」（[call_push_host.dart](lib/features/call/call_push_host.dart)）、
   原生那侧 `CallKitBridge`（`AppDelegate.swift` 里，含 PushKit）、`Info.plist` 的 `voip`
   后台模式都在了，Dart 那层用 19 条用例钉着（`test/core/callkit_test.dart` 11 条钉接口契约，
   `test/features/call_system_ui_test.dart` 8 条钉「什么时候报 / 什么时候收尾」，
   另加 `test/core/ios_runner_test.dart` 里那几条盯着 Swift 源码里该有的东西在不在）。
   **但它离「能用了」还差三样**：服务端那条 VoIP 推送（第六节第 3 项）、VoIP 证书、
   一台 iPhone —— 现在报给系统的那些通话，在锁屏上还弹不出任何东西（CallKit 不在
   模拟器上跑，这是苹果的事）。

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
   - 服务端那边**不再「不用改」**了（2026-10-15 起）：普通消息仍走 FCM 的 token，
     但**来电**走另一条直连通道 —— 同一把 `.p8` 还要填进服务端的 `[PUSH]` 段
     （`APNS_KEY_FILE` / `APNS_KEY_ID` / `APNS_TEAM_ID`，见 `REFACTOR_PLAN` 的 S12.47
     与补丁里的《部署说明.md》）。标识也分开了：普通通知是 `fcm_ios:`、来电是 `apns_voip:`。
4. ~~**跑一次 CI**：GitHub → Actions → 「iOS 构建与自检」→ Run workflow。
   绿了再往下做 CallKit；红了就先修红 —— 在那之前写更多 iOS 代码都是赌。~~
   **2026-10-15 已绿**（第 12 跑）：这一步之后，剩下的只有「签名 + 上传」。
5. **出 TestFlight**：见第九节（要加一个签名 + 上传的 job，代码骨架留在
   `.github/workflows/ios.yml` 末尾的注释里）。

---

## 四、iOS 与安卓的机制对照（**同名不同实现**的那些）

| 能力 | 安卓（已验） | iOS（本轮做完；CI 已编、已在模拟器上跑） |
|---|---|---|
| 通话期间不被冻住 | `CallForegroundService` 前台服务 + 常驻通知 | `UIBackgroundModes: audio` + **激活的 `AVAudioSession`**（`IosCallKeepAlive`）；被打断（来电 / 闹钟 / Siri）后**自己恢复**，见第五节最后一条。〔2026-10-15：start / stop / isRunning 已在模拟器上验；「中断后自己恢复」仍未验〕 |
| 灵听切后台继续响 | `audio_service` 前台服务 | `audio_session` 把会话设成 `playback` 并激活（`AudioSessionConfigurator`，2026-10-14 补） |
| 来电响铃 / 接听界面 | 全屏通知 + `setShowWhenLocked` | **接线做完了（2026-10-15），还没在真机上弹出来过**：App 不在屏幕上时收到来电 → 报给 CallKit（锁屏那个界面由系统画）；用户在系统界面上按接听 / 挂断 → 真正动的是我们这套状态机。见第五节的 CallKit 那一段 |
| 后台收到消息 | FCM 数据消息 → 后台 isolate 画通知 | 同一条路（FCM 经 APNs 投递），**但进程被用户划掉以后收不到**（苹果的硬限制） |
| 通知权限 | `POST_NOTIFICATIONS`（13+ 运行时权限） | `UNUserNotificationCenter` 授权框 |
| 「去系统设置」 | 应用详情页 / 通知设置页 / 电池优化页三个入口 | 只有 `openSettingsURLString`（本应用设置页）一个入口 |
| 电池优化白名单 | 有（不申请就会掉线） | **不存在**这个概念（恒 true，不显示那条提示） |
| 画中画 | 系统 PiP（`enterPipNow`） | 没有（要 `AVPictureInPictureController` + 一层视频视图） |
| 屏幕共享 | `MediaProjection` | 没有（要 ReplayKit 的广播扩展，且审核要额外说明） |
| 通话窗口盖锁屏 | `setCallScreenMode` | **一半**：报给 CallKit 的那一通，锁屏由系统画（那就是它存在的理由）；而我们**自己那张通话页**在 iPhone 上仍然盖不住锁屏（那是 CallKit 的界面，不是我们的） |
| 系统媒体卡片（灵听） | `audio_service` 的媒体通知 | `audio_service` 的 darwin 那份（Now Playing / 锁屏 / 耳机键）；**后台播放要会话分类配合，见第六节** |

---

## 五、这一轮落地了什么（逐项）

**工程配置**（`ios/`）
* `Runner/Info.plist`：五条权限文案（相机 / 麦克风 / 相册读 / 相册写 / 本地网络）、
  `UIBackgroundModes = audio + remote-notification + **voip**`（voip 是 2026-10-15 与
  CallKit 一起加的：PushKit 靠它才能收到 VoIP 推送。网上「iOS 13 之后不必再声明」
  是把两件事搞混了 —— iOS 13 改的是「收到就必须立刻报给 CallKit」，不是取消这个模式）、`ITSAppUsesNonExemptEncryption = false`（免掉每次上传的出口合规问答）、
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
* **`gracelinkim/callkit`：系统来电界面（CallKit + PushKit，2026-10-15 加）** ——
  `CallKitBridge`（同一个文件里）：
  - **Dart → 原生**：`isAvailable` / `reportIncomingCall`（`CXProvider.reportNewIncomingCall`，
    回执是异步的：`ok` / `reason` / `alreadyReported` —— 同一通重复报**绝不再弹一次**，
    否则锁屏上是两条一模一样的来电）/ `reportEnded`（`reportCall endedAt:`，结束原因
    映到系统认的那几种：`declinedElsewhere` / `unanswered` / `failed` / `remoteEnded`）/ 
    `takePendingCall`（App 被 VoIP 推送叫醒时 Dart 还没起来，报文先存在原生那儿，取一次清掉）/ 
    `voipToken` / `lastError`（失败原话，诊断面板用）；
  - **原生 → Dart**：**同一条通道反方向**调 `action`（`kind` = answer / end /
    incoming / token）—— `CXProviderDelegate` 的接听（`CXAnswerCallAction`）、挂断
    （`CXEndCallAction`）与「系统把通话整个重置了」（`providerDidReset`，当成一次 end）
    都从那里上去；**接电话的是我们的状态机**，原生只管那个界面
    （还有一条反方向的判定：那条报文只在 Dart **真的收下**之后才从暂存里清掉）；
  - **PushKit**：`PKPushRegistry`（`voip` 类型）注册在前台启动时；token 到了回调 Dart；
    收到 VoIP 推送**就地**报给 CallKit（苹果的硬规则，iOS 13 起：先去别处转一圈再报，
    这条推送就算滥用，系统会掐掉 App）。`completion` 收在一只「只放行一次」的盒子里
    （回执 + 5 秒兜底），绝不漏调、也不调两次；报完再 `sendAction("incoming")` 叫醒
    已经活着的 Dart，**Dart 收下了才把暂存报文清掉**（不然下次冷启动会把这通早挂了的
    电话又接一遍）；
  - **音频会话交给系统**：`didActivate audioSession` 里复用保活那条 `CallAudioSession.apply()`
    （分类 `playAndRecord`），`didDeactivate` 如实关掉 —— 不关的话「麦克风正在使用」
    那个点会一直亮着；
  - `CXProviderConfiguration`：语音 / 视频都支持，`maximumCallsPerCallGroup` 与
    `maximumCallGroups` 都是 1（多人通话那个界面还没做）；handle 用 uid（取不到回退昵称）。
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
* `lib/core/platform/callkit.dart`（新，2026-10-15）：CallKit 的 Dart 接口 + `IosCallKit`
  + `NoopCallKit`（非 iOS 上是彻底的空操作），provider 按平台分流；
  `takePendingCall` /`voipToken` / `lastError` 都收成「失败就回空串 / 空值」，
  不让平台通道上的意外把整条链带倒。
* `lib/features/call/call_push_host.dart`（改，2026-10-15）：**「什么时候把它交给系统」
  那套判断**都在这儿：App 不在屏幕上（`lifecycleState != resumed`）且会话处于
  `incoming` → 报一次；同一通只报一次（拿 `messageId` 去重）；一旦不再活跃（接听 / 挂断 /
  超时 / 被换成另一通）→ `reportEnded` 收尾 —— 不收的话锁屏上那个界面会一直挂着。
  系统那侧按的接听 / 挂断回到 `CallController.accept()` / `hangup()`；冷启动时
  报文从 `takePendingCall()` 取回来。
  ⚠️ 这里顺手修掉一个真 bug：监听原先在 `initState` 里挂一次，而
  `callControllerProvider` **会随登录 / 登出重建** —— 挂在旧实例上的监听从此再也不响，
  表现是「登录之后收到来电，系统界面不弹、通知也收不掉」。现在改成每帧盯
  `ref.watch` 当前那个控制器（`_attach`，幂等）。

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
* `test/core/callkit_test.dart`（新，11 条，2026-10-15）：这一层的契约 ——
  参数怎么传（`callId` / `peerName` / 语音还是视频 / payload）、
  报失败**不抛**只带回原因、`takePendingCall` 只交一次、事件通道把系统的动作叫醒监听表、
  非 iOS 上是空操作。
* `test/features/call_system_ui_test.dart`（新，8 条，2026-10-15）：**报给系统的时机**，
  这是最容易被写错、而且在模拟器上永远看不出错的一段：后台收到来电要报、
  **前台不报**（再叠一层系统界面等于同一通电话响两次、两个接听键）、同一通只报一次、
  报失败不抛、系统界面上按接听真的发出 `acceptRtc`、冷启动那条报文接得起来、
  对端挂断与本机挂断都要收尾。
* `integration_test/ios_callkit_smoke_test.dart`（新，2026-10-15）：设备/模拟器上的自检 ——
  通道在不在、上报不会「既没成功也没原因」、能报成时不报两次。它**故意不把
  「来电真的弹出来了」当判据**：模拟器上 CallKit 不工作，写死就是一条永久红。
* `test/core/ios_runner_test.dart` 里新增那几条：`UIBackgroundModes` 必须有 `voip`、
  `AppDelegate.swift` 里 PushKit 回调必须在**同一轮回调里**报给 CallKit、
  `gracelinkim/callkit` 的每个方法名都要与 Dart 侧对得上。
* `tool/audit/ios_support.js`（新）：读 pub 缓存列出每个依赖的 iOS 支持与**最低 iOS 版本**
  （`IPHONEOS_DEPLOYMENT_TARGET` 就是照着它的输出定的）。
* `.github/workflows/ios.yml`（新）：macOS runner 上编译（不签名）+ 模拟器真启动 + 截图。
  2026-10-15 扩成三条自检（原生保活 / 建连取流 / 启动到登录页），各自一个步骤、
  各自有硬时限 —— 为什么必须拆开、为什么授权要排在装包之后，见第八节。

---

## 六、还没做的（按优先级）

| # | 事 | 价值 | 依赖 | 估时 |
|---|---|---|---|---|
| 1 | ~~**让 CI 跑绿一次**（编得过 + 模拟器起得来）~~ **2026-10-15 已绿**（第 12 跑） | 把「应该能跑」变成「确实能跑」 | 无 | 做完了 |
| 2 | ~~**CallKit + PushKit 来电界面**~~ **2026-10-15 接线写完**（Dart + Swift + `voip` 后台模式，见第五节；19 条 Dart 用例钉着。**但还在模拟器上弹不出来** —— 那是苹果的事）。剩下：VoIP 证书 + 真机验 | iPhone 上锁屏来电只有它是"系统级"的；现在只能靠一条普通通知 | 真机（+ 后一项的证书） | 接线已完，真机验收 1 天 |
| 3 | ~~服务端 VoIP 推送那条链~~ **2026-10-15 写完了**（APNs 直连 + VoIP topic + 客户端上报 `apns_voip:`，见 `REFACTOR_PLAN` S12.47；补丁在 `gracelinkim-server-patch-20261015-voip-push`）。剩下的是**部署 + 真机验收** | 上面那条的一半（APNs VoIP topic、payload 形状）；没它时第 2 项写完了也弹不出来 | 账号（建一把带 VoIP 权限的 `.p8`）+ 一台 iPhone | 接线已完，验收 1 天 |
| 4 | ~~灵听在 iOS 的后台播放（`audio_session` 会话分类）~~ **2026-10-14 已写**（`AudioSessionConfigurator`；但 iPhone 上还没试过） | 修好前切后台音乐会被系统停（安卓有前台服务撑着） | 无 | 做完了 |
| 5 | 画中画（AVPictureInPictureController） | 通话切出去还能看着对方 | 真机 | 3–5 天 |
| 6 | 屏幕共享（ReplayKit 广播扩展） | 群里那个功能补齐 | 账号（App Extension）+ 真机 | 3–5 天 |
| 7 | 上架资料（隐私政策页、审核说明）—— ~~账号删除入口~~ **应用内早就有**（见第九节第 4 项） | 不写就上不了架 | 账号 | 2–3 天 |
| 8 | 让 `open_filex` 支持 Swift Package Manager（或换掉它） | CI 日志里已经在警告：等 Flutter 把 SPM 变成默认，这条会**直接变红**（原文 `This will become an error in a future version of Flutter`） | 插件上游，或换一个支持 SPM 的文件选择器 | 看上游 |

**为什么它原先排第一位，以及现在为什么可以往下走了**：那几项都要动 Swift，而当时这份
Swift 一行都没编译过 —— 在没验证的地基上加代码，只会把「一次修十个错」变成「一次修三十个」。
2026-10-15 首绿之后，地基从「照文档写」变成了「编过、模拟器上跑过」，第 2 项（CallKit）
当天就开工并写完了接线 —— **它是 iOS 上唯一还缺一大块的地方**。

**第 2 项「写完了」不等于「能用了」，三件事分开记**：
1. **接线**：写完了。判据在 Dart 那 19 条用例里（报的时机 / 去重 / 收尾 / 接听回到状态机 /
   冷启动），以及 `ios_runner_test.dart` 盯着的源码事实（`voip` 模式、推送回调里立刻上报）。
2. **服务端**（第 3 项）：~~没做~~ **2026-10-15 写完了（S12.47）**：APNs 直连（VoIP topic）
   那条通道、`accepts` 分发门、以及客户端把 `apns_voip:` 标识上报上去这三件事都做了，
   自检 171 项 + 补丁自检 44 项全绿。但**一次都没真推到苹果**（没有 `.p8`、没有真机）——
   所以「部署完之后手机上到底弹不弹」仍然要看第十一节第 11 条。
3. **真机**：没验。CallKit 在模拟器上不跑（`reportNewIncomingCall` 必回错误）——
   所以「锁屏上到底弹不弹、接听键按了之后音频对不对」只有一台 iPhone 能答。
   模拟器上能验的是「通道在、上报失败会带回原因而不是静默」
   （`integration_test/ios_callkit_smoke_test.dart`）。

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

## 八、CI（`.github/workflows/ios.yml` 与 `ios-live-call.yml`）

* **「真拨一通」那条**（`.github/workflows/ios-live-call.yml`，2026-10-15 加）：与上面那条
  刻意分开的**手动**流水线（`workflow_dispatch` 或推一个 `live-call-v*` tag）——
  它每次都**真的打一通电话**，接的是人，所以不能自动跑。它干的是同一件事：
  云 Mac + iPhone 模拟器当主叫，真人的手机当被叫，判据是「状态机进 `connected`」+
  「媒体收发字节 > 0」（只能证明「拨出去了」的那一层不算）。凭据走四个 Secret，
  本文件与用例里**没有任何一个真值**。
* **中转自检一条**（2026-10-15 加）：`integration_test/call_relay_smoke_test.dart` —— 两边
  都只许走中转（`iceTransportPolicy: relay`）时，媒体到底过不过得去。它**不需要人接**
  （两个端点都是同一个进程里的连接），所以它不是拨号那条的附属品，而是一件能天天跑的事：
  判据是「候选全是 `typ relay`」+「真的 `connected`」+「数据通道来回一趟」+「选中那一对是
  `relay→relay`」，有麦克风再加一条「音频双向都有字节」。**它排在拨号之前**：
  中转是断的，就该在响人家手机之前红。只想跑它时选 `relay_only = yes`。
  为什么不在 `ios.yml`：它要账号（TURN 凭据要登录态），靠 `LIVE_TEST_*` 那两个 Secret，
  放进 `ios.yml` 只会变成一条永远 SKIP 的步骤。
* `build-ios`：`flutter analyze` + `flutter test` + `flutter build ios --release --no-codesign`
  + 打印产物里的版本号 / 后台模式 / 权限文案（**配错了那里就是空的**）。
* `simulator-smoke`：动态挑一台 iPhone 模拟器 → `flutter test integration_test/boot_smoke_test.dart -d <UDID>`
  → 截图 + 日志当产物。用例与 macOS 那条是同一个文件（判据用类型，不看文案）。
* 触发：手动（workflow_dispatch）、`v*` tag、以及**动到 `ios/**` 的 push**。
  平时改 Dart 不会触发它（macOS 构建十分钟起，没必要每次提交都等）。
* 模拟器这条路**不需要账号**，所以今天就能用 —— 唯一的门槛是把仓库推上去。
* **通话自检两条**（2026-10-15 加）：① `ios_call_keep_alive_smoke_test.dart`：我们自己那份
  Swift（`start` / `isRunning` / `stop` / 幂等）；② `ios_call_media_smoke_test.dart`：
  `createPeerConnection` + `createOffer` 必须过，`getUserMedia` 只在**真有输入设备**时取
  （runner 是虚拟机，判据不能把「环境没麦克风」钉成永久红）。
  两条各自一个步骤、各自 `timeout-minutes`，而且**用例自己还带硬时限**（`withDeadline`）：
  卡住会当场红并说清卡在哪一步，而不是被整步超时砍掉、注解都来不及发。
* **`simctl privacy grant` 的位置是一个 bug 修出来的**：它只对**已经装上**的 App 生效，
  原先排在装包之前等于授了个空 —— 于是 `getUserMedia` 一直等一个没人点的系统权限框，
  整步 28 分钟被杀。现在它排在自检①之后（那一步刚把同一个 bundle id 装进这台模拟器）。

**现状（2026-10-15，第 12 跑 `05e294e` 全绿）**

| 这条证明了什么 | 证据（产物日志里的原话） |
|---|---|
| 未签名 Release 包编得出来 | `build/ios/iphoneos/Runner.app`；`App.framework` 与 `flutter_assets` 都在且非空；Info.plist 里版本号 / 后台模式 / 权限文案都读得到 |
| Dart 侧全量用例在这套工具链下全过 | 2351 条（3.47.7；本地同一条命令也跑过） |
| **我们自己那份 Swift 是活的** | `[IOS-KEEPALIVE] start：成功`（2241ms）→ `isRunning = true` → `stop` → 再 `stop` 幂等；1 test passed |
| **建连那条路不崩**（安卓上崩过的就是它） | `ALIVE transceivers=0 offer=4330 字节`；2 tests passed |
| **取麦克风真的能取到** | `音频输入设备：1 个` → `getUserMedia（要权限的那一步）：388ms` → `取流 OK tracks=1` |
| 起得来、到得了登录页 | iOS 18.5（22F77），`落在=登录页，耗时=2s，仍停在启动页=false` |
| 模拟器截图 | `ios-simulator.png`（1206×2622，跑完用例之后拍的，多半是桌面） |

**中转那条自检（2026-10-15 加）**：它在 Windows 真机上先跑过一遍 —— 服务端签发
两条（STUN 一条 + 带账号的 `turn:` 六条），八条候选**全是 `typ relay`**、没有一条直连，
选中那一对 `relay→relay`，503ms 连上、数据通道一个来回 291ms、RTT 41ms（原话见
`REFACTOR_PLAN.md` 的 S12.45）。**它在 iOS 模拟器上还没跑过** —— 那一天要等下一次
`iOS 真拨一通`（选 `relay_only = yes`，产物里的 `relay.log` 就是它的现场）。

顺带两条从这份日志里读出来、原先没人知道的：
* SPM 警告 `open_filex` 不支持 Swift Package Manager（第六节新加的第 8 项）；
* 启动日志里 `[推送] Firebase 初始化失败` 是**预期**（还没有 `GoogleService-Info.plist`，
  第十一节第 5 条），被代码收成「推送通道不可用」，不影响登录与收发消息。

---

## 九、上传 App Store / TestFlight 要准备的东西

1. **签名**：证书导出成 `.p12`、描述文件、以及 App Store Connect 的 API Key
   （六个 secret 的名字写在 `.github/workflows/ios.yml` 末尾）。
2. **隐私清单**：`ios/Runner/PrivacyInfo.xcprivacy` 已经放好（插件各自的清单它们自己带，
   上传时会被合并）。上架前按当时的真实情况复核一遍收集项。
3. **审核备注**：这是个 IM + 音视频通话应用，审核大概率会要**测试账号**（用户名/密码各一份）
   以及「怎么发起一通电话」的说明；麦克风/摄像头用途说明已经在 Info.plist 里。
4. **账号删除入口 —— 早就有（这行第一版写错了， 2026-10-15 查代码改掉）**：苹果对「有账号
   体系的 App」要求应用内能注销账号，而这条一直在：设置 › **账号与安全** 页底部那块红字
   「注销账号」（`lib/features/mine/secure_page.dart`）→ `/mine/secure/cancel` 的
   `AccountCancelPage`（先逐条列后果、要登录密码、再确认一次）→ 服务端
   `/enterprise/im/deleteAccount`（软删除 + 手里那枚 token 当场作废）。
   `test/features/mine_pages_test.dart` 里有用例钉着「点进去就是那一页」。
   所以**上架前不用补它**；真机上要看的只是它在 iPhone 上长得对不对、流程顺不顺。
5. **出口合规**：`ITSAppUsesNonExemptEncryption = false` 已经答了，上传时不会再问。
6. **TestFlight**：内部测试（自己 + 100 人）不需要审核，外部测试要过一次轻量审核；
   所以「12 月买号 → 当天就能让 iPhone 用户装上」，走的是内部测试这条路。

---

## 十、验收清单（第一次拿到 Mac / 真机时照这个过）

模拟器上（CI 就能跑）：编得过 → 起得来（登录页）→ 七种语言里至少中英各切一次 →
设置 › 通知 里那一行在 → 会话列表那条红条在权限被拒时出现、开了之后消失。
〔2026-10-15：前两步已经过了（第 12 跑）；语言切换与那两处界面还没人看过。〕

真机上（要账号 + iPhone）：
装得上 → 登录（扫码 / 密码）→ 收消息（前台 + 后台 + 划掉 App 三种状态各看一次）→
通知权限框只弹一次 → **打电话**：麦克风权限 → 接通 → 切到后台 5 分钟**不断线**（这是
本轮保活那条路要证明的事）→ 锁屏 5 分钟不断线 → 挂断后音频会话确实关了（别人的音乐能恢复）→
语音消息、发图（HEIC 压缩）、存到相册、文件预览 → 灵听播放 + 锁屏控制 → 关于页版本号对得上。

---

## 十一、没验过的东西（照实记）

1. ~~**一行 Swift 都没编译过**~~ **2026-10-15 编过、也跑过了**（第 12 跑）：编译走的是
   `xcodebuild`，连 SPM 取依赖（firebase-ios-sdk / SDWebImage 那一路）与 `pod install`
   都过了；运行走的是模拟器上那两条自检。**仍未验**的是真机行为，见第 3 条。
2. ~~**`ios/` 的这些改动没在 Xcode 里打开过**~~ **2026-10-15 被 `xcodebuild` 真读过**：
   `project.pbxproj` 能解析、能构建（脚本改的括号配平没白校验）；`Info.plist` 是从
   **产物**里用 `PlistBuddy` 读出来的（版本号 / 后台模式 / 权限文案都在）；
   `PrivacyInfo.xcprivacy` 与 entitlements 也确认进了包。**仍没人用 Xcode 的图形界面
   打开过它** —— 但「能不能编」这个问题已经答了。
3. ~~**没在任何 iOS 设备或模拟器上跑过**~~ **模拟器上跑过了**（2026-10-15）：起得来、
   到得了登录页、通话那两条自检全过。**真机行为仍然一件都没验** —— 音频会话在真实机型上
   能不能把进程撑住（后台 5 分钟不断线）、被来电 / Siri 打断之后恢复得对不对、
   锁屏下的行为、权限框的时序、FCM 经 APNs 的到达率、图标与启动图在真机上顺不顺眼：
   全都要等一台 iPhone。
4. **最低 iOS 版本 15.0 算验过一半**：3.47.7 这套工具链下真编出来了（若 Flutter 自身
   要求更高，第一次编就会报）。「15.0 够不够 / 要不要降到 13、14」仍是没验的：
   真要降得先确认 `firebase` 那两条能不能不要（现在是必需）。15.0 意味着
   **放弃 iPhone 6s / 7 那几代**（它们停在 15.8，其实还在支持）。
5. **没有 `GoogleService-Info.plist`**，所以 iOS 上 `Firebase.initializeApp()` 现在必然失败
   （代码里已经把它收成「推送通道不可用」，不影响登录与收发消息）。买号之后按第三节第 3 步补。
6. **`audio_session` 的背景播放策略写了，但没在 iPhone 上试过**（第六节第 4 项，
   2026-10-14）：会话分类（`playback`）、激活与交还的四处接线都在了，Dart 那侧有用例
   钉着；可「切后台 / 锁屏之后音乐到底停不停」只有真机能答。同理，通话那条会话新加的
   **中断恢复**（来电 / Siri 之后自己爬回来）：2026-10-15 已随包编译通过（不再只是
   「照文档写的」），但**没有被任何一次真实中断触发过** —— 模拟器上没人打进来。
7. ~~**CI 那条工作流本身也没跑过**~~ **跑了 12 次、第 12 次全绿**（2026-10-15）。
   中间的坑都记在第八节（`simctl privacy` 的时序、整步超时报不出注解、一条用例卡住
   吃掉另一条的预算、runner 慢到 45 分钟不够）—— **这些不是猜的，是踩出来的。**
8. **图标与启动图**：像素级验收过了（尺寸对、没有 alpha 通道、四角是底座蓝、不是模板
   那几张），CI 现在也会截一张模拟器的图（`ios-simulator.png`）—— 但那张是**跑完用例
   之后**拍的（App 已经收了，多半是桌面），当参考可以，**不算验收**。真机上桌面上大小
   合不合适、启动那一下闪不闪，还是没人看过。
9. **CallKit 那一层只在一只「假通道」上验过，真设备上一次都没跑过**（2026-10-15 写）：
   19 条 Dart 用例验的是接线与时机（用一个 `FakeCallKit` 记下报了哪几通），而 CallKit 本身
   **在模拟器上不工作**（苹果没在模拟器里实现它），所以 `reportIncomingCall` 在真设备上的
   回执必然也是失败 —— 这一点已经写进用例的预期（判据是「要么成功、要么带回一条非空原因」，
   而不是「一定弹得出来」）。因此下列事实**全部未验**：那个界面长什么样、接听键按下之后
   系统真的把音频交给我们了吗、被划掉 App 之后 VoIP 推送真能叫醒吗、
   `CXProviderDelegate` 那几个回调在真机上的时序。至于当初顺手记下的那两件事
   （「服务端那条 VoIP 推送没写、`voipToken()` 也没上报」）—— **都已不是缺口**：服务端写完在
   第六节第 3 项（S12.47），客户端也把 PushKit 给的串上报成 `apns_voip:` 了
   （`lib/core/store/credential_store.dart`、`lib/domain/notify/push_registrar.dart`）。
   但它们和上面那条一样：**没有 `.p8`、没有真机，一次网都没真出过**（见第 11 条）。
10. **中转那条自检在 iOS 上还没跑过**（2026-10-15 加的，见第八节）：它的判据先在
   **Windows 真机**上过了（候选全是 relay、`relay→relay`、数据通道 291ms 一个来回），
   而 iOS 那侧走的是同一段 Dart、同一份插件配置键（`iceTransportPolicy` 在
   `FlutterWebRTCPlugin.m` 里有解析）—— 但**「同一段代码」不是证据**。
   下一次 `iOS 真拨一通`（选 `relay_only = yes`）会给它：`relay.log` 作为产物。
   同一件事的旁证是第八节那张表里 `取流 OK tracks=1` —— runner 的模拟器有麦克风，
   所以那一步在 CI 上会真的把音频也过一遍，而不是跳过。
11. **服务端的 VoIP 推送写完了，但一条都没真推出去过**（2026-10-15，S12.47）：
   签名/请求头/报文/错误映射都有自检钉着（`tools/push_selftest.php` 共 171 项，
   补丁自检 44 项），可是**没有 `.p8` 钥匙、没有真机** ——「苹果收下了没有、
   手机上弹了没有」只有真机能答。部署与验收步骤见补丁里的《部署说明.md》。
   另有一件只能在服务器上验的：那台机器的 **curl 有没有编 HTTP/2**（APNs 只收它），
   没有的话日志里会明说，出路是配 `[PUSH] HTTP_PROXY`。

---

## 十二、顺序建议

0. ~~**2026-10-14 又往 Swift 里加了东西**（通话会话的中断恢复），Dart 那侧加了音频会话
   那一层 —— 第六节第 1 项（先把 CI 跑绿）因此比之前更要紧了：这些代码全是没编译过的。~~
   **2026-10-15 做完了**：CI 首绿，那批代码现在编过、也在模拟器上跑过。
1. ~~**今天**：把仓库推上去 → 手点一次 `iOS 构建与自检` → 修它报出来的错
   （这一步不需要账号，也不需要你做什么 iOS 相关的决定）；~~ **2026-10-15 做完了**
   （第 12 跑）。在那之前能做的只剩「把没验的验掉」那一类（比如第六节第 8 项）；
2. **12 月买号之后**：第三节那五步（多一步：苹果后台 Keys 里建一把带 **VoIP 推送**
   权限的 `.p8`）→ 内部 TestFlight 装到 iPhone 上 → 走一遍第十节；
3. **然后**：CallKit + PushKit（第六节第 2、3 项）—— iOS 上唯一还"缺一大块"的地方，
   也是「锁屏来电只能看到一条通知」这件事的解药。**接线 2026-10-15 已经写完了**
   （第五节、第六节），所以这一步剩下的是：服务端补一条 VoIP 推送 + 把 VoIP token
   收上去（第 3 项）、拿真机把「锁屏弹出 → 按接听 → 真的说上话」走一遍。
   顺序上先做服务端：没有它，真机上什么都看不见；
4. 之后 iOS 与安卓共用同一条 `bump_version.dart` 发版链，多出来的只有
   「出 .ipa → 上传 TestFlight → 填 App Store Connect 的更新说明」三步。
