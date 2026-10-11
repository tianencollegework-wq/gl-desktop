# HTTP 接口对照表

来源：`api/login.js`、`api/message.js`、`api/friend.js`、`api/emoji.js`、`utils/request.js`。

## 请求约定

| 项 | 值 |
| --- | --- |
| Base URL | `https://{host}`（老端 `config.apiUrl`） |
| 方法 | 全部为 **POST**（`getRequest` 存在，但业务模块未使用） |
| Content-Type | 绝大多数为 `application/json`（`postJsonRequest`）；`postRequest` 用的是 `application/x-www-form-urlencoded`，业务模块里没用到 |
| 超时 | 10 秒 |
| 请求头 | `Authorization`（本地存的 `authToken`）、`clientId`（本地 `client_id`）、`cid`（推送客户端 id）、`accept-language`（`language.value`，注意是**对象取值**，实际发送 `zh-Hans` / `en`） |

### 响应约定

```jsonc
{ "code": 0, "msg": "", "data": {} }
```

| code | 含义 | 老端行为 |
| --- | --- | --- |
| `0` | 业务成功 | 业务代码直接取 `res.data` |
| `-1` | 需要重新登录 | 提示后 `reLaunch` 到登录页 |
| `400/401/402/403/404/405/500/502` | 请求异常 | 弹 toast 显示 `msg` |
| HTTP `401` | 鉴权过期 | App 端弹窗（取消=退出应用 / 确认=去登录）；非 App 端弹 modal 去登录 |
| HTTP `500` | 服务端错误 | 提示 |
| 其它 | 网络异常 | 提示"无网络" |

> ⚠️ 待确认：拦截器在 `code == 0` 且 `msg` 非空时**也会弹 toast**，与"`code == 0` 即成功"的用法冲突。
> 可能成功响应不带 `msg`，也可能存在 `code 0 + msg` 的软错误。以真实报文为准，首版按"`code == 0` 成功"实现。

### 网络前置检查

`request.js` 的请求拦截器里会先 `uni.getNetworkType`，无网络时提示并**中断请求**。
Flutter 端对应：Dio 拦截器里检查连接状态，或在 UI 层统一处理（推荐后者，避免每个请求都探测一次）。

## 接口全表

### 1. 认证与用户（`api/login.js`）

| 接口 | 路径 | 参数（M2 已从调用点确认） | 返回 |
| --- | --- | --- | --- |
| 登录 | `/common/Pub/login` | `{account, password, code, client_id, rememberMe}` | `{authToken, userInfo}` |
| 退出 | `/common/Pub/logout` | `{client_id}` | — |
| 注册 | `/common/pub/register` | `{account, realname, password, repass, code}` | — |
| 绑定 client_id | `/common/Pub/bindUid` | `{client_id, user_id, cid}` | — |
| 绑定群 client_id | `/common/pub/bindGroup` | `{client_id, group_id}` | — |
| 全局配置 | `/common/pub/getSystemInfo` | 无 | `globalConfig` 整份（见下） |
| 发送验证码 | `/common/pub/sendCode` | `{account, type}`，`type`: 1 登录/忘记密码、2 注册、**3 改密码、4 改账号（S5.5 补）** | — |

两个容易踩的细节（都是从老端调用点读出来的）：

* **登录的 `password` 在「忘记密码」模式下写死为 `123456`**，真正的验证码走 `code` 字段
  （`pages/login/index.vue` 的 `watch.forget`）。
* **`client_id` 在登录请求里是上一次会话存下来的**。老端从本地读，首次登录（或刚装完包）
  拿到的是空串；真正把 `client_id` 绑到用户身上靠的是 WS `init` 后的 `bindUid` + WS `bindUid` 帧。
* **`cid` 全项目从来没有被写入过**（只有 `uni.getStorageSync('cid')` 的读），所以老端上报的永远是空串。
  新端同样先不伪造（避免改变服务端语义），等 M8 接离线推送时再定。

`getSystemInfo` 返回的 `globalConfig` 结构（默认值取自 `store/login.js` 的 `defaultConfig`）：

```
sysInfo:  { logo, name, diyName, regauth, regtype, runMode, ipregion, multipleLogin }
chatInfo: { online, webrtc, dbDelMsg, redoTime, groupChat, simpleChat }
compass:  { mode, status }        // status == 1 才显示「发现」tab
demon_mode: bool                 // 演示模式：登录页显示演示账号
```

