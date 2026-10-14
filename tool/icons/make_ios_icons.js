// 生成 iOS 的应用图标（`AppIcon.appiconset` 里那 15 张 PNG）与启动图
//（`LaunchImage.imageset` 里那 3 张）。
//
//   node tool/icons/make_ios_icons.js
//
// **为什么要有它**：`flutter create` 模板里那 15 张是 **Flutter 自己的青色图标**，
// 不换掉的话 iPhone 桌面上显示的不是我们的东西 —— macOS 那份
//（`tool/icons/make_macos_icons.js`）已经踩过一次同样的坑，iOS 这边一直没补。
// 启动图那 3 张更直接：模板给的是一张 **1×1 的透明图**（等于没有），
// 所以 App 一启动就是一片白，而我们自己的启动页是「白底 + logo + 转圈」——
// 把 logo 接上，启动那一下才不至于先白一下再「跳」出 logo。
//
// **源图**：`tool/audit/icon-fg.png`（与安卓那份同一个文件、与 macOS 那份同一张），
// 内容是不透明的蓝底座 **#008CFF** + 白色鸽形，四角透明、圆角约占 17%。
//
// 与 macOS 那三条**不一样的地方都是苹果的规矩，不是口味问题**：
//
// 1. **铺满画布**：macOS 的图标本体只占画布的 80%（824/1024，四周留空），那是
//    Mac 的图标网格；iOS 要满幅 —— 圆角与留白由系统的蒙版去做，我们交一张方图。
// 2. **不许有透明**：源图四角是透明的圆角，直接当 iOS 图标会被 App Store 拒
//    （「Invalid App Store Icon: … can't be transparent」）。所以用**同色**底座铺平
//    （`flatten`）：颜色与被盖住的那圈一模一样，看不出接缝。
// 3. **圆角也别自己画**：iOS 会再套一层自己的圆角，我们再画一层就是「圆里套圆」。
//    源图那 17% 的圆角在同色铺平之后等于不存在，视觉上和安卓那份仍是同一个标。
//
// 所以「三个平台同一个标」这件事在这里仍然成立：同一个源图、同一个蓝、同一只鸽子，
// 只是 iOS 这一份是方图（系统负责圆角），Android/macOS 那两份自带圆角。
//
// sharp 直接从官网那份借（`website/node_modules/sharp`）：不为了这个脚本再装依赖。
// 与 macOS 那份同一个写法（CommonJS + 绝对路径 require），改一处记得另一处一起看。
//
// ⚠️ 这个脚本**自带验收**：写完会把每张图读回来对尺寸、对「有没有 alpha 通道」、
// 对 1024 那张的角像素颜色 —— 苹果那两条硬要求（不透明、尺寸齐）当场就能看见。
const fs = require('fs');
const path = require('path');

const sharp = require(
  path.resolve(__dirname, '..', '..', 'website', 'node_modules', 'sharp'),
);

const ROOT = path.resolve(__dirname, '..', '..');
/// 图标那个标（蓝底 + 白鸽），与安卓 / macOS 同一张
const SRC = path.join(ROOT, 'tool', 'audit', 'icon-fg.png');
/// 启动图用**应用内那张 logo**（`AppInfo.logoAsset`）：启动页画的就是它
const LOGO = path.join(ROOT, 'assets', 'images', 'logo.png');
const OUT = path.join(
  ROOT,
  'ios',
  'Runner',
  'Assets.xcassets',
  'AppIcon.appiconset',
);
const LAUNCH_OUT = path.join(
  ROOT,
  'ios',
  'Runner',
  'Assets.xcassets',
  'LaunchImage.imageset',
);

/// 底座蓝（源图那个 #008CFF）：用来把四角铺平，也用来验收
const BASE = { r: 0x00, g: 0x8c, b: 0xff };

/// 文件名 → 像素。**必须与 `Contents.json` 一一对应**：
/// 少一张 Xcode 只会在编译时报一句「missing icon」，多一张则是白占体积。
const SIZES = [
  ['Icon-App-20x20@1x.png', 20], // iPad 通知 / 设置
  ['Icon-App-20x20@2x.png', 40], // iPhone 通知
  ['Icon-App-20x20@3x.png', 60], // iPhone 通知 @3x
  ['Icon-App-29x29@1x.png', 29], // 设置
  ['Icon-App-29x29@2x.png', 58],
  ['Icon-App-29x29@3x.png', 87],
  ['Icon-App-40x40@1x.png', 40], // iPad 聚焦
  ['Icon-App-40x40@2x.png', 80], // 聚焦
  ['Icon-App-40x40@3x.png', 120],
  ['Icon-App-60x60@2x.png', 120], // 主屏
  ['Icon-App-60x60@3x.png', 180],
  ['Icon-App-76x76@1x.png', 76], // iPad 主屏
  ['Icon-App-76x76@2x.png', 152],
  ['Icon-App-83.5x83.5@2x.png', 167], // iPad Pro
  ['Icon-App-1024x1024@1x.png', 1024], // App Store（审核用，必须不透明）
];

