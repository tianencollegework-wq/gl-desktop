# 通话信令对照表

来源：`pages/message/call.vue`、`App.vue` 的 `webrtc` 分支、`hybrid/html/index.html`、
`components/message/im-input.vue`、`pages/contacts/detail.vue`。

## 核心事实：信令借道业务消息

**没有独立的信令通道。** 所有通话信令都以「一条 `type = webrtc` 的业务消息」的形式：

1. 客户端 `POST /enterprise/im/sendToMsg`（字段见下）；
2. 服务端落库并向对端推 WS `{ type: "webrtc", data: {...} }`；
3. 对端在 `App.vue` 里分流：`event == calling` 走**来电弹页**，其它 event 走 `uni.$emit('webrtcConn')` 交给通话页。

> 这也解释了为什么聊天页要把 webrtc 消息过滤掉：`chat.vue` 只显示
> `calling / hangup / otherOpt` 三种，否则 ICE candidate 会把聊天记录刷爆。

## 发送字段（`sendToMsg`）

| 字段 | 说明 |
| --- | --- |
| `id` | **通话 id，两端共用**（见下）：主叫侧是自己生成的 uuid，被叫侧原样带回主叫那个 id |
| `msg_id` | 服务端返回的消息业务 id |
| `toContactId` | 对方 user_id |
| `type` | `0` = 语音，`1` = 视频（与 `extends.type` 同源） |
| `event` | 见下表 |
| `status` | 见下表 |
| `code` | 见下表 |
| `callTime` | 通话时长（秒），仅在挂断时携带 |
| `sdp` | offer / answer 的 SDP |
| `iceCandidate` | JSON **字符串**（老端把对象 `JSON.stringify` 后发送，收到时再 parse） |

## 事件

| event | 方向 | 载荷 | 说明 |
| --- | --- | --- | --- |
| `calling` | 主叫 → 被叫 | `status`、`code` | 发起呼叫。被叫 App 收到后弹来电页（`status=3`） |
| `acceptRtc` | 被叫 → 主叫 | `code: 904` | 已接听。主叫收到后 `createOffer` |
| `offer` | 主叫 → 被叫 | `sdp` | 被叫 `setRemoteDescription` 后 `createAnswer` |
| `answer` | 被叫 → 主叫 | `sdp` | 主叫 `setRemoteDescription` |
| `iceCandidate` | 双向 | `iceCandidate`（字符串） | 逐条发送；对端延迟 100ms 后 `addIceCandidate` |
| `hangup` | 双向 | `code`、`callTime` | 挂断。请求体里**没有 `isbtn`**（那个字段只在 WebView ↔ 页面之间传，见下） |
| `busy` | 任一方 → 对方 | `code: 907` | 忙线（对方正在通话中） |
| `turndown` | — | — | 客户端 `switch` 里有分支，但**没有任何地方发送**，语义待确认 |
| `otherOpt` | 多端 | — | 同一账号其它端已处理该通话，本端直接挂断 |
| `mediaDevices` | 本端 WebView → 本端 | — | `getUserMedia` 失败（没权限/没设备），提示并关闭通话页 |

### `isbtn` 为什么不在请求体里

`isbtn` 是 WebView 内部消息的一个字段，**从来不上服务端**：

1. `index.html::hangup(btn)` 里 `postMsg({event:'hangup', isbtn: btn, callTime, code})` —— 这是发给**本端页面**的；
2. `call.vue::msgCallback` 的 `hangup` 分支里：`if(!e.data.isbtn) api = false;` —— 意思就是
   **不是用户主动点的挂断，本端不要回枪**；
3. 真的调 `sendToMsg` 时那十个字段里没有 `isbtn`。

推论：**对端发来的 `hangup` 里不会有 `isbtn`**（双方都不发），所以「收到挂断不回枪」实际是
恒定行为。新端直接把这层意思写死在状态机里（收到结束信令只做本地收尾、不发信令），
`CallSignal.byButton` 只作为报文解析的保留字段。

## 状态（`status`）

| 值 | 含义 |
| --- | --- |
| `0` | 默认 |
| `1` | 拨号中（主叫） |
| `2` | 通话中 |
| `3` | 来电中（被叫） |
| `4` | 忙线 |

## 错误码（90x）

| code | 含义 | 产生位置 |
| --- | --- | --- |
| `901` | 发起呼叫 | WebView 里 `getUserMedia` 成功后回传 |
| `902` | 主叫取消 | 拨号中挂断 |
| `903` | 被叫拒接 | 来电状态挂断 |
| `904` | 已接听 | 被叫点接听 |
| `905` | **未知** | 客户端代码里从未出现，只在"解锁多端锁"的列表里被列过 → 待确认 |
| `906` | 通话中挂断 | `status == 2` 时挂断 |
| `907` | 对方忙线 | 冲突检测 |

