# 消息类型（服务端没有 schema，字段全部从老端渲染代码里读出来）

老端的分发逻辑在 `pages/message/chat.vue`（两次渲染各一份：当前页与"上下文"页），
每种类型的渲染在 `components/messageType/*.vue`，动态表情直接在 `chat.vue` 里画。

新端的对应实现：`lib/domain/chat/message_media.dart`（纯解析）+ `lib/features/chat/widgets/media/`（渲染）。

## 一览

| `type` | 内容 | 附加字段 | 新端实现 |
| --- | --- | --- | --- |
| `text` | `content`：文字（含 `[!1f600]` 表情 token） | `extends.content`：引用块文字 | `MessageBubble._richText` |
| `image` | `content`：图片地址 | `extends.fixMode/width/height` | `ImageBubble` |
| `emoji` | `content`：表情图地址 | — | `StickerBubble` |
| `voice` | `content`：音频地址 | `extends.duration`（**秒**） | `VoiceBubble` |
| `video` | `content`：视频地址 | `extends.poster`（封面）、`extends.duration`（秒）、`extends.width/height` | `VideoBubble` |
| `file` | `content`：文件地址 | `fileName` / `fileSize`（**顶层**，见下）、`extends.name/size` | `FileBubble` |
| `location` | `content`：地点标题 | `extends.address/latitude/longitude` | `LocationBubble` |
| `contact` | — | `extends.id/displayName/avatar`（`realname` 兜底） | `ContactBubble` |
| `webrtc` | `content`：卡片文案（1:1 的"通话时长 00:35"、群通话结束那条"群通话 12:30"） | `extends.type`（1 = 视频，其它 = 语音）、群记录多一个 `extends.group_call`（1 = 群通话，点一下进群通话页） | `CallBubble` |
| `event` | `content`：那行系统字（"创建了群聊"、"小明加入了群聊"、"撤回了一条消息"） | **`is_undo`**（1 = 撤回提示） | `_SystemLine`（居中一条半透明小黑条，**不是气泡**） |
| `diy` / 其它 | — | — | `UnsupportedBubble`（`diy` → "自定义"，其余 → "暂不支持的消息类型"） |

## 各类型的细节

### `text` + 动态表情 token

文字里的 `[!1f600]` 这种 token 要换成图片：根地址是 `{apiUrl}/static/img/emoji/twitter/{code}.png`。
分段规则与纯文本预览在 `lib/core/util/emoji.dart`（S4.1 已做），渲染在 `message_bubble.dart`。

### `image`

老端 `im-image.vue` 有四个分支，**实际只有三个能到**：

| 条件 | 效果 |
| --- | --- |
| `fixMode <= 2`（1 → 宽定 200、2 → 高定 240） | 老端本地发图时只写 1 或 2（`im-input.vue`：`res.width > res.height ? 1 : 2`） |
| `fixMode == 3` | 按 `extends.width/height` 原尺寸铺 |
| 其余 | 宽 120 等比 |

第四个分支 `v-else-if="!src && info && info.width"` 是**死代码**：它要求 `src` 为空，
却又拿空 `src` 去渲染图片。新端把它理解成作者的本意——"有原始宽高就按原比例算"——
用 `imageCoverStyle` 的效果兜住没有 `fixMode` 的报文。

`utils.js::imageCoverStyle` 自己也有死代码：第一个 `if (width < 200 && height < 240)` 必然被
第二个 `if` 覆盖，所以实际规则只有"宽 > 高 → 宽固定 200；否则高固定 240"。
`width`/`height` 都为 0 时会算出 `Infinity` / `NaN`，新端见 `lib/core/util/media_format.dart::mediaBoxSize`。

### `voice`

`extends.duration` 是**秒**。老端的宽度是 `秒数 × 3px` 夹在 160rpx…400rpx 之间
（3px 是逻辑像素、夹取用 rpx，两套单位混着，所以短语音永远顶在最小宽度）；
新端统一按 rpx 算（`最短 + 秒数 × 每秒钟多少`，见 `VoiceBubble`）。

老端的图标是 `cuIcon-subscription` 旋转 45°（自己发的那条转 225° = 镜像），
也就是「**一个实心圆点 + 围绕它的三道同心弧**」，圆点在最外侧、光弧朝里对着时长；
新端在 `VoiceWaveIcon` 里手画这个形状（弧的张角 ~100°、粗细 0.085、圆头），
播放时三道弧依次亮起。点同一条停、点别的切歌，离开页面要停（`VoicePlayerNotifier`）。

### `video`

