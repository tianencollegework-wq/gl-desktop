# Gracelink 官网方案（待确认，未开工）

> 这份文档只是**方案**，一行官网代码都还没写。目标读法：先看第 0 节的结论，
> 再看第 2 节（语言自动识别怎么做才不出错，这是你最关心的一条），
> 然后看第 9 节要你拍板的四件事。

---

## 0. 结论摘要

* **做法**：做一个**静态优先的双语营销站**，路径分语言（`/zh/`、`/en/`），
  根路径做一次**服务端语言协商**（认不出来落 `/en/`，即英文为默认），
  手动切换用 cookie 记住、之后不再被浏览器语言覆盖。
  这套就是 **WhatsApp 官网的实测做法**，也是唯一能同时满足「自动识别」+
  「兜底英文」+「SEO 不串」的姿势（见第 2 节）。
* **栈**：Astro + Tailwind（静态产出）→ 部署到边缘平台，用一段边缘函数做根路径协商。
  备选：Next.js + Vercel middleware（gravity 索引推荐 Vercel）；不建议纯 Next 静态导出。
* **首发范围**：首页 + 下载页（含版本号/校验和/四平台），法律两页复用现有协议文案。
  功能页、更新日志、帮助中心放二期。
* **顺手补的缺口**：`docs/release/windows-release.md` 发版清单第 8 步写的是
  「把 `dist\Gracelink-Setup-x.y.z.exe` 传到**下载页**」—— 而这个下载页目前**不存在**。
  官网正好把它补上，并让下载地址与 `update.json` 的 `url` 保持**同一个真源**。
* **一个需要你提前知道的现实**：官网（静态文件）放哪都好办，但**安装包（几十 MB）
  不建议放在前两者的默认产物里**；而且「**中国大陆访问快 + 大文件分发**」这件事，
  服务检索里没有任何候选能同时满足（原话：没有候选满足大陆可达性与大二进制分发），
  要大陆体验就必须走国内云 + 备案。见第 6 节。

---

## 1. 六个官网的实测结论

研究方法：先用文本抓取拿站点结构，再**开真实浏览器逐个加载**（390×844 手机视口 +
桌面视口），读 DOM、`<html lang>`、hreflang、响应头、脚本指纹与内联样式的实际背景色。
下表结论均为实测，不是推测。

| 站 | 前端 | 语言机制 | 语言默认 | 下载入口 | 视觉要点 |
|---|---|---|---|---|---|
| **WhatsApp** | 自有构建（`static.whatsapp.net/rsrc.php`，无 Next/Vue 指纹） | `<html lang="zh-Hans">`；根路径**服务端按 Accept-Language 出对应语言**，并**写入 cookie `wa_lang_pref=zh_cn`**；根路径响应头 `cache-control: private, no-cache, no-store, must-revalidate`、`Vary: Accept-Encoding`；**61 条 hreflang**，其中 `x-default` 与 `en` **都指向根域**；显式语言 URL 是 `?lang=xx` | 英文（根域 = 英文） | 桌面走 **Microsoft Store 安装器**（`get.microsoft.com/installer/download/...`）；移动/平板/桌面分三条路径；页内有二维码图 | 奶油底 `#FCF5EB` 整段铺色、超大字重标题、**绿色胶囊 CTA**、下划线的文字链接（「试试看 ›」）、页脚 60 项语言下拉 |
| **微信** | **Nuxt/Vue2**（`_nuxt/*.js` + `legacy` polyfill 包） | `<html lang="">`（**空**）、**无 hreflang**、无自动识别；导航右上角两个纯文字链接「WeChat (繁体) │ WeChat (EN)」 | 中文 | 每平台一个入口（Android/iOS/鸿蒙/Windows/macOS/Linux 各自子域），iOS 走 App Store | 整屏**品牌绿**、白色大字标 + 圆形半透明平台徽章阵列、版本动态列表（版本号 + 日期）、页脚备案信息 |
| **QQ** | **Vue3 SPA + hash 路由**（`polyfills-legacy.js`、`/index/#/`） | `lang="zh-CN"`、**没有英文版**（`/en/` 返回的仍是中文）、无语言切换 | 中文 | **exe 直链**：`qqdl.gtimg.cn/qqfile/QQNTV2/9.9.36/.../QQ_9.9.36_260924_x64_01.exe` | 移动端点开几乎只有一屏：**竖渐变条纹动态背景** + 巨大标题「轻松做自己」+ 白胶囊「下载」按钮 + 版本号 `v 9.9.36 2026-09-24` + 一排平台图标 |
| **Snapchat** | **Next.js**（`_next/static/chunks/pages/*` → Pages Router） | 自动出中文（`<html lang="zh-Hans">`，与 WhatsApp 同理）；该页**无 hreflang** | 英文（根域） | **AppsFlyer 智能跳转**：`click.snapchat.com/...&af_ios_url=apps.apple.com/...`（iOS 直落 App Store，未装则跳下载页） | 白底 + **亮黄胶囊**「Open Snapchat」、移动端**底部固定四宫格导航**（聊天/特效镜头/故事/聚光灯，直接复刻 App）、大量社交证明轮播、`next` 版 `video` ×4 |
| **0xchat** | **Vite + Vue SPA**，**Cloudflare** 托管（`cloudflareinsights` 指标） | `lang="en"`，**只有英文**，无切换 | 英文 | 「GET APP」→ `/download`（GitHub Release 分平台） | 纯黑 + 紫色、**等宽字体 + emoji** 终端风、「BREAKING」红色滚动条、紫色描边按钮、发光 logo。**扣分项：390px 下 hero 文案横向溢出被裁掉**（「decentrali…」「No c…」） |
| **Mosavi** | **Next.js App Router**（`main-app-*.js`）+ `next/font` 自托管 Manrope；**Caddy** 发静态文件（`vary: Accept-Encoding`，**不含语言**） | `lang="en"`，只有英文；右下角有悬浮「EN」+ 明暗主题切换控件 | 英文 | App Store / Google Play 图标直链（顶栏） | 亮绿整屏 hero + 白色大标题「THE CHANNEL OF FREE SPEECH」、白胶囊「Download Now」+ 圆形幽灵按钮「Watch Introduction」、**三台手机样机**展示聊天/群聊/视频通话 |

