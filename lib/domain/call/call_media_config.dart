import '../../data/model/global_config.dart';

/// 通话媒体的配置口径（S6.2）。
///
/// 对照老端 `hybrid/html/index.html` 顶部那段 `config` 与三处 `getUserMedia` 调用。
/// 这里只算「该用什么参数」，不碰任何插件，所以可以整体跑单测。
abstract final class CallMediaConfig {
  /// 公共 STUN：老端硬编码的那一组（`index.html` 的 `iceServers[0]`）。
  ///
  /// 一个都不能省：站点没配 TURN 时，能不能打通基本全靠这几个（见风险登记 #1）。
  static const List<String> publicStunUrls = <String>[
    'stun:stun.xten.com',
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
    'stun:stun2.l.google.com:19302',
    'stun:stun3.l.google.com:19302',
    'stun:stun4.l.google.com:19302',
  ];

  /// 站点没配 STUN 时老端的兜底（`opt.stun ? opt.stun : ['stun:stun.callwithus.com']`）
  static const String fallbackStunUrl = 'stun:stun.callwithus.com';

  /// 我们自己的 TURN 服务器。
  ///
  /// **现在是空的，而且这是当前最大的一块空缺**（规划书风险登记 #1）：
  /// 两边都在对称 NAT / 移动网络后面时，没有 TURN 就是打不通，老端也一样打不通。
  /// 自建 coturn 之后把地址填在这里，客户端就有了不依赖站点配置的兜底。
  static const List<Map<String, dynamic>> ownTurnServers =
      <Map<String, dynamic>>[
        // 形如：
        // <String, dynamic>{
        //   'urls': <String>['turn:turn.example.com:3478?transport=udp'],
        //   'username': 'xxx',
        //   'credential': 'yyy',
        // },
      ];

  /// 合法的 ICE 地址协议头（大小写不敏感）
  static const List<String> _iceSchemes = <String>[
    'stun:',
    'stuns:',
    'turn:',
    'turns:',
  ];

  /// 这个地址自己写了协议头吗（[normalizeIceUrl] 与「通话线路」那一页共用同一套判断）。
  ///
  /// 单独拿出来是因为它决定了一件很要命的事：**没写协议头的地址会被当成 STUN**
  /// （见 [normalizeIceUrl]）。所以站点想用 TURN 却漏了 `turn:` 时，那一台会静默地
  /// 变成一台 STUN —— 设置页的「通话线路」就是靠这个把那种写法指出来。
  static bool hasIceScheme(String raw) {
    final lower = raw.trim().toLowerCase();
    return _iceSchemes.any(lower.startsWith);
  }

