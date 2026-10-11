// Inspect the new logo source: locate the blue disc, sample its palette, and
// suggest a "blueness" threshold that separates the white glyph from the disc.
const { decode } = require('./crop_png.js');

const img = decode(process.argv[2]);
const { w, h, ch, px } = img;
const at = (x, y) => {
  const i = (y * w + x) * ch;
  return [px[i], px[i + 1], px[i + 2]];
};
// blueness: blue minus the average of red/green. White glyph ~0, light blue disc > 20.
const blueness = (x, y) => {
  const [r, g, b] = at(x, y);
  return b - (r + g) / 2;
};

let minX = w, maxX = -1, minY = h, maxY = -1;
const hist = new Map();
for (let y = 0; y < h; y++) {
  for (let x = 0; x < w; x++) {
    const d = Math.round(blueness(x, y));
    if (d > 25) {
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    hist.set(d, (hist.get(d) || 0) + 1);
  }
}
const bw = maxX - minX + 1, bh = maxY - minY + 1;
console.log('disc bbox', { minX, minY, maxX, maxY, w: bw, h: bh });
console.log('center', { cx: (minX + maxX) / 2, cy: (minY + maxY) / 2, r: (bw + bh) / 4 });

// circularity: horizontal extent on a few rows through the middle
for (const frac of [0.25, 0.5, 0.75]) {
  const y = Math.round(minY + bh * frac);
  let l = -1, r = -1;
  for (let x = 0; x < w; x++) if (blueness(x, y) > 25) { if (l < 0) l = x; r = x; }
  console.log('row', y, 'span', l, r, 'width', r - l + 1);
}

const cx = Math.round((minX + maxX) / 2), cy = Math.round((minY + maxY) / 2);
console.log('palette inside disc:');
for (const [dx, dy, label] of [[0.75, -0.6, '右上'], [-0.75, 0.6, '左下'], [0, 0, '中心'], [-0.7, -0.6, '左上'], [0.7, 0.6, '右下']]) {
  const x = Math.round(cx + dx * bw / 2), y = Math.round(cy + dy * bh / 2);
  console.log(' ', label, x, y, at(x, y), 'blueness', Math.round(blueness(x, y)));
}
console.log('outside disc corner', at(5, 5), 'blueness', Math.round(blueness(5, 5)));

// blueness histogram restricted to the disc; look for the gap between glyph and background
const R = (bw + bh) / 4;
const inDisc = new Map();
for (let y = minY; y <= maxY; y++) {
  for (let x = minX; x <= maxX; x++) {
    if ((x - cx) ** 2 + (y - cy) ** 2 > (R - 3) ** 2) continue;
    const d = Math.round(blueness(x, y));
    inDisc.set(d, (inDisc.get(d) || 0) + 1);
  }
}
const keys = [...inDisc.keys()].sort((a, b) => a - b);
console.log('blueness histogram inside disc (value:count) low->high:');
console.log(keys.map((k) => `${k}:${inDisc.get(k)}`).join('  '));