### 从六家抽出、直接决定我们方案的六条规律

1. **移动端首屏只有三样东西**：一句主张 + 一个下载按钮 + 平台图标。六家无一例外。
   手机访客不读长文，官网的第一职责是「一屏内让人装上 App」。
2. **「自动识别语言 + 兜底英文」只有国际产品在做**（WhatsApp / Snapchat），
   **中文产品一律不做**（微信/QQ 靠手动链接，甚至没有英文版）。
   你这个需求实质上是「**用国际产品的姿势服务中文用户**」，方案照第 2 节走即可。
3. **下载入口分三档**：直链 exe（QQ）、商店链接（Mosavi/微信 iOS）、
   **智能跳转**（Snapchat 的 AppsFlyer、WhatsApp 的 Microsoft Store 安装器）。
   我们要的是第一档 + 二维码（自有 Windows/Android 包，没有商店渠道）。
4. **下载区必须带版本号与日期**（QQ `v 9.9.36 2026-09-24`、微信版本动态列表）——
   用户用这个核对「我下的是不是最新」，也顺便解决了「安装包是不是最新」的信任问题。
5. **反面教材**：0xchat 在 390px 下横向溢出裁字。我们的验收里要有一条
   「320/390/768/1280 四个宽度下 `scrollWidth == clientWidth`」。
6. **隐私叙事要能兑现**。WhatsApp 把它放在「功能段」里讲（端到端加密），
   0xchat/Mosavi 把它当第一主张。我们写文案时**只能写实际做得到的**
   （见第 10 节的合规红线）。

---

## 2. 语言自动识别：怎么做才不出错（核心需求）

### 2.1 抄 WhatsApp 的哪一部分

WhatsApp 的实测行为拆开是这样的（我们的目标形态）：

```
访问 /            → 服务端协商：cookie 偏好 > Accept-Language 匹配 > 兜底英文
                    响应头 Cache-Control: no-store（同一 URL 不缓存，避免 CDN 串语言）
                    协商结果写入 cookie（wa_lang_pref=zh_cn）
访问 /zh/…        → 原样返回中文，不再根据浏览器语言改写
访问 /en/…        → 原样返回英文，同上
手动切语言        → 直接指向 /zh/ 或 /en/，并写 cookie
<hreflang>       → 每个语言版本互指，x-default 与 en 都指向根域
```

**关键点：`/en/` 必须是一个真实存在的静态页面**，不是「根路径跳过语言前缀」。
这样 `x-default`（英文）在搜索引擎与「JS 没跑起来」的情况下都成立，
这也是「判断不了默认英文」这句需求在工程上的落点。

### 2.2 判定顺序（写进代码的就是这一条链）

1. URL 里已带语言（`/zh/`、`/en/`）→ **原样服务，绝不改写**（否则用户分享的链接会跳语言）。
2. 有手动选择的 cookie（`gl_lang`）→ 用 cookie。
3. 读 `Accept-Language`，按 `q` 权重**只在我们支持的语言列表里匹配**：
   语言标签以 `zh` 开头（`zh`、`zh-CN`、`zh-Hans`、`zh-TW`…）→ `zh`；
   以 `en` 开头 → `en`；其余（`ja`、`de`、`fr`…）**不猜** → `en`。
4. 都没有 / 头缺失 / 解析失败 → `en`（**英文兜底**，与 `x-default` 一致）。

注意 `zh-TW` 也归 `zh`（首发只有简中，不假装有繁体；真要给繁体，就是第三条语言）。

### 2.3 五条最容易踩的坑（每条都有对应措施）

| 坑 | 后果 | 措施 |
|---|---|---|
| 同一 URL 按语言返回不同 HTML，却被 CDN 缓存成一份 | A 用户看到 B 语言 | 根路径跳转响应 **`Cache-Control: no-store`**（WhatsApp 的做法）；或让协商**只产出 302**，语言内容永远在 `/zh/`、`/en/` 这些不同 URL 上 |
| 用户手动选了中文，下次访问又被浏览器语言顶回英文 | 用户觉得「设置没用」 | 顺序里 cookie **优先于** `Accept-Language`（2.2 第 2 步） |
| 只在根路径做协商，却在**深层页面**也改写语言 | 分享链接失效、SEO 混乱 | 2.2 第 1 步：带语言的路径永不改写 |
| 边缘函数不支持时整站白屏 | 站长最怕的事 | 根路径本身就是一个**能独立站住的最小 HTML**（居中 logo + 「正在进入…/Redirecting…」+ 两个手点链接），JS 关掉也能走 |
| hreflang 写反/漏 `x-default` | 搜索引擎把英文页当重复内容 | 每个语言页各自输出完整的一组（含自指），`x-default` → `/en/`（或根域，二选一，全站统一） |

