import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/call/call_media_config.dart';

/// `describeSdpDirections` 是 S12.34 为「对方看不到画面」这类问题加的一句诊断。
/// 它只做一件事：把 SDP 里每条 m-line 的方向列出来。**绝不能抛** ——
/// 一个诊断函数把通话搞崩就本末倒置了，所以这里把畸形输入也钉住。
void main() {
  group('describeSdpDirections（S12.34）', () {
    test('把每条 m-line 的方向列出来（含 S12.32 那条空音频轨）', () {
      const sdp =
          'v=0\r\n'
          'o=- 1 2 IN IP4 127.0.0.1\r\n'
          's=-\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=mid:0\r\n'
          'a=sendrecv\r\n'
          'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
          'a=mid:1\r\n'
          'a=recvonly\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=mid:2\r\n'
          'a=sendrecv\r\n';

      expect(
        describeSdpDirections(sdp),
        '3 条：audio/sendrecv, video/recvonly, audio/sendrecv',
      );
    });

    test('没有方向属性的 m-line 留 `/?`（不能默认当成在收）', () {
      const sdp = 'm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:1\r\n';

      expect(describeSdpDirections(sdp), '1 条：video/?');
    });

    test('LF 换行、带空格的畸形行也认（真机日志里贴回来的就是这么乱）', () {
      const sdp =
          'm=audio 9 RTP/AVP 111\n'
          '\ta=sendonly  \n'
          'm=video 9 RTP/AVP 96\n'
          'a=inactive\n';

      expect(describeSdpDirections(sdp), '2 条：audio/sendonly, video/inactive');
    });

    test('空 SDP / 没有 m= 行 / null 都不抛', () {
      expect(describeSdpDirections(null), '（空 SDP）');
      expect(describeSdpDirections(''), '（空 SDP）');
      expect(describeSdpDirections('v=0\r\ns=-\r\n'), '认不出（没有 m= 行）');
    });
  });
}
