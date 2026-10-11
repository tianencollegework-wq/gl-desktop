// Template-match the supplied art inside a device screenshot.
//
//   node icon_match.js <screenshot.png> <art.png> <x0> <y0> <x1> <y1> <k>
//
// Coarse-to-fine: downsample everything by 1/k (k=4), slide the art over the
// region over a range of sizes, then refine at k=2 around the best hit.
// Prints best (size, centre, MAE) plus the runner-up, so a real match is obvious.
const { decode } = require('./crop_png.js');

function toGray(img, x0, y0, x1, y1, k) {
  const w = Math.floor((x1 - x0) / k), h = Math.floor((y1 - y0) / k);
  const out = new Float64Array(w * h);
  const { w: iw, ch, px } = img;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let sum = 0;
      for (let dy = 0; dy < k; dy++) {
        for (let dx = 0; dx < k; dx++) {
          const i = ((y0 + y * k + dy) * iw + (x0 + x * k + dx)) * ch;
          sum += 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
        }
      }
      out[y * w + x] = sum / (k * k);
    }
  }
  return { w, h, px: out };
}

const g0 = (g, x, y) => g.px[y * g.w + x];

function resizeGray(g, S) {
  const out = new Float64Array(S * S);
  const sx = g.w / S, sy = g.h / S;
  for (let y = 0; y < S; y++) {
    for (let x = 0; x < S; x++) {
      const fx = Math.min(g.w - 1, (x + 0.5) * sx - 0.5);
      const fy = Math.min(g.h - 1, (y + 0.5) * sy - 0.5);
      const x0 = Math.max(0, Math.floor(fx)), y0 = Math.max(0, Math.floor(fy));
      const x1 = Math.min(g.w - 1, x0 + 1), y1 = Math.min(g.h - 1, y0 + 1);
      const tx = fx - x0, ty = fy - y0;
      out[y * S + x] =
        (g0(g, x0, y0) * (1 - tx) + g0(g, x1, y0) * tx) * (1 - ty) +
        (g0(g, x0, y1) * (1 - tx) + g0(g, x1, y1) * tx) * ty;
    }
  }
  return { w: S, h: S, px: out };
}

function mae(tpl, region, ox, oy) {
  let sum = 0, n = 0;
  for (let y = 0; y < tpl.h; y++) {
    for (let x = 0; x < tpl.w; x++) {
      const rx = ox + x, ry = oy + y;
      if (rx < 0 || ry < 0 || rx >= region.w || ry >= region.h) { sum += 200; n++; continue; }
      sum += Math.abs(tpl.px[y * tpl.w + x] - g0(region, rx, ry));
      n++;
    }
  }
  return sum / n;
}

function search(art, region, minS, maxS, step) {
  const hits = [];
  for (let S = minS; S <= maxS; S += step) {
    const tpl = resizeGray(art, S);
    for (let oy = 0; oy + S <= region.h; oy++) {
      for (let ox = 0; ox + S <= region.w; ox++) {
        hits.push({ S, ox, oy, mae: mae(tpl, region, ox, oy) });
      }
    }
  }
  hits.sort((a, b) => a.mae - b.mae);
  return hits;
}

const [shot, artFile, x0s, y0s, x1s, y1s] = process.argv.slice(2);
const x0 = +x0s, y0 = +y0s, x1 = +x1s, y1 = +y1s;
const shotImg = decode(shot), artImg = decode(artFile);

// coarse pass at 1/4
const K = 4;
const region = toGray(shotImg, x0, y0, x1, y1, K);
const art = toGray(artImg, 0, 0, artImg.w, artImg.h, K);
console.log('粗搜区域', `${region.w}x${region.h}`, '（1/' + K + ' 缩放）');
const coarse = search(art, region, 24, 40, 1);
const best = coarse[0];
console.log('粗搜最佳：尺寸', best.S * K, 'px  MAE', best.mae.toFixed(1),
  ' 中心', (x0 + (best.ox + best.S / 2) * K).toFixed(0) + ',' + (y0 + (best.oy + best.S / 2) * K).toFixed(0));
// runner-up far away from the best (a different spot)
const far = coarse.find((h) => Math.hypot(h.ox - best.ox, h.oy - best.oy) > 8);
console.log('粗搜次优（远处）：尺寸', far.S * K, 'px  MAE', far.mae.toFixed(1),
  ' 中心', (x0 + (far.ox + far.S / 2) * K).toFixed(0) + ',' + (y0 + (far.oy + far.S / 2) * K).toFixed(0));

// fine pass at 1/2 around the coarse hit
const K2 = 2;
const fx0 = x0 + (best.ox - 6) * K, fy0 = y0 + (best.oy - 6) * K;
const fine = toGray(shotImg, Math.max(0, fx0), Math.max(0, fy0), Math.min(shotImg.w, x0 + (best.ox + best.S + 6) * K), Math.min(shotImg.h, y0 + (best.oy + best.S + 6) * K), K2);
const art2 = toGray(artImg, 0, 0, artImg.w, artImg.h, K2);
const res = search(art2, fine, Math.round(best.S * K / K2) - 8, Math.round(best.S * K / K2) + 8, 1);
const b2 = res[0];
const far2 = res.find((h) => Math.hypot(h.ox - b2.ox, h.oy - b2.oy) > 16);
console.log('细搜（1/' + K2 + '）最佳：尺寸', b2.S * K2, 'px  MAE', b2.mae.toFixed(1),
  ' 位置', (Math.max(0, fx0) + b2.ox * K2) + ',' + (Math.max(0, fy0) + b2.oy * K2));
console.log('细搜次优（远处）：MAE', far2 ? far2.mae.toFixed(1) : '-');
console.log('→ 判定：', b2.mae < 22 && (!far2 || far2.mae - b2.mae > 8)
  ? '截图里有这张原图（尺寸/位置已定位）' : '不确定，需要人工看图');
