/**
 * 双语字典。
 *
 * `en` 的类型就是中文那份的**形状**，缺一个键或键名拼错都会让 `astro check` 报红，
 * 不会出现「中文页正常、英文页空一块」。中文那份**刻意不写 `as const`**：
 * 写了之后类型变成字面量（`'下载'`），英文的 `'Download'` 就全都不可赋值。
 * 要钉的是形状，不是值。
 *
 * 文案口径（2026-10-10 用户定的）：
 * * 口号就是「让沟通更简单，让连接更真实」，不要另创；
 * * **不放**「说清楚数据放在哪」那一类自贬内容（官网不讲自己做不到什么）；
 * * **不放**版本号 / 内部号 / 安装包校验和 这类面向运维的信息 —— 官网不是发版日志。
 *   ⚠️ 唯一例外是 `download.macosNote`（macOS 首次打开那三步，2026-10-11 加）：
 *   那不是运维信息、是**用户操作指引** —— macOS 版未签名是既定路线，页面上
 *   不说这三步，用户双击被拦后只会以为软件坏了。其余以「未签名」为由的说明
 *   仍不进官网；
 * * 不写「装好、登录、开始用」这种口号，用正常的营销语气。
 */
import type { Lang } from '../consts';

const zh = {
  /** 品牌字标：中文写「恩信」，与 App 底部第一个 tab 一致 */
  wordmark: '恩信',
  meta: {
    title: '恩信 Gracelink — 让沟通更简单，让连接更真实',
    description:
      '恩信是桌面与手机上的即时通讯客户端：单聊、群聊、音视频通话、通讯录与群组管理。Windows、Android 与 macOS 版本已开放下载。',
  },
  nav: {
    features: '功能',
    download: '下载',
    support: '支持',
  },
  /** 法律页 / 常见问题页上的固定标签 */
  doc: {
    updated: '最后更新',
    toc: '本页内容',
  },
  hero: {
    eyebrow: '恩信 · GRACELINK',
    title: '让沟通更简单，让连接更真实',
    lede: '单聊、群聊、音视频通话、通讯录与群组管理，都在一个客户端里。桌面与手机同一个账号，消息一处不漏。',
    ctaPrimary: '下载客户端',
    ctaSecondary: '了解功能',
    forPlatforms: 'Windows · Android · macOS · iOS',
  },
  platforms: {
    title: '支持的系统',
    windows: 'Windows',
    android: 'Android',
    ios: 'iOS',
    macos: 'macOS',
    available: '可下载',
    soon: '即将上线',
    /** iOS 还没上线，但这次给个时间口径（用户 2026-10-11 定的） */
    iosEta: '预计 2027 年 1 月上线',
  },
  features: {
    title: '一个客户端，够用且好用',
    lede: '消息、通讯录、发现、我，四个入口，都按你熟悉的方式排列。',
    items: [
      {
        title: '单聊与群聊',
        body: '文字、表情、图片、文件都能发；消息可以撤回、转发、@提醒，会话能置顶或免打扰。',
        bullets: ['撤回 / 转发 / @提醒', '会话置顶与免打扰', '图片、文件与语音消息'],
      },
      {
        title: '音视频通话',
        body: '一对一和群组都能打，支持共享屏幕；多人通话里谁开着麦克风，通话界面上就能看到。',
        bullets: ['一对一语音与视频', '群组多人通话', '共享屏幕与麦克风状态'],
      },
      {
        title: '通讯录与群组',
        body: '好友、群组、群公告、群主与管理员、成员禁言——群该有的管理能力都在客户端里。',
        bullets: ['好友与群组管理', '群公告 / 管理员 / 禁言', '通讯录分组与搜索'],
      },
      {
        title: '发现',
        // 名字照 App 的语言包来：两栏是 lingting.title「灵听」与 news.title「媒体号」。
        // 灵听是**音乐频道**（每日三十首 / 热门歌曲 / 推荐歌单 / 推荐歌手 / 播放器），
        // 媒体号才是文章聚合 —— 2026-10-10 之前这里写成「资讯」还把灵听说成
        // 「把长文听成音频」，两处都不是 App 里的事实。
        body: '「灵听」和「媒体号」都在发现里：前者是音乐频道，热门歌曲、推荐歌单与歌手、播放器都在；后者是多来源的文章。看内容和回消息，不用来回切应用。',
        bullets: ['灵听：歌曲与歌单、歌手', '媒体号：多来源文章', '与聊天同一个账号'],
      },
    ],
  },
  download: {
    sectionTitle: '下载恩信',
    sectionLede: '选择你的系统，或让手机扫码。',
    cardTitle: '下载客户端',
    cardLede: 'Windows、Android 与 macOS 版本已开放下载；iOS 版本预计 2027 年 1 月上线。',
    downloadButton: '下载',
    soonButton: '即将上线',
    scanTitle: '手机扫码下载',
    scanHint: '用手机相机对着二维码，即可打开下载页。',
    stepsTitle: '从这里开始',
    steps: [
      '下载并安装客户端。Windows 版装到当前用户目录，不需要管理员权限。',
      '打开客户端，用恩信账号登录；手机端已登录时也可以直接扫码登录。',
      '联系人与群组已经躺在列表里，登录即可开始。',
    ],
    allPending: '安装包正在接入中，稍后回来看看。',
    /**
     * macOS 首次打开那三步（2026-10-11 macOS 版上线时加）。
     *
     * 为什么要写：macOS 版没有买苹果开发者签名，用户双击会被 Gatekeeper 拦下；
     * 而 **macOS 15 起已经不能再靠「右键 → 打开」绕过**（苹果取消了这个入口），
     * 只认「系统设置 → 隐私与安全性 → 仍要打开」。不写这三步，用户下完只会
     * 以为文件坏了或软件有问题。
     */
    macosNote: {
      title: 'macOS 版第一次打开会先被系统拦一下',
      body: '这不是文件损坏，也不是你下错了包。我们没有购买苹果的开发者签名，所以首次打开时系统会提示无法验证开发者。按下面三步放行一次即可，之后系统会记住，双击就能开。',
      steps: [
        '打开下载的 dmg 文件，把 Gracelink 拖进「应用程序」；',
        '双击它 —— 弹出「无法验证开发者」之类提示时，点「完成」或「好」；',
        '打开「系统设置 → 隐私与安全性」，往下找到「安全性」，点「仍要打开」，再输入开机密码。',
      ],
      tip: 'macOS 15 及以上不能再靠「右键 → 打开」绕过；「仍要打开」这个按钮在你尝试打开后的约一小时内才会出现在设置里。',
    },
  },
  footer: {
    tagline: '让沟通更简单，让连接更真实。',
    productTitle: '产品',
    supportTitle: '支持',
    legalTitle: '法律',
    featureList: '功能介绍',
    download: '下载客户端',
    faq: '常见问题',
    contact: '在客户端内反馈',
    terms: '服务条款',
    privacy: '隐私政策',
    rights: 'All Rights Reserved.',
  },
  /**
   * 应用内浏览器（in-app webview）里的下载拦截提示。
   *
   * 为什么要拦：在 App 内置浏览器里点外链直接下 exe/apk，一来微信这类客户端会把
   * 它判成「诱导下载」，轻则拦掉这一次、重则把域名整个拉黑；二来很多内置浏览器
   * 本来就没有下载安装包的能力（点下去没反应或下一张打不开的图）。
   * 所以下载链接**不直接跳**，先判 User-Agent，是应用内浏览器就弹这一张说明。
   *
   * 文案**不点名某一家**（2026-10-11 用户：「不只是微信，QQ 也一样，软件内 webview
   * 最好都提示」）：只讲「你在应用内浏览器里」与「怎么做才能下」；
   * 微信 / QQ 那套「···」菜单当例子提一下。
   */
  inAppGuard: {
    title: '请在浏览器中打开',
    body: '你是从应用内的浏览器打开本页的，这类内置浏览器不能直接下载安装包。请点右上角菜单里的「在浏览器打开」（微信、QQ 里是右上角的「···」），再回来点下载。',
    copy: '复制下载地址',
    copied: '已复制，粘贴到浏览器地址栏即可',
    copyFail: '复制失败，请长按上方地址手动复制',
    close: '知道了',
  },
  langSwitch: {
    label: '语言',
    current: '当前语言',
  },
  root: {
    title: '恩信 Gracelink',
    redirecting: '正在进入…',
    pick: '选择语言 / Choose a language',
    hint: '浏览器语言识别失败时会显示英文页面。',
  },
  notFound: {
    title: '页面不存在',
    lede: '你要找的页面可能已经移动或删除。',
    backHome: '回到首页',
  },
};

