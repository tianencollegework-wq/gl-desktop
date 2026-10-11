// Build app icons / in-app logo from the supplied GraceLink source art.
//
//   node make_logo.js <src.png>
//
// The source is a light-blue gradient disc with a WHITE dove + wheat glyph and a
// "GraceLink" wordmark below it (which overlaps the disc's lower edge). Steps:
//   1. fit the disc as an ellipse from "blueness" (b - (r+g)/2) pixels;
//   2. extract the glyph as alpha = ramp(blueness): the glyph is neutral white
//      (~0) while even the palest disc pixel is >= 32, so the two separate cleanly;
//   3. cut off the wordmark: inside the disc the ONLY dark ink is that wordmark,
//      so the first run of dark rows marks its top edge (the dove ends at y=744,
//      the letters start at y=803) — everything below is dropped, which also kills
//      the pale halo the letters carry;
//   4. drop remaining specks smaller than AREA_MIN px (biggest stray was 41px,
//      while the smallest real part — the bird's eye — is 210px).
const fs = require('fs');
const path = require('path');
const { decode, encode } = require('./crop_png.js');

const SRC = process.argv[2] || 'build/probe/logo-src.png';
const ROOT = path.resolve(__dirname, '..', '..');

// blend of the brand blue for the icon tile: the dark end of the disc's gradient,
// nudged slightly deeper so the white glyph keeps ~3.9:1 contrast at 48px.
const TILE = [0x2e, 0x86, 0xc8];
const TILE_RADIUS = 0.22;      // rounded-square corner radius, same feel as the old logo
const GLYPH_FRACTION = 0.58;   // glyph max side / canvas (adaptive safe zone is 0.61)
const LO = 3, HI = 12;         // alpha ramp over blueness: <=LO opaque, >=HI transparent
const AREA_MIN = 150;          // drop connected components smaller than this

const src = decode(SRC);
const { w: SW, h: SH, ch: SCH, px: SPX } = src;
const at = (x, y) => {
  const i = (y * SW + x) * SCH;
  return [SPX[i], SPX[i + 1], SPX[i + 2]];
};
const blueness = (x, y) => { const [r, g, b] = at(x, y); return b - (r + g) / 2; };
const luma = (x, y) => { const [r, g, b] = at(x, y); return 0.299 * r + 0.587 * g + 0.114 * b; };

