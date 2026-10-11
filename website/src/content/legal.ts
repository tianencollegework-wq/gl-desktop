/**
 * 法律文档正文：**服务条款**与**隐私政策**，中英各一份。
 *
 * 写法上的三条硬规矩（不是文案偏好，是能不能站得住的问题）：
 *
 * 1. **只写软件真的做了的事**。每一条都能在仓库里找到出处：
 *    账号与登录（`login_page` / `qr_login_page` / `register_page`）、注销账号
 *    （`account_cancel_page.dart` + `user.cancelIntro` 那几句）、多账号与切换
 *    （`accounts_page.dart`）、群公告 / 管理员 / 群禁言 / 群二维码（`group.*` 语言包）、
 *    音视频与屏幕共享（`group_call_page.dart`、`call.*`）、七种界面语言
 *    （`AppI18n.supportedLocales`）、本机数据与卸载不删（安装许可协议第五节）、
 *    权限清单（`android/app/src/main/AndroidManifest.xml`，macOS 那边是
 *    `macos/Runner/Release.entitlements` 与 `Info.plist` 里的权限文案）、推送与音视频中转用的
 *    第三方（`google-services.json` → FCM；`SfuPaths` → Cloudflare Realtime）。
 * 2. **不写做不到的承诺**：不写「端到端加密」、不写「服务器看不到你的消息」——
 *    消息是经服务器投递并在服务器上为多端同步而保存的。要写就写「存哪、存多久、
 *    谁能碰、怎么删」。
 * 3. **运营主体与联系方式与既有文件对齐**：安装许可协议（`tool/installer/license.txt`）
 *    用的是「Gracelink Team（恩信运营团队）」；邮箱由用户 2026-10-10 指定为
 *    `support@gracelink.cc`（客服/支持这一个口）。
 *
 * 中英两份**结构完全一致**（`LegalDoc` 类型把两边都钉住，缺一节就编译不过），
 * 页脚照既有文件的口径注明「如有歧义以中文版本为准」。
 */
import type { Lang } from '../consts';

/** 文档生效/更新日期（页面上的「最后更新」用它） */
export const LEGAL_UPDATED = '2026-10-11';

/** 对外联系方式：与页脚、FAQ 用的是同一个地址（只此一个口） */
export const SUPPORT_EMAIL = 'support@gracelink.cc';

export interface LegalSection {
  /** 节标题（含编号，如「一、服务内容」） */
  heading: string;
  /** 普通段落 */
  paras?: string[];
  /** 该节下的条目（页面上渲染成列表） */
  items?: string[];
}

export interface LegalDoc {
  title: string;
  /** 开头的导读段落（谁和谁、什么适用、生效时点） */
  lede: string[];
  sections: LegalSection[];
  /** 文末的说明（版本语言、生效方式等） */
  closing: string[];
}

/* ------------------------------------------------------------------ 中文 */

