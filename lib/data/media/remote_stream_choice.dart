/// 收到一路远端轨（`onTrack`）时，`_remote`（界面那块「对方的画面」用的引用）
/// 该怎么办。
enum RemoteStreamAction {
  /// 用插件给的那份流（正常情况：轨带着 `msid`）
  adoptProvided,

  /// 没有 `msid`、也不是画面轨 —— 丢掉
  ignore,

  /// 没有 `msid`、但是画面轨，而且手里还没有画面 —— 自己包一份流顶上
  wrapTrack,
}

/// 判据（纯函数，单测直接钉）。
///
/// 背景（2026-10-06 真机事故）：手机上「两个画面都是自己的摄像头，一个实时、
/// 一个卡在接通那一瞬间」，而日志里 **`recv=13873 帧 / decoded=13848 帧`**
/// —— 对方的画面一直在正常收、正常解，坏的是界面拿到的那份流。
///
/// 根源是「共享电脑声音」那条预协商的空音频 m-line（S12.32）：对端把它的方向
/// 开成 `sendrecv` 之后，插件会替那条 m-line 报一条**没有 `msid` 的音轨**。
/// 老代码对「没有 stream」的轨一律自己包一份新流、并**覆盖 `_remote`** ——
/// 一份不含画面轨的空流盖上去，原生播放器（安卓 `setStream` 取第一条
/// `videoTrack`，取不到就摘掉）当场把已经渲染的那一帧冻在那儿：对方画面从此
/// 停在那一刻，之后对方再共享屏幕也只剩同一张静止图。
///
/// 音频不需要走这条路：远端声音由原生直接播，界面从来不碰音频流。
/// 所以没有 `msid` 时**只认画面轨**，而且手里已经有画面就不再认它。
RemoteStreamAction chooseRemoteStreamAction({
  /// 这一路轨带不带 `msid`（插件给没给 `MediaStream`）
  required bool trackHasStream,

  /// 这一路轨是 `video` 还是 `audio`
  required String trackKind,

  /// 手里的 `_remote` 是不是已经带着画面轨了
  required bool remoteHasVideo,
}) {
  if (trackHasStream) return RemoteStreamAction.adoptProvided;
  if (trackKind != 'video') return RemoteStreamAction.ignore;
  if (remoteHasVideo) return RemoteStreamAction.ignore;
  // 真·只有 track 没有 stream，而且这是画面：自己包一份流顶上，
  // 不然对方的画面会整个丢（老端也是这么兜的）。
  return RemoteStreamAction.wrapTrack;
}
