/**
 * 语言路由的小工具。刻意不用框架的 i18n 魔法：
 * 每种语言的路径都是**真实存在的静态页面**（`/zh/…`、`/en/…`），
 * 这里只负责把 (语言, 页面) 拼成 URL、以及算 hreflang 那一组标签。
 */
import {
  SITE,
  LOCALES,
  DEFAULT_LOCALE,
  HREFLANG,
  HTML_LANG,
  LANG_COOKIE,
  LANG_COOKIE_MAX_AGE,
  type Lang,
} from '../consts';

/**
 * 页面在站内的路径片段：'' = 首页，'download' = 下载页，
 * 'terms' / 'privacy' / 'faq' = 法律两页与常见问题（2026-10-10 从「即将上线」
 * 变成真页面；更新日志不做，见 Footer 的注释）。
 */
export type Slug = '' | 'download' | 'terms' | 'privacy' | 'faq';

export function isLang(value: string | undefined): value is Lang {
  return !!value && (LOCALES as readonly string[]).includes(value);
}

/** 站内路径：`/zh/`、`/zh/download/`（每个都带尾斜杠，静态托管下最稳） */
export function pagePath(lang: Lang, slug: Slug): string {
  return slug === '' ? `/${lang}/` : `/${lang}/${slug}/`;
}

/** 绝对地址（canonical / hreflang / 二维码都用它） */
export function absoluteUrl(lang: Lang, slug: Slug): string {
  return `${SITE}${pagePath(lang, slug)}`;
}

/**
 * 一整组 hreflang 标签：两种语言各一条 + 自指 + `x-default`。
 *
 * `x-default` 指向**英文页**（而不是根域）：根路径是一个只做协商的跳转页，
 * 内容不在那里；`x-default` 指一个真实存在的静态页，爬虫与「JS 没跑起来」
 * 的两种情况都有东西可看。见 docs/website/plan.md §2.4。
 */
export function alternates(slug: Slug): { hreflang: string; href: string }[] {
  return [
    ...LOCALES.map((lang) => ({
      hreflang: HREFLANG[lang],
      href: absoluteUrl(lang, slug),
    })),
    { hreflang: 'x-default', href: absoluteUrl(DEFAULT_LOCALE, slug) },
  ];
}

/** `<html lang="…">` 的值 */
export function htmlLang(lang: Lang): string {
  return HTML_LANG[lang];
}

/** 另一个语言（语言切换器用） */
export function otherLang(lang: Lang): Lang {
  return lang === 'zh' ? 'en' : 'zh';
}

export { LANG_COOKIE, LANG_COOKIE_MAX_AGE };

/** 浏览器语言标签 → 站点语言：只认 zh 与 en 开头，其余落英文。 */
export function negotiateBrowserLangs(langs: readonly string[]): Lang {
  for (const raw of langs) {
    const tag = String(raw).trim().toLowerCase();
    if (tag.startsWith('zh')) return 'zh';
    if (tag.startsWith('en')) return 'en';
  }
  return DEFAULT_LOCALE;
}
