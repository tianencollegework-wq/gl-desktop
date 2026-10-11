# 群通话：Cloudflare Realtime SFU 契约

来源：Cloudflare 官方文档（2026-09 核过 `realtime/sfu/api/`、`concepts/architecture/`、
`concepts/sessions-tracks/`、`concepts/negotiation/`、`platform/limits/`）与 `REFACTOR_PLAN.md`
里 2026-09-26 的决策（走裸 SFU，不走 mesh、不买 SDK）。

## 一、角色划分（谁拥有什么）

| 角色 | 拥有 |
| --- | --- |
| Cloudflare SFU | WebRTC 连接与**媒体转发**（音频/视频/DataChannel）。**没有**房间、成员、发现、权限 |
| 我们的 PHP（`/enterprise/im/sfu/*`） | 持有 App Secret、校验"是不是这个群的成员"、维护房间注册表、把端点 SDP 转给 CF |
| Flutter 客户端 | 采集媒体、持有 PeerConnection、应用 SDP、订阅对账 |

**媒体一个包都不经过我们的服务器**：音视频是「端点 ↔ Cloudflare」直连，我们只中转几百字节的
SDP/控制面。所以代理只影响建连与重协商的延迟，不影响通话质量。

## 二、每个参与者只开 2 条会话（这是与 mesh 最大的区别）

| 会话 | 用途 | 说明 |
| --- | --- | --- |
| **发布会话** | 发布自己的麦克风（+ 共享屏幕时多一路 video track） | `purpose = publish` |
| **接收会话** | 订阅房间里其他人的音频 + 共享屏那一路视频 | `purpose = receive`，一次批量订阅 |

官方文档明说：一个 session = **一条 PeerConnection + 一个 offer/answer 状态机**，且
separate publishing / receiving sessions 能简化所有权模型 —— 我们按这个形状来。

**每人订阅量**：`(N-1) 路音频 + 最多 1 路共享屏视频`。9 人 ≈ 9 条 track，
远低于 CF 单次请求 64 条的上限 → **一次 `tracks/new` 批量订阅全房间**。

## 三、我们的接口（全部 `POST`，沿用现有 JWT 鉴权与 `{code,msg,data}` 信封）

路径前缀 `/enterprise/sfu/`（独立的控制器 `app/enterprise/controller/Sfu.php`，**不并进 Im.php**）。
除特别注明外都需要登录态，且服务端必须校验**请求者属于该群**。

> 动作名都选**单个小写单词**（`session` / `close` / `room` …）：不依赖框架对驼峰动作名的转换，
> 少一处会踩的坑。服务端补丁包里的 `check_server.js` 会把“客户端路径 ↔ 控制器动作”
> 逐个对一遍。

| 接口 | 请求体 | 响应 `data` | 映射到的 CF 调用 |
| --- | --- | --- | --- |
| `session` | `{room_id, purpose}` | `{session_id}` | `POST /apps/{appId}/sessions/new` |
| `publish` | `{session_id, sdp_offer, tracks:[{track_name, mid}]}` | `{sdp:{answer}, tracks:[{track_name, mid, status}]}` | `POST …/sessions/{id}/tracks/new`（`location:"local"`） |
| `subscribe` | `{session_id, tracks:[{session_id, track_name}]}` **不带 offer** | `{sdp:{offer}, tracks:[{track_name, mid, status}], requires_renegotiation}` | `POST …/sessions/{id}/tracks/new`（`location:"remote"`） |
| `renegotiate` | `{session_id, sdp_answer}` | `{}` | `PUT …/sessions/{id}/renegotiate` |
| `closeTracks` | `{session_id, mids:[…], sdp_offer?, force?}` | `{sdp:{answer}, tracks:[…]}` | `PUT …/sessions/{id}/tracks/close` |
| `roomState` | `{room_id}` | `{members:[{user_id, session_id, tracks:[track_name]}], epoch}` | 无（读我们的注册表） |
| `heartbeat` | `{room_id}` | `{epoch, member_count}` | 无（续注册表的命） |
| `mute` | `{room_id, muted}` | `{}` | 无（只写注册表，触发 WS 推送） |
| `leave` | `{room_id, session_ids:[…], closing?}` | `{closed, announce, duration, participants}` | `PUT …/tracks/close(force)` + 注册表清理 |

`roomState` 的服务端路径是 `…/room`（动作名都用单个小写单词，同前），客户端那边叫 `SfuPaths.roomState`。

### 发布与订阅**不对称**（照 CF 的 connection patterns 抄，别自己发明）

**发布（端点出 offer）**

1. `getUserMedia()` → 每条 track `addTransceiver(track, {direction: sendonly})`；
2. `createOffer()` → `setLocalDescription()`；
3. **等候选收齐**（非 trickle），再从 transceiver 上读 `mid`；
4. `publish`（带上 `sdp_offer` 与 `track_name/mid`）；
5. `setRemoteDescription(返回的 answer)` —— **这一步不需要 renegotiate**。

**订阅（SFU 出 offer）**

1. 新建一条 PC，装好 `onTrack` 回调；
2. `subscribe`（**只报要谁的哪条 track，不带 offer**，可一次多条、可跨发布者）；
3. 拿到的 `sdp.offer` → `setRemoteDescription()` → `createAnswer()` → `setLocalDescription()`；
4. **等候选收齐**后走 `renegotiate` 把 answer 交回去；**等 API 接受**才算完成；
5. `onTrack` 里用 `event.transceiver.mid` 对上「哪条是订阅的谁的 track」。

**加媒体到已有连接**（共享屏就是这条）：加 transceiver → 重新 `createOffer/setLocalDescription` →
**等候选** → `publish` 只带**新增**的那几条 → 应用返回的 answer。

**关 track**：`stop()` 掉 transceiver → 重新出 offer → 等候选 →
`closeTracks(mids, sdp_offer)` → 应用返回的 answer（拿不到 answer 时走 `force: true` 直接关）。

> 三处最容易漏的：**每次发 SDP 前都要等候选收齐**（而且是**封了顶的等**，见下）；
> 订阅的 offer 是 **SFU 发的**；
> `setRemoteDescription` 之后 `signalingState` 回到 stable **不代表**服务端已经接受了 answer
> （官方原话），必须等 `/renegotiate` 的响应。
>
> 还有一条：**应用完 answer 要等到 ICE 连上**（`onConnectionState == connected`）才算这一步做完，
> 之后再往这条会话上发请求。等不到（超时）就按"结果未知"处理 → 换新会话重建，
> 不要在同一会话上接着改。

### 实现对照（客户端已落地，2026-09-26）