const termsZh: LegalDoc = {
  title: '恩信 Gracelink 服务条款',
  lede: [
    '本服务条款（以下称「本条款」）由 Gracelink Team（以下称「我们」）与您（以下称「您」或「用户」）就恩信 Gracelink 即时通讯客户端软件及其配套服务（以下称「本服务」）的安装与使用达成。本条款自您完成账号注册或实际使用本服务时生效。',
    '请在注册与使用前完整阅读本条款。您完成注册、登录或使用本服务，即表示您已阅读、理解并同意本条款的全部内容；如您不同意，请停止注册与使用。',
  ],
  sections: [
    {
      heading: '一、服务内容',
      paras: [
        '本服务由客户端软件与服务端两部分组成。客户端目前提供 Windows 桌面版、Android 移动版与 macOS 版，iOS 版正在开发中（预计 2027 年 1 月发布）；服务端包括账号体系、消息投递、多端同步、音视频通话中转、文件存储与「发现」栏目，由我们运营与维护。客户端仅包含客户端程序，不含服务器端软件。',
        '本服务提供的主要功能包括：单聊与群聊（文字、表情、图片、文件与语音消息，支持引用、转发、撤回与删除）、好友与通讯录管理、群组管理（群公告、群主与管理员、群禁言、群二维码、成员管理）、一对一及群组多人音视频通话（含屏幕共享）、扫码登录、多账号切换与七种界面语言，以及「发现」栏目中的内容服务（灵听音乐与媒体号文章）。',
        '不同平台、不同版本的功能可能不一致；我们新增的功能同样适用本条款。',
        '本服务目前不向用户收取费用。我们可能在未来推出收费功能或调整免费范围，届时会以本页面公示、客户端内提示等合理方式提前告知；已发布的功能不会因后续收费而溯及既往，您也可以选择不使用收费功能。',
      ],
    },
    {
      heading: '二、账号',
      paras: [
        '使用本服务需要注册恩信账号。注册时，您需要提供真实、有效且能够正常接收验证信息的手机号码或电子邮箱（以服务端当前开启的注册方式为准），并设置 6 至 16 位的密码。您应保证所提交的信息真实、准确、完整，并在信息变化时及时更新。',
        '账号的所有权归我们，您在遵守本条款的前提下取得账号的使用权。账号仅限本人（或经授权的单位内部成员）使用，不得出租、出借、赠与、转让，也不得以任何方式买卖。',
        '请妥善保管账号与密码。登录凭据在本机加密保存。因设备被他人使用、凭据泄露、账号转借或您未及时修改密码而造成的损失，由您自行承担。',
        '如您发现账号被盗用、存在异常登录或其他安全风险，请立即修改密码并通过第十条所示方式联系我们。',
        '您可以随时在客户端「我 → 设置 → 账号安全 → 注销账号」申请注销账号。注销不可撤销：该账号将无法登录，账号内的资料会被清除，且无法恢复；注销完成后，同一个手机号码或电子邮箱可以重新注册，但原账号的内容与关系不会恢复。本机已下载的文件与您自行保存到相册、下载目录的内容不在清除范围内，请在注销前自行处理。',
        '同一台设备上可以添加并切换多个账号（「我 → 设置 → 切换账号」）。各账号的登录状态、消息与设置相互独立，删除本机账号只会移除该账号在本机保存的凭据与数据，不影响账号本身。',
      ],
    },
    {
      heading: '三、使用规范',
      paras: ['您在使用本服务时，应遵守您所在国家或地区的法律法规以及本条款。具体而言，您不得：'],
      items: [
        '利用本服务制作、复制、发布、传播违法信息，或侵害他人合法权益的内容；',
        '骚扰、欺诈、侮辱、威胁他人，或冒用他人身份、伪造信息来源；',
        '利用本服务从事赌博、诈骗、传销、非法集资、贩卖违禁物品等违法活动，或传播他人隐私、未经授权公开他人信息；',
        '未经对方同意，对通话、语音或聊天内容进行录制、公开或传播；',
        '群发垃圾信息、批量注册账号或批量添加好友，使用自动化程序批量操作，或抓取、滥用服务端数据；',
        '干扰、攻击服务器、网络或他人设备，进行漏洞探测、渗透测试或其他危害服务安全的行为；',
        '对本服务进行反向工程、反编译、破解或修改，删除、遮挡、改动软件中的名称、标识与版权声明，或将本服务及其修改版本重新打包、出租、出售、提供给第三方。',
      ],
    },
    {
      heading: '四、违规处理与举报',
      paras: [
        '您对自己发布、发送与存储的内容负责。如您的行为违反本条款或法律法规，我们可以视情节采取提醒、限制功能、限制发言、暂停或终止向该账号提供本服务等措施；涉嫌违法犯罪的，我们会依法向有权机关报告并配合处理。',
        '如您认为其他用户的行为或「发现」栏目中的内容侵犯了您的合法权益，可通过第十条所示方式向我们反馈，并提供必要的说明与依据。我们会在核实后依法处理。',
      ],
    },
    {
      heading: '五、内容与知识产权',
      paras: [
        '您在服务中发送、上传的内容（消息、图片、文件、语音、资料等）归您或相应权利人所有。为实现消息投递、多端同步、历史记录查看与通话功能，您授权我们在提供本服务所必需的范围内存储、传输与处理这些内容，具体见《隐私政策》。',
        '本服务的软件、界面、图标、商标、文字与文档，其知识产权归我们或相应权利人所有。未经我们书面同意，您不得复制、修改、分发或以其他方式使用。',
        '本服务包含 Flutter 等第三方开源组件，这些组件按其自身的许可条款提供，相关声明见随软件分发的文件或组件项目页面。',
        '「发现」栏目中的文章等内容可能来自第三方或由用户发布，其权利归原作者或发布方所有。我们不对其准确性、完整性或可用性作出保证；通过应用内浏览器打开的站外页面适用该网站自身的条款与隐私政策。',
      ],
    },
    {
      heading: '六、隐私与数据',
      paras: [
        '我们按照《隐私政策》处理您的个人信息。《隐私政策》与本条款共同构成您与我们之间关于本服务的约定；就个人信息处理的具体规则，以《隐私政策》为准。',
        '为实现消息投递、多端同步与音视频通话，消息、文件与通话数据会经由我们的服务器或我们指定的中转服务器处理，并在为实现功能所必需的范围内保存。',
        '聊天记录、好友与群组信息、登录状态、设置等数据同时保存在您使用的设备上（Windows 版位于当前用户的数据目录，%APPDATA% 下；macOS 版位于应用自己的容器目录，~/Library/Containers/cc.gracelink.im/；Android 版位于应用的私有存储）。请自行做好备份；卸载软件不会自动删除这些数据，彻底清除的方法见《隐私政策》第七条。',
      ],
    },
    {
      heading: '七、服务变更、中断与终止',
      paras: [
        '我们可能因维护、升级、部署调整或产品规划，对本服务的功能与界面进行调整，或将部分功能下线。除紧急情况外，我们会尽量提前告知。',
        '本服务依赖网络、设备与第三方服务，可能因网络故障、设备环境、系统设置、第三方服务异常、不可抗力或我们的必要维护而延迟或中断；我们会尽力恢复。',
        '您可以随时停止使用本服务并卸载软件，卸载方式见第八条。',
        '如您严重或多次违反本条款，我们可以暂停或终止向您提供本服务。',
      ],
    },
    {
      heading: '八、更新与卸载',
      paras: [
        '我们会不定期发布新版本，以修复问题、提升性能或增加功能。客户端可检查更新并下载安装包；在您确认安装新版本后，新版随附的本条款即行适用。',
        '卸载方式：Windows 版可在客户端「我 → 关于恩信 → 卸载恩信」卸载，也可以在 Windows「设置 → 应用」中卸载；macOS 版把 Gracelink 从「应用程序」移到废纸篓即可；Android 版按系统常规方式卸载。',
      ],
    },
    {
      heading: '九、免责声明',
      paras: [
        '本服务按「现状」提供。在法律允许的最大范围内，我们不对本服务的适用性、持续可用性或无错误作出明示或默示的担保。',
        '消息与通话可能因网络状况、设备环境、系统设置、维护升级或不可抗力而延迟、中断或造成数据丢失。请勿将本服务用于应急救援、医疗、生命安全等对通讯有严格要求的场合。',
        '在法律允许的最大范围内，对于因使用或无法使用本服务而造成的间接损失、数据丢失或利润损失，我们不承担责任。',
        '本条不排除或限制依法不得排除或限制的责任。',
      ],
    },
    {
      heading: '十、联系我们',
      paras: ['如您对本条款有任何疑问、意见或投诉，可以通过以下方式联系我们：'],
      items: [
        '电子邮箱：support@gracelink.cc',
        '客户端内：我 → 设置 → 帮助与关于 → 帮助中心',
      ],
    },
    {
      heading: '十一、条款的更新与适用',
      paras: [
        '我们可能根据法律法规变化、产品调整或运营需要更新本条款。更新后的条款会在本页面公布并标注更新日期；涉及您主要权利的重大变更，我们会以客户端内提示等合理方式另行告知。您在条款更新后继续使用本服务，即视为接受更新后的条款。',
        '本条款的适用与解释，以您所在国家或地区的法律法规为准。其中部分条款被认定无效或不可执行的，不影响其余条款的效力。',
      ],
    },
  ],
  closing: [
    '本条款有中文与英文两个版本。两者如有歧义，以中文版本为准。',
    '本条款与安装时展示的软件使用许可声明如有不一致，就本服务的使用以本条款为准。',
  ],
};