  /// 把站点后台填的地址补成 WebRTC 认的形态。
  ///
  /// ⚠️ **这是真机上抓出来的坑（2026-09-19，三星 S23 Ultra）**：站点后台那栏
  /// 填的是 `stun.cloudflare.com:3478`（**没有 `stun:` 前缀**）。
  /// 浏览器会自动补前缀，所以网页端/老端 WebView 一直没事；
  /// 但**原生 WebRTC 不补** —— 见到没协议头的地址，整条连接直接建不起来
  /// （`createPeerConnection` 返回空对象，插件不检查，接着取麦克风就 NPE 闪退）。
  /// 所以我们自己补：没有协议头就当 STUN。
  static String normalizeIceUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return url;
    if (hasIceScheme(url)) return url;
    final lower = url.toLowerCase();
    // 少数面板把协议写在 `@` 前面（`turn@host:port`），也认一下
    if (lower.startsWith('turn@')) return 'turn:${url.substring(5)}';
    if (lower.startsWith('turns@')) return 'turns:${url.substring(6)}';
    return 'stun:$url';
  }

  /// 站点那一栏可能一次塞了好几个地址（逗号 / 空格 / 换行分隔），拆开并逐个补前缀。
  static List<String> splitIceUrls(String raw) => raw
      .split(RegExp(r'[,\s]+'))
      .map(normalizeIceUrl)
      .where((url) => url.isNotEmpty)
      .toList();

  /// 站点那台服务器带不带账号密码。
  ///
  /// 只配了 STUN（没有账号）时返回 false —— 见 [iceServers] 里为什么空串不能发。
  static bool _hasCredentials(ChatInfo chatInfo) =>
      chatInfo.stunUser.isNotEmpty || chatInfo.stunPass.isNotEmpty;

  /// 建 `RTCPeerConnection` 用的 `iceServers`。
  ///
  /// 与老端逐项对齐（顺序也一样，先公共 STUN 再站点那台）：
  /// * 站点没配 `stun` → 用 [fallbackStunUrl]；
  /// * 有账号密码才带 `username` / `credential`（TURN 要靠它鉴权）；
  /// * 地址一律补上协议头（[normalizeIceUrl]，真机上踩过这个坑）；
  /// * 老端配了 `stun` 时给的是**字符串**、兜底时给的是**数组**，这里统一成数组
  ///   （两者 WebRTC 都认，统一掉省得后面判断）。
  static List<Map<String, dynamic>> iceServers(ChatInfo chatInfo) {
    // 站点那一栏的地址先补全协议头（见 [normalizeIceUrl]），空则用老端的兜底
    final siteUrls = splitIceUrls(chatInfo.stun);
    final hasCredentials = _hasCredentials(chatInfo);
    final server = <String, dynamic>{
      'urls': siteUrls.isEmpty ? <String>[fallbackStunUrl] : siteUrls,
      // **空账号密码不发这两个键**：STUN-only 的服务器不需要鉴权，
      // 发空串在原生 WebRTC 里没有意义（也会让 IceServer 变成「带鉴权的 STUN」）
      if (hasCredentials) 'username': chatInfo.stunUser,
      if (hasCredentials) 'credential': chatInfo.stunPass,
    };

    return <Map<String, dynamic>>[
      <String, dynamic>{'urls': publicStunUrls},
      server,
      ...ownTurnServers.map(_normalizedServer),
    ];
  }

  /// 自建 TURN 那份也走同一套补全（手填地址时容易忘前缀）
  static Map<String, dynamic> _normalizedServer(Map<String, dynamic> server) {
    final urls = server['urls'];
    if (urls is! List) return server;
    return <String, dynamic>{
      ...server,
      'urls': urls.map((url) => normalizeIceUrl(url.toString())).toList(),
    };
  }

  /// `getUserMedia` 的参数（老端 `initLocalStream`）。
  ///
  /// **两处刻意的差异，都是为了在原生上真的生效**：
  ///
  /// 1. **音频给 `true` 而不是 `{'echoCancellation': true}`**。老端那是在浏览器里，
  ///    那个键会被尊重；但 `flutter_webrtc` 只在 `audio` 是**布尔**时才套用它内置的
  ///    默认约束（`googNoiseSuppression` + `googEchoCancellation` + `echoCancellation`
  ///    + `googDAEchoCancellation`），给 map 反而会去解析 `mandatory/optional` 拿到空约束
  ///    —— 也就是**回声消除会丢**。给 `true` 才是老端想要的效果，而且更全。
  /// 2. **视频不带 `width` / `height`**。老端传的是 `{width: 屏幕高, height: 屏幕宽}`
  ///    （横竖写反了，请求的是一组横向分辨率），而原生侧只认 `mandatory` 里的
  ///    `minWidth` 这类键，顶层这两个键**会被直接忽略**。既然忽略，就不留这个误导。
  ///    分辨率交给插件选最接近的档位。
  ///
  /// [facingMode] 必须是 `user`（前置）或 `environment`（后置），老端默认前置。
  static Map<String, dynamic> localMediaConstraints({
    required bool video,
    String facingMode = 'user',
  }) => <String, dynamic>{
    'audio': true,
    if (video) 'video': <String, dynamic>{'facingMode': facingMode},
  };

  /// `createOffer` / `createAnswer` 的参数（老端 `offerParams`）。
  ///
  /// 老端写的是 `offerToRecieveAudio`（字母顺序写错的拼法，浏览器里照样生效，
  /// 因为浏览器把无法识别的键当空气）。原生侧认的是 `mandatory` 里的
  /// `OfferToReceiveAudio` / `OfferToReceiveVideo`，所以这里用原生那套写法。
  ///
  /// 值跟老端一致：语音通话 `OfferToReceiveVideo = false`、视频通话 `true`。
  /// 我们自己要发的那路流是 `addTrack` 上去的，与这个参数无关。
  static Map<String, dynamic> sdpConstraints({required bool video}) =>
      <String, dynamic>{
        'mandatory': <String, dynamic>{
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': video,
        },
        'optional': <dynamic>[],
      };

  /// SFU **发布**那条会话出 offer 用的参数：**只要发**。
  ///
  /// 与 [sdpConstraints] 的唯一差别是 `OfferToReceiveAudio: false`。发布会话是
  /// sendonly 的（我们只发不收；收靠另一条接收会话），而 `OfferToReceiveAudio: true`
  /// 会让 libwebrtc 在 offer 里**额外塞一条 recvonly 的音轨**：
  ///
  /// * 那条 m-line 谁也认领不了（我们只报自己真在发的那几条 track 的 mid），
  ///   却会让 CF 认为这个 offer 还缺一次重协商；
  /// * CF 的发布流程是「offer 里描述什么就发什么」，offer 与该描述不一致时
  ///   会在回包里要 `requiresImmediateRenegotiation`。
  ///
  /// 于是发布这一步在真机上会“看着成功、实际没落地”（别人听不到我）。
  /// 发布路径一律用这一份。
  static Map<String, dynamic> publishSdpConstraints() => <String, dynamic>{
    'mandatory': <String, dynamic>{
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    },
    'optional': <dynamic>[],
  };

  /// ICE 候选里只留这三个键（老端 `call.vue::msgCallback` 也是这么筛的）
  static const List<String> iceCandidateKeys = <String>[
    'candidate',
    'sdpMLineIndex',
    'sdpMid',
  ];
}