| 契约要求 | 落在哪 | 关键决定 |
| --- | --- | --- |
| 非 trickle：每次发 SDP 前等候选收齐 | `IceGatherBarrier`（`lib/domain/group_call/sfu_ice_gathering.dart`） | 等 `onIceGatheringState == complete`，**最多 5 秒就放行**：这次等待在**会话队列内部**，等不到也必须走，否则整条会话的改动全被堵死 |
| 发出去的必须是**收齐候选之后**的 SDP | `WebrtcSfuPeerConnection._swapOffer` | 读 `pc.getLocalDescription()`，**不是** `createOffer()` 的返回值（那份里还没有候选） |
| 应用完 answer 等到连通 | `SfuRoom`（发布/订阅各一次） | `pc.waitConnected(connectTimeout = 10s)`；超时 → `4005` → 毒化 + 重建 |
| 同一会话串行 | `SfuSessionQueue` | 一次改动 = 整轮 SDP 交换 |
| 按 `roomState` 对账订阅 | `SfuRoom._diffOf` | 三种情况：新增 / 消失 / **同一条 track 但发布者换了 sessionId** → 退订**再**重订 |
| 订阅 mid 的记账时机 | `SfuRoom._addSubscriptions` | 拿到 `tracks[].mid` 后**先记账再作答**（`onTrack` 可能比 `/renegotiate` 早），谈不成要撤销记账 |
| 远端流认人 | `SfuRoom._watchIncoming` + `incomingMedia` | `onTrack` 的 `transceiver.mid` → `SfuIncomingMedia{userId, trackName, kind, stream}`；**认不出来的 mid 丢弃**（重建期间旧 mid 作废） |
| 本机媒体只采一次 | `SfuLocalMedia`（`lib/data/media/sfu_local_media.dart`） | 两条会话共用同一条轨道；共享屏顺序仍是「投屏同意 → 前台服务升 `mediaProjection` → `startScreen`」 |

> ICE 服务器**不在这里下发**：客户端复用已有的 `POST /enterprise/im/turnCredentials`
> （S6.9，2026-09-26 真机验证 relay 分配成功）。两条会话都用它当兜底。

## 四、必须遵守的三条硬规则（写错就会出现"偶发怪话"）

1. **同一 session 的改动必须串行**，而且**一次改动要跨越完整的 SDP 交换才算完成**
   （发 offer → 等 CF 的 answer 应用完；或应用 CF 的 offer → 把 answer 交回）。
   并发提交同一个 session 的请求会被 CF 拒绝（HTTP 406）。
   实现：`SfuSessionQueue`（每会话一条队列，操作在队列里保持到交换结束）。
2. **结果不确定时不要重试，要换一条新 session 重建。**
   官方原话："Application-level duplicate detection does not make an SFU request safe to repeat"。
   重复 `tracks/new` 会**重复分配**订阅。所以：超时/网络错/我方 5xx → 判为**未知结果** →
   毒化该会话 → 房间状态机建新会话、重新发布、重新订阅。
3. **订阅是"发布者 sessionId + trackName"**，这份映射由我们的**房间注册表**维护并靠现有 WS
   广播给房间成员（CF 不提供房间发现）。发布者掉线重建会**换一个 sessionId** →
   其他人必须重新订阅（注册表要带 `epoch`，客户端按 epoch 收敛）。

## 五、错误码（我们的信封 `code`，服务端把 CF 的错误翻成它们）

| code | 含义 | 客户端处理 | 来自 CF 的什么 |
| --- | --- | --- | --- |
| `0` | 成功 | — | — |
| `4001` | 参数不合法 | 报错、不上屏 | 400 / 校验失败 |
| `4002` | 会话不存在或已过期 | **重建会话** | 410 `session_error` |
| `4003` | 会话冲突（同一会话并发改动） | 修好顺序后**重新发起**，不重建 | 406 |
| `4004` | 上游鉴权失败（我方 App Secret / 配置问题） | 报错（运维修） | 401 |
| `4005` | 上游不可达 / 超时（结果未知） | **重建会话** | 超时 / 5xx |
| `4006` | 不是这个群的成员 | 提示无权限 | 无（我们自己的判定） |
| `4007` | 房间人数已满 | 提示人数已满 | 无（我们自己的判定） |
| `4008` | 逐条 track 失败 | **看响应体里的 `tracks[]`**，HTTP 200 不代表每条都成功 | 200 里的 per-track error |

> 注意 `4008` 形态：CF 的整包 200 里面可以**逐条**报错，所以客户端必须看
> `tracks[].error_code`，不能只看 `code == 0`。

两条判定要分清：

* **明确被拒**（4001/4003/4006/4007，以及任何 200 里逐条返回失败的 track）：什么都没发生，
  会话仍然可用，修好触发条件后重新发起即可；
* **结果未知**（4002 会话过期、4005 超时/上游 5xx、以及客户端侧的断网/超时）：
  **一律按"可能已经生效"处理** —— 这正是毒化 + 重建而不是重试的原因。

CF 的 406 归到"明确被拒"：官方举的例子就是并发提交被拒，那种情形下 CF 没有应用任何东西，
修法是让改动串行（`SfuSessionQueue`），而不是重建会话。

## 六、房间注册表（服务端状态，客户端不可省）

```
sfu_room_member(room_id, user_id, purpose, session_id, tracks, mids, updated_at)
```

* `purpose = publish` 的行才有 `tracks`（track_name 列表）；`receive` 行的 `tracks` 恒为空；
* `session_id` 是**发布会话**的 id —— 订阅别人时用它；
* `mids` 存本会话的 `mid=trackName`：关共享屏、离开房间时要靠它把“关掉的 mid”
  翻回“哪个 track 不再发布了”（客户端下发的 `mids` 只有数字）；
* **心跳**：客户端进房间后每 **20 秒**一次 `heartbeat`（`publish` / `room` 也会顺手续命），
  服务端清掉超过**行超时**没动静的行（**封顶 45 秒**；CF 侧媒体 30 秒没有包就会回收 track）；
  发布之后一直不动的客户端如果没心跳，就会被当成掉线清掉、别人会退订他的声音；
* **清场（`prune`）有两个入口**：`room`（拉快照）与 `heartbeat`。以前只有前者，
  而客户端"该不该拉快照"看的是版本号变没变 —— 掉线的人不会自己写注册表、版本号不变，
  于是清场永远不跑（真机上的"人都走了还写着他在共享"）。
* `leave` 与"掉线重建"都要删/换行，并广播 `epoch` 变化（WS `sfuRoom` 推到**群频道**）。
  心跳回包里也带 `epoch`：客户端发现对不上就重新拉快照 —— 推送丢了也能自愈。
* 另外两处**只服务端有**的状态（都不进注册表，免得被当成"房间里的人"）：
  * `sfu_meta_{room}`（缓存）：这通话什么时候开的、期间到过谁 —— 最后一个人挂断时
    靠它算出「打了多久、几个人」（注册表只有 `updated_at`，人一走行就删了，算不出来）；
  * `purpose='closed'` 的哨兵行：谁把它插进去（撞唯一键）谁就拿到「这一通结束了」的
    广播权 —— 两个人前后脚挂断时不能各往群里写一条记录。它会被所有读注册表的地方
    按 `purpose` 过滤掉，并在下一通电话开始（或被 TTL 清理）时消失。

## 七、实现顺序（对应重构计划的分期）