type Dict = typeof zh;

const en: Dict = {
  wordmark: 'Gracelink',
  meta: {
    title: 'Gracelink — Simpler conversations, truer connections',
    description:
      'Gracelink is a messaging client for desktop and mobile: direct and group chat, audio and video calls, contacts and group management. Windows, Android and macOS builds are available.',
  },
  nav: {
    features: 'Features',
    download: 'Download',
    support: 'Support',
  },
  doc: {
    updated: 'Last updated',
    toc: 'On this page',
  },
  hero: {
    eyebrow: 'GRACELINK',
    title: 'Simpler conversations, truer connections',
    lede: 'Direct messages, group chats, audio and video calls, contacts and group management — all in one client, with the same account on desktop and mobile.',
    ctaPrimary: 'Download',
    ctaSecondary: 'See features',
    forPlatforms: 'Windows · Android · macOS · iOS',
  },
  platforms: {
    title: 'Supported platforms',
    windows: 'Windows',
    android: 'Android',
    ios: 'iOS',
    macos: 'macOS',
    available: 'Available',
    soon: 'Coming soon',
    iosEta: 'Expected January 2027',
  },
  features: {
    title: 'One client, everything you need',
    lede: 'Messages, contacts, discover, and you — four places, laid out the way you already expect.',
    items: [
      {
        title: 'Direct and group chat',
        body: 'Text, emoji, images and files. Messages can be recalled, forwarded or used to @mention someone; conversations can be pinned or muted.',
        bullets: ['Recall, forward, @mention', 'Pin and mute conversations', 'Images, files and voice messages'],
      },
      {
        title: 'Audio and video calls',
        body: 'One-to-one and group calls with screen sharing; in a group call you can see at a glance who has their microphone on.',
        bullets: ['One-to-one voice and video', 'Group calls', 'Screen sharing and mic state'],
      },
      {
        title: 'Contacts and groups',
        body: 'Friends, groups, announcements, owners and admins, member muting — the group controls live in the client, not in a separate console.',
        bullets: ['Friend and group management', 'Announcements, admins, muting', 'Contact groups and search'],
      },
      {
        title: 'Discover',
        body: 'Lingting and Media both live in Discover: a music channel with hot songs, playlists, artists and a player, plus articles from many sources. Reading and replying do not mean switching apps.',
        bullets: ['Lingting: songs, playlists, artists', 'Media: articles from many sources', 'Same account as chat'],
      },
    ],
  },
  download: {
    sectionTitle: 'Download Gracelink',
    sectionLede: 'Pick your platform, or scan the code with your phone.',
    cardTitle: 'Download the client',
    cardLede: 'Windows, Android and macOS builds are available; iOS is expected in January 2027.',
    downloadButton: 'Download',
    soonButton: 'Coming soon',
    scanTitle: 'Scan to download',
    scanHint: 'Point your phone camera at the code to open the download page.',
    stepsTitle: 'Getting started',
    steps: [
      'Download and install the client. The Windows build installs into your user folder — no administrator rights needed.',
      'Open it and sign in with your Gracelink account, or scan the code from the mobile app if you are already signed in there.',
      'Your friends and groups are already in the list — sign in and start chatting.',
    ],
    allPending: 'Installers are being wired up — check back shortly.',
    macosNote: {
      title: 'On macOS, the system blocks the first launch',
      body: 'The download is not corrupt and you did not grab the wrong file. We do not hold an Apple developer signing certificate, so macOS reports that it cannot verify the developer the first time you open the app. Approve it once with the three steps below and the system remembers it — double-clicking will work from then on.',
      steps: [
        'Open the downloaded dmg and drag Gracelink into Applications;',
        'Double-click it — when macOS says it cannot verify the developer, click Done;',
        'Open System Settings → Privacy & Security, scroll to Security, click Open Anyway, then enter your login password.',
      ],
      tip: 'On macOS 15 and later the old right-click → Open shortcut no longer works; the Open Anyway button appears in Settings for about an hour after you first try to open the app.',
    },
  },
  footer: {
    tagline: 'Simpler conversations, truer connections.',
    productTitle: 'Product',
    supportTitle: 'Support',
    legalTitle: 'Legal',
    featureList: 'Features',
    download: 'Download',
    faq: 'FAQ',
    contact: 'Feedback in the app',
    terms: 'Terms of Service',
    privacy: 'Privacy Policy',
    rights: 'All Rights Reserved.',
  },
  inAppGuard: {
    title: 'Open in a browser to download',
    body: 'You opened this page in an app\'s built-in browser, and those browsers cannot download installers directly. Open the menu at the top right and choose "Open in browser" (in WeChat and QQ that is the "···"), then tap download again.',
    copy: 'Copy download link',
    copied: 'Copied — paste it into your browser\'s address bar',
    copyFail: 'Copy failed — long-press the link above instead',
    close: 'Got it',
  },
  langSwitch: {
    label: 'Language',
    current: 'Current language',
  },
  root: {
    title: 'Gracelink',
    redirecting: 'Entering…',
    pick: '选择语言 / Choose a language',
    hint: 'If your browser language cannot be recognised, the English site is shown.',
  },
  notFound: {
    title: 'Page not found',
    lede: 'The page you are looking for may have moved or been removed.',
    backHome: 'Back to home',
  },
};

export const ui: Record<Lang, Dict> = { zh, en };
