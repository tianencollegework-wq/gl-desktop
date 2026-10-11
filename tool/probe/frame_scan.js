// 扫一遍 screenrecord 抽出来的帧，找出「冷启动那一屏」并报告上面的内容。
// 用法：node build/probe/frame_scan.js build/probe/frames/*.png
const { decode } = require('./crop_png.js');

const STRIDE = 3;
for (const file of process.argv.slice(2).sort()) {
  const { w, h, ch, px } = decode(file);
  let white = 0, blue = 0, navy = 0, other = 0, n = 0;
  let minX = w, minY = h, maxX = -1, maxY = -1;
  for (let y = 0; y < h; y += STRIDE) {
    for (let x = 0; x < w; x += STRIDE) {
      const i = (y * w + x) * ch;
      const r = px[i], g = px[i + 1], b = px[i + 2];
      n++;
      if (r > 245 && g > 245 && b > 245) { white++; continue; }
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (b > r + 30 && b > 150 && g > 120) blue++;
      else if (r < 95 && g < 115 && b > 55 && b < 180) navy++;
      else other++;
    }
  }
  console.log(
    file.replace(/.*[\\/]/, ''),
    `白${(white / n * 100).toFixed(1)}%`,
    `蓝${blue}`,
    `藏青${navy}`,
    `其它${other}`,
    maxX >= 0
      ? `非白框 ${minX},${minY} ${maxX - minX + 1}x${maxY - minY + 1} 中心x=${((minX + maxX) / 2 / w).toFixed(2)}`
      : '全白',
  );
}