| # | 做什么 | 状态 |
| --- | --- | --- |
| 1 | `SfuSessionQueue` + 失败分类（纯逻辑、带单测） | ✅ 已落 |
| 2 | `SfuApi` 8 个接口（含 heartbeat），字段用单测钉死 | ✅ 已落 |
| 3 | 发布/接收两条会话的 SDP 交换（`WebrtcSfuPeerConnection` + `WebrtcSfuLocalMedia`） | ✅ 已落（真机验收待做） |
| 4 | 房间状态机：按 `roomState` 对账订阅、epoch 收敛、掉线重建、心跳 | ✅ 已落 |
| 5 | 服务端：`Sfu.php`（8 个动作 + 注册表 + 心跳 TTL） | ✅ 已落（补丁包 2026-09-26-sfu） |
| 6 | 共享屏：把 `SfuLocalMedia` 的 screen 流作为第二路 video track 发布（`track_name = "screen"`） | ✅ 房间层已落（界面按钮待做） |
| 7 | 界面：主区域（共享屏 / 说话人 / 头像墙）+ 成员列表 + 静音/挂断；群资料页入口 | ✅ 已落（`GroupCallController` + `GroupCallPage`） |
| 8 | WS `sfuRoom` 事件处理（收到就 `refreshRoomState()`） | ✅ 已落（`GroupCallHub` + `GroupCallSyncService`） |
| 9 | 诊断面板（订阅 / 会话 / 计数 / 时间线，长按打开） | ✅ 已落（`SfuTrace` + `group_call_diagnostics_sheet.dart`） |
| 10 | 群里的通话记录（房间空了由最后一个走的人落一条） | ✅ 已落（`Sfu.php::leave` 回包 + `MessageSender.sendGroupCallRecord`） |
| 11 | 离线叫醒：群里有人开语音时给没打开 App 的成员响铃（房间空了收掉） | ✅ 已落（`Sfu.php::ringGroupCall` / `endGroupCall` + `group_call_push.dart` + `GroupCallPushHost`，见第十三节） |
| 12 | 在线的应用内提示（别人开语音时给正在用 App 的人一条横幅 + 会话列表标记） | ✅ 已落（`GroupCallPresenceTracker` + `GroupCallBannerHost`，见第十四节） |
| 13 | 进群以后的两处（群里顶上那条常驻提示；点历史记录先看详情卡） | ✅ 已落（`GroupCallBar` + `group_call_record_sheet.dart`，见第十五节） |
| 14 | 退出通话页不挂断（通话常驻 + 小窗 + 「回到通话」） | ✅ 已落（`GroupCallSession` + `GroupCallMiniBarHost`，见第十六节） |

## 九、界面这一层（2026-09-26 落）

* **`GroupCallController`**（`lib/features/group_call/`）：把房间状态机、群成员名单、
  本机开关、保活串起来；名单来自 `groupAdminRepository.members(群会话 id)`
  （房间注册表只有 user_id，它不认识名字/头像），拉不到只是名字退化成「群成员」，
  **绝不影响通话**；
* **共享屏的三步顺序**（Android 14 硬要求）：投屏授权 → 前台服务类型升 `mediaProjection`
  → 取流发布；失败回滚类型位。与 1:1 那条路径逐字一致；
* **`GroupCallPage`** 主区域三种形态：有人共享屏 → 那块画面（左下角写明是谁在共享）；
  有人说话 → 说话人放大 + 其余人一条排在下面；都没人说话 → 头像墙（列数按人数）；
  另外**自己在共享时不回传自己**，所以显示一张「正在共享」的牌子；
* **说话人判定**（`SfuSpeakerTracker`）：能量取自接收会话的 `getStats()`→
  `inbound-rtp` 的 `audioLevel`，按**接收侧 mid**归位到人；阈值 0.02 + 保持 1.2 秒
  （说话换气不闪）。插件不给这个字段时就是「没人说话」→ 头像墙，**不猜**；
* **音频路由**：进房间（媒体已经在手上）之后调一次 `setSpeakerEnabled(true)` ——
  与 1:1 那条同一个口径（`Helper.setSpeakerphoneOn`）。不调的话安卓会按「通话模式」
  默认走**听筒**：群里别人说话会小得像在远处，而微信群语音默认就是免提。
  切不去也不影响这通电话（只记日志）。
* 入口**只在消息流的「＋」面板里**（与单聊那颗「语音通话」同一个位置）——
  2026-09-27 用户要求把群资料页那一行「群通话」删掉（两处入口反而让人拿不准哪个是真的，
  而且「＋」面板本来就有）；1:1 通话中不给进，弹一句提示（`callBusyProvider`）。
  进房间前那一瞬的等待文案是「**正在连接恩信全球智能网络**」
  （`group.callJoining`，原来那句干巴巴的「正在加入...」按用户 2026-09-27 的要求换掉了）。

## 十、谁把 WS 推的事件接进房间（2026-09-26 落）

房间对象挂在通话页上，WS 推的 `sfuRoom` 落在 WS 层 —— 中间那个东西是
`GroupCallHub`（`lib/domain/group_call/group_call_hub.dart`）：

* 通话页 `start()` 时 `attach(room)`、挂断 / 销毁时 `detach(room)`（同一时刻最多一个）；
* `onRoomChanged(roomId, epoch)` ：**只理自己那个房间**（推送里的房间号对不上就直接忽略）；
  版本号（`epoch`）不比手里这份新就不发请求 —— 一次进出会 bump 一次，9 个人就是 9 条推送；
* 长连接恢复时 `onReconnected()` 再对一次账（断线期间的进出全补上）。

两个容易写错的地方（都有用例钉住）：**离开房间之后的推送不能再把它拉回来**
（`refreshRoomState` 在没发布会话时直接返回 —— 否则界面早关掉了还会重新建出接收会话）；
**没有登记的房间不建房间**（没在通话里收到推送只当没看见）。

## 十一、诊断面板（长按通话页）

群通话的问题与 1:1 不一样（没有"候选没有 / 只有 host"那几类，媒体是端点 ↔ CF 直连），
面板分的是另外三类：

| 在面板上看什么 | 结论 |
| --- | --- |
| 「订阅」那节里没有 `u2|mic → mid-…` | 订阅没建上：快照 / 权限 / 重协商的问题 |
| 有订阅却听不到人 | CF 侧或对方没在发（不是我们这一端） |
| 「重建」计数一直涨 | 网络或凭据问题（这通电话的体验一定差） |

数据源是 `SfuRoom.diagnostics`（纯逻辑在 `domain/group_call/sfu_trace.dart`，带单测）：
房间 / epoch / 两条会话 id / 我发布的 track / 订阅表 / 说话人 / 计数 / 时间线（只留最近 80 条）。
「复制」拿到的那段文本就是排查时贴给对方的东西。

## 十二、群里的通话记录（2026-09-26 落）

微信里打完一通群语音，群里会留下一条「通话时长 12:30」——那一块是这么分工的：

| 谁 | 做什么 |
| --- | --- |
| 服务端（`Sfu.php::leave`） | 最后一个走的人拿到 `announce = true`，并告诉他这通打了多久、期间到过几个人（底账见第六节） |
| 最后一个走的人（`GroupCallController._writeCallRecord`） | 把这条记录**当一条普通消息**发到群里（`MessageSender.sendGroupCallRecord` → `im/sendMessage`） |
| 所有人（与没进过通话的群成员） | 走普通群消息那条链收到：未读计数、离线推送、会话预览全在服务端那条链上 |

三个刻意的决定：

* **为什么让客户端发、服务端不直接写消息表**：客户端走的是它每天都在走的
  `im/sendMessage`（未读 / 推送 / 会话预览都在那儿），不用在 SFU 控制器里重现一遍
  消息系统的行为（重做一遍很容易漏掉未读与离线推送）；代价是最后走的那个人如果不告而别
  （App 被杀 / 没网），这一条就没了 —— 可以接受，别为它去做一套服务端消息写入；
