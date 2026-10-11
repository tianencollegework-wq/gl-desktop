# Gracelink 官网

双语（中文 / 英文）营销站，纯静态产出 + 一段边缘函数做语言协商。
方案与所有实测依据在 [`docs/website/plan.md`](../docs/website/plan.md)。

**默认语言是英文**：认不出浏览器语言时落 `/en/`（需求里明确的一条）。

## 跑起来

```bash
cd website
npm install

npm run dev        # Astro 开发服务器（根路径靠页面内脚本协商）
npm run build      # 产出 dist/（纯静态）
npm run verify     # 构建产物自检 241 项契约，非 0 = 不通过
npm run dev:edge   # 用 workerd 跑**真的**边缘协商（推荐，见下）
```

`npm run dev` 与 `npm run dev:edge` 的区别很重要：

* `astro dev` 只是静态开发服务器，**没有** `Accept-Language` 那条服务端协商；
* `wrangler dev` 起的是真的 workerd + Cloudflare Assets，`/` 会真的按请求头 302。
  发布前必须用这个验一遍。

## 语言自动识别怎么工作（三层，顺序一致）

| 层 | 位置 | 作用 |
|---|---|---|
| 边缘函数 | `worker/index.js` | 根路径 `/`：cookie `gl_lang` → `Accept-Language`（按 q 权重，只认 zh/en）→ **兜底英文**；302 带 `Cache-Control: no-store`，并写 cookie |
| 根页脚本 | `src/pages/index.astro` | 边缘函数不在时（纯静态托管、直接开 `dist/index.html`）用 `navigator.languages` 做同样判断 |
| 切换器 | `src/components/LangSwitcher.astro` + `BaseLayout` 里的内联脚本 | 手动切语言时**写 cookie**，之后访问根路径不再被浏览器语言顶回 |

带语言的地址（`/zh/…`、`/en/…`）**永远不会被改写** —— 分享出去的链接在别人那里也是同一种语言。

> ⚠️ `wrangler.jsonc` 里 `assets.run_worker_first: true` 是必须的：
> Cloudflare Assets 默认「静态资源优先」，`dist/index.html` 存在时根路径的请求
> **根本不会进 Worker**（本地第一次验证就撞上了：`curl -H 'Accept-Language: zh-CN' /`
> 返回的是那份静态页，不是 302）。若部署目标没法表达这个开关，根路径会退化成
> 由页面内脚本协商（结果一样，只是多一次客户端跳转）。

## 下载页的版本信息从哪来

构建期读 App 的那份清单 `https://message.gracelink.cc/update.json`
（与 `lib/data/api/update_api.dart` 同一个地址），三层来源：

1. `src/data/downloads.override.json` —— 人工覆盖（**默认不存在**；清单地址还没接好时用它）
2. 官方清单（构建期 fetch，3 秒超时）
3. `src/data/update.snapshot.json` —— 断网时的构建期快照

```jsonc
// src/data/downloads.override.json —— 只在需要时创建；至少填一格有 url 才算数
{
  "windows": { "url": "https://…/Gracelink-Setup-1.0.1.exe" }
}
```

页面上**只渲染**「哪个平台能不能下、点了去哪」：清单里的版本号 / 内部号一律
不往页面上放（用户 2026-10-10 的要求：官网不是发版日志）。

* 清单里 `url` 指向 `example.com` 一律当成「地址还没接」→ 页面上显示「即将上线」，
  **绝不渲染一个点了 404 的按钮**；构建日志里会打一条提醒；
* 离线构建：`DOWNLOAD_MANIFEST=snapshot npm run build`；
* 下载地址与 `update.json` 同源，就不会出现「官网下的包装完又被提示更新」（plan §7）。

## 目录

