// 启动图资源生成（纯 Node，零依赖；复用 crop_png.js 的 PNG 编解码）。
//
// 产物两套，都来自 assets/images/logo.png（原图，逐字节不改）：
//
//  1. mipmap-*/launch_logo.png
//     给 Android 11 及以下：drawable-v21/launch_background.xml 里白底居中摆的整张图。
//     尺寸 100dp —— 和 Flutter 侧 SplashPage 的 `context.rpx(180)`（750rpx=屏宽，
//     主流 411dp 机器上约 99dp）对齐，两段启动图大小一样，不会跳一下。
//
//  2. mipmap-*/launch_logo_pad.png
//     给 Android 12+：系统强制启动屏会把图标按圆形蒙版裁掉
//     （官方规格：288dp 画布、可见区是直径 192dp 的圆 = 画布 66.7%）。
//     原图是白底方形，直接交上去四角和底下那行 GraceLink 会被切。
//     所以这里把原图缩到画布的 62%（< 66.7%，留一点余量），四周填透明 ——
//     蒙版只切到透明区，原图一个像素没少，只是整体小一圈。
//
// 用法：node make_launch_logo.js
const fs = require('fs');
const path = require('path');
const { decode, encode } = require('./crop_png.js');

const ROOT = path.resolve(__dirname, '../..');
const SRC = path.join(ROOT, 'assets/images/logo.png');

/** 五档密度的倍率（mdpi = 1×） */
const DENSITIES = [
  ['mdpi', 1],
  ['hdpi', 1.5],
  ['xhdpi', 2],
  ['xxhdpi', 3],
  ['xxxhdpi', 4],
];

/** ≤11 白底居中那张的显示尺寸（dp） */
const FLAT_DP = 100;
/** 12+ 图标的画布尺寸（dp）与其中原图所占比例 */
const PAD_DP = 192;
const PAD_RATIO = 0.62;

/**
 * 面积平均（box）缩放，按预乘 alpha 加权。
 *
 * 纯缩小用面积平均是最稳的（每个目标像素 = 源图上对应方块的加权均值），
 * 既不会像最近邻那样出锯齿，也不会像双线性那样在大倍率下丢细节；
 * 按预乘 alpha 加权则能避免透明边缘渗出黑边（12+ 那张图有透明区）。
 */
function resize(src, dw, dh) {
  const { w: sw, h: sh, ch } = src;
  const tmp = Buffer.alloc(dw * sh * ch);
  for (let y = 0; y < sh; y++) {
    for (let x = 0; x < dw; x++) {
      const x0 = (x * sw) / dw;
      const x1 = ((x + 1) * sw) / dw;
      let r = 0, g = 0, b = 0, a = 0, ws = 0;
      for (let i = Math.floor(x0); i < Math.ceil(x1); i++) {
        const wgt = Math.min(x1, i + 1) - Math.max(x0, i);
        if (wgt <= 0) continue;
        const si = (y * sw + i) * ch;
        const al = ch === 4 ? src.px[si + 3] / 255 : 1;
        r += src.px[si] * al * wgt;
        g += src.px[si + 1] * al * wgt;
        b += src.px[si + 2] * al * wgt;
        a += al * wgt;
        ws += wgt;
      }
      const di = (y * dw + x) * ch;
      const alpha = a / ws;
      if (alpha > 0) {
        tmp[di] = Math.round(r / ws / alpha);
        tmp[di + 1] = Math.round(g / ws / alpha);
        tmp[di + 2] = Math.round(b / ws / alpha);
      }
      if (ch === 4) tmp[di + 3] = Math.round(alpha * 255);
    }
  }
  const out = Buffer.alloc(dw * dh * ch);
  for (let x = 0; x < dw; x++) {
    for (let y = 0; y < dh; y++) {
      const y0 = (y * sh) / dh;
      const y1 = ((y + 1) * sh) / dh;
      let r = 0, g = 0, b = 0, a = 0, ws = 0;
      for (let i = Math.floor(y0); i < Math.ceil(y1); i++) {
        const wgt = Math.min(y1, i + 1) - Math.max(y0, i);
        if (wgt <= 0) continue;
        const si = (i * dw + x) * ch;
        const al = ch === 4 ? tmp[si + 3] / 255 : 1;
        r += tmp[si] * al * wgt;
        g += tmp[si + 1] * al * wgt;
        b += tmp[si + 2] * al * wgt;
        a += al * wgt;
        ws += wgt;
      }
      const di = (y * dw + x) * ch;
      const alpha = a / ws;
      if (alpha > 0) {
        out[di] = Math.round(r / ws / alpha);
        out[di + 1] = Math.round(g / ws / alpha);
        out[di + 2] = Math.round(b / ws / alpha);
      }
      if (ch === 4) out[di + 3] = Math.round(alpha * 255);
    }
  }
  return { w: dw, h: dh, ch, px: out };
}

/** 把 img 居中贴到透明画布上（画布边长 canvas，图占 round(canvas*ratio)） */
function pad(img, canvas, ratio) {
  const side = Math.round(canvas * ratio);
  const art = resize(img, side, side);
  const ch = img.ch;
  const px = Buffer.alloc(canvas * canvas * ch); // 全透明
  const off = Math.floor((canvas - side) / 2);
  for (let y = 0; y < side; y++) {
    art.px.copy(
      px,
      ((y + off) * canvas + off) * ch,
      y * side * ch,
      (y + 1) * side * ch,
    );
  }
  return { w: canvas, h: canvas, ch, px };
}

function main() {
  const src = decode(SRC);
  if (src.w !== src.h) {
    throw new Error(`原图不是正方形：${src.w}x${src.h}，留白居中会变形`);
  }
  const report = [];
  for (const [bucket, scale] of DENSITIES) {
    const dir = path.join(ROOT, 'android/app/src/main/res', `mipmap-${bucket}`);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

    const flatPx = Math.round(FLAT_DP * scale);
    const flat = resize(src, flatPx, flatPx);
    const flatFile = path.join(dir, 'launch_logo.png');
    fs.writeFileSync(flatFile, encode(flat.w, flat.h, flat.ch, flat.px));

    const padPx = Math.round(PAD_DP * scale);
    const rounded = pad(src, padPx, PAD_RATIO);
    const padFile = path.join(dir, 'launch_logo_pad.png');
    fs.writeFileSync(padFile, encode(rounded.w, rounded.h, rounded.ch, rounded.px));

    report.push({
      bucket,
      launch_logo: `${flatPx}x${flatPx}`,
      'launch_logo_pad(画布/原图)': `${padPx}x${padPx} / ${Math.round(padPx * PAD_RATIO)}`,
      bytes: fs.statSync(flatFile).size + fs.statSync(padFile).size,
    });
  }
  console.table(report);
  console.log(`源图：${src.w}x${src.h} ch=${src.ch}`);
}

main();
