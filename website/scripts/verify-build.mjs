/**
 * 构建产物自检：`npm run build && npm run verify`。
 *
 * 这个脚本钉的是**方案的契约**（docs/website/plan.md §2.4 与 §8 的验收项），
 * 不是「跑起来不报错」：语言属性、hreflang 三件套、canonical 自指、
 * 不出现占位域名、两种语言真的各有各的页面、根页的 cookie 名与常量一致。
 *
 * 退出码非 0 = 契约破了（构建不算通过）。
 */
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const dist = `${root}dist`;

const failures = [];
const passed = [];

function check(name, condition, detail = '') {
  if (condition) passed.push(name);
  else failures.push(`${name}${detail ? ` — ${detail}` : ''}`);
}

function html(relative) {
  const path = `${dist}/${relative}`;
  if (!existsSync(path)) return null;
  return readFileSync(path, 'utf8');
}

// ---------------------------------------------------------------- 页面都在
const pages = {
  'dist/index.html': 'index.html',
  'dist/404.html': '404.html',
  'zh 首页': 'zh/index.html',
  'en 首页': 'en/index.html',
  'zh 下载页': 'zh/download/index.html',
  'en 下载页': 'en/download/index.html',
  'zh 服务条款': 'zh/terms/index.html',
  'en 服务条款': 'en/terms/index.html',
  'zh 隐私政策': 'zh/privacy/index.html',
  'en 隐私政策': 'en/privacy/index.html',
  'zh 常见问题': 'zh/faq/index.html',
  'en 常见问题': 'en/faq/index.html',
};
const loaded = {};
for (const [label, relative] of Object.entries(pages)) {
  const content = html(relative);
  loaded[label] = content;
  check(`页面存在：${label}`, content !== null, `缺 dist/${relative}`);
}

// ------------------------------------------------- 语言属性 / canonical / hreflang
// `path` 是语言前缀之后的路径片段：hreflang 那一组要按它拼（首页是空串）。
const expectations = [
  { label: 'zh 首页', lang: 'zh-Hans', canonical: 'https://gracelink.cc/zh/', path: '' },
  { label: 'en 首页', lang: 'en', canonical: 'https://gracelink.cc/en/', path: '' },
  { label: 'zh 下载页', lang: 'zh-Hans', canonical: 'https://gracelink.cc/zh/download/', path: 'download/' },
  { label: 'en 下载页', lang: 'en', canonical: 'https://gracelink.cc/en/download/', path: 'download/' },
  { label: 'zh 服务条款', lang: 'zh-Hans', canonical: 'https://gracelink.cc/zh/terms/', path: 'terms/' },
  { label: 'en 服务条款', lang: 'en', canonical: 'https://gracelink.cc/en/terms/', path: 'terms/' },
  { label: 'zh 隐私政策', lang: 'zh-Hans', canonical: 'https://gracelink.cc/zh/privacy/', path: 'privacy/' },
  { label: 'en 隐私政策', lang: 'en', canonical: 'https://gracelink.cc/en/privacy/', path: 'privacy/' },
  { label: 'zh 常见问题', lang: 'zh-Hans', canonical: 'https://gracelink.cc/zh/faq/', path: 'faq/' },
  { label: 'en 常见问题', lang: 'en', canonical: 'https://gracelink.cc/en/faq/', path: 'faq/' },
];

for (const { label, lang, canonical, path } of expectations) {
  const content = loaded[label];
  if (!content) continue;

  check(
    `${label}：<html lang="${lang}">`,
    new RegExp(`<html[^>]*lang="${lang}"`).test(content),
    '语言属性不对，爬虫与读屏软件都会读错',
  );

  check(
    `${label}：canonical 自指 ${canonical}`,
    content.includes(`<link rel="canonical" href="${canonical}"`),
    '双语站最常见的错：把译文页 canonical 到英文页',
  );

  // 一组 hreflang：zh-Hans / en / x-default（x-default 指英文页）
  for (const [hreflang, href] of [
    ['zh-Hans', 'https://gracelink.cc/zh/'],
    ['en', 'https://gracelink.cc/en/'],
    ['x-default', 'https://gracelink.cc/en/'],
  ]) {
    const expected = `${href}${path}`;
    check(
      `${label}：hreflang ${hreflang} → ${expected}`,
      content.includes(`hreflang="${hreflang}" href="${expected}"`),
      '语言版本没有互指，搜索引擎可能当成重复内容',
    );
  }
}

