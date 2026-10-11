/**
 * 常见问题正文（中英各一份）。
 *
 * 与法律两页同一条规矩：**每一条都能在客户端里找到出处**，不写「请联系客服
 * 了解更多」这种空话。逐条对照过的位置（都是仓库里真实存在的路径/文案）：
 *
 * * 注册方式与 6–16 位密码、验证码：`register_page.dart`、`user.passLimit`；
 * * 忘记密码没有自助入口：登录页那颗「忘记密码」实际是**切到密码登录**的开关
 *   （`login_page.dart` 的 `_toggleForget`），改密码在账号安全里（`password_change_page.dart`，
 *   有原密码与邮箱验证码两条路）；
 * * 扫码登录：`qr_login_page.dart` / `desktop.scanLoginHint`；
 * * 多账号与切换：`accounts_page.dart`、`user.switchAccount`；
 * * 注销账号：`account_cancel_page.dart` + `user.cancelIntro` / `cancelBullet2` / `cancelBullet3`；
 * * 消息能力（引用 / 转发 / 撤回 / 单条删除 / 语音转文字 / 发图前本机压缩）：
 *   `feature.item3`、`message_actions.dart`、`message_bubble.dart`；
 * * 撤回时限由服务端 `redoTime` 决定：`message_actions.dart::canUndo`；
 * * 保存到相册 / 下载目录：`common.savedToGallery` / `common.savedToDownloads`；
 * * 群管理（公告 / 管理员 / 禁言 / 群二维码 / 移除成员）：`group.*` 语言包与群设置页；
 * * 通话（群通话、共享屏幕、整屏或单窗、共享系统声音、通话保活通知）：
 *   `group.*` 与 `call.*` 语言包、`group_call_page.dart`；
 * * 后台在线与省电策略提示：`feature.item12`、`help.notifyP4`；
 * * 来电与群通话邀请的超时：`IncomingCallPush.isFresh` / `GroupCallPush.isFresh`（60 秒）；
 * * 灵听（后台播放、通知栏控制）与媒体号：`feature.item*`、`audio_service` 那套前台服务；
 * * 七种界面语言：`AppI18n.supportedLocales`；
 * * 本机数据位置与卸载不删：安装许可协议第五节、`feature.item10`；
 * * 帮助中心：`doc_page.dart`（`user.help`）。
 */
import type { Lang } from '../consts';

export interface FaqItem {
  /** 问题 */
  q: string;
  /** 答案段落（数组即多段） */
  a: string[];
}

export interface FaqGroup {
  title: string;
  items: FaqItem[];
}

export interface FaqDoc {
  title: string;
  lede: string[];
  groups: FaqGroup[];
  /** 文末「没有找到答案？」那一块 */
  contact: { title: string; body: string[] };
}

/* ------------------------------------------------------------------ 中文 */

