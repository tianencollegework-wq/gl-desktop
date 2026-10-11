# WebSocket 事件对照表

来源：`App.vue`（`getWebsocketData()` 里的巨型 switch）、`common/socket.js`。

## 连接

| 项 | 值 |
| --- | --- |
| 地址 | `wss://{host}/wss`（http 时为 `ws://`） |
| 建立方式 | 老端 `main.js` 里 `new socketIO()` 单例，`App.vue` 的 `onShow` 检查连接状态，断了就重连 |
| 客户端心跳 | 每 **25 秒** 发 `{"type":"ping"}` |
| 服务端心跳 | 服务端发 `ping`，客户端必须回 `{"type":"pong"}` |
| 退出 | 发送 `{"type":"close"}` 后主动关闭，不再重连 |

## 信封结构

客户端只依赖两层：`res.type` 与 `res.data`，另有若干顶层字段散落在各分支里
（`res.client_id`、`res.multiport`）。

```jsonc
{ "type": "simple", "data": { /* 消息体 */ } }
```

### ✅ 实测结果（2026-09-18 探测线上服务端）

样本：[samples/ws-probe-20260918T170604.jsonl](samples/ws-probe-20260918T170604.jsonl)
复现命令：`dart run tool/ws_probe.dart wss://message.gracelink.cc/wss 20`

| 观测项 | 结果 |
| --- | --- |
| 握手 | `wss://message.gracelink.cc/wss` 直接连通，约 1.4s，无需任何鉴权头 |
| `init` 报文 | `{"type":"init","client_id":"7f00000108fc00000009"}` |
| `pong` 报文 | `{"type":"pong","multiport":false}` |
| `multiport` 类型 | **布尔**（老端 store 里的默认值也是 `false`，一致） |
| 顶层字段 | 仅观测到 `type` / `client_id` / `multiport`，**没有** `code` / `msg` / `time` |
| `data` 层 | 协议事件**没有 `data` 层**，字段直接放在顶层 |
| 服务端主动 ping | 20 秒内未出现（客户端仍保留回 `pong` 的能力，以防服务端按更长间隔 ping） |
| 客户端 ping → 响应 | 每次都在 200～350ms 内收到 `pong`，链路健康 |

两个直接影响实现的结论：

1. **不能假设每个事件都有 `data`**：`WsEvent` 必须同时暴露顶层字段。
   老端是用 `res.client_id` 直接取顶层的，这一点被证实。
2. **`init` 在连接后立即下发**（本次在收到我们第一帧 ping 后 3ms），
   所以 `client_id` 不必等某个业务动作才拿得到。

> 仍未确认：**业务事件**（`simple` / `group` / `webrtc`）的信封里 `data` 是否为必需层。
> 已按“业务事件带 data”实现（`ChatSyncService` 对没有 `data` 的事件会明确打日志，不会静默丢弃）；
> 等 S4.2 聊天页接上后就能用真实消息验证。
> 老端业务代码统一读 `res.data`，推断业务事件形如 `{type, data}`，需登录后再实测一次（S6.0）。

## 服务端 → 客户端