老端显示封面图（复用 `im-image.vue`，`:info="item.extends"`）+ 半透明遮罩 + 播放图标 +
右下角 `videoFormatTime(duration)`，点一下进播放页（新端 S4.6）。

### `file`

老端读的是**顶层的 `fileName` / `fileSize`**（自己发出去的那条消息就是这么拼的），
而列表预览（`store/message.js::getMsgType`）用的是 `extends`。新端两处都读，最后再从 URL 猜文件名。
左侧那个图标老端是 `<image :src="item.extUrl">`，而 **`extUrl` 在整个老项目里只被读、从来没被写过**
——所以老端上文件图标一直是裂图。新端改成按后缀画彩色小方块，不依赖任何额外字段。

### `location` / `contact` / `webrtc`

* `location`：`content` 是标题，`extends.address` 是详细地址；点开地图（S4.6）。
* `contact`：`extends.avatar/displayName`，固定宽 360rpx，点进资料页（M5）。
* `webrtc`：1:1 的 `content` 由**服务端**给出（"通话时长 00:35"、"已取消"），`extends.type == 1` 用录像图标；
  信令语义（`code`/`event`）见 [call-signaling.md](call-signaling.md)，点一下回拨属于 M6。
  群里那条通话记录也走这个类型，但它是**客户端**发的（发了普通消息那条通道：`im/sendMessage`），
  内容形如「群通话 12:30」，靠 `extends.group_call == 1` 与新端区分 —— 点一下进群通话页，
  不是回拨。服务端与最后一个走的人怎么分工见 [sfu-group-call.md](sfu-group-call.md) 第十二节。

### `event`（系统消息：撤回 / 建群 / 入群）

**服务端什么时候发**：

* 建群：`app/enterprise/controller/Group.php::addGroup()` 直接往消息表插一条
  `type='event'`、`content = lang('group.add')`（"{:username}创建了群聊"，建群时用户名为空
  → 就是"创建了群聊"），同时给成员推 `addGroup`；
* 入群 / 被邀请：同一套语言包里的 `group.join` / `group.inviteJoin`；
* 撤回：`app/enterprise/controller/Im.php::undo()` 把那条消息本身改成 `type='event'` +
  `is_undo=1`，`content` 换成 `im.redo`（"撤回了一条消息"）/ `im.manageRedo`；
  推给别人的 WS 报文里 `content` 是**带名字**的（`fromUserName + text`，如"小明撤回了一条消息"）。

**老端怎么画**：`pages/message/chat.vue` 里 `v-if="item.type=='event'"` 单独一条分支，
渲染 `.cu-info`（`static/css/main.css`）：`display:inline-block` + `margin:20upx auto`、
字号 24upx、`padding: 8upx 12upx`、底 `rgba(0,0,0,.2)`、白字、圆角 6upx、最大宽 400upx；
`is_undo==1` 且还在 `redoTime` 窗口内时，后面再跟一个可点的「重新编辑」。

**新端**：`MessageBubble` 最前面那条分支（`isUndo == 1 || type == 'event'`）→ `_SystemLine`，
样式照抄 `.cu-info`。**用户 2026-09-21 反馈的 bug**：新端此前只认 `is_undo`，
所以建群后那条 `event` 消息掉进了未知类型分支，显示成蓝色气泡里的"暂不支持的消息类型"。

一个刻意的偏差：**本机撤回**那条的 `content` 还是原文（`patchMessage` 只把 `is_undo` 置 1），
照抄服务端内容会把原话又显示出来，所以自己撤的固定用语言包那句"你撤回了一条消息"；
别人撤的用服务端给的 `content`（"小明撤回了一条消息"）—— 与老端一致。

注意别和 `chat_items.dart` 里的**时间分隔**搞混：那个是界面上现造的假消息，
不是服务端来的 `event`。

### 未知类型

老端走 `im-item.vue`：白底不透明卡片，自己的消息在白底上显示黑字——看起来不像自己发的。
新端沿用文案，但底色跟随"是不是自己发的"。

## 尚未校准的地方

上面这些字段是从老端**代码**读出来的，还没有用真实报文逐条比对过（见规划书 S6.0）。
已知的风险点：

1. `extends` 里除了上面用到的字段，服务端可能还塞了别的东西（新端整体存 JSON 不丢字段）。
2. 自己发的图片/文件走的是上传接口（`msgApi.uploadUrl`，S4.4 接），
   `content` 存的是服务端返回的地址，**老端不做任何前缀拼接**——直接当 URL 用。
3. `fixMode == 3` 老端从未产出过，只有服务端/将来的端会发。
