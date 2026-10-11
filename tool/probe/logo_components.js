// Connected components of the keyed glyph mask (alpha > 0.5): area + bbox each.
// Usage: node logo_components.js <src.png> [lo=2] [hi=18]
const { decode } = require('./crop_png.js');

const [file, loS, hiS] = process.argv.slice(2);
const LO = +(loS ?? 2), HI = +(hiS ?? 18);
const img = decode(file);
const { w, h, ch, px } = img;
const blueness = (x, y) => { const i = (y * w + x) * ch; return px[i + 2] - (px[i] + px[i + 1]) / 2; };

let minX = w, maxX = -1, minY = h, maxY = -1;
for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
  if (blueness(x, y) > 25) { if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y; }
}
const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
const ra = (maxX - minX) / 2, rb = (maxY - minY) / 2;

const mask = new Uint8Array(w * h);
for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
  const e = ((x - cx) / (ra - 3)) ** 2 + ((y - cy) / (rb - 3)) ** 2;
  if (e > 1) continue;
  if (blueness(x, y) <= LO + (HI - LO) * 0.5) mask[y * w + x] = 1;
}

const label = new Int32Array(w * h).fill(-1);
const comps = [];
const stack = [];
for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
  if (!mask[y * w + x] || label[y * w + x] >= 0) continue;
  const id = comps.length;
  const c = { id, area: 0, x0: x, x1: x, y0: y, y1: y };
  stack.push([x, y]);
  label[y * w + x] = id;
  while (stack.length) {
    const [pxx, pyy] = stack.pop();
    c.area++;
    if (pxx < c.x0) c.x0 = pxx; if (pxx > c.x1) c.x1 = pxx;
    if (pyy < c.y0) c.y0 = pyy; if (pyy > c.y1) c.y1 = pyy;
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const nx = pxx + dx, ny = pyy + dy;
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      if (!mask[ny * w + nx] || label[ny * w + nx] >= 0) continue;
      label[ny * w + nx] = id;
      stack.push([nx, ny]);
    }
  }
  comps.push(c);
}
comps.sort((a, b) => b.area - a.area);
console.log('components:', comps.length, 'components >= 20px:',
  comps.filter((c) => c.area >= 20).length);
for (const c of comps.slice(0, 20)) {
  console.log(` #${c.id} area=${c.area} bbox=[${c.x0},${c.y0}]-[${c.x1},${c.y1}] size=${c.x1 - c.x0 + 1}x${c.y1 - c.y0 + 1}`);
}
console.log('total pixels in comps < 150px:', comps.filter((c) => c.area < 150).reduce((s, c) => s + c.area, 0));