| type | 关键字段 | 客户端行为 | Flutter 端落点 |
| --- | --- | --- | --- |
| `ping` | — | 回 `pong` | WS client |
| `pong` | `multiport` | 写入「多端在线」标志（消息页显示"PC 在线"） | 全局状态 |
| `init` | `client_id`（顶层） | 存 `client_id` → HTTP `bindUid` → 发 WS `bindUid` 帧 | ✅ M2 |
| `offline` | `data.id`、`data.client_id`、`data.isMobile` | 被顶下线：三条件同时成立才踢（且 `multipleLogin == 1` 时忽略） | ✅ M2 |
| `updateConfig` | `data` = 整份 `globalConfig`（字段平铺在顶层时也兼容） | 覆盖本地配置（「发现」tab 显隐跟着变） | ✅ M2 |
| `isOnline` | `data.id`、`data.is_online` | 更新联系人在线状态；若对方下线且正是通话对方，解锁 `webrtcLock` | ✅ M4（通话锁 M6） |
| `simple` | `data` = 单聊消息体 | 播提示音 + 落会话/未读 | ✅ M4 |
| `group` | `data` = 群消息体 | 同上（群聊） | ✅ M4 |
| `setChatTop` | `data.id`、`data.is_top` | 更新置顶 | ✅ M4 |
| `setIsNotice` | `data.id`、`data.is_notice` | 更新免打扰 | ✅ M4 |
| `addGroup` | `data` = 会话对象 | 新增会话 + 调 `bindGroup` | M5 |
| `setManager` | `data.group_id`、`data.avatar` | 更新群会话 | M5 |
| `addGroupUser` | 同上 | 同上 | M5 |
| `removeUser` | `data.user_id`、`data.group_id` | 若被踢的是自己则删除会话，否则更新 | M5 |
| `undoMessage` | `data.is_last`、`data.toContactId`、`data.content` | 若是最后一条则更新列表预览 | ✅ M4 |
| `editGroupName` | `data.id`、`data.displayName` | 改群名 | M5 |
| `removeGroup` | `data.group_id` | 删会话 | M5 |
| `setNotice` | `data.group_id`、`data.notice` | 更新群公告 | M5 |
| `groupSetting` | `data.group_id`、`data.setting` | 更新群设置 | M5 |
| `appendContact` | `data` = 会话对象 | 新增联系人 | M5 |
| `webrtc` | `data` = 通话消息体 | 来电弹页 / 转发信令，详见 [call-signaling.md](call-signaling.md) | M6 |
| `sfuRoom` | `data.room_id`、`data.epoch`、`data.live`、`data.members`（人数，数不过来时不推）、`data.call_id`、`data.started` / `data.name` / `data.starter`（只有「这一通刚开」那一次带） | 群通话的注册表变了（有人进来 / 走了 / 换了会话）→ 两件事：正在进行的那个房间重新对账订阅；**没在通话里**的人拿 `live` + `started` 弹一条应用内横幅、在会话列表挂「语音通话中」、并在群聊页顶上挂一条「N 人正在通话 · 加入」（**群频道**，服务端在 `Sfu.php::bumpEpoch` 里推），详见 [sfu-group-call.md](sfu-group-call.md) 第十/十四/十五节 | S9 / S6.16 |

## 客户端 → 服务端

| type | 字段 | 时机 |
| --- | --- | --- |
| `ping` | — | 每 25 秒 |
| `pong` | — | 收到服务端 `ping` |
| `bindUid` | `user_id`、`token` | 两处：① 登录成功后立刻发（老端 `pages/login/index.vue`）；② 收到 `init` 且本地已登录时（先 REST `bindUid`，成功后发） |
| `close` | — | App 卸载 / 主动退出，随后关闭连接 |

## 消息体字段（客户端消费到的）

来源：`App.vue::appendMessage`、`pages/message/chat.vue`、`pages/message/index.vue`。

| 字段 | 说明 |
| --- | --- |
| `id` | 消息 id（通话里作为 `main_id` 做忙线判定） |
| `msg_id` | 消息业务 id（客户端生成 uuid） |
| `type` | `text` / `emoji` / `image` / `voice` / `video` / `file` / `location` / `contact` / `event` / `webrtc` / `money` |
| `content` | 文本内容；**通话记录与部分类型由服务端生成文案** |
| `sendTime` | **单位不统一，入库前必须归一化**：见 `lib/data/model/time_units.dart`。老端渲染层用 `if (t < 9e10) t *= 1000` 兼容两种单位，但它的逻辑判断按毫秒写（撤回/时间分隔），而 WS 推送分支又写 `sendTime * 1000`（说明推送那份是秒）。新端统一毫秒 |
| `fromUser` | `{ id / user_id?, displayName, avatar, realname? }`（命名待报文确认） |
| `toContactId` | 目标会话 id；等于 `system` 时是系统消息 |
| `toUser` | 自己发的消息里指向对方 |
| `at` | 被 @ 的 user_id 数组（客户端用 `includes(自己的 user_id)` 判断） |
| `extends` | JSON 扩展：各消息类型的差异化字段都在这里（含通话事件、`isMobile`） |
| `is_undo` / `oldContent` | 撤回标记与撤回前的原文（老端用来支持“重新编辑”） |
| `is_group` | 群标识（`1` = 群；`2` 在会话列表里额外累加未读） |
| `is_notice` | 会话是否提醒（0 = 免打扰） |
| `is_top` / `unread` / `is_at` / `lastContent` / `lastSendTime` | 会话列表字段 |
| `role` | 群内角色，用于判断撤回权限（`role < 3`） |
| `contactInfo` | 陌生消息里附带的名片信息，用于补齐会话 |