* **消息类型沿用 `webrtc`、文案自己拼**（`content = "群通话 12:30"`，时长口径与 1:1 那条
  一致：分钟:秒）：老端的 `im-webrtc.vue` 就是直接显示 `content`，所以老网页端也能正常
  看到这条；`extends.group_call = 1` 是给新端的记号 —— 点一下进**群通话页**
  （1:1 那条的点击是回拨）；
* **只有 `participants >= 2` 才留记录**：一个人点进去又退出来，不值得在群里留一条。
  聊天列表里它的预览是「[语音通话]」占位（会话行只存 `last_type`，拿不到 ext）。

真实环境里对出来的两个边角（都不是 bug，写下来免得下次又查一遍）：

* 最后走的那个人是**连着建了两条会话的人**（发 + 收）——`leave` 要先把两条会话都报上去，
  服务端才会认为房间空了（`closing = true`）；重建时丢一条坏会话的那种 `leave` 不算收尾；
* 房间空了但**没人来认领**（比如最后一个人的行是被 90 秒 TTL 清掉的、而他已经不在了）：
  这通话就没有记录 —— 这也是「宁可少一条，也别冒出一条假的」的取舍。


## 十三、离线叫醒：群里有人开语音（2026-09-27 落）

「群里有人开语音」这件事，**只靠长连接是叫不醒人的**：`sfuRoom`（第十节那条）只发给在线的人。
所以这一块单独做成一次**离线推送**（1:1 的来电推送是 1:1 形状，不能直接重用）：

| 时机 | 服务端 | 客户端 |
| --- | --- | --- |
| 这个房间**第一次有人进来**（`Sfu::session` 建第一条会话） | 给「不在线 + 没静音这个群 + 不是发起人」的成员推一条 `groupCalling` | 后台 isolate 弹一条**能响铃**的群邀请通知（群名 + 「某某 邀请你加入群语音」） |
| 用户点那条通知 / App 是被它拉起来的 | —— | `GroupCallPushHost` 把整条报文捞出来 → 进**群通话页**（`?id=group-100&name=群名`），进去就是加入 |
| 房间空了（`leave` 拿到 `announce`，或 90 秒 TTL 把残骸清完） | 补一条**静默** `groupCallEnded`（只带 `call_id`，没有 body） | 后台 isolate 把那条邀请**收掉**（铃声跟着停） |

推送报文（`Sfu.php::pushGroupCall` 组装，`PushMessage` 摊平成 FCM 数据消息）：

```json
{
  "id": "100-1758888888-a1b2c3",
  "type": "group_call",
  "toContactId": "group-100",
  "fromUser": {"id": "7", "displayName": "张三"},
  "sendTime": 1758888888000,
  "extends": {
    "event": "groupCalling",
    "call_id": "100-1758888888-a1b2c3",
    "group_id": "100",
    "name": "项目群",
    "type": 0
  }
}
```

`PushMessage::dataPayload()` 把它摊平成 `type` / `event` / `contact_id` / `call_id` / `payload`
五样（与普通消息那条同一个信封），客户端的常量与判类在
`lib/domain/group_call/group_call_push.dart`（改一边就要改另一边，静态自检第 10 组会把两边对一遍）。

四个刻意的决定：

* **推送只管「叫醒」，不管「加入」**：报文里只有群名、群会话 id 与谁发起的 —— 点开之后走的是
  与群里「群通话」入口**同一条**路由，媒体/会话/保活全用那一套（服务端没有为推送另开建会话的路，
  接口与表结构因此一行没动）；
* **只有「第一笔」推**：这一通刚开时推一次足够把人叫醒，第二、第三个人进来不重复推；
* **推给不在线的人，且尊重免打扰**（与群聊离线推送同一个 `is_notice` 口径）：把一个群设成
  免打扰的人，不该因为群里有人开语音就被铃声叫醒；在线的人由应用内提示负责（还没做）；
* **结束也要推一条**（静默、不弹任何东西）：收到邀请的人恰恰是长连接不在了的那一端，
  「房间里没人了」他收不到 —— 少了这条，那条通知与铃声只能干等系统超时
  （与 1:1 那条 `callCanceled` 同一个理由）。

边界（写清楚，都不是 bug）：

* **App 开着、但没在群通话页的人不会响铃**：他们只收到 `sfuRoom`（第十节），走的是
  应用内横幅那条路（S6.15，见第十四节）—— 人就在手机前面，再响一声是骚扰；
* **通知只活 5 分钟**（客户端那半；服务端那条推送的存活时间是 60 秒）：一场语音打了半小时，
  中途才开机的人收不到 —— 那一下已经过去了；
* **一个人点进去又马上退出来**，群里其他人会先响一声、随即被收掉（与 1:1 拨了又取消一样）：
  真正在群里留下记录的门槛仍然是「起码两个人」（第十二节）。


## 十四、在线状态：App 开着但没在通话页的人（2026-09-27 落）

第十三节解决的是「App 没在跑」，这一节解决另一半：**人就在 App 里**（停在聊天页、
会话列表、随便哪个页面），别人在群里开了语音时他该知道 —— 但不该被系统通知响一声
（人就在手机前面）。两条路刻意分开，同一个人的两种状态各走各的：

| | App 没在跑 | App 在跑（本节） |
| --- | --- | --- |
| 怎么知道 | 服务端推 `groupCalling`（离线推送） | 长连接推 `sfuRoom`（`started` 那一次） |
| 怎么提示 | 系统通知 + 响铃（`GroupCallPushHost`） | 屏幕上飘一条横幅（`GroupCallBannerHost`） |
| 长驻记号 | —— | 会话列表那一行的绿字「语音通话中」 |
| 点开去哪 | 群通话页 | 群通话页（**同一个路由**，进去就是加入） |

**服务端多推的就是几个字段**（同一条 `bumpEpoch`，接口/表/配置一行没改）：

```json
{ "room_id": "100", "epoch": 12, "live": true, "call_id": "100-…-a1b2c3",
  "started": true, "name": "产品群", "starter": "张三" }
```

* `live`：这间屋子里现在还有人吗（每次广播都数一次注册表，调用点五六处，
  漏一处就会出现「人都走光了界面还写着通话中」）；数不出来时按还有人处理；
* `call_id`：前后两通的身份证，客户端靠它挡「上一通的收尾把这一通当成结束了」；
* `started` + `name` + `starter`：**只有「这一通刚开」那一次带** —— 只剩它会让客户端弹横幅，
  第二、第三个人进来不重复弹（与离线推送「只推第一笔」同一个取舍）；其余广播不带，
  客户端把上一份留住，不会被普通广播摸掉群名。

客户端那半（`lib/domain/group_call/group_call_presence.dart`）四条要点：

* **我就在那间屋里时不提示**：`onRoomEvent(inRoomId:)` 拿 `GroupCallHub.active.roomId` 比对，
  自己开的、自己正开着页的那个房间一律忽略（否则会给自己弹一条「邀请你加入」）；
* **老服务端当没看见**：载荷里没有 `live` 的事件直接丢掉 —— 不能凭一条 `epoch` 变化
  猜「有人在开语音」；
* **点掉与进去都按 `call_id` 记**：横幅按掉之后这一通不再弹（会话列表那行标记照留）；
  我自己进了那间屋，同一通之后的广播也不再弹；
