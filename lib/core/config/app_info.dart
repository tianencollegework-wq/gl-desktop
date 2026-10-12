/// 应用元信息。
///
/// 老端是从 `package.json` 里读的：`name`（Raingad-IM）、`version`（6.1.0）、
/// `logo`（`/static/image/logo.png`，构建时是本地资源）。
/// Flutter 打不进 `pubspec.yaml` 的字段，所以在这里显式声明一份。
///
/// 名字按用户 2026-09-27 的要求统一成 **Gracelink**（以前这里是 `Gracelink IM`，
/// 老端那份默认还叫 `Raingad-IM` —— 登录页底下那行「xxx for 1.0.0」就是它）。
abstract final class AppInfo {
  /// 站点名兜底值（服务端 `sysInfo.name` 为空时用）
  static const String name = 'Gracelink';

  /// 登录页底部显示的版本号
  static const String version = '1.0.0';

  /// 客服邮箱（S13.3，2026-10-11）。
  ///
  /// ⚠️ **要换成你们真实的邮箱**：改这一处即可（「关于」页那一行读的就是它），
  /// 对应的 i18n key 是 `user.contactEmail`（那一行左边那四个字的标题）。
  ///
  /// 为什么是常量而不是服务端配置：这一行是**给审核与用户看的联系方式**
  /// （App Store / 上架材料里也要填），跟服务端那份随时会变的好友/群配置不是一回事。
  static const String supportEmail = 'support@gracelink.cc';

  /// 官网（「关于」页那一行点开的就是它）。
  ///
  /// 走 `openChatLink`：`.cc` 域名属于「我们自己的站点」，直接进应用内浏览器
  /// （不是跳到系统浏览器，与聊天里点自己站点的链接同一种行为）。
  static const String siteUrl = 'https://gracelink.cc';

  /// 官网上显示出来的那一小行（不带 `https://`）
  static const String siteHost = 'gracelink.cc';

  /// 应用自己的 logo（**优先于服务端配的那张**，见 `login_page.dart`）。
  ///
  /// 从前的写法是「服务端 `sysInfo.logo` 有就用它、没有才用这张」，于是换品牌
  /// 之后登录页上头还挂着旧站点的图（用户 2026-09-27：「logo 也改成现在软件用的
  /// logo」）。启动页早在 2026-09-26 就已经固定用本地这张了，登录/注册页与它统一。
  static const String logoAsset = 'assets/images/logo.png';

  /// 老端登录页底部的写法：`{name} for {version}`
  static String footer(String siteName) => '$siteName for $version';

  /// 服务端报上来的**站点名**（`sysInfo.name`），是我们自己这个 App 的名字时
  /// 才用它 —— 否则一律换成 [name]（Gracelink）。
  ///
  /// 为什么需要这一层（用户 2026-09-27：「软件默认的『IM』、『raingad-im』等等
  /// 全部改成 Gracelink」）：这几个名字是**上游产品的默认值**，装完不问也是一串
  /// 「Raingad-IM」，登录页底下那行「Raingad-IM for 1.0.0」、还有「关于」页的
  /// 大标题就是它。服务端没改过配置时，客户端就替它认了 —— 换成自己的品牌名。
  ///
  /// 判断方式是**整串归一化后全等**（去掉空格/`-`/`_` 并转小写），不是「包含」：
  /// 管理员真起了个名字（比如「示例IM」）时原样显示，不会被误伤。
  static String siteName(String serverName) =>
      _legacyNames.contains(_normalize(serverName)) ? name : serverName;

  /// 上游那几个默认名（归一化后）
  static const Set<String> _legacyNames = <String>{
    '',
    'im',
    'raingad',
    'raingadim',
    'gracelinkim',
  };

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s\-_]'), '');
}