## 完整时序（1v1）

```
主叫 A                                     服务端                              被叫 B
  │ 点语音/视频（检查 webrtcLock）                                                │
  │ navigateTo /message/call: status=1, type=0|1                                 │
  │ 申请 RECORD_AUDIO(+CAMERA)                                                   │
  │ ── sendToMsg{calling} ──────────────────► 落库 ── WS webrtc{calling} ──────► │ 弹来电页 status=3
  │ getUserMedia 成功 → code 901                                                 │ 播放铃声
  │ ◄──────────────────────── offer{sdp} ◄── 落库 ◄── sendToMsg{acceptRtc,904} ── │ 点接听 → 904
  │ setRemote/Answer                                                        │
  │ ── sendToMsg{answer,sdp} ──────────────► 落库 ── WS ──────────────────────► │ setRemote
  │ ◄───────────── iceCandidate（逐条，双向，多次）─────────────────────────────►│
  │ 媒体连通，双方计时开始                                                        │
  │ ── sendToMsg{hangup, code:906, callTime} ─► 落库 ── WS ────────────────────► │ 播放挂断音、关闭页面
```

## 「通话 id」是两端共用的那一个（S6.1 逐行核实）

`call.vue::msgCallback` 发出去的每一条信令都写 `id: this.main_id`，而 `main_id` 是页面参数
（`App.vue` 拼 URL 时传的 `data.id`）。于是：

* **主叫侧**：`im-input.vue` 建会话时 `msg_id = $util.getUuid()` 自己造一个 id，之后所有信令都用它；
* **被叫侧**：从 `calling` 那条消息的 `id` 取到同一个值，之后每一条信令（`acceptRtc` / `answer` /
  `iceCandidate` / `hangup`）都把主叫的 id 原样带回。

**所以「`main_id != e.id` 就是忙线」这条规则能成立**——对方发回来的信令 id 必然等于本端那个 id，
不相等就说明是另一次通话（或另一个设备）的报文。

> ⚠️ 一个容易踩的点：**忙线判定对每一类事件都生效**，不只 `calling`。`call.vue` 的 `webrtcConn`
> 回调在 `switch` 之前就先比 id，不相等直接回 `busy/907` 并 `return` —— 连 ICE 候选都会被拦下来。
> 新端 `CallMachine` 照抄了这个顺序（`test/call/call_machine_test.dart` 有一条专门钉它）。

## 冲突与多端规则（客户端侧，服务端不参与）

| 场景 | 判定 | 处理 |
| --- | --- | --- |
| 本端正在通话，又来一个报文（任何事件） | `main_id` 与收到消息的 `id` 不一致 | 回 `busy/907`（本通继续） |
| 本端已在通话页，又来一个 `calling` | 当前路由 == `pages/message/call` | 回 `busy/907` |
| 同账号另一端已在处理 | 自己发的消息（`fromUser.id == 自己`）且带 `isMobile != 1` | 按 `otherOpt` 挂断本端 |
| 多端并发阻止 | `msgStore.webrtcLock`（内存变量） | `offer`/`answer` 时置锁，`hangup`/`isOnline` 下线/90x 挂断时解锁 |

> ⚠️ 这套锁**完全是客户端的启发式**，服务端没有通话会话概念，所以多端登录时无法真正保证
> 只有一台设备振铃。Flutter 端保持同样的行为（为了与老端一致），但**不要指望它可靠**。

锁的三种形态（老端是 JS，三种值混着用）：

| 值 | 何时置上 | 何时解开 |
| --- | --- | --- |
| `false` | 初始值 / 手动解锁 | — |
| 对方 `user_id` | 收到 `calling`（`App.vue`） | 「锁着的这个人下线」（`isOnline: false`） |
| `true` | 收到 `offer` / `answer`（多端：同账号另一端已在通话） | 收到 `hangup`（**无条件**）/ 自己那条信令带回 902/903/905/906/907 |

两处容易看漏的行为：

1. **`hangup` 是无条件解锁**（`App.vue` 的 `else if (data.extends.event == 'hangup')`），
   而**带 90x 码的解锁只看自己的回显**（要 `data.fromUser.id == 自己`）。
2. **锁成 `true` 之后「对方下线」永远匹配不上**（那时没有 id 可比），所以那种形态只能靠
   `hangup` / 自己的挂断回显来解。新端 `_hangupWith` 与 `mediaFailed` 里**本地直接解锁**，
   不依赖服务端把自己那条消息推回来（见 REFACTOR_PLAN 的 S6.1 刻意差异 #4）。