// ------------------------------------------------- 不能出现的东西
for (const [label, content] of Object.entries(loaded)) {
  if (!content) continue;
  check(`${label}：没有 example.com 占位链接`, !content.includes('example.com'));
  check(
    `${label}：没有把 Markdown 星号当正文打印出来`,
    !content.includes('**'),
    '字典里写了 **加粗** 但没人渲染 Markdown（首版真出现在了隐私段上）',
  );
  check(
    `${label}：没有「undefined / [object Object]」之类的漏字符`,
    !/undefined|\[object Object\]/.test(content),
  );
  // 2026-10-10 用户明确要求的两件事，做成回归护栏：
  check(
    `${label}：用了软件自己的 logo`,
    content.includes('src="/logo-96.png"'),
    'logo 由 scripts/make-logo.mjs 从 assets/images/logo.png 生成（96 / 192 / 512）',
  );
  check(
    `${label}：没有版本号 / 内部号 / 安装提示这类发版信息`,
    !/261008|内部号|Build<\/|checksum|SHA-256|Not code-signed|未签名|未知发布者/i.test(content),
    '官网不放发版日志（用户 2026-10-10 要求）',
  );
  check(
    `${label}：没有留下「备案信息待补充」这类占位`,
    !/备案信息待补充|Filing information to be added/.test(content),
    '2026-10-11 用户要求去掉（站点托在 Cloudflare 上，不涉及 ICP）',
  );
  check(
    `${label}：没有「说清楚数据放在哪」那类自贬段落`,
    !/说清楚数据放在哪|Where your data actually lives|做不到的承诺/.test(content),
    '官网不摆自己的短板（用户 2026-10-10 要求）',
  );
  check(
    `${label}：没有指向不存在的帮助页`,
    !/(href="[^"]*\/(legal|help)\/)/.test(content),
    '这些页面不存在，链接必须是灰色文字而不是 404',
  );
}

// ------------------------------------ 页脚的法律 / FAQ 链接必须真的落地（2026-10-10 起）
//
// 这是反向的护栏：首版（M1）这里有一条「不许链到 terms/privacy/faq」，因为那时它们
// 还不存在。三页做出来之后，那条护栏就该翻成「必须链，而且链的是真页面」——
// 留着旧的等于禁止我们做对的事。
for (const lang of ['zh', 'en']) {
  const content = loaded[lang === 'zh' ? 'zh 首页' : 'en 首页'];
  if (!content) continue;
  for (const slug of ['terms', 'privacy', 'faq']) {
    check(
      `${lang} 首页页脚链到 /${lang}/${slug}/`,
      content.includes(`href="/${lang}/${slug}/"`),
      '页脚没有可点的入口，等于这几页没人找得到',
    );
  }
  check(
    `${lang} 首页不再有更新日志条目`,
    lang === 'zh' ? !content.includes('更新日志') : !content.includes('Changelog'),
    '更新日志不做了（用户 2026-10-10），页脚不该再留一个灰色条目',
  );
}