const zh: FaqDoc = {
  title: '常见问题',
  lede: [
    '这里按「下载安装、账号登录、聊天消息、音视频通话、发现、隐私与数据」几类整理了最常被问到的问题，答案对应的是客户端里真实的行为。',
    '如果没有找到你要的答案，可以在客户端内「我 → 设置 → 帮助与关于 → 帮助中心」查看，或直接给我们写邮件。',
  ],
  groups: [
    {
      title: '下载与安装',
      items: [
        {
          q: '恩信支持哪些系统？',
          a: [
            'Windows、Android 与 macOS 版已经可以下载；iOS 版正在开发中，预计 2027 年 1 月上线。桌面端与手机端使用同一个账号，消息互通。',
          ],
        },
        {
          q: 'Windows 版装在哪里？需要管理员权限吗？',
          a: [
            'Windows 版安装到当前用户目录下，安装过程不需要管理员权限，也不改动系统目录。',
            '卸载可以在客户端「我 → 关于恩信 → 卸载恩信」里完成，也可以在 Windows「设置 → 应用」中卸载。',
          ],
        },
        {
          q: '怎么确认自己装的是最新版本？',
          a: [
            '在客户端「我 → 设置 → 帮助与关于」里能看到当前版本号，有新版本时客户端会提示，也可以在那里手动检查更新。官网下载页给的是与客户端更新同一批安装包，不必两边比对。',
          ],
        },
        {
          q: '安卓安装时提示「不允许安装未知应用」怎么办？',
          a: [
            '这是系统对非应用商店安装包的统一保护。按提示允许你正在使用的浏览器或文件管理器安装应用即可，安装完成后可以把这个权限再关掉。',
          ],
        },
        {
          q: 'macOS 版提示「无法验证开发者」，打不开怎么办？',
          a: [
            '这是 macOS 对未经苹果开发者签名软件的默认保护，不是文件损坏、也不是你下错了包。按下面三步放行一次即可，之后系统会记住，双击就能开：一、打开下载的 dmg，把 Gracelink 拖进「应用程序」；二、双击它，弹出提示时点「完成」或「好」；三、打开「系统设置 → 隐私与安全性」，往下找到「安全性」，点「仍要打开」，再输入开机密码。',
            '注意：macOS 15 及以上不能再靠「右键 → 打开」绕过，只能走上面第三步；「仍要打开」这个按钮在你尝试打开后的约一小时内有效。',
          ],
        },
      ],
    },
    {
      title: '账号与登录',
      items: [
        {
          q: '怎么注册账号？',
          a: [
            '在登录页点「注册」，填写手机号或邮箱（以站点开启的注册方式为准）、昵称，以及收到的验证码和 6 至 16 位的密码。验证码有发送次数与有效期限制，请在下发后尽快填写。',
          ],
        },
        {
          q: '忘记密码了怎么办？',
          a: [
            '客户端目前没有自助找回密码的入口。请联系你们的管理员，或写信到 support@gracelink.cc 让我们协助重置。',
            '如果你还能登录，可以自己在「我 → 设置 → 账号安全 → 修改密码」里改：需要先验证原密码；已通过邮箱认证的账号，也可以改用邮箱验证码修改。',
          ],
        },
        {
          q: '桌面端怎么扫码登录？',
          a: [
            '在桌面端登录页选择扫码登录，用已经登录的手机端「扫一扫」扫描屏幕上的二维码即可。扫码时请确认二维码来自官方客户端，不要扫描来源不明的图码。',
          ],
        },
        {
          q: '可以在一台设备上登录多个账号吗？',
          a: [
            '可以。在「我 → 设置 → 切换账号」里添加其他账号，之后轻触头像就能切换。各账号的登录状态、消息与设置相互独立；删除本机某个账号只会清掉它在本机保存的凭据与数据，不影响账号本身。',
          ],
        },
        {
          q: '怎么注销账号？',
          a: [
            '在「我 → 设置 → 账号安全 → 注销账号」里输入登录密码确认。注销不可恢复：账号无法再登录，账号内的资料会被清除；注销后同一个手机号或邮箱可以重新注册，但原账号的内容与关系不会恢复。',
            '本机已下载的文件，以及你自己保存到相册、下载目录的内容不会被删除，请在注销前自行处理。',
          ],
        },
      ],
    },
    {
      title: '聊天与消息',
      items: [
        {
          q: '消息发出去还能撤回吗？',
          a: [
            '自己发的消息，在服务器设定的时间范围内可以长按撤回；群主与管理员还可以撤回群里其他成员的消息。撤回后，对方的聊天里会留下一条撤回提示。通话类的消息不支持撤回。',
          ],
        },
        {
          q: '支持哪些消息类型？',
          a: [
            '文字、表情、图片、视频、文件与语音消息都支持，并且可以引用、转发、撤回或单条删除。收到的语音消息可以一键转成文字；发出的图片会先在本机压缩，iPhone 拍摄的 HEIC 格式与照片方向也会一并处理好。',
          ],
        },
        {
          q: '收到的图片和文件保存在哪里？',
          a: [
            '打开图片或文件时的菜单里可以把它保存到相册或下载目录。安卓 9 及更早的系统上，保存到相册需要授予存储权限。',
          ],
        },
        {
          q: '聊天记录存在哪里？换设备会同步吗？',
          a: [
            '聊天记录会同时保存在本机（Windows 在用户数据目录、macOS 在应用容器目录、Android 在应用私有存储）和服务器上：本机的那份用于离线查看与快速加载，服务器的那份用于多端同步与历史记录。',
            '换设备后用同一个账号登录，会话与历史会同步回来；你手动保存到相册或下载目录的文件、以及本机独有的内容不会跟着走。',
          ],
        },
        {
          q: '群公告、管理员、禁言在哪里设置？',
          a: [
            '进入群聊后打开右上角的群设置：群主可以设置或取消管理员、发布群公告、设置群禁言或对单个成员禁言、生成群二维码；群主与管理员都可以添加或移除成员。被禁言的成员仍可以查看历史消息，但不能发言。',
          ],
        },
      ],
    },
    {
      title: '音视频通话',
      items: [
        {
          q: '怎么发起一对一或群组通话？',
          a: [
            '单聊里点右上角的语音或视频图标即可发起通话；群里点通话入口开始多人通话，其他成员会收到加入提示，通话中可以看到谁在说话、随时开关麦克风。',
            '通话支持共享屏幕，可以共享整个屏幕或只共享一个窗口。共享整个屏幕时会把电脑里的声音一并发送（包括对方的声音），建议戴耳机；共享单个窗口则只发送该程序的声音。',
          ],
        },
        {
          q: '通话没有声音，或者听不到对方？',
          a: [
            '按这个顺序检查：一、系统有没有给麦克风权限（Windows：设置 → 隐私 → 麦克风；Android：应用的权限）；二、通话界面上自己是不是处于静音状态；三、声音是不是被切到了听筒或蓝牙耳机，切换一下音频设备；四、麦克风是否被其他程序占用；五、换一路网络再试。',
          ],
        },
        {
          q: '手机退到后台还能收到消息和来电吗？',
          a: [
            '可以。手机端退到后台仍保持在线，新消息与来电会通过通知送达。如果系统的省电策略限制了后台运行，客户端会提示你去放开通知、后台运行与自启动；按提示把这几项打开，通话与消息就不会被掐断。',
          ],
        },
        {
          q: '为什么来电或群通话邀请响一会儿就不响了？',
          a: [
            '来电与群通话邀请只在很短的时间内有效（约一分钟），超时后会自动撤销 —— 那时再响起来，对方往往已经挂断了，所以不再响铃。请在收到提示时及时接听，或直接打开客户端加入通话。',
          ],
        },
      ],
    },
    {
      title: '发现：灵听与媒体号',
      items: [
        {
          q: '「灵听」是什么？',
          a: [
            '「发现」里的音乐频道：有热门歌曲、推荐歌单与推荐歌手，带播放器。播放时通知栏会显示封面与播放控制，切到后台或锁屏后仍可继续播放。',
          ],
        },
        {
          q: '「媒体号」里的文章来自哪里？',
          a: [
            '媒体号聚合的是多个来源的文章。文章会在应用内浏览器中打开，其内容由来源方负责；若文章跳转到站外网站，则适用该网站自己的服务条款与隐私政策。',
          ],
        },
        {
          q: '发现里的内容打不开或加载很慢？',
          a: [
            '这些内容需要联网加载，弱网时会比较慢。如果网络正常仍然打不开，可能是内容侧暂时不可用，可以稍后再试，并通过客户端内反馈告诉我们具体条目。',
          ],
        },
      ],
    },
    {
      title: '隐私与数据',
      items: [
        {
          q: '消息会经过你们的服务器吗？',
          a: [
            '会。消息、文件与通话数据会经我们的服务器（通话的音视频媒体经专用的中转服务）处理，用于消息投递、多端同步与历史记录；我们不会把聊天内容用于广告投放，也不会出售给第三方。',
            '需要说明的是：恩信不在客户端做端到端加密 —— 服务器需要能够读取消息才能完成投递与多端同步。我们的处理规则见《隐私政策》。',
          ],
        },
        {
          q: '聊天记录保存在本机哪里？卸载会删掉吗？',
          a: [
            'Windows 版保存在当前用户的数据目录（%APPDATA% 下），Android 版保存在应用私有存储中，macOS 版保存在应用自己的容器目录里（~/Library/Containers/cc.gracelink.im/）。卸载软件不会自动删除这些数据：Windows 上如需彻底清除，要在卸载后手动删除该目录；macOS 上还要删掉上面那个容器目录；Android 上卸载应用会一并清除应用数据。',
          ],
        },
        {
          q: '怎么把本机的记录和数据清干净？',
          a: [
            '顺序是：退出登录 → 卸载客户端 → 删除本机用户数据目录（Windows：%APPDATA% 下那个目录；macOS：~/Library/Containers/cc.gracelink.im/；Android 卸载应用即可）。如果连账号侧的资料也要一并清除，可以在客户端里注销账号 —— 注销不可恢复，请先确认。',
          ],
        },
      ],
    },
    {
      title: '其它',
      items: [
        {
          q: '界面支持哪些语言？',
          a: [
            '简体中文、繁體中文、English、日本語、Español、Français、Deutsch 七种，在「我 → 设置 → 界面与显示 → 切换语言」里切换，客户端会记住你的选择。',
          ],
        },
        {
          q: '怎么反馈问题或提建议？',
          a: [
            '在客户端内「我 → 设置 → 帮助与关于 → 帮助中心」可以看到使用说明，也可以直接写邮件到 support@gracelink.cc。反馈时附上客户端版本、系统版本与复现步骤，会更容易定位问题。',
          ],
        },
        {
          q: 'iOS 版什么时候能用？',
          a: [
            'iOS 版还在开发中，目前预计 2027 年 1 月上线；如果时间有变化，我们会在这里更新。上线后也会同步到客户端的更新清单里。',
          ],
        },
      ],
    },
  ],
  contact: {
    title: '没有找到答案？',
    body: [
      '把问题、客户端版本与操作步骤写给我们，我们会尽快回复。',
    ],
  },
};