## 媒体层：老端（浏览器）→ 新端（`flutter_webrtc`）的逐项映射（S6.2）

老端那套跑在 WebView 里，所以直接搬浏览器 API 到原生时有几处会**静默失效**。下表里带 ⚠️ 的是
新端必须改写法的地方（改的是本地 API 调用，**线上报文一字未动**）：

| 老端（`index.html`） | 新端（`flutter_webrtc`） | 说明 |
| --- | --- | --- |
| `new RTCPeerConnection({iceServers})` | `createPeerConnection({...})` | `iceServers` 形状一致；额外显式写 `sdpSemantics: unified-plan` |
| `getUserMedia({audio: {echoCancellation: true}, video: {...}})` | `{'audio': true, 'video': {'facingMode': 'user'}}` | ⚠️ 音频给**布尔**才套用插件内置约束（噪声抑制/回声消除/AGC）；给 map 会解析 `mandatory` 拿到空约束 |
| `video: {width: screen.height, height: screen.width}` | 不传宽高 | ⚠️ 老端横竖写反，且原生侧只认 `mandatory` 里的 `minWidth` 这类键，顶层宽高被忽略 |
| `addTrack(track, stream)`（逐条） | `pc.addTrack(track, stream)`（逐条） | 一致 |
| `createOffer({offerToRecieveAudio: 1, offerToRecieveVideo: 0/1})` | `{'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': bool}, 'optional': []}` | ⚠️ 键名不同；老端那个拼写（`Recieve`）在原生侧会被当空气 |
| `setLocalDescription` / `setRemoteDescription` | `RTCSessionDescription(sdp, 'offer'|'answer')` | 一致（新端显式带 type） |
| `onicecandidate`（在 `createOffer/Answer` 里挂） | `pc.onIceCandidate`（建连时就挂） | 新端提前挂，不会错过候选 |
| `addIceCandidate(new RTCIceCandidate(JSON.parse(x)))` | `pc.addCandidate(RTCIceCandidate(...))` | 方法名叫 `addCandidate`（不是 `addIceCandidate`）；失败的候选只记日志，不中断通话 |
| `track.enabled = false`（静音/关摄像头） | `track.enabled = ...` | 一致（麦克风与摄像头各一路） |
| 切前后置：停旧 track → 再 `getUserMedia` → `replaceTrack` | `Helper.switchCamera(track)` | ⚠️ 老端连音频 track 一起换，**切镜头会把静音状态重置**；新端换摄像头源 |
| `pc.close()` + `track.stop()` | `close()` / `dispose()` | 新端在 `close()` 里逐条 `stop()` + `dispose()`，并把半成品连接收干净 |
| `event.streams[0]` 当远端流 | 优先 `event.streams.first`，为空则自包一个流 | ⚠️ 部分实现只推 track 不推 stream，老端那种读法会整个丢画面 |

### ⚠️ ICE 地址必须带协议头（真机实测，2026-09-19）

站点下发的 `chatInfo.stun` 实测值是 **`stun.cloudflare.com:3478`（没有 `stun:` 前缀）**。

* 浏览器（网页端 / 老端 WebView）**会自动补**前缀，所以一直没暴露问题；
* **原生 WebRTC 不补**：见到没协议头的地址，`createPeerConnection` 直接失败并**返回空对象**，
  而 `flutter_webrtc` 不检查返回值；紧接着的 `getUserMedia` 会遍历所有连接去查 track id，
  撞上这个空壳就是**不可捕获的 Java NPE** → **应用当场闪退**（现象：一点接听就闪退）。

客户端现在做两件事：

1. `CallMediaConfig.normalizeIceUrl` 自己补前缀（没头当 `stun:`，兼容 `turn@host:port` 写法，
   一栏里多个地址（逗号/空格/换行）会拆开）；
2. `WebrtcCallMediaEngine._ensureAlive` 建完连接先调一次 `getTransceivers`，
   拿到空壳就当「建连失败」走正常错误路径（提示 + 结束这通电话），不再闪退。

> 建议站点后台把该栏改成 `stun:stun.cloudflare.com:3478`（带协议头才是标准写法）。

**ICE 服务器列表（两边一致）**：第一组是老端硬编码的公共 STUN（`stun.xten.com` + Google 的五个）；
第二组是站点配置的 `stun` / `stunUser` / `stunPass`（来自 `globalConfig.chatInfo`，由 WS 配置下发），
站点没配时老端回退到 `stun:stun.callwithus.com`；新端还留了第三组「自建 TURN」的位置
（**目前为空**，见风险登记 #1）。