// ------------------------------------------- 根页的 cookie 字面量与常量一致
const rootPage = loaded['dist/index.html'];
if (rootPage) {
  const consts = readFileSync(`${root}/src/consts.ts`, 'utf8');
  const cookieMatch = /LANG_COOKIE = '([^']+)'/.exec(consts);
  const maxAgeMatch = /LANG_COOKIE_MAX_AGE = (\d+)/.exec(consts);
  check(
    '根页脚本用的是 consts.ts 里的 cookie 名',
    !!cookieMatch && rootPage.includes(`'${cookieMatch[1]}'`),
    `consts.ts 是 ${cookieMatch?.[1]}，页面里没有`,
  );
  check(
    '根页脚本的 cookie 有效期与 consts.ts 一致',
    !!maxAgeMatch && rootPage.includes(String(maxAgeMatch[1])),
    `consts.ts 是 ${maxAgeMatch?.[1]}`,
  );
  check(
    '根页认不出语言时落英文',
    rootPage.includes("return 'en'"),
    'plan §2.4：兜底必须是英文',
  );
  check(
    '根页写 cookie 后跳转的是 /<lang>/',
    rootPage.includes("location.replace('/' + lang + '/')"),
  );
  // 边缘函数的那份判定要与页面同源（两个文件各写一遍，靠这条钉住）
  const worker = readFileSync(`${root}/worker/index.js`, 'utf8');
  check(
    'worker 的默认语言是 en',
    /DEFAULT_LOCALE = 'en'/.test(worker),
  );
  check(
    'worker 与页面用同一个 cookie 名',
    !!cookieMatch && worker.includes(`COOKIE_NAME = '${cookieMatch[1]}'`),
  );
  check(
    'worker 根路径响应带 no-store',
    /'cache-control': 'no-store'/.test(worker),
    'plan §2.3：同一 URL 换语言不能被 CDN 缓存成一份',
  );
  // 2026-10-11 实测：静态资源默认的 `public, max-age=0, must-revalidate` 在这个
  // 部署上有「部署完还命中旧 HTML」的现象（换查询串也 HIT 同一份），所以 HTML
  // 现在被 Worker 强制改成 no-store。这条钉住它别被改回去。
  check(
    'worker 对 HTML 强制 no-store（否则部署完边缘还在发旧页）',
    /contentType\.includes\('text\/html'\)/.test(worker) &&
      /headers\.set\('cache-control', 'no-store'\)/.test(worker),
  );
}

// --------------------------- 手动切语言必须记下选择（否则下次会被顶回去）
for (const { label } of expectations) {
  const content = loaded[label];
  if (!content) continue;
  check(
    `${label}：语言切换会写 cookie`,
    content.includes("a[data-lang-switch]") && content.includes('COOKIE + \'=\' + lang'),
    'plan §2.3：手选的语言要比浏览器语言优先',
  );
  check(
    `${label}：切换器带 data-lang-switch`,
    /data-lang-switch="(zh|en)"/.test(content),
  );
}

// ------------------- 移动端顶栏不能在 390 宽度下换行（实测踩到过）
const zhHome = loaded['zh 首页'];
if (zhHome) {
  check(
    '顶栏里的按钮与导航都标了 whitespace-nowrap',
    (zhHome.match(/whitespace-nowrap/g) ?? []).length >= 3,
    '宽度不够时按钮内换行会把顶栏撞成两行',
  );
  check(
    '中文页用的是定下的口号',
    zhHome.includes('让沟通更简单，让连接更真实'),
    '口号是「让沟通更简单，让连接更真实」，不能另创',
  );
  check(
    '中文页没有「装好、登录、开始聊」那种口吻',
    !/装好[，、]登录/.test(zhHome),
  );
  check(
    '底部的 tab 与 App 一致（恩信 / 通讯录 / 发现 / 我）',
    ['恩信', '通讯录', '发现', '我'].every((label) => zhHome.includes(label)),
  );
}
const enHome = loaded['en 首页'];
if (enHome) {
  check(
    '英文页用的是对应的口号',
    enHome.includes('Simpler conversations, truer connections'),
  );
}

// --------------------------------------- 两种语言的下载状态来自同一份清单
const zhDownload = loaded['zh 下载页'];
const enDownload = loaded['en 下载页'];
if (zhDownload && enDownload) {
  // 这条守卫是拿血的教训换的：构建时清单抓取一次超时 → 回落到旧快照 →
  // 四个平台全变「即将上线」，部署之后才发现。构建读不到清单时这里会红。
  const downloadable = (zhDownload.match(/href="https:[^"]+\.(exe|apk|dmg|ipa)"/g) ?? []).length;
  check(
    '至少一个平台真的可下载',
    downloadable > 0,
    '零个可下 = 构建时没读到官方清单（回落到占位快照），或清单四格都是占位地址',
  );
  const exeOf = (content) => /href="([^"]+\.exe)"/.exec(content)?.[1] ?? '';
  const apkOf = (content) => /href="([^"]+\.apk)"/.exec(content)?.[1] ?? '';
  check(
    '中英两页的 Windows 安装包地址一致',
    exeOf(zhDownload) === exeOf(enDownload),
    `${exeOf(zhDownload)} vs ${exeOf(enDownload)}`,
  );
  check(
    '中英两页的 Android 安装包地址一致',
    apkOf(zhDownload) === apkOf(enDownload),
    `${apkOf(zhDownload)} vs ${apkOf(enDownload)}`,
  );
}