### 2.4 「判断不了就英文」在四个层面都要对齐

1. 协商兜底 → `en`；2. `x-default` → 英文页；3. 无 JS 时的根页 → 英文内容可见；
4. `<html lang>` 与 canonical 自指。四条都对齐，才算这条需求真做完。

---

## 3. 站点结构与页面清单

### 首发（M1）

**`/`（协商入口，no-store）** → 302 到 `/zh/` 或 `/en/`。

**首页（`/zh/`、`/en/`）**，区块顺序按第 1 节那六条规律定：

1. **顶栏**：左 logo（Gracelink / 恩信）、右「功能 · 下载 · 帮助」+ **语言切换（中/EN 两个文字链接，不用下拉）**。
   移动端只留 logo + 汉堡 + 下载按钮。
2. **Hero（一屏内解决）**：一句主张 + 一句说明 + **主 CTA「下载」** + 次 CTA「了解功能」。
   * 主张候选（中文）：「**连接，本该如此简单**」/「**说想说的，发想发的**」；
     英文对应 `Connects, simply.` / `Talk freely.` —— 具体文案等你定调。
3. **平台一行**：Windows / Android / iOS / macOS 四个图标，点进下载页。
4. **功能四段**（每段：一句标题 + 2~3 行说明 + 一张实拍/样机图，左右交错）：
   单聊与群聊、一对一/群组音视频通话、通讯录与群组管理、发现（资讯 · 灵听）。
5. **安全与隐私段**：只写能兑现的三条 —— 消息经服务器投递（明说不做端到端）、
   聊天记录存本机 `%APPDATA%`、卸载不删用户数据。**照现有 `license.txt` 的口径写，不要另起炉灶。**
6. **下载区**：四平台卡片 + 二维码（手机扫码）+ **版本号与日期**（规律 4）。
7. **页脚**：关于 / 服务条款 / 隐私 / 客服 / 备案号与版权（微信页脚那一套）。

**下载页（`/zh/download/`、`/en/download/`）**

* 四平台卡片：Windows（`Gracelink-Setup-x.y.z.exe`，标版本号 + 日期 + 文件大小）、
  Android（`app-release.apk`）、iOS（暂缺 → 显示「即将上线」而不是死链）、macOS（同上）；
* 每平台给 **SHA-256**（0xchat 的 GitHub Release 就这么做，对下载站的信任感很有用）；
* 一段「装完怎么登录」的说明（账号/扫码），移动端优先；
* 下载地址与 `update.json` 的 `url` 字段**同一批产物**（第 7 节）。

### 二期（M2，确认首发跑了再开）

* `/features/`（功能详情，首页四段的展开）；
* `/changelog/`（更新日志：可半自动 —— 发版时把 `CHANGELOG.md` 同步过来）；
* `/help/`（FAQ：怎么登录、怎么换设备、通话没声音怎么办 —— 这些我们踩过，有真东西可写）；
* `/legal/terms/`、`/legal/privacy/`（复用 `tool/installer/license.txt` 与
  `license-en.txt` 的九节结构，中英各一份，**以中文为准**那句照旧）。

---

## 4. 视觉方向：三个候选（要你选一个）

| 方向 | 长什么样 | 优点 | 缺点 | 出处 |
|---|---|---|---|---|
| **A. 暖色营销站**（推荐） | 奶油/米白底 + 超大字重标题 + 品牌绿胶囊 CTA + 图文分段 + 页脚密集链接 | 对中文大众用户最友好；能讲产品故事；移动端好做 | 需要 3~5 张高质量截图/样机图 | WhatsApp |
| **B. 品牌绿下载门户** | 整屏品牌绿 + 白色大字标 + 圆形平台徽章阵列 + 版本动态 | 实现最快、最省素材、一眼就是「来下载的」 | 没有产品叙事，功能说不清 | 微信 |
| **C. 深色加密风** | 纯黑 + 紫/青、等宽字体、终端感、发光 | 差异化强，契合「私密通讯」卖点 | 对非技术用户偏冷；容易做丑（0xchat 的移动端就溢出裁字） | 0xchat |

**推荐 A**：先用 A 把「这是什么 + 怎么装」讲清楚，把 C 的元素（深色段、发光）作为
**首个功能段的局部反色区块**用进去，既有辨识度又不牺牲可读性。

移动端硬性要求（来自六家的共同做法）：首屏只有 主张 + 下载按钮 + 平台图标；
底部可选一条**固定下载条**（滚动过半屏后出现）。

---

## 5. 技术栈