```
astro.config.mjs        静态产出 + Tailwind v4（@tailwindcss/vite）
worker/index.js         边缘函数：只管根路径语言协商，其余交给 ASSETS
wrangler.jsonc          本地 workerd 验证 / 部署参考
scripts/verify-build.mjs 构建产物自检（语言属性、hreflang、cookie、logo 来源…）
scripts/make-logo.mjs    从 assets/images/logo.png 生成 public/ 下的三个 web 尺寸
src/consts.ts           域名、语言、cookie 名、清单地址、品牌色
src/i18n/ui.ts          中英文字典（en 缺键 = 构建失败）
src/i18n/utils.ts       路径 / canonical / hreflang / 浏览器语言协商
src/content/legal.ts    服务条款 + 隐私政策正文（中英各一份，LegalDoc 类型钉住结构）
src/content/faq.ts      常见问题正文（中英各一份，FaqDoc 同上）
src/data/downloads.ts   下载数据（三层来源）
src/layouts/BaseLayout.astro  head 里的 canonical / hreflang / OG + 切换写 cookie
src/components/         顶栏、页脚、语言切换、平台图标、手机样机、功能段、下载卡、
                        LegalPage（法律页骨架）、FaqPage（原生 details 折叠）、
                        DownloadGuard（微信内置浏览器里的下载守卫）
src/pages/              index（协商入口）、zh/、en/、404、
                        {zh,en}/{terms,privacy,faq}
```

## 部署（到你自己的 Cloudflare 账号）

```bash
cd website
npm run build          # 产出 dist/（纯静态）
npm run verify         # 241 项产物契约，非 0 = 不通过
npx wrangler login     # 首次（本机已登录过就不必再跑）
npx wrangler deploy    # Worker + Assets 一起上传；域名见 wrangler.jsonc 的 routes
```

三个已经踩过的坑：

* **HTML 必须由 Worker 强制 `no-store`**。静态资源默认带
  `cache-control: public, max-age=0, must-revalidate`，看着像每次都会回源，
  但实际部署新版之后边缘**继续命中旧的那份 HTML** —— `curl https://gracelink.cc/zh/`
  还是改版前的页脚，带 `Cache-Control: no-cache` 请求头才拿到新的，换查询串也 HIT
  同一份（缓存键不含查询串）。已在 Worker 里对 `text/html` 统一改成 `no-store`；
  带哈希的 `/_astro/*` 不动；

* **`workers_dev: true` 必须显式写**。wrangler.jsonc 里一旦出现 `routes`，
  wrangler 会默认把 workers.dev 关掉 —— 第一次带 routes 部署时自定义域名没绑成、
  workers.dev 也一起没了，结果是站上没有任何地址。留着它还有个好处：
  能把「Worker 的问题」与「域名/DNS 的问题」分开排查；
* **自定义域名要求该主机名上没有「外部管理」的 DNS 记录**（Cloudflare 错误码 100117）。
  `gracelink.cc` 上原本有一条指向 `38.76.165.14`（与 `message.gracelink.cc` 同机）的
  A 记录、`www` 一条指回根域的 CNAME，必须先删掉才能绑 Worker；
  而 wrangler 的 OAuth 凭据里**没有 DNS 编辑权限**（只有 `zone (read)` / `ssl_certs (write)`），
  所以那一步只能在 Cloudflare 后台做。

`www` → 根域的 301 写在 Worker 里（`APEX_HOST` / `WWW_HOST`）。注意：
**`wrangler dev` 会把 `request.url` 的主机名改成本地地址**，所以 `curl -H 'Host: www.…'`
在本地测不出这条分支（实测两种来源都是 `127.0.0.1`）；它只能等域名真正绑好之后在
`https://www.gracelink.cc/` 上验。

## 验收（对应 plan §8 的 M1）

已经跑过的：

* `npm run check` → **0 errors / 0 warnings / 0 hints**（`astro check`，依赖
  `@astrojs/check` + `typescript` + `@types/node` + `@types/qrcode`，已写进 devDependencies）；
  * 字典护栏**验过并真的会响**：把英文那份的 `nav.download` 改个名 → 检查报 1 个错、退出码 1；
* `npm run build` → **12 个页面**（`/`、`/zh/`、`/en/`、两种语言的 `download` /
  `terms` / `privacy` / `faq`、`404.html`）；`npm run verify` → **241 项**全过；
  * 其中 15 条是 2026-10-10 新增的**内容事实检查**：%APPDATA% 本机目录、
    Cloudflare + Firebase 两个第三方处理者、权限四项（相机/麦克风/相册/通知）、
    注销不可恢复、FAQ 用原生 `<details>`、FAQPage 结构化数据、
    以及「不许声称端到端加密」这条（反向钉住：必须写明不做）；
  * 其中一条守卫是拿血的教训换的：**「至少一个平台真的可下载」**。
    构建时清单抓取超时一次 → 回落到旧快照 → 四个平台全变「即将上线」，
    部署之后才发现；现在这条会直接报红（已实测：把快照换成全占位版 → 退出码 1）；