> ⚠️ 服务端返回 `data: null`（空配置）时**不能用默认值覆盖本地**：老端是
> `globalConfig = res.data` 无脑覆盖，会把刚推来的 `updateConfig` 抹掉。新端已规避（M2）。

#### 我的（S5.5）

| 用途 | 接口 | 参数（老端写法） | 返回 / 本地跟着做什么 |
| --- | --- | --- | --- |
| 保存资料 | `/enterprise/im/updateUserInfo` | `{realname, email, sex, motto}`，`sex`: 1 男 / 0 女 | 成功后把四个字段合并回本地登录用户（老端 `loginStore.login(data)`） |
| 头像上传 | `/common/upload/uploadAvatar` | 表单：`ext=png` + `file`（图片本体） | **`data` 直接是图片 URL 字符串**（不是对象）；成功后换本地用户头像 |
| 修改密码 | `/enterprise/im/editPassword` | `{password, code, originalPassword}`（已认证只填 `code`，未认证只填原密码） | 弹回执的 `msg` |
| 修改账号 | `/enterprise/im/editAccount` | `{account, code, newCode}`（`code` 是当前账号的验证码、`newCode` 是新账号收到的） | 老端固定弹「修改成功，请重新登陆」 |

* **四个接口老端都没有前导斜杠**（`enterprise/im/updateUserInfo`），Flutter 端统一补上（见「迁移注意点」第 1 条）。
* **`sex` 是数字**：老端 `sexList` 顺序是「男(1) / 女(0)」，提交时不带字符串。
* **邮箱可空**，非空时必须匹配 `^[^\s@]+@[^\s@]+\.[^\s@]+$`（老端 `profile.vue` 那个正则）。
* **昵称的只读条件**是 `runMode == 1 && diyName != 1`（企业模式且不允许自定义名字），此时那一行标题从「用户名/昵称」变成「姓名」。
* **上传接口的鉴权头与字段名**仍待真实报文对照（老端的 uploader 是 `uni.uploadFile`，字段名由调用处指定）。

### 2. 消息与会话（`api/message.js` → `msgApi`）

`getUserInfo` 的 `data`（S5.2 用到的部分，字段名取自老端 `pages/contacts/detail.vue` 的读法）：

```
user_id, realname, account, avatar, email, sex, last_login_ip, location
friend:      { friend_id, nickname }        // 只有已经是好友时才有这个键
contactInfo: 会话列表用的那份联系人信息      // 老端 `sendMsg` 靠它 appendContacts
groupInfo:   { name, owner_id, manageRole, userInfo:{role, no_speak_time} }   // 群内管理，S5.3
```

* `sex`：`0` 女、`1` 男，其余（含缺失）都是「未知」（老端 `arr[value] || unknown`，`profile.vue` 的单选也是 1 男 0 女）。
* `account` 被当手机号用：只有能通过 `^1[3456789]\d{9}$` 才给「打电话」（`detail.vue` 的 `validatePhone`）。
* 好友那几个写接口（`/enterprise/friend/{add,del,update,setNickname}`）的**回执 `msg` 老端会直接弹成 toast**，
  所以新端这几个方法都返回 `msg`（走 `ApiClient.send` 取信封，失败由页面自己提示）。