| 方案 | 语言机制怎么落 | 适合 | 代价 |
|---|---|---|---|
| **Astro + Tailwind（推荐）** | 内置 i18n 路由（`locales` + `defaultLocale` + `prefixDefaultLocale: true`），语言页构建期全部产出静态 HTML；根路径协商交给**平台边缘函数**（一段几十行的 JS） | 营销站、内容型页面、几乎零 JS 的产物、Markdown 写法律/FAQ 页 | 需要写一小段边缘函数；团队要学 Astro（很浅，半天） |
| Next.js App Router + Vercel middleware | 官方范式：`/[lang]` 动态段 + middleware 读 `Accept-Language` 重定向 | 若将来官网要带后台/账号体系 | **`output: 'export'` 下 middleware 不可用**；Vercel **Hobby 非商用**（官网是商业用途 → 要 Pro）；大陆访问差 |
| 纯手写 HTML/CSS + 边缘函数 | 全部自己写，hreflang/i18n 手工维护 | 极致可控、零依赖 | 双语 + hreflang + 更新日志全靠手改，长期维护成本最高 |

**推荐 Astro**，理由：产出是纯静态 HTML（大陆可访问性取决于托管，不取决于框架）、
双语路由是内置能力、法律/FAQ 用 Markdown 写方便公司其他人自己改、
和 Flutter 仓库无耦合（放在 `website/` 子目录，或独立仓库）。

**产物预算（验收项）**：首屏 JS < 150 KB（Astro 默认几乎没有 JS，很容易达标）、
图片全部 WebP + 显式 `width/height`（防 CLS）、字体子集化或系统字体栈
（不要像 WhatsApp 那样背一个自定义可变字体，中文字体子集很贵）。

---

## 6. 托管与下载分发

先说一个从服务检索拿到的**硬事实**：我按「静态站 + 双语协商 + 大陆可达 + 几百 MB
安装包托管」去检索，**没有任何候选同时满足大陆可达性与大二进制分发**
（检索原文：「没有候选满足大陆可达性的要求以及大二进制文件托管」）。
所以这件事必须**拆成两件事**分别选：

**(a) 官网静态站**
* **Cloudflare（Workers/Pages）**：免费、边缘函数能做协商、全球快、本环境可直接部署预览；
  大陆访问「一般」（不稳、可能被墙），但静态资源通常尚可。
* **Vercel**（检索推荐）：DX 最好，`middleware.ts` 里读 `Accept-Language` 就是官方范式；
  但 **Hobby 禁商用**、大陆访问差。
* **国内云（阿里云/腾讯云 OSS + CDN）**：大陆最快、最稳，**但需要 ICP 备案 + 实名**
  （有周期，要提前排）。

**(b) 安装包（`exe` 几十 MB、`apk` 几十 MB）**
* **不要**放在静态站的构建产物里（每次部署都重新上传，还占平台带宽）；
* 放**对象存储**（Cloudflare R2 / 阿里云 OSS / 腾讯云 COS），单独一个域名如
  `dl.gracelink.cc`，下载页只放链接；
* **与 `update.json` 的 `url` 字段指向同一批文件** —— 这是第 7 节的单一真源问题；
* 现阶段最快的做法：延续现状，把包放在 `message.gracelink.cc` 下面
  （App 的 `updateManifestUrl` 已经指向 `https://message.gracelink.cc/update.json`），
  官网只做链接，等下载量上来再上对象存储。

**域名**：App 的 API 是 `message.gracelink.cc`，官网建议 **`gracelink.cc`（根域）+
`www` 跳根域**，`message` 子域保持不动（不要动 API 域名，会牵动 `AppConfig` 与
`hostToken` 那套自检）。

---

## 7. 与 App 的对接（一个必须钉住的真源）

现状（`lib/data/api/update_api.dart`、`lib/data/model/app_update.dart`）：

```jsonc
// https://message.gracelink.cc/update.json
{ "android": {"version":"1.0.1","code":2123,"url":"…"},
  "ios": {…}, "windows": {…}, "macos": {…} }
```

* **官网下载页的 Windows/Android 按钮必须指向上表的同一个 `url`**，
  否则会出现「官网下的包」与「App 内更新推的包」不是同一版（`code` 对不上、
  装完又被提示更新，安卓甚至装不上）。
* 落地方式：**下载页在构建期读同一份 `update.json`**（保留 fallback 文案），
  页面上的版本号/日期/大小就永远与清单一致，不用手改两处。
* 发版清单 `docs/release/windows-release.md` 第 8 步「传到下载页」从此有了明确对象。

---

## 8. 分阶段与验收标准

**M1（首页 + 下载页，中英双语 + 自动识别）**
1. `curl -H 'Accept-Language: zh-CN' https://…/` → 302 到 `/zh/`；`en-US`/`ja`/无头 → `/en/`；
2. 手选语言后重访问根路径 → 尊重 cookie，不被浏览器语言顶回；
3. `/zh/xxx` 带语言路径**永不**被改写成 `/en/xxx`；
4. 每页 `<html lang>` 正确、hreflang 含自指与 `x-default`、canonical 自指；
5. 320 / 390 / 768 / 1280 四个宽度 `scrollWidth == clientWidth`（0xchat 的教训）；
6. 首页首屏 = 主张 + 下载按钮 + 平台图标；Lighthouse 移动端 Performance ≥ 90；
7. 下载页版本号/日期与 `update.json` 一致（加一条自动化用例钉住）。

