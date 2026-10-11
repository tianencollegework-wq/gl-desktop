/**
 * 边缘函数：**只干一件事** —— 根路径的语言协商，然后把静态资源交给 ASSETS。
 *
 * 判定顺序（与 `src/pages/index.astro` 里的客户端脚本、以及
 * `docs/website/plan.md` §2.2 完全一致）：
 *
 *   1. URL 已带语言（`/zh/…`、`/en/…`）→ **原样服务**，绝不改写；
 *   2. cookie `gl_lang`（用户手动选过）→ 用 cookie；
 *   3. `Accept-Language` 按 q 权重匹配 zh / en；
 *   4. 认不出来 / 头缺失 → **英文**（`DEFAULT_LOCALE`）。
 *
 * 两处刻意的细节：
 *
 * * 响应带 `Cache-Control: no-store`：同一个 URL 会因为语言返回不同的 302，
 *   被共享缓存复用就等于「A 用户被送到 B 语言」（plan §2.3 第一条）。
 *   WhatsApp 官网的根路径也是这个头。
 * * 只有根路径做协商。`/zh/download/` 这种明确的语言地址永远不会被改写，
 *   否则用户分享出去的链接会在别人那里换语言。
 */

const LOCALES = ['zh', 'en'];
const DEFAULT_LOCALE = 'en';
const COOKIE_NAME = 'gl_lang';
const COOKIE_MAX_AGE = 31536000;

/**
 * 官网自己的两个主机名（2026-10-10 起绑在用户自己的 Cloudflare 账号上）。
 *
 * `www` 上来的请求 **301 到根域**：同一个站点不该有两个地址 —— 搜索引擎会把
 * www 与非 www 当成两份内容，而 canonical、hreflang 与二维码里写的都是根域。
 * 其它主机名（`*.workers.dev`、部署平台的预览域名）原样服务，不做跳转：
 * 预览要能直接看，跳到一个还没生效的域名上是灾难。
 */
const APEX_HOST = 'gracelink.cc';
const WWW_HOST = `www.${APEX_HOST}`;

/** 从 Cookie 头里取手动选择（认不出返回空串） */
function localeFromCookie(cookieHeader) {
  if (!cookieHeader) return '';
  for (const part of cookieHeader.split(';')) {
    const index = part.indexOf('=');
    if (index === -1) continue;
    const name = part.slice(0, index).trim();
    if (name !== COOKIE_NAME) continue;
    let value = part.slice(index + 1).trim();
    try {
      value = decodeURIComponent(value);
    } catch {
      /* 坏编码就当原值用 */
    }
    return LOCALES.includes(value) ? value : '';
  }
  return '';
}

/**
 * 解析 `Accept-Language`：按 q 权重降序，取第一个我们支持的语言。
 *
 * `q=0` 表示「明确不要这个语言」，跳过；`*` 跳过（那是「随便」，
 * 交给默认语言决定）。认不出来就返回空串，让调用方落默认值。
 */
function localeFromAcceptLanguage(header) {
  if (!header) return '';
  const candidates = header
    .split(',')
    .map((part) => {
      const [tag, ...params] = part.trim().split(';');
      let q = 1;
      for (const param of params) {
        const match = /^\s*q\s*=\s*([0-9.]+)\s*$/i.exec(param);
        if (match) q = Number.parseFloat(match[1]);
      }
      return { tag: tag.trim().toLowerCase(), q: Number.isFinite(q) ? q : 1 };
    })
    .filter((entry) => entry.tag && entry.tag !== '*' && entry.q > 0)
    .sort((a, b) => b.q - a.q);

  for (const { tag } of candidates) {
    if (tag.startsWith('zh')) return 'zh';
    if (tag.startsWith('en')) return 'en';
  }
  return '';
}

/** 浏览器要的是 HTML 吗（`Accept` 里带 text/html 就算） */
function wantsHtml(request) {
  const accept = request.headers.get('accept') || '';
  return accept.includes('text/html') || accept.includes('*/*');
}