| 接口 | 路径 | 备注 |
| --- | --- | --- |
| 初始化联系人/会话 | `/enterprise/im/getContacts` | 进消息页拉全量会话。**返回数组**；无参数（M3 已确认） |
| 会话列表 | `/enterprise/im/getChatList` | |
| 好友列表 | `/enterprise/im/getFriendList` | |
| 群聊列表 | `/enterprise/im/getGroupList` | |
| 消息列表 | `/enterprise/im/getMessageList` | **返回数组**；参数（M3 已从 `chat.vue::queryList` 确认）：`{is_group, toContactId, last_id, page, limit}`，其中 `last_id` 是当前手里最旧一条的 `msg_id`（首页传空串） |
| 消息上下文 | `/enterprise/im/getMessageContext` | 参数 `msg_id`、`is_group`、`direction` |
| 单条消息详情 | `/enterprise/im/getMessageInfo` | 参数 `msg_id` |
| 设置置顶 | `/enterprise/im/setChatTop` | 参数 `{id, is_top}` |
| 删除会话 | `/enterprise/im/delChat` | 参数 `{id}`。**只删服务端会话，老端也不清本地（因为它本来就不存历史）** |
| 会话免打扰 | `/enterprise/im/isNotice` | 参数 `{id, is_notice}` |
| 发送消息 | `/enterprise/im/sendMessage` | 请求体见下节（S4.4 逐个字段读出）。**只有文本/位置/名片/表情走这里**，图片/文件/视频/语音走上传接口 |
| 转发消息 | `/enterprise/im/forwardMessage` | 参数待 M5 做转发时确认 |
| 设置已读 | `/enterprise/im/setMsgIsRead` | 聊天页收到新消息时调，参数：`{toContactId, is_group, fromUser}`（M3 已确认；老端还会带上 `messages` 整个消息体，新端暂不带，待报文校正） |
| 清 @ 提醒 | `/enterprise/im/readAtMsg` | 打开 @ 面板时调，参数 `{toContactId}` |
| @消息已读 | `/enterprise/im/readAtMsg` | |
| 撤回消息 | `/enterprise/im/undoMessage` | |
| 删除消息 | `/enterprise/im/delMessage` | |
| **发送 WS 消息** | `/enterprise/im/sendToMsg` | **通话信令走这里**，见 call-signaling.md |
| 免打扰 | `/enterprise/im/isNotice` | |
| 更新业务卡片 | `/enterprise/im/updateCard` | |
| 获取成员信息 | `/enterprise/im/getUserInfo` | `{user_id, group_id}`（`group_id` 只有从群里点进来时才带） |
| 扫码登录 | `/enterprise/im/tokenLogin` | |
| 搜索用户 | `enterprise/im/searchUser` | 注意：老端这里**没有前导斜杠**（依赖 baseURL 拼接，Flutter 端注意归一化） |
| 修改用户信息 | `enterprise/im/updateUserInfo` | 同上 |
| 修改账号 | `enterprise/im/editAccount` | 同上 |
| 修改密码 | `enterprise/im/editPassword` | 同上 |
| 联系人信息 | `enterprise/im/getContactInfo` | 同上 |
| 公告信息 | `enterprise/im/getAdminNotice` | 同上 |

#### 发送消息的请求体（S4.4，从 `im-input.vue::msgItem()` + `chat.vue::sendMessage()` 逐字读出）

```json
{
  "id": "客户端 uuid（老端 $util.getUuid()）",
  "sendTime": 1700000000000,
  "status": "going",
  "type": "text",
  "content": "你好[!1f600]",
  "is_read": 0,
  "is_group": 0,
  "file_id": 0,
  "file_cate": 0,
  "fileName": "",
  "fileSize": 0,
  "extends": null,
  "fromUser": {"...整份登录用户对象...", "id": "user_id"},
  "from_user": "user_id",
  "toContactId": "对方 user_id / group_id",
  "at": [2, 3],
  "pid": "被引用消息的 msg_id"
}
```

* `at` 只在群里 @ 到人时才出现。老端是从富文本编辑器的 link 节点里抓 user_id
  （`utils/edit.js::getLink()`，还会 `parseInt` 一次）；新端输入框是纯文本，
  按「文本里还留着 `@名字`」判定，语义一致（`domain/chat/group_members.dart::resolveAt`），
  **不做 `parseInt`**（老端遇到非数字账号会变成 `NaN`）。@所有人 的 user_id 是 `0`。
* `pid` 与 `extends` 只在引用消息时出现
  （`extends` 此时就是引用块 `{msg_id, content, user_id, realname}`）。
* `fromUser` 是**整份登录用户对象**再补一个 `id`（老端 `user.id = user.user_id` 后整份塞进去）。
* 老端发完用 `data` 里的消息**覆盖**内存里那条（`updateMessage(res.data)`，按 `id` 匹配）；
  `code == 401` 时它会把最后一条从列表里弹掉（禁言之类）。
* **待实测确认**：服务端到底把哪个字段回传（老端把 uuid 放在 `id` 里、又按 `id` 匹配，
  说明服务端很可能原样回传这个 uuid；但 `msg_id` 又是分页游标）。新端两种都兼容：
  按 `id` / `msg_id` / 本机 `clientId` 依次匹配，都不中就按「同会话 + 同内容 + 时间接近」认领。

> **新端刻意的差别**：文本 `content` 发**纯文本**（表情以 `[!code]` token 内嵌），
> 不是老端那种带 `<p>` 的富文本 HTML。老端渲染时本来就要把 token 换成图片
> （`im-text.vue::emojiToHtml`），所以对方看到的完全一样。

#### 图片 / 文件 / 视频 / 语音怎么发（S4.4b 已接）