// --- 1. fit the disc (ellipse) -------------------------------------------------
let minX = SW, maxX = -1, minY = SH, maxY = -1;
for (let y = 0; y < SH; y++) {
  for (let x = 0; x < SW; x++) {
    if (blueness(x, y) > 25) {
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
}
const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
const ra = (maxX - minX) / 2, rb = (maxY - minY) / 2;
const inDisc = (x, y) => ((x - cx) / (ra - 3)) ** 2 + ((y - cy) / (rb - 3)) ** 2 <= 1;

// --- 2. where the wordmark starts (first run of dark rows inside the disc) -----
const darkRows = [];
for (let y = 0; y < SH; y++) {
  let n = 0;
  for (let x = 0; x < SW; x++) if (inDisc(x, y) && luma(x, y) < 100) n++;
  darkRows.push(n);
}
let wordmarkTop = SH;
for (let y = 0; y + 4 < SH; y++) {
  if (darkRows.slice(y, y + 5).every((n) => n > 3)) { wordmarkTop = y; break; }
}
const yCut = wordmarkTop - 4;
console.log('disc', { cx, cy, ra, rb }, 'wordmark top', wordmarkTop, '-> cut at y >=', yCut);

// --- 3. glyph alpha map -------------------------------------------------------
const alpha = new Float32Array(SW * SH);
for (let y = 0; y < yCut; y++) {
  for (let x = 0; x < SW; x++) {
    if (!inDisc(x, y)) continue;   // drops the white page background outside the disc
    const b = blueness(x, y);
    alpha[y * SW + x] = Math.min(1, Math.max(0, (HI - b) / (HI - LO)));
  }
}

// --- 4. drop stray specks -----------------------------------------------------
{
  const seen = new Uint8Array(SW * SH);
  const stack = [];
  for (let y = 0; y < SH; y++) {
    for (let x = 0; x < SW; x++) {
      const p = y * SW + x;
      if (seen[p] || alpha[p] <= 0.5) continue;
      const comp = [p];
      seen[p] = 1;
      stack.push(p);
      while (stack.length) {
        const q = stack.pop();
        const qx = q % SW, qy = (q - qx) / SW;
        for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
          const nx = qx + dx, ny = qy + dy;
          if (nx < 0 || ny < 0 || nx >= SW || ny >= SH) continue;
          const r = ny * SW + nx;
          if (seen[r] || alpha[r] <= 0.5) continue;
          seen[r] = 1;
          comp.push(r);
          stack.push(r);
        }
      }
      if (comp.length < AREA_MIN) for (const r of comp) alpha[r] = 0;
    }
  }
}

// --- 5. glyph bounding box ----------------------------------------------------
const T = 0.5;
let gx0 = SW, gx1 = -1, gy0 = SH, gy1 = -1;
for (let y = 0; y < SH; y++) {
  for (let x = 0; x < SW; x++) {
    if (alpha[y * SW + x] > T) {
      if (x < gx0) gx0 = x;
      if (x > gx1) gx1 = x;
      if (y < gy0) gy0 = y;
      if (y > gy1) gy1 = y;
    }
  }
}
const gw = gx1 - gx0 + 1, gh = gy1 - gy0 + 1;
console.log('glyph bbox', { gx0, gy0, w: gw, h: gh }, 'disc fill', (Math.max(gw, gh) / (2 * ra)).toFixed(3));

const sampleAlpha = (sx, sy) => {
  if (sx < 0 || sy < 0 || sx > SW - 1 || sy > SH - 1) return 0;
  const x0 = Math.floor(sx), y0 = Math.floor(sy);
  const x1 = Math.min(SW - 1, x0 + 1), y1 = Math.min(SH - 1, y0 + 1);
  const fx = sx - x0, fy = sy - y0;
  const a = alpha[y0 * SW + x0], b = alpha[y0 * SW + x1];
  const c = alpha[y1 * SW + x0], d = alpha[y1 * SW + x1];
  return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;
};

// --- 6. renderers -------------------------------------------------------------
function newCanvas(size) {
  return { size, px: Buffer.alloc(size * size * 4) };
}
// rounded-square coverage with 4x4 supersampling
function tileCoverage(size, x, y, radius) {
  const r = radius * size;
  let hits = 0;
  for (let sy = 0; sy < 4; sy++) {
    for (let sx = 0; sx < 4; sx++) {
      const px = x + (sx + 0.5) / 4, py = y + (sy + 0.5) / 4;
      const dx = Math.max(r - px, 0, px - (size - r));
      const dy = Math.max(r - py, 0, py - (size - r));
      if (dx * dx + dy * dy <= r * r) hits++;
    }
  }
  return hits / 16;
}
// white glyph, transparent background, max side = fraction * size, centred
function renderGlyph(size, fraction) {
  const c = newCanvas(size);
  const k = (fraction * size) / Math.max(gw, gh);
  const gcx = (gx0 + gx1 + 1) / 2, gcy = (gy0 + gy1 + 1) / 2;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const sx = gcx + (x + 0.5 - size / 2) / k;
      const sy = gcy + (y + 0.5 - size / 2) / k;
      const a = sampleAlpha(sx, sy);
      const i = (y * size + x) * 4;
      c.px[i] = 255; c.px[i + 1] = 255; c.px[i + 2] = 255;
      c.px[i + 3] = Math.round(a * 255);
    }
  }
  return c;
}
// blue rounded tile with the white glyph composited on top
function renderTile(size, fraction, radius) {
  const c = newCanvas(size);
  const glyph = renderGlyph(size, fraction);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 4;
      const ta = tileCoverage(size, x, y, radius);
      const ga = glyph.px[i + 3] / 255;
      const a = ta + ga * (1 - ta);
      for (let k = 0; k < 3; k++) {
        c.px[i + k] = a > 0 ? Math.round((TILE[k] * ta * (1 - ga) + 255 * ga) / a) : 0;
      }
      c.px[i + 3] = Math.round(a * 255);
    }
  }
  return c;
}
// opaque full-bleed tile (for iOS app icons, which must not carry alpha)
function renderFullBleed(size, fraction) {
  const c = newCanvas(size);
  const glyph = renderGlyph(size, fraction);
  for (let i = 0; i < size * size; i++) {
    const ga = glyph.px[i * 4 + 3] / 255;
    for (let k = 0; k < 3; k++) c.px[i * 4 + k] = Math.round(TILE[k] * (1 - ga) + 255 * ga);
    c.px[i * 4 + 3] = 255;
  }
  return c;
}
const save = (file, canvas) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, encode(canvas.size, canvas.size, 4, canvas.px));
  console.log('wrote', path.relative(ROOT, file), canvas.size + 'x' + canvas.size);
};

