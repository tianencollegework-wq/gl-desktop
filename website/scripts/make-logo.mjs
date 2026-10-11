/**
 * 从**软件自己的 logo** 生成官网用的尺寸。
 *
 * 源文件是 `assets/images/logo.png`（940×940，透明背景）—— 也就是 App 里那个
 * `AppInfo.logoAsset`：登录页/启动页显示的就是它，2026-09-26 随品牌一起换过。
 *
 * 为什么不用 `web/icons/Icon-192.png`：那是 `flutter create` 生成的**默认图**
 * （文件时间 2026-06-19，与 iOS 的 AppIcon 同一套像素），即 Flutter 的 logo，
 * 不是我们的（用户 2026-10-10 指出过一次）。生成网页图标时**别再拿它**。
 *
 *   node scripts/make-logo.mjs
 *
 * 产出（都在 `public/` 下）：
 * * `logo-96.png` —— 顶栏用（显示 30–32px，2× 屏正好）
 * * `logo-192.png` —— favicon
 * * `logo-512.png` —— apple-touch-icon
 *
 * 关于背景：源图是**白底不透明**的（不是透明 PNG），所以这里是照原样缩的
 * “应用图标磁贴”——页面用 CSS 给它圆角当图标展示。想要贴到奶油底上无白块的
 * 版本，得让设计给一份透明背景或矢量原件，再把这里换成直接缩。
 *
 * 压缩开 `palette: true`：图本身不透明，调色板 PNG 体积小很多
 * （192 从 53 KB 降到 18 KB）。
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const root = fileURLToPath(new URL('../', import.meta.url));
const SOURCE = `${root}../assets/images/logo.png`;
const OUT_DIR = `${root}public`;

const targets = [
  { file: 'logo-96.png', size: 96 },
  { file: 'logo-192.png', size: 192 },
  { file: 'logo-512.png', size: 512 },
];

const source = readFileSync(SOURCE);
const meta = await sharp(source).metadata();
console.log(`源文件：assets/images/logo.png  ${meta.width}×${meta.height}  alpha=${meta.hasAlpha}`);

for (const { file, size } of targets) {
  const out = `${OUT_DIR}/${file}`;
  await sharp(source)
    .resize(size, size, { fit: 'contain' })
    // 源图不透明，palette 只会压掉没用的 alpha 通道、体积降一半
    .png({ compressionLevel: 9, palette: true })
    .toFile(out);

  const written = readFileSync(out);
  const writtenMeta = await sharp(written).metadata();
  const stats = await sharp(written).stats();
  const mean = stats.channels.slice(0, 3).map((c) => Math.round(c.mean));
  console.log(
    `  ${file.padEnd(14)} ${writtenMeta.width}×${writtenMeta.height}  ` +
      `${(written.length / 1024).toFixed(1)} KB  mean rgb(${mean.join(',')})`,
  );
}

// 自检：确认用的是软件自己的 logo，不是 `web/icons/` 里那套 Flutter 默认图。
// 判据是两张图的像素差异——若它们几乎一样，说明源文件拿错了。
const a = await sharp(source).resize(32, 32, { fit: 'fill' }).raw().toBuffer();
const b = await sharp(`${root}../web/icons/Icon-192.png`)
  .resize(32, 32, { fit: 'fill' })
  .raw()
  .toBuffer();
let diff = 0;
for (let i = 0; i < Math.min(a.length, b.length); i++) diff += Math.abs(a[i] - b[i]);
const avgDiff = diff / Math.min(a.length, b.length);
console.log(
  `\n与 web/icons/Icon-192.png（Flutter 默认图）的平均像素差：${avgDiff.toFixed(1)}` +
    (avgDiff < 12 ? '  ← 太小，源文件可能拿错了！' : '  ← 确认是两张不同的图'),
);
console.log('提示：`npm run verify` 会检查页面引用的是 /logo-96.png。');