老端走 `uni.uploadFile`（`chat.vue` 第 946 行起），目标 `{apiUrl}/common/upload/uploadFile`：

```js
uni.uploadFile({
  url: this.$api.msgApi.uploadUrl,      // {apiUrl}/common/upload/uploadFile
  filePath: message.content,            // 本地临时路径
  name: 'file',                         // ← 文件字段名
  formData: { message: JSON.stringify(message) },  // ← 表单字段就这一个
  header: { 'Authorization': uni.getStorageSync('authToken') },
})
```

即：**两段式 multipart** —— `message` 字段是整条消息的 JSON 字符串（与上面同一份结构）、
`file` 字段是文件本体。响应同样是信封，`data` 是服务端存下来的那条消息
（图片的 `extends.fixMode/width/height` 由服务端算）；`code == 401` 时老端把自己那条弹掉。

发送前比 `globalConfig.fileUpload.size`（MB，默认 10）限制大小，视频另有 60 秒上限；
超限只本地提示、不发请求。**新端实现同上**（`ChatApi.uploadFile` + `MessageSender.sendMedia`，
`test/repo/media_send_test.dart` 逐字段断言了这两段）。

> **语音同样走这条链路**：老端 `chat.vue` 的分支条件是 `message.type`（`fileTypes` 包含
> `voice`），而 `im-input.vue` 发语音时只 `$emit('send', message)`、**没有传第二个参数**
> ——`file` 这个参数从头到尾没人用。语音消息体：`type: 'voice'`、`content` 是本地临时路径、
> `extends: {duration}`（老端那个 1 秒一跳的计数器）、`fileName: uuid + '.mp3'`、没有 `fileSize`。
> 新端如实给 `fileSize`（走同一道大小校验），并且录的是 AAC（`record` 没有 mp3 编码器），
> 因此 `fileName` 是 `uuid + '.m4a'`。
>
> **新端刻意的差别**：视频的 `extends`（`duration/width/height/fixMode`）**不由客户端算**。
> 老端在 `chooseVideo` 里自己算好再发；新端只带文件名与大小，等回执由服务端补
> —— 读到回执之前气泡上的时长显示 0。图片本来就看服务端回执，不受影响。

#### 名片怎么发（S4.6b 已接）

名片**不走上传**，走普通 `sendMessage`（老端 `im-input.vue::sendContactCard`）：

```json
{
  "type": "contact",
  "content": "[个人名片] 小红",
  "extends": { "avatar": "...", "displayName": "小红", "id": "u3" }
}
```

* `content` 是**会话列表与通知里显示的那行字**（老端 `'[' + $t('chat.userIDcard') + '] ' + displayName`）；
  真正渲染的是 `extends` 里那三个键，老端的 `im-contact.vue` 读的就是 `item.extends.displayName`。
* `extends.id` 是**对方的 `user_id`**：点名片时老端 `mixins/chat.js::openContact` 直接把它拼进
  `/pages/contacts/detail?id=`。老端没校验它是否存在（`undefined` 会拼出一个坏地址），新端会。
* 名片与引用**互斥**：引用块也放在 `extends` 里，所以发名片时不能带 `pid`。
* 候选人是**好友列表**（老端 `user-select :type="1"`，读 storage 里的整份好友缓存）且**单选**。

#### 消息操作（S4.5）

| 操作 | 接口 | 参数（老端写法） | 本地跟着做什么 |
| --- | --- | --- | --- |
| 撤回 | `/enterprise/im/undoMessage` | `{id, msg_id}`：`id` 是**服务端认那条消息的键** —— 数字 id，或者（刚发出去那条）服务端原样回传的本机 uuid；**只发 `msg_id` 不行**（`Im.php::undo()` 取 `$param['id']`，取不到就 HTTP 500，2026-09-30 修） | 把那条标成 `is_undo=1`，原文留着（能重新编辑）；服务端之后会推 `undoMessage` 事件 |
| 删除 | `/enterprise/im/delMessage` | 同上 | 把自己列表里那条删掉；新端连本地一起删（老端没本地历史） |
| 转发 | `/enterprise/im/forwardMessage` | `{user_ids: [...], msg_id}` | 服务端把消息复制给这些人；**一次请求搞定**，界面无反馈 |
| 已读上报 | `/enterprise/im/setMsgIsRead` | `{toContactId, is_group, fromUser}` | 老端只在聊天页收到新消息时调；新端一样（进页只清本地未读，不调接口） |
| @ 已读 | `/enterprise/im/readAtMsg` | `{toContactId}` | 点开「N 人提到我」面板时调，本地 `is_at` 归零 |

