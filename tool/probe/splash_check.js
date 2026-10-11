// 冷启动截图体检：底色是不是白、图标在哪、底下那行 GraceLink 有没有被蒙版切掉。
// 用法：node build/probe/splash_check.js build/probe/splash1.png [...]
const { decode } = require('./crop_png.js');
const fs = require('fs');

for (const file of process.argv.slice(2)) {
  const img = decode(file);
  const { w, h, ch, px } = img;
  const at = (x, y) => {
    const i = (y * w + x) * ch;
    return [px[i], px[i + 1], px[i + 2], ch === 4 ? px[i + 3] : 255];
  };
  let white = 0, navy = 0, blue = 0, dark = 0;
  let minX = w, minY = h, maxX = -1, maxY = -1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const [r, g, b] = at(x, y);
      const isWhite = r > 245 && g > 245 && b > 245;
      if (isWhite) { white++; continue; }
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      // 藏青那行字：蓝比红绿明显高、整体偏暗
      if (r < 90 && g < 110 && b > 60 && b < 175) navy++;
      else if (b > r + 25 && b > 150) blue++;
      else if (r < 90 && g < 90 && b < 90) dark++;
    }
  }
  const box = maxX < 0
    ? null
    : { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1,
        '中心x/屏宽': ((minX + maxX) / 2 / w).toFixed(3) };
  console.log(JSON.stringify({
    file: file.replace(/.*[\\/]/, ''),
    尺寸: `${w}x${h}`,
    '白占比%': (white / (w * h) * 100).toFixed(2),
    左上角: at(5, 5),
    非白包围盒: box,
    藏青像素: navy,
    蓝像素: blue,
    深色像素: dark,
  }, null, 1));
  // 非白区域每一行的像素数（看图形轮廓：圆盘宽、字行窄）
  if (box) {
    const rows = [];
    for (let y = box.y; y <= box.y + box.h - 1; y += Math.max(1, Math.round(box.h / 14))) {
      let n = 0;
      for (let x = 0; x < w; x++) {
        const [r, g, b] = at(x, y);
        if (!(r > 245 && g > 245 && b > 245)) n++;
      }
      rows.push(`y${y}:${n}`);
    }
    console.log('  行宽采样 ' + rows.join(' '));
  }
}
