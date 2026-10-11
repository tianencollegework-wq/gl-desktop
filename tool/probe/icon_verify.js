// Verify the launcher icon from a device screenshot by structural signature:
// the user's art is a white page with a blue gradient disc + a dark navy wordmark,
// while the keyed version was a flat blue tile with a white glyph and no white
// background / no navy text. Usage: node icon_verify.js <screenshot.png> [x0 x1 y0 y1]
const { decode } = require('./crop_png.js');

function stats(img, x0, x1, y0, y1) {
  const { w, ch, px } = img;
  const p = (x, y) => { const i = (y * w + x) * ch; return [px[i], px[i + 1], px[i + 2]]; };
  let white = 0, blue = 0, navy = 0, total = 0;
  let wx0 = 1e9, wx1 = -1, wy0 = 1e9, wy1 = -1;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const [r, g, b] = p(x, y);
      total++;
      if (r > 250 && g > 250 && b > 250) {
        white++;
        if (x < wx0) wx0 = x; if (x > wx1) wx1 = x;
        if (y < wy0) wy0 = y; if (y > wy1) wy1 = y;
      }
      const bl = b - (r + g) / 2;
      if (bl > 25) blue++;
      if (0.299 * r + 0.587 * g + 0.114 * b < 110 && bl > 15) navy++;
    }
  }
  const box = wx1 < 0 ? null : { wx0, wy0, wx1, wy1, side: wx1 - wx0 + 1 };
  // navy ink that sits in the lower quarter of the white box (= the wordmark band)
  let navyLow = 0;
  if (box) {
    const lo = Math.round(box.wy1 - (box.wy1 - box.wy0) * 0.25);
    for (let y = lo; y <= box.wy1; y++) {
      for (let x = box.wx0; x <= box.wx1; x++) {
        const [r, g, b] = p(x, y);
        if (0.299 * r + 0.587 * g + 0.114 * b < 110 && b - (r + g) / 2 > 15) navyLow++;
      }
    }
  }
  return { total, white, blue, navy, navyLow, box };
}

const [file, ...rect] = process.argv.slice(2);
const img = decode(file);
const [x0, x1, y0, y1] = rect.length ? rect.map(Number) : [0, img.w, 0, img.h];
const s = stats(img, x0, x1, y0, y1);
const pct = (n) => ((n / s.total) * 100).toFixed(2) + '%';
console.log(`--- ${file}  区域 ${x0},${y0}..${x1},${y1} (${s.total} px)`);
console.log(`  纯白 ${s.white} (${pct(s.white)})   蓝(蓝度>25) ${s.blue} (${pct(s.blue)})   藏青 ${s.navy}`);
console.log(`  纯白像素 bbox ${s.box ? `${s.box.wx0},${s.box.wy0}..${s.box.wx1},${s.box.wy1} 边长 ${s.box.side}` : '无'}`);
console.log(`  白框下四分之一里的藏青像素: ${s.navyLow}`);