**权限**：`flutter_webrtc` 在 `getUserMedia` 时会自己弹权限框，但它自带的 manifest 是空的，
所以宿主 App 必须声明 `RECORD_AUDIO`（已有）与 `CAMERA`（S6.2 补上）—— 不声明则申请不到，
表现为「取流直接失败」。

## 其它通话相关行为

| 项 | 老端实现 |
| --- | --- |
| 拨号超时 | WebView 内 40 秒倒计时（`index.html::cutdown = 40`），超时自动 `hangup`（码 902） |
| 铃声 | WebView 内 `<audio>` 循环播放 `hybrid/html/voice/calling.mp3` |
| 挂断音 | 关闭通话页时 `uni.createInnerAudioContext` 播放 `{apiUrl}/static/voice/guaduan.mp3` |
| 扬声器/听筒 | 通话页 WebView 内用 `plus.audio.setRoute(ROUTE_SPEAKER / ROUTE_EARPIECE)`；H5 端退化成 `video.muted` |
| 麦克风/摄像头开关 | `track.enabled` |
| 切前后置 | 停止旧 track → `getUserMedia(facingMode)` → `sender.replaceTrack()` |
| 大小窗互换 | 本地流全屏、远端流小窗，点击互换 `srcObject` 并切换 `muted` |
| ICE 服务器 | 服务端 `globalConfig.chatInfo` 下发 `stun` / `stunUser` / `stunPass`；缺省时回退公共 STUN |
| 权限 | Android `RECORD_AUDIO` / `CAMERA`；iOS 直接放行（`judgeIosPermission` 被注释掉了） |
| 通话记录展示 | `components/messageType/im-webrtc.vue`，只渲染 `item.content`（**服务端生成的文案**）+ 图标 |

## 页面与生命周期：老端 → 新端（S6.3）

| 行为 | 老端实现 | 新端实现 |
| --- | --- | --- |
| 通话页怎么开 | `App.vue` 收到 `calling` 就 `uni.navigateTo('/pages/message/call?...')`；主叫则由输入区自己跳 | `CallHost`（无界面组件）听控制器状态，`isActive` 变真就 push `/message/call` |
| 怎么关 | 收到结束信令 / 自己挂断后 `uni.navigateBack()` | `isActive` 变假就 `pop()`（用户不需要点任何东西） |
| 页面入参 | URL 带对端信息（`id` / `name` / `avatar` / `type` / `status`） | **不带参数**：对端信息全在信令里，页面只读 `CallViewState` |
| 「已在通话中」怎么判（忙线） | 当前路由 == `pages/message/call` | `CallController.pageActive`（由通话页 `initState` / `dispose` 置位） |
| 关页收尾 | `onUnload`：`wsData = null; main_id = null` + 停铃 | `CallPage.dispose` → `controller.reset()`：停铃、放掉本机媒体、状态机回 `idle` |
| 返回键 | 直接 pop，**一条信令都不发**（通话僵在对方那边） | 拦下来当挂断（来电中 = 拒接 903），见 REFACTOR_PLAN S6.3 刻意差异 #1 |

⚠️ 一个结论性的事实：**页面一关，控制器就回 `idle`**（不是停在「已结束」）。老端 `onUnload` 也是
把这一通整个清掉，所以任何「收尾之后还要读 `ended`」的逻辑都会落空 —— 要读的是「刚才发出去的那条信令」。

**哪些 `webrtc` 事件会变成聊天记录**：只有 `calling`（老端 `App.vue` 里那两句
`if (data.extends.event == 'calling') this.appendMessage(res)`）。否则一条通话会在聊天里
灌进几十条 ICE 候选，而聊天页本身又只渲染 `calling / hangup / otherOpt` 三种。

## Flutter 端重写时要做的改进（不改变对外协议）

1. **ICE candidate 并行发送**：老端逐条 `await`，N 条就是 N 个 RTT；改为并行提交（仍是每条约消息，
   保持与老端互通），把信令时延从 N×RTT 压到约 1×RTT。
2. **自带 STUN/TURN**：不从服务端拿不到的兜底；TURN 是移动网络下打通的底线（见 REFACTOR_PLAN 风险 #1）。
3. **状态机收口**：老端逻辑散在 `App.vue` / `call.vue` / `index.html` 三处，Flutter 端收敛成
   `idle → outgoing → connecting → connected → ended` 单一状态机。
4. **通话期间前台服务**：老端靠 WebView + 保活插件硬撑，Flutter 端用标准的前台服务 + 音频会话，
   保证切后台/息屏不断线（见 REFACTOR_PLAN S6.5）。