const privacyZh: LegalDoc = {
  title: '恩信 Gracelink 隐私政策',
  lede: [
    '本隐私政策说明 Gracelink Team（以下称「我们」）在您使用恩信 Gracelink 客户端软件及相关服务（以下称「本服务」）时，会收集哪些信息、如何使用与保存、与谁共享，以及您如何管理这些信息。',
    '本政策适用于恩信 Gracelink 的客户端（Windows 桌面版、Android 移动版、macOS 版，以及后续发布的 iOS 版本）、本官网，以及由我们运营的服务端。请您在使用前完整阅读；继续使用本服务，即表示您已阅读并理解本政策。',
  ],
  sections: [
    {
      heading: '一、我们收集哪些信息',
      paras: ['我们只收集为提供本服务所必需的信息。具体包括：'],
      items: [
        '账号与资料：您注册时填写的手机号码或电子邮箱（以服务端开启的注册方式为准）、密码（加密保存），以及昵称、头像、姓名、电子邮箱、个性签名、性别等您主动填写的资料。',
        '您在使用中产生的内容：您发送与接收的消息（文字、表情、图片、视频、文件、语音）、好友与群组关系、群公告与群设置、以及为发送这些内容所需的上传记录。',
        '通话相关信息：通话的信令与状态（发起、接听、结束时间、参与者、静音与共享屏幕状态）、为建立通话所需的网络地址与中转凭据，以及通话过程中的网络与质量数据。音频与视频内容仅在中转过程中转发，我们不会对其进行录制或留存。',
        '设备与日志信息：设备型号与厂商、操作系统及版本、客户端版本、设备推送标识（用于向您的设备送达离线消息与来电提醒）、网络类型与 IP 地址、登录时间与操作记录、错误与崩溃日志。',
        '权限对应的信息：仅在您使用相应功能时收集，详见第二条。',
      ],
    },
    {
      heading: '二、系统权限与用途',
      paras: [
        '客户端申请的权限都与具体功能一一对应；您可以在系统设置中随时关闭，关闭后对应功能将不可用（其他功能不受影响）。',
      ],
      items: [
        '相机：用于视频通话、扫描二维码（含从相册识别二维码）；',
        '麦克风：用于音视频通话与语音消息录制；',
        '存储与相册：用于选择并发送图片与文件、把收到的图片保存到相册、把文件保存到下载目录；',
        '通知：用于展示新消息提醒、来电与群通话邀请（含通话进行中的保活提示）；',
        '网络与设备状态、电池优化白名单：用于在通话与后台在线期间保持连接，避免被系统省电策略中断；',
        '屏幕录制（macOS）：仅在您主动发起屏幕共享时申请，用于把您的屏幕画面发送到通话中，不会在后台录制。',
      ],
    },
    {
      heading: '三、我们如何使用这些信息',
      paras: ['我们仅在下列目的范围内使用所收集的信息：'],
      items: [
        '提供与维护本服务：投递消息、在您的多个平台之间同步、建立音视频通话、上传与下载文件、送达离线消息与来电提醒、检查与安装更新；',
        '账号与安全：完成注册与登录（含扫码登录）、验证身份、修改与找回密码、注销账号，识别异常登录并防范盗号、垃圾信息与滥用行为；',
        '客户支持：响应您通过客户端内反馈或邮箱提出的问题与投诉；',
        '改进服务：分析功能使用情况与错误日志，以定位故障、优化性能与使用体验；',
        '履行法律义务：依照法律法规或有权机关的要求处理，或为主张、抗辩法律请求所必需。',
      ],
    },
    {
      heading: '四、我们如何共享与委托处理',
      paras: [
        '我们不会出售您的个人信息，也不会将您的聊天内容用于广告投放。客户端未集成第三方广告或营销 SDK。',
        '为提供本服务，我们会委托以下第三方处理必要的信息；它们只能按照我们的要求与约定用途处理，并负有保密义务：',
      ],
      items: [
        'Cloudflare：提供音视频通话的媒体中转与群通话服务，通话的音视频流经其服务器转发，不在其服务器上落盘保存；',
        'Google Firebase Cloud Messaging：在客户端未打开或处于后台时提供设备推送通道，用于送达新消息提醒、来电与群通话邀请；',
        '服务器托管、带宽与静态资源分发服务商：承载服务端程序、文件存储与官网等静态资源。',
      ],
    },
    {
      heading: '五、我们不会做的事',
      items: [
        '不出售、出租您的个人信息；',
        '不将您的聊天内容、通讯录或通话内容用于广告或商业推广；',
        '不在与功能无关的场景读取您的相机、麦克风或相册；',
        '不因您拒绝某项非必要权限而限制您使用与之无关的功能；',
        '除本政策第四条规定的情形外，未经您的同意，不向任何第三方提供您的个人信息。',
      ],
    },
    {
      heading: '六、信息的存储与保留期限',
      paras: [
        '您在使用过程中产生的内容与账号信息存储在我们的服务器上，服务器及所依托的云基础设施可能位于您所在国家或地区之外。',
        '我们在实现本政策所述目的所必需的最短期限内保留信息，法律法规另有要求的除外。注销账号后，我们会删除或匿名化该账号的资料与内容；为履行法律义务、处理争议或配合有权机关而必须保留的部分，将在法定期限届满后删除。',
        '您发送给对方的消息会同时存在于对方的账号与设备上。删除您自己一侧的记录，不会删除对方设备上已保存的内容。',
      ],
    },
    {
      heading: '七、本机数据与清除方式',
      paras: [
        '为支持离线查看与快速加载，聊天记录、好友与群组信息、登录状态与设置会保存在您使用的设备上：Windows 版位于当前用户的数据目录（%APPDATA% 下）；macOS 版位于应用自己的容器目录（~/Library/Containers/cc.gracelink.im/）；Android 版位于应用的私有存储，其他应用无法读取。',
        '卸载软件不会自动删除这些数据。Windows 版卸载后，如需彻底清除，请在文件管理器中删除上述用户数据目录；macOS 版卸载后还需删除上述容器目录；Android 版在系统中卸载应用会同时清除应用数据。',
        '本机保存的登录凭据经过加密。请勿把设备交给不可信的人使用，也尽量避免在公共或不安全的电脑上登录。',
      ],
    },
    {
      heading: '八、您的权利与控制',
      paras: ['您可以通过客户端自行管理自己的信息：'],
      items: [
        '查阅与更正：我 → 设置 → 个人资料（昵称、头像、姓名、邮箱、签名、性别等）；',
        '修改密码：我 → 设置 → 账号安全 → 修改密码（需验证原密码；已通过邮箱认证的账号也可使用邮箱验证码）；',
        '注销账号：我 → 设置 → 账号安全 → 注销账号（不可恢复，请在操作前处理本机文件与保存的内容）；',
        '撤回权限：在系统设置中关闭相机、麦克风、相册、通知等权限；',
        '清除本机数据：见第七条；',
        '退出登录与删除本机账号：我 → 设置（退出登录、切换账号）。',
      ],
    },
    {
      heading: '九、未成年人',
      paras: [
        '本服务面向具备完全民事行为能力的用户。若您未满法定年龄，请在监护人的同意与指导下使用本服务，并由监护人阅读本政策。我们不会主动收集未成年人的个人信息；如发现已收集，我们会尽快删除。',
      ],
    },
    {
      heading: '十、安全措施',
      paras: [
        '客户端与服务端之间的通信使用 HTTPS 与加密 WebSocket，音视频媒体经加密通道传输；登录凭据与本地数据在本机加密保存；我们按最小必要原则申请权限，并通过访问控制与内部审计限制人员对数据的接触。',
        '请注意，互联网环境不存在绝对安全。如发生安全事件，我们会按照法律要求及时告知您并向有关机关报告。',
      ],
    },
    {
      heading: '十一、本政策的更新与联系我们',
      paras: [
        '我们可能在功能变化或法律要求变化时更新本政策。更新后的政策将在本页面公布并标注更新日期；涉及处理目的、处理方式或信息类型等重大变更时，我们会以客户端内提示等合理方式另行告知。',
        '如您对本政策有任何疑问，希望查阅、更正或删除自己的信息，或进行投诉，可以通过以下方式联系我们：',
      ],
      items: ['电子邮箱：support@gracelink.cc', '客户端内：我 → 设置 → 帮助与关于 → 帮助中心'],
    },
  ],
  closing: ['本政策有中文与英文两个版本。两者如有歧义，以中文版本为准。'],
};