/* ------------------------------------------------------------------ English */

const en: FaqDoc = {
  title: 'Frequently asked questions',
  lede: [
    'Answers are grouped as downloading and installing, accounts and signing in, chats and messages, audio and video calls, Discover, and privacy and data — and they describe what the client actually does.',
    'If you cannot find what you need here, open "Me → Settings → Help and About → Help Centre" in the client, or email us.',
  ],
  groups: [
    {
      title: 'Downloading and installing',
      items: [
        {
          q: 'Which platforms does Gracelink support?',
          a: [
            'Windows, Android and macOS are available now; the iOS version is in development and expected in January 2027. The desktop and mobile clients use the same account, and messages stay in sync between them.',
          ],
        },
        {
          q: 'Where does the Windows version install, and do I need administrator rights?',
          a: [
            'The Windows build installs into your own user folder. The installer needs no administrator rights and does not modify system directories.',
            'To remove it, use "Me → About Gracelink → Uninstall Gracelink" in the client, or uninstall Gracelink through Windows "Settings → Apps".',
          ],
        },
        {
          q: 'How do I know I have the latest version?',
          a: [
            'The current version is shown under "Me → Settings → Help and About", where the client will also tell you when a newer version exists and lets you check manually. The installer offered here is the same one the client\'s updater uses, so there is nothing to compare by hand.',
          ],
        },
        {
          q: 'Android asks me to allow installing apps from unknown sources — what should I do?',
          a: [
            'That is the system\'s standard protection for apps that do not come from an app store. Allow the browser or file manager you are using to install the app when prompted; you can turn that permission off again once the installation is done.',
          ],
        },
        {
          q: 'macOS says it cannot verify the developer — how do I open the app?',
          a: [
            'That is macOS protecting you from software that is not signed with an Apple developer certificate — not a corrupt file and not the wrong download. Approve it once with these three steps and the system remembers it: (1) open the dmg and drag Gracelink into Applications; (2) double-click it and click Done when the warning appears; (3) open System Settings → Privacy & Security, scroll to Security, click Open Anyway and enter your login password.',
            'On macOS 15 and later the old right-click → Open shortcut no longer bypasses this check — only the third step works. The Open Anyway button appears in Settings for about an hour after you first try to open the app.',
          ],
        },
      ],
    },
    {
      title: 'Accounts and signing in',
      items: [
        {
          q: 'How do I create an account?',
          a: [
            'Choose "Register" on the sign-in page and fill in a phone number or email address (depending on which registration method the service enables), a nickname, the verification code you receive, and a password of 6 to 16 characters. Verification codes have a limited validity and a limit on how often they can be sent, so enter yours promptly.',
          ],
        },
        {
          q: 'I have forgotten my password.',
          a: [
            'The client does not offer self-service password recovery. Please ask your administrator, or email support@gracelink.cc and we will help you reset it.',
            'If you can still sign in, you can change it yourself under "Me → Settings → Account Security → Change Password". Your current password is required; accounts verified by email can use an email verification code instead.',
          ],
        },
        {
          q: 'How does signing in by QR code work on the desktop?',
          a: [
            'Choose the QR sign-in option on the desktop sign-in page and scan the code on screen with the "Scan" feature of a mobile client that is already signed in. Make sure the code comes from the official client, and do not scan codes from unknown sources.',
          ],
        },
        {
          q: 'Can I use more than one account on the same device?',
          a: [
            'Yes. Add another account under "Me → Settings → Switch Account" and switch by tapping your avatar. Each account keeps its own sign-in state, messages and settings. Removing an account from the device only deletes that account\'s local credentials and data — not the account itself.',
          ],
        },
        {
          q: 'How do I close my account?',
          a: [
            'Go to "Me → Settings → Account Security → Delete Account" and confirm with your password. Closure is irreversible: you can no longer sign in with that account, and its data is erased. The same phone number or email address can register again afterwards, but the original account\'s content and relationships are not restored.',
            'Files already downloaded to your device, and anything you saved to your album or download folder yourself, are not deleted — please deal with them before closing the account.',
          ],
        },
      ],
    },
    {
      title: 'Chats and messages',
      items: [
        {
          q: 'Can I take back a message I have sent?',
          a: [
            'Within the time window set on the server you can press and hold your own message to recall it; in a group, the owner and admins can also recall other members\' messages. After a recall, a notice is left in the recipient\'s chat. Messages that represent a call cannot be recalled.',
          ],
        },
        {
          q: 'Which kinds of message are supported?',
          a: [
            'Text, emoji, images, video, files and voice messages, all of which can be quoted, forwarded, recalled or deleted individually. A received voice message can be converted to text in one tap, and images are compressed on your device before they are sent — iPhone HEIC files and photo orientation are handled along the way.',
          ],
        },
        {
          q: 'Where are received images and files stored?',
          a: [
            'The menu you get when you open an image or a file lets you save it to your album or to your download folder. On Android 9 and earlier, saving to the album requires storage permission.',
          ],
        },
        {
          q: 'Where is my chat history kept, and will it follow me to a new device?',
          a: [
            'Chat history is kept both on your device (the user data directory on Windows, the app\'s own container on macOS, the app\'s private storage on Android) and on our servers: the local copy allows offline reading and fast loading, and the server copy provides sync between devices and history.',
            'Sign in on a new device with the same account and your conversations and history are synced back. Files you saved to your album or download folder yourself, and anything that exists only on the old device, do not come along.',
          ],
        },
        {
          q: 'Where do I set a group announcement, admins or muting?',
          a: [
            'Open the group and then the group settings from the top right. The owner can appoint or remove admins, publish announcements, mute the whole group or an individual member, and generate the group QR code; both the owner and admins can add or remove members. A muted member can still read history but cannot post.',
          ],
        },
      ],
    },
    {
      title: 'Audio and video calls',
      items: [
        {
          q: 'How do I start a one-to-one or group call?',
          a: [
            'In a one-to-one chat, tap the voice or video icon at the top right. In a group, tap the call entry point to start a multi-party call; other members are invited to join, and during the call you can see who is speaking and mute or unmute yourself at any time.',
            'Calls support screen sharing, either your whole screen or a single window. Sharing the whole screen also sends your computer\'s audio, including the other party\'s voice, so headphones are recommended; sharing a single window sends only that application\'s audio.',
          ],
        },
        {
          q: 'I cannot hear the other party, or they cannot hear me.',
          a: [
            'Check in this order: (1) does the system allow microphone access (Windows: Settings → Privacy → Microphone; Android: app permissions)? (2) are you muted on the call screen? (3) has the audio been routed to the earpiece or a Bluetooth headset — try switching audio device; (4) is another application holding the microphone? (5) try another network connection.',
          ],
        },
        {
          q: 'Will my phone still receive messages and calls in the background?',
          a: [
            'Yes. The mobile client stays online in the background and delivers new messages and incoming calls as notifications. If your phone\'s power saving restricts background activity, the client will tell you which settings to open — notifications, background activity and auto-start. Enable those and calls and messages will not be cut off.',
          ],
        },
        {
          q: 'Why does an incoming call or group-call invitation stop ringing?',
          a: [
            'Incoming calls and group-call invitations are valid only for a short period (about a minute) and are withdrawn after that. Ringing any later would usually mean the caller has already hung up, so the client stops. Please answer from the notification while it is shown, or open the client and join the call directly.',
          ],
        },
      ],
    },
    {
      title: 'Discover: Lingting and Media',
      items: [
        {
          q: 'What is Lingting?',
          a: [
            'It is the music channel inside Discover: hot songs, recommended playlists and artists, with a player. While music plays the notification shows the cover art and playback controls, and playback continues when the app goes to the background or the screen locks.',
          ],
        },
        {
          q: 'Where do the articles in Media come from?',
          a: [
            'Media collects articles from a number of sources. Articles open in the in-app browser and their content is the responsibility of the source; when an article takes you to a site outside Gracelink, that site\'s own terms and privacy policy apply.',
          ],
        },
        {
          q: 'Content in Discover will not open, or loads very slowly.',
          a: [
            'This content is fetched over the network, so it can be slow on a poor connection. If it still will not open on a good connection, the content may be temporarily unavailable — try again later, and tell us the specific item through in-app feedback.',
          ],
        },
      ],
    },
    {
      title: 'Privacy and data',
      items: [
        {
          q: 'Do my messages go through your servers?',
          a: [
            'Yes. Messages, files and call data are processed by our servers (call media is handled by a dedicated relay service) in order to deliver messages, keep devices in sync and show history. We do not use chat content for advertising and we do not sell it to third parties.',
            'To be clear: Gracelink does not use end-to-end encryption in the client — the servers need to be able to read a message in order to deliver it and keep your devices in sync. Our handling rules are set out in the Privacy Policy.',
          ],
        },
        {
          q: 'Where is my chat history stored on my device, and does uninstalling remove it?',
          a: [
            'On Windows it is stored in the current user\'s data directory (under %APPDATA%); on Android it is in the app\'s private storage; on macOS it is inside the app\'s own container (~/Library/Containers/cc.gracelink.im/). Uninstalling does not delete this data automatically: on Windows, remove that directory yourself after uninstalling if you want it gone; on macOS, remove the container as well; on Android, uninstalling through the system removes the app data too.',
          ],
        },
        {
          q: 'How do I clear everything from my device?',
          a: [
            'In this order: sign out → uninstall the client → delete the local user data directory (on Windows, the folder under %APPDATA%; on macOS, ~/Library/Containers/cc.gracelink.im/; on Android, uninstalling the app is enough). If you also want the data on our side removed, close your account in the client first — closure cannot be undone, so please be sure.',
          ],
        },
      ],
    },
    {
      title: 'Other questions',
      items: [
        {
          q: 'Which interface languages are available?',
          a: [
            'Seven: Simplified Chinese, Traditional Chinese, English, Japanese, Spanish, French and German. Switch under "Me → Settings → Appearance → Language"; the client remembers your choice.',
          ],
        },
        {
          q: 'How do I report a problem or suggest something?',
          a: [
            'Open "Me → Settings → Help and About → Help Centre" in the client for usage notes, or email support@gracelink.cc. Including the client version, your system version and the steps that reproduce the problem helps us find it faster.',
          ],
        },
        {
          q: 'When will the iOS version be available?',
          a: [
            'The iOS version is still in development and is currently expected in January 2027. If that changes we will update this page. Once released it will also be added to the client\'s update manifest.',
          ],
        },
      ],
    },
  ],
  contact: {
    title: 'Still stuck?',
    body: ['Send us the problem, your client version and the steps you took, and we will get back to you.'],
  },
};

export const FAQ: Record<Lang, FaqDoc> = { zh, en };