function negotiate(request) {
  const saved = localeFromCookie(request.headers.get('cookie'));
  if (saved) return saved;
  return localeFromAcceptLanguage(request.headers.get('accept-language')) || DEFAULT_LOCALE;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // www → 根域（301，保留路径与查询串）。放在协商之前：先归一到唯一的主机名，
    // 再谈语言，否则 www 上一次、根域上一次，cookie 与缓存都要多绕一圈。
    //
    // 主机名**两个来源都认**：真实边缘上 `url.hostname` 就是请求的主机名；
    // 但 `wrangler dev` 会把 url 的主机名改成本地地址（`127.0.0.1`），只有 `Host`
    // 头还留着客户端写的原值 —— 本地就靠它把这条分支真跑出来（本机
    // `curl --resolve www.gracelink.cc:8787:127.0.0.1 …` 实测：改走 Host 头
    // 之后才拿到 301，只信 url.hostname 时本地永远是 200）。
    //
    // 目标地址**写死 https**：这条分支只服务于绑定的自定义域名，而这些域名一定
    // 在 Cloudflare 上、一定走 https，没必要把 scheme 从原请求里继承下来。
    const host = (request.headers.get('host') || url.hostname).split(':')[0].toLowerCase();
    if (host === WWW_HOST) {
      return Response.redirect(
        `https://${APEX_HOST}${url.pathname}${url.search}`,
        301,
      );
    }

    // 只有根路径协商（`/` 与空路径）。
    if (url.pathname === '/' || url.pathname === '') {
      const lang = negotiate(request);
      const location = new URL(`/${lang}/`, url).toString();
      return new Response(null, {
        status: 302,
        headers: {
          location,
          'cache-control': 'no-store',
          // 记下这次判断：下次访问根路径直接听它的（与页面上的手动切换共用一个 cookie）
          'set-cookie': `${COOKIE_NAME}=${lang}; Path=/; Max-Age=${COOKIE_MAX_AGE}; SameSite=Lax`,
        },
      });
    }

    // 其余一律交给静态资源（`/zh/`、`/en/`、`/_astro/*`、favicon…）
    const response = await env.ASSETS.fetch(request);

    // 这个环境里所有请求都先进 Worker，所以静态资源命不中时拿到的是一张
    // 平台自带的裸 404（部署后实测：`/nope/` 返回 404，但不是我们那张
    // `dist/404.html`）。这里把它换成自己的 404 页：状态码仍是 404（不能是 200，
    // 否则搜索引擎会把不存在的地址当正常页收下），正文换成我们那张。
    if (response.status === 404 && wantsHtml(request)) {
      const fallback = await env.ASSETS.fetch(new URL('/404.html', url), { method: 'GET' });
      if (fallback.ok) {
        return new Response(fallback.body, {
          status: 404,
          headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' },
        });
      }
    }

    // **HTML 一律 no-store**（2026-10-11 实测后加的）。
    //
    // 背景：静态资源默认带 `cache-control: public, max-age=0, must-revalidate`，
    // 看着像「每次都会回源」，但部署新版之后实测边缘仍然继续命中旧的那份 ——
    // `curl https://gracelink.cc/zh/` 拿到改版前的页脚，只有带
    // `Cache-Control: no-cache` 请求头才拿到新版；而且换查询串也 HIT 同一份
    // （缓存键里不含查询串）。对「部署完就得是新的」这件事来说这是不能接受的。
    //
    // 代价：页面 HTML 不再由边缘缓存，每次回源取（本站十几 KB，gzip 后几 KB，
    // 完全付得起）；带内容哈希的 `/_astro/*` 不动 —— 它们的 URL 随内容变，
    // 缓存住正是想要的。
    const contentType = response.headers.get('content-type') || '';
    if (contentType.includes('text/html')) {
      const headers = new Headers(response.headers);
      headers.set('cache-control', 'no-store');
      return new Response(response.body, { status: response.status, headers });
    }

    return response;
  },
};