* **45 秒回查一次**（`GroupCallPresenceTracker.verify` → `POST /sfu/room`）：屋里最后一个人的
  App 被杀时没人去碰那间屋，那条 `live = false` 永远推不出来（服务端没有定时任务可用），
  只能由手里有标记的客户端定期问一次；那一次回查顺带把服务端的残骸也清了（`Sfu::room` 带 prune）。
  拿不准（网络失败）时**什么都不改**。

界面那半：横幅挂在 `MaterialApp.builder` 最外层（与 `NotificationHost` / `CallHost` 同一层，
所以任何页面上都活着、且浮在 AppBar 之上），20 秒自己收掉；1:1 电话正在进行时
既不显示也不让进（`callBusyProvider`：群资料页的入口、横幅、推送来的邀请三处共用同一个判据）。
会话列表那一行只换预览那一位（名字、时间、未读角标都不动），好友会话不受影响。

还没做的（写清楚）：**推送那条路（`GroupCallPushHost`）进来的邀请也没有横幅** ——
它直接进页面；以及**断线期间开的那通语音**（错过了 `started` 那一次）不会补弹横幅，
但会话列表的标记会在下一次广播（有人进来/走了）时补上。

## 十五、进群以后还有两处要顺手（2026-09-27 落）

第十四节把「有人在群里开语音」告诉了所有人，但**点进那个群之后**、以及**点那条历史记录时**，
还差两件事（与微信逐条对齐时找出来的）：

### 15.1 群聊页顶上那条常驻的「N 人正在通话 · 加入」

会话列表那一行绿字只在列表页看得见；横幅 20 秒就走。所以**人已经点进这个群**时，
顶上正该有一条能一直点得动的入口 —— 微信里就是这样。

`lib/features/chat/widgets/group_call_bar.dart`：标题栏下面、消息列表上面，
只在群会话（`is_group == 1`）里画，语音不在了整条高度为 0（不占位、不吃触摸）。
数据来源与第十四节那两处**同一本账**（`GroupCallPresenceTracker`），所以三处不会互相矛盾；
人数用服务端 `sfuRoom` 里那个 `members`（第十四节就推了），**数不出来时退化成
「语音通话中」而不画数字** —— 人数只影响这句话好不好看，不该成为「这条显不显示」的判据。
点整条 = 点「加入」（同一个 `_openGroupCall`，与群资料页那个入口同一条路由）。

⚠️ 现在只有「加入」一种形态：我们自己人在通话页上时聊天页看不见（离开那一页就等于挂断）。
「离开页面不挂断」做完之后，这一条要跟着长出一个「回到通话」的形态。

### 15.2 点历史通话记录 → 先弹详情卡，而不是直接进房间

S6.13 那版是「点一下进群通话页」，而**进那个页面 = 真的加入/开出一间房**，
于是手滑点一下就撞上第十四节之前定的规矩：**服务端第一笔就叫醒离线群成员**
（一群人的手机会响一声，然后被收掉）。微信里点这条记录是看详情，我们跟它对齐。

`lib/features/chat/widgets/group_call_record_sheet.dart`：卡上两行真实数据 + 一颗主操作。

| 位置 | 内容 | 来源 |
| --- | --- | --- |
| 通话时长 | `00:45` | `extends.callTime`，用 `formatCallRecordDuration`（**分钟:秒**，与气泡里 `content` 拼出来的那个数一模一样 —— 卡上的数字和气泡上的不能是两个） |
| 参与人数 | `3 人在通话` | `extends.participants`（服务端数的人头，**没有名单**，所以不假装有参与者列表）；0 就不画这一行 |
| 主操作 | 「加入」/「再次发起」 | 还在开是「加入」，散了是「再次发起」；两者走**同一条路由**，只是文案不一样 |

判「还在不在开」用的是同一本账（`GroupCallPresenceTracker.liveIn(conversationId)`）。
`CallPayload` 因此多了 `durationSeconds` / `participants` 两个字段（`lib/domain/chat/message_media.dart`，
默认 0：1:1 那条老记录本就不带这两样）。

**服务端这一轮一行没改**（不需要新补丁包）：`sfuRoom` 里的 `members` 是第十四节就带着的，
详情卡用的两样数据是 S6.13 那条记录自己写进 `extends` 的。

## 十六、退出通话页不挂断（2026-09-27 落）

到第十五节为止，群通话**仍然活在通话页上**：页面一关就 `dispose`，于是「退出页面 = 挂断」。
微信不是这样 —— 退出来还能听、还能说，群里那条「正在通话 · 回到通话」留着，通话就这么开着。
这一节把那层绑定拆开，与微信的最后一处明显差别也就没了。

### 16.1 通话现在常驻了（`GroupCallSession` / `GroupCallSessionHost`）

房间、控制器、保活、对账登记从页面搬到一个**常驻会话**里
（`lib/features/group_call/group_call_session.dart`）：

| | 页面（`GroupCallPage`） | 会话（`GroupCallSession`） |
| --- | --- | --- |
| 是什么 | 看着这一通的**视图** | 这一通本身（房间 + 控制器 + 保活 + 登记处） |
| 进出 | 进来 `openPage`、关掉 `closePage` | 只有 `end()` 才真的结束 |
| 关心的 | 画什么、按了什么 | 会话在不在、几个人、进来多久 |

几条刻意的取舍（都有单测钉住）：

* **同一个群再进来还是那一通**：`openPage` 复用现成的会话，**不重新加入**
  （重开会多建两条会话、还会让别人跟着重协商一次）；
* **换一个群进来 = 先把上一通挂干净**：一次只能有一通（一条链路一只麦克风），
  与 1:1 那条规矩一致；
* **一次只有两条路能结束它**：通话页那颗红钮、小窗上的挂断（加登出整段清）。
  返回键、返回手势、划走页面都只是「不看了」；
* **进不去又没人看着就收掉**：`failed` 且页面不在时留着它没有任何意义 —— 小窗不显示
  （它自己也进不去），用户也没地方挂断，那就是一颗看不见的僵尸；
* **通知界面要推到这一帧之后**（`_notifySoon`）：页面在 `initState` 里 `openPage`、
  在 `dispose` 里 `closePage`，那两刻正是 widget 树锁定的时候，当场通知会让监听者
  撞上 `setState() called during build`（整机用例抓到的）。一个微任务就落在构建与布局之后，
  界面看不到延迟，顺带把同帧的多次变化合成一次；
* **进去不用等收尾**：挂断那颗钮点完立刻返回上一页（关两条会话要几趟网络往返），
  会话一进 `end()` 就先从登记处摘掉并通知界面。

计时也跟着搬了：从「进房间成功那一刻」（`joinedAt`）算，所以关掉页面再进来，
时长接着往下走（以前是页面自己从 0 开始数）。

### 16.2 小窗（`GroupCallMiniBarHost`）

页面关掉之后总得有个地方告诉你「你还在一通话里」，以及一个点一下回去的入口 ——
就是那颗可拖的药丸（`lib/features/group_call/group_call_mini_bar.dart`）：

