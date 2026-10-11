// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

/**
 * 官网是**纯静态**产出（`dist/` 全是 HTML/CSS/图片），
 * 语言协商那一段放在边缘函数里（见 `worker/index.js`）。
 *
 * `trailingSlash: 'always'` 是刻意选的：`/zh/`、`/en/download/` 这种形状
 * 在静态托管上没有「目录 vs 文件」的歧义，也和 canonical/hreflang 里
 * 写的地址完全一致（少一层「谁补斜杠」的追责）。
 */
export default defineConfig({
  site: 'https://gracelink.cc',
  trailingSlash: 'always',
  build: {
    // 每种语言的每个页面都产出真实的 index.html（不是 SPA 兜底）
    format: 'directory',
  },
  vite: {
    plugins: [tailwindcss()],
  },
});