> 两个容易看漏的地方：
> * 老端长按菜单里的「删除」条件是 `globalConfig.chatInfo.dbDelMsg && fromUser.id == 自己`
>   ——**群里管理员也删不了别人的消息**（但能撤回，撤回的条件是 `role < 3`）；
> * 转发限 5 人（`message.forwardLimit`），候选是好友 + 群聊（`getFriendList` / `getGroupList`，
>   两个接口返回的都是**数组**），并且排掉当前会话。

#### 搜索与聊天记录（S5.4）

| 用途 | 接口 | 参数（老端写法） | 返回 |
| --- | --- | --- | --- |
| 搜人 | `/enterprise/im/searchUser` | `{keywords}` | **`data` 是数组**，每项 `{user_id, realname, avatar, account, friend}` |
| 会话内聊天记录 | `/enterprise/im/getMessageList` | `{toContactId, is_group, type, keywords, page, limit}` | **`data` 是数组**，信封里另带 `count`（总条数，分页条用它） |
| 某条消息的前后文 | `/enterprise/im/getMessageContext` | `{msg_id, is_group, direction}` | **`data` 是数组** |

* 聊天记录的 `type` 取 `all` / `text` / `image` / `video` / `file`（老端那五个分段，
  默认 `all`）；`keywords` 为空串就是不搜；`limit` 老端写死 10。
* **`direction` 是数字**（不是字符串）：`0` 以这条为中心、`1` 往更早、`2` 往更晚。
  老端 `viewContext` / `loadContext` 就是拿列表一头一尾继续往下拉。
* 聊天记录与前后文这两份新端**不写本地库**：它们可能缺 `toContactId`（前后文那一份就不带），
  而且前后文会带上边界重复条。要看本地历史有聊天页，它自己维护。

### 3. 群组（`api/message.js`）

| 接口 | 路径 | 参数（老端写法） | 本地跟着做什么 |
| --- | --- | --- | --- |
| 加入群聊 | `/enterprise/group/joinGroup`（老端重复定义了一次，后一个覆盖前一个） | `{id}` | — |
| 群成员列表 | `/enterprise/group/groupUserList` | `{group_id}` | 只读；**`data` 是数组**，信封里另带 `count`（总人数，老端那个「查看全部群成员 N 人」用它） |
| 修改群公告 | `/enterprise/group/setNotice` | `{id, notice}` | 公告存在会话行的 `extra.notice`，改完顺手覆盖本机那一格 |
| 群信息 | `/enterprise/group/groupInfo` | `{id}` | — |
| 修改群信息 | `/enterprise/group/groupSetting` | `{id, setting}` | 老端是「点开关改内存 → 点保存才提交」；`setting` 四个开关 `manage` / `invite` / `history` / `profile`（`'0'` / `'1'`）+ `nospeak`（0 关闭禁言 / 1 只有管理员能发言 / 2 只有群主能发言） |
| 转让群主 | `/enterprise/group/changeOwner` | `{id, user_id}` | 老端成功后 `reLaunch` 回首页（权限整个换了） |
| 全部人员 | `/enterprise/group/getAllUser` | — | — |
| 创建群聊 | `/enterprise/group/add` | — | — |
| 绑定群聊 | `/common/index/bindGroup` | — | — |
| 修改群名 | `/enterprise/group/editGroupName` | `{id, displayName}` | 新端连本地通讯录与会话一起改名（老端只改界面） |
| 添加群成员 | `/enterprise/group/addGroupUser` | `{id, user_ids: [...]}` | 一次可提交多个；候选是好友减去已在群里的 |
| 移除群成员 | `/enterprise/group/removeUser` | `{id, user_id, is_black}` | `is_black` 是那个「加入黑名单」开关；**退群也是这个接口**（`user_id` = 自己） |
| 解散群聊 | `/enterprise/group/removeGroup` | `{id}` | 新端把本地会话与联系人一起删 |
| 清空聊天记录 | `/enterprise/group/clearMessage` | `{id}` | 服务端清所有人的，新端连本地消息一起清 |
| 设置/取消管理员 | `/enterprise/group/setManager` | `{id, user_id, role}` | `role` 2 = 管理员、3 = 普通成员 |
| 设置禁言 | `/enterprise/group/setNoSpeak` | `{id, user_id, noSpeakDay, noSpeakTimer}` | 预设 `noSpeakTimer` 1..4（10 分钟 / 1 小时 / 3 小时 / 1 天）、自定义天数走 `noSpeakDay`、**取消禁言两个都传 0** |