* 挂在 `MaterialApp.builder` 最外层（与横幅同一层），所以**任何页面之上**都在；
* **只在通话页不在台上时出现**（`pageOpen`）：页面上已经有一样的四颗钮，再飘一颗是重复；
* 群名 + 「N 人 · 12:03」（还没进房间就写「正在加入…」/「正在重连…」）；
* 点整颗 = 回通话页（同一条路由，进去就是看着原来那一通，**不会重开**）；
* 右边那颗挂断是**唯一的兜底**：页面关着时也得有地方能把这通结束掉；
* 拖着走（挡着东西自己挪，松手后被钳回屏幕内）。

⚠️ 小窗用的是 `IconButton` 但**不给 `tooltip`**：它挂在 Navigator **外面**，那里没有
Overlay，带 tooltip 的按钮一构建就报「No Overlay widget found」（用例抓出来的）。

### 16.3 群里那条提示也跟着长了一种形态

群聊页顶上那条（第十五节）现在分两种：别人在开、我还没进去 → 「加入」；
**我自己就在这一通里** → 「回到通话」。两本账各管一半：我在不在通话里看会话登记处，
别人在不在看在线状态那本账（`GroupCallPresenceTracker`）。

### 16.4 还没做的（写清楚）

* **通话页被别的页面盖住时**（例：正在群里通话时来一通 1:1，`CallHost` 把通话页推上来），
  群通话页还活着、小窗不显示 —— 那会儿屏幕上是 1:1，要回群通话得退回一层；
* **1:1 打进来不会自动挂断群通话**（两条链路各管各的麦克风）；
* **没有锁屏全屏、没有来电那套叫醒**（群通话本来就是「点进去才有」）；
* **没有视频**（产品决定：语音 + 一人共享屏）。

## 十七、通了之后的四件"手感"修复（2026-09-27 落）

前提：服务端的字段名 bug（`trackName` vs `track_name`）由 **live5** 补上之后，
两台真机互相听得见、共享屏也看得见了。这一节全是**通了之后才看得出来**的事，
只动客户端，服务端一行没改。

### 17.1 进房间不再等自己的发布谈成

真机时间线（修前）：`+0.3s 进房间` → 第一次快照 `+8.9s`。那 8.9 秒全等在一个东西上：
采麦 → 建发布会话 → 候选收集 → 与 Cloudflare 建连。而**听见别人根本不需要它**
（订阅走的是另一条会话，两条会话互不相干）。

现在 `join()` 的顺序是：采麦 → 建发布会话（一条请求）→ **发布不 `await`** →
拉快照/订阅 → 等发布落地并回报成败。发布失败不再"默默留在房间里"：
`publishError` 落进 `failed` 阶段并写出原因（那正是"界面一切正常、别人一个字都听不到"的样子）。
另外接收会话**预建**（`_prewarmReceive`），`_ensureReceive` 也加了并发去重 ——
预建与首次对账同时来问时，两边各建一条会在房间里凭空多一个幽灵成员。

新增视图字段 `micPublishPending`：通话页那行红字的条件正好是
`!micPublished && !micPublishPending`，所以发布在飞的那几秒不会先红一下。

### 17.2 `micPublished` 只认注册表

删掉了 `_publishTracks` 里那句"回包说接受了就把 `micPublished` 置真"。
它就是老 bug 能藏一整天的原因：回包说"上游接受了 mic"，而服务端因为自己的解析 bug
根本没写进注册表，界面于是信心十足地显示一切正常。
现在 `join()` 在发布落地之后**再读一次注册表**，`micPublished` 只有一个来源：
**别人的注册表里查得到我**。

### 17.3 共享屏：`contain` + 同一时刻只允许一个人

* 渲染从 `cover`（填满、四周裁掉）换成 `contain`（**完整放下**，四周留黑边）：
  屏幕共享的意义就是"看清每个角落"，`cover` 会裁掉一圈；
* **抢共享拦住了**：SFU 没有"只能一个人共享"这个限制，两个人同时开就会打架
  （注册表里两条 `screen`、观看端只认其中一条，两边都要重协商）。
  第二个人那颗钮**弄灰但仍可点** —— 点一下会告诉他"已经有人在共享了"
  （`group.callShareTaken`），对方停止共享后立刻恢复可用。

### 17.4 我自己那一行的麦克风状态看"意图"

注册表只知道"这个人发布过一条 `mic`"，不知道我中途按了静音
（静音只是本端不再发包，`mic` 一条一直挂在注册表上）。
所以**我那一行**的 `audio` 用 `我的意图 && 注册表`，否则会出现
"按钮写麦克风已关、成员行写麦克风已开"。

⚠️ 这一条**只修了我自己那一行**。**别人**静音了我这边照样看不出来（注册表没有静音
这一维）—— 2026-10-07 补完了，见下面「二十一、静音状态的跨端同步」。

## 十八、界面不迟钝的硬保证：两条死区（2026-09-27 落）

S6.18 之后功能齐了，但真机上**一切都慢半拍**：对方停了共享这边还卡在画面上、
人走了三分钟还挂在成员里。查下来是两个**互相咬住**的死区：

**死区一：客户端的版本号判断写成了“不比手里新就不刷”**

版本号（`epoch`）是服务端缓存里的一个计数器：**清了缓存 / 重启过就从 1 重数**。
回退之后“比手里小 → 不刷”会让这台手机**永久不再收任何进出更新**。
→ 改成“**相同**才跳过”（回退时多刷一次无害：差集为空就是空转）。

**死区二（真正的那个）：两端正好互相等**

* 服务端的清场（`prune`）**只在拉快照（`room`）里跑**；
* 掉线 / 被杀的人**不会自己写注册表** → 版本号不变 → 客户端不拉快照；
* 客户端不拉快照 → 清场永远不跑 → **那一行永远挂在房间里**（连着他在共享的屏）。

所以“3 分钟还没反应”不是慢，是**永远不会自己好**。

**修法（两边各一刀）**

1. **客户端：定期状态回查**（`SfuRoom.stateRefreshInterval`，默认 **5 秒**）——
   无条件拉一次快照，不管推送有没有来、版本号变没变。这是界面不迟钝的唯一硬保证。
   回查时**状态没变就不记诊断时间线**（5 秒一条快照会把有用的几条冲掉），
   但状态该更新的一处不少。
2. **服务端：心跳也清场**（`heartbeat` 里调 `prune`）+ 行超时**封顶 45 秒**（原 90）：
   **2026-10-07 已落**（见第二十二节）。
   心跳是每个在通话里的人每 20 秒一定会调的接口，从那一刻起清场就一定跑得起来。

## 十九、系统小窗（画中画）（2026-09-27 落）

用户要求与 1:1 通话**一样**：左上角一颗「缩成小窗」，点一下把这一通缩进系统画中画。
群通话这边本来就是通话页 + 常驻会话，所以接的是**同一条原生通道**
（`gracelinkim/pip`，见 `lib/core/platform/call_pip.dart` 与 `MainActivity.kt`），
不是自绘悬浮窗：**零权限**、进/出由系统管。

### 19.1 通道的监听从「一个 setter」改成「一张表」

`CallPip.onModeChanged` 原来是个 setter，而平台通道（`setMethodCallHandler`）只挂得住一个：
群通话一来注册就会**把 1:1 那条顶掉**（1:1 的界面正是靠这条消息切成「只有内容」的）；
群通话挂断时再 `= null` 更糟 —— **两条监听一起没了**。
改成 `addModeListener` / `removeModeListener`：第一条监听进来才挂平台回调、
最后一条走时摘掉；原生报一次就给所有监听各推一次。两边各摘各的。