/* ------------------------------------------------------------------ English */

const termsEn: LegalDoc = {
  title: 'Gracelink Terms of Service',
  lede: [
    'These Terms of Service ("these Terms") govern the installation and use of the Gracelink instant-messaging client software and the related services (together, "the Service"), and are entered into between Gracelink Team ("we", "us") and you ("you", "the user"). These Terms take effect when you register an account or otherwise start using the Service.',
    'Please read these Terms in full before registering. By registering, signing in or using the Service you confirm that you have read, understood and accepted all of these Terms. If you do not agree, please do not register for or use the Service.',
  ],
  sections: [
    {
      heading: '1. The Service',
      paras: [
        'The Service consists of client software and our server side. The client is currently available for Windows desktop, Android and macOS; the iOS version is in development (expected in January 2027). The server side — accounts, message delivery, multi-device sync, audio/video call relay, file storage and the Discover section — is operated and maintained by us. The client contains no server-side software.',
        'Main features: one-to-one and group chat (text, emoji, images, files and voice messages, with quoting, forwarding, recall and deletion), friends and contacts management, group management (announcements, owner and admins, group mute, group QR code, member management), one-to-one and multi-party group audio/video calls with screen sharing, signing in by scanning a QR code, switching between multiple accounts and a seven-language interface, plus the content services in the Discover section (Lingting music and Media articles).',
        'Features may differ between platforms and between versions. Features we add are also governed by these Terms.',
        'The Service is currently free of charge. We may introduce paid features or change what is free in future; we will give reasonable advance notice on this page and in the client. Features already released will not become chargeable retroactively, and you may choose not to use paid features.',
      ],
    },
    {
      heading: '2. Accounts',
      paras: [
        'An account is required to use the Service. To register you must provide a phone number or an email address that is genuine, valid and able to receive verification messages (depending on the registration method currently enabled on our servers), and set a password of 6 to 16 characters. You are responsible for keeping your registration information accurate, complete and up to date.',
        'Accounts are owned by us; you receive a right to use your account subject to these Terms. An account is for your own use (or for use by authorised members of your organisation); it may not be lent, given away, transferred, or traded in any way.',
        'Please keep your account and password safe. Sign-in credentials are stored in encrypted form on your device. You are responsible for any loss caused by others using your device, by disclosure of your credentials, by lending your account to someone else, or by not changing your password in time.',
        'If you notice that your account has been taken over, that there are unusual sign-ins, or that it is at any other security risk, change your password immediately and contact us as set out in section 10.',
        'You may ask us to close your account at any time under "Me → Settings → Account Security → Delete Account". Closure is irreversible: the account can no longer be signed into, its data is erased and cannot be restored. The same phone number or email address may register again afterwards, but the content and relationships of the closed account are not restored. Files already downloaded to your device and content you saved to your album or download folder are outside the scope of that erasure; please deal with them before you close the account.',
        'You may add and switch between several accounts on one device ("Me → Settings → Switch Account"). Each account keeps its own sign-in state, messages and settings; removing an account from the device only deletes that account\'s credentials and data stored locally, not the account itself.',
      ],
    },
    {
      heading: '3. Acceptable Use',
      paras: [
        'You must comply with the laws and regulations of your country or region and with these Terms. In particular, you must not:',
      ],
      items: [
        'use the Service to create, copy, publish or spread unlawful information or content that infringes the lawful rights of others;',
        'harass, defraud, insult or threaten others, or impersonate anyone or falsify the origin of information;',
        'use the Service for gambling, fraud, pyramid schemes, illegal fundraising, the sale of prohibited goods or other unlawful activity, or spread the private information of others or disclose it without authorisation;',
        'record, publish or spread the content of calls, voice messages or chats without the other party\'s consent;',
        'send bulk unsolicited messages, register accounts or add friends in bulk, use automated tools to operate the Service at scale, or scrape or otherwise misuse server data;',
        'interfere with or attack our servers, the network or other people\'s devices, or probe for vulnerabilities, carry out penetration testing or otherwise endanger the security of the Service;',
        'reverse engineer, decompile, crack or modify the Service; remove, obscure or alter any name, logo or copyright notice in the software; or repackage, rent, sell or otherwise make the Service, or a modified version of it, available to any third party.',
      ],
    },
    {
      heading: '4. Enforcement and Reporting',
      paras: [
        'You are responsible for the content you publish, send and store. If your conduct breaches these Terms or the law, we may — depending on the circumstances — warn you, restrict certain features, restrict your ability to post, or suspend or terminate the Service for that account. Where a criminal offence may be involved, we will report it to the competent authorities as required by law and cooperate with them.',
        'If you believe that another user\'s conduct or content in the Discover section infringes your lawful rights, please contact us as set out in section 10 with the necessary explanation and supporting material. We will look into it and act as required by law.',
      ],
    },
    {
      heading: '5. Content and Intellectual Property',
      paras: [
        'Content you send or upload through the Service (messages, images, files, voice messages, profile information) belongs to you or to the relevant rights holder. In order to deliver messages, keep your devices in sync, show chat history and carry out calls, you authorise us to store, transmit and process that content to the extent necessary to provide the Service. See the Privacy Policy for details.',
        'The software, interface, icons, trade marks, text and documentation of the Service are owned by us or by the relevant rights holder. You may not copy, modify, distribute or otherwise use them without our written consent.',
        'The Service includes third-party open-source components such as Flutter. Those components are provided under their own licence terms; the relevant notices are included in the files distributed with the software or on the components\' project pages.',
        'Articles and other content in the Discover section may come from third parties or from users; the rights belong to the original author or publisher. We make no warranty as to their accuracy, completeness or availability. Pages outside Gracelink that you open in the in-app browser are governed by those sites\' own terms and privacy policies.',
      ],
    },
    {
      heading: '6. Privacy and Data',
      paras: [
        'We handle your personal information in accordance with the Privacy Policy. The Privacy Policy and these Terms together form the agreement between you and us regarding the Service; for the specific rules on personal information, the Privacy Policy prevails.',
        'To deliver messages, keep devices in sync and carry out audio/video calls, messages, files and call data are processed by our servers or by relay servers we designate, and are stored to the extent necessary to provide those features.',
        'Chat history, contacts and group information, sign-in state and settings are also stored on the device you use (on Windows in the current user\'s data directory, under %APPDATA%; on macOS in the app\'s own container, ~/Library/Containers/cc.gracelink.im/; on Android in the app\'s private storage). Please back them up yourself; uninstalling the software does not delete this data automatically. Section 7 of the Privacy Policy explains how to remove it completely.',
      ],
    },
    {
      heading: '7. Changes, Interruption and Termination',
      paras: [
        'We may adjust the features and interface of the Service, or retire part of it, for maintenance, upgrades, deployment changes or product planning. Except in emergencies we will try to give advance notice.',
        'The Service depends on the network, your device and third-party services and may be delayed or interrupted because of network failures, the device environment, system settings, third-party outages, events beyond our control or necessary maintenance. We will do our best to restore it.',
        'You may stop using the Service and uninstall the software at any time; section 8 explains how.',
        'If you seriously or repeatedly breach these Terms, we may suspend or terminate the Service for you.',
      ],
    },
    {
      heading: '8. Updates and Uninstalling',
      paras: [
        'We release new versions from time to time to fix problems, improve performance or add features. The client can check for updates and download the installer; once you confirm the installation of a new version, these Terms as supplied with it apply.',
        'How to uninstall: on Windows, use "Me → About Gracelink → Uninstall Gracelink" in the client, or uninstall Gracelink in Windows "Settings → Apps"; on macOS, move Gracelink from Applications to the Trash; on Android, uninstall the app the usual way.',
      ],
    },
    {
      heading: '9. Disclaimer',
      paras: [
        'The Service is provided "as is". To the maximum extent permitted by law, we give no express or implied warranty as to its fitness for a particular purpose, its continued availability or its freedom from errors.',
        'Messages and calls may be delayed, interrupted or lose data because of network conditions, the device environment, system settings, maintenance or upgrades, or events beyond our control. Do not use the Service for emergency rescue, medical or life-safety purposes.',
        'To the maximum extent permitted by law, we are not liable for indirect losses, loss of data or loss of profit arising from the use of, or the inability to use, the Service.',
        'Nothing in this section excludes or limits any liability that cannot be excluded or limited by law.',
      ],
    },
    {
      heading: '10. Contacting Us',
      paras: ['If you have any questions, comments or complaints about these Terms, you can reach us in the following ways:'],
      items: [
        'Email: support@gracelink.cc',
        'In the client: Me → Settings → Help and About → Help Centre',
      ],
    },
    {
      heading: '11. Changes to These Terms and Governing Law',
      paras: [
        'We may update these Terms to reflect changes in the law, the product or our operations. The updated Terms will be published on this page with a revised date; where a change materially affects your rights we will additionally give notice in the client. Continuing to use the Service after an update means you accept the updated Terms.',
        'These Terms are governed by and construed in accordance with the laws of your country or region. If any provision is held invalid or unenforceable, the remaining provisions remain in effect.',
      ],
    },
  ],
  closing: [
    'These Terms are available in Chinese and in English. If the two texts differ in meaning, the Chinese text prevails.',
    'If these Terms conflict with the software licence statement shown during installation, these Terms prevail as regards your use of the Service.',
  ],
};