**M2**：功能页 / 更新日志 / FAQ / 法律两页。
**M3（可选）**：官网带简易后台（更新日志与 FAQ 让非程序员改）、访问统计。

---

## 9. 素材待办（现在就能并行准备）

* `assets/images/logo.png` **549 KB** —— 官网上直接引用会拖慢首屏，
  需要**重导出**：SVG（首选，矢量缩放）+ WebP/PNG 各一档，以及 favicon 一套
  （仓库现在只有 `web/favicon.png` 一张）；
* **App 截图**：现在仓库里**一张都没有**（`assets/` 只有 logo、灵听 logo、空态图），
  Hero 与功能段需要 4~6 张真机/桌面截图（微信/WhatsApp/Mosavi 全靠这个）。
  建议统一角度与背景，做成 9:19.5 与 16:10 两套；
* 品牌色：待定（微信绿 / QQ 的紫蓝渐变 / Mosavi 亮绿 / 0xchat 紫黑都在那儿，
  建议定一个与 App 主题（`lib/core/theme/app_theme.dart`）一致的品牌色，
  官网与 App 不打架）。

---

## 10. 明确不做 / 风险

* **不吹做不到的加密**：App 的消息是**经服务器投递**（服务端能读），
  官网**不能**写「端到端加密」「服务器看不到你的消息」—— 这与
  `tool/installer/license.txt` 九节里的写法冲突，且有广告法/合规风险。
  要写就写「聊天记录存在本机、卸载不删、不经第三方」。
* **不做 61 国语言**：首发只有 `zh` + `en`，其余语言落 `en`（不猜、不跳空白页）。
* **不引入自定义中文字体**：中文字体子集化成本高于收益，用系统字体栈。
* **不改 API 域名**：`message.gracelink.cc` 与 `hostToken` 自检绑在一起。
* **风险**：`message.gracelink.cc` 与官网同机部署时的缓存/证书配置要分开
  （App 拉 `update.json` 必须拿到**不缓存的清单**，否则用户永远收不到更新提示 ——
  `windows-release.md` 已经点过一次这个坑）。

---

## 11. 要你拍板的四件事

1. **技术栈**：Astro（推荐）/ Next.js + Vercel / 纯手写 HTML？
2. **托管**：Cloudflare（本环境可即刻部署预览）/ Vercel / 国内云（要备案、大陆最快）？
3. **视觉方向**：A 暖色营销站（推荐）/ B 品牌绿下载门户 / C 深色加密风？
4. **首发范围**：只要 首页 + 下载页（推荐）/ 首页 + 下载 + 功能 + 法律一次做完？

拍完这四条我再开工。（研究过程中实际加载过的页面、
用于核对的脚本指纹与响应头，都记在第 1 节的表格里，可逐条复查。）

---

## 12. M1 已实施（2026-10-10）

拍板结果：**Astro + Tailwind** / **Cloudflare（本环境直接出预览）** /
**A 暖色营销站** / **首发 首页 + 下载页**。代码在 `website/`，怎么跑见
[`website/README.md`](../../website/README.md)。

**产物**：6 个静态页面（`/` 协商入口、`/zh/`、`/en/`、`/zh/download/`、
`/en/download/`、`404.html`），1 个 CSS、0 个外部 JS。

**已验过的**（都是真跑出来的，不是「应该可以」）：

* workerd 里 8 条协商用例（`zh-CN`→`/zh/`、`en-US`→`/en/`、`ja,de`→`/en/`、无头→`/en/`、
  `en;q=0.1,zh;q=0.9`→`/zh/`、cookie 压过浏览器语言、`/zh/` 不被改写、无斜杠补 307）；
* 部署后在预览域名上重跑同样几条，另外中英两页的 exe/apk 链接确认是**真能下**的
  （HTTP 206 + `application/octet-stream` / `vnd.android.package-archive`）；
* 浏览器端到端：访问 `/` 被 302 到 `/zh/` 并写 cookie；点 EN 后 cookie 变 `en`，
  再回 `/` 仍是英文；320/390/768/1280 四宽度无横向溢出；控制台零报错；
* `npm run verify` 93 项契约（语言属性、hreflang 三件套、canonical 自指、
  cookie 名与常量一致、产物里不许出现占位域名或 Markdown 星号…）。

**实施中撞到的两件事（方案里没预料到，已修）：**

1. **Cloudflare Assets 默认「静态资源优先」**：`dist/index.html` 存在时根路径的请求
   **不会进 Worker**，服务端协商根本不跑（`curl -H 'Accept-Language: zh-CN' /`
   返回的是静态页）。解法是 `assets.run_worker_first: true`（`website/wrangler.jsonc`）。
   部署环境实测确实按 Worker 优先跑。
2. **部署环境返回的是平台裸 404**，不是我们的 `dist/404.html`（`not_found_handling`
   在那个部署清单里表达不出来）。已在 Worker 里加一层：ASSETS 返回 404 且请求要 HTML 时，
   取回自己的 `404.html` 并保持 404 状态码；非 HTML 的请求仍返回裸 404。