### 19.2 取舍（与 1:1 逐项对齐）

| | 群通话怎么做 |
| --- | --- |
| 怎么进小窗 | **只有**点左上角那颗（`minimizeToPip` → `pip.enter()`）；按 Home / 切走**不进**（那几种情况靠前台服务 + 常驻通知） |
| 参数 | `joining / joined / rebuilding` 里 `setParams(video: false, title: 群名)`；参数没变不打通道 |
| 标题 / 比例 | 标题是**群名**；比例用**语音那档（1:1 方块）** —— 主内容是头像墙/说话人卡片 |
| 界面 | `GroupCallView.inPip`：进了就**只画内容、一个钮都不画**（PiP 里触摸被系统接管，点一下是「展开 / 菜单」）；共享屏那一路在里面也走 `contain` |
| 结束 | `hangup` / `dispose` 都走 `_releasePip`：摘监听 + 把已经打开的小窗收掉（不留一个「小窗里是聊天列表」的怪状态） |
| 失败 | 一律只记一行日志 —— 小窗是体验，绝不能影响这一通 |

诊断：小窗相关的每一条都走控制器的 `debugPrint`（`[群通话] 缩成小窗失败：…` 这类），
与房间状态同一条口径。

## 二十、与 1:1 通话的先后关系（2026-09-27 落）

一条链路只有一只麦克风、一块屏幕，而且 —— 这一点最容易漏 —— **前台服务全应用只有一份**
（`CallKeepAlive`，一颗常驻通知）。两通电话同时开着的后果因此不是“声音有点乱”，而是：

* 后结束的那一通调 `stop()` 时，把另一通的常驻通知也停掉 → 另一通切后台就被冻结
  （声音断、对账停）；
* 两条通知互相顶；群通话正共享屏幕时，那一位 `mediaProjection` 类型也一起没。

所以定成一条硬规矩：**同一时刻只允许一通通话**。三个方向都要堵：

| 方向 | 怎么做 |
| --- | --- |
| 有 1:1 电话时进群通话 | 拦（已有）：聊天页「＋」面板、离线邀请那条推送 两处都过 `callBusyProvider`（群资料页那个入口 2026-09-27 已删） |
| 正在群语音时**拨** 1:1 | 拦（`groupCallBusyProvider`）：聊天页 / 联系人详情页两个入口都提示「你正在通话中，请先挂断」 |
| 正在群语音时**接** 1:1 | 让路：1:1 接通那一刻，`GroupCallSessionHost` 把这一通挂干净（保活、登记表一起收）；群通话页自己退出去 |

为什么“接”是让路而不是拦：用户刚按了接听，不能拦；也不能让人两通同时挂着。
未接的来电响铃**不动**群通话（那时还没接）。

## 二十一、静音状态的跨端同步（2026-10-07 落）

### 21.1 症状与根因

真机：电脑端 A 与手机端 B 都在群里，**B 关掉麦克风，A 那一行一直写「麦克风已开」**。

根因是一处**从没做过**的事：`SfuRoom.setMicrophoneEnabled` 过去只调
`local.setMicrophoneEnabled`（本机 WebRTC 轨道），**一个字节都没发给服务端**。
而"这个人有没有声音"在别人那里**唯一来源**是注册表：

```dart
audio: member.tracks.contains('mic')      // sfu_room.dart::_participantsOf
```

静音不改 `tracks`（`enabled = false` 只是本端不再发包，publication 还挂着），
所以注册表永远说他有麦。17.4 那条补丁只修了"我自己那一行"（用本机意图），
**别人那一支没修** —— 就是这次这个 bug。

### 21.2 为什么**不能**靠"静音就把 track 摘了"

最省事的做法是静音时 `close` 掉 `mic`、取消静音再 `publish` 回来。**不能这么做**：
摘掉 track 会让对方**退订**；取消静音时重发布一旦失败（隧道抖一下、会话被判定毒化要重建），
对方就**再也听不到我** —— 那正是 2026-10-06 花大力气修掉的「说话没声」。
而且每次开关都要重协商，跨洋链路上要 1~2 秒。

**所以静音不改发布关系，只报一个"显示态"。** 好处是取消静音**立即恢复**：
对方的订阅从没断过。

### 21.3 客户端（已落地，2026-10-07）

| 位置 | 改动 |
| --- | --- |
| `SfuControlPlane.setMuted` | 新增：`{room_id, muted}` |
| `SfuApi.setMuted` | 新增，走 `SfuPaths.mute` |
| `SfuRoomMember.muted` | 新增字段，**默认 `false`**（老服务端没这个字段时行为逐字不变） |
| `SfuRoom._participantsOf` | `audio: tracks.contains('mic') && !member.muted` |
| `SfuRoom.setMicrophoneEnabled` | 本机静音**之后**再 `_announceMute` |
| `SfuRoom._announceMute` | 上报失败**不抛错**（本机已经静了），留 `_mutePending` |
| `SfuRoom._heartbeatTick` | 有 `_mutePending` 就顺手补报一次（自愈） |

顺序是硬的：**① 本机先静音**（用户按下去必须立刻生效）→ **② 再报服务端**。
反了、或者把①回滚掉才是真错：用户按了静音，声音却还在往外发。

### 21.4 服务端（已落地，2026-10-07 · 整份替换补丁）

**按 PHP 7.3 校验过**（线上就是 7.3）：补丁用官方 **PHP 7.3.33** 跑过真正的 `php -l`
（`No syntax errors detected`，改动前的底稿同样通过）。新增代码只用了 PHP 7.0 就有的语法
（`??` / `===` / `count()` / 数组字面量），没有箭头函数（7.4+）、类型化属性（7.4+）、
`match`（8.0+）、`?->`（8.0+）。

**① 注册表加一维**

成员行从 `{user_id, session_id, tracks:[…]}` 变成
`{user_id, session_id, tracks:[…], muted:bool}`（缺省 `false`）。

**② 新动作 `mute`（`app/enterprise/controller/Sfu.php`）**

| | |
| --- | --- |
| 路径 | `POST /enterprise/sfu/mute` |
| 请求 | `{room_id, muted}` |
| 响应 | `{}`（沿用 `{code,msg,data}` 信封） |
| 校验 | `$this->roomId($this->body('room_id'))` —— 与其它动作**同一个入口**，成员校验就在它里面（`GroupUser` 表）。**没有**单独的 `checkGroupMember`（第一版补丁里那个名字是占位符，抄进去就是致命错误） |
| 行为 | 只改**我自己那一行**（`purpose = 'publish'`）的 `muted`；**只在值真的变了时** `bumpEpoch()` 并推 `sfuRoom`（否则每次开关都惊动全屋）。还没有发布会话（正在进房间 / 人已被清场）时直接 `success('')` —— **不是错误**，客户端本机已经静了 |

**③ `roomState`（`…/room`）回包带上 `muted`**

`members: [{user_id, session_id, tracks:[…], muted}]`。

**④ 建行不必显式写 `muted`**

列有 `DEFAULT 0`（建表语句与补列语句都带），`putMember` 的 `UPDATE` **不碰这一列** ——
所以会话重建（换 `sessionId`）不会把静音态洗掉，这是刻意的。

