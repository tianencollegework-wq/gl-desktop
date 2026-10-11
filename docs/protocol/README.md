# 协议对照文档（S0.4 产出）

本目录是 **纯静态分析** 的结果：只读老端源码得出，**不需要真机、不需要抓包**。

| 文件 | 内容 | 主要依据 |
| --- | --- | --- |
| [ws-events.md](ws-events.md) | WebSocket 连接、心跳、全部事件与字段 | `App.vue`、`common/socket.js` |
| [http-api.md](http-api.md) | HTTP 接口全表、请求头、响应约定 | `api/*.js`、`utils/request.js` |
| [call-signaling.md](call-signaling.md) | 通话事件、状态、90x 码、字段与时序 | `pages/message/call.vue`、`App.vue`、`hybrid/html/index.html` |
| [message-types.md](message-types.md) | 九种消息类型的 `content` / `extends` 字段与显示规则 | `pages/message/chat.vue`、`components/messageType/*`、`utils/utils.js` |

> **M2 补充（登录链路）**：登录 / 注册 / 验证码 / 登出 / `bindUid` 的参数名已从调用点逐个确认，
> `getSystemInfo` 返回的 `globalConfig` 结构也已列全，见 [http-api.md](http-api.md) 第 1 节。
>
> **M3 补充（数据层）**：会话与消息接口的参数、分页游标、两个“返回数组而非对象”的接口
> 已确认；`sendTime` 的秒/毫秒问题已从源码侧查清（归一化方案见
> `lib/data/model/time_units.dart`）。
>
> **M4 补充（数据层 + 聊天页）**：九种消息类型的字段与显示规则已从渲染代码里读全，
> 见 [message-types.md](message-types.md)（含 `fixMode == 3` 从未产出、文件消息的 `extUrl` 从未被写入两个坑）；
> **发送消息的请求体**（每个字段、哪些类型走 HTTP 哪些走上传）见
> [http-api.md](http-api.md) 的「发送消息的请求体」一节。

## 这些结论可以直接用

接口路径、请求字段、请求头、WS 事件名、通话事件/状态/错误码、客户端发送的信令字段、消息模型字段名——全部已从源码读出，可以直接照着实现。

## 已经实测确认（2026-09-18）

用 `tool/ws_probe.dart` 连了一次线上服务端（不需要账号、不发业务消息），真实报文已存档到
[samples/](samples/)：

* WS 握手可用（无需鉴权），`init` 与 `pong` 的真实报文都拿到了；
* WS 信封是**扁平**的：协议事件形如 `{type, client_id, multiport}`，**没有 `data` 层**；
* `multiport` 是布尔值。

详见 [ws-events.md](ws-events.md)。

## 必须等真实报文才能定稿的部分

等 M1 打通（新端 WS 上线 + S1.6 协议日志开关）后，用**老端给新端发消息、打电话**，
把新端收到的原始 JSON 存进本目录，再校正下表。**注意不需要 Charles/mitmproxy 抓包**。

| # | 待确认 | 为什么读不出来 | 影响 |
| --- | --- | --- | --- |
| 1 | **业务消息**的字段集与嵌套（WS 协议事件已实测确认） | 源码里同一处出现 `fromUser.id` 与 `fromUser.user_id` 两种写法，实际用哪个只能看报文 | M1 / M3 / M4 |
| 2 | 响应里 `code` 的类型与语义边界 | `code` 有时 `parseInt` 比较、有时 `==` 松散比较；且**成功码是 `0`，但拦截器在 `code == 0 && msg 非空` 时又弹 toast**，语义有歧义（见下） | M1 |
| 3 | `sendTime` 到底是秒还是毫秒（**已部分解决**） | M3 从源码里挖出三处矛盾证据：本地乐观消息是毫秒、撤回/时间分隔按毫秒相减、WS 推送又 ×1000。新端已用阈值归一化兜住两种单位，所以**不影响显示**；仍需要真实报文来确认服务端实际给的是哪种（也顺便能验出老端“自己发的消息不能撤回”这个推断是否成立） | M4 |
| 4 | 9 种消息类型 `extends` 的具体嵌套（**字段名已从渲染代码读全**，见 [message-types.md](message-types.md)，缺的是“服务端会不会多给/少给”） | 源码只用到其中一部分字段 | M3 / M4 |
| 9 | **发消息的回执到底带哪些字段**（尤其：服务端是否把客户端 uuid 原样放在 `id` 里回来、`data` 会不会是空对象） | 老端把 uuid 写在 `id` 上又按 `id` 匹配，但 `msg_id` 又是分页游标，两种可能都说得通 | M4（新端已两种都兼容，不影响使用） |
| 5 | 服务端生成的通话记录文案 | 客户端只发 `event/status/code/callTime`，`content` 由服务端拼 | M4 / M6 |
| 6 | `905` 码的语义 | 客户端代码里从未出现（只在解锁列表里被列过） | M6 |
| 7 | 分页参数名与游标 | 客户端传参与返回结构需与实际对照 | M3 / M4 |
| 8 | 服务端转发 ICE candidate 的行为 | 是否可靠、是否有序，有没有去重或限流，只能实测 | M6 |

## 本轮排查中发现的问题（老端遗留）

1. **`hostToken` 与实际域名对不上。**
   `config.js` 的计算是 `'sha' + md5(md5(host)) + 'bi'`，对 `message.gracelink.cc` 算出来应该是
   `sha33a368c6b977f663e8cb1c07eeec03f5bi`，但配置里写的是
   `sha740A9C7018B2CB55C7CC93D75BE0E8D9bi`——两者不相等（已用独立实现核对，并写成单测固定住）。
   按老端逻辑此时 `apiUrl` 会被置成字符串 `'false'`，App 应该完全发不出请求，说明**实际打包用的配置
   与这份副本不一致**。
   → Flutter 端处理：**保留算法用于排查，但失败放行**（只打印警告），避免一个防盗链字段把整个 App 弄瘫。

2. **`common/socket.js` 里混着与本项目无关的抄写残留**：`traderDetailIndex`、
   `accountStateIndex`、`followFlake`、`arrayFilter`（"跟随/我的持仓"过滤逻辑）。重写时直接丢弃，
   只保留连接、心跳、重连三件事。

3. **重连策略写得比较随意**：`onSocketError` 走 15 秒 `setInterval` 重连（最多 10 次），
   `onClose` 走另一套（最多 5 次），两处条件不同；且 `reconnect()` 的触发条件依赖那几个残留标志位。
   → Flutter 端统一成「指数退避 + 心跳超时判定」。

4. **响应拦截器的 `code == 0` 分支语义可疑**：`request.js` 在 `code == 0 && msg` 非空时弹 toast，
   但业务代码把 `code == 0` 当成功用（`if (res.code == 0) { 使用 res.data }`）。
   两种解释只能靠真实报文区分：要么成功响应不带 `msg`，要么存在「code 0 + msg」的软错误。
   → Flutter 端先按「`code == 0` 成功」实现，抓到样本后再校正。

5. **`pages.json` 的 tabBar 与真实 tab 不一致**：`pages.json` 里声明了
   `pages/index/index` + `pages/contacts/index` 两项且 `custom: true`，但真实 tab 是
   `pages/index/index.vue` 里手工画的四项（消息、通讯录、[发现]、我的），
   其中「发现」还要服务端 `compass.status == 1` 才出现（默认配置是 0，默认只有 3 个 tab）。

6. **`im-input.vue` 里的「位置」入口是注释掉的**，但消息渲染层保留了 `location` 类型。
   → 首版可以不做位置消息的发送入口，但**必须能正确渲染**（老端可能已有历史位置消息）。