* **群成员每项的形态**：`{role, no_speak_time, no_speak_day, userInfo: {id, displayName, avatar, name_py}}`；
  `role` 1 群主 / 2 管理员 / 3 普通成员；`no_speak_time` 是**秒**（新端按 `> 9e10 才算毫秒` 归一化）。
  新端这里**不做「排除自己」的过滤**（判断我的角色要用到它），界面自己排除。
* 老端 `groupUser.vue` 那批接口都会把回执的 `msg` 弹成 toast，但回执文案的真实值待真机确认。

### 4. 好友（`api/friend.js`）

| 接口 | 路径 |
| --- | --- |
| 删除好友 | `/enterprise/friend/del` |
| 添加好友 | `/enterprise/friend/add` |
| 新朋友列表 | `/enterprise/friend/index` |
| 同意/拒绝申请 | `/enterprise/friend/update` |
| 设置备注 | `/enterprise/friend/setNickname` |

* **新朋友列表的 `data` 是数组**，信封里另带 `count`（总条数，`uni-pagination` 用它）；
  参数是 `{page, limit, is_mine}`，老端 `limit` 是 10。
* 两个口径的嵌套字段不同（以实际报文为准，新端两处都做了兼容）：
  `is_mine = 0` 用 `create_user_info`（申请人），`is_mine = 1` 用 `user_id_info`（被申请的人），
  字段都是 `{user_id, realname, avatar}`。每条另有 `status`（0 已拒绝 / 1 已同意 / 2 待处理）、`remark`（验证信息）、`friend_id`。
* **同意 / 拒绝**（`/enterprise/friend/update`）的参数是 `{friend_id, status}`（1 接受 / 0 拒绝），
  老端把回执的 `msg` 直接弹成 toast（真实值待真机确认）。

### 5. 表情（`api/emoji.js`）

| 接口 | 路径 |
| --- | --- |
| 表情列表 | `/enterprise/emoji/index` |
| 添加表情 | `/enterprise/emoji/add` |
| 删除表情 | `/enterprise/emoji/del` |
| 移动表情 | `/enterprise/emoji/move` |

* **列表返回数组**，每项是 `{src, file_id}`（老端直接拿去当图片地址用），S4.4 已用上。
* 发收藏表情时 `type` 是 `emoji`、`content` 是 `src`，并且带上 `file_id`。
* `add` 的参数是 `{file_id}`（先上传到 `uploadEmoji` 拿到 `file_id`）；`del` / `move` 待 S4.4b 接。
* 内置表情是**写死在客户端**的 66 张 twitter 图片（`utils/emoji.js`），
  `src` 规则为 `{apiUrl}/static/img/emoji/twitter/{code}.png`；
  发送时以 `[!code]` token 内嵌在 `content` 里（不是发图片地址）。

### 6. 上传（直接使用的完整 URL，不是封装方法）

| 用途 | 完整地址 |
| --- | --- |
| 文件上传 | `{apiUrl}/common/upload/uploadFile` |
| 头像上传 | `{apiUrl}/common/upload/uploadAvatar` |
| 自定义表情上传 | `{apiUrl}/common/upload/uploadEmoji` |

> 三个上传是**表单直传**（老端把完整 URL 拼好交给 uploader），Flutter 端用 `dio` 的 `FormData` 对应实现；
> 表单字段名与鉴权头需要真实请求对照。

## 迁移到 Flutter 时的注意点

1. **路径前导斜杠不统一**：部分接口少了 `/`，`baseURL` 拼接行为在 Dio 与 u-ajax 下不同（Dio 会按 URL 解析规则拼接）。
   统一在 `chat_api` 里补成以 `/` 开头的绝对路径，避免出现 `https://hostenterprise/im/...` 这类错误。
2. **`accept-language` 取的是对象**：老端 `uni.getStorageSync('language')` 存的是 `{key, value}`，
   所以真实值是 `zh-Hans`；Flutter 端直接存语言码字符串即可。
3. **`code == -1` 与 HTTP 401 是两条不同的重登路径**，都要实现。
4. 接口数量约 **60 个**，建议按 `auth / chat / group / friend / emoji / upload` 六个文件分组（对应 M1 的 S1.3）。