3. **字典的 `as const` 把「缺键报错」变成了「每个值都报错」**：中文那份写了 `as const`
   之后类型是字面量（`'下载'`），英文的 `'Download'` 全都不可赋值 —— `astro check`
   **89 个错误**。而在此之前我只用“构建通过”当类型安全，一直没真跑过 `astro check`。
   修法是只钉**形状**不钉字面量（去掉 `as const`），现在 `astro check` 0 错，并且
   验证过护栏真会响：把 `en.nav.download` 改个名 → 报 1 个错、退出码 1。
   教训：**“构建通过”不等于“类型检查通过”**，两者都得跑。

**与方案的两处偏差（都是刻意的）：**

* `x-default` 指向 `/en/` 而不是根域（§2.1 记录了 WhatsApp 用根域）：根路径只有协商、
  没有内容，把 `x-default` 指一个真实存在的静态英文页对爬虫更稳。全站统一；
* 二维码是**构建期用 `qrcode` 生成的真码**（指向本站下载页），不是贴图。

**还没做的**：法律两页 / FAQ / 更新日志（M2）、访问统计（M3）；
iOS 与 macOS 的下载地址在服务端 `update.json` 里仍是 `example.com` 占位
（Windows 与 Android 已指向真实的 GitHub Release）—— 页面对占位地址显示「即将上线」，
绝不渲染死链；品牌 logo 的内联 SVG 待设计出矢量原件；App 真截图仍缺。

**当前状态**：预览环境 `https://site-312b741e8c044f55b6b1c85c8366a946.freebuff.page`
（站点 id `e3b741fc-5c81-4ca1-b428-2be5b3c4942f`）。**生产环境尚未发布**，
要发布得单独授权。重新部署：`npm run build` → `sites_deploy`（`website/deploy.manifest.json`）。

### 12.1 第一版上线后的修正（用户评审，2026-10-10 晚）

用户看完第一版提出的六条，已全部改完并重新部署：

1. **口号换成定稿的「让沟通更简单，让连接更真实」**（英文同步为
   *Simpler conversations, truer connections*）；「装好、登录、开始聊」那类口吻全删；
2. **平台图标换成官方品牌标**：Android 机器人、Apple（macOS）、App Store（iOS）、
   Windows 四格 —— 路径取自 `simple-icons`（CC0）。参考 0xchat 的下载页（他们用
   Font Awesome 那套 apple / android / windows）。第一版自画的「手机 / 笔记本」
   抽象字形是错的；
3. **用软件自己的 logo**：替掉我复刻的内联 SVG。字标跟语言走（中文「恩信」/
   英文 Gracelink），与 App 底部第一个 tab 一致。
   * ⚠️ 这里又错过一次：第一版拿的是 `web/icons/Icon-192.png`，那是
     `flutter create` 生成的**默认图**（文件时间 2026-06-19，与 iOS 的 `AppIcon`
     同一套像素，内容是 Flutter 自己的青色 logo）—— 用户 2026-10-10 又指出一次。
   * 现在由 `npm run logo`（`website/scripts/make-logo.mjs`）从
     **`assets/images/logo.png`**（940×940，App 的 `AppInfo.logoAsset`）生成
     `public/logo-96.png` / `logo-192.png` / `logo-512.png`，顶栏 / favicon /
     apple-touch 各用一档；部署后逐张比对过 md5，线上就是这份。
   * `verify-build.mjs` 新增「logo 不是 flutter create 的默认图」（像素差判据）：
     实测把默认图冒充成自己的 logo → 报红 + 退出码 1。
   * 遗留：源图是**白底不透明**的（底色是白的，不是透明 PNG），所以顶栏按
     “应用图标磁贴”展示（CSS 圆角 + 极淡描边）。要贴到奶油底上无白块，
     需要一份透明背景或矢量原件。
4. **手机样机重做**：颜色逐项取 `app_colors.dart`（顶部栏 `#EDEDED`、自己气泡
   `#95EC69` 黑字、未读 `#FA5151`、底部栏 `#F7F7F7`、选中 `#07C160`、次级灰 `#575B66`），
   结构逐页对齐：会话列表（头像方块 + 名字 + 预览 + 时间 + 红点）、对话、群通话、
   通讯录（四个彩色入口 + 字母分组）、发现（资讯 / 灵听）；**底部四个 tab 就是 App
   的那四个**（恩信 / 通讯录 / 发现 / 我，`shell_tabs.dart`）；
5. **删掉「说清楚数据放在哪」整段**（官网不摆自己的短板）；
6. **删掉版本号 / 内部号 / 校验和 / 「未签名会提示未知发布者」**：官网不是发版日志。
   `update.json` 仍读，但只用于决定链接与是否可下。

两类同批修掉的坑：

* **一次构建时的清单抓取超时**（3 秒单次尝试、四个页面各发一次请求）让整站回落到旧快照，
  四个平台全变成「即将上线」—— 部署后才发现。现已改成超时 8 秒 + 重试 2 次 +
  在 `globalThis` 上共享同一个请求，并把快照刷新成真实地址；同时加了
  **「至少一个平台真的可下载」**这条自检（实测会红 → 退出码 1）；
* `verify-build.mjs` 新增回归护栏：口号必须出现、真 logo 必须被引用、
  页面里不得出现版本号 / 自贬段落、手机样机里四个 tab 必须齐。

### 12.2 二期：法律两页 + 常见问题 + 部署到用户自己的 Cloudflare 账号（2026-10-10 晚）

