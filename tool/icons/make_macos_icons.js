// 生成 macOS 的应用图标（AppIcon.appiconset 里那七张 PNG）。
//
//   node tool/icons/make_macos_icons.js
//
// **为什么要有它**：`flutter create` 模板里那七张是 **Flutter 自己的青色图标**，
// 不换掉的话，Dock / 访达 / 「关于本机」里显示的都不是我们的东西 —— 官网那次已经
// 踩过一次同样的坑（见 `website/src/components/BrandMark.astro` 顶部的注释，
// `website/scripts/make-logo.mjs` 结尾还会拿像素差把这件事钉住）。
//
// **源图**：`tool/audit/icon-fg.png`。它本身就是**安卓那份启动图标**
// （432×432：不透明的蓝底座 **#008CFF** + 白色鸽形，四角透明、圆角约占 17%），
// 既当自适应图标的前景，也和渲染出来那版长得一样 —— 实测字形占位
// 0.273 / 0.368（fg）对 0.271 / 0.365（`icon-192.png`），同一个标。
// 所以这里**不再另画底座**：直接拿它缩放，安卓 / Windows / macOS 三边才是同一个东西。
//
// **尺寸按 Apple 的图标网格来**：1024 的画布里，图标本体 824×824（居中，四周留空）。
// 不这么做（直接铺满画布）的话，图标会顶满画布、在 Dock 里比邻居大一圈。
// 注意圆角仍然是源图那 17%，而不是 Apple 网格的 22.4% —— 这是**故意的**：
// 三个平台一致优先，真要改就回 `tool/probe/make_logo.js` 一起改。
//
// ⚠️ 鸽形在底座里**偏左上一点点**（占位 0.446 / 0.433，而不是 0.5 / 0.5），
// 安卓那份也是这样 —— 这里**不要**顺手居中，否则三个平台的标就不一样了。
//
// sharp 直接从官网那份借（`website/node_modules/sharp`）：不为了这个脚本再装依赖。
const fs = require('fs');
const path = require('path');

const sharp = require(
  path.resolve(__dirname, '..', '..', 'website', 'node_modules', 'sharp'),
);

const ROOT = path.resolve(__dirname, '..', '..');
const SRC = path.join(ROOT, 'tool', 'audit', 'icon-fg.png');
const OUT = path.join(
  ROOT,
  'macos',
  'Runner',
  'Assets.xcassets',
  'AppIcon.appiconset',
);

const CANVAS = 1024; // Apple 的图标画布
const TILE = 824; // 图标本体（画布的 80.47%）
const SIZES = [16, 32, 64, 128, 256, 512, 1024]; // 与 Contents.json 一一对应

async function main() {
  // 把源图缩到「图标本体」大小，贴到画布正中，其余尺寸都从这张主图缩下来
  const art = await sharp(SRC)
    .resize(TILE, TILE, {
      fit: 'contain',
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .png()
    .toBuffer();

  const offset = Math.round((CANVAS - TILE) / 2);
  const master = await sharp({
    create: {
      width: CANVAS,
      height: CANVAS,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([{ input: art, top: offset, left: offset }])
    .png({ compressionLevel: 9 })
    .toBuffer();

  const lines = [];
  for (const size of SIZES) {
    const file = path.join(OUT, `app_icon_${size}.png`);
    await sharp(master)
      .resize(size, size, { fit: 'fill' })
      .png({ compressionLevel: 9 })
      .toFile(file);
    lines.push(
      `  app_icon_${size}.png  ${size}×${size}  ${(
        fs.statSync(file).size / 1024
      ).toFixed(1)}KB`,
    );
  }
  console.log(`写好 ${SIZES.length} 张 → ${path.relative(ROOT, OUT)}`);
  console.log(lines.join('\n'));
}

main().catch((error) => {
  console.error('生成失败：', error);
  process.exitCode = 1;
});