**⑤ 那一列由代码自己补**

`CREATE TABLE IF NOT EXISTS` 对**已经建好的表**什么都不做，所以光改建表语句，线上那张表
永远不会有这一列 —— 而 `room()` 要读它、`mute()` 要写它。`ensureTable()` 里因此多了一步
`ensureMutedColumn()`（`SHOW COLUMNS` 查一次，缺了就 `ALTER TABLE`），与建表共用那个
1 小时缓存。手工跑 SQL 仍然可以（`db/20261007_sfu_room_member_muted.sql`），只是不必。

**⑥ 交叉自检**

`check_server.js` 会把"客户端路径 ↔ 控制器动作"逐个对一遍。加一条 `mute` 进去，
否则自检会红（那是服务端自己的工具，不在本仓）。

### 21.5 上线顺序与验收

**顺序无所谓**：服务端先上，老客户端忽略多出来的 `muted` 字段；客户端先上，
`setMuted` 拿到 404 也按"尽力而为"吞掉（`_mutePending` 每 20 秒重试一次，
诊断面板里能看到失败条目）。**两边都上齐了才真正生效。**

客户端此刻是**优雅降级**：服务端没有 `muted` 时，行为与 2026-10-07 之前逐字一致。

验收（**这一次只动服务端**：两端客户端在 2026-10-07 16:43 / 16:44 就已经打好了包，
`muted` 字段与 `setMuted` 都在里面 —— 服务端一上，客户端下一拍心跳就把静音态补上去了）：

1. A 进群通话 → B 进群通话 → 都听得到对方；
2. **B 关麦克风 → A 那一行变成「麦克风已关」**（本次的唯一目标）；
3. B 再开麦 → A 那行变回「麦克风已开」，**且 A 立刻又能听到 B**（订阅从没断过）；
4. 反复开关几次，`subscribe` 计数不涨（`sfu_room_test.dart` 已钉住这条）；
5. 反例（防回归）：B 静音期间，A 不该有任何重协商，也不该退订 B 的 `mic`。

## 二十二、人数口径：「N 人在通话」为什么是 2 倍，以及横幅为什么不消失（2026-10-07 修）

真机（3 人群）：顶部栏时而是「4 人在通话」，时而又跳成 3、1 —— **明明只有两个人**；
而且人都走光了，它还挂在那儿不消失。

### 22.1 根因一：数的是**行**，不是人

注册表的唯一键是 `(room_id, user_id, purpose)`（见 `Sfu::putMember` 的注释）——
**一个人最多两行**：一条发布、一条接收。而 `live` / `members` 唯一的来源是
`Sfu::roomMemberCount()`：

```php
->where('purpose', '<>', 'closed')->count()      // ← 数行：2 个人 = 4
```

于是 2 个人 = 「4 人在通话」；有人重建会话（换 `sessionId`）时行数在 1~4 之间跳，
所以还会 1 / 3 / 4 地乱显示。

**同一份查询在这个文件里抄了四份，只有这一处没去重**：

| 用在哪 | 当时的口径 |
| --- | --- |
| `room()` 快照 | ✅ 按 `$members[$uid]` 去重 |
| `heartbeat()` 的 `member_count` | ✅ `distinct(true)->column('user_id')` |
| `assertCapacity()` 人数上限 | ✅ 同上（注释还写着「按"人"算，不按会话算（一个人两条会话）」） |
| **`roomMemberCount()`** | ❌ `count()` |

**修法**：抽出唯一的 `roomUserIds()`（`distinct(true)->column('user_id')`），四处全走它；
`roomMemberCount()` 返回它的 `count()`。这一条与 `leave()` / `prune()` 里那两处
「房间空了没有」同一个口径。

### 22.2 根因二：横幅收不掉 —— 清场太晚 + 「还剩几个人」数错了行

**2026-10-07 核实**：这一刀（第十八节留下的）**其实已经落过一半**。线上那份
（`Sfu.php`，1785 行，比我的底稿多 262 行）里已经有「心跳也清场」与
「行超时封顶 45 秒」（都标着 2026-09-27），所以「清场只跑在快照里」这个说法只对**更早**那版成立。
留下来的两个真问题：

1. **顺序反了**：线上是 `prune()` 在前、`touchMine()` 在后。刚睡醒的那台设备
   （行已经超时）会被自己这一次心跳清掉 —— 别人立刻把他退订，而他手里还觉得自己在发布。
   正确顺序是先续自己的命、再清场。
2. **「房间空了没有」也是数行**：`leave()` 的 `$remaining`、`prune()` 的 `$left` 都在
   `Db::name(...)->count()`。同一个人两条会话时它永远 > 0，于是
   **「这一通散了」那条 `live = false` 根本推不出去**（`endGroupCall` / 通话记录也跟着不落），
   屋外的人只能靠自己 45 秒一次的回查收掉横幅；有残骸时甚至更久。

**修法**：heartbeat 里把两句话换个位置；`leave()` / `prune()` 的「还有人吗」
改走 `roomMemberCount()`（按人去重）。这一条与 22.1 是同一根线：**数人，不数行**。

### 22.3 修法落地的方式：锚点脚本，不是整份替换

线上那份比底稿新 262 行，所以「整份替换」这条路作废（会把人家的改动冲掉）。
改成 `apply.php`：把每一处改动写成「旧文本 → 新文本」，**每处可以有多套写法变体**
（底稿写法 / 线上写法），命中哪套按哪套改；改完跑 19 条终检 + 一次
`token_get_all(TOKEN_PARSE)` 语法门，任何一处没命中或终检不过就**不写盘**。
2026-10-07 晚在本机用官方 PHP 7.3.33 过了五轮：

| 轮次 | 输入 | 期望 |
| --- | --- | --- |
| T1 | 底稿 | 输出与手工参考产出**逐字节一致** |
| T2 | 已打过补丁的文件 | 15 处全「已在」、**零字节变化** |
| T3 | 底稿的 CRLF 版 | 内容一致且**行尾保住 CRLF** |
| T4 | 底稿 + 一个别人手抄的半截 `mute()` | 先整段摘掉再插，结果与 T1 一致 |
| T5 | 「线上形态」夹具（4 个方法换成线上原文） | 14 处应用、1 处已在（45 秒封顶）、零没命中、19 条终检全过 |

### 22.4 客户端这一轮**没动**

顶部栏那个数字有两种来源（`group_call_bar.dart`）：

* **我自己在这一通里** → 用客户端的名单（`inCallMembers.length`，按 `user_id` 去过重）
  —— 一直是对的；
* **我还没进去** → 用服务端 `sfuRoom` 里的 `members` —— **错的就是这一路**。

服务端修好之后这一路就对了；客户端不需要为此改任何东西（它本来就是如实显示服务端给的人数）。

## 八、还需要用户提供的东西

Cloudflare Dashboard 建一个 **SFU App**（Realtime → 不是 TURN Key），拿到 **App ID 与 App Secret**，
填进站点 `.env`（与 TURN 那两个密钥并列，**App Secret 绝不进客户端、绝不放后台 chatInfo**）：

```ini
[REALTIME]
TURN_KEY_ID = …
TURN_API_TOKEN = …
SFU_APP_ID = …
SFU_APP_SECRET = …
```
