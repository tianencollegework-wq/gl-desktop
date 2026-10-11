/**
 * 全站常量。改域名 / 改语言 / 改清单地址只改这里。
 */

/** 官网自己的域名（canonical、hreflang、二维码都用它） */
export const SITE = 'https://gracelink.cc';

/** 支持的语言。**顺序即下拉/切换器顺序**，第一个是默认语言（英文）。 */
export const LOCALES = ['zh', 'en'] as const;

export type Lang = (typeof LOCALES)[number];

/**
 * 默认语言 = 英文。
 *
 * 这是需求里写死的一条：**判断不出用户语言时显示英文**。
 * 它在四个地方都要对齐（见 docs/website/plan.md §2.4）：
 * 边缘协商的兜底、`x-default`、根路径无 JS 时的可见内容、`<html lang>`。
 */
export const DEFAULT_LOCALE: Lang = 'en';

/** `<html lang>` 的值：中文用 zh-Hans（与 App 的七套语言包口径一致） */
export const HTML_LANG: Record<Lang, string> = {
  zh: 'zh-Hans',
  en: 'en',
};

/** hreflang 的值（中文按简体标注） */
export const HREFLANG: Record<Lang, string> = {
  zh: 'zh-Hans',
  en: 'en',
};

/** 语言切换器上显示的名字（用**该语言自己**的写法） */
export const LANG_LABEL: Record<Lang, string> = {
  zh: '中文',
  en: 'EN',
};

export const LANG_NAME: Record<Lang, string> = {
  zh: '简体中文',
  en: 'English',
};

/** cookie 名：用户手动选过语言就记这里，之后优先于浏览器语言 */
export const LANG_COOKIE = 'gl_lang';

/** 记住一年 */
export const LANG_COOKIE_MAX_AGE = 31536000;

/**
 * App 的更新清单（与 `lib/data/api/update_api.dart::updateManifestUrl` 同一份）。
 *
 * 下载页在**构建期**读它，而不是让运维把版本号再手抄一遍到官网上——
 * 抄两遍必然漂（见 docs/website/plan.md §7）。
 */
export const UPDATE_MANIFEST_URL = 'https://message.gracelink.cc/update.json';

/** 产品对外名 */
export const PRODUCT_NAME = 'Gracelink';

/** 品牌绿（= App 的 `AppColors.green`，主按钮色） */
export const BRAND_GREEN = '#39B54A';

/** 白底上的绿色文字链接（= App 的 `AppColors.linkGreen`，微信实测那档深绿） */
export const LINK_GREEN = '#12744D';