// ------------------- logo 必须是软件自己的，不能是 flutter create 的默认图
//
// 这条是用户 2026-10-10 指出的问题：我一开始拿的是 `web/icons/Icon-192.png`，
// 那是 Flutter 自己的 logo（文件时间 2026-06-19，跟 iOS 的 AppIcon 一套像素）。
// 判据用像素差：两张图太像就说明源文件又拿错了。
try {
  const sharp = (await import('sharp')).default;
  const mine = await sharp(`${root}public/logo-192.png`).resize(32, 32, { fit: 'fill' }).raw().toBuffer();
  const flutterDefault = await sharp(`${root}../web/icons/Icon-192.png`)
    .resize(32, 32, { fit: 'fill' })
    .raw()
    .toBuffer();
  let diff = 0;
  const len = Math.min(mine.length, flutterDefault.length);
  for (let i = 0; i < len; i++) diff += Math.abs(mine[i] - flutterDefault[i]);
  const avg = diff / len;
  check(
    'logo 不是 flutter create 的默认图',
    avg > 12,
    `与 web/icons/Icon-192.png 的平均像素差只有 ${avg.toFixed(1)}（< 12 说明拿错了源文件）`,
  );
} catch (error) {
  check('logo 不是 flutter create 的默认图', false, `比对失败：${error.message}`);
}

// ------------------------------------------- 三页内容的硬性事实（不是文风检查）
//
// 这几条钉的是「写的东西与软件里真实存在的东西一致」：运营方与联系邮箱、本机数据
// 的位置、第三方处理者、注销入口、权限清单、以及「不做端到端加密」这条必须讲明
// 的事实（写了做不到的加密承诺才是真风险）。改文案时如果把这些事实弄丢了，这里红。
const zhTerms = loaded['zh 服务条款'];
const enTerms = loaded['en 服务条款'];
if (zhTerms) {
  check(
    '中文服务条款：写明运营方与联系邮箱',
    zhTerms.includes('Gracelink Team') && zhTerms.includes('support@gracelink.cc'),
  );
  check('中文服务条款：带更新日期', zhTerms.includes('最后更新'));
  check(
    '中文服务条款：写明账号注销不可恢复',
    zhTerms.includes('注销不可撤销') && zhTerms.includes('注销账号'),
  );
  check(
    '中文服务条款：写明本机数据与卸载不删',
    zhTerms.includes('%APPDATA%') && zhTerms.includes('卸载'),
  );
}
if (enTerms) {
  check(
    '英文服务条款：是英文正文且带同一个联系邮箱',
    enTerms.includes('Terms of Service') && enTerms.includes('support@gracelink.cc'),
  );
  check('英文服务条款：注明以中文版本为准', enTerms.includes('the Chinese text prevails'));
}

const zhPrivacy = loaded['zh 隐私政策'];
const enPrivacy = loaded['en 隐私政策'];
if (zhPrivacy) {
  check('中文隐私政策：写明本机数据位置（%APPDATA%）', zhPrivacy.includes('%APPDATA%'));
  check(
    '中文隐私政策：列出第三方处理者（Cloudflare / Firebase）',
    zhPrivacy.includes('Cloudflare') && zhPrivacy.includes('Firebase'),
    '音视频中转与推送确实交给这两家，必须披露',
  );
  check(
    '中文隐私政策：逐项说明权限用途（相机 / 麦克风 / 相册 / 通知）',
    ['相机', '麦克风', '相册', '通知'].every((key) => zhPrivacy.includes(key)),
    '权限说明要与 AndroidManifest 里真实申请的权限对得上',
  );
  check('中文隐私政策：给出注销账号与清除本机数据的入口', zhPrivacy.includes('注销账号'));
  check('中文隐私政策：写明通话不做录制留存', zhPrivacy.includes('不会对其进行录制或留存'));
}
if (enPrivacy) {
  check(
    '英文隐私政策：与中文写的是同一套事实（%APPDATA% / Cloudflare / Firebase）',
    enPrivacy.includes('%APPDATA%') &&
      enPrivacy.includes('Cloudflare') &&
      enPrivacy.includes('Firebase'),
  );
}