// --- 7. outputs ---------------------------------------------------------------
const res = path.join(ROOT, 'android/app/src/main/res');
const densities = [
  ['mdpi', 108, 48], ['hdpi', 162, 72], ['xhdpi', 216, 96],
  ['xxhdpi', 324, 144], ['xxxhdpi', 432, 192],
];
for (const [dpi, fg, legacy] of densities) {
  save(path.join(res, `mipmap-${dpi}/ic_launcher_foreground.png`), renderGlyph(fg, GLYPH_FRACTION));
  save(path.join(res, `mipmap-${dpi}/ic_launcher.png`), renderTile(legacy, GLYPH_FRACTION, TILE_RADIUS));
}
save(path.join(ROOT, 'assets/images/logo.png'), renderTile(512, GLYPH_FRACTION, TILE_RADIUS));

// --- 8. preview gallery (Preview tab serves only the html, so inline data URIs)
const uri = (canvas) => 'data:image/png;base64,' +
  encode(canvas.size, canvas.size, 4, canvas.px).toString('base64');
const fg432 = renderGlyph(432, GLYPH_FRACTION);
const legacy192 = renderTile(192, GLYPH_FRACTION, TILE_RADIUS);
const tiny48 = renderTile(48, GLYPH_FRACTION, TILE_RADIUS);
const zoomBottom = renderTile(192, GLYPH_FRACTION, TILE_RADIUS); // for the speck check panel
const html = `<!doctype html><meta charset="utf-8"><body style="margin:0;background:#f2f2f2;font:13px sans-serif;padding:16px">
<div style="display:flex;gap:28px;align-items:flex-start;flex-wrap:wrap">
  <div style="text-align:center"><div style="font-weight:600;margin-bottom:6px">自适应：背景 #2E86C8 + 前景</div>
    <div style="width:170px;height:170px;background:#2e86c8;display:inline-block">
      <img src="${uri(fg432)}" style="width:170px;height:170px"></div></div>
  <div style="text-align:center"><div style="font-weight:600;margin-bottom:6px">圆形蒙版</div>
    <div style="width:170px;height:170px;background:#2e86c8;border-radius:50%;overflow:hidden;display:inline-block">
      <img src="${uri(fg432)}" style="width:170px;height:170px"></div></div>
  <div style="text-align:center"><div style="font-weight:600;margin-bottom:6px">圆角方形蒙版</div>
    <div style="width:170px;height:170px;background:#2e86c8;border-radius:38px;overflow:hidden;display:inline-block">
      <img src="${uri(fg432)}" style="width:170px;height:170px"></div></div>
  <div style="text-align:center"><div style="font-weight:600;margin-bottom:6px">legacy 192px</div>
    <img src="${uri(legacy192)}" width="170" height="170"></div>
  <div style="text-align:center"><div style="font-weight:600;margin-bottom:6px">48px（原始/放大2倍）</div>
    <img src="${uri(tiny48)}" width="48" height="48" style="vertical-align:top;margin-right:6px">
    <img src="${uri(tiny48)}" width="96" height="96" style="image-rendering:pixelated;vertical-align:top"></div>
</div>
<div style="margin-top:22px;font-weight:600">杂点检查：legacy 192 下半部放大 3 倍（应只见鸽尾，无横向印子）</div>
<div style="width:576px;height:300px;overflow:hidden;position:relative;margin-top:8px;border:1px solid #ccc">
  <img src="${uri(zoomBottom)}" style="position:absolute;left:0;top:-288px;width:576px;height:576px;image-rendering:pixelated">
</div>
<div style="margin-top:22px;font-weight:600">应用内 512（白底卡片）</div>
<div style="background:#fff;display:inline-block;margin-top:8px;padding:12px">
  <img src="${uri(renderTile(512, GLYPH_FRACTION, TILE_RADIUS))}" width="170" height="170">
</div></body>`;
fs.writeFileSync(path.join(ROOT, 'build/probe/new_icon_preview.html'), html);
console.log('wrote build/probe/new_icon_preview.html');
