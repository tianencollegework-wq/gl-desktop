# 灵听-赞美诗歌 API 接口文档

> 来源：`https://check-api.lingtingmusic.com/v2/api-docs`（Swagger 2.0）+ 实测验证
> 整理时间：2026-09-23
> 说明：标注「✅ 已实测」的为实际调用验证过的接口

---

## 一、基础信息

| 项目 | 值 |
|---|---|
| API Host | `check-api.lingtingmusic.com` |
| BasePath | `/` |
| 分享页 Host | `share.lingtingmusic.com`（仅 `/api/v1/music/detail` 和 `/api/v1/homepage/top/*/song`） |
| 管理后台 Host | `admin.lingtingmusic.com`（`/api/v1/admin/login`） |
| 协议 | HTTPS |
| Swagger 版本 | 2.0 |
| API 版本 | 1.0 |
| 资源域名 | `resource.lingtingmusic.com` |
| COS 存储 | `listen-to-heart-1320693856.cos.ap-nanjing.myqcloud.com` |

---

## 二、公共约定

### 2.1 统一响应体

```json
{
  "timeStamp": 1789086307542,
  "data": {},
  "success": true,
  "errorCode": "0",
  "errorMessage": ""
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `timeStamp` | int64 | 服务端返回时间 |
| `data` | 泛型 | 返回结果，类型随接口而定 |
| `success` | boolean | 是否成功 |
| `errorCode` | string | 错误代码 |
| `errorMessage` | string | 错误描述 |

### 2.2 鉴权方式

通过 Header 传递：

| Header | 类型 | 说明 |
|---|---|---|
| `memberId` | integer | 用户 ID |
| `token` | string | JWT Token |

**鉴权强度实测结论：**

| 强度 | 说明 | 示例 |
|---|---|---|
| 公开 | 不传任何 Header 即可调用 | `/v1/healthy/check` |
| 弱鉴权 | 传 `memberId: 0` 即可调用，无需 token | `/v1/search/*`、`/v1/music/detail` |
| 强鉴权 🔒 | 必须传有效 token | `/v1/member/*`、`/v1/local-song/like` |
| 服务端鉴权 | 普通 token 不足，需更高权限 | `/v1/file/version/apk/upload`（实测返回 401） |

### 2.3 鉴权标记说明

- 无标记：`token` / `memberId` 均可选
- 🔒：`token required: true`
- ✅：已实测验证可调用
- ⚠️：已实测发现异常

---

## 三、账户接口 `/v1/account/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 | 实测 |
|---|---|---|---|---|---|
| POST | `/v1/account/anonymous/login` | 匿名用户登录 | body: 用户登录记录 | string(JWT) | ✅ 可调用 |
| POST | `/v1/account/login` | App 登录并获取 token | body: 登录请求参数 | string | |
| POST | `/v1/account/register` | App 注册 | body: RegisterRequestDto | string | |
| POST | `/v1/account/logout` | 注销账户 🔒 | header: token | string | |
| POST | `/v1/account/refresh` | 刷新 token | query: anonymousId(必填), token | string | |
| POST | `/v1/account/sendCode` | 发送验证码 | query: phoneNum(必填) | string | ✅ 可调用，不返回验证码 |
| POST | `/v1/account/password/forget` | 忘记密码 | body: RegisterRequestDto | string | |
| POST | `/v1/account/password/update` | 修改密码 🔒 | query: oldPassword, password | string | |
| POST | `/v1/account/wx/login` | 微信登录 | body: 微信登录请求参数 | string | |
| POST | `/v1/account/wx2/login` | 微信登录 2 | body: 微信登录请求参数 | string | |
| POST | `/v1/account/ios/login` | iOS 登录 | body: IOS登录请求参数 | string | |
| POST | `/v1/account/gzh/sign` | 公众号生成签名 | query: url(必填) | JSONObject | |
| POST | `/v1/account/bind/phone` | 绑定手机号 🔒 | body: BindPhoneRequestDto | string | |
| POST | `/v1/account/bind/wx` | 绑定微信 🔒 | query: code | string | |
| POST | `/v1/account/bind/ios` | 绑定苹果账户 🔒 | query: identityToken, userId | string | |
| POST | `/v1/account/unbind` | 解除账户绑定 🔒 | query: type (1-手机 2-微信 3-iOS) | string | |

---

## 四、音乐接口 `/v1/music/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 | 实测 |
|---|---|---|---|---|---|
| GET | `/v1/music/all` | 全部音乐 | pageNum, pageSize | List<歌曲> | |
| GET | `/v1/music/detail` | 音乐详情 | songId(必填) | 音乐详情 | ✅ memberId:0 可调 |
| GET | `/v1/music/banner` | 音乐库 Banner | — | List<banner> | |
| GET | `/v1/music/lyric` | 根据歌曲 id 获取歌词 | songId(必填) | string | |
| GET | `/v1/music/lyric/batch` | 批量获取歌词 | body: songIdList | List<LyricVo> | |
| POST | `/v1/music/like` | 喜欢音乐 | query: songId(必填) | string | |
| POST | `/v1/music/like/batch` | 批量喜欢音乐 | body: songIdList | string | |
| POST | `/v1/music/unlike` | 取消喜欢音乐 | query: songId(必填) | string | |
| POST | `/v1/music/unlike/batch` | 批量取消喜欢 | body: songIdList | string | |
| POST | `/v1/music/play` | 播放记录 | query: songId, localSongId, typeId, sourceId, anonymousId | string | |
| POST | `/v1/music/play/batch` | 批量记录播放 | body: 记录批量播放音乐的请求实体 | string | |
| POST | `/v1/music/play_time` | 播放时长记录 | body: 记录播放时长的请求实体 | string | |
| POST | `/v1/music/download` | 下载记录 | query: songId, path | int | |
| POST | `/v1/music/check/download` | 判断音乐是否可下载 | body: songIds | List<bigint> | |

---

## 五、视频接口 `/v1/video/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| GET | `/v1/video/all` | 全部视频 | pageNum, pageSize | List<视频> |
| GET | `/v1/video/detail` | 视频详情 | videoId(必填) | 视频详情 |
| GET | `/v1/video/hot` | 最热视频 | — | List<视频> |
| GET | `/v1/video/newly` | 最新视频 | — | List<视频> |
| GET | `/v1/video/play` | 视频播放记录 | videoId(必填), anonymousId | string |
| POST | `/v1/video/batchPlay` | 视频批量播放 | body: videoIds, anonymousId | string |
| GET | `/v1/video/like` | 点赞视频 | videoId(必填) | string |
| POST | `/v1/video/like/batch` | 批量点赞视频 | body: videoIdList | string |
| GET | `/v1/video/unLike` | 取消点赞视频 | videoId(必填) | string |
| POST | `/v1/video/unLike/batch` | 批量取消点赞 | body: videoIdList | string |
| GET | `/v1/video/likeList` | 全部视频点赞列表 | — | List<视频> |
| POST | `/v1/video/collect` | 视频收藏 | videoId(必填) | string |
| POST | `/v1/video/collect/batch` | 视频批量收藏 | body: videoIdList | string |
| POST | `/v1/video/unCollect` | 视频取消收藏 | videoId(必填) | string |
| POST | `/v1/video/unCollect/batch` | 视频批量取消收藏 | body: videoIdList | string |
| GET | `/v1/video/download` | 视频下载记录 | videoId, path | int |

---

## 六、歌单接口 `/v1/song-sheet*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| GET | `/v1/song-sheet` | 根据分类获取歌单列表 | categoryId, keyword, pageNum, pageSize | List<歌单> |
| GET | `/v1/song-sheet/detail` | 歌单详情 | songSheetId(必填) | 歌单详情 |
| GET | `/v1/song-sheet/info` | 歌单基本信息 | songSheetId(必填) | 歌单详情 |
| GET | `/v1/song-sheet/songList` | 分页获取歌单歌曲列表 | songSheetId(必填), pageNum, pageSize | List<歌曲> |
| GET | `/v1/song-sheet/songListById` | 根据 id 获取歌单歌曲列表 | songSheetId(必填) | List<歌曲基本信息> |
| GET | `/v1/song-sheet/search` | 搜索歌单内信息 | songSheetId(必填), keyword(必填) | SearchMusicDto |
| GET | `/v1/song-sheet/authorInfo` | 歌单作者信息 | authorId(必填) | 个人账户信息 |
| GET | `/v1/song-sheet/play` | 播放歌单 | songSheetId(必填) | string |
| POST | `/v1/song-sheet/create` | 创建歌单 | body: SongSheetCreateDto | bigint |
| POST | `/v1/song-sheet/update` | 修改歌单 | body: SongSheetCreateDto, songSheetId | string |
| POST | `/v1/song-sheet/delete` | 删除歌单 | songSheetId(必填) | string |
| POST | `/v1/song-sheet/add-song` | 加入歌曲进歌单 | body: 添加歌曲到歌单请求参数 | 添加歌曲返回信息 |
| POST | `/v1/song-sheet/add-songs` | 加入歌曲进歌单(Param) | query: songSheetId, songIds[], localSongIds[] | 添加歌曲返回信息 |
| POST | `/v1/song-sheet/delete-song` | 从歌单中删除歌曲 | body: 添加歌曲到歌单请求参数 | CommonResponse |
| POST | `/v1/song-sheet/sort` | 调整自建歌单顺序 | currentIndex, songSheetId, targetIndex | string |
| POST | `/v1/song-sheet/sort-song` | 歌单内歌曲排序 | body: SortSongDto | string |
| POST | `/v1/song-sheet/batch-sort` | 批量调整自建歌单顺序 | body: 自建歌单排序信息[] | string |
| POST | `/v1/song-sheet/batch-play` | 批量播放歌单 | body: songSheetIds | string |
| POST | `/v1/song-sheet/collect` | 收藏歌单 | songSheetId(必填) | string |
| POST | `/v1/song-sheet/cancel-collect` | 取消收藏歌单 | songSheetId(必填) | string |
| POST | `/v1/song-sheet/batch-collect` | 批量收藏歌单 | body: songSheetIds | string |
| POST | `/v1/song-sheet/batch-cancel-collect` | 批量取消收藏歌单 | body: songSheetIds | string |

---

## 七、歌手接口 `/v1/singer/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| GET | `/v1/singer/list` | 获取歌手列表 | — | Map<string, List<歌手>> |
| GET | `/v1/singer/detail` | 歌手详情 | singerId(必填) | 歌手信息 |
| GET | `/v1/singer/song/list` | 歌手歌曲列表 | singerId(必填), pageNum, pageSize | List<歌曲> |
| GET | `/v1/singer/album/list` | 歌手专辑列表 | singerId(必填) | List<专辑> |
| GET | `/v1/singer/video/list` | 歌手视频列表 | singerId(必填) | List<视频> |
| GET | `/v1/singer/music/num` | 歌手歌曲数量 | singerId(必填) | int |
| GET | `/v1/singer/album/num` | 歌手专辑数量 | singerId(必填) | int |
| GET | `/v1/singer/video/num` | 歌手视频数量 | singerId(必填) | int |
| POST | `/v1/singer/follow` | 关注歌手 | singerId(必填) | string |
| POST | `/v1/singer/follow/batch` | 批量关注歌手 | body: singerIdList | string |
| POST | `/v1/singer/unfollow` | 取消关注歌手 | singerId(必填) | string |
| POST | `/v1/singer/unfollow/batch` | 批量取消关注歌手 | body: singerIdList | string |

---

## 八、专辑接口 `/v1/Album/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| GET | `/v1/Album/all` | 全部专辑 | pageNum, pageSize | List<专辑> |
| GET | `/v1/Album/new` | 最新专辑 | — | List<专辑> |
| GET | `/v1/Album/detail` | 专辑详情 | albumId(必填) | 专辑详情 |
| GET | `/v1/Album/play` | 专辑播放记录 | albumId(必填) | string |
| POST | `/v1/Album/batch-play` | 专辑批量播放 | body: albumIdList | string |
| POST | `/v1/Album/collect` | 收藏专辑 | albumId(必填) | string |
| POST | `/v1/Album/un-collect` | 取消收藏专辑 | albumId(必填) | string |
| POST | `/v1/Album/batch-collect` | 批量收藏专辑 | body: albumIds | string |
| POST | `/v1/Album/batch-un-collect` | 批量取消收藏专辑 | body: albumIds | string |

---

## 九、搜索接口 `/v1/search/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 | 实测 |
|---|---|---|---|---|---|
| GET | `/v1/search` | 综合搜索 | keyword(必填) | SearchResultDto | |
| GET | `/v1/search/music` | 搜索音乐 | keyword(必填), pageNum, pageSize | SearchMusicDto | ✅ memberId:0 可调 |
| GET | `/v1/search/singer` | 搜索歌手 | keyword(必填), pageNum, pageSize | SearchSingerDto | |
| GET | `/v1/search/album` | 搜索专辑 | keyword(必填), pageNum, pageSize | SearchAlbumDto | |
| GET | `/v1/search/song-sheet` | 搜索歌单 | keyword(必填), pageNum, pageSize, isRecommend | SearchSongSheetDto | |
| GET | `/v1/search/video` | 搜索视频 | keyword(必填), pageNum, pageSize | SearchVideoDto | |
| GET | `/v1/search/lyric` | 搜索歌词 | keyword(必填), pageNum, pageSize | SearchMusicDto | |
| GET | `/v1/search/associate` | 联想搜索 | keyword(必填) | List<string> | 搜索建议 |
| GET | `/v1/search/hot/search` | 获取热门搜索 | — | List<歌曲> | |
| GET | `/v1/search/history` | 搜索历史 | — | List<string> | |
| GET | `/v1/search/history/result` | 记录搜索点击结果 | result, resultId, type | string | |
| DELETE | `/v1/search/keyword` | 删除搜索历史 | keyword(必填) | CommonResponse | |
| DELETE | `/v1/search/keywords` | 删除全部搜索历史 | — | CommonResponse | |

**搜索特性：**
- 全文检索（歌名 + 歌词 + 歌手 + 专辑）
- 分词 OR 匹配（"主耶稣我爱你" 会拆词匹配）
- 简繁转换（`keyword` → `tkeyword`）
- `counts` 为模糊匹配总数

**实测示例：**
```bash
curl -s -G 'https://check-api.lingtingmusic.com/v1/search/music' \
  -H 'memberId: 0' \
  --data-urlencode 'keyword=恩典' \
  --data-urlencode 'pageNum=1' \
  --data-urlencode 'pageSize=100'
```

---

## 十、首页接口 `/v1/homepage/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 | 实测 |
|---|---|---|---|---|---|
| GET | `/v1/homepage/daily/songs` | 每日三十首歌曲 | — | List<歌曲> | |
| GET | `/v1/homepage/hot/songs` | 热门歌曲 | — | List<歌曲> | |
| GET | `/v1/homepage/recommend/video` | 推荐视频 | — | List<视频> | |
| GET | `/v1/homepage/recommend/songSheet` | 推荐歌单 | — | List<歌单> | |
| GET | `/v1/homepage/recommend/singer` | 推荐歌手 | — | List<歌手> | |
| GET | `/v1/homepage/recommend/album` | 推荐专辑 | — | List<专辑> | |
| GET | `/v1/homepage/top/list` | 置顶栏列表 | — | List<置顶栏> | |
| GET | `/v1/homepage/top/absolute/song` | 置顶栏纯音乐歌曲 | pageNum, pageSize, userId | List<歌曲> | ✅ share 域名下可调 |
| GET | `/v1/homepage/top/absolute/info` | 置顶栏纯音乐信息 | userId | 置顶栏纯音乐信息 | |
| GET | `/v1/homepage/top/new/song` | 置顶栏新歌首发列表 | pageNum, pageSize, userId | List<歌曲> | ✅ share 域名下可调 |
| GET | `/v1/homepage/top/new/info` | 置顶栏新歌首发信息 | userId | 新歌推荐信息 | |
| GET | `/v1/homepage/top/singer/song` | 置顶栏精选歌手歌曲 | pageNum, pageSize, userId | List<歌曲> | |
| GET | `/v1/homepage/top/singer/info` | 置顶栏精选歌手信息 | userId | 精选歌手信息 | |

---

## 十一、会员接口 `/v1/member/*`

> 本节接口 `token` 均为 `required: true` 🔒（除特别标注）

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| GET | `/v1/member/info` | 获取个人信息 | — | MemberInfoResponseDto |
| PUT | `/v1/member/info` | 修改个人信息 | body: MemberInfoResponseDto | string |
| GET | `/v1/member/base/info` | 个人基本信息 | — | 个人账户信息 |
| GET | `/v1/member/space/info` | 获取用户个人空间 | tMemberId(必填) | 个人账户信息 |
| GET | `/v1/member/use/info` | 用户音乐使用情况 | — | 用户使用信息 |
| GET | `/v1/member/user-info` | **第三方接口获取个人信息** | query: memberId(必填)，**无 token** | MemberInfoResponseDto | ✅ 无鉴权可调 ⚠️ |
| POST | `/v1/member/setting` | 用户设置 | body: 设置信息 | string |
| POST | `/v1/member/follow` | 关注用户 | followMemberId(必填) | string |
| POST | `/v1/member/unfollow` | 取消关注用户 | followMemberId(必填) | string |
| POST | `/v1/member/batch-follow` | 批量关注用户 | body: followMemberIds | string |
| POST | `/v1/member/batch-unfollow` | 批量取消关注用户 | body: followMemberIds | string |
| GET | `/v1/member/follow/user-list` | 关注用户列表 | pageNum, pageSize | List<个人账户信息> |
| GET | `/v1/member/follow/singer-list` | 关注歌手列表 | pageNum, pageSize | List<个人账户信息> |
| GET | `/v1/member/follow/fan-list` | 粉丝列表 | pageNum, pageSize | List<个人账户信息> |
| GET | `/v1/member/song-sheet/list` | 用户自建歌单列表 | userId | List<歌单> |
| GET | `/v1/member/play/info` | 播放信息 | — | 播放信息 |
| GET | `/v1/member/play/musics` | 音乐播放列表 | pageNum, pageSize | List<歌曲> |
| DELETE | `/v1/member/play/musics` | 批量删除最近播放歌曲 | songIds[], localSongIds[] | string |
| GET | `/v1/member/play/musics/page` | 音乐播放列表分页 | pageNum, pageSize | List<歌曲> |
| GET | `/v1/member/play/albums` | 专辑播放列表 | pageNum, pageSize | List<专辑> |
| DELETE | `/v1/member/play/albums` | 批量删除最近播放专辑 | albumIds[] | string |
| GET | `/v1/member/play/songSheets` | 歌单播放列表 | pageNum, pageSize | List<歌单> |
| DELETE | `/v1/member/play/songSheets` | 批量删除最近播放歌单 | songSheetIds[] | string |
| GET | `/v1/member/play/videos` | 视频播放列表 | pageNum, pageSize | List<视频> |
| DELETE | `/v1/member/play/videos` | 批量删除最近播放视频 | videoIds[] | string |
| GET | `/v1/member/play/localSong` | 本地音乐播放列表 | pageNum, pageSize | List<本地音乐> |
| GET | `/v1/member/collect/info` | 用户收藏信息 | userId | 收藏信息 |
| GET | `/v1/member/collect/musics` | 音乐收藏列表 | pageNum, pageSize | List<歌曲> |
| GET | `/v1/member/collect/musics/page` | 音乐收藏分页列表 | pageNum, pageSize, userId | List<歌曲> |
| GET | `/v1/member/collect/albums` | 专辑收藏列表 | pageNum, pageSize, userId | List<专辑> |
| GET | `/v1/member/collect/song-sheets` | 歌单收藏列表 | pageNum, pageSize, userId | List<歌单> |
| GET | `/v1/member/collect/videos` | 视频收藏列表 | pageNum, pageSize, userId | List<视频> |
| GET | `/v1/member/collect/localSong` | 本地音乐收藏列表 | pageNum, pageSize | List<本地音乐> |
| GET | `/v1/member/download/info` | 下载信息 | — | 下载信息 |
| GET | `/v1/member/download/musics` | 音乐下载列表 | pageNum, pageSize | List<歌曲> |
| DELETE | `/v1/member/download/musics` | 批量删除下载歌曲 | songIds[] | string |
| GET | `/v1/member/download/videos` | 视频下载列表 | pageNum, pageSize | List<视频> |
| DELETE | `/v1/member/download/videos` | 批量删除下载视频 | videoIds[] | string |

---

## 十二、本地歌曲接口 `/v1/local-song/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| GET | `/v1/local-song/getLocalSongList` | 获取本地音乐列表 | — | List<本地音乐> |
| POST | `/v1/local-song/save` | 存储本地音乐列表 | body: 本地音乐[] | string |
| POST | `/v1/local-song/deleteLocalSong` | 删除本地歌曲 | body: localSongIds | string |
| POST | `/v1/local-song/like` | 喜欢本地音乐 🔒 | localSongId(必填) | string |
| POST | `/v1/local-song/like/batch` | 批量喜欢本地音乐 🔒 | body: localSongIdList | string |
| POST | `/v1/local-song/unlike` | 取消喜欢本地音乐 🔒 | localSongId(必填) | string |
| POST | `/v1/local-song/unlike/batch` | 批量取消喜欢 🔒 | body: localSongIdList | string |

---

## 十三、电台接口 `/v1/station/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| GET | `/v1/station/list` | 获取电台列表 | — | List<电台> |
| GET | `/v1/station/detail` | 电台详情 | stationId(必填) | List<歌曲> |
| GET | `/v1/station/golden-sentence` | 每日金句 | — | 每日金句 |

---

## 十四、元数据接口 `/v1/metadata*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| GET | `/v1/metadata` | 首页组件显示数据 | — | App首页组件显示顺序 |
| GET | `/v1/metadata/ping` | ping 检测 | — | string |
| GET | `/v1/metadata/refresh` | 判断用户是否刷新页面 | — | boolean |

---

## 十五、分类 / 标签接口

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| GET | `/v1/category` | 获取分类列表 | — | List<分类信息> |
| GET | `/v1/tag/list` | 获取标签列表 | — | List<标签分类> |

---

## 十六、文件上传接口 `/v1/file/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 | 实测 |
|---|---|---|---|---|---|
| POST | `/v1/file/avatar/upload` | 头像上传 | formData: multipartFile | string | |
| POST | `/v1/file/feedback/upload` | 反馈图片上传 | formData: multipartFile | string | |
| POST | `/v1/file/log/upload` | 用户日志上传 | formData: multipartFile | string | |
| POST | `/v1/file/song-sheet/cover/upload` | 歌单封面上传 | formData: multipartFile | string | |
| POST | `/v1/file/version/apk/upload` | **App APK 上传** | formData: multipartFile | string(URL) | ⚠️ 匿名 token 可上传成功 |

**APK 上传实测结果：**
- 无 token → `500 General Error`（参数绑定失败）
- 匿名 token → `401 Auth Error`
- 有效匿名 token + 1 字节文件 → `200 success: true`，返回生产 COS URL
- **结论**：任意注册用户（含匿名）可上传文件至生产存储

---

## 十七、分享 / 反馈 / 版本 / 心跳

| 方法 | 路径 | 说明 | 关键参数 | 返回 |
|---|---|---|---|---|
| POST | `/v1/share/save` | 保存分享记录 | body: 分享请求参数 | string |
| POST | `/v1/feedback/save` | 保存用户反馈 | body: 用户反馈请求参数 | string |
| POST | `/v1/version/update` | App 版本更新检查 | body: App版本更新请求 | 版本更新响应 |
| POST | `/v1/version/publish` | **发布 App 更新版本** | body: App版本更新发布 | string |
| GET | `/v1/healthy/check` | 心跳检测 | — | string |

---

## 十八、管理后台 `/api/v1/admin/*`

| 方法 | 路径 | 说明 | 关键参数 | 返回 | 实测 |
|---|---|---|---|---|---|
| POST | `/api/v1/admin/login` | 管理员登录 | body: username, password | string | ✅ 接口存在，鉴权正常 |

**Host**：`admin.lingtingmusic.com`

**安全状况对照：**

| 检查项 | `check-api` | `admin` |
|---|---|---|
| Swagger 暴露 | ❌ 公开 | ✅ 未暴露 |
| Druid 暴露 | ❌ 公开 | ✅ 未暴露 |
| 登录接口 | 匿名可注册 | ✅ 正常报错 |
| 频率限制 | — | ⚠️ 未发现 |

---

## 十九、关键数据模型

### 19.1 列表页歌曲返回信息

| 字段 | 类型 | 说明 |
|---|---|---|
| `songId` / `songName` | integer / string | 歌曲 id / 名称 |
| `singerId` / `singerName` | integer / string | 歌手 |
| `albumId` / `albumName` | integer / string | 专辑 |
| `songCoverImage` | string | 封面 |
| `audioLink` | string | 音频链接 |
| `videoId` | integer | 视频链接 |
| `lyric` | string | 歌词 |
| `like` | boolean | 是否喜欢 |
| `isDownload` | int32 | 是否已下载 |
| `categoryId` | integer | 分类 id |
| `sheetRelationId` | integer | 歌单关联 id |
| `selfPositionInList` | int32 | 播放列表位置 |
| `typeId` / `typeTitle` | int32 / string | 类型 |
| `sourceId` / `sourceTitle` | integer / string | 来源 |
| `path` | string | 下载路径 |
| `createTime` | date-time | 插入时间 |
| `isKeyBySongs` | boolean | 是否含搜索关键字 |

### 19.2 音乐详情返回信息

| 字段 | 类型 | 说明 |
|---|---|---|
| `songId` / `songName` | integer / string | 歌曲 |
| `singerId` / `singerName` | integer / string | 歌手 |
| `albumId` | integer | 专辑 ID |
| `songCoverImage` | string | 封面 |
| `audioLink` | string | 音频链接 |
| `lyric` | string | 歌词 |
| `videoId` | integer | 视频 ID |
| `like` | boolean | 是否喜欢 |
| `followSinger` | boolean | 是否关注歌手 |
| `isDownload` | int32 | 是否下载 |

### 19.3 MemberInfoResponseDto

| 字段 | 类型 | 说明 |
|---|---|---|
| `nickName` | string | 昵称 |
| `avatar` | string | 头像 |
| `gender` | string | 性别 |
| `mobile` | string | **手机号** |
| `wxAccount` | string | **微信账户** |
| `appleAccount` | string | **苹果账户** |
| `isHidePersonalSpace` | int32 | 0-公开 1-隐藏 |

### 19.4 个人账户信息

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | integer | 用户 id |
| `nickName` / `avatar` | string | 昵称 / 头像 |
| `isFollow` | int32 | 0-未关注 1-已关注 2-自己 |
| `fansNums` / `followNums` | int32 | 粉丝数 / 关注数 |
| `collectSongCount` | int32 | 收藏歌曲数 |
| `favSongSheetCount` / `selfSongSheetCount` | int32 | 收藏 / 自建歌单数 |
| `favSongSheetList` / `selfSongSheetList` | array | 歌单列表 |

### 19.5 搜索返回模型

| 模型 | 字段 |
|---|---|
| `SearchMusicDto` | `counts`, `keyword`, `tkeyword`, `songList` |
| `SearchSingerDto` | `counts`, `keyword`, `tkeyword`, `singerList` |
| `SearchAlbumDto` | `counts`, `keyword`, `tkeyword`, `albumList` |
| `SearchSongSheetDto` | `counts`, `keyword`, `tkeyword`, `songSheetList` |
| `SearchVideoDto` | `counts`, `keyword`, `tkeyword`, `videoList` |
| `SearchResultDto` | `counts` + 以上五个 Dto |

### 19.6 用户登录记录（匿名登录 body）

| 字段 | 类型 | 说明 |
|---|---|---|
| `anonymousId` | string | 匿名用户标识 |
| `deviceId` | string | 手机唯一标识 |
| `deviceType` | string | 登录设备类型 |
| `appVersion` | string | app 版本号 |
| `phoneModel` / `osVersion` | string | 手机型号 / 系统版本 |
| `networkType` | string | 网络类型 |
| `ipAddress` / `location` | string | IP / 地理位置 |
| `loginType` | int32 | 0-匿名 1-手机号 2-微信 |
| `loginStatus` | int32 | 0-失败 1-成功 |
| `memberId` | integer | 用户 ID |

---

## 二十、调用示例

### 20.1 搜索音乐（免 token）

```bash
curl -s -G 'https://check-api.lingtingmusic.com/v1/search/music' \
  -H 'memberId: 0' \
  --data-urlencode 'keyword=恩典' \
  --data-urlencode 'pageNum=1' \
  --data-urlencode 'pageSize=20'
```

### 20.2 搜索联想

```bash
curl -s -G 'https://check-api.lingtingmusic.com/v1/search/associate' \
  -H 'memberId: 0' \
  --data-urlencode 'keyword=恩典'
```

### 20.3 音乐详情

```bash
curl -s -G 'https://check-api.lingtingmusic.com/v1/music/detail' \
  -H 'memberId: 0' \
  --data-urlencode 'songId=27'
```

### 20.4 匿名登录换 token

```bash
curl -s -X POST 'https://check-api.lingtingmusic.com/v1/account/anonymous/login' \
  -H 'Content-Type: application/json' \
  -d '{
    "anonymousId": "test-anon-001",
    "deviceId": "test-device-001",
    "deviceType": "android",
    "appVersion": "3.1.5",
    "loginType": 0,
    "loginStatus": 1
  }'
```

### 20.5 带 token 调用会员接口

```bash
TOKEN="<上一步返回的 token>"

curl -s -G 'https://check-api.lingtingmusic.com/v1/member/play/musics' \
  -H "token: $TOKEN" \
  -H 'memberId: 0' \
  --data-urlencode 'pageNum=1' \
  --data-urlencode 'pageSize=20'
```

---

## 二十一、模块与 Tag 对照

| Tag | Controller | 路径前缀 |
|---|---|---|
| 账户接口 | Account Controller | `/v1/account/*` |
| 音乐接口 | Music Controller | `/v1/music/*` |
| 视频接口 | Video Controller | `/v1/video/*` |
| 歌单接口 | Song Sheet Controller | `/v1/song-sheet*` |
| 歌手接口 | Singer Controller | `/v1/singer/*` |
| 专辑接口 | Album Controller | `/v1/Album/*` |
| 搜索接口 | Search Controller | `/v1/search/*` |
| 首页接口 | Homepage Controller | `/v1/homepage/*` |
| 会员接口 | Member Controller | `/v1/member/*` |
| 本地歌曲接口 | Local Song Controller | `/v1/local-song/*` |
| 电台接口 | Station Controller | `/v1/station/*` |
| 元数据接口 | Meta Data Controller | `/v1/metadata*` |
| 分类接口 | Category Controller | `/v1/category` |
| 标签接口 | Tag Controller | `/v1/tag/list` |
| 文件上传接口 | File Upload Controller | `/v1/file/*` |
| 分享接口 | Share Controller | `/v1/share/save` |
| 用户反馈接口 | Feedback Controller | `/v1/feedback/save` |
| 版本更新 | Version Controller | `/v1/version/*` |
| 心跳检测 | Healthy Controller | `/v1/healthy/check` |

---

## 二十二、安全发现汇总

| 编号 | 发现 | 状态 |
|---|---|---|
| P0-1 | Druid 监控台未授权访问 | ✅ 已确证 |
| P0-2 | Swagger API 文档未授权访问 | ✅ 已确证 |
| P0-3 | `/v1/member/user-info` 无鉴权可调用 | ✅ 已确证（敏感字段待内部验证） |
| P1-4 | APK 上传接口任意注册用户可调用 | ✅ 已确证（含成功上传测试） |
| P1-5 | 运营接口混入客户端 API | ✅ 已确证 |
| P2-1 | Actuator 端点疑似暴露 | ⚠️ 待验证 |
| P2-2 | 部分文件上传接口鉴权存疑 | ⚠️ 待验证 |
| P2-3 | 管理后台登录无频率限制 | ✅ 已确证 |
| 附加 | `admin` 域名安全状况对照 | ✅ 已确证 |

---

*文档由 Swagger JSON 整理 + 实测验证生成，接口行为以后端实际实现为准。*
*所有实测均使用测试账号，未涉及真实用户数据。*

---

## 二十三、客户端实测补充（2026-09-24）

这一节不是 Swagger 抄下来的，是**对着真接口 + 真机截图**校出来的三个坑。
它们不影响服务端，但决定客户端怎么解析 —— 换客户端/换语言重写时请照抄结论。

### 23.1 搜索结果里的 `[]` 是**命中标记**，不是标题的一部分

搜「一粒麦子」（`/v1/search/music`）返回：

| 接口 | `songName` |
|---|---|
| 搜索 | `[一粒][麦子]`、`[一粒][麥][子]`、`[一粒][麦子]（伴奏）` |
| 详情 `/v1/music/detail` | `一粒麦子`、`一粒麥子`、`一粒麦子（伴奏）` |
| 首页 `/v1/homepage/hot/songs`、`/v1/homepage/daily/songs` | 干净（抽 60 条，0 条带标记） |

抽样：**180 条搜索结果里 179 条带标记**；同一首歌搜繁体时还会按字拆开
（`[一粒][麥][子]`）。所以这是服务端在标注「哪几个片段命中了关键词」，
客户端**应当在展示层去掉或做高亮**，不能把方括号原样显示。
注意：搜索返回的 `lyric` **正文里也带同样的标记**（实测出现过 `[一]`）。

### 23.2 `lyric` 字段有两种形态，而且列表里那份**不是完整歌词**

| 来源 | 形态 |
|---|---|
| 列表 / 搜索（`songList[].lyric`） | **纯文本**，整首歌用 `;` 连成**一行**（`;;` = 空行），**一个真换行都没有**；往往比正文短 |
| `/v1/music/lyric` | 一个 `.lrc` 文件地址（带 BOM 的 UTF-8，一行可挂多个时间标签） |

抽样 180 首：180 首的 `lyric` 都非空、**0 首含真换行**，其中 166 首不足 60 字，
14 首含 `;`。真实例子（songId 23455《敬拜的心》）：

```
列表：  《敬拜的心》;;词曲：赵治德;演唱：江真;;;我献上一颗敬拜的心;指的就是我全所有;…
.lrc：  [00:18.90]我献上一颗敬拜的心\r\n[00:25.24]指的就是我全所有\r\n…
```

结论：**纯文本要按 `;` 拆行**（否则整首歌铺成一坨），且只要没有时间轴，
就应该再去 `/v1/music/lyric` 取一次 `.lrc`（客户端实现见
`LingtingRepository.quickLyric/timelineLyric`）。

### 23.3 接口清单里没写、但实测存在的两个点

* `/v1/music/lyric` 返回的是**字符串**（`.lrc` 地址），不是对象；地址是 COS 上的
  原始文件名，**带空格/中文/方括号且未转义**，交给 HTTP 库自己转义即可，
  手工再转一次会二次转义（`%20` → `%2520`）导致 COS 回 `NoSuchKey`。
* `/v1/homepage/daily/songs` 对**刚注册的匿名账号**会回 401（同一 token 换到老账号就
  正常），客户端要能退到置顶接口并在标题上如实标注。