async function main() {
  const lines = [];
  for (const [name, size] of SIZES) {
    const file = path.join(OUT, name);
    // flatten = 把透明像素按给定颜色压平（`removeAlpha` 再补一刀：确保交出去的是
    // 没有 alpha 通道的 PNG —— 苹果认的就是「有没有那个通道」，不是「像素透不透」）
    await sharp(SRC)
      .resize(size, size, { fit: 'fill' })
      .flatten({ background: BASE })
      .removeAlpha()
      .png({ compressionLevel: 9 })
      .toFile(file);

    // ── 当场验收（下面这两条任意一条不成立，上架时都会被拒）──
    const meta = await sharp(file).metadata();
    if (meta.width !== size || meta.height !== size) {
      throw new Error(`${name} 尺寸不对：${meta.width}x${meta.height}，应为 ${size}`);
    }
    if (meta.hasAlpha) {
      throw new Error(`${name} 还带 alpha 通道 —— App Store 会拒（透明图标）`);
    }
    lines.push(
      `  ${name.padEnd(28)} ${`${size}×${size}`.padEnd(10)} ` +
        `${(fs.statSync(file).size / 1024).toFixed(1)}KB`,
    );
  }

  // 角像素：证明四角真的是那块蓝（不是黑、不是透明）。只查 1024 那张，其余是它的等比缩图。
  const { data } = await sharp(path.join(OUT, 'Icon-App-1024x1024@1x.png'))
    .raw()
    .toBuffer({ resolveWithObject: true })
    .then((buffer) => ({ data: buffer.data, info: buffer.info }));
  const corner = [data[0], data[1], data[2]].join(',');
  const expected = [BASE.r, BASE.g, BASE.b].join(',');
  if (corner !== expected) {
    throw new Error(`1024 那张的左上角是 ${corner}，应该是底座蓝 ${expected}`);
  }

  console.log(`写好 ${SIZES.length} 张 → ${path.relative(ROOT, OUT)}`);
  console.log(lines.join('\n'));
  console.log(`\n验收：尺寸全对、全无 alpha 通道、四角是底座蓝 ${expected} ✓`);

  await makeLaunchImages();
}

/// 启动图三张（1x / 2x / 3x）。
///
/// 尺寸按模板原本记的那个框（1x = 168，见 `LaunchScreen.storyboard` 里
/// `<image name="LaunchImage" width="168" height="185"/>`）—— 那个属性只是
/// Interface Builder 画布上的提示值，**运行时**是按图片自己的尺寸居中摆的，
/// 所以这里给 168/336/504 的方图就对了（我们的 logo 本身是 940×940 的方图）。
/// 与应用内启动页（`splash_page.dart` 里那个 180 的圆角方块）配在一起看，
/// 从启动图到大 logo 的那一下几乎看不出来。
async function makeLaunchImages() {
  const base = 168;
  const files = [
    ['LaunchImage.png', base],
    ['LaunchImage@2x.png', base * 2],
    ['LaunchImage@3x.png', base * 3],
  ];
  for (const [name, size] of files) {
    const file = path.join(LAUNCH_OUT, name);
    // 启动图**可以有**透明（白底是 storyboard 的 backgroundColor，不是像素）：
    // logo 自己的圆角就靠它露出来。所以这里不 flatten、不移除 alpha。
    await sharp(LOGO)
      .resize(size, size, { fit: 'contain' })
      .png({ compressionLevel: 9 })
      .toFile(file);

    const meta = await sharp(file).metadata();
    if (meta.width !== size || meta.height !== size) {
      throw new Error(`${name} 尺寸不对：${meta.width}x${meta.height}`);
    }
    console.log(`  ${name.padEnd(20)} ${`${size}×${size}`.padEnd(10)} 启动图`);
  }
  console.log(`写好 3 张 → ${path.relative(ROOT, LAUNCH_OUT)}`);
  console.log('验收：启动图尺寸全对（模板原来那三张是 1×1 的空图）✓');
}

main().catch((error) => {
  console.error('生成失败：', error.message || error);
  process.exitCode = 1;
});