const zhFaq = loaded['zh 常见问题'];
const enFaq = loaded['en 常见问题'];
if (zhFaq) {
  check(
    '中文常见问题：用原生 <details> 折叠（不靠 JS）',
    (zhFaq.match(/<details/g) ?? []).length >= 15,
    `实际 ${(zhFaq.match(/<details/g) ?? []).length} 条`,
  );
  check('中文常见问题：带 FAQPage 结构化数据', zhFaq.includes('FAQPage'));
  check(
    '中文常见问题：覆盖六类问题',
    ['下载与安装', '账号与登录', '聊天与消息', '音视频通话', '发现', '隐私与数据'].every(
      (key) => zhFaq.includes(key),
    ),
  );
  check(
    '中文常见问题：讲明消息经服务器投递、不做端到端加密',
    zhFaq.includes('不在客户端做端到端加密'),
    '这是必须如实说明的一条，不能省成「加密传输」',
  );
  check(
    '中文常见问题：忘记密码指向真人通道而不是假的自助找回',
    zhFaq.includes('没有自助找回密码的入口') && zhFaq.includes('support@gracelink.cc'),
  );
}
if (enFaq) {
  check('英文常见问题：是英文正文', enFaq.includes('Frequently asked questions'));
  check(
    '英文常见问题：同样讲明不做端到端加密',
    enFaq.includes('does not use end-to-end encryption'),
  );
}

// ------------- 应用内浏览器里的下载守卫（2026-10-11 用户要求：不只微信，QQ 也一样）
//
// 安装包直链在 App 的内置浏览器里被点：微信 / QQ 这类会判成「诱导下载」（轻则当次
// 拦掉，重则整个域名被拉黑，那以后所有在微信里分享的链接都打不开），而很多内置
// 浏览器本来就没有下载能力。所以下载链接不直接跳，先判 UA。
// 这里钉住几件少一件就不成立的事：真链接带 `data-download`、页面里有各家的 UA
// 标记（含 `qq/` 与 Android WebView 的 `; wv)`）、判定为真时会 `preventDefault()`。
for (const label of ['zh 首页', 'en 首页', 'zh 下载页', 'en 下载页']) {
  const content = loaded[label];
  if (!content) continue;
  check(`${label}：安装包链接带 data-download`, content.includes('data-download'));
  check(
    `${label}：带应用内浏览器判定`,
    content.includes('micromessenger') &&
      content.includes("'qq/'") &&
      content.includes("'; wv)'") &&
      content.includes("getAttribute('data-download')"),
    '少了 UA 判定就拦不住，App 内置浏览器里还是直接下安装包',
  );
  check(
    `${label}：会拦住这次跳转（preventDefault）`,
    content.includes('event.preventDefault()'),
  );
  check(
    `${label}：兜底认安装包后缀（漏写 data-download 也不能裸着点）`,
    /\.\(exe\|apk\|dmg\|ipa\)/.test(content),
  );
}
if (loaded['zh 下载页']) {
  check(
    '中文页的提示文案是中文',
    loaded['zh 下载页'].includes('在浏览器打开') && loaded['zh 下载页'].includes('复制下载地址'),
  );
}
if (loaded['en 下载页']) {
  check(
    '英文页的提示文案是英文',
    loaded['en 下载页'].includes('Open in a browser') &&
      loaded['en 下载页'].includes('Copy download link'),
  );
}

// ------------------------------------------------- 产物是纯静态、没有 JS 洪水
const astroDir = `${dist}/_astro`;
if (existsSync(astroDir)) {
  const jsFiles = readdirSync(astroDir).filter((f) => f.endsWith('.js'));
  let total = 0;
  for (const file of jsFiles) total += readFileSync(`${astroDir}/${file}`).length;
  check(
    '首屏 JS 预算 < 150 KB（plan §5 的产物预算）',
    total < 150 * 1024,
    `实际 ${(total / 1024).toFixed(1)} KB`,
  );
}

// ------------------------------------------------------------------ 输出
for (const line of passed) console.log(`  ok   ${line}`);
if (failures.length > 0) {
  console.error(`\n构建自检失败 ${failures.length} 项：`);
  for (const line of failures) console.error(`  FAIL ${line}`);
  process.exit(1);
}
console.log(`\n构建自检通过（${passed.length} 项）。`);