const privacyEn: LegalDoc = {
  title: 'Gracelink Privacy Policy',
  lede: [
    'This Privacy Policy explains what information Gracelink Team ("we", "us") collects when you use the Gracelink client software and related services ("the Service"), how we use and retain it, who we share it with, and how you can manage it.',
    'It applies to the Gracelink clients (Windows desktop, Android and macOS, and the iOS version once released), this website, and the servers we operate. Please read it in full before use; continuing to use the Service means you have read and understood it.',
  ],
  sections: [
    {
      heading: '1. What We Collect',
      paras: ['We collect only what is necessary to provide the Service:'],
      items: [
        'Account and profile: the phone number or email address you register with (depending on the registration method enabled on our servers) and your password (stored encrypted), plus the nickname, avatar, name, email address, signature and gender you choose to provide.',
        'Content you create while using the Service: the messages you send and receive (text, emoji, images, video, files, voice messages), your friend and group relationships, group announcements and group settings, and the upload records needed to send that content.',
        'Call information: signalling and call state (who started the call, when it was answered and ended, who took part, mute and screen-sharing state), the network addresses and relay credentials needed to establish a call, and network and quality data during the call. Audio and video content is only relayed; we do not record or store it.',
        'Device and log information: device model and manufacturer, operating system and version, client version, the device push token (used to deliver offline messages and incoming-call alerts to your device), network type and IP address, sign-in times and operation records, and error and crash logs.',
        'Information corresponding to permissions: collected only while you use the relevant feature — see section 2.',
      ],
    },
    {
      heading: '2. Permissions and Why We Ask for Them',
      paras: [
        'Every permission the client requests maps to a specific feature. You can turn any of them off in your system settings at any time; the corresponding feature then stops working while the others are unaffected.',
      ],
      items: [
        'Camera: video calls, and scanning QR codes (including reading a QR code from your album);',
        'Microphone: audio and video calls, and recording voice messages;',
        'Storage and album: choosing and sending images and files, saving received images to your album and files to your download folder;',
        'Notifications: new-message alerts, incoming calls and group-call invitations, including the "call in progress" notice;',
        'Network and device state, battery-optimisation exemption: keeping the connection alive during calls and while running in the background, so the system\'s power saving does not cut it off;',
        'Screen recording (macOS): requested only when you start sharing your screen, so your display can be sent into the call — never recorded in the background.',
      ],
    },
    {
      heading: '3. How We Use This Information',
      paras: ['We use the information we collect only for the following purposes:'],
      items: [
        'Providing and maintaining the Service: delivering messages, syncing across your devices, setting up audio/video calls, uploading and downloading files, delivering offline message and incoming-call alerts, and checking for and installing updates;',
        'Accounts and security: registration and sign-in (including signing in by QR code), identity verification, changing and recovering passwords, closing accounts, detecting unusual sign-ins and preventing account theft, spam and abuse;',
        'Customer support: responding to the questions and complaints you raise through in-app feedback or email;',
        'Improving the Service: analysing feature usage and error logs to diagnose faults and improve performance and usability;',
        'Complying with the law: handling information as required by laws, regulations or competent authorities, or where necessary to assert or defend legal claims.',
      ],
    },
    {
      heading: '4. Sharing and Service Providers',
      paras: [
        'We do not sell your personal information and we do not use the content of your chats for advertising. The client contains no third-party advertising or marketing SDKs.',
        'To provide the Service we engage the following third parties to process information on our behalf. They may only process it on our instructions and for the agreed purposes, and they are bound by confidentiality obligations:',
      ],
      items: [
        'Cloudflare: audio/video call media relay and group-call service. Call media is forwarded through their servers and is not written to disk there;',
        'Google Firebase Cloud Messaging: a device push channel used when the client is closed or in the background, to deliver new-message alerts, incoming calls and group-call invitations;',
        'Hosting, bandwidth and content-delivery providers: hosting the server software, file storage and static assets such as this website.',
      ],
    },
    {
      heading: '5. What We Do Not Do',
      items: [
        'We do not sell or rent your personal information;',
        'We do not use your chat content, contacts or call content for advertising or marketing;',
        'We do not read your camera, microphone or album in contexts unrelated to the features;',
        'We do not restrict unrelated features because you declined an optional permission;',
        'Except as described in section 4, we do not provide your personal information to any third party without your consent.',
      ],
    },
    {
      heading: '6. Storage and Retention',
      paras: [
        'The content you create and your account information are stored on our servers; those servers, and the cloud infrastructure behind them, may be located outside your country or region.',
        'We retain information for the shortest period necessary for the purposes described in this policy, unless the law requires otherwise. When you close your account we delete or anonymise its profile and content; anything we must keep in order to comply with the law, handle a dispute or cooperate with a competent authority is deleted once the statutory period expires.',
        'Messages you send also exist in the recipient\'s account and on their device. Deleting your own copy does not delete what the other party has already saved.',
      ],
    },
    {
      heading: '7. Data on Your Device and How to Remove It',
      paras: [
        'To allow offline reading and fast loading, chat history, contacts and group information, sign-in state and settings are stored on the device you use: on Windows in the current user\'s data directory (under %APPDATA%); on macOS in the app\'s own container (~/Library/Containers/cc.gracelink.im/); on Android in the app\'s private storage, which other apps cannot read.',
        'Uninstalling the software does not delete this data automatically. After uninstalling on Windows, remove that user data directory in your file manager if you want it gone completely; on macOS, remove the container as well; on Android, uninstalling through the system removes the app data too.',
        'Sign-in credentials stored on the device are encrypted. Please do not let untrusted people use your device, and avoid signing in on public or untrusted computers.',
      ],
    },
    {
      heading: '8. Your Rights and Controls',
      paras: ['You can manage your own information in the client:'],
      items: [
        'Access and correction: Me → Settings → Profile (nickname, avatar, name, email, signature, gender and more);',
        'Change your password: Me → Settings → Account Security → Change Password (your current password is required; accounts verified by email can also use an email verification code);',
        'Close your account: Me → Settings → Account Security → Delete Account (irreversible — please deal with your local files and saved content first);',
        'Withdraw permissions: turn off camera, microphone, album or notification access in your system settings;',
        'Remove data from your device: see section 7;',
        'Sign out and remove a local account: Me → Settings (Sign out, Switch Account).',
      ],
    },
    {
      heading: '9. Minors',
      paras: [
        'The Service is intended for users with full legal capacity. If you are below the age of legal majority, please use the Service with your guardian\'s consent and guidance, and have your guardian read this policy. We do not knowingly collect personal information from minors; if we learn that we have, we will delete it promptly.',
      ],
    },
    {
      heading: '10. Security',
      paras: [
        'Communication between the client and our servers uses HTTPS and encrypted WebSocket, and call media travels over encrypted channels. Sign-in credentials and local data are stored encrypted on your device. We request permissions on a least-privilege basis and limit staff access to data through access controls and internal audit.',
        'Please note that no internet environment is absolutely secure. If a security incident occurs, we will notify you and report it to the competent authorities as required by law.',
      ],
    },
    {
      heading: '11. Changes to This Policy and Contacting Us',
      paras: [
        'We may update this policy when the features or the legal requirements change. An updated policy will be published on this page with a revised date; where the change affects the purposes, the methods or the types of information involved, we will additionally give notice in the client.',
        'If you have any questions about this policy, wish to access, correct or delete your information, or want to make a complaint, you can reach us in the following ways:',
      ],
      items: ['Email: support@gracelink.cc', 'In the client: Me → Settings → Help and About → Help Centre'],
    },
  ],
  closing: [
    'This policy is available in Chinese and in English. If the two texts differ in meaning, the Chinese text prevails.',
  ],
};

/* ------------------------------------------------------------------ 导出 */

export const TERMS: Record<Lang, LegalDoc> = { zh: termsZh, en: termsEn };
export const PRIVACY: Record<Lang, LegalDoc> = { zh: privacyZh, en: privacyEn };
