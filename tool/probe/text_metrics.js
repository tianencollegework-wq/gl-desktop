// Measure text band heights inside a region of a screenshot.
// Usage: node text_metrics.js <png> <x0> <x1> <y0> <y1> [darkLuma=170] [minPixels=4]
// Prints each band of consecutive "dark" rows: { y0, y1, height }.
const { decode } = require('./crop_png.js');

const [file, x0s, x1s, y0s, y1s, darkS, minS] = process.argv.slice(2);
const x0 = +x0s, x1 = +x1s, y0 = +y0s, y1 = +y1s;
const dark = +(darkS || 170), min = +(minS || 4);
const img = decode(file);
if (img.ch < 3) throw new Error('need color image');
const bands = [];
let cur = null;
for (let y = y0; y < y1; y++) {
  let n = 0;
  for (let x = x0; x < x1; x++) {
    const i = (y * img.w + x) * img.ch;
    const luma = 0.299 * img.px[i] + 0.587 * img.px[i + 1] + 0.114 * img.px[i + 2];
    if (luma < dark) n++;
  }
  if (n >= min) {
    if (!cur) cur = { y0: y, y1: y };
    else cur.y1 = y;
  } else if (cur) {
    bands.push(cur);
    cur = null;
  }
}
if (cur) bands.push(cur);
console.log(file, JSON.stringify(bands.map((b) => ({ y0: b.y0, h: b.y1 - b.y0 + 1 }))));