* workerd 里的 8 条协商用例：`zh-CN`→`/zh/`、`en-US`→`/en/`、`ja,de`→`/en/`、
  无头→`/en/`、`en;q=0.1,zh;q=0.9`→`/zh/`、cookie 压过浏览器语言、
  `/zh/` 不被改写、`/zh/download`→补斜杠 307；
* 真实浏览器：访问 `/` 被 302 到 `/zh/` 并写 cookie；点 EN 后 cookie 变 `en`，
  再回 `/` 仍是英文（没被浏览器语言顶回）；
* **应用内浏览器里的下载守卫**（2026-10-11 用户要求：「不只是微信，QQ 也一样，
  软件内 webview 最好都提示从浏览器打开下载」）：把 UA 逐个换掉、点**真链接**实测，
  本地 workerd 与线上 `gracelink.cc` 两处都跑了一遍 ——

  | UA | 期望 | 实测 |
  |---|---|---|
  | 桌面 Chrome | 不拦，直接跳 | ✅ 跳转照常（官网在正常浏览器里**不多一次点击**）|
  | 微信（`MicroMessenger`）| 拦 | ✅ 弹层出现、`location` 不变、弹层里就是那条 exe |
  | QQ（`QQ/8.9.63…`）| 拦 | ✅ 同上 |
  | 独立的 QQ 浏览器（`QQBrowser/`）| 不拦（它是真浏览器，能下）| ✅ 跳转照常 |
  | 通用 Android WebView（`; wv)`）| 拦 | ✅ 弹层出现 |
  | 没写 `data-download` 的 `.apk` 链接 | 拦（兜底）| ✅ 弹层出现 |

  * **QQ 不能用 `mqqbrowser` 认**：微信安卓版的 UA 里也有它，而独立的「QQ 浏览器」
    同样带它 —— 钉 QQ 要用带斜杠的 `qq/`；
  * 注意：`wrangler dev` 无法伪造 UA 之外的环境，所以这一条是改
    `navigator.userAgent` 后点真链接跑的（真机微信 / QQ 上的 X5 内核仍建议自己点一次）；
* 320 / 390 / 768 / 1280 四个宽度 `scrollWidth == clientWidth`（无横向溢出）；
* 首屏 JS **0 字节**外部脚本（只有两段内联小脚本），1 个 CSS 文件。

## 待办

* 品牌标由 `npm run logo`（`scripts/make-logo.mjs`）从**软件自己的 logo**
  `assets/images/logo.png` 生成：`public/logo-96.png`（顶栏）/ `logo-192.png`（favicon）/
  `logo-512.png`（apple-touch）。改 logo 只需换源图再跑一遍这个脚本；
  * ⚠️ **不要用 `web/icons/Icon-192.png`**：那是 `flutter create` 生成的默认图
    （文件时间 2026-06-19，与 iOS 的 `AppIcon` 同一套像素），内容是 Flutter 自己的
    logo。这个坑真踩过（用户 2026-10-10 指出），现在 `npm run verify` 会拿像素差
    把这件事钉住——已实测：把默认图冒充成自己的 logo → 报红、退出码 1；
  * 源图是**白底不透明**的，所以顶栏按「应用图标磁贴」展示（CSS 圆角 + 极淡描边）；
    有透明背景或矢量原件时，直接把 `make-logo.mjs` 里那句 resize 换成你的即可；
* **App 截图一张都没有**：首屏与功能段的手机画面是 `PhoneMock.astro` 画的 ——
  颜色与结构逐项对齐 App（`app_colors.dart` 的配色、`shell_tabs.dart` 的四个 tab），
  有真机截图后直接换成 `<img>` 即可（布局不用动）；
* iOS / macOS 的下载地址在清单里还是 `example.com` 占位；
* 法律两页与 FAQ **已于 2026-10-10 落地**（`src/content/legal.ts` / `faq.ts`），
  内容逐条对应软件的真实行为，不要写成通用模板；
* **更新日志不做**（用户 2026-10-10：不是即将上线，压根没准备做）—— 页脚那一条已撤掉，
  别再把它加回来；
* 访问统计未接（`docs/website/plan.md` M3）。