用户当天的四条要求：① 服务条款与隐私政策**现在就写**（不是挂号）；② 中英双语；
③ 不写通用套话、按软件实际情况写、正式但不口语化（「像正经大公司」）；
④ 常见问题直接做起来；⑤ 顺便确认官网能不能**直接部署到 Cloudflare + 自己的域名**。
另外一条修正：**「更新日志」不是「即将上线」，是压根没准备做** —— 所以页脚那一项直接撤掉。

**新增六个页面**（产物 6 → 12 个）：`/zh/terms/`、`/en/terms/`、`/zh/privacy/`、
`/en/privacy/`、`/zh/faq/`、`/en/faq/`。正文写在 `src/content/legal.ts` 与
`src/content/faq.ts`，用显式接口 `LegalDoc` / `FaqDoc` 钉住两份语言的结构
（比 `ui.ts` 那套「en 的类型是 zh 的形状」更硬：缺一节直接编译不过）。

**「不写套话」在工程上落成三条**（这也是这三页最值钱的地方）：

1. **每一条都能在仓库里找到出处**，逐条列在两个 content 文件的顶部注释里。
   例如：注销不可恢复与「同一手机号可以重新注册」= `user.cancelIntro` /
   `cancelBullet2` / `cancelBullet3`；忘记密码**没有自助入口** = 登录页那颗
   「忘记密码」实际是切到密码登录的开关（`login_page.dart::_toggleForget`）；
   撤回时限由服务端 `redoTime` 决定 = `message_actions.dart::canUndo`；
   权限逐项 = `android/app/src/main/AndroidManifest.xml`；
   本机目录与「卸载不删」= 安装许可协议第五节 + `feature.item10`。
2. **不写做不到的**：明说「不在客户端做端到端加密」（消息需经服务器才能投递与多端同步），
   只写「存哪、存多久、谁能碰、怎么删」。verify 里有一条**反向**护栏钉住这句必须有。
3. **第三方处理者按真实的写**：Cloudflare（音视频媒体中转与群通话，来自 `SfuPaths`
   那套 SFU 代理）与 Google Firebase Cloud Messaging（推送，来自
   `android/app/google-services.json` 的 `project_id: gracelinkim-23da9`）；
   运营方沿用安装许可协议的口径（Gracelink Team），邮箱用用户指定的
   `support@gracelink.cc`（页脚、法律两页、FAQ 三处同一个口）。

**页脚**：撤掉「更新日志」，服务条款 / 隐私政策 / 常见问题改为真链接，支持栏给邮箱；
顶栏的「支持」从页脚锚点改成**直接进 FAQ**（页面的 `#support` 锚点保留）。

**verify-build.mjs**：原来那条「不许链到 terms/privacy/faq」的护栏**翻转**成
「必须链、且必须是真页面」（首版写它是因为那三页还不存在，留着等于禁止我们做对的事），
并新增内容事实检查。总数 93 → **210 项**。实测护栏真会响：把 `%APPDATA%` 从条款里
去掉 → 报红、退出码 1。

**部署**（站点从「只能在 Freebuff 的 Sites 上出预览」变成用户自己 Cloudflare 账号上的 Worker）：

* Worker 名 `gracelink-website`，`npx wrangler deploy`，Assets 走 `./dist`
  （`run_worker_first: true` 那一条在真环境里确实生效：根路径真的 302）；
* **`workers_dev: true` 必须显式写**：wrangler.jsonc 里一出现 `routes`，wrangler 默认
  就把 workers.dev 关掉 —— 第一次带 routes 部署时自定义域名绑失败、workers.dev 也没了，
  等于站上没有任何能访问的地址（这条是部署中真踩到的）；
* **自定义域名的硬条件**：主机名上不能有「外部管理」的 DNS 记录。`gracelink.cc` 有一条
  指向 `38.76.165.14`（与 `message.gracelink.cc` 同机）的 A 记录、`www` 一条指回根域的
  CNAME，Cloudflare 直接拒掉（错误码 100117）并要求先删；而 **wrangler 的 OAuth 凭据里
  没有 DNS 编辑权限**（`whoami` 列出的是 `zone (read)` / `ssl_certs (write)`，没有
  dns_records），所以这一步只能由用户在后台处理。在这之前，站点在
  `https://gracelink-website.29dliu.workers.dev` 上是可用的；
* **www → 根域**是 Worker 里的 301（`APEX_HOST` / `WWW_HOST`，并写死 https）。
  教训：`wrangler dev` 会把 `request.url` 的主机名改成本地地址，`curl -H 'Host: www.…'`
  与 `--resolve` 在本地都测不出这条分支（实测两种来源都是 `127.0.0.1`），
  代码里因此**同时读 `Host` 头**；真正的验证只能等域名绑好之后在 www 上打一发。

### 12.3 上线当天的两条修正（用户 2026-10-11）

**① 去掉「备案信息待补充」。** 底栏只留版权。官网托在 Cloudflare 上、不经大陆机房，
本来就不涉及 ICP；正式站点上留一句「待补充」比没有更难看。真要做大陆节点时再把
那一行加回来（那时才需要备案号）。