/// 一句把 SDP 里**每条 m-line 的方向**列出来（S12.34）。
///
/// 为什么需要它：「对方看不到画面 / 听不到声音」这类问题，凭 `fps` 之类的统计
/// 只能看出一半；真正的分水岭是本机那条 m-line 到底是 `sendrecv` 还是 `recvonly`
/// —— 如果本机 SDP 里视频是 `recvonly`，那不管摄像头多正常，**一个像素都发不出去**
/// （WebRTC 里 m-line 的方向是协商好的，事后 `addTrack` 不会自己生效）。
///
/// 例：`2 条：audio/sendrecv, video/recvonly`。解析不出来就返回「认不出」——
/// 诊断用的东西绝不该自己抛。
String describeSdpDirections(String? sdp) {
  if (sdp == null || sdp.isEmpty) return '（空 SDP）';
  final parts = <String>[];
  String? kind;
  for (final raw in sdp.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('m=')) {
      final first = line.length > 2 ? line.substring(2) : '';
      kind = first.split(' ').first;
      parts.add('$kind/?');
      continue;
    }
    if (kind == null) continue;
    const directions = <String>['sendrecv', 'sendonly', 'recvonly', 'inactive'];
    if (!line.startsWith('a=')) continue;
    final value = line.substring(2);
    if (directions.contains(value)) {
      // 这一条改掉刚占位的 `/`（一个 m 段只有一个方向属性）
      parts[parts.length - 1] = '$kind/$value';
    }
  }
  if (parts.isEmpty) return '认不出（没有 m= 行）';
  return '${parts.length} 条：${parts.join(', ')}';
}

/// 前/后置摄像头的取值（老端 `facingMode`）
abstract final class CameraFacing {
  static const String front = 'user';
  static const String back = 'environment';

  /// 切一下（老端 `exchangeVideo` 里的 if/else）
  static String toggle(String current) => current == front ? back : front;
}

/// 一句断言式的小工具：把候选里的三个键挑出来。
///
/// 收候选时服务端可能给了别的键（`usernameFragment` 之类），多余的一律丢掉
/// —— 老端只在**发**之前筛，这里收和发都筛一遍，省得脏字段进到原生层。
Map<String, dynamic> pickIceCandidateFields(Map<String, dynamic> raw) =>
    <String, dynamic>{
      for (final key in CallMediaConfig.iceCandidateKeys)
        if (raw.containsKey(key)) key: raw[key],
    };
