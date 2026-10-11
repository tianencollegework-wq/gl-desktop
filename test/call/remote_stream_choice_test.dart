import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/media/remote_stream_choice.dart';

/// 收到一路远端轨时，`_remote`（界面那块「对方的画面」）该怎么办。
///
/// 这一条钉的是 2026-10-06 那次真机事故：手机端「两个画面都是自己的摄像头，
/// 一个实时、一个卡在接通那一瞬间」，而统计里 `recv`/`decoded` 都是满帧
/// —— 对方的画面一直收得到、解得开，坏的是界面拿到的那份流。
///
/// 起因是「共享电脑声音」那条预协商的空音频 m-line：对端把它开成 `sendrecv`
/// 之后，插件会替它报一条**没有 `msid` 的音轨**，老代码拿它覆盖了 `_remote`
/// —— 一份没有画面轨的空流盖上去，原生播放器当场把已渲染的那一帧冻住。
void main() {
  test('带 msid 的轨：一律用插件给的那份流（画面与声音都走这条路）', () {
    for (final kind in <String>['video', 'audio']) {
      for (final hasVideo in <bool>[true, false]) {
        expect(
          chooseRemoteStreamAction(
            trackHasStream: true,
            trackKind: kind,
            remoteHasVideo: hasVideo,
          ),
          RemoteStreamAction.adoptProvided,
          reason: 'kind=$kind 手里有画面=$hasVideo',
        );
      }
    }
  });

  test('没有 msid 的音轨：永远不进画面（这就是那次事故的元凶）', () {
    expect(
      chooseRemoteStreamAction(
        trackHasStream: false,
        trackKind: 'audio',
        // ⚠️ 关键：**手里已经有对方的画面**也不能让它顶掉
        remoteHasVideo: true,
      ),
      RemoteStreamAction.ignore,
      reason: '拿一份没有画面轨的空流顶掉 _remote，对方画面会当场冻住',
    );
    expect(
      chooseRemoteStreamAction(
        trackHasStream: false,
        trackKind: 'audio',
        remoteHasVideo: false,
      ),
      RemoteStreamAction.ignore,
      reason: '声音由原生直接播，界面不碰音频流，没有 msid 的音轨没有用处',
    );
  });

  test('没有 msid 的画面轨：手里还没画面才自己包一份顶上（老端的兜底）', () {
    expect(
      chooseRemoteStreamAction(
        trackHasStream: false,
        trackKind: 'video',
        remoteHasVideo: false,
      ),
      RemoteStreamAction.wrapTrack,
    );
  });

  test('没有 msid 的画面轨、手里已经有画面：不顶（重复报的轨不能把画面换掉）', () {
    expect(
      chooseRemoteStreamAction(
        trackHasStream: false,
        trackKind: 'video',
        remoteHasVideo: true,
      ),
      RemoteStreamAction.ignore,
    );
  });
}
