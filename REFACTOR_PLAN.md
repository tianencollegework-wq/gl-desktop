# Gracelink IM · Flutter 客户端重构规划书

| 项目 | 内容 |
| --- | --- |
| 目标工程 | 本仓库 `gracelinkim`（Flutter 空工程） |
| 源项目 | `C:\Users\David-local\Downloads\raingad-uniapp-6.2.0-2370507126(1)`（Raingad-IM uniapp 客户端 v6.2.0） |
| 后端 | `https://message.gracelink.cc`（**本期不动**） |
| 目标平台 | Android + iOS |
| 技术选型 | Flutter + Riverpod 分层 + Drift(SQLite) + 尽量还原现有 ColorUI 绿色 UI |
| 执行方式 | 按 M0 → M8 顺序推进，**每次只做一步，单步验收通过后再开下一步** |

---

## 一、结论先行

1. **可做，且比想象中简单。** 后端不动，全部协议都能从现有客户端代码里完整逆推，也没有黑盒原生 SDK 依赖需要破解。
2. **主要工作量在 UI 与数据层**（体力活，风险低），**真正有风险的只有通话**。
3. **通话是本次重构的核心动机**，采用 Flutter 原生方案（`flutter_webrtc`）重写，不再沿用 WebView 那套。
4. **保活与离线推送放到最后**（M8）。本期只做与老端一致的在线 WebSocket 推送。
5. **两件事是通话可用的底线，不是附加体验**：
   - 自带 STUN/TURN 中转（否则移动网络下 P2P 打不通就是黑屏无声）
   - 通话期间的前台服务（否则打电话时切一下微信就断线）
6. **不需要专门抓包，也不阻塞开工**：协议里唯一无法从源码读出的，只有"服务端真实返回的报文字段"和"服务端生成的通话记录文案"。这两样在 M1 打通之后，**让老端给新端发消息、打电话，新端自己把原始 JSON 落成日志**即可采集，比装代理抓手机流量简单得多。详见第十一节。

---

## 二、现状盘点

### 2.1 源项目概况

- **技术栈**：vue3 + uni-app（HBuilderX 工程）+ pinia + vue-i18n + u-ajax + z-paging + mp-html + mumu-recorder，另带 crypto-js / jsqr / quill / vconsole 依赖。
- **代码量**（不含 `node_modules`）：
  - 业务代码约 **1.8 万行**（`pages` 7777 / `components` 4009 / `api`+`store`+`utils`+`common`+`mixins`+`App.vue` 6279）
  - `uni_modules` 下 46 个 UI 插件约 **4.6 万行**（Flutter 端绝大部分有原生替代，不需要搬）
  - `hybrid/html/rtc/*` WebRTC 兼容垫片约 **5800 行**（历史包袱）
- **原生插件**：`lemonjk-FileSelect`（文件选择，只有 aar/framework）、`android-keeplive`（安卓保活）。
- **页面**：`pages.json` 共 28 个页面，分 6 组：`index`（首页/扫码/搜索/二维码/用户选择）、`message`（会话/聊天/通话/视频播放/聊天信息/聊天记录/群）、`contacts`（通讯录/详情/新朋友/群列表/搜索）、`login`（登录/注册/扫码登录）、`mine`（资料/安全/设置/关于/帮助/webview）、`compass`（发现/朋友圈）。

### 2.2 通话实现现状（重点）

**真正的音视频逻辑不在 uni-app 里，而在一个 WebView 里。**

- `pages/message/call.vue`（262 行）只是个壳：`<web-view src="/hybrid/html/index.html?...">`；与 WebView 通过 `evalJS("getUniAppMessage(...)")`（APP）／`iframe.postMessage`（H5）互推 JSON。
- `hybrid/html/index.html`（612 行）是独立的 Vue3 CDN 小应用，自己 `new RTCPeerConnection` + `getUserMedia`。
- **信令借道业务消息**：所有信令事件都通过 REST `/enterprise/im/sendToMsg` 落到消息表（`type=webrtc`），再由服务端经 WebSocket 推送给对端；连每一个 ICE candidate 都是一次独立的 HTTP + 落库 + 推送。

**通话时序（从代码还原）**：

1. `components/message/im-input.vue` 的 + 面板点语音/视频 → 检查 `msgStore.webrtcLock` → 跳 `/pages/message/call?...&status=1`
2. APP 端先申请 `RECORD_AUDIO`（视频再申请 `CAMERA`），拿到权限后向 WebView 注入 `{event:'calling'}`；H5 端 `calling=1` 自行发起
3. WebView `getUserMedia` 成功 → 回传 `{event:'calling', status:3, code:901}` → `call.vue` 调 `sendToMsg`
4. 对端 `App.vue` 收到 WS `type='webrtc'`：`event=calling` → 不在通话页则跳来电页（`status=3`），已在通话页则回 `busy/907`；其它事件一律 `uni.$emit('webrtcConn')` → `call.vue` 转发进 WebView
5. 接听：`acceptRtc/904` → 主叫 `createOffer` → `offer(sdp)` → `answer(sdp)` → 逐条 `iceCandidate`
6. 挂断：`hangup` + code + `callTime`；WebView 内 40 秒无人接自动挂断；`otherOpt` 用于多端同步挂断
7. 媒体控制：麦克风 `track.enabled`、切摄像头 `replaceTrack`、扬声器/听筒走 `plus.audio.setRoute`

**已识别的问题（重构目标）**：

| # | 问题 | 说明 |
| --- | --- | --- |
| 1 | P2P 连通性差 | 只配公共 STUN（`stun.xten.com`／Google，国内基本不可用），无自带 TURN 兜底；对称 NAT／移动网络下直连失败即黑屏无声 |
| 2 | 无 ICE restart | WiFi ↔ 4G 切换直接断线，不恢复 |
| 3 | 无服务端通话会话 | `webrtcLock` 是客户端内存启发式，多端登录无法保证只有一端振铃；忙线判定靠 `main_id` 比较，存在竞态 |
| 4 | 来电体验缺失 | 无 CallKit／ConnectionService 全屏来电、无锁屏接听、无系统铃声；App 被杀即收不到电话 |
| 5 | 音频路由与焦点不可控 | 全在 WebView 内，依赖 `plus.audio`，无 AudioFocus/AVAudioSession 管理，蓝牙耳机与听筒切换不可靠 |
| 6 | 信令风暴 | 每个 ICE candidate 一次 HTTP + 落库 + 推送，慢、可能乱序、无 ack 无重试 |
| 7 | 状态机分散 | 逻辑散在 `App.vue` / `call.vue` / `index.html` 三处，无单一真相 |
| 8 | 其它 | 群通话不支持；屏幕共享代码残留无用；`905` 码在客户端未出现（语义未同步） |

---

## 三、目标、范围与原则

### 3.1 目标

用 Flutter 重写客户端，功能对齐现有 uniapp App 端（Android + iOS），**通话用原生 WebRTC 重写**，并为后续悬浮窗等增强留出扩展空间。

### 3.2 本期不做

- 微信小程序端（Flutter 无法覆盖，老 uniapp 代码需并行保留）
- 离线推送（APNs / 厂商通道）与保活插件
- wgt 资源包热更新（Flutter 无此能力，改为整包更新）
- 屏幕共享、群组通话、桌面与 Web 端

### 3.3 四条原则

1. **后端不动**：协议 1:1 兼容，新客户端必须能与现有 uniapp 客户端互打互通。
2. **只用在线 WebSocket**：推送与信令行为与老端一致。
3. **单步开工**：每一步单独可验收，不跨步。
4. **细节不阻塞**：能修就修，修不了不纠结（自用场景）。

---

## 四、技术选型

| 领域 | 选择 |
| --- | --- |
| 状态管理 / 依赖注入 | `flutter_riverpod` |
| 路由 | `go_router` |
| HTTP | `dio` |
| WebSocket | `web_socket_channel` |
| 本地数据库 | `drift` + `drift_flutter`（+ 开发期 `drift_dev` / `build_runner`） |
| 本地键值 / 凭据 | `shared_preferences` + `flutter_secure_storage` |
| 音视频通话 | `flutter_webrtc` |
| 权限 / 音频会话 | `permission_handler` + `audio_session` |
| 音频播放（语音、提示音、铃声） | `just_audio` |
| 录音 | `record` |
| 图片 / 文件 / 视频 | `image_picker` + `file_picker` + `video_player` + `photo_view` + `cached_network_image` |
| 通知（通话前台服务） | `flutter_local_notifications` |
| 扫码 / 二维码 | `mobile_scanner` + `qr_flutter` |
| 悬浮窗（后期） | `flutter_overlay_window` |

**三条简化决策**：

- **emoji 不引 HTML 渲染库**：老端用 mp-html 渲染带 `<img>` 的表情。Flutter 端自写 `EmojiText`（`WidgetSpan` 内嵌图片），按 `[!name]` 语法解析即可。
- **输入框用普通 `TextField`**：老端的富文本 editor（H5 下还挂了 quill）对消息场景过度设计，消息本身是纯文本 + emoji 标记。
- **依赖按里程碑引入**：不一次性把 `drift` / `flutter_webrtc` / 各选择器等重依赖全堆进来，
  到对应里程碑再 `flutter pub add`，避免带着一堆没用的依赖开发和升级。

> 已引入（M0）：`flutter_riverpod`、`go_router`、`dio`、`web_socket_channel`、
> `shared_preferences`、`crypto`、`intl`、`flutter_svg`、`flutter_localizations`。
> 已引入（M3）：`drift`、`drift_flutter`（开发期 `drift_dev` + `build_runner`）。
>
> ⚠️ **不要加 `sqlite3_flutter_libs`**：它是 `sqlite3` 2.x 时代的产物，从 0.6.0 起
> 已经什么都不做了（pub 上的 `+eol` 后缀）。现在 `package:sqlite3` 3.x 通过 Dart 的
> build hooks 自带原生库，真机与单测都能直接用（实测：Windows 单测可用，
> Android debug 包构建通过）。

---

## 五、目标工程结构

```
lib/
├─ main.dart / app.dart
├─ core/
│  ├─ config.dart            # apiUrl / wssUrl / hostToken 自校验 / 环境切换
│  ├─ net/                   # dio 客户端、ApiResponse、错误码、接口常量
│  ├─ ws/                    # ws_client、ws_router（事件注册表）、ws_events
│  ├─ store/                 # 凭据与本地设置
│  ├─ theme/                 # ColorUI 绿主题、rpx→逻辑像素换算
│  ├─ i18n/                  # zh-Hans / en
│  └─ util/                  # uuid、时间格式化、文件大小、拼音、emoji 映射
├─ data/
│  ├─ db/                    # drift 表与 DAO
│  ├─ model/                 # message / conversation / contact / group / user
│  ├─ repo/                  # chat / contact / group / auth
│  └─ api/                   # auth_api / chat_api / group_api / file_api
├─ domain/call/              # 通话状态机、信令、ICE 配置
└─ features/
   ├─ splash/ login/ register/ home_shell/
   ├─ conversations/ chat/(message 渲染、输入区、预览)
   ├─ contacts/ groups/ moment/ scan/ profile/ settings/ webview/
   └─ call/(来电页、通话页) + 后期 overlay
```

---

## 六、分阶段实施计划

### M0 骨架与协议摸底（预计 0.5–1 天）

| 步骤 | 内容 | 参照老代码 | 验收标准 |
| --- | --- | --- | --- |
| S0.1 | 工程初始化：依赖清单、环境切换（dev/prod）、lint 与 analysis_options | — | `flutter analyze` 干净通过 |
| S0.2 | 分层目录 + `go_router` 路由表（照 `pages.json` 28 页）+ 绿色主题与 rpx 换算 + 底部 tab 外壳 | `pages.json`、`App.vue`（CustomBar/navBarHeight） | 真机能跑出带 4 个 tab 的空壳 |
| S0.3 | 资源迁移：iconfont 字体、tabbar 与导航图标、两份语言包、隐私文案 | `static/`、`locales/`、`androidPrivacy.json` | 图标与文案在空壳里正常显示 |
| S0.4 | 依据源码整理三张对照表：**WS 事件表、HTTP 接口表、通话事件 + 90x 码表**（纯静态分析，不需要真机） | `App.vue`、`api/*.js`、`call.vue`、`index.html` | 三张表与源码逐项对齐、无遗漏 |

> **M0 不需要真机配合。** 真实报文的采集推迟到 M6 之前（见 S6.0）——那时新客户端自己就是抓包器，只需要老端充当对端。

### M1 网络层（预计 2–4 天）

| 步骤 | 内容 | 参照老代码 | 验收标准 |
| --- | --- | --- | --- |
| S1.1 | Dio 封装与拦截器：`Authorization` / `clientId` / `cid` / `accept-language`、断网提示 | `utils/request.js` | 请求头与老端一致 |
| S1.2 | 错误码语义照搬：`code==0` toast、`code==-1` 强制重登、HTTP 401 重登/退出、500 提示 | `utils/request.js` | 三类错误行为与老端一致 |
| S1.3 | 接口常量全量迁移（约 100 个）到 auth / chat / group / file 四个 api 文件 | `api/*.js` | 接口清单无遗漏 |
| S1.4 | WS 客户端：连接、25s 心跳 ping/pong、断线重连（指数退避）+ 状态流 | `common/socket.js` | 断网 10s 内重连成功 |
| S1.5 | WS 事件路由：把 `App.vue` 巨型 switch 拆成 handler 注册表 | `App.vue` | 每类事件都能收到并落日志 |
| S1.6 | **协议日志开关**：把 WS 收发与 HTTP 请求/响应的原始 JSON 落成文件（仅 debug 开启）——这就是后续采集真实报文的工具 | 全新 | 能导出原始报文；S6.0 依赖它 |

### M2 登录与启动链路（预计 2–3 天）

| 步骤 | 内容 | 参照老代码 | 验收标准 |
| --- | --- | --- | --- |
| S2.1 | 登录页（`/common/Pub/login`）、注册页、验证码；扫码登录可延后 | `pages/login/*`、`api/login.js` | 能正常登录注册 |
| S2.2 | 凭据持久化：`authToken` / `userInfo` / `globalConfig` / `client_id` / `appSetting` | `store/login.js` | 重启后仍为登录态 |
| S2.3 | 启动序列：本地读 → `getSystemInfo` → WS connect → init → `bindUid`（带 cid）→ 首页 | `App.vue`、`store/login.js` | 冷启动直达首页 |
| S2.4 | 多端登录与"被顶下线"（`offline` 事件 + `multipleLogin` 判断） | `App.vue` | 别处登录能按原逻辑顶下线 |

### M3 数据层（预计 3–5 天）

| 步骤 | 内容 | 参照老代码 | 验收标准 |
| --- | --- | --- | --- |
| S3.1 | Drift 表：messages / conversations（**实际只建两张，理由见下**） | `store/message.js` | 表结构与接口字段一一对应 |
| S3.2 | DAO 与会话聚合：最后一条、未读、置顶、免打扰、草稿、@我、时间 | `store/message.js` `initContacts` | 聚合结果与老端一致 |
| S3.3 | repository：会话列表、消息分页、已读上报、本地缓存 | `store/message.js`、`api/message.js` | 替换掉 `allContacts`/`mainContacts` 的 storage 方案 |
| S3.4 | 字段口径对齐：`sendTime` 统一成毫秒（阈值归一化）、通话文案由服务端生成、`extends` 为 JSON | `App.vue` `appendMessage` | 时间与文案显示正确 |

> **表结构相比原计划的改动（M3 执行时的决定）**：
> * `contacts` / `groups` 不单独建表——老端把单聊、群聊、系统会话全部合并在
>   `allContacts` 这一个数组里（用 `is_group` 区分），分开建表反而要处处 UNION。
> * `users` 不建表——老端没有用户表，用户信息随会话与消息走；好友/群列表
>   （`friendList` / `groupList`）是另一份独立的缓存列表，放到 M5 再决定要不要落库。
> * `drafts` 不单独建表——老端草稿是 `draft_<会话 id>` 这个 key，语义上就是会话的一个属性，
>   落成会话表的一列；同步接口不下发 `draft`，所以同步用不含 draft 的 companion，不会被覆盖。
> * `app_settings` 不建表——就三个布尔开关，`SharedPreferences` 已足够（M2 已做）。

### M4 会话列表 + 聊天页（预计 1–1.5 周，工作量最大）

| 步骤 | 内容 | 参照老代码 | 验收标准 |
| --- | --- | --- | --- |
| S4.0 ✅ | **把推送接进库**：注册 `simple` / `group` 两个 WS 处理器（去重 → 落库 → 会话增量更新 → 提示音/未读），并在启动时拉一次 `getContacts` 对齐 | `App.vue` 的 `simple`/`group` 分支、`appendMessage` | 老端发来的消息能在新端落库并出现在会话列表 |
| S4.1 ✅ | 会话列表：列表、头像/在线点/最后一条/时间/未读/@/草稿、左滑置顶·免打扰·删除、筛选页签（所有/未读/@我）、PC 在线与 WS 断线提示；下拉刷新。**系统通知条延后**（它与推送/保活开关绑定，等 M8） | `pages/message/index.vue` | 列表行为与老端一致 |
| S4.2 ✅ | 聊天页骨架：反向列表、时间分隔、滚动到底/上拉加载历史、背景图、进页清未读、正在看时上报已读 | `pages/message/chat.vue` | 长列表滚动流畅不跳位 |
| S4.3 ✅ | 消息渲染：文本+emoji 混排、图片、语音、视频、文件、位置、名片、webrtc 卡片、动态表情、未知类型 | `components/messageType/*` | 9 类消息都能正确显示 |
| S4.4a ✅ | 输入区（文本 + 表情/收藏表情发送、引用条、草稿、失败重发） | `components/message/im-input.vue`、`chat.vue::sendMessage` | 能真的发出去，气泡有发送状态 |
| S4.4b ✅ | ＋面板与上传：图片/视频/文件（含 `uploadFile` 表单直传、大小与视频时长限制）。名片在 S4.6b 补齐 | 同上 | 各入口行为与老端一致 |
| S4.4c ✅ | 录音（按住说话/上滑取消/60 秒上限/太短丢掉/权限提示）与 @成员（群成员选择器 + `at` 数组） | 同上、`components/message/user-select.vue` | 同上 |
| S4.5 ✅ | 消息操作：长按菜单（撤回/复制/存表情/转发/引用/删除）、撤回后重新编辑、转发选人（≤5）、删除确认、「N 人提到我」面板与 @ 已读。**「查看上下文」用本地库代替服务端接口**（见下） | `pages/message/chat.vue`、`pages/index/userSelection.vue` | 操作结果在老端可见 |
| S4.6 ✅ | 预览：图片多图浏览 + 保存到相册、视频播放页（全屏播放 + 保存）、文件「本地预览 / 在线预览」、位置唤起系统地图 | `mixins/chat.js`、`pages/message/video.vue` | 各类型预览正常 |
| S4.6b ✅ | 名片收尾：发名片（＋面板 → 选好友）+ 点名片进资料页 | `im-input.vue::sendContactCard`、`mixins/chat.js::openContact` | 名片收发与点击都有反应 |

### M5 联系人 / 群 / 我的（预计约 1 周）

| 步骤 | 内容 | 参照老代码 | 验收标准 |
| --- | --- | --- | --- |
| S5.1 ✅ | 通讯录：拼音分组索引、好友列表、群聊列表、新朋友申请与处理 | `pages/contacts/*` | 索引与申请流程可用 |
| S5.2 ✅ | 用户详情：发消息 / 加好友 / 拨号 | `pages/contacts/detail.vue` | 三个动作都可用 |
| S5.3 ✅ | 群信息与管理：成员、改名、公告、群管理开关、管理员、禁言、踢人、退群/解散、清空记录。**群二维码 / 聊天背景 / 单聊页「发起群聊」延后到 S5.3b** | `pages/message/group/*`、`pages/message/detail.vue`、`components/message/user-select.vue` | 群操作在老端可见 |
| S5.4 ✅ | 搜索：服务端搜人、好友/群本地搜索、会话内聊天记录（分页 + 关键词 + 查看上下文）。**「全局消息搜索」是老端没有的东西**（见下） | `pages/contacts/search.vue`、`pages/index/search.vue`、`pages/message/record.vue` | 搜索结果正确 |
| S5.5 ✅ | 我的：资料与头像上传、账号安全、通用设置（多语言/提示音/震动）、关于、帮助中心（webview 外链留 M7） | `pages/mine/*` | 设置项持久化生效 |
| S5.6 ✅ | **用户选择器**（只做 `type == 1` 创建群聊：好友多选 + 搜索 + 底部已选头像栏；建群后本地落库并直接进新群） | `pages/index/userSelection.vue` | 从「＋」菜单建群 → 进新群能正常聊天 |
| S5.6b ✅ | 单聊页「发起群聊」（预选对方）、**表情管理页**（上传/整理/删除/移到最前） | `pages/message/emoji.vue`、`pages/message/detail.vue` | 表情能传能删能派序；从单聊一步开群 |

### M6 通话 · 原生重写（预计 1–2 个月，拆 6 步）

| 步骤 | 内容 | 参照老代码 | 验收标准 |
| --- | --- | --- | --- |
| S6.0 ★ | **采集真实报文样本**：用老端（充当对端）给新端发各类消息、打各类电话，新端把收到的原始 JSON 导出到 `docs/protocol/`，据此校正数据模型与通话文案 | S1.6 的日志开关 | 三张表用真实报文校准完毕；通话记录文案与老端逐字一致 |
| S6.1 ✅ | **信令层**：Dart 状态机（idle/outgoing/incoming/connecting/connected/ended）+ 事件与 90x 码 1:1 兼容 + `sendToMsg` 通道 + 忙线判定 + 多端锁语义 | `call.vue`、`App.vue` webrtc 分支、`index.html` | 已交：纯 Dart 无 IO，86 个单测钉住每一条信令与分支（详见下方 S6.1） |
| S6.2 ✅ | **媒体层**：`flutter_webrtc` 建连、`getUserMedia`、track 管理（静音/关摄像头/切前后置）、ICE 配置（站点 STUN/TURN + 公共 STUN 兜底）、控制器把状态机接上真实世界 | `index.html` | 已交：144 个通话测试全过、release 包能打；**真机互打仍需你来验**（详见下方 S6.2） |
| S6.3 ✅ | **通话 UI**：来电全屏页、通话中页（计时/挂断/静音/免提/切摄像头/大小窗互换）、通话记录卡片、铃声与挂断音 | `hybrid/html/index.html`、`components/messageType/im-webrtc.vue` | 已交：装上包就能看到通话页；**真机互打是下一步唯一要做的事**（详见下方 S6.3） |
| S6.4 | **原生能力**：权限（麦克风/摄像头/蓝牙 API31+/Android 14 前台服务用麦）、`audio_session` 设为 voiceCommunication、听筒/扬声器/蓝牙路由、屏幕常亮 | `call.vue` 权限逻辑、`utils/permission.js` | 耳机与听筒切换正确、无音频焦点冲突 |
| S6.5 ★ | **通话期间前台服务**：安卓"通话中"常驻通知 + iOS 后台音频模式 | 全新（老端靠保活插件） | 通话中切后台/息屏不断线 |
| S6.6 | （后期可选）锁屏来电：Android 全屏通知 / iOS CallKit + VoIP Push | 全新 | 锁屏可接听 |
| S6.6a ✅ | **通话小窗（画中画）**：**点按钮才进**（第二版改的：滑到后台不进，只留前台服务+通知）、比例与内容对齐微信（语音 1:1 / 视频 3:4）、通话结束自动收窗口 | 全新（用户指定要微信那种） | 已交：真机验证进入/退出与窗口尺寸（详见下方 S6.6a） |
| S6.3e ✅ | **通话页改版：全面对齐微信**（背景/居中方头像/圆钮开关配色/状态文案/左上角缩成小窗/视频多出的免提与摄像头开关） | 用户给的微信截图 | 已交：874 个测试通过（详见下方 S6.3e） |

**M6 总验收清单（逐项打勾）**：与老 uniapp 客户端互打语音/视频；接通、拒接、忙线、取消、超时；通话中切后台不断；WiFi ↔ 4G 不断或快速恢复；蓝牙耳机与听筒切换正确；通话记录文案正确。

### M7 杂项页面（预计几天）

| 步骤 | 内容 | 参照老代码 |
| --- | --- | --- |
| S7.1 ◐ | **已交**：发现页（服务端配置驱动）+ 内嵌浏览器 + 扫一扫 + 我的/群二维码 + 群资料（扫码进群）。用户选择器在 S5.6、表情管理在 S5.6b。**还差**：朋友圈（仍是占位页）、扫码登录确认页 | `pages/compass/*`、`pages/index/{scan,qrcode}.vue`、`pages/mine/webview.vue`、`pages/message/group/info.vue` |
| S7.2 | 版本检查（整包更新，无 wgt） | `common/appUpdate.js` |
| S7.3 | 多语言收尾与文案校对 | `locales/*` |

### M8 后期（按需）

| 步骤 | 内容 |
| --- | --- |
| S8.1 | 保活 + 离线推送（APNs + 厂商通道）+ 来电唤醒 |
| S8.2 | 悬浮窗（Android overlay；iOS 退化为应用内小窗） |
| S8.3 | 真机矩阵回归与性能优化 |

---

## 七、三个关键里程碑

| 里程碑 | 完成标志 |
| --- | --- |
| **M1 结束** | 能登录，WebSocket 在线，事件可观测 |
| **M4 结束** ✅ | 两个账号能完整聊天（全部消息类型）——S4.6 与 S4.6b 已完成，名片能发能点 |
| **M6 结束** | 能与老客户端互打电话（语音 + 视频） |

真实报文采集（S6.0）**不阻塞前期任何工作**，安排在 M6 开工之前即可。唯一必须双设备配合的环节是 M6 的通话互打验证。

---

## 八、风险登记

| # | 风险 | 应对 |
| --- | --- | --- |
| 0 | **站点配置的 ICE 地址写法（已修，但建议改配置）** | 站点后台 `chatInfo.stun` 实测填的是 `stun.cloudflare.com:3478`（**缺 `stun:` 前缀**）。客户端已会自己补（`CallMediaConfig.normalizeIceUrl`）+ 建连后健康检查，但**建议把后台改成 `stun:stun.cloudflare.com:3478`**；以后接 TURN 同理。详见 S6.3b |
| 1 | **P2P 打不通（最高）** | S6.2 已把 ICE 列表结构搭好：公共 STUN（老端那六个）+ 站点 STUN/TURN（`chatInfo.stun/stunUser/stunPass`）+ 一个**自建 TURN 的空位**（`CallMediaConfig.ownTurnServers`）。**待办事：把 coturn 地址填进去**，否则两边都在对称 NAT 后面时通话建不起来（新端会提示网络问题并结束，不会黑屏无声） |
| 2 | **通话中切后台断线** | S6.5 前台服务，属于底线而非可选体验 |
| 3 | **通话记录文案由服务端生成** | `event`/`status`/`code` 必须一字不差，以 S0.4 样本为准 |
| 4 | **与老端互通的边界** | 新端可往信令里加私有字段（老端忽略），但不改已有字段语义；批量候选、重传等增强只在两端均为新端时启用 |
| 5 | **历史消息含 HTML** | 先做纯文本 + emoji，遇到 HTML 用简单解析兜底 |
| 6 | **iOS 后台模式与审核** | 只保留通话必需的后台模式，不沿用老端定位续命那套 |
| 7 | **悬浮窗 iOS 不可用** | 别按双端排期；Android overlay，iOS 只能应用内小窗 |
| 8 | **隐性约定容易漏** | 见下方清单，已分别落进 M1/M3 |

---

## 九、隐性约定清单（容易踩的坑）

1. **HTTP**：`POST` JSON，路径如 `/enterprise/im/*`、`/enterprise/group/*`、`/common/pub/*`；请求头带 `Authorization`、`clientId`、`cid`、`accept-language`。
2. **响应判定**：`code == 0` 成功；`code == -1` 强制重新登录；HTTP 401 走重登/退出。
3. **WS**：`wss://{host}/wss`，客户端每 25 秒发 `{"type":"ping"}`；服务端发 `ping` 时需回 `pong`。
4. **WS 事件全集**：`init`、`ping`、`pong`、`isOnline`、`offline`、`updateConfig`、`simple`、`group`、`setChatTop`、`setIsNotice`、`addGroup`、`setManager`、`addGroupUser`、`removeUser`、`undoMessage`、`editGroupName`、`removeGroup`、`setNotice`、`groupSetting`、`appendContact`、`webrtc`。
5. **`sendTime` 单位老端自己也不统一**（M3 已查清）：渲染层 `utils.js::date()` 用
   `if (timestamp < 90000000000) timestamp *= 1000` 兼容两种单位；但逻辑判断按**毫秒**写
   （`chat.vue` 的“3 分钟插时间分隔”与“能否撤回”都是 `sendTime` 毫秒相减），
   而 WS 推送分支又写了 `data.sendTime * 1000`（说明推送那份是秒）。
   → 新端统一：**入库前一律归一化成毫秒**（`data/model/time_units.dart::toMillis`，阈值与老端一致）。
6. **两个接口的 `data` 是数组，不是对象**：`getContacts`（会话列表）与 `getMessageList`（消息列表）。
   老端直接 `res.data.forEach` / `res.data.length`；用“只取对象”的封装读它们会静默拿到空 map。
   → `ApiClient` 单独开了 `postList` / `postListMaps`。
7. **通话记录文本由服务端生成**，客户端只发 `event` / `status` / `code` / `callTime` / `sdp` / `iceCandidate`。
8. **`config.js` 有 hostToken 自校验**（`sha` + `md5(md5(host))` + `bi`），校验失败则 `apiUrl = 'false'`；为保持行为一致建议照搬并保留告警。
9. **多端登录**：`multipleLogin` 配置、`isOnline` 事件里的 `webrtcLock` 解锁逻辑。
10. **老端 `socket.js` 里混入了与本项目无关的抄写残留代码**（交易/跟单相关），重写时直接丢弃。
11. **`cid` 全项目只读不写**，所以老端上报的永远是空串（M2 已查明）；新端同样不伪造。
12. **老端会话列表的未读统计有两处不对称**（M3 已原样保留并测试固定）：
    未读只在“有 lastContent 且非免打扰”时累加，但 `@` 数不判免打扰；红点集合又只给非免打扰的会话。
13. **平台能力一律走 provider，不要直接在界面里读**：`defaultTargetPlatform` 在 widget 测试里是
    **宿主机**（Windows 上跑就是 windows），`MethodChannel`（本机版本号那条 `gracelinkim/app_info`）
    在 flutter_tester 里**永远不完成**（不是抛异常），所以「读平台 / 读版本」这类都要能注入
    （`targetPlatformProvider` / `appVersionSourceProvider`），否则用例里要么分流走错、要么直接挂住。

---

## 十、为什么还需要真实报文样本

老客户端是明文可读的 JS，因此大部分协议**静态分析就能拿到，不需要任何真机配合**。但有一小部分信息只存在于服务端的返回里，源码里看不到。这两类的边界如下。

### 10.1 能从源码完整读出的（不需要样本）

- 全部接口路径、请求字段、请求头（`Authorization` / `clientId` / `cid` / `accept-language`）
- WS 地址、心跳规则、**全部事件名**
- 通话的事件名、`status` 取值、90x 码
- 客户端发出去的信令字段清单
- 消息模型的字段名（客户端消费侧）、页面与交互逻辑

### 10.2 只能靠真实报文确定的

| # | 项目 | 为什么读不出来 | 影响范围 |
| --- | --- | --- | --- |
| 1 | 服务端返回的完整字段集与嵌套 | 源码里同一处出现 `fromUser.id` 与 `fromUser.user_id` 两种写法，实际用哪个只能看报文 | M1 / M3 / M4 |
| 2 | 字段确切类型与单位 | `code` 有时 `parseInt` 有时松散比较。**`sendTime` 已在 M3 从源码侧查清并用阈值归一化规避**（见第九节第 5 条），剩下的是“服务端到底给哪一种”这一条确认项 | M1 / M3 |
| 3 | 9 种消息类型 `extends` 的具体嵌套 | 源码只用到其中一部分字段 | M3 / M4 |
| 4 | 服务端生成的通话记录文案 | 客户端不发送 content，文案由服务端拼 | M4 / M6 |
| 5 | `905` 码的语义 | 客户端代码里从未出现 | M6 |
| 6 | 分页参数名与游标 | 需与实际返回对照 | M3 / M4 |
| 7 | WS 推送的信封结构与各 type 的 data 结构 | 只知 `type` / `data` 两层，内部字段靠观测 | M1 |
| 8 | 服务端转发 ICE candidate 的行为 | 是否可靠、是否有序、有无去重或限流，只能实测 | M6 |

### 10.3 怎么采：新端自己当抓包器

1. 新端在 **S1.6** 打开协议日志开关（把 WS 收发与 HTTP 请求/响应的原始 JSON 落文件）。
2. **老端充当对端**：用老端给新端发各类消息、打各类电话。
3. 新端记录的，就是**服务端原样返回的报文**，一份日志同时覆盖 WS 推送与 REST 响应。

因此**不需要 Charles / mitmproxy 之类的代理抓包，也不需要改老客户端代码**。

### 10.4 唯一必须双设备配合的环节

- **M6 的通话互打验证**：两个账号、两台设备，语音与视频都要实测（无人能替）。
- 各里程碑结束后的真机 UI 走查：跑一下、看一眼即可，不需要专门操作。

---

## 十一、附：通话信令速查

**事件**：`calling`（发起）、`acceptRtc`（接听）、`offer`、`answer`、`iceCandidate`、`hangup`（挂断）、`busy`（忙线）、`turndown`、`otherOpt`（多端同步）、`mediaDevices`（媒体获取失败）

**状态（`status`）**：`0` 默认 / `1` 拨号中 / `2` 通话中 / `3` 来电中 / `4` 忙线

**错误码（90x）**：

| 码 | 含义 | 来源 |
| --- | --- | --- |
| 901 | 发起呼叫 | WebView `getUserMedia` 成功后回传 |
| 902 | 主叫取消 | 未接通时挂断 |
| 903 | 被叫拒接 | 来电状态下挂断 |
| 904 | 已接听 | 被叫 `acceptRtc` |
| 905 | 未在客户端出现 | 语义待确认（可能仅服务端使用） |
| 906 | 通话中挂断 | 通话结束后挂断 |
| 907 | 对方忙线 | 多端/多通话冲突 |

**`sendToMsg` 关键字段**：`id`、`msg_id`、`toContactId`、`type`、`event`、`status`、`code`、`callTime`、`sdp`、`iceCandidate`

**ICE 配置来源**：服务端 `globalConfig.chatInfo` 下发 `stun` / `stunUser` / `stunPass`；老端默认回退到公共 STUN。**Flutter 端应自行合并一组自有 STUN/TURN。**

---

## 十二、进度记录

| 里程碑 | 状态 | 产出 |
| --- | --- | --- |
| M0 骨架与协议摸底 | ✅ 已完成 | 见下 |
| M1 网络层 | ✅ 已完成 | 见下 |
| M2 登录与启动链路 | ✅ 已完成 | 见下 |
| M3 数据层 | ✅ 已完成 | 见下 |
| M4 会话列表 + 聊天页 | ✅ 已完成 | 见下（九类消息都能收发与预览；名片在 S4.6b 补齐） |
| M5 联系人 / 群 / 我的 | ✅ 已完成 | S5.1 通讯录 / S5.2 用户详情 / S5.3 群信息与管理 / S5.4 搜索 / S5.5 我的（详见 M5 进度） |
| M6 通话原生重写 | 🚧 进行中 | S6.1 信令层、S6.2 媒体层、S6.3 通话界面、S6.3c 诊断面板、S6.5 前台服务（安卓）、S6.6a 通话小窗均已完成并在真机验证（详见 S6.3c/S6.3d/S6.5/S6.6a）；**下一步 S6.4 声音路由（听筒/扬声器/蓝牙）与 iOS 后台音频** |
| M7 杂项页面 | ⬜ 待开工 | |
| M8 保活 + 离线推送 | ⬜ 待开工 | |

### M0 交付物

| 步骤 | 产出 |
| --- | --- |
| S0.1 | `pubspec.yaml`（依赖 + 资源 + 字体）、`analysis_options.yaml` 沿用 flutter_lints |
| S0.2 | `lib/core/{config,theme,i18n,router}`、`lib/features/{home,common}`；`flutter analyze` 零问题 |
| S0.3 | `assets/`（navtab SVG 8 个、`customicons.ttf`、`iconfont.ttf`、中英语言包、logo/empty 图） |
| S0.4 | `docs/protocol/`：`README.md`（含待确认清单与本轮发现的问题）、`ws-events.md`、`http-api.md`、`call-signaling.md` |

### M0 遗留 TODO

1. `cuIcon-*`（292 个图标）的字体以 base64 内联在老端 `static/css/icon.css` 里，
   需在 M4/M5 抽成字体资源；在此之前骨架里少数图标用 Material 图标顶替。
2. ~~服务端 `globalConfig` 拉取后接上「发现」tab 的显隐（`compass.status == 1`）~~ → **M2 已完成**。
3. ~~语言切换（运行时切换入口在 M5 的设置页）~~ → 登录页右上角已可切（M2）；
   设置页里的入口仍在 M5 接。
4. 老端 `socket.js` 的残留代码（`traderDetailIndex` 等）在 M1 重写时直接丢弃。

### M1 交付物

| 步骤 | 产出 |
| --- | --- |
| S1.1 | `lib/core/net/api_client.dart`：Dio 封装 + 拦截器（四项请求头）、超时 10s、`ResponseType.plain` 自解析 |
| S1.2 | `lib/core/net/api_exception.dart`（sealed 异常层次 + 业务码映射）、`api_response.dart`（信封）；提示/重登通过 `core/ui/notice_bus.dart` → `notice_handler.dart` 走 UI 层 |
| S1.3 | `lib/data/api/endpoints.dart`（60 个路径常量）+ `auth_api / chat_api / group_api / friend_api / emoji_api / upload_api` |
| S1.4 | `lib/core/ws/ws_client.dart`：连接、25s 心跳、心跳超时判定、指数退避重连（1s→30s 带抖动） |
| S1.5 | `lib/core/ws/ws_router.dart`（处理器注册表 + 未知事件记录）、`ws_handlers.dart`（协议层 ping/pong/init）、`ws_service.dart` |
| S1.6 | `lib/core/net/protocol_log.dart`：WS 收发与 HTTP 请求/响应原始报文落 JSONL，`dumpToFile()` 导出 |
| — | `lib/core/store/credential_store.dart`：替代 `uni.setStorageSync` |

测试：36 个单测（`test/net/`、`test/ws/`），覆盖错误码语义、请求头、路径归一化、退避策略、事件解析与路由容错。

### M1 遗留 TODO

1. **各接口的参数名未定**：M1 只迁移了路径与调用方法，参数一律 map 透传；
   实现对应页面时（M2 登录、M4 聊天）再按老端调用点补齐字段名。
2. **上传的表单字段名未定**：老端用 `uni.uploadFile`，字段名在调用处指定，需真实请求校正。
3. `bindUid` / `bindGroup` 的调用时机已备好（`init` 事件回调），但**登录链路在 M2 才接**。
4. WS 目前**启动即连**（对齐老端 `App.vue onShow`），未登录也会建连（只拿 `client_id`，不做 `bindUid`）。
5. 若服务端推送了未知事件，会被记入 `WsRouter.unknownTypes` 并打日志——这是发现协议盲区的钩子。

### 协议实测（提前完成了一部分 S6.0）

用新增的 `tool/ws_probe.dart` 连了一次线上服务端（不需账号、不发业务消息）：

```
dart run tool/ws_probe.dart wss://message.gracelink.cc/wss 20
```

结果：WS 握手可用（无需鉴权头），`init` / `pong` 的真实报文已存档到
`docs/protocol/samples/ws-probe-*.jsonl`，并已固化成单测。

关键发现（都直接影响实现）：

1. **协议事件是扁平信封**：`{"type":"init","client_id":"…"}`、`{"type":"pong","multiport":false}`
   ——**没有 `data` 层**，字段直接在顶层。所以 `WsEvent` 必须同时暴露顶层字段。
2. **`multiport` 是布尔值**，不是 `1` / `0`。
3. **`init` 在连接后立即下发**（本次在首帧 ping 之后 3ms），`client_id` 不用等业务动作。
4. 20 秒内服务端未主动发 `ping`（客户端仍保留回 `pong` 的能力）。

仍需登录后再测（S6.0）：业务事件（`simple` / `group` / `webrtc`）的 `data` 层与字段命名、
HTTP 响应的 `code` 语义边界、`sendTime` 单位。

### M2 交付物

| 步骤 | 产出 |
| --- | --- |
| S2.1 | `lib/features/login/login_page.dart`（语言选择、站点 logo/名、账号密码、忘记密码=验证码登录、记住我、演示账号、版本号）、`register_page.dart`（中文过滤、`regauth` 提示语、验证码）、`widgets/auth_widgets.dart` |
| S2.2 | `lib/core/store/session_store.dart`（`SessionState` + Riverpod Notifier）、`lib/data/model/{global_config,user_info,app_setting}.dart`；凭据全部落 `CredentialStore` |
| S2.3 | `lib/domain/session/session_service.dart`（登录 / 注册 / 验证码 / 登出 / 配置拉取 / `bindUid`）、`lib/features/splash/splash_page.dart`、`lib/core/router/session_guard.dart` |
| S2.4 | `offline`（被顶下线，含 `multipleLogin` 与 `isMobile` 三条件判断）、`updateConfig`（配置热更新）两个 WS 处理器 |
| S2.5 | `lib/core/i18n/locale_controller.dart`：运行时语言切换（登录页右上角），`app_i18n.dart` 跟随语言重算 |

测试：86 个单测（新增 `test/session/`、`test/router/`、`test/support/fake_web_socket.dart`），
覆盖全局配置的宽松解析与默认值、用户模型、会话状态落盘、
登录/注册/验证码/登出参数、`init → bindUid`、四种「被顶下线」组合、配置热更新、路由守卫四条规则。

### M2 与老端不同的四处（都是刻意的）

1. **多了启动页 + 路由守卫**。老端一启动直接画主界面，等接口 401 才把人踢去登录页
   （主页会闪一下）；新端启动时同步读本地会话，直接决定去登录页还是主界面。
2. **登出不依赖接口结果**。老端只在 `logout` 接口 `code == 0` 时才清本地，接口一挂就登不出去；
   新端无论接口结果都清本地。
3. **配置接口返回空数据不覆盖**。老端是 `globalConfig = res.data` 无脑覆盖，
   如果服务端返回 `data: null`，刚推来的 `updateConfig` 会被抹回默认值；新端保底保留现有配置。
4. **注册页的密码校验按文案本意实现**。老端写的是
   `password == '' && length < 6 && length > 16`（三个条件同时成立才拦），等于没校验。

### M2 遗留 TODO

1. **登录响应字段仍待真实报文确认**：目前按 `{authToken, userInfo}` 解析并保留原始 map，
   等 S6.0 采到真实样本后校正 `UserInfo` 的字段清单（尤其头像地址是完整 URL 还是相对路径）。
2. **`cid` 一直是空串**：老端只读 `uni.getStorageSync('cid')`，全项目从来没有写入过它。
   新端照旧（不伪造一个设备 id，避免改变服务端语义），等 M8 接离线推送时再定。
3. **扫码登录**（`pages/login/qrlogin` + `tokenLogin`）按计划推迟到 M7。
4. 老端登录页底部那个隐藏的 `safe-verify`（连点 15 次复制设备 id）是开发者彩蛋，未实现。
5. 语言切换入口已可用（登录页右上角），但设置页里的切换入口在 M5 接。

### M3 交付物

| 步骤 | 产出 |
| --- | --- |
| S3.1 | `lib/data/db/tables.dart`（`DbConversations` / `DbMessages`，含两条索引+字段注释）、`app_database.dart`（`AppDatabase` + `appDatabaseProvider`）、`app_database.g.dart`（drift 生成） |
| S3.2 | `lib/domain/chat/conversation_rules.dart`（排序 / 置顶 / 预览文案 / 未读汇总 / 推送落会话，全部纯函数）、`lib/data/model/time_units.dart`（时间归一化） |
| S3.3 | `lib/data/db/{conversation,message}_dao.dart`（增删改查）、`lib/data/repo/{conversation,message}_repository.dart`（同步、分页、已读、撤回、草稿） |
| S3.4 | `lib/data/model/{message,conversation}.dart`（服务端 JSON ↔ 数据库行 ↔ 领域对象）、`ApiClient.postList/postListMaps` |

测试：169 个（新增 81 个）——
`test/chat/`（时间归一化、排序/汇总/预览/推送落地等规则）、
`test/db/`（真实 SQLite 内存库：去重、排序、游标、已读、级联删除、草稿保护）、
`test/repo/`（用真实 `ApiClient` + 假 adapter 断言请求参数：同步、分页游标、已读上报、撤回、置顶）。

### M3 挖出的问题（老端遗留）

1. **`sendTime` 单位混用导致撤回按钮失效**。
   渲染层用阈值兼容了两种单位，但“能否撤回 / 是否插时间分隔 / 已读上报”三处都按毫秒相减，
   而 WS 推送分支又写了 `* 1000`（说明推送那份是秒）。
   如果服务端在 WS 推送里给的确实是秒，**老端自己发出去的消息永远看不到“撤回”按钮**
   （除非是群管理员，因为那里有个 `role < 3` 的或条件）。
   → 新端统一入库毫秒，并用老端那套阈值归一化，两种单位都不会错。
2. **`getContacts` / `getMessageList` 返回的是数组**，但项目里其他接口返回对象；
   用同一个封装读会静默拿到空数据（老端是 JS，没这个限制，所以没暴露）。
   → 新端明确分开 `postMap` 与 `postList`。
3. **名片类型的预览 key 写错了**：`getMsgType` 用 `common.IDcard`，语言包里是 `common.idcard`，
   所以老端会话列表对名片消息会显示字面量 `[common.IDcard]`。新端用正确 key。
4. **`delChat` 只删会话不删本地记录**（老端本来也没存历史，所以看不出问题）；
   新端删会话时连本地聊天记录一起清掉。

### M3 遗留 TODO

1. ~~M4 才把推送接到库里~~ → **S4.0 已完成**：`simple` / `group` 等六个事件已注册（见 M4 进度）。
2. ~~9 种消息类型 `extends` 的具体字段~~ → **S4.3 已从渲染代码读全**（见 `docs/protocol/message-types.md`），
   仍待真实报文验证“服务端会不会多给/少给”。
3. ~~数据库迁移策略~~ → **S4.4a 已补**：`schemaVersion = 2` + `MigrationStrategy.onUpgrade`
   （加了 `clientId` / `status` 两列，都有默认值，老库升上来不丢数据）。
4. **`friendList` / `groupList` 还没落库**（老端存在 storage 里），M5 做通讯录时决定。
5. **性能**：目前所有查询都是同步小表，未测大数据量（几万条消息）下的表现；
   真要优化优先加索引而不是提前分库。

### M4 进度（进行中）

| 步骤 | 状态 | 产出 |
| --- | --- | --- |
| S4.0 | ✅ 完成 | `lib/domain/chat/chat_sync_service.dart`（`simple`/`group`/`isOnline`/`setChatTop`/`setIsNotice`/`undoMessage` 六个处理器 + 登录后对齐）、`lib/core/audio/message_alerter.dart`（提示音/震动，按会话免打扰开关） |
| S4.1 | ✅ 完成 | `lib/features/conversations/`（`conversation_list_page.dart` + `widgets/conversation_tile.dart` + `widgets/swipe_action_row.dart`）、`lib/core/util/time_format.dart`、`lib/core/util/emoji.dart`（表情分段与纯文本预览） |
| S4.2 | ✅ 完成 | `lib/features/chat/chat_page.dart`（聊天页本体）、`lib/features/chat/widgets/message_bubble.dart`（气泡骨架，S4.3 换真内容）、`lib/domain/chat/chat_items.dart`（时间分隔规则，纯函数）、`lib/core/store/credential_store.dart`（`chat-bg-info<id>` 背景读写） |
| S4.3 | ✅ 完成 | `lib/domain/chat/message_media.dart`（九种类型的载荷解析，纯函数）、`lib/features/chat/widgets/media/`（`image/voice/video/file/location/contact/call/unsupported` 八个气泡）、`lib/core/util/media_format.dart`（`getFileSize`/`videoFormatTime`/`imageCoverStyle` 三个工具）、`lib/core/audio/voice_player.dart`（语音播放，单通道）、`lib/features/chat/image_preview.dart`（多图预览） |
| S4.4a | ✅ 完成 | `lib/features/chat/widgets/chat_input.dart`（输入区）、`widgets/emoji_panel.dart`（表情/收藏两个 tab）、`lib/domain/chat/outgoing_message.dart`（请求体与引用块，纯函数）、`lib/data/repo/message_sender.dart`（乐观消息 + 发送 + 失败/重发）、`lib/core/util/emoji_pack.dart`（66 个内置表情码值）、`lib/core/util/uuid.dart` |
| S4.4b | ✅ 完成 | `lib/core/media/media_picker.dart`（`MediaPicker` 接口 + `SystemMediaPicker` 实现：相册/视频/文件三类，按后缀分类）、`ChatApi.uploadFile`（`FormData` 表单直传）、`MessageSender.sendMedia`（本地路径乐观落库 → 上传 → 服务端地址覆盖）、`widgets/media/media_image.dart`（本地文件与网络图统一渲染）、`GlobalConfig.maxUploadMb` |
| S4.4c | ✅ 完成 | `lib/core/audio/voice_recorder.dart`（`VoiceRecorder` 接口 + `record` 实现、`Recording`）、`lib/domain/chat/group_members.dart`（成员解析/搜索/`resolveAt`，纯函数）、`lib/features/chat/widgets/member_picker.dart`（群成员选择器弹层）、`lib/data/repo/group_member_repository.dart`（`groupMembersProvider`）、`GroupApi.userListMaps`（成员接口返回的是**数组**）、输入区的录音模式与 @ 按钮 |
| S4.5 | ✅ 完成 | `lib/domain/chat/message_actions.dart`（菜单项规则/可撤回窗/复制内容，纯函数）、`lib/domain/chat/forward_targets.dart`（转发候选解析，纯函数）、`lib/features/chat/widgets/forward_picker.dart`（转发选人弹层）、`lib/features/chat/widgets/mention_panel.dart`（@ 我面板）、`MessageRepository.{delete,forward,mentioning}`、`MessageBubble` 改成「动作列表 + 回调」 |
| S4.6 | ✅ 完成 | `lib/core/media/media_saver.dart`（`MediaSaver` 接口 + `SystemMediaSaver`：下载/存相册/系统打开/开链接，本机路径直通）、`lib/domain/chat/file_preview.dart`（后缀白名单与地图链接，纯函数）、`lib/features/chat/video_preview_page.dart`（全屏播放页）、`lib/features/chat/widgets/file_preview_sheet.dart`（本地/在线两项弹层）、`image_preview.dart` 加「保存到本地」、`media_format.dart::localFilePathOf`、`media_image.dart` 复用同一归一化 |
| S4.4d | ✅ 完成 | `lib/core/media/image_compressor.dart`（`ImageCompressor` 接口 + `NativeImageCompressor`（`flutter_image_compress` 原生编码）+ `NoopImageCompressor` + 纯逻辑 `shouldCompressImage`/`compressedImageName` + `imageCompressorProvider`）、`chat_page._sendMedia` 接线（**先压再判大小上限**）；服务端 `Upload.php` 不再把每张图都转 PNG |

测试：361 个（S4.3 的 231 + S4.4a 新增 32 + S4.4b 新增 8 + S4.4c 新增 25 + S4.5 新增 44 + S4.6 新增 21）——
`test/features/conversation_list_test.dart`（整个 App 跑真实路由 + 内存库 + 假网络：排序、未读角标、筛选页签、左滑阈值、群聊不给删除、进聊天页）、
`test/features/chat_page_test.dart`（同样跑整个 App，进的是真聊天页）、
`test/chat/chat_items_test.dart`（时间分隔）、`test/chat/emoji_test.dart`、`test/db/`，
S4.3 新增 `test/chat/message_media_test.dart`（九种类型的载荷解析，含缺字段/空值/单位边界）与
`test/features/message_render_test.dart`（同样跑整个 App：十种气泡各就各位、语音点一下播放再点一下停、点图进多图预览）；
S4.4a 新增 `test/chat/outgoing_message_test.dart`（请求体逐字段 + 引用块 + 能不能发言的四种组合）、
`test/repo/message_sender_test.dart`（乐观落库 → 回执合并 / 失败标红 / 重发 / 401 删除 / 回显认领）、
`test/features/chat_send_test.dart`（跑整个 App：敲字发出去、失败点重发、表情插入与收藏直发、引用、草稿、禁言、系统会话无输入框）。
S4.4b 新增 `test/repo/media_send_test.dart`（**表单直传的字段名与值逐字段断言**：`message` 是整条消息 JSON、`file` 是文件本体；图片/视频/文件三种；上传失败标红、重发重新上传同一份本地文件）
与 `test/features/chat_send_test.dart` 的「＋」面板用例（选图 → 面板关闭 → 乐观气泡立刻出现、超限与超时长只提示不发请求）。
S4.4c 新增 25 个（共 296 个）：`test/chat/group_members_test.dart`（成员解析/搜索/@ 解析）、
`test/repo/voice_send_test.dart`（语音表单直传字段、失败重发重新上传、`at` 发与不发）、
`test/features/chat_voice_test.dart`（跑整个 App：按住→松开发语音、录满 60 秒自动发、上滑取消、太短丢掉、权限被拒不录、禁言不录，录音器用替身）、
`test/features/chat_mention_test.dart`（跑整个 App：@ 按钮只在群聊聚焦时出现、选人插入 `@名字`、发送带 `at`、删掉 @ 就不带、成员接口失败给空态）。
S4.5 新增 44 个（共 340 个）：`test/chat/message_actions_test.dart`（菜单项的六个 `v-if` 条件、顺序、时间窗、复制内容）、
`test/chat/forward_targets_test.dart`（转发候选的过滤/搜索/群聊后缀）、
`test/repo/message_actions_test.dart`（删除的接口参数与本地删除、删除失败不先删本地、转发参数、撤回标记、@ 我查询、已读上报参数）、
`test/features/chat_menu_test.dart`（跑整个 App：菜单五项、撤回→变提示→重新编辑、复制到剪贴板、删除确认两次、转发选人、别人的消息/管理员两种菜单、时间窗过期、存表情、群里引用自动 @、@ 我面板清角标）。
S4.6 新增 21 个（共 361 个）：`test/chat/file_preview_test.dart`（后缀白名单、音频后缀、三种平台的地图链接与转义）、
`test/core/media_saver_test.dart`（`file://` 归一化、本机文件不走网络），
`test/features/chat_preview_test.dart`（跑整个 App：点图进预览并保存当前那张、点视频进播放页且插件不可用时不白屏、
点 pdf 弹层两项分别下载打开/交给浏览器、txt 只提示不支持、音频只有一个入口、下载失败提示、点位置带坐标唤起地图、没坐标只提示）。

**S4.1 与老端不同的地方（刻意的）**

1. **服务端返回空列表时不清本地会话**。老端是 `initContacts` 整份替换；新端本地是唯一真相，
   一次空响应（token 过期、网关抽风）就会把用户整个聊天列表抹掉——所以只在非空时做删除差集。
   这个行为是被组件测试当场抓出来的（列表渲染为空），已用单测固定。
2. **置顶 / 免打扰 / 删除改成“本地先改、接口后台同步”**，老端是等接口成功才改本地（弱网下点了没反应）。
   接口参数照抄老端：`setChatTop{id,is_top,is_group}`、`isNotice{id,is_notice,is_group}`、`delChat{id,is_group}`。
3. **未读角标挂到底部 tab 上**（老端只在消息页内部画），这样停在通讯录页也能看到红点。
4. **筛选页签的计数用全量汇总**（含本地未读），与老端的 `unread`/`msgAt` 语义一致。
5. **列表预览用纯文本**（表情 token 去掉），老端是 `mp-html` 渲染出小图——列表里为几个像素引 HTML 渲染不划算，
   聊天页里表情会正常显示成图片。

**S4.2 与老端不同的地方（刻意的）**

1. **进聊天页不打接口**：老端 `z-paging` 一进页面就 `load` 第一页，所以每次进聊天都得等网络；
   新端先出本地缓存（秒开、离线可看），只有本地一条都没有时才拉第一页。
2. **上拉加载先吃本地**：「加载更多」= 先把本地查询窗口放大一页（20 条），本地真的吃光了才去服务端翻页，
   游标仍是老端那套 `{is_group, toContactId, last_id, page, limit}`（`last_id` = 当前手里最旧那条的 `msg_id`）。
3. **时间分隔规则的合并**：老端把「3 分钟插一条」写在两个地方（`queryList` 的末页分支 + `appendTime` 的新消息分支），
   新端合成 `buildChatItems` 一个纯函数（含“历史拉到底时最旧那条上方补一条”）。
4. **顶端时间条的时机**：只有确认“这就是会话开头”（服务端返回过一页不满的）才在最早那条上方画时间条——
   本地缓存还有更早的消息时画它是撒谎。
5. **背景图只认网络地址**：老端 `chat-bg-info<id>` 里存的是 `uni.chooseImage` 的本地临时路径，换设备就是死链；
   键名与 `filter`（模糊）语义照抄，非 URL 一律当没背景。
6. **正在看时收到新消息**：老端只上报接口、本地未读一直挂着；新端顺手把本地未读清掉。
7. **`is_group == 2` 的系统会话**不给输入框与「更多」按钮（老端 `v-if="is_group!=2"` 两处，照抄）。

**S4.2 遗留 TODO**

1. ~~输入区还是占位~~ → **S4.4a/b/c 已完成**：文本、表情、图片/视频/文件、录音、@ 都有入口。
2. ~~消息气泡只渲染文本~~ → **S4.3 已完成**：九种类型都有各自的渲染（见下）。
3. **撤回消息重编辑入口**没做（S4.5）：老端那套 `common.reedit` 的时间判断依赖毫秒/秒混算（M3 已记），
   现在撤回只渲染成一条居中灰条。
4. **未上虚拟列表**（与 S4.1 同一条）：真实长列表的表现等真机验证。

**S4.2 挖出来的问题**

1. **进页那一瞬间会把缓存里的老消息当成“新消息”上报已读**：`_reportedServerId` 是异步算出来的，
   而消息流的第一帧可能更早就到了。改成“进页流程走完才处理新消息”（`_entryReady`），并写了用例固定
   （「进页面清未读，但不给服务端发已读」）。
2. **并发上滑会把窗口一次放大好几页**：本地那段流程没被 `_loading` 覆盖，连续触发会各放大一次。
   改成整个加载流程都算“加载中”。
3. **测试环境里的 reverse 列表方向**：`ListView(reverse: true)` 的 `axisDirection` 是 `AxisDirection.up`，
   手指**往下**拖才是往上看更早的消息；另外拖到头才触发加载，测试里得一直拖到目标出现
   （用 `scrollUntilVisible`，别写死拖几次）。

**S4.3 与老端不同的地方（刻意的）**

1. **消息类型的字段口径写进了文档**：`docs/protocol/message-types.md`（服务端没有 schema，
   九种类型的 `extends` 字段全是从老端渲染代码里读出来的）。
2. **文件消息的图标不依赖 `extUrl`**：老端 `im-file.vue` 读 `item.extUrl`，
   而这个字段在整个老项目里**只被读、从来没被写过**——所以老端上文件图标一直是裂图。
   新端按后缀画彩色小方块（PDF/DOCX/ZIP…）。
3. **图片宽度统一夹了一个上限**（屏宽减两侧头像与留白）。老端只有 `fixMode == 3` 这条分支不夹，
   遇到宽图会把整行挤歪。
4. **视频封面的尺寸单独算**：老端把 `extends` 整份丢给 `im-image`，于是封面的显示尺寸跟着图片的 `fixMode` 走；
   新端对封面只用 `imageCoverStyle` 那套规则（没有尺寸时给 16:9）。
5. **未知类型的底色跟随“是不是自己发的”**：老端那个卡片是白底不透明，自己的消息在上面显示成黑字，
   看起来不像自己发的。
6. **语音高亮按地址判断**：老端用全局下标 `playIndex`，翻页/插入消息后下标会变，
   高亮会跑到别的语音上。
7. **`videoFormatTime` 不再走 `date()`**：老端是把“时长”当时间戳格式化，UTC+8 下 1 小时 2 分
   的视频会显示成 `09:02:05`；新端直接算时长。

**S4.3 挖出来的问题（老端遗留）**

1. **`im-file.vue` 的 `extUrl` 从未被写入**（同上，文件图标一直是裂图）。
2. **`im-image.vue` 的第四个分支是死代码**：条件要求 `src` 为空，却又拿空 `src` 去渲染图片。
   新端按“作者本意”把它实现成“有原始宽高就按比例算”。
3. **`imageCoverStyle` 自带死代码**：第一个 `if` 必然被第二个覆盖；
   `width`/`height` 为 0 时会算出 `Infinity` / `NaN`。
4. **`fixMode == 3` 老端从未产出过**（本地发图只写 1 或 2），是服务端/将来才可能给的。

**S4.3 遗留 TODO**

1. ~~点图片/视频/文件/位置/名片的动作只接到图片~~ → **S4.6 + S4.6b 已补齐**：视频播放页、文件两项弹层、
   位置唤起地图、名片进资料页都接了；发名片的入口（＋面板 → 选好友）也在 S4.6b 做了。
2. **图片没做本地缓存与尺寸兜底**：加载中是一个灰块，失败是一个占位图标；
   磁盘缓存（`cached_network_image` 之类）等真机看效果后再定。
3. **真实报文还没对过**：上面那些字段是从老端代码读出来的，等 S6.0 用真机抓一轮报文校准。

**S4.4a 与老端不同的地方（刻意的）**

1. **先落库再发**。老端把消息只放在内存里（`messageList`），退出聊天页那条失败的记录就没了；
   新端落库，失败的行会一直留着并可以重新发送。发送状态存入 `status` 列（`going/sent/failed`）。
2. **回执按“叠加”处理，不整行覆盖**。老端是 `Object.assign(msg, res.data)`；新端等价实现
   （`Message.overlayWith`），只采用服务端真的给了的字段——回执是个 `{}` 时不会把本地这条清空。
3. **回显认领**：服务端把我们自己发的消息推回来时，按 `id`→`msg_id`→本机 `clientId`→
   「同会话 + 同内容 + 时间接近」四层依次匹配，不会出现两条一样的。
4. **文本发纯文本**（表情用 `[!code]` token），不发富文本 HTML。
5. **输入框上限 300 字照抄**；但没有老端编辑器那些排版按钮（加粗/颜色），它就一个输入框。
6. **草稿写在会话行的 `draft` 列**（老端是 `draft_<id>` 这个独立 storage key），
   换设备/重启都在，也与会话列表的草稿标记同源。
7. **长按菜单暂时只有「引用」**（引用功能需要入口），其余项（复制/转发/撤回/删除/上下文）在 S4.5 补齐。
8. **表情面板高度自适应**：老端写死 300px，横屏/小屏会把输入区挤出去；新端按 rpx 算并扣一道
   “不超过屏幕高度 40%”的上限。

**S4.4a 挖出来的问题**

1. **服务端回执可能是空的**（`data: {}` 或 `data: null`），老端因为 `Object.assign` 侥幸没事；
   新端一开始是整行覆盖，结果把刚发出去的消息清成了空消息——**这个是单测当场抓出来的**，
   现在整条链路都改成叠加（`overlayWith` + `providedKeys`）。
2. **推送也可能只有一部分字段**（比如只带 `id` 与 `is_read`），同样被上面的叠加逻辑兼容了。
3. **老端 `nospeak()` 名字是反的**：返回 `true` 其实是“可以发言”，且只在 `nospeak>0` 时判角色，
   新端改名为 [`canSpeak`](`lib/domain/chat/outgoing_message.dart`) 并照抄判断。
4. **老端的 uuid 生成器不受控**：`getUuid(str)` 传了参数会返回一个**固定的魔法字符串**，
   同一条消息重发时 id 不变（服务端会当成同一条）。新端没有保留这个行为。

**S4.4a 遗留 TODO**

1. ~~图片/视频/文件与录音~~ → 图片/视频/文件 **S4.4b 已完成**；录音仍在 S4.4c。
   ~~名片移交给 M5~~ → **S4.6b 已完成**（入口是好友列表选择器，用的是本地通讯录那份好友列表）。
   **位置消息老端自己也没入口**（`im-input.vue` 里注释掉了），但渲染层要支持（S4.3 已做）。
2. ~~@成员需要群成员列表~~ → **S4.4c 已完成**（成员列表按需请求 `groupUserList`，没等 M5）。
3. **`cid`** 仍未实现（M2 就记过：老端从来没写过这个字段），等 M8 做离线推送时一并定。

**S4.4b 与老端不同的地方（刻意的）**

1. **视频的时长/宽高先不自己算**。老端在客户端算出 `fixMode/width/height/duration` 再发；
   新端选完视频时只带文件名与大小，等上传回执由服务端补（图片的 `fixMode/width/height`
   本来就是服务端算的）。理由：读视频元数据要再加一个解码依赖，而服务端本来就要重新编码，
   客户端算的值只能当参考。**代价：离线/上传失败时气泡上的时长会显示 0**（`test/features/`
   里那条用例是拿手工构造的 `PickedMedia` 断言的，真机路径还没验）。
2. **选媒体的入口抽成了 `MediaPicker` 接口**：真机弹系统选择器，组件测试里没法点，
   所以给它一个替身口子（与语音播放器同一个做法）。
3. **「＋」面板里没有通话两项**（老端 `v-if` 要求服务端开了 webrtc 且是单聊）、也没有位置项
   （老端注释掉了）——通话入口是 M6。

**S4.6 与老端不同的地方（刻意的）**

1. **保存到相册是显式按钮**：老端靠 `uni.previewImage` 自带的长按菜单，Flutter 没这个等价物，
   所以预览页右下角放一个「保存到本地」（视频播放页也是两个按钮，与老端 `video.vue` 一致）。
2. **「在线预览」用消息里的真实地址**。老端这一项打开的是 `item.preview`，而这个字段
   **全项目只被读、从来没被赋值**（服务端也不返回），所以线上它打开的是 `undefined` ——
   也就是一个空白 webview。新端用 `content`（真实文件地址）交给系统浏览器，功能才真的能用。
3. **音频文件合并成一个入口**：老端把 mp3/wav/acc 也丢给那个坏掉的 webview；
   新端对音频只显示「在线预览」（同样是交给浏览器），不给「本地预览」这个必然失败的选项。
4. **播放页自己画控件**（点画面暂停/继续 + 可拖动进度条）：`video_player` 不带控件，
   而老端的 `<video controls>` 自带一套。控件很少，不做「全屏/倍速/画中画」这类附加体验。
5. **位置没坐标时明说一句**：老端会把 `undefined` 递给 `uni.openLocation`（点了没反应也不吭声），
   新端提示「暂无数据」。
6. **地图链接按平台拼**：`uni.openLocation` 在 Flutter 里没有等价 API，
   Android 用 `geo:` 意图、iOS 用 `maps.apple.com`、其它平台兜到 Google 地图。

**S4.6 挖出来的问题**

1. **`VideoPlayerController.dispose()` 在初始化失败时会永远不返回**：播放器 `create()` 抛错后
   内部那个 `Completer` 不会被完成，`await dispose()` 就挂在那里——我在 `catch` 里写了
   `await controller?.dispose()`，结果是**错误处理代码自己卡死**，整页停在转圈上（用户看到的就是
   “点开视频一片黑加一个不动的圈”）。组件测试当场抓到（只找到「关闭视频」「保存到本地」两个按钮，
   错误文案永远不出现）。现在改成：先把错误画出来，再 `unawaited` 收拾播放器。
2. **底部弹层默认只能用屏幕的 9/16**（`scrollControlDisabledMaxHeightRatio`）：
   文件那两项 + 标题 + 取消在 800×600 的测试视口里溢出 137px（真机小屏/横屏同样会）。
   加了 `isScrollControlled: true` + 滚动容器。
3. **`Uri.toFilePath()` 的默认行为跟着运行机器走**：Windows 上跑单测时
   `file:///storage/a.jpg` 会变成 `\storage\a.jpg`，手机上是 `/storage/a.jpg`。
   已统一用 `localFilePathOf`（`windows: false`），`MediaImage` 也改成共用它。

**S4.6 遗留 TODO**

1. **真机必验三件事**：视频能播（`video_player` 是平台插件）、保存到相册的权限弹窗、
   文件的系统应用打开（安卓没有能打开该类型的 App 时会提示「该文件不支持预览」）。
2. **图片预览保存的是“当前那张”**，多选保存（老端也没有）没做。
3. **视频没做“本地缓存后再播”**：直接走播放器的网络播放，弱网下起播慢；
   老端也只是 `<video :src>` 直连。
4. **位置只做“打开地图”，没做“发位置”入口**（老端把 `＋` 面板里的位置项注释掉了，照抄）。

**S4.6b 交付物（名片收尾）**

1. **发名片**：聊天输入区「＋」面板多一项「名片」（老端 `cuIcon-addressbook`）→ 弹层
   「选择要分享的人」（`message.shareTo`）→ 好友列表（名字 / 拼音搜索，单选）→「完成」。
   请求体逐字照老端：`type` 是 `contact`、`content` 是 `[个人名片] 小红`、
   `extends` 是 `{avatar, displayName, id}`（`lib/domain/chat/contact_card.dart` +
   `MessageSender.sendContactCard`）。
2. **点名片**：聊天页与「聊天记录」页点名片都进对方资料页（老端 `openContact` →
   `/pages/contacts/detail?id=<extends.id>`）；名片没带 `id` 时原地不动。
3. **选人弹层**：`lib/features/chat/widgets/contact_card_picker.dart`。

测试（新增 14 个，总 627 个）：`test/chat/contact_card_test.dart`（7：三个字段、`extends` 形状、
`content` 文案、只有 `realname` 的老报文、空 `id`）、`test/repo/message_sender_test.dart`（2：请求体与失败标红）、
`test/features/chat_send_test.dart`（3：选好友 → 请求体、没选就提示且弹层不关、收到的名片气泡）、
`test/features/{chat_preview,search_pages}_test.dart`（2：点名片进资料页且 `user_id` 正确；没 `id` 不跳）。

**S4.6b 与老端不同的地方（刻意的）**

1. **选人是单选**：老端那个 `user-select` 仍带多选框，选完再校验「必须选一位」；
   新端点一下即选中，只有「没选就点完成」才提示同一句话。
2. **候选只列好友**（本地通讯录那份 `getFriendList`）：老端那选择器的 `type=1` 也只有好友，
   但它把「当前聊天对象」也列进去了——新端照旧不排除（把名片发给自己正在聊的人也合理）。
3. **没带 `id` 的名片不跳页**：老端会把 `undefined` 拼进 URL，跳出一个空白资料页。

**S4.6b 挖出来的问题**

1. **名片不是引用消息**：`extends` 被用来装名片本体，而引用块（`buildQuote`）也放在 `extends` 里，
   两者互斥——所以发名片时不能带 `pid`（测试里钉了「请求体没有 `pid`」）。
2. **「发送名片」在老端还是走 `$emit('send', message, file)` 那条路**：第二个参数只对媒体有意义，
   识别靠 `message.type`（与 S4.4c 记的语音同一回事）。
3. **好友列表来自本地通讯录**：老端那个选择器读的是 `msgStore.contacts`（storage 里的整份缓存），
   新端订阅本地库的同一条流，好处是没网也能选人。

**S4.6b 遗留 TODO**

1. **真机要确认**：从老端收一张名片在这里能不能点（现在认 `extends.id`，兼容了它只有 `realname` 的写法）、
   以及我们发出去的名片在老端显示成什么样（服务端会不会保留 `extends` 三个键）。

**S4.5 与老端不同的地方（刻意的）**

1. **长按菜单用底部弹层**（图标 + 文字一行），不是老端那种“在长按位置弹一个带小尾巴的浮层”
   （它靠 JS 算 `popStyle` / `tailStyle`，还得处理边界）。手机上一行图标的弹层更好点。
2. **不做「双击气泡弹消息详情」**（老端的 `copymodel`）：Flutter 里注册 `onDoubleTap` 会让
   同级的单击（点图看大图、点语音播放、点文件打开）多出～300ms 延迟。这个代价不值得，
   要看全文就长按 → 复制。**这个是写完之后被三个已有的组件测试当场抓出来的**。
3. **「查看上下文」不用服务端接口**：老端在 @ 我面板里逐条调 `getMessageContext` 拉前后文，
   新端本地就是全部历史，面板直接列本地库里的消息（离线也能看）。
   **代价**：没做“跳到那条消息”的定位（在反向列表里精确滚动到任意一条需要先把历史载到那里），
   等 S4.6 之后真机上看看需不需要。
4. **撤回后的「重新编辑」多一道校验**：老端只看时间窗（别人撤回的消息也能点出别人的原文），
   新端要求“必须是自己撤的 + 文字消息”。
5. **转发候选从接口现拉**（好友 `getFriendList` + 群聊 `getGroupList`，老端缓存在 storage 里），
   当前会话排除。限 5 个照抄（`message.forwardLimit`）。
6. **单聊里不给「撤回别人的消息」这个入口**：老端的条件是 `role < 3`，而单聊的 `role` 恒为 0，
   所以它实际上允许“单聊里撤回对方的消息”（服务端会拒，但按钮先出来了）。

**S4.5 挖出来的问题**

1. **进聊天页会误清「有人 @ 我」的角标**（真的会丢提醒）：会话行的未读与 @ 提醒是两件事
   ——老端进聊天页只把未读归零，@ 角标要等你点开 @ 面板才清；而新端 `clearUnread` 把
   `unread` 与 `is_at` 一起清了。已拆开（`clearUnread` 只清 unread，`clearAt` 清 is_at + 调 `readAtMsg`），
   两处断言都跟上了。**这个是被「N 人提到我」那条用例当场抓出来的**。
2. **`common.confirm` 在老端语言包里不是「确定」而是「吗？」**（它是拼句子的片段：
   「确定要删除该会话」+ `common.confirm`）。删除会话那个确认框的按钮一直是「吗？」。
   新的消息删除框用的是正确的 `common.ok`（「确定」），顺手把旧的也修了。
3. **老端长按菜单里的「删除」条件是 `dbDelMsg && fromUser.id == 自己`**，
   所以群里管理员也删不了别人的消息（但能撤回）——新端照抄。
4. **老端的老 `getFriendList` / `getGroupList` 是数组**（`res.data.filter/forEach`），
   M1 当时按对象接收了（没调用点，一直没暴露），这次改成 `postListMaps`。

**S4.5 遗留 TODO**

1. **撤回后的“重编辑”只认文字**（老端对图片/文件也把 content 填回去，那是一段网址）。
2. **@ 我面板不能跳到那条消息**（见上面的第 3 条）。
3. **转发后的成功反馈没做**：老端转发完直接返回上一页，什么都不提示；新端只把失败记日志。
4. **消息“已读回执”列表没做**：老端也没有（它只是上报）。

**S4.4c 与老端不同的地方（刻意的）**

1. **录的是 AAC（`.m4a`），不是 mp3**。老端 H5 靠 lamejs、APP 靠系统编码器录 mp3；
   `record` 这个包**没有 mp3 编码器**，所以选 `AudioEncoder.aacLc`（16kHz 单声道 64kbps，
   60 秒约 480KB）。安卓/iOS/浏览器都能放，对方收到的还是同一个 URL。
   **如果服务端按扩展名卡白名单，就要换方案**（真机验证时特别看一下这一条）。
2. **录音状态条放在输入行上方**，不是老端那种绝对定位浮层：避免被外层裁剪，
   也省掉一层 `Overlay`。按住时的文案（按住说话/松开结束/松开取消/正在录音）与秒数一致。
3. **上滑取消的阀值照抄老端**（“指尖离开屏幕底部 80px”——也就是从说话按钮往上滑
   两三十像素就进入取消区）。这个阀值看着奇怪，但老朋友的手感是按这个长的。
4. **取消时静默**（老端也是只打一条 console 日志，不弹提示）；太短才提示 `录音时间太短`。
5. **@ 是纯文本 token**（`@名字`）而不是富文本 link 节点。发送时只把“文本里还留着这个
   @”的人算进 `at`，与老端 `edit.getLink()` 完全同一个语义（单测固定）。
6. **@ 按钮只在群聊且输入框聚焦时出现**（老端 `v-show="isFocus && is_group==1"`）；
   点表情/「+」会先退出录音模式（老端不退出，但那样表情只能插进看不见的输入框）。

**S4.4c 挖出来的问题**

1. **语音在老端也是走表单直传的**：`chat.vue` 里 `fileTypes` 包含 `voice`，
   而 `im-input.vue` 发语音时 `$emit('send', message)` **只传了一个参数**——
   第二个参数 `file` 从来没人用（真正的分支条件是 `message.type`）。
   新端按 `type` 判断，并且把 `localPath` 存在 `extra` 里（重发要重新上传同一份文件）。
2. **老端语音消息根本不给 `fileSize`**（发送前的大小校验判的是 `undefined > 10MB`，永远过）。
   新端如实填上大小，走同一道校验——实测 60 秒 AAC 只有几百 KB，不会拦住。
3. **老端录音有个 1 秒判定的笔误**：`onStop` 里写的是 `if(this.recLengt<1)`（少一个 h，
   永远是 `undefined < 1` → false），所以它总是走“发送”分支；真正拦住太短录音的是
   后面 `checkRecorder()` 里的判定。新端直接把判定放在录完之后。
4. **群成员接口返回的是数组**（`user-select.vue` 直接 `res.data.filter`），
   而 `GroupApi.userList` 是按对象解析的——用它拿成员会静默得到空表（M3 记过同类坑），
   已新增 `userListMaps`。
5. **老端 @ 所有人不需要权限校验以外的交互**：`user_id` 写死 0，且只有群主/管理员能看到入口。

**S4.4c 遗留 TODO**

1. **真机麦克风权限与录音产物的兼容性必验**：装上后按住说一句话发给老端，
   确认老端能播（这条是本次最需要真人验收的点，因为真机权限+编码器我无法在无设备环境验证）。
2. **没有录音波形/剩余秒进度条**（老端也没有，只有秒数）。
3. **@ 选择器每次打开都重新请求成员列表**（老端也是），没做本地缓存；群成员多时会有一次网络等待。
4. **引用别人消息时没有自动 @ 对方**：老端 `quoteMessage()` 在群里会自动把被引的人加进 @ 列表，
   新端现在只把引用块拼上（`at` 为空），下一轮接 S4.5 长按菜单时一并补。

**S4.4b 遗留 TODO**

1. **真机权限还没验**：相册/文件/视频三个入口我不可能在无真机环境验证；
   代码里权限失败会走到发送失败（气泡红叹号）并打日志。**需要在真机上过一遍**：
   选图、选文件、发视频各一次，确认老端能收到。
2. **上传进度条没做**：老端 `uni.uploadFile` 有 `onProgressUpdate` 但界面也没用，
   所以两边一样只有转圈。大文件时体感会差，等真机试完再决定要不要补。
3. **断点续传/压缩**：老端不做，新端也没做（图片不压缩，按原图上传）。

**S4.1 遗留 TODO**

1. **系统通知条**（`getAdminNotice` + `notice_<create_time>` 本地缓存 + 点击进 `admin_notice` 会话）没做：
   它只在“已开启通知且没被系统限制后台”时才显示，而这两个开关属于推送/保活（M8），现在做等于做半截。
2. **虚拟列表**：老端用 `z-paging` 的虚拟列表；新端目前是 `ListView.builder`（同样只建可见项），
   长列表下的差异等真机验证后再决定要不要上 `ListView.custom` + 高度估计。
3. **草稿**：数据库列与 `saveDraft/draftOf` 已就绪并有测试，但保存草稿的入口在聊天页（S4.4）。

**本轮挖出的问题（老端遗留 / 基础设施）**

1. **`GoRouter` 全局单例会在测试之间串位置**：一个用例 push 了聊天页，下一个用例启动时还停在聊天页。
   已改成 `appRouterProvider`（每个作用域一份），路由本身也顺手获得正确的 `dispose`。
2. **drift 在关闭查询流时会留一个零延迟定时器**，组件测试里框架会报“Timer 未结束”并连带把后续用例挂住；
   测试里用“卸载整棵树 + 推 1ms”收尾。真实运行不受影响。
3. **组件测试里真文件 I/O 永远不会完成**（这是 S4.4b 踩到的）：`MultipartFile.fromFile` 要读盘，
   而组件测试跑在假时区里，真 I/O 的续点不会被投递——实测 `pump` + `runAsync` 来回 10 轮也没用。
   → 上传链路的断言一律放在普通（非 `testWidgets`）测试里用假 adapter 做；
   组件测试只断言到“乐观落库 + 界面反应”，不碰网络。**别再为这个浪费一轮调试。**
4. **Flutter 弹层的默认高度只有屏幕的 9/16**（`isScrollControlled: false` 时）——
   三行以上的内容在小屏/横屏/测试视口里会直接溢出报错。要自己定高度就 `isScrollControlled: true`。
5. **测试机上跑 `flutter test` 报 `sqlite3.dll` 拒绝访问**：是上一次崩掉的 `flutter_tester.exe`
   还挂着这个 DLL。`taskkill /F /IM flutter_tester.exe` 一下就能继续（不影响代码）。

### M5 进度（已完成）

| 步骤 | 状态 | 产出 |
| --- | --- | --- |
| S5.1 ✅ | 通讯录主页 + 群聊列表 + 新朋友 | `lib/features/contacts/`、`lib/data/repo/{contact,friend_apply}_repository.dart`、`lib/domain/contacts/`、`DbContacts` 表 |
| S5.2 ✅ | 用户详情：资料 / 备注 / 发消息 / 打电话 / 音视频入口 / 加·删好友 | `lib/features/contacts/user_detail_page.dart`、`lib/data/model/user_detail.dart` |
| S5.3 ✅ | 群信息 + 群成员管理：改群名/公告/群设置、加人、禁言、管理员、踢人、清空、退群/解散 | `lib/features/chat/{chat_info_page,group_members_page,group_member_picker_page}.dart`、`lib/domain/chat/group_admin.dart`、`lib/data/repo/group_admin_repository.dart` |
| S5.4 ✅ | 搜索三件套：搜人（服务端）/ 好友·群本地搜索 / 会话内聊天记录 | `lib/features/contacts/user_search_page.dart`、`lib/features/search/search_page.dart`、`lib/features/chat/chat_record_page.dart`、`lib/data/repo/search_repository.dart`、`lib/domain/search/`、`lib/domain/chat/message_record.dart` |
| S5.5 ✅ | 我的：资料与头像上传 / 安全 / 设置 / 关于 / 帮助中心 | `lib/features/mine/`、`lib/domain/mine/profile_form.dart`、`lib/data/repo/profile_repository.dart` |

**M5 已完成**（S5.1–S5.5，总 613 个测试全过；下一步是 **M6 通话原生重写**，见下方 M6 小节）。

**S5.1 交付物**

1. **通讯录落库**：`DbContacts` 表（好友 / 群聊 / 系统通知三类同居，用 `is_group` 区分）+ `contact_dao`（整表对齐、WS 增量改单行）
   + `contact_repository`（两个接口分开 try/catch、空响应保留本地、登出清库）。
   → 老端把两份整份 JSON 塞在 storage 里、任何变化都重拉，新端订阅本地流，进页面秒开、离线可看。
2. **通讯录主页**（`contacts_page.dart`）：好友按拼音首字母分组 + 右侧字母索引条（点/滑都能跳，中间弹大字母）、
   顶部「新邀请 / 群聊 / 系统通知」三个入口、底部「N 个朋友」、下拉刷新。
3. **群聊列表**（`group_list_page.dart`）：四个分段（全部 / 我创建的 / 我管理的 / 我加入的）+ 搜索 + 点一行**直接进群聊**；
   我是群主的那行画群主图标（老端 `cuIcon-peoplefill`）。
4. **新朋友**（`new_friends_page.dart`）：我收到的 / 我发起的两个分段、分页（一页 10 条，底部翻页条）、
   按 `status` 显示已拒绝 / 发消息 / 操作（弹窗里接受或拒绝）/ 待同意；接受或拒绝后刷新通讯录红点。
5. **起会话的工具**：`ConversationRepository.ensureFromContact`——从通讯录进一个**没聊过**的群或人时先补一条本地会话，
   否则聊天页会说「联系人不存在」（老端是 `appendContacts` 之后再 `navigateTo`）。

测试（S5.1 合计新增 85 个，总 446 个；其中 77 个在下面这几个文件里，另 8 个在 `test/ws/ws_test.dart`
与 `test/db/conversation_dao_test.dart` 的通讯录增量用例）：
`test/contacts/{contact_index,friend_apply,group_list}_test.dart`（分组 / 申请解析 / 分段筛选 / 稳定排序）、
`test/db/contact_dao_test.dart`、`test/repo/{contact_repository,friend_apply_repository}_test.dart`（接口参数与「空响应不清库」）、
`test/features/{contacts_page,group_list_page,new_friends_page}_test.dart`（跑整个 App：索引跳转、分段、群主图标、进群聊、搜索、同意/拒绝、四种状态分支、翻页、空态）。

**S5.1 与老端不同的地方（刻意的）**

1. **「新邀请」的红点口径**：老端挂的是**系统消息未读数**（`getChatList().count` 塞进 `sysUnread`），
   跟「有几个好友申请」不是一回事；新端直接数申请列表里 `status == 2` 的条数。
2. **失败/空态**：老端接口挂了列表就无声无息地空着；新端统一给空态视图 + 下拉刷新（重试不用刷新整页）。
3. **搜索口径**：群聊列表搜索复用通讯录那一套（名字 / 拼音 / 账号，老端用同一个 `$util.searchObject`，但只匹配三列）。

**S5.1 踩坑（都值得记住）**

1. **`ListView`（懒加载）+ `Scrollable.ensureVisible` 会静默失效**：点索引条上一个还没滚到的字母，
   那组表头的 `GlobalKey.currentContext` 是 `null`，跳转什么都不做——而且**不报错**，只有测试能发现。
   → 通讯录改成 `SingleChildScrollView + Column` 全量渲染（老端 `scroll-view` 也是全量），
   并有用例钉住「点 Z 滚到 Z 组」。以后如果要换回虚拟列表，得换成能按 index 定位的列表（`scrollable_positioned_list` 那类），
   不能再用 `ensureVisible`。
2. **同字母的排序不能依赖 `List.sort`**：Dart 的 `sort` 不保证稳定，而老端那个「同 `index` 返回 0」的比较器依赖 JS 的稳定排序。
   → `sortGroups` 用原始下标兜底（用例固定）。
3. **接口失败时不要 `_total = 0` 之外还留着半截列表**：先清空再进错误分支，否则用户以为接口成功了。
4. **同意/拒绝要读服务端回执的 `msg`**（老端弹的就是它）：`ApiClient.postVoid` 会把 `msg` 丢掉，
   所以 `FriendApi.acceptApply` 走 `send` 手动取信封——它因此**不带自动提示**，失败提示由页面自己弹。
5. **老端关掉搜索框会把分段归回「全部」**（`watch.keywords('')` 里 `this.type='all'`），照抄了，否则用户关掉搜索会看到空列表。

**S5.1 遗留 TODO**

1. **真机上要确认三件事**：① 好友/群列表接口有没有 `index` / `name_py` 两列——没有的话中文名会全落 `#` 组，
   得引一个本地拼音库；② 申请列表的嵌套字段名与 `friend_id`（新端在两处都做了兜底，但兜底值对不对只能真机看）；
   ③ 同意之后服务端回的 `msg` 是什么（现在的提示文案直接来自它）。
2. **首屏会打两次 `/enterprise/friend/index`**（红点一次、新朋友页一次），老端也是各打各的，先不合并。
3. **群信息 / 群二维码的入口**不在群聊列表页：老端点群行也是直接进聊天，群信息入口在聊天页顶部（S5.3 接）。
4. **通讯录的虚拟列表**：现在是全量渲染，好友到几百个时再评估要不要换成能按 index 定位的虚拟列表（见上面第 1 条）。
5. ~~「名片」的发送入口~~ → **S4.6b 已补齐**（M4 移交过来的那一条）。

**S5.2 交付物**

1. **用户详情页**（`user_detail_page.dart`）：头像（点开可存）、真名、账号、备注 / 邮箱 / 性别 / IP 四行；
   底下按配置给按钮——发消息 / 打电话 / 音视频通话 / 删除好友（已加好友时），或「添加朋友」（还没加时）。
2. **备注**：点备注行弹输入框 → `setNickname({friend_id, nickname})` → **本地通讯录的显示名跟着改**（真的落库）。
3. **发消息**：先按 `contactInfo` 补一条本地会话（没有 `contactInfo` 就用详情字段兜底），再进聊天页。
4. **打电话**：账号能通过老端那个手机号正则才出现按钮，点了用 `tel:` 唤起拨号盘（对应老端 `uni.makePhoneCall`）。
5. **删除好友**：底部弹层（勾「加入黑名单」）→ `delFriend({id, is_black})` → 连本地联系人一起删，
   然后回上一页（老端是 `reLaunch` 回消息页）。
6. **音视频通话**：配置开了才出现，弹层选语音/视频后按老端参数拼 `/message/call?msg_id=&type=&status=1&id=&name=&avatar=` 入队。

测试（S5.2 新增 32 个，总 478 个）：`test/contacts/user_detail_test.dart`（解析 / 手机号 / 性别 / 八种按钮组合）、
`test/repo/user_detail_repository_test.dart`（`user_id`、`group_id`、`remark`、`is_black`、`friend_id`、`nickname` 六个参数与「失败不动本地」）、
`test/features/user_detail_page_test.dart`（跑整个 App：资料齐全、非手机号无拨号、加好友空验证信息被拦、发消息补会话、
改备注落库并重拉、删除好友弹层先取消再确认、音视频弹层进通话页占位、取详情失败给空态）。

**S5.2 与老端不同的地方（刻意的）**

1. **改备注真的会改本地显示名**。老端那里写的是 `msgStore.updateContacts({id: this.detaild.user_id, …})`
   ——多了一个 `d`，拿到 `undefined`，所以它的备注只改了当前详情页，回通讯录还是旧名字。
2. **删除好友后就地返回上一页**（老端 `reLaunch('/pages/index/index')` 回消息页），本地会话与聊天记录留着。
3. ~~音视频按钮只跳到 M6 的通话页占位~~：S6.3 已接成真的发起通话。
4. **取详情失败给空态**（老端是一张空白页）。

**S5.2 踩坑**

1. **`TextEditingController` 不能在 `showDialog` 返回后立刻 `dispose`**：弹窗的退场动画还在用它，
   会报 `A TextEditingController was used after being disposed`（组件测试当场抓到）。
   → 输入框弹窗做成 `StatefulWidget`，controller 由它自己的 `State` 拥有并释放。
2. **好友那几个写接口要读回执的 `msg`**：`postVoid` 会丢掉，所以 `FriendApi` 的 add/del/accept/setNickname
   统一走 `send` 取信封——代价是没有「失败自动 toast」，由页面自己弹。

**S5.2 遗留 TODO**

1. **真机上确认三件事**：① `getUserInfo` 返回里 `friend` / `contactInfo` 两个键的真实名字与内容
   （没有 `contactInfo` 时新端会用详情字段兜底建会话，但会话列表上显示的名字可能跟服务端口径不同）；
   ② `friend_id` 到底是对方 `user_id` 还是好友表主键；③ 删除好友后服务端会不会把会话也删掉。
2. **详情页的群内管理块**（改角色 / 禁言 / 移出群）没做——S5.3 里它的位置改成了「群成员页那一行的 ⋯ 菜单」（老端两处入口其实是同一套接口），详情页那格仍欠着（见 S5.3 遗留）。
3. **打电话是用 `tel:` 唤起拨号盘**，不是像老端那样直接拨号（`uni.makePhoneCall` 在安卓上其实也是拉起拨号盘）。

**S5.3 交付物**

1. **聊天信息页**（`chat_info_page.dart`，对应老端 `pages/message/detail.vue`）：单聊与群聊同一页。
   群聊有成员头像网格（有权限 18 个 / 允许邀请 19 个 / 都没有 20 个，逐条照老端）+「添加成员 / 移除成员」两个虚线格子
   +「查看全部群成员 N 人」（**N 是信封里的 `count`**，不是本页条数）+ 群名称 / 群公告 / 群管理三行；
   两聊共用免打扰 / 置顶 / 查看聊天记录；底部按身份给「清空聊天记录」（群主）与「退出群聊 / 解散群聊」。
2. **群成员管理页**（`group_members_page.dart`，老端 `groupUser.vue`）：搜索（名字 / 拼音）、角色标签（群主 / 管理员 / 我的）、
   「禁言至 m-d H:i」、有权限的人点右边「⋯」弹操作菜单（转让管理权限 / 设置·取消管理员 / 设置禁言 / 移出群聊）。
3. **禁言弹层**：4 个预设（10 分钟 / 1 小时 / 3 小时 / 1 天，`noSpeakTimer` 1..4）+ 自定义天数（`noSpeakDay`）+「取消禁言」。
4. **添加成员**（`group_member_picker_page.dart`，老端 `userSelection.vue` 的 `type == 2`）：候选 = 好友 − 已在群里的，多选后一次 `addGroupUser({id, user_ids})`。
5. **群管理开关**：老端那个「点一下改内存、点保存才提交」的底部弹层（4 个开关 + 3 选 1 的群禁言模式），照抄这个交互。
6. **本地联动**（老端只调接口，本地那份等下次整份同步）：改群名同步改通讯录与会话、退群/解散把本地会话与联系人一起删、清空记录连本地消息一起清。
7. **入口**：聊天页右上角「⋯」→ 聊天信息页（老端 `pages/message/chat.vue` 顶部那个 `more`）；成员头像点进用户详情页（先判权限）。

测试（S5.3 新增 39 个，总 517 个）：`test/chat/group_admin_test.dart`（角色 / 权限 / 能不能弹菜单 / 菜单四项的可见性 / 禁言时长与参数 / 到期文案 / `count` 口径）、
`test/repo/group_admin_repository_test.dart`（十个接口的参数与「失败不动本地」、改名后两份本地数据一起改、退群/解散删本地、清空记录连本地消息一起清）、
`test/features/chat_info_page_test.dart`（跑整个 App：从聊天页「⋯」进信息页、群主与非群主的差别、改群名、成员页的角色标签与移出、单聊页不请求群成员）以及好友选择器剔重。

**S5.3 与老端不同的地方（刻意的）**

1. **自己那一行不出操作菜单**：老端管理员点自己会看到菜单，点下去只有「移出群聊」（等于把自己踢了）；退出群聊在聊天信息页是正经入口。
2. **自定义禁言天数真的能改**：老端那个数字框只写了单向 `:value`、没有 `@change`，所以 `noSpeakDay` 永远是 1——「自定义 30 天」实际只禁言 1 天。
3. **点成员头像进详情页的权限判定反过来**：老端是 `setting.profile == '1'` 才放行（字段缺失就一律不给看），新端只有**明确是 `'0'`** 才算「已开启用户隐私」，没同步下来时不误报。
4. **`groupUserList` 里缺 `userInfo` 的项直接跳过**：老端会因为 `item.userInfo.displayName` 抛异常，整张成员列表都出不来。
5. **退群 / 解散之后回消息 tab 并删掉本地会话**：老端是 `reLaunch` 回首页但本地那份关系还在，列表上会留一条点进去报「联系人不存在」的死行。

**S5.3 遗留 TODO**

1. **群二维码 / 聊天背景 / 单聊页那个「发起群聊」（把当前会话的人拉进新群）延后到 S5.3b**：三者都与群管理无关，二维码还要引一个二维码库。（群二维码与「发起群聊」已在 S7.1 / S5.6b 补上，聊天背景仍未做。）
2. **用户详情页的「群内管理」块**（从群成员点进去时改角色 / 禁言 / 移出群）没做——现在这些操作都在群成员页那一行的菜单里，功能不缺，只是少一个入口。
3. **群公告的只读态**：非管理员点公告行会弹出只读输入框（老端是弹只读弹层），保存按钮还在（点了不发请求），后续可以改成纯展示。
4. **真机要确认三件事**：① `groupUserList` 的 `count` 是不是总人数（现在按「0 就用本页条数」兜底）；② `setting` 那几个键的真实值形态（`'0'` / `'1'` 字符串还是布尔）；③ 退群之后服务端会不会把会话也删掉（现在本地主动删）。

**S5.4 交付物**

1. **搜人页**（`user_search_page.dart`，对应老端 `pages/contacts/search.vue`）：查服务端 `searchUser({keywords})`，
   结果行右侧按 `friend` 给「发消息」或「查看」；点行进用户详情页；「发消息」在本地没会话时先
   `getUserInfo({user_id})` 拿 `contactInfo` 补一条再进聊天（与老端 `sendMsg` 一致）。
   入口是消息页「＋」菜单里的「添加朋友」（老端 `pages/index/index.vue` 的 `add-modal`）。
2. **本地搜索页**（`search_page.dart`，对应 `pages/index/search.vue`）：三个入口共用一页（消息页 `type=1`、
   通讯录 `type=2`、群聊列表 `type=3`），输入即搜、好友与群聊分两段（`type=3` 只搜群、不画好友段）。
3. **会话内聊天记录**（`chat_record_page.dart`，对应 `pages/message/record.vue`）：五个分段（全部/文本/图片/视频/文件）、
   右上角搜索图标切搜索框、一页 10 条的分页条、搜过的结果每条带「查看上下文」（底部弹层，两头都能继续加载）。
4. **消息页「＋」菜单**（`home_shell.dart`）：更新消息 / 添加朋友 / 创建群聊 / 扫一扫，
   可见性与老端逐条一致（`sysInfo.runMode == 2` 才有加好友、`chatInfo.groupChat == 1` 才有创建群聊）。
   当时后两项只有入口（页面是占位）；**创建群聊已在 S5.6 实装、扫一扫已在 S7.1 实装**。
5. **接口层**：`searchUser` 与 `getMessageContext` 都是 `postListMaps`（`data` 是数组），
   `getMessageList` 另加一个 `postPage` 版本（聊天记录页要信封里的 `count`）。

测试（S5.4 新增 48 个，总 565 个）：`test/search/local_search_test.dart`（搜人结果解析、分段口径、匹配字段、空关键词）、
`test/chat/message_record_test.dart`（五个分段、总页数/页码夹取、前后文合并与去重）、
`test/repo/search_repository_test.dart`（搜人参数与失败给空、按 `user_id` 补会话的四种情况、
聊天记录六个参数与 `count`、前后文 `direction` 与升序、记录页不写本地库）、
`test/features/search_pages_test.dart`（跑整个 App：从「＋」进搜人页搜出来点进详情、好友行「发消息」补会话再进聊天、
空关键词提示、搜不到换空态、本地搜索两段与三条路由、记录页从聊天信息页进 + 切分段 + 翻页 + 搜索 + 前后文弹层 + 会话不存在）。

**S5.4 与老端不同的地方（刻意的）**

1. **老端没有「全局消息搜索」**：规划书原来写的「全局搜索」在实现时被证实不存在——`pages/index/search.vue`
   三个 `type` 搜的都是 `getFriendList` + `getGroupList` 两份列表，与消息无关；真正的消息搜索只有会话内那一页。
2. **`type==2` 点好友进详情页**：老端写的是 `items.is_gourp==0`（`is_group` 拼错），恒为 `undefined`，
   所以那个分支从来没生效过——新端按它的**意图**做了（与通讯录列表点一行一致）。
3. **聊天记录页标题用「聊天记录」**：老端那一页的标题写的是 `message.info`（「聊天信息」），
   与聊天信息页撞了，`pages.json` 里写的才是「聊天记录」。
4. **记录页用真气泡渲染**：老端是左对齐的简化列表；新端直接复用消息气泡（图片/视频/文件点开仍能预览）。
   当时位置/名片在记录页不响应（聊天页里是响的）——名片已在 **S4.6b** 接上（老端记录页也调 `openContact`）；
   位置仍只在聊天页响应。
5. **前后文按 `msg_id` 去重**：老端每次「加载更多」都会多画一条边界消息（`v-for` 的 key 是 index，不报错但看着像重复）。
6. **搜人/本地搜索都忽略大小写**：老端 `searchObject` 是 `indexOf`，`ALICE` 搜不到 `alice`。
7. **本地搜索失败给空态**：老端接口挂了列表也空着，新端一样（`ApiClient` 已经弹过提示）。

**S5.4 踩坑**

1. **同路径取报文要用 `lastBodyOf`**：记录页一个接口会被调很多次（切分段、翻页、搜索），
   `bodyOf` 拿的是第一次的请求体，测试里会看到倒回去的 `type=all`——两条用例都是这么写错的。
2. **输入框里的文字也会被 `find.text` 匹配到**：搜人页搜完「张三」之后 `find.text('张三')` 有两个
   （输入框一个、结果行一个），要么用 `.last`、要么改成 `findsNWidgets(2)`。
3. **`searchUser` 与 `getMessageContext` 的 `data` 都是数组**（第三、第四例）：用 `postMap` 读会静默拿到空 map。
   这类「`data` 是数组」的接口至此已有六个：`getContacts` / `getFriendList` / `getGroupList` / `groupUserList` /
   `searchUser` / `getMessageContext`——以后接新接口先看老端是不是直接 `for` / `filter` / `res.data.length`。

**S5.4 遗留 TODO**

1. **真机要确认**：① `searchUser` 返回的 `friend` 是布尔还是 0/1（新端两种都认）；
   ② `getMessageList` 带 `type=all` 时服务端认不认这个值（老端就是这么发的）；③ `getMessageContext` 的 `direction` 确认是 0/1/2。
2. **记录页没有「跳到那条消息」**：搜索命中后只能看前后文，不像聊天页那样能滚到原位（聊天页自己在维护列表）。
3. **本地搜索页没搜会话**（老端也不搜）：以后若想搜「聊天记录里的人」，那是新功能，不在 S5.4。
4. **群聊列表页自己的搜索框**没用这个 `type=3` 页（老端是两套：列表内搜索 + 跳页搜索），保留现状。

**S5.5 交付物**

1. **「我的」tab**（`mine_page.dart`）：头部是自己的资料（点进个人信息页；头像按「圆形头像」开关决定画圆还是方、右上角个人二维码留 M7）
   + 扫一扫（M7）+ 通用设置 / 账号安全 / 帮助中心 / 检查更新（显示版本号）/ 关于IM。
2. **个人信息页**（`profile_page.dart`）：头像（选图 → `uploadAvatar`（表单 `ext=png`）→ 本地头像跟着换）、
   账号只读、昵称（企业模式且不允许自定义名字时只读，标题变「姓名」）、邮箱（可空，填了得像邮箱）、
   性别（男 1 / 女 0）、个性签名、保存（`{realname,email,sex,motto}` 发出去后把四个字段合并回本地登录用户）、底部红色注销登录。
3. **通用设置页**（`setting_page.dart`）：新消息声音 / 震动 / 圆形头像三个开关（改一个整份落盘）+ 语言切换（简中 / English，选完立刻存 + 界面立刻换）。
4. **账号安全页**（`secure_page.dart`）：改账号（未认证点不进去，只提示「请先认证账户！」）、改密码（已认证要验证码、未认证要原密码）、
   发送验证码（`type`：改密码 3、改账号 4）、注销登录（红色按钮 + 确认弹窗）。
5. **关于页 / 帮助中心**（`about_page.dart` / `doc_page.dart`）：关于页的 logo 与站点名取全局配置，`Version 1.0.0` + 七条特性文案；
   帮助中心两条手风琴（第一条默认展开），内容逐条照搬老端那段富文本。
6. **纯逻辑**（`domain/mine/profile_form.dart`）：邮箱正则、`ProfileForm` / `PasswordForm` / `AccountForm` 的校验与提交字段、
   `nicknameEditable` / `nicknameLabelKey` / `sendCodeType` / `avatarUrlOf` / `mergeProfile` / `mergeAvatar`，以及关于与帮助的文案常量。
7. **仓库**（`data/repo/profile_repository.dart`）：`updateProfile` / `uploadAvatar` / `changePassword` / `changeAccount` / `sendCode`——
   **这一层不动会话状态**，改完本地用户由页面交给 `sessionStore.applyLogin`。
8. **顺手补的底层**：`ApiClient.uploadEnvelope`（上传接口的 `data` 直接是 URL，用 `dataAsMap` 会拿到空 map）、
   `UploadApi.uploadAvatar`、`AuthApi.sendCodeMessage`、`ChatApi.editPasswordMessage` / `editAccountMessage`。

测试（S5.5 新增 48 个，总 613 个）：
`test/mine/profile_form_test.dart`（21 个：三个表单的校验顺序与提交字段、昵称可编辑条件、邮件正则、账号 URL 解析与两个 merge）、
`test/repo/profile_repository_test.dart`（8 个：六个接口的参数与回执、头像上传的表单字段、失败不动本地）、
`test/features/mine_pages_test.dart`（19 个：跑整个 App——我的 tab 与认证标签、卡片进二级页、资料保存与三种校验、企业模式昵称只读、
换头像成功与失败、三个开关落盘、语言切换持久化、未认证进不去改账号、改密码的三道校验、改账号参数、发送验证码 type、两处注销登录、关于页与帮助中心）。

**S5.5 与老端不同的地方（刻意的）**

1. **头像不做裁剪**：老端那个 `yq-avatar` 会弹裁剪框并固定输出 240px 的 png；新端直接传选中的原图
   （要裁剪得引一个原生裁剪插件，先不做）。表单仍带 `ext=png`（老端就是这么发的）。
2. **保存没有 8 秒冷却**：老端用 `saveTime` 防连点（土办法），新端用保存按钮禁用代替。
3. **保存后只合并四个字段**：老端是拿页面里那份副本整个覆盖本地用户（服务端后来推的新字段会被覆盖回去）；新端走 `mergeProfile` 只改这四个。
4. **「检查更新」这一行不可点**：老端在非 APP 平台也不可点，APP 上才 `checkVersion`；整包更新是 S7.2，现在只把版本号显示出来。
5. **「关于我们」不再依赖 `demon_mode`**：老端只有演示模式才显示这一行，那是它自己的开关。
6. **改密码回执为空就不弹空提示**：老端是无脑弹 `res.msg`。

**S5.5 挖出来的问题**

1. **上传接口的 `data` 直接就是图片 URL 字符串**（老端 `this.userInfo.avatar = res.data`），不是对象。
   用 `dataAsMap` 读会拿到空 map（头像白名单一个空框）——为此单独加了 `ApiClient.uploadEnvelope`。
   `avatarUrlOf` 还对「服务端哪天换成对象」做了兜底（`url` / `avatar` / `path`）。
2. **语言在老端是整对象存的**：storage 里 `language = {key:'简体中文', value:'zh-Hans'}`（弹出层把选中项整个塞进去）；
   新端只存语言码，展示名由 `LocaleController.options` 给。
3. **改账号的入口本身有前置条件**：`is_auth` 为 0 时老端连弹层都不给开（但它那行「认证账户」点下去也是同一条路，等于点了只弹一句提示）。
4. **改密码/改账号要读回执的 `msg`**（老端弹的就是它）：与 S5.1 的好友操作同族，这几个方法都改成返回 `msg`，失败提示由页面自己弹。

**S5.5 踩坑**

1. **`testWidgets` 里做真实文件 I/O 会死锁**（S4.4b 记过的那个坑的完整版）：`Directory.systemTemp.createTemp()`、写文件、
   `MultipartFile.fromFile` 全都跑在假时钟里，续点永远不投递——现象是 `flutter test` **卡住不报错**（这次挂了 6 分钟才被掐）。
   → 头像上传的组件测试改成**替换仓库**（`profileRepositoryProvider` 注入假实现），真实表单与接口参数留给普通测试
   （`test/repo/profile_repository_test.dart` 里可以用真文件）。**别在组件测试里碰任何真实 I/O。**
2. **`pumpAndSettle` 撞上一直转的进度圈会等到超时**：「上传中」是 `CircularProgressIndicator`（无限动画），永远等不到静止。
   → 固定次数 `pump(50ms)` + 轮询断言。
3. **`ExpansionTile` 外面套 `Container(color:)` 会直接报断言**（「ListTile background color or ink splashes may be invisible」）：
   `ListTile` 的背景与水波纹画在最近的 `Material` 上，`ColoredBox` 会把它盖掉。→ 帮助中心改成 `Material(color:)`。
4. **`RadioGroup` / `Radio` 只有那个小圆点可点**：老端那一行是 `<label>` 整块可点，新端一开始点「男/女」文案没反应。
   → 文案外面加 `GestureDetector(behavior: HitTestBehavior.opaque)`（真机上小圆点太难按）。
5. **`WidgetTester.pageBack()` 找的是英文 tooltip**（`Back`），这套界面是中文，找不到返回按钮就会直接失败。
   → 用 `find.byType(BackButton)`；`test/features/contacts_page_test.dart` 里也记过同一条。
6. **注销登录那一枪要 `client_id`**：`SessionService.logout` 只在本地存过 `client_id`（WS `init` 发的）时才调登出接口，
   测试里得先 `CredentialStore.instance.saveClientId(...)`。没有也不影响清会话（这是刻意的，见 M2）。

**S5.5 遗留 TODO**

1. **真机要确认**：① 头像上传的表单字段名（现在按 `file` + `ext=png` 发，老端 uploader 的实际字段名没核对过）；
   ② `editPassword` / `editAccount` 的回执 `msg` 到底说什么；③ 相册权限被拒时的提示（现在落在通用的「无权操作」）。
2. **头像不裁剪**（见上）：上传的就是原图，想统一成 240px 方图得引插件。
3. **`mine/webview` 路由还是占位**：老端 `pages/mine/webview.vue` 是「用户协议 / 隐私政策」那类外链的容器，
   现在仍在 `_PendingRoute` 里，M7 一起做。
4. **`Version 1.0.0` 是写死的常量**（`domain/mine/profile_form.dart::appVersion`）：`pubspec.yaml` 的 version 与它一起改；
   S7.2 做「检查更新」时换成运行时读包信息。

**S5.6 交付物（用户选择器）**

1. **创建群聊页**（`user_selection_page.dart`，老端 `pages/index/userSelection.vue`）：好友多选（`is_group == 0`，群聊不进候选）、
   搜索（名字 / 拼音 / 账号，与通讯录同一套 `searchContacts`）、底部横向「已选」头像栏（点头像即取消）、右上角「完成」为空时是灰的。
   建完直接把选择页 **replace** 成新群聊天页——返回键回消息首页，而不是回到这个已经用完的选择页。
2. **老端这一页的 `type` 五种用途，新端只在这一页保留 `type == 1`**：`2` 添加群成员（`GroupMemberPickerPage`）、
   `3` 转发（`showForwardPicker` 底部弹层）、`4` 提及某人（`showMemberPicker` 底部弹层）都各自有更合适的载体，不再挤进同一页。
3. **`GroupAdminRepository.createGroup({userIds})`**：`addGroup({user_ids})` → 写通讯录（`is_group` 缺省按 1）→ 写会话 → 绑定 client。
   与老端不同（刻意的）：老端只把接口返回的那条塞进本地缓存、**等 `addGroup` 推送**再 `bindGroup`；新端不赌推送，建完立刻绑
   （`ChatSyncService.bindGroupClient`，与收到推送那条路共用一份实现），失败只记日志、不影响创建。
4. **提示只弹一次**：`GroupApi.add` 这条路改成 `notify: false`，由页面调 `ApiClient.notifyError` 按同一套规则提示
   （`needsRelogin` 该跳登录还是跳登录）——否则接口层与页面会各弹一次同一句话。

测试（S5.6 新增 9 个，总 897 个）：`test/repo/group_admin_repository_test.dart`（参数只带 `user_ids`、新群写进通讯录与会话、绑一次 client、
没返回 id 就算失败不绑、空选不发请求、绑失败不影响建群）、`test/features/user_selection_page_test.dart`
（跑整个 App：列好友但不列群、点选/取消与「已选 N 人」、搜索与空态、空选时「完成」点不动、完成建群后本地落库并停在聊天页、失败留在原页并提示）。

**S5.6 遗留 TODO**

1. **真机要确认两件事**：① `group/add` 返回的那条到底带不带 `displayName` / `avatar`（现在缺字段就退化成 id 名、空头像）；
   ② 服务端会不会同时给创建者推 `addGroup`（推了就是重复 `bindGroup` 一次，无害但值得知道）。
2. **用户选择器的 `type == 2/3/4` 没有走这一页**（见上）：如果以后要对齐老端的路由（比如老端分享出去的 URL 直接带 `type=3`），
   得在这一页补一层转发；目前只有 `type=1` 从「＋」菜单进来。

**S5.6b 交付物（发起群聊 + 表情管理）**

1. **单聊信息页的「发起群聊」**：选择器支持预选（老端 `?contact_id=` —— 单聊时预选对方，建群请求里就会带上他），
   入口在单聊的聊天信息页。与老端不同（刻意的）：老端在单聊里也画群成员那块网格，那颗虚线格子写的是「添加成员」、
   点下去却走 `type=1`（创建群聊）——文案和行为对不上；新端直接写「创建群聊」。`contact_id` 还支持逗号分隔多个（老端只支持一个）。
2. **表情管理页**（`emoji_manage_page.dart`，老端 `pages/message/emoji.vue`）：标题带数量「表情管理（N）」，右上角「整理 / 取消」切多选，
   第一格「＋」上传（一次最多 9 张、单张 ≤2MB，超限那张跳过并提示），多选后底部出现「移动到最前面」「删除(N)」（删除二次确认），
   改完统一重拉列表。入口是表情面板「收藏」tab 的第一格（老端那个 `upload-emoji`）——**一个收藏都没有时它也在**，否则没地方进去。
3. **接口层收拢**：新建 `EmojiRepository`（列表 / 上传 / 删除 / 移到最前）+ `customEmojiProvider` 搬到仓库层，
   面板与这一页共用一份缓存（老端靠 `uni.$emit('updateEmoji')` 跨页刷新）；顺手修掉一个坑——`EmojiApi.list` 原来用 `postMap` 读，
   而这个接口 `data` 是**数组**，会静默拿到空 map。`ChatApi.emojiList` 随之删掉（重复的两个实现并成一个）。
4. **`CustomEmoji` 补上 `id`**：老端表情记录有 `id` 与 `file_id` 两个值，**删/移动用 `id`、发消息用 `file_id`**，以前只解析了后者。

测试（S5.6b 新增 12 个，总 909 个）：`test/repo/emoji_repository_test.dart`（列表解析与空地址过滤、删除/移动的 `ids` 参数、
上传表单字段名 `file`、失败抛异常）、`test/features/emoji_manage_page_test.dart`（标题数量、整理/取消切换、多选后移前并清空、
删除要二次确认、上传只传不超 2MB 的那张并提示超限）、`test/features/user_selection_page_test.dart`（`contact_id` 预选、逗号分隔多个与空值）、
`test/features/chat_info_page_test.dart`（单聊那颗「创建群聊」把对方预选好，建群参数只带他）。

**S5.6b 遗留 TODO**

1. **上传接口的回执没验**：老端上传完只重拉列表、不看返回值，所以这里也没解析——真机上传成功即可（要确认的是字段名 `file` 对不对）。
2. **「移到最前」的语义靠服务端**：接口只传 `ids`（老端也这样），到底移到最前还是按 `ids` 顺序重排，得真机看一眼。

---

## M6 进度（进行中）

### S6.1 信令层 ✅（纯 Dart，不依赖设备）

| 文件 | 内容 |
| --- | --- |
| `lib/domain/call/call_signal.dart` | 报文层：事件/90x 码/`status`/`type` 常量、收到的 `extends` 解析、发出去的十个字段 |
| `lib/domain/call/call_lock.dart` | 多端锁（老端 `msgStore.webrtcLock` 的三种形态：`false` / 对方 id / `true`） |
| `lib/domain/call/call_machine.dart` | 状态机：输入＝用户动作 / 远程信令 / 媒体层回调，输出＝`CallEffect`（要发的信令、提示、响铃、计时、取流、关页） |
| `lib/data/repo/call_repository.dart` | 信令通道（就是 `sendToMsg` 一层皮，为了 S6.3 能注入假实现） |
| `test/call/*`、`test/repo/call_repository_test.dart` | 86 个用例：常量、报文解析、十个字段、状态机每一条分支、锁的六条规则、仓库参数 |

**为什么先做它**：老端这套逻辑散在三处（`App.vue` 分流、`call.vue` 转发、`index.html` 产码），
状态藏在 DOM 与路由里。新端收成一个**无 IO 的纯状态机**，媒体层（S6.2）与界面（S6.3）
只需消费 `CallEffect`，信令本身与老端 1:1。这样通话最难的一段可以在没有设备的情况下测完。

**S6.1 与老端不同的地方（刻意的）**

1. **新增两个本地阶段**：老端只有 `status` 那五个值，新端把「接通中（`connecting`）」与「已接通（`connected`）」
   分开——对外 `status` 都是 2，但界面要能区分「正在建连」与「计时已开始」。
2. **只有主叫处理 `acceptRtc`、只有被叫处理 `offer`**：老端靠「自己那条被推回来时 `isMobile` 挡一下」，
   而 `isMobile` 是服务端加的、语义未确认；新端直接按角色过滤，被叫不会再回一个多余的 offer。
3. **`ended` 不算 `isActive`**：老端按钮没防抖，连点两次挂断会发两条 `hangup`（第二条码还可能算错）；
   新端重复挂断、挂断后再收到结束信令都是空操作。
4. **本地挂断当场解锁**：老端等自己那条 `hangup` 被服务端推回来（`fromUser.id == 自己` 且码在 902/903/905/906/907 里）才解锁；
   万一服务端不把发送方的消息推回去，老端那把锁就永远留着，**之后所有去电都会被自己拦成「其他终端正在通话中」**。
   锁本来就是本端这通电话锁上的，本地结束时就解掉（媒体失败那条路同理）。
5. **媒体就绪只认一次**：老端 WebView 的 `getUserMedia` 回调只会来一次，新端自己写的媒体层很容易重复回调，
   重复一次就会多发一条 `calling` / `acceptRtc`，对端会当成「又来一通」回忙线。

**S6.1 挖出来 / 确认的协议事实**

1. **`id` 是「通话 id」，两端共用**：`call.vue` 发出去的每一条信令都写 `id: this.main_id`，
   而 `main_id` 取自 URL 里的 `data.id` —— 也就是**主叫那条消息的 id**。所以被叫之后每一条信令都把主叫的 id 原样带回。
   老端「`main_id != e.id` 就是忙线」这条规则能成立，全靠这个。
2. **忙线判定对每一类事件都生效**（不只 `calling`）：`call.vue` 的 `webrtcConn` 回调在 `switch` 之前先比较 id，
   不一致就直接回 `busy/907` 并 return —— 连 ICE 候选都会被拦下来。
3. **`hangup` 事件无条件解锁**（`App.vue`），不只解自己的那条；而**带 90x 码的解锁只看自己的回显**。
4. **`905` 确认在客户端从未出现**：只在「收到这些码就解锁」的列表里被列过，语义仍待 S6.0 报文确认。
5. **`isbtn` 从不进请求体**：老端 `call.vue::msgCallback` 里那十个字段没有它，它只在 WebView 内部决定「要不要发这一枪」。
6. **`turndown` 没有任何地方发送**、`otherOpt` 只由服务端发出；`mediaDevices` 是老端 WebView 内部事件（本机媒体失败），
   新端走 `mediaFailed()`，不发信令。

**S6.1 踩坑**

1. **测试里的信令一定要带对 `id`**：我第一版测试给每条远程信令都用一个假 id，
   结果**18 个用例一起挂**——因为 id 不一致在老端就是「忙线」，状态机照规矩回了 `busy/907`。
   现在测试辅助函数默认取「当前通话的 id」，需要故意冲突的地方才显式写别的 id。
2. **Dart 的局部函数不能先用后声明**：把 `ringing()` 辅助函数插到 `remoteSignal()` 前面，
   整份文件直接编译不过（`Method not found`）。

**S6.1 遗留 TODO**

1. **真机/真实报文待确认**（都归 S6.0）：① 服务端会不会把发送方自己的信令推回来（决定多端锁的解锁路径，
   新端已本地解锁，所以不阻塞）；② `isMobile` 到底是什么（服务端加的字段，语义没读出来）；
   ③ `905` 的含义；④ `calling` 里 `status` 到底是 3 还是服务端会改写。
2. ~~**通话记录卡片还点不了**~~：S6.3 已接（点卡片回拨，类型跟着卡片走）。
3. **两端同时挂断**的收尾顺序（谁发 `hangup`、谁的 `EndCall` 先生效）在 S6.3 用真机确认。
4. **S6.2 接手时要知道的口子**：媒体层只需实现六个回调（`mediaReady` / `mediaFailed` / `localOffer` /
   `localAnswer` / `localIceCandidate` / `mediaConnected`）与五个副作用（`RequestLocalMedia` /
   `CreateOffer` / `AcceptRemoteOffer` / `ApplyRemoteAnswer` / `AddIceCandidate`）。

### S6.2 媒体层 + 控制器 ✅（真机互打待验）

| 文件 | 内容 |
| --- | --- |
| `lib/domain/call/call_media_config.dart` | 纯逻辑：ICE 列表（公共 STUN + 站点 STUN/TURN + 自建 TURN 位）、`getUserMedia` 参数、SDP 参数、候选字段筛选 |
| `lib/data/media/call_media_engine.dart` | 接口 + `flutter_webrtc` 实现（建连 / 取流 / offer-answer / ICE / track 开关 / 切镜头 / 收尾） |
| `lib/domain/call/call_controller.dart` | 控制器：把状态机的 `CallEffect` 落到真实世界（发信令 / 响铃 / 计时 / 取流 / 关页）+ 界面状态 `CallViewState` |
| `lib/core/audio/call_tones.dart` | 铃声（随包 `assets/audio/calling.mp3`，循环）与挂断音（服务端 `guaduan.mp3`） |
| `assets/audio/calling.mp3` + `pubspec.yaml` | 铃声资源（从老端 `hybrid/html/voice/calling.mp3` 拷过来，同一份文件） |
| `android/.../AndroidManifest.xml` | 补 `CAMERA`（麦克风 S4.4c 已有）+ 两个 `uses-feature` |
| `test/call/*`、`test/core/call_tones_test.dart`、`test/support/fake_call_media.dart` | 144 个用例（含**内存两端对打**） |

**这一层的分层与理由**：老端把 WebRTC 整个塞在 WebView 里，状态藏在 DOM；新端把它拆成
「状态机（纯逻辑）→ 控制器（翻译副作用）→ 媒体引擎（插件）」三层。这样单测能跑到
**除了真实 WebRTC 与真实网络之外的整条链路**：两个对端、真状态机、真控制器、假媒体层、
一条按服务端形态转发的假服务端。用例里连「主叫拨号 → 被叫振铃 → 接听 → offer/answer
→ 双向 ICE → 接通 → 挂断 906」的每一步报文都逐字断言。

**S6.2 与老端不同的地方（刻意的）**

1. **`getUserMedia` 的音频传 `true` 而不是 `{'echoCancellation': true}`**。后者是浏览器写法；
   `flutter_webrtc` 只在 `audio` 是布尔时才套用内置默认约束（噪声抑制 + 回声消除 + AGC），
   给 map 反而去解析 `mandatory/optional` 拿到空约束 —— **回声消除会丢**。
2. **不再传 `width` / `height`**。老端传的是 `{width: 屏幕高, height: 屏幕宽}`（横竖写反，
   请求一组横向分辨率），而原生侧只认 `mandatory` 里的 `minWidth` 这类键，顶层这两个键会被忽略。
   既然无用，就不留这个误导；分辨率交给插件选最接近的档位。
3. **切前后置用 `Helper.switchCamera`**，不再像老端那样「停旧 track → 重新取流 → `replaceTrack`」。
   顺带修了老端一个副作用：它连音频 track 也一起换了，所以**切镜头会把静音状态重置掉**。
4. **SDP 协商失败会补一枪挂断**。老端 `createOffer` / `createAnswer` 是**没有 catch** 的裸 promise，
   一失败就什么都不发，对方永远停在响铃/接通中；新端提示一句 + 发 `hangup`（码按阶段算）。
5. **ICE 连不上时明说**。老端完全不处理 `connectionState`，打不通就僵在「正在接通」；
   新端提示 `network.disconnect` 并结束这一通。
6. **新端监听 `onTrack` 时兼容「只推 track 不推 stream」**（老端读 `event.streams[0]`，那种情况会整个丢画面）。
7. **`busy` 那一枪不看回执**。老端两个发忙线的地方都是裸 `sendToMsg`、后面没有 `.then`；
   而服务端回执的 `extends` 就是刚发的那份报文，一解析就会把 907 当成「对方不在线」把自己挂掉
   ——（这个坑是写完控制器跑单测当场抓出来的，见踩坑 #1）。

**S6.2 确认下来的第三方事实（不是猜的，都在插件源码里核过）**

1. **权限由插件自己申请**：`GetUserMediaImpl` 内部会 `requestPermissions`（`RECORD_AUDIO` /
   `CAMERA`），但**它自带的 manifest 是空的**，所以宿主机 App 必须自己声明这两条权限
   —— 这就是为什么我们得手动加 `CAMERA`（不声明的话申请不到，取流会直接失败）。
2. **Android 上的 video 约束只认 `facingMode` 与 `mandatory`**：顶层 `width/height` 会被忽略，
   `mandatory` 里才认 `minWidth/maxWidth` 这类键。
3. **插件的默认 SDP 约束写法**是 `{'mandatory': {'OfferToReceiveAudio': bool, 'OfferToReceiveVideo': bool}, 'optional': []}`
   —— 与老端浏览器里的 `offerToRecieveAudio` 写法不同（后者在原生侧会被当空气）。
4. **插件版本**：`flutter_webrtc 1.6.2+hotfix.3`（android minSdk 21 / compileSdk 36，与工程的 24/36 兼容）。
   构建时 Flutter 会提醒这个插件还在用旧式 Kotlin 插件接入（只是前瞻性警告，不影响出包）。

**S6.2 踩坑**

1. **服务端回执的 `extends` 就是刚发出去的那份报文**：所以「看 `extends.code == 907` 判断对方不在线」
   对 **busy 自己那一枪**来说永远成立 —— 控制器照老端那样只对 WebView 那条路解析回执，
   busy 不看回执。测试里一开始没区分，表现为「回忙线之后自己反而弹了『对方不在线』」。
2. **假服务端必须按 `toContactId` 转发**：第一版把每条报文推给所有对端，结果两端的忙线
   你回我我回你，无限循环（真服务端只推给 `toContactId` 那个人）。
3. **`await controller.accept()` 之后一大串已经跑完了**：假服务端是同步转发的，所以 accept 返回时
   主叫已经 offer 完、被叫也 answer 完了。断言要写「链路每一环」，不能写「此刻还没发生」。
4. **假流只能靠 `noSuchMethod` 顶替**：`MediaStream` 是抽象类但成员太多，测试里用
   `class FakeMediaStream implements MediaStream { dynamic noSuchMethod(...) }` 才能造出来。
5. **`just_audio` 的失败拦不住**：`AssetCallTones` 在测试环境会被 `MissingPluginException` 打穿
   （是它内部的未捕获异步异常，我们的 `try/catch` 拦得住 await 那一层、拦不住它自己那条链），
   所以真实播放器在单测里只能验「资源真的打包了」与「地址拼对了」，出声必须真机。
6. **`dart format` 的路径别写宽**：`sed -i` 批量替换字段名时把 `import 'call_tones.dart'` 也换掉了
   （下划线开头的 pattern 匹配到了文件名的下划线），整份文件 33 个编译错误。批量改名前先 `grep` 看一眼。

**S6.2 产物尺寸（真机装包前先有个数）**

* debug APK：**214MB**（三个 ABI × 各自的 `libjingle_peerconnection_so.so` + 调试符号，仅供本机调试）
* release + `--split-per-abi`：armeabi-v7a **27.7MB** / arm64-v8a **35.1MB** / x86_64 **40.1MB**
* 合并后的 manifest 里已实际包含：`CAMERA`、`RECORD_AUDIO`、`MODIFY_AUDIO_SETTINGS`、`BLUETOOTH`、
  `WAKE_LOCK`、`INTERNET`、`ACCESS_NETWORK_STATE`（后四条来自插件与其它依赖）

**S6.2 遗留 TODO**

1. **真机互打（你来做，S6.3 之后一起验）**：语音/视频、耳机与听筒、切后台不断、WiFi↔4G。
2. **自建 TURN 仍然是空的**（风险登记 #1）：客户端现在只带公共 STUN，两边都在对称 NAT 后面就是打不通。
   `CallMediaConfig.ownTurnServers` 留了位置，有一条单测故意钉着「现在是空的」，填地址时它会提醒一起改文档。
3. **声音路由（听筒/扬声器/蓝牙）与音频会话没做**：属于 S6.4（`MODIFY_AUDIO_SETTINGS` 那条权限也到那一步再加）。
4. **没做 ICE 重启与断线恢复**：插件有 `restartIce()`，先用「连不上就提示并结束」兜着。
5. **铃声是随包资源、挂断音是服务端资源**：如果站点没有 `/static/voice/guaduan.mp3`，挂断就只有静默。

---

### S6.3 通话界面 ✅（装上包就能看到通话页）

| 文件 | 内容 |
| --- | --- |
| `lib/features/call/call_page.dart` | 通话页：背景（`assets/images/call_wallpaper.png`）+ 头像/名字/文案/计时 + 按钮行；视频通话多出大窗 + 右上小窗 |
| `lib/features/call/call_host.dart` | 无界面组件（挂在 `GracelinkApp` 外层）：会话开始自动 push、结束自动 pop（老端的 `navigateTo` / `navigateBack`） |
| `lib/features/call/widgets/call_video_view.dart` | `RTCVideoRenderer` 的 Flutter 封装（老端那块 `<video>`）；建/释放渲染器都在这里 |
| `lib/features/call/call_colors.dart` | 通话页专用色（老端 `index.html` 里那套 `#f2f2f2` 字色 / `rgba(0,0,0,.35)` 底） |
| `lib/domain/call/call_duration.dart` | `HH:MM:SS` 格式化 + 「通话时长」文案拼装（老端 `formatSeconds` / 服务端拼的那句） |
| `lib/domain/call/call_sync_service.dart` | WS `webrtc` 事件 → （`calling` 落库）→ 状态机；`isOnline` 事件接上多端锁解锁 |
| `lib/core/router/app_router.dart`、`lib/app.dart`、`lib/main.dart` | `/message/call` 从占位页换成真页面；`CallHost` 挂进 `GracelinkApp`；`main()` 启同步服务 |
| `lib/features/chat/widgets/chat_input.dart`、`chat_page.dart`、`contacts/user_detail_page.dart` | 三个入口：聊天「＋」的音/视频、通话卡片点一下回拨、资料页的音视频按钮 |
| `assets/i18n/*.json`、`lib/core/i18n/app_i18n.dart` | `call.*` 文案（中英）；`t()` 支持 `{name}` 占位（老端手拼句子） |
| `test/features/call_page_test.dart`、`test/call/call_sync_service_test.dart`、`test/core/app_i18n_test.dart`、`test/call/call_duration_test.dart`、`test/support/fake_call_ticker.dart` | 32 个新用例（跑整个 App 的通话页用例 13 个） |

**为什么通话页只 watch 控制器**：老端一页承担三件事（来电台 / 拨号台 / 通话中），
靠 URL 参数与 `status` 切换，文案与按钮显隐散在模板里。新端页面**不取 URL 参数**（信令里
已有对端信息），只读 `CallViewState`；谁是主叫、该显示哪句文案、哪个按钮该出现，全在控制器里算好。

**S6.3 与老端不同的地方（刻意的）**

1. **返回键 = 挂断**。老端按返回直接把通话页 pop 掉，WebView 的 `onUnload` 一条信令都不发，
   通话就那么僵在对方那边；新端用 `PopScope` 拦下来当挂断（来电中就是拒接 903）。
2. **按钮用 iconfont 字形而不是位图**（老端是 `guaduan.png` / `jieting.png` / `speaker.png` 等一堆 png），
   省掉一批位图，观感与项目其余页面一致。
3. **老端「点大画面收起按钮」在视频通话里保留**，但语音通话永远显示按钮组
   （老端语音通话根本没有可点的画面，收起后就没法恢复了）。
4. **计时器可注入**（`callTickerProvider`）：真实现用 `Timer.periodic`，测试用手动推进的假实现
   —— 否则 `pumpAndSettle` 永远等不到静止。
5. **多端锁的「另一台已处理」接上了 `isOnline` 事件**（老端 `App.vue` 里那两个 `otherOpt` 分支）。

**S6.3 挖出来 / 修掉的问题**

1. **控制器在销毁之后还会写 `view.value`**：信令链路里到处是 `unawaited`（回执、媒体回调、计时器），
   登出/换账号会把控制器整个换掉，那些还在飞的续点就会撞上
   「A ValueNotifier was used after being disposed」。现在 `_publish` 与 `reset` 都会先看 `_disposed`。
   （这是组件测试当场抓出来的，真机上表现为登出瞬间的一个红屏报错。）
2. **挂断之后 `phase` 会回到 `idle` 而不是停在 `ended`**：页面关掉时 `CallPage.dispose` 会 `reset()`
   （老端 `onUnload` 也是把这一通整个清掉），`ended` 只在页面还没关的那一瞬间存在。测试与后续
   搞挂断后处理的人都要知道这件事。
3. **`webrtc` 消息只有 `calling` 落库**（与老端 `if (data.extends.event == 'calling') appendMessage(res)` 一致），
   否则一条通话会在聊天里灌几十条 ICE 候选。

**S6.3 踩坑（组件测试里推 WS 事件极其阴）**

1. **WS 服务必须在 `setUp` 里建，事件必须在 `tester.runAsync` 里推**。`testWidgets` 的用例体跑在假时区，
   `startTestWsService` 里的 `await Future.delayed` 在用例体里永远等不到（实测直接卡到超时）；
   而反过来，在 `setUp`（真时区）建的服务，它收到事件之后的整条链（落库 → 状态机 → 发信令）
   续点也在真时区，`tester.pump` 推不动它 —— 现象是「明明推了报文，什么都没发生」，特别难查。
   正确姿势：`setUp` 建服务，`await tester.runAsync(() async { channel.emit(...); await Future.delayed(...); })` 推事件。
2. **路由过渡动画还得用假时钟推完**：通话页是 `CallHost` 在**真时区**里 push 的，`runAsync` 之后
   必须 `pumpAndSettle`，否则页面停在「动画一半」的位置（实测左边界在 97.5，按钮正好落在屏幕边缘点不到），
   报错还是 `tap()` 的 hit-test 警告，看不出根因。
3. **`stubAdapter` 的 `lastBodyOf` 在没发过请求时抛 `Bad state: No element`**：
   链路中途断掉时先看到的是这个，不是真正的断点。

**S6.3 遗留 TODO**

1. **真机互打（唯一必须你来做的）**：装上包 → 两个账号两台设备（或与老端互打）→ 语音/视频各打一次，
   验「能不能听见声音、能不能看见画面、挂断双方是否同时收尾」。信令链路的每一环都已在内存里对打验证过，
   但真实 WebRTC 与真实网络只有设备说了算。

---

### S6.3b 首次真机实测：通话必闪退（已修，2026-09-19）

**现象**（三星 S23 Ultra / Android 14 / 与官方网页端互打）：来电页正常弹、铃声正常响，
但**一点「接听」就即刻闪退**；自己发起通话同样闪退。

**定位过程（值得记下来，以后遇到同类型问题直接抳这个套路）**

1. 手机上开着 USB 调试 → `adb logcat -b crash -d` 直接拿到 Java 栈：
   ```
   java.lang.NullPointerException: ... PeerConnection.getTransceivers() on a null object reference
     at PeerConnectionObserver.getTransceiversTrack(PeerConnectionObserver.java:1252)
     at MethodCallHandlerImpl.getTrackForId(MethodCallHandlerImpl.java:1751)
     at MethodCallHandlerImpl.getNextTrackUUID(MethodCallHandlerImpl.java:1675)
     at GetUserMediaImpl.getUserAudio(GetUserMediaImpl.java:395)      ← 权限回调里
   ```
   结论：插件内部有个「空壳 PeerConnection」，而 `getUserMedia` 会遍历所有连接去查 track id，
   撞上它就是**不可捕获的 Java NPE**（Dart 侧 try/catch 拦不住，因为根本不在 Dart 里）。
2. 单测跑不到这一层（媒体层在单测里是假的），所以新增了
   `integration_test/call_media_smoke_test.dart`：**真机上直接跑真实媒体层**，
   并且把「建连接」和「取麦克风」拆开 —— 只建连接时插件会报错而不是崩溃，看得见原因：
   `DEAD: ... getTransceivers(): peerConnection is null`。
3. 拿真机上缓存的站点配置（`adb shell run-as … cat shared_prefs/...`）逐个配置对比，
   一发入魂（配置 JSON 打屏对比）：
   ```
   ...,{"urls":["stun.cloudflare.com:3478"]}        → DEAD（建不起连接）
   ...,{"urls":["stun:stun.cloudflare.com:3478"]}   → ALIVE
   ```

**根因：站点后台那栏 STUN 地址没写协议头。**
配置里实际填的是 `stun.cloudflare.com:3478`（没有 `stun:`）。浏览器会自动补，所以网页端/老端 WebView
一直没事；**原生 WebRTC 不补** —— 见到没协议头的地址就直接建不出连接（`createPeerConnection`
返回空对象），插件又不检查返回值，于是一路走到闪退。**与新旧客户端本身都没关系，是配置踩了原生实现的严格性。**

**修了什么**

1. `CallMediaConfig.normalizeIceUrl` / `splitIceUrls`：站点那栏的地址**自己补协议头**
   （没头就当 `stun:`；`turn@host` 这种写法也认；一栏里塞多个地址（逗号/空格/换行）拆成数组）。
   自建 TURN 那份也走同一套补全。
2. `WebrtcCallMediaEngine._ensureAlive`：**建完连接先摸一下**（`getTransceivers`），
   拿到空壳就当失败处理（提示 + 结束这通电话），而不是让整个应用死掉。
   这一道是保险：以后任何配置/插件回归导致的「空壳连接」，都不再是闪退。
3. 空账号密码不再发 `username` / `credential` 两个键（STUN-only 服务器不需要鉴权）。

**验证（都是真机上跑的）**

* 11 种 ICE 配置逐个建连接：**全部 ALIVE**（修之前 `site` 两种顺序都 DEAD）
* 完整流程：`minimal OK tracks=1` / **`site OK tracks=1`（就是崩过的那个配置）** / `video OK tracks=2`（麦克风+摄像头）
* `flutter analyze` 零问题；单测 **801 个全过**（新增 `test/core/rich_text_test.dart` 与 ICE 地址补全的用例）
* release 包重打并装回手机（arm64 35.3MB）

**新增的长期资产**：`integration_test/call_media_smoke_test.dart`
—— 媒体层任何改动都可以在装包前先跑一遍（`flutter test integration_test/… -d <设备>`），
把「真机上根本建不起连接」这类问题挡在真实使用之前。文件头里写了完整结论与跑法。

**给站点管理员的一条建议**：把后台那栏改成 `stun:stun.cloudflare.com:3478`（客户端现在兼容两种写法，
但带协议头才是正确写法；以后接 TURN 也一样）。

**顺带修掉的另一个真机问题**：网页端发来的消息 `content` 是 HTML
（`<p><span class="chat-grid-input">Hi</span></p>`），原来会在气泡里把标签原样显示出来。
现在按老端 `utils.js::htmlToLines` 的规矩剥成纯文本（新增 `core/util/rich_text.dart`：`<br>`/块级结束→换行、
实体解码、表情图片还原成 `[!code]`、普通图片丢掉），气泡、引用块、会话列表预览、复制都走它。
2. **多端锁的解锁路径仍待真实报文确认**（S6.1 遗留 #1）：服务端会不会把发送方自己的信令推回来。
3. **通话记录文案依赖服务端拼**（老端也是），`call_duration.dart` 只处理兜底显示。
4. **锁屏来电 / 悬浮窗**：S6.5 / S6.6（悬浮窗属于你最开始就想要的那项，位置留好了）。

---

### S6.3c 安卓权限/清单补齐 + 通话诊断面板（2026-09-19，S6.4/S6.5 之前的第一小步）

**为什么先做这两块**：① 权限与清单是后面两步（前台服务、音频路由）的地基，而现在这些权限
是靠依赖插件合并进 manifest 的（插件一升级就可能没）；② 「打不通」在界面上长得一模一样，
先有诊断面板，后面每一项改动都能在真机上马上验证。

| 文件 | 内容 |
| --- | --- |
| `android/app/src/main/AndroidManifest.xml` | 显式声明 `MODIFY_AUDIO_SETTINGS`、`BLUETOOTH`(≤30)+`BLUETOOTH_CONNECT`、`WAKE_LOCK`、`FOREGROUND_SERVICE(_MICROPHONE/_CAMERA)`、`VIBRATE`、`POST_NOTIFICATIONS`、`USE_FULL_SCREEN_INTENT` |
| `lib/domain/call/call_diagnostics.dart` | 纯逻辑采集器：候选按类型计数、信令收发/失败计数、`getStats` 解析、时间线、一句人话结论、导出文本 |
| `lib/features/call/call_diagnostics_sheet.dart` | 面板：结论 / 候选 / 连接（选中候选对、RTT、码率、丢包）/ ICE 服务器 / 信令 / 时间线；可复制、可导出 txt |
| `lib/core/util/dump_file.dart` | 文本落盘（应用文档目录，与 `ProtocolLog.dumpToFile` 同一套命名） |
| `lib/core/platform/app_settings.dart` + `MainActivity.kt` | 「去授权」：安卓自定义通道打开应用详情页，iOS 用 `app-settings:`（`url_launcher` 打不开安卓那个页面） |
| `lib/core/ui/notice_bus.dart`、`notice_handler.dart` | `ToastNotice` 支持一颗按钮（`toastWithAction`），权限提示旁边就是「去授权」，带按钮的提示留 6 秒 |
| `lib/data/media/call_media_engine.dart` | 接口多两个诊断成员（`iceServersDescription` / `sampleStats`）+ `CallMediaFailure` 分类（麦克风/摄像头/两者/没设备/认不出） |
| `test/call/call_diagnostics_test.dart`、`test/features/call_diagnostics_sheet_test.dart`、`test/call/call_controller_test.dart` | 新增 21 个用例（候选/统计解析、结论分支、面板渲染与复制、控制器接线与权限提示） |

**两个入口**：通话页**长按浮层**（看这一通的实时数据，视频通话接通后头像会收起来，所以长按加在整块浮层上）；
「设置 → 通话诊断」（看**上一通**的存档 —— 快照在挂断后不会被清掉）。

**结论那一行分得开的四类「连不上」**（这是面板最值钱的地方）：
一条候选都没有（ICE 地址不合法 / 权限没给）→ 只有 host（STUN 没起作用）→
有 srflx 还是连不上（对称 NAT，**必须 TURN**）→ 连上了但走中转（直连没打成功）。

**老端没有的东西（刻意的）**：老端一次都没调过 `getStats`，也没有任何信令/候选的记录，
所以它那边「打不通」只能靠猜。新端把这些都记在**纯逻辑**里（`call_diagnostics.dart` 不碰平台通道），
所以整条结论链都能跑单测。

**权限提示**：拿不到媒体时先由状态机说那句笼统的 `message.checkWebtc`（与老端一致），
随后补一句准确的（`call.micAuth` / `call.cameraAuth` / `call.micCameraAuth` / `call.deviceMissing`）——
安卓上麦克风与摄像头是分开授权、且**第二次拒绝后系统不再弹框**，所以权限那三条挂一个「去授权」
直接跳系统设置；「没设备」那条不给按钮（要的不是权限）。

**这一小步的遗留 TODO**

1. **前台服务（S6.5）与音频路由（S6.4）还没做**：权限已备好，服务与 `audio_session` 是下一步。
2. **真机上看两件事**：① 打完电话会话列表是否冒出未读红点（怀疑每条 ICE 候选都被服务端算成一条消息）；
   ② 「我的收藏」会话的 `is_group` 到底是多少（通话按钮那条规则靠它，若服务端给 0 需要再加一条按会话 id 的规则）。
3. **诊断面板只导出那一通的结构化文本**：没有把 `ProtocolLog` 的原始报文一起带上（真要连报文，先开协议日志再导出）。
4. **TURN（风险登记 #1）仍未部署**：接上之后面板的结论会从「必须部署 TURN」变成「走 TURN 中转」。

---

### S6.3d 真机上的两个信令时序坑：视频通话「一接通就闪退」（2026-09-19）

**用户报的现象**：语音通话正常，视频通话「一接通就闪退」，随后弹「请检查音视频」（`message.checkWebtc`）。

**真机取证（S23 / Android 14，`adb logcat` + `dumpsys`）**：

1. **App 从来没有崩溃/退出过**：整个会话是同一个 PID（15:43:37 起），crash 缓冲区与 `am_proc_died` /
   `am_kill` 里都没有本包，Activity 也没重建；`lib` 里没有任何 `exit()` / `SystemNavigator` 调用。
   用户看到的「闪退」是**通话页瞬间关掉**（通话结束 → `CallHost` pop 掉通话页）。
2. **日志里我们自己报了两次**：`[通话] 响应 offer失败：CallMediaException(PeerConnection 还没建立)`
   （15:46:06、15:51:07），紧跟的 `I/flutter` 行都没有；而 `FlutterWebRTCPlugin` 的日志显示
   这两次都是**媒体已经关掉之后**（`onConnectionChangeCLOSED`）才收到 offer。
3. 另有两次是媒体打开后 1~2 秒整通就结束了（PC CLOSED），其中 15:51:18 那次还真的
   `onConnectionChangeCONNECTED` 连上了，2 秒后又被关掉 —— 这一路「谁挂的」当时没有日志，只能看到结束。

**根因（两处，都在新端自己身上）**：

| 缺陷 | 位置 | 后果 |
| --- | --- | --- |
| 收到 `offer` 只判 `isCaller`，**没判这通电话还在不在**（`isCaller` 默认 false） | `call_machine.dart` `remote()` 的 `offer` 分支 | 一条过了期的 offer（对端在我们挂断后才发、或服务端连带旧信令重推）照样去响应 → 媒体层抛「PeerConnection 还没建立」→ 弹「请检查音视频」+ 补一枪空挂断 |
| 本机媒体还没就绪就响应 offer | 同上（`AcceptRemoteOffer` 由信令直接产出） | 视频取摄像头要 1~3 秒，这段窗口里 `RTCPeerConnection` 还没建出来 → 同一句错误 → **一接通就挂**。老端的 `call.vue` 本来就是「SDP 早到、页面还没点接听」那条分支，新端把它当成了错误 |

**修法**（都不动协议、不动服务端）：

* `call_machine.dart`：新增 `_pendingOffer` —— 媒体没就绪时**先把 offer 挂起**，等 `mediaReady()`
  再把 `AcceptRemoteOffer` 一起产出（顺序还是「先 `acceptRtc`、再 answer」）；
  `offer` 分支加 `!_session.isActive` 守卫；**挂起的那条在挂断/结束/重新开始时丢弃**（免得下一通拿着上一通的 SDP 去协商）。
* `call_controller.dart`：协商失败只在**通话还在进行**时才提示 + 挂断（过期的失败不再吓人）；
  新增信令日志（`收到信令：event/code/id/sdp 长度`）、结束码日志（`通话结束：906 通话中挂断` 等）、
  本机挂断日志 —— **「谁挂的、为什么挂」从此在 logcat 与诊断时间线上都有**。
* `call_media_engine.dart`：① 连接一建好（`_ensureAlive` 通过后）就摆到 `_pc` 上，对端的候选与 SDP
  早到时有地方落；② **远端候选在 `setRemoteDescription` 之前先攒着**（原来直接丢 —— 真机上
  「双方都发了候选却连不上」很可能就是缺了这几条；设好远端描述后按顺序补加）；
  ③ `open()` 单飞（并发调用等同一次取流）；④ 取流途中通话结束时按「取不到媒体」收尾，
  且清理时带「还是这条连接吗」的判断，不会误清下一通电话的连接。

**新增 8 个用例**（`call_machine_test` / `call_controller_test`，含 `FakeCallMediaEngine.holdOpen()`
让「取流途中 offer 到达」这条时序在单测里可复现）；全量 **855 个测试通过**，`flutter analyze` 干净。

**遗留**：真机上那次「媒体打开 1~2 秒后整通结束」的**主动方**还没确认（本地挂断与对端 `hangup`
在旧日志里长得一样）。新日志会把它指出来 —— 再看一次真机日志即可定案；同样待确认的还有
`服务器繁忙` 的已读上报与 `getContacts` 返回空列表这两条服务端表现。

---

### S6.5 通话期间的前台服务（安卓）—— 第一步：服务本身已完成并在真机验证（2026-09-19）

**目标**：通话中切后台/息屏不断线。App 切后台后进程随时会被系统冻结，WebRTC 媒体与 WS 信令
就断在那儿（对方听到的是「打一半没了」）；安卓唯一的解法是通话期间挂一个带常驻通知的前台服务。

**为什么自己写而不是用插件**：难点不是代码量，而是**时机与合规**（必须真的在用麦克风时才起、
必须由前台 UI 触发、每条结束路径都要停干净），这些恰恰要由我们控制；通用保活插件还会把
`dataSync` 类型、后台启动限制、以及「权限靠插件合并」-类风险一并引进来。

| 文件 | 内容 |
| --- | --- |
| `android/app/src/main/kotlin/.../CallForegroundService.kt` | 框架自带的 Service（不用 androidx）：API 29+ 带类型位（语音 `microphone`、视频 `microphone\|camera`）、LOW 渠道通知（不响不震不打扰）、点通知回 App、`startWithTask`、`START_NOT_STICKY`；**接住 `startForeground` 的异常**并记下原因 |
| `android/.../MainActivity.kt` | 通道 `gracelinkim/call_service`：`start` / `stop` / `isRunning` / `lastError` / `notificationPermission`（只查）/ `requestNotificationPermission`（申请） |
| `android/app/src/main/res/…` | 通知渠道文案 `strings.xml` + 通知小图标 `drawable/ic_call_notify.xml` |
| `lib/core/platform/call_keep_alive.dart` | Dart 侧接口 + 安卓实现 + 非安卓空实现；通知文案按当前语言拼（`call.ongoingVoice/Video` / `call.keepBack`）；`start` 会**轮询读回确认**（起不来就抛 [CallKeepAliveException]，不假装成功） |
| `lib/features/call/call_keep_alive_self_check.dart` | **debug 专属**自检面板（设置 → 前台服务自检）：不打电话就能验起/停/状态/通知权限 |
| `integration_test/call_keep_alive_smoke_test.dart` | 真机自检：先取麦克风 → 起服务 → 读回 → 保持 90 秒（观察/息屏窗口）→ 停干净 |
| `test/core/call_keep_alive_test.dart` | 通道契约单测（参数、文案、失败路径） |

**真机验证结果（三星 S23 Ultra / Android 14 / targetSdk 36）**

* 服务：`isForeground=true types=00000080`（语音）/ `000000C0`（视频）`createdFromFg=true`
* 系统日志：`Background started FGS: Allowed … uidState: TOP; code:PROC_STATE_TOP`（前台启动合规）
* 通知：`channel=gracelinkim_call category=call flags=0x62`，`android.title=与 自检 语音通话中`、`android.text=点击回到通话`
* **息屏 40 秒后 `isForeground=true` 仍在跑**；90 秒后测试断言仍为运行中
* 停之后：活动服务 0、`cmd notification list` 里没有本包（干净）

**真机踩出来的两个坑（都已在代码里接住，以后别重复踩）**

1. **`startForeground` 会抛，而且不接住就是「应用闪退」**。典型是 Android 14 的 while-in-use 校验
   （`ActiveServices.validateForegroundServiceType`）：mic/camera 类型的前台服务不允许从后台起。
   原来没接 → 系统抛 SecurityException → 进程当场死 → 用户看到的是「打个电话闪退」。现在：
   服务侧 catch + `lastError`，Dart 侧读回确认后抛 `CallKeepAliveException`（带系统原文）。
2. **通知权限框会把 App 顶到后台**，所以「申请通知权限」绝不能紧挨着「起服务」——那一瞬间
   正是「从后台起 mic 前台服务」，必然被拒。现在：通话路径里**只查不申请**
   （`hasNotificationPermission`），申请留给设置页/自检面板这类用户明示入口。

**顺带一个使用者的注意事项**：`flutter test integration_test/…` 跑完会**卸载**App，运行时权限
与登录数据一并清掉（下一次要重新授权/登录）；跑之前用
`adb shell pm grant com.example.gracelinkim android.permission.RECORD_AUDIO`（以及
`POST_NOTIFICATIONS`/`CAMERA`）把权限补上，且手机必须解锁亮屏——否则这条自检会（正确地）失败。

**S6.5 第二步：接进通话生命周期（已完成）**

* `CallController` 新增可注入的 `keepAlive`；`_openMedia` 拿到媒体之后 `unawaited(_startKeepAlive(video))`
  （不 await：起服务不该拖慢拨号），`_startKeepAlive` 里顺手**只查**通知权限；
* `_endCall`（EndCall 副作用）/ `reset` / `dispose` 三处停，且幂等（`_keepAliveStarted` 标记，
  不会重复发通道调用）；
* **堵一个竞态**：起服务要几百毫秒，期间若通话已结束（拨出去立刻取消），原生那边会晚于 stop
  完成 —— 所以 `start` 返回后若发现已经不需要了，再补一枪 `stop()`（用例钉住）；
* 结果写进诊断时间线：「后台保活已开启（前台服务：麦克风/麦克风+摄像头）」「后台保活失败：<系统原文>」
  「通知权限未给：保活照常，只是通知栏看不到「通话中」」；
* 新增 8 个用例（`test/support/fake_call_keep_alive.dart`）：取到媒体就起（参数对）、视频类型、
  拒接/接听后挂断/忙线/40s 超时/对方挂断/ICE 连接失败/`reset`/`dispose` 全都停、媒体失败不起、
  起不来只记诊断不影响通话、通知权限没给也保活、起服务中途挂断不留幽灵通知。

**还没在真实两机通话里验过的那件事**：真通话中切后台/锁屏要你打一通电话看一眼（见下方清单）。

**S6.5 还没做的**：iOS 那条**代码已经写好了**（见 S12.43：`UIBackgroundModes: audio` + `AppDelegate` 里激活 `AVAudioSession` + `IosCallKeepAlive`，
**一行都没编译过**）、电池优化白名单/自启动引导（降低国产 ROM 清理概率）、锁屏来电（S6.6）。

---

### S6.6a 通话小窗（画中画 P-i-P，安卓）—— 已完成并在真机验证（2026-09-19）

**产品要求：完全对齐微信**（用户明确要求，不是技术取舍）：

* 小窗里**只有内容、没有任何按钮**（进了小窗之后触摸被系统接管，点一下是「展开/菜单」，
  画按钮也点不到）——所以静音/挂断只能回通话页操作，**通知栏也不加按钮**；
* （第一版，已被第二版取代）**拨号中 / 通话中**离开应用（按 Home、划走）自动缩窗；**来电响铃保持全屏**（那一刻需要
  「接听 / 拒接」两颗大按钮，微信同样是全屏来电）；
* 内容：**未接通 = 白底绿卡片**（绿色话机图标 + 文案）；**接通后语音 = 1:1**（图标 + 放大计时）；
  **视频 = 3:4 竖的小长方形**（对方画面 `cover` 铺满 + 右上角自己的小窗）。

**为什么是系统画中画（PiP）而不是自绘悬浮窗**：自绘要「显示在其他应用上层」权限、要把原生
`track` 接到应用外的一个窗口上（只能碰插件内部实现）、要自己处理拖动/ROM 兼容；PiP 权限为 0、
画面就是现在这一路实时视频、由系统管窗口。代价：外形由系统定（12+ 才有圆角）、窗口会吸附到角落。

| 文件 | 内容 |
| --- | --- |
| `android/app/src/main/AndroidManifest.xml` | `MainActivity` 加 `android:supportsPictureInPicture="true"`（activity 本来就带 Flutter 模板那串 `configChanges`，正是 PiP 要求的） |
| `android/.../MainActivity.kt` | 通道 `gracelinkim/pip`：`supported` / `setEnabled(enabled, video, title)` / `isInPip`；`setAutoEnterEnabled`(API31+) + `setAspectRatio`（语音 1:1、视频 3:4）+ 标题；`onUserLeaveHint` 给 API24~30 兜底；`onPictureInPictureModeChanged` 回调 `modeChanged`；关掉时 `moveTaskToBack` 把小窗收掉 |
| `lib/core/platform/call_pip.dart` | `CallPip` 接口 + `AndroidCallPip`（**参数没变就不重复打通道**——通话里界面状态变化很频繁）+ `NoopCallPip`（iOS/桌面） |
| `lib/domain/call/call_controller.dart` | 每次界面状态变化按阶段 `unawaited(_syncPip())`：`outgoing/connecting/connected` 允许、其余（含来电响铃）不允许；`inPip` 进 `CallViewState`；失败只记诊断一行；`reset`/`dispose` 收尾 |
| `lib/features/call/call_page.dart` | 小窗布局：`inPip` 时收起所有按钮/状态字，视频 = 对方 `cover` 铺满 + 右上小窗，语音/未接通 = 白底绿卡片 |

**真机证据（S23 Ultra / Android 14，`flutter drive` 自检 `integration_test/call_pip_smoke_test.dart`，
`All tests passed`）**：

* `setEnabled` 两个模式都被系统接受（true）；按 Home 之后 `isInPip()` 立即变 true；
* 系统侧：`WindowManager: moveActivityToPinnedRootTask` +
  `ActivityTaskManagerService.enterPictureInPictureMode`（16:47:22 语音 / 16:47:54 视频）；
  `mLastReportedPictureInPictureMode=true`、`supportsPictureInPicture=true`；
* **窗口画面尺寸实测**：语音 `464x464`（= 1:1）、视频 `397x529`（= 3:4），与设计一致；
* 关掉允许（= 通话结束）之后小窗退出（`EXITED = true`，任务回后台，通话通知仍在）。

**为什么这条自检用 `flutter drive` 而不是 `flutter test integration_test/…`**：后者跑完会**卸载**
App（登录态与权限一起没），`flutter drive --keep-app-running` 只是安装并留着。所以新增了
`test_driver/integration_test.dart`（标准驱动），跑法见 `integration_test/call_pip_smoke_test.dart` 顶部注释。

**S6.6a 第二版：取消「自动缩窗」（2026-09-19，用户要求）**

用户反馈：「只有点了那颗缩小按钮才变成小窗，滑到后台默认不出小窗，只有前台服务和常驻通知就可以。」
于是把「离开应用自动缩窗」整条行为删掉：

* 通道从 `setEnabled(enabled, video, title)` 改成 **`setParams(video, title)` + `enter()` + `exit()`**；
* `MainActivity`：删掉 `setAutoEnterEnabled` 与 `onUserLeaveHint` 兜底（API 24~30 那条也一并去掉），
  `enter` 仍然是按钮触发（Android 14+ 要求前台可见时才能起 mic 类前台服务/进小窗），
  新增 `exit`：在小窗里就 `moveTaskToBack(true)` 把窗口收掉；
* 控制器 `_syncPip`：通话活跃时只交**参数**（比例 + 标题）；通话结束 / `reset` / `dispose` 时
  先 `isInPip()` 再 `exit()`（幂等：没在小窗里就不白调通道），并记一行「通话结束，小窗已收起」；
* 界面不变：那颗「缩成小窗」还是左上角（视频通话底部那排也有一个）——现在它是**唯一**入口；
* 真机自检 `integration_test/call_pip_smoke_test.dart` 重写成三行标记：
  `[PIP] READY no-auto`（此时按 Home → 断言 **不能** 进小窗）、`ENTER voice`、`ENTER video`；
* 测试跟着改：通道契约（`setParams`/`enter`/`exit`、参数没变不重复打通道、报错当 false）、
  控制器（拨号中就交参数、挂断/reset/dispose 收小窗且幂等、没在小窗里不调 exit）——全量 **876 个**通过。

**S6.6b 应用内悬浮窗（微信那种）—— 已评估，用户 2026-09-19 决定"先不做"**

用户观察到的差别是真的，而且根子在**两套完全不同的机制**：

| | 微信那个小窗 | 我们的系统画中画（S6.6a） |
| --- | --- | --- |
| 谁画的 | **App 自己**（微信界面之上的浮层） | **安卓系统**（把一个 Activity 缩成小窗口） |
| App 还能用吗 | 能，小窗浮在微信页面上，可以边聊边看 | 不能，整个 App 被缩成那个小窗口 |
| 离开 App | 微信那颗还能浮在别的应用上（它用的是**系统悬浮窗**，要“显示在其他应用上层”权限） | 小窗还在，但 App 是缩着的状态 |

**要做的话工作量不大（~1 天，零权限、不动协议与服务端）**，但需要动三处：

1. **“关掉通话页 ≠ 结束通话”**：现在 `CallPage.dispose()` 里就是 `reset()`（媒体、信令全收，老端
   `onUnload` 的语义）。要拆开 —— 缩小只是把页面藏起来，媒体/信令/前台服务继续跑
   （它们本来就在控制器与保活服务里，**不依赖通话页**，S6.5 那套正好接上）。
2. **小窗挂在一个全局浮层上**（`Overlay` / App 壳的 Stack），跨路由活着，聊天页里也看得见。
3. 控制器加一个"已缩小"状态（同 `inPip` 的位置），由 `CallHost` 决定要不要关页、要不要画小窗。

**三条约束（就是当初没直接开做的原因）**：

* 它只能**在 App 内**浮；按 Home / 切到别的应用就看不见了（那时只剩常驻通知）。
  微信能浮到别的应用上，靠的是**系统悬浮窗**（`SYSTEM_ALERT_WINDOW`，国产 ROM 还有一道
  “后台弹出界面”）—— 那条路要用户进设置授权，而且**视频画面**要塞进系统窗口得碰
  `flutter_webrtc` 的内部实现（公开 API 只给 Flutter 侧的渲染器），插件升级就可能碎；
  语音通话反而好做。要做的化单独立一项评估，不要跟应用内浮层混在一起做。
* 返回键语义要重定（现在是“返回 = 挂断”）：有了浮层小窗后，“返回 = 缩小”更贴微信。
* 语音通话小窗的显示内容（头像 + 计时 + 要不要静音状态）要定。

**用户决定**：先不做（2026-09-19）。以后要做就直接按上面三步走；系统悬浮窗那条路另评。

**S6.6a 还没做的**：iOS 的画中画（`AVPictureInPictureController`，与 S6.4 音频一起）；
部分 ROM 把画中画做成开关（「特殊应用权限 → 画中画」），没开就静默退回通知栏（已按此写，但没有
针对性文案引导）；小窗里没有静音状态角标（用户明确说不要）。

---

### S6.3e 通话页改版：全面对齐微信（2026-09-19，用户给定截图）

**背景**：用户希望「小窗再小」而画中画给不了（App 只能定比例，像素尺寸由系统按固定面积算，
实测语音 464×464 / 视频 397×529，面积都≈屏幕 5%），于是放弃那条路，**改为把通话页做成微信那套**。

**用户确认的三个选择**：图标用现有 iconfont（不够的自己拼）、只改「拨号中/通话中」（来电响铃页不动）、
语音页背景改固定深色渐变（不再铺老端那张 `wallpaper.png`）。

| 位置 | 改成什么 |
| --- | --- |
| 背景 | `CallColors.backdropTop→backdropBottom` 竖向渐变；视频通话再叠一层顶部压暗（`scrimStrong`→透明），名字/计时压在画面上 |
| 中间 | **大圆角方形头像**（`ContactAvatar` 新增 `radiusRpx`，圆角取边长 14%）+ 名字 + 状态；语音头像 190rpx、视频 130rpx；**视频接通后头像收起** |
| 状态文案 | 拨号中「**等待对方接受邀请..**」（新增 `call.waitingAnswer`，名字已在上面不再重复）；接通后原地换成计时；来电响铃仍用老端那两句 |
| 圆钮 | **开着 = 白底 + 深色图标；关着 = 半透明白底 + 白色图标**；文字改成**状态**（`call.micOnState`/`micOffState`/`speakerOnState`/`speakerOffState`/`cameraOnState`/`cameraOffState`），不再是「关闭麦克风」这种动作 |
| 语音页按钮 | 麦克风 / 红色挂断 / 扬声器（免提也带文字） |
| 视频页按钮 | 上面三颗带文字的麦克风/扬声器/**摄像头**（老端视频通话没有免提与摄像头开关，这两颗是新增），下面一排 **缩成小窗 / 红色挂断 / 翻转摄像头** |
| 红钮文字 | 拨号中写「**取消**」（`call.cancel`），接通后写「挂断」 |
| 左上角 | 「**缩成小窗**」（`IconFont.shrink`，`Tooltip` 文案 `call.minimize`）——点一下**立刻**进画中画，不用按 Home：通道新增 `enter`，控制器新增 `minimizeToPip()`，失败只记一行诊断 |
| 图标 | 摄像头没有「带斜杠」字形，关掉时在 `IconFont.video` 上自己画一条斜杠（`_withSlash`） |

**期间逮到的一个真 bug**：视频通话顶部那层压暗（`DecoratedBox`）**自己会吃掉触摸**，
导致顶部一整块（含右上角自己的小窗）点不动 —— 加 `IgnorePointer` 修掉（`call_page_test` 里
先命中测试抓到 `RenderDecoratedBox` 才定位到的）。

**测试**：通话页用例改成新文案/新按钮（含「点左上角 → `pip.enter()` 被调用一次」「视频三颗开关 +
摄像头关掉写 `setCameraEnabled(false)`」）；控制器新增两条（成功/系统拒了都只记一行）；
全量 **874 个测试**通过、`flutter analyze` 干净。

**还没做的**：iOS 那套（与 S6.4 一起）；小窗（画中画）里的画面还是旧的白卡片（用户只要求改通话页）。



### S6.7 模糊背景 vs 共享屏幕：为什么换掉那颗按钮，以及共享屏幕的实现（2026-09-19）

**用户的原始问题**：微信视频通话底部左边那颗是「模糊背景」，我们能不能做（不许动后端）？

**结论：做不了（用我们这套媒体栈）。** 虚化必须在**画面发出去之前**逐帧做人像分割 + 背景模糊，
而本机画面走的是插件接管：`getUserMedia` → 轨道直接进 PeerConnection，全程不经过我们的代码。
在 `flutter_webrtc 1.5.2` 的 Dart API 里逐个查过：没有逐帧回调、没有 `insertable streams`、
没有「视频处理器」这类口子（唯一的 `frame_cryptor` 是端到端加密，与画面无关），官方 issue #957
「Virtual background in WebRTC」自 2022 年至今 open。要做只能换/接管本机画面管线（LiveKit track-processors、
100ms、Twilio video processors 那一类），按天到周算，还要扛帧率与发热 —— 本项目不做。

**白捡的那条路**：三星 One UI 自带「视频通话效果」（状态栏那个「星光+摄像机」图标就是它），
里面有背景虚化/背景色，作用在系统相机流上 —— 对第三方 App 也可能生效（**真机点一下就知道，
这个成本为零，值得你试**）。那个图标是系统画的，App 画不了、也碰不到。

**于是这颗位置换成「共享屏幕」**（用户拍板）：

| 层 | 做了什么 |
| --- | --- |
| 清单 | `FOREGROUND_SERVICE_MEDIA_PROJECTION`（与上一版的 `FOREGROUND_SERVICE` / `..._MICROPHONE` / `..._CAMERA` 并列） |
| Kotlin | `CallForegroundService` 支持**多类型位**：`ACTION_SHARING` 用「同一颗通知」重新 `startForeground`（`serviceType()` = MICROPHONE\|CAMERA\|MEDIA_PROJECTION），并把正文换成「正在共享屏幕」。**不另起第二个服务**，所以不会多出第二条通知、也不会多一个「正在使用」图标 |
| Dart 保活 | `CallKeepAlive.setScreenSharing({required enabled})`（安卓真实现 / 空实现 / 假实现都有；通知文案走 `call.sharingNotice` ↔ `call.keepBack`） |
| 媒体层 | `supportsScreenShare`（安卓 true）、`requestScreenSharePermission()`（`Helper.requestCapturePermission(fullScreenOnly: false)`）、`startScreenShare()`（`getDisplayMedia` → 找视频 sender → `replaceTrack(屏幕轨)`）、`stopScreenShare()`（换回摄像头轨 + `track.stop()` 放掉屏幕流）。**只换发送端、不重新协商**：协议与服务端一行都没动。共享期间 `localStream` 返回**屏幕流**，所以自己的小窗看到的就是发出去的内容 |
| 控制器 | `toggleScreenShare()`；通话页按 `canShareScreen`（视频 + 平台支持）决定画不画那颗钮；共享期间界面把「摄像头」「翻转摄像头」弄灰；共享状态在 `_screenSharing` 里另存一份（界面状态会在通话结束那一刻被清掉，而收尾顺序还要用它） |
| 界面 | 底部左边那颗：`Icons.screen_share` ↔ `Icons.stop_screen_share`（iconfont 没有投屏字形，这是本页第一次用 Material 图标），共享中图标变主题绿 |
| i18n | `call.screenShare` / `call.stopShare` / `call.shareRefused` / `call.shareFailed` / `call.sharingNotice` |

**⚠️ 三处顺序是硬要求（写错了就是 SecurityException / 投屏不生效）**：

1. **先拿到用户对投屏的同意**（`requestCapturePermission` 弹系统框）→ **再**把前台服务类型升上 `mediaProjection`
   → **最后**才 `getDisplayMedia`。Android 14 要求「取投影之前已经有带该类型的服务在跑」；
   而插件把用户的同意存在自己内部（`mediaProjectionData`），所以同意之后再取流**不会弹第二次框**。
2. **通话结束时先停投影、再撤前台服务**（`_endCall` 里 `if (_screenSharing) await _stopScreenShare()`，
   走在 `_stopKeepAlive()` 前面）—— 投影在带该类型的服务停掉之前结束。
3. 屏幕流**不要音频**（`{'video': true, 'audio': false}`）：声音继续走本机麦克风，否则会把对方的声音回灌回去。

**真机验收后的一轮 UI 调整（2026-09-19，用户实测提出）**：共享一开，本机那路画面
换成了屏幕流，于是小窗里出现「整个 App 的缩小版」（而且小窗里又有小窗，递归感很强），
同时摄像头预览消失、界面除了那颗变绿的图标之外看不出在共享。用户拍的两个选择：

| 项 | 改成 |
| --- | --- |
| 自己那块画面 | **收掉**（共享期间只留对方那一路，大窗固定是对方，不再受「大小窗互换」影响）；小窗（画中画）里同样不放右上角那块 |
| 摄像头 | 共享期间**把摄像头轨停掉**（`enabled = false`，指示灯熄灭、不再采画面），停共享时按**共享前**的开关状态恢复（`_cameraWasEnabled`） |
| 状态提示 | 名字/计时下面加一行「**正在共享屏幕**」（绿点 + 绿字，`call.sharingNotice`）——同样会被采集进去，所以**对方也能看到这行字**，一眼就知道「画面为什么变成屏幕了」 |

没做、但知道的事：那行状态字在下那排按钮的浮层里（点画面可以把浮层收起来，
那一刻共享提示也跟着没了，跟挂断钮一样）—— 如果以后觉得不够显眼，可以把它提到浮层之外（PiP 里也能显示）。

**测试**（全量 **888 个测试**通过、`flutter analyze` 干净）：控制器新增 9 条（硬顺序用
「跨层轨迹」钉住：`media.requestScreenSharePermission()` → `service.sharing=true` → `media.startScreenShare()`；
用户拒绝 / 类型位升不上去 / 取流失败回滚 / 再点一次停止 / 语音通话里是空操作 / 平台不支持 / 挂断 / reset）、
通道契约 1 条、通话页 1 条（点一下 → 「停止共享」+ 摄像头那两颗点了没反应）。

### S6.3f 通话页图标换成「Material 圆角 + 一颗苹果」（2026-09-19）

**起因**：用户觉得通话页那套图标「有点丑」。诊断下来主因不是「不像微信」，而是
**不同来源拼在一起**：老端 `iconfont.ttf` 里那 32 个字形不是同一个设计体系，放在
一排圆钮里就出现「摄像头那颗大一圈、翻转摄像头那颗太碎、共享那颗是细线」的观感。

**做法：先给用户看，不瞎猜。** 临时做了一个对照页（设置 → 其他设置 → 通话图标对照），
把 12 颗功能 × 5 套候选画在**真机尺寸的圆钮**里（白底 + 深色字形）：
现有（老端 iconfont）/ Material 圆角变体 / Material 实心 / CupertinoIcons / Phosphor Fill。

**Phosphor 那一路的坑**：pub 上的 `phosphor_flutter` 编译不过（它
`class PhosphorIconData extends IconData`，而新版 Flutter 把 `IconData` 变成了 `final class`；
2.1.0 就是它的最新版）。所以改成自己带一个字体：拷 `Phosphor-Fill.ttf` 进
`assets/fonts/` + 自己声明字体族 + 抄十几个码点。顺带验证了一个便宜的事实：
**Flutter 的图标字体摇树对自定义字体一样有效**（449KB 的 Phosphor 打进包只剩 **~4KB**，
现有 iconfont 也是 10.5KB → 2.8KB）。

**用户最终选定**（对照页上挑的）：

| 功能 | 换成 |
| --- | --- |
| 麦克风开/关 | `Icons.mic_rounded` / `Icons.mic_off_rounded` |
| 扬声器开/关 | `Icons.volume_up_rounded` / `Icons.volume_off_rounded` |
| 摄像头开/关 | `Icons.videocam_rounded` / `Icons.videocam_off_rounded`（**终于不用再手画斜杠**） |
| 挂断/取消、接听 | `Icons.call_end_rounded` / `Icons.call_rounded`（小窗那张绿卡片同此） |
| 缩成小窗 | `Icons.picture_in_picture_alt_rounded` |
| 共享屏幕/停止共享 | `Icons.screen_share_rounded` / `Icons.stop_screen_share_rounded` |
| **翻转摄像头** | **`CupertinoIcons.switch_camera_solid`**（整套里唯一一颗苹果字形，Material 那个太碎） |

**顺手删掉的**：`_withSlash`（自画斜杠那条路径）与 `_toggleButton` 的 `slash` 参数、
临时对照页与它在设置里的入口、它的用例、`phosphor_fill_icons.dart`、
`assets/fonts/Phosphor-Fill.ttf`（+ 许可证文件）、pubspec 里那个字体声明、
`phosphor_flutter` 依赖。**通话页不再用 `iconfont`**（那个字体仍被聊天页等用着，保留）。

**测试**：888 个全过、`flutter analyze` 干净（小窗那两条断言从 `IconFont.call` 改成
`Icons.call_rounded`）。

**还没验证的（要真机）**：系统投屏框放过之后的完整链路 —— 用户点「开始投屏」→ 对端真的看到屏幕。
（`requestCapturePermission` 那个框只有人能点，集成测试替不了。）另外 iOS 仍然没有这条路
（`supportsScreenShare` 为 false，界面不画那颗钮，靠 `AVPictureInPictureController` 那类方案是以后的事）。



### S7.1 交付物（发现页 + 内嵌浏览器 + 扫一扫 + 二维码 + 群资料）

**一、发现 tab（`features/compass/compass_page.dart`）**

- tab 出不出现由服务端配置决定（`globalConfig.compass.status == 1`，`GlobalConfig.compassEnabled`）。
  整页**没有一个硬编码入口**：`mode == 2` 画三列宫格、`mode == 1` 画一列菜单，每项
  `{icon, name, url, type, badge}`；角标 `1` 画一个小圆点、其余当数字（超 99 显示 `99+`）。
- 点一项（`openCompassItem`，与 `compassRouteOf` 一起抽成纯函数好单测，同 `scanRouteOf`）：
  `type == 2` 或地址以 `http` 开头 → 内嵌浏览器；否则剥掉老端那个 `pages` 前缀当站内路由跳。
- 与老端不同（刻意的）：既不是外链也不是站内路径时，老端把它丢给 `navigateTo`（等于什么都不发生），
  新端提示一句「暂无数据」。

**二、内嵌浏览器（`features/common/webview_page.dart` + `core/platform/webview_host.dart`）**

- 官方 `webview_flutter`。抽成 `WebViewHost` 接口是为了能在组件测试里注入假的 —— 真机上 webview 是
  平台视图，测试里建 `WebViewController` 会直接抛（与 `MediaPicker` 同一个理由）。
- 进度条**只在拿到进度之后**才画：一上来就画一个「不知道什么时候完」的无限动画，既没信息量，
  也会让 `pumpAndSettle` 永远等下去。只有**主框架**失败才换成「加载失败 + 重试」（子资源失败不影响阅读）。
- 三处进来：用户协议 / 隐私政策、发现页里 `type == 2` 的条目、扫到普通网址的兜底。

**三、扫一扫（`features/common/scan_page.dart` + `domain/scan/scan_target.dart`）**

- 内容分流是纯函数 `parseScanTarget`：含我们的 apiUrl 且是站内路径 → 拿最后一段当 `realToken`
  问服务端；其余当普通文本，弹「已识别内容 + 复制」。与老端不同（刻意的）：老端只要内容里
  **出现过** apiUrl 就发请求（正文里引了我们的域名也会发），新端要求「以 `/` 开头且最后一段非空」。
- 服务端 `action` → 该跳哪，由纯函数 `scanRouteOf` 决定：`groupInfo` → 群资料页、
  `userInfo` → 用户详情、`qrLogin` → 扫码登录（确认页仍是占位）；关键字段为空或 action 不认识
  → 提示一句，而不是跳一个什么都加载不出来的空页（老端会跳过去）。
- 界面自己做（老端用 `uni.scanCode` 的系统界面）：取景框四角 + 手电筒 + 相机起不来时的「去设置」按钮；
  扫码只在前后台切换时自动停/起（插件自带），不自己管生命周期。

**四、二维码（`features/common/qrcode_page.dart`）**

- 一个页面两种形态：不带 `group_id` 是「我的二维码」（码值取用户资料里的 `qrUrl`），带了就是
  「群二维码」（码值来自 `groupInfo.qrUrl`，底部那句「该二维码7天内有效（…前到期）」）。
  入口：「我的」页标题栏那颗图标、群聊信息页那一行。
- 老端是往 canvas 上摞白底 + 头像 + 名字 + 二维码再整体存相册；新端用 `RepaintBoundary` 把同一块
  抓成 PNG，再交给统一的 `MediaSaver`（与其它存图同一条路，权限提示也是同一套）。

**五、群资料 / 加入群聊（`features/contacts/group_join_page.dart` + `domain/chat/group_join.dart`）**

- 只有扫码一个来路（`groupInfo`）。界面就三样：群头像、群名（拼上人数）、一颗按钮
  （已经在群里是「进入群聊」，否则「加入群聊」）。
- 字段形态照老端：名字读 `name`（**不是** `displayName`）、人数读 `groupUserCount`、
  `isJoin` 与 `setting.invite` 两种真假值形态都吃（`tolerantFlag`，`0/1`、字符串、布尔）、
  加群时要带 `inviteUid`；`setting.invite == 0` 时点加入只提示（老端也是拦在这里）。
- 与老端不同（刻意的）：老端加群成功只把 `is_group` 改成 1 就 `appendContacts`；新端走
  `GroupAdminRepository.join` —— 通讯录 + 会话都写、并且**立刻绑 client**（不赌推送，
  否则新进的群可能收不到消息），这段与「自己建群」共用一份 `_registerGroup`。

**测试**：本轮 +19（**总 940 个全过**、`flutter analyze` 干净）：
`test/core/scan_target_test.dart`（分流 8 条 + `scanRouteOf` 3 条）、
`test/features/compass_page_test.dart`（5 条：宫格与角标、一列与剥前缀、外链进内嵌浏览器、进度与失败重试、空地址）、
`test/features/group_join_page_test.dart`（4 条：已进群、加入、关闭加群、失败重试）、
`test/features/qrcode_page_test.dart`（4 条：我的二维码、群二维码、没码值空态、存相册链路）、
`test/repo/group_admin_repository_test.dart`（+3 条：群资料解析、加群参数与落库、失败不动本地）、
`test/session/global_config_test.dart`（+compass 配置）。

**踩坑**：

1. `qr_flutter` 的 `QrImageView` **不对外暴露码值**（`_data` 是私有的）——用例只能钉「画没画码」，
   码值对不对在仓库层钉；「保存到相册」那条路在测试里要 mock `path_provider` 的
   `getTemporaryDirectory` 通道（否则 `MissingPluginException`），而且得用 `tester.runAsync`
   （抓图 + 写临时文件是真异步，假时钟里跑不动）。
2. 这一轮的用例必须在**用例体结尾**显式 `await disposeApp(tester)`：`addTearDown` 跑在
   `_verifyInvariants` 之后，drift 的 `markAsClosed` 零延时定时器会以「Timer is still pending」报出来
   （已有用例都是这个写法，照着抄就对）。
3. 假的 webview 要照真实现的语义数「建了几次」：真实现是 `StatefulWidget` + `late final
   WebViewController`，同位置重建**不会**重新加载页面，所以假的只在 `initState` 里记一笔
   （否则进度/失败那些 `setState` 会被数成「又建了一个 webview」）。

**复查时逮到的一处漏接（已修）**：扫一扫的页面与用例都在，但**路由还指着占位页** ——
点「＋ → 扫一扫」进去看到的是「待实现」，而且没有任何用例会红（是复查功能清单时人工发现的）。
修法：`app_router.dart` 里补 `AppRoutes.scan` 的真路由（`ScanPage`）、把它从 `_pendingRoutes` 删掉；
顺手把 `videoPlay` 也从占位清单删掉（我们的视频播放是 `VideoPreviewPage` 底部弹层，
不走那条路由 —— 老端有独立的 `pages/message/video.vue`，新端等价物是弹层，功能不缺）。
新增防漏用例 `test/core/route_placeholders_test.dart`：
「已实装的页面不能还留在 `pendingRoutePaths` 里」+「占位清单只剩 `qrLogin` / `moments`
（加新的占位要在这里登记）」——以后「页面写了、忘接路由」会直接红。

**这一轮之后的待办（以 IM 6.2.0 为准）**：朋友圈（仍是占位）、扫码登录确认页、
检查更新（S7.2）、多语言收尾与文案校对（S7.3）、聊天背景、锁屏来电整屏弹（S6.6）、
离线推送与来电唤醒（S8.1）。

### S7.2 检查更新 + 老端还剩的四件（2026-09-20）

以 IM 6.2.0 为准，这一轮把「老端真有、我们没有」的那五件一起收掉（都是纯客户端、
零后端改动、零新依赖，除了最后一件给 `pubspec` 加了 `open_filex`）：

**一、扫码登录确认页（`features/login/qr_login_page.dart`）**

- 补上 PC / 网页端扫码登录的手机这半：读 `token` → 电脑图标 + 「您正在登录电脑端，是否确定是你本人登录？」
  → 「登录」调**早就存在**的 `ChatApi.tokenLogin` → 把服务端那句 `msg` 原样提示 → 1.5 秒后自动返回。
  没带 `token` 直接返回（老端也这么写）。接口与文案都是现成的，这一件之前只差这一页。
- **踩到一个自己埋的坑**：`/login/qrlogin` 原先在路由守卫的**白名单**里，于是已登录时访问它会被
  弹回首页 —— 而扫码登录的前提恰恰是「手机上已经登录」。已把它从白名单里拿出来
  （`session_guard_test` 同步钉住：未登录会被拦住、已登录能进）。
- 安全提示照抄老端：能显示的只有「这是登录码」，没有设备/IP 可展示（`verify` 只回
  `action / id / loginToken`）；想更安全需要后端在 verify 里多回设备信息，那是另一件事。

**二、群公告只读（`core/ui/text_prompt_dialog.dart` + 聊天信息页）**

- `showTextPrompt` 加 `enabled` / `showOk`：非管理员点群公告只能看，连「保存」都不画
  （老端是同一个弹层把输入框 `disabled`，但按钮还在）。
- 顺手把群成员页那几张操作弹层（禁言 / 移出 / 设管理员）抽到
  `features/chat/widgets/group_member_sheets.dart`，让「群成员管理页」与新的「群内管理」块共用一份。

**三、聊天背景（`data/repo/chat_background_repository.dart`）**

- 老端：`uni.chooseImage` → `uni.saveFile` 存进应用目录 → 路径写进 `chat-bg-info<会话 id>`
  （**设备本地偏好，不跟随账号**）。新端同一套，多一步把图片拷进应用文档目录 ——
  `image_picker` 给的是临时路径，系统随时会清理。图片路径失效（用户在相册删了）时静默退回默认背景，不报错。
- 与老端不同（刻意的）：老端改完要**重进聊天**才生效（它界面上就写着那句提示），
  新端用 `revision`（`ValueNotifier`）通知聊天页，改完当场就变；选图这一版只开相册
  （`MediaPicker.pickImages` 的多选接口不带 `source`，要拍照得另开一条路）。
- 「毛玻璃」开关没做：老端那个只在微信小程序端有，APP 端点了没效果。

**四、用户详情页「群内管理」（`domain/chat/user_group_manage.dart`）**

- 老端 `detail.vue` 那个块要**同时**满足三条才显示：服务端给了 `groupInfo`、
  `manageRole < 3`（`manageRole` 是**我**在这个群里的角色，服务端算好给下来）、对方不是群主。
  块里三行：对方的角色、设置/取消禁言、设为/取消管理员（只有我是群主才给），外加「移出群聊」。
- 与老端不同（刻意的）：`manageRole` 缺失 / 认不出来时**不显示**这块（老端 `undefined < 3` 是假，
  行为一致，但这里显式写出来，免得哪天当成 0 就把权限放开了）。

**五、检查更新（S7.2）—— 这一件最大**

- 链路照老端 `common/appUpdate.js`：读本机版本 → `POST /common/pub/checkVersion`
  （注意这接口**不在 `/enterprise` 下**，是公开接口）→ 服务端回 `{versionName, versionCode,
  versionInfo, updateType, downloadUrl}` → **没有 `downloadUrl` 就是没有新版本**。
- 两个入口：**启动时**（`home_shell`，`setupPage: false`，没新版本一声不吭）与
  **「我的 → 检查更新」**（`setupPage: true`，没新版本提示「暂无新版本」）。启动那次一个进程只查一次
  （老端每次 `onShow` 都查，太吵）。
- `updateType` 三档：`forcibly` 强制（弹窗没有「暂不升级」、遮罩点不掉、返回键也关不掉、下载中也不给取消）、
  `solicit` 弹窗确认、`silent`。地址后缀决定怎么装：`.wgt` → uni-app 资源包、`.html` → 浏览器、
  其它 → 安卓下载后交给系统安装器（iOS 一律丢浏览器，App Store 的更新不能由应用自己装）。
- 与老端不同（刻意的三处）：
  1. **`silent` 也弹窗确认**：老端的静默更新装的是 `.wgt` 资源包（能悄悄换掉界面资源），
     而安卓的 APK 必须由用户在系统界面点确认 —— 偷偷下几百兆却不给装，只会白烧流量；
  2. **`.wgt` 直接跳过并说明原因**（本客户端装不了那个包）；
  3. **安装完成后的提示说实话**：老端弹「应用资源更新完成！」，那是 `.wgt` 才成立的说法；
     APK 只是交给了系统安装器，用户可能直接在系统界面按了取消，所以这里说
     「升级包已交给系统安装器，请在系统提示里完成安装」。
- 已知偏差（没做，等你要）：老端那个下载弹窗是「取消 / 后台下载」两颗按钮，
  本客户端只做了「取消」（关掉弹窗就中断下载）。要做「后台下载」得让下载撑过弹窗被关、
  App 被切走，并在结束时通知 —— 那是另一条链。
- 平台能力抽成 `AppInstaller`（下载 / 交给安装器 / 开浏览器），与 `MediaSaver` / `CallKeepAlive` 同一套路。
- 版本号读法：**没用 `package_info_plus`** —— 它要 `win32 ^5.5.3`，而 `file_picker` 那条链要
  `win32 ^6.3.0`，两边解不开（`flutter pub get` 直接失败）。为此在 `MainActivity.kt` 里加了十几行
  小通道（`gracelinkim/app_info`）读 `PackageManager`，读不到时退回 `profile_form.dart` 里那个常量。
- 清单补 `REQUEST_INSTALL_PACKAGES`（老端 manifest 里也有）。

**这一轮的测试（+42，共 1015）**：版本模型与分流 14 条（`test/core/app_update_test.dart`）、
仓库 4 条（钉 `release`/`version`/`setupPage`/`type` 与「没有 downloadUrl 就是没有新版本」）、
整条界面链 14 条（`test/features/app_update_flow_test.dart`，用假安装器：进度 / 取消 / 下载失败 /
安装器没拉起来 / 强制更新不给取消 / `.wgt` 跳过 / `.html` 丢浏览器）、
「我的」页点一下真的发请求 1 条、扫码登录页与守卫各若干。

**这一轮之后的待办（以 IM 6.2.0 为准）**：朋友圈（老端自己就是静态模板 + 假数据，
**判定为不需要实现**，占位页保持）、多语言收尾与文案校对（S7.3）、锁屏来电整屏弹（S6.6）、
离线推送与来电唤醒（S8.1，要后端配合）。还有两处小的：老端那 292 个 `cuIcon` 还没抽成字体、
「后台下载」那颗按钮（见上）。

### S4.0b 消息通知（系统通知栏）—— 已装真机待验（2026-09-20）

**目标**：达到**官方 4.0.1+ 那套**的效果 —— 服务端走已有的 WS 把消息推下来，
**客户端自己建通知栏**（老端靠 uni-app 的 `push` 模块 `uni.createPushMessage`；
Flutter 端的等价物就是系统本地通知）。这也正是后端 `[UNIPUSH] IS_FORCE=false`
那句注释的含义：「app 接收后再创建通知栏」。

**分成三层，各自可测**：

| 文件 | 职责 |
|---|---|
| `domain/chat/message_notification.dart` | **纯逻辑**：这条消息要不要弹、弹什么（标题/内容） |
| `core/notify/message_notification_presenter.dart` | 平台能力：建渠道、申请权限、弹、清、接点击（接口 + `flutter_local_notifications` 实现） |
| `domain/chat/message_notifier.dart` | 决策：**前台**响提示音、**后台**弹系统通知（两边都守「自己发的不提醒 / 免打扰不提醒」） |
| `core/platform/app_foreground.dart` + `features/notify/notification_host.dart` | 前后台跟踪、点通知进会话、冷启动补跳（挂在 `MaterialApp.builder`，与 `CallHost` 同一层） |

**弹通知的条件**（照抄老端 `App.vue::createPushMsg`）：
`!appStatus && data.fromUser.id != userInfo.user_id && contact.is_notice == 1`
—— 即**后台 + 不是自己发的 + 会话没免打扰**。内容：标题取会话名（群名/对方昵称），
正文群消息带「发送者: 」，非文本用类型占位（`[图片]` / `[音视频通话]` …）。

**与老端刻意的三处不同**：
1. **后台不再「又响又弹」**：老端不管前后台都 `playSound()`，后台还额外建通知栏，
   于是响两次；新端前台只响、后台只弹（通知自带的系统声音）。
2. **系统消息也能弹**：老端那条判断要 `contact`，系统消息没有会话对象，永远弹不出来；
   新端标题退回「系统通知」（与通讯录里那一行同名）。
3. **通知权限在进主界面时要一次**（老端是登录后弹层），只问一次，被拒之后靠系统设置。

**真机上踩的两个坑**（都会让通知静默失效，记下来省下次）：
1. `flutter_local_notifications` 要求开**核心库脱糖**：`android/app/build.gradle.kts`
   里 `isCoreLibraryDesugaringEnabled = true` + `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")`，
   否则 `:app:checkReleaseAarMetadata` 直接失败。
2. **release 的资源压缩会把通知图标删掉**：`ic_notification` 只被 Dart 字符串引用，
   压缩器看不到 → `resources.txt` 里写着 `is not reachable`，APK 里没有这个资源，
   真机上 `initialize` 抛 `PlatformException(invalid_icon ...)`。
   修法：`android/app/src/main/res/raw/keep.xml` 里 `tools:keep="@drawable/ic_notification"`。
   （通话那个 `ic_call_notify` 没这问题，因为它在 Kotlin 里被 `R.drawable` 引用了。）

**这一轮的测试（+20，共 1035）**：纯逻辑 13 条（前后台 / 自己发的 / 免打扰 / 群消息带发送者 /
HTML 与表情 token 剥离 / 类型占位 / 通话类型 / 系统消息兜底）、
决策 5 条（前台响、后台弹、骚扰门槛两条、群消息）、宿主 3 条（前后台跟踪、
点通知进会话并清通知、冷启动补跳）。

**还没做的天花板**：进程被系统杀掉后 WS 断 → 一条都收不到（老端也一样，它靠保活插件硬撑）。
要「进程被杀也能收到」必须上厂商通道（FCM / 个推 / 华为…），那是下一步；
通知展示这一层到时候**原样复用**。

### S8.0b 「别让系统把你杀掉」的两道开关引导（2026-09-20）

**为什么这一步不能省**：S4.0b 那条通知链（WS 收消息 → 客户端建通知栏）**只依赖一件事
——进程活着**。而安卓上有两道系统开关会把这条链掐掉，而且**用户在自己的设置里根本
想不到它们跟「收不到消息」有关系**：

| 开关 | 关着会怎样 | 老端的提示文案 |
|---|---|---|
| 通知权限（`POST_NOTIFICATIONS`，13+） | 消息落库了、提示音响了，**通知栏里什么都没有**，锁屏状态下用户不知道有人找他 | `system.notNotify` |
| 电池优化（没加白名单） | 切后台几分钟进程就被冻结，WS 断开，**连消息都收不到**（要等下次打开才补） | `system.notBattery` |

老端在消息列表顶部用两条 `uni-notice-bar` 提示（`pages/message/index.vue` 第 26/27 行，
红字 `#F56C6C` + 粉底 `#fde2e2`），本端照做。

**分层（与 `CallKeepAlive` / `MediaSaver` 同一套路，平台能力可替身、决策可单测）**：

| 文件 | 职责 |
|---|---|
| `core/platform/background_health.dart` | 平台能力：查通知权限 / 查电池白名单 / 跳通知设置页 / 申请白名单（接口 + 安卓实现 + Noop） |
| `domain/notify/system_health.dart` | **纯逻辑**：两条开关 → 该显示哪条提示（`resolveSystemHealthHint`）+ 状态 provider |
| `features/notify/system_health_banner.dart` | 界面：列表顶上那条红提示条 |
| `MainActivity.kt` 的 `gracelinkim/app_settings` 通道 | 四个新方法（`notificationPermission` / `openNotificationSettings` / `isIgnoringBatteryOptimizations` / `requestIgnoreBatteryOptimizations`） |

**几个刻意的决定**：

1. **一次只显示一条，通知优先**（老端那对 `v-if` / `v-else-if` 的等价写法）。通知没开
   比电池更致命：电池问题导致「收不到」，通知问题导致「收到了你也看不见」。
2. **查询失败一律算「正常」**。通道不在（桌面/测试）、ROM 抽风时都不能拿一条**误报**
   的红提示条去烦用户 —— 宁可漏报。
3. **正常时「不占位」**（`SizedBox.shrink()`）而不是留个空条：查询本身是异步的，
   先闪一条错提示再收回去比什么都不显示更糟。
4. **回到前台自动重查**（`SystemHealthNotifier.build` 里 `ref.listen(appForegroundProvider)`）：
   用户点提示条去系统设置里改完回来，提示条必须**自己消失**（老端是在 `App.vue` 的
   `onShow` 里重查的）。切到后台那一刻**不查**。重查期间**不置 loading**，否则提示条会闪一下。
5. **通知那条跳「通知设置页」而不是弹系统授权框**：进主界面时已经问过一次（S4.0b 的
   通知权限引导），用户当时拒绝之后系统不会再弹框，只能去设置里手动打开。
6. **电池那条先试 `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`**（系统弹确认框，用户点一下
   就完事），弹不出来（部分 ROM 直接抛）才退到电池优化列表页，再不行退到应用详情页。
   这与老端一致（老端调 `keepAlive.requestIgnoreBatteryOptimizations()`）。
7. **不给「暂不处理」关闭按钮**：与老端一致 —— 这两道开关用户是能改的，
   提示条存在的意义就是**一直在那儿**直到改掉。

**这一轮的测试（+15，共 1050）**：纯逻辑 2 条（优先级、`ok`）、
状态 provider 5 条（首查 / 切回前台重查 / 切后台不查 / 点提示条各去各的页并重查 / `none` 不动）、
平台契约 4 条（方法名与语义 / 查不出来算正常 / 跳转失败不抛 / Noop）、
界面 4 条（都正常不显示 / 通知那条 + 点了跳通知设置 / 电池那条 + 点了申请白名单 /
两道都没开只显示通知那条）。

**真机现状（2026-09-20，三星 S23 Ultra）**：通知权限已授（那条不显示），
**电池白名单里没有本应用** → 进消息列表应当看到「省电优化」那条红提示条，
点一下 → 系统确认框 → 回来提示条自己消失。

**这条路的剩余天花板**（照旧）：白名单/自启动**降低**了被杀的概率，但国产 ROM 的省电
策略仍可能清进程。真要做到「进程被杀也能收到」只有厂商通道（S8.1：FCM 海外 + 个推国内），
那时这一层（通知展示）原样复用，只是「消息怎么到达设备」换了一条腿。

### S8.1 真推送（FCM 先行）—— 后端已完成，等测试服务器联调（2026-09-20）

**为什么要真推送**：S4.0b 那条通知链（WS 收消息 → 客户端建通知栏）**只依赖进程活着**。
进程被杀就一条都收不到（老端靠保活插件硬撑，撑不住就没了）。
「进程被杀也能收到」只有厂商通道能解决 —— 这就是 S8.1。
FCM 先做，是因为它文档最好、调试最容易，用它把**整条架构**（拿 token → 上报 →
后端按下发 → 客户端建通知 → 点击跳会话）验一遍；个推（国内无 GMS 的机器）随后，
客户端与后端都按同一套接口加。

**范围（这一轮）**：单聊消息 + 来电；**群聊扇出留到后面**（默认关闭，见下"已知边界"）。

#### 一、契约（客户端要按这个实现，后端已经按这个写好并在本地单测里钉住）

| 项 | 约定 |
|---|---|
| 设备标识 | **`<provider>:<token>`**，如 `fcm:xxxxx` / `getui:xxxxx`（后端按前缀分流） |
| 上报方式 | **沿用老端已有的 `cid` 字段**（登录时的 header `cid`、以及 `POST /common/Pub/bindUid` 的 `cid` 参数）—— 接口与表结构都不改 |
| 没有前缀的值 | 后端认不出来 → 只记一条日志、不落库（老端那种 uniPush 的 cid） |
| 下发形式 | **只发数据消息**（`message.data`），通知栏由客户端创建（免打扰/前台不弹/群消息带发送者这些规则都在客户端） |
| 优先级 | `android.priority = high`（低优先级在 Doze 里会被攒着）；来电额外带 `ttl=30s` |

数据消息里这几个字段（FCM 的 data **只接受字符串值**）：

| 字段 | 含义 |
|---|---|
| `title` | 通知标题（发送人昵称） |
| `content` | 通知正文（文本消息是内容，其它是 `[图片]` 这类类型文案，已剥 HTML） |
| `type` | `simple` / `webrtc` … |
| `event` | `webrtc` 才有：`calling` |
| `contact_id` | 点通知要进哪个会话（单聊是对方 uid，群聊是群 id） |
| `msg_id` | 消息 id（客户端用来去重） |
| `payload` | 整条消息的 JSON（与 WS 那份同构，客户端可直接复用现有解析）；**超过 3KB 会被丢掉**（只留预览） |

#### 二、触发规则（后端已改）

`Message::sendMessage` → `wsSendMsg` 那条链一个字没动，只改了 `wsSendMsg` 里"要不要推"：

* **只推给当前没有 WS 连接的接收者**（在线时客户端自己会弹通知，两边都推会重复提醒）；
  开关 `.env` 的 `[PUSH] ONLY_OFFLINE`（默认 true）。
  ⚠️ 已知代价：如果连接**僵死**（进程被冻住但 WS 还没超时），会出现"不推也不弹"。
  彻底解决要等服务端"发出去后若干秒没收到 ack 再补一条推送"（走队列延迟任务）—— 列为 P2。
* 来电（`webrtc` + `extends.event=calling`）照旧走推送。
* **群聊还没扇出**（老端也没有，官方文档说要"其他付费服务"）。要做时是：群成员 - 发送者 -
  该群免打扰的人 → 逐个查设备下发，默认关。

#### 三、后端落地（`raingad-im-6.4.1` 那份代码）

新增 `app/common/push/`（**纯 PHP、不依赖 ThinkPHP**，就是为了能在本地单测）：

| 文件 | 职责 |
|---|---|
| `DeviceToken.php` | 解析 `provider:token`、算数据库唯一键用的 sha1 指纹、日志用的短标识 |
| `PushMessage.php` | 标题/正文/数据负载组装（正文剥 HTML、截断 50 字；超长 payload 丢弃） |
| `PushResult.php` | 成功 / 可重试失败 / **设备失效**（只有失效才停设备） |
| `HttpClient.php` + `CurlHttpClient.php` + `HttpResponse.php` | 极小 HTTP 客户端（**带状态码**、**默认校验证书**） |
| `PushProvider.php` | 服务商接口（`name` / `configured` / `send`） |
| `ServiceAccount.php` | 服务账号解析 + JWT(RS256) 签名 |
| `FcmProvider.php` | 换 access_token（三层缓存：进程内 → Redis → 现取）、`messages:send`、错误映射、401 自动换 token 重试一次 |
| `PushManager.php` | 按前缀分发 + 汇总（不碰数据库、不打日志，便于单测） |

改动的现有文件：

* `app/common.php`：`bindCid()` 改成落库（原来 POST 到**已废弃**的 uniPush 云函数，等于空转）；
  `unipush()` 改成"查设备 → 组装 → 分发 → 停失效设备"；
  新增 `pushManager()`（按 `.env` 装配服务商，进程内只装一次）；
  `wsSendMsg()` 加"离线下发"判断。
* `app/enterprise/model/UserDevice.php`（新增模型）：`bind()` / `tokensOf()` / `markInvalid()`。
* `public/sql/6.4.1 升 6.4.2.sql`（新增）+ `public/sql/database.sql`：`yu_user_device` 表
  （唯一键是 `token_hash` = sha1，避免 FCM token 200 字符做唯一索引的长度问题）。
* `example.env`：新增 `[PUSH]` 段（`ENABLE` / `ONLY_OFFLINE` / `FORCE_NOTIFICATION` /
  `FCM_SERVICE_ACCOUNT(_FILE)`），并给已废弃的 `[UNIPUSH]` 加注释。
* `tools/push_selftest.php`（新增，**78 项断言**，不需要数据库/网络/凭据）：
  `php tools/push_selftest.php`
* `tools/push_check_fcm.php`（新增，联调用）：先单独验凭据那一跳，再验真下发
  （`php tools/push_check_fcm.php service-account.json [设备token] [message|call]`）

本地环境：装了一个 **PHP 7.3.33 命令行**（`D:\coding\tools\php73`，免安装 zip，项目外）
专门用来 `php -l` 与跑上面那个自检 —— 后端所有文件 lint 干净、自检 78 项全过。
⚠️ 本机没有 MySQL/Redis，所以「消息落库 → 触发推送」那段**集成链只能在测试服务器上验**。

#### 四、客户端还差的（下一步做）

1. `PushTokenSource`（可插拔：FCM / 个推 / 空实现）+ 把 token 填进登录时那个
   **目前恒为空**的 `cid`（`session_service.dart::_bindAfterInit` 里已经在上报了）；
2. 收到 FCM 数据消息 → 交给已有的通知层建通知（**同一套代码**，与 WS 那条路共用）；
3. 冷启动/后台 isolate（应用被杀时被推送拉起）→ 初始化最小环境 → 建通知；
4. 点击通知 → 进对应会话（`contact_id`），落地由已有的路由与通知点击逻辑复用。

#### 五、已知边界（都要记着）

* **FCM 只覆盖有 Google 服务的机器**：国产 ROM（华为/小米/OPPO/vivo/荣耀）收不到 →
  必须再上个推/厂商通道（客户端与后端都按同一套接口加，见上面契约）。
* **登出不解绑设备**（P2）：登出后该设备仍会收到推送（消息内容会出现在通知里）。
  要修得把设备标识也带上登出请求，或给绑定加一个"与 client_id 关联"的字段。
* **同一台设备换账号登录**：后端直接把该行 `user_id` 改掉（不会把消息推到上一个用户）。
* 推送失败**绝不影响发消息本身**（后端整个链都在 try/catch 里，只记日志）。

#### S8.1b 顺手修掉的一个安全洞：`/common/Pub/bindUid` 无鉴权（2026-09-20）

**洞**：`app/common/controller/Pub.php` 的 `bindUid()` 原来**完全不看 token**，
`user_id` 直接取请求参数（`Pub.php:236`），而 `Pub` 这个控制器没挂任何中间件
（只有 `Upload` 挂了 `checkAuth`）。它的作用是把一条 WebSocket 连接（`client_id`）
绑到某个 uid 上 —— 也就是**任何人只要知道别人的 uid，就能把自己的一条连接绑成他，
从而收到发给他的消息**。上游 6.4.1 的遗留，不是本次推送改动引入的。

**改法**（只动这一个接口，不动 CheckAuth 中间件）：给 `bindUid()` 加"只允许把自己绑到自己"，
并新增一个 `currentUserId()`（从 token 解 uid，失败返回 null 而不是中断响应；
逻辑与 `CheckAuth` 一致）。

**为什么两个客户端都不受影响**：老端 `utils/request.js` 与 Flutter 端 `ApiClient`
都带 `Authorization` 头调这个接口，而且传的都是自己的 uid；Flutter 端 `_bindAfterInit`
本来就有 `on ApiException catch`（失败只记日志、不弹提示，也不会继续发 WS 那条 bindUid）。

**顺带核过、不用改的两处**：
* `app/enterprise/controller/Im.php:205` 那个 `Gateway::bindUid` 用的 uid 来自
  **已鉴权的 token**（enterprise 应用整体挂了 `checkAuth`），是安全的；
* `Pub::offline()` 同样没鉴权，但影响只是"能替别人广播一条离线状态"，级别低得多 ——
  列为 P2。

#### S8.1c 客户端推送（token → 上报 → 后台弹通知）（2026-09-20）

上面「四、客户端还差的」那四项，这一轮全做完了。分成三块：

**1. 设备标识的来源（`core/platform/push_token.dart`）**

`PushTokenSource` 接口 + 两个实现：`FcmPushTokenSource`（Firebase，覆盖海外/带 GMS 的机器）
与 `NoopPushTokenSource`（桌面/测试，没有推送通道）。上报形态沿用老端那个 `cid` 字段，
值加上服务商前缀：`fcm:xxxx` —— 后端按前缀分流（`PushManager`），所以以后接个推就是
「多一个实现 + 多一个 `provider`」，客户端其它地方一行都不用改。

三个细节：Firebase 初始化**失败也缓存**（缺 `google-services.json` 这类问题不会自己
变好，重试只会刷日志）；拿不到 token **不抛异常**（推送拿不到不该影响登录与收发消息）；
日志里只出现 token 的前 8 位（完整 token 等于一把给别人推送的钥匙）。

**2. 登记（`domain/notify/push_registrar.dart`）**

`PushRegistrar` 把「拿标识 → 落盘成 `cid` → 上报服务端」串起来，三件事都是注入的回调，
所以能纯单测（8 条）。两处刻意：**标识没变就不上报**（设备表本来按标识去重，
每次启动都报一遍只会刷日志）；**先落盘再上报**（上报请求本身要带 `cid` 头）。

接线（`session_service`）：启动、登录、连接就绪各跑一次 `ensure()`；`_bindAfterInit`
在 bindUid 前最多等它 2 秒 —— 这样「登录 → 绑定」那一步就把 `cid` 带上了，
不用等下次连接；token 轮换（`onTokenRefresh`）也会自己补报一次，不用重启 App。

**3. 推送 → 通知（`core/notify/push_background.dart`）**

服务端只发**数据消息**，所以通知栏还是客户端画（`PushMessage::dataPayload()` 就是那份
契约）。App 没在跑时由 **后台 isolate** 里的 `firebaseMessagingBackgroundHandler` 画：
`DartPluginRegistrant.ensureInitialized()` → `Firebase.initializeApp()` → 读本地语言包 →
`PushNotificationHandler.handle(data)`。三条容易漏的：入口**必须是顶层函数**且带
`@pragma('vm:entry-point')`（release 会把「没人调用」的函数摇掉）、必须在 `runApp`
之前注册、后台 isolate 里插件与 Firebase 都要重新初始化一次。

通知内容走 `messageNotificationFromPush()`（纯函数，11 条单测），它与 WS 那条路
**共用同一套正文规则**：`payload` 里带着整条消息就用 `notificationBodyOf()`
（群消息带「发送者: 」、表情 token 剥掉、非文本用类型文案），标题优先取 `payload`
里 `contactInfo.displayName`（那才是会话名 —— 群聊要显示群名而不是发信人）；
`payload` 被服务端丢掉（太长）或解不出来时，退回服务端给的 `title`/`content`。
用户不该看出这条通知是「长连接来的」还是「推送来的」。

点击通知**不用新写代码**：后台那条通知用的是同一个渠道、同一个 `payload`（会话 id），
所以点击仍然走 `NotificationHost` 那套（`onDidReceiveNotificationResponse` + 冷启动
`getNotificationAppLaunchInfo`），与 WS 那条路完全一致。

#### S8.1d 这一轮之后，推送还差什么

1. **服务端凭据**：`[PUSH] ENABLE=true` + `FCM_SERVICE_ACCOUNT_FILE` 指向服务账号 JSON，
   并且 `tools/push_check_fcm.php` 要能拿到 access_token（这一步不通，前面全白搭）；
2. **群聊还不推**：`wsSendMsg()` 里只有单聊（`simple`）与来电（`webrtc` + `calling`）
   会走 `unipush()`，群聊扇出是后端的事（要遍历群成员、按 `group_user.is_notice` 过滤）；
3. **登出不解绑设备**（P2）：登出后这台设备仍会收到推送；要修就得把设备标识也带上登出请求；
4. **国内 ROM**：FCM 覆盖不到没装 Google 服务的机器，仍然要靠个推/厂商通道
   （客户端只需加一个 `PushTokenSource` 实现，后端加一个 `PushProvider` 实现）；
5. **iOS**：客户端这套已经按平台写好了（FCM 也能代发 APNs），`UIBackgroundModes`
   （`audio` + `remote-notification`）与推送到权限已经在 S12.43 里落地；
   现在缺的是 Apple 后台的 APNs Key + Firebase 里那个 iOS 应用（要开发者账号）。

#### S8.1e 热修：开了 ENABLE 之后消息不实时、通知消失（2026-09-20）

**现场**：`.env` 里把 `[PUSH] ENABLE` 改成 `true`（并把服务账号路径填上）之后，
对方发来的消息**不再实时到达**（手动刷新又能看到 —— 因为消息其实已经落库），
通知栏也没有任何提示。

**原因两处，都是推送代码自己引入的。主因是第 1 条，它跟 `[PUSH] ENABLE` 开关无关**
（现场把开关关回 `false` 仍然不实时 —— 这一点把范围直接指到了「发出消息前多做的那一步判断」上）：

1. **把数组当 uid 传给了 Gateway（主因）。** `wsSendMsg()` 里加的“在线就不推”判断写的是
   `Gateway::isUidOnline($user)`，而单聊那条 `$user` 是**数组** `[接收者, 发送者]`
   （见 `Message::sendMessage`）。`Gateway::isUidOnline()` 只接受单个 uid，
   数组最终进了 `GatewayProtocol::encode()` 里的 `strlen($data['ext_data'])`
   —— 对数组调 `strlen` 会报 **E_WARNING**。

   致命的不是“判断结果不对”，而是**这个警告会变成一个被吞掉的异常**：
   ThinkPHP6 的 `think\initializer\Error::appError()`（开头就 `error_reporting(E_ALL)`）
   把警告**直接抛成 `think\exception\ErrorException`**，它继承 `think\Exception`
   → `\Exception`，于是正好被 `wsSendMsg()` 外面那层 `catch(\Exception){ //忽略错误 }`
   接住 —— **同一行之后（也就是函数末尾）的 `Gateway::$send()` 再也没执行过**，
   消息压根没送出去。注意方向：异常在 `encode()` 里就抛了，所以**报文根本没发到
gateway**（一开始我怀疑是把内部报文的长度字段写坏了、连接卡死，**这个方向是错的**，
   已在本机用服务器同款 PHP 7.3 + 本项目自带 vendor 逐句复现推翻了）。

   于是：**单聊消息不实时送达**（手动刷新能看到，因为已经落库），而通话信令
   （offer/answer/hangup）、群消息、`syncUnread` 照常 —— 只有单聊那条分支会走到这句。
   复现与回归断言都在 `tools/push_selftest.php`（自检 84 → 87 项，多了三条：
   `encode()` 遇数组会告警 / 该警告被抛成 `ErrorException` / `catch(\Exception)` 后的送达一步不执行）。

2. **推送排在「送达」前面，而且同步跑。** `wsSendMsg()` 第一版是
   `if (单聊/来电) { unipush(...) }` 然后才 `Gateway::$send($user, $message)`。
   而 `unipush()` 要连 Google（换 access_token + 下发 = 两次 HTTPS，服务器出不了
   外网时每次都要等到超时，10 秒 × 2）。就算第 1 条修好了，这条也会让每条消息
   晚十几秒送达，发消息的人也在陪着等 —— php-fpm 工作进程被占满之后，
   连「已读上报」这类普通接口都开始回“服务器繁忙”。

**改法**（对应用户侧那份「推送热修」包）：

* `wsSendMsg()`：**先** `Gateway::$send()` 送达，**再**考虑离线推送；catch 改 `\Throwable`；
* 新增 `pushOffline()`：只挑不在线的人推；来电例外（在线也推）；群聊仍不推（S8.1d 第 2 条）；
* 新增 `pushAfterResponse()`：推送挪到**响应发完之后**（php-fpm 里
  `fastcgi_finish_request()` 之后再推；CLI/Workerman 没有“响应”可结束，只能直接推）；
* 新增 `app\common\push\PushTargets::pick()`：在线判断**逐个 uid** 问，
  并把“不会把数组整个传下去”钉成一条回归单测（自检 79 → 84 项）；
* `unipush()` / `bindCid()` 的 catch 从 `\Exception` 换成 `\Throwable`；
* FCM 超时 10s → 6s、连接超时 5s → 3s；新增可选 `[PUSH] HTTP_PROXY`
  （国内机房直连 googleapis 常常不通）。

**不需要重启 WS 服务**（GatewayWorker）：那条内部连接是每次调用新建的
（`getBufferFromGateway()` 里 `stream_socket_client` 一发一收就关），没有“卡住”的状态，
换代码即生效 —— 之前以为要重启的那一步，是建立在错误机制上的，**删掉**。
真正需要的是**重载 PHP**（php-fpm / opcache）：`opcache.validate_timestamps` 或
`revalidate_freq` 会让新代码晚几秒到无限期才生效，重载一次最省事。

**教训（写给以后的自己）**：推送、埋点、日志这类「锦上添花」的副链路，
**永远不能排在主链路上** —— 顺序上放最后，异常上兜 `\Throwable`，
耗时上要么丢到响应之后、要么压到能接受的超时。这三条里第一条就足以让
“加功能”变成“功能全挂”。

**还没确认的**：这台服务器（message.gracelink.cc）到底能不能出网到 Google。
`tools/push_check_fcm.php` 一跑就知道；不通就得配 `HTTP_PROXY` 或改走个推。

#### S8.1f 现场核对：整站下载对照（2026-09-20）

用户把线上整站（`/www/wwwroot/gracelinkim`）打包下载回来核对，结论是**补丁只上了一半**：

| 项 | 现场状态 | 说明 |
| --- | --- | --- |
| `app/common/push/`（10 个文件） | ✅ 已上 | 但缺 `PushTargets.php` |
| `app/enterprise/model/UserDevice.php` | ✅ 已上 | |
| `gracelink_user_device` 表 | ✅ 已建 | 前缀已按用户的 `gracelink_` 改对 |
| `.env` 的 `[PUSH]` 段 | ✅ 已加 | `ENABLE=false`、服务账号路径已填 |
| `app/sql/6.4.1 升 6.4.2.sql` | ✅ 已放 | |
| **`app/common.php`（S8.1e 的修）** | ❌ **没上** | 现场仍是「先推后送 + 数组传 uid」那版 —— **这就是消息不实时的直接原因** |
| **`app/common/push/PushTargets.php`** | ❌ **没上** | 上面那版引用的新文件 |
| `CurlHttpClient` / `FcmProvider` / `ServiceAccount` | ❌ 是旧版 | 少代理、超时还是 10s/5s、报错信息还是旧的 |
| `tools/push_selftest.php` | ❌ 是旧版（78 项） | 少 9 条含回归的断言 |
| `app/common/controller/Pub.php` 的 `bindUid` 鉴权（S8.1b） | ❌ **没上** | 安全修，与本次故障无关，可另传 |

**落地方式**：`C:\Users\David-local\Downloads\raingad-push-fix2.zip`
（`app/common.php` + 整个 `app/common/push/` + `tools/`，解压到项目根目录覆盖）。
含「上传什么 / 上完怎么验 / 回退」的说明。

**教训**：补丁分次发、且其中一次只发了「新增文件」没发「被改的既有文件」，
会造出「代码上去了但主链路断了」这种最难查的现场。以后每次改动都按
**同一个包、同一份清单**发，并在包里放一条不依赖数据库的自检命令让用户当场跑。

#### S8.1g 排障：杀 App 后收不到推送（2026-09-20）

修完 S8.1e/S8.1f 之后**在线消息已恢复正常**，剩下的问题是「杀掉 App 收不到 FCM 推送」。
为此补了两样东西（包：`raingad-push-diagnose.zip`，2 个文件）：

* **`tools/push_diagnose.php`（新增）**：一条命令按顺序走完整条链并给结论 ——
  `[1] .env 的 [PUSH] 配置 → [2] 设备表里有没有在册的 fcm 设备 → [3] 真的换一次
  access_token（= 验服务器能不能出网到 Google）→ [4]（--send）真发一条并打印 FCM 原文响应`。
  它自己按 `think\Env` 的规则解析 `.env`（`parse_ini_file` + `INI_SCANNER_RAW` +
  `SECTION_KEY` 拍平 + true/false 转换），所以看到的就是框架看到的。
* **`unipush()` / `pushOffline()` 的三处静默返回补上日志**：以前「开关没开」
  「设备表里没设备」这两种情况**一行日志都不写**，排障时完全看不出卡在哪；
  现在分别写「未启用或没有可用服务商」「接收者没有在册设备」，
  并且接收者在线时也写一行「接收者在线，按 ONLY_OFFLINE 跳过下发」。

**最容易被误判成故障的一条**：`ONLY_OFFLINE=true` 时，服务端要等**心跳超时**才知道
对方掉线（几十秒到一两分钟）。刚把 App 划掉就发消息，很可能被判定成「在线」而不推 ——
这是设计使然，不是坏了。日志里那行「接收者在线…跳过下发」就是用来区分这一点的。

#### S8.1h 服务端：离线来电不再被改写成「忙线」（2026-09-20）

**现场**：对方 App 被杀时打电话，主叫**秒收到「对方不在线」**，被叫手机**毫无反应**。
根因在服务端（`Im.php::sendToMsg()`）而不是推送：

```php
if(!Gateway::isUidOnline($toContactId)){       // 逐帧判断
    $toContactId = 我;  $code=907;  $event='busy';  sleep(1);
}
```

四个后果，其中第 3 个最要命：

1. 被叫**连 `calling` 帧都收不到**，自然不响；
2. 来电推送挂在 `event=='calling'` 上，事件已被改写成 busy →
   **推送永远触发不到**；于是出现最讽刺的局面：来电推送只在你**在线**时才发得出去
   （也就是只在不需要它的时候）；
3. 它是**逐帧**判的 → 通话中途一方切网/被冻一下，对方发来的 offer / answer / ICE
   会被改写成「忙线」发给发起人，而客户端收到 907 就挂断 ——
   真机上「接通的那一下断掉」的偶发就是它；
4. 主叫超时发的 `hangup` 同样被改写 → 下面「更新通话记录」那段被跳过 →
   **离线那一通在聊天列表里没有任何痕迹**。

**改法**（包：`raingad-offline-call-server.zip`，5 个文件）：

* `Im.php`：只在「叫号 + 对方离线 + 对方一台可推设备都没有」时才回忙线；
  其余一律照原样发出去（网关会静默丢弃），唤醒交给推送。删掉 `sleep(1)`。
* `PushTargets::blockOfflineCall($event, $isOnline, $hasDevice)`：把判据抽出来，
  `$hasDevice` **收闭包**（惰性），所以在线通话不会多查一次设备表；
  自检从 87 项 → **98 项**，其中一条专门钉「除 calling 外任何一帧都不许拦」。
* `UserDevice::hasUsableDevice($uid)`：失败时按「有设备」处理 ——
  宁可让主叫多等，也不能把推得着的人当成推不着。
* `FcmProvider`：来电 TTL `30s → 60s`，与接下来的客户端等待窗口对齐。

**协议事实（这轮核出来、以后别再绕）**：`calling` 帧**不带 SDP**。真正的 offer/answer
是**被叫接听之后**才开始的（主叫收到 `acceptRtc` 才 `CreateOffer()`），
所以：
* **不需要**“服务端暂存信令 / 上线补投”那套机制；
* 离线来电的唯一难点是**时间窗口**（对方要在主叫放弃前被唤醒、连线、接听），
  以及**别在自己这边把帧掐掉**（本次修的就是这个）。

**待做（客户端那半）**：来电通知走独立渠道 + 全屏/响铃、从通知冷启动进来电页、
「接听」等长连接就绪、等待窗口 40 → 60 秒、对方上线时补发一次 offer。

#### S8.1i 客户端：被推送叫醒的来电（2026-09-20）

服务端那半（S8.1h）上完并验通过后，客户端这半补齐。改动分三条链，**新增 3 个文件**：

**① 后台 isolate 画的是「来电通知」，不是消息通知**

* `IncomingCallNotification` + `showIncomingCall() / cancelIncomingCall()`：
  **独立渠道** `gracelinkim_call`（`importance: max`、`category: call`、
  `fullScreenIntent: true`、`ongoing`、响应后 45 秒自动超时）、固定通知 id。
  与消息那条渠道刻意分开：用户在系统里静音「消息」时**不该把来电一起静音**。
* `push_background.dart` 里按 `webrtc + calling` 分流；来电那条通知的 `payload`
  放的是**整条 `calling` 报文**（不是会话 id）—— 冷启动要靠它重建会话。
* 通知的标题/正文走**和会话列表同一套规则**（`ConversationRules.preview`，
  所以是 `[语音通话]` / `[视频通话]`，不是英文的 `[webrtc]`）。

**② 从通知进来电页，且**只留一条路**

* 新增 `CallPushHost`（挂在 `MaterialApp.builder`，与 `NotificationHost` / `CallHost` 同层）：
  接住「点来电通知」（App 活着）与「App 被来电通知拉起来」（冷启动）两条入口，
  解析成 `IncomingCallPush` 后交给 `CallSyncService.handlePushedCalling()` ——
  **和长连接同一个人口**（落库 + 状态机），绝不另开第二条逻辑。
  它不会和 `NotificationHost` 抢：那份 payload 是消息层**主动不接**的（在 presenter 里按形状分流）。
* 两道闸门：`isFresh()`（超过 50 秒的来电报文直接丢：主叫 60 秒就挂了，
  「响一秒对面已挂」比不响更烦人；**只卡上界**，两端时钟差几秒不该让你漏接）+ 同一通话 id 只处理一次
  （WS 先到、推送也到时会重）。
* 通话一开始（接听或结束）就把通知栏那条来电收掉（盯着 `session.phase`，
  不然接听完它还挂到 45 秒兜底超时）。
* `_awaitSession()`：冷启动那一瞬 `myUserId` 可能还是空串（本地会话还没恢复），
  那时状态机会把这通电话当成「别人的」丢掉 —— 最多等 2 秒。

**③ 状态机 / 控制器：把「叫他起来」这段窗口候住**

* `dialTimeoutSeconds 40 → 60`（与服务端那条来电推送的 TTL 对齐）。
* `incomingRingTimeoutSeconds = 45`：被叫侧**自己收场**的兜底。
  必需的场景：主叫超时后发的 `hangup` 到不了我们（我们刚被唤醒、长连接还没建好）。
  `ringTimeout()` **一枪信令都不发**（我们并不知道主叫还在不在等，乱发会搅乱多端场景）。
* `peerOnline()`：主叫在 `connecting` 阶段听到「对方上线了」就**原样重发一次 offer**
  （上线钩子用现成的 `isOnline` 事件，最多 2 次：幂等、防洪水）。
  修的是「他刚被唤醒时我们那份 offer 早发了、而且被服务端丢了」。
* 接听前等长连接就绪（被推送叫醒时急着发 `acceptRtc` 会把主叫随后的 offer 丢掉）。

**安卓层**：`USE_FULL_SCREEN_INTENT`（清单里本来就有）+ 新增
`BackgroundHealth.fullScreenIntentAllowed/openFullScreenIntentSettings`
（走已有的 `gracelinkim/app_settings` 通道；`MainActivity` 里用
`NotificationManager.canUseFullScreenIntent()`，安卓 14 以下恒为 true），
设置页多一行「来电全屏显示」—— 安卓 14 起系统只给通话类应用自动授权，
我们默认是关的；关着只是降级成横幅 + 响铃，所以这行**只放设置里**，
不进消息列表那条红提示条（那不是病，别去烦用户）。

**测试**：`incoming_call_push_test`(11) —— 认不认得出、还原得对不对、时效闸门；
`call_push_host_test`(5) —— 冷启动真的建出这通电话、超龄/非来电不接、同一条只建一次、
挂断后通知收掉；`call_machine_test` 补 7 条（补发 offer 的上限与条件、
响铃上限自收场且不发信令）；`push_background_handler_test` 补 5 条（来电走哪条通知、
payload 原样留存、超龄不弹、自己发的不弹、弹失败不炸）。全套 **1106 项通过**。

**没做**：不做「服务端暂存信令 / 上线补投」（协议上不需要，见 S8.1h）；
不碰 iOS（CallKit + APNs 另立一轮）；国产机无 Google 服务仍收不到（个推另立一项）。

#### S8.1j 服务端：群聊离线推送（2026-09-20）

到这一轮为止，离线推送只有单聊和来电两种 —— 群消息压根不走推送（`wsSendMsg()` 里
`if(!$isGroup)` 直接跳过）。补上它，**客户端 0 行**（推送→通知那条链本来就是按类型无关
写的，群消息会显示「群名 + 发送者: 内容」、点开进群会话，有单测钉着）。

**为什么扇出只能做在服务端**：App 被杀时画通知的是**后台 isolate**，它读不到数据库
（那里只有一个语言包和一份 `cid`）—— 所以「免打扰的群不弹」在离线这条路上没法靠
客户端兜。

**三道筛子**（`PushTargets::groupAudience()`，纯函数，可单测）：

1. 发送者自己不推（`unipush()` 里还会再排一次，双保险）；
2. **免打扰的人不推**（`chat_group_user.is_notice = 0`）。注意这条**优先于 @**：
   免打扰的群即使被 @ 也不推（要改成「被 @ 就推」，是把两个 `continue` 换个顺序的事）；
3. **只推被 @ 的人**（`.env` 的 `GROUP_ONLY_AT`，**默认关**）。`@所有人` 在
   `Message::sendMsg` 里已经被展开成「除发送者之外的全员」，所以这里不用管 0。

**其余四件**：

* `PushTargets::capAudience()`：单次扇出上限（`GROUP_MAX_AUDIENCE`，默认 **50**）。
  为什么必须有 —— `PushManager::sendTokens()` 是**逐个 token 一次 HTTPS**，而这批推送
  跑在每个发消息请求的收尾阶段，会占住一个 php-fpm 工作进程。截断**会写日志**
  （「已截断 N 人」），不会悄悄少推。
* 成员清单**一次查完**（`group_id + status=1 + delete_time=0`，顺带取回 `is_notice`）：
  群里几百人，逐个查库比逐个 `isUidOnline` 贵得多。
* 群消息的标题改取**群名**（`PushMessage::forChat`）：客户端优先用 payload 里的
  `contactInfo`，只有 payload 超长被丢掉时才回退到标题/正文 —— 那时写发送人名字
  会让人以为是私聊。
* 群消息用 **24 小时** TTL（`FcmProvider::$chatTtl`）：默认是 FCM 的 4 周，
  手机离线三天回来被一堆陈旧通知砸中毫无意义（消息本来就靠登录时的同步补上）。

**测试**：`tools/push_selftest.php` 98 → **125 项**（免打扰、只推被@、@所有人、
发送者排除、脏行、重复行、模型对象行、上限截断与不限、群标题、群 TTL）。

**没做**：FCM 的 batch 端点（一次 HTTP 推 500 个 token）—— 人多了那才是正解，
现在靠上限兜着；单聊的免打扰没过滤（`chat_friend.is_notice`，要单独说一声再做）。

#### S8.1k 真机故障：被推送叫醒的来电「响一声就断、界面卡死、点接听没反应」（2026-09-20）

**现场日志**（三星 S23，离线来电叫醒后点接听）：

```
Unhandled Exception: Cannot use the Ref of Provider<CallController>#0afa2
                        after it has been disposed
  #3  CallController.accept → call_controller.dart:353
  #4  _CallPageState._controlsRow → call_page.dart:481   ← 用户点的那一下
```

**根因不是推送，是 provider 的依赖图**：`callMediaEngineProvider` 当时是
`ref.watch(sessionStoreProvider)` —— 盯的是**整份**会话状态，而
`callControllerProvider` 又 watch 了引擎。于是**任何**会话变化都会把正在进行的
通话整个重建：控制器 `dispose()`（里面会 `tones.stopRing()`、关媒体、`view.dispose()`）。

冷启动那一路恰好每次都会命中：App 起来 → WS 连上 → 服务端发 `pong`（带多端标记）
→ `applyMultiport` 造出一份新的 `SessionState` → 引擎重建 → **通话刚响一声就被拆掉**。
由此一次性解释了四个现象：

| 现象 | 解释 |
|---|---|
| 响铃 1 秒就断 | 控制器被 dispose，`dispose()` 里停了铃声 |
| 界面卡死、按钮不响应 | 通话页挂在**旧**控制器上再也不更新（`CallHost._attach` 只把 `_open` 清零，不会 pop 旧页） |
| 点接听毫无反应 | 回调里迟到的 `ref.read(wsServiceProvider)` 撞上已销毁的 ref，当场抛异常 |
| 点挂断能真挂断但页面不动 | 旧控制器本身还能干活（信令照发），但界面没人 pop |

**四处修**：

1. `callMediaEngineProvider` 改成 `WebrtcCallMediaEngine.withLazyIceServers`：ICE 列表
   **建连接那一刻才读**，provider 不再盯任何会变的东西（与原来那句「热更新对下一通
   电话生效」语义完全一致）；
2. `callControllerProvider` 里信令服务改成**在 build 时取一次**存住，绝不把 `ref`
   带进回调里迟到才用；
3. `CallController._dispatch()` 加了**总闸** `if (_disposed) return;` —— 一条地方堵住
   「重建/登出之后还在飞的那些续点」（信令回执、媒体回调、计时器、推送叫醒的来电）；
   `accept()` / `hangup()` 也各自加了早期返回；
4. `CallHost._attach()`：控制器被换掉时**顺手把旧页 pop 掉**（不能只清标记，那是
   界面卡死那一环）。

**回归保护**：新增 `test/call/call_provider_lifecycle_test.dart`（6 条）—— 「多端标记 /
改设置不会重建控制器」（这两条**在旧代码上一定是红的**，已验证）、「只有换账号才重建」、
「已放掉的控制器点接听/挂断/收信令都不抛」；`call_page_test` 加一条「换账号通话页跟着关掉」。
全套 **1113 项通过**。

#### S8.1l 真机故障：被叫一接听就「闪退」（2026-09-20）

S8.1k 修完之后铃声不断了，但**接通后一秒**App 回到桌面 —— 音视频都一样。
日志里**没有任何崩溃**（`am_proc_died` 全是 `remove task`），说明不是崩，
**是这一通电话被自己结束了**。真机日志（pid 21774，离线来电叫醒）：

```
14:42:51.164  [通话] 收到信令：calling code=901       ← 推送唤醒 → 来电页 ✓
14:42:54.474  前台服务起来了（说明接听成功、媒体已拿到）✓
14:42:54.799  [通话] 收到信令：otherOpt code=904      ← ★ 接通后 0.3 秒
14:42:55.105  [通话] 收到信令：offer code=901
14:42:57.153  [通话] 收到信令：hangup code=906
```

**根因在服务端协议的回声**：`Im.php::sendToMsg()` 末尾把 `acceptRtc` / `hangup`
改写成 `otherOpt` 再 `wsSendMsg($userInfo['id'], ...)` —— 收件人是**发送者的整个账号**，
`Gateway::sendToUid` 会发给该 uid 的**所有连接**，**包括刚发出这条信令的连接自己**。
于是：我们自己按下的「接听」在几百毫秒后变成一条 `otherOpt code=904` 回来，
而状态机里 `otherOpt` 是**无条件**结束（「同一账号的其它端已经处理了」）——
每通电话都在接通那一瞬间被自己关掉；通话页一关，从通知冷启动起来的 App
看起来就是「闪退」。

**为什么已有的那道「回声过滤」没拦住它**（`im.php` 是服务器的，客户端是 `remote()` 开头那段）：

```dart
if (signal.isEchoOf(myUserId)) {        // ✓ 回声确实被认出来了（fromUserId == 我自己）
  lock.ownSignal(signal.code);
  if (signal.isMobile || signal.event == CallEvent.calling) {
    return _out(effects);               // ✗ 但只有这两种才真的丢掉
  }
}
```

`extends.isMobile` 是**服务端按请求的 User-Agent 算的**（`'isMobile'=>$this->request->isMobile() ? 1 : 0`），
而我们的 HTTP 请求没有带 UA（Dart 默认 `Dart/x.y (dart:io)`），所以服务端算出来是 0，
回声就漏进了 `switch`。老端跑在系统 webview 里、UA 是手机型的，所以它一直没撞上这个闸口。

**修法**（客户端一侧，服务端不用动 —— HTTP 控制器里拿不到「发送者那条 client_id」，
服务端排除不掉自己）：`call_machine.dart` 的 `otherOpt` 分支加一道窄闸 ——
**本端是被叫且已经接听**（`!_session.isCaller && _inCall`）时收到
`code == 904` 的回声，**忽略**。

为什么这样分得开：

| 情形 | 本端阶段 | 结果 |
|---|---|---|
| 自己那句 acceptRtc 的回声 | `connecting`（已接听） | **忽略**（修的就是它） |
| 同账号**另一台**真的接了 | `incoming`（还停在响铃） | 照旧结束（行为不变） |

**顺带**：诊断时间线（`_record`）现在也 `debugPrint` 一份 —— 这次能一眼定位，
全靠 `logcat` 里那几行「收到信令」；面板里的时间线用户要自己进设置翻，太慢。

**回归保护**：`call_machine_test` 加两条（回声不许关掉自己的通话 / 响铃时收到同账号
接听照样结束）。

#### S8.1m 「来电全屏显示」的引导（2026-09-20）

安卓 14 起系统只给「通话类应用」自动授予 `USE_FULL_SCREEN_INTENT`，我们默认是关的：
关着时**息屏/锁屏来电只会是一条横幅 + 响铃**（照样能接，但不是整屏接听界面）。

不做「一进 App 就把用户顶到系统设置页」—— 粗暴且没必要（那一步并不影响能不能接）。
改成复用消息列表那条红提示条（`SystemHealthHint.fullScreen`）：
**一键跳系统页，从设置页回来自己消失**；排在前两条（通知权限 / 电池优化）之后 ——
那两条是「消息收不到」，这条只是「来电不够醒目」。
设置页那一行（`FullScreenIntentRow`）保持不动。

全套 **1117 项通过**。

#### S8.1n 真机故障：「只有一行文案」，没有全屏、没有铃声（2026-09-20）

用户要的是**系统级的全屏来电**（锁屏直接亮屏弹接听界面），实测却是：只有一条静音的低优先级通知。
在设备上查到两个硬证据：

```
$ adb shell dumpsys notification | grep gracelinkim_call
  mId='gracelinkim_call', mImportance=2(低), mSound=null        ← 来电渠道被创成了低优先级静音
$ adb shell appops get cc.gracelink.im USE_FULL_SCREEN_INTENT
  USE_FULL_SCREEN_INTENT: default; rejectTime=+45s ago         ← 全屏意图发出去了，被系统拒了
```

**根因一：通知渠道撞车（这是「没声音 + 不全屏」的真凶）。**
`CallForegroundService.kt` 与 Dart 的来电通知**共用同一个渠道 id `gracelinkim_call`**，
而前台服务先把它创成了 `IMPORTANCE_LOW` + `setSound(null)`. 通知渠道的重要性/声音
**由第一次创建它的那次决定，之后谁都改不了** —— 于是 Dart 那边请求的 `Importance.max`
+ 铃声 + `fullScreenIntent` 全被系统忽略（全屏通知只对高优先级通知生效）。

修：两边各用一条渠道 —— 前台服务 `gracelinkim_call_service`（LOW + 静音，本来就该无声），
来电 `gracelinkim_call_incoming`（max + 声音 + 全屏，**新 id 才能拿到新重要性**）。
旧渠道由服务启动时 `deleteNotificationChannel` 清掉（免得设置里留一个没用的「通话」）。

**根因二：Activity 没声明「能盖在锁屏之上」。**
全屏通知只解决「系统愿意让这个通知启动界面」；**能不能盖住锁屏是 Activity 自己的事**
（`setShowWhenLocked` / `setTurnScreenOn`）。不声明的话，即使全屏通知被放行、
Activity 也起来了，系统仍退回成一条横幅、用户看到的是锁屏。

新增 `lib/core/platform/call_window.dart`（接口 + 安卓实现 + Noop + provider，
与 `CallKeepAlive` / `CallPip` 同一套写法）：控制器在 `_publish` 里幂等地开关它
（通话中开、结束/登出关）。原生那半还多一个入口：**被来电通知拉起来时（`onCreate`/
`onNewIntent`，靠启动 Intent 的 `SELECT_NOTIFICATION` + 通知 id 认出）立刻打开** ——
不能等 Dart，引擎启动那几秒系统已经判定完了。

**根因三（必须用户本人开一次）：安卓 14+ 只给「通话类应用」自动授予
`USE_FULL_SCREEN_INTENT`**，我们默认是被拒的（上面那条 `rejectTime` 就是证据）。
入口：消息列表那条红提示条（S8.1m）/ 设置页「来电全屏显示」→ 打开后才真的整屏弹。

**回归保护**：`call_controller_test` 加一组 3 条 —— 「通话开始就开、结束就关」、「中途状态变化
不重复打通道（幂等）」、「登出也要关（否则下一通通知也会盖住锁屏）」、「通道抛异常不影响通话」；
新增 `test/support/fake_call_window.dart`。全套 **1120 项通过**。

**顺带纠正一个我以为已经做好的事**：来电**全屏**需要用户在设置里把「来电全屏显示」
打开（安卓 14 起系统只给通话类应用自动授权），且只在**锁屏/息屏**时才整屏弹；
屏幕亮着在用就是横幅。没开也**不是错误** —— 降级成横幅 + 响铃。

#### S8.1o 真机复检：三条现象、两条是真 bug（2026-09-20）

用户报：「开了全屏还是没有全屏；最重要的是**没有铃声**；还有 a 呼叫一会儿自己取消了，
**b 那边的通知一直显示**」。上设备 dump，逐条落地：

**① 全屏这条其实通了 —— 上次的结论要修正。**
```
$ adb logcat | grep checkUseFullScreenIntentPermission
  16:57:50.228  permissionResult = 0     ← 允许
  17:02:34.956  permissionResult = 0     ← 允许
$ adb shell dumpsys package cc.gracelink.im | grep USE_FULL_SCREEN
  android.permission.USE_FULL_SCREEN_INTENT: granted=true
```
而且 17:02 那次（锁屏后 4 秒来电）系统日志里能看到 `I=cc.gracelink.im/.MainActivity`
被拉起来、随后用户按了接听（Dart 侧 `取本机媒体（语音）`）—— **全屏意图真的生效了**。
之前那次「没有全屏」是**屏幕亮着测的**：安卓只在锁屏/息屏时整屏弹，亮屏就是横幅（微信亦然）。

**② 没有铃声：一半是系统的静音模式，一半是我们的渠道用错了声音。**
```
$ adb shell settings get global mode_ringer
  0                                                    ← 静音模式
$ adb shell dumpsys notification --noredact | grep gracelinkim_call_incoming
  mImportance=5, mSound=content://settings/system/notification_sound
```
真机当时是**静音模式**（`ringer mode muted streams = 0x126`：铃声/通知/系统音全被 mute）——
那个模式下**任何** App 的通知都不会响，微信也一样。
但我们的渠道本身也错了一档：它用的是**默认通知提示音**（一声「叮」），不是来电铃声。

修：渠道换成**系统来电铃声** + `AudioAttributesUsage.notificationRingtone`（音量跟着铃声走），
id 再换一次（`gracelinkim_call_ring` —— 渠道的声音和重要性一样，建成之后改不了）。

**③ 对方取消后通知一直挂着：这是真缺口。**
被叫收到来电推送时**恰恰是长连接不在线的那一端**（在线就不会走推送），所以主叫取消时
那句 `hangup` 走长连接过去、他一个字都收不到 —— 那条通知没人收。
原来留的两道兜底都不顶：客户端的 `CallPushHost`（这端没起来，够不着）、
通知自带的 45 秒 `timeoutAfter`（而这条通知当时是 `ongoing` 的，系统不许 ongoing 通知超时自收）。

修（两边一起）：
* 客户端：`ongoing: false`（放开超时自收，也允许用户手动划掉）；
* 服务端：主叫取消/超时（`code` 902/905）且被叫离线时，补一条**静默**数据推送
  （`event = callCanceled` + `call_id`，不带任何可展示内容），走 `deferAfterResponse`
  （主叫按挂断不能等 Google 那一趟）；
* 客户端：`isCallCancelPush()` 判在「是不是来电」**之前**，拿 `call_id` 与
  「最后响过的那一通」比对（`PushNotificationHandler._lastRingingCallId`）——
  否则新的一通刚响、上一通那条收尾帧会把它一起收掉。

**回归保护**：`incoming_call_push_test` 加一组 3 条（认得出收尾帧 / 不是来电 / 带出 call_id）、
`push_background_handler_test` 加一组 4 条（收到就收通知且不弹任何东西 / 上一通的收尾帧
不许收正在响的 / App 刚被杀也照收一次 / 别被收尾帧误导着弹来电）；服务端自检 125 → **135 项**。
全套 **1127 项通过**，`flutter analyze` 干净。

**还没做的**（用户已知）：真正的「响到你接」需要**原生响铃服务**（渠道声音不能循环，
只能响一遍；而且要响就得由正在运行的进程去放）—— 现在 App 一起来就由 `CallTones` 循环放
`calling.mp3`（走 media 音轨，静音模式下也能响）。

#### S8.2 首页改成微信那一套（2026-09-20）

用户口径：「先搞首页，尽量和微信一模一样」。这一轮**只动客户端 UI，服务端一行没改**。

1. **顶部标题与底部第一个 tab 都显示应用名**（微信：顶部「微信」、底部也是「微信」）。
   新增语言包键 `user.appName`：中文「恩信」、英文「Gracelink」，
   取词处同时用于导航栏标题与 `message` tab 的 label（`_buildTabs`）。
2. **消息页导航栏按微信摆**：左边空着，**搜索 + 圆框加号都在右边**，标题用 `Stack` 钉在屏幕正中
   （原来是搜索在左、加号在右，两边各占 52）。加号图标从 `Icons.add` 换成 `Icons.add_circle_outline`
   （微信是圆框加号）—— 连带把两处测试的 `find.byIcon(Icons.add)` 一起改掉。
3. **删掉「所有 / 未读 / @我」筛选页签**（`ConversationFilter` 枚举、`_applyFilter`、`_FilterTabs` 全删），
   列表不再过滤，静态测试改写成「这三个页签文案一条都不该出现」。
4. **「电脑端已登录」那一行**（微信的「Windows 微信已登录」）：
   从「导航栏右侧小胶囊」改成**列表最上面独立一行**（显示器图标蹲在头像那一列、文字与昵称左对齐、
   通宽分隔线），数据仍是 `multiport && wsConnected`（老端同款判据）。
   `chat.pcOnline` 文案由「电脑在线」改成「电脑端已登录」（服务端不会告诉我们另一端是什么设备，
   所以不带平台名）。断线时**不显示**这一行。
5. **行内几何对齐微信**（`conversation_tile`）：头像 48dp、昵称 17、预览 14、时间 12、
   未读角标 18 高，行内边距 16/10.6；**分隔线不通到底**，从昵称那一列开始画（微信的招牌细节）。
6. **非文本消息的预览改占位**：`lastContent` 对语音/图片/视频/文件来说**是文件路径**，
   直接显示会露路径（老端就是这样）。改成走已有的 `ConversationRules.previewOf`
   （`[语音]` / `[图片]` / `[视频]` / `[文件]` / `[音视频通话]`）—— 规则早写好了，只是一直没接上 UI。
7. **今天的时刻改成微信写法**：`上午9:33` / `下午5:47`（原来是 24 小时的 `17:53`）。
   语序中英不同，所以格式串放进语言包 `time.today`（zh `{ap}{h}:{mm}` / en `{h}:{mm} {ap}`），
   新增 `time.am` / `time.pm`；为此给 `timeFormat` 引入 `Translate` typedef（`t` 同形签名）。

**测试**：+9（会话列表 11 条、新增 `test/core/time_format_test.dart` 7 条），全套 **1153 项通过**，
`flutter analyze` 干净；真机截图核对过（顶部「恩信」+ 右侧搜索/圆框加号、行内尺寸、`[语音]`、
`下午5:53` / `上午7:23`）。

**没做的（用户知情）**：底部栏选中色仍是品牌蓝（微信是绿 `#07C160`）；
底部图标 22（微信约 26）；`周一` 还是两字（微信是 `星期三`）；
免打扰未读微信是**小灰点**、我们仍是灰底数字；
微信在置顶超过 2 条时会折成一行「折叠置顶聊天」，我们仍是全展开；
「＋」菜单还是 Material 白底弹层（微信是深色圆角下拉）；
聊天页那行时间分隔（`hoursTimeFormat`）还是 24 小时 —— 说了「先搞首页」，下轮再对齐。

#### S8.3 首页三处真机反馈：长按菜单、浅灰顶栏、行高压小（2026-09-20）

用户看过真机后三条：

1. **左滑 → 长按**。`SwipeActionRow` / `SwipeAction` **整个删掉**（含文件），
   改成 `ConversationTile` 接一个带坐标的 `onLongPress(Offset)`：外面套一层 `GestureDetector`
   拿 `onLongPressStart` 的 `globalPosition`（`InkWell` 不给带坐标的长按回调，而它自己不接管长按，
   所以不会抢手势），列表页用 `showMenu` 弹在按下的位置（`RelativeOffset.fromRect`）。
   三个动作与老端左滑那三个**完全一致**：置顶/取消置顶、免扰/取消免扰、删除（群聊 `is_group == 2`
   不给删）。注意老端这个按钮是**反着写**的：`isNotice == 1`（提醒开着）时显示的文案是「免扰」。
2. **顶部栏是浅灰，不是纯白**（微信那一片灰连状态栏都在内），并且**下面要有一条分割线**。
   新增 `AppColors.navBar = #EDEDED`、`AppColors.navDivider = #DCDCDC`；置顶会话那行的底色
   也从 `page(#F5F5F5)` 换成 `navBar(#EDEDED)`（微信里置顶区就是这个灰）。
3. **行高太大 → 压到约 62dp**：头像 40dp（原 51）、昵称 16（原 17.4）、预览 14、时间 12、
   隐藏角标 17、行内边距 16 / 10.6、分隔线起点跟着前移。

顺带修：**长按菜单的卡片原来是淡绿灰**（Material 3 拿种子色派生的 `surfaceContainer`），
加了 `popupMenuTheme`（纯白 + 10 圆角 + elevation 6 + 16 号字），「＋」菜单一起变白。

**测试**：会话列表 13 条（删掉两条左滑用例，换成「长按弹菜单」「点「免扰」真的生效（本地先改）」
「群聊菜单没有删除」「行高不高于 70dp」），全套 **1155 项通过**，`flutter analyze` 干净。
真机 `adb shell input swipe x y x y 900` 复现长按、截图核对过菜单内容与白色卡片。

#### S8.4 首页「全面对齐微信」+「标为未读」红点 + 深色「＋」菜单（2026-09-20）

把上一轮列出的「还和微信不一样」逐条做掉（用户：全都改了吧）：

1. **底部栏**：浅灰底 `#EDEDED` + 一条上分割线（原来纯白）；选中态换成微信绿 `#07C160`
   （新增 `AppColors.wechatGreen` / `tabInactive`），图标 26dp。tab 文案跟微信对齐：
   第一个 = 应用名（`user.appName`，中文「恩信」/ 英文「Gracelink」）、`探索` → `发现`
   （`user.compass`）、顶部「我的」而底部只写「我」（新增 `user.mineTab`，`_ShellTab.tabLabel`）。
2. **「电脑端已登录」那一行**改成与顶部栏同色的灰底 + 通宽分割线（原来白底）。
3. **折叠置顶聊天**：置顶超过 2 条时折起来，列表最下面留一行 `_FoldPinnedRow`（☰ + 文案 +
   上下箭头），点一下展开/收起 —— 这一整块是微信独有的，之前没有。
4. **长按菜单内容按微信**：标为未读 / 置顶聊天（已置顶则「取消置顶」）/ 不显示该聊天 /
   免扰 / 删除该聊天。其中**「不显示该聊天」与「标为未读」是老端和协议里都没有的动作**，
   都只作用在本机（见第 6 条与 `hidden_conversations.dart`）。
   一处刻意的保留：微信把免打扰放在聊天设置页，我们那边还没有入口，删了就没地方点，所以留在菜单里。
5. **文字与角标对齐微信**：昵称 `#1A1A1A`（原来 `#333` 摆在微信旁边发灰）、时间 `#B2B2B2`、
   未读红 `#FA5151`（单个数字是正圆）、免打扰会话有未读时只点一个**小灰点** `#D2D2D2`、
   白底菜单卡片（`popupMenuTheme`：M3 默认会渲染成淡绿灰）。
6. **「标为未读」= 红点，不是数字**（微信长按标为未读只点一个红点）。新增
   `lib/core/store/manual_unread.dart`：`SharedPreferences` 落盘的一份 id 名单；
   会话行照旧同时把库里 `unread` 置 1（底部 tab、服务端对齐口径都还自洽），
   这份名单只决定**这一条不显示数字**。进会话（两处 `markReadLocally`）清掉、退出登录清空。
   会话行新增 `unreadIsDot`，圆点高度**故意和角标一样（34rpx）**，免得行高随角标形态变。
7. **「＋」菜单换成微信那种深色半透明卡片**（`AppColors.menuDark = #F24C4C4C`、白字白图标、
   12 圆角、`position: under`）—— 长按那个菜单才是白底，两者本来就不一样。

**测试**：+10（`test/core/manual_unread_test.dart` 5 条：落盘/重启还在、重复标记不写两遍、
clear/clearAll、存坏不崩；会话列表：标为未读顶红点且不显示数字、进会话后标记消失），
全套 **1165 项通过**，`flutter analyze` 干净。真机核对：底部灰底+绿选中+`恩信/通讯录/发现/我`、
深色「＋」菜单、长按白卡菜单、「标为未读」那一行确实只顶一个红点、进会话后红点消失。

**这台机器上没法用 adb 验证的**：菜单项的点击要靠 widget 测试钉（`input tap` 落在弹层上的
坐标得手算，容易点空、甚至误触发下面的行/呼叫按钮，本轮踩过）。

**仍与微信不同（要么做不到，要么等用户点头）**：
* 「Windows 微信已登录」里的**平台名**：协议只有 `multiport` 一个布尔，服务端不说另一端是什么设备；
* `发现` 的图标形状（我们用的是老端那套 svg 指南针，微信是圆里一个罗盘指针）；
* 微信长按菜单只有 4 项（没有免扰）；
* 「我的收藏」「系统通知」两行没有预览文字 —— 服务端那两条会话不给 `lastContent`（数据问题，不是 UI）；
* 聊天页那行时间分隔仍是 24 小时（这轮只动首页）。

---

## R7　聊天页照微信重排 + 系统表情 + 语音转文字（2026-09-20）

本轮**只动客户端**（服务端一行没动，协议没动）。用户给了两张微信截图，要求「录音界面照抄、
转文字用 stillnooot 那套、内置表情图片换成系统表情」。

### 1. 内置表情：图片包 → 系统表情（`lib/core/util/emoji.dart`）

老端是「文本 token + 服务端图片」两段式：消息里存 `[!1f600]`，渲染时换成
`{apiUrl}/static/img/emoji/twitter/1f600.png`。改法：

* token 里的码值**本身就是 Unicode 码点**（老端 twitter 表情包的文件名就是码值），
  所以解析出来直接 `String.fromCharCode` 交给系统字体（安卓 Noto Color Emoji）；
* **面板里点一下插进输入框的是真 emoji 字符**，于是我们自己发的消息里没有 token，
  网页端 / 老端收到的也是普通 emoji；
* **历史消息与网页端发来的仍有 `[!code]`**，显示时照旧解析，只是从「加载图片」变成「显示字符」
  —— 一样的表情、不依赖服务端静态资源、还省一堆请求；
* 解析不出码点的 token **保留原文**（对齐老端），不能把 `[!xyz]` 变成空白。

连带改：`emoji_panel.dart`（格子画字符）、`message_bubble.dart`（气泡里画字符），
`test/chat/emoji_test.dart` 重写，`rich_text_test` / `message_actions_test` 跟着对齐。

### 2. 录音界面：微信那套遮罩（`lib/features/chat/widgets/voice_record_overlay.dart`，新增）

* 遮罩 `voiceOverlayScrim = 0xB3000000`（**不是全黑**，能看见背后的聊天，和微信截图一致）；
* 中间一颗绿色声波气泡（`#7BE05A`，深色竖条按实时音量左右对称起伏，静音时是一排小圆点），
  气泡底下带一个朝下的小尖角（`_BubblePainter` 自绘）；
* 底部两块：上排是 **「取消」（左上角圆角）** 与 **「滑到这里 转文字」（右上角圆角）** 两个区，
  手指滑进哪块哪块变亮；下排是白色上圆角托盘，写**「松开 发送」**（加粗近黑 `#111111`）；
* 三档判定靠 `Listener` 的**绝对屏幕坐标**（`armRpx` 一条「武装线」）：手指在线上方时，
  **左半边 = 取消、右半边 = 转文字**，线下方就是「松开 发送」；
* 被系统抢走手势（来电/通知栏）时 `onPointerCancel` 当成「取消」，不把半截录音发出去。

### 3. 语音转文字：接 stillnooot 那个 Whisper Worker（`lib/core/audio/speech_to_text.dart`，新增）

* `POST {workerUrl}`，`multipart/form-data`，**音频字段名 `audio`**（不是 `file`），
  请求头 `x-api-key`；响应 `{"text": "..."}` —— **纯转写**，没有 success / language 等字段；
* 地址与密钥都可打包时覆盖：`--dart-define=VOICE_WORKER_URL= --dart-define=VOICE_API_KEY=`；
  默认值就是 stillnooot 那把 key。**它写在客户端里迟早能被扒出来**，防滥用要在 Worker 侧限流；
* **不做本地语义解析**（stillnooot 那边还要跑一遍规则库抽提醒时间，我们没有那个需求）：
  识别到什么就填什么，直接进输入框；
* **不为转文字单独再录一份别的格式**：我们录音本来就是 16kHz 单声道 AAC（`.m4a`，24kbps），
  **curl 实测** Worker 吃这个（12KB 的样例返回 `{"text":"Remind me to buy milk at 7pm tonight."}`）；
* 非 200 / 超时 / 网络 / JSON 坏 / 缺 `text` 全部收敛成一个 `SpeechToTextException`；
* 转文字这条支路**不发语音**：识别完（或失败）就把刚录的那段丢掉，只提示一句「转文字失败」，
  想留住这段语音得重新按住说一遍（微信同样是这个语义 —— 转文字和发语音是二选一）。

### 4. 聊天页照微信（`chat_page.dart` / `message_bubble.dart` / `chat_input.dart`）

* 页面底色 `#EDEDED`；自己那颗气泡**微信绿 `#95EC69` + 小尾巴**，对方白底黑字 + 小尾巴；
* 时间分隔改成 **`8月15日 晚上8:47`** 这种 12 小时制（`timeSeparator`，与首页那套同一份语言包）；
* 输入区：**底色是聊天那层灰、输入框是白的**（原来整体白底 + 灰输入框，反了）；
* 按钮摆法按微信：**语音/键盘切换 → 输入框 → 表情 → ＋（或发送）**
  （老端是表情在最左、语音切换在其右）；「发送」换成微信绿；那排图标改近黑 `#333`、46rpx；
* 群里聚焦时那个 `@` 还在（微信把它放在输入框浮动菜单里），保留老端入口。

### 5. 测试与验证

* `flutter analyze` 干净；全套 **1178 项通过**（1165 → 1178，+13：`speech_to_text_test` 契约
  `audio` 字段 / `x-api-key` / 非 200 / 缺 `text` / 超时，`emoji_test` 重写，`chat_voice_test` 补三档判定）；
* release 包已构建（73.9MB）；**本轮结束时手机不在电脑上**（`adb devices` 为空），
  所以遮罩与转文字的**真机观感/识别效果这两件没在设备上核过**，装包后再看一眼。

---

## R8　消息气泡 / 表情分类 / 头像可点 / 已读上报的 500（2026-09-20 晚）

用户列了六个问题，其中一个是**服务端 500 的真 bug**。这轮同样**只动客户端**（服务端一行未改）。

### 1. 键盘与面板互斥（之前两者会同时出现）

面板开着时点输入框 → 系统键盘顶上来、面板还占着下半屏，输入框被挤出视野。
修法：`ChatInput._onFocusChanged()` 里一旦拿到焦点就把 `_panel` 收起（老端 `@focus` 时
`showAppBox(0)` 是同一个意思）；另外 `_insertText()` 在面板开着时**不再请求焦点**，
这样连着点好几个表情不会把键盘也拉起来。

### 2. 表情面板分类（`emoji_pack.dart` 重写 + `recent_emoji.dart` 新增）

底部一条分类带（微信摆法，可横向滑）：**最近 / 收藏 + 8 个内置分类**
（常用 / 笑脸 / 手势 / 动物 / 食物 / 活动 / 旅行 / 物品 / 符号），共 400+ 个系统表情。

* 第一栏「**常用**」原样照抄老端 `utils/emoji.js` 那 66 个（顺序、码值都不动），
  老用户在原来的位置还能点到同一个表情；
* 「最近」是**纯本机**的（`SharedPreferences`，上限 24，重复的提到最前），
  退出登录清空，存坏了当没有；
* 用例把这份手写清单钉住：码点必须能解成字符、同栏不重复、分类不少于 5 栏、
  每栏的分类图标必须**是本栏里的一个表情**。

### 3. 语音气泡照微信（`media/voice_bubble.dart` 重写）

* 宽度 = `最短 180rpx + 秒数 × 9rpx`，夹到 `460rpx`。老端是 `秒数 × 3`（**逻辑像素**）
  再用 rpx 夹上下限 —— 两套单位混着，结果 3 秒和 40 秒一样宽（永远是下界）；
* 内容只有「时长 + 声波图标」，图标在靠外那侧；声波是自绘的（三道光弧 + 一个实心点），
  **播放时一道道亮起来**（1→2→3 循环），这就是用户说的「波纹会有变化」；
* 播放中**不再变底色**（微信不变色，靠声波动画表示在播）；底色仍是自己绿、对方白。

### 4. 通话气泡也是绿/白（`media/call_bubble.dart`）

原来是一条浅蓝灰卡片（老端 `im-webrtc.vue` 的样式），现在和自己的文字/语音一样是
**绿（自己）/ 白（对方）气泡 + 小尾巴**，图标在靠外那侧（自己的文案在前、话筒在后）。
`message_bubble.dart` 的 `_hasTail` 与尾巴竖直位置跟着改（矮气泡的尾巴贴中间）。

### 5. 聊天页头像可点（老端点了没反应）

`MessageBubble` 新增 `onAvatarTap`；聊天页里**自己的头像 → 「我」的资料页**、
**别人的 → 用户详情页**（群里还会带上 `group_id=group-5`，资料页里那块「群内管理」才有数据）。

### 6. 聊天信息页点头像 → 「服务器繁忙」+「暂无数据」（**这条是真 bug**）

两个毛病叠在一起：

* **服务端 500**：我们的 `setMsgIsRead` 少传了一个 `messages` 键。
  服务端 `Im::setMsgIsRead()` 第一行就是 `$param['messages']` → PHP notice →
  ThinkPHP 把 notice 转成 ErrorException → **HTTP 500**，客户端（`notify: false`）静默失败。
  线上日志里那条 `[8]未定义数组索引: messages[Im.php:518]` 一天几十条就是这个。
  现在照老端传一条消息进去（单聊分支不看内容，群聊分支只挑 `at`）。
* **资料页只会说「暂无数据」**：现在把失败原因（服务端那句话/网络错误）直接显示，
  并给一个「重试」；`userId` 为空时**干脆不发请求**（服务端 `User::find(null)` 会直接 500，
  那就是用户看到的那句「服务器繁忙」）。

> 还没在真机上确认第 6 条的服务端那一半：手边没有设备，也没法登进线上验证。
> 若装包后还报「服务器繁忙」，请在服务器上跑
> `grep '\[error\]' runtime/enterprise/log/$(date +%Y%m)/$(date +%d).log | tail`
> —— 有行就能一眼看出是哪个接口的哪个下标。

### 7. 测试与验证

* `flutter analyze` 干净（顺手把 `dart format` 弄坏的 3 处 `// ignore: prefer_initializing_formals`
  改成文件级忽略，那两个依赖注入的构造函数本来就该忽略它）；
* 全套 **1193 项通过**（1178 → 1193，+15：`emoji_categories_test` 4 条、`recent_emoji_test` 5 条、
  键盘与面板互斥、最近使用、点头像进资料页、语音宽度按时长、通话气泡自己/对方、
  资料页空 id 不发请求、已读上报多带 `messages`）；
* release 包已构建（73.9MB）；**手机不在电脑上**（`adb devices` 为空），装不了机 ——
  表情分类条的观感、语音声波动画、点头像这三件都还没在设备上核过。

## R9　聊天信息页照微信（单聊 + 群聊）（2026-09-20 深夜）

用户给了微信「聊天信息」的三张截图（单聊一张、群聊两张），要求「一摸一样的照着抄」，
并点名两件事：**「提醒」这一栏不做**（我们没这个功能）、
**「清空聊天记录」是唯一要新增的功能**、**「投诉」只做表面功夫**
（点一下出「提交成功 + 一个勾」的动画即可）。这轮**服务端一行未改、协议未改**。

### 1. 整页重写（`lib/features/chat/chat_info_page.dart`）

微信那套结构：顶部导航栏（群聊标题带人数 `聊天信息(3)`，群聊右边一颗搜索）→
顶上头像块（白底）→ 一张张白卡片、卡片之间留灰缝、行内的细线**从文字左边开始**。

* **单聊**：对方头像（点进资料页）+ 一颗虚线「＋」（= 发起群聊，`contact_id` 预选对方）、
  查找聊天记录、消息免打扰、置顶聊天、设置当前聊天背景、清空聊天记录、投诉；
* **群聊**：成员网格（头像 + 名字，`＋` 加人 / `－` 移除，管理员才看得见 `－`）+
  「查看全部群成员 N 人」、群聊名称、群二维码、群公告、群管理、查找聊天记录、
  消息免打扰、置顶聊天、设置当前聊天背景、清空聊天记录、投诉、
  底部红字「退出群聊」（群主是「解散群聊」）。

**没做的行**（服务端与老端都没有对应功能，按用户的话「有的做，没有的就不要做」）：
「提醒」「备注」「保存到通讯录」「我在群里的昵称」「显示群成员昵称」。
群二维码那一行仍跟着 `setting.invite`（老端 `v-if="contact.setting.invite"`）。

> 群聊截图里那块「群二维码」我们本来就有（S5.3 接的 `AppRoutes.qrcode`），这轮只是挪到
> 微信的位置上。

### 2. 「清空聊天记录」（**这轮唯一新增的能力**）

服务端**没有**「只清我这边」的接口 —— 历史还在它库里，一进聊天页又会被拉回来，
只删本地的话用户看到的就是「清空不管用」。所以：

* 新增 `lib/core/store/cleared_chats.dart`：本机一份名单，记下被清掉那批消息的
  **`msgId` + `serverId`**，以及最后一条的 `sendTime`；
* `MessageRepository._dropCleared()`：任何来源（拉历史、推送、乐观消息）落库前先过一遍名单；
* `ConversationRepository._blankClearedPreview()`：服务端列表里最后一条正好是被清掉的那条 →
  预览抹掉、未读归零（来了新消息 `sendTime` 变了，预览自然恢复）；
* `ChatInfoPage._clearHistory()`：单聊 = 记名单 + 删本地 + 抹预览；
  **群聊里我还是群主/管理员时**才照旧连服务端一起清（所有人的记录都删，老端行为），
  普通成员清的是自己这份；
* 退出登录清空（id 是按账号的）。

**边界（刻意如此）**：只影响本机；对方记录还在，换台设备还能看到历史。
记 id 而不是记时间戳，是为了不踩「设备时钟比服务端快几分钟」把新消息一起吞掉的坑。

### 3. 「投诉」= `lib/core/ui/success_check.dart`（新增）

一个居中的深色圆角盒子：绿圈里的勾**从中心弹出来**（`easeOutBack` 回弹），停一下整体淡出，
全程 1.4 秒、不用点确认。**不发任何请求**（用例就是钉这一点：`adapter.paths` 不变）。

> 顺手修了它自己的一个 bug：原来用 `Navigator.maybePop()` 关自己，而外面的
> `PopScope(canPop: false)` 会把 `maybePop` 拦下来（那个 API 是给系统返回键用的），
> 弹层就永远关不掉、整页被它挡死。改成 `pop()`，并加了一条用例把它钉住。

### 4. 测试与验证

* `flutter analyze` 干净；
* 全套 **1208 项通过**（1193 → 1208，+15）：
  `cleared_chats_test` 8 条（命中/预览/落盘/reload/存坏了/合并/上限/退出登录清空）、
  `message_repository_test` 3 条（清空后重拉落不进去、名单外的新消息照常进、只影响被清的会话）、
  `conversation_repository_test` 2 条（预览抹掉、来了新消息恢复）、
  `chat_info_page_test` 2 条（清空链路、投诉动画）；
  另有既有用例跟着新界面改：标题带人数、`查看聊天记录` → `查找聊天记录`、
  「清空聊天记录」不再只给管理员、那两颗虚线格子改用 key 找（图标没有文字）。
* release 包已构建（73.9MB）；**手机不在电脑上**（`adb devices` 为空），没装机 ——
  这一页的观感（间距、虚线格子、白色卡片之间的灰缝）还没在设备上核过。

---

## S4.4d 「＋」面板照微信重画（2026-09-21）

用户给的微信「＋」面板截图要求：**一行四个、白方块浮在浅灰底上、深色实心图标、
下面一行灰字**，文案也换成微信那套（照片 → 相册）。我们没有的功能（位置 / 红包 /
礼物 / 转账 / 收藏 / 音乐）不画格子。

### 1. `_morePanel`（`lib/features/chat/widgets/chat_input.dart`）

* 摆法从「白底灰方块 + Wrap 自动换行」换成「**浅灰底 + 白方块**、一行四个」：
  格子宽度按可用宽度平分（`gap = 60rpx`、上限 `160rpx`），列间距自己撑开；
  格子比白方块宽一点，`个人名片` 这种四个字才不会挤成两行；
* 图标全换成 **Material 实心字形**（`Icons.photo` / `photo_camera` / `videocam` /
  `call` / `video_library` / `folder` / `person`），不再用老端那套描边的 `iconfont`；
* 文案：`相册`（新增 `common.album`）、`拍摄`（新增 `common.capture`）、
  `视频通话` / `语音通话`（`message.*`）、`视频`、`文件`、`个人名片`（`chat.userIDcard`）；
  顺序：相册 / 拍摄 / 视频通话 / 语音通话 / 视频 / 文件 / 个人名片；
* 面板高度仍是与表情面板同一档（`EmojiPanel.heightRpx`）。横屏 / 小窗上两行塞不下，
  所以**整体按比例缩一档**（`scale = height / 需要的高度`，竖屏手机算出来就是 1），
  再兜一层滚动；
* 面板底色抽成 `AppColors.panelBackground`（`#F5F5F5`），**表情面板一并用它**
  （微信两块面板是同一个底；分类条选中态因此从 `page` 灰改成**白**）。

### 2. 「拍摄」= 新的一条真功能（`lib/core/media/media_picker.dart`）

`MediaPicker.pickCamera()` → `ImagePicker.pickImage(source: camera)`，拍出来是一张图，
和相册选图**走同一条发送链路**（压缩 / 大小限制 / 乐观落库全都在聊天页那边）。
用户取消返回 null —— 与 `_pick` 同口径：面板不收、什么都不发。
（5 个测试假体都补了这个方法。）

### 3. 测试与验证

* `flutter analyze` 干净；
* 全套 **1211 项通过**（1208 → 1211，+3）：
  面板布局用例（7 个文案齐、7 个实心图标齐、**前四个格子标签齐平** + 第五个换行、
  第二行三个齐平、底是 `panelBackground` 灰），
  「拍摄」拍一张 → 落库 / 压缩被调用 / 面板收起，
  「拍摄」取消 → 什么都不发、面板还开着；
  既有用例跟着改：`照片` → `相册`（3 个测试文件）、`名片` → `个人名片`。
* **服务端一行没动。**

---

## S4.3b `type == 'event'` 系统消息（2026-09-21）

用户反馈：新建群聊后聊天里显示一条蓝色气泡「暂不支持的消息类型」，而网页端显示的是
系统消息「创建了群聊」。

### 根因（对着服务端源码查的）

服务端建群时直接插一条 `type = 'event'` 的消息（`Group.php::addGroup()`，
`content = lang('group.add')`），入群/被邀请同源（`group.join` / `group.inviteJoin`）；
**撤回也是同一种类型**（`Im.php::undo()` 把原消息改写成 `type='event'` + `is_undo=1`）。

老端 `chat.vue` 里 `v-if="item.type=='event'"` 是**单独一条分支**，画成 `.cu-info`：
居中、`rgba(0,0,0,.2)` 底、白字 24upx、最大宽 400upx（撤回提示后面再跟一个「重新编辑」）。

新端 `MessageBubble` 此前只认 `is_undo`，非撤回的 `event` 就掉进了未知类型分支
（`UnsupportedBubble` → 「暂不支持的消息类型」），而且那颗气泡自己是蓝底白字，
看起来就像自己发了一条怪消息。

### 改了什么

* `lib/features/chat/widgets/message_bubble.dart`：最前面那条分支扩成
  `isUndo == 1 || type == 'event'`，渲染新的 `_SystemLine`（即原来的 `_UndoLine` 抽了个
  `text` 参数，样式一字没动）；
* 「重新编辑」只给**自己撤的**那条（原来就是这个条件）；
* 显示的文案：群事件 = 服务端 `content`；**自己撤的**仍用语言包那句「你撤回了一条消息」
  —— 本机撤回时 `patchMessage` 只置了 `is_undo`、`content` 还是原文，照抄会把原话显示出来；
  别人撤的用服务端 `content`（「小明撤回了一条消息」），与老端一致；
* 会话列表预览、通知正文**本来就是对的**（`ConversationRules.rawPreviewTypes` 里早有
  `event`，直接显示 `content`），所以这次只动了气泡这一层。

### 验证

* `docs/protocol/message-types.md` 补了 `event` 一行的规格与老端 `.cu-info` 的尺寸；
* `flutter analyze` 干净；全套 **1212 项通过**（+1）：新增
  「系统消息（type=event）：居中一条小字，不是气泡、也不是「暂不支持」」
  （同时钉住建群事件与别人撤的两条，并断言**居中**不再靠左/靠右）；
* release 包已重建；手机仍不在电脑上，没装机。

---

## S4.5b 三处 UI 修正（2026-09-21，用户真机反馈）

### 1. 聊天信息页的箭头跑到屏幕中间了

`ChatInfoPage._row` 原来是 `Text(label) → Spacer → Flexible(Text(value)) → Icon(chevron)`。
**两个 flex 子项会把剩余空间对半分**：Spacer 占一半、`Flexible` 也占一半（空值时它自己只画 0 宽，
但那半截空间已经预留掉了），于是箭头落在「一半空白的中间」——用户截图里那一排箭头就是这么来的。

改成 `Text(label) → Expanded(Text(value, textAlign: right, ellipsis)) → 8rpx → Icon`：
值占满剩余宽度并右对齐、箭头贴最右（微信那套）。单聊页与群聊页都跟着好。

### 2. 语音气泡里的「声波」重画

`_VoiceWavePainter` 原来是错的：三道弧各画一个**半圆**（±90°，弧高顶到整个方块高），
圆心还摆在 x = 0.62：半径 0.5 的那一圈直接画到方块**外面**（漏到旁边的时长文字上），
三圈一大一小的「C」形叠在一起 —— 这就是用户说的「这么丑」。

现在：**圆心就是那个实心点**（真正的同心弧）、张角只有 ~100°（微信也不是半圆）、
粗细 0.085、圆头；最外圈半径 0.52 加上圆点的 0.24 刚好落在方块内，不再溢出。
方向也照老端对齐（`im-voice.vue` 的 `isSelf ? rotate225 : rotate45`）：
**圆点在最外侧、光弧朝里对着时长**，所以 `Transform.flip` 从 `!mine` 改成 `mine`。

### 3. 往上翻历史后会自动弹回最底下

根因是「加载更多」的机制本身：窗口大小 `_limit` 是 provider 的 key
（`chatMessagesProvider(ChatQuery(id, limit))`），放大一页 = **换了一个全新的 provider**，
而它头一帧只有 `loading`、没有值 → `messages` 变成空列表 → 反向列表的
`maxScrollExtent` 塌成 0、位移被夹回 0 → 界面直接跳回最新那一条。用户看到的
「转完圈就回到最底下、得重新往上翻」就是它。

修法：留一份 `_lastMessages`（在已有的 `ref.listen` 里更新），新 provider 还没吐值时先拿它顶着；
真正的新数据到了再换。一行的事，但必须靠**能复现的用例**钉住 ——
新增的用例先在**去掉修复**的代码上跑成了失败（`find.text('消息40')` 被弹到眼前、位移塌到 0），
加回修复才通过。

### 4. 顺手：系统消息点不动（用户要求「拿不准就按微信的做法」）

`type == 'event'` 的系统小字在 `MessageBubble` 里是**提前 return** 的，所以长按菜单
（那个 `GestureDetector`）本来就没挂上去 —— 已补一条用例钉住：长按系统消息不出现
转发/删除/引用，以后改坏了会被抓住。

### 5. 验证

* `flutter analyze` 干净；全套 **1214 项通过**（+2）：
  聊天页「加载更多不会把界面弹回最底下」（带「去掉修复会失败」的验证）、
  聊天信息页「每一栏的箭头都贴最右边」（四条有箭头的行逐条量右边距）；
  系统消息那条用例加了「长按没有菜单」的断言。
* `docs/protocol/message-types.md` 的 `voice` 一节改成了真实几何（老端的图标签、新端的画法）。
* release 包已重建并 `adb install -r` 装到设备上（保留登录态）。

---

## S4.5c 长按菜单改成微信那张深色小卡片（2026-09-21）

用户发来微信的长按菜单截图要求照抄。之前这里是**白色底部弹层**（一行灰底方块 + 灰字，
自己的设计），跟微信差得远。微信的规则是「**深色浮动小卡片 + 一个指着气泡的小尖角**」：

* 卡片：`menuDark`（半透明深灰）圆角 16rpx，白图标 + 白字，**一行 5 个**
  （一格 112rpx、一行 150rpx），行之间一条淡分隔线（左右各内缩 12rpx）；
  条目不足 5 个时卡片就窄到刚好放下那一行（微信最后一页也是这么短）；
* 位置：压在**长按的位置上方**、尖角朝下指着气泡；上方放不下就翻到下面、尖角朝上；
  左右夹在屏幕内；尖角中心跟着手指走、但不贴到卡片两角；
* 点别处关掉（屏障透明 —— 微信不会把背景压暗）；点卡片空白处**不关**
  （卡片自己 `HitTestBehavior.opaque` 吸住，否则会漏到屏障上）；
* 图标换成**实心白字形**（`Icons.replay/copy/favorite/reply/format_quote/delete`）：
  老端那套描边 iconfont 放在深色底上很碎。「存表情」= 微信的「收藏」那一格，所以用了心形；
  「转发」用一面镜像的弯箭头（微信就是个向右的弯箭头）。

**没有的功能没做**：微信截图里的「多选 / 提醒 / 翻译 / 搜一搜」我们都没有对应功能，
按用户说的「没有的功能不用做」不画格子。

实现上换成 `showGeneralDialog`（透明屏障 + 140ms 淡入），卡片位置在
`_MessageMenuCard` 里按 `MediaQuery` 与长按坐标算，尖角是 `_MenuTailPainter`。
新增用例钉住：卡片底色是 `menuDark`、五个标签都是白字、**卡片底边在气泡上方**、
点卡片外面菜单关掉。

`flutter analyze` 干净；全套 **1215 项通过**（+1）；release 包已重建并装机。

---

## S8.1o 离线呼叫不再秒回忙线：主叫「重喊」+ 落库幂等（2026-09-21）

用户真机反馈：给**不在线**的好友打电话，客户端约 1 秒就显示「对方忙~~」并挂断。
「他过一会儿自己打开 App 也接不到 —— 电话在第 1 秒就没了。」

### 根因（对着自己服务器下载回来的源码核过）

`S8.1h` 那版规则是「**叫号 + 对方不在线 + 一台可推设备都没有 → 回忙线**」
（`PushTargets::blockOfflineCall`）。它比原版好（原版是离线一律忙线），但真机上更不讲理：
**收得到推送的人能接到离线电话，推不着、但过一会儿会自己打开 App 的人反而接不到**。

### 改法（两边配套，缺一边就出怪事）

**服务端**（新包 `call_ring_server/`，只覆盖 `app/enterprise/controller/Im.php` + 自检脚本）：

1. **`calling` 一律照发，一枪都不拦**。离线时这一帧被网关静默丢弃
   （`Gateway::sendToUid` 对离线 uid 返回 false），能推的照旧走离线推送；
   被叫离线时只 `trace` 一行（把「他当时确实不在线」和「别的地方坏了」分开）；
2. **`calling` 落库幂等**：报文里的 `id`（主叫生成的 uuid）已在消息表里且
   `from_user` 是自己 → **只转发，不新建记录、不动 `is_last`**。
   不幂等的代价是对方聊天列表里凭空多一条通话记录；
3. `PushTargets::blockOfflineCall()` 不再被调用（文件留着，但自检改成在**源码**上
   钉住「Im.php 里不再有兜底忙线」+「重喊不重复落库」两条）。

**客户端**（`call_machine.dart`）：

1. `peerOnline(peerId)` 现在是**看阶段做两件事**：
   * `outgoing`（还在响、没人接）→ **用同一个 id 重喊整帧 `calling`**
     （上下线是全站广播的，主叫一定知道对方什么时候上来），上限
     `callResendLimit = 3`（防弱网反复重连刷信令）；
   * `connecting`（已接听、等 answer）→ 照旧补发同一份 offer（S8.1h）；
2. `case CallEvent.calling` 前面加一条守卫：**同一个 `id` 的重复来电静默忽略**。
   不忽略就会掉进「已经有一通 → 回忙线」，被叫回的忙线反而把主叫那通挂掉。

### 边界（写进说明书，别当 bug）

* 对方**推不着又一直不打开 App** → 主叫响满 60 秒后「未接通」，我们没有任何通道
  能叫醒一台没登记推送设备的机器；
* 被叫侧响铃上限仍是 45 秒：他第 50 秒才上线，最多响 10 秒就被主叫超时收掉；
* 两端**都不会**因此多出一条聊天记录：客户端 `_findExisting` 按 serverId 匹配，
  续写同一行（已核对 `message_dao.dart`）。

`flutter analyze` 干净；全套 **1221 项通过**（+6，新增「对方中途上线」那组）；
release 包已重建并 `adb install -r` 装机（保留登录态）。

---

## UI 仿微信：通讯录页（S9 观感）

用户要求「把通讯录改成微信这样，没有的功能不做，UI 照抄越像越好，注意细节」。
这一轮**只动观感层**，数据链路、接口、服务端一行没改。

### 色值和尺寸不是估的，是从用户给的那张微信截图里实采的

截图 1080×2316，密度 3x（用「顶部栏 68dp = 状态栏 24 + 内容 44」反推出来的）
→ 屏幕 360×772dp。拿它量出来：

| 元素 | 微信实测 | 我们 |
|---|---|---|
| 顶部栏底 / 分组字母条底 | `#EDEDED` | `AppColors.navBar`（原本就是这个） |
| 底部 tab 栏底 | `#F7F7F7` | `AppColors.tabBar`（**新**，原来是 `#EDEDED`） |
| 行底 | `#FFFFFF` | 同 |
| 行与行细线 | `#E5E5E5`，1px | `AppColors.rowDivider`（**新**，原来是通栏 `#EEEEEE`） |
| 字母条下细线 | `#D5D5D5` | `AppColors.sectionDivider`（**新**） |
| 行高 | 150px = 50dp | 110rpx ≈ 53dp（沿用，差 5%，看不出来） |
| 入口方块 | 107px ≈ 36dp，圆角约 4/36 | 80rpx ≈ 38dp，圆角 10rpx |
| 分组字母条 | 86px ≈ 28dp | 58rpx ≈ 28dp |
| 行首文字 | 17dp，`#181818` | 34rpx ≈ 16.3dp，`AppColors.text000` |
| 新朋友 / 群聊 / 蓝色方块 | `#FA9E3B` / `#07C160` / `#2781D7` | `entryOrange` / `wechatGreen` / `entryBlue` |

### 改了什么

1. **入口图标**：老端那几张 PNG（`invite.png` / `group.png` / 服务端头像）换成
   微信那种**实心彩色圆角方块 + 白色字形**（`person_add_alt_1` / `groups` /
   `campaign`）。字形用 Material 实心字形，不用描边。
2. **行细线**：从**这行文字左边**才开始（微信不是通栏）。入口行 134rpx、
   好友行 140rpx —— 好友头像的布置盒比头像本身宽 6rpx（给在线小绿点留位置），
   所以两条缩进各算各的。
3. **分组字母条**：白底 → `#EDEDED` 整条、高 28dp、下沿一条 `#D5D5D5`。
4. **右侧索引条**：去掉白底圆角盒和投影（微信就是字母浮在列表上），字母改
   `text333`，最上面多一格「**↑ 回到顶部**」。微信还有一格「☆ 星标朋友」，
   我们没有星标功能，**不做**。
5. **顶部栏**：通讯录从「搜索在左」改成微信的「**左边空着，放大镜 + ＋ 都在右边**」，
   底色跟消息页一样是 `#EDEDED` + 一条下分割线。
6. **「＋」菜单按页分**：通讯录那颗 ＋ 里是「创建群聊 / 添加朋友 / 扫一扫」
   （微信是 发起群聊/添加朋友/扫一扫/收付款，收付款我们没有）；消息页那颗保持
   原来的四项（含「更新消息」）。
7. **底部 tab 栏**：`#EDEDED` → `#F7F7F7`（微信比顶部栏浅一档）。
8. **文案**：`friend.newApply` 新邀请 → **新的朋友**（新朋友页的标题跟着变，微信也是这个名），
   `friend.contactNum` 个朋友 → **位朋友**。

### 刻意不做的（用户说「没有的功能我们不做」）

仅聊天的朋友、标签、公众号、服务号、星标朋友、我的企业及企业联系人、
通讯录那格「☆」——都没有对应数据，一格都不画。截图里那些入口的颜色我们全部采下来了
（`#FA9E3B` / `#07C160` / `#2781D7` / `#1485EF` / `#0EAFFF` / `#5CBBFF`），
以后要加同类入口直接用。

### 验证

`flutter analyze` 干净；全套 **1227 项通过**（+6，新增「微信那套观感」那组：
方块底色与白字形、细线色值与缩进对齐文字、字母条底色与高度、索引条没有白底且有 ↑、
点 ↑ 回顶部、顶部右边两颗图标与 ＋ 的项）；release 包 73.9MB 已 `adb install -r` 装机。

**没法自己截图看观感** —— 色值和尺寸是量出来的，真机上那一眼还是得用户看。

## S5.5b「我」页 + 设置页照微信重排

用户的诉求：这一页照微信抄；原来平铺在「我」页上的那些入口**全部收进设置**、
在设置里**重新分类**；并且要求「微信那套固定色调你自己去学、自己应用，别我一个一个指」。
于是这一轮先把你三张截图（我页 / 设置页上下两屏）逐像素采了一遍，量出下面这套
**全站规矩**，再按它一次性改到位：

| 元素 | 微信实测 | 之前 |
|---|---|---|
| 页面底 / 分组标题条 | `#EDEDED` | `#F5F5F5` |
| 「卡片」 | **通栏白**（无圆角、无左右留白） | 圆角卡片 + 左右留白 |
| 行高 | **150px = 50dp** | 112rpx ≈ 58dp |
| 行分割线 | `#E5E5E5`，左缩进 16dp（有行首图标时从文字左边起） | 没有 |
| 主文字 / 副文字 / 箭头 | `#181818` / `#707070` / `#B0B0B0` | `#333` / `#999` / `#999` |
| 行首图标 | **彩色线稿**（绿 `#10B060`、黄 `#F0B010`、红 `#E06050`、浅蓝 `#20A0E0`、蓝 `#2080D0`） | 白字 + 渐变圆底 / PNG |
| 二级页顶栏 | 同一档灰 `#EDEDED` | `#F5F5F5` 或白 |

改了什么：

1. 新增共用件 `AppDimens.listRowRpx / listPadRpx / listIconRpx / listGapRpx /
   listDividerRpx / listIconDividerRpx` 与 `MineList / MineListItem / MineSwitchItem`
   （通栏白底、50dp 行、细线按有无图标分两档缩进）——**通讯录页也换成同一组常量**，
   微信里这两页的行高本来就是同一个数。
2. 「我」页重写成微信那样：**没有标题栏**（白底资料卡直接顶到状态栏），
   卡里是头像 + 昵称 + 「恩信号：xxx」+ 右上角二维码；下面只剩 `表情`、`设置` 两块。
3. 「设置」页按微信分四组：`账号`（个人资料 / 账号安全）、`通用`（通知 / 界面与显示）、
   `功能`（音视频通话）、`帮助与关于`（帮助中心 / 关于恩信 + 右侧版本号），
   最后单独一块居中的 `退出登录`。
4. 新增三个二级页：`设置 › 通知`（声音 / 震动）、`设置 › 界面与显示`（圆形头像 / 切换语言）、
   `设置 › 音视频通话`（通话诊断 / 保活通知 / 来电全屏 / debug 自检），
   原来混在一页的开关各归各位；`检查更新` 从「我」页搬到 `关于` 页（微信也在那儿）。
5. `个人信息` 页底部那条红字退出登录去掉了（微信没有；退出统一在设置页）。
6. `user.profile` 改回 **个人信息**（个人页 / 通讯录的人详情页标题），
   设置里那一行另用 `user.personalData` **个人资料** —— 微信正是「设置行叫个人资料、
   进去那页叫个人信息」。

刻意不做的：设置页那个**搜索框**（我们没有设置搜索，假框子比没有更糟）、
`切换账号`（没有第二账号）、底部两条合规链接（不是我们的）、
以及资料卡上的 `+ 状态` / `朋友`。

一处**背离**微信、但故意保留的：资料卡昵称后面那颗「已认证 / 未认证」小标签
（微信资料卡上没有这东西）——它是我们本来就有的信息，去掉就再也看不见了。

### 验证

`flutter analyze` 干净；全套 **1230 项通过**（原「我」页那组用例按新结构重写，
新增「设置页四组 + 单独一块退出登录」「四行都进得去」「这一页没有退出登录」
「通知两个开关落盘」「圆形头像落盘」）；release 包 73.9MB 已装机。

### S5.5b 补：资料卡上下留白（用户说「顶部顶得太高、身份那块太小」）

这一轮没法截图看（手机锁屏着，adb 截出来是黑的 / 锁屏界面），所以改成
**把你那张微信我页截图逐像素量出来、照着数字摆**：

| 位置（1080px 宽截图里的 px） | 微信实测 | 改前 | 改后 |
|---|---|---|---|
| 状态栏 → 头像顶 | 184 | **34** | **184**（`rpx(128)`） |
| 头像 | 172 | 182 | 182（`rpx(125)`） |
| 名字 / 恩信号 行顶 | 276 / 360 | 160 / 264 | 274 / ~385 |
| 那排小药丸 | 475~539（高 65） | 无 | 473~539（高 `rpx(46)`） |
| 药丸底 → 卡片底 | 65 | — | 66（`rpx(46)`） |
| 整卡高 | 604 | 366 | ~636 |

- 微信那片顶部留白是真的很大（62dp），之前只给了 `rpx(24)`，卡片就贴在状态栏上了。
- 「已认证」从**名字后面那颗小 chip** 挪到微信那排小药丸的位置（`rpx(44)` 的行距下方），
  样式也照微信实测：高 46rpx、全圆角、`#B2B2B2` 细边、24rpx 近黑字 + 小图标。
  这样卡片的骨架就和微信一致了（头像 → 名字 → 恩信号 → 一排药丸 → 底部留白）。
- 新增 **`test/features/mine_pages_test.dart` 里的几何回归**：
  卡片从 0 起画、名字距卡顶 = `rpx(128)+rpx(8)`、药丸高 `rpx(46)`、
  药丸底到卡底 `rpx(46)`、以及「除两行字外全是留白，合计 290rpx」——
  以后谁动这几个数就会被抓住（不用真机、不用截图）。

`flutter analyze` 干净；全套 **1231 项通过**；release 包已装机。

### S?「通知权限」那一行 + 个人信息 / 账号与安全两页照微信（2026-09-21）

**一、设置 › 通知 最上面多了一行「通知权限」**（`features/mine/notification_permission_row.dart`）：

- 它是**只读状态行**：右边直说「已开启 / 未开启」，点一下跳系统的应用通知设置。
  不做成开关 —— 通知权限是系统权限，App 自己关不掉，做开关就是做假的。
- 回到前台**必须重查**（`didChangeAppLifecycleState → resumed`），否则用户在系统里开了、
  这句话还写着「未开启」。有的 ROM 是弹框不是跳页，所以点完也补查一次。
- 与「通话保活通知」那一行的分工：那一行是**通话期间**要的那条常驻通知；
  这一行是「系统到底允不允许我们弹通知」，两者查同一件事但入口/目的不同，各留一行。
- ~~只有安卓画这一行（iOS 走系统设置，另说）~~ → **iOS 现在也画**（S12.43）：点一下跳本应用的设置页
  （苹果没有「本应用的通知设置」那种深链），所以这一行在 iPhone 上同样成立。

**二、声音 / 震动的默认值改成微信那套**（`data/model/app_setting.dart`）：

| | 老端 uniapp | 微信 | 现在 |
|---|---|---|---|
| `voiceStatus` | true | 开 | true（没变） |
| `vibrateStatus` | false | 开 | **true** |

`fromJson` 那个 key 缺失时的兜底也一起改成 true。**已存的设置优先**：老用户手机上存着的
那份不会被这次默认值改动覆盖（升级不会突然开始震）。

**三、音视频通话页删掉「通话诊断」一行**：那是 S6.5 之前排查打不通的工具，通话稳定后没用了。
诊断面板本身没删 —— **通话页长按浮层**还能打开（`call_page.dart`），只是不再占设置页一格。

**四、个人信息页**（`features/mine/profile_page.dart`）改成微信那套列表：通栏白底、
行高 50dp、行间细线从文字左边起、行首文字近黑 / 右侧值那档灰 / 箭头 `#B0B0B0`，
尺寸全部取 `AppDimens` 里那组共用常量（与设置页、「我」页同一套，不是这一页另定）。
保存按钮换成微信品牌绿 `#07C160`。刻意不画的：微信那页的「我的二维码」「更多」「我的地址」
（没有对应数据），微信也没有保存按钮（它改完即时上传，我们仍是一次性提交四个字段）。

**五、账号安全 → 「账号与安全」**（`features/mine/secure_page.dart`）：

- 微信 `设置 → 账号与安全` 那页**没有行首图标**，去掉我们之前那三个描边图标；
- 微信的退出入口只在「设置」最底下那一块，所以这页**去掉了底部那个红色退出按钮**
  （全 App 现在只有设置页能退，与微信一致）。
- 文案从「账号安全」改成微信的叫法「**账号与安全**」（设置页那一行、这页标题都跟着变）。

`flutter analyze` 干净；全套 **1233 项通过**（+2：通知权限那一行的三态与跳转、
账号与安全页没有退出登录）；release 包已装机。

### S?二维码页照微信重做 + 修改密码三步向导 + 修掉「认证账户」点不进去（2026-09-21）

**一、二维码页（`features/common/qrcode_page.dart`）整页按微信重排。**

色值与几何全部从用户给的微信截图**逐像素量的**（1080×2316，1rpx = 1.44px），
不是照着「差不多」摆的。量出来的关键值：

| | 微信实测 | 这里 |
|---|---|---|
| 顶栏 | **纯白**、**没有底下那条灰线**、标题黑 | 白底 `AppBar` + `shape: Border()` |
| 头像 | 169px（=116rpx）圆角方 | `ContactAvatar(sizeRpx: 116, radiusRpx: 12)` |
| 名字 | 与头像同排、字号 34rpx、与头像隔 21rpx | 同 |
| 二维码 | 726px（=**504rpx**）、居中 | `QrImageView(size: rpx(504), padding: zero)` |
| 头像底 → 码顶 | 52px（36rpx） | `rpx(30)`（`ContactAvatar` 盒子比头像高 6rpx） |
| 码底 → 提示 | 61px（42rpx） | 同 |
| 提示字 | `#989898` | `rpx(26)` + `text999` |
| 底部动作 | **绿 `#12744D`**（比品牌绿深，实测就是这个值） | 新增 `AppColors.linkGreen` |
| 动作 → 屏幕底 | 224px（含安全区） | `rpx(112)` + 安全区 |

- 底部那行改成微信的 **`扫一扫 | 保存图片`**（原来是一颗「保存到相册」按钮）：
  左边进扫一扫页，右边存图；中间一根同色细竖线（微信里量到也是同一个绿）。
- 标题从「我的二维码」改成微信的「**二维码**」（`user.qrcode`；`user.myQrcode`
  仍留给「我」页那颗二维码按钮的 tooltip）。
- `RepaintBoundary` 挪到「头像行 → 提示文字」这一块（存下来的图就是微信那种白底 + 码）。
- 新增**几何回归测试**（`test/features/qrcode_page_test.dart`）：白底白顶栏、码 504rpx 且居中、
  头像行往里缩 17rpx、三段竖排间距、底部动作行是 `linkGreen` 且距屏底 112rpx。

**二、修改密码改成**三步三个页面**（新页 `features/mine/password_change_page.dart`）。**

老端（和我们原来）是**一个弹层塞三栏**（验证码 / 新密码 / 重复新密码，一起填完再保存）。
现在按微信那种「一屏一项」的向导拆开：

| 步骤 | 已认证 | 未认证 |
|---|---|---|
| 1 | 验证码（右侧「发送验证码」，发完变 60 秒倒计时） | 原密码 |
| 2 | 新密码（6–16 位） | 同左 |
| 3 | 确认新密码 | 同左 |

- 每步：白底一栏 + 下面一行灰提示 + 一颗绿大按钮（`#07C160`）；**字段空着时按钮是灰的**
  （微信也是），校验也拆到各步（文案与顺序仍是老端那三条，见 `PasswordForm`）。
- **返回键 = 回上一步**（`PopScope` + 顶栏 `BackButton` 同一套逻辑），不是退出整页；
  来回翻步时填过的内容留着（四个 `TextEditingController` 由页面 State 拥有）。
- 密码框改为 `obscureText`（老端是明文）。
- 新增路由 `/mine/secure/password`（`AppRoutes.minePassword`）。

**三、修掉「认证账户」点了只弹「请先认证账户！」（真 bug）。**

那一行原来是 `_openSheet(editPassword: false)`，跟「我的账号」走**同一道**认证校验，
于是未认证的人点它永远被拦下 —— 而它**本来就是用来认证的**
（认证 = 把账号换成真实的手机号/邮箱，验证成功后服务端把 `is_auth` 置 1）。
老端那两行是分开的：`editAcc()` 才查 `is_auth`，认证那行直接进弹层。
现在 `_openAccountSheet({required bool checkAuth})`：「我的账号」传 true（保留提示），
「认证账户」传 false。测试里加了「点认证账户必须真的进弹层」。

`flutter analyze` 干净；全套 **1235 项通过**（+2：二维码页几何回归、未认证改密码走原密码）；
release 包已装机。

### S?弹窗统一成微信那个白框（2026-09-21）

**全站弹窗收敛到一个实现**：`core/ui/wechat_dialog.dart`。

以前是**各页各写一个 `AlertDialog`**（Material 那套：正文左对齐、小圆角、文字按钮），
十二个文件十三处，摆在一起一眼就看出是「拼的」。现在全部换成微信那个白框。

尺寸/配色同样是从用户给的微信截图**逐像素实采**（1080×2316，1rpx = 1.44px）：

| 元素 | 微信实测 | 这里 |
|---|---|---|
| 框宽 | 864px = **600rpx**（左右各留 75rpx） | `rpx(600)` |
| 圆角 | ≈24px | `rpx(17)` |
| 正文 | 居中、近黑、行高 1.4 | `rpx(33)` + `height: 1.4` |
| 正文上下留白 | 各 ≈70rpx | `rpx(62)` |
| 分割线 | `#E5E5E5` 0.5px | `AppColors.rowDivider` |
| 按钮行高 | 150px = **104rpx**（= 50dp） | `rpx(104)`，两颗等分 |
| 「取消」 | `#191919` | `text000` |
| 右边那颗 | **`#576B95`**（截图里的「退出」就是这个值） | 新增 `AppColors.wechatLinkBlue` |
| 破坏性动作 | —（微信删除类也是红） | `WeChatDialogTone.danger` |
| 遮罩 | 白底被罩成 118 = 黑 54% | 不传 `barrierColor`（Flutter 默认就是 `black54`） |

对外三个入口：`showWeChatConfirm`（确认框，返回 bool）、`showWeChatAlert`（只有「确定」）、
以及自定义内容时直接拼 `WeChatDialogBox`（`actions` 为空 = 不画按钮行，纯进度框用）。

**改到的地方**：退出登录（正文换成微信那句「退出后不会删除任何历史数据…」、右键「退出」）、
删消息 / 删表情 / 删会话 / 清空聊天记录 / 退群（`danger` 红字）、群成员那些确认框、
新朋友「拒绝 / 接受」（三态：点外面关掉什么都不做）、扫一扫结果（正文合成一块 + 复制）、
更新提示与下载进度（`onTap` 型按钮 = 只中断下载、不关框）、
语言选择（框里一行一项 + 取消）、群公告/群名那种输入弹窗。

**没动的**：`core/ui/success_check.dart` 那个「提交成功 ✓」是**动画浮层**不是确认框
（深色小框本来就是微信那套 toast 的样子），留着了。

`flutter analyze` 干净；全套 **1241 项通过**（+6：`test/core/wechat_dialog_test.dart`
把框宽/圆角/按钮行/三种按钮颜色/无按钮行/返回值/`onTap` 不关框全钉住）；release 包已装机。

## S5.5c 关于页照微信 + 更换账号改向导 + 全站去手机号（2026-09-21）

### 1. 「关于」页照微信重排（骨架仍是逐像素实采）

微信「关于微信」（1080×2316，3x → 1rpx = 1.44px）：

| 元素 | 微信实测 | 这里 |
|---|---|---|
| 顶栏 | **纯白、没有标题**（只有左上角返回箭头）、底下没有那条灰线 | `AppBar(title: SizedBox.shrink(), shape: Border())` |
| logo | 173×173px、圆角 ≈16px、水平居中 | `rpx(120)` + 圆角 `rpx(12)` |
| 顶栏底 → logo 顶 | 131px | `rpx(91)` |
| logo 底 → 名字顶 | 107px | `rpx(68)` |
| 名字 | 57px 粗体（「微信」两字宽 109px） | `rpx(40)` w600 |
| 版本号 | 44px（「Version 8.0.72」宽 289px） | `rpx(30)`，文案仍是 `Version $appVersion` |
| 版本底 → 首条细线 | 124px | `rpx(78)` |
| 列表块 | 细线 64..1015px（左右各缩 64px = 44rpx），行高 152px | `MineList(paddingRpx: 44, dividerIndentRpx: 0)` + 共用行高 |
| 三栏 | 功能介绍 / 投诉 / **版本更新**（右侧不写版本号） | 同 |
| 版权 | 居中 `#999999`，压在页面底部（末行距屏底 110px） | `text999`、`rpx(22)`、`SafeArea` 贴底 |

* `MineList` 新增 `paddingRpx`（整块白底的左右缩进；微信大多通栏，只有这一页缩）。
* 「版本更新」= 原来的「检查更新」（`runAppUpdate(isPrompt: true)`）。
* 「投诉」按用户要求**只做表面功夫**：复用 `core/ui/success_check.dart` 那个
  「提交成功 ✓」动画（和聊天信息页的投诉同一套）。
* 老端那七条特性（`aboutFeatures`）从关于页搬进新的二级页
  `features/mine/feature_page.dart`（路由 `/mine/about/feature`），观感沿用那一块列表。
* 页脚版权换成 `user.copyright` = **2026 Gracelink Team 版权所有**
  （英文包是 `© 2026 Gracelink Team. All Rights Reserved.`）。

### 2. 「更换账号」也拆成一屏一项的向导页

老端 / 我们原来都是一个底部弹层塞三栏（新账号 / 当前账号验证码 / 新账号验证码）。
新增 `features/mine/account_change_page.dart`（路由 `/mine/secure/account`），
步骤学微信「更换手机号」——**先填新号 → 验新号 → 验原号**：

| 步骤 | 已认证（`is_auth`） | 未认证 |
|---|---|---|
| 1 | 新邮箱（不是邮箱格式就拦） | 同左 |
| 2 | 新邮箱收到的验证码（右侧「发送验证码」→ 送**新邮箱**、type 4、60 秒倒计时） | 同左 |
| 3 | **当前账号**的验证码（发送 → 送当前账号） | 没有这一步（两步就走完） |

`schema` 不变（还是 `account` / `code` / `newCode` 三个字段，未认证时 `code` 为空）。
返回键仍是「回上一步」，填过的内容留着；`SecurePage` 也因此从 `StatefulWidget`
降回 `ConsumerWidget`（弹层那套 state 全删了）。

### 3. 全站去「手机号」：这套后端只验邮箱

后端 `User::checkAccount` 里 `regauth` 1/2/3 分别对应「只允许手机号 / 只允许邮箱 /
两者都行」，而**短信根本没接**，所以文案统一成邮箱口径：

* `user.emailOrPhone` → 「输入新的邮箱」；`user.inputEmailOrPhone` → 「请输入邮箱」；
* `user.stepCodeHint` → 「验证码将发送到当前账号绑定的邮箱」；
* `user.newAccount` → 「新邮箱」、`user.naCode` → 「新邮箱验证码」、
  `user.inputNewAccount` / `user.inputNaCode` 同步；
* 帮助中心第二条（为什么未认证）也去掉了手机号那句；
* **留着** `user.inputPhone`「请输入手机号」——它只在服务器把注册权限设成 1
  （只允许手机号）时才出现，那种配置下它才是对的。

`flutter analyze` 干净；全套 **1246 项通过**（+11：关于页三栏与骨架几何、功能介绍七条、
投诉动画、更换账号三步与两步、发送验证码 type=4）；release 包 73.9MB 已装机。

## S5.2c 好友资料页照微信重做 + 朋友资料页（2026-09-21）

### 1. `UserDetailPage` 换成微信「好友资料」那一页

骨架还是逐像素实采（用户给的截图，1080×2316、3x → 1rpx = 1.44px）：

| 元素 | 微信实测 | 这里 |
|---|---|---|
| 顶栏 | **纯白、没有标题**（左上返回箭头 + 右上「⋯」）、底下没有灰线 | `title: SizedBox.shrink()` + `shape: Border()` |
| 头像 | 163×163px、左缩 48px、与名字**顶对齐** | `ContactAvatar(sizeRpx: 113)` + `rpx(32)` |
| 头像右 → 名字左 | 63px | `rpx(44)` |
| 名字 | 57px 粗体（设过备注就显示备注） | `rpx(40)` w600 + `displayName` |
| 恩信号 / 地区 | 40px、`#666`，两行行距 72px | `rpx(28)` + `rpx(10)` 间隔 |
| 「朋友资料」栏 | 标题 40px、说明两行（56px 行距）、箭头 `#B2B2B2` | 标题 `rpx(28)` + 说明 `rpx(24)`/height 1.6 |
| 底部动作栏 | **居中「图标 + 蓝字」**：图标 55px、间距 27px、字 43px、行高 150px | `rpx(38)` / `rpx(19)` / `rpx(30)` / `rpx(104)` |
| 两栏之间那条线 | **通栏**（x 0..1079） | `AppColors.rowDivider` 通栏 |
| 蓝字颜色 | 实测均值 ≈ `#5A667F`（偏灰的蓝） | 复用 `AppColors.wechatLinkBlue`（`#576B95`，与弹窗同一支） |

* **去掉了邮箱那一行**，**也去掉了 IP 那一行**（用户要求）；顶部保留「地区：xxx」——
  它是服务端按上次登录 IP 查出的**归属地**（`Im::getUserInfo` 的 `location`），不含 IP 本身；
* **删除好友搬进右上角「⋯」**（微信也在那儿）：深色小卡片（`AppColors.menuDark`），
  点它仍走原来那个带「加入黑名单」开关的底部弹层；
* 底部那四栏（发消息 / 音视频通话 / 打电话 / 添加朋友）从**实心按钮**改成微信那种
  一栏一项；「群内管理」块（S5.2b）原样保留；
* 记上一笔服务端事实：`getUserInfo` 返回的 `account` 是**打过码的**
  （`substr(0,3).'******'.substr(-2)`），所以老端那个「打电话」按钮的手机号正则
  永远不成立 —— 逻辑留着，但真机上基本不会出现。

### 2. 新增「朋友资料」页（`features/contacts/friend_data_page.dart`）

微信「好友资料 → 朋友资料」：一栏一项（复用 `MineList` / `MineListItem`）

* **备注名**（可改，右侧显示当前备注或「未设置」）→ 老端 `friendApi.setNickname`；
* **个性签名**（只读，显示对方的 `motto`）——`UserDetail` 新增 `motto` 字段
  （`yu_user.motto` 那一列，`User::find` 原样带回来）；
* **性别**（只读，原来摆在详情页那一行）。

两个刻意的做法：这一页**自己拉一次详情**（只认 `userId`，从哪进来都一样）；
改过东西返回时 **`pop(true)`**，详情页据此重拉（名字与备注都要变）。
微信那一页的「标签 / 电话 / 附加图片 / 朋友权限」后端没有这些字段，不做。

路由：`/contacts/detail/friend?id=<用户 id>`（`AppRoutes.contactsFriendData`）。

`flutter analyze` 干净；全套 **1249 项通过**（新增：朋友资料栏与二级页、签名显示对方的
motto、不是好友就没有那一栏、备注在二级页改完返回详情页跟着变、删除好友走「⋯」菜单）；
release 包 73.9MB 已构建（真机当时已拔线，未安装）。

---

## 2026-09-21 好友资料三处修复（用户真机反馈）

### 1. 从单聊进「好友资料」报「服务器繁忙，请稍后再试」

根因在**聊天信息页**：`chat_info_page.dart` 的 `_openUser()` 把 `group_id` 无条件拼进
`/contacts/detail`，而**单聊的会话 id 就是对方的 `user_id`**。服务端
`Im::getUserInfo` 里是 `$group_id = explode('-', $group_id)[1];`（没有兜底），
`explode('-','5')[1]` 踩 undefined offset → ThinkPHP 把 notice 抛成异常 → HTTP 500
→ 客户端只拿到默认的「服务器繁忙」。

老端在这里有判断：`pages/message/detail.vue` 是
`"/pages/contacts/detail?id="+item.id+ (this.is_group==1 ? "&group_id="+this.contact_id : '')`。
我们移植时把 `is_group==1` 丢了。

两处修：

* `_openUser(userId, {groupId})`：`group_id` 只在**群聊**（那一片成员网格）里带；
  单聊的对方那格不带（`chat_info_page_test.dart` 新增两条：单聊不带、群聊带）；
* 仓库层兜底：`ContactRepository.userDetail()` **只有 `group-` 开头才发 `group_id`**
  —— 服务端那几个群管理接口（`removeUser` / `setNoSpeak` / `setManager`）也是
  `explode('-', $param['id'])[1]`，所以群里到处都是这个形状的 id，也就不会误伤。

### 2. 备注设过就再也清不掉 → 现在可以清空（要一个服务端小补丁）

服务端 `Friend::setNickname` 里 `if(!$param['nickname'])` 把**空串**也当成「没传」
拦下（老端前端也在空输入时直接弹「请输入备注！」），于是备注一旦设过就再也去不掉。

* 客户端 `friend_data_page.dart`：空输入 = **清空备注**，`nickname` 传空串；
  `ContactRepository.setFriendNickname()` 新增 `fallbackName`，备注为空时把本地
  **联系人 + 会话行**的 `displayName` 回落到对方真名（`UserDetail.title`，
  真名为空还会退到 `user_id`），通讯录/消息列表/聊天页标题立刻跟着变；
* 服务端补丁：`Friend.php` 的 `setNickname()` 改成 `if(!array_key_exists('nickname',$param))`，
  于是空串照常入库（`nickname=''`），其它地方本来就是
  `$friend['nickname'] ?: $user['realname']`，自动回落到真名，不需要改第二处。
  补丁包：`~/Downloads/gracelinkim-remark-clear-patch.zip`（1 个文件 + 说明）。

### 3. 朋友资料页「未设置」飘在行中间

`MineListItem` 的布局是 `Row[ Expanded(标签), trailingWidget ]`；那一格原先是
`Flexible(child: …)`，于是它和标签**按 flex 平分**了行宽，短值就落在行中间。
改成**定宽上限**（`ConstrainedBox(maxWidth: rpx(375))` + 单行省略号）：标签吃所有余量、
值贴行尾。回归测试直接量坐标（`user_detail_page_test.dart`：备注行留白 < 90px 且值在右半边、
签名行留白 < 40px；把实现换回 `Flexible` 时那条测试会以 150.57px 失败）。

`flutter analyze` 干净；全套 **1256 项通过**（新增 7 条）；release 包 73.9MB 已装机。

### 4. 「我的收藏」被当成群聊（用户 2026-09-21 报：群成员 0 人 / 群名称 / 群公告）

服务端把「我的收藏」那条会话存成 **`is_group = 3`**（`to_user = -1`，见
`User::setContact` 与 `Message::create`；老端 `is_group` 的取值是
**0 好友、1 群聊、2 系统通知、3 我的收藏 / 应用号**）。

聊天信息页当时写的是「`is_group != 0` 就算群」，于是收藏那一页长出了整块群的东西。

老端 `pages/message/detail.vue` 的门槛很清楚：成员/头像那块 `v-if="is_group<2"`、
群名/公告/群管理/退群那几块 `v-if="is_group==1"` —— **`3` 两样都没有**，
只剩免打扰 / 置顶 / 背景 / 查找记录那几行公共项。

改法：`chat_info_page.dart` 改成先判**种类**（`_kindOf`），
`_isGroup`（只有 1）、`_isPeerChat`（只有 0）各自判断；拉群成员、清空记录里的
「连服务端一起清」也都跟着按 `== 1` 走。顺手把模型里那个
`Conversation.isGroupChat` 从 `isGroup != 0` 改成 `isGroup == 1`
（同一个坑，虽然 lib 里没人用它），并在两边都写清 0/1/2/3 的含义。

`flutter analyze` 干净；全套 **1258 项通过**（新增：「我的收藏不当群处理」那条
把群成员请求与所有群行都钉住 + `isGroupChat` 的取值回归）；release 包 73.9MB
已构建（手机当时没插着，未安装）。

### 5. 同一台手机换账号后，「我的收藏」里 a 和 b 混在一起（用户 2026-09-21 报的「乱套了」）

诊断过程（先用代码把「服务端到底会不会串」排除掉，再落到本机）：

| 环节 | 服务端代码 | 结论 |
|---|---|---|
| 存 | `Message::sendMessage`：`if($param['toContactId']==-1){ $is_group=0; }` | 收藏被强制按单聊处理，`is_group>1` 本身还会被拒 |
| 记录标识 | `chat_identify = chat_identify($uid, -1)` | `-1-<uid>`，**带 user_id** |
| 拉历史 | `Im::getMessageList`：`is_numeric($toContactId) ? 0 : …` | 同上，只查自己那一份 |
| 列表预览 | `User::otherChat`：`chat_identify($uid, -1)` | 同上 |
| 推送 | `wsSendMsg(['-1', 你], 'simple', …)`（`is_group==0` 分支） | 只发给发送者，**不是群广播** |

所以服务端是按人分开的；**串的是本机那一份**：本地库没有账号维度，
退出登录只清了通讯录与几份本地偏好，**会话与消息一直留着**；而「我的收藏」的
会话 id 是**固定的 `-1`**（系统通知是 `system`，其它会话 id 都是对方的 `user_id`），
于是 a 的收藏与 b 的收藏落在本机**同一条会话**里，打开看就像两个人在一个群里说话。

改法：把「本机那一份」绑到账号上（**只在换账号时清，同账号重登保留缓存**）：

* `CredentialStore.keyLastUserId`：记住上次登录的 `user_id`（`clearSession` 不删它）；
* `SessionService._resetLocalDataForAccount()`：登录成功后、`applyLogin` **之前**
  **await** 比较 —— 账号变了就 `ConversationRepository.wipeLocal()`
  （清 `dbConversations` + `dbMessages`）并把四份按会话 id 存的本地偏好
  （不显示该聊天 / 手动未读 / 清空记录名单 / 最近表情）一起清掉。
  账号没变就不动。顺序很关键：放在 `applyLogin` 前且 await，否则新账号的首次
  同步可能跑在清理前面，把刚拉回来的数据又删一遍。

服务端数据不动，重新登录会重新拉会话列表、进会话时分页拉回历史。

`flutter analyze` 干净；全套 **1260 项通过**（新增两条：换账号清干净且记住新账号、
同账号重登保留本机缓存）；release 包 73.9MB 已装机。

### 6. 顺手：换账号时把「聊天背景」也清掉

上一节只清了会话/消息与四份按会话 id 存的本地偏好，**漏了聊天背景** ——
它是 `chat-bg-info<会话 id>`（图片存在 `<文档目录>/chat-bg/` 下），
换账号后跟**同一个人**聊会沿用上个账号设的图。

* `CredentialStore.chatBackgroundPrefix` + `clearChatBackgrounds()`：
  把 `getKeys()` 里所有以它开头的 key 删掉；
* `ChatBackgroundRepository.clearAll()`：清 key + 删 `<文档目录>/chat-bg/` 整个目录，
  并 `revision++` 让页面立刻重画。目录那一段包在 `try/catch` 里
  （拿不到文档目录的环境、文件被占都只记日志，不能影响登录）；
* `SessionService._resetLocalDataForAccount()` 里在换账号分支调用它。

`flutter analyze` 干净；全套 **1260 项通过**（两条换账号用例各加了一条背景断言：
换账号后 `chatBackground('u7').image` 为空、同账号重登仍是 `'/tmp/favor.png'`）；
release 包 73.9MB 已装机。

---

## 「灵听」音乐频道（2026-09-23，独立于聊天后端）

服务端「发现」页里可以填页面路径，所以这一块干脆做成了一个**站内频道**：
配置里填 `/pages/lingting/index` 就进得来（`compassRouteOf` 会剥掉 `/pages` 前缀）。

### 数据来源（第三方，与聊天后端无关）

`https://check-api.lingtingmusic.com`（接口清单见 `docs/api/lingting-api.md`）。四件事实测确认：

1. **信封不同**：`{success, errorCode, errorMessage, data}`，不是聊天的 `{code, msg, data}`；
   所以没有复用 `ApiClient`，而是新开了 `LingtingClient`（baseUrl / 请求头 / 信封各一套）；
2. **鉴权是 `memberId` + `token` 两个头**；匿名登录（`POST /v1/account/anonymous/login`）
   返回的 JWT **payload 里就带 `id`**，解出来就是 `memberId`（实测 `{"id":1404914, …}`）；
3. **写接口参数挂在 query 上**（`like?songId=27`、`collect?songSheetId=…`），
   body 反而是空的 —— 这一点与聊天接口相反，写错就是 400/500；
4. `lyric` 这一个字段**有两种形态**：详情接口给 `.lrc` 地址、搜索接口给歌词正文，
   所以 `LingtingLyricSource` 先判形态再决定要不要下载（判据：`http` 开头且无换行）。

### 分层

* `core/store/lingting_store.dart`：**另立一份**凭据（`anonymousId` / `token` / `memberId` / 搜索历史），
  刻意不塞进 `CredentialStore` —— 退出聊天账号不该把音乐会话一起清掉；
  `anonymousId` 生成一次就落盘（否则每次都会在灵听那边建一个新匿名账号）；
* `data/api/lingting/*`：`LingtingClient` + `LingtingApi`（首页五个接口并行、搜索三个并行，
  任一块挂了只让那一块空着）；
* `data/model/lingting/*`：歌曲 / 歌单 / 歌手 / 专辑 / banner / 首页聚合 / 搜索结果 / 歌词与 LRC 解析；
* `data/repo/lingting_repository.dart`：会话（401 自动重登一次）、歌词（按曲目缓存 + 两形态）、
  喜欢、播放与播放时长上报；
* `domain/lingting/*`：播放器（队列 / 上下首 / 三种循环模式 / 进度 / 乐观喜欢的喜欢集合）、
  首页与各详情页的 provider；
* `features/lingting/*`：首页、搜索、歌单、歌手、专辑、我喜欢的音乐、播放页、迷你播放条。

### 几处刻意的行为

* 播放器与语音消息**两套引擎分开**，只在一个点上握手：**开始放音乐时把语音停掉**；
  反过来，收到 `calling` 信令时把音乐**暂停**（铃声一起音乐就停，通话结束能接着听）；
* 播放列表里**不能播的歌（没 `audioLink`）直接不进队列**，一首都不能播就什么都不做；
* 「下一首」算出来还是自己（队列只有一首、随机抽到自己）→ **从头重播，不重新 `setUrl`**；
* 单曲循环只在**自然播完**时生效，手动点「下一首」照旧往后走；
* 播放记录每首只报一次，播放时长在暂停 / 切歌 / 停止时上报。

验证：`flutter analyze` 干净；全套 **1332 项通过**（新增 72 项：LRC 解析 14、模型 19、
播放器 24、页面 15）。

## 灵听：去掉「收藏 / 我喜欢的音乐」+ 首页视觉一次过（2026-09-23）

**为什么去掉**：灵听那套收藏是绑在 `memberId` 上的（`/v1/music/like`、`/v1/member/collect/*`
都要真 token 与真实账号），我们只借了它一个**匿名身份** —— 收藏进得去、但对用户没有意义
（换台设备就没了，也没法跟聊天账号对应）。所以整块不做，连模型里的 `like` 字段都**不解析**，
免得界面上再长出心形来。

删掉的东西（一个不留，避免「代码在但没人用」）：

* `lib/features/lingting/lingting_likes_page.dart`、`lib/domain/lingting/lingting_likes.dart`
* 路由 `/lingting/likes`（`AppRoutes.lingtingLikes`）与它的 import
* 播放页顶部那颗心形（顺带：顶部栏不再因为右侧有按钮而偏左）
* 歌单 / 专辑 / 歌手页进页面时那次 `seed(...)` 校正
* 接口层 `like` / `unlike` / `favorites` 三个方法，模型 `LingtingSong.liked` / `copyWith`
* i18n 键 `lingting.myLikes`、`lingting.emptyLikes`、`lingting.like`、`lingting.unlike`（中英各一份）
* 用例里对应的 3 条（喜欢打接口、收藏列表渲染、点心形取消喜欢）

**首页视觉**（老规矩：WeChat 那套浅灰分区，不要一片白糊到底）：

* 顶部一颗**搜索胶囊**（灰底圆角 + 放大镜 + 「搜索歌曲、歌手、歌单」），点了进搜索页 ——
  比丢一颗放大镜图标好找，也和音乐类 App 的常规一致；
* 区块之间加一条 **16rpx 的浅灰带**（`AppColors.page`）分区，白底只留给内容；
* 区块标题统一成「**绿色小竖条 + 标题**」，右侧「播放全部」带播放图标；
* banner 加圆角 + 底部**黑→透明渐变**，标题压在图上也读得清；指示点当前那颗拉长成小胶囊；
* 歌单卡 / 歌手圆头像都带**淡投影**，横滑排版才立得住。

顺手修的：歌曲行原来 `InkWell` 包在铺了不透明白底的 `Container` 里，**点下去没有水波纹**
（波纹被压在下面了）—— 换成 `Material(color:) + InkWell`；正在播那首的副标题也跟着**淡绿**，
整行不再是「只有名字变色」。

验证：`flutter analyze` 干净；全套 **1333 项通过**；release 包 74.2MB 已装机（登录态保留）。

## 灵听：歌词「看不到」的根因 + 播放页按微信版式重做（2026-09-23）

### 一、歌词为什么像没做（真因：每帧重算 + 闪转圈）

歌词其实一直在取，接口也通（实测那条 `.lrc` 能下到 1018 字节的真歌词）。
看不到的是**界面**：`lingtingLyricProvider` 原来 `ref.watch(lingtingPlayerProvider)`
整个状态，而播放器的 `position` 由 `just_audio` 的 `positionStream` 每秒推好几帧 ——
每来一帧歌词 provider 就重算一次，`AsyncValue` 回到 loading，`.when()` 就画转子，
于是「歌词」和「转圈」高频闪烁，观感上等于没有歌词。

修法两处，缺一不可：

* `lingtingLyricProvider` 改成 `select((state) => state.current)`（只看歌，别看进度）；
* 播放页 `.when(skipLoadingOnReload: true)`，切歌时保留上一首的歌词而不是闪一下转子。

回归用例是**数调用次数**的：进度跳 4 帧后 `repository.lyricCalls` 必须还是 1。
把实现换回旧写法跑一遍，它以 `Expected: <1> Actual: <5>` 失败 —— 以后能挡住复发。

顺带修掉两个「辅助「看不到」的因素」：

* `.lrc` 是**带 BOM** 的 UTF-8，解析前先 `stripBom`（第一行正文不再混进不可见字符）；
* 封面改成可点的提示已经不需要了 —— 换成顶栏明确的「歌曲 / 歌词」两个 tab。

**踩过并回退的一个坑**：一开始以为问题在「地址没转义」（COS 返回的地址里有空格、
中文、方括号），自己写了个 `encodeUrl` 逐段 `encodeComponent` —— 结果**二次转义**
（`%20` → `%2520`），COS 直接回 `NoSuchKey`。实测 `Uri.parse`（Dio 内部用的就是它）
本来就会转好，所以这里**什么都不该做**。用例现在钉住这一点：本机 HTTP 服务收到的
路径必须含 `%20` / `%E4%B8%80` / `%5B…%5D`，且**不含** `%25`。

### 二、播放页版式（照微信那个播放器）

```
⌄              歌曲 | 歌词              ↗
                 （封面唱盘，压缩即缩）
歌名
歌手 - 专辑
当前这一句歌词
              ⤓        ⋮
─────────●────────────────────
0:00                       5:52
   ↺1    |◀    ▶    ▶|    ☰
```

* 背景＝**封面放大 + 高斯模糊 + 压黑**（没封面时退回原来那层墨绿渐变）；
* 顶栏三块：收起（⌄）· 歌曲/歌词两个 tab（选中那条下面一道白线）· 分享（↗）；
* 歌名/歌手/当前歌词行**左对齐**摆在唱盘下面；
* 操作行只留**下载**和**更多**——「喜欢」「加入歌单」我们没有收藏那一套，
  不摆出来占地方（用户的决定）；
* 「更多」底部弹出三栏：**查看歌手 / 查看专辑 / 复制歌词**（复制的是整首歌词，
  有时间轴就按播放顺序拼行）。没有「定时关闭」（用户的决定）。
* 分享：复用聊天那套**转发选人**，选完把《歌名》- 歌手 + 音频直链当**文本消息**发出去。

### 三、下载（新功能）

灵听的音频是直链 mp3，下载＝**存到本机、之后播放走本地文件**（弱网/离线也能听）：

* 落盘 `<应用文档目录>/lingting/<歌曲 id>.mp3`，先写 `.part` 再改名（断网不留残文件）；
* 路径记在 `LingtingStore.downloads`（`{id: path}` 的 JSON），启动时把「记录里
  有、磁盘上没了」的剔除；`LingtingPlayerNotifier.startEngine` 有本地文件就用
  `setFilePath`，否则才 `setUrl`；
* 三种图标状态：下载（下箭头）→ 下载中（环形进度）→ 已下载（绿色对勾）；
  失败给一句提示，再点一次是重试。

### 四、顺手修的

* 首页「每日三十首」接口对新注册的匿名账号会回 **401**（同 token 换老账号就好使，
  实测多次）—— 这一块原来静悄悄空掉。现在拿不到就退到**置顶栏**的歌曲列表
  （新歌首发 → 纯音乐），并且**换标题显示**（不挂着「每日三十首」的名头冒充）；
* 唱盘外面套 `FittedBox(scaleDown)`：屏幕矮（小屏/横屏）时整体缩小，而不是把
  下面的按钮顶飞（原来 800×600 视口下会 overflow 44px）。

验证：`flutter analyze` 干净；全套 **1354 项通过**（新增 18 项：下载落盘 4、
分享文本 3、歌词 BOM/转义 4、播放页 tab/更多/剪贴板/下载键 6、首页兜底标题 1）；
release 包 74.2MB 已构建（**手机没插，没装机**）。

## 灵听：音乐通知（通知栏 / 锁屏 / 耳机键）（2026-09-23）

**为什么不是 `just_audio_background`**：它源码里只允许**一个**播放器实例
（第二个 `AudioPlayer` 一创建就抛 `supports only a single player instance`），
而我们还有语音消息、来电铃声、拨号音、消息提示音四个播放器 —— 装上它一点提示音
就炸。改用 `audio_service`：它**不代理播放器**（播放器还是我们自己那一个），
所以音乐与通话/语音那几套能共存。

### 一、分层（handler 不管播放，只管「告诉系统」和「接收系统按键」）

* `lib/domain/lingting/lingting_audio_handler.dart`
  * `mediaItemOf(song)`：歌曲 → 系统那份曲目（`id` 用歌曲 id，否则系统认不出换歌，
    通知栏不刷新；没封面时 `artUri` 给 `null`，不给空 Uri —— 否则通知栏出现空白图位）；
  * `publishQueue` / `publishState` / `publishIdle`：把队列、播放状态、总时长交给系统；
  * `onPlay` / `onPause` / `onNext` / `onPrevious` / `onSeek`：系统那几颗键**回调进
    `LingtingPlayerNotifier`**——通知栏按「下一首」和播放页按「下一首」是同一个方法，
    不会出现两条路各算一遍状态；
  * `activeLingtingAudioHandler`：全局一个、常驻，不属于任何页面；单测里为 `null`，
    播放器那头全是「有就用、没有就算」；
  * `initLingtingAudioService()`：**永不抛异常**（清单写错/ROM 限制也只当作
    「没有通知栏那一份」，不能连累 App 启动），且在 `runApp` 之前调用。
* `LingtingPlayerNotifier`：`build()` 里接线；`_syncSession()` 只在**关键节点**推
  （切歌、播/停、拖动、时长变化、队列变化）——进度由系统按
  `updatePosition + speed` 自己插值，**不每帧推**（那会把通知栏刷成电灯泡）；
  总时长只有播起来才知道，所以在 `publishState` 里补进当前曲目的 `duration`
  （锁屏进度条的分母）。
* `main.dart`：`AudioService.notificationClicked` → 回播放页（已经在播放页就不重复 push）。

### 二、安卓侧（两处）

* `AndroidManifest.xml`：`FOREGROUND_SERVICE_MEDIA_PLAYBACK` 权限（Android 14 起
  每种前台服务类型都要单独申请）、`com.ryanheise.audioservice.AudioService`
  （`foregroundServiceType="mediaPlayback"` + MediaBrowserService intent-filter）、
  `MediaButtonReceiver`（耳机线控），并声明 `xmlns:tools` 压掉 lint 误报。
  与通话那个 mic/camera 前台服务完全独立。
* `MainActivity.kt`：改继承 `AudioServiceActivity`（它只是重写了
  `provideFlutterEngine`）。**不换的话 Activity 会另起一个引擎 = 两个 Dart 世界**，
  点通知回 App 会看到「界面以为没在播、通知栏却在播」的分裂。

### 三、验证

* `flutter analyze` 干净；全套 **1377 项通过**（新增 23 项：媒体会话 12、
  播放器与通知栏联动 10、时长补进曲目 1）；合并清单已在 `build/app/intermediates/
  merged_manifests/release/` 里核对到那三条新声明；
* release 包 74.5MB 已构建（**手机没插，没装机**）。

---

## 灵听：歌词排版修正 + 音乐卡片分享（2026-09-24）

真机上用户报的两个「看着就不对」的问题，加上他自己挑的那条路线（新增消息类型）。
两处根因都是**实测校出来的**，不是猜的（数据见 `docs/api/lingting-api.md` 第二十三节）。

### 一、歌词为什么会铺成一坨（两个毛病叠在一起）

* **取错了源**：列表/搜索接口每条歌都带 `lyric`，它是**纯文本、用 `;` 当换行**
  （`;;` = 空行），而且**一个真换行都没有**（抽 180 首，0 首含 `\n`）。
  旧代码「只要有文本就不再去取 `.lrc`」，于是整首歌被当成一整段铺出来。
* **没拆分号**：`plainLyricLines` 原来只按换行拆，纯文本进来就是一整块。

改法（两段式，`LingtingRepository.quickLyric` / `timelineLyric`）：
1. `quickLyric`：**不发请求**，把手上那份纯文本按 `;`/`；` 拆成逐行显示；
2. `timelineLyric`：没有时间轴就去 `/v1/music/lyric` 要 `.lrc`（逐行带时间戳），
   拿到就替换界面那份 → 当前行高亮 + 自动滚中间那套才生效；**同一首歌只问一次**
   （`_timelineAsked`），失败/没有就当没有（歌词是锦上添花，不能把播放页变成错误态）。
3. `lingtingLyricProvider` 从 `FutureProvider` 变成 `AsyncNotifier`：`build()` 返回
   第一段，然后 `unawaited(_upgrade(...))` 后台升级成第二段（切歌就丢弃，避免把
   上一首的歌词贴到新歌上）。仍然**只 `select` 歌曲 id**，进度每帧跳动不会重算。

### 二、歌名里的 `[]` 是搜索命中标记（不是脏数据）

同一首歌：搜索回 `[一粒][麦子]`，详情/首页回 `一粒麦子`（180 条搜索结果里 179 条带标记，
首页 60 条 0 条带）。所以只在**解析层**统一去掉（`stripLingtingMarkup`，歌名/歌手/专辑/歌词
片段都过一遍），界面与分享出去的内容就都是干净的 —— 比「每个展示面各自记得去括号」可靠。
（做成高亮渲染也能，但那样要模型留住分段，先按用户要求「不要显示出来」处理。）

### 三、音乐卡片：新消息类型 `lingting`（用户选的 A 方案）

* **为什么能这么做**：服务端**不校验 `type` 白名单**（`Message` 模型只对 `text` 做长度与
  XSS 处理，`type` 原样入库），所以新类型能存、能转发、能通过 WS 推给客户端；
  `extends` 是 JSON 列，转发时随行带走，**卡片被转发也不会丢载荷**（已核 `Work::forwardMessage`）。
* **取舍（写清楚，以后别再纠结）**：官方网页端与旧 uniapp 收到会显示「暂不支持的消息类型」。
  服务端**一行都不用改**就能用；`~/Downloads/gracelinkim-music-push-patch.zip` 里那 6 行
  只是让服务端也认得出这个类型（把兜底文案从「[暂不支持]」换成「[音乐]」），
  而客户端离线通知**本来就显示「[音乐]」**（它拿的是整条消息 payload，按类型自己拼文案），
  所以那 6 行只在「payload 超 4KB 被丢掉」时才看得出来。故意不给整份 `common.php`，
  免得把「离线来电」那些改动冲掉。
* **一条消息长什么样**（照名片 `contact` 那套）：`content` 是会话列表/通知里那行字
  （`[音乐] 《歌名》- 歌手`），渲染要用的字段在 `extends`：
  `{songId, name, singer, cover, audioUrl}`。所以**对方点开不依赖联网**就能起播。
* **点一下做什么**：`playSong(卡片那首)` + `context.push('/lingting/player')`
  （聊天页与聊天记录页同一套；没有音频地址的裸记录只 toast，不跳空播放页）。
* **分享**：播放页的 ↗ 不再发「歌名 + 链接」的文本，改发 `sendMusicCard`。
  `shareTextOf` 与它的用例一起删掉了。

服务端补丁（可选、只影响离线通知文案）：
`/www/wwwroot/gracelinkim` 三处 —— `app/common.php` 的 `getMsgType()` 加
`case 'lingting'`、`zh_cn.php` / `en_us.php` 的 `messageType` 各加一个 `music` 键。

### 四、验证

* `flutter analyze` 干净；全套 **1399 项通过**（新增/改写：歌词仓库两段式 7 项、
  分号拆行与标记去除 4 项、模型 1 项、卡片模型 8 项、发送 2 项、渲染 1 项、
  点卡片 2 项、会话预览 1 项、歌词升级不转圈 1 项）；
* release 包 74.5MB 已构建，并已 `adb install -r` 装到真机（SM-S918U，保留登录态）。

### 五、结论：服务端补丁**可以不传**

上面那 6 行是**可选**的：不用它，音乐卡片在客户端侧完全正常（会话预览、气泡、离线通知
都显示「[音乐]」，点开照样播）。唯一的差别在服务端**兜底**场景：payload 超 4KB 被
`PushMessage` 丢掉时，服务端会用 `getMsgType()` 自己拼一行 —— 那时才会显示成
「[暂不支持的消息类型]」。日常一条音乐卡片只有几百字节，碰不到这条路径。

## 灵听：真机反馈的五件事（2026-09-25）

用户装机跑了一圈，报回四个 bug + 一个想要的功能。前两个是**同一个根因**。

### 一、根因：`await player.play()` —— just_audio 的 `play()` 要到「暂停/播完」才完成

`just_audio` 的 `play()` 文档原文：*「The Future returned by this method completes when
playback completes or is paused or stopped.」* 而我们的播放器里原来写的是
`await player.play()`（`startEngine` 与 `playEngine` 各一处），于是：

* `_startCurrent` 卡在那一行 → 后面那句「把歌名/歌手/封面推给通知栏」**永远等不到**。
  **用户看到的**：通知栏一直显示系统那句「正在播放音频」，**点一下播放/暂停才突然
  变成歌名封面歌手**（那一按才让上面那个 Future 完成），**换歌也一样**。
  同时被推迟的还有播放时长计时表（`_startClock`）与播放上报，那段听的秒数全丢。
* 聊天里点音乐卡片：`await playSong(...)` 后面才是 `context.push`，所以
  **歌响了页面没进去、再点一次才进**（第二次点击让上一次那个 Future 解脱）。

修法：
* 新增 `playWithoutWaiting(player)`：`unawaited(player.play().catchError(...))`，
  `startEngine` / `playEngine` 都不再 `await` 它（离开页面/暂停时它自己会收尾）；
* `_startCurrent` 里**先** `_syncSession(queue: true)` 再等引擎加载：元数据先到系统，
  通知栏一建出来就是对的（不给它「先按没歌名建一次」的机会）；
* 卡片那边改成「先把播放点着（不 await），马上 `context.push`」—— 起播要等一次网络
  （`setUrl`），不能把「进播放页」压在它后面。播放状态里「现在这首」在等网络**之前**
  就写好了，所以页面一开就有歌。
* 回归用例（都是真机现象直译）：`lingting_player_test.dart`「起播时先把歌名/歌手推给
  系统，不等引擎加载完」（把假引擎卡在 Completer 上）、`chat_preview_test.dart`
  「引擎还在加载（网络慢）也照样进播放页，不把它压在网络后面」。

### 二、下载一直失败：Dio 的 `receiveTimeout` 只管「等响应头」，body 卡住它不管

拿真实地址在本机连着测（同一个链接）：直接要整份经常**握手成功只给几 KB 就没声了**
（一次 0 字节、一次只到 32768 字节就卡死不动），而带 `Range: bytes=N-` 从断点接着要，
一次就把剩下的 13MB 全拿回来。原来那句 `dio.download` 既没有超时也不重试 → 永远是
「下载失败」。现在 `downloadLingtingSong` 自己管三件事：

1. **卡住就掐**：每轮一根看门狗（`stallTimeout`，默认 15s），超时没新字节就 `cancel`
   （注意**每一轮要新造一枚 CancelToken** —— 掐过的那枚已经废了，续传再用它就是
   「一上来就被取消」，这个坑是先写错再改的）；
2. **断了接着下**：带 `Range: bytes=N-` + `FileAccessMode.append`，不是从 0 重来，
   所以「一条连接只给一小截」也能靠多轮拼齐；
3. **长度对齐才算下好**：`Content-Range`（续传看它）/ `Content-Length`（整份看它）
   与磁盘字节数对上了才把 `.part` 改名成 `<id>.mp3`；服务端不认 Range（回 200 整份）时
   续写会把旧前缀拼进去 —— 这种情况整份丢掉重来，绝不让拼坏的文件冒充「已下载」。
* 失败时**保留** `.part`（下次接着下的原料，它不叫 `.mp3` 所以不会被当成下好了）；
* `lingting.downloadFailed` 提示后面**带上原因**（异常第一行，截 80 字）：三种失败
  （断了 / 服务端不理 / 没权限）以前提示一样，看屏幕分不出是哪种。
* 用例：`lingting_downloads_test.dart` 新增「第一条连接卡住 → 掐掉，带着 Range 从断点
  把剩下的拿完」「服务端不认 Range → 不把旧前缀拼进去」「一直断 → 抛异常、不留一个
  看着像下好了的 mp3，但留下断点」。写用例时还踩到一个测试环境的坑：本机 `HttpServer`
  只写 1000 字节时客户端**一个字节也收不到**（Dart HTTP 响应在缓冲），换成 100KB 才
  走通 —— 不要把「收不到数据」当成被测代码的问题。

### 三、卡片进来的播放页看不到歌手/专辑

原因：卡片的 `extends` 只装了 `{songId, name, singer, cover, audioUrl}`，**没有**
`singerId`/`albumId`，而「更多」里那两颗是**指着 id 的**（没有 id 就只能显示成灰的）。

* 新发的卡片补上 `singerId` / `album` / `albumId`；
* 老卡片（已经躺在聊天里的那些）由播放页按 `songId` 去 `/v1/music/detail` 补一次
  （`needsLingtingSongDetail`：只有「id 全缺」才补，列表/搜索进来的不发这个请求），
  补完歌手那行也会带上专辑名。测试里记得把 `lingtingRepositoryProvider` 换成假的，
  否则组件测试会真去请求灵听接口。

### 四、播放页左右滑动切换「封面 ⇄ 歌词」

上半屏那一整块换成 `PageView`（第 0 页唱盘、第 1 页歌词）：手指从右往左滑 → 歌词，
从左往右滑 → 回到封面；顶栏那两个 tab 与它同步（点 tab 也会滑过去）。歌词列表是纵向
滚动，和横向翻页不打架；进度条/按钮在 PageView 外面，拖它不会翻页。
用例：`lingting_pages_test.dart` 的「上半屏能横滑：封面 ←→ 歌词」。

### 五、验证

* `flutter analyze` 干净；全套 **1406 项通过**（新增/改写 7 项）；
* release 包已构建（`--target-platform android-arm64`），装机状态见当次对话。

## 「新的朋友」永远是空白的（2026-09-25 晚 · 第三批）

用户报：A 给 B 发了好友申请，B 打开「新的朋友」却是**暂无数据**。

**根因在客户端解析层，不在服务端**：`Friend::index()` 返回的是**原始表行**
（`friend_id` / `friend_user_id` / `create_user` / `status` / `remark` / `is_invite` …，
再额外挂 `create_user_info` / `user_id_info`），主键叫 **`friend_id`，根本没有 `id`**。
而 `FriendApply.fromServerJson` 把 `id` 当成「这条记录有效吗」的凭据，
`parseApplyRows` 又据此跳过——于是**每一条申请都被当成脏数据丢掉**：
「新的朋友」两个分段都永远空白，通讯录那个红点也永远是 0。

老端 `pages/contacts/friend.vue` 读的是 `x.friend_id` / `x.create_user_info` /
`x.user_id_info` / `x.status`，接受申请时发的也是 `x.friend_id`。

修的地方：
* 记录 id 就是 `friend_id`（另外兼容包一层的 `id`）；
* `parseApplyRows` 改成看 `friend_id` 判断脏数据；
* 拿掉「没给 `friend_id` 就退到对方 `user_id`」那条退路 —— 两张表的 id 各自
  自增、空间重叠，撞上了会去处理**别人**的申请。真缺了就留空，让 `respond()`
  报一句清楚的错。

顺带查明的一件事（不是 bug，不用改）：申请到达时服务端推的是 ws `simple`，
客户端有处理器（`chat_sync_service`）→「系统通知」会话能看到那条，**只有**
「新的朋友」列表因为上面这个解析问题一直空着。

用例：`test/contacts/friend_apply_test.dart` 把假数据里的 `id` 键删了（它本来就不存在，
正因为它把 bug 盖住了）并新增「服务端不给 id 也照样列得出来」；
`test/repo/friend_apply_repository_test.dart` 的假数据同步改成真实行形状。

## 登录/注册页微信风 + 「发现」那个红圈 0（2026-09-25 晚 · 第二批）

### 一、「发现」上挂着个红圈写着 0

服务端把「没有角标」也下发成 `badge: 0`（灵听那一项就是），而列表模式（`mode=1`）
**无条件**画角标（官格模式有 `hasBadge` 护着）—— 于是出现一个红圈写着 0。
现在：`CompassItem.hasBadge` 只认正数，列表模式也加上这道护；
顺手把 `badge == 1` 从「一个小胶囊」改成微信那种**小红点**（没有数字、正圆）。

### 二、登录/注册页改成微信风

原来那套是老端的：蓝底导航栏、白卡片表单行（`#eee` 分割线）、蓝底小按钮、
左上右下的「记住我 / 忘记密码」夹在表单和按钮中间。现在两边一起换成微信那套：

| 位置 | 微信风做法 |
|---|---|
| 底板 | 整页白底；右上角一行**轻量灰字**语言切换（原来占 150rpx 高） |
| 页头 | 居中 logo（160rpx，圆角 20）+ 站点名 |
| 表单 | **下划线输入行**：左标签 + 右输入 + 底下一根 `#EDEDED` 细线 |
| 主按钮 | **通栏绿**（`#07C160`、圆角 10、无投影），不再是品牌蓝 |
| 链子 | 「忘记密码 / 用密码登录」「注册」都是**绿色纯文字**（`AuthTextLink`）；验证码那颗「发送验证码」也从蓝底小方块改成绿字 |
| 顺序 | 表单 → **按钮** → 按钮下面那行（记住我 / 忘记密码），微信就是先按钮再链子 |
| 记住我 | 微信没这一项（它默认就记住），所以做成最轻的一行：一个绿勾 + 灰字 |

注册页同步：白底顶栏返回箭头（原来是蓝底）、同尺寸 logo、同样的下划线表单与
绿色按钮；顺手修了一个重复：同一个位置**并排画了两行「用户名/昵称」**。

用例：`login_page_test.dart` 新增三条（微信风那几件都在 / 版面顺序与通栏宽度 /
注册页昵称只占一行）、`compass_page_test.dart` 新增一条（`badge=0` 什么都不画，
`badge=1` 只有点没有数字）。

### 三、验证

* `flutter analyze` 干净；全套 **1428 项通过**；
* release 包已构建并装机（登录态保留）。

## 灵听通知栏歌词 + 点歌词跳转 + 下载管理页 + 服务端黑名单/注销（2026-09-25 晚）

### 一、通知栏那行歌词（`displaySubtitle`）

系统那里通知栏「第二行」的取值顺序是 `DISPLAY_SUBTITLE → ARTIST`，所以：
* `LingtingAudioHandler.publishLyric()` 把当前这句写进 `mediaItem.displaySubtitle`，
  传空串就把它去掉、第二行自动回到**歌手**（标题、封面、锁屏那份元数据一律不动）；
* 只在**换句**时推（进度每 200ms 一帧，每帧推会把通知栏刷成电灯泡）；
* 歌词来源：`LingtingPlayerNotifier._loadNotificationLyric()` 先问仓库要手上那份，
  没有时间轴再去要 `.lrc`；仓库按歌曲 id 缓存，**播放页同时在看歌词时不会多下一次**；
* 取不到（断网 / 没时间轴）就什么都不做，播放不受影响。

### 二、播放页：歌词字大一点 + 点某一句从那句开始放

* 歌词行字号提上去，当前那句更亮；
* `LingtingLyricView.onLineTap` → `player.seek(line.at)`（只有有时间轴的歌词才有这回事，
  纯文本那份点不动是对的）。

### 三、下载管理页（首页右上角那颗下载图标）

* **不挂数字角标**（用户定：右上角就一个下载符号）；
* 进去能看本机下过的全部歌曲、点一行从那儿播（队列就是下载列表，本地文件优先）、
  长按删除；
* **老记录补全**：最早那版下载只存了一条路径，于是列表里歌名是一个歌曲 id（`3866`）、
  封面空白、点一下没反应。现在打开这一页会按 `songId` 找 `/v1/music/detail` 补上
  歌名/歌手/封面/直链并存回本机清单（`enrichMissing()`，只补缺的字段）；
* **点一下没反应**还有第二个原因：`playQueue` 的过滤条件是 `song.audioUrl` 非空，
  老记录没有直链 → 被默默踢出队列。现在「有直链 **或** 本机已下好」都算能播。

### 四、服务端：删好友勾了拉黑之后自己加不回来

`Friend::del()` 勾拉黑时一次把两个方向的两行都写成 `status=3`，「谁拉黑了谁」就丢了，
`add()` 一看到 3 就拦 —— 主人自己也被拦住，永远提示「对方拒绝添加」。

改成**只写拉黑者自己那一行**（对方那行删掉）：`add()` 看「我这行是 3」= 我拉黑过 TA → 放行
（加回来顺手解除），看「TA 那行是 3」= TA 拉黑了我 → 拦住。老数据（两行都是 3）分不出谁
拉黑了谁，按「我自己要加回来」兜底并清掉残留。顺手修了「好友上限把申请中/黑名单也数进去」。

补丁：`C:\Users\David-local\Downloads\gracelinkim-server-patch-20260925.zip`（4 个文件 + 部署说明）。

### 五、注销账号（设置 → 账号与安全 → 注销账号）

* 服务端新增 `POST /enterprise/im/deleteAccount`（参数 `password`）：校验密码 → 管理员不许自注销
  → 事务里清好友关系/群成员/推送设备 → **软删除账号**（`delete_time`）→ 那枚 token 当场作废
  （`forbidUser_{uid}` 缓存，和后台「踢下线」同一套）→ 给好友推 `removeGroup`；
* 客户端：`AccountCancelPage`（后果逐条写清楚 + 填密码 + 二次确认弹窗），成功后清本机会话回登录页；
* 语言包新增 `user.cancel*` 五条（中英）。

### 六、验证

* `flutter analyze` 干净；全套 **1424 项通过**（本轮新增/改写 12 项：通知栏歌词 3、老记录补全 3、
  点歌词跳转 1、本地文件可播 1、下载管理页补全 1、注销账号 2，另加假仓库的缓存语义对齐）；
* release 包已构建（`--target-platform android-arm64`），装机状态见当次对话。

## 表情面板加「旗子」一栏（2026-09-25 晚 · 第四批）

用户要求：表情面板里再加一栏旗子。

### 一、国旗不是单个码点

国旗是**两个区域指示符拼起来**的序列（U+1F1E8 + U+1F1F3 = 🇨🇳），单码点的老写法
根本表达不了。于是三处一起动：

* `emoji.dart::emojiCharOf` —— 码值支持用 `-` 接的多段（`1f1e8-1f1f3`），按顺序拼成一个
  字符；**只要有一段不合法就整串不认**（宁可保留原文，不画半个旗子）；
* 表情 token 的正则从「十六进制」放宽到 `[\w-]+`，网页端/历史消息里的 `[!1f1e8-1f1f3]` 也认；
* `emoji_pack.dart` 新增 `flags` 一栏（40 面：周边国家在前，后面跟常见国家），
  分类图标就是国旗本身；语言包中英各加 `chat.emojiFlags`。

### 二、验证

* `flutter analyze` 干净；全套 **1432 项通过**；
* 新增 3 项用例：多段码值拼接（含「一段坏了整串不认」的边界）、token 形式的多段代码、
  旗子那一栏每条都是两段区域指示符且数量不少于 20；分类总数与英文文案一并钉住。
* release 包已构建并装机（`--target-platform android-arm64`）。

## 聊天里的网址点不动（2026-09-25 晚 · 第五批）

用户反馈：文字消息里带链接，点它**没有任何反应**。

### 一、根因：文字气泡压根没有手势

文字消息渲染成 `Text.rich` + 一串纯 `TextSpan`（为什么用 `Text.rich` 见表情那条：
`[!code]` 要拆成系统表情）。**没有 `recognizer`、外层也没有 `GestureDetector`** ——
图片/语音/文件那几类各自带 `onTap`，文字这一类的 `onTap` 只有长按菜单，于是点网址
就是一塹死路。老端是在文本里插 `<a href>`（uniapp 会处理），新端没把那一段接过来。

### 二、做法

* 新增 `core/util/link_text.dart`：`parseLinkSegments` 把纯文本拆成「文字 / 链接」。
  认 `http(s)://`、`www.`、以及**裸域名**（结尾过 TLD 白名单，免得 `报告.docx`、
  `1.5`、`v1.2.3` 被误认）；中文天然的断句边界（网址字符集只收 RFC 3986 那套 ASCII）；
  尾巴上的标点不收进地址；邮箱里的域名不单独成链接；裸域名/`www.` 打开时补 `http://`
  （HSTS 站点浏览器会自动升级，反过来硬套 https 会 TLS 报错）。
* `message_bubble.dart`：新增 `_MessageRichText`（有状态，因为 `TapGestureRecognizer`
  必须自己回收）+ 可测试的 `openChatLink` —— **在应用内浏览器**
  （`/mine/webview?title=域名&src=…`）打开，与「发现」外链、微信一致。
  链接是蓝字 `#576B95`、不加下划线（微信在绿气泡里也是这个蓝）。

### 三、验证

* `flutter analyze` 干净；全套 **1446 项通过**；
* 新增 14 项：`test/core/link_text_test.dart` 11 项（协议/`www.`/裸域名/中文断句/
  尾标点/邮箱/文件名不误判），`test/features/chat_link_test.dart` 3 项端到端
  （真消息 → 点那截蓝字 → 落地到应用内浏览器、标题是域名；裸域名与 `www.` 补 http；
  普通文字点了不乱跳）—— 用的就是 `tester.tapOnText` 真的按在那一截子上。

## 外链三道闸门：官方直开 / 腾讯系拦截 / 第三方确认（2026-09-25 晚 · 第六批）

用户定的规矩（比单纯「点得开」严得多）：

1. **自己的站点直接开**：`gracelink.cc` 及其**子域名**（`film.gracelink.cc`）→ 不弹任何确认，
   直接进应用内浏览器；
2. **微信/腾讯那一系拦住**：网址里出现 `weixin` / `wechat` / `tencent` / `tenpay` /
   `foxmail` / `qq.com` / `qq.cn` / 微信 / 腾讯 / 财付通 就跳到「已停止访问该网页」页
   （仿微信：白底、居中大红圈 + 感叹号、标题、灰色说明、地址原样列在下面）；
3. **其它第三方先确认**：到「即将打开第三方网页」页（灰圈问号、域名、完整地址、
   绿底「继续访问」/「取消」），点继续才真的建 webview。

### 实现

* `core/util/link_safety.dart`：`linkSafetyOf(url)` → `official / blocked / thirdParty`。
  两个关键判断：
  * **官方只认主机名**（不是整串包含）—— `evil.com/?ref=gracelink.cc` 是别人的站，
    而 `gracelink.cc.evil.com` 的主人是 `evil.com`，两者都算第三方（有用例钉住）；
  * 官方根域 = 写死的 `gracelink.cc` ∪ **从接口域名推出来的那两级**
    （`message.gracelink.cc` → `gracelink.cc`），将来换域名不用改代码。
* 两个新页 `features/common/link_blocked_page.dart` / `link_confirm_page.dart`
  + 路由 `/mine/linkBlocked`、`/mine/linkConfirm`（均带 `?url=`），文案进 i18n（中英）。
  确认页的「继续访问」用 `pushReplacement`：从网页返回时直接回聊天页，
  中间那页不会又冒出来（有用例钉住）。
* `openChatLink` 变成三道岔路的总闸；拦截页**一根 webview 都不建**（有用例钉住）。
* 「发现」页那些外链**没动**：那是后台配的官方入口，不走这套闸门（免得管理员配个
  腾讯域名反而被自己的规则拦死）。

### 验证

* `flutter analyze` 干净；全套 **1456 项通过**；
* 新增 10 项：`test/core/link_safety_test.dart` 7 项（子域名/参数里带域名/拿域名当子域的骗术/
  大小写/腾讯系各写法/空串），`chat_link_test.dart` 扩到 6 项（官方直开、子域名直开、
  第三方先确认再加载且返回不回到确认页、取消什么也不加载、腾讯系拦住且不建 webview）。

## 客户端整体体检（2026-09-25 深夜 · 第七批）

用户要求「整体检查一下有没有 bug 或细节问题」。做法是**先扫再改**：写几个一次性脚本
（i18n key 覆盖、控制器释放、测试覆盖地图、界面写死中文、空 catch、`substring`/`int.parse`
越界、网络超时与 WS 退避），再人手复核可疑处，最后只改能明确认定是问题的。

### 一、扫下来状态好的地方（记录一笔，以后不用重查）

* `flutter analyze` 干净、`dart format` 干净；247 个 lib 文件里 197 个被测试直接 import，
  **只有 `features/splash/` 一个目录完全没被测试碰到**（就是一个启动占位页）；
* 路由里的未实现页只剩 **1 个**（朋友圈，`_PendingRoute` 里写着「暂不做」）；
* 网络层：超时（10s 三件套）、错误分类、连接重试、WS 心跳 + 指数退避（带抖动）都在；
* 服务端 JSON 全走 `json_value.dart` 的宽松取值（`1`/`"1"`/`true` 都忍）；时间戳统一
  在 `time_units.dart` 归一化成毫秒（秒/毫秒两种口径都能吃）；
* 换账号/退出登录的本地数据清理很全（会话与消息、不显示该聊天、手动未读、清空名单、
  最近表情、聊天背景）；
* `// ignore` 只有 8 处，全是为「构造参数可注入」放开的 `prefer_initializing_formals`；
  空 catch 只有 5 处，逐一看过都是刻意吞的（关连接、后台 isolate、诊断探路）。

### 二、改掉的问题

1. **系统字号没兜底**（最要紧的一条）：全站版式按 `rpx` 画、行高写死，无障碍里的
   「超大字号」（2.0×）会把文字撑出容器。`app.dart` 的 builder 外面套
   `MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3)`：只封上限、不动下限。
2. **桌面上显示的还是 `gracelinkim` + Flutter 模板图标**：清单里 `android:label` 写死包名，
   mipmap 里是建工程时那份模板 PNG（和 SDK 模板 md5 一模一样）。现在：
   * 名字走 `@string/app_name`（values = 恩信，values-en = Gracelink）；
   * 图标用**我们自己的 logo**（`assets/images/logo.png`）经 ffmpeg 生成 5 档 legacy PNG，
     再加一份自适应图标（Android 8+）：背景取 logo 蓝底瓦片的边缘色 `#007AE7`，
     前景满幅（logo 里那个浅色图形占 62%，正好落在自适应图标 66% 的安全区里）。
3. **附件气泡的兜底名写死「文件」**：切 English 后不变。改成注入取词函数（与其他气泡一致）。
4. **注册成功提示写死中文**：改走新增的 `user.registerOk`（中英各一条）。
5. **通话诊断面板的配色在匹配文案**：`hint.contains('已连通')` —— 改个措辞颜色就静默失效。
   现在快照里带 `connected` 布尔字段，配色抽成可测的 `hintColorOf()`。
6. `new_friends_page` 写死 `Colors.orange` → `AppColors.orange`。
7. **把 i18n key 覆盖固化成用例**：`test/core/i18n_keys_test.dart` 扫全仓
   `t('...')`/`translate('...')` 与两份语言包对账（两种语言的 key 也要对齐）。
   以前这种情况只会「界面上显示一串 `chat.xxx`」，不崩不报错、测试全绿。

### 三、记在案但没动的

* **iOS 一把都没配**：`ios/Runner/Info.plist` 里没有任何 `NS*UsageDescription`，
  真上 iOS 的话，按住说话 / 相机 / 保存相册一碰就崩。只发安卓 APK 就无所谓。
* **英文界面是半成品**：网络层两条错误文案（`请求超时，请检查网络后重试`、
  `请求失败（HTTP $code）`）和**服务端下发的所有 msg** 都是中文，切到 English 也会
  原样弹出来 —— 要真做得多语言，得给错误码建一层文案映射。
* 语言包里 **193 个 key 已经没人用了**（老端遗留），`en` 还多一个拼写不同的
  `common.SearchNone`（已写进新用例的白名单）。
* `pubspec.yaml` 里的 `intl` 在 lib 里没人 import（留给 flutter_localizations）。
* 通话前台服务那条通知渠道名是中文写死（渠道只在首次创建时生效，改文案要卸载重装）。
* 朋友圈仍是占位页。

### 四、验证

* `flutter analyze` 干净；全套 **1465 项通过**（本轮新增 9 项：字号钳制 1、附件取词 3、
  诊断配色 3、文案 key 对账 2）；
* 图标肉眼验过（把生成结果套进圆形/圆角方形蒙版看安全区，小到 48px 也认得出）；
* release 包已构建，`aapt dump badging` 确认 `application-label:'恩信'`、
  `application-label-en:'Gracelink'`、图标指向自适应图标；
* ⚠️ 装这一版时**手机没连上**（`adb devices` 是空的），所以这一轮还没装机验证。

### 五、装机验收（2026-09-26 上午 · 手机连上了）

`adb install -r` 覆盖安装（保留登录态）：`dumpsys package` 记 `lastUpdateTime=2026-09-26 09:11:49`，
`firstInstallTime` 仍是 2026-09-20，`versionName=1.0.0`。三条改动逐项在真机确认：

| 项 | 证据 |
| --- | --- |
| 名字 | 桌面图标节点 `text="恩信"`（本机语言 zh-Hans-CN）；APK 内还带 `application-label-en='Gracelink'` |
| 图标 | 截屏裁切肉眼确认：蓝底圆角瓦片 + 浅色 logo 图形（不再是 Flutter 模板）；`aapt` 指向自适应图标 `res/BW.xml` |
| 字号兜底 | 系统 `font_scale=2.0` 时聊天列表正文文本带高 33/37/38/38px → 43/47/50/50px，**只放大 1.27–1.32×**；列表与底部四个导航项都不挤版。验完已把 `font_scale` 还原成 1.0 |
| 登录态 | App 起来直接是聊天列表（David Liu / 我的收藏 都在），没跳登录页 |

* 顺带发现：桌面上有**两个**「恩信」图标，两条节点的 `content-desc` 都是 `gracelinkim`，
  即同一个包的两条快捷方式（不是两个 App）。机上另外两个 gracelink 包
  （`cc.gracelink.oneline` = A Line a Day、`com.gracelink.piecesync`）都不是它。
  长按删掉多余的那个即可，不用改代码。
* 验收做的工具留在 `build/probe/`：`crop_png.js`（纯 Node 解/编 PNG + 裁切放大，
  因为预览服务只发 html，所以顺手写一份内嵌 data URI 的 html 供肉眼看）、
  `text_metrics.js`（量某区域内文本带的高度，用来算字号放大倍数）；
  产物 `home_ui.xml`、`home2.png`、`home_icons.png`、`fontA2.0.png`、`fontA1.0.png`。

## 换 Logo（2026-09-26 · 用户指定图，原图直贴）

用户给了一张新 logo（`Downloads/gracelink-logo.jpg`，940×940：浅蓝渐变圆盘 + 白色鸽子/麦穗
+ 底下「GraceLink」字样），要求软件 logo 换成它。**结论：原图直贴，不做任何加工**——
中间试过自动抠底（蓝度分离出白色图形、切掉文字、圆角瓦片上色），用户看过真机效果后否掉了
（「抠图更丑了，直接用我这个」），所以最终方案是：

* `assets/images/logo.png`：源图逐字节照搬（940×940 PNG；源文件用同目录那份 394KB 的
  `gracelink-logo.webp` 无损转出来，比 76KB 的 jpg 干净，画面同一张）；
* `android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png`：
  同一张图按 48/72/96/144/192 用 ffmpeg Lanczos 缩放，不抠底、不裁文字、不做圆角；
* **删掉了自适应图标那套**：`mipmap-anydpi-v26/ic_launcher.xml`、5 个
  `ic_launcher_foreground.png`、`values/colors.xml`。原因：自适应图标的前景层会被系统
  放大 1.5× 再按启动器蒙版裁切，等于擅自改了用户的图；去掉之后 Android 8+ 直接回退到
  位图图标（`android:icon="@mipmap/ic_launcher"` 没动），用户的图就原样显示了。

### 真机结果（SM-S918U / 三星桌面）

* 图标 = 原图本身（白底方图 + 蓝色渐变圆盘 + GraceLink 字样），启动器按自己的形状把外圈
  切圆；图标中心像素 `[136,192,232]` 与原图圆盘中心 `[134,190,230]` 一致，文字带上检出
  1474 个藏青像素 —— 证明显示的就是这张原图；
* 两个「恩信」桌面图标都换上了（重复的那条见上一节，长按删即可）；
* 改完重新构建（release APK 75.2MB，比上一版 74.6MB 大是因为多了 549KB 的 logo 资源）、
  `adb install -r` 成功、App 进程正常、logcat 无 FATAL/异常，登录态未丢。

### 留下的东西

* `build/probe/make_logo.js`：被否掉的那套「抠底→白色图形→蓝色瓦片→自适应图标 + legacy」
  流水线（以后真想要透明底风格时可直接复用）；`logo_analyze.js` / `logo_components.js`
  是当时用来量圆盘几何、选蓝度阈值、找杂点连通域的；
* `build/probe/icon_verify.js`（截图结构对账）、`icon_match.js`（把原图在截图里做
  多尺度模板匹配，用来确认启动器到底显示了什么）、`crop_png.js`（纯 Node 解/编 PNG +
  裁切放大 + 内嵌 data URI 的 html）。
* 提醒：原图是白底不透明，所以图标看着是「白瓦片里一个蓝圆盘」。以后想要「满幅蓝色
  圆角瓦片 + 白色图形」那种自适应图标风格，需要一张**透明底、不含文字**的 PNG。

## 启动屏：白底 + 原图居中（2026-09-26 · 第八批）

用户要求「启动图也用这张 logo，别改图」。摸清之后发现，按开关键看到的那一屏其实是
**三段拼的**，而且两段各有毛病：

| 段 | 谁在画 | 原来长什么样 | 现在 |
| --- | --- | --- | --- |
| A 系统启动窗口 | `LaunchTheme.windowBackground`（API 24+ 都走 `drawable-v21/launch_background.xml`） | `?android:colorBackground` **跟随系统深浅色** → 深色系统下先黑一屏 | 锁死纯白 + 原图居中（`@mipmap/launch_logo`，100dp，和 Flutter 侧 `rpx(180)` 对齐） |
| B Flutter `SplashPage` | Dart | 白底 + 180rpx logo + **图片下面又一行站点名** | 只留 logo + 转圈，品牌名只出现在图片里；logo **固定用本地资源**（不再优先服务端 `sysInfo.logo`） |
| C 目标页 | Flutter | 白底 | 未改 |

### 一、深色系统下「黑 → 白」闪一下（两个原因叠在一起）

* `values-night/styles.xml` 的 LaunchTheme 继承 `Theme.Black.NoTitleBar`，底色取暗色
  `colorBackground`；
* Flutter 侧只有亮色主题（`lib/app.dart:30` 只有 `theme`，没有 `darkTheme`），所以黑底窗口
  后面接的是白界面。

**做法：整体删掉 `values-night/styles.xml`**（不是改继承，是删）。理由：本 App 就没有暗色主题，
留一个 night 版本只会带来两个麻烦 —— 一是深色系统下闪黑，二是 **`values-night` 的优先级高于
`values-v31`**，会把下面 12+ 那两条启动屏属性整个盖掉。顺带把 `NormalTheme` 的
`windowBackground` 也从 `?android:colorBackground` 改成 `@android:color/white`。

### 二、Android 12+ 的强制启动屏（圆蒙版躲不掉）

本项目 `targetSdk=36`（跟 Flutter 默认值），API 31+ 系统**自己接管**启动屏：App 只能交
「一层纯色背景 + 一个图标」，图标规格是 288dp 画布、可见区直径 192dp（画布的 **2/3**），
「圆外的内容一律变透明」（官方文档原话）。我们的 logo 是白底方图 + 底下还有一行 GraceLink，
直接交上去四角和那行字就会被切掉。

**做法：不动图片，另出一张「带透明留白」的版本交给系统** —— 新增
`values-v31/styles.xml`（`windowSplashScreenBackground` 白 + `windowSplashScreenAnimatedIcon`
= `@mipmap/launch_logo_pad`）。`launch_logo_pad` 是把原图缩到画布的 **62%**（< 66.7%，留余量）
四周填透明，蒙版只切到透明区，原图一个像素不少，只是整体小一圈。
资源由 `build/probe/make_launch_logo.js` 生成（纯 Node，复用 `crop_png.js` 的 PNG 编解码，
面积平均 + 预乘 alpha 缩放，避免透明边渗黑）：五档密度各两张 ——
`launch_logo.png`（100dp 整图，给 ≤11）、`launch_logo_pad.png`（画布 192dp / 原图 119dp，给 12+）。

### 三、验证

* `flutter analyze` 干净、`dart format` 全仓干净、**1474 项测试通过**；
* 新增 `test/core/launch_resources_test.dart`（6 条）：五档密度两张图都在、`drawable-v21`
  是白底 + `gravity="center"`、`values-v31` 指向 `launch_logo_pad`、**`values-night/styles.xml`
  不许存在**，并且**真的解码 PNG 量几何** —— 12+ 那张的不透明包围盒必须小于画布 2/3、
  居中、四角 alpha=0（蒙版只切到留白），≤11 那张必须满幅不透明；
* 新增 `test/features/splash_page_test.dart`：logo 必须是本地 `AppInfo.logoAsset`，
  且页面上**一个 Text 都没有**（品牌名只出现一次）；
* `aapt2 dump resources` 反查 APK：`style/LaunchTheme` 的 `(v31)` 配置里
  `0x0101062c=@0x0106000b`（= `@android:color/white`）、`0x0101062d=@mipmap/launch_logo_pad`，
  而 `() `默认配置只有 windowBackground；`drawable/launch_background` 编译后是
  `drawable=@0x0106000b`（白）+ `src=@0x7f0c0001`（`mipmap/launch_logo`）、
  `gravity=0x11`（CENTER）；
* 真机（SM-S918U / Android 14）：`adb install -r` 成功、登录态保留；用
  `screenrecord` + `ffmpeg` 抽帧（20fps）看冷启动全过程 —— 启动屏那 1.1 秒里
  **蓝盘 + 底下 GraceLink 字样都完整**（就是「留白包裹」生效的样子），随后直接进主界面。

## 冷启动不再误报「通信断开」（2026-09-26 · 第九批）

用户反馈：一开 App 列表顶上就闪一条红色的「通信断开」，一两秒后自己消失，看着像出错。

**根因是拿「不是 connected」当断开用**：

```dart
// 旧：wsStatusProvider 的 AsyncValue 在首帧还是 loading（value 为 null），
// 于是冷启动那一瞬就被判成「断开」
final connected = ref.watch(
  wsStatusProvider.select((value) => value.value == WsStatus.connected),
);
```

而这一瞬在真机上是**必然**出现的：`main()` 里有 4 个 await（凭据 / 语言包 / 媒体会话等），
WS 还要等 `bootstrap` 才 `start()`，所以「还没开始连」这段时间列表早就画出来了。

**做法：连接状态按三态处理**，并新增一条中性的提示：

| 状态 | 界面 |
| --- | --- |
| `null`（状态流还没吐第一帧）/ `connecting` | 灰icon + 「连接中…」（`chat.wsConnecting`） |
| `connected` | 不显示 |
| `idle` / `reconnecting` / `closed` | 红icon + 「通信断开」（可点重连），不变 |

* `lib/features/conversations/conversation_list_page.dart`：两条提示抽成同一个
  `_buildStatusRow()`（行高/内边距/字号/右侧那颗 refresh 完全一致，只有左边图标与文案不同），
  所以「连接中 → 连上了」时不会有条横线抖一下；
* 新增文案 key `chat.wsConnecting`（中「连接中…」/ 英 `Connecting...`）；
* 用例：`test/features/conversation_list_test.dart` 里 `pumpApp` 多一个可注入状态流的参数，
  新增两条 —— 「状态流一帧都还没吐」时显示「连接中…」而不是「通信断开」，以及
  「connecting → connected」时提示直接消失；
* 真机冷启动抽帧核对：主界面出来后列表顶部是**灰色「连接中…」**，不再有红图标。

### 记在案但没做的（候选）

* 断线提示的**宽限期**：网络抖一下（重连退避 1s 起）也会闪一条红提示，可以「断开超过 N 秒
  才显示」；这次没做，因为用户反馈的是启动那一瞬、且加计时器会把状态判断复杂化；
* 客户端启动的 4 个 await 目前串行，理论上能压掉「连接中…」存在的时间（未做评估）。

## 列表第一行上方那段空白（2026-09-26 · 第十批）

用户反馈：消息列表第一行和顶部栏之间多了一段空白。

### 一、根因：安全区被吃了两次

`HomeShell` 的导航栏是自己撑高的（`height: statusBarHeight + customBarHeight`，其中
`statusBarHeight = MediaQuery.paddingOf(context).top`），而它**没有把 MediaQuery 里的这块
内边距去掉**。于是页面里的 `ListView` 又把它当自己的 padding 吃了一遍 —— Flutter 的
`BoxScrollView` 在 `padding == null` 时会自动把 `MediaQuery.padding` 包成 `SliverPadding`
（这是给「没有 AppBar 的页面自己顶到状态栏下」准备的）。

所以这段空白 = 状态栏高度：真机抽帧量到 79px（三星 76px 状态栏，`1080×2316 @2.625`），
用组件测试把状态栏设成 `FakeViewPadding(top: 76)` 能一模一样地复现（第一行顶从列表顶
往下偏 29.0dp）；不设（默认 0）就复现不出来 —— 这就是为什么之前没人发现。

### 二、改法

`lib/features/home/home_shell.dart`：把 `IndexedStack` 包一层
`MediaQuery.removePadding(removeTop: current.name != 'mine', removeBottom: true)`。

* 顶部：导航栏已经吃过一次，四个 tab 里只有「我」页**没有导航栏**（白底资料卡直接顶到
  状态栏，而且它自己用 `context.statusBarHeight` 留位），所以那一页不能去；
* 底部：手势条内边距被底部 tab 栏的 `SafeArea` 吃掉了，列表不该再留（顺手把列表末尾
  那段多出来的可滚动空白也去掉了）；
* 改在外壳而不是各个页面：同一个壳下的列表（消息、通讯录、发现）是同一个毛病，
  而且这些页面自己并不该关心「我在导航栏下面」。

### 三、验证

* 新增用例 `test/features/conversation_list_test.dart`：「列表第一行紧贴上面那条」
  —— 设了 `FakeViewPadding(top: 76)` 后，第一行顶 = 列表顶（±1dp），
  且列表看到的 `MediaQuery.paddingOf(...).top` 必须是 0；
* 新增用例 `test/features/mine_pages_test.dart`：「「我」页保留状态栏内边距」
  —— 守住上面那个例外（`top: 60` 物理像素 → 页面里读到 20dp）；
* `flutter analyze` 干净、`dart format` 全仓干净、**1476 项测试通过**；
* 探针（临时用例 + 真机抽帧）留在 `build/probe/`：`frames2/`、`frame_scan.js`、
  `splash_check.js`、`bands.html`、`top_band.html`（这次没写新脚本，都在用之前那套
  纯 Node 的 PNG 工具）。
* ⚠️ 这一版的 APK 已构建（75.9MB）但**没装上**：构建完手机就断开了，下次连上装机确认。

---

## 2026-09-26 · 通话 TURN：接上 Cloudflare Realtime TURN（0 元方案的第一步）

### 一、为什么做这个

「多人通话」讨论到最后落在预算上：总预算 ¥30/月，主站那台 4C4G 已经 ¥19。
自托管 LiveKit 要么跟 PHP 抢带宽（一次 4 人视频 8–10 Mbps，主站会一起卡），
要么再买一台（最少 +¥11~25）。而 Cloudflare 的 SFU / TURN 是**按流量**计费、
**每月前 1,000 GB 免费**（SFU 与 TURN 共用额度），群通话的量级根本摸不到线。

顺序上先做 TURN（不是 SFU）：现有 1:1 的通话里有 `ownTurnServers` 是空的，
代码注释自己写着「两边都在对称 NAT / 移动网络后面时没有 TURN 就是打不通」
（规划书风险 #1）——**群通话同样绕不过这道坎**，而修它对 1:1 立刻有收益。

### 二、服务端（补丁包已生成）

`build/server-patch/gracelinkim-server-patch-20260926-turn.zip`（含 README.txt）：

* `app/enterprise/controller/Im.php` 新增 `turnCredentials()`：拿 `.env` 里的
  TURN Key 去 Cloudflare 换**短时凭据**（官方上限 48 小时，默认 24 小时），
  **全站共用一条并缓存 12 小时**（凭据不绑定用户，所以每 12 小时最多请求一次）；
* `config/realtime.php`（新）：`REALTIME_TURN_KEY_ID` / `REALTIME_TURN_API_TOKEN` /
  `REALTIME_TURN_TTL` 全部走 `.env` —— **绝不放后台 chatInfo**，那个 JSON 会随
  `getSystemInfo` 下发给每个客户端，等于公开密钥；
* 三条「正常返回」：没配密钥 / 没 curl / Cloudflare 报错，一律回空列表 + trace，
  客户端退回「只有 STUN」，**一次都不给客户端报错**（通话不该因为 TURN 挂了而挂）。

### 三、客户端

* `lib/domain/call/turn_credentials.dart`（新）：`parseTurnIceServers()` 纯函数
  （补协议头、丢 53 端口、去重、坏条目整条丢）+ `TurnCredentialService`
  （缓存到 `expiresIn` 打八折、并发只发一次、失败静默 + 失败后 5 分钟退避 ——
  站点配了密钥而 Cloudflare 连不上时，不能让每通电话都白等那 4 秒）+ provider；
* `lib/data/media/call_media_engine.dart`：`withLazyIceServers` 新增可选
  `turnIceServers`；新增 `resolveIceServers()`（站内那份在前、TURN 在后；
  取不到就原样返回站内那份）；`_activeIceServers` 记住实际用的那份；
* `lib/domain/call/call_diagnostics.dart`：新增 `updateIceServers()` —— `begin`
  在会话一起来就调了，而 TURN 要等建连接那一刻才知道有没有拿到；
  `call_controller.dart` 在 `media.open()` 之后补记一笔，诊断面板与导出报告里
  就能看到 `turn:turn.cloudflare.com...（带账号）` 这一行。

### 四、验证

* 新增 `test/call/turn_credentials_test.dart`（11 条：解析 5 + 服务 6）、
  `test/call/call_media_engine_test.dart`（5 条）、诊断与控制器各 +1 条；
* `flutter analyze` 干净、`dart format` 全仓干净、**1495 项测试通过**（+19）；
* release 包 75.9MB 已构建；⚠️ 没装机：`adb devices` 为空（手机没连上）。

### 五、下一步（未做）

1. 用户在 Cloudflare 建 TURN Key、填 `.env`、部署补丁 → 真机验证
   （看诊断面板里出现 `relay` 候选 = TURN 真的用上了）；
2. 群通话走 Cloudflare **Realtime SFU**（同样是免费额度内）：服务端加信令接口
   （CF 由 SFU 出 offer，后端用 App Secret 把客户端的 answer 通过
   `PUT /apps/{appId}/sessions/{sessionId}/renegotiate` 交回去 —— 与现有
   「服务端中转 SDP」的形状完全一致），客户端加房间状态机与发布/订阅。

## 2026-09-26（补）：Cloudflare TURN 真机验证 —— **通过**

用户已在 Cloudflare 建 TURN Key、填 `.env`、部署补丁；本轮用 `adb` 长按通话页中间那块
（`call_page.dart` 的浮层长按）打开「通话诊断」取证，一通**手机关 WiFi 走流量 ↔ 网页端**
的语音通话（手机为被叫）：

| 看哪 | 实测 | 结论 |
| --- | --- | --- |
| ICE 服务器 | `turn:turn.cloudflare.com:3478?transport=udp`、`:3478?transport=tcp`、`turns::5349?transport=tcp`、`:443?transport=udp`、`:80?transport=tcp`、`turns::443?transport=tcp`**（带账号）** | `.env` 那把 Key 生效：服务端换到短时凭据、客户端取回并交给插件（六条 URL 与 CF 返回的一模一样） |
| 候选 | **本机 15（host 6 / srflx 3 / relay 6）** / 对方 18（host 16 / srflx 2） | **`relay` 6 条 = TURN 中继地址分配成功**（过去这个 App 永远不可能出现 relay）。对端（老网页端）没有 relay：TURN 只配在 Flutter 端 |
| 连接 | `srflx → srflx`，RTT 72ms，15kbps↑/71kbps↓ | 这一通实际走的是**打洞直连**，TURN 是备着的（正是想要的：先打洞、打不通再中继） |

### 同一轮发现的新问题（未修，已记）

**ICE 候选信令会成批超时**：这通里 `iceCandidate` 成功 15 条、**失败 13 条**，时间线写着
`NetworkUnavailableException(请求超时，请检查网络后重试)`，13 条全挤在 `+14.29s ~ +15.66s`
一秒多里（另有 `+20.37s` 一条）。这通在 `+6.54s` 已经 ICE 连通，所以没影响结果；
但**中继候选正是靠这些信令发出去的** —— 真要兜底时（对端只有 TURN 能通），候选发不出去
等于兜底失效。`NetworkUnavailableException` 只由 Dio 的 timeout 类错误映射（见
`api_client.dart` 的 `_mapDioException`），所以是「请求超时」而不是服务端拒绝。
可疑点：候选是并发发的，走的又是同一个 Dio 实例（连接池/keep-alive 被占），
要么给候选信令加「串行 + 重试」，要么单独一条连接。

### 收尾：候选信令串行化（已修 + 真机对照通过）

改动：`call_controller.dart` 里 `iceCandidate` 不再逐条并发 `sendToMsg`，改成
**一条串行队列**（`_queueLocalCandidate` / `_sendCandidate`），每条最多试 3 次；
关键信令（calling / acceptRtc / offer / answer / 挂断 / 忙线）不走这条队列，
所以不会被候选拖慢（有一条用例专钉这一点）。队列在会话开始（`_trackRecording`）
开门、`_endCall` 关门、控制器放掉即停。
`call_diagnostics.dart` 新增 `signalRetried()`：重试只进时间线，**不动计数**——
面板那句「信令：iceCandidate 22」要一直表示「想发 22 条」。

真机对照（同一位用户、同样手机关 WiFi 走流量、同样网页端对端）：

| | 改之前 | 改之后 |
| --- | --- | --- |
| 信令那一行 | `iceCandidate 15 ｜ 失败 iceCandidate 13` | **`iceCandidate 22`（没有失败段）** |
| 时间线 | 13 条 `NetworkUnavailableException(请求超时)` | 无 |
| 候选 | 本机 15（host 6 / srflx 3 / relay 6） | 本机 22（host 6 / srflx 4 / relay 12），**22 条全部发出** |
| 连接 | srflx → srflx，RTT 72ms | host → host（手机走流量、对端走 WiFi，host 直连=双方都有全局 IPv6），RTT 58ms |

结论：**每条候选都发出去了**（22 发 22 成），中继候选不会再被丢掉 —— TURN 的兜底
从「配了但可能发不出去」变成「配了而且一定发得出去」。

验证：`flutter analyze` 干净、`dart format` 干净、**1501 项测试通过**（+3，
新增用例：一批候选同时只有一条在飞 / 失败重试到 3 次且计数口径不变 /
候选卡死也不挡住挂断）、release 包已装机（14:19）。

## 2026-09-26（群通话第一步）：CF SFU 契约 + 串行队列 + 控制面接口

用户决定：**走 Cloudflare 裸 SFU**（不做 mesh、不买 SDK），规模 **5–9 人**，
场景是**语音 + 一个人共享屏幕**（不会全员视频）。

本轮只做**能被验证的那半**（本机没有 php，服务端写了也验不了，会变成"我猜它对"）：

| 落什么 | 文件 | 验什么 |
| --- | --- | --- |
| 线格式契约（6 个接口、与 CF 的映射、三条硬规则、错误码表） | `docs/protocol/sfu-group-call.md` | 服务端/客户端的共同依据 |
| 失败分类：把「明确被拒」与「结果未知」分开 | `lib/domain/group_call/sfu_failure.dart` | code / HTTP 异常 → 要不要重建会话 |
| **每会话一条串行队列**（操作跨越整个 SDP 交换） | `lib/domain/group_call/sfu_session_queue.dart` | 并发提交不越序、未知结果即毒化 |
| 控制面 6 个接口 + 返回模型 | `lib/data/api/sfu_api.dart`、`lib/data/model/sfu_models.dart`、`endpoints.dart` | 路径与字段（服务端照这个实现） |
| 测试 20 条 | `test/group_call/` | 见下 |

三条从 CF 文档核出来的硬规则（都写进了契约与代码注释）：

1. 同一 session 的改动**必须串行**，且一次改动要**跨越完整 SDP 交换**才算完成（并发会被 CF 拒 406）；
2. **结果不确定时不要重试**（`tracks/new` 不幂等，重复会重复分配）→ 判为"未知结果"→
   **毒化会话 + 换新会话重建**；
3. 订阅靠"发布者 sessionId + trackName"，房间发现由我们的服务端维护（CF 不提供），
   发布者重建会换 sessionId → 客户端按注册表 `epoch` 收敛。

⚠️ **与 `call_controller` 里那条 ICE 候选队列策略相反**，两处注释互相点名，别互相抄：
候选**幂等无害**所以失败重试 3 次；SFU 的 `tracks/new` **不幂等**所以失败即毒化重建。

验证：`flutter analyze` 干净、`dart format` 干净、**1521 项测试通过**（+20）。

### S6.10 续：两条会话的 SDP 交换 + 房间状态机（2026-09-26）

| 落什么 | 文件 | 验什么 |
| --- | --- | --- |
| 房间状态机：按快照对账订阅、epoch 收敛、掉线重建 | `lib/domain/group_call/sfu_room.dart` | 补差集不重订、发布者换 sessionId 要退订再重订、毒化即重建（同一时刻只一次） |
| 有界等候选（非 trickle 的硬要求，且在队列内部） | `lib/domain/group_call/sfu_ice_gathering.dart` | 收齐即走、超时**照样放行**（不能把会话堵死）、可反复用 |
| 真机那侧：发布/接收两条会话的 SDP 交换 | `lib/data/media/sfu_peer_connection.dart` | CF 的 connection patterns 逐条翻译（含 `getLocalDescription()` 那份、`answerSfuOffer`、`prepareClose→force`） |
| 本机媒体（只采一次，两条会话共用） | `lib/data/media/sfu_local_media.dart` | mic + 屏幕；共享屏顺序仍是「投屏同意 → 前台服务升 `mediaProjection` → startScreen」 |
| 远端流认人 | `SfuRoom._watchIncoming` / `incomingMedia` | `mid → 谁的哪条 track`；认不出来的丢弃 |
| 测试 28 条 | `test/group_call/`（共 48 条） | 详见下 |

这一轮从 CF 文档又核出两条（都已写进契约的「实现对照」表）：

1. **发出去的必须是收齐候选之后的 SDP** —— 要读 `pc.getLocalDescription()`，
   `createOffer()` 返回的那份里还没有候选；
2. **应用完 answer 要等到 ICE 连上**（`onConnectionState == connected`）再往这条会话上发请求；
   等不到就按"结果未知"→ 毒化 + 换新会话重建（`SfuRoom.connectTimeout` 终于有了用处）。

三条容易写反的地方，都在代码里互相点名了：

* **候选幂等 → 重试 3 次**（`call_controller`）；**`tracks/new` 不幂等 → 失败即毒化重建**（`sfu_session_queue`）；
* 等候选**必须有界**（5 秒），因为它跑在会话队列内部：一次等不到的 gathering 会把整条会话堵死；
* 订阅的 mid 要**先记账再作答**（`onTrack` 可能比 `/renegotiate` 早到），谈不成再撤销记账
  —— 否则要么丢流、要么差集以为"已经订上了"而永远不重订。

验证：`flutter analyze` 干净、`dart format` 干净、**1549 项测试通过**（+28），其中 `test/group_call/` 48 条。

### S6.10 服务端：SFU 代理 + 房间注册表（2026-09-26）

补丁包：`build/server-patch/gracelinkim-server-patch-20260926-sfu.zip`
（整份 `app/enterprise/controller/Sfu.php` + `config/realtime.php` + `sql/` + README；
**不改任何已有文件**，不碰路由）。

| 落什么 | 位置 | 要点 |
| --- | --- | --- |
| 8 个代理动作（session/publish/subscribe/renegotiate/close/room/heartbeat/leave） | `app/enterprise/controller/Sfu.php` | 动作名都是单个小写单词，路径 `/enterprise/sfu/…`（不依赖驼峰转换） |
| 房间注册表 | 表 `sfu_room_member`（代码自动建） | `(room_id,user_id,purpose)` 唯一；`tracks`/`mids` 两列把"谁发布了什么"和 mid→track 名都记下 |
| 心跳与 TTL | `heartbeat` 动作 + `room` 里的 prune | 客户端 25 秒一次；90 秒没动静算掉线（否则"静音坐着的发布者"会被清掉、别人退订他的声音） |
| 业务码映射 | `cf()` | 400/406 → 明确被拒；410/超时/5xx → **结果未知**（客户端重建会话）；401 → 配置错 |
| 两条安全边界 | `roomId()` / `requireSession()` / `findPublished()` | ①是不是群成员；②这个 session_id 是不是你的；③要订的 track 是不是也在同一个房间（CF 自己不管权限） |
| 静态自检 | `check_server.js` | 本机没 php，所以用 node 查括号/方法名/配置键/建表字段/**客户端路径↔动作**/业务码 |

客户端的相应改动：路径全部移到 `/enterprise/sfu/…`、新增 `SfuPaths.heartbeat` 与
`SfuApi.heartbeat()`、`SfuRoom` 加了心跳定时器（25 秒一次；回包 epoch 与手里快照
不一致就重新对账 —— **WS 推送丢了也能自愈**）。

验证：`flutter analyze` 干净、`dart format` 干净、**1556 项测试通过**（+7，其中
`test/group_call/` 55 条）、服务端静态自检 8 组全过。

⚠️ 本机没有 php，跑不了 `php -l`：服务端那份只能靠静态自检 + 真机验证。

### S6.11 群通话界面 + 接到房间状态机（2026-09-26）

| 落什么 | 位置 | 要点 |
| --- | --- | --- |
| 控制器 | `lib/features/group_call/group_call_controller.dart` | 名单（群成员接口）+ 房间状态合成一份；共享屏**三步顺序**；保活；挂断幂等 |
| 页面 | `lib/features/group_call/group_call_page.dart` | 主区域三态（共享屏 / 说话人 / 头像墙）、成员面板、成员·麦克风·共享屏·挂断四颗钮 |
| 说话人 | `lib/domain/group_call/sfu_speaker.dart` + `SfuRoom` 轮询 | 能量取自接收会话 `getStats()` 的 `audioLevel`，按接收侧 mid 归位到人；**拿不到就是没人说话**（头像墙），不猜 |
| 入口 | 群资料页群卡片第一行（**不放消息流**，防误触）+ 路由 `/message/group/call` | 1:1 通话中不给进（弹提示） |
| 共用件 | `lib/features/call/widgets/call_round_button.dart` | 圆钮与开关圆钮从 1:1 通话页抽出来，两页共用一套观感 |
| 文案 | `assets/i18n/zh-Hans.json` + `en.json` | 新增 18 条 `group.call*`（带 `{n}` / `{name}` 占位） |

三个容易踩空的地方（都有用例钉住）：

* **共享屏的顺序**：投屏授权 → 前台服务类型升 `mediaProjection` → 取流；取流失败要回滚类型位，
  否则前台服务会一直挂着「屏幕录制」那个标记；
* **说话人是采出来的、不是猜的**：`audioLevel` 拿不到就退回头像墙；能量要按**接收侧 mid**
  归位（归不了位的丢掉 —— 不认识的流不能变成一个人名）；
* **页面级排版**：主区域尺寸按实际高度算（写死 rpx 在横屏/小窗/系统大字体下会撑爆），
  说话人下面那条放不下一块砖时宁可不画。

验证：`flutter analyze` 干净、`dart format` 干净、**1585 项测试通过**（+29：控制器 14、
说话人 7、房间 3、页面 5）。

页面测试有两个坑值得记着（都是本机看出来的，不是真机才发现）：**画布要设成手机尺寸**
（默认 800x600 又宽又矮，主区域根本摆不下，报的还是溢出）；**点按钮前要等路由那 300ms
滑完**（半路上下手，整页还在屏幕外，点到的是空白）。

### S6.12 群通话：WS `sfuRoom` 事件 + 诊断面板（2026-09-26）

| 落什么 | 位置 | 要点 |
| --- | --- | --- |
| 事件枢纽 | `lib/domain/group_call/group_call_hub.dart` | 通话页进出时 `attach`/`detach`；**只理自己那个房间**；版本号不比手里新就不发请求；重连后再对一次账 |
| WS 接线 | `lib/features/group_call/group_call_sync.dart`（在 `main()` 启动） | 收 `sfuRoom` → 枢纽对账；`main()` 里与 `CallSyncService` 并列 |
| 收敛把关 | `SfuRoom.refreshRoomState({int? epoch})` | 离开房间后（没发布会话）直接返回 —— **推送不能再把关掉的一页拉回来** |
| 收尾兜底 | `SfuRoom.dispose()` | 页面被直接销毁时**先当作离房**（关会话、放采集），不只靠注册表 90 秒 TTL |
| 诊断数据 | `lib/domain/group_call/sfu_trace.dart`（纯逻辑，`ChangeNotifier`） | 时间线（上限 80 条）+ 计数（发布/订阅/重协商/关闭/重建/失败/心跳） |
| 诊断面板 | `lib/features/group_call/group_call_diagnostics_sheet.dart` | **长按主区域**打开：房间 / 两条会话 / 我发布的 track / 订阅表 / 说话人 / 计数 / 时间线 + 一键复制 |

面板要分的那三类问题（与 1:1 的候选那几类完全不同）：
**订阅没建上**（看不到 `u2|mic → mid-…`）、**有订阅却没流**（CF 侧或对方没发）、
**重建计数一直涨**（网络或凭据）。

验证：`flutter analyze` 干净、`dart format` 干净、**1604 项测试通过**（+19：枢纽与 WS 接线 9、
诊断数据 6、房间诊断 3、面板 1）。

### S6.13 群里的通话记录（2026-09-26）

打完一通，群里要留下微信那种「通话时长 12:30」。分工的关键是**最后一个走的人**：

| 落什么 | 位置 | 要点 |
| --- | --- | --- |
| 服务器的交代 | `Sfu.php::leave` 回包 `{closed, announce, duration, participants}` | 底账（何时开的、期间到过谁）放缓存；`announce` 靠注册表唯一键上的哨兵行仲裁 —— 两个人前后脚挂断也不会各写一条 |
| 回包模型 | `SfuLeaveResult`（`lib/data/model/sfu_models.dart`）+ `SfuControlPlane/SfuApi.leave(closing:)` | `closing` 区分「退出通话」与「重建时丢一条坏会话」（后者不算收尾） |
| 房间层 | `SfuRoom.leaveResult` | 一通话只认第一次拿到的「结束」（`dispose()` 兜底那次不能把它冲掉） |
| 发记录 | `MessageSender.sendGroupCallRecord` + `GroupCallController.writeRecord` | 走普通发消息那条路（`im/sendMessage`）：未读 / 离线推送 / 会话预览都在它上面；只写一次；`participants < 2` 不写 |
| 气泡 | `CallBubble`（`type` 仍是 `webrtc`）+ `CallPayload.groupCall` | 文案「群通话 12:30」（时长口径与 1:1 那条一致：分钟:秒）；`extends.group_call = 1` |
| 点击 | `chat_page._openGroupCall` | 群记录点一下进**群通话页**（1:1 那条仍是回拨） |
| 文案 | `group.callRecord`（zh / en） | 记录内容带 `{time}` 占位，缺 key 时也保底带上时长 |

几个刻意的取舍（写下来免得下次又绕回去）：

* **记录让客户端发、服务端不直接写消息表**：未读与离线推送都在 `im/sendMessage` 那条链上，
  在 SFU 控制器里重现一遍很容易漏；代价是最后走的人不告而别（App 被杀 / 没网）时没这条记录；
* **房间空了但没人认领**（最后一个人的行是被 90 秒 TTL 清掉的）：也不留记录 ——
  宁可少一条，也别冒出一条假的；
* **聊天列表预览是「[语音通话]」占位**：会话行只存 `last_type`，拿不到 `extends`；
  （消息本身、通知里都能看到「群通话 12:30」）。

验证：`flutter analyze` 干净、`dart format` 干净、**1623 项测试通过**（+19：控制器 7、
房间 3、接口回包 3、发送报文 2、时长格式 3、气泡载荷 1）；服务端静态自检 9 组全过。

### S6.14 群语音的离线叫醒（2026-09-27）

群里有人开语音时，**没打开 App 的人什么都不知道**：`sfuRoom` 那条 WS 提示只到得了在线的人。
所以这一块是一次**离线推送**（1:1 那套 `pushCallCanceled` 是 1:1 形状，单独设计）：

| 落什么 | 位置 | 要点 |
| --- | --- | --- |
| 什么时候推 | `Sfu.php::session` → `ringGroupCall` | 靠底账判「这一通是不是刚开」（`rememberMember` 的返回值一路传上去），只有第一笔推；后来进来的人不重复推 |
| 推给谁 | `Sfu.php::groupCallAudience` | **不在线** + **没把群静音**（读同一个 `is_notice`，与群聊推送一个口径）+ **不是发起人**；按 `GROUP_MAX_AUDIENCE` 截断；逐个 uid 问在线（不能传数组，那个坑修过一次） |
| 什么时候收 | `Sfu.php::endGroupCall` | 房间空了补一条**静默**推送（只带 `call_id`）：正常散场（`leave` 拿 `announce`）与 90 秒 TTL 清场（`prune`，大家 App 被杀那条路）都会走到 |
| 报文 | `Sfu.php::pushGroupCall` | `type = group_call`、`extends.event = groupCalling / groupCallEnded`、带群会话 id / 群名 / 发起人 / 这一通的 id；`PushMessage` 用 `isCall`（高优先级 + 60 秒存活） |
| 报文层（客户端） | `lib/domain/group_call/group_call_push.dart` | 判类（响铃 / 结束）、解析、新鲜度、通知文案；与 1:1 那份（`incoming_call_push.dart`）并列 |
| 后台 isolate | `lib/core/notify/push_background.dart` | 两条推送各一条路：响铃走 `showGroupCallRing`，结束走 `cancelGroupCallRing`；两个通知位**分开记 id**（上周那套「最后响过的那通」同理） |
| 通知位 | `LocalMessageNotificationPresenter` | 新 id `0x0CA12`；与来电**共用响铃渠道**（要的就是铃声）但**不全屏**（群邀请不该顶掉整屏）、能自己超时（5 分钟） |
| 点通知 | `lib/features/group_call/group_call_push_host.dart` + `app.dart` | 冷启动与点击两条入口都接住 → push 群通话页（`?id=group-100&name=群名`）——与群资料页那个入口同一条路由，不另开建链的路 |
| 收掉通知 | `GroupCallPage.initState` | 人进来了就把那条邀请收掉（点通知进来是幂等，从群资料页进来也能收） |
| 判类 | `_kindOfPayload`（改掉了原来那个「包含 calling」的模糊判据） | 群通话那条必须判在最前：`groupCalling` 恰好躲得过老判据的大小写，顺序反了就会点进聊天页 |
| 文案 | `group.pushTitle` / `group.pushRing`（zh / en） | 「群语音通话」/「邀请你加入群语音」；正文拼成「某某 邀请你加入群语音」 |

四个刻意的取舍：

* **服务端不暂存、不代发任何东西**：推送只是「叫醒 + 带上群名与群号」，加入还是客户端那套 `/enterprise/sfu/*`；
  所以这次接口、表结构、计费都没动（只是多推了两条数据）；
* **在线的人不推**：他们收得到 `sfuRoom`，该由应用内提示来管（S6.15 已落，见下）；
* **推送挪到响应之后**（`deferAfterResponse`）：进来的人不该陪着 Google 等；线上没有这个函数时退化成同步发；
* **一个人点进去又马上退出来**，其他人会先响一声再被收掉（与 1:1 拨了又取消一样）；
  真正留在群里的记录仍然是「两个人以上」那条规矩。

验证：`flutter analyze` 干净、`dart format` 干净、**1656 项测试通过**（+33：报文层 16、
后台推送 8、落地宿主 8、页面收通知 1）；服务端静态自检 10 组全过
（新增第 10 组：推送的刷新点、受众三道筛、事件名与客户端常量逐字对齐）。

### S6.15 在线状态：App 开着的人也要看到（2026-09-27）

S6.14 管的是「App 没在跑」，这一节是另一半：**人就在 App 里**（停在哪个页面都可能），
别人在群里开了语音时该看到一条横幅、会话列表那一行该挂上「语音通话中」——
但**不弹系统通知、不响铃**（人就在手机前面，再响一声是骚扰）。

| 落什么 | 位置 | 要点 |
| --- | --- | --- |
| 服务端多推的字段 | `Sfu.php::bumpEpoch($roomId, $extra)` | 同一条 `sfuRoom` 载荷多带 `live`（还有没有人）/ `call_id`（哪一通）；「刚开」那一次还带 `started` + `name` + `starter`。接口 / 表 / 配置一行没改 |
| `live` 怎么来 | `Sfu.php::roomOccupied` | **每次广播现算**（数注册表里 `purpose <> 'closed'` 的行，与快照/心跳人数同口径）—— 调用点五六处，漏一处就会出现「人都走光了界面还写着通话中」；数不出来时按还有人处理 |
| 状态模型 | `lib/domain/group_call/group_call_presence.dart` | `GroupCallLive` + `GroupCallPresenceTracker`：记账、忽略、按 `call_id` 认人、45 秒回查 |
| WS 接线 | `group_call_sync.dart` | 同一条 `sfuRoom` 喂两处：`GroupCallHub`（对账）+ 追踪器（在线状态）；推来我所在那间屋的事件要过滤（`hub.active.roomId`）；重连时顺手回查一次 |
| 回查 | `GroupCallPresenceTracker.verify` → `POST /sfu/room` | 屋里最后一个人的 App 被杀时，那条 `live = false` 推不出来（服务端没有定时任务）——手里有标记的客户端每 45 秒问一次；拿不准（网络失败）时什么都不改 |
| 横幅 | `lib/features/group_call/group_call_banner_host.dart` + `app.dart` | 挂在 `MaterialApp.builder` 最外层（任何页面上都活着、浮在 AppBar 之上）；群名 + 「某某 邀请你加入群语音」+ 加入/忽略；20 秒自己收掉 |
| 列表标记 | `ConversationTile.callLabel` + `conversation_list_page.dart` | 只换预览那一位（名字、时间、未读角标不动），绿字 + 一颗小图标；好友会话不受影响 |
| 1:1 忙线 | `lib/domain/call/call_busy.dart` | 把「现在是不是正打着 1:1」拎成 provider：群资料页的入口、横幅、推送来的邀请**三处同一个判据**（一条链路一只麦克风） |
| 音频路由 | `SfuLocalMedia.setSpeakerEnabled` + `GroupCallController._applySpeaker(true)` | 拿到媒体之后切免提（与 1:1 同口径）——**本轮核对微信时发现的缺口**：不切的话安卓按通话模式默认走听筒，群里别人说话会小得像在远处；切不去不影响通话 |
| 文案 | `group.callLiveHint` / `callLiveGeneric` / `callLiveJoin` / `callLiveIgnore` / `callInProgress`（zh / en） | 「{name} 邀请你加入群语音」/「加入」/「忽略」/「语音通话中」 |

四个刻意的取舍：

* **只有「刚开」那一次弹横幅**（服务端带 `started`）：中途进来的人不该把已经在用 App 的人又提示一遍
  —— 与离线推送「只推第一笔」同一个取舍；
* **我就在那间屋里不提示自己**：服务端广播的是整个群（包括发起人），客户端用「我登记的/正开着的房间」把它过滤掉；
* **点掉横幅 ≠ 清掉标记**：「忽略」只按掉这一条横幅，会话列表那行「语音通话中」留着（它才是长驻的记号）；
* **回查比猜好**：宁可每 45 秒问一次服务端（顺带把它的残骸也清了），也别让一条早就散场的语音挂在列表上。

* **退登出就把这本账清掉**：`main.dart` 里那句登出分支（与 `chatSync.onLoggedOut` 并列）——
  换账号接着用时不该还挂着上一个账号的群。

边界（都不是 bug）：**断线期间开的那通**（错过了 `started` 那一次）不会补弹横幅 ——
会话列表的标记会在下一次广播时补上；**点离线通知进来的那条路没有横幅**（它直接进页面）；
**老服务端**（`Sfu.php` 没换成新版）的事件里没有 `live`，客户端一律当没看见
（功能不报错，只是没有那条横幅与标记）。

验证：`flutter analyze` 干净、`dart format` 干净、**1701 项测试通过**（+45：追踪器 29、
应用内横幅 10、WS 接线 5、会话列表标记 1）；服务端静态自检 11 组全过
（新增第 11 组：载荷字段、`live` 现算、以及**拿客户端真读的字段名逐个对一遍**）。

一个只能在整机测试里抓到的坑（`chat_page_test` 抓出来了）：群通话页的 `initState`
里同步通知「我进去了」，正好撞在那一帧的构建过程中 —— 横幅宿主不在这一页的祖先链上，
于是是一个 `setState() called during build` 断言。修法是把那一次通知挪到本帧之后。

### S6.16 进群以后的两处补齐（2026-09-27）

与微信逐条对表时找出来的两处不一致（其余都已对齐：入口、界面、静音、共享屏、
群里那条记录、离线响铃、在线标记），这一节只动客户端（**服务端一行没改，不需要新补丁包**）：

**1）群聊页顶上那条常驻的「N 人正在通话 · 加入」**
（`lib/features/chat/widgets/group_call_bar.dart`）

会话列表那行绿字只在列表页看得见，横幅 20 秒就走 —— 人已经点进这个群了，
顶上得有一条能一直点得动的入口。只在群会话里画，语音不在了整条高度为 0。
数据来源与 S6.15 那两处是同一本账（三处不会互相矛盾）；人数用 `sfuRoom` 里的 `members`，
**数不出来就退化成不带数字的说法**（人数只影响文案好不好看，不该决定这条显不显示）。

**2）点历史通话记录 → 先弹详情卡，而不是一点就进房间**
（`lib/features/chat/widgets/group_call_record_sheet.dart`）

S6.13 那版点一下就直接进群通话页，而那个页面**进去就是加入** —— 手滑点一下会真的
在服务端开出一间房，而「第一笔就叫醒离线群成员」那条规则会让**一群人的手机响一声
再被收掉**。微信里点这条记录是看详情，跟它对齐：卡上只有时长（`extends.callTime`，
**分钟:秒**，与气泡里那个数同一个口径）、参与人数（`extends.participants`，没有名单，
0 就不画那一行），主操作还在开就是「加入」、散了就是「再次发起」（同一条路由）。
`CallPayload` 因此多了 `durationSeconds` / `participants` 两个字段（默认 0，1:1 那条不带）。

文案：`group.callRecordDuration` / `callRecordPeople` / `callRestart`（zh / en）。

验证：`flutter analyze` 干净、`dart format` 干净、**1705 项测试通过**
（本轮：记录详情卡整机用例 3 条（先弹卡 / 不进房间 / 点「再次发起」才进）、
顶上那条 2 条、载荷解析那两条新字段的断言）；服务端不需要自检（未改）。

整机用例里踩到的新坑（已写进用例注释）：那个弹层的尺寸是按 750 设计宽换算的，
在测试默认的 800x600 画布上会算出比屏幕还高的内容（`RenderFlex overflowed`），
要先把画布设成手机尺寸（1080x2280 @3x → 360x760）—— 与 `group_call_page_test.dart` 同一个坑。

### S6.17 退出通话页不挂断（2026-09-27）

S6.16 对表时剩下的**离微信最远的一处**：页面一关就 `dispose`，于是「退出页面 = 挂断」。
微信退出来还能听、还能说。这一节把那层绑定拆开（只动客户端，服务端一行没改）：

**1）通话常驻：`GroupCallSession` + `GroupCallSessionHost`**
（`lib/features/group_call/group_call_session.dart`）

房间、控制器、保活、对账登记从页面搬到一个常驻会话：页面进来只是「看着它」
（`openPage` / `closePage`），**关页面不再收尾**；只有通话页那颗红钮、小窗上的挂断、
登出（`main.dart` 里与在线标记那本账并列）才真的 `end()`。
两个容易写错的取舍：**同一个群再进来是复用现成的会话**（不重新加入），
**换一个群进来先把上一通挂干净**（一次只有一通）。
还有一个僵尸口子堵上了：进不去（`failed`）又没人看着的会话自己收掉 ——
小窗不显示它，用户也没地方挂断，留着就是一颗看不见的僵尸。

**2）小窗：`GroupCallMiniBarHost`**（`lib/features/group_call/group_call_mini_bar.dart`）

页面关掉之后那颗可拖的药丸：只在通话页不在台上时出现，写着群名 +「N 人 · 12:03」
（还没进房间就写「正在加入…」），点整颗回通话页，右边那颗是**唯一的兜底挂断**。

**3）群里那条提示多了「回到通话」一种形态**（`GroupCallBar`）：
两本账各管一半 —— 我在不在通话里看会话登记处，别人在不在看在线状态那本账。

**4）计时搬到会话里**：从「进房间成功那一刻」算，关掉页面再进来接着走
（以前是页面从 0 重新数）。

三个只能在用例里抓到的坑（都写进了注释）：

* 登记处的通知**要推到这一帧之后**（`_notifySoon`）：页面在 `initState` 里 `openPage`、
  在 `dispose` 里 `closePage`，那两刻 widget 树是锁着的，当场 `notifyListeners()` 会让
  监听者撞上 `setState() called during build`；
* 小窗里的 `IconButton` **不能给 `tooltip`**：它挂在 Navigator 外面、没有 Overlay；
* 挂断**不要 `await` 收尾再 pop**（真机上关会话要几百毫秒，而且整机用例里那串在假异步下
  走不完）—— 先摘登记处 + 通知界面，再 pop，清理在后台走完。

验证：`flutter analyze` 干净、`dart format` 干净、**1721 项测试通过**（+16：
常驻会话 7（复用 / 换群 / 关页仍在 / 挂断 / 僵尸 / reset）、通话页 2（返回不挂断、重进不重新加入）、
小窗 6（出现与让位 / 点它回页面 / 挂断 / 正在加入态 / 拖动）、聊天页那条 1）；
服务端不需要自检（未改）。

边界（写清楚，都不在这一节的范围）：通话页被别的页面盖住时小窗不显示；
1:1 打进来不会自动挂断群通话；没有锁屏全屏、没有视频。

### S6.18 通了的第二天：四件"手感"修复（2026-09-27）

S6.14 ~ S6.17 那一整条链在**两台真机上都通了**（服务端补上 live5：一个字段名
`trackName` / `track_name` 之差，让注册表永远写不进我的 track）。通了之后剩下的是
"功能对但手感错"的四件事（**只动客户端，服务端一行没改**）：

**1）进房间不再等自己的发布谈成**（`SfuRoom.join()`）

真机时间线：进房间 +0.3s，第一次快照却到 +8.9s —— 那 8.9 秒全等在一个东西上：
采麦 → 建发布会话 → 候选收集 → 与 Cloudflare 建连。而**听见别人根本不需要它**
（订阅走的是另一条会话）。现在 `join()` 只等"接收侧可用"：建发布会话（一条请求）→
**发布不 await** → 拉快照/订阅 → 等发布落地并回报成败。发布的异常也接住了
（`publishError`）：被逐条拒 / 连不上时落进 `failed` 并写出原因，不再默默留在房间里
——那正是"界面一切正常、别人一个字都听不到"的样子。
新增 `micPublishPending`：发布在飞时那行红字不出现（条件正好是"两者都为假"）。
顺带：接收会话**预建**（`_prewarmReceive`）+ `_ensureReceive` 的并发去重 ——
预建与首次对账会同时来问，两个调用方都看到 `_receive == null` 会各建一条，
房间里凭空多一个幽灵成员。

**2）`micPublished` 只认注册表**（拿发布回包自己下结论 = 老 bug 的成因）

`_publishTracks` 里那句 `if (accepted.contains('mic')) _micPublished = true;` 删掉了。
它就是那个 bug 能藏一整天的原因：回包说"上游接受了 mic"，而服务端因为自己的解析 bug
根本没把它写进注册表，界面于是信心十足地显示一切正常。
现在 `join()` 在发布落地之后**再读一次注册表**（`refreshRoomState()`），
`micPublished` 只有一个来源：别人的注册表里查得到我。
"我说我发出去了"和"别人查得到我"不是一回事。

**3）共享屏：`contain` + 同一时刻只允许一个人**

* 渲染那层从 `cover`（填满、裁掉四周）换成 `contain`（**完整放下**）：屏幕共享的意义就是
  "看清每个角落"，`cover` 会把对方屏幕裁掉一圈（用户原话"共享屏幕显示不完整"）；
* **抢共享拦住了**（`GroupCallController.toggleScreenShare` 里那道判断）：SFU 没有这个限制，
  两个人同时开就会打架（注册表里两条 `screen`、观看端只认其中一条，两边都要重协商）。
  第二个人看到的那颗钮**弄灰但可点** —— 点了会告诉他"已经有人在共享了"
  （`group.callShareTaken`），比一颗纯点不动的钮有用。

**4）我自己那一行的麦克风状态看"意图"**

注册表只知道"我发布过一条 mic"，不知道我中途按了静音（静音只是本端不再发包，
`mic` 一直挂在注册表上）。所以我那一行的 `audio` 用 `_micEnabled && 注册表`，
否则会出现"按钮写麦克风已关、成员行写麦克风已开"。

⚠️ 还没做的（写清楚）：**别人**静音了我这边看不出来（注册表没有静音这一维，
要真做得加一条信令）。

验证：`flutter analyze` 干净、`dart format` 干净、**1738 项测试全过**
（+17：进房间不等发布 1、共享屏抢用 2、渲染 `contain` 1、钮弄灰 1、
以及几处顺序断言按新时序改口径）；服务端不需要自检（未改）。

### S6.19 “更新不及时、不同步”的病根：两个死区（2026-09-27）

S6.18 之后功能齐了，但真机上**一切都慢半拍**：对方停了共享这边还卡在画面上、
人走了三分钟还挂在成员里。查下来是两个**互相咬住**的死区，一个在客户端、
一个在服务端：

**死区一：客户端只信推送，而推送这件事没有任何保证**

`refreshRoomState(epoch:)` 原来是“推来的版本号**不比手里这份新**就不刷”。
版本号是服务端缓存里一个计数器（清了缓存/重启就从 1 重数），回退之后这台手机就
**永久不再收任何进出更新**。→ 改成“**相同**才跳过”（回退时多刷一次完全无害）。

**死区二（真正的那个）：两端正好互相等，谁也不会先动**

* 服务端的清场（`prune`）**只在拉快照（`room`）里跑**；
* 掉线/被杀的人**不会自己写注册表** → 版本号不变 → 客户端不拉快照；
* 客户端不拉快照 → 清场永远不跑 → **那一行永远挂在房间里**（再加上 he 在共享的屏）。

所以“3 分钟还没反应”不是慢，是**永远不会自己好**，只能靠这台手机重进房间。

**修法（两边各一刀）**

1. **客户端：定期回查**（`SfuRoom.stateRefreshInterval`，默认 **5 秒**）—— 无条件拉一次
   快照，不管推送有没有来、版本号变没变。这是界面“不迟钝”的**唯一硬保证**：
   任何漏推、任何服务端漏通知，最多 5 秒自己纠回来。代价是每 5 秒一条很小的读请求
   （服务端只查自己的表，不碰 CF）。回查**状态没变就不记诊断时间线**，
   否则 5 秒一条快照会把有用的那几条冲掉；
2. **服务端：心跳也清场**（`heartbeat` 里调 `prune`），并把行超时**封顶 45 秒**
   （原来 90）：心跳是每个在通话里的人每 20 秒一定会调的接口，清场从那一刻开始
   就一定跑得起来。客户端心跳也从 25 秒提到 **20 秒**（45 秒 = 两拍 + 余量）。

验证：`flutter analyze` 干净、`dart format` 干净、全量测试通过
（+2：定期回查把界面纠回来、版本号回退不再永久失联；测试里的房间都显式关掉回查定时器）。
服务端补丁：`gracelinkim-server-patch-20260927-group-live6.zip`。

### S6.20 群通话也缩成小窗（画中画）（2026-09-27）

用户要求：**「跟一对一通话一样的画中画，一样放到左上角，点击后缩小成画中画」**。
1:1 那条（S6.6a / S6.3e）早就有，群通话这边一直没有 —— 而两者的**机制完全相同**
（系统 PiP，不是自绘悬浮窗），所以这次是把同一条通道接到群通话上，不是新造一套。

**先修的一处隐患：通道只有一个，监听必须是一张表**

`CallPip.onModeChanged` 原来是个 setter（`_methodChannel.setMethodCallHandler`
只能挂一个）：群通话一旦也来注册，就会**把 1:1 那条顶掉** —— 而 1:1 的界面正是靠
这条消息切成「只有内容」的。群通话挂断时再 `= null` 更糟：**两条监听一起没了**。
→ 改成 `addModeListener` / `removeModeListener`（第一条监听挂平台回调、最后一条
走时摘掉；原生报一次就给所有监听各推一次）。1:1 与群通话各摘各的，互不影响。

**控制器（`GroupCallController`）** —— 与 `CallController._syncPip` 同一套口径：

| 做什么 | 怎么做的 |
| --- | --- |
| 进/出小窗进界面状态 | `GroupCallView.inPip`（原生说进就进、说退就退；同一状态重复报不重画） |
| 参数（比例 + 标题） | `joining / joined / rebuilding` 这三段里 `setParams(video: false, title: 群名)`；参数没变不打通道 |
| 收尾 | `hangup` / `dispose` 都走 `_releasePip`：摘监听 + 把已经打开的小窗收掉（`isInPip` → `exit`） |
| 进小窗 | 只有 `minimizeToPip()`（点按钮）；**不做自动缩窗**（按 Home / 切走不进） |
| 失败 | 一律只记一行日志：小窗是体验，绝不能影响这一通 |

标题用**群名**、比例固定**语音那一档**（1:1 方块）而不是视频那档：群通话的主内容是
头像墙/说话人那块卡片，方块最贴；共享屏那一路在小窗里用 `contain` 完整放下。

**界面（`GroupCallPage`）**

* 正形包成 `_callView`：`SafeArea`（原样）+ 左上角那颗「缩成小窗」——
  位置、图标（`Icons.picture_in_picture_alt_rounded`）、Tooltip 文案（`call.minimize`）
  与 1:1 **逐项一致**；只在 `joined / rebuilding` 时给（进不去那一页要的是重试/返回）；
* 小窗形态 `_pipView`：**只画内容、一个按钮都不画**（PiP 里触摸被系统接管，
  点一下是「展开 / 菜单」）；有人在共享屏幕 → 那一路 `contain` 铺满；
  其余 → 白底 + 绿色话机 + 一行字（`_pipLabel`：我在共享写「正在共享屏幕」、
  满一秒写通话时长、刚进来写「N 人在通话」）；
* 尺寸按**窗口**算（`constraints.maxWidth * 0.3` 那种），不用 `context.rpx` —— 
  小窗比屏幕小得多（1:1 那张小窗踩过同一个坑）。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量 **1751 项测试通过**
（+10：通道的多人监听与摘除、控制器五条小窗用例、页面四条
——「参数交给系统但不自己缩窗」「点左上角 → `enter` 一次」「进了小窗只剩内容、出来恢复」
「小窗里共享屏仍然 `contain`」）。**服务端零改动**（PiP 是纯客户端机制）。

**没做的**：小窗里没有挂断/静音钮（PiP 触摸被系统接管，这是系统限制）；
群通话那颗「药丸」（页面关掉之后那颗）上还没有「缩成小窗」的入口；iOS 侧同样没有
（与 S6.4 一起做）。

### S6.21 客户端整体自检：一个真 bug + 几处小问题（2026-09-27）

用户让「整体再看看客户端有没有细节 bug 或小问题」。过了一遍：

**① 【真 bug】1:1 电话与群通话可以同时开着（单边闸门）**

群里那道闸门一直是**单向**的：有 1:1 电话时不给进群通话（聊天页「＋」面板、群资料页、
离线邀请那条推送，三处都有）；但**反过来没有** —— 正在群语音里的人可以发起 1:1 通话
（聊天页 / 联系人详情页），**别人打来的 1:1 也照接**。

后果不是“声音有点乱”而已，而是硬伤：

* **前台服务全应用只有一份**（`CallKeepAlive`，一颗常驻通知）——1:1 挂断时那句 `stop()`
  会把群语音那条通知**一起停掉**，群通话从此切后台就被系统冻结（声音断、对账停）；
* 两条通知互相顶（通知栏那句「与 X 通话中」会被对方覆写）；
* 群通话正共享屏幕时，那一位 `mediaProjection` 类型也跟着一起没。

修法（两处，都不动协议，服务端零改动）：

1. **对称闸门**：新增 `groupCallBusyProvider`（与 `callBusyProvider` 镜像的那个）——
   1:1 的两个拨出入口（聊天页 `_startCall`、联系人详情页 `_startCall`）都要过一道，
   正在群语音里就提示「你正在通话中，请先挂断」、一通都不起；
2. **1:1 接通那一刻群通话让路**：`GroupCallSessionHost` 收两个可选依赖
   （1:1 控制器的 `view` + 一个「现在算不算通话中」的取值函数，不传就不联动），
   它一变“通话中”就把这一通挂干净（`end()`，含保活与登记表）。
   只在**接通**时动，来电响铃不管（那时还没接）。
   配套：群通话页新增 `_leaveIfCallOver()` —— 这一通被外面收掉时（1:1 顶掉 / 登出）
   页面自己退出去，不留一个永远转圈的「正在加入...」。

**② 【小问题】群通话页的秒表不跟着通话结束停**

`_maybeStartTimer` 原来是“起了就不管”，通话结束（挂了 / 被顶掉）后那个 1 秒定时器
会一直把整页重画下去（页面上已经没有任何会变的字了）。改成只在 `joined` 那几段里跑，
重建回来会自己再起。

**③ 【小问题，已记录未改】语言包与写死的文案**

* `assets/i18n/en.json` 里的 `common.SearchNone` 在中文包里没有对应键（代码里没人用它，
  是个死键，但两份包理论上应该一一对应）；
* 有几处**用户看得见的中文写死在代码里**（英文界面下会显示中文）：
  `api_exception.dart` 那些网络错误文案、`app_router.dart` 的「页面不存在」、
  `lingting_client.dart` 的「灵听请求失败」、`profile_form.dart` 的两行问句。
  英文用户很少（当前只有中文在用），所以只记录不改。

**④ 【仓库杂物，已记录未删】**

根目录有前几轮留下的临时文件：`app_smoke_tmp.png.html`（248KB 的截图 base64）、
`.tmp_wx_time.png`、`REFACTO_PLAN.md`（名字打错的那份 3 行笔记，与 `REFACTOR_PLAN.md` 无关）、
`flutter_01..27.log`（已被 `.gitignore` 的 `*.log` 盖住）。都不是产物，建议删，但删之前问一声。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量 **1754 项测试通过**
（+3：「1:1 接通 → 群通话自己让路」「群语音里拨 1:1 被拦下」
「通话被外面收掉 → 群通话页自己退回去」）。手机：新包已构建（安装时手机掉线，需重插）。

### S6.22 三件界面调整：入口收敛、公告成页、等待文案（2026-09-27）

用户 2026-09-27 一次提了三件事，都不动协议、服务端零改动。

**① 群资料页删掉「群通话」那一栏（入口只留「＋」面板）**

原话：「群聊资料页那一栏群通话删掉，加号面板已经有了嘛」。删了 `chat_info_page`
那一行与 `_startGroupCall`（连 `call_busy` 的 import 一起清掉）。守卫没丢也**不用丢**：
「＋」面板那条（`chat_page._openGroupCall`）与离线邀请那条推送照样过 `callBusyProvider`。
路由器里那句「入口只在群资料页」的注释、协议文档同口径的那两句也一并改了。

**② 群公告：弹层 → 整页（右上角保存）**

新增 `lib/features/chat/group_notice_page.dart` + 路由
`/message/group/notice?id=<会话 id>&auth=<0|1>`，群资料页那一行只负责把人送进去。
四条取舍：

* **权限由入口带过去**（`auth=`），不在新页重拉一次成员：多一次请求，而且网络抖一下
  就会把管理员变成只读（公告是"进去就写"的东西，不能让人对着它没辙）；
* **内容从本地库读**，不通过路由传文本：公告可能很长，塞 URL 又丑又容易被截断；
* 保存走同一个 `GroupAdminRepository.setNotice` —— 它写服务端之后**顺手覆盖本地那一格
  `extra.notice`**，所以返回群资料页时那一行的值自己就变了（那一页盯着同一条流）；
* 非管理员：连「保存」都不画、输入框 `readOnly`（能全选能复制，只是改不了）；
  管理员进来自动聚焦，保存成功 toast 一句「保存成功」再自己 pop。

**③ 「正在加入...」→「正在连接恩信全球智能网络」**

就改了 `group.callJoining` 这一条文案（中英都改）；用到它的四处（通话页的顶部/
主区域/小窗卡片、大药丸那一行）自动跟着变。小药丸上那句会按一行省略号截断，
所以文案本身不带上省略号。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量 **1754 项测试通过**
（改了两条群公告用例 —— 现在断言"真的是一页"、只读页没有「保存」、保存完自己退回去；
主群那条加了「群通话不在这一页」；小窗那条换成新文案）。

### S8.2 权限这件小事一次做齐 + 扫一扫收尾 + 两处界面调整（2026-09-27）

用户 2026-09-27 的第二批（原话里那几条）：扫一扫（权限提示、相册导入、外链）、
那条「系统开启了省电优化」的红横幅、**首次启动申请基本权限**、
**通话/发图/发文件/发语音之前的权限检查**、「我的收藏 / 系统通知」的国际化。

**① 自己写了一条权限通道（不引 `permission_handler`）**

新文件 `lib/core/platform/app_permissions.dart`（Dart 侧）+ `MainActivity.kt` 里的
`PERMISSIONS_CHANNEL`（安卓侧，约 60 行）。三个权限：`camera` / `microphone` /
`notifications`；两个方法：`check`（只查不弹框）与 `request`（缺的弹系统框），
回 `granted` / `denied` / `permanentlyDenied` / `unsupported`。

* 为什么要 `permanentlyDenied`：安卓从**第二次拒绝**起就不再弹框，这一档要换成
  「去授权」那颗钮（打开本应用在系统设置里的页面）；
* 为什么 `unsupported` 一律算通过：桌面端 / iOS / 单测里这条通道根本不在，
  权限这层**绝不能变成新的拦路虎**；
* 通道回调里**先调 `super.onRequestPermissionsResult`**：插件（mobile_scanner）
  也在等同一批回调，不转交它们会永远挂着。

唯一的调用入口是 `lib/core/ui/permission_gate.dart::ensurePermission(context, …)`：
查 → 缺了就 `request` → 还是没给就弹微信那只白框（说清要哪个权限 + 「去授权」）。
通话那两处走 `ensureCallPermissions(context, ref, video: …)`（先麦克风，视频再要摄像头）。

**② 首次打开只问通知那一条**（`lib/features/notify/first_launch_permissions.dart`）

挂在 `HomeShell.initState` 的 post-frame 里（与检查更新同一处），本地存
`firstLaunchPermissionsAsked`：问过（无论同不同意）就不再骚扰；早就允许的
一声不响。**摄像头/麦克风刻意不在启动时问** —— 一上来要相机权限用户只会拒绝，
而且系统框会把 App 顶上后台（安卓 14 那套 while-in-use 校验很不欢迎这种事）。

**③ 用之前检查的地方（这一轮补齐的）**

| 场景 | 之前 | 现在 |
|---|---|---|
| 1:1 通话（拨号前） | 无 | 麦克风（视频再要摄像头），没给就不发这一通 |
| 群语音（进房间前） | 无 | 麦克风；已经在通话里（小窗/提示回来）不查 |
| 扫一扫（相机） | 一句笼统的「摄像头授权失败」 | 「需要摄像头权限」+「去授权」+ **相册照样能用** |
| 拍照（「＋」面板） | 无 | 先确认摄像头再进系统相机 |
| 相册/视频/文件 | 失败就静默（异常冒到框架） | 抓异常 → 「需要文件访问权限」+「去授权」 |
| 按住说话 | 一句 toast | 同一句 + 「去授权」那颗钮 |
| 保存到相册 | **安卓 9 及以下静默失败** | 补上 `WRITE_EXTERNAL_STORAGE(maxSdk=29)` 与 `requestLegacyExternalStorage` |

**④ 扫一扫那三条路**

* **外链**：`ScanUrlTarget` → `core/ui/link_opener.dart::openChatLink`，也就是
  **聊天里点链接那三道闸门**（自家站点直开 / 微信系拦掉 / 其它先确认）。
  `openChatLink` 这一轮从 `message_bubble.dart` 搬到了 `core/ui/link_opener.dart`
  （那一侧照旧 `export`，老 import 路径不作废）；
* **相册导入**（新）：`mediaPickerProvider.pickImages` → `controller.analyzeImage`，
  取第一条有内容的当结果；「图里没有二维码」与「读图失败」分开说；
* **走 URL 的三道闸门 + 相册那颗钮**让「相机被拒」不再等于「扫一扫整个废掉」。

**⑤ 去掉「系统开启了省电优化」那条红横幅**

`SystemHealthHint.battery` 整个删掉（连同 `SystemHealth.batteryIgnored` 与
两条 i18n key）：消息到达现在靠**厂商推送**唤醒，WS 被冻住照样收得到，
那条常驻红条只会吓人（用户原话：「这个红色横幅也很丑，而且也有推送通知了要这个干嘛」）。
平台那侧的能力（`BackgroundHealth.ignoringBatteryOptimizations`）留着不用。

**⑥ 「我的收藏」「系统通知」跟语言走**

两个名字是**服务端用中文存的**，所以英文界面里就只有这两行还是中文。
新增 `ConversationRules.displayNameOf`：`id == 'system'`（或 `is_group == 2`）→
`user.systemNotice`、`id == '-1'` → `user.myFavorites`（新 key），其余照用服务端给的。
**`is_group == 3` 不认**：老端那个值还有「应用号」，硬换会把人家名字改成「我的收藏」。
会话列表那一行与聊天页标题栏两处接上。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量测试通过（新增
`test/core/app_permissions_test.dart`、`test/core/permission_gate_test.dart`、
`test/features/first_launch_permissions_test.dart` 三个文件 + 扫一扫/会话名/提示条几组用例）。

### 下一步（未做）

0. 权限这层还有两处**故意的**没做：iOS 那侧（`openAppSettings` 与权限通道都是
   安卓优先，iOS 上走系统默认那套：`getUserMedia`/相册自己弹框，失败只给提示语）；
   以及「相册/文件」没有走 `READ_MEDIA_*`（图片与视频走系统选择器，本来就不需要）。
1. 真机验收（群通话全部逻辑只有假件单测覆盖）：两台新端（老网页端**没有**群通话，
   加入不了同一个房间）→ 三人 → 共享屏 → 断网重连；顺带验「共享屏发布与停止」
   与「说话人」这两个真机才能看的项；
   两件离线/在线的事也在这里验：
   * **离线叫醒**（S6.14）：被杀的手机响不响、点进去加不加入得了、全部挂断后那条通知自不自己消失；
   * **应用内提示**（S6.15）：另一台停在别的页面时飘不飘横幅、会话列表那一行是不是「语音通话中」、
     全体挂断后那行几秒内回到最后一条消息（两台手机都要装新包）；
   * **进群以后的两处**（S6.16）：语音还在开时进群的聊天页顶上是不是「N 人正在通话 · 加入」、
     点历史那条记录是不是先弹卡（而不是直接开一场新的）、卡上时长与人数对不对；
   * **退出通话页不挂断**（S6.17）：点返回键退出来 —— 对方还听得到你说话吗（不退话筒）、
     屏幕上有那颗小窗吗、点它能不能回到原来那一通（不是新开一场）、
     聊天页顶上是不是变成「回到通话」；小窗上挂断能不能真的把两边的会话都收干净
     （挂断后对方的界面几秒内把人去掉）；中途锁屏/切后台回到 App 时声音还在不在；
2. 顺带把 S6.13 那条也看一眼：**群里那条记录到底落没落库**（服务端 `sendMessage` 对
   `type=webrtc` 的处理是本机没法验的）+ 两人同时挂断时群里是不是只有一条
   —— 出问题时把诊断面板「复制」的那段文本贴回来；
3. 真正剩下的功能缺口（都不是这次的范围）：群通话**没有视频**（只做语音 + 一人共享屏，
   这是产品决定）、老网页端进不了同一条语音。

### 需要用户提供

Cloudflare Dashboard 建一个 **SFU App**（Realtime → 不是 TURN Key），拿 **App ID / App Secret**
填进站点 `.env` 的 `[REALTIME]` 段（`SFU_APP_ID` / `SFU_APP_SECRET`），App Secret 只在服务端。

### S8.3 锁竖屏 · 发现页写死（灵听）· 全平台品牌名收敛（2026-09-27）

用户 2026-09-27 的第三批，四件事，**服务端零改动**：

**① 强制竖屏（不允许横屏）**

三道一起上，少一道就会在某个系统上被转过来：

* `AndroidManifest.xml` 那个 Activity 的 `android:screenOrientation="portrait"`
  —— 安卓侧唯一的硬锁（系统压根不许转）；
* `main()` 里的 `SystemChrome.setPreferredOrientations([portraitUp])`（**要 await**）；
* iOS 的 `UISupportedInterfaceOrientations`（含 `~ipad` 那份）只留竖屏
  —— iOS 的方向是清单与 Dart 偏好的交集，plist 里留着横屏等于没锁。

只给正着的竖屏（`portraitUp`），连倒着的也不给：全站版式是按竖屏宽度用 `rpx`
（750 = 屏宽）算的，横过来只会到处溢出。
守卫用例 `test/core/portrait_lock_test.dart`（三处都在、且没有 `landscape`/`sensor` 类兜底）。

**② 「发现」页改成纯客户端写死：只有「灵听」一条**

`lib/features/compass/compass_page.dart` 不再看 `globalConfig.compass`：名字走语言包
（`lingting.title`）、图标是**随包的** `assets/images/lingting_logo.png`（用户上传的那张：
红音符 + 环绕的叶子，256×274，带透明通道），点了直接 `AppRoutes.lingtingHome`。

* `HomeShell` 里那个 `compass.status == 1` 的开关**也不再决定这一格在不在**
  （老端服务端把 compass 关掉时整格都会消失）；
* 服务端那份 `CompassConfig` 照样在解析（接口本来就返回它），只是这一页不看了；
* 好处：弱网/断网时「发现」不会空一格，切语言时名字跟着变（老端那张是网络图 + 服务端配好的中文名）。

**③ 品牌名收敛：老端那几个默认名一律换成 Gracelink**

`sysInfo.name` 的**默认值就是 `Im`**（`SysInfo` 那个 `asText(json['name'], 'Im')`），
老端上游的默认叫 `Raingad-IM` —— 服务端没改过配置时，登录页底下那行就会写成
「Im for 1.0.0」、关于页标题是一串旧品牌名。新增 `AppInfo.siteName(serverName)`：
**整串归一化后全等**（去掉空格/`-`/`_`、转小写）命中 `''` / `im` / `raingad` /
`raingadim` / `gracelinkim` 这几个上游默认名时换成 `Gracelink`；管理员自己起过的
名字（比如「示例IM」「恩信」）**原样显示**，不会被误伤。登录页、注册页、关于页三处接上。

各平台的显示名一起对齐（原来都是 Flutter 建工程时的包名 `gracelinkim`）：

| 位置 | 之前 | 现在 |
|---|---|---|
| iOS `CFBundleDisplayName` / `CFBundleName` | `Gracelinkim` / `gracelinkim` | `Gracelink` |
| Web 标题 / `apple-mobile-web-app-title` / manifest | `gracelinkim` | `Gracelink` |
| macOS `PRODUCT_NAME`、Windows `ProductName`/`FileDescription` | `gracelinkim` | `Gracelink` |
| `pubspec.yaml` 的 description | `Gracelink IM · …` | `Gracelink · …` |

安卓那侧的中文包仍是**恩信**（`values/strings.xml`）、英文包是 `Gracelink`
（`values-en/`），这是刻意的：中文品牌叫恩信。

**④ 「关于」页的 logo 也改成随包那张**

原来是「服务端 `sysInfo.logo` 有就用它」（于是换品牌之后关于页顶上是旧站点的图），
现在与启动页、登录页、注册页统一用 `AppInfo.logoAsset`（`assets/images/logo.png`）。
`about_page.dart` 里那段 Image.network + errorBuilder 也一起删了。

**顺手修掉的一处版式 bug**：底部 tab 的文字**只给一行**了（`Flexible` +
`maxLines: 1` + `ellipsis`）。以前是裸 `Text`，英文界面下 `Gracelink` 这种名字会折成
两行，而 tab 栏高度是死的（`rpx(100)`），于是底部那格溢出 9px、冒黄黑条
（`test/features/compass_page_test.dart` 的英文用例先暴露出来的）。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量测试通过（新增
`test/core/portrait_lock_test.dart`、`test/core/branding_test.dart`（含两张 logo 的像素特征
——主 logo 白底不透明、灵听那张有红音符与青叶），另加关于页/登录页两组品牌用例）。

**服务端**：这一轮一个字都不用动。

---

### S8.4 登录 / 注册页换掉「微信风」，改成现代风（2026-09-29）

用户原话：「登录注册页面 UI 太丑太丑了，美化一下，现代化一点」。被否掉的是
2026-09-25 那版**照抄微信登录页**的样子（白底 + 左标签右输入 + 一根根下划线 +
通栏绿按钮）。

**新的一套（两页共用）**，零件全在 `lib/features/login/widgets/auth_widgets.dart`：

| 部分 | 现在长什么样 |
|---|---|
| 页面底色 | 顶部一层极淡的品牌绿渐变（往下 50% 就化到白）压两团柔光（`RadialGradient`，不是 `BackdropFilter`——纯装饰不值得每帧重采样） |
| 顶栏 | 左上返回（只有注册页有）+ 右上**语言药丸**（地球图标 + 当前语言 + 箭头，点开底部弹层） |
| 品牌 | 白底圆角 logo 卡（`rpx(10)` 内边距衬出圆角、低不透明度投影）+ 站点名 `rpx(46)` 半粗 + 一行说明（登录「欢迎回来，登录后继续聊天」/ 注册「创建一个新账号，开始聊天」） |
| 表单 | 一张白色卡片（圆角 `rpx(36)` + 柔投影），卡片里每行是**标题在上、输入框在下** |
| 输入框 | 圆角 `rpx(26)` **填充**式（浅灰底 + 几乎看不见的描边）+ 行首图标；**聚焦时描边变品牌绿、底色转白**（`AnimatedContainer` 160ms） |
| 密码 | 右侧自带一颗眼睛（明文/密文切换）——老端没有，手机上戳密码很容易错 |
| 验证码 | 「发送验证码」做成**框内**的淡绿小药丸（原来挂在行尾，像一句注释） |
| 按钮 | 主按钮通栏**药丸**（圆角 = 半个高度）+ 同色柔光投影；登录页的「注册」从一行小字换成**白底绿描边药丸**（小字容易被当成免责声明） |
| 记住我 | 圆角小方块，选中填绿 + 白勾 |
| 演示提示 | 淡绿底圆角面板 + info 图标（挂在注册按钮下面） |

**顺手清理的三处**：

* 两页的**重复代码合并**：顶栏、品牌、底部版本号、键盘处理（`resizeToAvoidBottomInset: false`
  + 键盘高度加进滚动内边距）原来在每个页面里各写一遍，现在统一走 `AuthScaffold`；
  注册页那对 `_buildBrand` / `_localLogo` 直接删掉了。
* **注册页也能切语言了**：以前只有登录页右上角有 `picker`，落到注册页的人被卡在
  当前语言里出不来。
* **登录页那三行演示提示不再是写死的中文**（`_buildDemoHint` 里的三句原文是硬编码），
  现在走 `user.demoHintTitle` / `user.demoHintAccount` / `user.demoHintPassword`；
  另外新增 `user.hintAccount`（标签移到框上方后，占位符不该再写「账号」两个字）、
  `user.loginIntro` / `user.registerIntro` / `user.hasAccount`。中英两份都补齐。

**行为一点没动**：controller、校验、提示语、「忘记密码」写死 `123456`、记住我落盘、
说明模式随机账号、验证码 `type` 1/2、注册成功等 2 秒回登录页、`AppInfo.siteName` 站点名口径、
底部 `{站点名} for 1.0.0`——全部原样。

**测试**：`test/features/login_page_test.dart` 从 6 条扩到 11 条（换掉「微信风」和「版面
顺序照微信」两条断言，新增：卡片/药丸圆角/语言药丸/密码眼睛、忘记密码切验证码模式、
演示提示走语言包、`registerOpen` 时的描边注册按钮、注册页与登录页同观感）。
另外给这组用例加了 `usePhoneSurface()`（把测试窗口摆成 360×780 的手机）：`rpx` 按**宽度**
换算，默认那个 800×600 的窗口会把界面撑得比真机高一截，输入框掉到屏幕外、`tap()` 打空。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量 `flutter test` **1803 通过**、
arm64 release APK 已装到手机上（`--build-number 2002`，见下）。

**装机小坑**：`adb install -r` 报 `INSTALL_FAILED_VERSION_DOWNGRADE`——手机上那份是
`versionCode=2001`（`pubspec.yaml` 里是 `1.0.0+1`），而且 release 包不是 debuggable，
`-d` 也没用。按上次的老办法重打一份：`flutter build apk --release
--target-platform android-arm64 --build-number 2002`（不动 `pubspec.yaml`）。

**服务端**：一个字都没动。

---

### S10.1 切换账号（最多三个）（2026-09-29）

用户原话：「设置里，退出登录上面再搞一栏 UI 跟退出登录一样的叫『切换账号』，点进去
就是那张图那样，最多可以切换三个账号…点击『添加账号』就是出现一个底部抽屉，两个分别
是注册新账号和登录其他账号」（图来自 Mosavi，客户端的 logo 换成我们自己那张）。

#### 本机是**单槽位**会话，所以不是另起一套体系

`CredentialStore` 里 `authToken` / `userInfo` / `client_id` 各一份，`hasSession`
就是「token 非空」；路由守卫、网络层、WebSocket 全读那一份。于是多账号的做法是：
**当前账号仍然是那一份**，另外几份存在新的 `SavedAccountsStore` 里，切换 = 把目标的
那一份写回单槽位。好处是 `apiClient` / `sessionGuard` / `WsService` **一行都不用改**。

| 文件 | 干什么 |
|---|---|
| `core/store/saved_accounts.dart`（新） | 最多 3 份 `SavedAccount`：整份 `userInfo` + `authToken` + 本机用过的 `clientIds` + `usedAt`；与 `ClearedChatsStore` 一个路子（单例 + 一份 JSON + `revision` 通知界面） |
| `domain/session/session_service.dart` | `switchAccount()` / 登录时把**上一个**账号存进列表 / 退出登录把那一条的令牌清空 / `_onOffline` 加固 |
| `features/mine/accounts_page.dart`（新） | 切换页：品牌块（复用 `AuthBrand`）→ 「轻触头像以切换账号」→ 账号卡 → 「添加账号」；右上角「管理」 |
| `core/router/app_router.dart` | `/mine/accounts`、`/mine/accounts/add`、`/mine/accounts/add/register` |
| `features/login/{login,register}_page.dart` | 加了 `addAccount` 模式（预填账号 / 登录成功后回主界面 / 注册完换成登录表单） |
| `features/mine/setting_page.dart` | 退出登录上面那一行（两行共用 `_centeredRow`，样式完全一致） |
| `main.dart` | 会话监听多认一种情况：**「换人了」**（见下） |

#### 用户定的四条规则

1. **最多三个**：存满后「添加账号」那一行**不画**（不是弹提示拦你）；要加先点「管理」
   删一个，余位回来那行自己出现。
2. **卡片第二行是「恩信号」**：服务端没有单独的号码字段，就用登录账号
   （`account`，为空退回 `user_id`）；文案 key 复用「我」页资料卡那个 `user.wechatId`
   （本来就是「恩信号 / Gracelink ID」），没有另造 
3. **退出登录的那一份留在列表里**：但服务端令牌已作废，所以 `authToken` 清空 ——
   卡上标「已退出」，点它进登录表单（账号预填，只输密码）。切换账号**不调登出接口**，
   两条路彻底分开。
4. **管理里当前账号也能删**，删它等同退出登录（弹的是「退出后不会删除任何历史数据…」
   那个确认框）；删别的账号弹的是删账号自己的提示。

#### 三处不改容易踩的坑

* **添加账号不能借道 `/login`**：守卫第 3 条是「已登录的人去登录页就弹回主界面」
  （`authRoutes`），而添加账号恰恰是「已登录再登一个」—— 借道会被弹回来，功能等于不通。
  所以做成 `/mine/accounts/add`（普通路由，已登录可进），**守卫一行都没动**；注册同理。
* **本机聊天数据照旧要清**：本地库没有账号维度（`_resetLocalDataForAccount`），
  不清就会把两个人的收藏串在一起（用户 2026-09-21 报过的「乱套了」）。所以切换后
  列表是空的、要重新从服务端拉一遍——`main.dart` 那段监听现在也会在**换人**时跑一次
  `onLoggedOut`（清通讯录 + 群语音那本账 + 正在跑的那通），外加 `onLoggedIn`（整轮对齐）。
  以前只在「登录态 true→false」时跑，而切换是 true→true。
* **被顶下线要认得出自己**：`offline` 那条推送按 `id + client_id + isMobile` 判断，
  而切换账号会换一个 client_id —— 服务端可能把「上一个连接下线」的事件发到新连接上，
  照旧逻辑会**把自己踢掉**。现在每份账号都记着自己用过的 client_id
  （`rememberClientId`，在 `bindUid` 那一步记），命中就忽略。真别的设备不在名单里，照样踢
  （测试里两条都钉了）。

#### 已知限制（写在页面注释里了）

**只有当前账号在线**：一条 WebSocket 只能绑一个 uid，后台那几个账号收不到消息、来电与推送，
切过去那一瞬间才重连 —— 不改造服务端解决不了。令牌有效期也未知（`network.authExpire`
会把人踢回登录页），所以「保存的 token 切过去」在服务端清过 token 后会退化成「要重新登录」。

#### 切换后「其它地方」都跟着变吗（用户追着问过，所以逐项过了一遍）

| 东西 | 谁负责 | 结论 |
|---|---|---|
| 消息列表 | 本地库被清（`_resetLocalDataForAccount(force: true)`）+ 列表本身订阅 DB 流 + `catchUp()` 重拉 | ✓ |
| 消息详情（聊天页 / 分页 / 草稿） | 切换后 `context.go(home)` 把人送回主界面，聊天页整棵拆掉；消息与草稿都在库里（已清） | ✓ |
| 发送中 / 失败的消息 | 没有自动重发队列（重发是在气泡上手动点的），失败那行随库一起清 | ✓ |
| 底部红点 / 未读汇总 | `visibleTotalsProvider` 由 DB 流 + `hiddenConversations`（已清）算出来 | ✓ |
| 通讯录 | `main.dart` 的「换人了」分支 → `chatSync.onLoggedOut()` 清本地 + `catchUp()` 重拉 | ✓ |
| 系统通知那条的未读计数 | 同上（`onLoggedOut` 里归零） | ✓ |
| 1:1 通话 | `callControllerProvider` 盯 `user_id` → 重建，`call_host` 顺手把通话页收掉 | ✓（登录/登出走的就是这条路） |
| 群通话（在跑的那通 / 横幅 / 「谁在开」） | 同一个「换人了」分支 → `groupCallSession.reset()` + `presence.reset()`；`groupCallBusyProvider` 跟着变 false | ✓ |
| 推送（WS） | 重连后 `init` → `bindUid` 拿的是**新账号**的 user_id + token | ✓（测试里钉了） |
| 推送设备标识 `cid` | `_bindAfterInit` 的 HTTP `bindUid` 把 cid 与新 uid 一起登记（`PushRegistrar` 自己因「cid 没变」会跳过，不指望它） | ✓ |
| 通知栏里旧账号的通知 | **审计时补上**：切换时 `cancelAll()`（不清的话点一下会拿着新账号去开那个会话 id） | ✓ |
| 正在播的语音 | **审计时补上**：切换时 `voicePlayingProvider.stop()` | ✓ |
| 通知点击 / 冷启动那套宿主 | `NotificationHost` 自己不留账号态 | ✓ |
| 界面里那个 `client_id` | 顺手清了 `WsService._clientId`（连接一断就没意义，避免拿死 id 去 `bindGroup`） | ✓ |
| 语言 / 设置 / 聊天背景 | 设备级偏好，不跟账号走（背景是按会话 id 存的，已清） | ✓ |
| 灵听（音乐） | 另一套匿名账号（`LingtingStore`），刻意不动 | — |

剩下的是**服务器侧的未知数**（客户端做不了）：设备表里 `cid`↔旧 uid 那一行会不会被新 uid 覆盖 ——
没覆盖的话旧账号的离线推送可能还会落到这台机器上；`cancelAll` 只能把「点旧通知」那条路
堵掉。另外切过去那一瞬间会看到「列表空 → 拉回来」（本机缓存按既有规则清掉了）。

#### 验证

`flutter analyze` 干净、`dart format` 干净、全量 `flutter test` **1825 通过**：

* `test/core/saved_accounts_test.dart`（8 条：读写往返、同 id 替换、三个上限与顶替规则、
  恩信号回落、touch 排序、client_id 记账与上限、删除、脏数据不炸）；
* `test/session/account_switch_test.dart`（8 条：登录自动进列表、一键切换（身份/令牌/
  上一个账号留着/本机数据清掉/重连后用新身份 bindUid）、令牌作废只报 needsLogin、
  未知与当前账号、退出登录保留条目、offline 自认 client_id、**没记过 `lastUserId` 时
  也要强制清库**、**顺带清通知栏与停语音**）；
* `test/features/accounts_page_test.dart`（6 条：设置里那两行的位置与样式、账号卡与
  「当前使用」、满三个不画添加行 + 管理删除后回来、删当前账号=退出登录、添加抽屉两条路、
  「已退出」那一条点进登录表单且账号预填）。

**服务端**：一个字都没动（每个账号仍是各自正常登录，切换只是本地换令牌 + 重连）。

---

### S11.1 资讯频道：像公众号，但文章是自动抓来的（2026-09-29）

用户原话：「想做一个微信公众号一样的功能，但我懒得自己发文章，有没有办法自动获取到新闻
资讯然后显示出来」。问过之后定的方案：**纯客户端资讯页**，内容由**手机自己去拉公开 RSS**
（备选是服务端定时聚合，好处是能推送新文章、能出未读红点、还能把它做成消息列表里真正的
会话，但服务端要动 —— 用户这轮选了不动服务端）。

#### 落在哪儿

「发现」里加了第二栏「资讯」（在「灵听」下面）：图标是一颗 Material 图标 + 圆角底色
（没往仓库里加新的图片资源），名字走语言包。点进去是列表，再点进详情。

```
发现 › 资讯
  /news/index    列表：来源 · 时间、两行摘要、缩略图、未读红点、全部已读
  /news/detail   详情：标题 / 来源 · 时间 / 大图 / 摘要段落 / 「阅读原文」「复制链接」
```

#### 四个源（写死在客户端）

`IT之家` `少数派` `爱范儿` `奇客 Solidot`。选的时候是**一个个实测过的**，不是拍脑袋列：

* 可用：`ithome.com/rss/`、`sspai.com/feed`、`ifanr.com/feed`、`solidot.org/index.rss`；
* **36氪不放**：`36kr.com/feed` 现在返回的是 WAF 拦截页（HTTP 200 + 一句「正在进行安全检测」）；
* **虎嗅不放**：`huxiu.com/rss/0.xml` 直接超时；
* 海外源（BBC/路透那类 RSS 很规整）不放：国内设备到不了。

源名是第三方品牌名，所以**走语言包**（`news.source.*`）：中文包 `IT之家`、英文包 `ITHome`。
换源要发版（要免发版就得走服务端聚合）。

#### 手写的解析器（零新依赖）

`domain/news/feed_parser.dart` 自己解析 RSS 2.0 / Atom，**没引 `xml` / `html` 包**
（那一轮的顾虑写在文件注释里：只想吃四个写死的源，用不上通用 XML，而多一个依赖就是多一份
要跟着 Flutter 升级走的负担）。四种真实形态都得吃下：

* CDATA 包裹（Solidot）、被转义的 HTML（IT之家 / 少数派）、真 HTML（爱范儿的 WordPress）、
  自闭合带属性（Atom 的 `link rel=alternate href=`、`media:content url=`）。

跑测试时抓出来的两个真 bug（都会在真机上出错，不是测试写法的问题）：

1. **CDATA 没先拆**：`htmlToText` 第一步是「去标签」，而 `<![CDATA[正文……<p>` 从 `<` 到第一个
   `>` 整段会被当成一个标签删掉 —— Solidot 的摘要只剩一个 `]]>`。现在拆 CDATA 放在洗标签之前。
2. **`Uri.replace(query: ...)` 的坑**：`replace` 的 null 参数是「保留原值」，传空串又会留下一个
   光秃的 `?` / `#`。结果 Atom 条目的地址尾巴上挂了个 `#`，同一条新闻算成两条。改成自己重拼 Uri。

另一处刻意的选择：**日期里没有时区就按北京时间算**，而且不能交给 `DateTime.tryParse` ——
它对 `2026-09-29 23:25:25` 也会成功，并按**设备时区**理解，同一个源在两台机器上会变成两个
时间。认不出来（比如「刚刚」）就留空：宁可不显示时间，也不显示一个错的时间。

#### 只给摘要 + 缩略图，正文点「阅读原文」

详情页**不做全文渲染**，三个理由：版权（只给摘要与链接最稳）、依赖（真渲染 HTML 要引
`flutter_html` 那类）、排版（源站正文里塞满推广卡片和 `data-*`，硬渲染比纯文本更难看 ——
IT之家的正文第一张图就是京东商品卡，所以缩略图**只从 `content:encoded` 里找**，
不认 `description` 里那张）。摘要截到 1000 字，同时也是缓存体积。

「阅读原文」走的是**聊天里点链接那套同一逻辑**（`core/ui/link_opener.dart` 的 `openChatLink`）：
新闻源都是第三方站点，所以先弹「第三方网址，是否继续访问」再进内嵌浏览器。

#### 单源挂掉不能让整页没内容

抓取是**并发 + 各自 try/catch**：

| 情况 | 表现 |
| --- | --- |
| 某个源超时 / 5xx / 返回 WAF 页 | 其它源照常出内容，列表底部点名「这些来源这次没拉到：…」 |
| 一个源都没拉到，但本机有缓存 | 画缓存，顶上「网络不可用，显示的是上次拉到的内容」 |
| 一个源都没拉到且没缓存 | 「资讯加载失败，请检查网络后重试」+ 重试按钮 |

解析出 0 条**也算这个源这次没拉到**（拦截页的 HTTP 是 200，只看状态码会以为「今天没内容」）。

#### 缓存与已读

都放本机 SharedPreferences（不是数据库），键 `newsCache` / `newsReadIds`：最多 120 条、
已读 id 只留最近 300 条。**换账号时刻意不清**（资讯是公开内容、不属于任何账号，清了只会让
用户切回来白等一次重新拉取）。「已读」是进详情页那一刻标的（`initState` 里一次，不在 `build` 里
反复写盘）。

#### 验证

`flutter analyze` 干净、`dart format` 干净、全量 `flutter test` **1856 通过**（新增 31 条）：

* `test/news/feed_parser_test.dart`（13 条：四种真实报文、CDATA/转义/自闭合、自链接「查看全文」
  剥掉、utm 归一化去重、guid 优先、Atom 的 rel=alternate 与 media:content、三种时区写法算成同一
  时刻、认不出的时间留空、无标题丢掉、WAF 页解析成空、摘要截断、源名走语言包）；
* `test/news/news_repository_test.dart`（9 条：并发出4个源、按时间倒序、单源超时与 WAF 页容错、
  全挂回读缓存、全挂无缓存抛网络异常、抓取时间、已读落盘且不重复写、坏缓存不炸、已读 id 上限）；
* `test/features/news_pages_test.dart`（8 条：列表版式与未读红点、进详情标已读且返回后红点消失、
  「阅读原文」先弹第三方闸门、断网画缓存、失败重试能拉回来、部分源失败点名、id 找不到不白屏、
  英文界面跟着换）；
* `test/features/compass_page_test.dart`（+1 条：点「资讯」进列表）。

**服务端**：一个字都没动。

#### 这一版做不到的（服务端才能解）

* **没有新文章推送**：用户得自己进来看（客户端没有能定时拉的后台任务，也没有服务端推的钩子）；
* **换源要发版**；
* **它不在消息列表里**：只是个「发现」入口，不是那种带未读红点的会话 ——
  要那样得服务端真的下发这条会话（客户端自己造的会被 `syncConversations` 的差集删掉）。

这三条都是同一个升级方向：**服务端定时抓取入库 + 客户端只读自家接口**，界面一行不用动
（客户端已经抽了一层：`NewsRepository` 只暴露 `fetch()`，换实现即可）。

---

### S11.2 资讯频道：混着排、分批铺、去掉全部已读、分享成卡片（2026-09-30）

装到手机上让用户看了一遍，回来的四条意见，一次做完：

> 建议混着排，不然容易全是IT之家；一次性加载太多了，先加载十篇，下滑再拉十篇；
> 把全部已读功能去掉，毫无意义；能不能做成像音乐一样的卡片可以分享到聊天里？

#### 1. 混着排（`_merge` 改成按源轮转）

纯按时间倒序时 IT之家会把列表开头占满（它一天几十条，其余三个源一天几条）。
现在**每个源各自按时间倒序，源之间轮流取一条**，源之间的顺序按 `kNewsFeeds` 里
配的顺序 —— 所以同样的内容每次排出来一样，刷新不会跳。

取舍：整条列表不再严格时间递减（第 2 条可能比第 1 条旧）。这个列表本来就是
「随便看看」的形态，不是时间轴，四个源轮着露脸更值得。

#### 2. 分成十篇铺（`NewsListState.visibleCount`）

抓取仍是一次把四个源拉完（RSS 没有分页接口，每个源给的本来就是一整份），
**分批的是渲染**：首屏先铺 10 条，滑到底再续 10 条，尾巴收一句「没有更多了」。
省的是「建 100 多个卡片 + 下 100 多张缩略图」，不是流量。

两个配套细节不然会白做：

* 列表必须是 **`ListView.builder`**：`ListView(children: [...])` 会把子项一次性全建出来，
  「滑到底再续」会变成「一进来就全拉完」（用例里就是这么抓到的：首屏断言写 10，实际是 20）；
* 续拉靠**尾部那个 widget 被建出来**（`addPostFrameCallback` 里 `loadMore`），
  不是靠滚距计算 —— 也就自然带上了「先填满一屏」的效果。
* 刷新**不动**已经露出的条数：滑到第 60 条时下拉不该把人甩回顶部。

#### 3. 去掉「全部已读」

用户：「毫无意义」。入口、`NewsListController.markAllRead`、`NewsRepository.markAllRead`
和语言包里的 key 一起删了（未读红点留着：点进详情就消）。

#### 4. 分享成卡片（`type: 'news'`）

照搬灵听那套（用户原话：「做成像音乐一样的卡片」）：

* `domain/news/news_card.dart`：`content` 放会话列表/通知里那行字（`[资讯] 标题`），
  渲染字段全放 `extends`；
* `MessageSender.sendNewsCard`（与 `sendMusicCard` 同一个 `_send`）；
* `NewsCardBubble`：标题两行 + 「来源 · 时间」+ 右侧缩略图 + 底部「资讯」；
* `ConversationRules.preview` 加 `'news' => 'common.news'`（列表与通知显示「[资讯]」）；
* 入口是详情页底栏原本「复制链接」旁边那颗分享图标，选人复用聊天那套转发选择器。

卡片里**标题截 120 字、摘要截 200 字**：`extends` 会跟着消息一起存和推，
整篇 1000 字摘要塞进去没必要（别的端还会把它当正文渲染）。
收卡片的人本机列表里没有这一篇（那是发的人机器上抓到的），所以点卡片进详情页时
**把卡片作为路由 `extra` 带过去**，详情页在列表里找不到就用它合成一条（标题/摘要/
缩略图/原文地址都在，点「阅读原文」照样看全文），且不标已读。

已知取舍（与音乐卡片一致）：服务端不校验 `type`，但**官方网页端与旧 uniapp 收到会
显示「暂不支持的消息类型」**。

#### 验证

`flutter analyze` 干净、`dart format` 干净、全量 `flutter test` **1867 通过**（新增 11 条）：
轮转混排与顺序稳定（仓库 2 条）、分页（首屏不铺满 + 滑到底续页 + 收尾句）、
分享进来的那一篇（列表里没有也能看 + 阅读原文仍走闸门）、详情页分享入口、
卡片模型往返与截断（6 条）、聊天里卡片渲染并点入详情（1 条）。

---

### S11.3 「媒体号」：改成公众号那样一张卡一个号（2026-09-30）

用户给了两张公众号的截图，要求「把 UI 改成这样子，有图片的放上面，越像越好」
（并明确：右上角那三颗图标不用抄，搜索能做就做；名字叫**媒体号**，不叫资讯）。
上一版是一条条平铺的信息流（左边标题+摘要、右边缩略图），用户看了说「全是 IT之家」
「一次加载太多」——这一轮改成**一屏一张一张的号卡**。

#### 版式（`features/news/widgets/news_source_card.dart`）

```
┌──────────────────────────────────────────┐
│ (头像) 少数派                    14小时前 │   ← 卡头是**号**，不是文章
│ ┌──────────────────────────────────────┐ │
│ │   封面（标题压在图上，下深上透渐变） │ │   ← 「有图片的放上面」
│ └──────────────────────────────────────┘ │
│ 可塑的白昼：ColorOS17 深度评测      [图] │   ← 没图的小行只占左边
│ ───────────────────────────────────────── │
│ 余下 12 篇                              ⌄ │
└──────────────────────────────────────────┘
```

* 卡头 = 品牌色圆底 + 一个字（`NewsSourceStyle`；没有真实 logo 可引，
  但**颜色故意错开**：IT之家和少数派都是红的，纯红＋纯红两张卡会分不清）；
  右上角是号里最新那篇的相对时间（`feedTime`：`14小时前` / `昨天`）；
* 第一篇：**图在上、标题压在图上**（用户原话「有图片的放上面」），
  16:9 + 「中透下深」的渐变底，白字加一点阴影 —— 压什么图上都读得清；
  还没有封面时退成「大标题」，补到图自己就换版；
* 后面几篇：左标题 + 右 66dp 缩略图，行间一条**从标题左边起**的细线；
* 未读完的收在「余下 N 篇」后面，点一下**这个号**再露 10 条。

**列表里不再放摘要**（公众号的卡片也不放）：摘要归详情页。

#### 分页按号算（`domain/news/news_providers.dart`）

`NewsListState` 从「全局 `visibleCount` 平铺分页」改成 **`Map<sourceKey, int> expanded`**：
每个号先露 3 条，点哪张卡的「余下N篇」就展开哪张，别的卡不受影响。
（上一版滑到底自动续页：号卡下面没有「底」，续页那套在这里就不成立了。）
刷新**不动**已经展开的号。

#### 搜索

AppBar 右上角一颗搜索（截图里最右边那颗，用户说「能做就做」）：点开变成输入框，
对**已经拉到的那批**按标题/号名筛（不发新请求、即时出结果），结果是平铺的一行行，
搜不到就一句「没有找到相关文章」。搜不到还没拉到的内容 —— 那本来也搜不出来。

#### 封面：IT之家 / 少数派 / Solidot 的 feed 里一张图都没有

`htmlMetaImage` 原来只认 `og:image` / `twitter:image`。用**这台机器的真实网络**
（先 `read_url`、后在浏览器里同源 `fetch` 拿原始 HTML）逐个实测了四个源的头几篇：

| 号 | feed 带图 | 原文页 og:image | 兜底（正文第一张图） |
| --- | --- | --- | --- |
| IT之家 | ❌ | ❌ **根本没有** | ✅ 懒加载的 `data-original` |
| 少数派 | ❌ | ✅ `rssfile.sspai.com/...` | — |
| 爱范儿 | ✅ | ✅ | — |
| 奇客 Solidot | ❌ | ❌ | ❌ 只有 `php.gif` 徽章和 59×57 的板块图标 |

所以补了两条：**认懒加载**（`data-original` / `data-src` / `data-lazy-src` / `data-echo`，
IT之家的 `src` 是个 1px 占位 `//img.ithome.com/images/v2/t.png`，只看 `src` 就是拿到它）、
**过滤站点装饰图**（logo / icon / avatar / btn / gif / svg / 明写着 <300×200 的）。
Solidot 那个 59×57 的图标就是这样被挡住的 —— 宁可画纯文字的卡，
也不要把人家的 php.gif 当封面。相对地址与 `//cdn...` 也在这里补成绝对地址。

封面**一篇一次 HTTP**（原文页几百 KB），所以 `NewsCoversNotifier` 同时最多拉 4 张，
而且只给**卡片上露出来的那几篇**拉（不是一进页面就把上百篇都拉一遍）；
每补到一张 provider 刷一次，卡片自己就换版，不用等四张齐。失败一律静默降级成纯文字卡。

#### 改名

`news.title` / `common.news`：资讯 → **媒体号**（英文 `Media`）。
「阅读原文」那条闸门、卡片分享、未读红点、缓存策略全部照旧。

#### 验证

`flutter analyze` 干净、`dart format` 干净、全量 `flutter test` **1874 通过**
（资讯相关新增 5 条：号卡版式、封面上屏、按号展开、搜索、封面提取的四种报文形态）。
新增/改写的用例：号卡（卡头号名 + 一卡一图 + 没有摘要）、懒加载封面、
「余下N篇」只展开点的那张卡、搜索筛选且不再请求、封面提取（og 优先 / 懒加载 /
装饰图全挡 / twitter 兜底）。**服务端一个字没动。**

---

### S11.4 两处收尾：分享卡片统一白底、「发现」两栏之间留缝（2026-09-30）

用户：「转发到聊天里的不管是灵听还是媒体号文章，都改成对方发给我的那种 UI，
白色的这种气泡框，不要绿色了，不管我发给他还是他发给我都用白色」；
「发现页面的这一栏一栏之间稍微隔开一点点距离，就像第一栏和顶部栏一样的距离差不多」。

#### 卡片不分你我，永远白底

`MusicCardBubble` / `NewsCardBubble` 原来按 `mine` 选色（自己的绿 `#95EC69`、
对方的白）。现在**底色写死纯白**，两边那个 `mine` 参数直接删了（调用方、用例里都没人再用）
—— 分享卡片是「一张卡片」而不是「一句我说的话」，绿底会让人误以为卡片里的标题是我打的字。
**只有普通文字气泡分颜色**（自己的绿 + 黑字、对方的白），那条路径没动。

回归用例：`test/features/message_render_test.dart`——自己发的（`fromUserId` 是自己）
灵听/媒体号两张卡片，底色都断言 `AppColors.white`。

#### 「发现」：两栏各占一块白底

原来是「一整块白底 + 一条缩进分隔线」，现在是**两块白底、中间留 `rpx(20)` 的缝**
—— 与页面上下留白（顶部栏到第一栏）同一个值，所以两处看着一样宽。
分隔线（连同它的 helper）删了：留着线又加缝会像「两块之间还连着一条线」。

回归用例：`test/features/compass_page_test.dart` 里用 `tester.getRect` 量出
「第一栏顶 - 页面顶」与「第二栏顶 - 第一栏底」，断言两者相等（`closeTo … 0.5`）
—— 量像素不靠眼睛。

#### 验证

`flutter analyze` 干净、`dart format` 干净、全量 `flutter test` **1876 通过**。
arm64 release 已装机（`--build-number 2008`）。**服务端一个字没动。**

---

### S11.5 媒体号：去掉下拉刷新（改成半小时自动刷）、扩到 11 个源（2026-09-30）

用户：「把下拉刷新功能去掉，就改成每半个小时自动刷新一次（也不用提示更新于什么时间）」；
「能不能再多搞几个源？或者你是通过什么来获取文章的」—— 后者答：公开 RSS。

#### 刷新改成自动的

* **底下没有「下拉刷新」了**（`RefreshIndicator` 删掉，页面上再也找不到）。
* **进页面时**：手上这份如果超过 `autoRefreshInterval`（30 分钟）就悄悄刷一次
  （`NewsListController.refreshIfStale`）；首次进页面 `build` 本来就抓，所以这一路
  只对**再进来**有意义。
* **页面开着时**：每 `staleCheckInterval`（5 分钟）问一次「该更新了吗」——
  每次只是比一下时间戳（不发请求），所以问得比刷得勤，数据最多 30+5 分钟旧。
  抖动成 5 分钟一检查还有个副作用是**好处**：抓失败时（`cachedAt` 一直是上次成功的时间）
  就变成了每 5 分钟自己重试一次，用户不用管。
* **顶上那条时间没了**（`news.updatedAt` 这个 key 从两份语言包删掉）。
  但「正在更新…」（新的 `news.updating`）和「网络不可用，显示的是上次拉到的内容」留着
  —— 前者是进度、后者是**警告**，都不是「上次几点抓的」那种可有可无的信息；
  两件事都没有时整条 `SizedBox.shrink()`，不占位置。

配套的关键一条：**刷新期间不再切成 `AsyncLoading`**（新增 `NewsListState.updating`）。
理由是自动刷新每半小时就来一次，切 loading 会让整页闪一下、已经点开的「余下N篇」
缩回去（`AsyncLoading` 没有值，页面只能回退到磁盘缓存那份，`expanded` 就丢在那一瞬）。
现在刷新期间画的一直是上一份内容；刷新**失败**也留着旧内容（只把 `fromCache` 打开，
于是顶上那句「显示的是上次拉到的内容」会说真话）；本来就没内容才抛给页面画「加载失败 + 重试」。

用例：新增 `test/news/news_providers_test.dart`（7 条，不用起界面）——
半小时内不白刷、超过半小时自己刷、`cachedAt == 0`（一直没抓到）也每次都重试、
正在抓时不叠第二次、失败保留旧内容、刷新不动已展开的号、刷新那一刻页面仍有旧内容。
页面那边加了一条「再也找不到 `RefreshIndicator`、也找不到『更新于』」。

#### 源从 4 个扩到 11 个

新增：**极客公园**（geekpark 30 条）、**钛媒体**（tmtpost 18 条，feed 自带图）、
**界面新闻**（jiemian 30 条，综合新闻，不只科技）、**cnBeta**（150 条，量最大）、
**量子位**（qbitai 10 条，AI）、**InfoQ 中文**（20 条，开发者）、**小众软件**（appinn 10 条，带图）。

试过但**没放**的（都记在 `news_feed.dart` 的头注释那张表里，省得以后重试一遍）：
36氪（WAF 拦截页）、虎嗅（超时）、品玩/机器之心（200 但 1~3KB，解析 0 条）、
果壳/澎湃（404，RSS 早停了）、数字尾巴（403）、新浪科技（能拉，最近一条是 **2018** 年的）、
中关村在线（能拉，但 **GBK** 编码，标题全是乱码）、雷锋网（330KB）/开源中国（新闻流里混推广）、
V2EX（是论坛帖子）。

`kNewsFeeds` 的顺序就是**号卡顺序 + 轮转顺序**，重新按信息密度排了一遍。
新号的品牌色 + 徽标补进 `NewsSourceStyle`（11 个源里蓝色系有三个，所以除色相外
还靠两三个字符的徽标区分）。另加一条用例：**每个源的 `nameKey` 都得在双语包里**
（源名是 `'news.source.' + key` 拼出来的，上面那条「字面量 key」扫描扫不到，
写错了会直接把 `news.source.xxx` 显示在卡头上）。

**实测（这台机器的真实网络，11 个源）**：全部成功，抓完 120 条（库上限）
—— 每个源 10~12 条，轮转顺序 = 配置顺序。一轮总流量 **约 1.06MB**
（极客公园 311KB、爱范儿 251KB、IT之家 191KB 是大头）。封面兜底：IT之家/少数派/
极客公园/cnBeta 挖得到，**界面新闻和奇客挖不到**（页面里既没 `og:image` 也没有正文图），
那两张卡就老实画纯文字。

#### 验证

`flutter analyze` 干净、`dart format` 干净、全量 `flutter test` **1886 通过**（新增 10 条）。

`--build-number 2100` 已装机，手机上验了四件事：

* **11 张号卡全在**（IT之家 / 界面新闻 / 钛媒体 / cnBeta / 极客公园 / InfoQ / 爱范儿 /
  奇客 / 量子位 / 少数派 / 小众软件），号卡顺序是按「号里最新那篇」排的（最新更新的号浮上来）；
* **顶上再没有「更新于 …」**（差量比对整份语义树，『更新于』/『正在更新』都是 0 处）；
* **下拉真的什么都没发生**：在顶部慢慢下拉 1100px，前后语义树**逐字一样**
  （有 RefreshIndicator 时必然多出一行进度指示）——下拉刷新确实拆干净了；
* **自动刷新在真机上跑通了**：临时把两个间隔改成 3 秒 / 1 秒打了个包（`--build-number 2099`，
  验完就改回来并重打过），看到「正在更新…」一次次出现，**出现时卡片还在**
  （不是 loading 白屏），卡头的相对时间也跟着从「刚刚」变成「1分钟前」。
  logcat 里同时看到真实容错：`[资讯] geekpark 拉取失败：connectionError`、
  `[资讯] sspai 拉取失败：receiveTimeout` —— 手机上少数派确实会超时，
  但页面照常出别的源。

**服务端一个字没动。**

---

### S11.6 第 12 个号：用户自己的协会通知网（2026-09-30）

用户给了个地址问能不能加：`https://691f6a1b5b559.site123.me/rss.xml`（「兴华民会通知网」）。

实测：HTTP 200、**12KB**、31 条、时间跨 2025-11 → 2026-09，标题是中/日/英混排（UTF-8，**没乱码**），
日期是 `2026-09-24 12:12:00` 这种裸时间 —— 和其他源一样按 +0800 理解，
所以在手机上显示出来的数字**跟站点自己写的一致**。能吃下，就加了。

但它是**公告站**，不是媒体，两个特点要专门处理：

* **feed 里 `description` 全空**（31 条里只有 1 条有）→ 这个号是**纯标题卡**，
  详情页走现成的那句「这条来源没给摘要，点『阅读原文』看全文」；
* **`og:image` 是全站同一张头图**（三篇原文页挖出来是同一个 `800_gi-…jpg`）
  —— site123 把站点头图当成了 og:image。照原逻辑，这个号的每篇文章都会贴着
  **同一张图**，看着像坏了。

所以给 `NewsFeed` 加了 **`pageCovers`**（默认 `true`，这个源设 `false`）：
仓库层的 `resolveCover` 直接返回空串，**不发请求也不落盘**
（调用方会把空串记在内存里，不会反复问），这个号就老实画纯标题卡。

其余：号名 zh「兴华民会」/ en「Xinghua Minhui」，徽标「兴」+ 金 `#B4881F`；
放在 `kNewsFeeds` **最后** —— 它是公告不是媒体，轮转取用时不跟新闻抢前面的位置
（号卡顺序本来就只按「号里最新那篇」排，它一发新公告自然会浮上去）。

用例：`resolveCover` 对 `pageCovers: false` 的源**一个请求都不发**（断言假 adapter
没收到任何请求）；S11.5 那条「每个源都有中英号名」自动把它也盖上了。

**装机验证**：手机列表末尾就是「兴 · 兴华民会 · 5天前」的号卡，三条标题都在，
点进去详情页能读、「阅读原文」能开原文页。
同屏还出现了一句「这些来源这次没拉到：**极客公园**」—— 这个手机的网络下，
它那个 311KB 的 feed 会撞上 12 秒的 receive 超时（容错生效，页面照常出别人家的）。

`flutter analyze` 干净、全量 `flutter test` **1887 通过**。`--build-number 2101` 已装机。

---

### S11.7 媒体号：把顶部「网络连接失败」和底部「这次没拉到…」两句去掉（2026-09-30）

用户：「把媒体号首页顶部『网络连接失败』和底部的『这次没拉到...』文案去掉」。

* **顶部那条没了**：「网络不可用，显示的是上次拉到的内容」——`_StatusBar` 现在
  只剩「正在更新…」（而且**只在真的正在抓的时候存在**），不更新时整条
  `SizedBox.shrink()`，不占位置。缓存内容照常画，**只是不再解释了**。
* **底部那句没了**：整段「这些来源这次没拉到：极客公园」的 `Padding` 删掉。
* 两个 i18n key（`news.offlineCache` / `news.failedFeeds`）**连着从双语包删掉**，
  不留没人用的文案（i18n 对等用例继续看着两份包）。

数据一点没丢：`NewsFetchResult.failedFeeds` / `fromCache` 还在（日志和用例用），
但两个**专为渲染而存在**的桥接 getter 删了 —— `NewsFetchResult.failedFeedObjects`
和 `NewsListState.failedFeeds`，它们存在的唯一理由就是那句话。（`failedFeedObjects`
原先还有个用例在断言，改成直接断言 `failedFeeds` 的 key 清单。）

用例改成**反向断言**（拦住「以后又加回来」）：

* 「没网但本机有缓存」：缓存内容照常画，页面上**找不到任何含「网络」的文字**；
* 「部分源没拉到」：活着的源照常出内容，**找不到任何含「没拉到」的文字**。

**装包静态核对**（手机当时没插，先用解包验）：

```
unzip -p app-release.apk assets/flutter_assets/assets/i18n/zh-Hans.json \
  | grep -c "网络不可用|没拉到|offlineCache|failedFeeds|更新于"   → 0
```

中文、英文两份包都是 0 —— 这两句话（连带早先的「更新于 …」）**已经不在包里了**。

`flutter analyze` 干净、全量 `flutter test` **1887 通过**。
`--build-number 2102` 的包已打好，插上手机就装。

---

### S11.8 文章详情页改版：顶栏分享、底栏只留阅读原文（2026-09-30）

用户：「文章详情页 UI 再美化一下，底部就留一个阅读原文，分享按钮放到右上角去，
复制链接去掉不要」。

改完的版式：

```
←   少数派                    [分享]   ← 顶栏写**号名**（公众号读文章时顶上就是号）
┌─────────────────────────────────┐
│ 标题（44rpx / 粗）                 │
│ (派) 少数派  09-24 14:20           │ ← 头像 + 号名 + 时间
│ ───────────────────────────────── │
│ [        封面（16:9，圆角）       ] │
│ 摘要段落…（31rpx / 1.75 行高）       │
│ ───────────────────────────────── │
│ ▤ 以上是来源给出的摘要…              │
└─────────────────────────────────┘
        [       阅读原文       ]          ← 通栏一颗，只剩这一颗
```

* **顶栏**：标题从「媒体号」改成**号名**（长号名 `maxLines: 1` + 省略号，不让它撞 
  到分享那颗）；右边一颗分享（原来在底栏）。
* **底栏**：只剩**通栏**的「阅读原文」（多加一条上分隔线 + 白色底 + SafeArea）。
  它本来就是这页唯一的主操作，满宽之后不再和别的钮抢地方。
* **复制链接整个删了**（包括 `Clipboard` 那个 import、`_IconButton` 小方钮组件、
  以及语言包里那个 `news.copyLink`）—— 删 key 不是洁癖：没人用的文案留着，
  下次改风格时还得猜它是不是还有用。
* 版式上顺手都一遍：标题与 meta 行间距放宽（26rpx）、号名那行换成
  **头像 + 号名 + 时间**（和列表卡头同一套观感）、封面 16:9 圆角（和列表里那张一致）、
  正文 31rpx/1.75、尾注前面加一条分隔线并配一个小图标，说的还是「这是摘要」。

为了两边长得一样，顺手把号头像抽成 **`widgets/news_source_avatar.dart`**
（`NewsSourceAvatar` + `NewsSourceStyle`）：列表卡头、详情页共用一份
（尺寸给参数：卡头 64rpx、详情页 48rpx；两个字的徽标自动小一档）。
原来它埋在列表卡那个文件里，详情页要用就只能复制一遍配方。

用例（详情页那几条里加深）：底栏只有一颗「阅读原文」，**`复制链接` 和那个链接图标
必须找不到**，`ios_share` 只有右上角那一颗；顶栏与 meta 行**两处都有号名**
（断言 `findsNWidgets(2)`，并写清楚为什么是两处）。

`flutter analyze` 干净、全量 `flutter test` **1887 通过**。
`--build-number 2103` 的包已打好（手机当时没插，插上就装）。

---

### S7.3 二维码「保存图片」存下来的是微信那种海报（2026-09-30）

（挨着 S11.x 放在文末：这份文档是按时间往后追加的。）

用户：「群二维码还有自己的二维码点击保存图片保存下来都是这个样子的，也太奇葩了吧
这么大边上一点白边没有？照这个把群的还有个人的二维码保存图片都改一下」。

**病根**：存的那张就是**屏幕上那一块**（`RepaintBoundary` 直接包着页面里那块），
而页面上的码是 `padding: EdgeInsets.zero` 的 —— 页面上四周本来就是白的，看不出问题，
一存成图就是「一张 756px 的码顶满四条边 + 顶上挤着一行头像和名字」。

**现在存的是单独排的一张海报**（`_SaveCard`），照微信「保存图片」那张：

```
┌────────────────────┐
│       (头像)        │  居中，圆角方
│     群聊：嘻嘻哈哈    │  居中（群是「群聊：名字」，微信那张就是这么写的）
│   ┌──────────┐    │
│   │   二维码    │    │  码自带静区，四周再留一大圈
│   └──────────┘    │
│   该二维码7天内…      │  底部小灰字，居中
└────────────────────┘
```

几个刻意的决定：

* **宽度固定 360 逻辑像素 × pixelRatio 3 = 1080px 宽**，和屏幕多宽无关 ——
  存下来的图在哪台手机上都是同一张（微信那张 1024×1520，我们这张 1080×1644，
  长宽比 1.52 vs 1.48）；卡内尺寸按 **750 设计稿**换算（`_u`），页面上量出来的
  rpx 值可以直接拿过来用；
* 四周留白 120/750、码的静区 45/750 → **码只占宽度的一半多一点**，不再顶边；
* 缩放系数锁死（`TextScaler.noScaling`）：存出去的是一张海报，不该因为用户把系统
  字体调大就涨出卡外；
* 挂载方式：放到屏幕**左边外面**（`Positioned(left: -width)` + `Stack(clipBehavior: Clip.none)`）
  —— 它照样会被绘制，而 `RepaintBoundary` 抓的就是它自己那层，跟它在不在屏幕里无关；
* 卡上的码用 **`QrPainter` + `CustomPaint`**（不是 `QrImageView`）：一来能给静区，
  二来正好让「页面上只有一个 `QrImageView`」那条老断言继续成立；
* 头像**不复用 `ContactAvatar`**（它按屏宽算 rpx，和固定宽度的卡对不上），卡上自己画：
  圆角方 + 灰底 + `person` 占位；抓之前先 `precacheImage`，不然抓下来是个灰块。

**屏幕上那一页没动**：那套是照微信的**页面**量出来的（头像行在左、码 504rpx 贴边），
用户抱怨的是「存下来的图」。个人码和群码两条路都换成了这张海报。

用例（新增一条，加上把老用例里「页面上」的断言限定住）：

* 新增「存下来的那张是微信那种海报」—— **真去遍历像素**：图宽 1080、长宽比 1.3~1.8、
  最外面 2% 一圈**不准出现黑点**（正是用户那句抱怨）、码那一带左右各留 ≥15% 且水平
  居中、码宽 < 卡宽 60%、名字居中；
* 老用例里查页面文案/位置的断言用 `KeyedSubtree(key: 'qrcodeScreen')` 限定在「屏幕上」
  —— 存相册那张故意写了同一句提示语；
* 踩到的一个测试环境细节：卡高常是小数 → 最外一行是**半透明白**（AA），
  所以「白边」检查只算 alpha=255 的像素，否则每次都会栽在最后那一行。

`flutter analyze` 干净、全量 `flutter test` **1889 通过**。
`--build-number 2104` 的包已打好（手机还是没插，插上就装并把存出来的图拿回来核对）。

---

### S7.4 未入群的人扫群二维码，报「您没有操作权限！」（2026-09-30）

用户：「还有为什么一个未入群的账号扫描群二维码显示"您没有操作权限！"这是啥鬼？
群二维码不就是为了给别人扫码入群用的吗？你没有操作权限那怎么入群啊？这什么奇葩bug啊赶紧修复。」

**先承认：这确实是我们的锅，但病根在「服务端接口的职责分家」，不在扫码本身。**
（服务端这次没动，改的是客户端 —— 下面会写清楚为什么客户端能单独修掉。）

对着服务端源码把整条链路捋了一遍（`app/index/route/app.php` → `Index::scanQr()`/`Index::group()`
→ `app/enterprise/controller/Group::groupInfo()`），实情是：

* 群二维码的内容是 `…/scan/g/<authcode(uid-group_id)>`；
* `scan/:action/:token` 那条路（`Index::group`）**是公开的** —— 它解出 `realToken`、
  把群那一行原样回给你，还顺手补了 `avatar`、`invite_id`（码的创建人，必然是群成员）、
  `id = 'group-<群id>'`、`action = 'groupInfo'`。**它压根没有成员校验**，扫谁都能进这一步；
* 真正会拒绝人的是**紧接着的第二步**：群资料页去拉 `/enterprise/group/groupInfo`，
  而 `Group::groupInfo()` 头一行就是
  `checkGroupMember($group_id, $this->uid)`（`GroupUser` 里 `status=1` 那行），
  不为空才继续，否则 `return warning(lang('system.notAuth'))` ——
  也就是 `app/lang/zh_cn.php:19` 那句 **「您没有操作权限！」**。

所以逻辑上很讽刺：**这个接口是给「已经在群里的人」看群资料用的，拿来给「还没进群的人」
做入群引导本来就问错了接口**。老端（uni-app）之所以没暴露这件事，是它扫码后直接拿**第一步
（`verify`）返回的那份群资料**把页面渲染出来，根本没依赖第二步。我们这边反而是拿第二步
当数据源，于是非成员一进来就被顶回一句「没有权限」，连「加入群聊」按钮的影子都看不到。

**修法：把第一步「顺手给的」那份群资料真正用起来。**

1. `domain/scan/scan_target.dart`：`ScanVerdict` 多带一个 `GroupJoinInfo? group` ——
   只在 `action == 'groupInfo'` 时按同一条 json 解析出来（`==`/`hashCode` 一并算上）；
   注释里写明「这个接口只有群成员能拉，所以扫码就得把它带过去」；
2. `domain/chat/group_join.dart`：`GroupJoinInfo.fromJson` 做两处容错，都是为了对上服务端
   这一步的**原始库行**（不是精心包装过的模型）：
   * `inviteUid` 兜底读 `invite_id`（服务端给的键名就是它）；
   * 新增 `_asSetting()`：`setting` 在这一步是**没解码的 JSON 字符串**（`'{"invite":0}'`），
     另外几条路径给的又是 map —— 两种都吃，解不开就当 `{}`；
3. `data/api/group_api.dart` + `data/repo/group_admin_repository.dart`：`groupInfo()` /
   `joinInfo()` 加一个 `notify` 开关，一路透传到 `postMap(..., notify: notify)`；
4. `features/common/scan_page.dart`：`_verify()` 跳到群资料页时 `extra: verdict.group`
   把那份资料捎过去；
5. `core/router/app_router.dart`：`AppRoutes.groupInfo` 的 builder 读 `state.extra`，
   是 `GroupJoinInfo` 就当 `scanned` 传进去；
6. `features/contacts/group_join_page.dart`：`GroupJoinPage` 多一个 `GroupJoinInfo? scanned`——
   有它就**直接拿它开页**（不转圈、不请求），后台那次 `joinInfo(notify: false)` 拉到了就更正、
   拉不到（大概率就是那句「没有操作权限」）就**安静地咽下去**，绝不再弹错页/弹提示；
   只有「自己从通讯录点进来」（没有 `scanned`）时，才照旧走「拉不到就报错」那条老路。

一句话：**服务端没变，我们改的是「别拿成员专属接口当入群入口」+「把扫码那一步已经拿到的资料用上」。**

用例：

* `test/core/scan_target_test.dart` 新增一组 3 条：群行解析（`id`/`name`/`avatar`、
  `invite_id`→`inviteUid`、`inviteOpen`、无 `groupUserCount`/`isJoin`）、
  `setting` 传 JSON 字符串 `'{"invite":0}'` 时 `inviteOpen == false`、
  其余 action（`userInfo` / `{}`）`group` 为 null；
* `test/features/group_join_page_test.dart` 新增 2 条：
  ①「未入群（群资料接口拒绝）：用扫码带过来的那份照常显示，并真能加入」——
  让假适配器对 `GroupPaths.info` 回 403「您没有操作权限！」，断言群名照常显示、
  **那句错误话不出现在屏幕上**、`notices` 为空，点「加入群聊」发出去的 body 是
  `{'group_id': 'group-9', 'inviteUid': 'u9'}`（正是 `joinGroup` 要的形状），会话落到 `group-9`；
  ②「扫码带过来的那份 + 群资料拉得到：换成更全的那份（人数 / 进入群聊）」。

---

### S7.5 聊天底部栏跟聊天区「糊」在一起，加一条分割（2026-09-30）

用户：「另外聊天界面（私聊和群聊都一样），底部栏（语音、文字输入框、表情、加号）
跟聊天信息区域高一点颜色区别啊分割一下，现在完全是融合在一起的，我给你了微信的图片示例。」

照那张微信截图（聊天区 `#EDEDED`、输入条比它浅一档、两者之间一条极细的分隔线、
输入框是白的圆角框）量了色值：

* 聊天区保持不变 `AppColors.chatBackground = #EDEDED`（Scaffold 底色）；
* `features/chat/widgets/chat_input.dart` 里那层根 `Container`：底色从
  `chatBackground` 换成 `AppColors.tabBar = #F7F7F7`（比聊天区浅一档，正是微信那个观感），
  并加上 `border: Border(top: BorderSide(color: AppColors.navDivider #DCDCDC, width: 0.5))`
  —— 就是截图里那条发丝线；
* 文本输入框本来就是白的，不动。

顺手给这层根 `Container` 挂了 `key: ValueKey('chatInputBar')`，好让用例能精确拿到它：
`test/features/chat_page_test.dart` 新增「输入区与聊天区分得开：底色比聊天区浅一档 + 顶上一条细线」，
读出那层 `BoxDecoration`，断言 `color != Scaffold.backgroundColor`、
`color.computeLuminance() > 聊天区的`、`border.top.width > 0` —— 只要以后有人
typo 把底色改回去，这条就红。私聊/群聊共用同一个 `ChatInput`，两处一起生效。

---

S7.4 + S7.5 这次的验证：`flutter analyze` 干净；`dart format` 后
全量 `flutter test` **1895 通过**（上一版 1889，新增 6 条：扫码 3 + 入群页 2 + 底部栏 1）。
`--build-number 2105` 的包已打好（手机还是没插，插上就装，重点验两件事：
①未入群的号扫群码 → 群资料页正常显示且点得动「加入群聊」；②私聊/群聊底部栏看得出是单独一条）。

---

### S7.6 整体体检：提示的位置不像微信、同一句还会弹两遍（2026-09-30）

用户：「你再整体看一下 flutter 客户端，有没有地方的 UI 还不统一不像微信的，
还有没有细节 bug，检查更新等等小接口这些都处理好了吗？再整体检查一下」

先把「像不像微信 / 有没有漏」逐条扫了一遍（结构一致性的部分结论在下表），
挑出两处**确定要改**的，都在提示这一条线上。

| 项 | 现状 | 处理 |
|---|---|---|
| 全局提示**位置** | 走 Material 的 `SnackBar`（贴屏幕**底边**、Material 自己的圆角），而「提交成功」那种是**正中**的盒子 —— 一个 App 两种提示位置 | **改**：统一成微信那种居中深色圆角浮层 |
| 同一句提示**弹两遍** | `ApiClient` 默认 `notify: true` 先弹一次，页面 catch 到 `ApiException` 再弹一次 `error.message`（34 处页面都是这么写的）→ 两条 `SnackBar` 前后脚各播一遍 | **改**：同一句还在屏幕上就不弹第二遍 |
| 提示盒子的颜色 | `success_check` 里硬编码 `0xE6333333`，跟新提示会是两套 | **改**：抽到 `AppColors.toastBackground` / `toastText`，两边共用 |
| 列表头下面那条线 | `group_list_page` / `new_friends_page` 硬编码 `Color(0xFFEFEFEF)`，别处都是 `AppColors.line`（`#EEEEEE`） | **改**：统一成 `AppColors.line` |
| 转圈的颜色 | 大多数跟主题（`brand` 蓝），灵听那 5 页显式 `wechatGreen` | 没动（灵听是另一套账号体系的子频道，刻意留自己的主色） |
| 顶栏 / 列表 / 弹窗骨架 | 36 处 `AppBar` 全部走主题（灰底 + 居中 17dp + 一条底线），只有「关于」「我的二维码」「用户详情」故意白底无底线（对得上微信那几页） | 没动，本来就是齐的 |
| 尺寸单位 | 除底部 tab 栏与占位页以外，全站走 `context.rpx`（抽查 `fontSize` / `SizedBox` / `EdgeInsets` 无游离数字） | 没动 |
| `AppRoutes.videoPlay` | 常量还在，但没有对应的 `GoRoute`、也没人 push（视频是 `VideoPreviewPage` 直接 push） | 没动（无害的遗留常量；删了反而以后接老端深链要重加） |
| 检查更新 | 入口齐：启动时静默查一次 + 我的 › 关于 › 版本更新 + 设置页右边那个版本号；`.wgt`（跳过后说明）/ `.html`（丢浏览器）/ APK（下载 + 交系统安装器）三条分流都在，失败提示也分「手动点才说话」 | 已处理，无改动 |
| 路由里的占位页 | 只剩**朋友圈**一个（老端那页自己写着「静态模板」） | 仍不做 |
| 系统通知条（`getAdminNotice`） | 接口方法在 `ChatApi` 里躺着，页面没做（S4.1 遗留 #1：它依赖推送/保活那套开关） | 仍是遗留 |

**改法**

* 新文件 `core/ui/wechat_toast.dart`：`WeChatToastLayer` —— 一块挂在**根 Navigator 的 Overlay**
  上的浮层（`routerDelegate.navigatorKey.currentState.overlay`），“屏幕正中 + 深色圆角 + 白字 + 自己淡入淡出”，
  不拦点击、不进导航栈、换页也不跟着消失（原来 `SnackBar` 那些行为它都保留）；
  带按钮的那种提示（「去授权」）在盒子底下挂一颗白字按钮，跟原来一样留 6 秒；
* 三个微信才有的行为：①**同一句还在屏幕上时不弹第二遍**（这就是重复提示的解法）；
  ②后来的**直接顶掉**前一条（微信不排队等前一条播完）；③浮层不吃点击（`Positioned.fill` 里只有一个居中的盒子，
  外面那圈是空的）；
* `core/ui/notice_handler.dart`：不再 `showSnackBar`，改写「往浮层里弹」。
  `appMessengerKey` 留着（页面自己那种贴底的 `SnackBar` 还在用：通话诊断面板「导出日志 + 打开」那一条），注释里写清了它现在的职责；
* `AppColors` 新增 `toastBackground`（`0xE6333333`）/ `toastText`，`success_check` 也换成它（两边一套颜色）。

**用例**

* `test/core/wechat_toast_test.dart`（新）5 条：位置在屏幕正中（`getCenter` ≈ 400/300）+ 深色圆角白字、
  同一句不弹第二遍、换一句顶掉前一条且到点自己收掉（`defaultDuration` + 淡出后 `findsNothing`）、
  带按钮的提示点了回调就走、铺满屏的那层不吃点击（底部的按钮照样点得到）；
* `test/features/notice_handler_test.dart`（新）1 条：**端到端复现那条重复提示** ——
  让假适配器对 `editGroupName` 回 400「服务器说改不了」，从聊天信息页真的去改群名，
  起真 `NoticeHandler`，断言屏幕上 `wechatToast` **只有一块**、文案就是服务端那句话。
  （改之前实测是 `TOASTS=[服务器说改不了, 服务器说改不了]` —— 两条 `SnackBar` 各播一遍。）

**这一轮的操作记一笔**：这个用例收尾必须先「卸载整棵树 + 推 1ms」（`disposeApp`），
而且**必须在用例体里做** —— 测试框架查「还有没有定时器在跑」是在用例体结束那一刻，
放 `addTearDown` 里已经晚了（就是 S4.1 那条「drift 关流留零时长定时器」的坑）。

**验证**：`flutter analyze` 干净；`dart format` 后全量 `flutter test` **1901 通过**
（上一版 1895，新增 6 条：提示浮层 5 + 宿主 1）。

---

### S12.1 灵听：分层加载 + 本机缓存（2026-09-30）

用户：「把灵听也做一下分层加载和缓存，不然每次要转圈圈大半天很不友好」。

**病根（对着代码一处一处数出来的）**

| 页面 | 老做法 | 要等几次往返 |
|---|---|---|
| 灵听首页 | 五个接口 `Future.wait` 到一起；「每日三十首」拿不到时**再串两次**兜底（新歌首发 → 纯音乐） | 最多 7 次（每次超时 12 秒） |
| 歌手页 | 资料 / 歌曲 / 专辑三个接口 `Future.wait` | 3 次 |
| 歌单页 | 详情；一首都没内嵌时再拉一页歌曲 | 2 次 |
| 搜索 | 单曲 / 歌手 / 歌单三个接口 `Future.wait` | 3 次 |

而且整页只有**一个**转圈：任何一块慢，前面已经拿到的东西也一个字都不画。
另一半问题是**没有缓存**：详情页那几个 provider 是 `autoDispose.family`，
退出再进来就重新拉一遍（所以是「每次」）。

**做法（四层，从上到下）**

1. **本机内容缓存**：`LingtingStore` 新增 `cacheRead/cacheTime/cacheWrite/cacheRemove/cacheClear`，
   根键 `lingting.cache`，每个区段存 `{"at": 写入毫秒, "v": JSON}`。存 JSON 而不是内存对象，
   就是为了**冷启动也秒出画**。坏数据一律当没有（不能把页面弄崩）。
2. **模型能转一圈**：`LingtingSong` / `LingtingBanner` / `LingtingSongSheet` / `LingtingSinger` /
   `LingtingAlbum` 加 `toJson`（字段名与各自的 `fromJson` 对齐），`LingtingHome` 加
   `toJson/fromJson/copyWith`（含「每日三十首是从置顶栏兜底来的」那个标记）。
3. **仓库层**：`cachedHome/saveHome`、`cachedSheet/saveSheet`、`cachedSinger/saveSinger`、
   `cachedSingerSongs|cachedSingerAlbums`（歌手那三块分三条键）、`cachedAlbum/saveAlbum`。
   **空的那一份不写**（省得下次进来拿一个空壳）。
4. **接口拆块**：`home()` 拆成 `homeBanners/homeDaily/homeHot/homeSheets/homeSingers`
   （`homeDaily` 回一个 `(songs, fromTop)` 记录）；搜索拆成
   `searchSongs/searchSingers/searchSheets`（`searchAll` 是「不怕等」的那条旧路）。

**provider 那一层改成「缓存先出画 + 逐块刷新」**（`lingting_providers.dart`）

* 新状态对象：`LingtingStaged<T>`（详情页用：`value` / `pending` / `failed`）与
  `LingtingHomeState`（首页用：一份 `LingtingHome` + `pending` 是**哪几块**还在路上）；
* `lingtingHomeProvider` 从 `AsyncNotifier` 改成普通 `Notifier` —— `AsyncNotifier` 只有
  「一次 loading → 一份 data」，而这一页要的是「一块一块长出来」；
* 首页五块各走各的：回来一块就并进 `home` 并落盘，单块失败只让那一块空着（老行为）；
* 歌单/歌手/专辑：缓存先摆上，网络回来再盖；歌手那三块也各拉各的（回来一块长一块）；
* 搜索页：三块各拉各的，**单曲一回来就能看能点**，歌手/歌单随后自己长出来，
  tab 上的条数跟着变（用户手动点过 tab 就不再被自动改）。

**页面那一层**

* 首页那块渲染规矩收成一个 `_section(...)`：**有内容画内容**（下拉刷新时照画，不闪骨架）
  → 没内容但在等就画骨架（`lingtingHomeSkeleton.<区块>`）→ 没内容也不在等就不画；
* 详情页新增 `widgets/lingting_skeleton.dart`：骨架 + `LingtingRetryView`（一句说明 + 重试）；
* **骨架刻意不做闪烁动画**：一闪一闪的动画会把组件测试里的 `pumpAndSettle` 挂死。

**顺手修掉的一个坑（值得记下来）**

`Notifier.build()` 是**同步**执行的：里面 `ref.read(lingtingRepositoryProvider)` 一旦抛异常，
provider 直接进 error 态、**整棵树报错白屏**（原来 `AsyncNotifier` 是同步执行的 `Future`，
异常变成 `AsyncError`，页面画的是「加载失败 + 重试」）。测试里 `LingtingStore` 没初始化，
`compass_page_test` 那条「点灵听进首页」就撞上了这个。所以新加了一个
`lingtingRepositoryOrNull(ref)`：拿不到仓库就当「加载失败」，不抛给组件树。

**用例**（新增 16 条）

* `test/lingting/lingting_cache_test.dart`（新）11 条：五个模型转一圈不丢字段、首页整份
  （含 `dailyFromTop`）、解析不出来当作没缓存；`LingtingStore` 缓存读写/覆盖/清空/坏 JSON；
  仓库层首页与四类详情各存各的、空的那份不存、坏缓存不崩；
* `test/features/lingting_pages_test.dart` +5 条：①首页「慢的那一块不挡别的」——把每日三十首
  用闸门挂住，断言那一块是骨架、标题一个字没画，而它后面的热门歌曲照画，放行后骨架换内容；
  ②「第二次进来先用本机存着的那份出画，一块都没回来也不转圈」；③歌单页缓存先出画；
  ④歌手页三块各拉各的（资料先到就先把名字与粉丝数画出来）；⑤搜索三块各拉各的
  （单曲先出结果、歌手/歌单的 tab 随后才出现）。

**验证**：`flutter analyze` 干净；`dart format` 后全量 `flutter test` **1917 通过**
（上一版 1901，新增 16 条）；`--build-number 2107` 的包已打好。

**下一个同类候选（记下来）**：资讯那 12 个源还是 `Future.wait` 一次拿完
（`news_repository.fetch`）—— 首次进页面且本机没缓存时要等最慢的那个源（12 秒超时）。
缓存那条已经有了（页面同步读 `cachedArticles()` 先画），差的是「按源流式合并」。

---

### S12.2 资讯：12 个源按源流式铺（2026-09-30）

用户：「把资讯那 12 个源也改成分层加载：哪个源先回来先铺哪几条，不再等最慢的那个，
同时保留本机缓存先出画」。（就是 S12.1 结尾自己记下的那条候选。）

**病根**

| 老做法 | 结果 |
|---|---|
| `NewsRepository.fetch()` = `Future.wait(kNewsFeeds.map(_fetchFeed))` | 12 个源**全回来**才有一份数据 |
| 每个源独立超时 12 秒 | 最慢的那个（挂掉的源就是 12 秒）把整页按在转圈上，而它前面的 11 个早就拿到了 |
| 页面只有「一次 loading → 一份 data」（`build()` 里 `await fetch()`） | 前面拿到的那些**一个字也不画** |

缓存那条本来就有（页面同步读 `cachedArticles()` 先画），所以这一轮差的只是「按源流式合并」。

**做法（从上到下）**

1. **仓库改成吐流**：`fetch()` 保留但变成 `fetchStream().last`（老调用点一个字不用改）；
   新 `fetchStream()` 每回来一个源就吐一份「到目前为止的合并结果」。合并规则**一个字没动**
   （`_merge` 还是按源轮转 + 截断 + 稳定排序），所以先铺出去的那几条不会被后面的源挤走位置，
   也不会重复。
2. **空手回来的源不吐帧**：超时/拦截页（解析出 0 条）没有让内容变多，吐出去只是一份一模一样的
   片 —— 12 个源里 10 个超时的话，那十次失败会各吐一次同样的一帧。（第一版没做这一步，
   新用例当场逮住了：`expect(frames, hasLength(1))` 实际 11。）
3. **还没回答的源先拿缓存顶着**（`_frame`）：不加这条的话，第一帧到达时页面会从
   「缓存里的 100 多条」突然缩成「刚回来的那个源的 3 条」，看着像内容被删了。判据是
   「这个源这一轮**有没有拿新内容回答**」—— 所以某源今天挂了（超时/拦截页）时，
   它上一份那几条继续留着，不会突然空一块。
4. **落盘只有最后一份，而且只写这一轮真拉到的**：中间帧不写盘，缓存顶上来的那几行也不写回，
   所以磁盘上永远是一份完整快照（旧内容不会一轮一轮地续命）。
5. **已读状态每帧都贴**（`_withReadState`）：不贴的话，流一路过列表里的小圆点会闪一下没了、
   最后那帧才回来。

**控制器（`newsListController`）改成「一块一块出画」**

* `build` 只等**第一块**（`_first` 这个 completer）—— 第一块到手就返回，页面从转圈变成内容；
  剩下的源回来一块就 `state = AsyncData(...)` 补一块。`build` 返回的是 `_latest`
  （手上最新那份），所以就算某一块抢在它返回前到了也不会丢；
* `refresh`（自动刷新 / 失败重试）等的是**整轮**（`_subscribe` 给出的 round future）：
  每一块立刻画，`updating`（顶上那条「正在更新…」）全程亮着，流关上时收掉；
* 新加 `_pulling`：「正在抓」不再等于 `state.isLoading`（第一块一到就不 loading 了，但剩下的源
  还在跑）—— `refreshIfStale` 靠它不叠第二轮，免得把还没回来的源掐掉从头再拉；
* 页面上只多了一处：**缓存先画的那一段也把「正在更新…」亮上**
  （`updating: async.isLoading`；已经抓挂了就不再顶这句）。

**用例（新增 9 条）**

* `test/news/news_repository_test.dart` +4（新 `group('一块一块地吐')`，走真仓库 + 假 adapter，
  用 `Completer` 把某个源卡在 `adapter.handler` 里）：①慢的还挂着、快的已经吐了一帧
  （且「还在路上的源不算失败」）；②中间那几帧**不落盘**（第一帧时 `cachedAt()` 还是 0，
  整轮跑完才写）；③还没回来的源拿缓存顶位（第一帧 `['新的 IT','旧的派']`，已经用新内容
  回答过的源那行不顶）；④已读的小圆点在每一帧上都在。
* `test/news/news_providers_test.dart` +3：①首屏不等最慢的那个（闸门卡住第二块 → 第一块到手
  就有内容、`updating` 亮着，放行后补上并收圈）；②刷新也是分层的（`await refresh()` 完
  才是整轮完了）；③抓一半时 `refreshIfStale` 不会把这一轮掐掉重来。
* `test/features/news_pages_test.dart` +2：①慢的还挂着、先回来的那条已经画出来（这条要用
  `settle: false` + 手动 `pump` —— 抓取还没完时顶上转着圈，`pumpAndSettle` 会一直等下去）；
  ②第一块还没回来时先画本机缓存。
* 假仓库 `test/support/fake_news.dart`：把 `fetch()` 换成 `fetchStream()`（真仓库那条路的收口
  就是 `fetchStream().last`），新增 `batches`（一次分几块吐）+ `gates/open(i)`（卡住某一块）+ `fetchDelay`。

**顺手记一笔（Riverpod 3 的默认重试）**：provider 抛错会自动重试 **10 次**（200ms 起步、
翻倍、封顶 6.4s），所以「所有源都挂 + 本机没缓存」那条用例里会连着看到 11 行
`[资讯] 抓取失败` —— 这是框架自带行为（老代码也一样，只是那时没打日志），不是这一轮加的。
好处是断网时它自己会在十几秒内再试几轮，页面上的「加载失败 + 重试」不用等人点。

**验证**：`flutter analyze` 干净；`dart format` 后全量 `flutter test` **1926 通过**
（上一版 1917，新增 9 条）；`--build-number 2108` 的包已打好（76.4MB）。

**仍然没验到的**：没插手机（`adb devices` 是空的），S7.4 / S7.5 / S7.6 / S12.1 / S12.2 都只有
单测 + 组件测试背书，真机上没点过。装上之后值得盯的：①冷启动进资讯，缓存立刻出画、
第一块大概 0.3~1.5 秒内补上来；②断网时列表停在缓存那份、不闪白屏；③十分钟内不动它，
自动刷新那条路（半小时一次）不会把已经展开的「余下N篇」缩回去。

---

### S12.3 资讯首屏：转圈换骨架屏 + 失败态换同款重试视图（2026-09-30）

用户：「把资讯列表首屏那个转圈换成不闪的骨架屏（照灵听那套 `LingtingDetailSkeleton`
的做法），顺便给失败态也换成同款重试视图」。

**病根**

| 老做法 | 结果 |
|---|---|
| 首屏（没缓存 + 第一块还没到）画一个居中的 `CircularProgressIndicator` | 说不出「马上会有什么」，内容一到整页版式跳一下；和灵听那边的做法也不一致 |
| 失败态是页面私有的 `_Failed`（`OutlinedButton`） | 和灵听的 `LingtingRetryView`（`TextButton`、`text999`、28rpx）不是同一个东西，同一件事两处两个样 |

**做法（从上到下）**

1. **重试视图提到 `lib/core/ui/retry_view.dart`（`RetryView`）**：原来它长在灵听里
   （`LingtingRetryView`），资讯也要用了才提出来 —— 两边**用的是同一个组件**，不是各抄一份。
   顺手加了左右留白与居中（资讯那句接口文案比「加载失败」长），对灵听原样没影响。
2. **灵听三页（歌单 / 歌手 / 专辑）改用 `RetryView`**，`lingting_skeleton.dart` 里的
   `LingtingRetryView` 删掉（骨架留在原处，它是灵听详情自己的版式）。
3. **新增 `lib/features/news/widgets/news_skeleton.dart`（`NewsListSkeleton`）**：灰块版式
   照着 `NewsSourceCard` 摆 —— 卡头（圆头像 64 + 号名 + 右上角相对时间）、16:9 的大封面、
   两条「左标题 + 右缩略图」小行（行间同样一条细线）。默认两张卡，正好铺满一屏。
4. **骨架不做闪烁动画**（和灵听同一条硬规矩）：闪一下会把组件测试里的 `pumpAndSettle` 挂死，
   而这一屏要传达的只有「在路上」这一个信息。
5. **`news_list_page.dart` 首屏分支改成**
   `state == null ? (async.isLoading ? NewsListSkeleton() : RetryView(...))`，页面私有的
   `_Failed` 删掉。规矩一个字没变：**有缓存先画缓存**（不摆骨架），只有「连缓存都没有 +
   第一块还没到」才轮到它。

**一个必须记下来的副作用（Riverpod 3 自带重试）**

骨架是**静态**的，所以「所有源都挂 + 没缓存」时 `pumpAndSettle` 会立刻返回 —— 停在
「Riverpod 还在自己重试」那一步（状态是 `AsyncLoading(error: …, retrying)`，`isLoading`
仍为 true → 页面画骨架）。以前那颗转圈一直在动，`pumpAndSettle` 会被它拖着把 10 次重试
全跑完才返回（S12.2 记下的那 11 行 `[资讯] 抓取失败` 就是这么来的）。所以失败那条用例
现在要自己把时间快进 60 秒（整串重试加起来 ~38s），重试耗完、状态落到 `AsyncError`，
才轮到「加载失败 + 重试」。**用户看到的时序没变**：断网时先停在「还在忙」的观感上，
重试都失败之后才给失败态（失败态本身反而比以前多了一条自己救回来的路 —— 点重试
走的是 `refresh()`，不经过框架重试）。

**用例（+3，共 1929）**

* `test/features/news_pages_test.dart` 新增「第一块还没回来且没缓存：首屏摆骨架屏（不是转圈），
  内容到了原地换上」：闸门卡住第一块 → 断言 `NewsListSkeleton` 在、`CircularProgressIndicator`
  一个都没有（首屏不再有这个圈）、`pumpAndSettle` 能正常返回（静态骨架挂不住测试）→
  放行后骨架消失、内容出来。
* 同一文件另两处补断言：失败态是 `RetryView`、重试成功后它消失；「先画本机缓存」那条
  顺带断言**不摆骨架**（有缓存就不该有骨架）。
* 老的失败用例改成先把时间快进过整串重试（原因见上）。
* 窄屏各钉一条：`news_pages_test` 的「窄屏（320dp）下骨架屏不溢出」在 960×1707
  （= 320dp 宽，老手机的宽度）下验两张灰卡铺得下；`lingting_pages_test` 同一条给
  `LingtingDetailSkeleton`（歌单 id 5 + `sheetDetail` 挂住，本机没缓存 → 停在骨架上）。
  骨架屏是溢出就报错的组件测试，所以「跑完了 + 骨架在 + 转圈不在」本身就是结果。

**验证**：`flutter analyze` 干净；`dart format` 后全量 `flutter test` **1929 通过**
（上一版 1926，新增 3 条）；后两条只动用例、`lib` 没动，所以 `--build-number 2109`
那个包（76.4MB）仍然就是这一版代码。

**仍然没验到的**：还是没插手机（`adb devices` 是空的）。装上之后值得盯的：
①冷启动进资讯（本机没缓存）先摆一屏号卡灰块，第一块到手原位换内容、版式不跳；
②断网时先停在骨架、十几秒后落到「加载失败 + 重试」，点它能拉回来；
③灵听歌单 / 歌手 / 专辑的失败态与资讯长得一模一样了（同一个 `RetryView`）。

---

### S12.4 整体清点：把没人用的东西挑出去（2026-09-30）

用户：「再整体检查一下整个软件有没有没用的东西可以删掉了」。

**怎么扫的**（没有 git 仓库可用，全部靠引用计数）

写了个临时 node 脚本，按五条维度扫全仓（`lib` + `test`，资源另算）：

1. **文件级**：每个 `.dart` 的 basename 有没有作为 import/export/part 的引号路径出现在别的文件；
2. **顶层定义**：class/enum/mixin/typedef、顶层 final/const、顶层函数 —— 「本文件外引用数」
   与「本文件内引用数（去掉声明行本身）」**都是 0** 才算死；
3. **类内 static const**：同上（这条把 `AppRoutes` / `AppColors` / `AppDimens` 那些常量都过了一遍）；
4. **资源**：每个 `assets/**` 文件名/路径在代码里出现没；（注意 `home_shell.dart` 是
   `'assets/icons/navbar/$name.svg'` 拼的，所以 navbar 那 8 个 SVG 是误报）；
5. **语言包**：671 个 key 逐个查有没有作为字面量（`'key'`）出现在 lib 或 test；
   另外单独确认了**没有** `${}` 拼 key、没有字符串拼接 key 的写法 —— 和已有的
   `test/core/i18n_keys_test.dart` 同一套口径（那份测的是「用到的 key 都存在」，
   这次反过来：「存在的 key 都有人用」）。

**挑出去的东西**（先整体挪进 `_trash/`，目录里镜像原路径、配一份 `README.txt` 写理由；
清完静态检查与全量测试都绿，用户复核后 **`_trash/` 已整体删除** —— 这批文件在仓库里
不再有副本，包括语言包改动前的原件。要恢复只能从交付物/老端仓库找）

| 类 | 东西 | 证据 |
|---|---|---|
| 代码 | `lib/core/theme/app_icons.dart` | 无人 import；`IconFont.`/`CustomIcons.` 零引用；全仓再无第二处 `fontFamily:`（1849 行那句「iconfont 仍被聊天页用着」已过时） |
| 代码 | `clearedChatsProvider` | 只有声明；实际走 `ClearedChatsStore.instance` |
| 代码 | `resetStartupUpdateCheck()` | 定义了没人调 |
| 代码 | `AppColors.iconRed`/`iconSky`、`AppDimens.pagePaddingRpx`/`radiusLarge` | 四个常量零引用 |
| 依赖 | `intl` | 没有任何直接用法（`flutter_localizations` 自己依赖 intl 0.20.2） |
| 资源 | `iconfont.ttf` + `customicons.ttf`(共 13KB) + pubspec 两段 fonts 声明 | 只有 app_icons.dart 用 |
| 资源 | `call_wallpaper.png`(62.8KB)、`group.png`、`invite.png`(共 83.7KB) | 通话页改渐变、入口图改画法，代码里零引用 |
| 文案 | 语言包 **64 个 key**（zh/en 各删 64 行，671 → 607/608） | lib 和 test 都不引用，且不是动态拼的；`common.home/chat/contact`、`network.noNetwork/serverError`、`system.keepTitle` 这类老端遗物 |
| 杂物 | 27 个 `flutter_*.log` + `.tmp_wx_time.png` + `app_smoke_tmp.png.html` + `gracelinkim.iml` + `REFACTO_PLAN.md`（手滑文件名） | 开发期垃圾；`.gitignore` 里 `*.log`/`*.iml` 本来就忽略 |
| 杂物 | 9 个服务端补丁目录（741KB）：`push_fix2/3`、`push_hotfix`、`*_server` | 服务端手递包，不是客户端代码 |

**故意没动的**（扫出来像死的，其实不是）

* navbar 8 个 SVG —— `home_shell.dart` 用 `'assets/icons/navbar/$name.svg'` 拼的；
* `assets/images/logo.png`(549KB) 与 `lingting_logo.png`（都在用；549KB 那个想瘦身是另一件事）；
* `AppRoutes.videoPlay` —— S7.6 体检就记过：留着，删了以后接老端深链要重加；
* `cupertino_icons` —— 没人直接 import，但 `call_page.dart` 用了
  `CupertinoIcons.switch_camera_solid`，字体资源就是它提供的（APK 里那个 1072 字节的
  CupertinoIcons.ttf），删不得；
* `docs/`、`tool/ws_probe.dart`、`integration_test/` + `test_driver/integration_test.dart`
  （call_pip 那套的跑法明确要用 driver）；
* `web/`/`windows/`/`macos/`/`ios/` 平台壳（只在 Android 出包，但删了以后
  桌面/网页调试要重新生成）。

**验证**：`flutter analyze` 干净；全量 `flutter test` **1929 通过**（一条用例没动）；
`--build-number 2110` 的包已打好（76.3MB，比上一版小 0.1MB —— 两个死字体不再进包）。
删前又做了一遍**双向确认**：① 挪走的名字（`IconFont`/`CustomIcons`/两套字体族/
四个常量/被删 provider 与函数/三张图）在 `lib`+`test`+`pubspec`+`android` 里只剩
两处**历史注释**提了一句 iconfont（顺手把那句改成现在的写法）；② 删掉的 64 个 key
在 `lib`+`test` 里连子串都搜不到（唯一命中是 `user.email` 这种模型字段、
`user.emailOrPhone`/`chat.messageRecord` 这种更长 key 的前缀，都是误报）。

**附：音乐推送补丁（可选，服务端）**（原 `REFACTO_PLAN.md` 的内容，已并进来）

* 客户端把整条消息 payload 交给自己拼文案，所以新消息类型 lingting 的通知本来就显示 [音乐]；
  服务端 `getMsgType()` 的 case 只在 payload 超 4KB 被丢掉时才看得出来 —— 故补丁可不传。

---

### S12.5 清理收尾：探针脚本挪出 `build/`、补丁包与截图证据清掉（2026-09-30）

用户：「乱七八糟没用的，包括服务端补丁 zip 等等都清理干净」。

* **服务端补丁包**：删 `build/server-patch/` —— 9 个 `gracelinkim-server-patch-*.zip`
  （sfu / turn / group-live1~6 / group-ring）加两个解包目录。源码目录在 S12.4 已经清了，
  这批是同一套交付物的打包版。
* **测试缓存**：删 `build/test_cache/`（**71MB**，`flutter test` 的 kernel 缓存，下次跑自动重建）。
* **探针与体检脚本挪出 `build/`**：`build/probe/`（前面几节验收时做的 `crop_png.js` /
  `make_launch_logo.js` / `frame_scan.js` / `icon_*` …）与 `build/audit/`（整体体检那几个脚本）
  共 31 + 12 个文件，原样挪到 **`tool/probe/`**、**`tool/audit/`**（共 1.4MB）。
  它们本来是手写东西，却躺在 gitignore 的 `build/` 里 —— 跑一次 `flutter clean` 就全没了，
  现在稳了。上面历史章节里写的 `build/probe/xxx.js` 对应的就是 `tool/probe/xxx.js`
  （脚本内部的输出路径还写 `build/probe/...`，跑的时候会在 build/ 下重新长出来，不影响用）。
* **截图/抽帧证据清掉**：`build/probe/` 剩下的 85MB（png/html 对、`frames/`、`frames2/`）
  与 `build/audit` 一起删了 —— 结论都已经写在本计划里，图留着只是占地方。
* **模板残留**：删 `android/app/src/main/res/drawable/launch_background.xml`（Android 模板默认文件；
  minSdk ≥ 21，永远走 `drawable-v21` 那份，`@drawable/launch_background` 由它提供）。
  引用同步改成新路径：`drawable-v21/launch_background.xml`、`values-v31/styles.xml`、
  `test/core/launch_resources_test.dart` 里的 `tool/probe/make_launch_logo.js`。

**验证**：`flutter analyze` 干净；全量 `flutter test` **1929 通过**；
`--build-number 2111` 出包成功（76.3MB）—— 也顺带验了删掉那份模板 drawable 后 AAPT2 照样链得上。

---

### S12.6 正式签名：release 包不再用 debug 钥匙（2026-09-30）

用户：「把正式的 release 包证书配置起来（我们还没配置过吧？）要哪些信息啊」。

* **改之前**：`android/app/build.gradle.kts` 还是模板默认 —— release 也签
  `signingConfigs.getByName("debug")`，即 `~/.android/debug.keystore`
  （每台机器一份、丢了就发不出能覆盖安装的包，商店也拒收 debug 签名的包）。
* **生成的证书**：`android/app/gracelink-release.keystore`
  （PKCS12 / RSA 4096 / SHA384withRSA / 有效期 30 年（10950 天）/ 别名 `gracelink` /
  DN `CN=Gracelink, O=Gracelink, C=US`）；口令（store 与 key 同一个 28 位随机串）
  写在 `android/key.properties`。两个文件都加进了根 `.gitignore`
  （`android/key.properties`、`*.jks`、`*.keystore`）。
* **配置**：`build.gradle.kts` 读 `android/key.properties` 建 `signingConfigs.release`；
  **拿不到该文件时退回 debug 签名**（新机器 clone 下来不会在配置阶段就崩）。
* **验证**：`--build-number 2112` 出包后用 `apksigner verify --print-certs` 核对 ——
  `certificate DN: CN=Gracelink, O=Gracelink, C=US`，
  SHA-256 `7e8360f1a9ae4988fe92b045d03b503123a9a8ab25369029909a924458fec6a5`
  （= keystore 自己的指纹），不再是 debug 证书。
* **三点提醒**：① keystore + `key.properties` **必须离线备份**（密码管理器 / 网盘），
  丢了就永远无法给 `cc.gracelink.im` 发新版本 —— 直发 APK 没有商店那种恢复兼底；
  ② 换签名后手机上已装的旧包要**卸载重装**（本机缓存与登录态会清）；
  ③ 以后若用 Firebase 的登录 / App Check，把新证书的 SHA-1
  （`71542b126f3c59406bf8a0e323a306903e87dfc2`）登记进控制台（只用 FCM 推送则不需要）。

---

### S12.7 记一个构建坑：程序包 `dev.flutter.plugins.integration_test` 不存在（2026-09-30）

用户在 PowerShell 里跑 `flutter build apk --release`（**不带任何参数**）时报：

```
GeneratedPluginRegistrant.java:74: 错误: 程序包 dev.flutter.plugins.integration_test 不存在
```

* **现象**：那一次生成的插件注册表里有 23 个插件（**含 `integration_test`**）；重跑同一条
  命令后注册表变成 22 个（**不含它**），构建直接过。成因：`integration_test` 是测试用的
  dev 依赖，release 包里没有它的代码 —— 工具在「刚重新解析完依赖」那一次把它也算进了
  注册表，Java 编译就找不到包（与签名、业务代码无关）。
* **处理**：**再跑一次**即可（必要时 `flutter clean` 后再跑）。
* 同时记下那条命令的两个坑：
  * 不带 `--target-platform android-arm64` → 三种 CPU 架构全打，包从 76.3MB 涨到 **122.7MB**；
  * 不带 `--build-number NNNN` → versionCode 取 `pubspec.yaml` 的 `1.0.0+1` = **1**，
    比手机上已装的（2112）小，系统按降级**拒绝安装**。
* **正式出包命令**（一直用这个）：
  `flutter build apk --release --target-platform android-arm64 --build-number NNNN`，
  出完用 `apksigner verify --print-certs` 核对证书 DN 是 `CN=Gracelink`。
* **验证**：按正式命令重打 `--build-number 2113`（76.3MB），`apksigner` 显示
  DN `CN=Gracelink, O=Gracelink, C=US`、SHA-256 `7e8360f1…c6a5`，签名正确。

### S12.8 用户报的四件事：撤回、一直「连接中」、两条黄色下划线、红横幅（2026-09-30）

用户当天一口气报的四个现象，逐个查根因 —— **都在客户端，服务端一行没动**。

**① 撤回消息：界面变「你撤回了一条消息」，随后弹「服务器繁忙」，对方那边其实没撤**

两层原因：

1. **请求里少了服务端要的 `id`**。旧代码拼的是 `{'id': ?serverId, 'msg_id': ?msgId}`；
   `serverId` 来自服务端 JSON 的 `id`（`Message.fromServerJson` 只认数字），而**刚发出去
   那条**的回执是把本机 uuid 原样放在 `id` 里（老端的写法，新端存进 `clientId`）——
   于是这个 `id` 是空的，只发了个 `msg_id`。`Im.php::undo()` 取的是 `$param['id']`，
   取不到 → PHP notice → ThinkPHP 抛 ErrorException → **HTTP 500** → 客户端那句
   「服务器繁忙，请稍后再试」（`ServerException` 只在 HTTP 5xx 时出现；业务码那条会说
   「请求失败（code）」）。同一个坑 `setMsgIsRead` 那边早记过（少了 `messages` 也 500）。
2. **本地是「先标再发」**。老端 `undoMsg()` 是在 `.then` 里才 `updateMessage` 的，
   新端反着来 —— 请求失败时界面已经写着「你撤回了一条消息」了。

改了什么（`lib/data/repo/message_repository.dart`）：

* 新增 `_identityOf()`：`id` 取 `serverId ?? clientId`（服务端给数字用数字、给 uuid 用 uuid），
  `msg_id` 一起带上；两个都没有就干脆不发（记日志）；
* `undo()` 改成**先调接口、成功了才 `patchMessage(isUndo: 1)`**，失败不动本地、返回 false，
  提示交给接口层（`undoMessage` 没关 notify）；
* `delete()` 用同一套 id 拼法 —— 它此前有一模一样的毛病，只是还没被报过。

**没验到的**：没有真机、也不该拿生产接口乱试，所以「服务端认哪个 id」这一步是按老端行为
（`undoMessage({id: message.id})`）与仓库里既有的 `clientId` 归一化（`fromServerJson` 的注释）
推断的；真机上要再撤一条确认。

**② 装好包一进消息页，顶上一直「连接中…」，点右边那颗刷新才消失**

* **根因**：`WsService.statusChanges` 只是把 `_statusController` 那个**广播流**透出去，不会重放；
  而 `main()` 里 `bootstrap()` 在 `runApp` **之前**就把 WS 连上了 —— 会话页建的时候
  `connecting` / `connected` 两帧早发完了，`StreamProvider` 就永远停在 `AsyncLoading`，
  那条「连接中…」一直挂着，直到下一次状态变化（点刷新就是造一次状态变化）。
* **改了什么**：`WsService.statusChanges` 改成 `async*`，**先吐当前这一帧**（`client.status`）
  再转发后续变化；会话页把 `idle` 也算「连接中」（不然补出来的第一帧是 `idle`，会先闪一条
  红色的「通信断开」）。
* 用例：`test/ws/ws_test.dart` 两条（连上之后才订阅要拿到 `connected`；之后的变化照旧转发）。

**③ 很多提示底下有两条黄色下划线**

* **根因**：那是 `MaterialApp` 给「**不在任何 Material 里**的 Text」准备的调试样式
  （`material/app.dart` 的 `_errorTextStyle`：红字 + 黄色 `TextDecorationStyle.double`）。
  全站的提示浮层（`WeChatToastLayer`）与录音浮层（`VoiceRecordOverlay`）都是**插在根
  Navigator 的 Overlay** 上的 —— 那一层祖先里没有 `Material`（Material 在页面里、
  在 Navigator 内部），于是里面的白字把颜色盖掉了，却把那份黄色的 `decoration` 继承了下来。
* **改了什么**：两处各包一层 `Material(type: MaterialType.transparency)`（提示里那颗
  `TextButton` 也顺带有了正经的 Material 祖先）。全仓 `OverlayEntry` 只有这两处。
* 用例：`test/core/wechat_toast_test.dart` 与 `test/features/chat_voice_test.dart` 各加一条
  「离文字最近的那层 Material 就是它自己包的」（共用新加的
  `test/support/widget_ancestors.dart`）。

**④ 消息页顶上「来电全屏显示未开启」那条红横幅**

* 用户原话：「首页顶部那条红色横幅删掉，通话提醒就在发起通话之前弹窗提示就好了啊」。
* **改了什么**：
  * `SystemHealthBanner` 只留「通知权限没开」那一条（`SystemHealthHint.fullScreen` 从枚举与
    `resolveSystemHealthHint` 里删掉，`SystemHealth.fullScreenIntentAllowed` 一并去掉）；
  * 换成拨号前的一次性白框：`core/ui/permission_gate.dart::remindFullScreenBeforeCall`
    —— 只在「没开启」时弹、**一台机器只弹一次**（`fullScreenCallHintShown`），
    「去授权」跳系统的全屏通知设置页；接在两处 1:1 通话入口上（聊天页那个面板 / 用户详情页）。
    群语音不弹（群邀请那条通知本来就不是全屏的）；
  * 设置里那一行（`features/call/full_screen_intent_row.dart`）照旧。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量 **1936 项通过**（1929 → 1936，净 +7：
ws +2、permission_gate +3、message_actions +2、toast +1，system_health 去掉一条、
banner / voice 两条在既有用例里改写）。**没有真机**（`adb devices` 仍是空的）——
①「服务端认哪个 id」与④的弹窗时机要真机再看一眼。


### S12.9 七种语言 + 打开软件跟随系统语言（2026-10-01）

用户原话：「请新增繁体中文、日语、西班牙语和法语、德语，全面适配哦别只适配一部分。
做仔细，另外要求打开软件根据实际系统语言来决定显示，如果没有符合的默认英语。」

拆成两件事：**语言从 2 种加到 7 种**（而且不能只加个名字、要全面 —— 每一页都要换掉），
以及**首次启动按系统语言挑一档**。

**① 名单与默认值**

* 7 档，顺序就是选择器里的顺序：`zh-Hans` / `zh-Hant` / `en` / `ja` / `es` / `fr` / `de`。
* 展示名一律用**该语言自己的写法**（微信、系统设置里都这么列）：`简体中文` / `繁體中文` /
  `English` / `日本語` / `Español` / `Français` / `Deutsch`。用当前语言去翻译别的语言名，
  切换之后那一列会跟着变，反而找不到自己要的那个。
* 默认口径（`LocaleController.build()`）：**手动选过就用手动的**（存本地，重启保持），
  **没选过就看系统**，系统那一堆语言一档都对不上（韩语、俄语、阿拉伯语…）→ **英语**。

**② 系统语言怎么映射**（`locale_controller.dart`）

* `systemLocaleCode([List<Locale>?])`：逐条 `codeOf`，取**第一条认得的**（系统给的列表是
  按用户偏好排序的，可能 `[ja, en_US]` 这样混着）；一条都不认得落 `fallbackLocale = 'en'`。
* `codeOf(Locale)`：中文分繁简 —— 脚本是 `Hant`、或地区是 `TW` / `HK` / `MO` 的算繁体，
  其余一律简体（安卓可能给 `zh_TW`，iOS 可能给 `zh-Hant` / `zh_Hant_TW`，都得认）；
  `en` / `ja` / `es` / `fr` / `de` 按语言码；其它返回 `null`。
* `flutterLocaleOf(code)`：中文必须带**脚本**（`Hans` / `Hant`）—— `GlobalMaterialLocalizations`
  认的是脚本而不是地区，只给 `Locale('zh')` 会落到「通用中文」那一档。这个 Locale 是给
  Material / Cupertino 自己那套本地化用的（日期选择器、长按菜单里的「复制/粘贴」…）。
* 老端 `LoggerController.defaultLocale`（恒为简中）删掉，改为只认「存的那份 ?? 系统那份」。

**③ 改到的位置**（全在客户端，服务端一行没动）

* `main.dart`：`await AppI18n.load(store.language ?? LocaleController.systemLocaleCode())`
  —— 第一帧出来之前就得定好语言，否则会闪一下英语。
* `app.dart`：`supportedLocales` 由 `options` 生成；`locale:` 用 `flutterLocaleOf`。
* `core/net/api_client.dart` 的 `accept-language`、`core/notify/push_background.dart` 的
  后台推送 isolate：同样「存的那份 ?? 系统那份」（那两个地方还没有 ProviderContainer，
  所以是静态方法）。后台 isolate 里引擎可能还没起、读不到设备语言 —— 那时落英语，
  只是弹一条通知，不影响什么（`_deviceLocales()` 里 try/catch 兜住）。
* `domain/mine/profile_form.dart` 的 `languageOptions()` 删掉（选择器只此一处真相：
  `LocaleController.options`），登录页右上角那颗药丸（`AuthLanguageChip`）与
  设置 › 界面与显示那一行都遍历它，加语言自动多出来，没有第二份名单要同步。

**④ 五份新语言包**（`assets/i18n/`）

* `zh-Hant` / `ja` / `es` / `fr` / `de` 各 **607 条**，与母本 `zh-Hans.json` 逐 key 对齐
  （`node -e` 拿 `Object.keys` 两轮比对，7 份全 `missing: [] extra: [] bad: []`）——
  没有空值、没有「原文照抄当翻译」。（`en.json` 是 608：多一条老端遗留的
  `common.SearchNone`，用例里白名单放行。）
* 繁体用台版用语（`設定` / `訊息` / `聯絡人` / `相簿`…），日语用です・ます + 体言止め的
  UI 用语，西/法/德用各自平台的惯用词（`Ajustes` / `Réglages` / `Einstellungen`、
  `Notificaciones` / `Notifications` / `Benachrichtigungen`）。品牌名 `user.appName` 与
  `lingting.title` 沿用 `Gracelink` / `Lingting`；媒体号源名（ITHome、sspai…）与英语一致。
* `de.json` 两处语法修过（`user.cancelBullet2` 的从句语序、`user.inputNaCode` 的介词短语）。

**⑤ 两处「拼出来的文案」必须跟着改，不然某些语言凑不成句**

* 群二维码有效期：老端是「有效期（7 天）」，其余部分是 `user.sevenLimit` 和 `group.qrExpire`
  **两段拼**的，中文读得通、日语/西语一处一截就读不通了。改成整句带占位符：
  `zh-Hans` / `zh-Hant`「（{date}前到期）」、`en`「 (expires {date})」、
  `ja`「（{date}まで有効）」、`es`「 (válido hasta el {date})」、
  `fr`「 (valable jusqu'au {date})」、`de`「 (gültig bis {date})」；
  `features/common/qrcode_page.dart::_hintText` 用 `t('group.qrExpire', {'date': …})` 拼。
* 时间格式：`core/util/time_format.dart` 的 `_wechatClock` / `hoursTimeFormat` 补了一个
  **24 小时制占位符 `{H}`**（补零的小时，不带「上午/下午」）—— 西/法/德看 12 小时制别扭，
  但它们的时间格式本身是「时:分」的样子，不能整段换掉。欧洲那几档用 `{H}:{mm}`，
  日期 `{d}.{m}.`（德）/ `{d}/{m}`（西、法）；中文与日语维持 `{ap}{h}:{mm}` 与中文日期。

**⑥ 又扫了一遍「还有哪里没走语言包」**

`i18n_keys_test` 扫的是**字面量** `t('…')`，所以「写死中文、连 key 都没有」的地方它一条都报不出来。
把 `Text('中文')` / `label:` / `title:` / toast / tooltip 这几类扫一遍，又揪出两处：

* **404 页**（`app_router.dart` 的 `errorBuilder`）：`页面不存在` + `未匹配的路径：…` 写死的。
  抽成了 `features/common/not_found_page.dart::RouteNotFoundPage`（跟 `placeholder_page.dart`
  一个路子），文案进语言包（`common.pageNotFound` / `common.routeUnmatched` 带 `{path}`）；
  抽出来的另一个好处是能用普通 widget 用例钉住它，不用为了验一句话去拉整棵树。
* **帮助中心正文**（`helpTopics`）：「如何开启手机通知」那两条，标题与段落以前是**写死的中文常量**
  —— 切到日语/西语整页还是中文。现在 `HelpTopic` 存的是 key（`titleKey` / `paragraphKeys`），
  正文进语言包（`help.notifyTitle` / `notifyP1`～`P6` / `certTitle` / `certP1`，7 份都有），
  `doc_page.dart` 渲染时翻。
* 扫下来只剩两类**故意**不走语言包的：`placeholder_page.dart`（占位页，上面那行写着
  「对应老端：pages/…」，是给改造时看的，只在「朋友圈」那条占位路由上用）与
  `call_setting_page.dart` 里 `kDebugMode` 才加的那行「前台服务自检（debug）」。

**⑦ 用例（1936 → 1949，净 +13）**

* 新增 `test/core/i18n_keys_test.dart`（4 条，7 档一起体检）：源码里出现的字面量 key 都在包里有；
  媒体号源名没被翻译掉；每份包与 `zh-Hans` **零缺零多**（只放行 en 那条遗留）；
  每一条都真翻过（不是把原文抄一遍）。
* 新增 `test/core/locale_controller_test.dart`（8 条）：繁简判定（`zh` / `zh_TW` / `zh-Hant` /
  `zh_Hant_TW`）、日西法德英、认不出的落英语、多 locale 取第一条认得的、`flutterLocaleOf`
  （中文带脚本）、7 项清单且每档 >500 条、展示名用本语言写法、「没选过 = 系统且落在名单内」
  与「选过就存下来」。
* `test/features/login_page_test.dart`：原来断言那颗药丸写死「简体中文」，现在按
  `labelOf(systemLocaleCode())` 算（用例宿主是 `[en_US, zh_CN]`，落 `en`）；另加一条
  「手动选过语言：药丸写的是存下来的那份（不跟系统）」。
* `test/features/mine_pages_test.dart` 的「切换语言」用例重写：先按当前值断言那一行，弹框里
  **7 个 label 一个不能少**，挑一个跟当前不同的点掉，再断言 state / 本地存的 / 界面文案都换了。
* 新增 `test/features/not_found_and_help_test.dart`（3 条）：404 页换一份包换一份字
  （中文 → 日语），帮助中心正文换一份包换一份字（中文 → 德语，第二条标题在视口外，
  要滚下去才断言得到 —— 德语比中文长）；再一条遍历 7 份包，钉住 `help.*` 与 `common.pageNotFound`
  都在、`common.routeUnmatched` 的 `{path}` 真的被替换掉了。
  `test/mine/profile_form_test.dart` 那条跟着改成断言 key。
* **踩到的坑（值得记）**：`setLocale` 里的两个 await（`rootBundle` 读语言包、
  SharedPreferences 存偏好）走的是真事件循环，`testWidgets` 的 fake-async **推不动** ——
  `pumpAndSettle` 只把动画走完，`tester.pump(20ms)` 转二十圈也没用（`localesTestValue`
  也改不到 `PlatformDispatcher.instance.locales`，测试里系统语言只能靠 `systemLocaleCode()`
  自己算一遍来对齐）。正解是 `await tester.runAsync(() async { …轮询到落地… })`，再
  `pumpAndSettle` 重建界面。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量 **1949 项通过**。
出包 `2116`（arm64，正式签名 SHA-256 同 2114，76.4MB，包内 `assets/i18n/` 7 份都在）；
`2115` 是先出的一版（那时帮助正文与 404 页还写死中文），已废弃不用。

**没验到的**：仍是**没有真机**（`adb devices` 空的）—— 系统语言跟随（在系统设置里改成日语、
韩语各看一眼）、七种语言下的界面文案与排版、以及 Material 自己那套（日期选择器、
长按菜单）是否跟着 `flutterLocaleOf` 走，都得真机再走一遍。


### S12.10 选择器里的「跟随系统」+ 系统语言变了马上跟（2026-10-01）

用户：「给语言选择器加一个『跟随系统』选项：选中后重新按系统语言显示，并且系统语言
变化时界面即时跟随（现在是选过就固定住，没有回到自动的入口）。」

**① 状态从「一个字符串」变成「快照」**（`locale_controller.dart`）

* 新增 `LocaleChoice{code, followsSystem}`：`code` 是**实际在用的那一档**（永远是具体语言，
  `MaterialApp.locale` 不认「跟随系统」这种值），`followsSystem` 是给选择器打勾用的。
  做成值对象而不是 `Notifier<String>` + 额外字段：语言没变、只是从「手动选了 English」
  换成「跟随系统」时，那个勾要移、界面得快 —— 两份信息得在同一个 state 里、
  相等实现好，Riverpod 才判得出该不该重建。
* **哨兵码 `systemCode = 'system'` 不放进 `options`**：那份名单是「有哪些语言」
  （`app.dart` 拿它生成 `MaterialApp.supportedLocales`、用例拿它验每档都有包），
  混进去会直接生成一个 `Locale('system')`。选择器用的是新加的 `pickerItems(i18n)`
  —— 最上面一条「跟随系统」+ 那 7 档，设置页的白框与登录页那个底部弹窗共用它。
* 「跟随系统」这一条的写法跟着**当前界面语言**走（日语下是「システムに従う」），
  语言那几档一律用各自的写法（`labelOf(choice, i18n)` / `languageLabelOf(code)`）。
* 切档：`setLocale(systemCode)` → `setSystem()`；`setSystem` 把本地存的那份**删掉**
  （`saveLanguage(null)`）并按系统语言重算。

**② 两个容易做错的地方（都有用例钉住）**

* `setLocale` 的提前返回不能只看语言码：跟随系统时 `state.code` 恰好就是系统那一档，
  这时点同一个语言**要**存下来（否则用户以为选定了、其实还在跟随）；反过来已经手动
  选过同一档就不该重复干活。条件写成 `!followsSystem && code == state.code`。
* `setSystem` 结束时必须换掉整个 state：系统语言正好等于当前那一档时语言码没变，
  但「跟随系统」这个勾要跟上、界面得重建。
* `syncWithSystem()`：只在跟随时动；系统换了语言但落到同一档（`en_GB` → `en_US`）不动。

**③ 系统语言一变就跟着换**

* `app.dart` 从 `ConsumerWidget` 改成 `ConsumerStatefulWidget` + `WidgetsBindingObserver`：
  `didChangeLocales` 里 `unawaited(syncWithSystem())`（安卓在「设置 → 语言」里一改就发这条）；
  手动选过的那份不动 —— 用户自己定的不能被系统改掉。换包是异步的，这里不能等，
  换好之后 `localeProvider` 会通知界面重建。
* `_deviceLocales()` 改成先读 `WidgetsBinding.instance.platformDispatcher.locales`
  （**同一个引擎**，但测试能替换：`tester.platformDispatcher.localesTestValue`），
  没有 binding 时（后台推送 isolate）退回 `PlatformDispatcher.instance`。
  不改这一步的话，「系统语言变了」这条**根本验不了**（实测 `localesTestValue`
  改不到 `PlatformDispatcher.instance.locales`）。
* 语言包 +7 处：`common.followSystem`（跟随系统 / 跟隨系統 / Follow system / システムに従う /
  Seguir el sistema / Suivre le système / Systemeinstellung folgen）。

**④ 顺手拆了一个真 bug：登录页那一行窄屏溢出**

写「320dp 下七种语言都不溢出」这条用例时发现的：「记住我 / 忘记密码」是
`Row(spaceBetween)` + 两个自然宽度的孩子，而版式字号是按 `rpx` 缩的 —— **英语在 320dp
上就溢出 78px**（日语「パスワードをお忘れですか」、西语更长）。改成
`LayoutBuilder` + `Wrap` + 每项 `ConstrainedBox(maxWidth: 整行宽)`，
`AuthCheckBox` 里的文字包一层 `Flexible`：一行装不下就整块换行（每项自己一行，
读得全），宽屏仍是左右分开；单个标签比一整行还长时在行内换行，不再画到屏幕外。

**⑤ 用例（1949 → 1960，净 +11）**

* `test/core/locale_controller_test.dart` +5：选过再选「跟随系统」→ 本地清掉、回到系统那一档；
  跟随时系统语言变了跟着换（用 `localesTestValue` 直接改系统语言）；手动选过之后系统变了装没看见；
  系统正好是当前那一档时点它也要记成手动选的；选择器条目首条是「跟随系统」且写法跟着当前语言。
* 新增 `test/features/language_picker_test.dart`（3 条）：从没选过时那一行与弹框首条都写「跟随系统」
  且 7 档一个不少（页面级的端到端）。
* `test/app_boot_test.dart` +2：走真正的系统通知（`WidgetsBinding.instance.handleLocaleChanged`
  + `localesTestValue`）验「跟着换」与「手动选过不动」；这两个用例顺带把测试窗口摆成
  真手机（默认 800×600 又宽又矮，`rpx` 会把字号放大到接近 26px，各种假溢出）。
* `test/features/login_page_test.dart` +1：320dp 窄屏 × <b>每</b>一种语言都不溢出
  （每轮换一棵新 ProviderScope —— 类型相同元素会被复用，容器里还是第一轮那档语言）。
* 原有那几条跟着改口径：登录页药丸「没选过时写跟随系统」、设置页那一行与弹框首条、
  `mine_pages_test` 挑语言时跳过「跟随系统」那一条。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量 **1960 项通过**。
出包 `2117`（arm64，正式签名 SHA-256 同 2114）。

**没验到的**：仍是**没有真机** —— 安卓/iOS 在设置里改语言后「即时跟随」这一步
（`didChangeLocales` 真不真发、发了多快）只能在真机上看了；iOS 不重启 App 不一定发这条通知。

### S12.11 Windows 适配第一批：桌面壳、三个必崩的点、键鼠交互（2026-10-03）

用户：「趁装 Visual Studio 的时间，先把不依赖编译的 Windows 适配做掉：桌面壳、三个崩溃点、
键鼠交互」。形态当场定死：**窄窗口 + 内容封顶居中**（初始 420×760、最小 360×600、屏幕居中、
标题 `Gracelink`）；范围只做 **P0 + P1**，通话 / 视频 / 音乐（P2）这轮不碰。
「服务端不动」照旧 —— 这一批**一行接口都没改**，全是客户端自己归位。

**① 桌面壳：不去改 106 个文件，在根上把宽度换掉**

* 新增 `core/platform/desktop_shell.dart`：窗口比 [`DesktopShell.maxWidth`]（500）宽时，
  把子树看到的 `MediaQuery.size.width` **覆写成 500** 并居中，两侧留一档灰（`AppColors.page`）；
  窗口本来就窄（≤500）时原样透传，行为与手机完全一致。
* 这样做的理由：整站版式是按「宽度 = 屏宽」算的 —— `rpx()` 就是 `屏宽 / 750`
  （**1897 处 / 106 个文件**），另有十几处直接读 `MediaQuery.sizeOf(context).width`
  （扫码取景框、图片气泡最大宽度…）。窗口一拉宽这些尺寸跟着放大，界面会变成
  「放大镜里的手机」；在根上换掉宽度之后，上面那些写法**一个字都不用改**就全部归位。
  只夹宽度不夹高度：竖版布局依赖的是宽度这一个前提。
* 挂在 `app.dart` 的 `builder` 里（`MediaQuery.withClampedTextScaling` 内层），
  所以每个页面都在壳里，不用逐页处理。

**② 「测试里默认关」是这一批的护栏（踩过一次就懂）**

* `isDesktopRuntime` 用的是 `dart:io` 的 `Platform.isX`，**不是** `defaultTargetPlatform`
  —— 组件测试跑在 Windows 宿主机上时后者就是 windows。
* 即便如此，`flutter test` 里 `isDesktopRuntime` 仍然是**真**的（宿主就是 Windows）。
  现有那 1900 多条用例钉的全是手机上的版式与交互（默认窗口 800×600、输入栏有「拍摄」、
  扫码页有取景框…），桌面分支一律开起来会成片变红。所以桌面行为统一走
  `desktopFeaturesEnabled`／`desktopFeaturesProvider`：**`FLUTTER_TEST=true` 时为假**
  （本机实测 `flutter test` 一定会设这个变量），用例要验桌面形态就自己 override。
* 拿得到 `ref` 的 widget 读 provider；拿不到 `ref` 的实现类（`SystemMediaPicker`、
  `SystemMediaSaver`）用同一个判据做**构造默认值**，同样能注入。
  **别再写裸判据** —— 这一条现在有用例钉着（见⑤第一条）。

**③ 三个必崩的点（每个都是「点到就崩」，不是「不好看」）**

1. **内嵌浏览器**：`webview_flutter` 只支持安卓/iOS/macOS，Windows 上只要
   `WebViewController()` 就抛 `WebViewPlatform.instance is not set`。协议、隐私政策、
   「发现」里 `type == 2` 的外链、扫到网址的兜底 —— 四个入口全走它。
   桌面换成 `DesktopWebViewHost`：一颗图标 + 「此页面由系统浏览器打开」+ 地址
   （`SelectableText`，能选中复制）+「在浏览器中打开」→ `launchUrl(externalApplication)`；
   进度直接报 100（页面根本不在我们这儿加载，那条进度线不能一直挂着）。
   微信 PC 端的外链也正是丢给系统浏览器的。
2. **扫一扫**：`mobile_scanner` 没有任何桌面实现，`MobileScannerPlatform.instance`
   没被设过 —— 构造、`.barcodes`、`.stop()`、`analyzeImage()` 全会抛。
   桌面这一页**不建控制器、不订阅、不 dispose、不 stop**（原来这四步全是无条件执行的，
   只是页面外观换掉了根本不够），只留「从文件里选一张图」，解码换成纯 Dart 的
   `zxing2`（新增直接依赖）+ `image`（原来是传递依赖，这轮提成直接依赖）：
   读文件 → `RGBLuminanceSource` → `HybridBinarizer` → `QRCodeReader`。
3. **选图 / 拍照**：`image_picker_windows` 对 `ImageSource.camera` 直接抛 `StateError`。
   「＋」面板里「拍摄」那一格在桌面**不摆**（微信 PC 端也没有），`pickCamera()` 桌面返回
   null；相册 / 视频改走 `file_picker` 的文件对话框（桌面本来也没有「相册」这个概念）。

顺带把「存图」与「开文件」两条归位：`gal` 只有 android/ios/macos、`open_filex` 只有
android/ios —— 桌面上存图改成复制到系统「下载」目录（拿不到就退回文档目录），
开文件走 `url_launcher` 的 `Uri.file(...)`（Windows 上就是 ShellExecute），
提示语也跟着换成「已保存到下载目录」。

**④ 键鼠交互**

* **回车发送 / Shift+回车换行**（照微信 PC 端，用户要的）。两个必须先查引擎才写得对的地方：
  Windows 引擎（`text_input_plugin.cc::EnterPressed`）**只在** `input_type == multiline`
  **且** `input_action == newline` 时自己插 `\n`，插完**总是**再发一条 `performAction`；
  所以在桌面上：`textInputAction` 必须是 `newline`（否则回车直接变成一次 `performAction`），
  发送由我们自己的 `Shortcuts` 拦，**换行也由我们自己插**（引擎插 + 我们插会多一个空行）。
  手机一侧一个字没动：仍是 `send` + `onSubmitted`。
* **右键 = 长按**：消息气泡、会话行、1:1 通话页与群通话页的「诊断」、灵听下载页的删除、
  灵听搜索历史 —— 六处都补了 `onSecondaryTapDown`（鼠标没有「长按」这个动作）。
* **悬停**：主题里加了 `hoverColor` / `focusColor`（8% 黑，白底上约 `#EBEBEB`，正是微信
  顶部栏那档灰）—— `InkWell` 那一路（会话行、底部 tab、设置行、通讯录行…）全覆盖；
  自绘的那些钮（发送、＋、表情、语音、「＋」面板里每一格）包一层新的
  `core/ui/hover_highlight.dart`（悬停蒙版 + 手型光标，不加涟漪、不改按下的样子）。
* **窗口**：`main.cpp` 初始 **420×760**、按屏幕尺寸算居中、标题改 `Gracelink`；
  `win32_window.cpp` 加 `WM_GETMINMAXINFO`（最小客户区 **360×600**）。那里有两处换算都
  不能省：`ptMinTrackSize` 说的是**整个窗口**（含标题栏/边框），得用 `AdjustWindowRectEx`
  把边框加回去；而 360×600 是**逻辑像素**（与 `main.cpp` 的初始尺寸同一个口径），
  Win32 那边是物理像素 —— 150% 缩放不乘一下的话，能拉到的最小客户区只有 240×400，
  正好把要挡的那一档放过去。DPI 用引擎给的 `FlutterDesktopGetDpiForHWND`
  （头文件里写明：任何在 Windows 尺寸与 Dart 尺寸之间换算的代码都该用它）。

**⑤ 用例（1960 → 1972，净 +12）**

新增 `test/features/desktop_windows_test.dart`：

* **默认关**（护栏本身也钉住）：`FLUTTER_TEST` 下 `desktopFeaturesEnabled` 为假；
* 桌面壳：宽窗封顶 500 居中（子树读到的宽度就是 500、高度不动）/ 窄窗 360 原样透传 /
  开关关着时一个字都不改；
* 存图提示语按平台换、桌面 `pickCamera()` 不去碰相机插件；
* 桌面读二维码：现场用 `zxing2` 编码 + `image` 出图（白底带静默区），从 PNG 里认出内容；
  纯白图返回 null（是「没认出来」，不是出错）。**两条都是普通 `test()`** ——
  真读文件那一步在组件测试的假时钟里等不到续点；
* 外链分流（开 → 桌面那页，关 → 真机 webview）+ 桌面那页的文案、地址、进度 100；
* 聊天输入栏：**回车真的发出去**（断言请求体与气泡）、Shift+回车只换行不发送、
  桌面「＋」面板里没有「拍摄」。

**⑥ 语言包（4 条 × 7 份）**

`scan.desktopTip`（扫码页那副「没有相机」的样子）、`webview.desktopTip` /
`webview.openInBrowser`（外链降级页；原来是硬编码中文，顺手补上）、
`common.savedToDownloads`。现各 **623 条**（en 624，含历史遗留的 `common.SearchNone`）。
写这一批时踩了一个坑：`scan.desktopTip` 第一次是写成**嵌套对象**塞进去的，
`i18n_keys_test` 立刻两条变红（key 找不到 + 文案没翻）—— 这个包是**全平面 key**，
`scan.albumHint` 这些也是平面写法。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量 **1972 项通过**。

**⑦ 首次 Windows 构建：一次暴露三个坑（2026-10-03 当天）**

`flutter doctor` 全绿（VS Build Tools 17.14.41）之后跑 `flutter build windows`，
前两个已修，第三个要管理员装一个组件：

1. **代码页 936 下的 C4819**（中文 Windows 上必踩）：runner 与插件的 C++ 源码是 UTF-8
   （注释里有中文），而本机代码页是 936 —— MSVC 报 C4819「该文件包含不能在当前代码页中
   表示的字符」，而 Flutter 给这些 target 统一开了 `/WX`（警告当错误），**一个中文注释
   就能让编译失败**（flutter_webrtc 就是这么挂的，连 runner 自己也中招）。
   修法：`windows/CMakeLists.txt` 里加 `add_compile_options(/source-charset:utf-8)`，
   放在几个 `add_subdirectory` **之前**（这样 runner 与全部插件都覆盖）。只改**读源码**
   用的字符集，不动执行字符集 —— 窄字符串字面量仍按本机 ACP 编码，插件运行时行为不变。
2. **`main.cpp` 被我改窗口尺寸时误删了一行**：`FlutterWindow window(project);` 没了，
   于是 `window.Create(...)` 报 C2065「未声明的标识符」。已补回。
   值得记一笔的是**怎么抓到的**：改完 C++ 别等整包构建 —— 单独编 runner 快得多：
   ```
   MSBuild.exe D:\coding\flutter\gracelinkim\build\windows\x64\runner\gracelinkim.vcxproj \
     -p:Configuration=Release -p:BuildProjectReferences=false -t:ClCompile
   ```
   （在 Git Bash 里**必须用 `-p:` / `-t:`**，写成 `/p:` / `/t:` 会被 MSYS 当成路径改写掉，
   报「只能指定一个项目」。）
3. **ATL 组件缺失**（这一条要管理员）：`flutter_local_notifications_windows` 的
   `src/plugin.cpp` 直接 `#include <atlbase.h>`（C++/WinRT 那条路要用），而装 Build Tools
   时用的 `--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`
   **不含 ATL** → C1083 找不到头文件。补装（VS 安装器会弹 UAC）：
   ```
   "C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify ^
     --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" ^
     --add Microsoft.VisualStudio.Component.VC.ATL --passive --wait --norestart
   ```

顺带记一个**缓存陷阱**：Firebase C++ SDK（约 963MB，落在
`build/windows/x64/firebase_cpp_sdk_windows_13.12.0.zip`）的解压是「目录存在就跳过」
（`firebase_core/windows/CMakeLists.txt` 里 `if(NOT EXISTS ${extracted_path})`）。
第一次构建被我掐掉时解压到一半（只出来 `VS2019/MT/x86`），之后每次都会拿这份残的 SDK
去链接，报 `LNK1181: 无法打开输入文件 .../VS2019/MD/x64/Release/firebase_app.lib`。
**这时候要删掉 `build/windows/x64/extracted`（zip 留着，不用重下）让它重新解压。**

**没验到的（更新到 2026-10-03 构建后）**

* `windows/` 那两处 C++ 改动**已经单独编过、能编过**（`-t:ClCompile` 干净，整包构建里
  runner 也走到了链接这一步）；`/source-charset:utf-8` 也实证有效（加之前 runner 自己
  就在报 C4819）。**整包构建现在只差 ATL 那一步** —— 装完 ATL 再
  `flutter build windows`，然后 `flutter run -d windows` 人工走查这几条：
  420×760 居中、拉宽后 500 列居中、拉到 360 不挤、右键菜单、回车发送 / Shift+回车换行、
  扫码页只剩选图、外链走系统浏览器、文件消息能用默认应用打开、图片存到下载目录。
  首次构建要拉 Firebase C++ SDK（963MB）与 libwebrtc 预编译包，预计 10–30 分钟。
* 桌面上**不能播视频、不能放音乐、不能通话**（`video_player` / `just_audio` /
  `audio_service` 都没有桌面实现；`flutter_webrtc` 有 Windows 实现但没验）—— 这是 P2，
  用户明确说了这轮不做。桌面上的视频消息目前会落到「播放失败」那一档，不是崩，是不给播。

### S12.12 Windows 适配收尾：出包 + 实机验证（2026-10-03）

S12.11 结尾那句「整包构建只差 ATL」当天就翻篇了。这一节记的是**第一次真的把 Windows 包
跑起来**，以及把「空间几何」这类没法靠单测钉住的东西量出来的过程。

**① 绕过 ATL：一份 30 行的替身，而不是等管理员**

`flutter_local_notifications_windows` 的 `src/plugin.cpp` 里对 ATL 的依赖其实只有 **3 处
`CW2A`**（宽字符 → UTF-8 的转换宏）。装了三次提权对话框都超时（人不在），于是给它写了一份
最小替身：`windows/atl_shim/atlbase.h`，只定义 `CW2A`（`WideCharToMultiByte` + `CP_UTF8`），
然后用 `include_directories(${CMAKE_CURRENT_SOURCE_DIR}/atl_shim)` 指过去。

* 位置有讲究：这段**必须放在 `include(generated_plugins.cmake)` 之后** —— 插件 target 是那一步
  才创建的，而 `include_directories()` 只影响**它之后**创建的 target。
* 这只是让构建能过的权宜之计（不碰系统、随时可撤）。**正道还是装 ATL 组件**（S12.11 ⑦.3 那条
  命令），装完把 `windows/atl_shim/` 与 `CMakeLists.txt` 里那两行一起删掉。
* 第一次成功出包：`build/windows/x64/runner/Release/gracelinkim.exe`，约 62MB
  （含 libwebrtc、sqlite3、通知插件）。增量构建 47 秒。

**② 怎么「看」Windows 上跑起来的样子（可复用的手法）**

桌面程序没有 adb，也没有 VM service（release 包），所以这一轮用两条**可程序化**的路子：

1. **几何**：PowerShell 里 `GetWindowRect` + `GetDpiForWindow` + `SystemParametersInfo(SPI_GETWORKAREA)`
   —— 位置、逻辑尺寸、与工作区居中的偏差都能算出来。**脚本进程必须先声明 DPI 感知**
   （`SetProcessDpiAwarenessContext(-4)`），否则拿到的是虚拟化坐标；窗口坐标一律按**物理像素**读写。
2. **画面**：`PrintWindow(hwnd, hdc, 2)`（`PW_RENDERFULLCONTENT`）。**flag 必须是 2** —— 传 0 时
   Flutter 的 GPU 合成结果抓不到（一片紫渐变，那是桌面壁纸不是界面）。抓到的 PNG 交给
   项目里已有的 `image` 包，转成 ASCII / 按色相分类的粗图 / 逐列剖面来「读」版面：
   白色卡片、蓝色 logo、绿色主按钮、灰底两侧各在哪些列，都能量出来。
   —— 打字机里看界面的次数，比截图轮询可靠得多。

**③ 实机量到的（3072×1824 工作区 @192dpi，即 200% 缩放）**

* **冷启**：标题 `Gracelink`、窗口 **逻辑 420×760**、原点 `(1116,152)` —— 与工作区居中位置
  **偏差 (0,0)**，完全在屏内。重新构建后复测仍然如此。
* **最小尺寸**：请求缩到 200×300（物理）被挡在 **746×1271 物理 = 373×636 逻辑**，
  即客户区 **360×600 + 边框/标题栏**，正是 `WM_GETMINMAXINFO` 设的那一档。
  早先担心的「只能变大不能变小」是**误读**：`1400×1300` 能精确生效，再从 `1400×1300`
  缩回 `500×700` 会被正确挡回 360×600 —— 两个方向都对。
* **桌面壳（500 列）**：把窗口拉到 1600×1400 物理（800×700 逻辑）后逐列量灰度：
  非灰底内容占 x `292..1300`（≈ **504 逻辑像素**，等于封顶值 500 加上边缘抗锯齿），
  左右各留 ≈147 / 149 逻辑像素的 `AppColors.page` 灰底。**「视图换宽 → 中间那个宽度」
  这条在真机上成立**，不只是单测里成立。
* **登录页渲染**：蓝 logo（`AppColors.brand`）、站点名、副标题、三行表单项、通栏绿按钮
  （实测 `#09c161` ≈ `AppColors.wechatGreen`）、「注册」描边钮、底部版本号 —— 与
  `AuthScaffold` / `AuthBrand` / `AuthCard` / `AuthButton` 的结构逐条对得上。
  顺带看清一件事：**800×700 的窗口装不下登录页**（内容按 500 宽算出约 890 高），
  会可滚动 —— 这是 `AuthScaffold` 本来就有的设计，不是溢出。

**④ 悬停：两层都验到了**

* **Material 按钮**（`ElevatedButton`，即登录那颗）：鼠标移上去后按钮内色
  `#0BC262 → #1DC66E`（白 8% 叠色），差异包围盒 `x 81..758 / y 1125..1275` **正好就是按钮**，
  窗口其它地方零变化。
* **自绘控件**：拿语言 chip 对比（改动前是裸 `GestureDetector`，划过毫无反馈）：
  加 `HoverHighlight` 后差异 `15561` 像素、包围盒 `x 558..794 / y 77..146`
  = **236×70 物理 ≈ 118×35 逻辑**，正是那颗药丸；y=180（药丸外）无差异，没有多余热区。
* 踩过的坑：第一次两张图 **md5 完全相同** —— 不是悬停坏了，是窗口不在前台时鼠标事件根本
  没进来（`WindowFromPoint` 照出来的其实是 Flutter 的子窗口 `FLUTTERVIEW`）。
  测悬停前先 `SetForegroundWindow` + 确认光标下的窗口。

**⑤ 顺手补的一族：登录 / 注册页的悬停**

S12.11 的悬停只覆盖了 `InkWell` 那一路与聊天输入栏的自绘钮，但**桌面用户看到的第一屏是
登录页**。这一族里还有四个可点控件是裸 `GestureDetector`：语言 chip、`AuthTextLink`
（忘记密码 / 已有账号那个「登录」）、`AuthCodeButton`（发送验证码）、`AuthCheckBox`（记住我）。
四个都包上 `HoverHighlight`（圆角与被包控件一致）。**密码框里那颗「眼睛」故意不加**：
光标是有用的，但在一个光秃秃的图标背后压一块灰蒙版很难看。

**⑥ 用例（1972 → 1974，净 +2）**

`test/features/desktop_windows_test.dart` 新增一组「鼠标悬停反馈」：

* `HoverHighlight`：悬停压 8% 黑蒙版、移开立刻撤掉（读 `foregroundDecoration`）；
* **主题 `hoverColor` 真的会把 `InkWell` 那一族压暗** —— 用 `RepaintBoundary` 取正中心像素
  （`tester.runAsync` 里 `toImage`），悬停前 / 悬停后逐通道比对，必须变暗。
  这条是像素级的，所以「主题里那个值有没有真的走到会话行上」不再是靠读代码猜。

**⑦ 仍然没验到的**

* **聊天那一侧的人工走查**：右键菜单、回车发送 / Shift+回车换行、扫码页只剩选图、
  图片存到下载目录、文件消息用默认应用打开、外链丢给系统浏览器 —— 这些都要**登录之后**
  才摸得到，而这台机器上桌面端没有会话（启动日志：「连接就绪但未登录」）。
  登录页这一屏能验的都已验完，剩下的建议用户在那扇窗口里登录后自己过一遍。
* **P2**（视频 / 音乐 / 通话）照旧没碰：`video_player` / `just_audio` 没有桌面实现，
  `flutter_webrtc` 有但没验。
* 记一条工具上的坑：**`flutter analyze` 不会跳过 `build/`** —— 临时验证脚本放那里，
  会以 `avoid_print` 之类把「No issues found!」弄花。这类脚本一律放 `.dart_tool/` 下
  （本项目实测：放 `build/shottool/` 时 30 条 info，挪到 `.dart_tool/shottool/` 后干净）。

### S12.13 桌面横屏三栏：照微信 PC 端重排（2026-10-03）

上一节刚出包，用户就把窗口打开看了一眼，然后给了微信 PC 端的截图：

> 「我觉得你UI层面是不是要适配一下电脑的UI，你现在电脑端还是手机的样子…你学一下微信电脑端UI的
> 大致框架…电脑是横屏手机是竖屏的嘛」

判断是对的：S12.11/S12.12 那一批只解决了「**能用**」（不崩、能点、内容不放大），版式仍然
是「顶部标题栏 + 底部 tab 栏 + 一屏一页」。这一节是把主界面改成**横屏三栏**。

**① 形态**

```
┌──┬──────────────┬─────────────────────────────┐
│图│ 🔍 搜索   ＋ │ 标题             ⋯（聊天信息）│  ← 聊天页自己的顶栏（内嵌形态）
│标│──────────────│                             │
│条│ 会话行（选中行带底色）│      消息 / 输入区      │
│  │ 会话行       │                             │
│≡ │              │  😊 ⊕ @ 🎤          [发送]  │  ← 输入框里那一排 + 常驻的发送
└──┴──────────────┴─────────────────────────────┘
  60        300                  剩余
```

* 新增 `features/home/desktop_frame.dart`（[DesktopFrame]）：左图标条（头像 / 四个分区 /
  底部「≡」进设置）、中栏（搜索框 + ＋ + 会话列表）、右栏（聊天）。
* 门槛 **900 逻辑像素**（`kDesktopFrameMinWidth`）：低于它就是手机那套（<=500 还会把内容
  封顶居中）。900 是排出来的：60 + 300 + 聊天区至少 540。

**② 「宽度靠列数解决，不靠放大」——这是这一批最要紧的一条**

三栏里每一栏的**字号、头像、行高仍是手机那一档**，只是窗口里多摆了一栏。做法是把三栏子树
看到的 `MediaQuery` 宽度**钉在 420**（`DesktopFrame.contentBaseWidth`）：`rpx` 是
`屏宽/750`，钉住之后 1200 宽的窗口里字不会变成 24px，会话行也不会变成半屏高。
高度不钉（竖向该多高还是多高）。

**③ 与手机壳共用同一份「分区」定义**

新增 `features/home/shell_tabs.dart`：`ShellTabSpec` + `buildShellTabs()` + `shellTabBody()`
（原来都是 `home_shell.dart` 的私有东西）。两处共用：
手机壳的底部 tab 栏、桌面图标条。**选中的分区下标也挪进 provider**
（`HomeTabIndex extends Notifier<int>`）—— 两套外壳各存一份下标就会各切各的。
顺带把右上角那颗「＋」菜单抽成 `features/home/shell_menu.dart`（手机导航栏与桌面中栏共用
一套 `ShellAddAction`）。

**④ 点会话 = 选中到右栏，不 push 整页**

* `ConversationListPage` 多了两个参数：`onOpenChat`（不传 = 手机那套 push；传了就换成
  「选中到右栏」）与 `selectedId`（选中行加底色）。手机上这两个参数永远是 null/不传，
  版式一点不变。
* 从**搜索 / 通讯录 / 通知**进聊天那条路走的还是普通路由，那种情况下 `ChatScreen`
  （新）会把同一个框架套起来 —— 所以「从哪儿进聊天」看到的都是三栏，不会一半三栏一半竖版。
* `ChatPage` 多了 `embedded`：只改顶栏摆法 —— **没有返回箭头**（左栏一直在，没有「返回」
  这个动作）、标题靠左（微信 PC 就那样）。手机上恒为 false。

**⑤ 输入区按微信 PC 摆**

桌面那份改成：一个白框（内含输入区 + **框内底部一排图标**：表情 / ＋面板 / @ / 语音），
「发送」挪到框**外右下角**且**常驻**（没内容时是灰的、点不动）—— 与手机那份「有内容才长出
发送键」不同。为此把「回车发送 / Shift+回车换行」那套快捷键抽成 `_enterShortcuts()`：
两种外形共用一份，不然迟早漂。

**⑥ 一个必须记住的坑：三栏里要有 `Material`**

框架根部包了一层 `Material`。少了它，中栏搜索框与会话行里的 `InkWell` 会在**构建期**
抛「No Material widget found」，而表现是**整个中栏消失**（不是红屏、也不是报错弹窗），
第一遍写的时候就是这么踩的 —— 用例里那条「搜索框在不在」当场抓到了。

* 另一个测试侧的坑：三栏用例必须在**用例体最后**显式调一次收尾（卸载 + 推一帧），
  光靠 `addTearDown` 不够 —— 框架那道「不能有 Timer 挂着」的断言跑在 body 结束、
  teardown **之前**，而三栏在体内就会踢掉一批 drift 流（首帧之后「吃满整窗」开关打开，
  DesktopShell 从「夹 500」换成「透传」，那次换版式会关流重开）。

**⑦ 窗口尺寸跟着改成横屏**

`main.cpp`：初始 **1200×800**（按工作区收敛，四边各留 40 逻辑像素）、居中；
`win32_window.cpp`：最小客户区 **480×600**（容许拉窄到手机形态，又不至于挤到没法用）。
单位仍是逻辑像素 + DPI 折算那一套（见 S12.11）。

**⑧ 语言包**：新增 `desktop.pickChat`（右栏还没选会话时那句）× 7 份，现各 **624** 条。

**⑨ 用例（1974 → 1977，净 +3）**：宽窗三栏（图标条 + 搜索 + 会话列 + 右栏空态）、
图标条切分区、点会话进右栏（发送键常驻 + 工具排就在输入框里）、窄窗（800）退回手机壳。

**验证**：`flutter analyze` 干净、`dart format` 干净、全量 **1977 项通过**；
实机：冷启 **逻辑 1200×800 居中偏差 (0,0)**、最小尺寸挡在 480×600（客户区），
以及**宽窗下非三栏页面（登录页）仍精确封顶 500 逻辑宽居中**（左右各 700 物理像素灰底）——
即「三栏吃满整窗、普通页面照旧居中」这条设计在真机上成立。

**没验到的**：三栏本身的**实机画面**需要登录后才看得到（桌面端本机没有会话，
启动后停在登录页），所以三栏的像素级走查留给下一轮；视频 / 音乐 / 通话（P2）照旧没碰。

**⑩ 修一个「三栏永远不出现」的判据 bug（2026-10-03 夜，用户当场报的）**

现象：代码全在、测试也过，可**用户登录之后看到的还是手机版式**（顶部「恩信」导航栏 +
封顶 500 居中的会话列表 + 底部 tab 栏）。

两层原因：

1. **旧包**：那一版源码还没重新编译，用户窗口里跑的是旧 EXE（先出包，才谈得上验）；
2. **真 bug**：`desktopWideLayout` 读的是 `MediaQuery.sizeOf(context).width`，而
   `DesktopShell` 在宽窗下**正是把子树看到的那份宽度覆写成 500**（那条封顶）。
   于是判据拿到 500，永远小于 `kDesktopFrameMinWidth` —— 生产上三栏从不激活。
   测试没抓到，是因为三栏用例**没开 `desktopShellProvider`**：壳关着 → 宽度是真实值 →
   判据成立。**测试跑的是「另一个形态」，不是生产**。

**验证**：`flutter analyze` 干净、`dart format` 0 改动、全量 **1977 项通过**
（`test/features/desktop_windows_test.dart` 17 条，其中三栏那条现在**开着桌面壳**跑 ——
这条用例以前没开壳，所以那个 bug 一个都抓不到）。实机画面走查见 S12.14。

**修法**：新增 `realWindowWidth(context)`（读 `View.physicalSize / devicePixelRatio`，
那是引擎给的真实窗口尺寸，不受 `MediaQuery` 覆写影响），判据改用它。
顺手把 `DesktopShell` 的「夹 500 ↔ 透传」两态改成**同一棵 widget 层次只换宽度**
（`ColoredBox > Center > SizedBox > MediaQuery` 两态都在，只换 `contentWidth`），
避免翻面那一帧整棵子树被重挂（登录进主界面会闪一下，drift 流被关掉重开）。

测试那边：三栏组 `pumpHome` 加 `desktopShellProvider.overrideWithValue(true)`，
并把「宽窗」那条改成先断 `DesktopFrame` 出现、再断框架看到的宽度是整窗 1200。

**教训（写在这里给以后）**：凡是要判「窗口有多宽」的地方，一律走
`realWindowWidth(context)`，不要读 `MediaQuery.sizeOf(context).width`（它可能是被上层
覆写过的）；测试里跑桌面形态时，`desktopShellProvider` 该开就开 —— 关着测出来的是
「另一个形态」，不是生产。

### S12.14 三栏实机走查：bug 修复后重出包（2026-10-03 深夜）

**结论：三栏在真机上确实出来了。**

`flutter build windows --release`（47.0s，增量）→ 重启 `gracelinkim.exe`：

* 窗口几何：物理 2400×1600 @ dpi 192 → **逻辑 1200×800**，居中（量自 `GetWindowRect`）；
* 截图（`PrintWindow` 抓不到 GPU 画面，改用置顶 + `CopyFromScreen`）：`build/shot_now.png`；
* 版面（`build/shot_now.png` 逐列扫描，物理像素 → 逻辑 = ÷2）：
  * 左图标条：**x 0..60**（`AppColors.navBar` 灰底 + 绿色选中图标 + 底部「≡」）；
  * 会话列：**x 60..367**（白底 + 截图里那三行会话：Gracelink Team / 我的收藏 / 群聊 / 系统通知）；
  * 右栏：**x 368..1194**（`AppColors.page` 灰底 = 空态）；
  * 竖向分界线正好落在 367/368（= 60 + 300 + 分隔线），与 `railWidth` / `listWidth` 对上。

**右栏空态**：会话列那几行就是真实的会话（用户已登录），右栏在没点会话时是灰底空态
（中心一团浅色像素 = 空态图标 + 「选择左侧的聊天开始」）。

**本轮改动清单（相对 S12.13）**：

1. `lib/core/platform/desktop_shell.dart`
   * `realWindowWidth(context)`：读 `View.physicalSize / devicePixelRatio`，
     绕开自己那条 500 覆写；`desktopWideLayout` 改用它（**这就是三栏永不出现的根因**）；
   * 两态（夹 500 / 透传）改成同一棵 widget 层次只换宽度，避免翻面那一帧整棵子树重挂。
2. `test/features/desktop_windows_test.dart`
   * 三栏组 `pumpHome` 加 `desktopShellProvider.overrideWithValue(true)`（与生产同形态，
     这条以前没开壳，所以那个 bug 抓不到）；
   * 「宽窗」那条改成先断 `DesktopFrame` 出现、再断框架看到的宽度是整窗 1200。
3. `REFACTOR_PLAN.md`：本节 + S12.13 ⑩（bug 记录与教训）。

**验证**：`dart format` 0 改动、`flutter analyze` 干净、全量 **1977 项通过**
（`test/features/desktop_windows_test.dart` 17 条全绿）；出包成功；实机三栏画面如上述。

**没验到的**：视频 / 音乐 / 通话（P2）照旧没碰；安卓包没重新构建；
三栏里的交互（右键菜单、回车发送、扫码选图）只过了组件测试，没在真机上逐个点。
### S12.15 桌面聊天区右上角三颗 + 右侧信息面板（2026-10-03 夜）

用户对着微信 PC 的两张截图指出：**通话、查找聊天记录、三个点都在聊天区右上角**；
点「⋯」不是整页跳转，而是**右侧滑出一栏**（查找聊天内容 / 消息免打扰 / 置顶聊天 /
清空聊天记录）。

**改动**

1. `lib/features/chat/widgets/chat_info_panel.dart`（新）：
   * `ChatInfoPanel` —— 宽 **300** 的右侧栏，内容对照微信 PC：
     头像（点进整页聊天信息）+ 单聊那颗虚线「＋」（发起群聊）/ 「查找聊天记录」/
     「消息免打扰」「置顶聊天」两颗开关（复用 `conversationRepository` 的
     `setNotice` / `setTop`）/ 「清空聊天记录」（红字，本机口径）。群聊多一行
     「聊天信息」（成员网格 / 群公告 / 群管理仍在整页里，300 宽摆不下）。
   * `chatInfoPanelProvider`（`Notifier<bool>`，`toggle()`）—— 面板开关。
2. `lib/features/chat/chat_page.dart`：
   * `_buildScaffold` 桌面内嵌时把面板摆成 `Row` 的第二个孩子（**挤占**聊天区宽度，
     与微信 PC 一致，不是盖一层浮层）；面板只在开着时在树上。
   * 顶栏右边：桌面内嵌且非系统会话时画 `_desktopActions` —— 查找聊天记录（搜索图标，
     进聊天记录页）、通话（单聊 & webrtc，弹菜单选语音 / 视频；群聊是群通话）、
     ⋯（切面板）。手机形态（窄窗 / 整页）仍是原来那一颗「更多」。
   * 面板里的「清空聊天记录」走 `_clearHistoryFromPanel`（本机口径：本地名单 +
     删缓存 + 清预览；群里「连服务端一起清」仍在整页聊天信息里）。
3. 语言包**没有新增 key**（复用 `chat.searchMsg` / `common.webrtc` / `message.info` /
   `group.noVoice` / `chat.isTop` / `message.clearRecord` / `group.addUser` 等）。

**验证**

* `flutter analyze` 干净、`dart format` 0 改动；全量 **1979 项通过**（净 +2 条：
  「右栏右上角：查找聊天记录 / 通话 / ⋯，⋯ 抻出右侧信息面板」、
  「窄窗（800）进聊天：没有桌面那三颗，仍是整页那套」）；
* 实机（`build/walk_final_panel.png`、`build/tap_close.png`，脚本 `build/tap.ps1`）：
  * 关闭态右上角三颗在（x≈1075 放大镜 / x≈1117 摄像机 / x≈1146 三个点，逻辑坐标）；
  * 点 ⋯ → x=894 处出现分界线、右侧 300 宽换成面板（截图 `walk_final_panel.png`）；
  * 再点一次 ⋯（面板开时它被挤到 x≈858）→ 分界线消失，聊天区回到通栏
    （截图 `tap_close.png`）。

**没做**：聊天记录页 / 整页聊天信息 / 通讯录详情 / 设置等**仍是手机整页形状**
（用户已指出"很多页面和弹窗还是手机的 UI"，这一轮只做了聊天区右上角与信息面板）。

### S12.16 桌面：通讯录两栏 + 发现/我/所有二级页「一栏面板」（2026-10-03 深夜）

用户：「通讯录、发现、我、设置等等好几个页面我看了都还是手机的 UI」——上一轮只做了
消息分区（会话列 + 聊天区）与聊天信息面板，剩下的分区与**所有 push 出去的二级页**
还是手机那套整页形状（宽窗里被拉成一条）。

**四个分区按各自的形状摆**（`desktopWideLayout` 门控，窄窗 / 手机一个字节不改）：

| 分区 | 桌面形状 |
|---|---|
| 消息 | 图标条 + 会话列（300）+ 聊天区 |
| 通讯录 | 图标条 + 好友列（300，顶上「搜索 + ＋」）+ **右栏好友资料** |
| 发现 / 我 | 图标条 + **一栏定宽面板（500）** + 右侧留灰 |
| 二级页（设置、资料、聊天记录、群成员、灵听、资讯…） | 同上：图标条 + 一栏面板 + 右侧留灰 |

**改动**

1. `lib/features/home/desktop_frame.dart`：框架按分区形状分派（`_messageBody` /
   `_contactsBody` / `_panelBody`），`otherSections` 这个「整页塞进去」的口子删掉；
   * `DesktopPanel`：定宽 500 的一栏（里面把 `MediaQuery` 再钉一次，`rpx` 按 500 算），
     右边一条细线；
   * `DesktopPageFrame`（新）：二级页的外壳（图标条 + 面板 + 灰底），`section` 决定
     图标条点亮哪一格；图标条上点分区 = `go` 回主界面并切过去；
   * `_ListColumnHeader`：中栏顶上「搜索框 + ＋」抽出来，消息（type=1）与通讯录
     （type=2）共用；
   * `_ContactsColumn` / `_ContactsPane`：好友列 + 右栏资料（复用 `UserDetailPage`）。
2. `lib/features/contacts/contacts_page.dart`：加 `onOpenContact` / `selectedId`
   （与 `ConversationListPage` 同一套）——桌面上点好友是**选中到右栏**，选中行加底色；
   手机上不传，仍是 push 用户详情。
3. `lib/features/contacts/user_detail_page.dart`：加 `embedded` / `onDeleted`；
   `embedded` 时不画自己的 `Scaffold` / 返回箭头，只留栏顶那条「⋯（删除好友）」
   （否则删除好友那颗钮会因为换摆法而消失）；补 `didUpdateWidget` —— 右栏换人是在
   同一个 State 上换 `userId`，不重拉会一直显示上一个人。
4. `lib/core/platform/desktop_shell.dart`：`desktopFrameActiveProvider` 从
   `ValueNotifier<bool>` 改成 `ValueNotifier<int>`（**计数**：二级页可以叠着推，
   顶层 pop 掉时下面那个还在树上，布尔会被误置回 false）；
   新增 `DesktopFrameScope`（挂载 +1 / 卸载 -1，都是 post-frame），两个框架共用。
5. `lib/core/router/app_router.dart`：`_desktopPage(child, [section])` 把二级页包进
   `DesktopPageFrame`（约 30 条路由）。**刻意不包**：登录 / 注册、扫一扫、通话 /
   群通话（沉浸式全屏）。
6. 语言包新增 `desktop.pickContact`（7 份，通讯录右栏空态那句）。

**踩到的坑（重要）**

* **没有 child 的 `ColoredBox` 只占 `constraints.smallest`** —— 在 `Row` 的
  `Expanded` 里交叉轴是松约束，于是它 **0 高、什么都不画**：实机上「发现 / 我 /
  二级页」右边一片白，而 widget 用例只断言 left/right 照样绿。改成
  `Container(color:)`（无 child 时自己撑满有界的那一维），并把用例改成断言
  **矩形（含高度）**。`_EmptyPane` 那些带 child 的 `ColoredBox` 不受影响。
* `DesktopFrameScope.dispose` 里**不能同步**改计数：卸载发生在 `finalizeTree`
  （框架锁着）期间，通知会让 `DesktopShell` 的 `ValueListenableBuilder` 在锁定期
  标脏 —— 报「setState() or markNeedsBuild() called when widget tree was locked」
  （从二级页点图标条回主界面时踩到）。改成 post-frame 减。

**验证**

* `flutter analyze` 干净、`dart format` 0 改动；全量 **1984 项通过**（净 +5：
  「手机（桌面开关关着）哪怕窗口 1200 宽也还是手机那套」「宽窗通讯录：中栏好友列 +
  右栏空态」「宽窗通讯录：点好友 = 右栏出资料，⋯ 还在」「宽窗发现 / 我：一栏面板 +
  右侧留灰」「宽窗二级页：设置摆成一栏面板」）。
* 实机（1200×800 逻辑，脚本 `build/tap.ps1` + `.dart_tool/shottool/grid.dart` 采色）：
  * 通讯录：中栏 60–367（搜索 / ＋ / 好友行），点一行后右栏 368–1200 出资料（卡片白、
    其余页面底色灰）—— `build/walk_contacts.png`、`build/walk_contact_detail.png`；
  * 我：面板 60–560（资料卡 / 表情 / 设置），560–1200 灰 —— `build/walk_mine.png`；
  * 发现：面板 60–560（灵听 / 媒体号两栏），560–1200 灰 —— `build/walk_compass.png`；
  * 设置（图标条底部「≡」→ `/mine/setting`）：面板 60–560（顶栏 + 分组列表），
    560–1200 灰 —— `build/walk_settings.png`。
* 预览页 `build/shot.html` 已更新（五组截图）。

**手机端影响**：零。所有新形状都挂在 `desktopWideLayout`（= 桌面运行时 &&
`desktopFeaturesProvider`）后面；安卓 / iOS 上 `isDesktopRuntime` 为假，走的仍是
原来那条手机分支（本轮没有改任何手机分支的代码，只是把「桌面怎么摆」换成按分区派发）。
上面那条「开关关着时窗口 1200 宽也还是手机那套」的用例把这件事钉住了。

### S12.17 桌面三件事：二级页进右栏、弹层居中、**扫码登录**（2026-10-04）

用户这一轮的三个要求（原话）：

1. 「全部要改成适配电脑 UI 的不要保留任何手机样式」；
2. 「为什么有些页面都一直在左半部分显示，右边一直空着干嘛呢？比如通讯录这个主页
   面可以在左半部分，那么点击新的朋友之后是不是可以显示把新的朋友页面在右半部分
   呢？还有很多灵活应用一下不要我一个个指出来你自己看看」；
3. 「我给你上传了一个文件夹你看一下，这是服务端文件夹（虽然是老的不是最新的，但是
   网页前端代码没变过）你看看能不能找出来就是，网页端是可以扫码登陆的你能找到怎么
   搞不？能的话把 flutter 电脑端也改成扫码登陆呢」。

---

#### 一、二级页进**右栏**（要求 2）

旧形状是「图标条 + 一栏定宽面板 + 右侧留灰」（S12.16）—— 右边那半个窗口白瞎了，
用户点的就是这个。新形状：**同一个桌面框架，二级页摆进右栏**，中栏（会话列 /
好友列 / 发现·我那一栏）照旧留着。

```text
消息    ┌──┬──────────┬──────────────────────┐
        │图│ 会话列    │      聊天区           │
        ├──┼──────────┼────────────┬─────────┤
        │  │ 会话列    │  聊天区     │ 二级页   │  ← 会话信息 / 聊天记录 /
        │  │          │            │  （420） │     群公告 / 群成员
        ├──┼──────────┼────────────┴─────────┤
通讯录  │图│ 搜索 ＋   │                       │
        │标│ 新的朋友 ●│   新的朋友 / 群聊 /    │
        │条│ 群聊      │   好友资料 / 搜人      │
        │  │ 好友行    │                       │
        ├──┼──────────┼───────────────────────┤
发现/我 │图│ 那一页    │ 设置 / 账号与安全 /    │
        │  │ （500）   │ 灵听 / 媒体号…        │
        └──┴──────────┴───────────────────────┘
```

* `DesktopFrame` 新增 `pane`（右栏那一页）、`section`（强制用哪个分区的形状）、
  `paneId`（中栏点亮哪一行）、`railGoesHome`（点图标条回不回主界面）；
* `DesktopPageFrame` 缩成一层皮：`desktopWideLayout` 为真时返回
  `DesktopFrame(section:, pane: child, paneId:, conversationId:, railGoesHome: true)`；
* 消息分区那四个「属于某个会话」的二级页（会话信息 / 聊天记录 / 群公告 / 群成员）
  从路由的 `id` / `group_id` 拿到会话，**聊天留在中栏、那一页当右侧栏（420）** ——
  微信 PC 就是这个形状（`DesktopFrame.paneSideWidth`）；
* `_Pane`：白底 + 一条左细线 + `MediaQuery` 钉 500（`rpx` 回到面板那一档，
  电脑上多出来的是宽度不是更大的字）；
* `ContactsPage` 加 `selectedEntry`（`ContactEntries.newFriends` / `groups`），
  二级页开着时中栏那一行带底色（与会话列表同一个口径）；
* 二级页里点列表行 = **照手机推一页**（`onSelect` 传 null）：那一页自己带着列表 +
  右栏资料，观感一致，也不会出现「点了没反应」。

#### 二、弹层桌面化（要求 1）

* `lib/core/ui/desktop_overlay.dart`（新）：
  * `showAppSheet(...)`：手机上就是原来的 `showModalBottomSheet`（参数原样透传，
    一个像素都不动），宽窗桌面上换成**居中的白色窗口**（定宽 500、圆角 10、投影 +
    90% 高封顶、`rpx` 钉 500）。**18 处 `showModalBottomSheet` 全部换成它**；
  * `DesktopOverlayScale`：弹层子树的 `rpx` 尺度归位（钉回 500）；
  * `desktopFeaturesFor(context)`：读桌面开关，**没挂 `ProviderScope` 时退回编译期
    开关**（全站那些空壳 `MaterialApp` 的弹窗用例没有 ProviderScope，直接
    `ref.watch` 会抛「No ProviderScope found」——真踩到过，一次性打红 37 条）。
* `WeChatDialogBox`：桌面上先钉尺度再画 —— 不钉的话 600rpx 的确认框按 1200 算成
  **960 宽**（一个占满屏幕的「微信白框」）。注意必须让里面的 `Builder` 拿到钉过的
  context（写错过一次，框宽仍旧 960）。

#### 三、桌面扫码登录（要求 3）

**服务端那一半（从上传的服务端文件夹里读出来的）**：

| 环节 | 位置 | 做什么 |
|---|---|---|
| 连上就发 `pong` | `app/worker/Events.php` `case 'pong'` | 客户端发 `{type:pong, isQrLogin:true}` → 服务端现生成 `qrurl` 推回来（`{type:codeLoginQr}`）；带着 `isQrLogin` 的心跳不会被当成未登录踢掉 |
| 二维码内容 | 同上 | `{app_host}/scan/a/{urlencode(authcode(client_id,'ENCODE',app_id,100))}` —— **100 秒**寿命，所以网页端每 60 秒（服务端 `ping`）重发一次、拿一张新码 |
| 手机扫到之后 | `app/index/route/app.php` + `app/index/controller/Index.php::scanQr/qrLogin` | 路由 `scan/:action/:token` → `action=a` 那条：解出 client_id，回 `{loginToken}`（300 秒寿命） |
| 手机确认 | `app/enterprise/controller/Im.php::tokenLogin` | 手机带着自己的登录态 POST `/enterprise/im/tokenLogin {token:loginToken}` → 服务端把**那条要登录的连接** `bindUid` 到这个人，并 `sendToClient` 推 `{type:tokenLogin, data:{sessionId, authToken, userInfo}}` |
| 网页端怎么用 | `public/assets/js/app.*.js` 的 `Socket` 组件 | 收 `tokenLogin` 就把 `authToken` / `sessionId` 写进本地并 `location.reload()` |

**电脑端这一半（新实现）**：

* `lib/features/login/qr_login_session.dart`（新）：`QrLoginSession` = 一条**匿名**连接
  （同一个 `WsClient`，地址还是 `wss://{host}/wss`）；
  * `init` / 服务端 `ping` → 发 `{type:pong, isQrLogin:true}`（要码 / 换码）；
  * `codeLoginQr` → `qrurl` 原样上图；每 50 秒再要一次（比 100 秒的寿命提前）；
  * `tokenLogin` → `SessionService.applyQrLogin(data)`，状态转 `confirmed`，收摊；
  * `WsStatus.reconnecting` 且屏幕上有一张码 → 标成 `failed`（那条连接的 `client_id`
    已经作废，扫了也绑不上）；
  * `qrLoginSessionProvider` 是 `autoDispose`：切回账号密码登录就把这条连接关掉。
* `SessionService.applyQrLogin(...)`：与密码登录**共用后半段**（换账号清本机数据 →
  进切换列表 → 登记推送设备标识 → 发 WS `bindUid`），所以扫码进来与输密码进来
  在数据上完全同一条路。
* `lib/features/login/widgets/desktop_login.dart`（新）：桌面登录页两栏 ——
  左边品牌绿渐变（logo / 站名 / 一句说明），右边一列定宽卡片，**默认二维码**
  （微信 PC 就是这么登的），底下一条「密码登陆」切回账号表单；账号表单直接复用
  手机那套零件（`AuthCard` / `AuthTextField` / `AuthButton`…），只是摆进右栏。
  这一页挂 `DesktopFrameScope`：登录页自己没有框架，不挂的话 `DesktopShell` 会把
  它夹回 500（两栏版式就不存在了）。
* 语言包新增 5 个 key（`desktop.scanLogin` / `scanLoginHint` / `qrConnecting` /
  `qrRefresh` / `qrFailed`，7 份 → 各 630 条）。

**验证**

* `dart format` 0 改动、`flutter analyze` 干净、全量 **2001 项通过**（+17）：
  * 桌面 26 条（+2 新、1 条改）：设置进右栏（面板右边就是设置页、铺到 1200）、
    通讯录点「新的朋友」→ 那一页从 x=360.5 铺到 1200 且好友列还在、会话信息 =
    聊天还在中栏 + 右侧栏 420（`chatInputBar` 在侧栏左边）；
  * `test/core/desktop_overlay_test.dart`（新 6 条）：宽窗弹层 = 居中窗口（宽 500、
    `MediaQuery` 也是 500）、窄窗 / 手机仍是底部弹层、桌面上确认框 600rpx → 400、
    手机上仍是 390/750*600；
  * `test/features/qr_login_test.dart`（新 4 条）：连上就问码、服务端 `ping` 也回
    同一句、`tokenLogin` 转 confirmed 并把数据交出去、断开转 failed；
  * `test/session/session_service_test.dart`（+2 条）：`applyQrLogin` 存 token /
    userInfo / 发 bindUid、推送缺字段时明确抛且不落半个登录态；
  * `test/features/desktop_login_test.dart`（新 4 条）：两栏（二维码落在右半边）、
    `qrurl` 真被画成 `QrImageView`、切回账号表单后连接关掉（`channel.closed`）、
    手机 390 宽仍是竖排那一版。
* **真服务端验证**（用 App 自己那条实现连生产）：
  `QrLoginSession(url: 'wss://message.gracelink.cc/wss')` → 拿到
  `https://message.gracelink.cc/scan/a/488bdd…%2BUW7A`（与网页端同一条
  `/scan/a/` 链接，手机扫一扫会认成站内链接 → 进确认页）。这条验证写成临时用例
  跑了一次，**跑完即删**（不留需要网络的用例）。
* `flutter build windows --release` 成功，Release exe 起得来（进程在、主窗口
  2400×1600 物理 = 1200×800 逻辑，与用例里那个尺寸一致）。

**这次没法做的**：实机**截图**走查。这台机器的桌面会话是锁着的（`full.ps1` 抓下来
1536×960 全黑，`shot.ps1` 的 `CopyFromScreen` 与 `pw2.ps1` 的
`PrintWindow(PW_RENDERFULLCONTENT)` 都只拿到空白面 —— Flutter 的 D3D 面在锁屏时
读不回来）。所以这轮的「实机」证据是：Release 包装上了、进程与窗口尺寸对、以及上面
那条真服务端的扫码链路；几何断言全部落在组件用例里（窗口正是 1200×800 逻辑，
与真窗口同一个尺寸）。**下次解锁后补一次截图走查**。

**手机端影响**：零。三条新形状分别挂在 `desktopWideLayout`（二级页 / 登录页）、
`desktopOverlayLayout`（弹层）后面；`showAppSheet` 在手机上就是原来的
`showModalBottomSheet`（连参数都照旧），新用例里各有一条「手机还是老样子」的钉子。

---

## S12.18 桌面：通话菜单锚回那颗钮 + 设置页两栏（2026-10-04）

**用户的两条**：
1. 聊天页点通话按钮，弹出的「语音通话 / 视频通话」菜单**跑到了窗口右下角**（用户截图：
   菜单悬在右下，而那颗摄像头图标在右上角）——「为什么在下面那里多奇怪啊，适配一下
   电脑UI」；
2. 设置页还是手机 UI（「不太符合电脑操作习惯，虽然比例已经对了」）。

### 一、通话菜单：锚错成了整页

根因在 `features/chat/chat_page.dart::_showCallMenu`：定位用的是
`context.findRenderObject()`，而这个 `context` 是 `ChatPage` **自己的 build context**
（`_buildNavBar → _desktopActions → onTap` 一路传下来的）。于是拿到的是**整页那块**
RenderBox，`showMenu` 的 `position` 就落在页面右中/右下 —— 菜单自然离那颗钮很远。
（`_PopupMenuRouteLayout.getPositionForChild`：菜单顶 = `position.top`，横向朝着空间大的
那一侧长；旧的 `Rect.fromPoints(centerRight, bottomRight)` 把菜单顶摆在了**页面竖向中点**。）

修法：
* `core/ui/desktop_overlay.dart` 新增 `appMenuPosition(context, {anchorKey, gap = 6})`：
  给的是**钮底边那一条零高矩形**，与
  `PopupMenuButton(position: PopupMenuPosition.under)` 内部那套算法同一个口径；顺带把
  「`showMenu` 的 position 语义」与「为什么不能用页面的 context」写进文档。
* `chat_page.dart`：State 上新增 `_callAnchor = GlobalKey(debugLabel: 'chatNavCallAnchor')`；
  `_navIcon(..., anchorKey:)` 用它把 `IconButton` 套一层 `KeyedSubtree` 当把手；
  `_showCallMenu` 改成 `position: appMenuPosition(context, anchorKey: _callAnchor)`。
  单聊的「语音/视频」与群里的「群通话」是同一个菜单，一起修好。

**实机（1200×800 逻辑）量出来的**：那颗钮（`chatNavCall`）在 x 1095–1143 / y 30–78，
菜单 x 1032–1142 / y 84–196 —— 菜单**右边与钮右边对齐**（1142 ≈ 1143）、
**顶边 = 钮底 + 6**（84 ≈ 78+6），两项文本在 y≈106–118 / 154–166。
截图：`build/s1218_callmenu.png`。

### 二、设置页：左分类 + 右内容

`features/mine/setting_page.dart` 由 `ConsumerWidget` 改成 `ConsumerStatefulWidget`：
* 手机 / 窄窗：`_phoneBody` —— 原来的「一列竖排分组」，一个像素没动；
* 桌面（`desktopWideLayout`，二级页在右栏那条路）：`_desktopBody` 在这条栏里再分两栏：
  * 顶上一条 `settingPaneHeader`（返回箭头 + 「设置」，灰底 + 下面一条细线）：手机那条
    居中 `AppBar` 是手指语言，摆进右栏就不像栏了；
  * 左列（宽 = `pane 宽 * 0.32`，夹在 96–176；底色 `navBar` 灰）：四个分类
    「账号 / 通用 / 功能 / 帮助与关于」（与手机那份分组同源），点一下右列换内容；
    选中那行白底 + 左边 3px 品牌绿细条；
  * 右列：那一类的行，复用 `MineListItem`（行高/字号/箭头仍与全站同一套）；
    手机版页面最底下那两块「切换账号 / 退出登录」并进「账号」这一类。
* 行数没变、i18n 没新增 key（`test/core/i18n_keys_test.dart` 那份 parity 照旧）。

**实机量出来的**：左列 x 570–750（选中行 x 567–570 是绿条）、右列 x 750–1190；
点「通用」后右列从「个人资料/账号与安全/切换账号/退出登录」换成「通知/界面与显示」，
左列选中格跟着从第 1 行挪到第 2 行。截图：`build/s1218_settings_account.png`、
`build/s1218_settings_general.png`。

### 用例

* `test/features/desktop_windows_test.dart`（+2 / 改 1）：
  * 新「宽窗设置：左列分类 + 右列那一类的内容」——分类竖排同一个 x、内容在分类右边且
    落在右栏里、默认选中「账号」、点第 2 类后右列换成通用那一类（还在同一个 x）；
  * 新「顶栏那颗通话：菜单挂在钮**下面**」——菜单文本顶边落在
    `[button.bottom, button.bottom + 48]`、横向上贴着那颗钮。**验过它能抓旧 bug**：
    把锚临时换回页面自己那块，这条立刻红；
  * 改「宽窗二级页：设置进右栏」——原来断言右栏里那条 `AppBar` 铺满，现在改成断言
    `settingPaneHeader`（并加一条「右栏里不该有手机 `AppBar`」）。
* 全量 `flutter test` **2003 项全过**；`dart format` 0 改动、`flutter analyze`
  No issues found；`flutter build windows --release` 成功。

**手机端影响**：零。通话菜单本来就只在桌面（`embedded`）那条路上有；设置页两栏挂在
`desktopWideLayout` 后面，窄窗 / 手机仍是原来那一列。

### 工具

`build/move.ps1 -To "x,y"`：把鼠标移到窗口内某个**逻辑点**但**不点击**（tap 之后
把鼠标挪开，好让 tooltip 收掉再截图 —— 鼠标停在钮上时那张「语音通话」的提示框会盖住
刚弹出的菜单）。

---

## S12.19 桌面：消息右键菜单（学微信 PC）+ 语音消息在 Windows 上真的能播（2026-10-04）

**用户的两条**：
1. 「撤回引用这些还是不符合电脑端UI设计啊，这是手机的习惯，你学一下微信」（截图：长按/右键
   自己的语音消息，弹出来的是手机那张**深色大卡片**：大图标 + 白字，占了半个聊天区）；
2. 「为啥我点这个语音消息放不了啊？你再检查一下，感觉很多细节上还是不太符合电脑操作习惯」。

### 一、消息菜单：桌面用微信 PC 那套**白底列表**

原来 `_showMenu` 只有一种形态 —— 微信手机那个**深色浮动卡片**（`menuDark`、白图标 + 白字、
一行 5 个、带指着气泡的小尖角），桌面右键（`onSecondaryTapDown`）弹的也是它。手机上是对的，
鼠标上就是手指的语言（瞄准难、挡内容、一行 5 个大图标）。

* 新增 `core/ui/app_context_menu.dart`：`AppMenuItem<T>` + `showAppContextMenu(context,
  globalPosition, items)` —— **在指针那儿弹一张白底小卡片，一行一项、无图标**。位置用指针那
  1×1 矩形（`showMenu` 的语义：菜单顶 = 矩形顶、横向朝着空间大的那一侧长，贴着窗口边也翻得
  回来），样式跟着 `popupMenuTheme`（白底/圆角 10/投影 6），字号与会话行那个右键菜单同一个口径。
* `features/chat/widgets/message_bubble.dart`：`_showMenu` 开头分形态 ——
  `desktopFeaturesFor(context)` 为真走白底列表（同一批 `MessageAction`、同一批文案），
  否则仍是原来那张深色卡片。右键与长按共用这一个入口。
* `features/conversations/conversation_list_page.dart`：会话行的右键菜单改走同一个构件
  （原来自己拼 `showMenu` + `_menuLabel`），全站只剩**一种**「右键菜单」。
* 动作集没变（`availableActions`），没新增 i18n key。

**实机（1200×800 逻辑）量出来的**（`build/s1219_msgmenu.png`）：右键那颗语音气泡（x 993–1111
/ y 548–600）→ 白卡片 x 941–1053 / y 574–686（3 项），**顶边 = 指针那一行、右边 = 指针那一列**，
文字色 `#333333`（与用例里断言的一致）。手机那套深色卡片不在桌面上出现了（用例钉着）。

### 二、语音消息「点了没反应」：Windows 上**根本没有音频插件**

根因不在播放器逻辑，而在**平台实现**：`windows/flutter/generated_plugin_registrant.cc` 里
一个音频插件都没有 —— `just_audio` 只实现了 Android / iOS / macOS / web / Linux，
Windows 得单独加一个实现；没有它时 `AudioPlayer.setUrl` 直接抛（MissingPluginException），
而 `VoicePlayerNotifier.toggle` 里那个 `catch` 只 `debugPrint('[语音] 播放失败')` —— **界面上
什么都不发生**，正是用户看到的「点不了」。

修法：`flutter pub add just_audio_windows_plus`（^0.5.3，WinRT MediaPlayer；选它而不是
`just_audio_windows` 0.2.3 的两个理由：① 0.2.3 是 C++17、在 VS2022 17.14/新 MSVC 上编译踩
STL1011；② 它会去抢系统媒体控制、与本项目已用的 `audio_service` 打架，plus 那版专门把它
让开了）。零配置：`flutter build windows` 后 `JustAudioWindowsPlusPlugin` 自动注册。

顺手把「看不清」的两处补上日志（原来失败是彻底静默的）：
* `startEngine`：`setUrl` 成功后打 `[语音] 开始播放：<url>（时长 <ms>）` —— **时长是引擎从远端
  读出来的**，有这行就说明真的挂上了源；
* `_onPlayerState`：播完打 `[语音] 播完：<url>` —— 「开始播放」有、「播完」不来，就是卡在半路。

**实机验证**（Release，`gracelinkim.exe` 的 stdout）：
```
[语音] 开始播放：https://message.gracelink.cc/storage/voice/2026-10-04/22/6ac24d3a7309e.m4a（时长 2367ms）
[语音] 播完：https://message.gracelink.cc/storage/voice/2026-10-04/22/6ac24d3a7309e.m4a
```
（点一下那颗 `3"` 气泡 → 挂载 2367ms 的 m4a → 播完。用户那条语音是别的端发的，服务端给的
是 `.m4a`，Media Foundation 直接吃。）

同一根因也压着**灵听**（音乐用的也是 `just_audio`）：插件补上后它应该也能在 Windows 上出声了
（`audio_service` 起不来会静默降级，见 `lingting_audio_handler.dart` 的注释）—— **这条我没在
实机上点歌验证**，只确认了插件注册与语音这条路。

### 三、这一轮顺手审的「电脑习惯」清单

| 已经是电脑习惯的 | 这一轮动没动 |
|---|---|
| 会话行右键 → 白底列表 | 只把实现收拢到同一个构件 |
| 聊天顶栏三颗图标的 tooltip、Enter 发送 / Shift+Enter 换行 | 没动 |
| 列表 hover 高亮、滚轮、滚动条、窗口最小尺寸 | 没动（Flutter 桌面默认就有） |
| 消息右键 → 白底列表 | **这轮新增** |
| 语音消息能点、能播 | **这轮修好** |

还**没做**的（列出来给用户挑，不是漏）：消息文本不能拖选复制（微信 PC 可以；我们右键有
「复制」，够用所以先没做 —— 拖选会和右键菜单抢手势）；窗口大小/位置不记忆（每次启动回到
1200×800 居中）；表情 / 「＋」面板是**内嵌**面板（与微信 PC 一致，不动）。

### 用例

* `test/features/chat_menu_test.dart`（+1，`pumpApp` 加 `desktop:` 开关）：桌面右键一条消息
  → 动作一个不少（撤回/复制/转发/引用/删除）、**白底列表**（深色卡片 `findsNothing`）、
  文字色是那档近黑、菜单顶 = 指针那一行（+ 菜单自己的 8 内边距）、菜单左边或右边落在指针上；
  再点「复制」验一次剪贴板。手机那条（深色卡片压在气泡上方）原样保留。
* 全量 `flutter test` **2004 项全过**；`dart format` 0 改动、`flutter analyze`
  No issues found；`flutter build windows --release` 成功。

**手机端影响**：只有消息菜单那一处按 `desktopFeaturesFor` 分形态（手机上仍是原来那张深色
卡片，用例钉着）；会话行菜单的标签字号与行高与原来完全一致（`rpx(31)` + `popupMenuTheme`）。

## S12.20 桌面：「我的收藏」里那颗「＋ 添加成员」不该有（2026-10-04）

用户：「我的收藏怎么可以添加成员呢？请修复！」—— 打开「我的收藏」的右栏信息面板，头上摆着一颗
虚线「＋」、下面写着「添加成员」，点下去进的是「发起群聊」的选人页。收藏里没有一个「人」，
谈不上拉人开群。

### 根因

`lib/features/chat/widgets/chat_info_panel.dart`：那颗钮的判据写的是 `if (!isGroup)`，而
`isGroup` 只代表 `conversation.isGroup == 1` —— **「不是群」全放行**。本项目的 `is_group`
语义是 **0 = 单聊 / 1 = 群 / 2 = 系统通知 / 3 = 我的收藏**，于是单聊（该有）、系统通知、
我的收藏（都不该有）一起被画了出来。

### 修法

* 新加 `final isSingle = conversation.isGroup == 0;`
* `_header(context, i18n, isSingle: isSingle)`（形参从 `isGroup` 改名 `isSingle`）
* 按钮判据 `if (isSingle)` —— 只有真单聊（一个人）才画那颗虚线「＋」；群拉人在整页的
  「聊天信息」里（宽 300 的侧栏摆不下成员网格，本来就不画）。

### 实机验证（Release，2026-10-04）

新工具 `build/ocr.ps1`：调 Windows 自带的 WinRT OCR（`Windows.Media.Ocr`，zh-Hans-CN）
读界面文字，输出「[x,y,WxH] 文字」——以前只能靠 ASCII 方框图猜文案，现在能直接断言
「这个词在不在」。「添加成员」这四个字 OCR 读得出来，所以下表的「读不到」是有意义的对照。

| 会话（is_group） | 右栏面板第一屏 OCR |
|---|---|
| 我的收藏（3，修复后） | 我的收藏 / 查找聊天记录 / 消息免打扰 / 置顶聊天 / 清空聊天记录 —— **全窗 0 处「员」字** |
| Gracelink Team（0，单聊，正面对照） | Gracelink.. / **添加成员** / 查找聊天记录 / 消息免打扰 / 置顶聊天 / 清空聊天记录 |
| 群聊（1） | 群聊 / 查找聊天记录 / … / 聊天信息 —— 也没有「添加成员」 |

截图：`build/s1220_panel_favorite.png`（收藏的面板）、`build/s1220_panel_single.png`（单聊的
面板，同一裁剪框）—— 两张并排，差的正好就是那颗钮。

### 用例

`test/features/desktop_windows_test.dart` 新增「右栏那颗『＋ 添加成员』只给真单聊」：先给单聊
断言 `chatInfoPanel-addMember` 在；再切到 `Conversation(id:'favorite', displayName:'我的收藏',
isGroup: 3, …)` 断言 `findsNothing`。**变异验证**：把判据 sed 回 `conversation.isGroup != 1`
→ 该用例立刻红（「收藏里不该有添加成员」），还原后绿。

全量 `flutter test` **2005 项全过**；`dart format` 0 改动、`flutter analyze` No issues found；
`flutter build windows --release` 成功（`data/app.so` 10:18 晚于源码改动）。

### 附：用户问「能不能像微信 PC 那样，文章在新窗口打开」（只回答，未动代码）

**能，有四条路，代价差得很远。** 关键背景：我们桌面上今天点外链走的是
`desktopFeaturesProvider → DesktopWebViewHost` 那条降级路（`webview_flutter` 没有 Windows
实现），也就是**在应用内那一页里放一颗「在浏览器中打开」**——真内容已经在系统浏览器里了，
只是要用户点一下。

| 路线 | 今天能不能用 | 代价 |
|---|---|---|
| ① 保持现状：丢系统浏览器 | ✅ 已实现 | 0。缺点：不是应用自己的窗口，没有应用内样式 |
| ② `desktop_webview_window ^0.3.0`（原生 WebView2 窗口） | ✅ stable 可用 | 小。**真·独立窗口**装 WebView2（Win11 自带，Win10 可能要预装/引导安装）；那一窗里只能是网页，塞不进我们的 Flutter 界面。最贴近「文章开新窗」 |
| ③ `webview_flutter_windows` 0.4.0（WebView2 接进 webview_flutter） | ✅ | 小-中。让桌面也有**应用内真网页**（现在是降级页），配「应用内可拖动浮层」= 假多窗口；要真窗口还得靠 ④ |
| ④ 真多窗口 | 官方 API 要 main 通道；社区插件 stable 可用 | 大。见下 |

④ 的两条子路：

* **官方 Desktop Windowing API**（Canonical + Google，2026-08-24 官方博客）：`WindowController`
  + `Window` widget、`runWidget` 起根，**所有窗口同一棵 widget 树** —— Riverpod / drift / WS
  都不用动，这是它最大的好处。但入口在 **main 通道**、藏在 `flutter config --enable-windowing`
  实验开关后面；我们这台机器上的 3.44.2 stable **框架代码已经带着**（`packages/flutter/
  lib/src/widgets/_window.dart`，90 KB），但 flutter_tools 的 `windowingFeature` 只给 master
  通道标了 `available: true`（`features.dart`）—— stable 上这个开关根本打不开。要用得换通道
  （`flutter channel main` + `flutter upgrade`），而且实验 API 会变。
* **社区 `desktop_multi_window ^0.3.1`**：stable 上今天就能跑（Windows ✅）。但**每个窗口一个
  独立 Flutter engine/isolate**：方法通道不共享，每个新窗口的插件都要手动注册（要在
  `windows/runner/flutter_window.cpp` 里挂 `DesktopMultiWindowSetWindowCreatedCallback` →
  逐个 engine `RegisterPlugins`），窗口间要自己搭 IPC（`WindowMethodChannel`）。对我们项目还有
  三处真麻烦：drift/SQLite 在两个 isolate 里各自开库与监听、WS 连接与登录态只在主引擎、
  `go_router` 路由表两份。

**建议**：先做 ②（或 ③ + 浮层）——「文章 / 外链单独一个窗口」是 90% 的诉求，②一天级就能上，
不碰任何状态；④ 留给「会话拖出来成独立窗口」这种真正需要多引擎的场景，等官方 API 进 stable。

## S12.21 桌面：修掉「一层套一层」+ 文章 / 灵听开**独立窗口**（2026-10-04）

用户拿着截图问：「群聊为什么是这样的？一层套一层干什么啊？三个点点击后就应该是显示
适配 UI 的详情层，为什么套了一层私聊的电脑 UI 的详情页点了之后又跳到手机 UI 的群详情
页？」—— 截图里是四个竖条：图标条 + 会话列 + 聊天区（被挤到 ~120 宽）+ 信息面板 +
那一整页手机版「聊天信息(3)」。

### 一、套娃的根因（两条叠在一起）

1. `lib/features/home/desktop_frame.dart::_messageBody`：**属于某个会话的二级页是在聊天区
   右边再接一栏**（420 宽）。1200 的窗口下：60 图标条 + 300 会话列 + 聊天 + 300 面板 +
   420 详情页 —— 聊天区只剩 120 宽。注释里当时写的理由（「微信 PC 就是这个形状」）站不住：
   微信 PC 里那一页是**换掉**聊天区的，不是在旁边再接一条。
2. `ChatInfoPanel` 里挂了一个「聊天信息」入口，点它 `context.push('/message/detail')`
   —— 推的正是那一整页**手机版**详情（自带 AppBar 与「聊天信息(3)」标题）。

### 二、修法

* `_messageBody`：二级页**铺满右栏**（`Expanded(child: _Pane(child: pane))`），删掉
  `paneSideWidth`；形状与其它分区的二级页一致：图标条 + 中栏 + 这一页。
* `ChatInfoPanel` 改成**一层薄壳**：按面板宽度（300）钉 `MediaQuery`，里面直接嵌
  `ChatInfoPage(embedded: true)` —— 面板自己就是「聊天信息」那份内容（成员网格、群聊名称、
  群二维码、群公告、群管理、查找聊天记录、免打扰 / 置顶、清空、退出群聊…全在栏里滚），
  **不再有「从面板再推一页」这条路**。手机那边整页的 `ChatInfoPage` 一个字节没改。
* 配套三处小改：`ChatInfoPage` 加 `embedded`（不画 `Scaffold` / 手机那条导航栏）与
  `onClearRecord`（桌面面板的「清空聊天记录」是**本机口径** —— 微信 PC 那一栏也是，删全体
  的入口在群资料里；`ChatPage._clearHistoryFromPanel` 原样保留）；
  `didUpdateWidget` 里换会话时清掉上一个群的成员 / 权限并重拉（面板是同一个 State 换
  `conversationId`，整页版每次都是新推的一页，没这个问题）；`chatInfoPanelProvider` 挪到
  面板文件里重新声明（原来那份随旧实现被删掉了）。

### 三、文章 / 灵听 → **独立窗口**（用户：如果能做多窗口就用新窗口打开）

新增 `lib/core/ui/desktop_windows.dart`：一套**应用内独立窗口**。

* `DesktopWindowSpec{ id, title, builder, size, offset }` + `desktopWindowsProvider`
  （同 id 只留一个窗口，再 open 就是抬到最前）；
* `DesktopWindowHost` 挂在 `MaterialApp.builder` 里（浮在所有页面 / 弹层之上，手机上是空的）；
* `_FloatingWindow`：标题条拖动（顺便抬到最前）、右下角把手缩放、右上角 ✕ 关，
  不出主窗口边界；
* `DesktopMiniApp`：窗口里那份**小 App**，自带一份 `GoRouter`（只挂传进来的那串路由），
  并且在这一支里把 `desktopFeaturesProvider` **关掉**（窗口里按手机版式排，
  `DesktopPageFrame` 原样返回 child，不会再套一层桌面外壳）；语言跟随主 App。
* 路由表**一份两用**：`app_router.dart` 里抽出 `newsRoutes()` / `lingtingRoutes()`，
  主 App 与窗口共用（不然窗口里的文章点进去就是 404）。
* 入口三处：`compass_page`（灵听）、`news_list_page::_open`（媒体号列表里的文章）、
  `chat_page` / `chat_record_page::_openNewsCard`（聊天里的资讯卡片）。
  资讯窗口从**列表**起手再推到文章上，所以窗口里那支返回箭头能回到列表。
* 判据统一 `desktopWideLayout(context, ref)`（开关 + 真实窗口宽 ≥ 900）：窄窗 / 手机照旧整页推。

**为什么先做应用内窗口而不是第二个 Flutter 引擎**（`desktop_multi_window` 那条）：第二引擎
要把登录态、drift 库、WS、插件注册都各来一份（窗口里的播放还得让 `audio_service` 别打架），
代价大一个量级；应用内这一版**不碰任何状态**，页面直接就能用，而且窗口里跑的就是主 App
那几张页面。真·OS 级窗口留作下一步（路线与代价见本文件 S12.20 附录）。

### 四、验证

* 用例：`test/features/desktop_windows_test.dart` **31 条全过**（新增 2 条：灵听从「发现」
  点开在独立窗口里、文章窗口能拖能关且主窗口不换页；改了 2 条：面板 = 聊天信息正文 /
  二级页把聊天区换掉不再加第 4 栏）。
* 全量 `flutter test` **2007 项全过**；`dart format` 0 改动；`flutter analyze` No issues found；
  `flutter build windows --release` 成功（`app.so` 11:18）。
* 实机：Release 起来后 stdout 干净（WS connected、灵听媒体会话就绪、无异常 / 溢出）。
  **截图走查这一轮没做成**：写这页时本机桌面是锁着的（`shot.ps1` / `pw2.ps1` 拿到的都是
  黑屏，OCR 零文字），解锁后补一次（要看的四处：群聊 ⋯ 面板里的成员网格、二级页换掉聊天区、
  灵听窗口、文章窗口）。

### 五、顺手记下的（没动）

* **外链**（第三方网页文章）仍然走「系统浏览器」那条降级路 —— 要真·WebView2 独立窗口
  （`desktop_webview_window`）是单独一件事，这轮没做；
* 真·OS 级独立窗口（能拖出主窗口、任务栏独立一项）= 第二颗 Flutter 引擎，见 S12.20 附录；
* 窗口大小 / 位置不记忆这条仍然没做（主窗口与这些独立窗口都一样）。

## S12.22 桌面：系统级多窗口 spike —— 「微信那种两个窗口」到底能不能做（2026-10-04）

用户带两张截图问：「我说的是微信这种，就是系统级别的两个窗口，不是应用内的窗口，能不能做到？」
—— 即 S12.21 那套**应用内浮窗**不是他要的。

### 结论：能做，stable 上今天就能做；「官方那套」打不开

* 官方 Desktop Windowing API（`WindowController` / `Window` widget，一颗引擎一棵 widget 树、
  零状态搬运）要求 `flutter config --enable-windowing`，而这个开关**只在 main 通道开放**：
  本机 `3.44.2 stable` 的 `flutter_tools/src/features.dart` 里 `windowingFeature` 只有
  `master: FeatureChannelSetting(available: true)`；**3.47.0（当前最新 stable）的同一文件也一样**，
  3.47 发布博客里 multi-window 仍写作「Experimental multi-window Progress」。
* stable 上可用的路 = **`desktop_multi_window ^0.3.1`**（mixin.dev，8 月底刚发的一版）：
  每个窗口一颗**独立 Flutter engine**，也就是真·Win32 顶层窗口。它的源码已经是新 C++ API
  （`FlutterDesktopViewGetHWND` / `PluginRegistrarManager`），本项目的 runner 也是新模板
  （`flutter_controller_`），README 那段补丁能原样贴。

### spike 怎么搭的（`lib/dev/desktop_window_spike.dart`，**临时**文件）

* `main(List<String> args)` 分流：带 `--gracelink-spike-window` 的进程只跑那颗小探针 App
  （不连 WS、不建 drift、不读聊天凭据）；带 `--gracelink-spike-auto` 时主窗口 3 秒后自动开子窗口。
* `windows/runner/flutter_window.cpp`：`DesktopMultiWindowSetWindowCreatedCallback` 里
  `RegisterPlugins(engine)` —— 插件不跨引擎，不注册的话子窗口里全是 MissingPluginException。
* 子窗口自己的窗口控制：runner 里一条 `gracelinkim/child_window` 通道
  （`setTitle` / `close` / `bounds`）—— 插件原生只给了 `window_show` / `window_hide`。

### 实测结果（Release 实机，stdout 见 `build/spike_run*.log`，窗口清单用 `build/wins.ps1`）

* **真·两个 OS 窗口**：同一进程里两个顶层窗口，类名 `FLUTTER_RUNNER_WIN32_WINDOW`（主）与
  `FLUTTER_MULTI_WINDOW_WIN32_WINDOW`（子），都是 `WS_OVERLAPPEDWINDOW=True`、`owner=0`、
  `taskbar/alt-tab=True` —— 原生标题栏、独立任务栏项、能 alt-tab、能被 `SetWindowPos`
  拖到主窗口范围之外（实测把它挪到主窗口右下角外侧）。子窗口默认 800×600、标题为空。
* **原生插件能用**：子引擎里 `url_launcher` 的 `canLaunchUrl` 返回 true。
* **本地存储跨引擎可读**：子窗口里 `SharedPreferences` 读到 15 个 key，含 `authToken`、
  `lingting.token` —— 灵听那套凭据在子窗口里拿得到（`LingtingStore` 只是包装 prefs）。
* **双向 IPC 通**：`WindowMethodChannel('gracelink/spike', bidirectional)` 两个方向都有回值
  （子→主 `child_ready`；主→子 `main_hello`）。
* **开销**：`WindowController.create()` 到子窗口就绪 < 0.6 秒；Dart 入口到首帧 6 ms；
  内存 +≈56 MB（单引擎 199.5 MB → 双引擎 255.6 MB）。
* **中文标题能设**：得拿**顶层**句柄 —— `view()->GetNativeWindow()` 是窗内那颗视图窗口，
  要先 `GetAncestor(..., GA_ROOT)`；不爬的时候 `SetWindowTextW` 返回 true 但标题栏还是空的（踩过）。

### 两个必须绕开的坑（都已在 runner 里处理）

1. **销毁子窗口会把整个进程带走**：点子窗口那颗 ✕ → 插件销毁窗口 → 拆引擎 → 进程直接没，
   且**不是**走消息循环退出（连循环后面那句日志都来不及打），Application 事件日志里也没有
   任何崩溃记录。处置：给子窗口注册 `RegisterTopLevelWindowProcDelegate`，`WM_CLOSE` 只
   `ShowWindow(SW_HIDE)` + 把 `window_close_requested` 发回 Dart —— 任务栏项/alt-tab 项随之消失，
   看上去就是关掉了；`WindowController.show()` 能把它叫回来。实测：✕ → `visible=False` →
   `show()` → `visible=True`，主程序全程活着、Dart 侧收到通知。
2. **主窗口关闭照旧退出**：`main.cpp` 的消息循环只忽略「主窗口还在、又不是它在关」的 `WM_QUIT`，
   另加一句循环结束日志，免得以后又踩。实测关主窗口进程正常退出。

### 下一轮（真实现）要做的事

* 子窗口里换成真内容：文章窗自己拉 `newsList`/`newsDetail`（只要网络，不依赖登录态）；
  灵听窗自己 `CredentialStore.init()` + `LingtingStore.init()`，**别起媒体会话**
  （`activeLingtingAudioHandler` 本来就可空，两个引擎抢会话没意义）；
* 删掉 S12.21 那套应用内浮窗（`lib/core/ui/desktop_windows.dart`、`desktop_window_specs.dart`、
  4 处入口、`test/features/desktop_windows_test.dart` 31 条）—— 用户已确认「真窗口跑通后删掉」；
* 窗口大小/位置记忆；子窗口标题接上真标题（spike 里已证明能设）。

### 这一轮加的验证工具（`build/`）

* `wins.ps1`：枚举本进程全部顶层窗口（类名/标题/rect/样式位/是否 owner/能不能进任务栏），
  可选 `-Move "序号,x,y[,w,h]"` 移动缩放某个窗口；
* `closewin.ps1 -Index N`：给第 N 个顶层窗口发 `WM_CLOSE`（等价于点 ✕，用来验关闭行为）；
* **坑**：PowerShell 5.1 把**无 BOM** 的 .ps1 按 GBK 读，脚本里的中文会把解析器带崩
  （报「字符串缺少终止符」）—— 这两个脚本都带 UTF-8 BOM 才是好的。
## S12.23 桌面：文章 / 灵听真的开成了**系统级独立窗口**（2026-10-04）

用户 2026-10-04 的原话：「微信这种，**系统级别的两个窗口**，不是应用内的窗口」。S12.21 做的
是主窗口 Stack 里套一层「假窗口」，这轮按 S12.22 spike 的结论把它换成**第二颗 Flutter 引擎
的真 Win32 顶层窗口**（类名 `FLUTTER_MULTI_WINDOW_WIN32_WINDOW`，有自己的任务栏项与
alt-tab 项），并把假窗口那套删干净。形态见 `build/two_windows_s1223.png`：主窗口 + 一个
叠在它上面的独立文章窗。

### 一、实现清单

**native（`windows/runner/`）**

* `flutter_window.cpp`：插件不跨引擎，`DesktopMultiWindowSetWindowCreatedCallback` 里给新引擎
  补 `RegisterPlugins(engine)`；
* 新通道 `gracelinkim/child_window`：`setTitle` / `setSize`（逻辑像素 × 该窗口 DPI）/ `center`
  （工作区居中）/ `show`（SW_SHOW + SetForegroundWindow）/ `close` / `bounds`。原生只给了
  `window_show` / `window_hide`，标题、尺寸、居中、关窗这几样都得自己出；
* `RegisterTopLevelWindowProcDelegate` 拦 `WM_CLOSE` → `ShowWindow(SW_HIDE)` + 回一条
  `window_close_requested` 给 Dart（真销毁会把整个进程带走，见 S12.22）；
* `main.cpp`：消息循环丢掉「主窗口还在、且不是主窗口在关」的 `WM_QUIT`；
  `flutter_window.h` 里 `IsMainWindowClosing()` 就是给这条判断用的。

**Dart（`lib/features/desktop_window/`，全是新文件）**

* `window_args.dart`：`DesktopWindowKind{article,lingting}` + `DesktopWindowArgs`
  （`toUri/encode/decode`，`gracelink://<kind>?id=..&title=..&card=<json>`）；坏卡片只当没有；
* `desktop_window_native.dart`：上面那条通道的封装（全部吞异常）；
* `child_window_app.dart`：子引擎入口 `runDesktopChildWindow(args)`（`CredentialStore.init()` +
  `LingtingStore.init()` + `AppI18n.load()`；`desktopFeaturesProvider` 覆盖成 false —— 子窗口里
  不能再开窗口）+ `DesktopChildRoot` 自带 GoRouter（复用 `newsRoutes()/lingtingRoutes()`，
  文章从 `newsList` 起手 push 详情、带 `card: widget.args.shared`）；IPC 线
  `gracelink/window/<kind>`，方法 `open_article`（在详情页就 `pushReplacement` 换文，否则 push）
  与 `ping`；
* `desktop_window_service.dart`：`DesktopWindowService` 抽象 + `desktopWindowServiceProvider`
  + `MultiWindowDesktopWindowService` —— **一个 kind 只开一颗**：`getAll()` 按解码出的参数找
  已有窗口（被 ✕ 藏起来的也在里面）→ `show()`（文章再走 IPC 换文）；找不到才
  `create(hiddenAtLaunch: true)`。失败只 `debugPrint`，开不出来不该把点它的动作带崩。

**入口（四处，都走服务、`unawaited`）**：`compass_page.dart`（灵听）、`news_list_page.dart::_open`、
`chat_page.dart::_openNewsCard`、`chat_record_page.dart::_openNewsCard`。窄窗 / 手机照旧整页推
（判断还是 `desktopWideLayout(context, ref)`）。

**删掉**：`lib/core/ui/desktop_windows.dart`、`lib/features/home/desktop_window_specs.dart`、
`lib/dev/desktop_window_spike.dart`（`lib/dev` 整个目录没了）；`app.dart` 去掉
`DesktopWindowHost`（Stack 还原成 DesktopShell 直包）。`news_card.dart` 顺手加了
`NewsCard.fromExt`（主窗口往子窗口递卡片用）。

### 二、实机验证（Release，2026-10-04 14:16–14:28，日志 `build/live_s1223b.log`）

逐条都是「点出来看」，不是只看日志：

* **灵听窗**：发现 → 灵听 → 真开出第二颗窗口。`wins.ps1`：
  `class=FLUTTER_MULTI_WINDOW_WIN32_WINDOW title='灵听' visible=True rect=(1016,212,2056,1612) size=1040x1400`
  （= 逻辑 520×700，工作区居中、标题中文、任务栏/alt-tab 都有）；OCR（`build/child_lingting_live.png`）
  读到 **歌曲 / 歌词** 两个 tab、**神的良善榮美**、**约书亚乐团**、`0:00 / 0:00` —— 页面真在跑，
  而且是真数据；
* **文章窗**：发现 → 媒体号 → 点第一条 → `wins.ps1` 多出
  `title='Java新闻汇总：新的OpenJDK JEP、CDI 5.0、Spring、Open Liberty、RefactorFirst和ADK for Kotlin'`
  的窗口，`size=1120x1440`（= 逻辑 560×720）；日志 `article 窗口就绪：title=… id=https://www.infoq.cn/article/KXmob0H9RXKmJxIlcAaA?...`；
  OCR（`build/child_article_live.png`）读到标题、`InfoQ 中文`、时间、**阅读原文**；
* **同 kind 只有一颗 + 换文**：先隐藏两颗子窗口，再点列表里第二篇 → 同一个 hwnd `2622134`
  变成 `visible=True`、标题换成第二篇（`GraalVM、Jakarta Data、JNoSQL、Azul Payara、WildFly、Quarkus、Atmosphere`），
  OCR 也换成了那篇 → 走的是 `show()` + IPC `open_article`，`开了` 计数没涨（日志里始终 2）；
* **✕ → 藏起来**：日志 `用户关掉了 lingting 窗口` + `lingting 窗口被藏起来了：{kind: lingting}`
  （两次，是用户在桌面上顺手关的）→ `visible=False`，进程照常活着；
* **再点 → 唤回**：藏起来之后（`hidechild.ps1` 复现同一个状态）点发现 → 灵听：
  `visible=True`、句柄还是 `329186`、日志**没有**新的 `开了 lingting 窗口` → 确认是
  「找到已有窗口 → `show()`」，不会叠第二颗引擎；
* 全程主窗口原地不动（位置、大小、页面都不变）。

### 三、这轮踩到的坑（都写进代码注释了）

1. **主窗口 topmost 会把自己的子窗口压住**：验证脚本（`tap.ps1`）会把主窗口设成
   `HWND_TOPMOST`，子窗口即使 `visible=True` 也被压在下面 —— 于是「截子窗口那块屏」截到的是
   主窗口的像素，一度以为子窗口没渲染。**排错时先看 z 序**；新脚本 `build/tap2.ps1` 改成
   按窗口类拿句柄、不设 topmost（多窗口下 `MainWindowHandle` 也会飘到子窗口上，点错地方）；
2. 顺序：子窗口 `_setup()` 里 **先 setTitle → setSize → center → show，最后才挂 IPC handler** ——
   挂线在前，`show()` 那一步会一直等（通道还没应）。
3. `desktop_multi_window` 没给「标题栏写中文」的入口：`view()->GetNativeWindow()` 拿到的是
   **视图内窗**，得先 `GetAncestor(..., GA_ROOT)` 才是顶层句柄（见 S12.22）。

### 四、用例

* `test/features/desktop_child_window_test.dart`（新，11 条）：参数编解码（中文 / 符号 / 卡片 /
  坏卡片）、`windowArgsOf` 扫进程参数、子窗口 `setTitle → setSize → center → show` 的顺序与参数、
  文章窗停在文章且列表在栈下、卡片渲染、灵听窗、✕ → `pause()` + IPC `window_hidden`；
* `test/features/desktop_windows_test.dart`：31 条（删掉旧的两条「应用内浮窗」用例，改成断言
  入口把活交给了替身 `_RecordingWindowService`：`lingting:灵听`、`article:n-1:朋友分享来的新闻:n-1`）；
* 全量 `flutter test`：**2018 条全过**（S12.22 时 2007 + 新 11），`dart format` 0 改动、
  `flutter analyze` No issues。

### 五、`build/` 里加着的验证工具

* `tap2.ps1`（按窗口类定位 → 点 → 截那张窗口，多窗口下才算得准）、`hidechild.ps1` /
  `raisechild.ps1` / `normz.ps1`（藏 / 抬 / 复位 z 序）、`fixwin.ps1`（还原被最小化的主窗口）、
  `poll.ps1`（盯 rect / IsIconic）、`wins.ps1`、`closewin.ps1`、`shot.ps1`、`full.ps1`、`ocr.ps1`。

### 六、留着的（这轮没做）

* 窗口位置 / 大小**不记忆**（每次居中；用户挪过就丢了）；
* 文章窗没有「在浏览器打开」/ 复制链接；
* 子窗口不跟随主窗口最小化 / 退出（主窗口退出＝整个进程退出，子窗口跟着走，够用）；
* 官方 Desktop Windowing API（stable 上还没开放，见 S12.22，将来可以评估迁移）。
## S12.24 桌面四问：灵听全屏变形 / 媒体号独立窗 / ✕ 真销毁 / 系统媒体控制（2026-10-04）

用户 2026-10-04 下午的四句话，四问四答，全在这一节：

1. 「灵听全屏后会变形」；
2. 「为啥我这看到的媒体号还是这样的不是独立窗口？」；
3. 「我把这种独立窗口关掉了怎么不是真的销毁了吗？怎么后台还在的吗？」；
4. 「还有灵听的音乐播放能不能让系统知道？」

四件事当天全部落地并**在真机上验过**（Debug + Release 各一遍）。

### 一、灵听全屏「变形」→ 内容不再跟着窗口拉伸

**现象**（用户截图：灵听窗最大化后进度条横贯全屏、标题字号巨大、卡片全变形）：这一页是按手机
竖屏写死的 `rpx` 布局，而 `context.rpx()` 的基准就是**窗口宽度** —— 窗口一宽，所有尺寸等比放大，
看起来就是「全屏后变形」。

**修法**：`lib/core/platform/desktop_shell.dart` 多一个 `contentMaxWidth`（默认 500 逻辑像素）：

* 内容板外面套一层「居中 + 定宽」的盒子，窗口再宽，内容板也只有这么宽；
* `desktopShellProvider`（`StateProvider<DesktopShell>`）给子窗口用：独立窗口的 builder 里包
  `DesktopShell(contentMaxWidth: 该窗默认宽度)` 并 `override` 掉，于是灵听窗最大化后内容仍是
  520 逻辑像素、居中——**和手机上看到的是同一张版式**；
* `desktopFrameActiveProvider` / `realWindowWidth` / `kDesktopFrameMinWidth=900` 一起把「宽窗走
  桌面版式、窄窗走路由版式」的判断收敛到一个地方。

**实机证据**：`build/rel_max3.png`（最大化后的播放页）——「歌曲 / 歌词」两个字贴在窗口中线附近
（物理 x≈1436 / 1598），进度条两端 0:00 与 4:26 在物理 x≈1116 与 1925，也就是**内容板仍是
中间的 520 逻辑像素**，没有横贯那颗 3098 物理像素宽的窗。

### 二、媒体号 → 独立窗口（和灵听同一套）

用户看到的还是旧行为（截图里媒体号开在主窗口右栏）。这轮把它接进 S12.23 那套多窗口：

* `DesktopWindowKind` 加 `news`，`DesktopWindowArgs.news`（只带标题，没有 id / 卡片）；
* `DesktopWindowService.openNews(title:)`：抽象、真实现（`DesktopWindowNative.open` +
  `_findAlive` 探活）、测试替身三份都补齐；
* `compass_page.dart` 的「媒体号」入口和灵听同一个判断：**桌面宽窗 → 开独立窗口**，
  手机 / 窄窗照旧整页推 `AppRoutes.newsList`；
* `child_window_app.dart` 里媒体号路由**复用主窗口那套 `newsRoutes()`**：列表 → 文章 → 卡片，
  全在子引擎里往下推（子引擎里桌面功能是关的，不会再套娃）；
* 尺寸 `_geometryOf(news) = 560×760`（比灵听窗宽一点，文章列表一行放得下标题）。

**实机证据**（Release，17:40）：点发现 → 媒体号 → 多出一颗**顶层窗**（类
`FLUTTER_MULTI_WINDOW_WIN32_WINDOW`、标题「媒体号」、rect 1120×1520 物理 = 560×760 逻辑、
有自己的任务栏项）；窗内点第一条文章 → 文章页在**这颗窗里**推（`build/b_news.png` 列表、
`build/b_news2.png` 已是 cnBeta 那篇文章的正文 + 阅读原文）。主窗口原地不动。

### 三、✕ 关独立窗口「后台还在」→ 两层根因，都已修

先分清两件事：**窗口藏起来**（S12.22 的 `WM_CLOSE → SW_HIDE`，进程活着、引擎不销毁）和
**窗口真销毁**（引擎拆掉、内存回落）。用户要的是后者，而且「后台还在」还叠了一个崩溃：
真去销毁引擎时进程会被插件带崩，看起来就更像「没关干净」。

**native 侧**（`windows/runner/flutter_window.cpp`）：`ChildWindowProcDelegate` 拦 `WM_CLOSE` →
转手给 helper 窗口 → `DestroyWindow`（GUI 线程外直接 `DestroyWindow` 会违反 Win32 规矩），
`WM_DESTROY` 里 `ReleaseMediaSession` 后照常让引擎拆；`main.cpp` 的消息循环把子窗口弹上来的
`WM_QUIT` 丢掉（原写法的返回值判断是死代码，见 `[窗口] 忽略一条子窗口带来的 WM_QUIT`）。

**Dart 侧**：`_findAlive` ping 探活（800ms）——插件那张窗口表不会清理（WER 里它自己崩在
`~JustAudioWindowsPlusPlugin`），所以「窗口还在不在」以 ping 为准，不认表。

**但真正的大头是插件里的 AV**（两层，全部由 PDB 符号化确诊）：

```
desktop_multi_window: Win32Window::WndProc → FlutterWindow::MessageHandler → OnDestroy
 → ~FlutterViewController → FlutterDesktopViewControllerDestroy → ~FlutterWindowsEngine
    → FlutterDesktopMessenger::SetEngine(nullptr)          ← 引擎先把 messenger 的 engine 摘空
    → PluginRegistrarManager::OnRegistrarDestroyed → ClearPlugins
       → ~JustAudioWindowsPlusPlugin                        ← 这时才拆插件
          → MethodChannel::SetMethodCallHandler(nullptr)
             → BinaryMessengerImpl::SetMessageHandler
                → FlutterDesktopMessengerSetCallback → messenger->engine == nullptr
                   → 读偏移 0x1e8 → c0000005 AV @ flutter_windows.dll+0x14f37
```

* **第一层**：插件自己的析构里那句反注册（`just_audio_windows_plus_plugin.cpp`）。空闲状态关窗
  就崩在这里。
* **第二层**：`player.hpp` 里还有两处同类反注册 —— `AudioPlayer::Dispose()` 的
  `player_channel_->SetMethodCallHandler(nullptr)` 与 `~JustAudioEventSink()` 的
  `messenger_->SetMessageHandler(id_, nullptr)`。**播放中关窗**崩在这里
  （`~JustAudioWindowsPlusPlugin → AudioPlayer::Dispose → MethodChannel::SetMethodCallHandler`）。
  上游 0.5.3（最新）没有任何版本修过它。

**修法：vendored 到 `third_party/just_audio_windows_plus/`**（`pubspec.yaml` 改 path 依赖，
`pubspec.lock` 变成 path source），两处都改成「**引擎拆插件时跳过反注册、正常运行时照旧**」：
插件析构先把每个 player 标成 `PrepareForEngineTeardown()`，之后 `Dispose()` 与两个事件 sink 的
析构都不再碰通道 —— 注册表马上跟着引擎一起没，跳过没有任何后果；而**运行时**（Dart 主动
`disposePlayer`）标志是 false，反注册照旧，不留悬着的 handler（事件 sink 的 handler 是裸
`this` 捕获，留着真会 UAF）。

**实机证据**（Release，17:35）：灵听窗 `status=Playing`（SMTC 里 `pause=True`）→ 给那颗窗
`WM_CLOSE` → 进程活着、内存 313MB→269MB、stderr 一路走完
`开始销毁子窗口 → 子窗口收到 WM_DESTROY → 释放媒体会话（找到/IsEnabled(false)/PlaybackStatus/
controls 置空/channel 置空）→ 系统媒体会话已释放 → 子窗口销毁返回（进程还活着）`、
`crash_stack.txt` 时间戳没动；Debug 同样跑了一遍（1.28GB→997MB，同样走完）。空闲关窗、关主窗口
（`[窗口] 消息循环结束（主窗口关闭）`、进程正常退出）也各验了一遍。

### 四、灵听播放 → 让系统知道（SMTC）

`audio_service` 在 Windows 上**没有实现**（包里只有 android/darwin/web），手机那份通知栏在桌面
上一直是空的；桌面这份由 runner 出的原生通道 `gracelinkim/media_session` 接手
（`SystemMediaTransportControls` + `windowsapp.lib`）：

* native（`flutter_window.cpp`）：`MediaSession / EnsureMediaSession / RegisterMediaSessionChannel`
  —— `update`（标题/歌手/专辑/封面/时长/进度/播放态）/ `clear`；按钮回调 → 反向通道
  `media_button`（play / pause / next / previous）；`ButtonName` / `Utf8ToUtf16` 两个小工具；
  会话按窗口挂在 `g_media_session_channels` 里，窗口销毁时 `ReleaseMediaSession` 完整收掉
  （`IsEnabled(false)` → `PlaybackStatus` → controls/channel 置空）；
* Dart（`lib/core/platform/system_media_session.dart`，新）：`bind()` 把系统那几颗键接回
  `LingtingPlayerNotifier`（和通知栏走同一套逻辑），`update()/clear()` 只在**关键节点**推
  （切歌 / 播放暂停 / 拖动 / 时长 / 队列变化），进度由系统按 `updatePosition + speed` 自己插值
  —— 每帧推会把卡片刷成电灯泡；
* `lingting_player.dart` 的 `_syncSession()` 现在**双推**：手机那份 `audio_service` + 桌面
  这份 SMTC（子引擎里前者可能不存在，两边都容错）。

**实机证据**：系统会话列表出现 `app=gracelinkim.exe`，`title=难忘的救赎 / artist=于永旺 /
album=偶遇的清泉 / end=4:26`，点播后 `status=Playing`；按键盘那颗播放暂停键 → 日志
`[灵听] 系统那颗键：play`、SMTC `Playing → Paused` 跟着变（上一轮观察到的「一次按键发
pause+play 两条事件」这轮没有再复现，留一眼看着）；关窗时会话完整释放，列表里那条消失。

### 五、这轮踩到的坑 / 新工具（都写进注释了）

1. **PDB + DIA 才是能看清 native 崩溃的路**：`build/diaprobe/`（`probe.cpp` + `build.cmd`，
   `cl /utf-8 /EHsc ... diaguids.lib oleaut32.lib`）读 `flutter_windows.dll.pdb` /
   插件 PDB，把 `RVA → 函数名`；配合 `build/stackmap.sh` / `symbstack.sh` 才有上面那条
   `+0x14f37 = FlutterDesktopMessengerSetCallback` 的结论。没有 PDB 的话，那串地址什么都说明
   不了。
2. **`std::cout` 重定向到文件是全缓冲**：日志不落盘，排查时像「代码没跑」——关键日志改用
   `std::cerr`（`[窗口] …` 那一串）。
3. **Freebuff 前台时，抢前台点击/截图全会失灵**：`tap2.ps1` / `shot.ps1` 会 `SetForegroundWindow`
   + 移光标，点到别的窗上；换成 `build/postap.ps1`（`PostMessage` 直发 FLUTTERVIEW，不抢前台）
   + `build/shot3.ps1`（按类/标题找窗、`SWP_NOACTIVATE` 置顶、CopyFromScreen、完事撤销）。
   这轮又加了 `build/closetitle.ps1`（按**标题**给某颗子窗发 `WM_CLOSE`，`closechild.ps1` 只能按
   序号）。
4. **debug 专用 VEH 崩溃栈**（`main.cpp`，`#ifndef NDEBUG`）：只处理致命码，全用 Win32 文件 API
   （`std::ofstream` 会卡死），写 `crash_stack.txt`（模块表 + rip/rsp + 512 槽栈）。MSVC 的
   「线程命名」异常（`0x406d1388`）无害，不能收。
5. **PowerShell 5.1 读无 BOM 的 .ps1 按 GBK**：中文脚本必须带 UTF-8 BOM，否则解析器直接崩。

### 六、用例与验证

* `test/features/desktop_child_window_test.dart` 13 条（新增媒体号窗：参数编解码、路由、
  `_geometryOf`）、`test/lingting/lingting_player_test.dart` +4 条（SMTC 的 update/clear/
  media_button，用 mock 通道 `gracelinkim/media_session`）；
* 全量 `flutter test`：**2025 条全过**（改 path 依赖之后也重跑过）、`dart format lib test`
  0 改动、`flutter analyze` No issues；`flutter build windows --release` 与 `--debug` 都是
  patched 插件（Debug `just_audio_windows_plus_plugin.dll` 17:13、Release 17:29）。

### 七、留着的（这轮没做）

* 系统那张卡片的**封面**只推了 URL（没走 `RandomAccessStreamReference` 下载），任务栏上可能是
  空白图；
* 媒体键在极少数时序下可能收到两条事件（这轮没复现，先记着）；
* 子窗口位置/大小仍不记忆；媒体号的列表窗没有「在浏览器打开」；
* `build/shot.html` 还是 S12.23 那版（这轮的证据图是 `rel_max3.png` / `b_news.png` /
  `b_news2.png`，没再拼进 HTML）。
---

## S12.25 桌面网页窗：外链进真 webview，开成独立窗口（2026-10-04）

用户这一轮两条，一条 bug、一条需求：

* 「媒体号变成独立窗口打开之后，点『阅读原文』就如图所示这样」（= Page Not Found）；
* 「我发现你现在软件里是没有 webview 还是怎样，为什么好像都要将链接从浏览器打开，
  不能像微信电脑端一样做一个 webview 吗？如果可以，请把 webview 网页的窗口也独立窗口打开」。

### 一、那条 404：外链那三页只挂在主 App 那张表上

「阅读原文」走 `openChatLink`（`core/ui/link_opener.dart`）：第三方站点先推
`/mine/linkConfirm`（「第三方网址，是否继续访问」那道闸门）。而独立窗口那颗引擎的
路由表当时只挂了 `newsRoutes()` 那两条 —— 闸门页在子引擎里**根本不存在**，
go_router 于是画了 errorBuilder 那一页，用户看到的正是
`GoException: no routes for location: /mine/linkConfirm?url=...`。

修法与资讯/灵听那两张表同一条规矩（一份表两处用）：

* `externalLinkRoutes()`：内嵌浏览器 + 两道闸门（`/mine/webview`、`/mine/linkBlocked`、
  `/mine/linkConfirm`），主 App 与每扇子窗共用；
* `webRoutes()`：网页窗自己那一张（就内嵌浏览器一页）。

### 二、Windows 上真 webview：`webview_flutter_windows`（WebView2）

* 依赖 `webview_flutter_windows`（`webview_windows` 0.4.0 的维护分支）：把 WebView2
  离屏渲染成 Flutter **Texture** 贴进 widget 树，所以多窗口（每扇窗一颗引擎）各有各的
  纹理；要求 Flutter 3.44+ / Dart 3.12+，与本仓正好对上。构建期用 NuGet 拉 WebView2
  SDK（本机没装 nuget.exe，插件自己从 dist.nuget.org 取 v7.6.0，实测能下）。
* 新实现 `WindowsWebViewHost`（`core/platform/webview_host.dart`）：起不来（机器没装
  WebView2 运行时、插件报错）就**不白屏也不崩**，退回原来那张「此页面由系统浏览器打开」
  的降级页。
* 分流判据改成**平台**（`Platform.isWindows` → WebView2；macOS / Linux → 降级页；
  安卓 / iOS → `webview_flutter`）：不能再用 `desktopFeaturesProvider` —— 子窗口里那个
  开关是关的（窗口里按手机版式排），可网页窗照样得用 Windows 那一支，用手机那支的
  `WebViewController` 在 Windows 上只要建就抛「WebViewPlatform.instance is not set」。

### 三、网页窗（`DesktopWindowKind.web`）

* 尺寸 1000×720，标题栏写域名（微信 PC 那扇浏览器窗也是这么写的）；**不套**
  `DesktopShell` 那条宽度封顶（它装的就是一页网页，不是手机版式）；
* 一个 kind 一扇窗：已经开着就抬起来 + `open_url` IPC 让它自己换地址（不叠第二扇）；
* 网页窗里那一页靠 `webWindowHostProvider` 认出「自己已经在网页窗里了」，
  不会再套一扇（否则自己套自己）。

### 四、外链去哪儿：`desktopLinkWindowProvider` + `openExternalLinkWindow()`

* `features/desktop_window/desktop_link_window.dart`：单独一个文件，避开
  `link_opener.dart` ↔ `app_router.dart` 那圈 import 环；
* 生产桌面为真、测试里为假（那批用例钉的是「推了哪条路由」），**子窗自己那颗引擎
  显式改真**（窗里点外链照样开成另一扇窗）；
* 三处入口都接了：`openChatLink` 的官方站点直进、确认页「继续访问」（顺手把自己
  `maybePop` 掉，回到点链接之前那页）、以及 `/mine/webview` 这一页本身 ——
  别的入口（我的 → 用户协议那类）推进来时也把网址交给网页窗。
  最后一处不只是口味问题，见下面坑 2：**主窗口自己占掉那条线程上唯一的名额，
  网页窗就再也起不来**。

### 五、三个坑（都是实机撞出来的）

1. **双向通道 ping 不通 → 一个 kind 会叠两扇窗**。`WindowMethodChannel` 的双向模式
   只允许「成对的两个引擎」互调，而调用方（主窗口 / 另一位子窗）从没注册过这条通道，
   于是 `_findAlive` 的 ping 一律回 `CHANNEL_UNREGISTERED`，每次都当「那颗窗已经关了」。
   这条从 S12.22 就潜伏着（关窗真销毁之后更明显）。改成
   `ChannelMode.unidirectional`（谁都能调、只有装得上手的那一颗能注册）——
   实测连点两次「媒体号」只有一扇窗，网页窗也一样复用。
2. **WebView2 插件每线程只允许一个 DispatcherQueueController**。
   `MultiWindowManager::Create` 是在**调用方线程**上建引擎并注册插件的，而
   `webview_platform.cc` 的构造里要建一个 `DQTYPE_THREAD_CURRENT` 的 DispatcherQueue ——
   同一条线程上的第二颗引擎会失败（日志就一句 `Creating DispatcherQueueController failed.`），
   `IsSupported()` 于是为假，Dart 侧收到 `unsupported_platform`。
   结论：桌面上**同一时刻只有一扇窗装得下 webview**，所以「网页只进网页窗」是硬约束。
3. **关网页窗把整个进程带走**。崩溃栈 `exception_address = flutter_windows.dll+0x14f37`，
   符号化后调用链是
   `~WebviewBridge → MethodChannel::SetMethodCallHandler(nullptr) → BinaryMessengerImpl::SetMessageHandler`
   —— 引擎拆的时候 messenger 的 engine 先被摘空，插件这时候去反注册通道就是 AV。
   与 S12.24 的 just_audio 同一个坑，修法也一样：**vendored 到
   `third_party/webview_flutter_windows/`**（pubspec 改 path 依赖），插件析构先给每颗
   bridge 打一声「引擎在拆了」，`~WebviewBridge` 那条路上跳过通道反注册与纹理反注册
   （正常路径 —— Dart 主动 dispose 一个 webview —— 照旧反注册，不然已销毁的 bridge
   还会被调用到）。

### 六、用例与验证

* 新增 `test/features/desktop_web_window_test.dart` 8 条：web 参数编解码、域名标题、
  **媒体号窗里点「阅读原文」不再 404 且确认后交给网页窗**、确认页两条去处、
  `/mine/webview` 那一页的转交与「已经在网页窗里就不再套」、官方站点直进；
* `desktop_windows_test.dart` 那条「桌面 → 降级页」改成按平台断言（Windows 现在是
  `WindowsWebViewHost`）；
* 全量 `flutter test`：**2033 条全过**、`dart format lib test` 0 改动、
  `flutter analyze` No issues、`flutter build windows --release` / `--debug` 都过；
* 实机（release，2026-10-04 晚）：
  * 发现 → 媒体号：连点两次只有一扇窗（复用生效）；
  * 媒体号窗里 文章 → 阅读原文 → **第三方确认页正常显示**（不再 404）→ 继续访问 →
    网页窗开出（标题 `www.ithome.com`、1000×720、任务栏单独一项），窗里 WebView2 真把
    ithome / cnbeta 的页面画出来（OCR 到导航条与正文）；
  * 已有网页窗时再点外链：窗口数不变（同一扇窗换地址）；
  * ✕ 关网页窗：进程活着（402MB→379MB），日志走完「开始销毁子窗口 → 子窗口收到
    WM_DESTROY → 子窗口销毁返回（进程还活着）」；
  * 关掉之后重新开一扇：WebView2 照样起来（err 里没有 `unsupported_platform`），
    页面正常渲染。

### 七、留着的（这轮没做）

* 一扇网页窗只开一页（第二条外链是**换地址**，不是新标签页）；
* macOS / Linux 仍是「系统浏览器」那张降级页（没有可用的 webview 实现）；
* 网页里的弹窗 / 下载这类边角按插件默认策略，没逐项调；
* 受坑 2 所限，主窗口里不再内嵌 webview（`/mine/webview` 一律转给网页窗）。

## S12.26 网页窗多标签 + 桌面通话真机自检（2026-10-04 晚）

### 一、这轮的两件事

用户原话：「电脑端通话现在是啥情况能做吗？还有你说的多标签做上呗」。

* **网页窗多标签**：S12.25 那扇网页窗只有一页 —— 第二条外链是把这一页**换地址**
  （`open_url` 里 `router.go`），看上一条时点下一条就把它顶掉了。这轮做成真标签页。
* **桌面通话**：之前只是「查过代码」（无桌面拦截、`flutter_webrtc` 的 Windows 实现已编入、
  没人验过），这轮把它跑出结论。

### 二、多标签怎么做的

* 新增 `features/desktop_window/web_tabs.dart`：`WebTab`（id / url / title / pageTitle）
  + `WebTabsController`（`ChangeNotifier`，每扇网页窗一份，不挂 provider、窗口之间不串）：
  * **同址去重**：同一条地址点了两遍不叠第二个、切过去（不然点几下就多出几条各自占一份
    WebView2 的标签）；
  * **关当前那个**：右邻顶上来，右边没有了退回左邻（与浏览器同一个手感）；
  * **关完一个不剩**：controller 只把自己清空，「窗要不要跟着关」由界面定；
  * 网页报了自己标题（`<title>`）就把它换上去，不用一直顶着域名。
* 新增 `features/desktop_window/desktop_web_window.dart`：顶上标签栏（一条 180 宽、能横滚、
  带 ✕ 与 tooltip）+ 下面 `IndexedStack`：
  * 每个标签的 webview **一直挂在树上**（没轮到的那几页只是不画出来），所以切回来不重新
    加载、滚动位置与页面里的状态都还在 —— 这就是「真标签页」与「同一个浏览器换地址」的区别；
  * 原生标题栏（任务栏那一项）跟着**当前标签**走；
  * **关掉最后一个标签 = 关掉这扇窗**（走 `DesktopWindowNative.close()`，与用户点 ✕ 同一条路：
    native 真销毁，引擎一起释放）。
* `child_window_app.dart`：web 那一支不再走 `webRoutes()`（那张表删了，`app_router.dart` 里
  只剩 `externalLinkRoutes()` 等三张共用表），改成一条路由摆 `DesktopWebWindow`；
  `open_url` 从「`router.go` 换地址」改成 `_tabs.open(url, title)`（新开一个标签）；
  `ping` 回的是**当前标签**那行字，不再是开窗时那一条。
* `core/platform/webview_host.dart`：`build()` 多一个可选 `onTitle`（页面标题上报）。只有
  Windows 那支实现（订阅插件的 `WebviewController.title` 那条流），其余实现忽略 —— 手机 /
  降级页那两份签名一样、行为不变。
* i18n：7 份语言包各加一条 `webview.closeTab`（关闭标签页 / 關閉分頁 / Close tab / タブを閉じる /
  Tab schließen / Cerrar pestaña / Fermer l'onglet）。
* **关键发现**（把 S12.25 的坑 2 说清楚）：那个「每线程只允许一个 DispatcherQueueController」
  的坑是**每颗引擎**的事 —— 插件是每颗引擎一份 `WebviewWindowsPlugin`，平台对象里建 DQC；
  而**同一颗引擎里**的第二个 `WebviewController` 共用同一份 `WebviewPlatform`（DQC）与同一个
  `WebviewHost`（CoreWebView2 环境是引用计数的），插件的 `instances_` 本来就是一张表。所以
  「一扇窗里开多个 webview」可行，多标签不必退化成单 webview 换 URL。

### 三、用例与验证

* `test/features/desktop_web_window_test.dart` 新增「网页窗多标签」7 条：3 条标签规矩
  （同址去重、关当前竖右邻/退左邻/关完为空、标题替换）+ 4 条把网页窗这颗引擎摆起来的
  （开窗先一条标签且 native 顺序不变、`open_url` 变第二个标签且**上一页还挂在树上**、
  原生标题跟着当前标签、同址再点不叠、点标签条来回切、✕ 关当前另一个顶上来且窗不关、
  关最后一个叫 native `close`）；
* 新增真机自检 `integration_test/web_tabs_smoke_test.dart`（**这轮唯一的技术风险点**）：
  同一颗引擎里两颗 WebView2 同时 initialize + 同时真加载两个站点 →
  `[SMOKE] tabs two WebView2 initialized`、`titles A=cnBeta.COM - 中文业界资讯站 B=IT之家`、
  `both disposed`（两颗都起得来、都真加载完、都干净关掉、没崩）；
* 全量 `flutter test`：**2040 条全过**（S12.25 是 2033，+7）；`dart format lib test` 0 改动；
  `flutter analyze` No issues；`flutter build windows --release` 过、产物比源码新；
* 真机上没做的那半段：写这一版时机器进了**锁屏**（前台窗口就是 Windows 锁屏界面，抓屏
  只能抓到锁屏壁纸与 20:05 的时钟、连唤醒都只亮一下），所以「标签条长什么样、点两条外链
  出两个标签、点 ✕ 关最后一个窗跟着关」这几步的**肉眼**确认还没做 —— 逻辑层（上面 7 条）
  与平台层（上面那条自检）都已验。

### 四、桌面通话：能到什么程度（这轮跑出来的结论）

`integration_test/call_media_smoke_test.dart` 四条在 Windows 真机上**全过**
（flutter_webrtc；Release 目录里 `flutter_webrtc_plugin.dll` + `libwebrtc.dll` 都在）：

* `mode=raw`：只取麦克风 → `raw OK tracks=1`；
* `mode=minimal`：公共 STUN + `createPeerConnection` + 取麦（真通话走的就是这两步）→
  `minimal OK tracks=1`、干净关闭；
* `mode=site`：**站点真实 ICE 配置**（`stun.cloudflare.com:3478`，没有账号密码那份）→
  `site OK tracks=1`；
* `mode=video`：公共 STUN + 摄像头 → `video OK tracks=2`（音频 + 视频都拿得到）。

即：**桌面通话的媒体层是通的**（这台机器有摄像头、麦克风；建连接、取流、关闭全过）。
代码侧也**没有任何桌面专用拦截**：入口 `chat_page.dart` 的 `chatNavCall` 只按
`canCall = conversation != null && isGroup == 0 && id != 自己 && webrtcEnabled` 判断；
通话页在 `_desktopPage` 那套里是**刻意不包**的（沉浸式全屏，`app_router.dart` 注释里写着）。
还**没验**的是 UI 与信令那一层：通话页 / 来电页 / 群通话页在桌面上的样子与交互、
以及两端真通话（要两台设备 + 对端）。要补的话优先级是「先两端真通话（自检里再加一条
带信令的）」→「再看 UI」。

### 五、留着的（这轮没做）

* 标签**拖拽排序 / 中键关闭 / 右键菜单（复制链接等）**没做；
* 标签不持久化（关窗即忘）—— 微信 PC 那扇浏览器窗也是关窗即忘；
* macOS / Linux 仍是「系统浏览器」那张降级页（没有可用的 webview 实现）；
* 上面第四节里通话 UI / 两端真通话那两条。
## S12.27 通话：独立窗口 + 电脑版式 + 一通电话里不许再发起第二通（2026-10-04）

用户这一轮三句话（截图里通话页整个炸开：三颗钮铺满全屏、挂断钮压在用户名上）：

1. 「通话这个 UI 现在属于完全乱套的情况，整个变形」→ **改成电脑适配的，学习微信电脑端**；
2. 「请将通话做到新开一个独立窗口」；
3. 「如果已经在一个通话里要禁止发起第二个通话」。

### 一、桌面版式（`lib/features/call/call_desktop_page.dart`，新文件）

根因：那一版尺寸全是 `context.rpx(...)`（750rpx = 屏宽），桌面窗口一宽就等比放大
—— 三颗钮铺满整屏、挂断钮盖到名字上。这一版**一个 rpx 都不用**：头像 112、名字 22、
圆钮 56、挂断 60，窗口多大都这套；版式照微信 PC 的通话窗：上面是对方的画面/头像，
底部一条控制栏（麦克风 / 摄像头 / 挂断），**不画「扬声器」那颗**（桌面就是外放，
没有听筒那回事），屏幕共享没实现也不画。

入口两处：桌面兜底页（`call_page.dart::_desktopBody`）与通话窗
（`call_window.dart`）。`CallDesktopPage` 不认识控制器、不碰 Riverpod ——
状态与两路流由调用方递进来，按钮只回调。

⚠️ 判据的坑：`call_page.dart` 里这条分支**不能**用 `isDesktopRuntime` —— 组件测试
就跑在桌面宿主机上（它为真），而那批用例钉的是手机版式（「扬声器已开」、小窗、
共享屏幕……），一刀切过去整批变红（真跑过：`flutter test` 里 30+ 条桌面用例全红）。
用 `desktopFeaturesProvider`（测试里默认关）。

### 二、独立窗口（`DesktopWindowKind.call`）

`MediaStream`（以及它背后那份原生 `RTCPeerConnection`）**过不了引擎边界**，所以
媒体引擎必须搬到拿画面的那颗引擎里 —— 也就是通话窗。这条链于是切成两半：

```
 主窗口（状态机 / WS 信令 / 通话记录）          通话窗（第二颗引擎）
 ├ CallMachine + CallController      ──状态──▶  界面（call_desktop_page）
 ├ CallWindowMediaEngine（代理）      ──媒体指令─▶ WebrtcCallMediaEngine（真引擎）
 └ CallHost（宿主）                    ◀─媒体事件／界面动作─
```

* 两条线：`gracelink/window/call`（主→子：`ping` / `state` / `media` / `bye`）与
  `gracelink/call/events`（子→主：`media_event` / `action`），都是
  `ChannelMode.unidirectional`（理由同 S12.25 那条：双向模式只认「成对的两个引擎」，
  而调用方从来不是那一对）；
* 窗口参数（`DesktopWindowArgs.call`）带上对端 id/名字/头像、语音还是视频、谁发起，
  以及**算好的 ICE 列表**（子引擎里没有会话配置，自己算不出来）；
* **ICE 要等 TURN 凭据**（服务端签发的短时凭据，主窗口拿）：先算完再 `plan`，
  少一档 TURN 在有些网络里直接打不通；
* 子引擎冷启动那几百毫秒里那条线还没挂上（`CHANNEL_UNREGISTERED`）：媒体指令
  **重试到 15 秒封顶、绝不重开窗**（重开会留下一颗没人管的引擎）；窗口那条线
  挂上之后会自己伸手要一次状态（`ready`）—— 被叫那一屏没有计时器，全靠主窗口
  主动推是推不到的；
* **兜底**：窗口起不来（原生建不出引擎 / 起太慢）→ 代理退回「就在主窗口里建一份
  真引擎」，`degraded` 为真，界面回到主窗口那张页 —— **一通电话不会因为一扇窗
  开不出来而打不出去**；
* 挂断：主窗口说 `bye`，**窗口自己关**（关窗只有窗口自己做得干净）。

⚠️ 一条通道在单向模式下只允许一颗引擎注册：`DesktopChildRoot` 那套通用处理
（open_article/ping/open_url）原本也挂在 `gracelink/window/call` 上，两边都注册的话
**先到的那个赢**，主窗口的媒体指令会全部落到那个不认识 `media` 的处理上。所以
`child_window_app.dart` 里通话这一支**让开**，那条线归页面自己
（`call_window.dart`）管。

### 三、一通电话里不许再发起第二通

状态机里本来就拦（老端那三道检查），但它的文案是「其他终端正在通话中」——
本地自己拨第二通时对不上号。所以三处入口提前拦下、统一提示
`group.callBusy`（「你正在通话中，请先挂断」）：

* `chat_page.dart` 顶栏那颗通话：`callBusyProvider` 为真就直接提示、不开菜单；
* `chat_page.dart::_startCall`（输入区那颗 + 通话卡片回拨都走它）；
* 群通话入口（1:1 通话中不给进，与群资料页那个入口同一个口径）。

### 四、验证

* 组件/单测：全量 **2059 条全过**（本轮 +14：`test/features/call_window_test.dart`
  —— 窗口参数编解码、状态编解码、媒体代理（转发/事件/家底/**兜底退回**）、
  通话窗那一页（第一屏来自参数、推状态就变、点挂断把动作送回主窗口）、
  传输层（假原生：冷启动重试、只开一颗窗、挂断说再见、一直叫不应就抛））；
  `test/features/call_desktop_test.dart` 另 5 条（1200 宽下圆钮还是 56、计时/名字/状态、
  来电两颗钮、视频大小窗、桌面标签栏与 #EDEDED 那套外观逐像素核对）；
* `dart format` 0 改动、`flutter analyze` No issues；
* 媒体层真机自检（`integration_test/call_media_smoke_test.dart`，本轮之前那条）：
  `raw` / `minimal` / `site` / `video` 四条在 Windows 上全过；
* ⚠️ **通话窗没能在真机上自检**：`flutter test integration_test/... -d windows` 的
  入口点会被子引擎继承 —— 子引擎跑的是**测试那个 `main`**（不是 `lib/main.dart`），
  于是它既不注册通道也不画界面。实测对照：连早就验过的**文章窗**在同一个自检里也
  `CHANNEL_UNREGISTERED`（`[SMOKE] 对照：文章窗 1 → 2，叫应=false`）。结论：窗口类
  功能只能跑真 App 验（真 App 里子引擎跑的才是 `main()`）；另外这台机器当时屏幕
  是锁着的，鼠标走查也做不了。**真机走查（点一通电话 → 通话窗弹出 → 挂断窗自己关）
  留待解锁后补**。

### 五、留着的

* 通话窗里右键要诊断面板没接（面板是主窗口那套，要 controller + 一个主窗口 overlay）；
* 用户 ✕ 关掉通话窗 = 那条媒体链路断了（主窗口会退化成兜底页），没有「关窗=挂断」；
* macOS / Linux 同一条路（`desktop_multi_window` 三平台都支持），但只在本机 Windows 上验过。

**补记（同一轮，收尾时把结论钉死）**：子引擎为什么连一行日志都没有 ——
`flutter test -d windows` 给 `--target` 那个入口包了一层 `flutter_test_listener.dart`，
它先跟测试宿主握手，而子引擎里那一步永远等不到，于是**我们的 `main` 压根不执行**
（试过在测试入口里认窗口参数再走 `runDesktopChildWindow`：同样是拿不到机会）。
所以窗口类功能的自检只能跑真 App；通道那一层改由「假原生」契约测试盯着
（`test/features/call_window_test.dart` 的「传输层（假原生）：开窗、重试、关窗」两条：
真机那两条通道全 mock，钉住开窗参数、冷启动重试、**只开一颗窗**、挂断说 `bye`、
一直叫不应就抛给代理退回本引擎）。`integration_test/call_window_smoke_test.dart`
留成 `skip` 的证据与配方。
## S12.28 通话窗真机走查：揪出并修掉四个 bug（2026-10-05）

S12.27 只做到「写得出来」，真机走查一直没做（当时屏幕锁着）。这一轮补上了：
**桌面通话在真机上从头到尾走通**（点通话 → 独立通话窗弹出 → 对方接听 →
`阶段=connected` → 挂断 → 窗自己关、主窗口活着），并揪出四个 bug，全已修。

### 一、走查方式（记下来，以后还要用）

* 屏幕 1536×960 逻辑（物理 3072×1920，dpr=2）；主窗口 1200×800 逻辑、
  位置 (168,56) 逻辑 / (336,112) 物理。
* 坐标换算：`shot3` 抓出来的 PNG 是**物理像素**，÷2 就是 `postap.ps1 -Points`
  要的「窗口相对」逻辑坐标。实测：会话列表第一行 `(200,114)`、顶栏通话钮
  `(1124,56)`、菜单里「视频通话」`(1076,162)`；通话窗挂断钮：语音 `(270,537)`、
  视频 `(420,617)`。
* 顶栏那三颗图标（搜索/通话/⋯）靠 `build/scan_dark.ps1` 扫暗像素列定位
  （列中心 2153 / 2232 / 2314 物理）。
* **锁屏也能验一大半**：`wins.ps1`（列窗口）与 `postap.ps1`（PostMessage 点击）
  在锁屏/黑屏下照常工作，日志也读得到 —— 所以「窗弹没弹、窗自己关没关、有没有
  退化成兜底页」这一组光看 `rel_s1225_out.log` 里那几个固定字串就能判。
* ⚠️ `shot3`（CopyFromScreen）与 `shot4`（PrintWindow）在锁屏下发不出内容
  （全黑 / 全白），别拿它们当「界面坏了」的证据 —— 这一轮就先误判过一次。
* ⚠️ 别往锁屏上乱发键：敲一下空格会推到**安全桌面**的登录页，那时
  `OpenInputDesktop` 不再可达，所有脚本一起失效（真踩了）。

### 二、四个 bug

**① 桌面「切换扬声器」抛错 → 整通电话退回主窗口，通话窗只剩空壳**

`Helper.setSpeakerphoneOn` 在 Windows 上必抛 `MissingPluginException`（插件只在
Apple / Android 那份原生里接了 `enableSpeakerphone`）。独立通话窗里这颗钮一抛错，
主窗口那条媒体通道把它当成「窗口没应答」，重试满 15 秒后
`CallWindowMediaEngine.degraded = true` —— 界面又回主窗口、通话窗变成一具没人管
的空壳，白开一扇窗。

修：`call_media_engine.dart` 与 `sfu_local_media.dart` 把
`MissingPluginException` 当成功（桌面这一档本来就等于外放）。

**② 一条指令失败 = 空转 15 秒 + 整通电话判死**

`MultiWindowCallWindowTransport.invokeMedia` 把「子引擎冷启动叫不应」与「窗口回了话、
但这条指令失败」混成同一个异常，一律重试到预算耗尽。修：新增
`isCallWindowUnreachable()` 与 `CallWindowCommandFailed`，**只在叫不应时才重试**；
媒体代理也只在叫不应时才退回本引擎，业务失败原样抛给控制器（控制器本来就有失败处理）。

**③ 占位流的非空 getter 返回 null → 视频渲染器初始化炸**

主窗口那份「只回答流到了没」的 `_WindowOnlyStream` 靠 `noSuchMethod` 兜底，但
`MediaStream.id` / `ownerTag` 是**非空 `String`**（`getTracks()` 那一族是非空
`List`），隐式转换拿到 null 就炸 `type 'Null' is not a subtype of type 'String'`。
真机上表现为：兜底页放视频时画面只剩一块黑底，日志一行
`[通话] 视频渲染器初始化失败`（异常被 `CallVideoView` 自己吞了）。修：那几个非空
getter 给真值。

**④ 挂断时释放「对方那一路」必失败**

Dart 的 `MediaStreamNative.dispose()` 只传 `streamId`，C++ 的 `MediaStreamDispose`
却要拿 `ownerTag` 才肯去连接里找 —— 拿不到就只查
`FlutterWebRTCBase::local_streams_`（里面只有**本机**流，见
`flutter_media_stream.cc` 的两处 `local_streams_[uuid] = stream`），于是对方那一路
永远「not found」。每通接过对方流的电话，挂断都留一条
`释放媒体流失败：PlatformException(MediaStreamDisposeFailed, stream [xxx] not found!)`。
修：`close()` 不再释放 `_remote`（它归 `PeerConnection`，紧跟的
`pc.close()/dispose()` 一并收掉），只放本机的 `_display` / `_local`；
顺手把 `close()` 改成「先摘引用再释放」，两条路同时叫到时第二条拿到 null（幂等）。

### 三、验证

* `dart format` 0 changed、`flutter analyze` No issues；
* `flutter test` **2061 全过**（S12.27 基线 2059，+2：`call_window_test.dart`
  新增「窗口回了话但这条指令失败 → 不重试」「业务失败不退回主窗口」两条）；
* `flutter build windows --release` 通过，并且能在 `app.so` 里 grep 到这一版新增的
  字串（确认编进去的确实是新代码，不是缓存）；
* **真机（release，视频通话）**：`[窗口] call 窗口就绪：title=test1` →
  `生成 offer` → `应用对方 answer` → `本机挂断（阶段=connected）` →
  通话窗从 `wins.ps1` 里消失、主窗口还在。下面五条**计数全 0**
  （修之前 ①②③ 各出现 ≥1 次；④ 特殊 —— 要等①②修好、通话**真的接通**之后
  才露出来，接通那一通里 =1）：
  `退回主窗口里的引擎` / `视频渲染器初始化失败` / `一直没送到` /
  `设置音频路由失败` / `释放媒体流失败`。
* 版式（解锁后抓图复核）：语音窗 420×620、视频窗 600×700（逻辑），底部控制栏
  56 圆钮、间距 36 —— 视频挂断钮实测落在逻辑 x=420，与代码里
  `84×3 + 36×2 = 324` 居中算出来的完全一致；S12.27 之前那张「三颗巨大圆钮铺满屏」
  的现象没有再出现。

### 四、留着的

* 通话窗里右键要诊断面板仍没接（面板是主窗口那套，要 controller + 一个主窗口 overlay）；
* 用户 ✕ 关掉通话窗 = 那条媒体链路断（主窗口退化成兜底页），没有「关窗=挂断」；
* 走查过程中机器自己锁了屏，**版式那一项只能解锁看**；本轮的界面证据靠
  「S12.27 的离线证据图 + 本轮坐标/字串核验」两段拼起来。

## S12.29 通话代码整体复查（P0/P1 修复）+ 真机走查揪出的新 P0：✕ 会把整个 app 干掉（2026-10-05）

用户这一轮只说了一句：「再整体检查一下通话的所有代码看看有没有细节Bug」。于是先把
整个通话那条线通读完、报一份 P0/P1 清单，用户选了「全修 P0 + P1」。修完做真机走查
时又撞出一个**比清单上任何一条都严重**的问题（✕ 让整个进程 abort），一并修了。

### 一、复查：核过没问题的

* 媒体引擎接口（`call_media_engine.dart` 的 `CallMediaEngine`）**13 个方法**在通话窗
  那条 `call_window.dart::_onMedia` 里一条不缺（逐条对过：open / createOffer /
  acceptOffer / applyAnswer / addIceCandidate / setMicrophoneEnabled /
  setCameraEnabled / toggleCamera / setSpeakerEnabled /
  requestScreenSharePermission / startScreenShare / stopScreenShare /
  sampleStats / close）；
* 四条通道（`gracelink/window/call` / `gracelink/call/events` /
  `gracelinkim/child_window` / `mixin.one/desktop_multi_window/channels`）的编解码对
  **缺字段 / 未知阶段**是安全的（`callViewStateFrom` 认不出当 idle、
  `callSamplePayload` 认不出当空采样，都不会抛）；
* i18n：这一轮用到的键（`call.waitingAnswer` / `call.micOnState` /
  `call.cameraOnState` / `call.incomingVideo` …）**七个语言文件全有**；
* 群通话（`group_call_controller.dart` / `sfu_local_media.dart`）通读一遍，没有
  确定的问题，**一行没动**。

### 二、P0（会真出画面 / 真卡住）

1. **退回兜底之后，那颗开不起来的通话窗不关**：代理退回本引擎（`degraded`）之后
   `_windowOpen`/`_spec` 还留着，主窗摆了一张通话页、通话窗也在 —— 两份界面。
2. **✕ 关掉通话窗 = 空转 15 秒后整通电话搬回主窗**：`alive()` 写了但**生产零调用**，
   「叫不应」这一件事在代码里只有一条路 —— 重试到预算（15 秒）用完、然后判死退回本引擎。
3. **登出 / 换账号不收通话窗**：控制器一换（登录态变了）那颗窗里的电话已经作废，却
   还开着，成了一块显示着上一通电话的僵尸窗。

### 三、P1

* `_fallback?.supportsScreenShare ?? _supportsScreenShare` —— 一旦建过兜底引擎，
  子窗那份家底**永远**作废（`??` 只在 null 时兜底，不是「用哪一份」）；
* `hasLocalVideo` 永远是 false 且**全仓无人读**；
* 挂断之后残余的媒体指令白等 2 秒（`_ensureOpen` 里那句写死的 2 秒）；
* 被叫那一通，窗口可能晚 4 秒才出现（`_plan` 先 await TURN 凭据，最长 4 秒）；
* `call_desktop_page.dart` 视频通话点一下画面：`_peerInfo` 的条件是 `!_controls`，
  与压暗层的 `showControls` **相反**（收起控制栏时名字冒出来、压暗却消失）；
* 通话窗右键 → 诊断面板只 `debugPrint`（没接上主窗口那张面板）；
* `_WindowOnlyStream` 漏 `getMediaTracks()`（`MediaStream` 上的非空成员，靠
  `noSuchMethod` 兜不住）。

### 四、这一轮改了什么（5 个源文件 + 3 个测试文件）

* `call_window_host.dart`：新增 `CallWindowLost` 与 `_everAnswered`（`_create()` 清回
  false、`closeWindow()` 刻意不清）；`invokeMedia` 里「答过话之后叫不应 → 先 `alive()`
  确认 → 立刻认输」那一段（**超时不算**：子引擎忙起来也会超时，误判会把一通好电话挂掉）；
  `_ensureOpen` 里那句写死的 2 秒改成与重试同一个预算（`plan()` 算 ICE 最长 4 秒）；
  `alive()` 补文档。
* `call_window_media_engine.dart`：新增 `onWindowLost`；`CallWindowLost` 不再退回本地
  引擎（交给宿主收尾）；三个家底 getter 与 `sampleStats()` 改按 `_degraded` 判据；
  `_WindowOnlyStream` 补 `getMediaTracks()`。
* `call_host.dart`：`onWindowLost → 挂断收尾`；退化的窗不再 `plan` 第二扇；`diagnostics`
  动作真的弹主窗口那张面板；控制器一换就把上一通那颗窗收掉。
* `call_window.dart`：家底**报两次**（拿媒体之后 `hasLocalVideo` / ICE 列表才是真的）；
  见下第五节的 ✕ 收摊。
* `call_desktop_page.dart`：`_peerInfo` 与压暗层同判据（`showControls`）。
* 测试：`call_window_test.dart`（✕ 收摊的顺序、bye 不插手）、`call_page_test.dart`
  （主窗口弹诊断面板）、`call_desktop_test.dart`（视频接通时名字/计时都在）。

### 五、⚠️ 真机走查揪出的新 P0：✕ 把整个 app 干掉

修完上面那些去真机走查（屏幕锁着，用 PostMessage 那条路），**两次实测**在通话中按 ✕
（`closetitle.ps1` 发 WM_CLOSE，与用户点 ✕ 同一条消息）：

* 事件日志：`17:33:09 gracelinkim.exe / flutter_windows.dll / 0xc0000409`、
  `17:36:26 gracelinkim.exe / ucrtbase.dll / 0xc0000409` —— **abort，整个进程没了**；
* stderr（GBK，`iconv` 解回来）最后几行：

```
[窗口] 开始销毁子窗口            ← 原来的 ✕ ＝ 立刻 DestroyWindow
[窗口] 子窗口收到 WM_DESTROY
… rtc_peerconnection_impl.cc: RTCPeerConnectionImpl::Close
… webrtc_voice_engine.cc: WebRtcVoiceEngine::Terminate
… audio_device_impl.cc: AudioDeviceModuleImpl::Terminate     ← 到这儿就没了
（崩溃；`[窗口] 子窗口销毁返回（进程还活着）` 那行**没打出来**）
```

**根因**：通话窗里那颗 webrtc 媒体引擎还活着的时候拆那颗引擎 —— 插件在引擎销毁时去
拆音频设备（ADM），在那条路上 abort。对照实验（同一版、同一通电话）：**点窗里那颗
「挂断」**（先 `engine.close()` 放媒体、再关窗）一路正常，stderr 里
`AudioDeviceWindowsCore::~AudioDeviceWindowsCore` → `AudioDeviceBuffer::~dtor` →
`[窗口] 子窗口销毁返回（进程还活着）` 全都在。也就是**顺序问题：先放媒体，再拆引擎**。

**修法**（`windows/runner/flutter_window.cpp` + `desktop_window_native.dart` +
`call_window.dart`）：

* WM_CLOSE 不再直接销毁：先顺着 HWND 找这扇窗那条 `gracelinkim/child_window` 通道，
  `InvokeMethod("close_requested")` 问 Dart 一声（答完 `return 0` 把消息吃掉）；
  Dart 那边没接这一手（**文章窗 / 网页窗**，它们没有要收的活）或回话里报错，就照
  **老路**（消息窗转一手 → DestroyWindow）直接销毁，行为与 S12.22～S12.25 一模一样；
* 通话窗接了：`✕ → ①请主窗口按挂断收尾（它会发信令、记通话记录）→ ②
  `engine.close()` 把媒体放干净（3 秒封顶）→ ③才叫 `close` 让原生拆`；
  收摊过程中主窗口那句 `bye` 到了**不插手**（`_closing` 那道闸），不然就是在「媒体
  还在拆」的时候把引擎拆了；
* 又按一下 ✕（双击）：**也等着**，不再「不等 Dart 直接销毁」—— 那时候 Dart 的收摊
  可能还在半路，拆下去照样 abort；
* `close` 那条方法不能再回头 `PostMessage(WM_CLOSE)`（那条现在会先问 Dart，两边会
  你问我我问你转不完），改成直接走销毁那一手。

**验证**（release，锁屏下）：

* 单击 ✕（语音通话、拨号中）：`[窗口] 关闭请求：先问 Dart 收不收摊` → webrtc 先放干净
  → `[窗口] 开始销毁子窗口` → `[窗口] 子窗口销毁返回（进程还活着）`；主窗口日志
  `[通话] 本机挂断（阶段=outgoing）` → `otherOpt 902` → `通话结束：902`，
  通话窗从 `wins.ps1` 里消失、主窗口还在（进程 pid 没变）、事件日志**没有新的崩溃**；
* 连发两次 ✕（间隔 120ms）：第二次那时窗已经销毁（`ok=False`），同样不崩；
* ⚠️ 「第二下 ✕ 落在收摊半路」那一支是**按构造**安全（分支就是忽略 + 记一行），
  真机没撞上（间隔 120ms 那次的第二下已经没窗可发，5ms 那次对方正好拒接、窗已经关了）。

### 六、验证

* `dart format` 0 changed、`flutter analyze` No issues；
* `flutter test` **2070 条全过**（复查这一轮新增 3 条：✕ 收摊的顺序、bye 不插手、
  主窗口弹诊断面板）；
* `flutter build windows --release` 通过；并且核过编进去的是新代码：
  `gracelinkim.exe` 里有新字串 `关闭请求：先问`（GBK 编码，见下面的坑）、
  `data/app.so` 里有 `close_requested`；
* 真机走查（锁屏下用 PostMessage 那条路，同 S12.28）：✕ 与双击 ✕ 都验过（见上）；
  诊断面板那条由组件用例钉住（`窗里点「诊断」：面板弹在**主窗口**`）—— 真机上
  右键那一下要等解锁再看。

### 七、这一轮的坑（记下来）

* **C++ 字符串里别写 `✕`（U+2715）**：`/W4` 把「通用字符名在当前代码页（936）表示不出来」
  当错（C4566 → error C2220），构建直接失败 —— 注释里写没事，日志字串里写就炸；
* 原生那几行日志是 **GBK** 编出来的（源码里的中文字面量按 936 走），
  `grep` UTF-8 中文匹配不到，要 `iconv -f gbk -t utf-8` 解一下才看得顺；
* 锁屏下能用的工具：`wins.ps1` / `postap.ps1`（PostMessage 点击）/ `closetitle.ps1`
  （WM_CLOSE）/ 新加的 `doubleclose.ps1`（连发 WM_CLOSE，模拟双击 ✕）/ `evlog.ps1`
  （事件日志里翻崩溃 + WER 目录）/ `pxmap.ps1`（ASCII 亮度图）；`shot3/shot4`
  在锁屏下全黑/全白，**别当界面证据**；
* 奔溃证据链要看三处：`rel_s1225_err.log`（原生 stderr，含我们那几行 `[窗口]`）、
  `build/rel_s1225_exit.txt`（退出码）、事件日志 `Application Error`（异常代码 +
  哪个 dll + 偏移）。这一次是「`[窗口] 子窗口销毁返回` 没打出来」+ `0xc0000409` 两处
  对上的。

## S12.30 桌面共享屏幕（电脑端也能共享了）+「全屏后有点变形」这一条（2026-10-05）

用户这一轮问三件事：① 电脑端视频通话的共享屏幕能不能做；② 现在通话全屏后有点变形；
③ 电脑的画中画能不能做。选了「先做共享屏幕 + 顺手修全屏比例」，**画中画这一轮没做**
（做法见下面第六节）。

### 一、核过的插件事实（为什么「桌面共享」本来就差一步）

* `flutter_webrtc 1.6.2+hotfix.3` 的 **Windows 原生就带桌面捕获**：
  `common/cpp/src/flutter_screen_capture.cc`（`GetDesktopSources` /
  `GetDisplayMedia` / `GetDesktopSourceThumbnail` / `UpdateDesktopSources`），
  Windows 的 `CMakeLists.txt` 把这份源码编进去了 —— 所以
  `navigator.mediaDevices.getDisplayMedia()` 在 Windows 上是能用的；
* `GetDisplayMedia` 认的参数：`video -> deviceId -> exact` = 要共享的那个源的 id，
  **不给就用默认源（主屏）**；另外认 `video.mandatory.frameRate`（默认 30fps）与
  `video.cursor`（`always`/`never`，默认带光标）。源 id 是字符串，本机实测屏幕那块是
  `"0"`，窗口那块是窗口句柄（如 `"459138"`）；
* 源列表来自 `desktopCapturer.getSources()`（`SourceType.Screen` / `SourceType.Window`），
  屏幕那类的名字是**英文**的（`Screen 1`），窗口那类就是窗口标题；
* **Windows 这份 `GetDesktopSources` 还没填 `thumbnail` 字段**（源码里挂着
  `// TODO "thumbnailSize"`）—— 面板里那一栏实际是灰底占位块（代码本来就按
  「没有缩略图就画灰块」写的，不是 bug）；
* 我们的媒体层（`startScreenShare` / `stopScreenShare`：`replaceTrack` 换轨、不重协商
  SDP）**本来就不是安卓专属**，只是被 `supportsScreenShare => Platform.isAndroid`
  与「界面不画那颗钮」挡在门外。

### 二、这一轮改了什么（10 个源文件、其中 1 个是新的 + 7 个语言文件 + 4 个测试文件 + 1 份真机自检）

* `call_media_engine.dart`：`supportsScreenShare` 放开到
  Windows / macOS / Linux；`requestScreenSharePermission()` 在 Windows/Linux
  直接返回 true（插件那个 `Helper.requestCapturePermission` 只接了 Android/macOS，
  别的平台会抛）；`startScreenShare({String? sourceId})` 把 `deviceId.exact` 带下去；
* **新 `screen_share_picker.dart`**：点了先弹「整个屏幕 / 某个窗口」面板
  （`showAppSheet` + 源列表）。三条口径：取消 = 什么都不做；读不到列表 = 按系统默认源走
  （不弹空面板）；`null`（默认源）与「用户取消」是两件事；
* `call_desktop_page.dart`：视频通话 + 平台支持时多画一颗「共享屏幕 / 停止共享」；
  控制栏从 `Row` 换成 **`Wrap`**（视频通话加上这颗是四颗：4×84 + 3×36 = 444，
  420 宽的通话窗盛不下 —— 组件测试直接抓到 `RenderFlex overflowed by 24 pixels`）；
* 动作链：`CallDesktopActions.startScreenShare(sourceId)` → 通话窗
  `_action('screenShare', {'sourceId': …})` → 主窗口 `_onWindowAction` →
  `controller.toggleScreenShare(sourceId:)` → 媒体层。为此 `CallWindowSink.onAction`
  加了第二个参数（这一下的附件）；
* `call_window_bridge.dart`：状态报文里**补 `canShareScreen`** —— 漏了这个字段，
  通话窗那颗钮永远不画（那颗窗只能看到 state payload，拿不到主窗口的 `CallViewState`）；
* i18n：七个语言文件加 `call.sharePickScreen`（「整个屏幕」/「Entire screen」…）。

### 三、「通话全屏后有点变形」

* 先把账算清：`cover` 不是拉伸而是**裁切**（`RTCVideoView` 内部按原生上报的宽高算
  `SizedBox`，外面那层 `FittedBox` 是等比缩放）——桌面窗口的宽高比与镜头画面差得远时，
  铺满的代价就是「裁掉一大块」，脸只露中间一条，看着就像被拉宽/拉窄；
* 所以桌面这一版：大窗**默认 `contain`**（完整放，四周黑边 —— 微信 PC 的通话窗也是
  这个口径），**双击大窗切 `cover`**（想要铺满的观感时自己切）；本机在共享屏幕时那块
  一律 `contain`（屏幕裁掉一边就是真丢信息，与群通话那条注释同一个理）；
* 手机那一版（`call_page.dart`）**一行没动**：竖屏窗口的比例与镜头画面接近，
  铺满是对的。

### 四、真机自检（新 `integration_test/screen_share_smoke_test.dart`，2026-10-05 本机 4/4 过）

「电脑上能不能共享屏幕」这件事只有这台机器说了算（组件测试里那条通道永远是假原生），
所以按 `call_media_smoke_test.dart` 那套写了一份桌面自检：

```
flutter test integration_test/screen_share_smoke_test.dart -d windows
```

实测日志（本机 3072×1920 单屏）：

* 源列表 3 个：`SourceType.Screen id=0 name=Screen 1`、两个窗口
  （`Freebuff Desktop` / `Cua.AgentCursorOverlay.default`），**缩略图都是 0 字节**
  （见第一节那条 TODO）；
* 按**屏幕** id 取流 ✔（采 3 秒仍在采）、按**窗口** id 取流 ✔、**不给源**（默认源）✔。

它只验原生「取屏幕流」那条路；通话里那一套（换轨、停止共享换回摄像头、对端看到什么）
由这一轮补的 8 条组件用例 + 两台设备对拨验。

### 五、验证

* `dart format` 0 changed、`flutter analyze` No issues；
* `flutter test` **2078 条全过**（这一轮 +8：桌面页 5 条 —— 默认 contain 与双击切、
  画共享钮、不支持时不画、共享中变「停止共享」、共享时本机那块 contain；
  通话窗 2 条 —— 「共享屏幕」这一下带着 sourceId 回主窗口、canShareScreen 为 false
  时不画；控制器 1 条 —— 选中的源原样透传给媒体层）；
* `flutter build windows --release` 通过；核过产物里是新代码：
  `data/app.so` 有 `startScreenShare` / `sharePickScreen`，
  `data/flutter_assets/assets/i18n/*.json` 里有新键；
* 真机：上面那份自检 4/4；（通话内那一段要两台设备/两个账号在场时对拨走一次）。

### 六、还没做 / 下一轮

* **画中画（置顶小窗）没做**（用户这轮没选它）。做法已核：给通话窗加一条 `setPip` ——
  去边框与标题栏 + `WS_EX_TOOLWINDOW`（不进任务栏/alt-tab）+ `HWND_TOPMOST`（置顶）+
  约 240×180、`WM_NCHITTEST → HTCAPTION`（按着画面就能拖），Dart 侧给
  `CallDesktopPage` 一份紧凑版式（只留画面 + 挂断）；现有 `CallPip` 抽象不动，
  另开一份桌面实现。真做的时候要注意：置顶窗被系统「显示桌面」/全屏应用挡住是正常的，
  Windows 上 `SetWindowPos` 置顶会与 `desktop_multi_window` 的生命周期管理交错，得走原生；
* **1:1 没有「对方在共享屏幕」的信令**：对方从手机共享屏幕时，PC 这头只能靠「默认
  contain / 双击切」看全；要做成「自动切换到 contain + 提示一句」，得在信令里加一条
  （老端也没有，属于协议层的新东西）；
* 真机对拨一遍：对方那头看到什么、停止共享能不能换回摄像头、共享时「摄像头/翻转」
  两颗是灰的、以及共享**窗口**时对方看到的是那个窗口（本机自检只验到取流）。

### 七、这一轮的坑

* **组件测试里 `MissingPluginException` 要等真事件循环**：`flutter test` 跑在
  flutter_tester 上，平台消息的回话走真异步 —— 「点共享屏幕 → 什么也没发生」那条用例
  一开始就是这么失败的（`debugPrint` 探明回调确实被调了，只是 `getSources` 的回话还没到）。
  修法是给 `FlutterWebRTC.Method` 装个**假原生**（`initialize` 回 null、其余抛
  `MissingPluginException`），回话就在假时钟里完成，不用 `runAsync`；
* `ThumbnailSize` / `DesktopCapturerSource` **都不是 const 构造**：
  `const ThumbnailSize(160, 90)` 直接被 `flutter analyze` 拦住（`const_with_non_const`）；
* 改文件时注意本仓是 **CRLF**：按 `\n` 去匹配的脚本会静默不生效（探针打不上就是这么来的），
  要么用编辑器，要么落盘后再核一遍。

## S12.31 桌面画中画小窗（通话窗能缩成右下角那个置顶小窗）（2026-10-05）

S12.30 末尾留的那条「画中画没做」，这一轮做了。用户在本轮开头的三个问题里选的是
「先做共享屏幕 + 顺手修全屏比例」（S12.30），说「继续检修和完善」之后，从四个方向里
挑中的就是这一条：**桌面置顶画中画小窗**。

### 一、做成什么样

* 通话窗（`DesktopWindowKind.call` 那颗**独立窗口**，不是主窗口）控制栏多一颗
  「画中画」（`call.pip`）。点了这扇窗自己去跟原生说一句：**去掉标题栏与边框 +
  不进任务栏/alt-tab（`WS_EX_TOOLWINDOW`）+ 置顶（`HWND_TOPMOST`）+
  挪到工作区右下角 320×180（逻辑像素）**；
* 界面同时换成**小窗那一版版式**（`call_desktop_page.dart::_pipLayout`）：只剩画面
  + 底下一排 30 的图标钮（麦克风 / 摄像头 / 挂断 / 还原；来电那一屏是拒接 + 接听）。
  文字只留在 tooltip 里 —— 320 宽里放不下桌面那套 84 宽的圆钮（四颗 336）；
* 小窗里**按住画面就能拖**（原生按真光标位置算位移，见第三节）；双击画面还是
  「完整 ⇄ 铺满」（与大窗同一个开关）；
* 那颗「还原」把它变回原来的样子：**样式与位置都是进小窗之前存下的那一份**
  （不重新居中、不改大小）；挂断那条路（`bye` → 关窗）与 S12.29 的 ✕ 收摊
  一个字节都没动 —— 小窗里没有标题栏，出路就是那排钮里的「挂断」/「还原」；
* **只有通话窗有这颗钮**：`CallDesktopActions.togglePip == null` 时不画
  （主窗口里那份兜底页没有窗可缩），语音通话也画 —— 那颗小窗会摆头像 + 名字 +
  计时（没有画面时才需要那块）。

### 二、这一轮改了什么（4 个源文件，其中 1 个是原生 + 7 个语言文件 + 2 个测试文件）

* `windows/runner/flutter_window.cpp`（原生，子窗那条小通道 `gracelinkim/child_window`）：
  * `setPip`：进 = 存下原样式与原位置 → `WS_POPUP`（去掉 `WS_CAPTION` /
    `WS_THICKFRAME` / `WS_MINIMIZEBOX` / `WS_MAXIMIZEBOX` / `WS_SYSMENU`）+
    `WS_EX_TOOLWINDOW`（顺手拿掉 `WS_EX_APPWINDOW`）→ 隐藏/显示一次（**这一步不能省**：
    `WS_EX_TOOLWINDOW` 的变化要一次隐藏/显示才会反映到任务栏上）→ 右下角 320×180
    置顶（工作区留 24 逻辑像素的边）。出 = 把存下的样式与矩形原样还回去 + 非置顶；
  * `dragBegin` / `dragUpdate` / `dragEnd`：拖窗那三下（理由见第三节）；
  * 两份状态（`g_child_pip_states` / `g_child_drag_states`）**都按 HWND 记，
    `WM_DESTROY` 里跟着反查表一起清** —— 句柄会被系统复用，留着就是给下一扇窗埋雷；
* `desktop_window_native.dart`：`setPip({on, width, height})`（返回**这台机器上做没做成**，
  通道没注册就是 false）+ `dragBegin` / `dragUpdate` / `dragEnd`；
* `call_window.dart`：`_pip` 状态、`_togglePip()`（原生回 false 就**不切版式** ——
  界面绝不能自己以为在小窗里，那样画面挤成一小块而窗还是大的，比不做还难用）、
  `_draggable()`（小窗外面包一层 pan；用 `translucent` 让底下那些钮照样点得到）；
* `call_desktop_page.dart`：`CallDesktopActions.togglePip` + `CallDesktopPage.pip` +
  小窗那一版版式（`_pipLayout` / `_pipBar` / `_pipButton` / `_pipPeerInfo`），
  顺手把深色渐变底抽成 `_backdrop()`（大窗小窗共用），`kCallDesktopPipSize = (320,180)`；
* i18n：七个语言文件加 `call.pip`（画中画 / 子母畫面 / Mini window / ミニウィンドウ /
  Mini-Fenster / Ventana mini / Mini-fenêtre）与 `call.pipRestore`
  （恢复大窗 / 還原大視窗 / Back to window …），插在 `call.minimize` 之后；
* 测试：`test/features/call_desktop_test.dart` 5 条（大窗那颗点了交给宿主、没传就不画；
  小窗版式只剩画面 + 一排图标钮且都在 320 宽里；那排钮的三下都接得上；语音通话的小窗
  摆头像 + 计时；小窗里来电那一屏两颗）；`test/features/call_window_test.dart` 3 条
  （点「画中画」→ 原生收到 `setPip(on: true, 320×180)` 且版式换紧凑；原生回 false →
  版式不切；小窗里拖一下 → `dragBegin`/`dragUpdate`/`dragEnd` 三下都送到）。

### 三、拖窗为什么不按 Dart 报的 delta 算（这段最值钱）

S12.30 第六节写的做法是「`WM_NCHITTEST → HTCAPTION`，按着画面就能拖」，真做的时候
这条路有两处不通：

* **整块客户区当标题栏会把 Flutter 的鼠标输入整块吃掉**（`HTCAPTION` 意味着系统接过
  鼠标去走自己的移动循环）—— 小窗里那排钮就点不着了；只把顶上一条窄条当标题栏，
  320×180 的小窗里那条窄条太占地方；
* 客户区是被 Flutter **视图子窗口**盖住的，命中测试先落到那颗子窗上（顶层窗那条
  `RegisterTopLevelWindowProcDelegate` 只管顶层 HWND 自己的消息），这条路要生效还得
  再去子类化一层 —— 动静比这件事本身大。

所以改成：**Flutter 那边用 pan 手势开个头，位移由原生按真光标位置算** ——
`dragBegin` 记下 `GetCursorPos()` 与那一刻的 `GetWindowRect()`，`dragUpdate` 拿**当前
光标**减按下时的光标得到位移，直接 `SetWindowPos`（并 clamp 在工作区里，拖不丢），
`dragEnd` 收摊。

关键点是**不能用 Dart 报过来的 delta**：窗口一跟着动，指针在窗里的局部坐标也跟着变，
两边一抵消，拖到一半就不动了。`GetCursorPos` 给的是屏幕坐标，跟按下那一刻一比，
位移永远是准的 —— 拖窗这件事只有系统自己那一份才对得上。

### 四、验证

* `dart format lib test integration_test` 0 changed、`flutter analyze` No issues found；
* `flutter test` **2086 条全过**（这一轮 +8：上面那 5 + 3 条）；
* `flutter build windows --release` 通过；核过产物里是新代码：
  `gracelinkim.exe`（9.0 MB）里有 `setPip` / `dragBegin` / `dragUpdate` / `dragEnd`
  四条方法名（原生那半边确实编进去了），
  `data/flutter_assets/assets/i18n/zh-Hans.json:486` = `"call.pip": "画中画"`、
  `:487` = `"call.pipRestore": "恢复大窗"`（en 是 487/488）；
* 真机：release 实例起来、连上服务端（`[WS] 状态：connected`）。

### 五、还没做 / 只差一次「真拨一通」的那几条

* **小窗本人只有真拨一通才看得到**：组件测试钉的是「原生收到什么、版式跟着换什么」，
  原生那半边（无边框/置顶/不进任务栏/右下角/拖走）得在**一通活着的通话**里目视一眼
  —— 本机自检那条路（`integration_test/call_window_smoke_test.dart`）验不了窗口：
  子引擎继承的是测试入口（文件头那段 2026-10-04 实测），窗口类功能只能真 App 用鼠标验；
* 「置顶小窗被系统『显示桌面』/全屏应用挡住」是 Windows 的正常行为（真·置顶要独占
  全屏的配合），不算 bug；
* 「对方在共享屏幕」的信令（S12.30 第六节第二条）还没做；
* 顺手发现的一条（**不是这一轮改出来的**）：Windows runner 没实现
  `gracelinkim/app_info` 那条通道，所以 `app_version.dart` 一直走兜底 ——
  启动日志里就有 `[版本] 读不到本机版本，用常量兜底：MissingPluginException`，
  也就是说 PC 上「检查更新」上报的是 pubspec 里那个常量 + `release: 0`。
  要修的话在 runner 里加一条小通道读 exe 的版本信息（`GetFileVersionInfo`）就够。

### 六、踩坑

* `WS_EX_TOOLWINDOW` 改完**必须隐藏/显示一次**：不这么做，任务栏上那颗钮还挂着
  （任务栏只在窗口显隐时重读这一个样式位）；
* 进小窗要**只在第一次存**原样式与矩形：连着进两次不该把「小窗那一份」当成原样
  （`g_child_pip_states` 里已有这一扇窗就不再存）；
* `setPip` 里那对宽高是**逻辑像素**（与大窗那条 `setSize` 同一个口径），原生按
  `GetDpiForWindow` 折算 —— 否则 200% 缩放的屏上小窗会小一半；
* 测试里那条 `child_window` 假原生默认 `return null`：`setPip` 的返回是
  `Future<bool>`，得让它回 `true` 才会切版式（`pumpWindow(pipApplied:)`），
  另有一条用例专钉「回 false 版式不切」；
* 拖窗那条用例别用 `tester.drag`：一次 move 报的位移可能刚好卡在 pan 的
  触发阈值上，用 `startGesture` + 三次 `moveBy` 才稳。

## S12.32 共享电脑的声音（连麦克风一起发）+ 选择面板给真缩略图（2026-10-05）

用户这一轮两句原话：「任何就是共享屏幕你能不能跳出系统默认的那个共享选择窗啊？」
「还有能不能共享声音啊」。前一句在 `ask_questions` 里定成**做成系统那个的样子**
（保留自研面板：真缩略图 + 中文名 + 整屏优先），后一句定成**电脑声音 + 麦克风两条
一起发**（要动协商，两端都得升级）。

### 一、系统那个选择窗为什么喂不进（先验的结论，别再试）

Windows 的 `GraphicsCapturePicker` 交回来的是 `GraphicsCaptureItem`，**反求不出
HWND / 显示器序号**；而插件那边只认它自己那套 source id（屏幕序号 / 窗口 HWND，
`flutter_screen_capture.cc::GetDisplayMedia` 里 `video -> deviceId -> exact`）。
所以「弹出系统框、拿它的结果去取流」这条路是死的 —— 面板留在我们这边，把它的
观感补上（缩略图/名字/顺序）。

### 二、缩略图：插件不填，但它另有一条路由

* `GetDesktopSources` 在 Windows 上**不填** `thumbnail` 字段（源码里挂着 TODO），
  所以 `source.thumbnail` 永远是空 —— 面板里一直是灰块；
* 但插件另有一条原生路由 `getDesktopSourceThumbnail`（`FlutterWebRTC.Method`，
  参数 `{sourceId, thumbnailSize:{width,height}}`；原生里是
  `source->UpdateThumbnail()` + `source->thumbnail()`，**那两个宽高是被 `(void)`
  掉的，但不给这个 map 直接报 Bad Arguments**）；
* ⚠️ 插件自己那个 Dart 包装 `DesktopCapturerNative.getThumbnail` **用不了**：真机
  实测它在类型检查那一步抛 `type '_UnmodifiableUint8ArrayView' is not a subtype of
  type 'bool'`（`common/cpp` 那条回话被按 bool 解了）。所以面板里**直打原生那条
  通道**（`screen_share_picker.dart::_askThumbnail`）；
* 实测（`integration_test/screen_share_smoke_test.dart` 第 5 条）：屏幕与窗口**都
  能给真图**（屏幕 3072×1920 / 92~362KB / 10~40ms；窗口 2880×1800~3088×1844），
  一张 300KB 的整屏图按 `cacheWidth: 192` 收小再给 `Image.memory`；
* ⚠️ 原生**不是每次都当场给**：同一条窗口第一问 0 字节、隔 250ms 再问就有
  308744 字节。所以空的回话不算数：`_sourceThumbnail` 最多问三轮（250ms 一档），
  三问都空才画灰块（S12.33 里补的）。

### 三、共享声音：空闲音频 m-line 预协商

困难在于**通话中重新协商没有现成通道**（`CallEvent` 只有 calling/acceptRtc/offer/
answer/iceCandidate/hangup/busy/otherOpt）。方案是**把那条音频 m-line 提前摆好**：

* 主叫 `createOffer` 之前 `_prepareSpareAudio(pc)`：`addTransceiver(audio,
  init: RTCRtpTransceiverInit(direction: SendRecv, streams: [_local]))` —— 空的
  音频轨（没有 track），对方那时候也听不到任何东西；
* 被叫 `acceptOffer` 里 `_adoptSpareAudio(pc)`：对面 offer 里那条**没有轨道的
  音频 m-line**，把它的 direction 改成 `SendRecv`（不然应答方向是 inactive）；
* 共享屏幕时 `_attachShareAudio`：`'audio': withAudio` 交给插件 —— Windows 原生
  走 `ApplicationLoopbackCapturer`（WASAPI，源 id `"0"` = 全部系统声音、窗口 id =
  按 PID 只抓那个程序），拿到轨之后 `spare.replaceTrack(loopback)`；
* **没有 spare 那条**（对面是老版本 / 应答方向没改到）就退成
  `replaceTrack` 到**麦克风那颗 sender** 上（`ScreenShareAudioRoute.microphone`）；
  一条音频轨都没有就是 `unavailable`。两种退化都各提一嘴
  （`call.shareAudioFallback` / `call.shareAudioNone`）—— 那一刻对方的听感与
  预期差得远，不能默默发生；
* 停止共享：`_detachShareAudio` —— `spare.replaceTrack(null)` 摘掉，麦克风那颗
  换回原来的轨道；
* 枚举返回值过不了通道，通话窗回的是 `ScreenShareAudioRoute.name`（字符串），
  主窗口那份代理自己解回来（`call_window_media_engine.dart::_audioRouteOf`，
  认不出来的当 `off` —— 宁可少提一嘴，绝不因为一条回话没看懂就抛）。

⚠️ 共享**整屏**会把对方的声音一起回传（环路采集抓的是系统输出，对方也在里面）：
耳机、或者只共享某个窗口，能避开回声。

### 四、顺带修掉的一个真机 bug：共享期间摄像头那颗没置灰

手机版一直是灰的（共享时摄像头已被引擎关掉、发出去的是屏幕），桌面版漏了 ——
点它只会把一颗没在用的轨道开来关去，界面说一套、对方看另一套。
`call_desktop_page.dart::_round` 加 `enabled`（`Opacity(disabledOpacity)` +
`onTap: enabled ? onTap : null`），摄像头那颗传 `enabled: !state.screenSharing`。

### 五、验证

* 全量 **2094 条全过**（本轮 +15）；`test/features/call_desktop_test.dart` 新增
  「面板：整屏排最前、窗口用标题；空手的缩略图会再问一轮」；
  `test/call/call_controller_test.dart` +4（withAudio 透传、microphone/unavailable
  两条提示、没勾声音时不提示）；`test/features/call_window_test.dart` +2
  （源与 withAudio 都带过去、回话解成枚举 / 认不出来的当 off）；
* 真机自检 `flutter test integration_test/screen_share_smoke_test.dart -d windows`
  **6 条全过**：源列表、按屏 id 取流、按窗口 id 取流、默认源、逐条缩略图、
  loopback 音频轨（17~88ms 拿到 1 条轨、采 3 秒仍在采）；
* `dart format` 0 改动、`flutter analyze` No issues、`flutter build windows
  --release` 通过，产物里 `getDesktopSourceThumbnail` / `call.shareAudioNone` 都在，
  7 份 i18n 各 4 个新键都进了 release 包；
* ⚠️ **听感验不了**：「对方实际听到什么」（两条一起发 / 退成换麦克风那支 /
  停止共享换回麦克风与摄像头）要两台设备、两个账号对拨。

## S12.33 缩略图重问 + 来电那一屏 + 「电脑共享屏幕，手机端看不全」（2026-10-05）

用户这一轮：「还有一些通话的细节瑕疵你再看看」（定成**来电那一屏**）+ 复查时刚
报的「电脑共享屏幕，手机端看到的好像是不完整的」。

### 一、来电那一屏：头像贴在空屏上（`call_desktop_page.dart::_peerInfo`）

`_peerInfo` 原来是「视频那一档一律贴顶（`top: 40`）+ 头像 72」—— 那是为**有画面**
时定的（名字压在画面上）。可**来电那一屏一路媒体都还没取**（`RequestLocalMedia`
要等接听），于是 600×700 的窗里只有一个 72 的小头像挂在顶上、下面六成全空。
判据改成「真的有画面才压」：

```dart
final overlaid = video && session.phase != CallPhase.incoming;
final avatarSize = overlaid ? 72.0 : 112.0;
```

来电那一屏于是与语音那一屏同一个摆法（头像 112 居中）。两屏抓图
（`build/call_desktop_incoming.png` / `call_desktop_incoming_voice.png`，
真窗尺寸 600×700 / 420×620）逐张核过。

### 二、「手机端看不全」：1:1 没有「对方在共享屏幕」这条信令，只能按比例判

根因与群通话那条老坑一模一样（`call_video_view.dart` 的注释里就记着：「群通话的
共享屏一开始也走 `cover`，对方只看到画面中间那一块 —— 用户原话『共享屏幕显示不
完整』」）：电脑那路屏幕是 3072×1920（16:10），手机那块大画面是 390×700
（9:19.5），`cover` 的缩放取 `max(390/3072, 700/1920)` = 0.365，画出来
1121×700 —— **只看得见中间 35% 的宽度**，屏幕左右两边全没了。

群通话有信令（`sharedScreen`），1:1 没有，所以按**几何**判（新文件
`lib/features/call/widgets/call_video_fit.dart`，纯函数）：

* `coverVisibleFraction(frame, area)`：铺满之下这块区域能看到原画面的百分之几；
* `coverCropsTooMuch(...)`：裁掉超过 **35%** 就算太多；
* `fitFor(frame, area, {fill})`：`fill != null`（用户自己挑过）照他挑的来，
  否则按上面那条判；画面尺寸还不知道时按 `cover`（摄像头那一套默认）。

尺寸从哪来：`CallVideoView` 新增 `onFrameSize`（原生那条
`didTextureChangeVideoSize` → `RTCVideoRenderer` 是个 `ValueNotifier`，监听它，
同一份尺寸不重复报；换流时把上一路的作废）。宿主（`call_page.dart`）拿它算
`_bigFit`；**长按大画面**在「铺满 ⇄ 完整」之间翻（桌面那一版是双击）。

⚠️ 手机这边**不能用 `onDoubleTap`**：与 `onTap` 同挂时，单击要等那 300ms 的
双击超时才会生效 —— 「点一下收按钮」会等半拍（已有用例钉这一条）。长按与
桌面右键 ⇄ 手机长按那套既有约定也一致。

实测那几个尺寸都钉进了单测（`test/features/call_video_fit_test.dart` 9 条）：

| 画面 | 区域 | 铺满看得见 | 结论 |
| --- | --- | --- | --- |
| 3072×1920（电脑屏） | 390×700（手机大画面） | 34.8% | **完整放** |
| 1080×1920（竖屏手机） | 390×700 | 98.6% | 铺满 |
| 1920×1080（横过来拿） | 390×700 | 31.7% | **完整放** |
| 1920×1080（横屏手机） | 192×144（自己那块小窗） | 75% | 铺满 |

### 三、验证

* 全量 **2104 条全过**（本轮 +10：`call_video_fit_test.dart` 9 条 +
  `call_page_test.dart` 的「大画面长按：铺满 ⇄ 完整」）；
* `dart format` 0 改动、`flutter analyze` No issues、`flutter build windows
  --release` 通过（`lib` 里没有比 `app.so` 更新的文件、`windows` 里没有比 runner
  更新的手写源码），release 实例起来后 `[WS] 状态：connected`；
* 真机自检 `screen_share_smoke_test` 再跑一遍 **6 条全过**（缩略图那条：屏幕
  第 2 轮 92787 字节 / 3072×1920，3 条窗口都是第一问就有图）；
* ⚠️ **手机那一档验不了**：手边没有连着的安卓设备（`adb devices` 是空的），
  「电脑共享屏幕时手机上看到完整的屏幕」要真机对拨才能看见；能钉到的只有那条
  比例判定 + 长按逃生口。

### 四、踩坑

* `RTCVideoRenderer` 是 `ValueNotifier`（不是普通对象）：`addListener` 就能拿到
  `didTextureChangeVideoSize`，`videoWidth/videoHeight` 在 native 与 web 两份实现
  上都有；
* `fitFor` 那种「换行写成多行」的表达式**不能写成 getter**：`bool get x =>` 后面
  换行会让 Dart 把下一行当成新语句（编译期直接报 `Expected a function body`），
  写成 `bool _autoFill() =>` 或加括号；
* 长按/双击与单击同挂要当心那 300ms —— 反过来，**加了 `onLongPress` 不影响单击**
  （长按超时只在按住不放时走）。
## S12.35 手机端看不到电脑的画面（对方画面被一条空流顶掉）

**用户报的**（2026-10-06，附了手机端与电脑端两张截图）：
「电脑端表面上看是没有任何问题了，手机端的画面也能看到自己的、电脑摄像头画面也能看到，
然后手机端自己的画面也能看到，**但是看不到电脑的画面** —— 手机端就是两个画面都是自己的，
一个实时的，一个卡在接通的瞬间。然后音频都是好的，就是视频画面不对。」

**先分清是哪一环**（这一步救了一整轮）：翻两端的统计日志。

* 手机：`[通话·媒体] video sent=14011 帧 · recv=13873 帧/decoded=13848 帧`（约 30fps）
  —— **对方的画面一直在正常收、正常解**；
* 电脑：`video sent=0 帧 · recv=0 帧`（这一行是假的：桌面那颗引擎的统计走代理通道，
  新字段没带过去；画面本身是好的，见桌面的截图）。

所以：**媒体链路没问题，坏的是界面拿到的那份「远端流」**。

**根因**：`WebrtcCallMediaEngine._handleTrack` 里那条「没有 stream 就自己包一份」的兜底。
S12.32 给共享电脑声音加了一条**预协商的空音频 m-line**（`_prepareSpareAudio`）；对端把它的
方向开成 `sendrecv` 之后，插件会替那条 m-line 报一条**没有 `msid` 的音轨**。老代码对
「没有 stream」的轨一律：

```dart
final stream = await createLocalMediaStream(uuidV4());   // 一份**空的**流
await stream.addTrack(event.track);                      // 里面只有一条音轨
_remote = stream;                                        // ← 把对方的画面顶掉了
```

安卓那边 `videoRendererSetSrcObject` 拿到这份流后取第一条 `videoTrack`，取不到就
`setVideoTrack(null)` —— 已经渲染的那一帧**冻在原地**。于是：

* 大窗（绑 `_remote`）→ 冻在接通那一瞬间的**本机摄像头画面**；
* 小窗（绑本地流）→ 好着，还是本机摄像头。

「两个画面都是自己的、一个实时一个卡住」就是这么来的。日志里那三行排在一起，
顺序恰好是要害（`audio(有 stream)` → `video(有 stream)` → `audio(没有 stream)`）。

**改法**（判据抽成纯函数，单测直接钉）：新文件 `lib/data/media/remote_stream_choice.dart`

```dart
enum RemoteStreamAction { adoptProvided, ignore, wrapTrack }

RemoteStreamAction chooseRemoteStreamAction({
  required bool trackHasStream,
  required String trackKind,
  required bool remoteHasVideo,
});
```

* 带 `msid` → 用插件那份流（老路）；
* 没有 `msid`、又不是画面轨 → **丢掉**（远端声音由原生直接播，界面从来不碰音频流）；
* 没有 `msid`、是画面轨、而且手里还没画面 → 才自己包一份顶上（老端的兜底保留）；
* 没有 `msid`、是画面轨、但手里已经有画面 → 丢掉（重复报的轨不能把画面换掉）。

外加一条硬化（`widgets/call_video_view.dart`）：重绑的条件从「换了流」扩成
「换了流**或者同一份流的画面轨刚刚才上来**」——插件是按轨逐条报 `onTrack` 的，
第一份流先建出来时里面可能还没有画面轨，那一刻绑上去等于绑了个空的。

**测试**：`test/call/remote_stream_choice_test.dart` 4 条（真值表 + 那次事故那一条），
外加 `画面绑流` 那行诊断日志（流 id + 画面轨指纹）。全量 **2112** 全过。

**用户复测**：「基本已经修好了不错」——真机（Galaxy S23 Ultra + Windows）确认。

## S12.36 Windows 系统托盘（关窗 ≠ 退出）

**用户要的**：「你从 Windows 底部栏右边那个小箭头点开还能看到，就应用没有真正被关掉」
—— 微信那套：关窗缩到托盘，进程与连接都留着（来电、消息照样收得到），
真退出只有托盘菜单里那一项。

**原生**（`windows/runner/tray_icon.h/.cpp`，新文件）：

* `Shell_NotifyIcon(NIM_ADD)` + `NOTIFYICON_VERSION_4`（V4 的回调语义清楚：`lparam`
  低 16 位就是鼠标消息）；
* 图标取 exe 资源里那张 `IDI_APP_ICON` 的 16×16 那一档（通知区就那么点大）；
* 右键菜单是**弹的那一刻现建**的（`TPM_RETURNCMD` 直接返回命令 id）；
  经典的两条也照做了：弹之前 `SetForegroundWindow`、选完补一条 `WM_NULL`；
* 与 `flutter_window.cpp` 的接法：`FlutterWindow::MessageHandler` 里
  `WM_CLOSE` → `ShowWindow(SW_HIDE)`（**不是最小化**：用户要的是底部栏上找不到它）、
  托盘回调 → 左键/双击恢复、右键菜单；`WM_DESTROY` 摘图标（否则通知区留一颗点不动的残影）；
* 真退出走 `QuitFromTray()`：`PostMessage(WM_CLOSE)` 让消息转一圈再销毁
  —— 托盘菜单是在我们自己的窗口过程里弹的（`TrackPopupMenu` 同步阻塞），
  在那条栈上 `DestroyWindow` 等于自己拆自己；
* 第一次缩进托盘冒一句气泡（跟微信一样，只说一次）。

**文案**：原生一个字都不翻译 —— 由 Dart 递（`lib/features/desktop_window/tray_native.dart`
+ `gracelinkim/tray` 通道）。语言包那 7 份是唯一的事实来源，新增 3 个 key：
`tray.open` / `tray.exit` / `tray.balloon`（7 份都翻了，`i18n_keys_test` 会守）。
`GracelinkApp.build` 里叫一次，同一个语言自己去重（换语言再配一次）。

**真机验证**（`build/trayprobe.ps1`，纯自动化）：

```
RESULT main-window=0x18065E visible=True pid=28180
RESULT tray-icon=yes rect=2476,1824,2540,1920      ← Shell_NotifyIconGetRect：图标真在通知区
RESULT after-close visible=False alive=True         ← 关窗 = 缩起来，进程活着
RESULT after-restore visible=True                   ← 托盘左键放回来
```

菜单文字用截图 + OCR 复核：光标 (1800,1000) 处弹出两项，第一项 161px 宽
（「打开 Gracelink」）、第二项 46px（「退出」）—— 中文文案确实是从语言包过来的。
原生日志三个标记：`(tray-ready)` / `(tray-hidden)` / `(tray-shown)`。

**没验到的**：气泡本身（Windows 可以把气球提示关掉，这台机器上截到的是系统自己那条
通知）；菜单里点「退出」那一下是人工路径，没做自动化（`TrackPopupMenu` 是模态的）。

## S12.36 附：共享窗口被遮住之后画面不实时（**不是我们的 bug，但要知道**）

用户报的：「共享一个电脑应用的画面，这个应用在放视频，我把它放到后台（视频没停），
对方看到的画面就卡在前台最后一秒；切回前台又恢复实时」。

查证：抓窗口那颗capturer 在**插件的预编译 `libwebrtc.dll` 里**（`common/cpp/src/
flutter_screen_capture.cc` 只是 `base_->desktop_device_->CreateDesktopCapturer(source, ...)`
的调用方）。`grep -a` 那 20MB 的 DLL：有 `WindowCapturerWin`（GDI/`PrintWindow`），
**没有 `WindowCapturerWinWgc`**（Windows Graphics Capture）—— 也就是这颗预编译库
没开 WGC。

后果：被完全遮住的窗口，DWM 会停止为它合成新表面，`PrintWindow` 拿回来的就是
「最后一帧」。要真修得换 WGC 那条路，而它在预编译库里、插件也不给替换 capturer 的口子
（要改就得 fork 整个插件并把那 20MB 的 libwebrtc 一起带进仓库）。

**能用的话术**：这个场景请共享**整个屏幕**（屏幕一直在变，抓帧就不会停），
或者把被共享的窗口留着别被完全遮住。真要做 WGC，是一件独立的大活（S12.37 候选）。

## S12.37 群通话的桌面版式：一屏看全（不再是 500 宽的手机长条）

用户 2026-10-06 问「群通话电脑端现在啥情况」，那句话本身就是答案：
`/message/group/call` 那条路由**刻意没包** `_desktopPage`（沉浸式全屏那类，见
`app_router.dart` 里那段注释），所以它躲过了三栏框架，却躲不过 `DesktopShell`
那条 500 的封顶 —— 桌面上点进群通话，看到的是一条 500 宽的手机长条居中摆在
2400 物理（1186 逻辑）的窗口里：头像墙两列、字号全按 500 算、两边一大片灰。

### 改法：宽窗走桌面版式，窄窗一个字不改

`group_call_page.dart` 的 builder 里多一档（`desktopWideLayout`，与三栏框架同一条判据）：

```dart
if (view.inPip) return _pipView(...);                    // 手机那套小窗，不变
if (desktopWideLayout(context, ref))                     // 桌面 + 真实窗口 ≥ 900
  return DesktopFrameScope(builder: (c) => _desktopCallView(context, session, view));
return _callView(...);                                   // 窄窗仍是手机那套
```

* `DesktopFrameScope` 是给 `DesktopShell` 看的挂载标记：挂着它就不再夹那 500
  （与 `DesktopPageFrame` 用的是同一本账，`desktopFrameActiveProvider` 是计数）；
* 桌面那一档全是**固定逻辑像素**（与 1:1 的 `call_desktop_page.dart` 一个口径）：
  顶栏群名 20 / 副标题 13；头像砖的圈 84、名字 13；底排圆钮 56 的圈、26 的图标、
  12 的标签、`Wrap(spacing: 36)` 居中；头像墙
  `SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, spacing: 20,
  childAspectRatio: 0.9)` —— **列数按窗口宽自己分**，手机那套写死的 2/3/4 列在电脑上
  会空掉一大片（1186 宽的窗口自己分出来是 5 列、格子 210）；
* **键与手机版一模一样**（`group-call-members` / `group-call-mic` / `group-call-screen`
  / `group-call-hangup` / `group-call-member-<uid>`）：两种版式只是外面那圈尺寸不同，
  自动化脚本与用例两边共用同一套选择器；
* 顶栏那颗「缩成小窗」在桌面上**不画**了：Windows 上 `CallPip` 的实现是 `NoopCallPip`
  （`supported => false`），画出来是一颗点不动的钮。判据加在 `_minimizeButton` 上
  （`session.controller.pip?.supported ?? false`），手机不受影响；
* 右键与长按都开群通话诊断（鼠标没有「长按」这个动作），与手机版同一个入口。

### 真机核出来的两个版式毛病（都已修）

跑起来量像素，量出两处「没排完」的地方 —— 都不是逻辑错，是**布局约束**漏了：

1. **顶栏整块跑到了窗口中间**：外层 `Column` 的 `crossAxisAlignment` 默认 `center`，
   而 `_desktopHeader` 里那层 `Column`（`start` 对齐）只会缩到「最宽那行字」的宽度，
   于是整块被居中 —— 群名落在 x≈531（窗口宽 1186），微信 PC 那种「群名贴左墙」没了。
   修：外层 `Column` 加 `CrossAxisAlignment.stretch`，修后群名 x≈28 ✓；
2. **头像墙排不满一行时贴着左墙**：一两个人时第一行右边空掉四五个格子。修：
   `LayoutBuilder` 里按 delegate 那套算法（`ceil(可用宽 / (220 + 20))`）先算出列数与
   格子宽，把「这一行实际占多宽」居中（`side = max(28, (可用宽 − 行宽) / 2 + 28)`）；
   排满一行或超过一行时保持 28 不变。

### 真机验证（新探针 `build/regions.ps1` + OCR，全自动化）

窗口宽档 2400×1600 物理（1186×800 逻辑，显示器 200%）：

```
red: n=260 box=(1722,1498)-(1830,1606) size=108x108   ← 挂着的那颗红圆钮：108px ≈ 56 逻辑 ✓
标签：成员 x=1272 / 麦克风已开 x=1476 / 挂断 x=1752      ← 三颗中心 473 / 593 / 713 逻辑
                                                          （84 宽 + 36 缝，整排居中）
顶栏：群聊 (406,222)、副标题 「1 人在通话 · 00:02:12」(408,288)
                                                       ← 逻辑 x≈28.5：贴左墙 ✓
头像墙：David Liu (1483,719)                            ← 中心 1536 = 窗口中心 ✓（单人时居中）
整窗扫不出 240,242,239 那种外壳底色横条                  ← 没被 500 封顶 ✓
```

窄档（窗口拉到 1400 物理 = 700 逻辑 < 900）：

```
red: box=288x288 物理                                   ← rpx(160) = 149 逻辑 ≈ 298：手机那套 ✓
标题「群聊」(978,230) 113x54 物理、副标题居中             ← 手机那套的大标题（居中）✓
```

再从窄拉回宽，桌面版式**当场切回来**（群名回 x≈28、头像居中、挂断回到 108 物理）；
点红钮挂断 → 回到群聊页、日志 `离开房间` ✓、页面上再无红像素 ✓。

**一次没归因的插曲**：第一次进房那条日志里只有 `离开房间`（没有挂断），页面自己退回去了 ——
那时服务端那条 `上游不可达（5s 超时）` 的抖动刚好发生（SfuApi.subscribe 抛 4005）。
重建之后再进房就稳了（连续 2 分钟在房里，`epoch 18`）。没深究，记一笔。

### 顺带查实：Windows AOT 会把「平台判死」的分支连同字符串一起消掉

核产物时 `grep -a group-call-screen app.so` 是 **0** 次，而同族的 `group-call-mic` /
`group-call-hangup` 各 1 次 —— 一度怀疑 app.so 是陈旧的（Android 那份 `libapp.so`
里同样是 1 次）。查清了：`sfuScreenShareSupported`（`!kIsWeb && Platform.isAndroid`）
在 Windows 上被常量折叠成 false，那一整块分支连同里面的字符串常量一起被删。
对照组同样为 0 的还有 `gracelinkim/pip`、`gracelinkim/call_keep_alive`（安卓专属），
而跨平台的 `gracelinkim/app_info`、Windows 专属的 `gracelinkim/tray` 都在（各 1 次）。
**结论**：Windows 的 `app.so` 里搜不到「安卓专属字符串」是预期的，不是构建陈旧；
判产物新鲜得看别的东西（这次是 `_desktopStage` 那批新符号 + 真机像素）。

### 没做 / 下一步

* **Windows 上群通话还不能共享屏**：`sfuScreenShareSupported` 现在只认安卓，
  所以桌面底排只有三颗（成员 / 麦克风 / 挂断）。开它是 S12.38 的活；
* **桌面上没有画中画**：上面那颗缩窗钮不画就是这个原因；
* 三端真机验收（三人 / 共享屏 / 断网重连 / 说话人高亮）仍然挂着 —— 这次只验了
  **版式与那一串动作**（进房 / 宽窄切换 / 挂断），没验多人；
* 收尾那串日志里 `离开房间` 打了两次、夹一条 `BusinessException(4001, 上游说请求不合法)`
  （挂断时服务器说会话已不在）—— 幂等收尾的正常噪声，今天没动它。

### 用例（`test/features/group_call_page_test.dart`，+6 条）

`pumpPage` 多了几个旋钮：`logicalSize`（默认仍是手机那档 360×760 —— 组件测试默认的
800×600 又宽又矮，不是手机上真实的样子）、`desktopFeatures`、`shell`（把整页套进
`DesktopShell`，验「跳出 500」那条），另加 `supportsScreen`（能力关掉时那颗钮不画）。

1. 桌面宽窗：主区域吃满 1280、群名贴左（`dx≈28`）、两块砖关于窗口中线对称、
   `gridDelegate` 是 `SliverGridDelegateWithMaxCrossAxisExtent`、钮与砖的键齐全、
   缩窗图标不画、群名与「2 人在通话」照旧；
2. 桌面宽窗：这台设备没有屏幕采集 → 共享屏那颗不画（其余三颗照旧）；
3. 桌面宽窗 + 外壳：跳出那条 500 封顶（再推一帧等框架标记生效）；
4. 桌面但窗口 700：仍是手机那套（delegate 是 `FixedCrossAxisCount`、缩窗图标还在）；
5. 桌面：别人在共享屏幕 —— 那块画面仍然 `contain` + 「小明 正在共享屏幕」；
6. 桌面底排走同一条链：点麦克风 → 「麦克风已关」；点成员 → `group-call-member-row-u3`。

全量：`dart format` 0 changed（517 files）/ `flutter analyze` 无问题 / **2121 条全过**。
## S12.38 群通话「几乎没法用」：四条病一个根因 + 电脑上开共享屏 + 电脑端图标与录音 UI（2026-10-06）

用户这次的话是「群聊通话貌似还是有诸多问题，状态不同步，说话没声，共享看不到，延迟极其严重等等全是问题几乎没法用，
电脑端手机端都有问题」。这一段先把四条病查到底，再做电脑端那两件（语音录音 UI、图标），顺带把 S12.37 里挂着的
「Windows 上群共享屏」开出来。

### 一、四条病是一个根因：控制面被源站拖死，而客户端 10 秒就判死

复现与取证（都是本机实测，不是推测）：

* 真机日志（`build/rel_s1225_out.log`）里那串原话：
  `进房间失败：NetworkUnavailableException(请求超时，请检查网络后重试)`，
  紧跟着 `进房间失败：BusinessException(4005, 上游不可达（Operation timed out after 5000 milliseconds with 0 bytes received）)`
  —— 连**服务端自己那条到 Cloudflare 的上游**都超时了；
* 控制面延迟实测（`build/sfuprobe.sh` / `build/interleave.sh` / `build/baseline.sh`）：
  源站上 `checkVersion` 1.7~6.3s、`sfu/room` 0.5~30s（还遇到整段无响应），而 **CF 边缘取同一个静态文件 0.2s**
  —— 本机网络与边缘都正常，慢的是源站这条链；
* `ApiClient` 的全局超时是 **10 秒**：服务端其实会成功的请求被判死 → 发布会话毒化 → 重建 → 再建会话/再发布/再订阅，
  每一步又是几秒。于是四条病是**同一条链上的五个面**：
  发布死 = 别人听不到我（说话没声）、订阅死 = 看不到共享（共享看不到）、回查死 = 界面停在旧快照（状态不同步）、
  整条链排队 = 点什么都等（延迟极其严重）。

改的地方（都在客户端，服务端不动）：

| 文件 | 改什么 | 为什么 |
| --- | --- | --- |
| `core/net/api_client.dart` | 新增**按请求的超时**（`send/post/postVoid/postMap` 都多一个 `timeout`，不传还是全局 10s） | 普通接口继续失败得快，SFU 那条链单独放宽 |
| `data/api/sfu_api.dart` | 全链路用 `SfuApi.requestTimeout = 30s` | 大于服务端自己那条上游超时（5s）：让它的业务错误码（4005 = 结果未知，要重建）回来，而不是本端一句含糊的「网络不可用」 |
| `domain/group_call/sfu_room.dart` | 定期回查**自适应退避**（一趟 ≥ `slowPollThreshold` 或失败 → 间隔 ×1.5，封顶 30s；一趟又快又好 → 回到 5s） | 服务端一抖，固定 5 秒就从「兜底」变成「加压」：房间里人越多越糟，而界面反而更不准 |
| 同上 | 心跳**不叠飞**（`_heartbeatPending`） | 20 秒一拍在慢服务端上一次不一定回得来，不叠飞否则每个间隔多压一条 |
| 同上 | 进房间那两趟「读快照」失败**只记日志**（`_refreshBestEffort`） | 那是读：读不到只是界面停在上一次的样子。以前是硬 await，一次读超时就把整通电话顶成「进不去」——而那时发布正在谈，别人其实听得到我 |
| `domain/group_call/group_call_hub.dart` | WS 推送对账失败只记日志 | 以前是裸 await，一次推送就能甩出一条「没人接的异步异常」（真机日志里那串 `Unhandled Exception: BusinessException(4005 …)` 就是它） |

### 二、S12.38：电脑上的群共享屏（以前那颗钮**根本不画**）

`sfuScreenShareSupported` 以前只认安卓（`Platform.isAndroid`），于是 Windows 上群通话底排只有三颗钮，
共享屏这条能力在电脑上等于不存在 —— 而 1:1 通话在 Windows 上早就有了（`CallMediaEngine.supportsScreenShare` 认桌面）。

* `data/media/sfu_local_media.dart`：能力判据与 1:1 **逐项同一个口径**（安卓 / Windows / Linux / macOS），
  `requestScreenSharePermission()` 在桌面直接返回 true（原生的桌面捕获不需要授权框；
  `Helper.requestCapturePermission` 在非 Android/macOS 上会抛），`startScreen({String? sourceId})`
  走 `video -> deviceId -> exact`（原生的 `getDisplayMedia` 认这个键）；
* `features/call/screen_share_picker.dart`：`showScreenSharePicker(..., allowAudio: false)` ——
  群里那一路声音统一走本机 mic，把电脑的声音也推进去等于把别人的话又回灌一遍，所以**不画**那座开关；
* `features/group_call/group_call_page.dart`：那颗钮的 handler 抽成 `_onScreenShareTap`，两种版式共用。
  顺序是**先判「此刻能不能开」再弹面板**（已经有人在共享时弹一个面板、选完了才告诉他「等小明的共享结束」是白跑一趟）；
  「取消」与「用默认源」是两件事（`null` vs `sourceId == null`）；
* 面板做成 provider（`screenSharePickerProvider`）：它要问 `desktopCapturer`（插件）拿源列表，
  组件测试里拿不到 —— 可替换之后，「选中的源一路带到引擎」这条链才钉得住。

### 三、电脑端那两件

**语音录音 UI**（`features/chat/widgets/voice_record_overlay.dart` + `chat_input.dart`）：
手机那套尺寸全是 `rpx`（= 窗宽 / 750），窗口 2400 物理 / 1200 逻辑时那个气泡会胀到 830 逻辑宽、
底下托盘 350 高；「武装线」在手机上离底 220rpx 是按屏高算的，桌面上同一个公式是 375 逻辑像素，
用鼠标往上拖那么远很别扭。桌面这一档改成**底部居中的固定像素卡片**（360 宽、不吃 rpx）+ **武装线 72** + 不压暗整窗；
手势语义一点不改（按住说话、上滑选取消/转文字、松手发送）。

**图标**（`windows/runner/resources/app_icon.ico`）：以前是 Flutter 模板那份（33772 字节）。
现在从 `assets/images/logo.png`（940×940，与安卓启动图标逐像素比对差 8.5/255 —— 本来就是同一个图案）生成
7 档 **DIB** 帧（16/24/32/48/64/128/256）。为什么手写帧而不用 `Icon.Save`：GDI 会把 256 那档写成 PNG 压缩帧，
而同一个 GDI（`System.Drawing.Icon`、以及老的 `LoadImage` 路径）随后读不回来。
exe / 窗口 / 托盘三处都取 `IDI_APP_ICON`（`Runner.rc`），换这一个文件三处一起变。

### 四、验过什么（都在最终源码状态之后跑的）

* `dart format lib test` 0 changed（517 files）、`flutter analyze` No issues、**全量 `flutter test` 2131 条全过**（本轮 +10）；
* `flutter build windows --release` 通过；产物核验：`find lib|windows -newer 产物` 为空；
* 电脑端图标（真机）：exe 自带图标 vs logo = **11.5/255**（对照：vs 旧模板图标 46.9/255）；
  运行中的窗口类图标 `HICON` = 9.0/255、`HICONSM` = 11.5/255（对照 47.2 / 46.9）；托盘探针照旧通过
  （`tray-icon=yes`、关窗隐藏、托盘唤回）；
* 语音录音（真机按住鼠标不放截图）：卡片宽 **720 物理 = 360 逻辑**（dpr 2，正是不吃 rpx 的那个固定值）、
  绿色声波条在画、整窗没被压暗；上滑取消后没有发出任何东西；
* **群共享屏（真机 + 服务端注册表）**：Windows 群通话底排现在有「共享屏幕」那颗钮 → 点开是 1:1 那个面板
  （整个屏幕 / Snapchat / Freebuff Desktop / 千问…真源列表）→ 选「整个屏幕」→ 页面出现「正在共享屏幕 /
  他们现在看到的就是你的屏幕」，并且**服务端注册表里我这一行变成 `tracks: ["mic","screen"]`**
  （`POST /enterprise/sfu/room`）；停止共享后 screen 消失；挂断后那一行在行超时（45s）内被清场，没有幽灵成员。

### 五、还没验的（如实记）

* **多人链路没验**：手机现在不在 `adb` 里，一台电脑只能验到「一个人进房间」。三条剩下的活：
  ① 手机与电脑同进一个群 → 端到端量「谁在说 / 听不听得见 / 共享看不看得见 / 延迟几秒」（两端诊断面板的 trace 一起读）；
  ② 断网重连；③ 说话人高亮。这一段做的所有事都只能算「把客户端这边能自愈的都自愈了」；
* 服务端那条链仍然是慢的（源站 1.7~30s）——客户端现在能扛住（30s 超时 + 退避 + 不判死），但**进房间仍要几秒**，
  这是服务端的问题，客户端只能不放大它；
* 桌面上没有群通话画中画（Windows 上是 `NoopCallPip`），这一条仍挂在待办里。


## S12.40 共享某个窗口：最小化再还原之后，对方画面永久卡住（2026-10-08 用户报的）

用户原话：「我电脑共享一个应用程序的时候，如果把这个应用程序最小化了再点开，别人看到的画面就会一直卡在最小化前的最后一秒，但是声音是实时正常的就画面卡住」。

> 编号说明：代码注释里引用的 `S12.39` 是「共享电脑的声音」那一档（实际落在 S12.32 / S12.33 两节里），
> 计划书里没有 S12.39 这一节；这一条按顺序记成 S12.40。

### 一、根因（改不了的那一层）

采集器是**插件预编译 `libwebrtc.dll` 里的 `WindowCapturerWin`**（GDI / `PrintWindow`，**没开 WGC**，
与 S12.36 附记那条同源）。窗口被最小化期间 DWM 不再为它合成新表面 → 抓回来的是最后那一帧；
而**窗口回来之后，同一个 capturer 手里的表面也不会再更新** —— S12.36 那档「被遮住」是切回前台就恢复，
这一档不会，于是对方永久停在那张图上。声音走的是 WASAPI 环路（`ApplicationLoopbackCapturer`），
与窗口可不可见无关，所以一直是好的 —— 与用户描述逐字对上。

采集器本体在预编译的 dll 里，**我们改不了**；能改的只有我们这侧的动作。

### 二、修法：盯住那扇窗，回来时重建一次采集，新轨挂回原位

* 判「被共享的是不是一个窗口」：Windows 上窗口源的 id 就是十进制 HWND（屏幕那块是 `"0"`）
  —— `windowHandleOf()`；只有窗口源才需要盯；
* `window_state_probe_io.dart`：`IsWindow` + `IsIconic` + `IsWindowVisible` **三条一起问**
  （只看最小化会漏掉「最小化到托盘」那种 `SW_HIDE`；只看可见会把「最小化但还在任务栏」当正常）；
* `SharedWindowWatch`：**最小化期间什么都不做**（那会儿对方停在最后一帧是正常的，重建只会白折腾，
  还可能把正在共享的声音一起断掉）、**回来后先等 1.5 秒宽限**（等窗口先画出来）再叫一声、
  **3 秒冷却**防抖；
* `desktop_screen_capture.dart` 里的 `recaptureDesktopScreen()`：重建采集。两条硬细节：
  1. 重建前**必须先 `desktopCapturer.getSources()` 刷新插件那份源列表** —— 原生 `getDisplayMedia`
     只在 `sources_` 里找源，而 Windows / macOS 分支**没有** Linux 那段「找不到就重建列表再试」，
     不刷就是 `Bad Arguments / source not found!`；
  2. 顺序是硬的 —— **先放掉旧的、再取新的**：插件里 `loopback_capturer_` **整个插件只有一份**，
     旧视频采集器被停掉时（`MediaStreamDispose` → `FlutterScreenCapture::OnStop`）会连带把当时手里
     那条环路一起停；反过来「先取新的、再放旧的」就会把**刚建好**的那一路声音掐掉（画面回来了、声音没了）。
* 新轨接回原位 —— **不重新协商、服务端一行不改**（mid 与注册表里那一行都不变）：
  * 1:1（`call_media_engine.dart`）：`_videoSender(pc).replaceTrack(新画面轨)`，带电脑声音时
    再 `_attachShareAudio()` 换上新环路；
  * 群通话：`SfuLocalMedia.addScreenTrackReplacedListener` → `SfuRoom` 里走
    `SfuPeerConnection.replaceTrackByName(name)` —— 按名字找到**原来那个 mid** 的 transceiver，
    `sender.replaceTrack(新轨)`；重建后「该发的哪几路」可能变了（原来带声音、这次取不到）就顺手把
    那一路关掉；
  * 重建**失败**（本机就没了采集）也照样叫一声：群通话那边把这几路发布关掉 + 界面回到「未共享」
    —— 不留死轨，也不留一颗按了没反应的「停止共享」。

### 三、验过什么（都在最终源码状态之后跑的）

* `flutter analyze lib test integration_test`：No issues；
* `flutter test` **全量 2157 条全过**（本轮 +14）；
* 新增 `test/call/shared_window_watch_test.dart` 10 条：假探针 + 假时钟把时序钉住（可见期不动 /
  最小化期不动 / 宽限后才触发 / 冷却内不重复 / 冷却过后照常重建 / 托盘隐藏那档 / `stop()` 后不动），
  外加**本机真装一次 Win32**（探针装得上、无效句柄说 false、非 Windows 应当是 null）；
* `sfu_room_test` 新增 4 条：按名字换轨**不重新发布、不重新协商**（连一条 SDP 都不动）、
  重建后少了一路要关掉、重建失败要收干净、停共享之后监听已摘掉。

### 四、还没验的（如实记）

* **两端真机没验**：这台电脑上只有一个运行实例，而 `libwebrtc` 的窗口枚举跳过自己进程的窗口 ——
  「最小化 → 还原 → 对方画面在 ~2 秒内恢复实时」这条只能两端试（这是交付验收项）；
* 共享**带电脑声音**时，重建会把环路重新建一次 —— 理论上声音会顿一下（几十~几百毫秒），
  真机上要听一下能不能接受；
* `integration_test/screen_share_minimize_test.dart`（PowerShell 自绘窗 + Win32 `ShowWindow` +
  缩略图指纹 + 发送端帧计数）是这次排查用的诊断脚本，可以手动跑（要先关掉正在跑的 release 实例）。

---

## S12.41 共享屏幕时对方**直接挂断**：画面永久卡死、连「已离开」都没有（2026-10-08 用户报的）

用户原话：「还有我试了一下，就是异常情况，比如电脑正在共享屏幕然后电脑直接挂断群通话，
手机端看到的就突然卡住然后就卡死了那种没有显示对方已离开就卡在那里」。

### 一、为什么会卡在最后一帧

正常收尾靠**注册表**：A 端 `leave()` 删掉自己那几行 + `bumpEpoch` 推 `sfuRoom`，B 端
`GroupCallHub.onRoomChanged` → `SfuRoom.refreshRoomState` → 差集退订 → 界面看到「没人共享了」
才把画面放下。这条链上有三处会漏：

1. **推送丢了 / 没到**（WS 正断线重连、`onRoomChanged` 那一下正好在处理别的事）：没有人主动补推；
2. **对账只在有事件时跑**：没人推就没人对账，而 `prune` 只在服务端 `room()` / `heartbeat()`
   里跑 —— 两边可能互相等；
3. 真正的兜底是**行超时**（`row_ttl`，**封顶 45 秒**）配上自己的心跳（20 秒）才走到对账。

于是 B 端手里就一张**最后一帧的死图**，而且**没人告诉界面**：`SfuRoom` 之前只有「新流到达」
这一个事件（`incomingMedia`），**退订不通知界面**；界面那层（`GroupCallController._sync()`）
也只在「注册表说没人共享了」时才把 `_screen` 置 null —— 全靠注册表，注册表不说话就一直挂着。
用户说的「卡住 + 没有已离开」正是这个组合。

顺手查了服务端：**不是那边的 bug** —— `Sfu.php::touchMine()` 只续自己那一行
（`where user_id = uid`），`prune` 的 deadline 有 45 秒封顶；`leave()` 里 `$this->uid` 直接拼 SQL
的写法与本文件里其它调用同风格（老代码习惯，记着，本轮没动）。

### 二、修法：接收侧盯「那一路还在不在收」，本机自愈（不等注册表、也不退订）

* `lib/domain/group_call/sfu_stream_watch.dart`（新）—— 判据只有一条：**接收侧计数不涨了**：
  * `SfuPeerConnection.inboundVideoCounters()`（`inbound-rtp` + kind video + mid，按
    `framesDecoded` / `framesReceived` / `bytesReceived` / `packetsReceived` 优先级取第一个有数的）
    —— 插件那份 `MediaStreamTrack` **没有** `getStats()`，但 `RTCRtpSender` / `RTCPeerConnection` 有；
  * 第一次见到算「在动」；连续 `screenStallTimeout`（默认 **8 秒**）一点没涨就判死；
    **统计里整个消失**的 mid 也算（连那一路的统计都没了）；
  * 采样周期 `screenHealthInterval`（默认 **2 秒**，`null` = 不自动采、用例自己调
    `pollScreenHealth()`）；只在**有 screen 订阅**时才开定时器，没人在共享时**一条 `getStats` 都不发**；
* 判死之后只做两件事：`droppedMedia` 发一条（界面把画面放下来 + 飘字）、`forget(mid)`。
  **不退订、不碰注册表** —— 订阅关系归快照对账管（对方真走了的话，最多 45 秒那条行超时把他清掉，
  那时按差集关门）。好处是**误判可恢复**：`pollScreenHealth()` 每轮**先看判死过的有没有又涨**
  （`_reviveStalledScreen` 把同一份 `SfuIncomingMedia` 再发一次，界面把画面接回来）——
  静态画面被误判、或对方重开了共享，都能自己接上，不用两边重谈；
* 界面侧（`lib/features/group_call/group_call_controller.dart`）：
  * 新参数 `notice`（`(key, name) → 飘字`），provider 里接到 `noticeBus.toast`；
  * `_onDropped`：**认同一份流**（`identical` 比 stream）才把 `_screen` 置 null，并飘
    `group.callShareLost`（「{name} 的屏幕共享已中断」）—— 别人已经换了新画面时不误伤；
  * `_noteDepartures()`：拿「上一轮名单」`_inCall` 与新名单对差，**只在 `phase == joined`** 时飘
    `group.callMemberLeft`（「{name} 已离开通话」）；**自己走了不飘**（那不是别人走了，是这一页散了）；
* i18n：7 份语言包各加 `group.callMemberLeft` / `group.callShareLost`（都带 `{name}`）。

### 三、验过什么（都在最终源码状态之后跑的）

* `flutter analyze lib test/group_call integration_test`：No issues；
* `flutter test` **全量 2169 条全过**（EXIT=0）；聚焦
  `test/group_call test/call test/core/i18n_keys_test.dart` **448 条全过**（EXIT=0）；
* 新增 `test/group_call/sfu_stream_watch_test.dart` 5 条：一直在涨不判死 / 不涨够 timeout 判死 /
  统计里消失也算 / 退订忘掉 / reset；
* `sfu_room_test` 新增 4 条：「那一路上不再出帧 → `droppedMedia`」、「画面一直在动不判死」、
  「**误判之后又出帧把画面接回来（订阅一直没动）**」、「没人在共享时一条统计都不问」；
* `group_call_controller_test` 新增 3 条：共享中断 → 画面放下 + 飘字 / 有人退出通话 → 飘带名字的
  「已离开通话」/ 我自己挂断不飘字 —— 这一组**抓到一个真 bug**：`_noteDepartures()` 里 map 字面量
  顺序写反（`_roster` 那份 false 把 participant 的 true 盖掉，所有人都会被算成「不在通话」）→ 已修；
* 顺手修的一处测试约定：`test/features/group_call_page_test.dart` 里 SfuRoom 也要把
  `screenHealthInterval` 关掉 —— 与 `heartbeatInterval` / `stateRefreshInterval` / `audioLevelPollInterval`
  那三支同一个道理（页面测试不 dispose 房间，留着定时器收尾会报「A Timer is still pending」）。

### 四、还没验的（如实记）

* **两端真机没验**（这台机器上只有一个运行实例，而 `libwebrtc` 的窗口枚举跳过自己进程的窗口）：
  A 端共享中直接挂断 → B 端应当在 **≤ ~10 秒**（2 秒采样 + 8 秒阈值）把死图放下来，并飘
  「{name} 的屏幕共享已中断」；若同时有人退了通话，再过一轮（≤2 秒）还要飘「{name} 已离开通话」；
* 8 秒 / 2 秒这两个数是拍的：屏幕共享正常情况下一直有帧（画面静止时编码器也会周期刷新），
  但**极端弱网**下（丢包严重、抖动大）可能连续 8 秒一点计数都不涨 → 会误判。误判的代价是画面先
  放下来、下一轮又接回来（界面闪一下），真机上要看一眼能不能接受；
* 若注册表推送一路正常（绝大多数情况），用户看到的还是「快」的那条路：差集退订 → 画面放下；
  本轮这条是**兜底**，两条叠在一起不打架（退订时会 `_streamWatch.forget` 掉那一路）。

## S12.42 共享屏「绿标有、画面没有」+ 反应慢半拍：控制面异常**从未翻译** + 订阅失败没有快重试（2026-10-08 用户报的）

用户原话两句：「电脑端先加入通话，开始共享，然后手机端再加入，就发现能看到电脑端那个账号有个绿色的共享标识，
但就是不显示出共享画面，什么鬼啊」；「我感觉为什么反应总是慢半拍……共享了 5 秒对方才看到……这个是 cloudflare 的问题还是我们的问题啊，能修吗」。

### 一、真机现场（手机 logcat 原文，`adb logcat -d | grep I/flutter`）

```
15:32:20  进房间（房间 3）
15:32:32  快照：2 人 / epoch 82 ｜ 22:mic+screen+screen-audio ｜ 23(我):mic
15:32:32  对账：新增 2 / 退订 0            ← 绿标就是这一刻来的（推送很及时，0.3 秒）
15:32:38  推送对账失败（忽略，回查会补）：BusinessException(4005,
          上游不可达（Operation timed out after 5000 milliseconds with 0 bytes received）)
15:32:38  快照 epoch 83 + 对账：新增 2      ← 没订上，重来
15:32:44  快照 epoch 84 + 对账：新增 2
15:32:49 / 15:32:55 / 15:33:39 / 15:33:44 / 15:33:50 / 15:33:56 …「对账：新增 2」一直重复
15:33:38  又一条一模一样的 4005 超时
15:33:58  用户退出（已经耗掉一分多钟）
15:34:13  重进房间（= 换了一条新接收会话）→ 15:34:38 订阅成功（0.8 秒）
15:35:00  ✗ 共享屏卡死：22 的 screen 连续 8 秒没有新帧 → 把画面放下来
15:35:10  ✗ 同上（再来一次）
15:35:13  epoch 93：22 那边共享没了 → 对账：新增 0 / 退订 2
```

三个可读的结论：

1. **绿标与画面是两条路**：绿标读服务端注册表（推送 0.3 秒就到）；画面要另走一趟
   `subscribe`（服务端 → Cloudflare `/tracks/new`），而那一趟**整整两分钟没订上**；
2. **`leave + 进房间`（换新会话）立刻就好** —— 说明坏的是「那一条接收会话」，不是网络也不是 CF；
3. 后来订阅成功了也**没有帧**（S12.41 那条看门狗报到 8 秒没新帧）—— 说明媒体面还有第二个问题，
   从手机这一侧看不出来（要么电脑没在发帧，要么 CF 没转发），需要电脑侧诊断。

### 二、根因一：`SfuFailure.fromApiException` **写好了却零调用**（本轮查实）

`lib/domain/group_call/sfu_failure.dart` 里那套翻译（业务码 → 被拒 / 结果未知 / 会话没了 /
要重登）是整条自愈链的入口，而 `SfuApi`（`lib/data/api/sfu_api.dart`）之前是**裸着往上抛**
`BusinessException` / `NetworkUnavailableException`。后果一串：

* `SfuSessionQueue.run` 只 `on SfuFailure` 才毒化会话，`_receiveMutation` 只 `on SfuFailure`
  才走「换新会话重建」—— 裸异常**两条路都不进**；
* 于是「结果未知」的处理（官方要求：可能已生效 → 必须换会话，不能重试）**一步都走不到**；
* 重试继续打在**同一条已经不可信的接收会话**上，直到用户手动退出重进。
  这与「两分钟订不上、重进就好」的真机现象逐字吻合，也与日志里那串
  `BusinessException(4005 …)`（若是 `SfuFailure`，`toString()` 会打成
  `SfuFailure(unknownOutcome, code=4005, …)`）对得上。

**改法**：`SfuApi` 新增 `_guard(label, run)`，九条控制面接口全部包一层
`on ApiException → SfuFailure.fromApiException(error, label: …)`（label：session / publish /
subscribe / close / renegotiate / room / heartbeat / mute / leave）。

### 三、根因二：订阅失败只有「5 秒兜底回查」能救，而那条还会退避到 30 秒

`stateRefreshInterval`（5 秒）是**兜底**，服务端一慢就 ×1.5 退避（封顶 30 秒，见 `_notePollPeriod`）。
它不能当重试用：真机上那两分钟里，客户端其实一直在重试，节奏就是「5 秒一发」，每一发都被
5 秒超时吃掉。

**改法**（`SfuRoom`）：新增 `reconcileRetryInterval`（默认 1 秒，`null` = 关掉）与
`reconcileRetryMaxInterval`（默认 5 秒）。`refreshRoomState` 在两种情况开火：
① 对账抛异常；② 对账回来了但**差集还在**（逐条失败的订阅也走这条）。
退避：1 → 2 → 4 → 封顶 5 秒；差集一空就 `_resetReconcileRetry()` 回到 1 秒。
它只补订阅，不碰注册表、不碰发布侧。

### 四、「慢半拍」是哪来的（回答用户的第二个问题）

**不是 CF 的媒体面**（媒体是端点 ↔ CF 边缘直连，起来之后是毫秒级），**是控制面绕了我们那台源站**：

```
电脑：开始共享 → 本机重谈 → HTTP 我们的服务端 → 服务端再调 CF /tracks/new
                                  ↓ 服务端改注册表 + WS 推送（这一步很快，0.3 秒级）
手机：推送 → HTTP roomState（又一趟服务器→CF）→ HTTP subscribe（服务器→CF）
     → CF 回 offer → 手机作答 → HTTP renegotiate（服务器→CF）→ 才开始出帧
```

每一跳都是一个「绕到源站再出去」的往返，而源站的实测延迟是 0.5~30s 级（S12.38 那轮量过），
再加服务端调 CF 那条 5 秒硬超时（超了就算失败）。三档修法已跟用户对过：
① 本轮做的「客户端快重试 + 服务端超时/重建」；② 服务端 CF 超时放宽（见下）；
③ 把控制面搬到 Cloudflare Worker（客户端直连 Worker，CF 内网调 CF Calls，每跳降到百毫秒级；
项目里已有先例：语音转文字那个 `my-whisper-worker`）。

### 五、本轮改了什么

| 文件 | 改什么 | 为什么 |
| --- | --- | --- |
| `lib/data/api/sfu_api.dart` | 新增 `_guard(label, run)`，九条接口统一把 `ApiException` 翻成 `SfuFailure` | 「结果未知 → 换会话重建」这条自愈链的**唯一入口**，以前一步都走不到 |
| `lib/domain/group_call/sfu_room.dart` | 新增 `reconcileRetryInterval`（默认 1s）/ `reconcileRetryMaxInterval`（默认 5s）+ `_scheduleReconcileRetry` / `_reconcileRetryTick` / `_resetReconcileRetry`；`refreshRoomState` 在「抛异常」与「差集还在」时开火；`leave()` / `dispose()` 里取消 | 把「等下一次回查（5~30 秒）」换成「1 秒级自己补」 |

服务端（配置，不在本仓）：`config/realtime.php` 里 `'timeout' => 5` 是那条 CF 上游超时
（`Sfu.php::cf()` 的 `CURLOPT_TIMEOUT`），线上实测 5000ms 到点。**建议放宽到 10 秒**：
它现在只在「CF 真的慢」时才吃满，而超时的代价（4005 → 整条会话重建）比多等几秒大得多。

### 六、用例（+5，全量 2174 条全过）

* `test/group_call/sfu_api_test.dart` +3（新组「失败必须翻成 SfuFailure」）：
  订阅撞 4005 → `unknownOutcome` + `requiresRebuild` + `code=4005` + `label=subscribe`；
  被明确拒 4001 → `rejected` 且**不**重建；HTTP 5xx → 也是「结果未知」。
  （测试用的 `_StubAdapter` 多了一个 `statuses` 覆写，用来造 5xx）
* `test/group_call/sfu_room_test.dart` +2（新组「补订阅的快速重试」，回查那条**关掉**，
  能补上就只可能是快重试）：订阅被拒 → 20ms 后自己订上；只订上一部分（逐条失败）→
  退避里接着补，上游一好就订上。
* `test/features/group_call_page_test.dart`：房间构造加 `reconcileRetryInterval: null`
  （页面测试不 dispose 房间，与 S12.41 的 `screenHealthInterval: null` 同一个道理 —— 不是放宽断言）。

### 七、验过 / 没验 / 剩下的疑点

* 验过：`dart format`（4 个文件被格式化）、`flutter analyze lib test/group_call
  test/features/group_call_page_test.dart` **No issues**、聚焦 205 条全过、全量 **2174 条全过**；
* 没验（要两端真机）：① 电脑开始共享 → 手机 ≤2 秒拿到画面（以前 5 秒起、卡住时两分钟都拿不到）；
  ② 电脑**直接挂断** → 手机放下死图 + 飘「XXX 的屏幕共享已中断」（S12.41 那条，仍未真机验）；
  ③ 共享窗口最小化→还原（S12.40，仍未真机验）；
* **没钉死**：15:35 那一段「订阅成功了也没有帧」到底是**电脑没在发帧**还是 **CF 没转发**。
  手机侧看不到这一层（它的看门狗只能报到「没有新帧」）。需要电脑侧的群通话诊断面板
  （长按通话页看时间线，里面会有 `发布已交回上游 / 与上游建连完成 / 发布 1 条：…（上游接受了 … 条）`）
  加上服务端 `runtime/log` 里 `SFU：` 那几行，两边一对就能定位。**电脑端目前没有「我到底发出帧没有」
  的  自检**（1:1 那套有 `framesSent` 诊断，群共享这条路没有）—— 这是下一件该做的事。

---

### S12.43 「离线推送的通知点开白屏，没跳到对应页面」（2026-10-08，**已定位、已修复、真机验收通过**）

用户：「现在不管是通话还是消息，离线推送的通知点击后都会白屏，没有正确跳到对应页面。」

**这一轮干到哪**：把通知点开这条链上一个**真机抓到的**异常修掉了，并给这条链补了定位用的
日志；**白屏本身还没钉死到底属于哪一种**（见下面「接下来」）。

#### 一、真机证据（唯一的一条硬证据）

新包（versionCode 2122）16:14:48 的 logcat：

```
E/flutter: Unhandled Exception: Bad state: Using "ref" when a widget is about to or has been unmounted is unsafe.
  #2 _ChatPageState._cached (chat_page.dart:236)
  #3 _ChatPageState._onEnter (chat_page.dart:298)
```

意思是：**聊天页在被卸载之后，进页那一步（`_onEnter`）还在飞** —— 它 await 完回来接着用
`ref`，而那时候 widget 已经不在了。时间点正好是用户在做「点通知」那组尝试（16:15:00 他手动
重启过 App）。

#### 二、改了什么

1. **聊天页不再在 await 之后碰 `ref`**（`lib/features/chat/chat_page.dart`）。这个文件本来就有
   这条规矩（`_conversations` / `_messages` / `_voicePlayer` 都是为它才在 `initState` 里存下来的，
   注释里写着「`dispose` 里再 `ref.read` 会抛」），但 `_cached()` / `_refreshNewest()` /
   `_loadHistory()` / `_onIncoming()` / `_clearManualUnreadMark()` 这几处漏了。现在：
   `_cached` 用 `_messages`，`_clearManualUnreadMark` 用新存的 `_manualUnread`，
   `_onEnter` 开头就把 `myUserId` 取出来（后面全是 await）。
2. **群通话小窗宿主不再换层次**（`lib/features/group_call/group_call_mini_bar.dart`）：
   以前「没有通话 / 通话页开着」时直接 `return widget.child`、否则返回一层 `Stack` ——
   这是 `DesktopShell` 里特意写着要避免的写法（翻面那一帧子树按类型比对失败会被整棵重挂）。
   现在永远是同一个 `Stack`，只换里面那颗药丸在与不在。
   **注意**：用例实测这条**不会**把页面状态弄丢（Navigator 自己那把 GlobalKey 兜住了），
   所以它只是省掉一次 Router 重挂，**不是**白屏的病因 —— 别把它当成本次修复。
3. **补了定位日志**（下次复现一眼就能定性）：
   * `message_notification_presenter`：点开通知时打一行 `[通知] 点了通知：<分到哪一类> / <payload 前 160 字>`；
     冷启动那条路打一行 `[通知] App 是被通知拉起来的：…`；
   * `notification_host`：`[通知] 冷启动带回来的会话：<id>` 与 `[通知] 点通知进会话：<id>`。
   有了这两组，就能直接分清是「分错类跳错页」「payload 没带会话 id」还是「跳了但页面没找到会话」。

#### 三、真凶（2026-10-08 下午，真机一手复现出来的）

用户 17:18:19 那次真实点击的 logcat：`START … act=SELECT_NOTIFICATION … with LAUNCH_SINGLE_TOP …
开始新任务 #1849` ——**之后 Dart 侧一行日志都没有**（没有 `[通知]`、没有 `[路由]`，连探针都没有）。
同一条时间线上还有两行关键日志：`Start proc … for broadcast {
FlutterFirebaseMessagingReceiver}`（推送把进程从零拉起）与 `flutterEngine warmed up`
（`AudioService.java:346`）——**推送到达时 audio_service 把共用引擎「热」起来了**。

把这两件事串起来就是：**「进程被推送拉起 → 引擎已热 → 用户才点通知」**这条路（用户的每一次离线
推送都是这个顺序，而 `am force-stop` 模拟的冷启动是另一条路，所以之前一直复现不出来）。
这条路上一共断了两处，各自都能单独造成「点通知只会见到一块白屏」：

**第一处（白屏?正所谓「卡在 runApp 之前」）：`lib/main.dart` 里那句
`await SystemChrome.setPreferredOrientations(...)` 在「无界面引擎」里永远不返回。**

audio_service 的暖机（推送到达时）会建一个**还没有 Activity 的引擎**并把 `main()` 跑起来。
那种引擎里平台侧收下这条消息却**永远不会回**，于是 `await` 就卡在那里：`runApp` 到不了、
Dart 一行日志没有、**界面永远画不出第一帧** —— 系统只好一直停在白底启动图上（Android 12+
由系统托管的 `SplashScreenStartingData`，就是用户看到的那块「白屏 + 居中 logo」）。

实测证据（把 `[启动探针]` 一步步打进去、重打包装机后复现）：

```
[启动探针] 0 进来了 args=[]
[启动探针] 1 绑定就绪
[启动探针] 2 不是独立窗口
        ← 再也没有 3；45 秒后一条 [WS] 都没有，却等到了一条 ANR
```

**第二处（就算引擎活了，点了也不会跳）：payload 在「Activity 新建」这条路上被插件丢掉了。**

`flutter_local_notifications` 只在 `onNewIntent` 里分发 payload
（`sendNotificationPayloadMessage` → `didReceiveNotificationResponse`），而 Activity **新建**时走的是
`onAttachedToActivity`，那份代码**只处理 `SELECT_FOREGROUND_NOTIFICATION_ACTION`** ——
也就是说 App 已经活着（引擎热着）时点通知，**payload 根本不会交给 Dart**：界面起来了，却停在原地。

#### 四、改了什么（两处，都很小）

1. `lib/main.dart`：那句 `setPreferredOrientations` **加 2 秒上限**
   （`.timeout(…, onTimeout: …)`），超时就继续往下走，并留一行
   `[启动] 没有界面可锁方向，先继续` —— **这行出现就等于「这次是无界面引擎启动」**，
   是这条链上最有用的诊断。安卓那侧「锁死竖屏」的硬锁本来就在 `AndroidManifest.xml`，
   这一句只是 Flutter 自己的方向偏好，晚一步 / 收不到都不影响竖屏。
2. `android/…/MainActivity.kt`：`onCreate` 里，**若这次启动之前引擎就已经在跑**
   （`FlutterEngineCache.contains(AudioServicePlugin.getFlutterEngineId())`，必须在 `super.onCreate`
   之前看）**且 intent 正是通知点击**，就手动 `onNewIntent(intent)` 补一刀 ——
   插件在 `onAttachedToActivity` 里早把自己注册成了 Activity 的 `OnNewIntentListener`，
   超级类会把这次事件转给它，于是它就去发 `didReceiveNotificationResponse` 了。
   不用碰插件的内部 API，走的就是「App 已在前台」那条能正常工作的路。
   **只在「引擎本来就在跑」时补**：冷启动那条路走 `getNotificationAppLaunchDetails()`，
   再补一刀会跳两次。

#### 五、验过 / 没验

* 验过（真实退出码）：`dart format`、`flutter analyze lib` **No issues**、全量 `flutter test`
  **2174 条全过**（EXIT=0）；此前那一轮的 `chat_page` / 小窗两处改动也仍在（2150+ 条那一次全过）。
* 验过（真机，**最终代码**、装机后原样重放，两条都过）：
  * 消息：`force-stop` → `am start-foreground-service …AudioService`（＝推送到达，把引擎热出来）
    → `am start -a SELECT_NOTIFICATION … --es payload group-3` →
    `[通知] 点了通知：_PayloadKind.conversation / group-3` → `[路由] /（1 页）→ /（2 页）`，
    屏幕上是「媒体号」那个会话页（`uiautomator` 里能看到返回/媒体号/搜索与那一串资讯列表）；
  * 通话：同一条流程 + `--es payload '<一整条 calling 报文>'` →
    `_PayloadKind.incomingCall` → `[来电] 推送里的来电接进通话链路：u2（语音）` →
    `[通话] 收到信令：calling code=901` → `[路由] /（2 页）`，屏幕上是通话页
    （整屏偏暗、底部一排按钮；`uiautomator` 那时读到的是下面那一层窗口，别被它骗了）；
  * 修之前同一条流程是：Dart 零日志 + 整屏白（`screencap` 三段采样 255/255/255）。
* 没验：**系统那一层**的干扰（三星 `FreecessController` 一直在对我们的包做冻结尝试、
  日志里能看到 `FZ error : cc.gracelink.im`）。本次修复不依赖它，但如果真机上还偶发
  「点通知没反应」，那是另一个方向：看 `dumpsys activity processes` 里那个进程有没有被冻住。

#### 六、复现 / 回归用的命令（不用真推送也能重放这条路）

```bash
adb logcat -c
adb shell am force-stop cc.gracelink.im
# 推送到达那一刻：FCM 把进程拉起来，audio_service 顺手把共用引擎「热」好
adb shell am start-foreground-service -n cc.gracelink.im/com.ryanheise.audioservice.AudioService
sleep 4
# 用户点通知（payload = 会话 id；来电就传一整条 calling 报文）
adb shell am start -a SELECT_NOTIFICATION -n cc.gracelink.im/.MainActivity --es payload group-3
sleep 7
adb logcat -d | grep -E '启动\]|通知\]|路由\]'
```

⚠️ `am start-foreground-service` 是我用来模拟推送暖机的命令，它会在 ~5 秒后带出一条
「startForegroundService 没有 startForeground」的 ANR ——**那是这条命令自己的副作用，
真机推送走 FCM 广播不会有**（想避免就压在 5 秒内点完通知）。

#### 七、接下来

1. **手机真机上再走一遍用户本人的那台**：让用户按平时的用法（上滑清掉 → 等真推送 → 点通知）
   试一次，日志里应当能看到 `[启动] 没有界面可锁方向，先继续`。
2. `[启动] 没有界面可锁方向，先继续` 这条日志可以当长期哨兵：**它一出现就说明这次启动
   是无界面引擎**（推送把进程拉起来），值得在别的「后台启动」问题上继续用它。
3. 还没查的邻居：无界面引擎里 `gracelinkim/app_settings` 那些**在 MainActivity 里注册的自定义
   通道不存在**（日志里那句 `[后台开关] 查询通知权限失败：MissingPluginException…`）。
   目前都被 try 住了、不影响这条路，但「后台启动时用得到自定义通道」的逻辑要格外小心。


---

### S12.44 「电脑端设置的『音视频通话』点开是白纸」（2026-10-10 用户报的）

#### 一、现场

用户原话：**「电脑端设置的音视频通话点开是啥都没有的这体验很不好，要么有东西，要么就不要有这一栏」**。

原因很直白：那一页原来只有三行，**三行在桌面上都不存在** ——

* 「通话保活通知」：`CallKeepAlive.supported == false`（非安卓）→ `SizedBox.shrink()`；
* 「来电全屏显示」：`BackgroundHealth.supported == false`（非安卓）→ `SizedBox.shrink()`；
* 「前台服务自检」：`kDebugMode` 才画 → release 包里也没有。

于是电脑端（release）点进来就是一张白纸 —— 而不是「入口不该显示」：设置里那个入口
在桌面上是正常摆着的（`app_router.dart` 的 `_desktopPage(const CallSettingPage(), …)`）。

#### 二、改了什么

1. **新增 `lib/domain/call/call_route_info.dart`**：从站点配置（`ChatInfo`）算出
   「**这一通电话实际会用的 ICE 线路**」——公共 STUN 六条 → 站点那一台 → 客户端内置 TURN，
   口径与真正建连接用的 `CallMediaConfig.iceServers` **完全一致**（显示的和实际用的不一样的话，
   这个页面就只剩误导），所以不碰插件、可整体单测。
2. **新增 `lib/features/call/call_route_row.dart`**：设置里的「通话线路」一行 + 点开的明细弹层。
   行上是结论（**绿 = 已配置 TURN / 橙 = 仅 STUN**），弹层里是那句人话结论、三段清单（含
   「站点没有配置，用的是兜底地址」「需不需要账号」）与「复制线路」。
   两端的形状都照顾了：手机是底部弹层，桌面是居中窗口（`showAppSheet`）。
3. **`call_setting_page.dart`**：这一行接在最上面，**任何平台上都有东西**（安卓那几行照旧按平台自己出现）。
4. **`CallMediaConfig.hasIceScheme`**：把 `normalizeIceUrl` 里那段协议头判断提出来复用。
5. **顺手把一个会静默失效的配错变得看得见**：站点那栏填 `turn.example.com:3478`（漏掉 `turn:` 前缀）时，
   `normalizeIceUrl` 会把它当 **STUN** 发出去 —— 一台 TURN 静默变成一台 STUN，双方都在严格 NAT
   后面时打不通，界面上看不出任何异常。现在：行上只说「**仅 STUN**」（不再谎称「仅公共 STUN」，
   因为站点那台并不是公共的），弹层里用橙字点出来「站点填的『…』会被当作 STUN 发出去；要用 TURN
   得写成 turn:主机:端口」。判断很窄（**没写协议头 + 主机名以 `turn` 开头**），正常 STUN 主机名不会误报。
6. 7 份语言包 +14 条 key（`call.route*`）。

#### 三、验过 / 没验

* 验过：`flutter analyze` **No issues**；全量 `flutter test` **2268 条全过**（EXIT=0）。
* 验过（新用例）：`test/domain/call_route_info_test.dart` 6 条（口径、兜底、`turn@` 写法、
  漏前缀的识别、与 `iceServers` 逐条对账）；`test/features/call_setting_page_test.dart` 5 条 ——
  这份用例**特意把平台钉成「那两行都不存在」的样子**（`NoopCallKeepAlive` / `NoopBackgroundHealth`），
  验这一页仍不是白纸、点开逐条对得上、账号密码不露面、复制真的走了剪贴板。
* 没验：**真 Windows 窗口 / 真机**没有手点一遍（这一轮只有用例里的真实渲染树）；`ownTurnServers`
  仍是空的 —— 自建 coturn 之后「客户端内置 TURN」那一段才会长出来（规划书风险登记 #1 仍未动）。

#### 四、接下来

1. 顺手可做的下一格：站点后台若真有 TURN，写全 `turn:主机:端口`（页面现在会把这种写法看得出来）。
2. 桌面上点一下「设置 → 音视频通话」确认观感（一行白底 + 右值，点开是那张弹层窗口）。

---

## S12.43 iOS 版开工：工程配置 + 四条平台通道 + Dart 侧分支（2026-10-14）

#### 一、背景（用户原话）

> 我圣诞节买开发者账号，我也没有苹果手机给你真机调试，也没有苹果电脑，
> 不过 iOS 代码层面你先完善一下，之前很多功能都还没适配。

三个约束定下了这一轮的形状：**12 月之前没有账号**（签不了名、上不了 TestFlight）、
**没有 iPhone**（真机行为一律验不了）、**没有 Mac**（连编都编不了）。
所以这一轮只做「代码层面先完善」，并且把**能验的东西**尽量留在本机（配置守卫用例）
与 CI（macOS runner 上编包 + 模拟器真启动）。计划书与没验过的清单见
`docs/release/ios-plan.md`。

#### 二、做了什么

1. **`tool/audit/ios_support.js`（新）**：与 `macos_support.js` 同一个套路，读 pub 缓存列出
   每个依赖的 iOS 支持与**它要求的最低 iOS 版本**。跑出来的第一件事就值回票价：
   `firebase_core` / `firebase_messaging` 要 **iOS 15.0**，而模板留的是 13.0 ——
   这个错在 Xcode 上要等到第一次编译才报（本机永远看不到）。
   结论：**最低系统 13.0 → 15.0**（放弃 iPhone 6s/7 那几代，那几代停在 15.8，其实仍在支持内）。
2. **工程配置**（`ios/`）：五条权限文案（相机/麦克风/相册读/相册写/本地网络）、
   `UIBackgroundModes = audio + remote-notification`（**故意不给 `voip`**：那是 PushKit 的，
   声明了却不用，审核会问「你要它干什么」，做 CallKit 时再一起加）、
   `ITSAppUsesNonExemptEncryption = false`、七种语言的 `CFBundleLocalizations`
   （iOS **只看这里**，不看 pubspec）、`NSAllowsLocalNetworking`（开发联调用 http）、
   `tel` + `app-settings` 进 `LSApplicationQueriesSchemes`。
   新增 `Runner.entitlements`（`aps-environment`，三份构建配置都接上）与
   `PrivacyInfo.xcprivacy`（上传 App Store 必须的那份）；包名从 `com.example.gracelinkim`
   改成 **`cc.gracelink.im`**（与 macOS 同一个 App ID，一张票两个平台）。
   ⚠️ 隐私清单**光放文件不会进包**（Xcode 只打包被引用且在某一个 build phase 里的文件），
   所以 `project.pbxproj` 里把四处引用都接上了（PBXBuildFile / PBXFileReference /
   group children / Resources 那一相），并由守卫用例钉住 —— 一个“看着做好了、其实没进包”
   的文件正是这个仓库最想防的那种错。
3. **原生侧**（`ios/Runner/AppDelegate.swift`，**没有动工程文件**）：补上四条通道的 iOS 实现 ——
   `app_info.version`、`permissions.check/request`（摄像头/麦克风/通知，与安卓同一套语义）、
   `app_settings`（通知权限 + 跳本应用设置页；电池那两条如实回「iOS 没有这个东西」）、
   `call_service`（按语音/视频设 `playAndRecord` + `voiceChat`/`videoChat` 并激活，
   结束时关掉并把音乐还回去）。
   通道挂在 `engineBridge.applicationRegistrar` 上（引擎专门给「应用级通道」留的那条路，
   不是借插件的注册表）。**全挤在一个文件里是刻意的**：iOS 多一个 `.swift` 就要改
   `project.pbxproj`（多三处引用），而本机没有 Xcode，改坏一个字符的代价是「工程打不开」。
4. **Dart 侧**：`IosCallKeepAlive`（同一条通道，另一个机制：**激活音频会话**而不是起服务；
   不用轮询确认、不编通知文案、投屏是空操作）与 `IosBackgroundHealth`（只有通知权限那一道是真的
   → 会话列表那条红提示条与「设置 › 通知」那一行在 iPhone 上同样成立）。
   顺手把「通话保活通知」那一行改成按**平台**判（那条常驻通知是安卓独有的，
   iOS 的保活不产生任何通知），自检面板的说明也按平台分开写。
5. **守卫用例**（`test/core/ios_runner_test.dart`，16 条）：把上面每一条配置都钉住 ——
   权限文案一条不能少、后台模式不能多也不能少、包名不许留 `com.example`、最低系统 ≥ 15.0、
   **每条通道的每个方法名都要与 Dart 侧对得上**（对不上就是「功能静默消失」），
   还加了一条「Dart 侧新加的通道必须说清 iOS 上谁来实现」（以后加通道时会红，逼着先想一遍）。
6. **应用图标与启动图**（`tool/icons/make_ios_icons.js`，新）：模板里那 15 张图标是
   **Flutter 自己的青色标**，启动图是三张 **1×1 的空图**。现在图标从与安卓/macOS
   **同一个源图**生成（满幅 + **不带 alpha 通道** —— 苹果会拒透明图标，源图四角带透明，
   用同色底座铺平），启动图从应用内那张 logo 生成（168/336/504，与启动页那 180 的方块接得上）。
   脚本自带验收：尺寸、有没有 alpha、四角颜色，当场对一遍。
7. **CI**（`.github/workflows/ios.yml`，新）：macOS runner 上 `flutter build ios --release --no-codesign`
   + 模拟器真启动一次（`integration_test/boot_smoke_test.dart`，与 macOS 那条同一个用例）
   + 截图与日志当产物。**全都不需要开发者账号** —— 这是「没有 Mac」这件事的解法。

#### 三、验过 / 没验

* 验过：`flutter analyze` **No issues**；全量 `flutter test` **2332 条全过、1 跳过**（EXIT=0）。
* 验过（新增用例）：`test/core/ios_runner_test.dart` 19 条（配置守卫 + 隐私清单的工程引用 +
  图标像素对账 + 通道方法名对账）；
  `call_keep_alive_test.dart` 加了 6 条 iOS 契约（只发 video、不轮询、会话起不来收成
  `CallKeepAliveException`、旧包的 `MissingPluginException` 也收成同一个异常、投屏空操作）；
  `background_health_test.dart` 加了 3 条（通知权限照实读、电池那条恒 true、iOS 上不存在的两个动作回 false）。
* 没验（照实记，全部写进了 `docs/release/ios-plan.md` 第十一节）：**Swift 一行都没编译过**、
  `ios/` 的改动**没在 Xcode 里打开过**（pbxproj 是脚本改的，只做了括号配平与值替换计数）、
  **没有任何 iOS 设备或模拟器跑过**、CI 那条工作流本身也没跑过（本地推不了）。
* 顺带记一个踩过的坑：Dart 里 `'\s'` 这种**非 raw 字符串**会把反斜杠吃掉（`\s*` 变成 `s*`），
  正则于是去找一个真的字母 s，而且**不报错** —— 断言只会莫名其妙地拿到 null。
  这批用例里正则一律写成 `r'...'`。

#### 四、接下来

1. **推仓库 → 手点一次 `iOS 构建与自检`**，把 CI 跑绿（不需要账号，也不需要做任何 iOS 决定）。
   在没验证的地基上继续加 Swift，只会把「一次修十个错」变成「一次修三十个」。
2. 12 月买号之后的五步（建 App ID 并勾推送 → Xcode 自动签名 → Firebase 加 iOS 应用 + APNs Key →
   跑绿 CI → 出 TestFlight）写在 `docs/release/ios-plan.md` 第三节。
3. 然后才是真正缺的那一块：**CallKit + PushKit 来电界面**（iOS 上锁屏来电目前只能是一条普通通知；
   而要让进程被划掉以后还能被叫醒，只有 VoIP 推送这条路，它必须和 CallKit 一起做）。

---

## S12.45 通话「中转这条路」自检：TURN 到底有没有在承载媒体（2026-10-15）

#### 一、为什么还要做这一条

风险登记第 1 条（P2P 打不通）的答案是 TURN：**两边都躲在对称 NAT / 运营商大内网
后面时，直连（host / srflx）根本没有一条路可用**。到昨天为止它有两层已被证明的部分：

* `test/call/turn_credentials_test.dart`：凭据的解析与缓存（纯逻辑，跑得飞快）；
* 服务端真的在签发 —— 今天用 curl 当场复看了一遍（`POST /enterprise/im/turnCredentials`，
  带令牌返回 `stun:` 两条 + **带账号的 `turn:` 六条**，`expiresIn=86400`；不带令牌是
  `请先登录系统`）。

缺的是**最后一格**：媒体有没有真的从那条中转上过去。这不是小事 —— 域名被墙、
TURN 端口被封、凭据被拒、插件不认 `urls` 是数组，任何一条都会让「有 TURN 凭据」
变成一句空话，而**单测与 curl 一个都测不到**。而这件事又恰好不能靠
`live_call_dial_smoke_test.dart` 来验：那条要电话那头有个真人。

#### 二、做法：两个端点在同一个进程里，且**只许走中转**

新用例 `integration_test/call_relay_smoke_test.dart`（三条）：

1. **凭据**：走生产路径（登录 → `turnCredentialServiceProvider`）取凭据，
   空列表或没有带账号的 `turn:` 条目**当场红**（那正是「有的朋友打不通」）；
2. **中转**：建**两条** `RTCPeerConnection`（`iceTransportPolicy: 'relay'`），
   SDP 与候选**本地交换** —— 所以它一个真人也用不着。判据四条，缺一不可：
   * 收集到的候选**全部**是 `typ relay`（有一条不是就说明插件忽略了那条策略，
     这一跑什么都没证明 → 红）；
   * 两侧真的进入 `connected`；
   * 数据通道 ping → pong 走通（**这才是「有字节真的过去了」**；
     连接状态只说明 ICE 谈成了）；
   * 统计里选中那一对是 `relay → relay`（`getStats` 给不全就**明确跳过**，
     不假装）。
3. **音频**：两侧都挂同一只麦克风，判据是**双向字节都在动**（轨道到了 ≠ 声音在传 ——
   「接通了但听不到声音」正是这个）。没有输入设备就**明确跳过**，与
   `ios_call_media_smoke_test.dart` 同一套口径。

#### 三、证据（Windows 真机，2026-10-15）

```
[RELAY] 服务端给了 2 条：（无账号）stun:stun.cloudflare.com:3478 | …443
[RELAY]   · （账号 64 位）turn:turn.cloudflare.com:3478?transport=udp | …turns:…:443?transport=tcp
[RELAY] 候选[relay] candidate:… udp 8331263 104.30.145.19 65232   ← 八条，全是 relay
[RELAY] 两侧都进入 connected（用时约 503ms）
[RELAY] 数据通道来回一趟 ✓（291ms）
[RELAY] 统计：CallMediaSample(rtt=41ms, pair=relay→relay/, sent=0, recv=0, …)
[RELAY] 音频输入设备：0 个（这台机器没有 → 跳过取流）
```

**一条直连候选都没有**，选中那一对是 `relay→relay`，中转到连上 503ms、
数据一个来回 291ms —— 中转这条路的媒体面到此为止是**被证明过的**，而不是
「服务端配了密钥」。

#### 四、CI

`.github/workflows/ios-live-call.yml` 里加了一步，排在**拨号之前**：

* 它要账号（TURN 凭据要登录态），所以只能待在带 Secrets 的那条流水线里；
  放进 `ios.yml` 只会变成一条永远 SKIP 的步骤；
* 但它**不需要人接**，所以顺手加了 `relay_only = yes` 这个入口 ——
  想只验中转、不响任何人手机就选它（拨号那一步会跳过）；
* runner 的模拟器**是有麦克风**的（`docs/release/ios-plan.md` 第八节那张表里
  `音频输入设备：1 个` → `取流 OK tracks=1`），所以第 3 条（音频）在 CI 上会真的跑起来。

#### 五、验过 / 没验

* 验过：`flutter analyze` **No issues**；新用例在 Windows 真机上
  **3 passed**（第 3 条按设计跳过：这台机器没有输入设备）；
  `test/call/` 那批 **282 条全过**（TURN 那一层没被动过，回归确认）。
* 没验：**iOS 模拟器上还没跑过**（本地推不了，等你点一次 `iOS 真拨一通`
  —— 选 `relay_only = yes` 即可，`relay.log` 会作为产物传上来）；
  真机（iPhone）上的同一条也还没跑（要有账号 + 一台 iPhone）。
* 顺带一句：这一条**不**证明苹果独有的那几样（锁屏来电 / 划掉 App 后的唤醒 /
  后台不断线），那些仍然要 CallKit + PushKit + 真机。

---

## S12.46 iOS 系统来电界面（CallKit + PushKit）接线（2026-10-15）

#### 一、为什么做这一条

`docs/release/ios-plan.md` 第六节第 2 项，也是 iOS 上唯一还「缺一大块」的地方：

* 安卓那条来电体验是**我们自己画的**（全屏通知 + `setShowWhenLocked` + `CallForegroundService`），
  只要进程活着就没问题；iPhone 上**锁屏来电是系统的东西**，只有 CallKit 能画；
* 更要紧的是**被划掉之后还能被叫醒**：苹果的硬限制是「用户上滑划掉 App 之后，普通推送
  （含静默推送）不再唤醒它」，唯一例外是 **VoIP 推送（PushKit）** —— 而它要求你必须接
  CallKit，所以这两件事只能一起做。

所以这一轮的目标是「**接线**」：把「有一通来电」这件事交给系统那侧，把系统那侧的动作
（接听 / 挂断）接回我们这套状态机。**不是**「让 iPhone 上现在就弹出来」—— 那还差服务端
一条 VoIP 推送与一把 VoIP 证书（下面第四节）。

#### 二、做了什么

**Dart 侧**

* `lib/core/platform/callkit.dart`（新）：接口 `CallKit`（`supported` / `isAvailable` /
  `reportIncomingCall` / `reportEnded` / `takePendingCall` / `voipToken` / `lastError` /
  动作监听表）+ `IosCallKit` + `NoopCallKit`，provider 按平台分流。所有平台调用都收成
  「失败回一条原因 / 空值」，不让通道上的意外带倒整条链。
* `lib/features/call/call_push_host.dart`（改）：**「什么时候交给系统、什么时候收回来」
  那套判断**都在这里 —— 判据只有一条「App 不在屏幕上」：不看屏幕就报（那时我们自己
  那张通话页用户看不到），**前台不报**（再叠一层系统界面 = 同一通响两次、两个接听键）；
  同一通只报一次（拿 `messageId` 去重，报两次在锁屏上就是两条一模一样的来电）；
  一旦不再活跃（接听 / 挂断 / 超时 / 被换成另一通）→ `reportEnded` 收尾 ——
  不收的话锁屏上那个界面会一直挂着，用户以为对方还在打。
* 系统那侧按接听 / 挂断 → 回到 `CallController.accept()` / `hangup()`：
  **接电话的是状态机**（发 `acceptRtc`、取麦克风、建连），原生只管那个界面。
* 修掉一个真 bug：监听原先在 `initState` 里挂一次，而 `callControllerProvider` **会随
  登录 / 登出重建** —— 挂在旧实例上的监听从此再也不会响，现象是「登录之后收到来电，
  系统界面不弹、通知也收不掉」，而这条链上每一段单看都是对的。现在每帧盯
  `ref.watch` 当前那个控制器（`_attach`，幂等）。这个 bug 是写用例时被逼出来的：
  用例里先起 App 再登录，正好就是那条路径。

**原生侧**（`ios/Runner/AppDelegate.swift`，同一个文件，没动工程文件）

* `gracelinkim/callkit` 通道 + `CallKitBridge`：`reportIncomingCall`
  （`CXProvider.reportNewIncomingCall`，回执异步：`ok` / `reason` / `alreadyReported`）、
  `reportEnded`（`reportCall endedAt:`，结束原因映到系统认的那几种）、`takePendingCall`
  （App 被 VoIP 推送叫醒时 Dart 还没起来，报文先存在原生，取一次清掉）、`voipToken`、
  `lastError`、`isAvailable`；
* **原生 → Dart 走同一条通道反方向**（`invokeMethod("action", …)`，`kind` = answer /
  end / incoming / token）：`CXProviderDelegate` 的接听、挂断、与「系统把通话整个重置了」
  （`providerDidReset`，当成一次 end）都从那里上去；
* **PushKit**：`PKPushRegistry`（`voip` 类型）前台启动时注册；收到 VoIP 推送**就地**报给
  CallKit（苹果的硬规则，iOS 13 起：先去别处转一圈再报就算滥用推送，系统会掐掉 App），
  `completion` 收在一只「只放行一次」的盒子里（回执 + 5 秒兜底），报完再叫醒已经活着的
  Dart，**Dart 收下了才把暂存报文清掉**（不然下次冷启动会把这通早已结束的电话又接一遍）；
* **音频会话交给系统**：`didActivate audioSession` 复用保活那条 `CallAudioSession`
  （分类 `playAndRecord`），`didDeactivate` 如实关掉 —— 不关的话「麦克风正在使用」
  那个点会一直亮着；`CXProviderConfiguration` 语音 / 视频都支持、
  `maximumCallGroups = 1`（多人通话那个界面还没做）。
* `ios/Runner/Info.plist`：`UIBackgroundModes` 加 **`voip`**（PushKit 靠它才收得到；
  网上「iOS 13 之后不必再声明」是把两件事搞混了）。

**用例**

* `test/core/callkit_test.dart`（新，11）：接口契约 —— 参数怎么传、报失败**不抛**只带回原因、
  `takePendingCall` 只交一次、事件通道叫醒监听表、非 iOS 上是空操作；
* `test/features/call_system_ui_test.dart`（新，8）：**报给系统的时机**（后台要报 /
  前台不报 / 同一通只报一次 / 报失败不抛 / 按接听真的发出 `acceptRtc` / 冷启动那条报文
  接得起来 / 对端挂断与本机挂断都要收尾）；
* `test/core/ios_runner_test.dart`（+几条）：`voip` 模式必须在、PushKit 回调必须
  在同一轮里上报、`gracelinkim/callkit` 的方法名与 Dart 侧对得上；
* `integration_test/ios_callkit_smoke_test.dart`（新）：设备上的自检，判据**故意不是**
  「来电真的弹出来了」（模拟器上 CallKit 不工作，写死就是一条永久红），而是
  「通道在 + 上报要么成功、要么带回一条**非空**原因」。

#### 三、验过 / 没验

* 验过：`flutter analyze` **No issues**；上述三个用例文件 **43 passed**
  （`call_system_ui_test` 8 + `callkit_test` 11 + `call_page_test` 24 回归）；
  `flutter test` 全量 **2379 passed / 1 skipped**。验的是**接线与时机** ——
  真设备上的 CallKit 一条都没碰（那一层只能在 iPhone 上验）。
* 没验（**照实记，别把绿灯当整条路通了**）：
  * **真机一次都没验** —— 模拟器上 CallKit 不跑，`reportNewIncomingCall` 必回错误；
    「锁屏上那个界面长什么样、按了接听之后音频对不对、被划掉之后真能被叫醒吗」
    只有 iPhone 能答；
  * ~~**服务端那条 VoIP 推送还没写**：现在 iOS 上收到的仍是普通 FCM 数据推送 →
    锁屏上仍是一条普通通知，不是系统来电界面；~~
    **2026-10-15 当天补上了（见 S12.47）**：APNs 直连（VoIP topic）那条通道写完了，
    客户端也会把 `apns_voip:` 标识上报上去；**仍未验的只剩「真机上到底收到没有」**
    （要一把 .p8 钥匙 + 一台 iPhone）；
  * ~~**VoIP token 拿到了但没上报服务端**（只存在内存里）~~ **S12.47 做了**
    （`PushRegistrar.applyVoip` → 走既有 `bindUid` 的 `cid` 字段，服务端按前缀当另一行设备）；
  * 拨出去的那一侧**没接 CallKit**（我们自己的拨号界面照旧），要做系统级的发起
    得用 `CXStartCallAction`，那是另一件事。

#### 四、接下来

1. ~~服务端补 VoIP 推送（APNs VoIP topic + payload 形状）+ 收下 VoIP token；~~
   **2026-10-15 做完了（S12.47）**：补丁在 `gracelinkim-server-patch-20261015-voip-push`，
   部署步骤与验收命令见那里的「部署说明.md」；
2. 账号到手后：苹果后台建一把带 VoIP 推送权限的 `.p8` → 真机走一遍
   「锁屏弹出 → 按接听 → 真的说上话 → 挂断后界面收掉」；
3. 之后才是多人通话（`maximumCallGroups`）与拨出侧的系统界面。

---

## S12.47 iOS 锁屏来电的服务端那一半：APNs 直连 + VoIP 推送（2026-10-15）

#### 一、为什么必须自己开一条通道

S12.46 把「什么时候把来电交给系统」那套判断写完了，但整条路还差最后一格：
**服务端得发得出 VoIP 推送**。它不能借 FCM —— `apns-push-type: voip` 与
`apns-topic: <bundle>.voip` 这两个头 FCM 不给你传（它永远走普通 `alert` 通道），
而 PushKit **只认 voip 那一条**。所以只能拿 `.p8` 直连 `api.push.apple.com`（HTTP/2）。

顺带一个必须说清的语义差别：**同一台 iPhone 上现在有两条登记**
（服务端把它们当两台设备）——

| 通道 | 管什么 | 标识 |
|---|---|---|
| `fcm_ios` | 普通消息通知、以及「这通电话已结束」的收尾帧 | `fcm_ios:xxx` |
| `apns_voip` | **一通新来电**（锁屏 / 后台弹系统来电界面） | `apns_voip:xxx` |

老客户端（只报 `fcm:`）不受影响 —— 行为不退化，只是 iPhone 上的来电仍是一条普通通知。

#### 二、服务端改了什么（10 个文件，交付为补丁目录）

* 新增 `app/common/push/ApnsKey.php`：解析 `.p8`、签 **ES256** 的 provider token
  （**DER → r‖s 那一步不做的话苹果回 `InvalidProviderToken`**，而且从错误里看不出是格式问题）、
  拼 `/3/device/<token>`；topic 由 Bundle ID 加 `.voip`。
* 新增 `app/common/push/ApnsVoipProvider.php`：`apns-topic` / `apns-push-type: voip` /
  `apns-priority: 10` / `apns-expiration`；报文顶层字段与 FCM 那条**逐字一致**
  （客户端原生 `parseCallPayload` 读的就是它们），另加 `aps.content-available`
  （缺 `aps` 苹果回 `BadPayload`）、**不放 alert**（PushKit 不显示通知，界面由 CallKit 画）。
* **停设备的判据收紧**：只有 `410 Unregistered` / `BadDeviceToken` 才算「标识失效」。
  `DeviceTokenNotForTopic`、`InvalidProviderToken`、`BadTopic` 一律只算失败 ——
  它们是**我们这边**配错了（Bundle ID、钥匙权限、沙箱/生产），
  当成设备失效就会一次把所有 iPhone 停掉，而日志里看起来是「设备全失效了」。
* `PushProvider` 接口多了 `accepts(PushMessage)`：这是本轮的**关键一层** ——
  同一条 FCM 通道在安卓能画来电界面、在 iPhone 只能弹普通通知，
  服务商自己才知道自己那条路能干什么，所以由它回答、`PushManager` 统一问
  （被跳过的写进日志：`apns_voip 不发行这类推送`）。
* `PushMessage` 多了 `isCallCanceled()` / `isIncomingCall()`：收尾帧与「一通新来电」
  在旧代码里都是 `isCall = true`，但它们该走的通道完全不同。
* `FcmProvider` 支持两个登记名（`fcm` / `fcm_ios`），`fcm_ios` **不发行来电**
  （两条一起发 = 锁屏上系统界面 + 一条通知，两个「接听」）；`access_token` 改成
  **进程内静态共享**（两个登记名共用一张，不重复跑 Google 换 token）。
* `CurlHttpClient` 可选强制 HTTP/2，并**先查 libcurl 有没有编 nghttp2**：
  没有就带一句人话失败，而不是发出一个降级成 HTTP/1.1 的请求
  （苹果会直接断连，那个错跟「钥匙不对」长得一模一样）。
* `app/common.php` 的 `pushManager()` 注册三条通道；APNs 凭据不齐**不注册**
  （那时 iPhone 的来电退回 `fcm_ios` 那条普通通知，而不是每次白打一趟）。
* `tools/push_selftest.php` 从 100 多项扩到 **171 项**（新增 APNs 段：ES256 签名能被
  **公钥验签**、请求头、报文、错误映射、两个登记名的规则、token 共享）。
  顺手修了两处**既有**问题：共享 token 之后几条用例要显式 `forgetAccessToken()`；
  「传数组会报错」那两条在 **PHP 8** 上会当场 Fatal（`strlen(array)` 是 `TypeError`，
  不再是 PHP 7 的 warning）—— 现在两个版本的行为都如实记下来。

#### 三、客户端改了什么（要让 iPhone 真的收到，这一半也得在）

* `push_token.dart`：iOS 上 FCM 那条的登记名改成 **`fcm_ios`**（服务端靠它把来电排除
  在这条路之外）；新增 `apns_voip` 前缀与 `voipCidOf()`。
* `credential_store.dart`：`cidVoip` 与 `cid` **分开存**（它们是两行设备）。
* `push_registrar.dart`：新增 `applyVoip()`（拿到 PushKit 标识 → 落盘 → 上报；
  空串跳过、没注入回调就空操作、整段吞异常）；provider 里接上 `CredentialStore` 的读写。
* `call_push_host.dart`：拿到 VoIP 标识的两条路径（启动时 `voipToken()`、
  原生回调 `CallKitActionKind.token`）都上报一次。

#### 四、验过 / 没验

* 验过：
  * 服务端：`php -l` 全部通过；`php tools/push_selftest.php` → **全部通过（171 项）**
    （本机 php 默认没开 openssl/curl 扩展，跑的时候要带
    `-d extension_dir=…\ext -d extension=openssl -d extension=curl -d extension=mbstring`）；
  * 补丁自检：`node _patch/check-voip-push-patch.js` → **44 项全部通过**（只读文件，
    核对文件齐不齐、关键实现在不、有没有把真钥匙带进来）；
  * 客户端：`flutter analyze` **No issues**；`flutter test` 全量 **2385 passed / 1 skipped**
    （新增 6 条：`push_registrar_test` 5 + `call_system_ui_test` 1）。
* 没验（**照实记**）：
  * **一次都没真的推到苹果**：没有 `.p8` 钥匙、没有真机 —— 「苹果收下了没有、
    手机上弹了没有」只有真机能答（`.p8` 要到 12 月买号之后才有）；
  * **线上服务器的 curl 有没有编 HTTP/2 没验**（本机 php 没装 curl 扩展，
    那条判断只能在服务器上跑出来）；没有的话日志里会明说，出路是配 `[PUSH] HTTP_PROXY`；
  * **沙箱 / 生产填反**这件事一定会踩一次（表现是 `BadDeviceToken`）—— 测试期
    先用 `APNS_SANDBOX=true`，出正式包改 `false`，文档里写清了。

#### 五、接下来

1. 按补丁里的「部署说明.md」部署到测试服务器（含 `.env` 六项 + `php think clear`）；
2. 客户端出新包，iPhone 上确认设备表里出现 `apns_voip` 与 `fcm_ios` 两行；
3. 买号之后建 `.p8` → 真机走一遍「锁屏弹出 → 接听 → 说上话」；
4. 之后才是拨出侧的系统界面（`CXStartCallAction`）与多人通话。

## S12.48 删掉「通话线路」那一栏：它报的 TURN 结论是假的（2026-10-15 用户要求）

#### 一、为什么删

那一栏（S12.44，2026-10-10）只读三份**静态**来源：站点后台那栏
（`chatInfo.stun / stunUser / stunPass`）、代码里写死的公共 STUN、
`CallMediaConfig.ownTurnServers`（**刻意留空**）。而真正在通话里起作用的那一路 TURN 是
**服务端动态签发的 Cloudflare 短时凭据**（`POST /enterprise/im/turnCredentials`），它是在
**建 `RTCPeerConnection` 的那一刻**才并进来的（`call_media_engine.dart` / `call_host.dart` /
`sfu_peer_connection.dart`）—— 这一页压根看不到。

于是出现了最糟的一种界面：S12.45 那次实测里（八条候选全是 `typ relay`、中转 503ms 接通、
数据通道往返 291ms）**TURN 明明在承载媒体**，而这一栏写的是「没有可用的 TURN」「仅 STUN」，
还叫用户「去站点后台配置 TURN」。它把「TURN 好用」和「TURN 真挂了」显示成同一个样子，
既误导、又不能当判据。用户 2026-10-15 看到截图后的原话：「把这个直接删了」。

#### 二、删了什么 / 顺手处理的后果

* 删：`features/call/call_route_row.dart`（那一行 + 明细弹层）、
  `domain/call/call_route_info.dart`、`test/domain/call_route_info_test.dart`，
  以及 7 份语言包里 `call.route*` 共 **14 个 key**（`call.route*` 再无引用）。
* 后果：桌面上那一页剩下的行全是安卓专属，release 构建里点进去**又变白纸** —— 正是
  2026-10-10 用户报过的那件事。按同一句原话的后半段「要么有东西，要么就不要有这一栏」，
  改成**没有内容就不给入口**：`callSettingHasAnyRow()`（`mine/call_setting_page.dart`）与
  那一页真正会画出来的三行**同一套口径**，设置页两个布局都问它
  （`mine/setting_page.dart`；桌面左列的分类顺手从 `int 下标` 换成 `_SettingSection` 枚举 ——
  藏掉一整类时下标才不会错位，`settingCategory<N>` 这几个 key 的含义保持不变）。
* 「前台服务自检」那一行改成走 `callSelfCheckRowProvider`（默认 `kDebugMode`）：只为了让用例
  能像 **release 构建**那样把它关掉，从而验证「入口整栏消失」这条路（否则那条路在测试里
  永远不可达 —— `kDebugMode` 编译期就是 true）。

#### 三、验过 / 没验

* 验过：`flutter analyze` → **No issues found**；`flutter test` 全量 →
  **2387 passed / 1 skipped**（`EXIT=0`；改前是 2392，差额 = 删掉的那份 `call_route_info_test`
  与其后重写的这一页用例）。
  * `call_setting_page_test.dart` 重写为 6 条：那一栏确实没了（连带那句错结论）/
    桌面上剩下 debug 自检那一行 / release 里自检也不画 / 「来电全屏显示」只跟
    `backgroundHealth` 走 / **一行都画不出时入口整栏消失**（`功能` 一并消失、别的分组照旧）/
    有内容时入口照旧；
  * `desktop_windows_test` 那条「点开不是白纸」改成断 debug 自检那一行（宽窗那条路也覆盖）。
* 没验：真机观感 —— 「桌面 **release** 包里设置看不到『音视频通话』这一栏」要出一个正式包
  才能眼见（测试环境是 debug，那一栏是被 provider 顶掉后验的）。

## S12.49 macOS：三条自家原生通道（子窗 / 版本号 / 菜单栏），独立窗口在 Mac 上从来就没出现过（2026-10-15）

#### 一、为什么动这一块（用户的原话是「不是重头戏，你看着来」）

macOS 版 10-11 就已经出包并上架官网（`Gracelink.Mac.-1.0.0.dmg`），但 `macos/Runner/`
里一直只有两个 Swift 文件（`AppDelegate` / `MainFlutterWindow`），
A 块那三条自家通道（`gracelinkim/child_window`、`tray`、`app_info`）只有 Windows 有实现。

其中 `child_window` 那条**不是缺一个体验，是缺一大块功能**：桌面上每一扇子窗
（文章 / 灵听 / 媒体号 / 网页窗 / **通话窗**）都是 `hiddenAtLaunch: true` 建出来的，
`show` 那一声走的正是这条通道（Dart 侧见 `desktop_window_service.dart` /
`call_window_host.dart` 里「设好标题/大小/居中再 show，不然先闪一下 800×600」那行注释）。
macOS 上没有这条通道 → **窗口建出来了、只是永远藏着**：点文章 / 灵听 / 网页窗「没反应」，
来电话时那扇通话窗也不出现。顺带还有两个小口子：版本号读不到（「检查更新」报给服务端的
内部号永远是 0），以及 ✕ 直接退出、没有「缩回后台」。

#### 二、改了什么（`macos/Runner/` 三个新文件 + 两个老文件，都已进 pbxproj）

* **`ChildWindowChannel.swift`（新）**：`setTitle` / `setSize` / `center` / `show` /
  `close` / `guardClose`。挂上它的时机用插件给的公开回调
  （`FlutterMultiWindowPlugin.setOnWindowCreatedCallback`）。✕ 的语义照 Windows 搬：
  **没声明过的窗**（文章 / 网页 / 媒体号 / 灵听）✕ 就是关掉；**声明过的窗**（通话窗那颗
  webrtc 引擎，Dart 侧 `onCloseRequested` 会先发 `guardClose`）先回一条 `close_requested`
  让 Dart 收摊，等不到就 5 秒后照样关（与 Windows 的 `kChildCloseGraceMs` 同值）——
  没有这道兜底，那扇窗会永远关不掉（Windows 上真机踩过）。
  `close` 时先把 `contentViewController` 置空再关，引擎才会真的被释放
  （不然只是不可见，每颗 ≈56MB 留着）。
* **`AppInfoChannel.swift`（新）**：`gracelinkim/app_info` 的 `version`，从 `Info.plist`
  那两个由 Flutter 从 pubspec 展开的键读（`CFBundleShortVersionString` / `CFBundleVersion`），
  与 Windows 那边读 CMake 宏同一个来源。读不到就如实报错让 Dart 用常量兜底，
  不回一个「看起来对」的假版本号。
* **`TrayIcon.swift`（新）**：`NSStatusItem` + 「打开 / 退出」菜单（文案由 Dart 经
  `gracelinkim/tray` 递进来，与 Windows 的分工一样），✕ 走 `orderOut` 缩回后台。
  **闸门**：菜单栏图标没建起来就维持老行为（关窗 = 退出）—— 半成品会造出
  「窗口关掉了、程序还在跑、却叫不回来」那种状态。回来的路有两条：菜单栏那一项，
  以及点 Dock 图标（`applicationShouldHandleReopen`，不写它点 Dock 什么都不会发生）。
* **`MainFlutterWindow.swift`**：注册三条通道 + `performClose` 缩回后台（不走 delegate：
  主窗的 delegate 是 MainMenu.xib 接给 AppDelegate 的，抢过来会连带影响 Flutter 自己那套）。
* **`AppDelegate.swift`**：`applicationShouldTerminateAfterLastWindowClosed` 在图标就绪后
  回 false（关窗留进程），并补上 `applicationShouldHandleReopen`。

#### 三、验过 / 没验（照实记）

* 验过：`flutter analyze` → **No issues found**；`flutter test` 全量 →
  **2394 passed / 1 skipped**（`EXIT=0`，改前 2387，新增的 7 条里 6 条在
  `test/core/macos_runner_test.dart` 的「原生通道」一组、1 条是 entitlements 白名单）。
  那 6 条钉的是**契约**而不是实现：
  Dart 调的每个方法名 macOS 那边都得实现（画中画 / 拖窗除外）、`close_requested` 两边同名、
  子窗通道必须在建出任何子窗之前挂上、**Runner 下每个 .swift 都得在 `project.pbxproj` 的
  Sources 里**（忘了加进工程在 Windows 上报不出来）、app_info 与 tray 的键两边对齐、
  以及「关窗缩回后台」必须守在 `TrayIcon.isReady` 之后。
  这些错**一个都不会让本机报错**（`DesktopWindowNative` 的每次调用都吞异常），
  所以只能这样钉。
* **没验（本轮最大的缺口）**：**Swift 一行都没编译过** —— 本机是 Windows，编不了 macOS；
  这一批要等 `.github/workflows/macos.yml` 在 CI 上跑一遍才算「编得过」，
  而「窗口在屏幕上摆得对不对、菜单栏图标长什么样、✕ 缩回后点 Dock 能不能回来」
  只有真 Mac 能答（租一小时云 Mac 就能过验收清单）。
* 屏幕共享要不要加 entitlement —— **2026-10-15 查清了：不用加**。Apple 的 entitlements 列表里
  没有 `com.apple.security.device.screen-capture` 这个写法（与屏幕捕获相关的只有
  `com.apple.developer.persistent-content-capture`，那是给 VNC 那类「持续捕获」应用的）；
  普通捕获要的是「系统设置 → 隐私与安全性 → 屏幕录制」里那一下授权，
  客户端自己会请求它（`flutter_webrtc` 的 `requestCapturePermission` →
  `CGRequestScreenCaptureAccess`）。所以两份 entitlements **一个字都没改**，
  改成用用例把白名单锁住（新加的那条「只有这几条是我们有意加的」）：
  以后想塞新键，得先把它加进那份名单并写清理由 —— 免得再出现「以为配上了、
  其实真正的授权根本没要到」。来源见 Apple 的 Entitlements 列表与
  `CGRequestScreenCaptureAccess()` 文档，链接与推理过程记在 `docs/release/macos-plan.md`。
* 真机上还差一步：那个「屏幕录制」授权框在 **ad-hoc 签名（未公证）**下会不会每次重建都要一次 ——
  Apple 官方文档没有承诺过，开发者论坛有「重建后又要授权」的报告，只有真 Mac 能答。