**② 应用内浏览器里的下载守卫（`DownloadGuard.astro`）。** 用户的原话：「下载页面
的下载按钮点击后不要直接跳转下载链接，先检测是否在微信环境，如果在微信环境就提示
用浏览器打开下载，不然容易把域名黑了」；随后又补了一条：「不只是微信环境，QQ 也一样，
软件内 webview 最好都提示让从浏览器打开下载」。这一条是真的：微信 / QQ 把「外链直接
下安装包」判成诱导下载，轻则当次拦掉、重则整个域名被拉黑 —— 而域名被拉黑之后**所有**
在微信里分享的链接都打不开，代价远超少一次下载；而很多其它 App 的内置浏览器本来
就没有下载安装包的能力（点下去没反应，用户只会以为官网坏了）。所以判定做成**通用**的
应用内浏览器识别，文案也不点名某一家。

做法与三个工程选择：

* 链接**不直接跳**：在 `document` 的**捕获阶段**用事件委托拦下载链接，判 UA 是不是
  应用内浏览器；是就 `preventDefault()` 并弹说明（带「复制下载地址」），
  不是就什么都不做 —— 正常浏览器里仍然是**一次点击直达**，不引入多余步骤；
* 判定分两层：① 各家 App 的 UA 标记（微信 `micromessenger`、企业微信 `wxwork`、
  **QQ `qq/`**、微博、钉钉、支付宝、抖音/头条系、小红书、快手、飞书…）；
  ② Android 的通用标记 `; wv)`（WebView）—— 绝大多数 App 的内置浏览器都带它，
  Chrome / Firefox / 三星浏览器这些真浏览器都不带。iOS 的内置 WebView 外观与
  Safari 一致、没有可辨识标记，只能靠第 ① 层；
* **不能用 `mqqbrowser` 认 QQ**：微信安卓版的 UA 里也有它，而独立的「QQ 浏览器」
  同样带它 —— 那是个真浏览器，能正常下载，拦了就是错的。钉 QQ 用带斜杠的 `qq/`；
* 除 `data-download` 外还认安装包后缀（`.exe/.apk/.dmg/.ipa`）：将来某处直接链了
  安装包而忘了写属性，也不会裸着点下去；
* 用委托而不是给每个按钮挂 onclick：下载入口有两处（首页平台卡、下载页卡片）且是
  按构建期清单渲染的，委托一次全覆盖；
* **不用 `Element.closest`**（微信 X5 内核版本很杂），手写向上遍历；
* 弹层可见性用**行内 `style.display`**，不用 `hidden` 属性：UA 的 `[hidden]` 与
  Tailwind 的 `.grid` 同为一档选择器权重，谁在后面谁赢，结果是「隐藏的弹层显示出来」。

`verify-build.mjs` 新增契约（共 **241 项**）：四个带下载链接的页面必须有
`data-download`、必须有各家的 UA 判定（`micromessenger` / `qq/` / `; wv)`）、
必须 `preventDefault()`、必须有后缀兜底，中英文案各自到位，以及「页面里不得再出现
备案占位」。

实测矩阵（本地 workerd + 线上 `gracelink.cc` 两处，改 `navigator.userAgent` 后点**真链接**）：
桌面 Chrome → 不拦，跳转照常；微信 → 拦（弹层出现、`location` 不变、弹层里就是那条 exe）；
QQ → 拦；**独立的 QQ 浏览器 → 不拦**（它是真浏览器）；通用 Android WebView（`; wv)`）→ 拦；
漏写 `data-download` 的 `.apk` 链接 → 拦（兜底生效）。

**③ 顺带修掉一个部署级问题：HTML 的缓存。** 部署新版之后实测边缘**仍在发旧 HTML**
（`curl https://gracelink.cc/zh/` 是改版前的页脚，带 `Cache-Control: no-cache` 才拿到新的，
换查询串也 HIT 同一份）。静态资源默认那个 `public, max-age=0, must-revalidate` 在这里
并不能保证「部署完就是新的」。现在 Worker 对 `text/html` 统一改成 `no-store`：页面每次
回源取（十几 KB，gzip 后几 KB，付得起），带内容哈希的 `/_astro/*` 不动。

**在真域名上（`gracelink.cc` / `www.gracelink.cc`，用户自己的 Cloudflare 账号）逐项验过的**：
根路径协商（`zh-CN`→`/zh/`、`en-US` / 无头 / `ja,de`→`/en/`，带 `no-store` 与
`Set-Cookie: gl_lang`）、12 个页面全部 200、不存在的路径回自己的 `404.html` 且状态码仍是 404、
`/zh/` 不被改写、`www` 上任何路径 301 到根域（路径与查询串一起带上）、TLS 正常、
canonical / hreflang 指向 `gracelink.cc`、下载按钮指向真实的 GitHub Release 安装包、
微信守卫在两个语言下都拦得住（改 UA 点真链接实测）、页脚不再有备案占位；
本地 237 项产物契约。

**还没验的**：**真机微信 / QQ**（本机只能改 `navigator.userAgent` 模拟，X5 内核上的
实际表现、以及「在浏览器打开」那个菜单的真实位置，得在微信 / QQ 里真点一次才算数）；
iOS / macOS 的下载地址（服务端清单里仍是 `example.com` 占位，页面上显示「即将上线」）。
